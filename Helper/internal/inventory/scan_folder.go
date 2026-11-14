package inventory

import (
	"database/sql"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"zimage/helper/internal/db"
)

// ErrNotFolder means the prefix is not a directory under Photos.
var ErrNotFolder = errors.New("not a folder")

// FolderSummary is one folder walk. Added files were missing from the catalog.
// Removed rows pointed at files that are gone. The walk does not delete a file.
type FolderSummary struct {
	Looked  int
	Added   int
	Removed int
}

// FolderOptions reports the walk. Yield runs between write batches.
// Progress phase is counting, scanning, or removing. total is 0 while the file count is still unknown.
type FolderOptions struct {
	Progress func(phase string, done, total, added, removed int)
	Yield    func()
}

// ScanFolder catalogs prefix and its subfolders, then deletes catalog rows whose files are gone.
// An existing rel_path is left in place. A row with an open journal entry stays, because that file may be mid-move.
// A stat failure other than a missing file leaves the row in place.
func ScanFolder(root, prefix string, catalog *db.Catalog, opts FolderOptions) (FolderSummary, error) {
	var summary FolderSummary
	prefix, ok := folderPrefix(prefix)
	if !ok {
		return summary, ErrNotFolder
	}
	full := filepath.Join(root, filepath.FromSlash(prefix))
	info, err := os.Stat(full)
	if err != nil && !os.IsNotExist(err) {
		return summary, err
	}
	if err == nil && !info.IsDir() {
		return summary, ErrNotFolder
	}
	report := func(phase string, done, total int) {
		if opts.Progress != nil {
			opts.Progress(phase, done, total, summary.Added, summary.Removed)
		}
	}
	pause := func() {
		if opts.Yield != nil {
			opts.Yield()
		}
	}

	catalogRows, err := countUnder(catalog, prefix)
	if err != nil {
		return summary, err
	}
	var diskFiles int
	if err == nil && info != nil && info.IsDir() {
		err = walkFolder(root, prefix, full, func(string, string, os.FileInfo) error {
			diskFiles++
			if diskFiles%50 == 0 {
				report("counting", diskFiles, 0)
				pause()
			}
			return nil
		})
		if err != nil {
			return summary, err
		}
	}
	report("counting", diskFiles, 0)
	total := diskFiles + catalogRows

	seen := 0
	if info != nil && info.IsDir() {
		err = walkFolder(root, prefix, full, func(path, rel string, fileInfo os.FileInfo) error {
			seen++
			added, err := addIfMissing(catalog, path, rel, fileInfo)
			if err != nil {
				return err
			}
			if added {
				summary.Added++
				time.Sleep(20 * time.Millisecond)
			}
			summary.Looked = seen
			if seen%20 == 0 || seen == diskFiles {
				report("scanning", seen, total)
			}
			if seen%50 == 0 {
				pause()
			}
			return nil
		})
		if err != nil {
			return summary, err
		}
	}
	summary.Looked = seen
	report("scanning", seen, total)

	rowsTotal := catalogRows + summary.Added
	removed, err := removeAbsent(root, prefix, catalog, func(examined, gone int) {
		summary.Removed = gone
		report("removing", seen+examined, seen+rowsTotal)
	}, pause)
	if err != nil {
		return summary, err
	}
	summary.Removed = removed
	report("removing", seen+rowsTotal, seen+rowsTotal)
	return summary, nil
}

func folderPrefix(prefix string) (string, bool) {
	prefix = strings.TrimSpace(prefix)
	prefix = strings.Trim(prefix, "/")
	if prefix == "" || strings.Contains(prefix, "\\") || strings.Contains(prefix, "\x00") {
		return "", false
	}
	parts := strings.Split(prefix, "/")
	if parts[0] != "Photos" {
		return "", false
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return "", false
		}
	}
	return prefix, true
}

func walkFolder(root, prefix, full string, visit func(path, rel string, info os.FileInfo) error) error {
	return filepath.WalkDir(full, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		name := entry.Name()
		if entry.IsDir() {
			if path != full && skipDirectory(name) {
				return filepath.SkipDir
			}
			return nil
		}
		if skipFile(name) {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if rel != prefix && !strings.HasPrefix(rel, prefix+"/") {
			return nil
		}
		fileInfo, err := entry.Info()
		if err != nil {
			return nil
		}
		return visit(path, rel, fileInfo)
	})
}

func addIfMissing(catalog *db.Catalog, path, rel string, info os.FileInfo) (bool, error) {
	var exists int
	err := catalog.Read.QueryRow(`SELECT 1 FROM assets WHERE rel_path = ?`, rel).Scan(&exists)
	if err == nil {
		return false, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	tx, err := beginWrite(catalog.Write)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback() }()
	if err := insert(tx, path, rel, info); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	var stored int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE rel_path = ?`, rel).Scan(&stored); err != nil {
		return false, err
	}
	return stored == 1, nil
}

func removeAbsent(root, prefix string, catalog *db.Catalog, progress func(examined, removed int), pause func()) (int, error) {
	rows, err := catalog.Read.Query(`
		SELECT id, rel_path FROM assets
		WHERE placement != 'purged'
		AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\')`,
		prefix, likeUnder(prefix))
	if err != nil {
		return 0, err
	}
	type candidate struct {
		id  int64
		rel string
	}
	var listed []candidate
	for rows.Next() {
		var row candidate
		if err := rows.Scan(&row.id, &row.rel); err != nil {
			rows.Close()
			return 0, err
		}
		listed = append(listed, row)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()

	removed := 0
	examined := 0
	var batch []int64
	note := func() {
		if progress != nil {
			progress(examined, removed)
		}
	}
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		tx, err := beginWrite(catalog.Write)
		if err != nil {
			return err
		}
		defer func() { _ = tx.Rollback() }()
		for _, id := range batch {
			gone, err := deleteCatalogRow(tx, id)
			if err != nil {
				return err
			}
			if gone {
				removed++
			}
		}
		batch = nil
		if err := tx.Commit(); err != nil {
			return err
		}
		time.Sleep(20 * time.Millisecond)
		pause()
		note()
		return nil
	}
	for _, row := range listed {
		examined++
		absent, ok := missingFile(root, row.rel)
		if ok && absent {
			batch = append(batch, row.id)
		}
		if len(batch) >= 20 {
			if err := flush(); err != nil {
				return removed, err
			}
		} else if examined%20 == 0 {
			note()
		}
	}
	if err := flush(); err != nil {
		return removed, err
	}
	note()
	return removed, nil
}

func missingFile(root, rel string) (absent bool, ok bool) {
	info, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel)))
	if err == nil {
		return info.IsDir(), true
	}
	if os.IsNotExist(err) {
		return true, true
	}
	return false, false
}

func deleteCatalogRow(tx *sql.Tx, id int64) (bool, error) {
	var open int
	if err := tx.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE asset_id = ? AND state NOT IN ('done', 'failed')`, id).Scan(&open); err != nil {
		return false, err
	}
	if open > 0 {
		return false, nil
	}
	if _, err := tx.Exec(`DELETE FROM journal WHERE asset_id = ?`, id); err != nil {
		return false, err
	}
	if _, err := tx.Exec(`DELETE FROM cache_objects WHERE asset_id = ?`, id); err != nil {
		return false, err
	}
	if _, err := tx.Exec(`UPDATE derivative_groups SET keeper_asset_id = NULL WHERE keeper_asset_id = ?`, id); err != nil {
		return false, err
	}
	res, err := tx.Exec(`DELETE FROM assets WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n == 1, nil
}

func countUnder(catalog *db.Catalog, prefix string) (int, error) {
	var n int
	err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM assets
		WHERE placement != 'purged'
		AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\')`,
		prefix, likeUnder(prefix)).Scan(&n)
	return n, err
}

func likeUnder(prefix string) string {
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(prefix)
	return escaped + "/%"
}

func beginWrite(conn *sql.DB) (*sql.Tx, error) {
	deadline := time.Now().Add(2 * time.Minute)
	for {
		tx, err := conn.Begin()
		if err == nil {
			return tx, nil
		}
		if !writeBusy(err) || time.Now().After(deadline) {
			return nil, err
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func writeBusy(err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "busy") || strings.Contains(text, "locked")
}
