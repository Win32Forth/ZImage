package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/db"
)

func TestCleanFolderDropsMissingTwinsAndLeavesTheRest(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	payload := []byte("same-bytes")
	insertAPIMember(t, root, catalog, 0, "live", "Photos/2026/2026-03-19/1970s Debbie portrait/Debbie.jpg", payload, 100, nil, 0)
	insertAPIMember(t, root, catalog, 0, "ghost", "Photos/2026/2026-03-19/event/Debbie.jpg", payload, 100, nil, 0)
	removeFile(t, root, "Photos/2026/2026-03-19/event/Debbie.jpg")

	insertAPIRow(t, catalog, "orphan", "Photos/2026/2026-03-19/event/Only.jpg", 4)
	insertAPIMember(t, root, catalog, 0, "big", "Photos/2026/2026-03-20/scans/Scan.jpg", []byte("nine-bytes"), 100, nil, 0)
	insertAPIRow(t, catalog, "small", "Photos/2026/2026-03-20/event/Scan.jpg", 4)

	insertAPIMember(t, root, catalog, 0, "edited-live", "Photos/2026/2026-09-23/Bartlett/Keep.jpg", payload, 100, nil, 0)
	insertAPIRow(t, catalog, "edited", "Photos/2026/2026-09-23/event/Keep.jpg", len(payload))
	if _, err := catalog.Write.Exec(`UPDATE assets SET edit_rel = '.zimage/edits/edited.zimg' WHERE uid = 'edited'`); err != nil {
		t.Fatal(err)
	}

	insertAPIMember(t, root, catalog, 0, "sidecar-live", "Photos/2026/2026-09-23/Bartlett/Side.jpg", payload, 100, nil, 0)
	insertAPIRow(t, catalog, "sidecar", "Photos/2026/2026-09-23/event/Side.jpg", len(payload))
	edits := filepath.Join(root, ".zimage", "edits")
	if err := os.MkdirAll(edits, 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(edits, "sidecar.zimg"), []byte("ZIMG"), 0o644); err != nil {
		t.Fatal(err)
	}

	insertAPIMember(t, root, catalog, 0, "moving-live", "Photos/2026/day/album/Move.jpg", payload, 100, nil, 0)
	insertAPIRow(t, catalog, "moving", "Photos/2026/day/event/Move.jpg", len(payload))
	var movingID int64
	if err := catalog.Read.QueryRow(`SELECT id FROM assets WHERE uid = 'moving'`).Scan(&movingID); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (?, 'reorg', 'planned', 'Photos/2026/day/event/Move.jpg', 'Photos/2026/day/album/Move.jpg', ?, '2026-11-09T00:00:00Z')`,
		movingID, len(payload)); err != nil {
		t.Fatal(err)
	}

	neighbor := []byte("neighbor")
	insertAPIMember(t, root, catalog, 0, "year-live", "Photos/2025/day/album/Neighbor.jpg", neighbor, 100, nil, 0)
	insertAPIRow(t, catalog, "year-ghost", "Photos/2026/day/event/Neighbor.jpg", len(neighbor))

	wild := []byte("wild-card")
	insertAPIMember(t, root, catalog, 0, "wild-live", "Photos/axb/day/Same.jpg", wild, 100, nil, 0)
	insertAPIRow(t, catalog, "wild-ghost", "Photos/a_b/day/event/Same.jpg", len(wild))

	client, base := reorgServer(t, root, catalog, nil)
	removed, kept := postClean(t, client, base, "Photos/2026")
	if removed != 1 || kept != 6 {
		t.Fatalf("clean removed %d kept %d", removed, kept)
	}
	assertPurged(t, catalog, "ghost")
	assertActive(t, catalog, "live", "Photos/2026/2026-03-19/1970s Debbie portrait/Debbie.jpg")
	assertActive(t, catalog, "orphan", "Photos/2026/2026-03-19/event/Only.jpg")
	assertActive(t, catalog, "small", "Photos/2026/2026-03-20/event/Scan.jpg")
	assertActive(t, catalog, "edited", "Photos/2026/2026-09-23/event/Keep.jpg")
	assertActive(t, catalog, "sidecar", "Photos/2026/2026-09-23/event/Side.jpg")
	assertActive(t, catalog, "moving", "Photos/2026/day/event/Move.jpg")
	assertActive(t, catalog, "year-ghost", "Photos/2026/day/event/Neighbor.jpg")
	got, err := os.ReadFile(filepath.Join(root, "Photos", "2026", "2026-03-19", "1970s Debbie portrait", "Debbie.jpg"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("live bytes")
	}

	removed, kept = postClean(t, client, base, "Photos/a_b")
	if removed != 0 || kept != 1 {
		t.Fatalf("underscore removed %d kept %d", removed, kept)
	}
	assertActive(t, catalog, "wild-ghost", "Photos/a_b/day/event/Same.jpg")
	assertActive(t, catalog, "wild-live", "Photos/axb/day/Same.jpg")
}

func TestCleanFolderRefusesABusyReorg(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	payload := []byte("same-bytes")
	insertAPIMember(t, root, catalog, 0, "live", "Photos/2026/album/Debbie.jpg", payload, 100, nil, 0)
	insertAPIRow(t, catalog, "ghost", "Photos/2026/event/Debbie.jpg", len(payload))
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running', safe_to_reboot = 0 WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	body, err := json.Marshal(map[string]string{"prefix": "Photos/2026"})
	if err != nil {
		t.Fatal(err)
	}
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/folders/clean", body)
	got := readAll(t, resp)
	if resp.StatusCode != http.StatusConflict || got != `{"error":"busy"}` {
		t.Fatalf("busy %d %s", resp.StatusCode, got)
	}
	assertActive(t, catalog, "ghost", "Photos/2026/event/Debbie.jpg")
	if _, err := os.Stat(filepath.Join(root, "Photos", "2026", "album", "Debbie.jpg")); err != nil {
		t.Fatal(err)
	}
}

func TestCleanFolderRefusesABadPrefix(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	client, base := reorgServer(t, root, catalog, nil)
	for _, prefix := range []string{"Photos/_Duplicates", "Photos/_Removed", "../Photos", "Movies", `Photos\hidden`} {
		body, err := json.Marshal(map[string]string{"prefix": prefix})
		if err != nil {
			t.Fatal(err)
		}
		resp := authorizedSend(t, client, http.MethodPost, base+"/v1/folders/clean", body)
		got := readAll(t, resp)
		if resp.StatusCode != http.StatusBadRequest || got != `{"error":"prefix"}` {
			t.Fatalf("prefix %q %d %s", prefix, resp.StatusCode, got)
		}
	}
}

func postClean(t *testing.T, client *http.Client, base, prefix string) (int, int) {
	t.Helper()
	body, err := json.Marshal(map[string]string{"prefix": prefix})
	if err != nil {
		t.Fatal(err)
	}
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/folders/clean", body)
	raw := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("clean %d %s", resp.StatusCode, raw)
	}
	var result cleanResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatal(err)
	}
	return result.Removed, result.Kept
}

func insertAPIRow(t *testing.T, catalog *db.Catalog, uid, rel string, size int) {
	t.Helper()
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, placement,
			discovered_at, updated_at
		) VALUES (?, ?, ?, 'jpg', 'image', 'move', 'placed', 'active', '2026-11-09T00:00:00Z', '2026-11-09T00:00:00Z')`,
		uid, rel, size)
	if err != nil {
		t.Fatal(err)
	}
}

func removeFile(t *testing.T, root, rel string) {
	t.Helper()
	if err := os.Remove(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
		t.Fatal(err)
	}
}

func assertPurged(t *testing.T, catalog *db.Catalog, uid string) {
	t.Helper()
	var placement, rel string
	if err := catalog.Read.QueryRow(`SELECT placement, rel_path FROM assets WHERE uid = ?`, uid).Scan(&placement, &rel); err != nil {
		t.Fatal(err)
	}
	if placement != "purged" || rel != ".zimage/purged/"+uid {
		t.Fatalf("%s placement %s path %s", uid, placement, rel)
	}
}

func assertActive(t *testing.T, catalog *db.Catalog, uid, rel string) {
	t.Helper()
	var placement, got string
	if err := catalog.Read.QueryRow(`SELECT placement, rel_path FROM assets WHERE uid = ?`, uid).Scan(&placement, &got); err != nil {
		t.Fatal(err)
	}
	if placement != "active" || got != rel {
		t.Fatalf("%s placement %s path %s", uid, placement, got)
	}
}
