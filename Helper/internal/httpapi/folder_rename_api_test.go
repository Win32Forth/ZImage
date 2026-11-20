package httpapi

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestRenameFolderRouteKeepsTheAsset(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
		) VALUES ('keepuid', 'Photos/Album/a.jpg', 4, 'jpg', 'image', 'move', 'thumbed', '2026-11-19T00:00:00Z', '2026-11-19T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "Photos", "Trip"), 0o750); err != nil {
		t.Fatal(err)
	}
	client, base := reorgServer(t, root, catalog, nil)
	body, err := json.Marshal(map[string]string{"from": "Photos/Album", "to": "Photos/Trip"})
	if err != nil {
		t.Fatal(err)
	}
	anon, err := http.NewRequest(http.MethodPost, base+"/v1/folders/rename", nil)
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
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/folders/rename", body)
	raw := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("rename %d %s", resp.StatusCode, raw)
	}
	var reply struct {
		Renamed int `json:"renamed"`
	}
	if err := json.Unmarshal([]byte(raw), &reply); err != nil {
		t.Fatal(err)
	}
	if reply.Renamed != 1 || !apiRelExists(t, catalog, "Photos/Trip/a.jpg") {
		t.Fatalf("reply %+v", reply)
	}
}
