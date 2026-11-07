package cacheledger

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/db"
)

func TestCapEvictsOrRefusesAndNeverExceeds(t *testing.T) {
	root := t.TempDir()
	catalog := openLedger(t, root)
	limits := Limits{Operating: 1_000_000, Hard: 1_000_000}
	first := bytes.Repeat([]byte("a"), 600_000)
	second := bytes.Repeat([]byte("b"), 600_000)
	tooBig := bytes.Repeat([]byte("c"), 1_000_001)
	if err := Put(root, catalog, ".zimage/cache/thumbs/aa/a.jpg", "thumbnail", 1, first, limits); err != nil {
		t.Fatal(err)
	}
	if sum := ledgerSum(t, catalog); sum != 600_000 || sum > limits.Hard {
		t.Fatalf("sum %d", sum)
	}
	if err := Put(root, catalog, ".zimage/cache/thumbs/bb/b.jpg", "thumbnail", 2, second, limits); err != nil {
		t.Fatal(err)
	}
	if sum := ledgerSum(t, catalog); sum != 600_000 || sum > limits.Hard {
		t.Fatalf("after eviction %d", sum)
	}
	if _, err := os.Stat(filepath.Join(root, ".zimage/cache/thumbs/aa/a.jpg")); !os.IsNotExist(err) {
		t.Fatal("first thumbnail should have been evicted")
	}
	if _, err := os.Stat(filepath.Join(root, ".zimage/cache/thumbs/bb/b.jpg")); err != nil {
		t.Fatal(err)
	}
	if err := Put(root, catalog, ".zimage/cache/thumbs/cc/c.jpg", "thumbnail", 3, tooBig, limits); err != ErrRefuse {
		t.Fatalf("refuse %v", err)
	}
	if sum := ledgerSum(t, catalog); sum != 600_000 || sum > limits.Hard {
		t.Fatalf("after refuse %d", sum)
	}
	scratch := bytes.Repeat([]byte("s"), int(scratchMax)+1)
	if err := Put(root, catalog, ".zimage/cache/scratch/big.bin", "scratch", 0, scratch, Limits{}); err != ErrRefuse {
		t.Fatalf("scratch %v", err)
	}
}

func TestEvictsScratchBeforeEmbeddings(t *testing.T) {
	root := t.TempDir()
	catalog := openLedger(t, root)
	limits := Limits{Operating: 1_000, Hard: 5_000}
	if err := Put(root, catalog, ".zimage/cache/scratch/s.bin", "scratch", 0, bytes.Repeat([]byte("s"), 400), limits); err != nil {
		t.Fatal(err)
	}
	if err := Put(root, catalog, ".zimage/cache/embeddings/e.bin", "embedding", 0, bytes.Repeat([]byte("e"), 400), limits); err != nil {
		t.Fatal(err)
	}
	if err := Put(root, catalog, ".zimage/cache/thumbs/tt/t.jpg", "thumbnail", 1, bytes.Repeat([]byte("t"), 400), limits); err != nil {
		t.Fatal(err)
	}
	if err := Put(root, catalog, ".zimage/cache/thumbs/uu/u.jpg", "thumbnail", 2, bytes.Repeat([]byte("u"), 400), limits); err != nil {
		t.Fatal(err)
	}
	if sum := ledgerSum(t, catalog); sum > limits.Hard || sum >= limits.Operating {
		t.Fatalf("sum %d", sum)
	}
	if _, err := os.Stat(filepath.Join(root, ".zimage/cache/scratch/s.bin")); !os.IsNotExist(err) {
		t.Fatal("scratch should go first")
	}
	if _, err := os.Stat(filepath.Join(root, ".zimage/cache/embeddings/e.bin")); !os.IsNotExist(err) {
		t.Fatal("embedding should go before thumbnails")
	}
	if _, err := os.Stat(filepath.Join(root, ".zimage/cache/thumbs/tt/t.jpg")); err != nil {
		t.Fatal(err)
	}
}

func TestReconcileDropsScratchAndKeepsMoveBackup(t *testing.T) {
	root := t.TempDir()
	catalog := openLedger(t, root)
	scratch := filepath.Join(root, ".zimage", "cache", "scratch", "left.bin")
	backup := filepath.Join(root, ".zimage", "move-backup", "7")
	catalogNote := filepath.Join(root, ".zimage", "catalog", "note.txt")
	for _, path := range []string{scratch, backup, catalogNote} {
		if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(scratch, []byte("scratch"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(backup, []byte("backup"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(catalogNote, []byte("db"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at)
		VALUES ('asset-1', 'Photos/1999/a.jpg', 6, 'jpg', 'image', 'move', 'discovered', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, backup_rel, updated_at)
		VALUES (1, 'reorg', 'source_detached', 'Photos/1999/a.jpg', 'Photos/2020/a.jpg', 6, '.zimage/move-backup/7', '2026-11-05T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO cache_objects (rel_path, class, bytes, last_access)
		VALUES ('.zimage/move-backup/7', 'scratch', 6, '2026-11-05T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if err := Reconcile(root, catalog, Limits{}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(scratch); !os.IsNotExist(err) {
		t.Fatal("unreferenced scratch should be gone")
	}
	got, err := os.ReadFile(backup)
	if err != nil || string(got) != "backup" {
		t.Fatalf("backup %q %v", got, err)
	}
	note, err := os.ReadFile(catalogNote)
	if err != nil || string(note) != "db" {
		t.Fatalf("catalog %q %v", note, err)
	}
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM cache_objects WHERE rel_path = '.zimage/move-backup/7'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatal("move-backup must leave the ledger without being deleted")
	}
}

func TestReconcileRemembersAThumbWithoutRewritingIt(t *testing.T) {
	root := t.TempDir()
	catalog := openLedger(t, root)
	rel := ".zimage/cache/thumbs/ab/one.jpg"
	full := filepath.Join(root, filepath.FromSlash(rel))
	payload := []byte("preview-bytes")
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(full)
	if err != nil {
		t.Fatal(err)
	}
	if err := Reconcile(root, catalog, Limits{}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(full)
	if err != nil || string(got) != string(payload) {
		t.Fatalf("thumb %q %v", got, err)
	}
	after, err := os.Stat(full)
	if err != nil {
		t.Fatal(err)
	}
	if !before.ModTime().Equal(after.ModTime()) || before.Size() != after.Size() {
		t.Fatal("thumb was rewritten")
	}
	var class string
	var size int64
	var rows int
	if err := catalog.Read.QueryRow(`SELECT class, bytes FROM cache_objects WHERE rel_path = ?`, rel).Scan(&class, &size); err != nil {
		t.Fatal(err)
	}
	if class != "thumbnail" || size != int64(len(payload)) {
		t.Fatalf("ledger %s %d", class, size)
	}
	if err := Reconcile(root, catalog, Limits{}); err != nil {
		t.Fatal(err)
	}
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM cache_objects WHERE rel_path = ?`, rel).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("rows %d %v", rows, err)
	}

	over := filepath.Join(root, ".zimage", "cache", "thumbs", "ab", "big.jpg")
	if err := os.WriteFile(over, []byte("0123456789abcdef"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Reconcile(root, catalog, Limits{Operating: 8, Hard: 8}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(over); !os.IsNotExist(err) {
		t.Fatal("over-cap thumb should be gone")
	}
}

func TestPutDoesNotUnlinkMoveBackup(t *testing.T) {
	root := t.TempDir()
	catalog := openLedger(t, root)
	backup := filepath.Join(root, ".zimage", "move-backup", "9")
	if err := os.MkdirAll(filepath.Dir(backup), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(backup, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO cache_objects (rel_path, class, bytes, last_access)
		VALUES ('.zimage/move-backup/9', 'scratch', 900000, '2026-11-05T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	err := Put(root, catalog, ".zimage/cache/thumbs/aa/a.jpg", "thumbnail", 1, bytes.Repeat([]byte("a"), 200_000), Limits{Operating: 1_000_000, Hard: 1_000_000})
	if err != ErrRefuse {
		t.Fatalf("expected refuse, got %v", err)
	}
	got, readErr := os.ReadFile(backup)
	if readErr != nil || string(got) != "keep" {
		t.Fatalf("backup %q %v", got, readErr)
	}
}

func openLedger(t *testing.T, root string) *db.Catalog {
	t.Helper()
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = catalog.Close() })
	return catalog
}

func ledgerSum(t *testing.T, catalog *db.Catalog) int64 {
	t.Helper()
	var sum int64
	if err := catalog.Read.QueryRow(`SELECT COALESCE(SUM(bytes), 0) FROM cache_objects`).Scan(&sum); err != nil {
		t.Fatal(err)
	}
	return sum
}
