package dating

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
	"time"

	"zimage/helper/internal/db"
)

func TestVideoCreationTimePlacesTheDay(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	rel := "Photos/inbox/clip.mp4"
	when := time.Date(2020, 5, 1, 12, 0, 0, 0, time.UTC)
	writeMovie(t, filepath.Join(root, filepath.FromSlash(rel)), when, false)
	insertVideo(t, catalog, "clip", rel)
	if err := Assign(root, catalog, Options{Now: time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)}); err != nil {
		t.Fatal(err)
	}
	var conf float64
	var source, capture string
	if err := catalog.Read.QueryRow(`
		SELECT capture_confidence, COALESCE(capture_source, ''), COALESCE(capture_time, '')
		FROM assets WHERE uid = 'clip'`).Scan(&conf, &source, &capture); err != nil {
		t.Fatal(err)
	}
	if conf != ConfidenceVideoCreated || source != "video_created" || capture != "2020-05-01T12:00:00Z" {
		t.Fatalf("dated %v %s %s", conf, source, capture)
	}
	counts, err := PlanPrefix(catalog, "Photos/inbox")
	if err != nil {
		t.Fatal(err)
	}
	if counts.Move != 1 || counts.Park != 0 || counts.Leave != 0 {
		t.Fatalf("counts %+v", counts)
	}
	var dest string
	if err := catalog.Read.QueryRow(`SELECT dest_rel FROM journal`).Scan(&dest); err != nil {
		t.Fatal(err)
	}
	if dest != "Photos/2020/2020-05-01/inbox/clip.mp4" {
		t.Fatal(dest)
	}
}

func TestVideoCreationAtTheEndOfALargeFile(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "tail.mov")
	when := time.Date(2014, 7, 4, 15, 30, 0, 0, time.UTC)
	writeMovie(t, path, when, true)
	got, ok := readMovieCreation(path)
	if !ok || !got.Equal(when) {
		t.Fatalf("tail %v %v", got, ok)
	}
}

func TestSharedVideoCreationStaysBelowPlacement(t *testing.T) {
	root := t.TempDir()
	catalog := openCatalog(t, root)
	when := time.Date(2018, 1, 2, 3, 4, 5, 0, time.UTC)
	for i := 0; i < 26; i++ {
		rel := "Photos/Albums/clip" + itoa(int64(i)) + ".mov"
		writeMovie(t, filepath.Join(root, filepath.FromSlash(rel)), when, false)
		insertVideo(t, catalog, "v"+itoa(int64(i)), rel)
	}
	if err := Assign(root, catalog, Options{Now: time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)}); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM assets
		WHERE capture_source = 'video_created' OR capture_confidence >= ?`, PlacementThreshold).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("placed %d", n)
	}
}

func insertVideo(t *testing.T, catalog *db.Catalog, uid, rel string) {
	t.Helper()
	now := time.Now().UTC().Format(time.RFC3339)
	ext := filepath.Ext(rel)
	if len(ext) > 0 {
		ext = ext[1:]
	}
	if _, err := catalog.Write.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at
		) VALUES (?, ?, 20, ?, 'video', 'move', 'discovered', ?, ?)`, uid, rel, ext, now, now); err != nil {
		t.Fatal(err)
	}
}

func writeMovie(t *testing.T, path string, when time.Time, pad bool) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	var body []byte
	if pad {
		body = append(body, box("mdat", make([]byte, movieWindow+32))...)
	}
	seconds := uint32(when.Sub(quickTimeEpoch) / time.Second)
	payload := make([]byte, 100)
	binary.BigEndian.PutUint32(payload[4:8], seconds)
	binary.BigEndian.PutUint32(payload[8:12], seconds)
	binary.BigEndian.PutUint32(payload[12:16], 600)
	body = append(body, box("moov", box("mvhd", payload))...)
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

func box(typ string, payload []byte) []byte {
	out := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint32(out[:4], uint32(len(out)))
	copy(out[4:8], typ)
	copy(out[8:], payload)
	return out
}
