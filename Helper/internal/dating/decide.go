// Package dating assigns capture confidence and planned destinations.
// It does not move or delete library files.
package dating

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	// ConfidenceEXIFOriginal is DateTimeOriginal, with OffsetTimeOriginal when the file has it.
	ConfidenceEXIFOriginal = 0.95
	// ConfidenceEXIFDigitized is DateTimeDigitized.
	ConfidenceEXIFDigitized = 0.85
	// ConfidenceEXIFDateTime is the file-change DateTime tag.
	ConfidenceEXIFDateTime = 0.70
	// ConfidenceVideoCreated is the movie container creation time.
	ConfidenceVideoCreated = 0.90
	// ConfidenceFilename is a full day found in the filename or path.
	ConfidenceFilename = 0.80
	// ConfidenceYear is a year folder. The day stays unknown.
	ConfidenceYear = 0.75
	// ConfidenceMTime is the filesystem time.
	ConfidenceMTime = 0.40
	// ConfidenceUser is a date typed in the inspector.
	ConfidenceUser = 1
	// ConfidenceMacSuggest is a Mac checkpoint suggestion. It is never 1.
	ConfidenceMacSuggest = 0.90
	// PlacementThreshold is the confidence required for a year or day folder.
	PlacementThreshold = 0.70
	// SharedStampLimit rejects a timestamp copied onto too many files in one directory.
	SharedStampLimit = 25
)

// Stamp is one parsed clock reading.
type Stamp struct {
	Time        time.Time
	OffsetKnown bool
}

// Input is the evidence for one file. A zero Now uses the current year.
type Input struct {
	RelPath        string
	EXIFOriginal   *Stamp
	EXIFDigitized  *Stamp
	EXIFDateTime   *Stamp
	SameOriginal   int
	SameDigitized  int
	SameChanged    int
	VideoCreated   *Stamp
	SameVideo      int
	MTime          *time.Time
	SameMTimeCount int
	Now            time.Time
}

// Decision is the strongest reliable evidence for one file.
type Decision struct {
	Confidence  float64
	Source      string
	Capture     time.Time
	HasCapture  bool
	FullDay     bool
	YearOnly    bool
	Year        int
	OffsetKnown bool
}

// StoredTime is the catalog text. A year-only decision is the four-digit year.
func (d Decision) StoredTime() string {
	if !d.HasCapture {
		return ""
	}
	if d.YearOnly {
		return fmt.Sprintf("%04d", d.Year)
	}
	return d.Capture.Format(time.RFC3339)
}

// Places reports whether the file can leave the review park.
func (d Decision) Places() bool {
	return d.Confidence >= PlacementThreshold && d.HasCapture
}

// User is a date typed in the inspector. Confidence is 1. It is never produced by a file pass.
func User(text string) (Decision, bool) {
	d, ok := parseClock(text)
	if !ok {
		return Decision{}, false
	}
	d.Confidence = ConfidenceUser
	d.Source = "user"
	return d, true
}

// Suggest is a Mac checkpoint date. Confidence is 0.90. A rejected wall clock is ignored.
func Suggest(text string, now time.Time) Decision {
	if now.IsZero() {
		now = time.Now()
	}
	d, ok := parseClock(text)
	if !ok {
		return Decision{}
	}
	if d.YearOnly {
		if d.Year == 1969 || !yearOK(d.Year, now) {
			return Decision{}
		}
	} else if !acceptWall(d.Capture, now) {
		return Decision{}
	}
	d.Confidence = ConfidenceMacSuggest
	d.Source = "mac_suggest"
	return d
}

func parseClock(text string) (Decision, bool) {
	text = strings.TrimSpace(text)
	if len(text) == 4 {
		year, err := strconv.Atoi(text)
		if err != nil || year < 0 {
			return Decision{}, false
		}
		return Decision{
			HasCapture: true,
			YearOnly:   true,
			Year:       year,
			Capture:    time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC),
		}, true
	}
	if when, err := time.Parse(time.RFC3339, text); err == nil {
		return Decision{
			HasCapture: true,
			FullDay:    true,
			Year:       when.Year(),
			Capture:    when,
		}, true
	}
	if len(text) == 10 && text[4] == '-' && text[7] == '-' {
		year, errY := strconv.Atoi(text[0:4])
		month, errM := strconv.Atoi(text[5:7])
		day, errD := strconv.Atoi(text[8:10])
		if errY != nil || errM != nil || errD != nil || !validYMD(year, month, day) {
			return Decision{}, false
		}
		return Decision{
			HasCapture: true,
			FullDay:    true,
			Year:       year,
			Capture:    time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC),
		}, true
	}
	return Decision{}, false
}

type candidate struct {
	conf     float64
	source   string
	when     time.Time
	has      bool
	full     bool
	yearOnly bool
	year     int
	offset   bool
	rank     int
}

// Decide keeps the strongest evidence that passes the reject rules.
// Filename dates are not rejected for a shared directory timestamp.
func Decide(in Input) Decision {
	now := in.Now
	if now.IsZero() {
		now = time.Now()
	}
	var best candidate
	consider := func(c candidate) {
		if !c.has {
			return
		}
		if c.conf > best.conf || (c.conf == best.conf && best.has && c.rank < best.rank) {
			best = c
		}
	}
	if in.EXIFOriginal != nil {
		consider(exifCandidate(*in.EXIFOriginal, in.SameOriginal, now, ConfidenceEXIFOriginal, "exif_original", 0))
	}
	if in.EXIFDigitized != nil {
		consider(exifCandidate(*in.EXIFDigitized, in.SameDigitized, now, ConfidenceEXIFDigitized, "exif_digitized", 1))
	}
	if in.EXIFDateTime != nil {
		consider(exifCandidate(*in.EXIFDateTime, in.SameChanged, now, ConfidenceEXIFDateTime, "exif_datetime", 2))
	}
	if in.VideoCreated != nil {
		consider(exifCandidate(*in.VideoCreated, in.SameVideo, now, ConfidenceVideoCreated, "video_created", 3))
	}
	if when, ok := pathDate(in.RelPath, now); ok {
		consider(candidate{conf: ConfidenceFilename, source: "filename", when: when, has: true, full: true, year: when.Year(), rank: 4})
	}
	if year, ok := yearFromPath(in.RelPath, now); ok {
		consider(candidate{
			conf: ConfidenceYear, source: "year_folder", has: true, yearOnly: true, year: year, rank: 5,
			when: time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC),
		})
	}
	if in.MTime != nil && in.SameMTimeCount <= SharedStampLimit && acceptWall(*in.MTime, now) {
		when := in.MTime.UTC()
		consider(candidate{conf: ConfidenceMTime, source: "mtime", when: when, has: true, full: true, year: when.Year(), rank: 6})
	}
	if !best.has {
		return Decision{}
	}
	return Decision{
		Confidence:  best.conf,
		Source:      best.source,
		Capture:     best.when,
		HasCapture:  true,
		FullDay:     best.full,
		YearOnly:    best.yearOnly,
		Year:        best.year,
		OffsetKnown: best.offset,
	}
}

func exifCandidate(stamp Stamp, same int, now time.Time, conf float64, source string, rank int) candidate {
	if same > SharedStampLimit || !acceptWall(stamp.Time, now) {
		return candidate{}
	}
	return candidate{
		conf: conf, source: source, when: stamp.Time, has: true, full: true,
		year: stamp.Time.Year(), offset: stamp.OffsetKnown, rank: rank,
	}
}

func acceptWall(t time.Time, now time.Time) bool {
	if !yearOK(t.Year(), now) || epochDay(t) {
		return false
	}
	return true
}

func yearOK(year int, now time.Time) bool {
	return year >= 1960 && year <= now.Year()+1
}

func epochDay(t time.Time) bool {
	year, month, day := t.Date()
	if year == 1969 && month == time.December && day == 31 {
		return true
	}
	return year == 1970 && month == time.January && day == 1
}

var (
	imgDate = regexp.MustCompile(`(?i)(?:^|[^A-Za-z0-9])IMG_(\d{4})(\d{2})(\d{2})(?:[^0-9]|$)`)
	isoDate = regexp.MustCompile(`(?:^|[^0-9])(\d{4})-(\d{2})-(\d{2})(?:[^0-9]|$)`)
	ymdDate = regexp.MustCompile(`(?:^|[^0-9])(\d{4})(\d{2})(\d{2})(?:[^0-9]|$)`)
	yearDir = regexp.MustCompile(`^\d{4}$`)
)

func pathDate(rel string, now time.Time) (time.Time, bool) {
	base := rel
	if i := strings.LastIndex(rel, "/"); i >= 0 {
		base = rel[i+1:]
	}
	if when, ok := findDate(base, now); ok {
		return when, true
	}
	return findDate(rel, now)
}

func findDate(text string, now time.Time) (time.Time, bool) {
	if text == "" {
		return time.Time{}, false
	}
	padded := " " + text
	bestAt := -1
	var best time.Time
	found := false
	patterns := []*regexp.Regexp{imgDate, isoDate, ymdDate}
	for _, pattern := range patterns {
		for _, m := range pattern.FindAllStringSubmatchIndex(padded, -1) {
			if len(m) < 8 {
				continue
			}
			year, _ := strconv.Atoi(padded[m[2]:m[3]])
			month, _ := strconv.Atoi(padded[m[4]:m[5]])
			day, _ := strconv.Atoi(padded[m[6]:m[7]])
			if !validYMD(year, month, day) || !yearOK(year, now) {
				continue
			}
			when := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
			if epochDay(when) {
				continue
			}
			// The date nearest the file wins. An earlier pattern keeps the same span.
			if found && m[2] <= bestAt {
				continue
			}
			bestAt = m[2]
			best = when
			found = true
		}
	}
	return best, found
}

func validYMD(year, month, day int) bool {
	if month < 1 || month > 12 || day < 1 {
		return false
	}
	when := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
	return when.Year() == year && int(when.Month()) == month && when.Day() == day
}

func yearFromPath(rel string, now time.Time) (int, bool) {
	parts := strings.Split(rel, "/")
	if len(parts) > 0 {
		parts = parts[:len(parts)-1]
	}
	found := 0
	ok := false
	for _, part := range parts {
		if !yearDir.MatchString(part) {
			continue
		}
		year, err := strconv.Atoi(part)
		if err != nil || year == 1969 || !yearOK(year, now) {
			continue
		}
		found = year
		ok = true
	}
	return found, ok
}
