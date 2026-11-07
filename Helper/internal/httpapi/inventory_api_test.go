package httpapi

import (
	"bytes"
	"image"
	"image/jpeg"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/inventory"
	"zimage/helper/internal/thumb"
)

func TestAssetsListOmitsSkippedFiles(t *testing.T) {
	root := t.TempDir()
	photos := filepath.Join(root, "Photos")
	for i := 1; i <= 17; i++ {
		writeTinyJPEG(t, filepath.Join(photos, "img"+strconv.Itoa(i)+".jpg"))
	}
	writeTinyJPEG(t, filepath.Join(photos, "_Duplicates", "ab", "kept.jpg"))
	if err := os.MkdirAll(filepath.Join(photos, ".thumbnails"), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(photos, "Thumbs.db"), []byte("noise"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(photos, ".thumbnails", "hidden.jpg"), []byte("hidden"), 0o644); err != nil {
		t.Fatal(err)
	}
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer catalog.Close()
	if _, err := inventory.Run(root, catalog, inventory.Options{}); err != nil {
		t.Fatal(err)
	}
	if err := thumb.Apply(root, catalog, nil); err != nil {
		t.Fatal(err)
	}
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(root, true, true, "token-value", catalog, pair, leaf)
	client, base := startServer(t, server)
	resp := authorizedGet(t, client, base+"/v1/assets")
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d %s", resp.StatusCode, body)
	}
	if strings.Contains(body, "Thumbs.db") || strings.Contains(body, ".thumbnails") {
		t.Fatalf("skipped %s", body)
	}
	if !strings.Contains(body, "Photos/_Duplicates/ab/kept.jpg") || strings.Count(body, `"relPath"`) != 18 {
		t.Fatalf("rows %s", body)
	}
	uid := uidFor(t, catalog, "Photos/img1.jpg")
	resp = authorizedGet(t, client, base+"/v1/assets/"+uid+"/thumbnail")
	jpegBytes, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !thumb.LongEdgeIsBounded(jpegBytes) {
		t.Fatalf("thumbnail %d %d bytes", resp.StatusCode, len(jpegBytes))
	}
}

func authorizedGet(t *testing.T, client *http.Client, url string) *http.Response {
	t.Helper()
	var last error
	for i := 0; i < 50; i++ {
		req, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer token-value")
		resp, err := client.Do(req)
		if err == nil {
			return resp
		}
		last = err
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal(last)
	return nil
}

func uidFor(t *testing.T, catalog *db.Catalog, rel string) string {
	t.Helper()
	var uid string
	if err := catalog.Read.QueryRow(`SELECT uid FROM assets WHERE rel_path = ?`, rel).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	return uid
}

func writeTinyJPEG(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	img := image.NewGray(image.Rect(0, 0, 8, 4))
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 70}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}
