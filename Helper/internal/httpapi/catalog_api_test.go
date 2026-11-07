package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/db"
)

func TestDatingRoutesDoNotMoveBytes(t *testing.T) {
	root := t.TempDir()
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer catalog.Close()
	rel := "Photos/old/keep.jpg"
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	payload := []byte("untouched-bytes")
	if err := os.WriteFile(full, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	insertAPIAsset(t, catalog, "keepuid", rel, 0.95, "")
	insertAPIAsset(t, catalog, "parkuid", "Photos/old/park.jpg", 0.4, "")
	insertAPIAsset(t, catalog, "reviewuid", "Photos/_Review/Undated/ab/already.jpg", 0.95, "")
	insertAPIAsset(t, catalog, "yearuid", "Photos/1964/scan.jpg", 0.75, "1964")
	insertAPIAsset(t, catalog, "pctuid", "Photos/100%_keep.jpg", 0.2, "")
	insertAPIAsset(t, catalog, "otheruid", "Photos/100Xkeep.jpg", 0.2, "")
	if _, err := catalog.Write.Exec(`INSERT INTO events (uid, name, name_source, slug, folder_rel) VALUES ('ev1', 'Madrid', 'album', 'madrid', 'Photos/2020/2020-05-01/madrid')`); err != nil {
		t.Fatal(err)
	}

	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(root, true, true, "token-value", catalog, pair, leaf)
	client, base := startServer(t, server)

	review := authorizedGet(t, client, base+"/v1/assets?review=1")
	body := readAll(t, review)
	if review.StatusCode != http.StatusOK || !bytesContain(body, "parkuid") || !bytesContain(body, "reviewuid") || bytesContain(body, "keepuid") {
		t.Fatalf("review %d %s", review.StatusCode, body)
	}
	year := authorizedGet(t, client, base+"/v1/assets?year=1964")
	yearBody := readAll(t, year)
	if !bytesContain(yearBody, "yearuid") || bytesContain(yearBody, "parkuid") {
		t.Fatalf("year %s", yearBody)
	}
	q := authorizedGet(t, client, base+"/v1/assets?q="+urlQuery("100%_"))
	qBody := readAll(t, q)
	if !bytesContain(qBody, "pctuid") || bytesContain(qBody, "otheruid") {
		t.Fatalf("query %s", qBody)
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			capture_confidence, capture_time, discovered_at, updated_at
		) VALUES
			('later', 'Photos/old/later.mp4', 8, 'mp4', 'video', 'move', 'discovered', 0.9, '2020-05-01T12:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
			('earlier', 'Photos/old/earlier.mov', 8, 'mov', 'video', 'move', 'discovered', 0.9, '2014-07-04T15:30:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	videos := authorizedGet(t, client, base+"/v1/assets?media=video")
	videoBody := readAll(t, videos)
	earlierAt := bytes.Index([]byte(videoBody), []byte("earlier"))
	laterAt := bytes.Index([]byte(videoBody), []byte("later"))
	if videos.StatusCode != http.StatusOK || earlierAt < 0 || laterAt < 0 || earlierAt > laterAt || bytesContain(videoBody, "keepuid") {
		t.Fatalf("videos %d %s", videos.StatusCode, videoBody)
	}
	photos := authorizedGet(t, client, base+"/v1/assets?media=photo")
	photoBody := readAll(t, photos)
	if photos.StatusCode != http.StatusOK || bytesContain(photoBody, "earlier") || !bytesContain(photoBody, "keepuid") {
		t.Fatalf("photos %d %s", photos.StatusCode, photoBody)
	}
	badMedia := authorizedGet(t, client, base+"/v1/assets?media=audio")
	badBody := readAll(t, badMedia)
	if badMedia.StatusCode != http.StatusBadRequest || badBody != `{"error":"media"}` {
		t.Fatalf("media %d %s", badMedia.StatusCode, badBody)
	}

	facts := map[string]any{
		"dhash":             "0000000000000007",
		"width":             32,
		"height":            16,
		"thumbnail":         base64.StdEncoding.EncodeToString([]byte{1, 2, 3, 4}),
		"captureTime":       "2020-05-01T12:00:00Z",
		"captureConfidence": 1,
		"isKeeper":          true,
	}
	raw, _ := json.Marshal(facts)
	resp := authorizedSend(t, client, http.MethodPut, base+"/v1/assets/parkuid/facts", raw)
	text := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("facts %d %s", resp.StatusCode, text)
	}
	if bytesContain(text, `"captureConfidence":1`) || !bytesContain(text, "mac_suggest") || !bytesContain(text, "0000000000000007") {
		t.Fatalf("suggestion %s", text)
	}
	var conf float64
	var source, phase string
	if err := catalog.Read.QueryRow(`SELECT capture_confidence, capture_source, phase FROM assets WHERE uid = 'parkuid'`).Scan(&conf, &source, &phase); err != nil {
		t.Fatal(err)
	}
	if conf >= 1 || source != "mac_suggest" || phase != "thumbed" {
		t.Fatalf("stored %v %s %s", conf, source, phase)
	}
	var cacheRows int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM cache_objects`).Scan(&cacheRows); err != nil {
		t.Fatal(err)
	}
	if cacheRows != 0 {
		t.Fatal("cache ledger")
	}

	if _, err := catalog.Write.Exec(`UPDATE assets SET capture_source = 'user', capture_confidence = 1 WHERE uid = 'keepuid'`); err != nil {
		t.Fatal(err)
	}
	userFacts, _ := json.Marshal(map[string]any{"captureTime": "2019-01-01T00:00:00Z", "captureConfidence": 1})
	resp = authorizedSend(t, client, http.MethodPut, base+"/v1/assets/keepuid/facts", userFacts)
	readAll(t, resp)
	if err := catalog.Read.QueryRow(`SELECT capture_confidence, COALESCE(capture_source, '') FROM assets WHERE uid = 'keepuid'`).Scan(&conf, &source); err != nil {
		t.Fatal(err)
	}
	if conf != 1 || source != "user" {
		t.Fatalf("user overwritten %v %s", conf, source)
	}

	detailBody, _ := json.Marshal(map[string]any{
		"detailScore":  2.5,
		"nativePixels": 512,
		"width":        32,
		"height":       16,
		"detailSource": "mac",
		"isKeeper":     true,
	})
	resp = authorizedSend(t, client, http.MethodPut, base+"/v1/assets/parkuid/detail", detailBody)
	detailText := readAll(t, resp)
	if resp.StatusCode != http.StatusOK || bytesContain(detailText, `"isKeeper":true`) {
		t.Fatalf("detail %d %s", resp.StatusCode, detailText)
	}
	var keeper int
	if err := catalog.Read.QueryRow(`SELECT is_keeper, detail_source FROM assets WHERE uid = 'parkuid'`).Scan(&keeper, &source); err != nil {
		t.Fatal(err)
	}
	if keeper != 0 || source != "mac" {
		t.Fatalf("keeper %d %s", keeper, source)
	}

	dateBody, _ := json.Marshal(map[string]any{"captureTime": "2020-05-01T15:04:05Z"})
	resp = authorizedSend(t, client, http.MethodPost, base+"/v1/assets/keepuid/date", dateBody)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("date %d %s", resp.StatusCode, readAll(t, resp))
	}
	readAll(t, resp)
	got, err := os.ReadFile(full)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(payload) {
		t.Fatal("bytes moved")
	}
	var state, dest string
	if err := catalog.Read.QueryRow(`SELECT state, dest_rel FROM journal WHERE asset_id = (SELECT id FROM assets WHERE uid = 'keepuid')`).Scan(&state, &dest); err != nil {
		t.Fatal(err)
	}
	if state != "planned" || dest == "" {
		t.Fatalf("journal %s %s", state, dest)
	}
	var nameSource string
	if err := catalog.Read.QueryRow(`SELECT name_source FROM events WHERE uid = 'ev1'`).Scan(&nameSource); err != nil {
		t.Fatal(err)
	}
	if nameSource != "album" {
		t.Fatal(nameSource)
	}
	one := authorizedGet(t, client, base+"/v1/assets/yearuid")
	oneBody := readAll(t, one)
	if one.StatusCode != http.StatusOK || !bytesContain(oneBody, `"phase"`) || !bytesContain(oneBody, "Photos/1964/scan.jpg") {
		t.Fatalf("one %d %s", one.StatusCode, oneBody)
	}
	events := authorizedGet(t, client, base+"/v1/events")
	if events.StatusCode != http.StatusOK || !bytesContain(readAll(t, events), "Madrid") {
		t.Fatal("events")
	}
}

func insertAPIAsset(t *testing.T, catalog *db.Catalog, uid, rel string, confidence float64, capture string) {
	t.Helper()
	var stored any
	if capture != "" {
		stored = capture
	}
	_, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase,
			capture_confidence, capture_time, discovered_at, updated_at
		) VALUES (?, ?, 20, 'jpg', 'image', 'move', 'discovered', ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`,
		uid, rel, confidence, stored)
	if err != nil {
		t.Fatal(err)
	}
}

func authorizedSend(t *testing.T, client *http.Client, method, url string, body []byte) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, url, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer token-value")
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func bytesContain(body, part string) bool {
	return bytes.Contains([]byte(body), []byte(part))
}

func urlQuery(text string) string {
	return url.QueryEscape(text)
}
