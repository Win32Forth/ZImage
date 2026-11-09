package httpapi

import (
	"net/http"
	"time"

	"zimage/helper/internal/dhashindex"
	"zimage/helper/internal/organize"
)

// scanStatus is the on-demand duplicate comparison plus the startup-pass buffer.
// passPhase, passDone, and passTotal are the latest task. They are not the trim lamp.
type scanStatus struct {
	RunState  string `json:"runState"`
	Phase     string `json:"phase"`
	Done      int    `json:"done"`
	Total     int    `json:"total"`
	Groups    int    `json:"groups"`
	PassPhase string `json:"passPhase"`
	PassDone  int    `json:"passDone"`
	PassTotal int    `json:"passTotal"`
}

func (s *Server) duplicateScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, s.scanSnapshot())
		return
	}
	s.scanMu.Lock()
	if s.scanRun == "running" {
		snap := s.scanSnapshotLocked()
		s.scanMu.Unlock()
		writeJSON(w, http.StatusOK, snap)
		return
	}
	s.scanMu.Unlock()
	quiet, err := s.jobsQuiet()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if !quiet || !organize.Hold() {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	s.scanMu.Lock()
	if s.scanRun == "running" {
		organize.Release()
		snap := s.scanSnapshotLocked()
		s.scanMu.Unlock()
		writeJSON(w, http.StatusOK, snap)
		return
	}
	s.scanRun = "running"
	s.scanPhase = "hashing"
	s.scanDone = 0
	s.scanTotal = 0
	s.scanGroups = 0
	snap := s.scanSnapshotLocked()
	s.scanMu.Unlock()
	go s.runDuplicateScan()
	writeJSON(w, http.StatusOK, snap)
}

func (s *Server) runDuplicateScan() {
	defer organize.Release()
	pause := func() {
		for s.Shedding() {
			time.Sleep(200 * time.Millisecond)
		}
	}
	report := func(phase string, done, total int) {
		s.scanMu.Lock()
		s.scanPhase = phase
		s.scanDone = done
		s.scanTotal = total
		s.scanMu.Unlock()
		if done%50 == 0 {
			pause()
		}
	}
	if err := dhashindex.IndexThumbsProgress(s.Root, s.Catalog, pause, func(done, total int) {
		report("hashing", done, total)
	}); err != nil {
		s.failScan()
		return
	}
	if err := dhashindex.GroupProgress(s.Catalog, s.Note, func(phase string, done, total int) {
		report(phase, done, total)
	}); err != nil {
		s.failScan()
		return
	}
	n := s.countFoundGroups()
	s.scanMu.Lock()
	s.scanRun = "completed"
	s.scanPhase = ""
	s.scanGroups = n
	s.scanMu.Unlock()
	s.Note("duplicate_scan_done")
}

func (s *Server) failScan() {
	s.scanMu.Lock()
	s.scanRun = "failed"
	s.scanMu.Unlock()
	s.Note("duplicate_scan_failed")
}

func (s *Server) scanSnapshot() scanStatus {
	s.scanMu.Lock()
	defer s.scanMu.Unlock()
	return s.scanSnapshotLocked()
}

func (s *Server) scanSnapshotLocked() scanStatus {
	run := s.scanRun
	if run == "" {
		run = "idle"
	}
	return scanStatus{
		RunState:  run,
		Phase:     s.scanPhase,
		Done:      s.scanDone,
		Total:     s.scanTotal,
		Groups:    s.scanGroups,
		PassPhase: s.passPhase,
		PassDone:  s.passDone,
		PassTotal: s.passTotal,
	}
}

func (s *Server) jobsQuiet() (bool, error) {
	reorgRun, err := s.reorgRunState()
	if err != nil {
		return false, err
	}
	var trimRun string
	if err := s.Catalog.Watch.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = 'trim'`).Scan(&trimRun); err != nil {
		return false, err
	}
	return jobQuiet(reorgRun) && jobQuiet(trimRun), nil
}

func jobQuiet(run string) bool {
	switch run {
	case "", "idle", "completed":
		return true
	default:
		return false
	}
}

func (s *Server) countFoundGroups() int {
	var n int
	err := s.Catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM (
			SELECT derivative_group_id FROM assets
			WHERE derivative_group_id IS NOT NULL
			AND placement NOT IN ('purged', 'removed')
			AND media_class IN ('image', 'raw')
			GROUP BY derivative_group_id
			HAVING COUNT(*) >= 2
		)`).Scan(&n)
	if err != nil {
		return 0
	}
	return n
}
