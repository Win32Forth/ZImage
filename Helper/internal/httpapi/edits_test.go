package httpapi

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/events"
)

func TestEditsRoundTripAfterRestart(t *testing.T) {
	root := t.TempDir()
	catalog := openEditsCatalog(t, root)
	insertAPIAsset(t, catalog, "keepuid", "Photos/2020/2020-05-01/one.jpg", 0.95, "2020-05-01T12:00:00Z")
	photo := filepath.Join(root, "Photos", "2020", "2020-05-01", "one.jpg")
	if err := os.MkdirAll(filepath.Dir(photo), 0o750); err != nil {
		t.Fatal(err)
	}
	const payload = "untouched-one"
	if err := os.WriteFile(photo, []byte(payload), 0o644); err != nil {
		t.Fatal(err)
	}

	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(root, true, true, "token-value", catalog, pair, leaf)
	client, base := startServer(t, server)
	body := append([]byte{}, zimgMagic...)
	body = append(body, []byte("catalog-ref-bytes")...)
	resp := authorizedRaw(t, client, http.MethodPut, base+"/v1/edits/keepuid", body)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("put %d %s", resp.StatusCode, readAll(t, resp))
	}
	resp.Body.Close()
	info, err := os.Stat(filepath.Join(root, ".zimage", "edits", "keepuid.zimg"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o", info.Mode().Perm())
	}
	var editRel string
	if err := catalog.Read.QueryRow(`SELECT edit_rel FROM assets WHERE uid = 'keepuid'`).Scan(&editRel); err != nil {
		t.Fatal(err)
	}
	if editRel != ".zimage/edits/keepuid.zimg" {
		t.Fatalf("edit_rel %s", editRel)
	}

	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if err := catalog.Close(); err != nil {
		t.Fatal(err)
	}
	reopened := openEditsCatalog(t, root)
	defer reopened.Close()
	pair2, leaf2, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	again := NewServer(root, true, true, "token-value", reopened, pair2, leaf2)
	client2, base2 := startServer(t, again)
	got := authorizedGet(t, client2, base2+"/v1/edits/keepuid")
	stored := readBytes(t, got)
	if got.StatusCode != http.StatusOK || !bytes.Equal(stored, body) {
		t.Fatalf("get %d %q", got.StatusCode, stored)
	}
	left, err := os.ReadFile(photo)
	if err != nil {
		t.Fatal(err)
	}
	if string(left) != payload {
		t.Fatalf("photo changed %q", left)
	}
}

func TestEditRejectsABodyThatIsNotZimgOrTooLarge(t *testing.T) {
	root := t.TempDir()
	catalog := openEditsCatalog(t, root)
	defer catalog.Close()
	insertAPIAsset(t, catalog, "keepuid", "Photos/2020/2020-05-01/one.jpg", 0.95, "")
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(root, true, true, "token-value", catalog, pair, leaf)
	server.MaxEditBytes = 16
	client, base := startServer(t, server)

	plain := authorizedRaw(t, client, http.MethodPut, base+"/v1/edits/keepuid", []byte("not-a-zimg-file"))
	if plain.StatusCode != http.StatusBadRequest {
		t.Fatalf("plain %d %s", plain.StatusCode, readAll(t, plain))
	}
	plain.Body.Close()

	over := append([]byte{}, zimgMagic...)
	over = append(over, bytes.Repeat([]byte{1}, 32)...)
	tooBig := authorizedRaw(t, client, http.MethodPut, base+"/v1/edits/keepuid", over)
	if tooBig.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("cap %d %s", tooBig.StatusCode, readAll(t, tooBig))
	}
	tooBig.Body.Close()
	if _, err := os.Stat(filepath.Join(root, ".zimage", "edits", "keepuid.zimg")); !os.IsNotExist(err) {
		t.Fatal("final edit exists")
	}

	missing := authorizedGet(t, client, base+"/v1/edits/keepuid")
	if missing.StatusCode != http.StatusNotFound {
		t.Fatalf("missing %d", missing.StatusCode)
	}
	missing.Body.Close()

	anon, err := http.NewRequest(http.MethodPut, base+"/v1/edits/keepuid", bytes.NewReader(zimgMagic))
	if err != nil {
		t.Fatal(err)
	}
	refused, err := client.Do(anon)
	if err != nil {
		t.Fatal(err)
	}
	defer refused.Body.Close()
	if refused.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anon %d", refused.StatusCode)
	}
}

func TestUserEventNameSurvivesSecondApply(t *testing.T) {
	root := t.TempDir()
	catalog := openEditsCatalog(t, root)
	defer catalog.Close()
	insertAPIAsset(t, catalog, "mayuid", "Photos/2020/2020-05-01/one.jpg", 0.95, "2020-05-01T12:00:00Z")
	insertAPIAsset(t, catalog, "junuid", "Photos/2020/2020-06-01/two.jpg", 0.95, "2020-06-01T12:00:00Z")
	may := filepath.Join(root, "Photos", "2020", "2020-05-01", "one.jpg")
	jun := filepath.Join(root, "Photos", "2020", "2020-06-01", "two.jpg")
	if err := os.MkdirAll(filepath.Dir(may), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(jun), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(may, []byte("may-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(jun, []byte("jun-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := events.Apply(root, catalog, nil); err != nil {
		t.Fatal(err)
	}

	var mayEvent string
	if err := catalog.Read.QueryRow(`
		SELECT e.uid FROM events e JOIN assets a ON a.event_id = e.id WHERE a.uid = 'mayuid'`).Scan(&mayEvent); err != nil {
		t.Fatal(err)
	}
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(root, true, true, "token-value", catalog, pair, leaf)
	client, base := startServer(t, server)
	renamed := authorizedSend(t, client, http.MethodPost, base+"/v1/events/"+mayEvent, []byte(`{"name":"Nick Sara Wedding"}`))
	text := readAll(t, renamed)
	if renamed.StatusCode != http.StatusOK || !bytesContain(text, `"nameSource":"user"`) || !bytesContain(text, "Nick Sara Wedding") {
		t.Fatalf("rename %d %s", renamed.StatusCode, text)
	}
	blank := authorizedSend(t, client, http.MethodPost, base+"/v1/events/"+mayEvent, []byte(`{"name":" "}`))
	if blank.StatusCode != http.StatusBadRequest {
		t.Fatalf("blank %d %s", blank.StatusCode, readAll(t, blank))
	}
	blank.Body.Close()

	var userID int64
	if err := catalog.Read.QueryRow(`SELECT id FROM events WHERE uid = ?`, mayEvent).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE assets SET capture_time = ? WHERE uid = 'junuid'`, "2020-07-01T12:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if err := events.Apply(root, catalog, nil); err != nil {
		t.Fatal(err)
	}

	var id int64
	var name, source string
	if err := catalog.Read.QueryRow(`SELECT id, name, name_source FROM events WHERE uid = ?`, mayEvent).Scan(&id, &name, &source); err != nil {
		t.Fatal(err)
	}
	if id != userID || name != "Nick Sara Wedding" || source != "user" {
		t.Fatalf("user event %d %s %s", id, name, source)
	}
	var generated string
	if err := catalog.Read.QueryRow(`SELECT name FROM events WHERE name_source = 'generated'`).Scan(&generated); err != nil {
		t.Fatal(err)
	}
	if generated != "2020-07-01" {
		t.Fatalf("generated %s", generated)
	}
	var june int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM events WHERE name = '2020-06-01'`).Scan(&june); err != nil {
		t.Fatal(err)
	}
	if june != 0 {
		t.Fatalf("june rows %d", june)
	}
	leftMay, err := os.ReadFile(may)
	if err != nil {
		t.Fatal(err)
	}
	leftJun, err := os.ReadFile(jun)
	if err != nil {
		t.Fatal(err)
	}
	if string(leftMay) != "may-bytes" || string(leftJun) != "jun-bytes" {
		t.Fatal("photo bytes changed")
	}
}

func openEditsCatalog(t *testing.T, root string) *db.Catalog {
	t.Helper()
	catalog, err := db.Open(filepath.Join(root, ".zimage", "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}

func authorizedRaw(t *testing.T, client *http.Client, method, url string, body []byte) *http.Response {
	t.Helper()
	var last error
	for i := 0; i < 50; i++ {
		req, err := http.NewRequest(method, url, bytes.NewReader(body))
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

func readBytes(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
