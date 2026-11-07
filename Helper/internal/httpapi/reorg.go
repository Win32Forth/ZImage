package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/move"
)

// reorgStatus is the reorg lamp. The body does not name the other job.
type reorgStatus struct {
	ReorgSafeToReboot bool   `json:"reorgSafeToReboot"`
	RunState          string `json:"runState"`
	Phase             string `json:"phase"`
	PauseRequested    bool   `json:"pauseRequested"`
	Move              int    `json:"move"`
	AlreadyPlaced     int    `json:"alreadyPlaced"`
	Park              int    `json:"park"`
	Leave             int    `json:"leave"`
	Counting          bool   `json:"counting,omitempty"`
	Seen              int    `json:"seen,omitempty"`
	CacheBytes        int64  `json:"cacheBytes"`
	RSSBytes          int64  `json:"rssBytes"`
	LastRecovery      string `json:"lastRecovery"`
}

func (s *Server) reorgPlan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	rawPrefix, ok := readPlanPrefix(w, r)
	if !ok {
		return
	}
	prefix, err := dating.CleanPrefix(rawPrefix)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	run, err := s.reorgRunState()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if reorgBusy(run) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	if _, err := s.Catalog.Write.Exec(`UPDATE job_state SET run_state = 'planning' WHERE job_kind = 'reorg'`); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.publishPlan(prefix, dating.Counts{})
	defer s.clearPlan()
	counts, err := dating.PlanPrefixRootProgress(s.Catalog, prefix, s.Root, func(c dating.Counts) {
		s.publishPlan(prefix, c)
	})
	if err != nil {
		_, _ = s.Catalog.Write.Exec(`UPDATE job_state SET run_state = 'idle' WHERE job_kind = 'reorg' AND run_state = 'planning'`)
		if errors.Is(err, dating.ErrPrefix) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if _, err := s.Catalog.Write.Exec(`
		UPDATE job_state
		SET run_state = 'plan_ready', phase = ?, pause_requested = 0
		WHERE job_kind = 'reorg'`, prefix); err != nil {
		_, _ = s.Catalog.Write.Exec(`UPDATE job_state SET run_state = 'idle' WHERE job_kind = 'reorg' AND run_state = 'planning'`)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"move":          counts.Move,
		"alreadyPlaced": counts.AlreadyPlaced,
		"park":          counts.Park,
		"leave":         counts.Leave,
		"prefix":        prefix,
	})
}

func (s *Server) reorgStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil || s.reorgRunner() == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	quiet, err := move.TrimQuiescent(s.Catalog)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if !quiet {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "trim"})
		return
	}
	run, err := s.reorgRunState()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if reorgBusy(run) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	err = s.reorgRunner().Start()
	if errors.Is(err, dating.ErrPrefix) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "plan"})
		return
	}
	if errors.Is(err, move.ErrBusy) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.writeReorgStatus(w)
}

func (s *Server) reorgPause(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil || s.reorgRunner() == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	if err := s.reorgRunner().Pause(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.writeReorgStatus(w)
}

func (s *Server) reorgResume(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil || s.reorgRunner() == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	if err := s.reorgRunner().Resume(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.writeReorgStatus(w)
}

func (s *Server) reorgStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	s.writeReorgStatus(w)
}

func (s *Server) writeReorgStatus(w http.ResponseWriter) {
	body, err := s.currentReorgStatus()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) currentReorgStatus() (reorgStatus, error) {
	var body reorgStatus
	if s.Catalog.Watch == nil {
		return body, errors.New("watch")
	}
	var pause int
	// Watch is not the connection PlanPrefix holds, so this sees run_state planning during the count.
	if err := s.Catalog.Watch.QueryRow(`
		SELECT run_state, phase, pause_requested FROM job_state WHERE job_kind = 'reorg'`).Scan(&body.RunState, &body.Phase, &pause); err != nil {
		return body, err
	}
	body.PauseRequested = pause != 0
	safe, err := move.ReorgSafeConn(s.Catalog.Watch)
	if err != nil {
		return body, err
	}
	body.ReorgSafeToReboot = safe
	body.Move, body.AlreadyPlaced, body.Park, body.Leave = s.reorgCounts(body.Phase)
	if err := s.Catalog.Watch.QueryRow(`SELECT COALESCE(SUM(bytes), 0) FROM cache_objects`).Scan(&body.CacheBytes); err != nil {
		return body, err
	}
	body.RSSBytes = s.rss.Load()
	s.planMu.Lock()
	if body.RunState == "planning" && s.planLive {
		body.Counting = true
		body.Phase = s.planPrefix
		body.Move = s.planMove
		body.AlreadyPlaced = s.planAlready
		body.Park = s.planPark
		body.Leave = s.planLeave
		body.Seen = s.planSeen
	}
	s.planMu.Unlock()
	body.LastRecovery = "none"
	if runner := s.reorgRunner(); runner != nil {
		if name := runner.Recovery(); name != "" {
			body.LastRecovery = name
		}
	}
	return body, nil
}

func (s *Server) publishPlan(prefix string, counts dating.Counts) {
	s.planMu.Lock()
	s.planLive = true
	s.planPrefix = prefix
	s.planMove = counts.Move
	s.planAlready = counts.AlreadyPlaced
	s.planPark = counts.Park
	s.planLeave = counts.Leave
	s.planSeen = counts.Seen
	s.planMu.Unlock()
}

func (s *Server) clearPlan() {
	s.planMu.Lock()
	s.planLive = false
	s.planMu.Unlock()
}

func (s *Server) reorgCounts(phase string) (moveCount, already, park, leave int) {
	prefix, err := dating.CleanPrefix(phase)
	if err != nil {
		return 0, 0, 0, 0
	}
	pattern := reorgLikeUnder(prefix)
	_ = s.Catalog.Watch.QueryRow(`
		SELECT
			COALESCE(SUM(CASE WHEN state = 'planned' AND src_rel != dest_rel AND instr(dest_rel, '/_Review/') = 0 THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN state = 'planned' AND src_rel = dest_rel THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN state = 'planned' AND src_rel != dest_rel AND instr(dest_rel, '/_Review/') > 0 THEN 1 ELSE 0 END), 0)
		FROM journal
		WHERE job_kind = 'reorg' AND (src_rel = ? OR src_rel LIKE ? ESCAPE '\')`,
		prefix, pattern).Scan(&moveCount, &already, &park)
	_ = s.Catalog.Watch.QueryRow(`
		SELECT COUNT(*) FROM assets
		WHERE reorg_policy = 'leave' AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\')`,
		prefix, pattern).Scan(&leave)
	return moveCount, already, park, leave
}

func (s *Server) reorgRunState() (string, error) {
	var run string
	err := s.Catalog.Watch.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = 'reorg'`).Scan(&run)
	return run, err
}

func reorgBusy(run string) bool {
	switch run {
	case "planning", "running", "pause_requested", "recovering":
		return true
	default:
		return false
	}
}

func readPlanPrefix(w http.ResponseWriter, r *http.Request) (string, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return "", false
	}
	if len(strings.TrimSpace(string(raw))) == 0 {
		return "Photos", true
	}
	var body struct {
		Prefix string `json:"prefix"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return "", false
	}
	return body.Prefix, true
}

func reorgLikeUnder(prefix string) string {
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(prefix)
	return escaped + "/%"
}
