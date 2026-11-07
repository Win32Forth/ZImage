package events

import (
	"testing"
	"time"
)

func TestGapsAndGPS(t *testing.T) {
	base := time.Date(2020, 5, 1, 12, 0, 0, 0, time.UTC)
	if len(Cluster([]Item{
		stamp(1, base),
		stamp(2, base.Add(8*time.Hour)),
	})) != 2 {
		t.Fatal("8h should split")
	}
	if len(Cluster([]Item{
		stamp(1, base),
		stamp(2, base.Add(2*time.Hour)),
	})) != 1 {
		t.Fatal("2h should stay")
	}
	near := stamp(1, base)
	far := stamp(2, base.Add(3*time.Hour))
	if len(Cluster([]Item{near, far})) != 1 {
		t.Fatal("missing GPS should stay")
	}
	lat1, lon1 := 0.0, 0.0
	lat2, lon2 := 0.5, 0.0
	near.Lat, near.Lon = &lat1, &lon1
	far.Lat, far.Lon = &lat2, &lon2
	if HaversineKM(lat1, lon1, lat2, lon2) <= 50 {
		t.Fatal("fixture distance")
	}
	if len(Cluster([]Item{near, far})) != 2 {
		t.Fatal("far GPS should split")
	}
	exact := far
	exact.Time = base.Add(2 * time.Hour)
	if len(Cluster([]Item{near, exact})) != 1 {
		t.Fatal("exact 2h should stay")
	}
	left := stamp(1, base)
	right := stamp(2, base.Add(10*time.Hour))
	left.HasHash, right.HasHash = true, true
	left.Hash, right.Hash = 1, 1
	if len(Cluster([]Item{left, right})) != 1 {
		t.Fatal("dHash should rejoin 10h")
	}
	right.Time = base.Add(19 * time.Hour)
	if len(Cluster([]Item{left, right})) != 2 {
		t.Fatal("19h should stay split")
	}
}

func TestYearOnlyStaysOutOfTheHourSplitter(t *testing.T) {
	day := stamp(1, time.Date(2020, 5, 1, 12, 0, 0, 0, time.UTC))
	year := Item{ID: 2, HasTime: true, YearOnly: true, Year: 1964, Time: time.Date(1964, 1, 1, 0, 0, 0, 0, time.UTC), Rel: "Photos/1964/Scans/a.jpg"}
	year2 := year
	year2.ID = 3
	year2.Time = year.Time.Add(24 * time.Hour)
	clusters := Cluster([]Item{day, year, year2})
	if len(clusters) != 2 {
		t.Fatalf("clusters %d", len(clusters))
	}
}

func stamp(id int64, when time.Time) Item {
	return Item{ID: id, Time: when, HasTime: true, Rel: "Photos/a.jpg"}
}
