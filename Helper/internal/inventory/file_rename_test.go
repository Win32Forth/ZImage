package inventory

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRenameFileKeepsTheAssetAndDropsTheRescanRow(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	insertRenamedAsset(t, catalog, "keepuid", "Photos/1964/1964-11-24/Syntek_USB Camera_day.jpg")
	insertRenamedAsset(t, catalog, "extra", "Photos/1964/1964-11-24/day.jpg")
	insertRenamedAsset(t, catalog, "sib", "Photos/1964/1964-11-24/other.jpg")
	if _, err := catalog.Write.Exec(`
		UPDATE assets
		SET edit_rel = '.zimage/edits/keepuid.zimg', phase = 'planned'
		WHERE uid = 'keepuid'`); err != nil {
		t.Fatal(err)
	}
	var id int64
	if err := catalog.Read.QueryRow(`SELECT id FROM assets WHERE uid = 'keepuid'`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (?, 'reorg', 'planned', 'Photos/1964/1964-11-24/Syntek_USB Camera_day.jpg', 'Photos/1964/1964-11-24/Syntek_USB Camera_day.jpg', 4, '2026-11-21T00:00:00Z')`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		UPDATE assets SET thumb_rel = '.zimage/cache/thumbs/ex/extra.jpg' WHERE uid = 'extra'`); err != nil {
		t.Fatal(err)
	}
	thumb := filepath.Join(root, ".zimage", "cache", "thumbs", "ex", "extra.jpg")
	if err := os.MkdirAll(filepath.Dir(thumb), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(thumb, []byte("thumb"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeRenameFile(t, root, "Photos/1964/1964-11-24/day.jpg")

	err := RenameFile(root, catalog,
		"Photos/1964/1964-11-24/Syntek_USB Camera_day.jpg",
		"Photos/1964/1964-11-24/day.jpg")
	if err != nil {
		t.Fatal(err)
	}
	var uid, editRel, phase string
	if err := catalog.Read.QueryRow(`
		SELECT uid, COALESCE(edit_rel, ''), phase FROM assets WHERE rel_path = 'Photos/1964/1964-11-24/day.jpg'`).
		Scan(&uid, &editRel, &phase); err != nil {
		t.Fatal(err)
	}
	if uid != "keepuid" || editRel != ".zimage/edits/keepuid.zimg" || phase != "planned" {
		t.Fatalf("uid %s edit %s phase %s", uid, editRel, phase)
	}
	if relExists(t, catalog, "Photos/1964/1964-11-24/Syntek_USB Camera_day.jpg") {
		t.Fatal("old path stayed")
	}
	if !relExists(t, catalog, "Photos/1964/1964-11-24/other.jpg") {
		t.Fatal("sibling changed")
	}
	var src, dest string
	if err := catalog.Read.QueryRow(`SELECT src_rel, dest_rel FROM journal WHERE asset_id = ?`, id).Scan(&src, &dest); err != nil {
		t.Fatal(err)
	}
	if src != "Photos/1964/1964-11-24/day.jpg" || dest != "Photos/1964/1964-11-24/day.jpg" {
		t.Fatalf("journal %s -> %s", src, dest)
	}
	if _, err := os.Stat(thumb); !os.IsNotExist(err) {
		t.Fatal("duplicate thumb stayed")
	}
	if err := RenameFile(root, catalog,
		"Photos/1964/1964-11-24/Syntek_USB Camera_day.jpg",
		"Photos/1964/1964-11-24/day.jpg"); err != nil {
		t.Fatal(err)
	}
}

func TestRenameFileRefusesEditsAnOpenMoveAndAMissingFile(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	insertRenamedAsset(t, catalog, "keepuid", "Photos/Day/old.jpg")
	insertRenamedAsset(t, catalog, "edited", "Photos/Day/new.jpg")
	if err := os.MkdirAll(filepath.Join(root, ".zimage", "edits"), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".zimage", "edits", "edited.zimg"), []byte("edits"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeRenameFile(t, root, "Photos/Day/new.jpg")
	if err := RenameFile(root, catalog, "Photos/Day/old.jpg", "Photos/Day/new.jpg"); err != ErrRenameTaken {
		t.Fatalf("taken %v", err)
	}
	if !relExists(t, catalog, "Photos/Day/old.jpg") || !relExists(t, catalog, "Photos/Day/new.jpg") {
		t.Fatal("taken rename changed a path")
	}

	if _, err := catalog.Write.Exec(`DELETE FROM assets WHERE uid = 'edited'`); err != nil {
		t.Fatal(err)
	}
	var id int64
	if err := catalog.Read.QueryRow(`SELECT id FROM assets WHERE uid = 'keepuid'`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (?, 'reorg', 'copying', 'Photos/Day/old.jpg', 'Photos/Day/later.jpg', 4, '2026-11-21T00:00:00Z')`, id); err != nil {
		t.Fatal(err)
	}
	if err := RenameFile(root, catalog, "Photos/Day/old.jpg", "Photos/Day/new.jpg"); err != ErrRenameBusy {
		t.Fatalf("busy %v", err)
	}
	if !relExists(t, catalog, "Photos/Day/old.jpg") {
		t.Fatal("busy rename changed the path")
	}

	if _, err := catalog.Write.Exec(`DELETE FROM journal WHERE asset_id = ?`, id); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "Photos", "Day", "new.jpg")); err != nil {
		t.Fatal(err)
	}
	if err := RenameFile(root, catalog, "Photos/Day/old.jpg", "Photos/Day/new.jpg"); err != ErrRenameMissing {
		t.Fatalf("missing %v", err)
	}
	if err := RenameFile(root, catalog, "Photos/Day/old.jpg", "Photos/_Removed/old.jpg"); err != ErrRenameKept {
		t.Fatalf("kept %v", err)
	}
}

func writeRenameFile(t *testing.T, root, rel string) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte("photo"), 0o644); err != nil {
		t.Fatal(err)
	}
}
