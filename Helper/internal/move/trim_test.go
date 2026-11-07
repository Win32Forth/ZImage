package move

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/trim"
)

func TestTrimKeepsTheSharpFileAndSkipsANullScore(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	sharp := []byte("sharp-1000-bytes")
	large := []byte("large-4000-bytes-are-different")
	pinned := []byte("pinned-stays-in-the-event")
	group := insertGroup(t, catalog, "g1")
	insertMember(t, root, catalog, group, "a", "Photos/2020/event/a.jpg", sharp, 1_000_000, 10.0, 0)
	insertMember(t, root, catalog, group, "b", "Photos/2020/event/b.jpg", sharp, 1_000_000, 10.0, 0)
	insertMember(t, root, catalog, group, "c", "Photos/2020/event/c.jpg", large, 16_000_000, 10.0, 0)
	insertMember(t, root, catalog, group, "d", "Photos/2020/event/d.jpg", pinned, 4_000_000, 10.0, 1)

	nullGroup := insertGroup(t, catalog, "g2")
	for _, name := range []string{"e.jpg", "f.jpg", "g.jpg"} {
		insertMember(t, root, catalog, nullGroup, name, "Photos/2020/event/"+name, []byte(name), 1_000_000, 10.0, 0)
	}
	insertMember(t, root, catalog, nullGroup, "h.jpg", "Photos/2020/event/h.jpg", []byte("missing-score"), 16_000_000, nil, 0)

	if err := trim.Plan(catalog); err != nil {
		t.Fatal(err)
	}
	var nullRows int
	if err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal j
		JOIN assets a ON a.id = j.asset_id
		WHERE a.derivative_group_id = ?`, nullGroup).Scan(&nullRows); err != nil || nullRows != 0 {
		t.Fatalf("null group rows %d %v", nullRows, err)
	}
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running', safe_to_reboot = 0 WHERE job_kind = 'trim'`); err != nil {
		t.Fatal(err)
	}
	runner := &Runner{Root: root, Catalog: catalog, JobKind: "trim"}
	if err := runner.loop(); err != nil {
		t.Fatal(err)
	}

	assertBytes(t, root, "Photos/2020/event/a.jpg", sharp)
	assertBytes(t, root, "Photos/2020/event/d.jpg", pinned)
	assertBytes(t, root, "Photos/_Duplicates/g1/b.jpg", sharp)
	assertBytes(t, root, "Photos/_Duplicates/g1/c.jpg", large)
	assertJournalHash(t, root, catalog, "b", "Photos/_Duplicates/g1/b.jpg")
	assertJournalHash(t, root, catalog, "c", "Photos/_Duplicates/g1/c.jpg")
	if _, err := os.Stat(filepath.Join(root, "Photos", "2020", "event", "b.jpg")); !os.IsNotExist(err) {
		t.Fatal("copy stayed in the event folder")
	}
	for _, name := range []string{"e.jpg", "f.jpg", "g.jpg", "h.jpg"} {
		assertBytes(t, root, "Photos/2020/event/"+name, []byte(nameOrMissing(name)))
	}

	var keeperRel string
	var keeperFlag int
	if err := catalog.Read.QueryRow(`SELECT rel_path, is_keeper FROM assets WHERE uid = 'a'`).Scan(&keeperRel, &keeperFlag); err != nil {
		t.Fatal(err)
	}
	if keeperRel != "Photos/2020/event/a.jpg" || keeperFlag != 1 {
		t.Fatalf("keeper %s %d", keeperRel, keeperFlag)
	}
	assertPlacement(t, catalog, "b", "Photos/_Duplicates/g1/b.jpg", "duplicates", "same_resolution")
	assertPlacement(t, catalog, "c", "Photos/_Duplicates/g1/c.jpg", "duplicates", "trim")
	assertPlacement(t, catalog, "d", "Photos/2020/event/d.jpg", "active", "")
	var run string
	if err := catalog.Read.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = 'trim'`).Scan(&run); err != nil || run != "completed" {
		t.Fatalf("trim run %s %v", run, err)
	}
	safe, err := TrimLive(catalog)
	if err != nil || !safe {
		t.Fatalf("trim live %v %v", safe, err)
	}
	reorgSafe, err := ReorgSafe(catalog)
	if err != nil || !reorgSafe {
		t.Fatalf("reorg %v %v", reorgSafe, err)
	}
}

func TestTrimPauseDuringCopyLeavesTheReorgBit(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	sharp := []byte("sharp-1000-bytes")
	large := []byte("large-4000-bytes-are-different")
	group := insertGroup(t, catalog, "g1")
	insertMember(t, root, catalog, group, "a", "Photos/2020/event/a.jpg", sharp, 1_000_000, 10.0, 0)
	insertMember(t, root, catalog, group, "b", "Photos/2020/event/b.jpg", sharp, 1_000_000, 10.0, 0)
	insertMember(t, root, catalog, group, "c", "Photos/2020/event/c.jpg", large, 16_000_000, 10.0, 0)
	if err := trim.Plan(catalog); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running', safe_to_reboot = 0 WHERE job_kind = 'trim'`); err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	release := make(chan struct{})
	runner := &Runner{Root: root, Catalog: catalog, JobKind: "trim", CopySleep: func() {
		close(started)
		<-release
	}}
	done := make(chan error, 1)
	go func() { done <- runner.loop() }()
	<-started
	live, err := TrimLive(catalog)
	if err != nil || live {
		t.Fatalf("trim live during copy %v %v", live, err)
	}
	var stored int
	if err := catalog.Read.QueryRow(`SELECT safe_to_reboot FROM job_state WHERE job_kind = 'trim'`).Scan(&stored); err != nil || stored != 0 {
		t.Fatalf("stored trim bit %d %v", stored, err)
	}
	reorgSafe, err := ReorgSafe(catalog)
	if err != nil || !reorgSafe {
		t.Fatalf("reorg during trim copy %v %v", reorgSafe, err)
	}
	if err := runner.Pause(); err != nil {
		t.Fatal(err)
	}
	var reorgPause int
	if err := catalog.Read.QueryRow(`SELECT pause_requested FROM job_state WHERE job_kind = 'reorg'`).Scan(&reorgPause); err != nil || reorgPause != 0 {
		t.Fatalf("reorg pause %d %v", reorgPause, err)
	}
	live, err = TrimLive(catalog)
	if err != nil || live {
		t.Fatalf("trim live while pausing %v %v", live, err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	assertBytes(t, root, "Photos/_Duplicates/g1/b.jpg", sharp)
	assertBytes(t, root, "Photos/2020/event/c.jpg", large)
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "c.jpg")); !os.IsNotExist(err) {
		t.Fatal("second file moved after pause")
	}
	reorgSafe, err = ReorgSafe(catalog)
	if err != nil || !reorgSafe {
		t.Fatalf("reorg after pause %v %v", reorgSafe, err)
	}
}

func TestPurgeRecoveryUnlinksOnlyTheStore(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	store := []byte("store-file")
	year := []byte("year-file")
	writePayload(t, root, "Photos/_Duplicates/g1/dup.jpg", store)
	writePayload(t, root, "Photos/1999/keep.jpg", year)
	writePayload(t, root, "Photos/2020/event/keeper.jpg", []byte("keeper"))
	insertPlain(t, catalog, "dup", "Photos/_Duplicates/g1/dup.jpg", len(store))
	insertPlain(t, catalog, "keep", "Photos/1999/keep.jpg", len(year))
	insertPlain(t, catalog, "gone", "Photos/_Duplicates/g1/gone.jpg", 4)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (1, 'purge', 'purge_planned', 'Photos/_Duplicates/g1/dup.jpg', '', ?, ?)`, len(store), now); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (3, 'purge', 'unlinked', 'Photos/_Duplicates/g1/gone.jpg', '', 4, ?)`, now); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (2, 'purge', 'purge_planned', 'Photos/1999/keep.jpg', '', ?, ?)`, len(year), now); err != nil {
		t.Fatal(err)
	}
	runner := &Runner{Root: root, Catalog: catalog}
	if err := runner.Boot(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "dup.jpg")); !os.IsNotExist(err) {
		t.Fatal("store file remained")
	}
	assertBytes(t, root, "Photos/1999/keep.jpg", year)
	assertBytes(t, root, "Photos/2020/event/keeper.jpg", []byte("keeper"))
	assertPlacement(t, catalog, "dup", ".zimage/purged/dup", "purged", "")
	assertPlacement(t, catalog, "gone", ".zimage/purged/gone", "purged", "")
	assertPlacement(t, catalog, "keep", "Photos/1999/keep.jpg", "active", "")
	var state, code string
	if err := catalog.Read.QueryRow(`SELECT state, COALESCE(error, '') FROM journal WHERE asset_id = 2`).Scan(&state, &code); err != nil {
		t.Fatal(err)
	}
	if state != "failed" || code != "purge_refused" {
		t.Fatalf("year purge %s %s", state, code)
	}
	var dupState string
	if err := catalog.Read.QueryRow(`SELECT state FROM journal WHERE asset_id = 1`).Scan(&dupState); err != nil || dupState != "done" {
		t.Fatalf("store purge %s %v", dupState, err)
	}
}

func insertGroup(t *testing.T, catalog *db.Catalog, uid string) int64 {
	t.Helper()
	res, err := catalog.Write.Exec(`INSERT INTO derivative_groups (uid, eligible) VALUES (?, 0)`, uid)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func insertMember(t *testing.T, root string, catalog *db.Catalog, groupID int64, uid, rel string, payload []byte, pixels int64, score any, pinned int) {
	t.Helper()
	writePayload(t, root, rel, payload)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			derivative_group_id, native_pixels, detail_score, pinned, placement,
			discovered_at, updated_at
		) VALUES (?, ?, ?, 'jpg', 'image', 'move', 'discovered', ?, ?, ?, ?, 'active', ?, ?)`,
		uid, rel, len(payload), groupID, pixels, score, pinned, now, now)
	if err != nil {
		t.Fatal(err)
	}
}

func insertPlain(t *testing.T, catalog *db.Catalog, uid, rel string, size int) {
	t.Helper()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, placement,
			discovered_at, updated_at
		) VALUES (?, ?, ?, 'jpg', 'image', 'move', 'discovered', 'active', ?, ?)`,
		uid, rel, size, now, now)
	if err != nil {
		t.Fatal(err)
	}
}

func writePayload(t *testing.T, root, rel string, payload []byte) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, payload, 0o644); err != nil {
		t.Fatal(err)
	}
}

func assertJournalHash(t *testing.T, root string, catalog *db.Catalog, uid, rel string) {
	t.Helper()
	sum, err := hashFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	var stored []byte
	if err := catalog.Read.QueryRow(`
		SELECT j.blake3 FROM journal j JOIN assets a ON a.id = j.asset_id
		WHERE a.uid = ? AND j.state = 'done'`, uid).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(sum, stored) {
		t.Fatalf("%s hash", uid)
	}
}

func assertPlacement(t *testing.T, catalog *db.Catalog, uid, rel, placement, reason string) {
	t.Helper()
	var gotRel, gotPlace string
	var gotReason string
	if err := catalog.Read.QueryRow(`
		SELECT rel_path, placement, COALESCE(duplicate_reason, '') FROM assets WHERE uid = ?`, uid).Scan(&gotRel, &gotPlace, &gotReason); err != nil {
		t.Fatal(err)
	}
	if gotRel != rel || gotPlace != placement || gotReason != reason {
		t.Fatalf("%s path %s placement %s reason %s", uid, gotRel, gotPlace, gotReason)
	}
}

func nameOrMissing(name string) string {
	if name == "h.jpg" {
		return "missing-score"
	}
	return name
}
