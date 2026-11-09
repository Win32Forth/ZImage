package thumb

import (
	"bytes"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestHundredMegapixelHeaderIsNotDecoded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "big.jpg")
	if err := os.WriteFile(path, jpegSOF(10000, 10000), 0o644); err != nil {
		t.Fatal(err)
	}
	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	result, err := Build(path)
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	if err != nil {
		t.Fatal(err)
	}
	if !result.NeedsMac {
		t.Fatal("expected needs_mac")
	}
	if result.JPEG != nil {
		t.Fatal("decoded a thumbnail")
	}
	used := after.TotalAlloc - before.TotalAlloc
	if used > 64<<20 {
		t.Fatalf("allocated %d bytes", used)
	}
}

func TestPixelCeilingCoversThirtyMegapixels(t *testing.T) {
	if tooBig(6000, 5000) || tooBig(6720, 4480) {
		t.Fatal("a 30 MP frame was refused")
	}
	if !tooBig(10000, 10000) {
		t.Fatal("a 100 MP frame was allowed")
	}
}

func TestPortraitSizedJPEGIsPreviewed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "portrait.jpg")
	// 1920×2560 is 4.9 MP. The decoded buffer is about 20 MB, over the old 16 MB cap.
	if err := os.WriteFile(path, solidJPEG(t, 1920, 2560), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	result, err := Build(path)
	if err != nil {
		t.Fatal(err)
	}
	if result.NeedsMac || result.Width != 1920 || result.Height != 2560 || jpegLong(t, result.JPEG) != 256 {
		t.Fatalf("result %+v fileBytes %d", result, info.Size())
	}
}

func TestThirtyMegapixelJPEGIsPreviewed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "thirty.jpg")
	if err := os.WriteFile(path, solidJPEG(t, 6000, 5000), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	result, err := Build(path)
	if err != nil {
		t.Fatal(err)
	}
	if result.NeedsMac || result.DecodeSupport != "full" || result.Width != 6000 || result.Height != 5000 || jpegLong(t, result.JPEG) != 256 {
		t.Fatalf("result %+v fileBytes %d", result, info.Size())
	}
}

func TestSmallJPEGLongEdgeStaysAtMost256(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wide.jpg")
	if err := os.WriteFile(path, solidJPEG(t, 800, 20), 0o644); err != nil {
		t.Fatal(err)
	}
	result, err := Build(path)
	if err != nil {
		t.Fatal(err)
	}
	if result.NeedsMac || jpegLong(t, result.JPEG) != 256 {
		t.Fatalf("result %+v len %d", result.NeedsMac, len(result.JPEG))
	}
}

func jpegLong(t *testing.T, jpegBytes []byte) int {
	t.Helper()
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(jpegBytes))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Height > cfg.Width {
		return cfg.Height
	}
	return cfg.Width
}

func jpegSOF(width, height int) []byte {
	return []byte{
		0xFF, 0xD8,
		0xFF, 0xC0,
		0x00, 0x0B,
		0x08,
		byte(height >> 8), byte(height),
		byte(width >> 8), byte(width),
		0x01,
		0x01, 0x11, 0x00,
		0xFF, 0xD9,
	}
}

func solidJPEG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewGray(image.Rect(0, 0, width, height))
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 70}); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}
