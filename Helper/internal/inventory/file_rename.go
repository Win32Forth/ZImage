package inventory

import (
	"database/sql"
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"zimage/helper/internal/db"
)

// RenameFile points the catalog row at from to the file that is already at to.
// The Mac has renamed the file. The asset id stays, so edits stay with the photograph.
// A second row that a folder rescan inserted for to is removed when that row has no edits.
// The call does not delete a file and does not move one.
func RenameFile(root string, catalog *db.Catalog, from, to string) error {
	from, fromOK := photoFile(from)
	to, toOK := photoFile(to)
	if !fromOK || !toOK || !fileNameOK(path.Base(to)) {
		return ErrRenamePrefix
	}
	if parkedFile(from) || parkedFile(to) {
		return ErrRenameKept
	}
	if path.Dir(from) != path.Dir(to) {
		return ErrRenamePrefix
	}
	if from == to {
		info, err := os.Lstat(photoAbs(root, from))
		if err != nil || !info.Mode().IsRegular() {
			return ErrRenameMissing
		}
		return nil
	}

	state, info, err := classifyRenamedFile(photoAbs(root, from), photoAbs(root, to))
	if err != nil {
		return err
	}
	switch state {
	case renamedReady, renamedSameFile:
	case renamedConflict:
		return ErrRenameTaken
	default:
		return ErrRenameMissing
	}

	tx, err := beginWrite(catalog.Write)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	var keeperID int64
	var placement string
	err = tx.QueryRow(`SELECT id, placement FROM assets WHERE rel_path = ?`, from).Scan(&keeperID, &placement)
	if errors.Is(err, sql.ErrNoRows) {
		var already int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM assets WHERE rel_path = ?`, to).Scan(&already); err != nil {
			return err
		}
		if already == 1 {
			return nil
		}
		return ErrRenameMissing
	}
	if err != nil {
		return err
	}
	if placement != "active" {
		return ErrRenameKept
	}
	if busy, err := journalBusy(tx, keeperID); err != nil {
		return err
	} else if busy {
		return ErrRenameBusy
	}

	dropped, err := absorbRenamedDuplicate(root, tx, keeperID, to)
	if err != nil {
		return err
	}

	ext := strings.ToLower(strings.TrimPrefix(path.Ext(to), "."))
	class, policy := mediaClass(ext)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	res, err := tx.Exec(`
		UPDATE assets
		SET rel_path = ?, ext = ?, media_class = ?, reorg_policy = ?,
			byte_size = ?, mtime_ns = ?, missing = 0, updated_at = ?
		WHERE id = ? AND rel_path = ?`,
		to, ext, class, policy, info.Size(), info.ModTime().UnixNano(), now, keeperID, from)
	if err != nil {
		if uniqueConstraint(err) {
			return ErrRenameTaken
		}
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n != 1 {
		return ErrRenameMissing
	}
	if _, err := tx.Exec(`
		UPDATE journal
		SET src_rel = ?,
			dest_rel = CASE WHEN dest_rel = ? THEN ? ELSE dest_rel END,
			updated_at = ?
		WHERE asset_id = ? AND state = 'planned' AND (scratch_rel IS NULL OR scratch_rel = '')`,
		to, from, to, now, keeperID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		if uniqueConstraint(err) {
			return ErrRenameTaken
		}
		return err
	}
	for _, rel := range dropped {
		_ = os.Remove(filepath.Join(root, filepath.FromSlash(rel)))
	}
	return nil
}

type renamedDisk int

const (
	renamedMissing renamedDisk = iota
	renamedReady
	renamedSameFile
	renamedConflict
)

func classifyRenamedFile(oldAbs, newAbs string) (renamedDisk, os.FileInfo, error) {
	newInfo, newErr := os.Lstat(newAbs)
	if newErr != nil && !os.IsNotExist(newErr) {
		return renamedMissing, nil, newErr
	}
	oldInfo, oldErr := os.Lstat(oldAbs)
	if oldErr != nil && !os.IsNotExist(oldErr) {
		return renamedMissing, nil, oldErr
	}
	if newErr != nil || !newInfo.Mode().IsRegular() {
		return renamedMissing, nil, nil
	}
	if oldErr != nil {
		return renamedReady, newInfo, nil
	}
	if os.SameFile(oldInfo, newInfo) {
		return renamedSameFile, newInfo, nil
	}
	return renamedConflict, nil, nil
}

func absorbRenamedDuplicate(root string, tx *sql.Tx, keeperID int64, to string) ([]string, error) {
	var otherID int64
	var otherUID, editRel, thumbRel string
	err := tx.QueryRow(`
		SELECT id, uid, COALESCE(edit_rel, ''), COALESCE(thumb_rel, '')
		FROM assets WHERE rel_path = ? AND id != ?`, to, keeperID).Scan(&otherID, &otherUID, &editRel, &thumbRel)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(editRel) != "" || editSidecar(root, otherUID) {
		return nil, ErrRenameTaken
	}
	gone, err := deleteCatalogRow(tx, otherID)
	if err != nil {
		return nil, err
	}
	if !gone {
		return nil, ErrRenameBusy
	}
	if rel, ok := cachedThumb(thumbRel); ok {
		return []string{rel}, nil
	}
	return nil, nil
}

func journalBusy(tx *sql.Tx, assetID int64) (bool, error) {
	var n int
	err := tx.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE asset_id = ? AND state NOT IN ('done', 'failed')
		AND NOT (state = 'planned' AND (scratch_rel IS NULL OR scratch_rel = ''))`, assetID).Scan(&n)
	return n > 0, err
}

func editSidecar(root, uid string) bool {
	if uid == "" || strings.Contains(uid, "/") || strings.Contains(uid, ".") {
		return false
	}
	for _, ext := range []string{".zimg", ".zflat", ".zjpg"} {
		info, err := os.Lstat(filepath.Join(root, ".zimage", "edits", uid+ext))
		if err == nil && info.Mode().IsRegular() {
			return true
		}
	}
	return false
}

func cachedThumb(rel string) (string, bool) {
	rel = path.Clean(strings.TrimSpace(rel))
	if rel == "." || strings.Contains(rel, "..") || !strings.HasPrefix(rel, ".zimage/cache/thumbs/") {
		return "", false
	}
	return rel, true
}

func photoFile(rel string) (string, bool) {
	rel = strings.TrimSpace(rel)
	if rel == "" || strings.Contains(rel, "\\") || strings.Contains(rel, "\x00") {
		return "", false
	}
	parts := strings.Split(rel, "/")
	if len(parts) < 2 || parts[0] != "Photos" {
		return "", false
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return "", false
		}
	}
	return strings.Join(parts, "/"), true
}

func fileNameOK(name string) bool {
	if name == "" || name == "." || name == ".." || len(name) > 255 {
		return false
	}
	return !strings.ContainsAny(name, "/\\\x00\n\r:")
}

func parkedFile(rel string) bool {
	for _, shelf := range []string{"Photos/_Removed", "Photos/_Duplicates", "Photos/_Review"} {
		if rel == shelf || strings.HasPrefix(rel, shelf+"/") {
			return true
		}
	}
	return false
}

func photoAbs(root, rel string) string {
	return filepath.Join(root, filepath.FromSlash(rel))
}
