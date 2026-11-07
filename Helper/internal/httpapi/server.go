// Package httpapi is the helper's LAN API.
// GET /v1/health is the only unauthenticated route, and its body has no paths and no token.
package httpapi

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/move"
	"zimage/helper/internal/pathsafe"
)

// Server is one helper listener. v1 binds tcp4 only.
type Server struct {
	Root          string
	LibraryRootOK bool
	AllowLoopback bool
	Token         string
	Catalog       *db.Catalog
	MaxEditBytes  int64
	Leaf          *x509.Certificate
	LogPath       string
	LogMax        int64
	Now           func() time.Time

	tlsCert  tls.Certificate
	limiter  limiter
	rss      atomic.Int64
	shedWork atomic.Bool
	mu       sync.Mutex
	fileMu   sync.Mutex
	httpSrv  *http.Server
	runner   *move.Runner
	trim     *move.Runner

	planMu      sync.Mutex
	planLive    bool
	planPrefix  string
	planMove    int
	planAlready int
	planPark    int
	planLeave   int
	planSeen    int
}

// UseRunner shares the process mover with boot recovery and the reorg routes.
func (s *Server) UseRunner(r *move.Runner) {
	s.mu.Lock()
	s.runner = r
	s.mu.Unlock()
}

func (s *Server) reorgRunner() *move.Runner {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.runner == nil && s.Catalog != nil {
		s.runner = &move.Runner{Root: s.Root, Catalog: s.Catalog, Note: s.Note, Shed: s.Shedding}
	}
	return s.runner
}

// UseTrim shares the trim mover with boot recovery and the trim routes.
func (s *Server) UseTrim(r *move.Runner) {
	s.mu.Lock()
	s.trim = r
	s.mu.Unlock()
}

func (s *Server) trimRunner() *move.Runner {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.trim == nil && s.Catalog != nil {
		s.trim = &move.Runner{Root: s.Root, Catalog: s.Catalog, JobKind: "trim", Note: s.Note, Shed: s.Shedding}
	}
	return s.trim
}

// NewServer stores the certificate the listener will present.
func NewServer(root string, ok bool, allowLoopback bool, token string, catalog *db.Catalog, pair tls.Certificate, leaf *x509.Certificate) *Server {
	return &Server{
		Root:          root,
		LibraryRootOK: ok,
		AllowLoopback: allowLoopback,
		Token:         token,
		Catalog:       catalog,
		Leaf:          leaf,
		tlsCert:       pair,
	}
}

// ListenIPv4 opens a tcp4 socket. An IPv6 address fails this call.
func ListenIPv4(addr string) (net.Listener, error) {
	ln, err := net.Listen("tcp4", addr)
	if err != nil {
		return nil, err
	}
	tcp, ok := ln.Addr().(*net.TCPAddr)
	if !ok || tcp.IP.To4() == nil {
		_ = ln.Close()
		return nil, errors.New("listener is not IPv4")
	}
	return ln, nil
}

// Serve wraps ln in TLS 1.2+ and serves until Close. A non-IPv4 socket is refused.
func (s *Server) Serve(ln net.Listener) error {
	tcp, ok := ln.Addr().(*net.TCPAddr)
	if !ok || tcp.IP.To4() == nil {
		return errors.New("listener is not IPv4")
	}
	cfg := &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{s.tlsCert},
	}
	s.mu.Lock()
	s.httpSrv = &http.Server{
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	srv := s.httpSrv
	s.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.watchRSS(ctx)
	return srv.Serve(tls.NewListener(ln, cfg))
}

// Close stops the listener.
func (s *Server) Close() error {
	s.mu.Lock()
	srv := s.httpSrv
	s.mu.Unlock()
	if srv == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return srv.Shutdown(ctx)
}

// Handler is the route table. Tests call it without a socket.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/health", s.guard(false, s.health))
	mux.HandleFunc("/v1/pair/claim", s.guard(false, s.claim))
	mux.HandleFunc("/v1/assets/{uid}/to-duplicates", s.guard(true, s.toDuplicates))
	mux.HandleFunc("/v1/assets/{uid}/restore", s.guard(true, s.restoreAsset))
	mux.HandleFunc("/v1/assets/{uid}/pin", s.guard(true, s.pinAsset))
	mux.HandleFunc("/v1/assets/{uid}/purge", s.guard(true, s.purgeAsset))
	mux.HandleFunc("/v1/duplicates/purge-all", s.guard(true, s.purgeAll))
	mux.HandleFunc("/v1/duplicates", s.guard(true, s.duplicates))
	mux.HandleFunc("/v1/assets/{uid}/thumbnail", s.guard(true, s.assetThumbnail))
	mux.HandleFunc("/v1/assets/{uid}/facts", s.guard(true, s.assetFacts))
	mux.HandleFunc("/v1/assets/{uid}/detail", s.guard(true, s.assetDetail))
	mux.HandleFunc("/v1/assets/{uid}/date", s.guard(true, s.assetDate))
	mux.HandleFunc("/v1/assets/{uid}", s.guard(true, s.assetOne))
	mux.HandleFunc("/v1/assets", s.guard(true, s.assets))
	mux.HandleFunc("/v1/events/{uid}", s.guard(true, s.eventRename))
	mux.HandleFunc("/v1/events", s.guard(true, s.events))
	mux.HandleFunc("/v1/edits/{uid}", s.guard(true, s.edits))
	mux.HandleFunc("/v1/reorg/plan", s.guard(true, s.reorgPlan))
	mux.HandleFunc("/v1/reorg/start", s.guard(true, s.reorgStart))
	mux.HandleFunc("/v1/reorg/pause", s.guard(true, s.reorgPause))
	mux.HandleFunc("/v1/reorg/resume", s.guard(true, s.reorgResume))
	mux.HandleFunc("/v1/reorg/status", s.guard(true, s.reorgStatus))
	mux.HandleFunc("/v1/trim/start", s.guard(true, s.trimStart))
	mux.HandleFunc("/v1/trim/pause", s.guard(true, s.trimPause))
	mux.HandleFunc("/v1/trim/continue", s.guard(true, s.trimContinue))
	mux.HandleFunc("/v1/trim/status", s.guard(true, s.trimStatus))
	return mux
}

func (s *Server) guard(requireBearer bool, next func(http.ResponseWriter, *http.Request)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := remoteIP(r)
		if !allowedSource(ip, s.AllowLoopback) {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}
		ipKey := ""
		if ip != nil {
			ipKey = ip.String()
		}
		if requireBearer || r.URL.Path == "/v1/pair/claim" {
			if s.limiter.silenced(ipKey, s.now()) {
				writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "slow down"})
				return
			}
		}
		if requireBearer && !tokensEqual(bearerToken(r.Header.Get("Authorization")), s.Token) {
			s.noteAuthFail(ipKey)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next(w, r)
	}
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	body := healthBody{
		Status:         "library_unavailable",
		SchemaVersion:  db.SchemaVersion,
		LibraryRootOK:  false,
		ManualOpsClear: false,
		RSSBytes:       s.rss.Load(),
	}
	if s.LibraryRootOK && s.Catalog != nil {
		body.Status = "ok"
		body.LibraryRootOK = true
		body.ManualOpsClear = true
		body.ReorgSafeToReboot = true
		body.TrimSafeToReboot = true
		var version int
		if err := s.Catalog.Read.QueryRow(`PRAGMA user_version`).Scan(&version); err == nil && version > 0 {
			body.SchemaVersion = version
		}
		rows, err := s.Catalog.Read.Query(`SELECT job_kind, run_state, safe_to_reboot FROM job_state`)
		if err == nil {
			defer rows.Close()
			trimStored := 1
			for rows.Next() {
				var kind, runState string
				var safe int
				if err := rows.Scan(&kind, &runState, &safe); err != nil {
					continue
				}
				switch kind {
				case "reorg":
					body.ReorgRunState = runState
				case "trim":
					body.TrimRunState = runState
					trimStored = safe
				}
			}
			if safe, err := move.ReorgSafe(s.Catalog); err == nil {
				body.ReorgSafeToReboot = safe
			}
			trimLive := true
			if live, err := move.TrimLive(s.Catalog); err == nil {
				trimLive = live
			}
			body.TrimSafeToReboot = trimStored != 0 && trimLive
		}
		var openManual int
		err = s.Catalog.Read.QueryRow(`
			SELECT COUNT(*) FROM journal
			WHERE job_kind IN ('manual_duplicate', 'restore', 'purge')
			AND state NOT IN ('planned', 'done', 'failed')`).Scan(&openManual)
		if err == nil {
			body.ManualOpsClear = openManual == 0
		}
		var cacheBytes int64
		if err := s.Catalog.Read.QueryRow(`SELECT COALESCE(SUM(bytes), 0) FROM cache_objects`).Scan(&cacheBytes); err == nil {
			body.CacheBytes = cacheBytes
		}
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) claim(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Token == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	raw, _ := io.ReadAll(io.LimitReader(r.Body, 512))
	got := strings.TrimSpace(string(raw))
	if strings.HasPrefix(got, "{") {
		var wrap struct {
			Token string `json:"token"`
		}
		if json.Unmarshal([]byte(got), &wrap) == nil && wrap.Token != "" {
			got = wrap.Token
		}
	}
	pairing := filepath.Join(s.Root, ".zimage", "PAIRING-TOKEN")
	_, statErr := os.Stat(pairing)
	if statErr == nil {
		if tokensEqual(got, s.Token) {
			_ = os.Remove(pairing)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		s.noteAuthFail(remoteKey(r))
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	if tokensEqual(bearerToken(r.Header.Get("Authorization")), s.Token) {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	s.noteAuthFail(remoteKey(r))
	writeJSON(w, http.StatusConflict, map[string]string{"error": "claimed"})
}

type assetJSON struct {
	UID               string   `json:"uid"`
	RelPath           string   `json:"relPath"`
	Ext               string   `json:"ext"`
	MediaClass        string   `json:"mediaClass"`
	DetailScore       *float64 `json:"detailScore"`
	DetailSource      *string  `json:"detailSource"`
	NativePixels      *int64   `json:"nativePixels"`
	IsKeeper          bool     `json:"isKeeper"`
	Placement         string   `json:"placement"`
	Pinned            bool     `json:"pinned"`
	Phase             string   `json:"phase"`
	ThumbRel          *string  `json:"thumbRel"`
	DecodeSupport     *string  `json:"decodeSupport"`
	CaptureConfidence float64  `json:"captureConfidence"`
	CaptureTime       *string  `json:"captureTime"`
	CaptureSource     *string  `json:"captureSource"`
	Width             *int     `json:"width"`
	Height            *int     `json:"height"`
	DHash             *string  `json:"dhash"`
}

const assetSelect = `
	SELECT id, uid, rel_path, ext, media_class, detail_score, native_pixels,
		is_keeper, placement, pinned, phase, thumb_rel, decode_support,
		capture_confidence, capture_time, capture_source, width, height, dhash, detail_source
	FROM assets`

func (s *Server) assets(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	limit := 200
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 && n < limit {
			limit = n
		}
	}
	var after int64
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		after, _ = strconv.ParseInt(raw, 10, 64)
	}
	query := assetSelect + ` WHERE id > ?`
	args := []any{after}
	q := r.URL.Query()
	if q.Get("duplicates") == "1" {
		query += ` AND rel_path LIKE 'Photos/_Duplicates/%'`
	}
	if year := q.Get("year"); year != "" {
		if !fourDigits(year) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "year"})
			return
		}
		query += ` AND (capture_time LIKE ? OR rel_path LIKE ?)`
		args = append(args, year+"%", "Photos/"+year+"/%")
	}
	if event := q.Get("event"); event != "" {
		query += ` AND event_id = (SELECT id FROM events WHERE uid = ?)`
		args = append(args, event)
	}
	if q.Get("review") == "1" {
		query += ` AND (capture_confidence < 0.70 OR rel_path LIKE 'Photos/_Review/%')`
	}
	if text := q.Get("q"); text != "" {
		query += " AND rel_path LIKE ? ESCAPE '\\'"
		args = append(args, likeContains(text))
	}
	switch q.Get("media") {
	case "":
	case "video":
		query += ` AND media_class = 'video'`
	case "photo":
		query += ` AND media_class != 'video'`
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "media"})
		return
	}
	if q.Get("media") == "video" {
		query += ` ORDER BY CASE WHEN capture_time IS NULL OR capture_time = '' THEN 1 ELSE 0 END, capture_time, id LIMIT ?`
	} else {
		query += ` ORDER BY id LIMIT ?`
	}
	args = append(args, limit)
	queried, err := s.Catalog.Read.Query(query, args...)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	defer queried.Close()
	list := make([]assetJSON, 0)
	var lastID int64
	for queried.Next() {
		row, id, err := scanAsset(queried)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		list = append(list, row)
		lastID = id
	}
	next := ""
	if len(list) == limit {
		next = strconv.FormatInt(lastID, 10)
	}
	writeJSON(w, http.StatusOK, map[string]any{"rows": list, "nextCursor": next})
}

func (s *Server) assetThumbnail(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	uid := r.PathValue("uid")
	if uid == "" || strings.Contains(uid, ".") || strings.Contains(uid, "/") {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "needs_mac"})
		return
	}
	var rel sql.NullString
	err := s.Catalog.Read.QueryRow(`SELECT thumb_rel FROM assets WHERE uid = ?`, uid).Scan(&rel)
	if err != nil || !rel.Valid || rel.String == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "needs_mac"})
		return
	}
	if err := pathsafe.Jail(s.Root, rel.String); err != nil || !strings.HasPrefix(rel.String, ".zimage/cache/thumbs/") {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "needs_mac"})
		return
	}
	body, err := os.ReadFile(filepath.Join(s.Root, filepath.FromSlash(rel.String)))
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "needs_mac"})
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (s *Server) noteAuthFail(ip string) {
	s.limiter.fail(ip, s.now())
	s.logEvent("auth_fail")
}

// Note writes one short log event. The text must not include a path or a token.
func (s *Server) Note(event string) {
	s.logEvent(event)
}

// Shedding reports that thumbnail work should wait. The API stays up.
func (s *Server) Shedding() bool {
	return s.shedWork.Load()
}

func (s *Server) logEvent(event string) {
	if s.Token != "" && strings.Contains(event, s.Token) {
		event = "redacted"
	}
	line := s.now().UTC().Format(time.RFC3339) + " info " + event + "\n"
	_ = AppendLog(s.LogPath, line, s.LogMax)
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Server) watchRSS(ctx context.Context) {
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			n, ok := readRSS()
			if !ok {
				continue
			}
			s.rss.Store(n)
			if n >= rssShedBytes {
				s.shedWork.Store(true)
			} else {
				s.shedWork.Store(false)
			}
			if n >= rssBlockBytes && s.Catalog != nil {
				_, _ = s.Catalog.Write.Exec(`UPDATE job_state SET run_state = 'blocked' WHERE run_state = 'running'`)
			}
		}
	}
}

type healthBody struct {
	Status            string `json:"status"`
	SchemaVersion     int    `json:"schemaVersion"`
	LibraryRootOK     bool   `json:"libraryRootOK"`
	ManualOpsClear    bool   `json:"manualOpsClear"`
	ReorgSafeToReboot bool   `json:"reorgSafeToReboot"`
	TrimSafeToReboot  bool   `json:"trimSafeToReboot"`
	ReorgRunState     string `json:"reorgRunState"`
	TrimRunState      string `json:"trimRunState"`
	RSSBytes          int64  `json:"rssBytes"`
	CacheBytes        int64  `json:"cacheBytes"`
}

func remoteIP(r *http.Request) net.IP {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return net.ParseIP(r.RemoteAddr)
	}
	return net.ParseIP(host)
}

func remoteKey(r *http.Request) string {
	ip := remoteIP(r)
	if ip == nil {
		return ""
	}
	return ip.String()
}

func allowedSource(ip net.IP, allowLoopback bool) bool {
	v4 := ip.To4()
	if v4 == nil {
		return false
	}
	if allowLoopback && v4.IsLoopback() {
		return true
	}
	if v4[0] == 10 {
		return true
	}
	if v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31 {
		return true
	}
	if v4[0] == 192 && v4[1] == 168 {
		return true
	}
	if v4[0] == 169 && v4[1] == 254 {
		return true
	}
	return false
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
