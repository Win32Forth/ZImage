package httpapi

import (
	"database/sql"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/db"
)

type cleanBody struct {
	Prefix string `json:"prefix"`
}

type cleanResult struct {
	Removed int `json:"removed"`
	Kept    int `json:"kept"`
}

// cleanFolder tombstones leftover catalog rows under one folder.
// A row goes only when its file is gone and another file in that folder has the same name and size.
// The call does not delete a file.
func (s *Server) cleanFolder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	var body cleanBody
	if err := readSmallJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	prefix, err := dating.CleanPrefix(body.Prefix)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	busy, err := s.copyingBusy()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if busy {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	result, err := dropLeftoverRows(s.Root, s.Catalog, prefix)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) copyingBusy() (bool, error) {
	for _, kind := range []string{"reorg", "trim"} {
		var run string
		err := s.Catalog.Read.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = ?`, kind).Scan(&run)
		if err == sql.ErrNoRows {
			continue
		}
		if err != nil {
			return false, err
		}
		switch run {
		case "running", "pause_requested", "recovering", "paused":
			return true, nil
		}
	}
	return false, nil
}

type cleanCandidate struct {
	id   int64
	uid  string
	rel  string
	size int64
	edit string
}

type fileState int

const (
	fileAbsent fileState = iota
	filePresent
	fileUnknown
)

// dropLeftoverRows tombstones active rows under prefix whose files are gone
// when a present file in that folder has the same name and the same size.
// Kept counts missing rows that stay. Present files are not counted and are not deleted.
func dropLeftoverRows(root string, catalog *db.Catalog, prefix string) (cleanResult, error) {
	rows, err := catalog.Read.Query(`
		SELECT id, uid, rel_path, byte_size, COALESCE(edit_rel, '')
		FROM assets
		WHERE placement = 'active'
		AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\')`,
		prefix, reorgLikeUnder(prefix))
	if err != nil {
		return cleanResult{}, err
	}
	var listed []cleanCandidate
	for rows.Next() {
		var row cleanCandidate
		if err := rows.Scan(&row.id, &row.uid, &row.rel, &row.size, &row.edit); err != nil {
			rows.Close()
			return cleanResult{}, err
		}
		listed = append(listed, row)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return cleanResult{}, err
	}
	rows.Close()

	open, err := openJournalIDs(catalog)
	if err != nil {
		return cleanResult{}, err
	}
	present := map[string]map[int64]struct{}{}
	var absent []cleanCandidate
	var unknown int
	for _, row := range listed {
		size, state := classifyFile(root, row.rel)
		switch state {
		case filePresent:
			name := path.Base(row.rel)
			sizes := present[name]
			if sizes == nil {
				sizes = map[int64]struct{}{}
				present[name] = sizes
			}
			sizes[size] = struct{}{}
		case fileUnknown:
			unknown++
		default:
			absent = append(absent, row)
		}
	}

	var doomed []cleanCandidate
	kept := unknown
	for _, row := range absent {
		if !canDrop(root, row, open, present) {
			kept++
			continue
		}
		doomed = append(doomed, row)
	}
	removed, skipped, err := tombstoneRows(catalog, doomed)
	if err != nil {
		return cleanResult{}, err
	}
	return cleanResult{Removed: removed, Kept: kept + skipped}, nil
}

func canDrop(root string, row cleanCandidate, open map[int64]struct{}, present map[string]map[int64]struct{}) bool {
	if strings.TrimSpace(row.edit) != "" || editFileExists(root, row.uid) {
		return false
	}
	if _, busy := open[row.id]; busy {
		return false
	}
	if !plainUID(row.uid) {
		return false
	}
	sizes := present[path.Base(row.rel)]
	if sizes == nil {
		return false
	}
	_, ok := sizes[row.size]
	return ok
}

func editFileExists(root, uid string) bool {
	if !plainUID(uid) {
		return false
	}
	info, err := os.Stat(filepath.Join(root, ".zimage", "edits", uid+".zimg"))
	return err == nil && info.Mode().IsRegular()
}

func classifyFile(root, rel string) (int64, fileState) {
	info, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		if os.IsNotExist(err) {
			return 0, fileAbsent
		}
		return 0, fileUnknown
	}
	if !info.Mode().IsRegular() {
		return 0, fileAbsent
	}
	return info.Size(), filePresent
}

func openJournalIDs(catalog *db.Catalog) (map[int64]struct{}, error) {
	rows, err := catalog.Read.Query(`
		SELECT asset_id FROM journal
		WHERE state NOT IN ('done', 'failed')`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	open := map[int64]struct{}{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		open[id] = struct{}{}
	}
	return open, rows.Err()
}

func tombstoneRows(catalog *db.Catalog, rows []cleanCandidate) (int, int, error) {
	if len(rows) == 0 {
		return 0, 0, nil
	}
	tx, err := catalog.Write.Begin()
	if err != nil {
		return 0, 0, err
	}
	defer func() { _ = tx.Rollback() }()
	stamp := time.Now().UTC().Format(time.RFC3339Nano)
	removed := 0
	skipped := 0
	for _, row := range rows {
		tomb := ".zimage/purged/" + row.uid
		res, err := tx.Exec(`
			UPDATE assets
			SET placement = 'purged', rel_path = ?, missing = 1,
				event_id = NULL, derivative_group_id = NULL, is_keeper = 0,
				updated_at = ?
			WHERE id = ? AND placement = 'active' AND rel_path = ?`,
			tomb, stamp, row.id, row.rel)
		if err != nil {
			return 0, 0, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return 0, 0, err
		}
		if n == 1 {
			removed++
		} else {
			skipped++
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, err
	}
	return removed, skipped, nil
}
