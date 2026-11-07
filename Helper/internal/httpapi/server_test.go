package httpapi

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"zimage/helper/internal/db"
)

func TestListenerIsIPv4(t *testing.T) {
	ln, err := ListenIPv4("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	tcp, ok := ln.Addr().(*net.TCPAddr)
	if !ok || tcp.IP.To4() == nil {
		t.Fatal("socket is not IPv4")
	}
	_ = ln.Close()
	if _, err := ListenIPv4("[::1]:0"); err == nil {
		t.Fatal("tcp4 listener accepted an IPv6 address")
	}

	v6, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Skip("tcp6 is not available")
	}
	defer v6.Close()
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	srv := NewServer(t.TempDir(), false, true, "", nil, pair, leaf)
	if err := srv.Serve(v6); err == nil {
		t.Fatal("Serve accepted an IPv6 socket")
	}
}

func TestAllowedSources(t *testing.T) {
	cases := []struct {
		ip   string
		loop bool
		ok   bool
	}{
		{"10.1.2.3", false, true},
		{"172.16.0.1", false, true},
		{"172.31.255.255", false, true},
		{"172.32.0.1", false, false},
		{"192.168.1.9", false, true},
		{"169.254.1.1", false, true},
		{"8.8.8.8", false, false},
		{"127.0.0.1", false, false},
		{"127.0.0.1", true, true},
		{"::1", true, false},
	}
	for _, tc := range cases {
		if allowedSource(net.ParseIP(tc.ip), tc.loop) != tc.ok {
			t.Fatalf("%s loop %v", tc.ip, tc.loop)
		}
	}
}

func TestSPKIVector(t *testing.T) {
	der, err := base64.StdEncoding.DecodeString(spkiFixtureDER)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	if hex.EncodeToString(sum[:]) != spkiFixtureHash {
		t.Fatalf("pin %x", sum)
	}
}

func TestUnauthenticatedAssetsAndClaim(t *testing.T) {
	root := filepath.Join(t.TempDir(), "library-root-marker")
	if err := os.MkdirAll(filepath.Join(root, "Photos"), 0o755); err != nil {
		t.Fatal(err)
	}
	zdir := filepath.Join(root, ".zimage")
	token, err := EnsureToken(zdir)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"auth.token", "PAIRING-TOKEN"} {
		info, err := os.Stat(filepath.Join(zdir, name))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode %o", name, info.Mode().Perm())
		}
	}
	catalog, err := db.Open(filepath.Join(zdir, "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer catalog.Close()
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	srv := NewServer(root, true, true, token, catalog, pair, leaf)
	srv.LogPath = filepath.Join(zdir, "logs", "helper.log")
	client, base := startServer(t, srv)

	resp := getRetry(t, client, base+"/v1/assets")
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("assets status %d %s", resp.StatusCode, body)
	}
	if strings.Contains(body, token) || strings.Contains(body, "library-root-marker") || strings.Contains(body, "Photos/") {
		t.Fatalf("401 leaked %s", body)
	}
	logText, err := os.ReadFile(srv.LogPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(logText), "auth_fail") || strings.Contains(string(logText), token) {
		t.Fatalf("log %s", logText)
	}

	resp = postRetry(t, client, base+"/v1/pair/claim", token)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("claim %d", resp.StatusCode)
	}
	resp.Body.Close()
	if _, err := os.Stat(filepath.Join(zdir, "PAIRING-TOKEN")); !os.IsNotExist(err) {
		t.Fatal("pairing file still present")
	}

	req, _ := http.NewRequest(http.MethodGet, base+"/v1/assets", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err = client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body = readAll(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, `"rows"`) {
		t.Fatalf("bearer assets %d %s", resp.StatusCode, body)
	}

	resp = getRetry(t, client, base+"/v1/health")
	raw := readAll(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatal(raw)
	}
	if strings.Contains(raw, token) || strings.Contains(raw, "library-root-marker") {
		t.Fatalf("health leaked %s", raw)
	}
	var health healthBody
	if err := json.Unmarshal([]byte(raw), &health); err != nil {
		t.Fatal(err)
	}
	if health.Status != "ok" || !health.LibraryRootOK || health.SchemaVersion != 1 || !health.ManualOpsClear || !health.ReorgSafeToReboot || !health.TrimSafeToReboot {
		t.Fatalf("health %+v", health)
	}

	if _, err := catalog.Write.Exec(`INSERT INTO assets (uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at) VALUES ('u1', 'Photos/a.jpg', 4, 'jpg', 'image', 'move', 'discovered', '2026-11-04T00:00:00Z', '2026-11-04T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at) VALUES (1, 'purge', 'purge_planned', 'Photos/_Duplicates/a.jpg', '', 4, '2026-11-04T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`UPDATE job_state SET safe_to_reboot = 0 WHERE job_kind = 'trim'`); err != nil {
		t.Fatal(err)
	}
	resp = getRetry(t, client, base+"/v1/health")
	raw = readAll(t, resp)
	if err := json.Unmarshal([]byte(raw), &health); err != nil {
		t.Fatal(err)
	}
	if health.ManualOpsClear || health.TrimSafeToReboot || !health.ReorgSafeToReboot {
		t.Fatalf("bits %+v", health)
	}
	if strings.Contains(raw, "Photos/") {
		t.Fatalf("health path %s", raw)
	}

	req, _ = http.NewRequest(http.MethodPost, base+"/v1/pair/claim", nil)
	resp, err = client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("second claim %d", resp.StatusCode)
	}
}

func TestLoopbackRejectedAndRateLimit(t *testing.T) {
	root := t.TempDir()
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	blocked := NewServer(root, false, false, "token-value", nil, pair, leaf)
	blockedClient, blockedBase := startServer(t, blocked)
	resp := getRetry(t, blockedClient, blockedBase+"/v1/health")
	body := readAll(t, resp)
	if resp.StatusCode != http.StatusForbidden || strings.Contains(body, root) {
		t.Fatalf("loopback %d %s", resp.StatusCode, body)
	}

	catalog, err := db.Open(filepath.Join(root, "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer catalog.Close()
	pair, leaf, err = GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	srv := NewServer(root, true, true, "token-value", catalog, pair, leaf)
	clock := time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC)
	srv.Now = func() time.Time { return clock }
	client, base := startServer(t, srv)
	for i := 0; i < 30; i++ {
		resp = getRetry(t, client, base+"/v1/assets")
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("attempt %d status %d", i, resp.StatusCode)
		}
	}
	resp = getRetry(t, client, base+"/v1/assets")
	body = readAll(t, resp)
	if resp.StatusCode != http.StatusTooManyRequests || strings.Contains(body, root) {
		t.Fatalf("silence %d %s", resp.StatusCode, body)
	}
	clock = clock.Add(5*time.Minute + time.Second)
	resp = getRetry(t, client, base+"/v1/assets")
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("after silence %d", resp.StatusCode)
	}
}

func TestHealthWithoutLibraryOmitsPaths(t *testing.T) {
	root := filepath.Join(t.TempDir(), "missing-library-root")
	pair, leaf, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	srv := NewServer(root, false, true, "secret-token", nil, pair, leaf)
	client, base := startServer(t, srv)
	resp := getRetry(t, client, base+"/v1/health")
	body := readAll(t, resp)
	var health healthBody
	if err := json.Unmarshal([]byte(body), &health); err != nil {
		t.Fatal(err)
	}
	if health.LibraryRootOK || health.Status != "library_unavailable" || strings.Contains(body, "missing-library-root") || strings.Contains(body, "secret-token") {
		t.Fatalf("health %s", body)
	}
}

func TestCertFilesStayMode0600(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	_, leaf, err := EnsureCert(dir)
	if err != nil {
		t.Fatal(err)
	}
	_, again, err := EnsureCert(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !leaf.Equal(again) {
		t.Fatal("second start minted a new certificate")
	}
	if leaf.PublicKeyAlgorithm != x509.ECDSA {
		t.Fatalf("algorithm %v", leaf.PublicKeyAlgorithm)
	}
	for _, name := range []string{"cert.pem", "key.pem"} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode %o", name, info.Mode().Perm())
		}
	}
}

func TestLogRotates(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "helper.log")
	for i := 0; i < 5; i++ {
		if err := AppendLog(path, "2026-11-04T00:00:00Z info auth_fail\n", 40); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(path + ".1"); err != nil {
		t.Fatal(err)
	}
}

const spkiFixtureDER = "MIIBZDCCAQqgAwIBAgIUNlSzFwYJLw+rDSFKft3vXwJJeBkwCgYIKoZIzj0EAwIwGDEWMBQGA1UEAwwNemltYWdlLWhlbHBlcjAeFw0yNjExMDQyMDQwMTNaFw0zNjExMDEyMDQwMTNaMBgxFjAUBgNVBAMMDXppbWFnZS1oZWxwZXIwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASAh28MWcMUEIi4EeFOmndNwihYO3j/EHoJDQ3KYpBrcdRM6ssKJ9s1WhdAxVZwiOKdcwONi8esfapFsUV9jhm8ozIwMDAdBgNVHQ4EFgQU05uhnItnhnJURyWj30faRsAFkX0wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiAZVFkKVmmC0sNYjCr/U4q9Cl1lxTn2T3znsHfYF/jVHAIhAIlfIeJZeeS5HimkG+ythEz/xyGh17a7Yyi0DRfTpjPk"
const spkiFixtureHash = "7d575f8bf6bf272ce9febb428f132ca251f0235951cd06ad7a72a76389af2166"

func startServer(t *testing.T, srv *Server) (*http.Client, string) {
	t.Helper()
	ln, err := ListenIPv4("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
	pool := x509.NewCertPool()
	pool.AddCert(srv.Leaf)
	client := &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    pool,
	}}}
	return client, "https://" + addr
}

func getRetry(t *testing.T, client *http.Client, url string) *http.Response {
	t.Helper()
	var last error
	for i := 0; i < 50; i++ {
		resp, err := client.Get(url)
		if err == nil {
			return resp
		}
		last = err
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal(last)
	return nil
}

func postRetry(t *testing.T, client *http.Client, url, body string) *http.Response {
	t.Helper()
	var last error
	for i := 0; i < 50; i++ {
		req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
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

func readAll(t *testing.T, resp *http.Response) string {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
