package dhashindex

import (
	"os"
	"path/filepath"
	"time"

	"image/jpeg"

	"zimage/helper/internal/db"
	"zimage/helper/internal/pathsafe"
)

// IndexThumbs writes a dHash for each stored NAS thumbnail. Files without one wait.
func IndexThumbs(root string, catalog *db.Catalog, pause func()) error {
	rows, err := catalog.Read.Query(`SELECT id, uid, thumb_rel FROM assets WHERE thumb_rel IS NOT NULL AND dhash IS NULL`)
	if err != nil {
		return err
	}
	type item struct {
		id   int64
		uid  string
		rel  string
	}
	var list []item
	for rows.Next() {
		var one item
		if err := rows.Scan(&one.id, &one.uid, &one.rel); err != nil {
			rows.Close()
			return err
		}
		list = append(list, one)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	pending := 0
	for _, one := range list {
		if err := pathsafe.Jail(root, one.rel); err != nil {
			continue
		}
		file, err := os.Open(filepath.Join(root, filepath.FromSlash(one.rel)))
		if err != nil {
			continue
		}
		img, err := jpeg.Decode(file)
		file.Close()
		if err != nil {
			continue
		}
		hash := HashImage(img)
		bands := Bands(hash)
		now := time.Now().UTC().Format(time.RFC3339)
		if _, err := tx.Exec(`
			UPDATE assets
			SET dhash = ?, dhash_b0 = ?, dhash_b1 = ?, dhash_b2 = ?, dhash_b3 = ?, dhash_b4 = ?, dhash_b5 = ?, updated_at = ?
			WHERE id = ?`,
			int64(hash), int64(bands[0]), int64(bands[1]), int64(bands[2]), int64(bands[3]), int64(bands[4]), int64(bands[5]), now, one.id); err != nil {
			return err
		}
		pending++
		if pending >= 50 {
			if err := tx.Commit(); err != nil {
				return err
			}
			if pause != nil {
				pause()
			}
			tx, err = catalog.Write.Begin()
			if err != nil {
				return err
			}
			pending = 0
		}
	}
	if pending == 0 {
		return nil
	}
	return tx.Commit()
}
