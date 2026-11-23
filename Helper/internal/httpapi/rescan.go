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
}

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
	s.folderMu.Lock()
	if s.folderRun == "running" {
		s.folderMu.Unlock()
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
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
	snap := s.folderScanSnapshotLocked()
	s.folderMu.Unlock()
	go s.runPageScan(prefix, paths)
	writeJSON(w, http.StatusOK, snap)
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
	s.finishFolderScan(summary, err)
}

func (s *Server) runPageScan(prefix string, paths []string) {
	summary, err := inventory.ScanPage(s.Root, prefix, paths, s.Catalog, s.folderScanOptions())
	s.finishFolderScan(summary, err)
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
			for s.Shedding() {
				time.Sleep(200 * time.Millisecond)
			}
		},
	}
}

func (s *Server) finishFolderScan(summary inventory.FolderSummary, err error) {
	s.folderMu.Lock()
	defer s.folderMu.Unlock()
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
