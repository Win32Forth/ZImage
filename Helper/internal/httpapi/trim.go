package httpapi

import (
	"errors"
	"net/http"

	"zimage/helper/internal/move"
	"zimage/helper/internal/trim"
)

// trimStatus is the trim lamp. Cache bytes stay on the reorg panel.
type trimStatus struct {
	SafeToReboot   bool   `json:"safeToReboot"`
	RunState       string `json:"runState"`
	PauseRequested bool   `json:"pauseRequested"`
	Eligible       int    `json:"eligible"`
	Moved          int    `json:"moved"`
	Waiting        int    `json:"waiting"`
}

func (s *Server) trimStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil || s.trimRunner() == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
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
	if err := trim.Plan(s.Catalog); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if err := s.trimRunner().Start(); err != nil {
		if errors.Is(err, move.ErrBusy) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.writeTrimStatus(w)
}

func (s *Server) trimPause(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil || s.trimRunner() == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	if err := s.trimRunner().Pause(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.writeTrimStatus(w)
}

func (s *Server) trimContinue(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil || s.trimRunner() == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	if err := s.trimRunner().Resume(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.writeTrimStatus(w)
}

func (s *Server) trimStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	s.writeTrimStatus(w)
}

func (s *Server) writeTrimStatus(w http.ResponseWriter) {
	body, err := s.currentTrimStatus()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) currentTrimStatus() (trimStatus, error) {
	var body trimStatus
	var pause, stored int
	if err := s.Catalog.Read.QueryRow(`
		SELECT run_state, pause_requested, safe_to_reboot FROM job_state WHERE job_kind = 'trim'`).Scan(&body.RunState, &pause, &stored); err != nil {
		return body, err
	}
	body.PauseRequested = pause != 0
	live, err := move.TrimLive(s.Catalog)
	if err != nil {
		return body, err
	}
	body.SafeToReboot = stored != 0 && live
	body.Eligible, body.Moved, body.Waiting, err = s.trimCounts()
	return body, err
}

func (s *Server) trimCounts() (eligible, moved, waiting int, err error) {
	err = s.Catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM (
			SELECT derivative_group_id FROM assets
			WHERE derivative_group_id IS NOT NULL
			GROUP BY derivative_group_id
			HAVING COUNT(*) >= 2
			AND SUM(CASE WHEN detail_score IS NULL THEN 1 ELSE 0 END) = 0
		)`).Scan(&eligible)
	if err != nil {
		return 0, 0, 0, err
	}
	err = s.Catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM (
			SELECT derivative_group_id FROM assets
			WHERE derivative_group_id IS NOT NULL
			GROUP BY derivative_group_id
			HAVING COUNT(*) >= 2
			AND SUM(CASE WHEN detail_score IS NULL THEN 1 ELSE 0 END) > 0
		)`).Scan(&waiting)
	if err != nil {
		return 0, 0, 0, err
	}
	err = s.Catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal WHERE job_kind = 'trim' AND state = 'done'`).Scan(&moved)
	return eligible, moved, waiting, err
}
