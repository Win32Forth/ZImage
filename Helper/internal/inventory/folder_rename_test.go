package inventory

import (
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/db"
)

func TestRenameFolderKeepsTheAssetAndLeavesASibling(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	insertRenamedAsset(t, catalog, "keepuid", "Photos/Album/a.jpg")
	insertRenamedAsset(t, catalog, "sib", "Photos/Album2/b.jpg")
	if _, err := catalog.Write.Exec(`
		INSERT INTO events (uid, name, name_source, slug, folder_rel)
		VALUES ('ev', 'Album', 'album', 'album', 'Photos/Album/day')`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		UPDATE assets SET edit_rel = '.zimage/edits/keepuid.zimg', thumb_rel = '.zimage/cache/thumbs/ke/keepuid.jpg'
		WHERE uid = 'keepuid'`); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(root, "Photos", "Trip Album")
	if err := os.MkdirAll(filepath.Join(dest, "day"), 0o750); err != nil {
		t.Fatal(err)
	}

	n, err := RenameFolder(root, catalog, "Photos/Album", "Photos/Trip Album")
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("renamed %d", n)
	}
	var uid, editRel, thumbRel string
	if err := catalog.Read.QueryRow(`
		SELECT uid, COALESCE(edit_rel, ''), COALESCE(thumb_rel, '')
		FROM assets WHERE rel_path = 'Photos/Trip Album/a.jpg'`).Scan(&uid, &editRel, &thumbRel); err != nil {
		t.Fatal(err)
	}
	if uid != "keepuid" || editRel != ".zimage/edits/keepuid.zimg" || thumbRel != ".zimage/cache/thumbs/ke/keepuid.jpg" {
		t.Fatalf("uid %s edit %s thumb %s", uid, editRel, thumbRel)
	}
	if relExists(t, catalog, "Photos/Album/a.jpg") {
		t.Fatal("old path stayed")
	}
	if !relExists(t, catalog, "Photos/Album2/b.jpg") {
		t.Fatal("sibling changed")
	}
	var folder string
	if err := catalog.Read.QueryRow(`SELECT folder_rel FROM events WHERE uid = 'ev'`).Scan(&folder); err != nil {
		t.Fatal(err)
	}
	if folder != "Photos/Trip Album/day" {
		t.Fatalf("event folder %s", folder)
	}
}

func TestRenameFolderRefusesAShelfAnOpenMoveAndATakenName(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	insertRenamedAsset(t, catalog, "moving", "Photos/Album/a.jpg")
	insertRenamedAsset(t, catalog, "there", "Photos/Trip/b.jpg")
	var id int64
	if err := catalog.Read.QueryRow(`SELECT id FROM assets WHERE uid = 'moving'`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (?, 'reorg', 'copying', 'Photos/Album/a.jpg', 'Photos/Album/a.jpg', 4, '2026-11-19T00:00:00Z')`, id); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "Photos", "Trip"), 0o750); err != nil {
		t.Fatal(err)
	}
	if _, err := RenameFolder(root, catalog, "Photos/Album", "Photos/Trip"); err != ErrRenameTaken {
		t.Fatalf("taken %v", err)
	}
	if _, err := catalog.Write.Exec(`DELETE FROM assets WHERE uid = 'there'`); err != nil {
		t.Fatal(err)
	}
	if _, err := RenameFolder(root, catalog, "Photos/Album", "Photos/Trip"); err != ErrRenameBusy {
		t.Fatalf("busy %v", err)
	}
	if !relExists(t, catalog, "Photos/Album/a.jpg") {
		t.Fatal("busy rename changed the path")
	}
	for _, prefix := range []string{"Photos", "Photos/_Removed", "Photos/_Duplicates", "Photos/_Review"} {
		if _, err := RenameFolder(root, catalog, "Photos/Album", prefix); err != ErrRenameKept {
			t.Fatalf("kept %s %v", prefix, err)
		}
	}
	if _, err := RenameFolder(root, catalog, "Photos/Album", "Photos/Missing"); err != ErrRenameMissing {
		t.Fatalf("missing %v", err)
	}
}

func TestRenameFolderAcceptsAVideoFolderAlreadyInTheCatalog(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	insertRenamedAsset(t, catalog, "videouid", "Photos/DebbieGrok/clip.MP4")
	if _, err := catalog.Write.Exec(`
		UPDATE assets SET media_class = 'video', ext = 'MP4' WHERE uid = 'videouid'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO events (uid, name, name_source, slug, folder_rel)
		VALUES ('ev', 'Debbie Grok', 'album', 'debbie-grok', 'Photos/Debbie Grok')`); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "Photos", "DebbieGrok"), 0o750); err != nil {
		t.Fatal(err)
	}

	n, err := RenameFolder(root, catalog, "Photos/Debbie Grok", "Photos/DebbieGrok")
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("renamed %d", n)
	}
	var class, uid string
	if err := catalog.Read.QueryRow(`
		SELECT uid, media_class FROM assets WHERE rel_path = 'Photos/DebbieGrok/clip.MP4'`).Scan(&uid, &class); err != nil {
		t.Fatal(err)
	}
	if uid != "videouid" || class != "video" {
		t.Fatalf("uid %s class %s", uid, class)
	}
	var folder string
	if err := catalog.Read.QueryRow(`SELECT folder_rel FROM events WHERE uid = 'ev'`).Scan(&folder); err != nil {
		t.Fatal(err)
	}
	if folder != "Photos/DebbieGrok" {
		t.Fatalf("event folder %s", folder)
	}

	// The old directory is still on disk and the new one is a different directory.
	// The catalog already uses the new name, and this split stays refused.
	if err := os.MkdirAll(filepath.Join(root, "Photos", "Debbie Grok"), 0o750); err != nil {
		t.Fatal(err)
	}
	if _, err := RenameFolder(root, catalog, "Photos/Debbie Grok", "Photos/DebbieGrok"); err != ErrRenameTaken {
		t.Fatalf("split %v", err)
	}
	if err := os.Remove(filepath.Join(root, "Photos", "DebbieGrok")); err != nil {
		t.Fatal(err)
	}
	if _, err := RenameFolder(root, catalog, "Photos/Debbie Grok", "Photos/DebbieGrok"); err != ErrRenameMissing {
		t.Fatalf("missing dest %v", err)
	}
}

func TestRenameFolderCaseOnlyKeepsTheSameFile(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	insertRenamedAsset(t, catalog, "keepuid", "Photos/Album/a.jpg")
	dest := filepath.Join(root, "Photos", "album")
	if err := os.MkdirAll(dest, 0o750); err != nil {
		t.Fatal(err)
	}
	n, err := RenameFolder(root, catalog, "Photos/Album", "Photos/album")
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("renamed %d", n)
	}
	var uid string
	if err := catalog.Read.QueryRow(`SELECT uid FROM assets WHERE rel_path = 'Photos/album/a.jpg'`).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	if uid != "keepuid" {
		t.Fatalf("uid %s", uid)
	}
}

func insertRenamedAsset(t *testing.T, catalog *db.Catalog, uid, rel string) {
	t.Helper()
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
		) VALUES (?, ?, 4, 'jpg', 'image', 'move', 'thumbed', '2026-11-19T00:00:00Z', '2026-11-19T00:00:00Z')`,
		uid, rel)
	if err != nil {
		t.Fatal(err)
	}
}
