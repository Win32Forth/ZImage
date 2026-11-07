package dhashindex

import (
	"strings"
	"testing"
	"time"

	"zimage/helper/internal/db"
)

func TestBandQueryHasNoLimit(t *testing.T) {
	upper := strings.ToUpper(BandSelectSQL)
	if strings.Contains(upper, "LIMIT") || strings.Contains(upper, "ORDER BY") {
		t.Fatal(BandSelectSQL)
	}
}

func TestDistanceFiveSharesABandPastSixtyFourDecoys(t *testing.T) {
	root := t.TempDir()
	catalog := openHashCatalog(t, root)
	const a uint64 = 7
	b := uint64(7) | (uint64(1) << 53) | (uint64(1) << 54) | (uint64(1) << 55) | (uint64(1) << 56) | (uint64(1) << 57)
	if Hamming(a, b) != 5 {
		t.Fatalf("distance %d", Hamming(a, b))
	}
	if a>>48 == b>>48 {
		t.Fatal("high 16 should differ")
	}
	decoy := uint64(7) | (uint64(0x3F) << 10)
	if Hamming(a, decoy) < 6 || Hamming(b, decoy) < 6 {
		t.Fatal("decoy is too close")
	}
	for i := 0; i < 70; i++ {
		id := insertHashRow(t, catalog, "decoy"+itoa(i), "Photos/decoy"+itoa(i)+".jpg")
		setStoredHash(t, catalog, id, decoy, 100, 100)
	}
	idA := insertHashRow(t, catalog, "filea", "Photos/a.jpg")
	idB := insertHashRow(t, catalog, "fileb", "Photos/b.jpg")
	setStoredHash(t, catalog, idA, a, 1000, 1000)
	setStoredHash(t, catalog, idB, b, 1000, 1000)
	got, err := Lookup(catalog.Read, idA, a, GroupDistance, ScanLimit, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !hasID(got, idB) {
		t.Fatalf("missed pair among %d", len(got))
	}
}

func TestSaturatedBandStops(t *testing.T) {
	root := t.TempDir()
	catalog := openHashCatalog(t, root)
	const hash uint64 = 1
	for i := 0; i < 10; i++ {
		id := insertHashRow(t, catalog, "s"+itoa(i), "Photos/s"+itoa(i)+".jpg")
		setStoredHash(t, catalog, id, hash, 10, 10)
	}
	var logged string
	got, err := Lookup(catalog.Read, 0, hash, GroupDistance, 3, func(column string, value uint64) {
		logged = column + "=" + itoa(int(value))
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) > 3 {
		t.Fatalf("kept %d", len(got))
	}
	if !strings.Contains(logged, "dhash_b") {
		t.Fatal(logged)
	}
}

func TestAspectAndBlake3(t *testing.T) {
	if AspectClose(100, 100, 200, 100) {
		t.Fatal("aspect")
	}
	if !AspectClose(1000, 1000, 1010, 1000) {
		t.Fatal("close")
	}
	if AspectClose(0, 100, 100, 100) {
		t.Fatal("unknown")
	}
	root := t.TempDir()
	catalog := openHashCatalog(t, root)
	far := insertHashRow(t, catalog, "far1", "Photos/far1.jpg")
	far2 := insertHashRow(t, catalog, "far2", "Photos/far2.jpg")
	setStoredHash(t, catalog, far, 1, 100, 100)
	setStoredHash(t, catalog, far2, 1, 200, 100)
	close1 := insertHashRow(t, catalog, "close1", "Photos/close1.jpg")
	close2 := insertHashRow(t, catalog, "close2", "Photos/close2.jpg")
	setStoredHash(t, catalog, close1, 1<<20, 1000, 1000)
	setStoredHash(t, catalog, close2, 1<<20, 1010, 1000)
	unknown := insertHashRow(t, catalog, "unk1", "Photos/unk1.jpg")
	unknown2 := insertHashRow(t, catalog, "unk2", "Photos/unk2.jpg")
	setStoredHash(t, catalog, unknown, 1<<40, 0, 0)
	setStoredHash(t, catalog, unknown2, 1<<40, 100, 100)
	blakeA := insertHashRow(t, catalog, "ba", "Photos/ba.jpg")
	blakeB := insertHashRow(t, catalog, "bb", "Photos/bb.jpg")
	setStoredHash(t, catalog, blakeA, 0, 80, 80)
	// One bit in each band, so no band matches the all-zero hash, and the distance is 6.
	other := uint64(1) | (uint64(1) << 10) | (uint64(1) << 20) | (uint64(1) << 31) | (uint64(1) << 42) | (uint64(1) << 53)
	if Hamming(0, other) <= GroupDistance {
		t.Fatal(Hamming(0, other))
	}
	setStoredHash(t, catalog, blakeB, other, 80, 80)
	sum := []byte("same-blake3-bytes")
	if _, err := catalog.Write.Exec(`UPDATE assets SET blake3 = ? WHERE id IN (?, ?)`, sum, blakeA, blakeB); err != nil {
		t.Fatal(err)
	}
	if err := Group(catalog, nil); err != nil {
		t.Fatal(err)
	}
	if sameGroup(t, catalog, far, far2) {
		t.Fatal("wide aspect grouped")
	}
	if !sameGroup(t, catalog, close1, close2) {
		t.Fatal("close aspect missed")
	}
	if sameGroup(t, catalog, unknown, unknown2) {
		t.Fatal("unknown dimensions grouped")
	}
	if !sameGroup(t, catalog, blakeA, blakeB) {
		t.Fatal("blake3 missed")
	}
}

func hasID(list []Neighbor, id int64) bool {
	for _, item := range list {
		if item.ID == id {
			return true
		}
	}
	return false
}

func sameGroup(t *testing.T, catalog *db.Catalog, a, b int64) bool {
	t.Helper()
	var ga, gb interface{}
	var aID, bID int64
	if err := catalog.Read.QueryRow(`SELECT COALESCE(derivative_group_id, 0) FROM assets WHERE id = ?`, a).Scan(&aID); err != nil {
		t.Fatal(err)
	}
	if err := catalog.Read.QueryRow(`SELECT COALESCE(derivative_group_id, 0) FROM assets WHERE id = ?`, b).Scan(&bID); err != nil {
		t.Fatal(err)
	}
	_ = ga
	_ = gb
	return aID != 0 && aID == bID
}

func openHashCatalog(t *testing.T, root string) *db.Catalog {
	t.Helper()
	catalog, err := db.Open(root + "/catalog.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = catalog.Close() })
	return catalog
}

func insertHashRow(t *testing.T, catalog *db.Catalog, uid, rel string) int64 {
	t.Helper()
	now := time.Now().UTC().Format(time.RFC3339)
	res, err := catalog.Write.Exec(`
		INSERT INTO assets (uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at, placement)
		VALUES (?, ?, 20, 'jpg', 'image', 'move', 'thumbed', ?, ?, 'active')`, uid, rel, now, now)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func setStoredHash(t *testing.T, catalog *db.Catalog, id int64, hash uint64, width, height int) {
	t.Helper()
	bands := Bands(hash)
	var w, h interface{}
	if width > 0 {
		w = width
	}
	if height > 0 {
		h = height
	}
	_, err := catalog.Write.Exec(`
		UPDATE assets SET dhash = ?, dhash_b0 = ?, dhash_b1 = ?, dhash_b2 = ?, dhash_b3 = ?, dhash_b4 = ?, dhash_b5 = ?,
			width = ?, height = ?
		WHERE id = ?`,
		int64(hash), int64(bands[0]), int64(bands[1]), int64(bands[2]), int64(bands[3]), int64(bands[4]), int64(bands[5]), w, h, id)
	if err != nil {
		t.Fatal(err)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
