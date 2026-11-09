package dating

import (
	"database/sql"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/pathsafe"
)

const batchSize = 50

// Options paces a pass. Pause runs after each batch of 50 files.
// Progress reports files looked at. It does no extra catalog work.
type Options struct {
	Now      time.Time
	Pause    func()
	Note     func(string)
	Progress func(done, total int)
}

func (o Options) now() time.Time {
	if o.Now.IsZero() {
		return time.Now()
	}
	return o.Now
}

func (o Options) pause() {
	if o.Pause != nil {
		o.Pause()
	}
}

func (o Options) note(event string) {
	if o.Note != nil && event != "" {
		o.Note(event)
	}
}

type row struct {
	id         int64
	rel        string
	policy     string
	source     string
	mtime      sql.NullInt64
	confidence float64
}

// Assign writes capture fields from EXIF, the path, the year folder, and mtime.
// A user date is left at confidence 1. Files are opened read-only.
func Assign(root string, catalog *db.Catalog, opts Options) error {
	if opts.Progress != nil {
		opts.Progress(0, 0)
	}
	rows, err := catalog.Read.Query(`
		SELECT id, rel_path, reorg_policy, COALESCE(capture_source, ''), mtime_ns, capture_confidence
		FROM assets
		WHERE reorg_policy = 'move' AND COALESCE(capture_source, '') != 'user'`)
	if err != nil {
		return err
	}
	var list []row
	for rows.Next() {
		var item row
		if err := rows.Scan(&item.id, &item.rel, &item.policy, &item.source, &item.mtime, &item.confidence); err != nil {
			rows.Close()
			return err
		}
		list = append(list, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	type stamped struct {
		row   row
		facts Facts
		has   bool
	}
	read := make([]stamped, len(list))
	origCount := map[string]int{}
	digCount := map[string]int{}
	chgCount := map[string]int{}
	videoCount := map[string]int{}
	mtCount := map[string]int{}
	advance := func(done int) {
		if opts.Progress != nil {
			opts.Progress(done, len(list))
		}
	}
	advance(0)
	for i, item := range list {
		read[i].row = item
		if item.mtime.Valid {
			mtCount[dirKey(item.rel)+"|"+itoa(item.mtime.Int64)]++
		}
		facts, ok := factsFor(root, item.rel)
		if !ok {
			advance(i + 1)
			continue
		}
		read[i].facts = facts
		read[i].has = true
		if facts.Original != nil {
			origCount[dirKey(item.rel)+"|"+facts.Original.Time.Format(time.RFC3339Nano)]++
		}
		if facts.Digitized != nil {
			digCount[dirKey(item.rel)+"|"+facts.Digitized.Time.Format(time.RFC3339Nano)]++
		}
		if facts.DateTime != nil {
			chgCount[dirKey(item.rel)+"|"+facts.DateTime.Time.Format(time.RFC3339Nano)]++
		}
		if facts.Video != nil {
			videoCount[dirKey(item.rel)+"|"+facts.Video.Time.Format(time.RFC3339Nano)]++
		}
		advance(i + 1)
	}

	now := opts.now()
	var pending int
	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	commit := func() error {
		if pending == 0 {
			return nil
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		pending = 0
		opts.pause()
		tx, err = catalog.Write.Begin()
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for _, item := range read {
		in := Input{RelPath: item.row.rel, Now: now, SameMTimeCount: 1}
		if item.has {
			in.EXIFOriginal = item.facts.Original
			in.EXIFDigitized = item.facts.Digitized
			in.EXIFDateTime = item.facts.DateTime
			if item.facts.Original != nil {
				in.SameOriginal = origCount[dirKey(item.row.rel)+"|"+item.facts.Original.Time.Format(time.RFC3339Nano)]
			}
			if item.facts.Digitized != nil {
				in.SameDigitized = digCount[dirKey(item.row.rel)+"|"+item.facts.Digitized.Time.Format(time.RFC3339Nano)]
			}
			if item.facts.DateTime != nil {
				in.SameChanged = chgCount[dirKey(item.row.rel)+"|"+item.facts.DateTime.Time.Format(time.RFC3339Nano)]
			}
			if item.facts.Video != nil {
				in.VideoCreated = item.facts.Video
				in.SameVideo = videoCount[dirKey(item.row.rel)+"|"+item.facts.Video.Time.Format(time.RFC3339Nano)]
			}
		}
		if item.row.mtime.Valid {
			when := time.Unix(0, item.row.mtime.Int64).UTC()
			in.MTime = &when
			in.SameMTimeCount = mtCount[dirKey(item.row.rel)+"|"+itoa(item.row.mtime.Int64)]
		}
		if err := writeDecision(tx, item.row.id, Decide(in), "dated"); err != nil {
			return err
		}
		pending++
		if pending >= batchSize {
			if err := commit(); err != nil {
				return err
			}
		}
	}
	return commit()
}

func factsFor(root, rel string) (Facts, bool) {
	if root == "" {
		return Facts{}, false
	}
	if err := pathsafe.Jail(root, rel); err != nil {
		return Facts{}, false
	}
	full := filepath.Join(root, filepath.FromSlash(rel))
	facts, err := ReadFacts(full)
	if err != nil {
		return Facts{}, false
	}
	if videoExt(rel) {
		if when, ok := readMovieCreation(full); ok {
			facts.Video = &Stamp{Time: when}
		}
	}
	return facts, true
}

func videoExt(rel string) bool {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(rel), "."))
	switch ext {
	case "mov", "mp4", "m4v", "m4p", "avi", "mkv", "mpg", "mpeg", "mpe", "m2v", "wmv", "flv", "webm", "3gp", "3g2", "mts", "m2ts", "ts", "vob", "ogv", "asf", "divx":
		return true
	default:
		return false
	}
}

func writeDecision(tx *sql.Tx, id int64, d Decision, phase string) error {
	stored := d.StoredTime()
	var capture any
	if stored != "" {
		capture = stored
	}
	offset := 0
	if d.OffsetKnown {
		offset = 1
	}
	var source any
	if d.Source != "" {
		source = d.Source
	}
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := tx.Exec(`
		UPDATE assets
		SET capture_time = ?, capture_offset_known = ?, capture_source = ?, capture_confidence = ?,
			candidate_capture_time = ?, phase = CASE WHEN phase IN ('placed', 'parked') THEN phase ELSE ? END,
			updated_at = ?
		WHERE id = ?`,
		capture, offset, source, d.Confidence, capture, phase, now, id)
	return err
}

func dirKey(rel string) string {
	if i := strings.LastIndex(rel, "/"); i >= 0 {
		return rel[:i]
	}
	return ""
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}
