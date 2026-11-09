package cacheledger

import (
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"zimage/helper/internal/db"
)

// Reconcile lists .zimage/cache only. It inserts orphan thumbnails and embeddings
// when they fit, and deletes unreferenced cache/scratch. It does not delete
// catalog/ or move-backup/.
func Reconcile(root string, catalog *db.Catalog, limits Limits) error {
	return ReconcileProgress(root, catalog, limits, nil)
}

// ReconcileProgress is Reconcile. progress reports files looked at and does no extra catalog work.
func ReconcileProgress(root string, catalog *db.Catalog, limits Limits, progress func(done int)) error {
	seen := 0
	tick := func() {
		seen++
		if progress != nil {
			progress(seen)
		}
	}
	if err := dropMissingLedger(root, catalog, tick); err != nil {
		return err
	}
	cacheRoot := filepath.Join(root, ".zimage", "cache")
	info, err := os.Stat(cacheRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if !info.IsDir() {
		return nil
	}
	return filepath.WalkDir(cacheRoot, func(abs string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil || entry.IsDir() {
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		rel, err := filepath.Rel(root, abs)
		if err != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if !underCache(rel) {
			return nil
		}
		tick()
		switch {
		case strings.HasPrefix(rel, ".zimage/cache/scratch/"):
			return dropScratch(root, catalog, rel, abs)
		case strings.HasPrefix(rel, ".zimage/cache/thumbs/") || strings.HasPrefix(rel, ".zimage/cache/embeddings/"):
			return adoptOrphan(root, catalog, rel, abs, limits)
		default:
			return nil
		}
	})
}

func dropMissingLedger(root string, catalog *db.Catalog, tick func()) error {
	rows, err := catalog.Read.Query(`SELECT rel_path FROM cache_objects`)
	if err != nil {
		return err
	}
	defer rows.Close()
	var drop []string
	for rows.Next() {
		var rel string
		if err := rows.Scan(&rel); err != nil {
			return err
		}
		if tick != nil {
			tick()
		}
		if !underCache(rel) {
			drop = append(drop, rel)
			continue
		}
		abs := filepath.Join(root, filepath.FromSlash(path.Clean(rel)))
		if _, err := os.Stat(abs); err != nil {
			drop = append(drop, rel)
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, rel := range drop {
		if _, err := catalog.Write.Exec(`DELETE FROM cache_objects WHERE rel_path = ?`, rel); err != nil {
			return err
		}
	}
	return nil
}

func dropScratch(root string, catalog *db.Catalog, rel, abs string) error {
	ref, err := scratchReferenced(catalog, rel)
	if err != nil {
		return err
	}
	if ref {
		return nil
	}
	if err := os.Remove(abs); err != nil && !os.IsNotExist(err) {
		return err
	}
	_, err = catalog.Write.Exec(`DELETE FROM cache_objects WHERE rel_path = ?`, rel)
	return err
}

func scratchReferenced(catalog *db.Catalog, rel string) (bool, error) {
	var n int
	err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE state NOT IN ('done', 'failed')
		AND (scratch_rel = ? OR backup_rel = ? OR src_rel = ? OR dest_rel = ?)`,
		rel, rel, rel, rel).Scan(&n)
	return n > 0, err
}

func adoptOrphan(root string, catalog *db.Catalog, rel, abs string, limits Limits) error {
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM cache_objects WHERE rel_path = ?`, rel).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil
	}
	class := "thumbnail"
	if strings.HasPrefix(rel, ".zimage/cache/embeddings/") {
		class = "embedding"
	}
	if info.Size() > limits.hard() || (class == "scratch" && info.Size() > scratchMax) {
		return os.Remove(abs)
	}
	err = remember(root, catalog, rel, class, info.Size(), limits)
	if errors.Is(err, ErrRefuse) {
		return os.Remove(abs)
	}
	return err
}

// remember records a file that is already under the cache. It does not read or rewrite those bytes.
func remember(root string, catalog *db.Catalog, rel, class string, size int64, limits Limits) error {
	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	var existing int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM cache_objects WHERE rel_path = ?`, rel).Scan(&existing); err != nil {
		return err
	}
	if existing > 0 {
		return nil
	}
	victims, err := evict(tx, rel, size, 0, limits)
	if err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.Exec(`
		INSERT INTO cache_objects (rel_path, class, bytes, last_access)
		VALUES (?, ?, ?, ?)`, rel, class, size, now); err != nil {
		return err
	}
	var total int64
	if err := tx.QueryRow(`SELECT COALESCE(SUM(bytes), 0) FROM cache_objects`).Scan(&total); err != nil {
		return err
	}
	if total > limits.hard() {
		return ErrRefuse
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	for _, victim := range victims {
		if underCache(victim) {
			_ = os.Remove(filepath.Join(root, filepath.FromSlash(victim)))
		}
	}
	return nil
}
