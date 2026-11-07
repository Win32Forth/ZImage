// Package dhashindex stores a 64-bit difference hash in six disjoint bands.
// A lookup is six equality queries. It does not bucket the high 16 bits.
package dhashindex

import "math/bits"

const (
	// GroupDistance is the Hamming limit for a derivative candidate.
	GroupDistance = 5
	// DateDistance is the Hamming limit for inheriting a capture time.
	DateDistance = 8
	// ScanLimit stops one band value. The unscanned tail stays ungrouped.
	ScanLimit = 8192
)

// BandSelectSQL is one equality probe. The column name is substituted from the fixed list.
const BandSelectSQL = `SELECT id, uid, dhash, width, height, capture_time, capture_confidence, capture_source FROM assets WHERE COLUMN = ? AND id != ? AND dhash IS NOT NULL`

// BandColumns are the six indexed slices of the 64-bit hash.
var BandColumns = []string{"dhash_b0", "dhash_b1", "dhash_b2", "dhash_b3", "dhash_b4", "dhash_b5"}

// Bands splits a hash into bits 0–9, 10–19, 20–30, 31–41, 42–52, and 53–63.
func Bands(hash uint64) [6]uint64 {
	return [6]uint64{
		hash & 0x3FF,
		(hash >> 10) & 0x3FF,
		(hash >> 20) & 0x7FF,
		(hash >> 31) & 0x7FF,
		(hash >> 42) & 0x7FF,
		(hash >> 53) & 0x7FF,
	}
}

// Hamming is the population count of the xor.
func Hamming(a, b uint64) int {
	return bits.OnesCount64(a ^ b)
}
