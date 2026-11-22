package httpapi

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestRenameFileRouteKeepsTheAsset(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
		) VALUES ('keepuid', 'Photos/Day/old.jpg', 4, 'jpg', 'image', 'move', 'thumbed', '2026-11-21T00:00:00Z', '2026-11-21T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	full := filepath.Join(root, "Photos", "Day", "new.jpg")
	if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte("photo"), 0o644); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	body, err := json.Marshal(map[string]string{
		"from": "Photos/Day/old.jpg",
		"to":   "Photos/Day/new.jpg",
	})
	if err != nil {
		t.Fatal(err)
	}
	anon, err := http.NewRequest(http.MethodPost, base+"/v1/files/rename", nil)
	if err != nil {
		t.Fatal(err)
	}
	unauth, err := client.Do(anon)
	if err != nil {
		t.Fatal(err)
	}
	unauth.Body.Close()
	if unauth.StatusCode != http.StatusUnauthorized {
		t.Fatalf("auth %d", unauth.StatusCode)
	}
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/files/rename", body)
	raw := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("rename %d %s", resp.StatusCode, raw)
	}
	if !apiRelExists(t, catalog, "Photos/Day/new.jpg") || apiRelExists(t, catalog, "Photos/Day/old.jpg") {
		t.Fatal("path did not follow")
	}
	var uid string
	if err := catalog.Read.QueryRow(`SELECT uid FROM assets WHERE rel_path = 'Photos/Day/new.jpg'`).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	if uid != "keepuid" {
		t.Fatalf("uid %s", uid)
	}
}
