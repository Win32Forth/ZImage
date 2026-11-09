package httpapi

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/move"
	"zimage/helper/internal/pathsafe"
)

type duplicateGroupJSON struct {
	UID     string      `json:"uid"`
	Keeper  *assetJSON  `json:"keeper"`
	Members []assetJSON `json:"members"`
}

func (s *Server) duplicates(w http.ResponseWriter, r *http.Request) {
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
	group := r.URL.Query().Get("group")
	if group != "" && !plainUID(group) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "catalog"})
		return
	}
	// found=1 lists matching groups that are still in the library. The default lists the store.
	found := r.URL.Query().Get("found") == "1"
	var rows *sql.Rows
	var err error
	if found {
		rows, err = s.Catalog.Read.Query(`
			SELECT g.id, g.uid, g.keeper_asset_id FROM derivative_groups g
			WHERE g.id > ? AND (? = '' OR g.uid = ?)
			AND (
				SELECT COUNT(*) FROM assets a
				WHERE a.derivative_group_id = g.id
				AND a.placement NOT IN ('purged', 'removed')
				AND a.media_class IN ('image', 'raw')
			) >= 2
			ORDER BY g.id LIMIT ?`, after, group, group, limit)
	} else {
		rows, err = s.Catalog.Read.Query(`
			SELECT id, uid, keeper_asset_id FROM derivative_groups
			WHERE id > ? AND (? = '' OR uid = ?)
			ORDER BY id LIMIT ?`, after, group, group, limit)
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	type groupRef struct {
		id       int64
		uid      string
		keeperID sql.NullInt64
	}
	var refs []groupRef
	var lastID int64
	for rows.Next() {
		var ref groupRef
		if err := rows.Scan(&ref.id, &ref.uid, &ref.keeperID); err != nil {
			rows.Close()
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		lastID = ref.id
		refs = append(refs, ref)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	list := make([]duplicateGroupJSON, 0)
	count := len(refs)
	for _, ref := range refs {
		item, err := s.duplicateGroup(ref.id, ref.uid, ref.keeperID, !found)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		if group == "" && len(item.Members) == 0 {
			continue
		}
		list = append(list, item)
	}
	next := ""
	if count == limit {
		next = strconv.FormatInt(lastID, 10)
	}
	writeJSON(w, http.StatusOK, map[string]any{"groups": list, "nextCursor": next})
}

func (s *Server) duplicateGroup(id int64, uid string, keeperID sql.NullInt64, storeOnly bool) (duplicateGroupJSON, error) {
	item := duplicateGroupJSON{UID: uid, Members: []assetJSON{}}
	query := assetSelect + `
		WHERE derivative_group_id = ?
		AND placement NOT IN ('purged', 'removed')`
	if storeOnly {
		query += `
		AND rel_path LIKE 'Photos/\_Duplicates/%' ESCAPE '\'`
	} else {
		query += `
		AND media_class IN ('image', 'raw')`
	}
	query += `
		ORDER BY id`
	rows, err := s.Catalog.Read.Query(query, id)
	if err != nil {
		return item, err
	}
	for rows.Next() {
		asset, _, err := scanAsset(rows)
		if err != nil {
			rows.Close()
			return item, err
		}
		if storeOnly && !dating.UnderDuplicates(asset.RelPath) {
			continue
		}
		item.Members = append(item.Members, asset)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return item, err
	}
	if keeperID.Valid {
		asset, _, err := scanAsset(s.Catalog.Read.QueryRow(assetSelect+` WHERE id = ?`, keeperID.Int64))
		if err == nil {
			item.Keeper = &asset
		} else if err != sql.ErrNoRows {
			return item, err
		}
	}
	return item, nil
}

func (s *Server) toDuplicates(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	loc, ok := s.locate(w, r.PathValue("uid"))
	if !ok {
		return
	}
	if dating.UnderDuplicates(loc.rel) || loc.placement == "purged" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	if busy, err := s.journalOpen(loc.id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	} else if busy {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	_, groupUID, err := s.ensureGroup(loc)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	dest, err := claimName(s, "Photos/_Duplicates/"+groupUID, path.Base(loc.rel))
	if err != nil || !dating.UnderDuplicates(dest) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	journalID, err := s.insertMove(loc, "manual_duplicate", dest)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.finishMove(w, "manual_duplicate", journalID, loc.uid)
}

// toRemoved journal-moves one file into Photos/_Removed. The bytes stay for a later deletion.
func (s *Server) toRemoved(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	loc, ok := s.locate(w, r.PathValue("uid"))
	if !ok {
		return
	}
	if dating.UnderRemoved(loc.rel) || dating.UnderDuplicates(loc.rel) || loc.placement == "purged" || loc.placement == "removed" || loc.placement == "duplicates" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	if busy, err := s.journalOpen(loc.id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	} else if busy {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	dest, err := claimName(s, "Photos/_Removed", path.Base(loc.rel))
	if err != nil || !dating.UnderRemoved(dest) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	journalID, err := s.insertMove(loc, "manual_remove", dest)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.finishMove(w, "manual_remove", journalID, loc.uid)
}

// placeAsset stores the typed date and journal-moves that one file into its date folder.
func (s *Server) placeAsset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	loc, ok := s.locate(w, r.PathValue("uid"))
	if !ok {
		return
	}
	if dating.UnderRemoved(loc.rel) || dating.UnderDuplicates(loc.rel) || loc.placement == "purged" || loc.placement == "removed" || loc.placement == "duplicates" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	var body struct {
		CaptureTime string `json:"captureTime"`
	}
	if err := readSmallJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body"})
		return
	}
	decision, ok := dating.User(body.CaptureTime)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "date"})
		return
	}
	var inflight int
	if err := s.Catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE asset_id = ? AND state NOT IN ('planned', 'done', 'failed')`, loc.id).Scan(&inflight); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if inflight > 0 {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	var run string
	err := s.Catalog.Read.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = 'reorg'`).Scan(&run)
	if err != nil && err != sql.ErrNoRows {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	if run == "running" || run == "pause_requested" || run == "recovering" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	planned, ok := dating.PlannedPath(loc.rel, "move", "", dating.ReviewBucket(loc.blake, loc.rel), decision)
	if !ok || !dating.PlaceDest(planned) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	dest, err := claimNameExcept(s, path.Dir(planned), path.Base(planned), loc.id)
	if err != nil || !dating.PlaceDest(dest) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	journalID, err := dating.PlaceUserDate(s.Catalog, loc.id, loc.rel, dest, loc.bytes, decision)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.finishMove(w, "manual_place", journalID, loc.uid)
}

func (s *Server) restoreAsset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	loc, ok := s.locate(w, r.PathValue("uid"))
	if !ok {
		return
	}
	if !dating.UnderDuplicates(loc.rel) || loc.placement == "purged" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	if busy, err := s.journalOpen(loc.id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	} else if busy {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	dest, err := s.restoreDest(loc)
	if err != nil || dating.UnderDuplicates(dest) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	journalID, err := s.insertMove(loc, "restore", dest)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	s.finishMove(w, "restore", journalID, loc.uid)
}

func (s *Server) pinAsset(w http.ResponseWriter, r *http.Request) {
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
	var body struct {
		Pinned *bool `json:"pinned"`
	}
	if err := readSmallJSON(r, &body); err != nil || body.Pinned == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "confirm"})
		return
	}
	bit := 0
	if *body.Pinned {
		bit = 1
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	res, err := s.Catalog.Write.Exec(`UPDATE assets SET pinned = ?, updated_at = ? WHERE uid = ?`, bit, now, uid)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	item, ok := s.loadUID(w, uid)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (s *Server) purgeAsset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	loc, ok := s.locate(w, r.PathValue("uid"))
	if !ok {
		return
	}
	var body struct {
		ConfirmFilename string `json:"confirmFilename"`
	}
	if err := readSmallJSON(r, &body); err != nil || body.ConfirmFilename != path.Base(loc.rel) || !dating.UnderDuplicates(loc.rel) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "confirm"})
		return
	}
	if busy, err := s.journalOpen(loc.id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	} else if busy {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	journalID, err := s.insertPurge(loc.id, loc.rel, loc.bytes)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	purger := &move.Runner{Root: s.Root, Catalog: s.Catalog, JobKind: "purge", Note: s.Note}
	if err := purger.FinishPurge(journalID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	item, ok := s.loadUID(w, loc.uid)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (s *Server) purgeAll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	var body struct {
		Confirm string `json:"confirm"`
	}
	if err := readSmallJSON(r, &body); err != nil || body.Confirm != "DELETE" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "confirm"})
		return
	}
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	rows, err := s.Catalog.Read.Query(`
		SELECT id, rel_path, byte_size FROM assets
		WHERE placement != 'purged'
		AND rel_path LIKE 'Photos/\_Duplicates/%' ESCAPE '\'`)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	type target struct {
		id    int64
		rel   string
		bytes int64
	}
	var targets []target
	for rows.Next() {
		var item target
		if err := rows.Scan(&item.id, &item.rel, &item.bytes); err != nil {
			rows.Close()
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		if dating.UnderDuplicates(item.rel) {
			targets = append(targets, item)
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	rows.Close()
	if _, err := s.Catalog.Write.Exec(`PRAGMA synchronous = FULL`); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	tx, err := s.Catalog.Write.Begin()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	var ids []int64
	for _, item := range targets {
		var open int
		if err := tx.QueryRow(`
			SELECT COUNT(*) FROM journal
			WHERE asset_id = ? AND state NOT IN ('done', 'failed')`, item.id).Scan(&open); err != nil {
			_ = tx.Rollback()
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		if open > 0 {
			continue
		}
		res, err := tx.Exec(`
			INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
			VALUES (?, 'purge', 'purge_planned', ?, '', ?, ?)`, item.id, item.rel, item.bytes, now)
		if err != nil {
			_ = tx.Rollback()
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		id, err := res.LastInsertId()
		if err != nil {
			_ = tx.Rollback()
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		ids = append(ids, id)
	}
	if err := tx.Commit(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	purger := &move.Runner{Root: s.Root, Catalog: s.Catalog, JobKind: "purge", Note: s.Note}
	purged := 0
	for _, id := range ids {
		if err := purger.FinishPurge(id); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
			return
		}
		var state string
		if err := s.Catalog.Read.QueryRow(`SELECT state FROM journal WHERE id = ?`, id).Scan(&state); err == nil && state == "done" {
			purged++
		}
	}
	writeJSON(w, http.StatusOK, map[string]int{"purged": purged})
}

type locatedAsset struct {
	id        int64
	uid       string
	rel       string
	bytes     int64
	groupID   sql.NullInt64
	groupUID  sql.NullString
	blake     []byte
	placement string
}

func (s *Server) locate(w http.ResponseWriter, uid string) (locatedAsset, bool) {
	var loc locatedAsset
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return loc, false
	}
	if !plainUID(uid) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return loc, false
	}
	err := s.Catalog.Read.QueryRow(`
		SELECT a.id, a.uid, a.rel_path, a.byte_size, a.derivative_group_id, g.uid, a.blake3, a.placement
		FROM assets a
		LEFT JOIN derivative_groups g ON g.id = a.derivative_group_id
		WHERE a.uid = ?`, uid).Scan(&loc.id, &loc.uid, &loc.rel, &loc.bytes, &loc.groupID, &loc.groupUID, &loc.blake, &loc.placement)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return loc, false
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return loc, false
	}
	return loc, true
}

func (s *Server) journalOpen(assetID int64) (bool, error) {
	var n int
	err := s.Catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE asset_id = ? AND state NOT IN ('done', 'failed')`, assetID).Scan(&n)
	return n > 0, err
}

func (s *Server) ensureGroup(loc locatedAsset) (int64, string, error) {
	if loc.groupID.Valid && loc.groupUID.Valid {
		return loc.groupID.Int64, loc.groupUID.String, nil
	}
	uid, err := newGroupUID()
	if err != nil {
		return 0, "", err
	}
	if _, err := s.Catalog.Write.Exec(`PRAGMA synchronous = FULL`); err != nil {
		return 0, "", err
	}
	tx, err := s.Catalog.Write.Begin()
	if err != nil {
		return 0, "", err
	}
	res, err := tx.Exec(`INSERT INTO derivative_groups (uid, eligible) VALUES (?, 0)`, uid)
	if err != nil {
		_ = tx.Rollback()
		return 0, "", err
	}
	id, err := res.LastInsertId()
	if err != nil {
		_ = tx.Rollback()
		return 0, "", err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.Exec(`UPDATE assets SET derivative_group_id = ?, updated_at = ? WHERE id = ?`, id, now, loc.id); err != nil {
		_ = tx.Rollback()
		return 0, "", err
	}
	if err := tx.Commit(); err != nil {
		return 0, "", err
	}
	return id, uid, nil
}

func (s *Server) restoreDest(loc locatedAsset) (string, error) {
	base := path.Base(loc.rel)
	var keeperRel string
	err := s.Catalog.Read.QueryRow(`
		SELECT k.rel_path
		FROM assets me
		JOIN derivative_groups g ON g.id = me.derivative_group_id
		JOIN assets k ON k.id = g.keeper_asset_id AND k.id != me.id
		WHERE me.id = ?`, loc.id).Scan(&keeperRel)
	if err == nil && keeperRel != "" && !dating.UnderDuplicates(keeperRel) {
		return claimName(s, path.Dir(keeperRel), base)
	}
	if err != nil && err != sql.ErrNoRows {
		return "", err
	}
	var src string
	err = s.Catalog.Read.QueryRow(`
		SELECT src_rel FROM journal
		WHERE asset_id = ? AND state = 'done' AND src_rel != ''
		ORDER BY id DESC LIMIT 1`, loc.id).Scan(&src)
	if err == nil {
		dir := path.Dir(path.Clean(src))
		if dir != "." && !dating.UnderDuplicates(dir) && dirExists(s.Root, dir) {
			return claimName(s, dir, base)
		}
	} else if err != sql.ErrNoRows {
		return "", err
	}
	bucket := dating.ReviewBucket(loc.blake, loc.rel)
	return claimName(s, "Photos/_Review/Undated/"+bucket, base)
}

func (s *Server) insertMove(loc locatedAsset, kind, dest string) (int64, error) {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	res, err := s.Catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (?, ?, 'planned', ?, ?, ?, ?)`, loc.id, kind, loc.rel, dest, loc.bytes, now)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Server) insertPurge(assetID int64, rel string, size int64) (int64, error) {
	if _, err := s.Catalog.Write.Exec(`PRAGMA synchronous = FULL`); err != nil {
		return 0, err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	res, err := s.Catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (?, 'purge', 'purge_planned', ?, '', ?, ?)`, assetID, rel, size, now)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Server) finishMove(w http.ResponseWriter, kind string, journalID int64, uid string) {
	runner := &move.Runner{Root: s.Root, Catalog: s.Catalog, JobKind: kind, Note: s.Note}
	if err := runner.Execute(journalID); err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
		return
	}
	var state string
	if err := s.Catalog.Read.QueryRow(`SELECT state FROM journal WHERE id = ?`, journalID).Scan(&state); err != nil || state != "done" {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	item, ok := s.loadUID(w, uid)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func claimNameExcept(s *Server, dir, name string, assetID int64) (string, error) {
	dir = path.Clean(dir)
	if dir == "." || name == "" || name == "." || name == ".." || strings.Contains(name, "/") {
		return "", sql.ErrNoRows
	}
	for n := 1; n < 1000; n++ {
		file := name
		if n > 1 {
			file = dating.CollisionName(name, n)
		}
		rel := dir + "/" + file
		if !dating.PlaceDest(rel) {
			return "", sql.ErrNoRows
		}
		var count int
		if err := s.Catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE rel_path = ? AND id != ?`, rel, assetID).Scan(&count); err != nil {
			return "", err
		}
		if count == 0 {
			return rel, nil
		}
	}
	return "", sql.ErrNoRows
}

func claimName(s *Server, dir, name string) (string, error) {
	dir = path.Clean(dir)
	for n := 1; n < 1000; n++ {
		file := name
		if n > 1 {
			file = dating.CollisionName(name, n)
		}
		rel := dir + "/" + file
		if dating.UnderDuplicates(rel) && !strings.HasPrefix(dir, "Photos/_Duplicates/") && dir != "Photos/_Duplicates" {
			return "", sql.ErrNoRows
		}
		var count int
		if err := s.Catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE rel_path = ?`, rel).Scan(&count); err != nil {
			return "", err
		}
		if count == 0 {
			return rel, nil
		}
	}
	return "", sql.ErrNoRows
}

func dirExists(root, rel string) bool {
	if err := pathsafe.MoveDestination(root, rel); err != nil {
		return false
	}
	info, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel)))
	return err == nil && info.IsDir()
}

func readSmallJSON(r *http.Request, dst any) error {
	raw, err := io.ReadAll(io.LimitReader(r.Body, 4096))
	if err != nil {
		return err
	}
	if len(strings.TrimSpace(string(raw))) == 0 {
		return io.ErrUnexpectedEOF
	}
	return json.Unmarshal(raw, dst)
}

func newGroupUID() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}
