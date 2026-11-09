package dating

import (
	"crypto/sha256"
	"encoding/hex"
	"path"
	"strconv"
	"strings"
)

// UnderDuplicates reports a source that the reorg leaves in the store.
func UnderDuplicates(rel string) bool {
	rel = strings.TrimPrefix(rel, "/")
	return rel == "Photos/_Duplicates" || strings.HasPrefix(rel, "Photos/_Duplicates/")
}

// UnderRemoved reports a file parked for later deletion. Reorg leaves it there.
func UnderRemoved(rel string) bool {
	rel = strings.TrimPrefix(rel, "/")
	return rel == "Photos/_Removed" || strings.HasPrefix(rel, "Photos/_Removed/")
}

// PlaceDest is a Photos path outside the review park and the two holding folders.
func PlaceDest(rel string) bool {
	rel = path.Clean(strings.TrimPrefix(rel, "/"))
	if rel == "." || rel == ".." || strings.HasPrefix(rel, "../") {
		return false
	}
	if rel != "Photos" && !strings.HasPrefix(rel, "Photos/") {
		return false
	}
	if UnderDuplicates(rel) || UnderRemoved(rel) {
		return false
	}
	if rel == "Photos/_Review" || strings.HasPrefix(rel, "Photos/_Review/") || strings.Contains(rel, "/_Review/") {
		return false
	}
	return true
}

// ReviewBucket is two hex characters from blake3, otherwise the fast fingerprint.
// A file with neither uses a stand-in digest of the relative path until blake3 exists.
func ReviewBucket(sum []byte, rel string) string {
	if len(sum) == 0 {
		digest := sha256.Sum256([]byte(rel))
		sum = digest[:1]
	} else {
		sum = sum[:1]
	}
	return hex.EncodeToString(sum)
}

// PlannedPath is the dry-run destination. The store prefix is never a destination.
func PlannedPath(rel, policy, folder, bucket string, d Decision) (string, bool) {
	if policy != "move" || UnderDuplicates(rel) || UnderRemoved(rel) {
		return "", false
	}
	base := rel
	if i := strings.LastIndex(rel, "/"); i >= 0 {
		base = rel[i+1:]
	}
	if base == "" || base == "." || strings.Contains(base, "/") {
		return "", false
	}
	var dest string
	title, hasTitle := AlbumTitleFromPath(rel)
	if !d.Places() {
		if bucket == "" {
			bucket = ReviewBucket(nil, rel)
		}
		dest = "Photos/_Review/Undated/" + bucket + "/" + base
	} else if folder != "" && !(hasTitle && folderMatchesTitle(folder, title)) {
		dest = strings.Trim(folder, "/") + "/" + base
	} else if d.YearOnly {
		year := d.Year
		if year == 0 {
			year = d.Capture.Year()
		}
		dest = "Photos/" + strconv.Itoa(year) + "/_NoDay/" + eventDir(title, hasTitle) + "/" + base
	} else {
		dest = "Photos/" + d.Capture.Format("2006") + "/" + d.Capture.Format("2006-01-02") + "/" + eventDir(title, hasTitle) + "/" + base
	}
	if UnderDuplicates(dest) || UnderRemoved(dest) || strings.Contains(dest, "/_Duplicates/") || strings.Contains(dest, "/_Removed/") {
		return "", false
	}
	return dest, true
}

func eventDir(title string, hasTitle bool) string {
	if hasTitle {
		return title
	}
	return "event"
}

// AlbumTitle is the occasion written in one folder name.
// A leading YYYY-MM-DD is removed. The placeholder folder "event" is not a name.
func AlbumTitle(name string) (string, bool) {
	name = strings.TrimSpace(name)
	if rest, ok := stripLeadingDay(name); ok {
		name = rest
	}
	if !albumFolder(name) {
		return "", false
	}
	return name, true
}

// AlbumTitleFromPath uses a dated folder's remainder when one is present.
// Otherwise it uses the folder closest to the file.
// A folder named Updated under Photos/_Review is a staging shelf, not an occasion.
func AlbumTitleFromPath(rel string) (string, bool) {
	parts := strings.Split(rel, "/")
	if len(parts) > 0 {
		parts = parts[:len(parts)-1]
	}
	underReview := false
	for _, part := range parts {
		if part == "_Review" {
			underReview = true
			break
		}
	}
	fallback := ""
	have := false
	for i := len(parts) - 1; i >= 0; i-- {
		part := strings.TrimSpace(parts[i])
		if underReview && strings.EqualFold(part, "Updated") {
			continue
		}
		if rest, ok := stripLeadingDay(part); ok && albumFolder(rest) {
			if underReview && strings.EqualFold(rest, "Updated") {
				continue
			}
			return rest, true
		}
		if !have && albumFolder(part) {
			fallback = part
			have = true
		}
	}
	return fallback, have
}

func folderMatchesTitle(folder, title string) bool {
	base := folder
	if i := strings.LastIndex(folder, "/"); i >= 0 {
		base = folder[i+1:]
	}
	return foldName(base) != "" && foldName(base) == foldName(title)
}

func foldName(name string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func stripLeadingDay(name string) (string, bool) {
	if len(name) < 11 || !isoDay(name[:10]) {
		return "", false
	}
	rest := strings.TrimSpace(name[10:])
	rest = strings.TrimPrefix(rest, "-")
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return "", false
	}
	return rest, true
}

func isoDay(name string) bool {
	if len(name) != 10 || name[4] != '-' || name[7] != '-' {
		return false
	}
	for i := 0; i < len(name); i++ {
		if i == 4 || i == 7 {
			continue
		}
		if name[i] < '0' || name[i] > '9' {
			return false
		}
	}
	return true
}

func reviewBucket(name string) bool {
	if len(name) != 2 {
		return false
	}
	for _, c := range name {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F') {
			return false
		}
	}
	return true
}

func albumFolder(name string) bool {
	if name == "" || name == "." || name == ".." || strings.Contains(name, "/") {
		return false
	}
	if name == "Photos" || name == "_Review" || name == "_NoDay" || name == "_Duplicates" || name == "_Removed" || name == "Undated" {
		return false
	}
	if strings.EqualFold(name, "event") || reviewBucket(name) {
		return false
	}
	if len(name) == 4 {
		year := true
		for _, c := range name {
			if c < '0' || c > '9' {
				year = false
				break
			}
		}
		if year {
			return false
		}
	}
	if isoDay(name) {
		return false
	}
	lower := strings.ToLower(name)
	if lower == "facebook photos" || lower == "facebook category photos" {
		return false
	}
	if strings.HasPrefix(name, "Photos Library") {
		return false
	}
	if strings.Contains(name, "1969-12-31") || strings.Contains(name, "1970-01-01") || name == "1969" {
		return false
	}
	return true
}

// CollisionName inserts -2, -3 before the extension when n > 1.
func CollisionName(name string, n int) string {
	if n <= 1 {
		return name
	}
	ext := ""
	stem := name
	if i := strings.LastIndex(name, "."); i > 0 {
		ext = name[i:]
		stem = name[:i]
	}
	return stem + "-" + strconv.Itoa(n) + ext
}
