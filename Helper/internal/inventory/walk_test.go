package inventory

import (
	"bytes"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/db"
	"zimage/helper/internal/thumb"
)

func TestWalkSkipsNoiseAndListsDuplicates(t *testing.T) {
	root := t.TempDir()
	photos := filepath.Join(root, "Photos")
	for i := 1; i <= 17; i++ {
		writeJPEG(t, filepath.Join(photos, "img"+itoa(i)+".jpg"))
	}
	writeJPEG(t, filepath.Join(photos, "_Duplicates", "ab", "kept.jpg"))
	if err := os.MkdirAll(filepath.Join(photos, ".thumbnails"), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(photos, "Thumbs.db"), []byte("noise"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(photos, ".thumbnails", "hidden.jpg"), []byte("hidden"), 0o644); err != nil {
		t.Fatal(err)
	}

	catalog := openCatalog(t, root)
	summary, err := Run(root, catalog, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Inserted != 18 {
		t.Fatalf("inserted %d commits %d", summary.Inserted, summary.Commits)
	}
	if err := thumb.Apply(root, catalog, nil); err != nil {
		t.Fatal(err)
	}

	var count int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 18 {
		t.Fatalf("rows %d", count)
	}
	var dupThumb string
	err = catalog.Read.QueryRow(`SELECT COALESCE(thumb_rel, '') FROM assets WHERE rel_path = 'Photos/_Duplicates/ab/kept.jpg'`).Scan(&dupThumb)
	if err != nil || dupThumb == "" {
		t.Fatalf("duplicate thumb %q %v", dupThumb, err)
	}
	var noise int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE rel_path LIKE '%Thumbs.db' OR rel_path LIKE '%.thumbnails%'`).Scan(&noise); err != nil {
		t.Fatal(err)
	}
	if noise != 0 {
		t.Fatalf("noise rows %d", noise)
	}
	jpegBytes, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(dupThumb)))
	if err != nil {
		t.Fatal(err)
	}
	if !thumb.LongEdgeIsBounded(jpegBytes) {
		t.Fatal("thumbnail long edge")
	}
}

func TestWalkAdoptsAVideoThatWasLeft(t *testing.T) {
	root := t.TempDir()
	rel := "Photos/inbox/clip.mov"
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte("video-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	catalog := openCatalog(t, root)
	now := "2026-01-01T00:00:00Z"
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
		) VALUES ('clip', ?, 11, 'mov', 'video', 'leave', 'discovered', ?, ?)`, rel, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := Run(root, catalog, Options{}); err != nil {
		t.Fatal(err)
	}
	var class, policy string
	if err := catalog.Read.QueryRow(`SELECT media_class, reorg_policy FROM assets WHERE uid = 'clip'`).Scan(&class, &policy); err != nil {
		t.Fatal(err)
	}
	if class != "video" || policy != "move" {
		t.Fatalf("adopted %s %s", class, policy)
	}
	var pdfPolicy string
	pdf := "Photos/inbox/page.pdf"
	pdfFull := filepath.Join(root, filepath.FromSlash(pdf))
	if err := os.WriteFile(pdfFull, []byte("pdf"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Run(root, catalog, Options{}); err != nil {
		t.Fatal(err)
	}
	if err := catalog.Read.QueryRow(`SELECT reorg_policy FROM assets WHERE rel_path = ?`, pdf).Scan(&pdfPolicy); err != nil {
		t.Fatal(err)
	}
	if pdfPolicy != "leave" {
		t.Fatal(pdfPolicy)
	}
}

func TestCommitsEveryFiftyFiles(t *testing.T) {
	root := t.TempDir()
	photos := filepath.Join(root, "Photos")
	for i := 0; i < 60; i++ {
		writeJPEG(t, filepath.Join(photos, "batch", itoa(i)+".jpg"))
	}
	if err := os.WriteFile(filepath.Join(photos, "batch", "desktop.ini"), []byte("ini"), 0o644); err != nil {
		t.Fatal(err)
	}
	catalog := openCatalog(t, root)
	summary, err := Run(root, catalog, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Inserted != 60 || summary.Commits != 2 {
		t.Fatalf("summary %+v", summary)
	}
}

func openCatalog(t *testing.T, root string) *db.Catalog {
	t.Helper()
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { catalog.Close() })
	return catalog
}

func writeJPEG(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	img := image.NewGray(image.Rect(0, 0, 8, 4))
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 70}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var digits [8]byte
	i := len(digits)
	for value > 0 {
		i--
		digits[i] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[i:])
}
