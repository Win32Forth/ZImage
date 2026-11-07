package dating

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestReadFactsReadsADateFromHEIC(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "IMG_6462.HEIC")
	if err := os.WriteFile(path, sampleHEIC(sampleTIFFDate("2025:01:01 09:50:17")), 0o600); err != nil {
		t.Fatal(err)
	}
	facts, err := ReadFacts(path)
	if err != nil {
		t.Fatal(err)
	}
	if facts.Original == nil {
		t.Fatal("missing DateTimeOriginal")
	}
	got := facts.Original.Time.UTC().Format("2006-01-02 15:04:05")
	if got != "2025-01-01 09:50:17" {
		t.Fatalf("date %s", got)
	}
	empty := filepath.Join(dir, "empty.heic")
	if err := os.WriteFile(empty, sampleHEIC(nil), 0o600); err != nil {
		t.Fatal(err)
	}
	none, err := ReadFacts(empty)
	if err != nil {
		t.Fatal(err)
	}
	if none.Original != nil || none.DateTime != nil {
		t.Fatal("empty container stored a date")
	}
}

func TestHEICDatePlacesTheFile(t *testing.T) {
	facts, err := ReadFacts(writeTemp(t, "shot.heic", sampleHEIC(sampleTIFFDate("2020:05:01 12:00:00"))))
	if err != nil {
		t.Fatal(err)
	}
	d := Decide(Input{
		RelPath:      "Photos/_Review/Undated/e0/shot.heic",
		EXIFOriginal: facts.Original,
		Now:          time.Date(2026, 11, 5, 0, 0, 0, 0, time.UTC),
	})
	if !d.Places() || d.Source != "exif_original" {
		t.Fatalf("decision %+v", d)
	}
	dest, ok := PlannedPath("Photos/_Review/Undated/e0/shot.heic", "move", "", "e0", d)
	if !ok {
		t.Fatal("no path")
	}
	if dest != "Photos/2020/2020-05-01/event/shot.heic" {
		t.Fatalf("dest %s", dest)
	}
}

func writeTemp(t *testing.T, name string, body []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func sampleTIFFDate(text string) []byte {
	date := append([]byte(text), 0)
	var b []byte
	b = append(b, 'M', 'M', 0, 42, 0, 0, 0, 8)
	b = append(b, 0, 1)
	b = append(b, 0x87, 0x69, 0, 4, 0, 0, 0, 1, 0, 0, 0, 26)
	b = append(b, 0, 0, 0, 0)
	b = append(b, 0, 1)
	b = append(b, 0x90, 0x03, 0, 2, 0, 0, 0, byte(len(date)))
	b = append(b, 0, 0, 0, 44)
	b = append(b, 0, 0, 0, 0)
	b = append(b, date...)
	return b
}

func sampleHEIC(tiff []byte) []byte {
	var exif []byte
	if tiff != nil {
		exif = make([]byte, 4+6+len(tiff))
		binary.BigEndian.PutUint32(exif[:4], 6)
		copy(exif[4:10], "Exif\x00\x00")
		copy(exif[10:], tiff)
	}
	ftyp := isoBox("ftyp", []byte("heic\x00\x00\x00\x00heic"))
	infe := isoBox("infe", []byte{
		2, 0, 0, 0,
		0, 1,
		0, 0,
		'E', 'x', 'i', 'f',
		'E', 'x', 'i', 'f', 0,
	})
	iinfBody := []byte{0, 0, 0, 0, 0, 1}
	iinfBody = append(iinfBody, infe...)
	iinf := isoBox("iinf", iinfBody)
	iloc := isoBox("iloc", []byte{1, 0, 0, 0, 0x44, 0x00, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0})
	metaBody := append([]byte{0, 0, 0, 0}, iinf...)
	metaBody = append(metaBody, iloc...)
	meta := isoBox("meta", metaBody)
	abs := len(ftyp) + len(meta)
	binary.BigEndian.PutUint32(iloc[len(iloc)-8:len(iloc)-4], uint32(abs))
	binary.BigEndian.PutUint32(iloc[len(iloc)-4:], uint32(len(exif)))
	meta = isoBox("meta", append(append([]byte{0, 0, 0, 0}, iinf...), iloc...))
	return append(append(ftyp, meta...), exif...)
}

func isoBox(typ string, payload []byte) []byte {
	out := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint32(out[:4], uint32(len(out)))
	copy(out[4:8], typ)
	copy(out[8:], payload)
	return out
}
