// Package events clusters accepted capture times and names the folders.
package events

import (
	"fmt"
	"math"
	"math/bits"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"zimage/helper/internal/dating"
)

// Item is one dated file. YearOnly files are not given 1 January.
type Item struct {
	ID         int64
	Time       time.Time
	HasTime    bool
	YearOnly   bool
	Year       int
	Lat        *float64
	Lon        *float64
	Hash       uint64
	HasHash    bool
	Rel        string
	EventID    int64
	EventName  string
	EventSlug  string
	NameSource string
}

// Named is one event after the gap rules and the album heuristic.
type Named struct {
	Items    []Item
	Name     string
	Source   string
	Slug     string
	Folder   string
	Start    time.Time
	End      time.Time
	YearOnly bool
	Year     int
	Lat      *float64
	Lon      *float64
	KeepID   int64
}

// Cluster sorts by capture time. A gap of 8 hours splits. A gap of 2 hours does not,
// unless both files have GPS, the gap is longer than 2 hours, and the distance exceeds 50 km.
func Cluster(items []Item) [][]Item {
	var dated, years []Item
	for _, item := range items {
		if !item.HasTime {
			continue
		}
		if item.YearOnly {
			years = append(years, item)
			continue
		}
		dated = append(dated, item)
	}
	return append(joinHashes(splitGaps(dated)), clusterYears(years)...)
}

func splitGaps(items []Item) [][]Item {
	if len(items) == 0 {
		return nil
	}
	sorted := append([]Item(nil), items...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Time.Equal(sorted[j].Time) {
			return sorted[i].ID < sorted[j].ID
		}
		return sorted[i].Time.Before(sorted[j].Time)
	})
	var clusters [][]Item
	cur := []Item{sorted[0]}
	for _, item := range sorted[1:] {
		prev := cur[len(cur)-1]
		gap := item.Time.Sub(prev.Time)
		if gap < 0 {
			gap = -gap
		}
		split := gap >= 8*time.Hour
		if !split && gap > 2*time.Hour && bothGPS(prev, item) && HaversineKM(*prev.Lat, *prev.Lon, *item.Lat, *item.Lon) > 50 {
			split = true
		}
		if split {
			clusters = append(clusters, cur)
			cur = []Item{item}
			continue
		}
		cur = append(cur, item)
	}
	return append(clusters, cur)
}

func joinHashes(clusters [][]Item) [][]Item {
	if len(clusters) < 2 {
		return clusters
	}
	for {
		merged := false
		out := [][]Item{clusters[0]}
		for i := 1; i < len(clusters); i++ {
			prev := out[len(out)-1]
			next := clusters[i]
			gap := next[0].Time.Sub(prev[len(prev)-1].Time)
			if gap < 0 {
				gap = -gap
			}
			if gap >= 8*time.Hour && gap <= 18*time.Hour && crossHash(prev, next) {
				out[len(out)-1] = append(prev, next...)
				merged = true
				continue
			}
			out = append(out, next)
		}
		clusters = out
		if !merged {
			return clusters
		}
	}
}

func crossHash(a, b []Item) bool {
	for _, left := range a {
		if !left.HasHash {
			continue
		}
		for _, right := range b {
			if !right.HasHash {
				continue
			}
			if bits.OnesCount64(left.Hash^right.Hash) <= 8 {
				return true
			}
		}
	}
	return false
}

func bothGPS(a, b Item) bool {
	return a.Lat != nil && a.Lon != nil && b.Lat != nil && b.Lon != nil
}

func clusterYears(items []Item) [][]Item {
	if len(items) == 0 {
		return nil
	}
	groups := map[string][]Item{}
	var keys []string
	for _, item := range items {
		key := strconv.Itoa(item.Year)
		if name, ok := dating.AlbumTitleFromPath(item.Rel); ok {
			key += "/" + name
		}
		if _, seen := groups[key]; !seen {
			keys = append(keys, key)
		}
		groups[key] = append(groups[key], item)
	}
	sort.Strings(keys)
	out := make([][]Item, 0, len(keys))
	for _, key := range keys {
		out = append(out, groups[key])
	}
	return out
}

// NameClusters applies the album rule, then a generated range. User names are kept.
func NameClusters(clusters [][]Item, usedSlugs map[string]bool) []Named {
	if usedSlugs == nil {
		usedSlugs = map[string]bool{}
	}
	albumCount := map[string]int{}
	out := make([]Named, 0, len(clusters))
	for _, cluster := range clusters {
		if len(cluster) == 0 {
			continue
		}
		named := Named{Items: cluster, YearOnly: cluster[0].YearOnly, Year: cluster[0].Year}
		named.Start, named.End = span(cluster)
		if id, name, slug, ok := preservedUser(cluster); ok {
			named.KeepID = id
			named.Name = name
			named.Source = "user"
			if slug == "" {
				slug = Slug(name)
			}
			named.Slug = slug
		} else if name, ok := sharedAlbum(rels(cluster)); ok {
			albumCount[name]++
			if albumCount[name] > 1 && !named.YearOnly {
				name = name + " " + named.Start.Format("2006-01-02")
			}
			named.Name = name
			named.Source = "album"
			named.Slug = Slug(name)
		} else {
			named.Name = generatedName(cluster, named)
			named.Source = "generated"
			named.Slug = Slug(named.Name)
		}
		named.Slug = freeSlug(named.Slug, usedSlugs)
		usedSlugs[named.Slug] = true
		if lat, lon, ok := meanGPS(cluster); ok {
			named.Lat = &lat
			named.Lon = &lon
		}
		named.Folder = Folder(named.Start, named.YearOnly, named.Year, named.Slug)
		out = append(out, named)
	}
	return out
}

func span(cluster []Item) (time.Time, time.Time) {
	start, end := cluster[0].Time, cluster[0].Time
	for _, item := range cluster[1:] {
		if item.Time.Before(start) {
			start = item.Time
		}
		if item.Time.After(end) {
			end = item.Time
		}
	}
	return start, end
}

func preservedUser(cluster []Item) (int64, string, string, bool) {
	counts := map[int64]int{}
	names := map[int64]string{}
	slugs := map[int64]string{}
	for _, item := range cluster {
		if item.NameSource != "user" || item.EventID == 0 || item.EventName == "" {
			continue
		}
		counts[item.EventID]++
		names[item.EventID] = item.EventName
		slugs[item.EventID] = item.EventSlug
	}
	var bestID int64
	bestN := 0
	for id, n := range counts {
		if n > bestN {
			bestID = id
			bestN = n
		}
	}
	if bestN == 0 || bestN*100 < len(cluster)*80 {
		return 0, "", "", false
	}
	return bestID, names[bestID], slugs[bestID], true
}

func rels(cluster []Item) []string {
	out := make([]string, len(cluster))
	for i, item := range cluster {
		out[i] = item.Rel
	}
	return out
}

func sharedAlbum(paths []string) (string, bool) {
	if len(paths) == 0 {
		return "", false
	}
	type hit struct {
		n     int
		depth int
	}
	counts := map[string]*hit{}
	for _, rel := range paths {
		seen := map[string]bool{}
		parts := ancestors(rel)
		for depth, part := range parts {
			title, ok := dating.AlbumTitle(part)
			if !ok || seen[title] {
				continue
			}
			seen[title] = true
			h := counts[title]
			if h == nil {
				h = &hit{}
				counts[title] = h
			}
			h.n++
			if depth >= h.depth {
				h.depth = depth
			}
		}
	}
	best := ""
	bestN := 0
	bestDepth := -1
	for name, h := range counts {
		if h.n > bestN || (h.n == bestN && h.depth > bestDepth) {
			best = name
			bestN = h.n
			bestDepth = h.depth
		}
	}
	if bestN*100 < len(paths)*80 {
		return "", false
	}
	return best, true
}

func ancestors(rel string) []string {
	parts := strings.Split(rel, "/")
	if len(parts) > 0 {
		parts = parts[:len(parts)-1]
	}
	return parts
}

func generatedName(cluster []Item, named Named) string {
	if named.YearOnly {
		name := strconv.Itoa(named.Year)
		if lat, lon, ok := meanGPS(cluster); ok {
			name += fmt.Sprintf(" %.1f, %.1f", lat, lon)
		}
		return name
	}
	start := named.Start.Format("2006-01-02")
	end := named.End.Format("2006-01-02")
	name := start
	if end != start {
		name = start + " to " + end
	}
	if lat, lon, ok := meanGPS(cluster); ok {
		name += fmt.Sprintf(" %.1f, %.1f", lat, lon)
	}
	return name
}

func meanGPS(cluster []Item) (float64, float64, bool) {
	var lat, lon float64
	n := 0
	for _, item := range cluster {
		if item.Lat == nil || item.Lon == nil {
			continue
		}
		lat += *item.Lat
		lon += *item.Lon
		n++
	}
	if n == 0 {
		return 0, 0, false
	}
	return lat / float64(n), lon / float64(n), true
}

// Folder uses the event start date. A year-only event uses _NoDay and does not invent a day.
func Folder(start time.Time, yearOnly bool, year int, slug string) string {
	if slug == "" {
		slug = "event"
	}
	if yearOnly {
		if year == 0 {
			year = start.Year()
		}
		return fmt.Sprintf("Photos/%04d/_NoDay/%s", year, slug)
	}
	return fmt.Sprintf("Photos/%s/%s/%s", start.Format("2006"), start.Format("2006-01-02"), slug)
}

// Slug is ASCII kebab-case.
func Slug(name string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			dash = false
			continue
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			continue
		}
		if !dash && b.Len() > 0 {
			b.WriteByte('-')
			dash = true
		}
	}
	s := strings.Trim(b.String(), "-")
	if s == "" {
		return "event"
	}
	return s
}

func freeSlug(slug string, used map[string]bool) string {
	if slug == "" {
		slug = "event"
	}
	if !used[slug] {
		return slug
	}
	for n := 2; ; n++ {
		next := slug + "-" + strconv.Itoa(n)
		if !used[next] {
			return next
		}
	}
}

// HaversineKM is the great-circle distance. Missing coordinates are the caller's concern.
func HaversineKM(lat1, lon1, lat2, lon2 float64) float64 {
	const earth = 6371.0
	r := math.Pi / 180
	dLat := (lat2 - lat1) * r
	dLon := (lon2 - lon1) * r
	lat1 *= r
	lat2 *= r
	a := math.Sin(dLat/2)*math.Sin(dLat/2) + math.Cos(lat1)*math.Cos(lat2)*math.Sin(dLon/2)*math.Sin(dLon/2)
	if a > 1 {
		a = 1
	}
	return 2 * earth * math.Asin(math.Sqrt(a))
}
