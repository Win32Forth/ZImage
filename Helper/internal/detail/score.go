// Package detail scores one preview at a time and chooses the active keeper.
// A missing score stays null. Pixel count is not a substitute.
package detail

import (
	"image"
	"math"
)

// MaxPixels is the helper's detail ceiling. Thumbnail creation uses a separate, higher ceiling.
const MaxPixels = 4_000_000

// ScoreGray is the Laplacian population variance after a long edge of 512.
// The input is not upscaled to manufacture a 1024 preview. A shorter preview is
// scaled up to 512 with separable Lanczos-3.
func ScoreGray(gray []float64, width, height int) float64 {
	if width <= 0 || height <= 0 || len(gray) < width*height {
		return 0
	}
	pw, ph := fitDown(width, height, 1024)
	preview := gray
	if pw != width || ph != height {
		preview = resize(gray, width, height, pw, ph)
	}
	return scorePreview(preview, pw, ph)
}

func scorePreview(gray []float64, width, height int) float64 {
	dw, dh := scaleToLong(width, height, 512)
	scaled := gray
	if dw != width || dh != height {
		scaled = resize(gray, width, height, dw, dh)
	}
	return laplacianVariance(scaled, dw, dh, 4)
}

// PreviewGray samples Rec. 601 luma at long edge min(1024, native). It does not upscale.
func PreviewGray(img image.Image) ([]float64, int, int) {
	bounds := img.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	dw, dh := fitDown(width, height, 1024)
	if dw < 1 {
		dw = 1
	}
	if dh < 1 {
		dh = 1
	}
	gray := make([]float64, dw*dh)
	for y := 0; y < dh; y++ {
		sy := bounds.Min.Y
		if height > 0 {
			sy = bounds.Min.Y + y*height/dh
			if sy >= bounds.Max.Y {
				sy = bounds.Max.Y - 1
			}
		}
		for x := 0; x < dw; x++ {
			sx := bounds.Min.X
			if width > 0 {
				sx = bounds.Min.X + x*width/dw
				if sx >= bounds.Max.X {
					sx = bounds.Max.X - 1
				}
			}
			r, g, b, _ := img.At(sx, sy).RGBA()
			gray[y*dw+x] = 0.299*float64(r)/257 + 0.587*float64(g)/257 + 0.114*float64(b)/257
		}
	}
	return gray, dw, dh
}

// ScoreImage scores a decoded preview. The caller must not pass a frame above MaxPixels.
func ScoreImage(img image.Image) float64 {
	gray, width, height := PreviewGray(img)
	return scorePreview(gray, width, height)
}

func fitDown(width, height, edge int) (int, int) {
	long := width
	if height > long {
		long = height
	}
	if long <= edge || long == 0 {
		return width, height
	}
	return scaleToLong(width, height, edge)
}

func scaleToLong(width, height, edge int) (int, int) {
	if width <= 0 || height <= 0 {
		return width, height
	}
	if width >= height {
		nh := int(math.Round(float64(height) * float64(edge) / float64(width)))
		if nh < 1 {
			nh = 1
		}
		return edge, nh
	}
	nw := int(math.Round(float64(width) * float64(edge) / float64(height)))
	if nw < 1 {
		nw = 1
	}
	return nw, edge
}

func laplacianVariance(gray []float64, width, height, border int) float64 {
	if width <= border*2 || height <= border*2 {
		return 0
	}
	var sum float64
	n := 0
	for y := border; y < height-border; y++ {
		for x := border; x < width-border; x++ {
			i := y*width + x
			sum += gray[i-width] + gray[i-1] - 4*gray[i] + gray[i+1] + gray[i+width]
			n++
		}
	}
	if n == 0 {
		return 0
	}
	mean := sum / float64(n)
	var acc float64
	for y := border; y < height-border; y++ {
		for x := border; x < width-border; x++ {
			i := y*width + x
			d := gray[i-width] + gray[i-1] - 4*gray[i] + gray[i+1] + gray[i+width] - mean
			acc += d * d
		}
	}
	return acc / float64(n)
}

func resize(src []float64, sw, sh, dw, dh int) []float64 {
	if sw == dw && sh == dh {
		out := make([]float64, len(src))
		copy(out, src)
		return out
	}
	tmp := make([]float64, sh*dw)
	for y := 0; y < sh; y++ {
		row := src[y*sw : y*sw+sw]
		for x := 0; x < dw; x++ {
			pos := (float64(x)+0.5)*float64(sw)/float64(dw) - 0.5
			tmp[y*dw+x] = lanczosAt(row, pos)
		}
	}
	dst := make([]float64, dw*dh)
	col := make([]float64, sh)
	for x := 0; x < dw; x++ {
		for y := 0; y < sh; y++ {
			col[y] = tmp[y*dw+x]
		}
		for y := 0; y < dh; y++ {
			pos := (float64(y)+0.5)*float64(sh)/float64(dh) - 0.5
			dst[y*dw+x] = lanczosAt(col, pos)
		}
	}
	return dst
}

func lanczosAt(row []float64, pos float64) float64 {
	n := len(row)
	if n == 0 {
		return 0
	}
	center := int(math.Floor(pos))
	var sum, weight float64
	for i := center - 2; i <= center+3; i++ {
		w := lanczos3(pos - float64(i))
		if w == 0 {
			continue
		}
		index := i
		if index < 0 {
			index = 0
		}
		if index >= n {
			index = n - 1
		}
		sum += w * row[index]
		weight += w
	}
	if weight == 0 {
		index := center
		if index < 0 {
			index = 0
		}
		if index >= n {
			index = n - 1
		}
		return row[index]
	}
	return sum / weight
}

func lanczos3(x float64) float64 {
	if x < 0 {
		x = -x
	}
	if x == 0 {
		return 1
	}
	if x >= 3 {
		return 0
	}
	pix := math.Pi * x
	return 3 * math.Sin(pix) * math.Sin(pix/3) / (math.Pi * math.Pi * x * x)
}
