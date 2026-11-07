package relink_test

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	"lukechampine.com/blake3"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/db"
	"zimage/helper/internal/inventory"
	"zimage/helper/internal/relink"
)

func TestFingerprintOverlapsShortFiles(t *testing.T) {
	root := t.TempDir()
	body := []byte("0123456789")
	path := filepath.Join(root, "short.bin")
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := relink.FingerprintFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := blake3.New(32, nil)
	_, _ = sum.Write(body)
	_, _ = sum.Write(body)
	if !bytes.Equal(got, sum.Sum(nil)) {
		t.Fatal("short fingerprint should hash the overlap twice")
	}
}

func TestRenameRelinksTheSameUID(t *testing.T) {
	root := t.TempDir()
	catalog := openRelink(t, root)
	body := bytes.Repeat([]byte("photo"), 300)
	from := filepath.Join(root, "Photos", "1999", "a.jpg")
	to := filepath.Join(root, "Photos", "1999", "b.jpg")
	writePhoto(t, from, body)
	fp := mustFP(t, from)
	insertAsset(t, catalog, "uid-a", "Photos/1999/a.jpg", int64(len(body)), fp, nil)
	if err := os.Rename(from, to); err != nil {
		t.Fatal(err)
	}
	if err := relink.Pass(root, catalog, relink.Options{}); err != nil {
		t.Fatal(err)
	}
	if _, err := inventory.Run(root, catalog, inventory.Options{}); err != nil {
		t.Fatal(err)
	}
	assertOne(t, catalog, "uid-a", "Photos/1999/b.jpg", 0)
}

func TestMoverPathUpdateKeepsASingleRow(t *testing.T) {
	root := t.TempDir()
	catalog := openRelink(t, root)
	body := []byte("moved-by-zimage")
	from := filepath.Join(root, "Photos", "1999", "a.jpg")
	to := filepath.Join(root, "Photos", "2020", "a.jpg")
	writePhoto(t, from, body)
	fp := mustFP(t, from)
	insertAsset(t, catalog, "uid-move", "Photos/1999/a.jpg", int64(len(body)), fp, nil)
	if err := os.MkdirAll(filepath.Dir(to), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(from, to); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE assets SET rel_path = 'Photos/2020/a.jpg' WHERE uid = 'uid-move'`); err != nil {
		t.Fatal(err)
	}
	if err := relink.Pass(root, catalog, relink.Options{}); err != nil {
		t.Fatal(err)
	}
	if _, err := inventory.Run(root, catalog, inventory.Options{}); err != nil {
		t.Fatal(err)
	}
	assertOne(t, catalog, "uid-move", "Photos/2020/a.jpg", 0)
}

func TestRenameIntoDuplicatesDoesNotPlanAMoveOut(t *testing.T) {
	root := t.TempDir()
	catalog := openRelink(t, root)
	body := []byte("stored-copy")
	from := filepath.Join(root, "Photos", "1999", "a.jpg")
	to := filepath.Join(root, "Photos", "_Duplicates", "group", "a.jpg")
	writePhoto(t, from, body)
	fp := mustFP(t, from)
	insertAsset(t, catalog, "uid-dup", "Photos/1999/a.jpg", int64(len(body)), fp, nil)
	if err := os.MkdirAll(filepath.Dir(to), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(from, to); err != nil {
		t.Fatal(err)
	}
	if err := relink.Pass(root, catalog, relink.Options{}); err != nil {
		t.Fatal(err)
	}
	assertOne(t, catalog, "uid-dup", "Photos/_Duplicates/group/a.jpg", 0)
	if err := dating.Plan(catalog); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE asset_id = 1`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("reorg rows %d", n)
	}
}

func TestPurgedBlakeIsNotTheRelinkTarget(t *testing.T) {
	root := t.TempDir()
	catalog := openRelink(t, root)
	body := bytes.Repeat([]byte("same"), 400)
	keep := filepath.Join(root, "Photos", "1999", "keep.jpg")
	other := filepath.Join(root, "Photos", "1999", "other.jpg")
	writePhoto(t, keep, body)
	fp := mustFP(t, keep)
	sum := mustHash(t, keep)
	insertAsset(t, catalog, "uid-keep", "Photos/1999/keep.jpg", int64(len(body)), fp, sum)
	if _, err := catalog.Write.Exec(`UPDATE assets SET placement = 'active' WHERE uid = 'uid-keep'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			fast_fp, blake3, placement, discovered_at, updated_at
		) VALUES ('uid-purged', '.zimage/purged/uid-purged', ?, 'jpg', 'image', 'move', 'placed', ?, ?, 'purged', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z')`,
		len(body), fp, sum); err != nil {
		t.Fatal(err)
	}
	writePhoto(t, other, body)
	if err := relink.Pass(root, catalog, relink.Options{}); err != nil {
		t.Fatal(err)
	}
	var keepUID, keepRel string
	var keepMissing int
	if err := catalog.Read.QueryRow(`SELECT uid, rel_path, missing FROM assets WHERE uid = 'uid-keep'`).Scan(&keepUID, &keepRel, &keepMissing); err != nil {
		t.Fatal(err)
	}
	if keepUID != "uid-keep" || keepRel != "Photos/1999/keep.jpg" || keepMissing != 0 {
		t.Fatalf("keeper %s %s missing %d", keepUID, keepRel, keepMissing)
	}
	var purged string
	if err := catalog.Read.QueryRow(`SELECT rel_path FROM assets WHERE uid = 'uid-purged'`).Scan(&purged); err != nil {
		t.Fatal(err)
	}
	if purged != ".zimage/purged/uid-purged" {
		t.Fatalf("purged path %s", purged)
	}
}

func TestMissingStaysAfterTwoWalks(t *testing.T) {
	root := t.TempDir()
	catalog := openRelink(t, root)
	path := filepath.Join(root, "Photos", "1999", "gone.jpg")
	writePhoto(t, path, []byte("gone"))
	fp := mustFP(t, path)
	insertAsset(t, catalog, "uid-gone", "Photos/1999/gone.jpg", 4, fp, nil)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := relink.Pass(root, catalog, relink.Options{}); err != nil {
		t.Fatal(err)
	}
	if err := relink.Pass(root, catalog, relink.Options{}); err != nil {
		t.Fatal(err)
	}
	var n, missing int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*), MAX(missing) FROM assets WHERE uid = 'uid-gone'`).Scan(&n, &missing); err != nil {
		t.Fatal(err)
	}
	if n != 1 || missing != 1 {
		t.Fatalf("rows %d missing %d", n, missing)
	}
}

func TestAmbiguousFastFingerprintDoesNotMerge(t *testing.T) {
	root := t.TempDir()
	catalog := openRelink(t, root)
	body := []byte("ambiguous-bytes")
	fp := fingerprintBytes(t, body)
	insertAsset(t, catalog, "uid-1", "Photos/1999/one.jpg", int64(len(body)), fp, nil)
	insertAsset(t, catalog, "uid-2", "Photos/1999/two.jpg", int64(len(body)), fp, nil)
	if _, err := catalog.Write.Exec(`UPDATE assets SET missing = 1`); err != nil {
		t.Fatal(err)
	}
	writePhoto(t, filepath.Join(root, "Photos", "1999", "new.jpg"), body)
	if err := relink.Pass(root, catalog, relink.Options{}); err != nil {
		t.Fatal(err)
	}
	rows, err := catalog.Read.Query(`SELECT uid, rel_path, identity_ambiguous FROM assets ORDER BY uid`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	got := map[string]struct {
		rel string
		amb int
	}{}
	for rows.Next() {
		var uid, rel string
		var amb int
		if err := rows.Scan(&uid, &rel, &amb); err != nil {
			t.Fatal(err)
		}
		got[uid] = struct {
			rel string
			amb int
		}{rel, amb}
	}
	if got["uid-1"].rel != "Photos/1999/one.jpg" || got["uid-1"].amb != 1 {
		t.Fatalf("uid-1 %+v", got["uid-1"])
	}
	if got["uid-2"].rel != "Photos/1999/two.jpg" || got["uid-2"].amb != 1 {
		t.Fatalf("uid-2 %+v", got["uid-2"])
	}
}

func TestYieldsWhileCopying(t *testing.T) {
	root := t.TempDir()
	catalog := openRelink(t, root)
	for i := 0; i < 50; i++ {
		name := filepath.Join(root, "Photos", "1999", string(rune('a'+(i%26)))+string(rune('a'+i/26))+".jpg")
		writePhoto(t, name, []byte{byte(i)})
	}
	var sleeps int
	err := relink.Pass(root, catalog, relink.Options{
		Copying: func() bool { return true },
		Sleep: func(d time.Duration) {
			sleeps++
			if d != 200*time.Millisecond {
				t.Fatalf("sleep %s", d)
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if sleeps < 1 {
		t.Fatalf("sleeps %d", sleeps)
	}
}

func TestInventoryStoresFastFingerprint(t *testing.T) {
	root := t.TempDir()
	catalog := openRelink(t, root)
	path := filepath.Join(root, "Photos", "1999", "fresh.jpg")
	writePhoto(t, path, []byte("fresh-file"))
	if _, err := inventory.Run(root, catalog, inventory.Options{}); err != nil {
		t.Fatal(err)
	}
	want := mustFP(t, path)
	var got []byte
	if err := catalog.Read.QueryRow(`SELECT fast_fp FROM assets WHERE rel_path = 'Photos/1999/fresh.jpg'`).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("inventory did not store the fast fingerprint")
	}
}

func openRelink(t *testing.T, root string) *db.Catalog {
	t.Helper()
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = catalog.Close() })
	return catalog
}

func writePhoto(t *testing.T, path string, body []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

func insertAsset(t *testing.T, catalog *db.Catalog, uid, rel string, size int64, fp, sum []byte) {
	t.Helper()
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			fast_fp, blake3, discovered_at, updated_at
		) VALUES (?, ?, ?, 'jpg', 'image', 'move', 'discovered', ?, ?, '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z')`,
		uid, rel, size, fp, sum)
	if err != nil {
		t.Fatal(err)
	}
}

func assertOne(t *testing.T, catalog *db.Catalog, uid, rel string, missing int) {
	t.Helper()
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("rows %d", n)
	}
	var gotUID, gotRel string
	var gotMissing int
	if err := catalog.Read.QueryRow(`SELECT uid, rel_path, missing FROM assets`).Scan(&gotUID, &gotRel, &gotMissing); err != nil {
		t.Fatal(err)
	}
	if gotUID != uid || gotRel != rel || gotMissing != missing {
		t.Fatalf("got %s %s missing %d", gotUID, gotRel, gotMissing)
	}
}

func mustFP(t *testing.T, path string) []byte {
	t.Helper()
	fp, err := relink.FingerprintFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return fp
}

func mustHash(t *testing.T, path string) []byte {
	t.Helper()
	sum, err := relink.HashFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return sum
}

func fingerprintBytes(t *testing.T, body []byte) []byte {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fp.bin")
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
	return mustFP(t, path)
}
