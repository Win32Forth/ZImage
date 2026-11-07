package httpapi

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/detail"
	"zimage/helper/internal/dhashindex"
	"zimage/helper/internal/pathsafe"
	"zimage/helper/internal/thumb"
)

type rowScanner interface {
	Scan(dest ...any) error
}

func scanAsset(row rowScanner) (assetJSON, int64, error) {
	var item assetJSON
	var id int64
	var keeper, pinned int64
	var score sql.NullFloat64
	var pixels sql.NullInt64
	var thumb, support, capture, source, detailSource sql.NullString
	var width, height sql.NullInt64
	var hash sql.NullInt64
	err := row.Scan(
		&id, &item.UID, &item.RelPath, &item.Ext, &item.MediaClass, &score, &pixels,
		&keeper, &item.Placement, &pinned, &item.Phase, &thumb, &support,
		&item.CaptureConfidence, &capture, &source, &width, &height, &hash, &detailSource,
	)
	if err != nil {
		return assetJSON{}, 0, err
	}
	item.IsKeeper = keeper != 0
	item.Pinned = pinned != 0
	if score.Valid {
		item.DetailScore = &score.Float64
	}
	if pixels.Valid {
		item.NativePixels = &pixels.Int64
	}
	if thumb.Valid {
		item.ThumbRel = &thumb.String
	}
	if support.Valid {
		item.DecodeSupport = &support.String
	}
	if capture.Valid {
		item.CaptureTime = &capture.String
	}
	if source.Valid {
		item.CaptureSource = &source.String
	}
	if width.Valid {
		w := int(width.Int64)
		item.Width = &w
	}
	if height.Valid {
		h := int(height.Int64)
		item.Height = &h
	}
	if hash.Valid {
		text := fmt.Sprintf("%016x", uint64(hash.Int64))
		item.DHash = &text
	}
	if detailSource.Valid {
		item.DetailSource = &detailSource.String
	}
	return item, id, nil
}

func (s *Server) assetOne(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	item, ok := s.loadUID(w, r.PathValue("uid"))
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (s *Server) loadUID(w http.ResponseWriter, uid string) (assetJSON, bool) {
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return assetJSON{}, false
	}
	if !plainUID(uid) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return assetJSON{}, false
	}
	item, _, err := scanAsset(s.Catalog.Read.QueryRow(assetSelect+` WHERE uid = ?`, uid))
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return assetJSON{}, false
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return assetJSON{}, false
	}
	return item, true
}

type factsRequest struct {
	DHash       string  `json:"dhash"`
	Width       int     `json:"width"`
	Height      int     `json:"height"`
	Thumbnail   string  `json:"thumbnail"`
	CaptureTime string  `json:"captureTime"`
	// Present so a client cannot set them by sending the field. They are ignored.
	CaptureConfidence float64 `json:"captureConfidence"`
	IsKeeper          bool    `json:"isKeeper"`
}

func (s *Server) assetFacts(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	uid := r.PathValue("uid")
	if !plainUID(uid) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
	var body factsRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body"})
		return
	}
	// A checkpoint must not set confidence 1 or is_keeper. Those fields are discarded.
	_ = body.CaptureConfidence
	_ = body.IsKeeper
	var id int64
	var source string
	err := s.Catalog.Read.QueryRow(`SELECT id, COALESCE(capture_source, '') FROM assets WHERE uid = ?`, uid).Scan(&id, &source)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	now := time.Now().UTC().Format(time.RFC3339)
	thumbRel := any(nil)
	if body.Thumbnail != "" {
		raw, err := base64.StdEncoding.DecodeString(body.Thumbnail)
		if err != nil || len(raw) == 0 || len(raw) > 2<<20 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "thumbnail"})
			return
		}
		rel := thumb.CacheRel(uid)
		if err := pathsafe.Jail(s.Root, rel); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "thumbnail"})
			return
		}
		full := filepath.Join(s.Root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		if err := os.WriteFile(full, raw, 0o644); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		thumbRel = rel
	}
	var hash any
	var b0, b1, b2, b3, b4, b5 any
	if body.DHash != "" {
		value, err := strconv.ParseUint(body.DHash, 16, 64)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "dhash"})
			return
		}
		hash = int64(value)
		bands := dhashindex.Bands(value)
		b0, b1, b2, b3, b4, b5 = int64(bands[0]), int64(bands[1]), int64(bands[2]), int64(bands[3]), int64(bands[4]), int64(bands[5])
	}
	var width, height, pixels any
	if body.Width > 0 && body.Height > 0 {
		width = body.Width
		height = body.Height
		pixels = int64(body.Width) * int64(body.Height)
	}
	_, err = s.Catalog.Write.Exec(`
		UPDATE assets
		SET dhash = COALESCE(?, dhash),
			dhash_b0 = COALESCE(?, dhash_b0),
			dhash_b1 = COALESCE(?, dhash_b1),
			dhash_b2 = COALESCE(?, dhash_b2),
			dhash_b3 = COALESCE(?, dhash_b3),
			dhash_b4 = COALESCE(?, dhash_b4),
			dhash_b5 = COALESCE(?, dhash_b5),
			width = COALESCE(?, width),
			height = COALESCE(?, height),
			native_pixels = COALESCE(?, native_pixels),
			thumb_rel = COALESCE(?, thumb_rel),
			phase = CASE WHEN phase = 'discovered' AND ? IS NOT NULL THEN 'thumbed' ELSE phase END,
			updated_at = ?
		WHERE id = ?`,
		hash, b0, b1, b2, b3, b4, b5, width, height, pixels, thumbRel, thumbRel, now, id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if source != "user" && body.CaptureTime != "" {
		suggested := dating.Suggest(body.CaptureTime, time.Now())
		if suggested.HasCapture && suggested.Confidence < dating.ConfidenceUser {
			if err := writeSuggested(s, id, suggested); err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
				return
			}
		}
	}
	item, ok := s.loadUID(w, uid)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func writeSuggested(s *Server, id int64, d dating.Decision) error {
	stored := d.StoredTime()
	now := time.Now().UTC().Format(time.RFC3339)
	offset := 0
	if d.OffsetKnown {
		offset = 1
	}
	_, err := s.Catalog.Write.Exec(`
		UPDATE assets
		SET capture_time = ?, capture_offset_known = ?, capture_source = ?, capture_confidence = ?,
			candidate_capture_time = ?,
			phase = CASE WHEN phase IN ('placed', 'parked', 'planned', 'clustered', 'thumbed') THEN phase ELSE 'dated' END,
			updated_at = ?
		WHERE id = ? AND COALESCE(capture_source, '') != 'user'`,
		stored, offset, d.Source, d.Confidence, stored, now, id)
	return err
}

type detailRequest struct {
	DetailScore  float64 `json:"detailScore"`
	NativePixels int64   `json:"nativePixels"`
	Width        int     `json:"width"`
	Height       int     `json:"height"`
	DetailSource string  `json:"detailSource"`
	IsKeeper     bool    `json:"isKeeper"`
}

func (s *Server) assetDetail(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	uid := r.PathValue("uid")
	if !plainUID(uid) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var body detailRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body"})
		return
	}
	if body.DetailSource != "mac" && body.DetailSource != "preview_only" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "detail_source"})
		return
	}
	_ = body.IsKeeper
	var id int64
	err := s.Catalog.Read.QueryRow(`SELECT id FROM assets WHERE uid = ?`, uid).Scan(&id)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	now := time.Now().UTC().Format(time.RFC3339)
	var width, height, pixels any
	if body.Width > 0 {
		width = body.Width
	}
	if body.Height > 0 {
		height = body.Height
	}
	if body.NativePixels > 0 {
		pixels = body.NativePixels
	}
	// isKeeper in the body is ignored. The helper recomputes it.
	_, err = s.Catalog.Write.Exec(`
		UPDATE assets
		SET detail_score = ?, detail_source = ?, native_pixels = COALESCE(?, native_pixels),
			width = COALESCE(?, width), height = COALESCE(?, height), updated_at = ?
		WHERE id = ?`,
		body.DetailScore, body.DetailSource, pixels, width, height, now, id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if err := detail.Recompute(s.Catalog, id); err != nil && err != sql.ErrNoRows {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	item, ok := s.loadUID(w, uid)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (s *Server) assetDate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	uid := r.PathValue("uid")
	if !plainUID(uid) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var body struct {
		CaptureTime string `json:"captureTime"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body"})
		return
	}
	decision, ok := dating.User(body.CaptureTime)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "date"})
		return
	}
	var id int64
	err := s.Catalog.Read.QueryRow(`SELECT id FROM assets WHERE uid = ?`, uid).Scan(&id)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if err := dating.EnqueueUserDate(s.Catalog, id, decision); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	item, ok := s.loadUID(w, uid)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	rows, err := s.Catalog.Read.Query(`
		SELECT uid, name, name_source, start_time, end_time, slug, folder_rel, gps_lat, gps_lon
		FROM events ORDER BY id`)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	defer rows.Close()
	type eventJSON struct {
		UID        string   `json:"uid"`
		Name       string   `json:"name"`
		NameSource string   `json:"nameSource"`
		StartTime  *string  `json:"startTime"`
		EndTime    *string  `json:"endTime"`
		Slug       string   `json:"slug"`
		FolderRel  *string  `json:"folderRel"`
		GPSLat     *float64 `json:"gpsLat"`
		GPSLon     *float64 `json:"gpsLon"`
	}
	list := make([]eventJSON, 0)
	for rows.Next() {
		var item eventJSON
		var start, end, folder sql.NullString
		var lat, lon sql.NullFloat64
		if err := rows.Scan(&item.UID, &item.Name, &item.NameSource, &start, &end, &item.Slug, &folder, &lat, &lon); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		if start.Valid {
			item.StartTime = &start.String
		}
		if end.Valid {
			item.EndTime = &end.String
		}
		if folder.Valid {
			item.FolderRel = &folder.String
		}
		if lat.Valid {
			item.GPSLat = &lat.Float64
		}
		if lon.Valid {
			item.GPSLon = &lon.Float64
		}
		list = append(list, item)
	}
	writeJSON(w, http.StatusOK, map[string]any{"rows": list})
}

func plainUID(uid string) bool {
	if uid == "" || len(uid) > 80 {
		return false
	}
	for _, c := range uid {
		switch {
		case c >= '0' && c <= '9':
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c == '-':
		default:
			return false
		}
	}
	return true
}

func fourDigits(text string) bool {
	if len(text) != 4 {
		return false
	}
	for _, c := range text {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func likeContains(text string) string {
	var b strings.Builder
	b.WriteByte('%')
	for _, r := range text {
		if r == '%' || r == '_' || r == '\\' {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	b.WriteByte('%')
	return b.String()
}
