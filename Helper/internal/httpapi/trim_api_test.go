package httpapi

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/move"
)

func TestTrimStartWhileReorgIsRunningMovesNothing(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	writeMoveAsset(t, root, catalog, "a", "Photos/2020/event/a.jpg", []byte("stay"), "2020-05-01T12:00:00Z", 0.95)
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running', pause_requested = 0 WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/trim/start", nil)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusConflict || body != `{"error":"busy"}` {
		t.Fatalf("start %d %s", resp.StatusCode, body)
	}
	var rows int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("rows %d %v", rows, err)
	}
	var pause int
	var run string
	if err := catalog.Read.QueryRow(`SELECT run_state, pause_requested FROM job_state WHERE job_kind = 'reorg'`).Scan(&run, &pause); err != nil {
		t.Fatal(err)
	}
	if run != "running" || pause != 0 {
		t.Fatalf("reorg %s pause %d", run, pause)
	}
	got, err := os.ReadFile(filepath.Join(root, "Photos", "2020", "event", "a.jpg"))
	if err != nil || string(got) != "stay" {
		t.Fatal("source changed")
	}
	status := authorizedGet(t, client, base+"/v1/reorg/status")
	statusBody := readAll(t, status)
	if strings.Contains(strings.ToLower(statusBody), "trim") {
		t.Fatalf("reorg status names trim %s", statusBody)
	}
}

func TestTrimStartMovesTheLesserCopies(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	sharp := []byte("sharp-1000-bytes")
	large := []byte("large-4000-bytes-are-different")
	group := insertAPIGroup(t, catalog, "g1")
	insertAPIMember(t, root, catalog, group, "a", "Photos/2020/event/a.jpg", sharp, 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, group, "b", "Photos/2020/event/b.jpg", sharp, 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, group, "c", "Photos/2020/event/c.jpg", large, 16_000_000, 10.0, 0)
	nullGroup := insertAPIGroup(t, catalog, "g2")
	insertAPIMember(t, root, catalog, nullGroup, "e", "Photos/2020/event/e.jpg", []byte("e"), 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, nullGroup, "f", "Photos/2020/event/f.jpg", []byte("f"), 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, nullGroup, "h", "Photos/2020/event/h.jpg", []byte("missing-score"), 16_000_000, nil, 0)

	client, base := reorgServer(t, root, catalog, nil)
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/trim/start", nil)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start %d %s", resp.StatusCode, body)
	}
	status := waitTrim(t, client, base, "completed")
	if !status.SafeToReboot || status.Eligible != 1 || status.Moved != 2 || status.Waiting != 1 {
		t.Fatalf("status %+v", status)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "b.jpg")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "c.jpg")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "2020", "event", "a.jpg")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "2020", "event", "h.jpg")); err != nil {
		t.Fatal(err)
	}
	var keeper int
	var place string
	if err := catalog.Read.QueryRow(`SELECT is_keeper, placement FROM assets WHERE uid = 'a'`).Scan(&keeper, &place); err != nil {
		t.Fatal(err)
	}
	if keeper != 1 || place != "active" {
		t.Fatalf("keeper %d %s", keeper, place)
	}
	reorg := authorizedGet(t, client, base+"/v1/reorg/status")
	reorgBody := readAll(t, reorg)
	if strings.Contains(strings.ToLower(reorgBody), "trim") {
		t.Fatalf("reorg status names trim %s", reorgBody)
	}
}

func TestManualCopyingClearsTheCombinedBit(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	client, base := reorgServer(t, root, catalog, nil)
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at)
		VALUES ('m', 'Photos/a.jpg', 4, 'jpg', 'image', 'move', 'discovered', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at)
		VALUES (1, 'manual_duplicate', 'planned', 'Photos/a.jpg', 'Photos/_Duplicates/g/a.jpg', 4, '2026-11-05T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	health := readHealth(t, client, base)
	if !health.ManualOpsClear || !health.ReorgSafeToReboot || !health.TrimSafeToReboot {
		t.Fatalf("planned manual %+v", health)
	}
	if _, err := catalog.Write.Exec(`UPDATE journal SET state = 'copying' WHERE job_kind = 'manual_duplicate'`); err != nil {
		t.Fatal(err)
	}
	health = readHealth(t, client, base)
	if health.ManualOpsClear || !health.ReorgSafeToReboot || !health.TrimSafeToReboot {
		t.Fatalf("copying manual %+v", health)
	}
	if _, err := catalog.Write.Exec(`UPDATE journal SET job_kind = 'purge', state = 'purge_planned', src_rel = 'Photos/_Duplicates/g/a.jpg'`); err != nil {
		t.Fatal(err)
	}
	health = readHealth(t, client, base)
	if health.ManualOpsClear || !health.ReorgSafeToReboot || !health.TrimSafeToReboot {
		t.Fatalf("purge planned %+v", health)
	}
}

func TestTrimPauseDoesNotWriteTheReorgFlag(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	sharp := []byte("sharp-1000-bytes")
	large := []byte("large-4000-bytes-are-different")
	group := insertAPIGroup(t, catalog, "g1")
	insertAPIMember(t, root, catalog, group, "a", "Photos/2020/event/a.jpg", sharp, 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, group, "b", "Photos/2020/event/b.jpg", sharp, 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, group, "c", "Photos/2020/event/c.jpg", large, 16_000_000, 10.0, 0)
	started := make(chan struct{})
	release := make(chan struct{})
	runner := &move.Runner{Root: root, Catalog: catalog, JobKind: "trim", CopySleep: func() {
		close(started)
		<-release
	}}
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(root, true, true, "token-value", catalog, pair, leaf)
	server.UseTrim(runner)
	client, base := startServer(t, server)
	resp := getRetry(t, client, base+"/v1/health")
	resp.Body.Close()

	go func() {
		req, err := http.NewRequest(http.MethodPost, base+"/v1/trim/start", nil)
		if err != nil {
			return
		}
		req.Header.Set("Authorization", "Bearer token-value")
		resp, err := client.Do(req)
		if err != nil {
			return
		}
		resp.Body.Close()
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("copy did not start")
	}
	paused := authorizedSend(t, client, http.MethodPost, base+"/v1/trim/pause", nil)
	pausedBody := readAll(t, paused)
	if paused.StatusCode != http.StatusOK {
		t.Fatalf("pause %d %s", paused.StatusCode, pausedBody)
	}
	var pause int
	if err := catalog.Read.QueryRow(`SELECT pause_requested FROM job_state WHERE job_kind = 'reorg'`).Scan(&pause); err != nil || pause != 0 {
		t.Fatalf("reorg pause %d %v", pause, err)
	}
	var status trimStatus
	if err := json.Unmarshal([]byte(pausedBody), &status); err != nil {
		t.Fatal(err)
	}
	if status.SafeToReboot {
		t.Fatalf("lamp during copy %+v", status)
	}
	close(release)
	_ = waitTrim(t, client, base, "paused")
	if _, err := os.Stat(filepath.Join(root, "Photos", "2020", "event", "c.jpg")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "_Duplicates", "g1", "c.jpg")); !os.IsNotExist(err) {
		t.Fatal("paused trim moved the next file")
	}
}

func waitTrim(t *testing.T, client *http.Client, base, want string) trimStatus {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var status trimStatus
	for {
		resp := authorizedGet(t, client, base+"/v1/trim/status")
		body := readAll(t, resp)
		if strings.Contains(body, "Photos/") {
			t.Fatalf("trim status path %s", body)
		}
		if err := json.Unmarshal([]byte(body), &status); err != nil {
			t.Fatal(err)
		}
		if status.RunState == want {
			return status
		}
		if status.RunState == "blocked" || status.RunState == "failed" {
			t.Fatalf("run %s %s", status.RunState, body)
		}
		if time.Now().After(deadline) {
			t.Fatalf("timeout %s", body)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func readHealth(t *testing.T, client *http.Client, base string) healthBody {
	t.Helper()
	resp := authorizedGet(t, client, base+"/v1/health")
	body := readAll(t, resp)
	var health healthBody
	if err := json.Unmarshal([]byte(body), &health); err != nil {
		t.Fatal(err)
	}
	return health
}

func insertAPIGroup(t *testing.T, catalog *db.Catalog, uid string) int64 {
	t.Helper()
	res, err := catalog.Write.Exec(`INSERT INTO derivative_groups (uid, eligible) VALUES (?, 0)`, uid)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func insertAPIMember(t *testing.T, root string, catalog *db.Catalog, groupID int64, uid, rel string, payload []byte, pixels int64, score any, pinned int) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	var group any
	if groupID > 0 {
		group = groupID
	}
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			derivative_group_id, native_pixels, detail_score, pinned, placement,
			discovered_at, updated_at
		) VALUES (?, ?, ?, 'jpg', 'image', 'move', 'discovered', ?, ?, ?, ?, 'active', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z')`,
		uid, rel, len(payload), group, pixels, score, pinned)
	if err != nil {
		t.Fatal(err)
	}
}
