package thumb

import (
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/db"
)

func TestApplyNextStopsAfterTheLimit(t *testing.T) {
	root := t.TempDir()
	catalog := openThumbCatalog(t, root)
	for i := 0; i < 3; i++ {
		name := "img" + string(rune('a'+i)) + ".jpg"
		path := filepath.Join(root, "Photos", name)
		if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, solidJPEG(t, 32, 16), 0o644); err != nil {
			t.Fatal(err)
		}
		insertDiscovered(t, catalog, "uid-"+name, "Photos/"+name)
	}
	big := filepath.Join(root, "Photos", "big.jpg")
	if err := os.WriteFile(big, jpegSOF(10000, 10000), 0o644); err != nil {
		t.Fatal(err)
	}
	insertDiscovered(t, catalog, "uid-big", "Photos/big.jpg")

	n, err := ApplyNext(root, catalog, nil, 1)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("finished %d", n)
	}
	if thumbedCount(t, catalog) != 1 {
		t.Fatal("expected one stored preview")
	}
	n, err = ApplyNext(root, catalog, nil, 1)
	if err != nil || n != 1 || thumbedCount(t, catalog) != 2 {
		t.Fatalf("second pass n=%d thumbs=%d err=%v", n, thumbedCount(t, catalog), err)
	}
	if err := Apply(root, catalog, nil); err != nil {
		t.Fatal(err)
	}
	if thumbedCount(t, catalog) != 3 {
		t.Fatalf("small files thumbed %d", thumbedCount(t, catalog))
	}
	var source string
	if err := catalog.Read.QueryRow(`SELECT COALESCE(detail_source, '') FROM assets WHERE uid = 'uid-big'`).Scan(&source); err != nil {
		t.Fatal(err)
	}
	if source != "needs_mac" {
		t.Fatalf("big file %q", source)
	}
	n, err = ApplyNext(root, catalog, nil, 5)
	if err != nil || n != 0 {
		t.Fatalf("drained n=%d err=%v", n, err)
	}
}

func TestApplyRetriesNeedsMacWithinTheCeiling(t *testing.T) {
	root := t.TempDir()
	catalog := openThumbCatalog(t, root)
	photo := filepath.Join(root, "Photos", "again.jpg")
	if err := os.MkdirAll(filepath.Dir(photo), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(photo, solidJPEG(t, 64, 32), 0o644); err != nil {
		t.Fatal(err)
	}
	insertNeedsMac(t, catalog, "uid-again", "Photos/again.jpg", 64*32)

	broken := filepath.Join(root, "Photos", "broken.jpg")
	// A real header with the scan removed still reports 800×600, and the decode fails.
	full := solidJPEG(t, 800, 600)
	cut := indexSOS(full)
	if cut < 4 {
		t.Fatal("missing SOS")
	}
	sosLen := int(full[cut+2])<<8 | int(full[cut+3])
	end := cut + 2 + sosLen
	if end > len(full) {
		t.Fatal("short SOS")
	}
	if err := os.WriteFile(broken, full[:end], 0o644); err != nil {
		t.Fatal(err)
	}
	insertNeedsMac(t, catalog, "uid-broken", "Photos/broken.jpg", 800*600)

	huge := filepath.Join(root, "Photos", "huge.jpg")
	if err := os.WriteFile(huge, jpegSOF(10000, 10000), 0o644); err != nil {
		t.Fatal(err)
	}
	insertNeedsMac(t, catalog, "uid-huge", "Photos/huge.jpg", 10000*10000)

	n, err := ApplyNext(root, catalog, nil, 10)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("finished %d", n)
	}
	if thumbedCount(t, catalog) != 1 {
		t.Fatal("expected the stored needs_mac photo to gain a preview")
	}
	var againSource, brokenSupport, hugeSupport string
	if err := catalog.Read.QueryRow(`SELECT COALESCE(detail_source, '') FROM assets WHERE uid = 'uid-again'`).Scan(&againSource); err != nil {
		t.Fatal(err)
	}
	if againSource != "" {
		t.Fatalf("retried photo detail_source %q", againSource)
	}
	if err := catalog.Read.QueryRow(`SELECT decode_support FROM assets WHERE uid = 'uid-broken'`).Scan(&brokenSupport); err != nil {
		t.Fatal(err)
	}
	if brokenSupport != "failed" {
		t.Fatalf("broken support %q", brokenSupport)
	}
	if err := catalog.Read.QueryRow(`SELECT decode_support FROM assets WHERE uid = 'uid-huge'`).Scan(&hugeSupport); err != nil {
		t.Fatal(err)
	}
	if hugeSupport != "needs_mac" {
		t.Fatalf("huge support %q", hugeSupport)
	}
	n, err = ApplyNext(root, catalog, nil, 10)
	if err != nil || n != 0 {
		t.Fatalf("second pass n=%d err=%v", n, err)
	}
}

func openThumbCatalog(t *testing.T, root string) *db.Catalog {
	t.Helper()
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { catalog.Close() })
	return catalog
}

func insertDiscovered(t *testing.T, catalog *db.Catalog, uid, rel string) {
	t.Helper()
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
		) VALUES (?, ?, 10, 'jpg', 'image', 'move', 'discovered', '2026-11-04T00:00:00Z', '2026-11-04T00:00:00Z')`,
		uid, rel)
	if err != nil {
		t.Fatal(err)
	}
}

func indexSOS(data []byte) int {
	for i := 0; i+1 < len(data); i++ {
		if data[i] == 0xFF && data[i+1] == 0xDA {
			return i
		}
	}
	return -1
}

func insertNeedsMac(t *testing.T, catalog *db.Catalog, uid, rel string, pixels int) {
	t.Helper()
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			detail_source, decode_support, native_pixels, discovered_at, updated_at
		) VALUES (?, ?, 10, 'jpg', 'image', 'move', 'discovered',
			'needs_mac', 'unknown', ?, '2026-11-04T00:00:00Z', '2026-11-04T00:00:00Z')`,
		uid, rel, pixels)
	if err != nil {
		t.Fatal(err)
	}
}

func thumbedCount(t *testing.T, catalog *db.Catalog) int {
	t.Helper()
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE thumb_rel IS NOT NULL`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
