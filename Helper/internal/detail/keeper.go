package detail

// Candidate is one group member. Only placement "active" can be the keeper.
type Candidate struct {
	ID        int64
	Rel       string
	Ext       string
	Score     float64
	Pixels    int64
	Bytes     int64
	Placement string
	HasScore  bool
	Pinned    bool
}

// EligibleFlag is 1 only when every member, stored or not, has a score.
func EligibleFlag(members []Candidate) int {
	if len(members) == 0 {
		return 0
	}
	for _, member := range members {
		if !member.HasScore {
			return 0
		}
	}
	return 1
}

// EligibleForTrim is false when any score is missing. Trim also ignores a group of one.
func EligibleForTrim(members []Candidate) bool {
	if len(members) < 2 || EligibleFlag(members) == 0 {
		return false
	}
	return true
}

// SelectKeeper picks the active keeper. A stored file is not the keeper.
// A missing score returns ok false. The caller must not invent a score from native pixels.
func SelectKeeper(members []Candidate) (int64, bool) {
	if EligibleFlag(members) == 0 {
		return 0, false
	}
	var active []Candidate
	best := 0.0
	seen := false
	for _, member := range members {
		if member.Placement != "active" {
			continue
		}
		active = append(active, member)
		if !seen || member.Score > best {
			best = member.Score
			seen = true
		}
	}
	if len(active) == 0 {
		return 0, false
	}
	near := active[:0]
	for _, member := range active {
		if best == 0 || (best-member.Score)/best <= 0.05 {
			near = append(near, member)
		}
	}
	winner := near[0]
	for _, member := range near[1:] {
		if betterKeeper(member, winner) {
			winner = member
		}
	}
	return winner.ID, true
}

func betterKeeper(a, b Candidate) bool {
	if a.Pixels != b.Pixels {
		return a.Pixels < b.Pixels
	}
	if ra, rb := formatRank(a.Ext), formatRank(b.Ext); ra != rb {
		return ra < rb
	}
	if a.Bytes != b.Bytes {
		return a.Bytes > b.Bytes
	}
	return a.Rel < b.Rel
}

func formatRank(ext string) int {
	switch ext {
	case "raf", "arw", "dng", "cr2", "cr3", "nef", "nrw", "orf", "rw2", "pef", "srw", "erf", "raw", "rwl", "3fr", "fff", "iiq", "mos", "sr2", "x3f":
		return 0
	case "tif", "tiff":
		return 1
	case "heic", "heif":
		return 2
	case "jpg", "jpeg":
		return 3
	case "png":
		return 4
	default:
		return 5
	}
}
