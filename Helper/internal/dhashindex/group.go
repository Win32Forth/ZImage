package dhashindex

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/detail"
)

type member struct {
	id        int64
	uid       string
	rel       string
	ext       string
	hash      uint64
	hasHash   bool
	blake     []byte
	width     int
	height    int
	score     sql.NullFloat64
	pixels    sql.NullInt64
	bytes     int64
	placement string
}

// Group builds derivative groups from blake3 equality and from band candidates
// at Hamming distance <= 5 with known dimensions and aspect within 2%.
// A file with no neighbor stays ungrouped. The saturated tail is whatever Lookup omitted.
func Group(catalog *db.Catalog, note func(string)) error {
	rows, err := catalog.Read.Query(`
		SELECT id, uid, rel_path, ext, dhash, blake3, width, height, detail_score, native_pixels, byte_size, placement
		FROM assets
		WHERE media_class IN ('image', 'raw')`)
	if err != nil {
		return err
	}
	var list []member
	byID := map[int64]member{}
	for rows.Next() {
		var item member
		var bits sql.NullInt64
		var width, height sql.NullInt64
		if err := rows.Scan(&item.id, &item.uid, &item.rel, &item.ext, &bits, &item.blake, &width, &height, &item.score, &item.pixels, &item.bytes, &item.placement); err != nil {
			rows.Close()
			return err
		}
		if bits.Valid {
			item.hash = uint64(bits.Int64)
			item.hasHash = true
		}
		if width.Valid {
			item.width = int(width.Int64)
		}
		if height.Valid {
			item.height = int(height.Int64)
		}
		list = append(list, item)
		byID[item.id] = item
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	parent := map[int64]int64{}
	var find func(int64) int64
	find = func(id int64) int64 {
		p, ok := parent[id]
		if !ok {
			parent[id] = id
			return id
		}
		if p == id {
			return id
		}
		parent[id] = find(p)
		return parent[id]
	}
	join := func(a, b int64) {
		ra, rb := find(a), find(b)
		if ra != rb {
			parent[rb] = ra
		}
	}
	log := func(column string, value uint64) {
		if note != nil {
			note("dhash_band_saturated " + column + "=" + formatUint(value))
		}
	}
	for _, item := range list {
		if len(item.blake) > 0 {
			matches, err := catalog.Read.Query(`SELECT id FROM assets WHERE blake3 = ? AND id != ?`, item.blake, item.id)
			if err != nil {
				return err
			}
			for matches.Next() {
				var other int64
				if err := matches.Scan(&other); err != nil {
					matches.Close()
					return err
				}
				join(item.id, other)
			}
			if err := matches.Err(); err != nil {
				matches.Close()
				return err
			}
			matches.Close()
		}
		if !item.hasHash {
			continue
		}
		neighbors, err := Lookup(catalog.Read, item.id, item.hash, GroupDistance, ScanLimit, log)
		if err != nil {
			return err
		}
		for _, neighbor := range neighbors {
			if !AspectClose(item.width, item.height, neighbor.Width, neighbor.Height) {
				continue
			}
			join(item.id, neighbor.ID)
		}
	}

	comps := map[int64][]member{}
	for id := range parent {
		root := find(id)
		if item, ok := byID[id]; ok {
			comps[root] = append(comps[root], item)
		}
	}

	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`UPDATE assets SET derivative_group_id = NULL, is_keeper = 0 WHERE media_class IN ('image', 'raw')`); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM derivative_groups`); err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	for _, members := range comps {
		if len(members) < 2 {
			continue
		}
		uid, err := newUID()
		if err != nil {
			return err
		}
		res, err := tx.Exec(`INSERT INTO derivative_groups (uid, eligible) VALUES (?, 0)`, uid)
		if err != nil {
			return err
		}
		gid, err := res.LastInsertId()
		if err != nil {
			return err
		}
		candidates := make([]detail.Candidate, len(members))
		for i, item := range members {
			if _, err := tx.Exec(`UPDATE assets SET derivative_group_id = ?, updated_at = ? WHERE id = ?`, gid, now, item.id); err != nil {
				return err
			}
			candidates[i] = detail.Candidate{
				ID: item.id, Rel: item.rel, Ext: item.ext, Bytes: item.bytes, Placement: item.placement,
				HasScore: item.score.Valid, Score: item.score.Float64,
			}
			if item.pixels.Valid {
				candidates[i].Pixels = item.pixels.Int64
			}
		}
		eligible := detail.EligibleFlag(candidates)
		var keeper any
		keeperID, ok := detail.SelectKeeper(candidates)
		if ok {
			keeper = keeperID
		}
		if _, err := tx.Exec(`UPDATE derivative_groups SET keeper_asset_id = ?, eligible = ? WHERE id = ?`, keeper, eligible, gid); err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE assets SET is_keeper = 0, updated_at = ? WHERE derivative_group_id = ?`, now, gid); err != nil {
			return err
		}
		if ok {
			if _, err := tx.Exec(`UPDATE assets SET is_keeper = 1, updated_at = ? WHERE id = ?`, now, keeperID); err != nil {
				return err
			}
		}
	}
	if _, err := tx.Exec(`
		UPDATE assets
		SET phase = CASE WHEN phase IN ('placed', 'parked', 'planned') THEN phase ELSE 'clustered' END
		WHERE derivative_group_id IS NOT NULL`); err != nil {
		return err
	}
	return tx.Commit()
}

func newUID() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}

func formatUint(n uint64) string {
	const digits = "0123456789"
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = digits[n%10]
		n /= 10
	}
	return string(buf[i:])
}
