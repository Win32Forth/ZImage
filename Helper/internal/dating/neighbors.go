package dating

import (
	"strconv"

	"zimage/helper/internal/db"
	"zimage/helper/internal/dhashindex"
)

type hashRow struct {
	id         int64
	hash       uint64
	capture    string
	confidence float64
	source     string
}

// InheritNeighbors copies a date across one dHash hop and applies the burst rule.
// The neighbor set is the pre-update snapshot, so a second hop does not chain.
func InheritNeighbors(catalog *db.Catalog, opts Options) error {
	rows, err := catalog.Read.Query(`
		SELECT id, dhash, COALESCE(capture_time, ''), capture_confidence, COALESCE(capture_source, '')
		FROM assets
		WHERE dhash IS NOT NULL AND COALESCE(capture_source, '') != 'user'`)
	if err != nil {
		return err
	}
	var list []hashRow
	for rows.Next() {
		var item hashRow
		var bits int64
		if err := rows.Scan(&item.id, &bits, &item.capture, &item.confidence, &item.source); err != nil {
			rows.Close()
			return err
		}
		item.hash = uint64(bits)
		list = append(list, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	updates := map[int64]Decision{}
	for _, item := range list {
		base := decisionFromStored(item.capture, item.confidence, item.source)
		neighbors, err := dhashindex.Lookup(catalog.Read, item.id, item.hash, dhashindex.DateDistance, dhashindex.ScanLimit, func(column string, value uint64) {
			opts.note("dhash_band_saturated " + column + "=" + uitoa(value))
		})
		if err != nil {
			return err
		}
		best := base
		for _, neighbor := range neighbors {
			when, full, yearOnly, year := dhashindex.ParseCapture(neighbor.Capture)
			distance := dhashindex.Hamming(item.hash, neighbor.Hash)
			hop := Inherit(base, Neighbor{
				Time: when, Confidence: neighbor.Confidence, FullDay: full, YearOnly: yearOnly,
				Year: year, Inherited: neighbor.Source == "dhash", Distance: distance,
			})
			if hop.Confidence > best.Confidence {
				best = hop
			}
			if !base.HasCapture || when.IsZero() {
				continue
			}
			delta := base.Capture.Sub(when)
			if delta < 0 {
				delta = -delta
			}
			burst := ApplyBurst(base, Burst{
				Time: when, Confidence: neighbor.Confidence, FullDay: full, YearOnly: yearOnly, Year: year,
				Distance: distance, Delta: delta,
			})
			if burst.Confidence > best.Confidence {
				best = burst
			}
		}
		if best.Source != base.Source || best.Confidence != base.Confidence || best.StoredTime() != base.StoredTime() {
			updates[item.id] = best
		}
	}
	if len(updates) == 0 {
		return nil
	}
	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	pending := 0
	for id, decision := range updates {
		if err := writeDecision(tx, id, decision, "dated"); err != nil {
			return err
		}
		pending++
		if pending >= batchSize {
			if err := tx.Commit(); err != nil {
				return err
			}
			opts.pause()
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

func uitoa(n uint64) string {
	return strconv.FormatUint(n, 10)
}
