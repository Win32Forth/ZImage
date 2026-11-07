package detail

import (
	"bytes"
	"database/sql"
	"image/jpeg"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/pathsafe"
	"zimage/helper/internal/thumb"
)

// ScoreFiles scores JPEG, PNG, GIF, and BMP at or under 4 megapixels.
// A larger header, a RAW file, and HEIC stay detail_score NULL and detail_source needs_mac.
func ScoreFiles(root string, catalog *db.Catalog, note func(string), pause func()) error {
	rows, err := catalog.Read.Query(`
		SELECT id, uid, rel_path, ext, width, height, native_pixels
		FROM assets
		WHERE reorg_policy = 'move' AND detail_score IS NULL
		AND COALESCE(detail_source, '') NOT IN ('mac', 'preview_only', 'helper')`)
	if err != nil {
		return err
	}
	type item struct {
		id     int64
		uid    string
		rel    string
		ext    string
		width  sql.NullInt64
		height sql.NullInt64
		pixels sql.NullInt64
	}
	var list []item
	for rows.Next() {
		var one item
		if err := rows.Scan(&one.id, &one.uid, &one.rel, &one.ext, &one.width, &one.height, &one.pixels); err != nil {
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

	for i, one := range list {
		if err := scoreOne(root, catalog, one.id, one.uid, one.rel, one.ext, one.width, one.height, one.pixels, note); err != nil {
			return err
		}
		if pause != nil && (i+1)%50 == 0 {
			pause()
		}
	}
	return nil
}

func scoreOne(root string, catalog *db.Catalog, id int64, uid, rel, ext string, width, height, pixels sql.NullInt64, note func(string)) error {
	w, h := 0, 0
	if width.Valid && height.Valid {
		w, h = int(width.Int64), int(height.Int64)
	}
	if w <= 0 || h <= 0 {
		if dw, dh, ok := thumb.Dimensions(filepath.Join(root, filepath.FromSlash(rel))); ok {
			w, h = dw, dh
		}
	}
	native := int64(0)
	if pixels.Valid {
		native = pixels.Int64
	}
	if native <= 0 && w > 0 && h > 0 {
		native = int64(w) * int64(h)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if ext == "x3f" {
		return scoreX3F(root, catalog, id, uid, rel, note)
	}
	if !decodable(ext) || native <= 0 || native > MaxPixels {
		_, err := catalog.Write.Exec(`UPDATE assets SET detail_source = 'needs_mac', updated_at = ? WHERE id = ? AND detail_score IS NULL`, now, id)
		return err
	}
	if err := pathsafe.Jail(root, rel); err != nil {
		_, err = catalog.Write.Exec(`UPDATE assets SET detail_source = 'needs_mac', updated_at = ? WHERE id = ? AND detail_score IS NULL`, now, id)
		return err
	}
	img, err := thumb.OpenDecoded(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		_, err = catalog.Write.Exec(`UPDATE assets SET detail_source = 'needs_mac', updated_at = ? WHERE id = ? AND detail_score IS NULL`, now, id)
		return err
	}
	score := ScoreImage(img)
	_, err = catalog.Write.Exec(`
		UPDATE assets
		SET detail_score = ?, detail_source = 'helper', native_pixels = ?, width = ?, height = ?, updated_at = ?
		WHERE id = ?`, score, native, w, h, now, id)
	if err != nil {
		return err
	}
	if note != nil {
		note("detail_scored " + uid + " helper " + strconv.FormatFloat(score, 'g', 6, 64))
	}
	return nil
}

func decodable(ext string) bool {
	switch ext {
	case "jpg", "jpeg", "png", "gif", "bmp":
		return true
	default:
		return false
	}
}

func scoreX3F(root string, catalog *db.Catalog, id int64, uid, rel string, note func(string)) error {
	now := time.Now().UTC().Format(time.RFC3339)
	mark := func() error {
		_, err := catalog.Write.Exec(`UPDATE assets SET detail_source = 'needs_mac', updated_at = ? WHERE id = ? AND detail_score IS NULL`, now, id)
		return err
	}
	if err := pathsafe.Jail(root, rel); err != nil {
		return mark()
	}
	file, err := os.Open(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return mark()
	}
	defer file.Close()
	buf := make([]byte, 8<<20)
	n, _ := file.Read(buf)
	buf = buf[:n]
	payload := embeddedJPEG(buf)
	if len(payload) == 0 || len(payload) > 4<<20 {
		return mark()
	}
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(payload))
	if err != nil || int64(cfg.Width)*int64(cfg.Height) > MaxPixels || cfg.Width <= 0 {
		return mark()
	}
	img, err := jpeg.Decode(bytes.NewReader(payload))
	if err != nil {
		return mark()
	}
	score := ScoreImage(img)
	_, err = catalog.Write.Exec(`
		UPDATE assets
		SET detail_score = ?, detail_source = 'preview_only', updated_at = ?
		WHERE id = ?`, score, now, id)
	if err != nil {
		return err
	}
	if note != nil {
		note("detail_scored " + uid + " preview_only " + strconv.FormatFloat(score, 'g', 6, 64))
	}
	return nil
}

func embeddedJPEG(buf []byte) []byte {
	for i := 0; i+1 < len(buf); i++ {
		if buf[i] != 0xFF || buf[i+1] != 0xD8 {
			continue
		}
		for j := i + 2; j+1 < len(buf); j++ {
			if buf[j] == 0xFF && buf[j+1] == 0xD9 {
				return buf[i : j+2]
			}
		}
		return nil
	}
	return nil
}

// Recompute rewrites keepers for the asset's group. It does not invent a missing score.
func Recompute(catalog *db.Catalog, assetID int64) error {
	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := RecomputeTx(tx, assetID); err != nil {
		return err
	}
	return tx.Commit()
}

// RecomputeTx is Recompute inside the caller's transaction.
// A trim, manual remove, or restore uses it in the same transaction as the path change.
func RecomputeTx(tx *sql.Tx, assetID int64) error {
	var gid sql.NullInt64
	if err := tx.QueryRow(`SELECT derivative_group_id FROM assets WHERE id = ?`, assetID).Scan(&gid); err != nil {
		return err
	}
	if !gid.Valid {
		return nil
	}
	rows, err := tx.Query(`
		SELECT id, rel_path, ext, detail_score, native_pixels, byte_size, placement
		FROM assets WHERE derivative_group_id = ?`, gid.Int64)
	if err != nil {
		return err
	}
	var members []Candidate
	for rows.Next() {
		var item Candidate
		var score sql.NullFloat64
		var pixels sql.NullInt64
		if err := rows.Scan(&item.ID, &item.Rel, &item.Ext, &score, &pixels, &item.Bytes, &item.Placement); err != nil {
			rows.Close()
			return err
		}
		item.HasScore = score.Valid
		item.Score = score.Float64
		if pixels.Valid {
			item.Pixels = pixels.Int64
		}
		members = append(members, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	eligible := EligibleFlag(members)
	keeperID, ok := SelectKeeper(members)
	var keeper any
	if ok {
		keeper = keeperID
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.Exec(`UPDATE derivative_groups SET eligible = ?, keeper_asset_id = ? WHERE id = ?`, eligible, keeper, gid.Int64); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE assets SET is_keeper = 0, updated_at = ? WHERE derivative_group_id = ?`, now, gid.Int64); err != nil {
		return err
	}
	if ok {
		if _, err := tx.Exec(`UPDATE assets SET is_keeper = 1, updated_at = ? WHERE id = ?`, now, keeperID); err != nil {
			return err
		}
	}
	return nil
}
