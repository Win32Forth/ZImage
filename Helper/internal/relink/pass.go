// Package relink points an existing catalog row at a file that moved outside the mover.
// It runs before inventory so a renamed file does not receive a second uid.
package relink

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"zimage/helper/internal/db"
)

// Options controls the yield while a mover is copying.
type Options struct {
	Copying func() bool
	Sleep   func(time.Duration)
}

// Pass walks Photos, marks disappeared non-purged rows missing, and relinks a unique match.
// It does not insert a row and it does not enqueue a reorg move.
func Pass(root string, catalog *db.Catalog, opts Options) error {
	if opts.Sleep == nil {
		opts.Sleep = time.Sleep
	}
	photos := filepath.Join(root, "Photos")
	info, err := os.Stat(photos)
	if err != nil || !info.IsDir() {
		return nil
	}
	if _, err := catalog.Write.Exec(`CREATE TEMP TABLE IF NOT EXISTS relink_seen (rel_path TEXT PRIMARY KEY)`); err != nil {
		return err
	}
	if _, err := catalog.Write.Exec(`DELETE FROM relink_seen`); err != nil {
		return err
	}
	seen := 0
	var batch []string
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		tx, err := catalog.Write.Begin()
		if err != nil {
			return err
		}
		for _, rel := range batch {
			if _, err := tx.Exec(`INSERT INTO relink_seen (rel_path) VALUES (?) ON CONFLICT(rel_path) DO NOTHING`, rel); err != nil {
				_ = tx.Rollback()
				return err
			}
		}
		batch = nil
		return tx.Commit()
	}
	// Record paths first and mark disappeared rows. Fast-fingerprint matches
	// require missing = 1, so the relink walk follows that update.
	err = walkPhotos(root, photos, func(rel, abs string) error {
		seen++
		batch = append(batch, rel)
		if seen%50 == 0 {
			if err := flush(); err != nil {
				return err
			}
			yield(opts)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if err := flush(); err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := catalog.Write.Exec(`
		UPDATE assets
		SET missing = CASE WHEN rel_path IN (SELECT rel_path FROM relink_seen) THEN 0 ELSE 1 END,
			updated_at = ?
		WHERE placement != 'purged'
		AND (rel_path = 'Photos' OR rel_path LIKE 'Photos/%')`, now); err != nil {
		return err
	}
	var candidates int
	if err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM assets
		WHERE placement != 'purged' AND (missing = 1 OR blake3 IS NOT NULL)`).Scan(&candidates); err != nil {
		return err
	}
	if candidates == 0 {
		return nil
	}
	seen = 0
	return walkPhotos(root, photos, func(rel, abs string) error {
		seen++
		var count int
		if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE rel_path = ?`, rel).Scan(&count); err != nil {
			return err
		}
		if count == 0 {
			if err := tryRelink(root, catalog, rel, abs); err != nil {
				return err
			}
		}
		if seen%50 == 0 {
			yield(opts)
		}
		return nil
	})
}

func yield(opts Options) {
	if opts.Copying != nil && opts.Copying() {
		opts.Sleep(200 * time.Millisecond)
	}
}

func walkPhotos(root, photos string, visit func(rel, abs string) error) error {
	return filepath.WalkDir(photos, func(abs string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		name := entry.Name()
		if entry.IsDir() {
			if abs != photos && skipDirectory(name) {
				return filepath.SkipDir
			}
			return nil
		}
		if skipFile(name) {
			return nil
		}
		rel, err := filepath.Rel(root, abs)
		if err != nil {
			return nil
		}
		return visit(filepath.ToSlash(rel), abs)
	})
}

func tryRelink(root string, catalog *db.Catalog, rel, abs string) error {
	sum, err := HashFile(abs)
	if err != nil {
		return nil
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil
	}
	fp, err := FingerprintFile(abs)
	if err != nil {
		return nil
	}
	absent, err := absentBlake(root, catalog, sum)
	if err != nil {
		return err
	}
	if len(absent) == 1 {
		return retarget(catalog, absent[0], rel, sum, fp)
	}
	if len(absent) > 1 {
		return markAmbiguous(catalog, absent)
	}
	matches, err := missingFast(catalog, info.Size(), fp)
	if err != nil {
		return err
	}
	if len(matches) == 1 {
		return retarget(catalog, matches[0], rel, sum, fp)
	}
	if len(matches) > 1 {
		return markAmbiguous(catalog, matches)
	}
	return nil
}

func absentBlake(root string, catalog *db.Catalog, sum []byte) ([]int64, error) {
	rows, err := catalog.Read.Query(`
		SELECT id, rel_path FROM assets
		WHERE placement != 'purged' AND blake3 = ?`, sum)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		var rel string
		if err := rows.Scan(&id, &rel); err != nil {
			return nil, err
		}
		if !filePresent(root, rel) {
			ids = append(ids, id)
		}
	}
	return ids, rows.Err()
}

func missingFast(catalog *db.Catalog, size int64, fp []byte) ([]int64, error) {
	rows, err := catalog.Read.Query(`
		SELECT id FROM assets
		WHERE placement != 'purged' AND missing = 1 AND byte_size = ? AND fast_fp = ?`, size, fp)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func retarget(catalog *db.Catalog, id int64, rel string, sum, fp []byte) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := catalog.Write.Exec(`
		UPDATE assets
		SET rel_path = ?, missing = 0, identity_ambiguous = 0,
			blake3 = COALESCE(blake3, ?), fast_fp = ?, updated_at = ?
		WHERE id = ? AND placement != 'purged'`,
		rel, sum, fp, now, id)
	return err
}

func markAmbiguous(catalog *db.Catalog, ids []int64) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, id := range ids {
		if _, err := catalog.Write.Exec(`
			UPDATE assets SET identity_ambiguous = 1, updated_at = ? WHERE id = ? AND placement != 'purged'`,
			now, id); err != nil {
			return err
		}
	}
	return nil
}

func filePresent(root, rel string) bool {
	abs := filepath.Join(root, filepath.FromSlash(rel))
	info, err := os.Stat(abs)
	return err == nil && !info.IsDir()
}

func skipDirectory(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch name {
	case "@eaDir", "#recycle", ".explorer-trash", ".zimage", "Thumbs", ".thumbnails", ".TemporaryItems":
		return true
	default:
		return false
	}
}

func skipFile(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	lower := strings.ToLower(name)
	return lower == "thumbs.db" || lower == "desktop.ini"
}
