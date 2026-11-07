package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/move"
)

func TestReorgPlanDoesNotCopy(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	payload := []byte("plan-keeps-these-bytes")
	writeMoveAsset(t, root, catalog, "madrid", "Photos/inbox/madrid.jpg", payload, "2020-05-01T12:00:00Z", 0.95)
	writeMoveAsset(t, root, catalog, "dup", "Photos/_Duplicates/ab/dup.jpg", []byte("stay"), "2020-05-01T12:00:00Z", 0.95)
	writeMoveAsset(t, root, catalog, "older", "Photos/1999/old.jpg", []byte("older"), "1999-01-02T00:00:00Z", 0.95)
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			discovered_at, updated_at
		) VALUES ('clip', 'Photos/inbox/clip.mov', 8, 'mov', 'video', 'leave', 'discovered', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)

	audio := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/plan", []byte(`{"prefix":"Audio"}`))
	audioBody := readAll(t, audio)
	if audio.StatusCode != http.StatusBadRequest || audioBody != `{"error":"prefix"}` {
		t.Fatalf("audio %d %s", audio.StatusCode, audioBody)
	}
	store := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/plan", []byte(`{"prefix":"Photos/_Duplicates"}`))
	storeBody := readAll(t, store)
	if store.StatusCode != http.StatusBadRequest || storeBody != `{"error":"prefix"}` {
		t.Fatalf("store %d %s", store.StatusCode, storeBody)
	}
	var rows int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("rows after refusal %d %v", rows, err)
	}

	planned := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/plan", []byte(`{"prefix":"Photos/inbox"}`))
	planBody := readAll(t, planned)
	if planned.StatusCode != http.StatusOK {
		t.Fatalf("plan %d %s", planned.StatusCode, planBody)
	}
	var counts struct {
		Move          int    `json:"move"`
		AlreadyPlaced int    `json:"alreadyPlaced"`
		Park          int    `json:"park"`
		Leave         int    `json:"leave"`
		Prefix        string `json:"prefix"`
	}
	if err := json.Unmarshal([]byte(planBody), &counts); err != nil {
		t.Fatal(err)
	}
	if counts.Move != 1 || counts.AlreadyPlaced != 0 || counts.Park != 0 || counts.Leave != 1 || counts.Prefix != "Photos/inbox" {
		t.Fatalf("counts %+v", counts)
	}
	dest := filepath.Join(root, "Photos", "2020", "2020-05-01", "inbox", "madrid.jpg")
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("plan wrote a destination")
	}
	got, err := os.ReadFile(filepath.Join(root, "Photos", "inbox", "madrid.jpg"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("source changed")
	}
	var dupRows int
	if err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal j JOIN assets a ON a.id = j.asset_id WHERE a.uid = 'dup'`).Scan(&dupRows); err != nil || dupRows != 0 {
		t.Fatalf("duplicates row %d %v", dupRows, err)
	}
	var olderRows int
	if err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal j JOIN assets a ON a.id = j.asset_id WHERE a.uid = 'older'`).Scan(&olderRows); err != nil || olderRows != 0 {
		t.Fatalf("outside prefix %d %v", olderRows, err)
	}

	statusResp := authorizedGet(t, client, base+"/v1/reorg/status")
	statusBody := readAll(t, statusResp)
	if statusResp.StatusCode != http.StatusOK || strings.Contains(strings.ToLower(statusBody), "trim") {
		t.Fatalf("status %d %s", statusResp.StatusCode, statusBody)
	}
	var status reorgStatus
	if err := json.Unmarshal([]byte(statusBody), &status); err != nil {
		t.Fatal(err)
	}
	if !status.ReorgSafeToReboot || status.RunState != "plan_ready" || status.Phase != "Photos/inbox" || status.Move != 1 || status.Leave != 1 || status.LastRecovery != "none" {
		t.Fatalf("status %+v", status)
	}
	healthResp := authorizedGet(t, client, base+"/v1/health")
	healthRaw := readAll(t, healthResp)
	var health healthBody
	if err := json.Unmarshal([]byte(healthRaw), &health); err != nil {
		t.Fatal(err)
	}
	if !health.ReorgSafeToReboot {
		t.Fatalf("planned row cleared the lamp %s", healthRaw)
	}

	paused := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/pause", nil)
	pausedBody := readAll(t, paused)
	if paused.StatusCode != http.StatusOK || strings.Contains(strings.ToLower(pausedBody), "trim") {
		t.Fatalf("pause %d %s", paused.StatusCode, pausedBody)
	}
	if err := json.Unmarshal([]byte(pausedBody), &status); err != nil {
		t.Fatal(err)
	}
	if !status.ReorgSafeToReboot || !status.PauseRequested || status.RunState != "plan_ready" {
		t.Fatalf("pause lamp %+v", status)
	}
	resumed := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/resume", nil)
	resumedBody := readAll(t, resumed)
	if resumed.StatusCode != http.StatusOK {
		t.Fatalf("resume %d %s", resumed.StatusCode, resumedBody)
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("resume copied")
	}
	got, err = os.ReadFile(filepath.Join(root, "Photos", "inbox", "madrid.jpg"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("resume changed the source")
	}
}

func TestReorgStartRequiresAPlan(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	payload := []byte("idle-source")
	writeMoveAsset(t, root, catalog, "madrid", "Photos/inbox/madrid.jpg", payload, "2020-05-01T12:00:00Z", 0.95)
	client, base := reorgServer(t, root, catalog, nil)
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/start", nil)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusConflict || body != `{"error":"plan"}` {
		t.Fatalf("start %d %s", resp.StatusCode, body)
	}
	dest := filepath.Join(root, "Photos", "2020", "2020-05-01", "inbox", "madrid.jpg")
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("start without a plan wrote a destination")
	}
	got, err := os.ReadFile(filepath.Join(root, "Photos", "inbox", "madrid.jpg"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("source changed")
	}
}

func TestReorgStartRefusesARunningTrim(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	payload := []byte("trim-holds-the-file")
	writeMoveAsset(t, root, catalog, "madrid", "Photos/inbox/madrid.jpg", payload, "2020-05-01T12:00:00Z", 0.95)
	if _, err := catalog.Write.Exec(`UPDATE job_state SET phase = 'Photos', run_state = 'plan_ready' WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running', pause_requested = 0 WHERE job_kind = 'trim'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/start", nil)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusConflict || body != `{"error":"trim"}` {
		t.Fatalf("start %d %s", resp.StatusCode, body)
	}
	var pause int
	if err := catalog.Read.QueryRow(`SELECT pause_requested FROM job_state WHERE job_kind = 'trim'`).Scan(&pause); err != nil || pause != 0 {
		t.Fatalf("trim pause %d %v", pause, err)
	}
	got, err := os.ReadFile(filepath.Join(root, "Photos", "inbox", "madrid.jpg"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("source changed")
	}
	var run string
	if err := catalog.Read.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = 'reorg'`).Scan(&run); err != nil || run != "plan_ready" {
		t.Fatalf("reorg run %s %v", run, err)
	}
}

func TestReorgMovesOneFile(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	payload := []byte("moved-once-bytes")
	writeMoveAsset(t, root, catalog, "madrid", "Photos/inbox/madrid.jpg", payload, "2020-05-01T12:00:00Z", 0.95)
	client, base := reorgServer(t, root, catalog, nil)
	planned := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/plan", []byte(`{"prefix":"Photos"}`))
	planBody := readAll(t, planned)
	if planned.StatusCode != http.StatusOK || !strings.Contains(planBody, `"move":1`) {
		t.Fatalf("plan %d %s", planned.StatusCode, planBody)
	}
	dest := filepath.Join(root, "Photos", "2020", "2020-05-01", "inbox", "madrid.jpg")
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("plan created the destination")
	}
	started := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/start", nil)
	startBody := readAll(t, started)
	if started.StatusCode != http.StatusOK {
		t.Fatalf("start %d %s", started.StatusCode, startBody)
	}
	status := waitReorg(t, client, base, "completed")
	if !status.ReorgSafeToReboot || status.Move != 0 {
		t.Fatalf("finished %+v", status)
	}
	got, err := os.ReadFile(dest)
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("dest %v %q", err, got)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "inbox", "madrid.jpg")); !os.IsNotExist(err) {
		t.Fatal("source still present")
	}
	var rel, state string
	if err := catalog.Read.QueryRow(`SELECT rel_path FROM assets WHERE uid = 'madrid'`).Scan(&rel); err != nil || rel != "Photos/2020/2020-05-01/inbox/madrid.jpg" {
		t.Fatalf("catalog %s %v", rel, err)
	}
	if err := catalog.Read.QueryRow(`SELECT state FROM journal`).Scan(&state); err != nil || state != "done" {
		t.Fatalf("journal %s %v", state, err)
	}
}

func TestReorgSecondStartIsBusy(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	payload := []byte("held-during-copy")
	writeMoveAsset(t, root, catalog, "madrid", "Photos/inbox/madrid.jpg", payload, "2020-05-01T12:00:00Z", 0.95)
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	runner := &move.Runner{
		Root:    root,
		Catalog: catalog,
		CopySleep: func() {
			close(entered)
			<-release
		},
	}
	client, base := reorgServer(t, root, catalog, runner)
	planned := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/plan", []byte(`{}`))
	if planned.StatusCode != http.StatusOK {
		t.Fatalf("plan %d %s", planned.StatusCode, readAll(t, planned))
	}
	readAll(t, planned)
	started := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/start", nil)
	if started.StatusCode != http.StatusOK {
		t.Fatalf("start %d %s", started.StatusCode, readAll(t, started))
	}
	readAll(t, started)
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("copy did not start")
	}
	again := authorizedSend(t, client, http.MethodPost, base+"/v1/reorg/start", nil)
	againBody := readAll(t, again)
	if again.StatusCode != http.StatusConflict || againBody != `{"error":"busy"}` {
		t.Fatalf("second start %d %s", again.StatusCode, againBody)
	}
	if _, err := os.Stat(filepath.Join(root, "Photos", "inbox", "madrid.jpg")); err != nil {
		t.Fatal("source missing while the copy is open")
	}
	once.Do(func() { close(release) })
	status := waitReorg(t, client, base, "completed")
	if !status.ReorgSafeToReboot {
		t.Fatalf("after copy %+v", status)
	}
	dest := filepath.Join(root, "Photos", "2020", "2020-05-01", "inbox", "madrid.jpg")
	got, err := os.ReadFile(dest)
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("dest %v", err)
	}
}

func TestReorgStatusAnswersWhileTheCountHoldsRead(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'planning', phase = 'Photos/2025' WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	rows, err := catalog.Read.Query(`SELECT job_kind FROM job_state`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	var blocked string
	err = catalog.Read.QueryRowContext(ctx, `SELECT run_state FROM job_state WHERE job_kind = 'reorg'`).Scan(&blocked)
	if err == nil {
		t.Fatal("read connection was free while its query was open")
	}
	server := &Server{Catalog: catalog}
	start := time.Now()
	body, err := server.currentReorgStatus()
	if err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > time.Second {
		t.Fatalf("status waited %s", time.Since(start))
	}
	if body.RunState != "planning" || body.Phase != "Photos/2025" || !body.ReorgSafeToReboot {
		t.Fatalf("status %+v", body)
	}
}

func openAPICatalog(t *testing.T, root string) *db.Catalog {
	t.Helper()
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = catalog.Close() })
	return catalog
}

func reorgServer(t *testing.T, root string, catalog *db.Catalog, runner *move.Runner) (*http.Client, string) {
	t.Helper()
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(root, true, true, "token-value", catalog, pair, leaf)
	if runner != nil {
		server.UseRunner(runner)
	}
	client, base := startServer(t, server)
	resp := getRetry(t, client, base+"/v1/health")
	resp.Body.Close()
	return client, base
}

func writeMoveAsset(t *testing.T, root string, catalog *db.Catalog, uid, rel string, payload []byte, capture string, confidence float64) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	var stored any
	if capture != "" {
		stored = capture
	}
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			capture_confidence, capture_time, discovered_at, updated_at
		) VALUES (?, ?, ?, 'jpg', 'image', 'move', 'discovered', ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`,
		uid, rel, len(payload), confidence, stored)
	if err != nil {
		t.Fatal(err)
	}
}

func waitReorg(t *testing.T, client *http.Client, base, want string) reorgStatus {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var status reorgStatus
	for {
		resp := authorizedGet(t, client, base+"/v1/reorg/status")
		body := readAll(t, resp)
		if strings.Contains(strings.ToLower(body), "trim") {
			t.Fatalf("status names trim %s", body)
		}
		if err := json.Unmarshal([]byte(body), &status); err != nil {
			t.Fatal(err)
		}
		if status.RunState == want || status.RunState == "blocked" || status.RunState == "failed" {
			if status.RunState != want {
				t.Fatalf("run %s %s", status.RunState, body)
			}
			return status
		}
		if time.Now().After(deadline) {
			t.Fatalf("timeout %s", body)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
