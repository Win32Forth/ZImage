package dating

import (
	"database/sql"
	"errors"
	"path"
	"strings"
	"time"

	"zimage/helper/internal/db"
)

// ErrPrefix means the plan prefix is outside Photos or under Photos/_Duplicates.
var ErrPrefix = errors.New("prefix outside Photos")

// Counts is the dry-run result. Nothing in the count has been copied.
type Counts struct {
	Move          int
	AlreadyPlaced int
	Park          int
	Leave         int
	Seen          int
}

type planRow struct {
	id         int64
	rel        string
	policy     string
	source     string
	capture    string
	confidence float64
	bytes      int64
	blake      []byte
	fast       []byte
	folder     string
	groupID    sql.NullInt64
	placement  string
	keeper     int
}

// Plan inserts one planned journal row per movable file under Photos.
// A file already under Photos/_Duplicates/ gets no row.
// A row whose source already equals the destination is planned and is not copied.
// This function does not rename, copy, or remove a library file.
func Plan(catalog *db.Catalog) error {
	_, err := PlanPrefix(catalog, "Photos")
	return err
}

// CleanPrefix accepts Photos and a directory under it. The store prefix is refused.
func CleanPrefix(prefix string) (string, error) {
	prefix = strings.TrimSpace(prefix)
	if prefix == "" {
		prefix = "Photos"
	}
	prefix = path.Clean(strings.TrimPrefix(prefix, "/"))
	if prefix == "." || strings.Contains(prefix, "..") {
		return "", ErrPrefix
	}
	if prefix != "Photos" && !strings.HasPrefix(prefix, "Photos/") {
		return "", ErrPrefix
	}
	if UnderDuplicates(prefix) {
		return "", ErrPrefix
	}
	return prefix, nil
}

// PlanProgress receives the counts so far. A nil function skips the calls.
type PlanProgress func(Counts)

// PlanPrefix writes planned rows for movable files under prefix.
// Every active member of a group uses that group's event folder.
// Planned rows outside the prefix are removed. Bytes stay where they are.
func PlanPrefix(catalog *db.Catalog, prefix string) (Counts, error) {
	return planPrefix(catalog, prefix, "", nil)
}

// PlanPrefixRoot is PlanPrefix, and it reads a header date when the stored capture does not already place the file.
// The picture is not decoded. An empty root skips the header read.
func PlanPrefixRoot(catalog *db.Catalog, prefix, root string) (Counts, error) {
	return planPrefix(catalog, prefix, root, nil)
}

// PlanPrefixRootProgress is PlanPrefixRoot, and it reports the four counts as each folder is counted.
func PlanPrefixRootProgress(catalog *db.Catalog, prefix, root string, progress PlanProgress) (Counts, error) {
	return planPrefix(catalog, prefix, root, progress)
}

func planPrefix(catalog *db.Catalog, prefix, root string, progress PlanProgress) (Counts, error) {
	prefix, err := CleanPrefix(prefix)
	if err != nil {
		return Counts{}, err
	}
	rows, err := catalog.Read.Query(`
		SELECT a.id, a.rel_path, a.reorg_policy, COALESCE(a.capture_source, ''),
			COALESCE(a.capture_time, ''), a.capture_confidence, a.byte_size, a.blake3, a.fast_fp,
			COALESCE(e.folder_rel, ''), a.derivative_group_id, a.placement, a.is_keeper
		FROM assets a
		LEFT JOIN events e ON e.id = a.event_id
		WHERE a.reorg_policy = 'move'
		ORDER BY a.id`)
	if err != nil {
		return Counts{}, err
	}
	var list []planRow
	for rows.Next() {
		var item planRow
		if err := rows.Scan(&item.id, &item.rel, &item.policy, &item.source, &item.capture, &item.confidence, &item.bytes, &item.blake, &item.fast, &item.folder, &item.groupID, &item.placement, &item.keeper); err != nil {
			rows.Close()
			return Counts{}, err
		}
		list = append(list, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return Counts{}, err
	}
	rows.Close()

	occupied, err := occupiedPaths(catalog)
	if err != nil {
		return Counts{}, err
	}
	folders := groupFolders(list)
	var counts Counts
	if err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM assets
		WHERE reorg_policy = 'leave' AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\')`,
		prefix, likeUnder(prefix)).Scan(&counts.Leave); err != nil {
		return Counts{}, err
	}

	plannedAt := time.Now().UTC()
	now := plannedAt.Format(time.RFC3339)
	headers := headerSet{
		facts:      map[int64]Facts{},
		origCount:  map[string]int{},
		digCount:   map[string]int{},
		chgCount:   map[string]int{},
		videoCount: map[string]int{},
	}
	shown := counts
	reportPlan(progress, shown)
	byDir := map[string][]planRow{}
	var dirs []string
	for _, item := range list {
		if !underPrefix(item.rel, prefix) {
			continue
		}
		key := dirKey(item.rel)
		if _, ok := byDir[key]; !ok {
			dirs = append(dirs, key)
		}
		byDir[key] = append(byDir[key], item)
	}
	for _, key := range dirs {
		var needs []planRow
		for _, item := range byDir[key] {
			if needsHeader(root, item) {
				needs = append(needs, item)
				continue
			}
			shown.Seen++
			tallyPlan(&shown, item, folders, headers, plannedAt)
			reportPlan(progress, shown)
		}
		for _, item := range needs {
			absorbHeader(&headers, root, item)
			shown.Seen++
			reportPlan(progress, shown)
		}
		for _, item := range needs {
			tallyPlan(&shown, item, folders, headers, plannedAt)
			reportPlan(progress, shown)
		}
	}
	tx, err := catalog.Write.Begin()
	if err != nil {
		return Counts{}, err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`
		DELETE FROM journal
		WHERE job_kind = 'reorg' AND state = 'planned'
		AND src_rel != ? AND src_rel NOT LIKE ? ESCAPE '\'`, prefix, likeUnder(prefix)); err != nil {
		return Counts{}, err
	}
	for _, item := range list {
		if !underPrefix(item.rel, prefix) {
			continue
		}
		d := decisionForPlan(item, plannedAt)
		if facts, ok := headers.facts[item.id]; ok {
			fromFile := decideHeader(item, facts, plannedAt, headers)
			if fromFile.Places() && fromFile.Confidence >= d.Confidence {
				d = fromFile
			}
		}
		stored := decisionFromStored(item.capture, item.confidence, item.source)
		if item.source != "user" && d.Places() && !stored.Places() {
			if err := writeDecision(tx, item.id, d, "dated"); err != nil {
				return Counts{}, err
			}
		}
		dest, ok := destination(item, folders, d)
		if !ok {
			continue
		}
		dest = claim(dest, item.id, occupied)
		if err := upsertPlanned(tx, item, dest, now); err != nil {
			return Counts{}, err
		}
		if _, err := tx.Exec(`
			UPDATE assets
			SET phase = CASE WHEN phase IN ('placed', 'parked') THEN phase ELSE 'planned' END,
				updated_at = ?
			WHERE id = ?`, now, item.id); err != nil {
			return Counts{}, err
		}
		switch {
		case dest == item.rel:
			counts.AlreadyPlaced++
		case strings.Contains(dest, "/_Review/"):
			counts.Park++
		default:
			counts.Move++
		}
	}
	if err := tx.Commit(); err != nil {
		return Counts{}, err
	}
	counts.Seen = shown.Seen
	reportPlan(progress, counts)
	return counts, nil
}

func reportPlan(progress PlanProgress, counts Counts) {
	if progress != nil {
		progress(counts)
	}
}

func needsHeader(root string, item planRow) bool {
	if root == "" || item.source == "user" {
		return false
	}
	return !decisionFromStored(item.capture, item.confidence, item.source).Places()
}

func tallyPlan(counts *Counts, item planRow, folders map[int64]string, headers headerSet, now time.Time) {
	d := decisionForPlan(item, now)
	if facts, ok := headers.facts[item.id]; ok {
		fromFile := decideHeader(item, facts, now, headers)
		if fromFile.Places() && fromFile.Confidence >= d.Confidence {
			d = fromFile
		}
	}
	dest, ok := destination(item, folders, d)
	if !ok {
		return
	}
	switch {
	case dest == item.rel:
		counts.AlreadyPlaced++
	case strings.Contains(dest, "/_Review/"):
		counts.Park++
	default:
		counts.Move++
	}
}

// EnqueueUserDate stores a typed date at confidence 1 and one planned journal row.
// It does not move the file and it does not set an event name_source.
func EnqueueUserDate(catalog *db.Catalog, assetID int64, d Decision) error {
	var rel, policy, phase string
	var bytes int64
	err := catalog.Read.QueryRow(`
		SELECT rel_path, reorg_policy, byte_size, phase FROM assets WHERE id = ?`, assetID).
		Scan(&rel, &policy, &bytes, &phase)
	if err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := writeDecision(tx, assetID, d, "dated"); err != nil {
		return err
	}
	if policy == "move" && !UnderDuplicates(rel) {
		dest, ok := PlannedPath(rel, policy, "", ReviewBucket(nil, rel), d)
		if ok {
			var taken int
			err = tx.QueryRow(`
				SELECT COUNT(*) FROM assets WHERE rel_path = ? AND id != ?`, dest, assetID).Scan(&taken)
			if err != nil {
				return err
			}
			if taken > 0 {
				base := dest
				if i := lastSlash(dest); i >= 0 {
					base = dest[i+1:]
					dest = dest[:i] + "/" + CollisionName(base, 2)
				} else {
					dest = CollisionName(base, 2)
				}
			}
			if err := upsertPlanned(tx, planRow{id: assetID, rel: rel, bytes: bytes}, dest, now); err != nil {
				return err
			}
			if _, err := tx.Exec(`
				UPDATE assets
				SET phase = CASE WHEN phase IN ('placed', 'parked') THEN phase ELSE 'planned' END,
					updated_at = ?
				WHERE id = ?`, now, assetID); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

// decisionForPlan keeps a date that already places the file.
// A blank catalog date still uses a full date in the filename or path.
type headerSet struct {
	facts      map[int64]Facts
	origCount  map[string]int
	digCount   map[string]int
	chgCount   map[string]int
	videoCount map[string]int
}

func absorbHeader(set *headerSet, root string, item planRow) {
	if root == "" || item.source == "user" {
		return
	}
	if decisionFromStored(item.capture, item.confidence, item.source).Places() {
		return
	}
	facts, ok := factsFor(root, item.rel)
	if !ok {
		return
	}
	set.facts[item.id] = facts
	if facts.Original != nil {
		set.origCount[dirKey(item.rel)+"|"+facts.Original.Time.Format(time.RFC3339Nano)]++
	}
	if facts.Digitized != nil {
		set.digCount[dirKey(item.rel)+"|"+facts.Digitized.Time.Format(time.RFC3339Nano)]++
	}
	if facts.DateTime != nil {
		set.chgCount[dirKey(item.rel)+"|"+facts.DateTime.Time.Format(time.RFC3339Nano)]++
	}
	if facts.Video != nil {
		set.videoCount[dirKey(item.rel)+"|"+facts.Video.Time.Format(time.RFC3339Nano)]++
	}
}

func decideHeader(item planRow, facts Facts, now time.Time, set headerSet) Decision {
	in := Input{RelPath: item.rel, Now: now}
	in.EXIFOriginal = facts.Original
	in.EXIFDigitized = facts.Digitized
	in.EXIFDateTime = facts.DateTime
	if facts.Original != nil {
		in.SameOriginal = set.origCount[dirKey(item.rel)+"|"+facts.Original.Time.Format(time.RFC3339Nano)]
	}
	if facts.Digitized != nil {
		in.SameDigitized = set.digCount[dirKey(item.rel)+"|"+facts.Digitized.Time.Format(time.RFC3339Nano)]
	}
	if facts.DateTime != nil {
		in.SameChanged = set.chgCount[dirKey(item.rel)+"|"+facts.DateTime.Time.Format(time.RFC3339Nano)]
	}
	if facts.Video != nil {
		in.VideoCreated = facts.Video
		in.SameVideo = set.videoCount[dirKey(item.rel)+"|"+facts.Video.Time.Format(time.RFC3339Nano)]
	}
	return Decide(in)
}

func decisionForPlan(item planRow, now time.Time) Decision {
	stored := decisionFromStored(item.capture, item.confidence, item.source)
	if item.source == "user" || stored.Places() {
		return stored
	}
	fromPath := Decide(Input{RelPath: item.rel, Now: now})
	if fromPath.Places() {
		return fromPath
	}
	if stored.Confidence >= fromPath.Confidence {
		return stored
	}
	return fromPath
}

func destination(item planRow, folders map[int64]string, d Decision) (string, bool) {
	folder := item.folder
	if item.placement == "active" && item.groupID.Valid {
		if shared, ok := folders[item.groupID.Int64]; ok && shared != "" {
			folder = shared
		}
	}
	sum := item.blake
	if len(sum) == 0 {
		sum = item.fast
	}
	return PlannedPath(item.rel, item.policy, folder, ReviewBucket(sum, item.rel), d)
}

func groupFolders(list []planRow) map[int64]string {
	folders := map[int64]string{}
	keepers := map[int64]string{}
	for _, item := range list {
		if !item.groupID.Valid || item.placement != "active" || item.folder == "" || UnderDuplicates(item.folder) {
			continue
		}
		if _, ok := folders[item.groupID.Int64]; !ok {
			folders[item.groupID.Int64] = item.folder
		}
		if item.keeper == 1 {
			keepers[item.groupID.Int64] = item.folder
		}
	}
	for id, folder := range keepers {
		folders[id] = folder
	}
	return folders
}

func occupiedPaths(catalog *db.Catalog) (map[string]int64, error) {
	rows, err := catalog.Read.Query(`SELECT id, rel_path FROM assets`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	occupied := map[string]int64{}
	for rows.Next() {
		var id int64
		var rel string
		if err := rows.Scan(&id, &rel); err != nil {
			return nil, err
		}
		occupied[rel] = id
	}
	return occupied, rows.Err()
}

func underPrefix(rel, prefix string) bool {
	rel = path.Clean(strings.TrimPrefix(rel, "/"))
	return rel == prefix || strings.HasPrefix(rel, prefix+"/")
}

func likeUnder(prefix string) string {
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(prefix)
	return escaped + "/%"
}

func decisionFromStored(capture string, confidence float64, source string) Decision {
	d := Decision{Confidence: confidence, Source: source}
	if len(capture) == 4 {
		year := 0
		for _, c := range capture {
			if c < '0' || c > '9' {
				return d
			}
			year = year*10 + int(c-'0')
		}
		d.HasCapture = true
		d.YearOnly = true
		d.Year = year
		d.Capture = time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC)
		return d
	}
	if capture == "" {
		return d
	}
	when, err := time.Parse(time.RFC3339, capture)
	if err != nil {
		return d
	}
	d.HasCapture = true
	d.FullDay = true
	d.Capture = when
	d.Year = when.Year()
	return d
}

func claim(dest string, id int64, occupied map[string]int64) string {
	base := dest
	name := dest
	dir := ""
	if i := lastSlash(dest); i >= 0 {
		dir = dest[:i]
		name = dest[i+1:]
	}
	for n := 1; ; n++ {
		candidate := name
		if n > 1 {
			candidate = CollisionName(name, n)
		}
		path := candidate
		if dir != "" {
			path = dir + "/" + candidate
		}
		owner, taken := occupied[path]
		if !taken || owner == id {
			occupied[path] = id
			return path
		}
		if path == base && owner == id {
			return path
		}
	}
}

func lastSlash(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '/' {
			return i
		}
	}
	return -1
}

func upsertPlanned(tx *sql.Tx, item planRow, dest, now string) error {
	var state string
	err := tx.QueryRow(`
		SELECT state FROM journal
		WHERE asset_id = ? AND job_kind = 'reorg' AND state NOT IN ('done', 'failed')
		ORDER BY id DESC LIMIT 1`, item.id).Scan(&state)
	if err == sql.ErrNoRows {
		// A planned row whose src_rel equals dest_rel is already in place and must not be copied.
		_, err = tx.Exec(`
			INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
			VALUES (?, 'reorg', 'planned', ?, ?, ?, ?)`,
			item.id, item.rel, dest, item.bytes, now)
		return err
	}
	if err != nil {
		return err
	}
	if state != "planned" {
		return nil
	}
	_, err = tx.Exec(`
		UPDATE journal
		SET src_rel = ?, dest_rel = ?, byte_size = ?, updated_at = ?
		WHERE asset_id = ? AND job_kind = 'reorg' AND state = 'planned'`,
		item.rel, dest, item.bytes, now, item.id)
	return err
}
