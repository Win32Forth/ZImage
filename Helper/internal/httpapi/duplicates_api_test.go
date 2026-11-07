package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"zimage/helper/internal/trim"
)

func TestManualMoveCreatesAGroupOfOne(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	payload := []byte("solo-bytes")
	insertAPIMember(t, root, catalog, 0, "solo", "Photos/2020/event/solo.jpg", payload, 1_000_000, nil, 0)
	if _, err := catalog.Write.Exec(`UPDATE assets SET derivative_group_id = NULL WHERE uid = 'solo'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/solo/to-duplicates", nil)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("move %d %s", resp.StatusCode, body)
	}
	var asset assetJSON
	if err := json.Unmarshal([]byte(body), &asset); err != nil {
		t.Fatal(err)
	}
	if asset.Placement != "duplicates" || !strings.HasPrefix(asset.RelPath, "Photos/_Duplicates/") || !strings.HasSuffix(asset.RelPath, "/solo.jpg") {
		t.Fatalf("asset %+v", asset)
	}
	got, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(asset.RelPath)))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("store bytes")
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "2020", "event", "solo.jpg")); !os.IsNotExist(err) {
		t.Fatal("source remained")
	}
	var reason string
	var groups int
	if err := catalog.Read.QueryRow(`SELECT COALESCE(duplicate_reason, ''), (SELECT COUNT(*) FROM derivative_groups) FROM assets WHERE uid = 'solo'`).Scan(&reason, &groups); err != nil {
		t.Fatal(err)
	}
	if reason != "manual" || groups != 1 {
		t.Fatalf("reason %s groups %d", reason, groups)
	}
}

func TestRestorePinsBesideTheKeeperAndTrimSkipsIt(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	group := insertAPIGroup(t, catalog, "g1")
	insertAPIMember(t, root, catalog, group, "a", "Photos/2020/event/a.jpg", []byte("keeper"), 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, group, "b", "Photos/_Duplicates/g1/b.jpg", []byte("copy"), 16_000_000, 10.0, 0)
	if _, err := catalog.Write.Exec(`UPDATE assets SET placement = 'duplicates', is_keeper = 0 WHERE uid = 'b'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE assets SET is_keeper = 1 WHERE uid = 'a'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE derivative_groups SET keeper_asset_id = (SELECT id FROM assets WHERE uid = 'a') WHERE uid = 'g1'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/b/restore", nil)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("restore %d %s", resp.StatusCode, body)
	}
	var asset assetJSON
	if err := json.Unmarshal([]byte(body), &asset); err != nil {
		t.Fatal(err)
	}
	if asset.RelPath != "Photos/2020/event/b.jpg" || !asset.Pinned || asset.Placement != "active" || strings.Contains(asset.RelPath, "_Duplicates") {
		t.Fatalf("restored %+v", asset)
	}
	got, err := os.ReadFile(filepath.Join(root, "Photos", "2020", "event", "b.jpg"))
	if err != nil || string(got) != "copy" {
		t.Fatal("restored bytes")
	}
	if err := trim.Plan(catalog); err != nil {
		t.Fatal(err)
	}
	var rows int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE asset_id = (SELECT id FROM assets WHERE uid = 'b') AND state = 'planned'`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("trim planned the pinned file %d %v", rows, err)
	}
	var rel string
	if err := catalog.Read.QueryRow(`SELECT rel_path FROM assets WHERE uid = 'a'`).Scan(&rel); err != nil || rel != "Photos/2020/event/a.jpg" {
		t.Fatalf("keeper %s", rel)
	}
}

func TestRestoreFallsBackWhenTheKeeperIsInTheStore(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	group := insertAPIGroup(t, catalog, "g1")
	insertAPIMember(t, root, catalog, group, "k", "Photos/_Duplicates/g1/k.jpg", []byte("keeper"), 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, group, "b", "Photos/_Duplicates/g1/b.jpg", []byte("copy"), 1_000_000, 10.0, 0)
	if _, err := catalog.Write.Exec(`UPDATE derivative_groups SET keeper_asset_id = (SELECT id FROM assets WHERE uid = 'k') WHERE uid = 'g1'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE assets SET placement = 'duplicates' WHERE uid IN ('k', 'b')`); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "Photos", "2019", "old"), 0o750); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES ((SELECT id FROM assets WHERE uid = 'b'), 'trim', 'done', 'Photos/2019/old/b.jpg', 'Photos/_Duplicates/g1/b.jpg', 4, '2026-11-05T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/b/restore", nil)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusOK || strings.Contains(body, "_Duplicates") {
		t.Fatalf("restore %d %s", resp.StatusCode, body)
	}
	var asset assetJSON
	if err := json.Unmarshal([]byte(body), &asset); err != nil {
		t.Fatal(err)
	}
	if asset.RelPath != "Photos/2019/old/b.jpg" || !asset.Pinned {
		t.Fatalf("fallback %+v", asset)
	}
}

func TestRestoreUsesReviewWhenNoDirectoryRemains(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	group := insertAPIGroup(t, catalog, "g1")
	insertAPIMember(t, root, catalog, group, "b", "Photos/_Duplicates/g1/b.jpg", []byte("copy"), 1_000_000, 10.0, 0)
	if _, err := catalog.Write.Exec(`UPDATE assets SET placement = 'duplicates' WHERE uid = 'b'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/b/restore", nil)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("restore %d %s", resp.StatusCode, body)
	}
	var asset assetJSON
	if err := json.Unmarshal([]byte(body), &asset); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(asset.RelPath, "Photos/_Review/Undated/") || strings.Contains(asset.RelPath, "_Duplicates") || !asset.Pinned {
		t.Fatalf("review %+v", asset)
	}
}

func TestPurgeRequiresTheFilenameAndLeavesOtherFiles(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	insertAPIMember(t, root, catalog, 0, "b", "Photos/_Duplicates/g1/b.jpg", []byte("copy"), 1_000_000, 10.0, 0)
	if _, err := catalog.Write.Exec(`UPDATE assets SET placement = 'duplicates', derivative_group_id = NULL, blake3 = ? WHERE uid = 'b'`, bytes.Repeat([]byte{7}, 32)); err != nil {
		t.Fatal(err)
	}
	writeMoveAsset(t, root, catalog, "keep", "Photos/1999/keep.jpg", []byte("year"), "1999-01-02T00:00:00Z", 0.95)
	client, base := reorgServer(t, root, catalog, nil)

	wrong := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/b/purge", []byte(`{"confirmFilename":"nope.jpg"}`))
	wrongBody := readAll(t, wrong)
	if wrong.StatusCode != http.StatusBadRequest || wrongBody != `{"error":"confirm"}` {
		t.Fatalf("wrong %d %s", wrong.StatusCode, wrongBody)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "b.jpg")); err != nil {
		t.Fatal(err)
	}
	year := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/keep/purge", []byte(`{"confirmFilename":"keep.jpg"}`))
	yearBody := readAll(t, year)
	if year.StatusCode != http.StatusBadRequest {
		t.Fatalf("year %d %s", year.StatusCode, yearBody)
	}
	if got, err := os.ReadFile(filepath.Join(root, "Photos", "1999", "keep.jpg")); err != nil || string(got) != "year" {
		t.Fatal("year file changed")
	}

	okResp := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/b/purge", []byte(`{"confirmFilename":"b.jpg"}`))
	okBody := readAll(t, okResp)
	if okResp.StatusCode != http.StatusOK {
		t.Fatalf("purge %d %s", okResp.StatusCode, okBody)
	}
	var asset assetJSON
	if err := json.Unmarshal([]byte(okBody), &asset); err != nil {
		t.Fatal(err)
	}
	if asset.RelPath != ".zimage/purged/b" || asset.Placement != "purged" {
		t.Fatalf("tombstone %+v", asset)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "b.jpg")); !os.IsNotExist(err) {
		t.Fatal("store file remained")
	}
	var hash []byte
	if err := catalog.Read.QueryRow(`SELECT blake3 FROM assets WHERE uid = 'b'`).Scan(&hash); err != nil || !bytes.Equal(hash, bytes.Repeat([]byte{7}, 32)) {
		t.Fatal("blake3 dropped")
	}
	if got, err := os.ReadFile(filepath.Join(root, "Photos", "1999", "keep.jpg")); err != nil || string(got) != "year" {
		t.Fatal("year file after purge")
	}
}

func TestPurgeAllRequiresDeleteAndSkipsTheYearFolder(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	insertAPIMember(t, root, catalog, 0, "b", "Photos/_Duplicates/g1/b.jpg", []byte("one"), 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, 0, "c", "Photos/_Duplicates/g1/c.jpg", []byte("two"), 1_000_000, 10.0, 0)
	if _, err := catalog.Write.Exec(`UPDATE assets SET placement = 'duplicates', derivative_group_id = NULL WHERE uid IN ('b', 'c')`); err != nil {
		t.Fatal(err)
	}
	writeMoveAsset(t, root, catalog, "keep", "Photos/1999/keep.jpg", []byte("year"), "1999-01-02T00:00:00Z", 0.95)
	client, base := reorgServer(t, root, catalog, nil)
	refused := authorizedSend(t, client, http.MethodPost, base+"/v1/duplicates/purge-all", []byte(`{"confirm":"delete"}`))
	refusedBody := readAll(t, refused)
	if refused.StatusCode != http.StatusBadRequest || refusedBody != `{"error":"confirm"}` {
		t.Fatalf("refused %d %s", refused.StatusCode, refusedBody)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "b.jpg")); err != nil {
		t.Fatal("refused unlinked")
	}
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/duplicates/purge-all", []byte(`{"confirm":"DELETE"}`))
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusOK || body != `{"purged":2}` {
		t.Fatalf("purge-all %d %s", resp.StatusCode, body)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "b.jpg")); !os.IsNotExist(err) {
		t.Fatal("b remained")
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "c.jpg")); !os.IsNotExist(err) {
		t.Fatal("c remained")
	}
	if got, err := os.ReadFile(filepath.Join(root, "Photos", "1999", "keep.jpg")); err != nil || string(got) != "year" {
		t.Fatal("year file")
	}
	var pause int
	if err := catalog.Read.QueryRow(`SELECT pause_requested FROM job_state WHERE job_kind = 'trim'`).Scan(&pause); err != nil || pause != 0 {
		t.Fatalf("trim pause %d %v", pause, err)
	}
}

func TestSecondTrimReusesTheStoreFilename(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	group := insertAPIGroup(t, catalog, "g1")
	insertAPIMember(t, root, catalog, group, "a", "Photos/2020/event/a.jpg", []byte("sharp-1000-bytes"), 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, group, "b", "Photos/_Duplicates/g1/b.jpg", []byte("old-copy"), 16_000_000, 10.0, 0)
	if _, err := catalog.Write.Exec(`UPDATE assets SET placement = 'duplicates' WHERE uid = 'b'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE assets SET is_keeper = 1 WHERE uid = 'a'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE derivative_groups SET keeper_asset_id = (SELECT id FROM assets WHERE uid = 'a') WHERE uid = 'g1'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	listed := authorizedGet(t, client, base+"/v1/duplicates?group=g1")
	listedBody := readAll(t, listed)
	if listed.StatusCode != http.StatusOK || !strings.Contains(listedBody, `"uid":"b"`) || !strings.Contains(listedBody, `"uid":"a"`) {
		t.Fatalf("list %d %s", listed.StatusCode, listedBody)
	}
	purged := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/b/purge", []byte(`{"confirmFilename":"b.jpg"}`))
	if purged.StatusCode != http.StatusOK {
		t.Fatalf("purge %d %s", purged.StatusCode, readAll(t, purged))
	}
	purged.Body.Close()
	insertAPIMember(t, root, catalog, group, "b2", "Photos/2020/event/b.jpg", []byte("new-copy-bytes"), 16_000_000, 10.0, 0)
	started := authorizedSend(t, client, http.MethodPost, base+"/v1/trim/start", nil)
	if started.StatusCode != http.StatusOK {
		t.Fatalf("trim %d %s", started.StatusCode, readAll(t, started))
	}
	started.Body.Close()
	_ = waitTrim(t, client, base, "completed")
	var rel, place string
	if err := catalog.Read.QueryRow(`SELECT rel_path, placement FROM assets WHERE uid = 'b2'`).Scan(&rel, &place); err != nil {
		t.Fatal(err)
	}
	if rel != "Photos/_Duplicates/g1/b.jpg" || place != "duplicates" {
		t.Fatalf("reused %s %s", rel, place)
	}
	got, err := os.ReadFile(filepath.Join(root, "Photos", "_Duplicates", "g1", "b.jpg"))
	if err != nil || string(got) != "new-copy-bytes" {
		t.Fatal("new bytes")
	}
	var keeper string
	if err := catalog.Read.QueryRow(`SELECT rel_path FROM assets WHERE uid = 'a'`).Scan(&keeper); err != nil || keeper != "Photos/2020/event/a.jpg" {
		t.Fatalf("keeper %s", keeper)
	}
}

func TestPinClearIsItsOwnControl(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	insertAPIMember(t, root, catalog, 0, "a", "Photos/2020/event/a.jpg", []byte("a"), 1_000_000, 10.0, 0)
	if _, err := catalog.Write.Exec(`UPDATE assets SET derivative_group_id = NULL WHERE uid = 'a'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	on := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/a/pin", []byte(`{"pinned":true}`))
	onBody := readAll(t, on)
	if on.StatusCode != http.StatusOK || !strings.Contains(onBody, `"pinned":true`) {
		t.Fatalf("pin %d %s", on.StatusCode, onBody)
	}
	off := authorizedSend(t, client, http.MethodPost, base+"/v1/assets/a/pin", []byte(`{"pinned":false}`))
	offBody := readAll(t, off)
	if off.StatusCode != http.StatusOK || !strings.Contains(offBody, `"pinned":false`) {
		t.Fatalf("clear %d %s", off.StatusCode, offBody)
	}
}

func TestFindListsMatchesThatAreStillInTheLibrary(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	group := insertAPIGroup(t, catalog, "gfound")
	insertAPIMember(t, root, catalog, group, "sharp", "Photos/2020/event/sharp.jpg", []byte("sharp"), 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, group, "soft", "Photos/2020/event/soft.jpg", []byte("soft"), 16_000_000, 4.0, 0)
	alone := insertAPIGroup(t, catalog, "galone")
	insertAPIMember(t, root, catalog, alone, "only", "Photos/2020/event/only.jpg", []byte("only"), 1_000_000, 8.0, 0)
	client, base := reorgServer(t, root, catalog, nil)

	stored := authorizedGet(t, client, base+"/v1/duplicates")
	storedBody := readAll(t, stored)
	if stored.StatusCode != http.StatusOK || strings.Contains(storedBody, "sharp") || strings.Contains(storedBody, "soft") {
		t.Fatalf("store list %d %s", stored.StatusCode, storedBody)
	}

	found := authorizedGet(t, client, base+"/v1/duplicates?found=1")
	foundBody := readAll(t, found)
	if found.StatusCode != http.StatusOK || !strings.Contains(foundBody, `"uid":"sharp"`) || !strings.Contains(foundBody, `"uid":"soft"`) || strings.Contains(foundBody, `"uid":"only"`) {
		t.Fatalf("find %d %s", found.StatusCode, foundBody)
	}
}
