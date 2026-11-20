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

// A folder rename updates catalog paths. It does not move the directory.
// The Mac has already renamed the folder on disk. Asset ids stay.
var (
	ErrRenamePrefix  = errors.New("prefix")
	ErrRenameKept    = errors.New("kept")
	ErrRenameMissing = errors.New("missing")
	ErrRenameTaken   = errors.New("taken")
	ErrRenameBusy    = errors.New("busy")
)

// RenameFolder records that from is now to. Photos, and the three shelves, stay.
// The new directory must already be on disk. An open journal under the old name refuses the change.
func RenameFolder(root string, catalog *db.Catalog, from, to string) (int, error) {
	from, fromOK := folderPrefix(from)
	to, toOK := folderPrefix(to)
	if !fromOK || !toOK || from == to {
		return 0, ErrRenamePrefix
	}
	if keptFolder(from) || keptFolder(to) || reservedFolderName(path.Base(to)) {
		return 0, ErrRenameKept
	}
	if strings.HasPrefix(to, from+"/") || strings.HasPrefix(from, to+"/") {
		return 0, ErrRenamePrefix
	}
	newFull, err := folderOnDisk(root, to)
	if err != nil {
		return 0, err
	}
	if oldInfo, oldErr := os.Lstat(filepath.Join(root, filepath.FromSlash(from))); oldErr == nil {
		if !os.SameFile(newFull, oldInfo) {
			return 0, ErrRenameTaken
		}
	} else if !os.IsNotExist(oldErr) {
		return 0, oldErr
	}
	tx, err := beginWrite(catalog.Write)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	var occupied int
	if err := tx.QueryRow(`
		SELECT COUNT(*) FROM assets
		WHERE rel_path = ? OR substr(rel_path, 1, length(?)+1) = ? || '/'`,
		to, to, to).Scan(&occupied); err != nil {
		return 0, err
	}
	// A retry after a committed rename finds the rows already under the new name.
	// That is success. Rows still under both names are a real collision.
	var already int
	if occupied > 0 {
		var remaining int
		if err := tx.QueryRow(`
			SELECT COUNT(*) FROM assets
			WHERE rel_path = ? OR substr(rel_path, 1, length(?)+1) = ? || '/'`,
			from, from, from).Scan(&remaining); err != nil {
			return 0, err
		}
		if remaining > 0 {
			return 0, ErrRenameTaken
		}
		already = occupied
	}
	var renamed sql.Result
	if already == 0 {
		var open int
		if err := tx.QueryRow(`
			SELECT COUNT(*) FROM journal j
			JOIN assets a ON a.id = j.asset_id
			WHERE j.state NOT IN ('done', 'failed')
			AND (a.rel_path = ? OR substr(a.rel_path, 1, length(?)+1) = ? || '/')`,
			from, from, from).Scan(&open); err != nil {
			return 0, err
		}
		if open > 0 {
			return 0, ErrRenameBusy
		}
		now := time.Now().UTC().Format(time.RFC3339)
		renamed, err = tx.Exec(`
			UPDATE assets
			SET rel_path = ? || substr(rel_path, length(?)+1), updated_at = ?
			WHERE rel_path = ? OR substr(rel_path, 1, length(?)+1) = ? || '/'`,
			to, from, now, from, from, from)
		if err != nil {
			if uniqueConstraint(err) {
				return 0, ErrRenameTaken
			}
			return 0, err
		}
	}
	if _, err := tx.Exec(`
		UPDATE events
		SET folder_rel = ? || substr(folder_rel, length(?)+1)
		WHERE folder_rel = ? OR substr(folder_rel, 1, length(?)+1) = ? || '/'`,
		to, from, from, from, from); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		if uniqueConstraint(err) {
			return 0, ErrRenameTaken
		}
		return 0, err
	}
	if already > 0 {
		return already, nil
	}
	count, err := renamed.RowsAffected()
	if err != nil {
		return 0, err
	}
	return int(count), nil
}

func keptFolder(prefix string) bool {
	switch prefix {
	case "Photos", "Photos/_Removed", "Photos/_Duplicates", "Photos/_Review":
		return true
	default:
		return false
	}
}

func reservedFolderName(name string) bool {
	switch name {
	case "_Removed", "_Duplicates", "_Review":
		return true
	default:
		return false
	}
}

func folderOnDisk(root, prefix string) (os.FileInfo, error) {
	full := filepath.Join(root, filepath.FromSlash(prefix))
	rel, err := filepath.Rel(root, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return nil, ErrRenamePrefix
	}
	info, err := os.Lstat(full)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrRenameMissing
		}
		return nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return nil, ErrRenameMissing
	}
	return info, nil
}

func uniqueConstraint(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "unique")
}
