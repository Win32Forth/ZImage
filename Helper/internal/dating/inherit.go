package dating

import "time"

// Neighbor is one dHash neighbor already accepted by the band index.
type Neighbor struct {
	Time       time.Time
	Confidence float64
	FullDay    bool
	YearOnly   bool
	Year       int
	Inherited  bool
	Distance   int
}

// Burst is a near-duplicate whose own clock is within two seconds.
type Burst struct {
	Time       time.Time
	Confidence float64
	FullDay    bool
	YearOnly   bool
	Year       int
	Distance   int
	Delta      time.Duration
}

// Inherit copies a neighbor's date once. A neighbor that was itself inherited does not chain.
func Inherit(base Decision, n Neighbor) Decision {
	if n.Inherited || n.Distance < 0 || n.Distance > 8 || n.Confidence < PlacementThreshold {
		return base
	}
	conf := n.Confidence - 0.15
	if conf <= base.Confidence {
		return base
	}
	year := n.Year
	if year == 0 && !n.Time.IsZero() {
		year = n.Time.Year()
	}
	return Decision{
		Confidence: conf,
		Source:     "dhash",
		Capture:    n.Time,
		HasCapture: true,
		FullDay:    n.FullDay,
		YearOnly:   n.YearOnly,
		Year:       year,
	}
}

// ApplyBurst keeps the higher confidence when two hashes are a burst.
// A dHash date is a copy of a neighbor. That copy is not a second exposure, so a later pass does not promote it to burst.
func ApplyBurst(base Decision, b Burst) Decision {
	if base.Source == "dhash" || !base.HasCapture || b.Distance < 0 || b.Distance > 8 || b.Delta < 0 || b.Delta > 2*time.Second {
		return base
	}
	if b.Confidence <= base.Confidence {
		return base
	}
	year := b.Year
	if year == 0 && !b.Time.IsZero() {
		year = b.Time.Year()
	}
	return Decision{
		Confidence: b.Confidence,
		Source:     "burst",
		Capture:    b.Time,
		HasCapture: true,
		FullDay:    b.FullDay,
		YearOnly:   b.YearOnly,
		Year:       year,
	}
}
