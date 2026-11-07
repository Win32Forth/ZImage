package thumb

import (
	"bytes"
	"errors"
	"image/jpeg"
	"path/filepath"
	"time"

	"zimage/helper/internal/cacheledger"
	"zimage/helper/internal/db"
	"zimage/helper/internal/pathsafe"
)

// Apply writes one thumbnail at a time for discovered images and RAW files.
// pause reports the RSS shed flag. A true result skips the rest of this pass.
// Rows are taken in id order, 32 at a time, so the first grid page is not
// blocked behind a query of the whole library.
func Apply(root string, catalog *db.Catalog, pause func() bool) error {
	for {
		if pause != nil && pause() {
			return nil
		}
		n, err := ApplyNext(root, catalog, pause, 32)
		if err != nil || n == 0 {
			return err
		}
	}
}

// ApplyNext writes at most limit previews, oldest id first.
// The count is rows finished in this call. A file that cannot be opened stays
// discovered and is left for a later pass, so one failure does not stall the batch.
func ApplyNext(root string, catalog *db.Catalog, pause func() bool, limit int) (int, error) {
	if limit <= 0 {
		return 0, nil
	}
	if err := releasePermanent(catalog); err != nil {
		return 0, err
	}
	// A needs_mac JPEG, PNG, GIF, or BMP at or under the pixel ceiling is tried
	// again. decode_support stays unknown until that attempt finishes, so a
	// failure can be marked failed and is not selected on the next pass.
	rows, err := catalog.Read.Query(`
		SELECT id, uid, rel_path FROM assets
		WHERE phase = 'discovered' AND thumb_rel IS NULL
		AND media_class IN ('image', 'raw')
		AND (
			detail_source IS NULL
			OR (
				detail_source = 'needs_mac'
				AND COALESCE(decode_support, '') = 'unknown'
				AND native_pixels IS NOT NULL
				AND native_pixels <= ?
				AND lower(ext) IN ('jpg', 'jpeg', 'png', 'gif', 'bmp')
			)
		)
		ORDER BY id
		LIMIT ?`, maxPixels, limit)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	type item struct {
		id       int64
		uid, rel string
	}
	var pending []item
	for rows.Next() {
		var one item
		if err := rows.Scan(&one.id, &one.uid, &one.rel); err != nil {
			return 0, err
		}
		pending = append(pending, one)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	finished := 0
	for _, one := range pending {
		if pause != nil && pause() {
			return finished, nil
		}
		if err := pathsafe.Jail(root, one.rel); err != nil {
			continue
		}
		result, err := Build(filepath.Join(root, filepath.FromSlash(one.rel)))
		if err != nil {
			continue
		}
		now := time.Now().UTC().Format(time.RFC3339)
		if result.NeedsMac || len(result.JPEG) == 0 {
			support := "needs_mac"
			if !tooBig(result.Width, result.Height) {
				support = "failed"
			}
			_, err = catalog.Write.Exec(`
				UPDATE assets
				SET detail_source = 'needs_mac', decode_support = ?,
					width = ?, height = ?, native_pixels = ?, updated_at = ?
				WHERE uid = ?`,
				support, nullInt(result.Width), nullInt(result.Height), pixels(result.Width, result.Height), now, one.uid)
			if err != nil {
				return finished, err
			}
			finished++
			continue
		}
		rel := thumbRel(one.uid)
		if err := pathsafe.Jail(root, rel); err != nil {
			return finished, err
		}
		if err := cacheledger.Put(root, catalog, rel, "thumbnail", one.id, result.JPEG, cacheledger.Limits{}); err != nil {
			if errors.Is(err, cacheledger.ErrRefuse) {
				return finished, nil
			}
			return finished, err
		}
		_, err = catalog.Write.Exec(`
			UPDATE assets
			SET thumb_rel = ?, phase = 'thumbed', decode_support = ?,
				detail_source = NULL,
				width = ?, height = ?, native_pixels = ?, updated_at = ?
			WHERE uid = ?`,
			rel, result.DecodeSupport, result.Width, result.Height, pixels(result.Width, result.Height), now, one.uid)
		if err != nil {
			return finished, err
		}
		finished++
	}
	return finished, nil
}

// releasePermanent stops polling rows this pass will not decode.
func releasePermanent(catalog *db.Catalog) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := catalog.Write.Exec(`
		UPDATE assets
		SET decode_support = 'needs_mac', updated_at = ?
		WHERE detail_source = 'needs_mac'
		  AND COALESCE(decode_support, '') = 'unknown'
		  AND (
		    native_pixels IS NULL
		    OR native_pixels > ?
		    OR lower(ext) NOT IN ('jpg', 'jpeg', 'png', 'gif', 'bmp')
		  )`, now, maxPixels)
	return err
}

func thumbRel(uid string) string {
	return CacheRel(uid)
}

// CacheRel is the thumbnail path under .zimage/cache/thumbs.
// ApplyNext records that file in the cache ledger before it counts as kept.
func CacheRel(uid string) string {
	prefix := uid
	if len(prefix) > 2 {
		prefix = prefix[:2]
	}
	return ".zimage/cache/thumbs/" + prefix + "/" + uid + ".jpg"
}

func nullInt(value int) any {
	if value <= 0 {
		return nil
	}
	return value
}

func pixels(width, height int) any {
	if width <= 0 || height <= 0 {
		return nil
	}
	return int64(width) * int64(height)
}

// LongEdgeIsBounded reports whether a JPEG's long edge is at most 512.
func LongEdgeIsBounded(jpegBytes []byte) bool {
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(jpegBytes))
	if err != nil {
		return false
	}
	long := cfg.Width
	if cfg.Height > long {
		long = cfg.Height
	}
	return long > 0 && long <= longEdge
}
