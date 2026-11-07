package dhashindex

import (
	"database/sql"
	"strconv"
	"strings"
	"time"
)

// Neighbor is one row that shares a band and is inside the Hamming limit.
type Neighbor struct {
	ID         int64
	UID        string
	Hash       uint64
	Width      int
	Height     int
	Capture    string
	Confidence float64
	Source     string
}

// Lookup streams six equality queries. It keeps a row only when popcount(xor)
// is within maxDist. A band value with more than scanLimit rows stops that
// stream and logs dhash_band_saturated. The query has no LIMIT and no ORDER BY.
func Lookup(db *sql.DB, self int64, hash uint64, maxDist, scanLimit int, log func(column string, value uint64)) ([]Neighbor, error) {
	if scanLimit <= 0 {
		scanLimit = ScanLimit
	}
	bands := Bands(hash)
	seen := map[int64]bool{}
	var out []Neighbor
	for i, column := range BandColumns {
		query := strings.Replace(BandSelectSQL, "COLUMN", column, 1)
		rows, err := db.Query(query, int64(bands[i]), self)
		if err != nil {
			return nil, err
		}
		n := 0
		saturated := false
		for rows.Next() {
			n++
			if n > scanLimit {
				saturated = true
				break
			}
			var item Neighbor
			var bits sql.NullInt64
			var width, height sql.NullInt64
			var capture, source sql.NullString
			if err := rows.Scan(&item.ID, &item.UID, &bits, &width, &height, &capture, &item.Confidence, &source); err != nil {
				rows.Close()
				return nil, err
			}
			if !bits.Valid || seen[item.ID] {
				continue
			}
			item.Hash = uint64(bits.Int64)
			if Hamming(hash, item.Hash) > maxDist {
				continue
			}
			if width.Valid {
				item.Width = int(width.Int64)
			}
			if height.Valid {
				item.Height = int(height.Int64)
			}
			if capture.Valid {
				item.Capture = capture.String
			}
			if source.Valid {
				item.Source = source.String
			}
			seen[item.ID] = true
			out = append(out, item)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
		if saturated && log != nil {
			log(column, bands[i])
		}
	}
	return out, nil
}

// AspectClose reports width/height ratios within 2 percent.
func AspectClose(w1, h1, w2, h2 int) bool {
	if w1 <= 0 || h1 <= 0 || w2 <= 0 || h2 <= 0 {
		return false
	}
	r1 := float64(w1) / float64(h1)
	r2 := float64(w2) / float64(h2)
	hi := r1
	if r2 > hi {
		hi = r2
	}
	if hi == 0 {
		return false
	}
	diff := r1 - r2
	if diff < 0 {
		diff = -diff
	}
	return diff/hi <= 0.02
}

// ParseCapture splits a stored capture into a clock, a full day, or a year.
func ParseCapture(text string) (when time.Time, full, yearOnly bool, year int) {
	if len(text) == 4 {
		for _, c := range text {
			if c < '0' || c > '9' {
				return time.Time{}, false, false, 0
			}
		}
		year, _ = strconv.Atoi(text)
		return time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC), false, true, year
	}
	when, err := time.Parse(time.RFC3339, text)
	if err != nil {
		return time.Time{}, false, false, 0
	}
	return when, true, false, when.Year()
}
