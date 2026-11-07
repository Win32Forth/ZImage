package move

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/db"
)

func TestCrashTableFiveFiles(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	setPhase(t, catalog, "Photos")
	payloads := [][]byte{
		[]byte("planned-file-bytes"),
		[]byte("copying-file-bytes-which-are-longer"),
		[]byte("verified-file-bytes"),
		[]byte("catalog-file-bytes"),
		[]byte("detached-file-bytes"),
	}
	names := []string{"planned.jpg", "copying.jpg", "verified.jpg", "catalog.jpg", "detached.jpg"}
	states := []string{"planned", "copying", "dest_verified", "catalog_updated", "source_detached"}

	for i := range names {
		rel := "Photos/in/" + names[i]
		dest := "Photos/2020/2020-05-01/event/" + names[i]
		id := seed(t, root, catalog, rel, dest, payloads[i])
		runner := &Runner{Root: root, Catalog: catalog, After: crashAt(states[i])}
		err := runner.advance(id)
		if !errors.Is(err, ErrCrashed) {
			t.Fatalf("%s advance %v", names[i], err)
		}
		switch states[i] {
		case "planned":
			plantEmptyScratch(t, root, catalog, id)
			action, err := runner.RecoverID(id)
			if err != nil || action != actionPlannedKept {
				t.Fatalf("planned recovery %s %v", action, err)
			}
			assertBytes(t, root, rel, payloads[i])
			if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(dest))); !os.IsNotExist(err) {
				t.Fatal("planned created a destination")
			}
			assertState(t, catalog, id, "planned")
		case "copying":
			before, err := hashFile(filepath.Join(root, filepath.FromSlash(rel)))
			if err != nil {
				t.Fatal(err)
			}
			action, err := runner.RecoverID(id)
			if err != nil || action != actionScratchReset {
				t.Fatalf("copying recovery %s %v", action, err)
			}
			after, err := hashFile(filepath.Join(root, filepath.FromSlash(rel)))
			if err != nil || !bytes.Equal(before, after) {
				t.Fatal("source hash changed")
			}
			assertBytes(t, root, rel, payloads[i])
			assertState(t, catalog, id, "planned")
			if _, err := os.Stat(filepath.Join(root, ".zimage", "move-scratch", itoa(id))); !os.IsNotExist(err) {
				t.Fatal("scratch remained")
			}
		case "dest_verified":
			action, err := runner.RecoverID(id)
			if err != nil || action != actionCatalogUpdated {
				t.Fatalf("verified recovery %s %v", action, err)
			}
			assertRel(t, catalog, id, dest)
			assertBytes(t, root, rel, payloads[i])
			assertBytes(t, root, dest, payloads[i])
			assertState(t, catalog, id, "catalog_updated")
		case "catalog_updated":
			action, err := runner.RecoverID(id)
			if err != nil || action != actionSourceDetached {
				t.Fatalf("catalog recovery %s %v", action, err)
			}
			assertRel(t, catalog, id, dest)
			if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel))); !os.IsNotExist(err) {
				t.Fatal("source still in place")
			}
			assertBytes(t, root, dest, payloads[i])
			backup := filepath.Join(root, ".zimage", "move-backup", itoa(id))
			got, err := os.ReadFile(backup)
			if err != nil || !bytes.Equal(got, payloads[i]) {
				t.Fatalf("backup %v", err)
			}
			assertState(t, catalog, id, "source_detached")
		case "source_detached":
			if err := os.Remove(filepath.Join(root, filepath.FromSlash(dest))); err != nil {
				t.Fatal(err)
			}
			action, err := runner.RecoverID(id)
			if err != nil || action != actionSourceRestored {
				t.Fatalf("restore %s %v", action, err)
			}
			assertRel(t, catalog, id, rel)
			assertBytes(t, root, rel, payloads[i])
			if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(dest))); !os.IsNotExist(err) {
				t.Fatal("dest came back")
			}
			assertState(t, catalog, id, "planned")
		}
	}
}

func TestPauseDuringCopyKeepsRebootFalseUntilDone(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	setPhase(t, catalog, "Photos")
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running', safe_to_reboot = 0 WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	first := seed(t, root, catalog, "Photos/in/a.jpg", "Photos/out/a.jpg", []byte("first-file"))
	second := seed(t, root, catalog, "Photos/in/b.jpg", "Photos/out/b.jpg", []byte("second-file"))
	started := make(chan struct{})
	release := make(chan struct{})
	runner := &Runner{Root: root, Catalog: catalog, CopySleep: func() {
		close(started)
		<-release
	}}
	done := make(chan error, 1)
	go func() { done <- runner.loop() }()
	<-started
	safe, err := ReorgSafe(catalog)
	if err != nil || safe {
		t.Fatalf("safe during copy %v %v", safe, err)
	}
	if err := runner.Pause(); err != nil {
		t.Fatal(err)
	}
	safe, err = ReorgSafe(catalog)
	if err != nil || safe {
		t.Fatalf("safe while pausing %v %v", safe, err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	safe, err = ReorgSafe(catalog)
	if err != nil || !safe {
		t.Fatalf("safe after done %v %v", safe, err)
	}
	assertState(t, catalog, first, "done")
	assertBytes(t, root, "Photos/out/a.jpg", []byte("first-file"))
	assertState(t, catalog, second, "planned")
	assertBytes(t, root, "Photos/in/b.jpg", []byte("second-file"))
	if _, err := os.Stat(filepath.Join(root, "Photos", "out", "b.jpg")); !os.IsNotExist(err) {
		t.Fatal("second file moved")
	}
	var run string
	if err := catalog.Read.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = 'reorg'`).Scan(&run); err != nil || run != "paused" {
		t.Fatalf("run %s %v", run, err)
	}
}

func TestBootWithPauseDoesNotStartTheNextFile(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	setPhase(t, catalog, "Photos")
	first := seed(t, root, catalog, "Photos/in/a.jpg", "Photos/out/a.jpg", []byte("keep-first"))
	second := seed(t, root, catalog, "Photos/in/b.jpg", "Photos/out/b.jpg", []byte("keep-second"))
	runner := &Runner{Root: root, Catalog: catalog, After: crashAt("copying")}
	if err := runner.advance(first); !errors.Is(err, ErrCrashed) {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		UPDATE job_state SET run_state = 'pause_requested', pause_requested = 1, phase = 'Photos'
		WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	restarted := &Runner{Root: root, Catalog: catalog}
	if err := restarted.Boot(); err != nil {
		t.Fatal(err)
	}
	assertState(t, catalog, first, "planned")
	assertBytes(t, root, "Photos/in/a.jpg", []byte("keep-first"))
	assertState(t, catalog, second, "planned")
	assertBytes(t, root, "Photos/in/b.jpg", []byte("keep-second"))
	if _, err := os.Stat(filepath.Join(root, "Photos", "out", "b.jpg")); !os.IsNotExist(err) {
		t.Fatal("next file started")
	}
	var run string
	var pause int
	if err := catalog.Read.QueryRow(`SELECT run_state, pause_requested FROM job_state WHERE job_kind = 'reorg'`).Scan(&run, &pause); err != nil {
		t.Fatal(err)
	}
	if run != "paused" || pause != 1 {
		t.Fatalf("state %s pause %d", run, pause)
	}
}

func TestPlannedRowDoesNotClearRebootBit(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	id := seed(t, root, catalog, "Photos/in/a.jpg", "Photos/out/a.jpg", []byte("planned-only"))
	safe, err := ReorgSafe(catalog)
	if err != nil || !safe {
		t.Fatalf("planned %v %v", safe, err)
	}
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running' WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	safe, err = ReorgSafe(catalog)
	if err != nil || safe {
		t.Fatal("running should be unsafe")
	}
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'idle' WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE journal SET state = 'copying' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	safe, err = ReorgSafe(catalog)
	if err != nil || safe {
		t.Fatal("open row should be unsafe")
	}
}

func TestSecondOpenRowFailsWithoutTouchingBytes(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	setPhase(t, catalog, "Photos")
	payload := []byte("untouched")
	id := seed(t, root, catalog, "Photos/in/a.jpg", "Photos/out/a.jpg", payload)
	var assetID int64
	if err := catalog.Read.QueryRow(`SELECT asset_id FROM journal WHERE id = ?`, id).Scan(&assetID); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (?, 'reorg', 'copying', 'Photos/in/a.jpg', 'Photos/out/a.jpg', ?, ?)`, assetID, len(payload), now); err != nil {
		t.Fatal(err)
	}
	runner := &Runner{Root: root, Catalog: catalog}
	if err := runner.advance(id); err != nil {
		t.Fatal(err)
	}
	assertState(t, catalog, id, "failed")
	assertBytes(t, root, "Photos/in/a.jpg", payload)
	if _, err := os.Stat(filepath.Join(root, "Photos", "out", "a.jpg")); !os.IsNotExist(err) {
		t.Fatal("bytes were copied")
	}
}

func TestDestinationUnderDuplicatesIsRejected(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	payload := []byte("stay")
	id := seed(t, root, catalog, "Photos/in/a.jpg", "Photos/_Duplicates/g/a.jpg", payload)
	runner := &Runner{Root: root, Catalog: catalog}
	if err := runner.advance(id); err != nil {
		t.Fatal(err)
	}
	assertState(t, catalog, id, "failed")
	assertBytes(t, root, "Photos/in/a.jpg", payload)
}

func TestMoveOneFile(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	setPhase(t, catalog, "Photos")
	payload := []byte("moved-bytes")
	id := seed(t, root, catalog, "Photos/in/a.jpg", "Photos/out/a.jpg", payload)
	runner := &Runner{Root: root, Catalog: catalog}
	if err := runner.advance(id); err != nil {
		t.Fatal(err)
	}
	assertState(t, catalog, id, "done")
	assertRel(t, catalog, id, "Photos/out/a.jpg")
	assertBytes(t, root, "Photos/out/a.jpg", payload)
	if _, err := os.Stat(filepath.Join(root, "Photos", "in", "a.jpg")); !os.IsNotExist(err) {
		t.Fatal("source remained")
	}
	if _, err := os.Stat(filepath.Join(root, ".zimage", "move-backup", itoa(id))); !os.IsNotExist(err) {
		t.Fatal("backup remained")
	}
	safe, err := ReorgSafe(catalog)
	if err != nil || !safe {
		t.Fatalf("safe %v %v", safe, err)
	}
}

func TestAlreadyPlacedSkipsTheCopy(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	payload := []byte("already")
	id := seed(t, root, catalog, "Photos/out/a.jpg", "Photos/out/a.jpg", payload)
	runner := &Runner{Root: root, Catalog: catalog}
	if err := runner.advance(id); err != nil {
		t.Fatal(err)
	}
	assertState(t, catalog, id, "done")
	assertBytes(t, root, "Photos/out/a.jpg", payload)
}

func crashAt(state string) func(string) error {
	return func(got string) error {
		if got == state {
			return ErrCrashed
		}
		return nil
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

func setPhase(t *testing.T, catalog *db.Catalog, phase string) {
	t.Helper()
	if _, err := catalog.Write.Exec(`UPDATE job_state SET phase = ? WHERE job_kind = 'reorg'`, phase); err != nil {
		t.Fatal(err)
	}
}

func seed(t *testing.T, root string, catalog *db.Catalog, rel, dest string, payload []byte) int64 {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	res, err := catalog.Write.Exec(`
		INSERT INTO assets (uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at)
		VALUES (?, ?, ?, 'jpg', 'image', 'move', 'discovered', ?, ?)`,
		rel, rel, len(payload), now, now)
	if err != nil {
		t.Fatal(err)
	}
	assetID, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	res, err = catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (?, 'reorg', 'planned', ?, ?, ?, ?)`, assetID, rel, dest, len(payload), now)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func plantEmptyScratch(t *testing.T, root string, catalog *db.Catalog, id int64) {
	t.Helper()
	rel := scratchRelFor(id)
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE journal SET scratch_rel = ? WHERE id = ?`, rel, id); err != nil {
		t.Fatal(err)
	}
}

func assertBytes(t *testing.T, root, rel string, payload []byte) {
	t.Helper()
	got, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("%s bytes %q", rel, got)
	}
}

func assertState(t *testing.T, catalog *db.Catalog, id int64, state string) {
	t.Helper()
	var got string
	if err := catalog.Read.QueryRow(`SELECT state FROM journal WHERE id = ?`, id).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != state {
		t.Fatalf("state %s", got)
	}
}

func assertRel(t *testing.T, catalog *db.Catalog, journalID int64, rel string) {
	t.Helper()
	var got string
	if err := catalog.Read.QueryRow(`
		SELECT rel_path FROM assets WHERE id = (SELECT asset_id FROM journal WHERE id = ?)`, journalID).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != rel {
		t.Fatalf("rel %s", got)
	}
}

func itoa(id int64) string {
	return filepath.Base(scratchRelFor(id))
}

func TestTrimQuiescentIgnoresThePauseFlag(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	ok, err := TrimQuiescent(catalog)
	if err != nil || !ok {
		t.Fatal(ok, err)
	}
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running', pause_requested = 0 WHERE job_kind = 'trim'`); err != nil {
		t.Fatal(err)
	}
	ok, err = TrimQuiescent(catalog)
	if err != nil || ok {
		t.Fatal("running trim")
	}
	var pause int
	if err := catalog.Read.QueryRow(`SELECT pause_requested FROM job_state WHERE job_kind = 'trim'`).Scan(&pause); err != nil || pause != 0 {
		t.Fatalf("pause flag %d %v", pause, err)
	}
	if _, err := dating.CleanPrefix("Audio"); err == nil {
		t.Fatal("audio prefix")
	}
}
