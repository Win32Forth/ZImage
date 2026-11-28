package inventory

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/db"
)

func TestScanFolderAddsAFileAndDropsADeletedOne(t *testing.T) {
	root := t.TempDir()
	keep := filepath.Join(root, "Photos", "Day", "keep.jpg")
	nested := filepath.Join(root, "Photos", "Day", "sub", "nested.jpg")
	gone := filepath.Join(root, "Photos", "Day", "gone.jpg")
	sibling := filepath.Join(root, "Photos", "Daylight", "stay.jpg")
	writeJPEG(t, keep)
	writeJPEG(t, nested)
	writeJPEG(t, gone)
	writeJPEG(t, sibling)
	if err := os.MkdirAll(filepath.Join(root, "Photos", "Day", ".hidden"), 0o750); err != nil {
		t.Fatal(err)
	}
	writeJPEG(t, filepath.Join(root, "Photos", "Day", ".hidden", "secret.jpg"))
	if err := os.WriteFile(filepath.Join(root, "Photos", "Day", "Thumbs.db"), []byte("noise"), 0o644); err != nil {
		t.Fatal(err)
	}
	catalog := openCatalog(t, root)
	if _, err := Run(root, catalog, Options{}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}
	fresh := filepath.Join(root, "Photos", "Day", "fresh.jpg")
	writeJPEG(t, fresh)

	summary, err := ScanFolder(root, "Photos/Day", catalog, FolderOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Added != 1 || summary.Removed != 1 {
		t.Fatalf("summary %+v", summary)
	}
	if !relExists(t, catalog, "Photos/Day/keep.jpg") || !relExists(t, catalog, "Photos/Day/sub/nested.jpg") {
		t.Fatal("kept files missing")
	}
	if !relExists(t, catalog, "Photos/Day/fresh.jpg") {
		t.Fatal("fresh file was not added")
	}
	if relExists(t, catalog, "Photos/Day/gone.jpg") {
		t.Fatal("deleted file stayed in the catalog")
	}
	if relExists(t, catalog, "Photos/Day/.hidden/secret.jpg") || relExists(t, catalog, "Photos/Day/Thumbs.db") {
		t.Fatal("skipped file was catalogued")
	}
	if !relExists(t, catalog, "Photos/Daylight/stay.jpg") {
		t.Fatal("sibling folder was changed")
	}
}

func TestScanFolderLeavesAnOpenMove(t *testing.T) {
	root := t.TempDir()
	rel := "Photos/Day/moving.jpg"
	full := filepath.Join(root, filepath.FromSlash(rel))
	writeJPEG(t, full)
	catalog := openCatalog(t, root)
	if _, err := ScanFolder(root, "Photos/Day", catalog, FolderOptions{}); err != nil {
		t.Fatal(err)
	}
	var id int64
	if err := catalog.Read.QueryRow(`SELECT id FROM assets WHERE rel_path = ?`, rel).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (
			asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at
		) VALUES (?, 'reorg', 'copying', ?, ?, 10, '2026-01-01T00:00:00Z')`, id, rel, rel); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(full); err != nil {
		t.Fatal(err)
	}
	summary, err := ScanFolder(root, "Photos/Day", catalog, FolderOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Removed != 0 || !relExists(t, catalog, rel) {
		t.Fatalf("open move removed %+v", summary)
	}
}

func TestScanFolderRemovesRowsWhenTheFolderIsGone(t *testing.T) {
	root := t.TempDir()
	full := filepath.Join(root, "Photos", "Day", "only.jpg")
	writeJPEG(t, full)
	catalog := openCatalog(t, root)
	if _, err := ScanFolder(root, "Photos/Day", catalog, FolderOptions{}); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(root, "Photos", "Day")); err != nil {
		t.Fatal(err)
	}
	summary, err := ScanFolder(root, "Photos/Day", catalog, FolderOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Removed != 1 || relExists(t, catalog, "Photos/Day/only.jpg") {
		t.Fatalf("folder removal %+v", summary)
	}
}

func TestScanFolderRejectsAPathOutsidePhotos(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	for _, prefix := range []string{"", "Movies", "Photos/../Secret", `Photos\hidden`} {
		if _, err := ScanFolder(root, prefix, catalog, FolderOptions{}); err != ErrNotFolder {
			t.Fatalf("prefix %q err %v", prefix, err)
		}
	}
}

func TestScanPageChecksOnlyTheListedFiles(t *testing.T) {
	root := t.TempDir()
	keep := filepath.Join(root, "Photos", "Day", "keep.jpg")
	gone := filepath.Join(root, "Photos", "Day", "gone.jpg")
	other := filepath.Join(root, "Photos", "Day", "other.jpg")
	fresh := filepath.Join(root, "Photos", "Day", "fresh.jpg")
	stray := filepath.Join(root, "Photos", "Day", "stray.jpg")
	sibling := filepath.Join(root, "Photos", "Daylight", "stay.jpg")
	writeJPEG(t, keep)
	writeJPEG(t, gone)
	writeJPEG(t, other)
	writeJPEG(t, sibling)
	catalog := openCatalog(t, root)
	if _, err := ScanFolder(root, "Photos", catalog, FolderOptions{}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(other); err != nil {
		t.Fatal(err)
	}
	writeJPEG(t, fresh)
	writeJPEG(t, stray)
	var phases []string
	var biggest int
	summary, err := ScanPage(root, "Photos/Day", []string{
		"Photos/Day/keep.jpg",
		"Photos/Day/gone.jpg",
		"Photos/Day/fresh.jpg",
	}, catalog, FolderOptions{
		Progress: func(phase string, _, total, _, _ int) {
			phases = append(phases, phase)
			if total > biggest {
				biggest = total
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Looked != 3 || summary.Added != 1 || summary.Removed != 1 {
		t.Fatalf("summary %+v", summary)
	}
	if biggest != 3 {
		t.Fatalf("total %d", biggest)
	}
	for _, phase := range phases {
		if phase != "scanning" {
			t.Fatalf("phase %q", phase)
		}
	}
	if !relExists(t, catalog, "Photos/Day/keep.jpg") || !relExists(t, catalog, "Photos/Day/fresh.jpg") {
		t.Fatal("listed files")
	}
	if relExists(t, catalog, "Photos/Day/gone.jpg") {
		t.Fatal("listed missing file stayed")
	}
	if !relExists(t, catalog, "Photos/Day/other.jpg") {
		t.Fatal("unlisted missing file was dropped")
	}
	if relExists(t, catalog, "Photos/Day/stray.jpg") {
		t.Fatal("unlisted new file was added")
	}
	if !relExists(t, catalog, "Photos/Daylight/stay.jpg") {
		t.Fatal("sibling folder was changed")
	}
}

func TestScanPageLeavesAnOpenMove(t *testing.T) {
	root := t.TempDir()
	rel := "Photos/Day/moving.jpg"
	full := filepath.Join(root, filepath.FromSlash(rel))
	writeJPEG(t, full)
	catalog := openCatalog(t, root)
	if _, err := ScanPage(root, "Photos/Day", []string{rel}, catalog, FolderOptions{}); err != nil {
		t.Fatal(err)
	}
	var id int64
	if err := catalog.Read.QueryRow(`SELECT id FROM assets WHERE rel_path = ?`, rel).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (
			asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at
		) VALUES (?, 'reorg', 'copying', ?, ?, 10, '2026-01-01T00:00:00Z')`, id, rel, rel); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(full); err != nil {
		t.Fatal(err)
	}
	summary, err := ScanPage(root, "Photos/Day", []string{rel}, catalog, FolderOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Removed != 0 || !relExists(t, catalog, rel) {
		t.Fatalf("open move removed %+v", summary)
	}
}

func TestScanPageStopsAtTwoThousand(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "Photos", "Day")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	sample := filepath.Join(dir, "sample.jpg")
	writeJPEG(t, sample)
	blob, err := os.ReadFile(sample)
	if err != nil {
		t.Fatal(err)
	}
	catalog := openCatalog(t, root)
	tx, err := catalog.Write.Begin()
	if err != nil {
		t.Fatal(err)
	}
	paths := make([]string, 0, PageCap+1)
	gone := "Photos/Day/gone.jpg"
	paths = append(paths, gone)
	if _, err := tx.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
		) VALUES ('gone', ?, 20, 'jpg', 'image', 'move', 'discovered', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`, gone); err != nil {
		t.Fatal(err)
	}
	for i := 1; i < PageCap-1; i++ {
		rel := fmt.Sprintf("Photos/Day/f%04d.jpg", i)
		paths = append(paths, rel)
		if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(rel)), blob, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(`
			INSERT INTO assets (
				uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
			) VALUES (?, ?, 20, 'jpg', 'image', 'move', 'discovered', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`,
			fmt.Sprintf("f%04d", i), rel); err != nil {
			t.Fatal(err)
		}
	}
	fresh := "Photos/Day/fresh.jpg"
	paths = append(paths, fresh)
	if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(fresh)), blob, 0o644); err != nil {
		t.Fatal(err)
	}
	past := "Photos/Day/past.jpg"
	paths = append(paths, past)
	if _, err := tx.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
		) VALUES ('past', ?, 20, 'jpg', 'image', 'move', 'discovered', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`, past); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(sample); err != nil {
		t.Fatal(err)
	}
	if len(paths) != PageCap+1 {
		t.Fatalf("paths %d", len(paths))
	}
	summary, err := ScanPage(root, "Photos/Day", paths, catalog, FolderOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Looked != PageCap || summary.Added != 1 || summary.Removed != 1 {
		t.Fatalf("summary %+v", summary)
	}
	if relExists(t, catalog, gone) {
		t.Fatal("listed missing file stayed")
	}
	if !relExists(t, catalog, fresh) {
		t.Fatal("file inside the cap was not added")
	}
	if !relExists(t, catalog, past) {
		t.Fatal("file past the cap was dropped")
	}
	var stored int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets WHERE rel_path = ?`, fresh).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != 1 {
		t.Fatalf("fresh rows %d", stored)
	}
}

func TestScanPageRejectsAPathOutsideTheFolder(t *testing.T) {
	root := t.TempDir()
	stay := filepath.Join(root, "Photos", "Day", "stay.jpg")
	writeJPEG(t, stay)
	catalog := openCatalog(t, root)
	if _, err := ScanPage(root, "Photos/Day", []string{"Photos/Day/stay.jpg"}, catalog, FolderOptions{}); err != nil {
		t.Fatal(err)
	}
	for _, paths := range [][]string{
		nil,
		{"Photos/Daylight/stay.jpg"},
		{"Photos/Day/../../Secret.jpg"},
		{`Photos\Day\stay.jpg`},
		{"Photos/Day"},
	} {
		if _, err := ScanPage(root, "Photos/Day", paths, catalog, FolderOptions{}); err != ErrNotFolder {
			t.Fatalf("paths %q err %v", paths, err)
		}
	}
	if _, err := ScanPage(root, "Photos/../Secret", []string{"Photos/Day/stay.jpg"}, catalog, FolderOptions{}); err != ErrNotFolder {
		t.Fatal(err)
	}
	if !relExists(t, catalog, "Photos/Day/stay.jpg") {
		t.Fatal("rejected scan changed the catalog")
	}
}

func TestScanFolderYieldsOnEveryFile(t *testing.T) {
	root := t.TempDir()
	writeJPEG(t, filepath.Join(root, "Photos", "Day", "a.jpg"))
	writeJPEG(t, filepath.Join(root, "Photos", "Day", "b.jpg"))
	catalog := openCatalog(t, root)
	var yields int
	summary, err := ScanFolder(root, "Photos/Day", catalog, FolderOptions{Yield: func() { yields++ }})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Added != 2 || yields < 4 {
		t.Fatalf("yields %d summary %+v", yields, summary)
	}
}

func relExists(t *testing.T, catalog *db.Catalog, rel string) bool {
	t.Helper()
	var id int64
	err := catalog.Read.QueryRow(`SELECT id FROM assets WHERE rel_path = ?`, rel).Scan(&id)
	if err == sql.ErrNoRows {
		return false
	}
	if err != nil {
		t.Fatal(err)
	}
	return true
}
