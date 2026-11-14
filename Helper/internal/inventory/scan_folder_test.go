package inventory

import (
	"database/sql"
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
