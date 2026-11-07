package detail

import "testing"

func TestSharpCheckerBeatsBlurredUpscale(t *testing.T) {
	sharp := checker(400, 2)
	soft := nearest(boxBlur(sharp, 400, 8), 400, 400, 2000, 2000)
	sharpScore := ScoreGray(sharp, 400, 400)
	softScore := ScoreGray(soft, 2000, 2000)
	if sharpScore <= softScore {
		t.Fatalf("sharp %v soft %v", sharpScore, softScore)
	}
	id, ok := SelectKeeper([]Candidate{
		{ID: 1, Rel: "Photos/sharp.jpg", Ext: "jpg", Score: sharpScore, HasScore: true, Pixels: 400 * 400, Placement: "active"},
		{ID: 2, Rel: "Photos/soft.jpg", Ext: "jpg", Score: softScore, HasScore: true, Pixels: 2000 * 2000, Placement: "active"},
	})
	if !ok || id != 1 {
		t.Fatalf("keeper %d %v", id, ok)
	}
}

func TestEqualScoreKeepsTheSmallerFile(t *testing.T) {
	id, ok := SelectKeeper([]Candidate{
		{ID: 1, Rel: "Photos/big.jpg", Ext: "jpg", Score: 3, HasScore: true, Pixels: 16_000_000, Bytes: 10, Placement: "active"},
		{ID: 2, Rel: "Photos/small.jpg", Ext: "jpg", Score: 3, HasScore: true, Pixels: 1_000_000, Bytes: 10, Placement: "active"},
	})
	if !ok || id != 2 {
		t.Fatalf("keeper %d", id)
	}
}

func TestNullScoreIsNotEligible(t *testing.T) {
	members := []Candidate{
		{ID: 1, Ext: "jpg", Score: 3, HasScore: true, Pixels: 100, Placement: "active"},
		{ID: 2, Ext: "jpg", Score: 3, HasScore: true, Pixels: 100, Placement: "active"},
		{ID: 3, Ext: "jpg", HasScore: false, Pixels: 100, Placement: "active"},
	}
	if EligibleFlag(members) != 0 || EligibleForTrim(members) {
		t.Fatal("eligible")
	}
}

func TestLowerScoreRAWIsNotKeeper(t *testing.T) {
	id, ok := SelectKeeper([]Candidate{
		{ID: 1, Rel: "Photos/a.jpg", Ext: "jpg", Score: 10, HasScore: true, Pixels: 1000, Bytes: 10, Placement: "active"},
		{ID: 2, Rel: "Photos/b.raf", Ext: "raf", Score: 1, HasScore: true, Pixels: 1000, Bytes: 80, Placement: "active"},
	})
	if !ok || id != 1 {
		t.Fatalf("keeper %d", id)
	}
}

func checker(n, cell int) []float64 {
	gray := make([]float64, n*n)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			if ((x/cell)+(y/cell))%2 == 0 {
				gray[y*n+x] = 255
			}
		}
	}
	return gray
}

func boxBlur(src []float64, n, radius int) []float64 {
	dst := make([]float64, n*n)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			var sum, count float64
			for yy := y - radius; yy <= y+radius; yy++ {
				if yy < 0 || yy >= n {
					continue
				}
				for xx := x - radius; xx <= x+radius; xx++ {
					if xx < 0 || xx >= n {
						continue
					}
					sum += src[yy*n+xx]
					count++
				}
			}
			dst[y*n+x] = sum / count
		}
	}
	return dst
}

func nearest(src []float64, sw, sh, dw, dh int) []float64 {
	dst := make([]float64, dw*dh)
	for y := 0; y < dh; y++ {
		sy := y * sh / dh
		for x := 0; x < dw; x++ {
			sx := x * sw / dw
			dst[y*dw+x] = src[sy*sw+sx]
		}
	}
	return dst
}
