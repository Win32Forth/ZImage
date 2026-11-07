// Package trim plans eligible derivative groups into the duplicates store.
// It writes journal rows. The mover copies one file at a time after Start.
package trim

import (
	"database/sql"
	"path"
	"time"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/db"
	"zimage/helper/internal/detail"
)

// Plan writes one planned trim row for every unpinned active member except the keeper.
// A group with any null detail_score is skipped. A group of one is skipped.
// An asset that already has an open or planned journal row is skipped.
func Plan(catalog *db.Catalog) error {
	groups, err := catalog.Read.Query(`SELECT id, uid FROM derivative_groups ORDER BY id`)
	if err != nil {
		return err
	}
	defer groups.Close()
	type group struct {
		id  int64
		uid string
	}
	var list []group
	for groups.Next() {
		var item group
		if err := groups.Scan(&item.id, &item.uid); err != nil {
			return err
		}
		list = append(list, item)
	}
	if err := groups.Err(); err != nil {
		return err
	}
	used := map[string]bool{}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, item := range list {
		members, err := loadMembers(catalog, item.id)
		if err != nil {
			return err
		}
		if !detail.EligibleForTrim(members) {
			continue
		}
		if err := detail.Recompute(catalog, members[0].ID); err != nil {
			return err
		}
		keeper, ok := detail.SelectKeeper(members)
		if !ok {
			continue
		}
		for _, member := range members {
			if member.ID == keeper || member.Placement != "active" || member.Pinned {
				continue
			}
			busy, err := journalBusy(catalog, member.ID)
			if err != nil {
				return err
			}
			if busy {
				continue
			}
			base := path.Base(member.Rel)
			dest, err := claim(catalog, item.uid, base, used)
			if err != nil {
				return err
			}
			if _, err := catalog.Write.Exec(`
				INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
				VALUES (?, 'trim', 'planned', ?, ?, ?, ?)`,
				member.ID, member.Rel, dest, member.Bytes, now); err != nil {
				return err
			}
		}
	}
	return nil
}

func loadMembers(catalog *db.Catalog, groupID int64) ([]detail.Candidate, error) {
	rows, err := catalog.Read.Query(`
		SELECT id, rel_path, ext, detail_score, native_pixels, byte_size, placement, pinned
		FROM assets WHERE derivative_group_id = ? ORDER BY id`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var members []detail.Candidate
	for rows.Next() {
		var item detail.Candidate
		var score sql.NullFloat64
		var pixels sql.NullInt64
		var pinned int
		if err := rows.Scan(&item.ID, &item.Rel, &item.Ext, &score, &pixels, &item.Bytes, &item.Placement, &pinned); err != nil {
			return nil, err
		}
		item.HasScore = score.Valid
		item.Score = score.Float64
		if pixels.Valid {
			item.Pixels = pixels.Int64
		}
		item.Pinned = pinned != 0
		members = append(members, item)
	}
	return members, rows.Err()
}

func journalBusy(catalog *db.Catalog, assetID int64) (bool, error) {
	var n int
	err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE asset_id = ? AND state NOT IN ('done', 'failed')`, assetID).Scan(&n)
	return n > 0, err
}

func claim(catalog *db.Catalog, groupUID, name string, used map[string]bool) (string, error) {
	for n := 1; n < 1000; n++ {
		file := name
		if n > 1 {
			file = dating.CollisionName(name, n)
		}
		rel := "Photos/_Duplicates/" + groupUID + "/" + file
		if used[rel] {
			continue
		}
		var count int
		if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE rel_path = ?`, rel).Scan(&count); err != nil {
			return "", err
		}
		if count == 0 {
			used[rel] = true
			return rel, nil
		}
	}
	return "", sql.ErrNoRows
}
