package events

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"path/filepath"
	"time"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/db"
	"zimage/helper/internal/dhashindex"
	"zimage/helper/internal/pathsafe"
)

// Apply writes event rows from accepted capture times.
// GPS is read for this pass and stored only as the event mean.
// Non-user events are deleted only after asset.event_id is cleared.
// Year-only files stay out of the hour-gap splitter.
func Apply(root string, catalog *db.Catalog, pause func()) error {
	items, err := loadItems(root, catalog, pause)
	if err != nil {
		return err
	}
	named := NameClusters(Cluster(items), map[string]bool{})
	now := time.Now().UTC().Format(time.RFC3339)
	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`UPDATE assets SET event_id = NULL WHERE event_id IS NOT NULL`); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM events WHERE name_source != 'user'`); err != nil {
		return err
	}
	seenUser := map[int64]bool{}
	for _, event := range named {
		id := event.KeepID
		folder := event.Folder
		if event.KeepID != 0 {
			if !seenUser[event.KeepID] {
				folder = Folder(event.Start, event.YearOnly, event.Year, event.Slug)
				if _, err := tx.Exec(`
					UPDATE events
					SET start_time = ?, end_time = ?, folder_rel = ?, gps_lat = ?, gps_lon = ?
					WHERE id = ? AND name_source = 'user'`,
					eventClock(event, event.Start), eventClock(event, event.End), folder,
					floatOrNil(event.Lat), floatOrNil(event.Lon), event.KeepID); err != nil {
					return err
				}
				seenUser[event.KeepID] = true
			}
		} else {
			uid, err := newEventUID()
			if err != nil {
				return err
			}
			res, err := tx.Exec(`
				INSERT INTO events (uid, name, name_source, start_time, end_time, slug, folder_rel, gps_lat, gps_lon)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				uid, event.Name, event.Source, eventClock(event, event.Start), eventClock(event, event.End),
				event.Slug, folder, floatOrNil(event.Lat), floatOrNil(event.Lon))
			if err != nil {
				return err
			}
			id, err = res.LastInsertId()
			if err != nil {
				return err
			}
		}
		for _, item := range event.Items {
			if _, err := tx.Exec(`
				UPDATE assets
				SET event_id = ?,
					phase = CASE WHEN phase IN ('placed', 'parked') THEN phase ELSE 'clustered' END,
					updated_at = ?
				WHERE id = ?`, id, now, item.ID); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

func loadItems(root string, catalog *db.Catalog, pause func()) ([]Item, error) {
	rows, err := catalog.Read.Query(`
		SELECT a.id, a.rel_path, COALESCE(a.capture_time, ''), a.capture_confidence, a.dhash,
			COALESCE(e.id, 0), COALESCE(e.name, ''), COALESCE(e.name_source, ''), COALESCE(e.slug, '')
		FROM assets a
		LEFT JOIN events e ON e.id = a.event_id
		WHERE a.media_class IN ('image', 'raw')`)
	if err != nil {
		return nil, err
	}
	type raw struct {
		item    Item
		rel     string
		capture string
		conf    float64
		bits    sql.NullInt64
	}
	var list []raw
	for rows.Next() {
		var one raw
		if err := rows.Scan(&one.item.ID, &one.rel, &one.capture, &one.conf, &one.bits, &one.item.EventID, &one.item.EventName, &one.item.NameSource, &one.item.EventSlug); err != nil {
			rows.Close()
			return nil, err
		}
		list = append(list, one)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()

	var items []Item
	for i, one := range list {
		when, full, yearOnly, year := dhashindex.ParseCapture(one.capture)
		if one.conf < 0.70 || (!full && !yearOnly) {
			continue
		}
		item := one.item
		item.Rel = one.rel
		item.Time = when
		item.HasTime = true
		item.YearOnly = yearOnly
		item.Year = year
		if one.bits.Valid {
			item.Hash = uint64(one.bits.Int64)
			item.HasHash = true
		}
		if root != "" && pathsafe.Jail(root, one.rel) == nil {
			if facts, err := dating.ReadFacts(filepath.Join(root, filepath.FromSlash(one.rel))); err == nil {
				item.Lat = facts.Lat
				item.Lon = facts.Lon
			}
		}
		items = append(items, item)
		if pause != nil && (i+1)%50 == 0 {
			pause()
		}
	}
	return items, nil
}

func eventClock(event Named, when time.Time) any {
	if event.YearOnly {
		year := event.Year
		if year == 0 {
			year = when.Year()
		}
		return fmt.Sprintf("%04d", year)
	}
	if when.IsZero() {
		return nil
	}
	return when.Format(time.RFC3339)
}

func floatOrNil(v *float64) any {
	if v == nil {
		return nil
	}
	return *v
}

func newEventUID() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}
