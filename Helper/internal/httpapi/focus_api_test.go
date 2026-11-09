package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestFocusStoresAPhotosPrefix(t *testing.T) {
	root := t.TempDir()
	catalog := openAPICatalog(t, root)
	client, base := reorgServer(t, root, catalog, nil)

	code, body := postFocus(t, client, base, "Photos/2024/Trip")
	if code != http.StatusOK || body != `{"prefix":"Photos/2024/Trip"}` {
		t.Fatalf("store %d %s", code, body)
	}
	got := authorizedGet(t, client, base+"/v1/focus")
	if gotBody := readAll(t, got); got.StatusCode != http.StatusOK || gotBody != `{"prefix":"Photos/2024/Trip"}` {
		t.Fatalf("get %d %s", got.StatusCode, gotBody)
	}

	code, body = postFocus(t, client, base, "Photos/_Duplicates")
	if code != http.StatusOK || body != `{"prefix":"Photos/_Duplicates"}` {
		t.Fatalf("duplicates %d %s", code, body)
	}
	code, _ = postFocus(t, client, base, "")
	if code != http.StatusOK {
		t.Fatalf("clear %d", code)
	}
	cleared := authorizedGet(t, client, base+"/v1/focus")
	if clearedBody := readAll(t, cleared); cleared.StatusCode != http.StatusOK || clearedBody != `{"prefix":""}` {
		t.Fatalf("cleared %d %s", cleared.StatusCode, clearedBody)
	}

	for _, prefix := range []string{"..", "Photos/../Secret", "Movies", `Photos\hidden`} {
		code, body = postFocus(t, client, base, prefix)
		if code != http.StatusBadRequest || body != `{"error":"prefix"}` {
			t.Fatalf("reject %q %d %s", prefix, code, body)
		}
	}

	req, err := http.NewRequest(http.MethodPost, base+"/v1/focus", nil)
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

func postFocus(t *testing.T, client *http.Client, base, prefix string) (int, string) {
	t.Helper()
	body, err := json.Marshal(map[string]string{"prefix": prefix})
	if err != nil {
		t.Fatal(err)
	}
	resp := authorizedSend(t, client, http.MethodPost, base+"/v1/focus", body)
	return resp.StatusCode, readAll(t, resp)
}
