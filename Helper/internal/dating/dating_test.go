package dating

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/dhashindex"
)

func TestFilenameDateScoresEighty(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	d := Decide(Input{RelPath: "Photos/trip/2020-05-01.jpg", Now: now})
	if d.Confidence != ConfidenceFilename || d.Source != "filename" || !d.FullDay {
		t.Fatalf("%+v", d)
	}
	if d.Capture.Format("2006-01-02") != "2020-05-01" {
		t.Fatal(d.Capture)
	}
}

func TestUserDateAcceptsACalendarDay(t *testing.T) {
	d, ok := User("2010-07-17")
	if !ok || d.Source != "user" || d.Confidence != ConfidenceUser || !d.FullDay || d.StoredTime() != "2010-07-17T00:00:00Z" {
		t.Fatalf("%+v %v", d, ok)
	}
	if _, ok := User("2010-02-31"); ok {
		t.Fatal("invalid day accepted")
	}
	year, ok := User("2010")
	if !ok || !year.YearOnly || year.StoredTime() != "2010" {
		t.Fatalf("%+v %v", year, ok)
	}
}

func TestPathDateUsesTheFolderClosestToTheFile(t *testing.T) {
	now := time.Date(2026, 11, 5, 0, 0, 0, 0, time.UTC)
	rel := "Photos/2010/20100714_27 Minnisota trip/20100717_100SSCAM day 4/SDC13577.MP4"
	d := Decide(Input{RelPath: rel, Now: now})
	if d.Confidence != ConfidenceFilename || d.Source != "filename" || d.Capture.Format("2006-01-02") != "2010-07-17" {
		t.Fatalf("%+v", d)
	}
	named := Decide(Input{RelPath: "Photos/2010/20100714_trip/clip_20100718.mp4", Now: now})
	if named.Capture.Format("2006-01-02") != "2010-07-18" {
		t.Fatal(named.Capture)
	}
	withVideo := Decide(Input{
		RelPath:      rel,
		Now:          now,
		VideoCreated: &Stamp{Time: time.Date(2010, 7, 17, 14, 21, 17, 0, time.UTC)},
	})
	if withVideo.Source != "video_created" || withVideo.Confidence != ConfidenceVideoCreated {
		t.Fatalf("%+v", withVideo)
	}
}

func TestEpochDumpStaysBelowPlacement(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	solo := filepath.Join(root, "Photos", "Albums", "solo.jpg")
	writeExifJPEG(t, solo, "2010:06:15 08:30:00")
	insertRow(t, catalog, "solo", "Photos/Albums/solo.jpg")
	for i := 0; i < 30; i++ {
		rel := "Photos/1969-12-31/dump" + itoa(int64(i)) + ".jpg"
		writeExifJPEG(t, filepath.Join(root, filepath.FromSlash(rel)), "1969:12:31 12:00:00")
		insertRow(t, catalog, "dump"+itoa(int64(i)), rel)
	}
	if err := Assign(root, catalog, Options{Now: time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)}); err != nil {
		t.Fatal(err)
	}
	var conf float64
	var source string
	if err := catalog.Read.QueryRow(`SELECT capture_confidence, COALESCE(capture_source, '') FROM assets WHERE uid = 'solo'`).Scan(&conf, &source); err != nil {
		t.Fatal(err)
	}
	if conf != ConfidenceEXIFOriginal || source != "exif_original" {
		t.Fatalf("solo %v %s", conf, source)
	}
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE uid LIKE 'dump%' AND capture_confidence < ?`, PlacementThreshold).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 30 {
		t.Fatalf("parked %d", n)
	}
}

func TestInheritDoesNotChain(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	a := insertRow(t, catalog, "aaaa", "Photos/a.jpg")
	b := insertRow(t, catalog, "bbbb", "Photos/b.jpg")
	c := insertRow(t, catalog, "cccc", "Photos/c.jpg")
	// A and B share a band at distance 8. C is within 8 of B and outside 8 of A.
	setHash(t, catalog, a, 0)
	setHash(t, catalog, b, 0xFF)
	setHash(t, catalog, c, 0x37F)
	when := "2020-05-01T12:00:00Z"
	if _, err := catalog.Write.Exec(`UPDATE assets SET capture_time = ?, capture_confidence = 0.95, capture_source = 'exif_original' WHERE id = ?`, when, a); err != nil {
		t.Fatal(err)
	}
	if err := InheritNeighbors(catalog, Options{}); err != nil {
		t.Fatal(err)
	}
	var source string
	var conf float64
	var captured string
	if err := catalog.Read.QueryRow(`SELECT COALESCE(capture_source, ''), capture_confidence, COALESCE(capture_time, '') FROM assets WHERE id = ?`, b).Scan(&source, &conf, &captured); err != nil {
		t.Fatal(err)
	}
	if source != "dhash" || conf < 0.79 || conf > 0.81 || captured != when {
		t.Fatalf("hop %s %v %s", source, conf, captured)
	}
	if err := catalog.Read.QueryRow(`SELECT COALESCE(capture_source, ''), capture_confidence FROM assets WHERE id = ?`, c).Scan(&source, &conf); err != nil {
		t.Fatal(err)
	}
	if source == "dhash" || conf >= PlacementThreshold {
		t.Fatalf("chained %s %v", source, conf)
	}
	if err := InheritNeighbors(catalog, Options{}); err != nil {
		t.Fatal(err)
	}
	if err := catalog.Read.QueryRow(`SELECT capture_confidence, COALESCE(capture_source, '') FROM assets WHERE id = ?`, b).Scan(&conf, &source); err != nil {
		t.Fatal(err)
	}
	if conf < 0.79 || conf > 0.81 || source != "dhash" {
		t.Fatalf("second pass %v %s", conf, source)
	}
}

func TestPlanKeepsBytesAndSkipsTheStore(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	rel := "Photos/old/a.jpg"
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	payload := []byte("keep-these-bytes")
	if err := os.WriteFile(full, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	id := insertRow(t, catalog, "keep", rel)
	dup := insertRow(t, catalog, "dup", "Photos/_Duplicates/ab/dup.jpg")
	other := insertRow(t, catalog, "other", "Photos/old/b.jpg")
	when := "2020-05-01T12:00:00Z"
	for _, asset := range []int64{id, other} {
		if _, err := catalog.Write.Exec(`UPDATE assets SET capture_time = ?, capture_confidence = 0.95, capture_source = 'exif_original' WHERE id = ?`, when, asset); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := catalog.Write.Exec(`UPDATE assets SET capture_time = ?, capture_confidence = 0.95, capture_source = 'exif_original' WHERE id = ?`, when, dup); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`INSERT INTO events (uid, name, name_source, slug, folder_rel) VALUES ('ev', 'Madrid', 'album', 'madrid', 'Photos/2020/2020-05-01/madrid')`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE assets SET event_id = (SELECT id FROM events WHERE uid = 'ev') WHERE id IN (?, ?)`, id, other); err != nil {
		t.Fatal(err)
	}
	if err := Plan(catalog); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(full)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(payload) {
		t.Fatalf("bytes changed %q", got)
	}
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE state = 'planned' AND dest_rel NOT LIKE '%/_Duplicates/%'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("plans %d", n)
	}
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE asset_id = ?`, dup).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatal("store was planned")
	}
	var dest string
	if err := catalog.Read.QueryRow(`SELECT dest_rel FROM journal WHERE asset_id = ?`, id).Scan(&dest); err != nil {
		t.Fatal(err)
	}
	if dest != "Photos/2020/2020-05-01/madrid/a.jpg" {
		t.Fatal(dest)
	}
}

func TestPlanPutsActiveMembersInTheEventFolder(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	keeper := insertRow(t, catalog, "keeper", "Photos/old/a.jpg")
	sibling := insertRow(t, catalog, "sibling", "Photos/elsewhere/b.jpg")
	when := "2020-05-01T12:00:00Z"
	for _, asset := range []int64{keeper, sibling} {
		if _, err := catalog.Write.Exec(`UPDATE assets SET capture_time = ?, capture_confidence = 0.95, capture_source = 'exif_original' WHERE id = ?`, when, asset); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := catalog.Write.Exec(`INSERT INTO events (uid, name, name_source, slug, folder_rel) VALUES ('ev', 'Madrid', 'album', 'madrid', 'Photos/2020/2020-05-01/madrid')`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`INSERT INTO derivative_groups (uid, eligible) VALUES ('g1', 1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		UPDATE assets
		SET derivative_group_id = (SELECT id FROM derivative_groups WHERE uid = 'g1'),
			event_id = (SELECT id FROM events WHERE uid = 'ev'),
			is_keeper = 1, placement = 'active'
		WHERE id = ?`, keeper); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		UPDATE assets
		SET derivative_group_id = (SELECT id FROM derivative_groups WHERE uid = 'g1'),
			is_keeper = 0, placement = 'active'
		WHERE id = ?`, sibling); err != nil {
		t.Fatal(err)
	}
	if err := Plan(catalog); err != nil {
		t.Fatal(err)
	}
	for _, asset := range []int64{keeper, sibling} {
		var dest string
		if err := catalog.Read.QueryRow(`SELECT dest_rel FROM journal WHERE asset_id = ?`, asset).Scan(&dest); err != nil {
			t.Fatal(err)
		}
		if dest != "Photos/2020/2020-05-01/madrid/a.jpg" && dest != "Photos/2020/2020-05-01/madrid/b.jpg" {
			t.Fatal(dest)
		}
	}
}

func TestPlanReadsAHEICHeader(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	rel := "Photos/_Review/Undated/e0/IMG_6462.HEIC"
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, sampleHEIC(sampleTIFFDate("2020:05:01 12:00:00")), 0o600); err != nil {
		t.Fatal(err)
	}
	id := insertRow(t, catalog, "heic", rel)
	kept := insertRow(t, catalog, "kept", "Photos/_Review/Undated/e0/kept.heic")
	if _, err := catalog.Write.Exec(`
		UPDATE assets SET capture_time = ?, capture_confidence = 0.95, capture_source = 'exif_original' WHERE id = ?`,
		"2010-01-02T00:00:00Z", kept); err != nil {
		t.Fatal(err)
	}
	counts, err := PlanPrefixRoot(catalog, "Photos/_Review", root)
	if err != nil {
		t.Fatal(err)
	}
	if counts.Move != 2 {
		t.Fatalf("counts %+v", counts)
	}
	var dest, source string
	var conf float64
	if err := catalog.Read.QueryRow(`SELECT dest_rel FROM journal WHERE asset_id = ?`, id).Scan(&dest); err != nil {
		t.Fatal(err)
	}
	if dest != "Photos/2020/2020-05-01/event/IMG_6462.HEIC" {
		t.Fatal(dest)
	}
	if err := catalog.Read.QueryRow(`
		SELECT capture_confidence, COALESCE(capture_source, '') FROM assets WHERE id = ?`, id).Scan(&conf, &source); err != nil {
		t.Fatal(err)
	}
	if conf != ConfidenceEXIFOriginal || source != "exif_original" {
		t.Fatalf("stored %v %s", conf, source)
	}
	if err := catalog.Read.QueryRow(`SELECT dest_rel FROM journal WHERE asset_id = ?`, kept).Scan(&dest); err != nil {
		t.Fatal(err)
	}
	if dest != "Photos/2010/2010-01-02/event/kept.heic" {
		t.Fatal(dest)
	}
}

func TestPlanUsesADateInTheFilename(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	dated := insertRow(t, catalog, "dated", "Photos/_Review/Undated/62/Syntek_USB Camera_1964-11-24_3725959643136.jpg")
	plain := insertRow(t, catalog, "plain", "Photos/_Review/Undated/62/IMG_3523_Original.jpg")
	kept := insertRow(t, catalog, "kept", "Photos/_Review/Undated/62/1964-11-24_kept.jpg")
	if _, err := catalog.Write.Exec(`
		UPDATE assets SET capture_time = ?, capture_confidence = 0.95, capture_source = 'exif_original' WHERE id = ?`,
		"2010-01-02T00:00:00Z", kept); err != nil {
		t.Fatal(err)
	}
	counts, err := PlanPrefix(catalog, "Photos/_Review")
	if err != nil {
		t.Fatal(err)
	}
	if counts.Move != 2 || counts.Park != 1 {
		t.Fatalf("counts %+v", counts)
	}
	var dest, source, captured string
	var conf float64
	if err := catalog.Read.QueryRow(`SELECT dest_rel FROM journal WHERE asset_id = ?`, dated).Scan(&dest); err != nil {
		t.Fatal(err)
	}
	if dest != "Photos/1964/1964-11-24/event/Syntek_USB Camera_1964-11-24_3725959643136.jpg" {
		t.Fatal(dest)
	}
	if err := catalog.Read.QueryRow(`
		SELECT capture_confidence, COALESCE(capture_source, ''), COALESCE(capture_time, '') FROM assets WHERE id = ?`, dated).Scan(&conf, &source, &captured); err != nil {
		t.Fatal(err)
	}
	if conf != ConfidenceFilename || source != "filename" || !strings.HasPrefix(captured, "1964-11-24") {
		t.Fatalf("stored %v %s %s", conf, source, captured)
	}
	if err := catalog.Read.QueryRow(`SELECT dest_rel FROM journal WHERE asset_id = ?`, plain).Scan(&dest); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(dest, "/_Review/") {
		t.Fatal(dest)
	}
	if err := catalog.Read.QueryRow(`SELECT dest_rel FROM journal WHERE asset_id = ?`, kept).Scan(&dest); err != nil {
		t.Fatal(err)
	}
	if dest != "Photos/2010/2010-01-02/event/1964-11-24_kept.jpg" {
		t.Fatal(dest)
	}
}

func TestPlanKeepsTheEventNameWrittenOnTheDayFolder(t *testing.T) {
	when := time.Date(2026, 3, 19, 0, 0, 0, 0, time.UTC)
	d := Decision{HasCapture: true, FullDay: true, Confidence: 0.80, Capture: when}
	dest, ok := PlannedPath("Photos/2026/2026-03-19 1970s Debbie portrait/Debbie.jpg", "move", "", "ab", d)
	if !ok || dest != "Photos/2026/2026-03-19/1970s Debbie portrait/Debbie.jpg" {
		t.Fatalf("portrait %v %s", ok, dest)
	}
	scans := d
	scans.Capture = time.Date(2026, 3, 20, 0, 0, 0, 0, time.UTC)
	dest, ok = PlannedPath("Photos/2026/2026-03-20 - 1970s scans/Scan.jpeg", "move", "", "ab", scans)
	if !ok || dest != "Photos/2026/2026-03-20/1970s scans/Scan.jpeg" {
		t.Fatalf("scans %v %s", ok, dest)
	}
	home := d
	home.Capture = time.Date(2026, 9, 23, 19, 3, 38, 0, time.UTC)
	dest, ok = PlannedPath("Photos/2026/2026-09-23 Bartlett Home Coming/IMG_5448.HEIC", "move", "", "ab", home)
	if !ok || dest != "Photos/2026/2026-09-23/Bartlett Home Coming/IMG_5448.HEIC" {
		t.Fatalf("home %v %s", ok, dest)
	}
	dest, ok = PlannedPath("Photos/2026/2026-03-19/1970s Debbie portrait/Debbie.jpg", "move", "Photos/2026/2026-03-19/1970s-debbie-portrait", "ab", d)
	if !ok || dest != "Photos/2026/2026-03-19/1970s Debbie portrait/Debbie.jpg" {
		t.Fatalf("slug %v %s", ok, dest)
	}
	dest, ok = PlannedPath("Photos/2026/2026-03-19/event/Debbie.jpg", "move", "", "ab", d)
	if !ok || dest != "Photos/2026/2026-03-19/event/Debbie.jpg" {
		t.Fatalf("placeholder %v %s", ok, dest)
	}
}

func TestReviewUpdatedIsNotAnEventName(t *testing.T) {
	when := time.Date(2010, 7, 17, 0, 0, 0, 0, time.UTC)
	day := Decision{HasCapture: true, FullDay: true, Confidence: 1, Capture: when}
	dest, ok := PlannedPath("Photos/_Review/Updated/photo.jpg", "move", "", "ab", day)
	if !ok || dest != "Photos/2010/2010-07-17/event/photo.jpg" {
		t.Fatalf("staging %v %s", ok, dest)
	}
	year := Decision{HasCapture: true, YearOnly: true, Year: 1964, Confidence: 1, Capture: time.Date(1964, 1, 1, 0, 0, 0, 0, time.UTC)}
	dest, ok = PlannedPath("Photos/_Review/Updated/photo.jpg", "move", "", "ab", year)
	if !ok || dest != "Photos/1964/_NoDay/event/photo.jpg" {
		t.Fatalf("year %v %s", ok, dest)
	}
	dest, ok = PlannedPath("Photos/_Review/Updated/Wedding/photo.jpg", "move", "", "ab", day)
	if !ok || dest != "Photos/2010/2010-07-17/Wedding/photo.jpg" {
		t.Fatalf("album %v %s", ok, dest)
	}
	dest, ok = PlannedPath("Photos/2010/2010-07-17/Updated/photo.jpg", "move", "", "ab", day)
	if !ok || dest != "Photos/2010/2010-07-17/Updated/photo.jpg" {
		t.Fatalf("real folder %v %s", ok, dest)
	}
	if title, ok := AlbumTitleFromPath("Photos/_Review/Updated/photo.jpg"); ok {
		t.Fatal(title)
	}
}

func TestPlanPrefixFiltersAndRefusesTheStore(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	year := insertRow(t, catalog, "year", "Photos/2024/a.jpg")
	other := insertRow(t, catalog, "other", "Photos/1999/b.jpg")
	dup := insertRow(t, catalog, "dup", "Photos/_Duplicates/ab/dup.jpg")
	when := "2024-06-01T12:00:00Z"
	for _, asset := range []int64{year, other, dup} {
		if _, err := catalog.Write.Exec(`UPDATE assets SET capture_time = ?, capture_confidence = 0.95, capture_source = 'exif_original' WHERE id = ?`, when, asset); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at)
		VALUES ('clip', 'Photos/2024/clip.mp4', 20, 'mp4', 'video', 'leave', 'discovered', ?, ?)`, now, now); err != nil {
		t.Fatal(err)
	}
	counts, err := PlanPrefix(catalog, "Photos/2024")
	if err != nil {
		t.Fatal(err)
	}
	if counts.Move != 1 || counts.Leave != 1 {
		t.Fatalf("counts %+v", counts)
	}
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE asset_id = ?`, other).Scan(&n); err != nil || n != 0 {
		t.Fatalf("outside prefix %d %v", n, err)
	}
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE asset_id = ?`, dup).Scan(&n); err != nil || n != 0 {
		t.Fatalf("store row %d %v", n, err)
	}
	if _, err := PlanPrefix(catalog, "Audio"); !errors.Is(err, ErrPrefix) {
		t.Fatal(err)
	}
	if _, err := PlanPrefix(catalog, "Photos/_Duplicates"); !errors.Is(err, ErrPrefix) {
		t.Fatal(err)
	}
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE asset_id = ?`, dup).Scan(&n); err != nil || n != 0 {
		t.Fatal("store gained a row")
	}
	_, ok := PlannedPath("Photos/a.jpg", "move", "Photos/_Duplicates/group", "ab", Decision{HasCapture: true, FullDay: true, Confidence: 0.95, Capture: time.Date(2020, 5, 1, 0, 0, 0, 0, time.UTC)})
	if ok {
		t.Fatal("destination in the store")
	}
}

func TestPlanLeavesTheRemovedFolder(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	id := insertRow(t, catalog, "parked", "Photos/_Removed/parked.jpg")
	when := "2024-06-01T12:00:00Z"
	if _, err := catalog.Write.Exec(`UPDATE assets SET capture_time = ?, capture_confidence = 0.95, capture_source = 'exif_original' WHERE id = ?`, when, id); err != nil {
		t.Fatal(err)
	}
	counts, err := PlanPrefix(catalog, "Photos")
	if err != nil {
		t.Fatal(err)
	}
	if counts.Move != 0 || counts.Park != 0 || counts.AlreadyPlaced != 0 {
		t.Fatalf("counts %+v", counts)
	}
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE asset_id = ?`, id).Scan(&n); err != nil || n != 0 {
		t.Fatalf("parked row %d %v", n, err)
	}
	if _, err := PlanPrefix(catalog, "Photos/_Removed"); !errors.Is(err, ErrPrefix) {
		t.Fatal(err)
	}
	_, ok := PlannedPath("Photos/_Removed/parked.jpg", "move", "", "ab", Decision{HasCapture: true, FullDay: true, Confidence: 0.95, Capture: time.Date(2024, 6, 1, 0, 0, 0, 0, time.UTC)})
	if ok {
		t.Fatal("removed folder was planned")
	}
}

func TestDatingPackageDoesNotDelete(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		body, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		text := string(body)
		if strings.Contains(text, "os.Remove") || strings.Contains(text, "RemoveAll") || strings.Contains(text, "unlink") {
			t.Fatalf("%s deletes a file", name)
		}
	}
}

func openCatalog(t *testing.T, root string) *db.Catalog {
	t.Helper()
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = catalog.Close() })
	return catalog
}

func insertRow(t *testing.T, catalog *db.Catalog, uid, rel string) int64 {
	t.Helper()
	now := time.Now().UTC().Format(time.RFC3339)
	res, err := catalog.Write.Exec(`
		INSERT INTO assets (uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at)
		VALUES (?, ?, 20, 'jpg', 'image', 'move', 'discovered', ?, ?)`, uid, rel, now, now)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func setHash(t *testing.T, catalog *db.Catalog, id int64, hash uint64) {
	t.Helper()
	bands := dhashindex.Bands(hash)
	_, err := catalog.Write.Exec(`
		UPDATE assets
		SET dhash = ?, dhash_b0 = ?, dhash_b1 = ?, dhash_b2 = ?, dhash_b3 = ?, dhash_b4 = ?, dhash_b5 = ?,
			width = 100, height = 100
		WHERE id = ?`,
		int64(hash), int64(bands[0]), int64(bands[1]), int64(bands[2]), int64(bands[3]), int64(bands[4]), int64(bands[5]), id)
	if err != nil {
		t.Fatal(err)
	}
}

func writeExifJPEG(t *testing.T, path, date string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	tiff := exifDateTIFF(date)
	payload := append([]byte("Exif\x00\x00"), tiff...)
	length := len(payload) + 2
	buf := []byte{0xFF, 0xD8, 0xFF, 0xE1, byte(length >> 8), byte(length)}
	buf = append(buf, payload...)
	buf = append(buf, 0xFF, 0xD9)
	if err := os.WriteFile(path, buf, 0o644); err != nil {
		t.Fatal(err)
	}
}

func exifDateTIFF(date string) []byte {
	ascii := append([]byte(date), 0)
	buf := make([]byte, 44+len(ascii))
	buf[0], buf[1] = 'I', 'I'
	binary.LittleEndian.PutUint16(buf[2:], 42)
	binary.LittleEndian.PutUint32(buf[4:], 8)
	binary.LittleEndian.PutUint16(buf[8:], 1)
	binary.LittleEndian.PutUint16(buf[10:], 0x8769)
	binary.LittleEndian.PutUint16(buf[12:], 4)
	binary.LittleEndian.PutUint32(buf[14:], 1)
	binary.LittleEndian.PutUint32(buf[18:], 26)
	binary.LittleEndian.PutUint16(buf[26:], 1)
	binary.LittleEndian.PutUint16(buf[28:], 0x9003)
	binary.LittleEndian.PutUint16(buf[30:], 2)
	binary.LittleEndian.PutUint32(buf[32:], uint32(len(ascii)))
	binary.LittleEndian.PutUint32(buf[36:], 44)
	copy(buf[44:], ascii)
	return buf
}
