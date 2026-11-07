package dhashindex

import "image"

// HashImage is a 64-bit difference hash from a 9×8 grayscale sample.
// Bit 0 is the first comparison on the top row.
func HashImage(img image.Image) uint64 {
	const dw, dh = 9, 8
	bounds := img.Bounds()
	sw, sh := bounds.Dx(), bounds.Dy()
	if sw <= 0 || sh <= 0 {
		return 0
	}
	px := make([]float64, dw*dh)
	for y := 0; y < dh; y++ {
		sy := bounds.Min.Y + (y*sh)/dh
		if sy >= bounds.Max.Y {
			sy = bounds.Max.Y - 1
		}
		for x := 0; x < dw; x++ {
			sx := bounds.Min.X + (x*sw)/dw
			if sx >= bounds.Max.X {
				sx = bounds.Max.X - 1
			}
			r, g, b, _ := img.At(sx, sy).RGBA()
			px[y*dw+x] = 0.299*float64(r) + 0.587*float64(g) + 0.114*float64(b)
		}
	}
	var hash uint64
	var bit uint
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			if px[y*dw+x] > px[y*dw+x+1] {
				hash |= 1 << bit
			}
			bit++
		}
	}
	return hash
}
