package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"zimage/helper/internal/inventory"
)

// folderScanStatus is one folder rescan. It is not the startup pass.
type folderScanStatus struct {
	Prefix   string `json:"prefix"`
	RunState string `json:"runState"`
	Phase    string `json:"phase"`
	Done     int    `json:"done"`
	Total    int    `json:"total"`
	Added    int    `json:"added"`
	Removed  int    `json:"removed"`
	Error    string `json:"error,omitempty"`
	// Applied means this response is the page that just committed.
	// The background folder scan can still be running.
	Applied bool `json:"applied,omitempty"`
}

// rushPage is one page listing waiting on the folder walk.
// The walk runs it at the next file and sends the result.
type rushPage struct {
	prefix string
	paths  []string
	done   chan pageOutcome
}

type pageOutcome struct {
	summary inventory.FolderSummary
	err     error
}

const (
	rushCap  = 8
	rushWait = 90 * time.Second
)

func (s *Server) rescanFolder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, s.folderScanSnapshot())
		return
	}
	var body focusBody
	if err := readSmallJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	prefix, ok := cleanFocus(body.Prefix)
	if !ok || prefix == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	s.folderMu.Lock()
	if s.folderRun == "running" {
		if s.folderPrefix == prefix {
			snap := s.folderScanSnapshotLocked()
			s.folderMu.Unlock()
			writeJSON(w, http.StatusOK, snap)
			return
		}
		s.folderMu.Unlock()
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	s.folderRun = "running"
	s.folderPrefix = prefix
	s.folderPhase = "counting"
	s.folderDone = 0
	s.folderTotal = 0
	s.folderAdded = 0
	s.folderRemoved = 0
	s.folderErr = ""
	snap := s.folderScanSnapshotLocked()
	s.folderMu.Unlock()
	go s.runFolderScan(prefix)
	writeJSON(w, http.StatusOK, snap)
}

// pageScanBody is the page on screen. Paths past inventory.PageCap are ignored.
// This is a separate route because the installed helper ignores unknown fields on /v1/folders/rescan
// and would walk the whole prefix.
type pageScanBody struct {
	Prefix string   `json:"prefix"`
	Paths  []string `json:"paths"`
}

func (s *Server) rescanPage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	var body pageScanBody
	if err := readPageJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	prefix, ok := cleanFocus(body.Prefix)
	if !ok || prefix == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	prefix, paths, err := inventory.CleanPage(prefix, body.Paths)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "paths"})
		return
	}
	// A library scan keeps its place. This page is written at the next file, and the answer waits for that commit.
	s.folderMu.Lock()
	if s.folderRun == "running" {
		if len(s.folderQueue) >= rushCap {
			s.folderMu.Unlock()
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "busy"})
			return
		}
		job := &rushPage{prefix: prefix, paths: paths, done: make(chan pageOutcome, 1)}
		s.folderQueue = append(s.folderQueue, job)
		s.folderMu.Unlock()
		s.writeRush(w, r, job)
		return
	}
	s.folderRun = "running"
	s.folderPrefix = prefix
	s.folderPhase = "scanning"
	s.folderDone = 0
	s.folderTotal = len(paths)
	s.folderAdded = 0
	s.folderRemoved = 0
	s.folderErr = ""
	s.folderMu.Unlock()
	summary, scanErr := inventory.ScanPage(s.Root, prefix, paths, s.Catalog, inventory.FolderOptions{})
	s.finishAfterDrain(summary, scanErr)
	s.writeApplied(w, prefix, len(paths), summary, scanErr)
}

func readPageJSON(r *http.Request, dst any) error {
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return err
	}
	if len(strings.TrimSpace(string(raw))) == 0 {
		return io.ErrUnexpectedEOF
	}
	return json.Unmarshal(raw, dst)
}

func (s *Server) runFolderScan(prefix string) {
	summary, err := inventory.ScanFolder(s.Root, prefix, s.Catalog, s.folderScanOptions())
	s.finishAfterDrain(summary, err)
}

func (s *Server) folderScanOptions() inventory.FolderOptions {
	return inventory.FolderOptions{
		Progress: func(phase string, done, total, added, removed int) {
			s.folderMu.Lock()
			s.folderPhase = phase
			s.folderDone = done
			s.folderTotal = total
			s.folderAdded = added
			s.folderRemoved = removed
			s.folderMu.Unlock()
		},
		Yield: func() {
			for {
				s.drainRush()
				if !s.Shedding() {
					return
				}
				time.Sleep(200 * time.Millisecond)
			}
		},
	}
}

// drainRush writes every page that arrived since the last file. The page scan does not yield.
func (s *Server) drainRush() {
	for {
		s.folderMu.Lock()
		if len(s.folderQueue) == 0 {
			s.folderMu.Unlock()
			return
		}
		job := s.folderQueue[0]
		s.folderQueue = s.folderQueue[1:]
		s.folderMu.Unlock()
		summary, err := inventory.ScanPage(s.Root, job.prefix, job.paths, s.Catalog, inventory.FolderOptions{})
		job.done <- pageOutcome{summary: summary, err: err}
	}
}

func (s *Server) cancelRush(job *rushPage) {
	s.folderMu.Lock()
	defer s.folderMu.Unlock()
	for i, item := range s.folderQueue {
		if item == job {
			s.folderQueue = append(s.folderQueue[:i], s.folderQueue[i+1:]...)
			return
		}
	}
}

func (s *Server) writeRush(w http.ResponseWriter, r *http.Request, job *rushPage) {
	timer := time.NewTimer(rushWait)
	defer timer.Stop()
	select {
	case outcome := <-job.done:
		s.writeApplied(w, job.prefix, len(job.paths), outcome.summary, outcome.err)
	case <-timer.C:
		s.cancelRush(job)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "busy"})
	case <-r.Context().Done():
		s.cancelRush(job)
	}
}

func (s *Server) writeApplied(w http.ResponseWriter, prefix string, total int, summary inventory.FolderSummary, err error) {
	if err != nil {
		status := folderScanStatus{
			Prefix:   prefix,
			RunState: "failed",
			Done:     total,
			Total:    total,
			Error:    "catalog",
			Applied:  true,
		}
		if errors.Is(err, inventory.ErrNotFolder) {
			status.Error = "prefix"
		}
		writeJSON(w, http.StatusOK, status)
		return
	}
	writeJSON(w, http.StatusOK, folderScanStatus{
		Prefix:   prefix,
		RunState: "completed",
		Done:     total,
		Total:    total,
		Added:    summary.Added,
		Removed:  summary.Removed,
		Applied:  true,
	})
}

// finishAfterDrain commits the walk only after pages that arrived during the last file are written.
func (s *Server) finishAfterDrain(summary inventory.FolderSummary, err error) {
	for {
		s.drainRush()
		s.folderMu.Lock()
		if len(s.folderQueue) == 0 {
			s.finishFolderScanLocked(summary, err)
			s.folderMu.Unlock()
			return
		}
		s.folderMu.Unlock()
	}
}

func (s *Server) finishFolderScan(summary inventory.FolderSummary, err error) {
	s.folderMu.Lock()
	defer s.folderMu.Unlock()
	s.finishFolderScanLocked(summary, err)
}

func (s *Server) finishFolderScanLocked(summary inventory.FolderSummary, err error) {
	if err != nil {
		s.folderRun = "failed"
		if errors.Is(err, inventory.ErrNotFolder) {
			s.folderErr = "prefix"
		} else {
			s.folderErr = "catalog"
		}
		s.Note("rescan_failed")
		return
	}
	s.folderRun = "completed"
	s.folderPhase = ""
	s.folderAdded = summary.Added
	s.folderRemoved = summary.Removed
	if s.folderTotal > 0 {
		s.folderDone = s.folderTotal
	}
	s.Note("rescan_done")
}

func (s *Server) folderScanSnapshot() folderScanStatus {
	s.folderMu.Lock()
	defer s.folderMu.Unlock()
	return s.folderScanSnapshotLocked()
}

func (s *Server) folderScanSnapshotLocked() folderScanStatus {
	run := s.folderRun
	if run == "" {
		run = "idle"
	}
	return folderScanStatus{
		Prefix:   s.folderPrefix,
		RunState: run,
		Phase:    s.folderPhase,
		Done:     s.folderDone,
		Total:    s.folderTotal,
		Added:    s.folderAdded,
		Removed:  s.folderRemoved,
		Error:    s.folderErr,
	}
}
