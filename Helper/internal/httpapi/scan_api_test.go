package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestDuplicateScanGroupsEqualBlake3(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	insertAPIMember(t, root, catalog, 0, "a", "Photos/2020/event/a.jpg", []byte("one"), 1_000_000, 10.0, 0)
	insertAPIMember(t, root, catalog, 0, "b", "Photos/2020/event/b.jpg", []byte("two"), 1_000_000, 10.0, 0)
	sum := bytes.Repeat([]byte{9}, 32)
	if _, err := catalog.Write.Exec(`UPDATE assets SET blake3 = ?, derivative_group_id = NULL WHERE uid IN ('a', 'b')`, sum); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`DELETE FROM derivative_groups`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	started := authorizedSend(t, client, http.MethodPost, base+"/v1/duplicates/scan", nil)
	startedBody := readAll(t, started)
	if started.StatusCode != http.StatusOK || !strings.Contains(startedBody, `"runState":"running"`) {
		t.Fatalf("start %d %s", started.StatusCode, startedBody)
	}
	deadline := time.Now().Add(5 * time.Second)
	var status scanStatus
	for {
		resp := authorizedGet(t, client, base+"/v1/duplicates/scan")
		body := readAll(t, resp)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status %d %s", resp.StatusCode, body)
		}
		if err := json.Unmarshal([]byte(body), &status); err != nil {
			t.Fatal(err)
		}
		if status.RunState == "completed" || status.RunState == "failed" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("scan %+v", status)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if status.RunState != "completed" || status.Groups != 1 {
		t.Fatalf("scan %+v", status)
	}
	listed := authorizedGet(t, client, base+"/v1/duplicates?found=1&limit=200")
	listedBody := readAll(t, listed)
	if listed.StatusCode != http.StatusOK || !strings.Contains(listedBody, `"uid":"a"`) || !strings.Contains(listedBody, `"uid":"b"`) {
		t.Fatalf("found %d %s", listed.StatusCode, listedBody)
	}
}

func TestPassBufferReadsWithoutTheCatalog(t *testing.T) {
	srv := &Server{}
	srv.SetPass("inventory", 10, 100)
	snap := srv.scanSnapshot()
	if snap.RunState != "idle" || snap.PassPhase != "inventory" || snap.PassDone != 10 || snap.PassTotal != 100 {
		t.Fatalf("%+v", snap)
	}
	srv.ClearPass()
	snap = srv.scanSnapshot()
	if snap.PassPhase != "" || snap.PassDone != 0 || snap.PassTotal != 0 {
		t.Fatalf("cleared %+v", snap)
	}
}

func TestDuplicateScanWaitsWhileReorgRuns(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	if _, err := catalog.Write.Exec(`UPDATE job_state SET run_state = 'running' WHERE job_kind = 'reorg'`); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	refused := authorizedSend(t, client, http.MethodPost, base+"/v1/duplicates/scan", nil)
	body := readAll(t, refused)
	if refused.StatusCode != http.StatusConflict || body != `{"error":"busy"}` {
		t.Fatalf("busy %d %s", refused.StatusCode, body)
	}
	status := authorizedGet(t, client, base+"/v1/duplicates/scan")
	statusBody := readAll(t, status)
	if status.StatusCode != http.StatusOK || !strings.Contains(statusBody, `"runState":"idle"`) {
		t.Fatalf("idle %d %s", status.StatusCode, statusBody)
	}
}
