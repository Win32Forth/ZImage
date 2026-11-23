package httpapi

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"zimage/helper/internal/db"
)

func TestRescanAddsAFileAndDropsADeletedOne(t *testing.T) {
	root := t.TempDir()
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "keep.jpg"))
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "gone.jpg"))
	catalog := openAPICatalog(t, root)
	client, base := reorgServer(t, root, catalog, nil)

	status := postRescan(t, client, base, "Photos/Day")
	status = waitRescan(t, client, base, status)
	if status.RunState != "completed" || status.Added != 2 || status.Removed != 0 {
		t.Fatalf("first %+v", status)
	}

	if err := os.Remove(filepath.Join(root, "Photos", "Day", "gone.jpg")); err != nil {
		t.Fatal(err)
	}
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "fresh.jpg"))
	status = postRescan(t, client, base, "Photos/Day")
	status = waitRescan(t, client, base, status)
	if status.RunState != "completed" || status.Added != 1 || status.Removed != 1 {
		t.Fatalf("second %+v", status)
	}
	if !apiRelExists(t, catalog, "Photos/Day/fresh.jpg") || !apiRelExists(t, catalog, "Photos/Day/keep.jpg") {
		t.Fatal("present files")
	}
	if apiRelExists(t, catalog, "Photos/Day/gone.jpg") {
		t.Fatal("deleted file stayed")
	}

	for _, prefix := range []string{"", "Movies", "Photos/../Secret"} {
		code, body := postRescanRaw(t, client, base, prefix)
		if code != http.StatusBadRequest || body != `{"error":"prefix"}` {
			t.Fatalf("reject %q %d %s", prefix, code, body)
		}
	}
	req, err := http.NewRequest(http.MethodPost, base+"/v1/folders/rescan", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("auth %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func postRescan(t *testing.T, client *http.Client, base, prefix string) folderScanStatus {
	t.Helper()
	code, body := postRescanRaw(t, client, base, prefix)
	if code != http.StatusOK {
		t.Fatalf("post %d %s", code, body)
	}
	var status folderScanStatus
	if err := json.Unmarshal([]byte(body), &status); err != nil {
		t.Fatal(err)
	}
	return status
}

func postRescanRaw(t *testing.T, client *http.Client, base, prefix string) (int, string) {
	t.Helper()
	body, err := json.Marshal(map[string]string{"prefix": prefix})
	if err != nil {
		t.Fatal(err)
	}
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/folders/rescan", body)
	return resp.StatusCode, readAll(t, resp)
}

func waitRescan(t *testing.T, client *http.Client, base string, status folderScanStatus) folderScanStatus {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for status.RunState == "running" {
		if time.Now().After(deadline) {
			t.Fatalf("timed out %+v", status)
		}
		time.Sleep(20 * time.Millisecond)
		resp := authorizedGet(t, client, base+"/v1/folders/rescan")
		body := readAll(t, resp)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status %d %s", resp.StatusCode, body)
		}
		if err := json.Unmarshal([]byte(body), &status); err != nil {
			t.Fatal(err)
		}
	}
	return status
}

func TestRescanPageChecksOnlyTheListedFiles(t *testing.T) {
	root := t.TempDir()
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "keep.jpg"))
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "gone.jpg"))
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "other.jpg"))
	catalog := openAPICatalog(t, root)
	client, base := reorgServer(t, root, catalog, nil)

	status := postRescan(t, client, base, "Photos/Day")
	status = waitRescan(t, client, base, status)
	if status.RunState != "completed" || status.Added != 3 || status.Removed != 0 {
		t.Fatalf("seed %+v", status)
	}
	if err := os.Remove(filepath.Join(root, "Photos", "Day", "gone.jpg")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "Photos", "Day", "other.jpg")); err != nil {
		t.Fatal(err)
	}
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "fresh.jpg"))
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "stray.jpg"))

	status = postPageRescan(t, client, base, "Photos/Day", []string{
		"Photos/Day/keep.jpg",
		"Photos/Day/gone.jpg",
		"Photos/Day/fresh.jpg",
	})
	status = waitRescan(t, client, base, status)
	if status.RunState != "completed" || status.Added != 1 || status.Removed != 1 || status.Total != 3 {
		t.Fatalf("page %+v", status)
	}
	if !apiRelExists(t, catalog, "Photos/Day/keep.jpg") || !apiRelExists(t, catalog, "Photos/Day/fresh.jpg") {
		t.Fatal("listed files")
	}
	if apiRelExists(t, catalog, "Photos/Day/gone.jpg") {
		t.Fatal("listed missing file stayed")
	}
	if !apiRelExists(t, catalog, "Photos/Day/other.jpg") {
		t.Fatal("unlisted missing file was dropped")
	}
	if apiRelExists(t, catalog, "Photos/Day/stray.jpg") {
		t.Fatal("unlisted new file was added")
	}

	for _, item := range []struct {
		prefix string
		paths  []string
		error  string
	}{
		{"Movies", []string{"Movies/a.jpg"}, "prefix"},
		{"Photos/Day", nil, "paths"},
		{"Photos/Day", []string{"Photos/Daylight/a.jpg"}, "paths"},
		{"Photos/Day", []string{"Photos/Day/../Secret.jpg"}, "paths"},
	} {
		code, body := postPageRescanRaw(t, client, base, item.prefix, item.paths)
		if code != http.StatusBadRequest || body != `{"error":"`+item.error+`"}` {
			t.Fatalf("reject %+v %d %s", item, code, body)
		}
	}
	req, err := http.NewRequest(http.MethodPost, base+"/v1/folders/rescan-page", bytes.NewReader([]byte(`{"prefix":"Photos/Day","paths":["Photos/Day/keep.jpg"]}`)))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("auth %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestFullRescanIgnoresAPathList(t *testing.T) {
	root := t.TempDir()
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "a.jpg"))
	writeTinyJPEG(t, filepath.Join(root, "Photos", "Day", "b.jpg"))
	catalog := openAPICatalog(t, root)
	client, base := reorgServer(t, root, catalog, nil)
	payload, err := json.Marshal(map[string]any{
		"prefix": "Photos/Day",
		"paths":  []string{"Photos/Day/a.jpg"},
	})
	if err != nil {
		t.Fatal(err)
	}
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/folders/rescan", payload)
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("post %d %s", resp.StatusCode, body)
	}
	var status folderScanStatus
	if err := json.Unmarshal([]byte(body), &status); err != nil {
		t.Fatal(err)
	}
	status = waitRescan(t, client, base, status)
	if status.RunState != "completed" || status.Added != 2 {
		t.Fatalf("full scan %+v", status)
	}
	if !apiRelExists(t, catalog, "Photos/Day/a.jpg") || !apiRelExists(t, catalog, "Photos/Day/b.jpg") {
		t.Fatal("path list did not keep the full walk")
	}
}

func postPageRescan(t *testing.T, client *http.Client, base, prefix string, paths []string) folderScanStatus {
	t.Helper()
	code, body := postPageRescanRaw(t, client, base, prefix, paths)
	if code != http.StatusOK {
		t.Fatalf("page post %d %s", code, body)
	}
	var status folderScanStatus
	if err := json.Unmarshal([]byte(body), &status); err != nil {
		t.Fatal(err)
	}
	return status
}

func postPageRescanRaw(t *testing.T, client *http.Client, base, prefix string, paths []string) (int, string) {
	t.Helper()
	payload, err := json.Marshal(map[string]any{"prefix": prefix, "paths": paths})
	if err != nil {
		t.Fatal(err)
	}
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/folders/rescan-page", payload)
	return resp.StatusCode, readAll(t, resp)
}

func apiRelExists(t *testing.T, catalog *db.Catalog, rel string) bool {
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
