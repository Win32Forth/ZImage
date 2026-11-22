package thumb

import (
	"bytes"
	"encoding/binary"
	"image"
	"os"
	"path/filepath"
	"testing"
)

func TestX3FPlainRGBKeepsThePaddedRow(t *testing.T) {
	payload := plainRGBPayload(2, 2, 8, [][]byte{
		{200, 10, 20, 30, 40, 50},
		{1, 2, 3, 4, 5, 6},
	})
	path := writeX3F(t, []x3fPart{{kind: "IMA2", data: seci(3, 2, 2, 8, payload)}})
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	img, width, height, ok := x3fPreview(file, 1000)
	if !ok || width != 2 || height != 2 {
		t.Fatalf("preview %v %d %d", ok, width, height)
	}
	assertRGB(t, img, 0, 0, 200, 10, 20)
	assertRGB(t, img, 1, 0, 30, 40, 50)
	assertRGB(t, img, 0, 1, 1, 2, 3)
	assertRGB(t, img, 1, 1, 4, 5, 6)
}

func TestX3FHuffmanWrapsInEightBits(t *testing.T) {
	payload := huffmanPayload([][]byte{
		{200, 0, 0, 57, 0, 0},
		{9, 8, 7, 1, 0, 0},
	})
	path := writeX3F(t, []x3fPart{{kind: "IMA2", data: seci(11, 2, 2, 0, payload)}})
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	img, width, height, ok := x3fPreview(file, 1000)
	if !ok || width != 2 || height != 2 {
		t.Fatalf("preview %v %d %d", ok, width, height)
	}
	assertRGB(t, img, 0, 0, 200, 0, 0)
	assertRGB(t, img, 1, 0, 1, 0, 0)
	assertRGB(t, img, 0, 1, 9, 8, 7)
	assertRGB(t, img, 1, 1, 10, 8, 7)
}

func TestX3FBuildPreviewsAJPEGPastEightMegabytes(t *testing.T) {
	jpegBytes := padJPEG(solidJPEG(t, 48, 32), 8<<20+64)
	if len(jpegBytes) <= 8<<20 {
		t.Fatalf("fixture %d", len(jpegBytes))
	}
	tiny := plainRGBPayload(1, 1, 4, [][]byte{{9, 8, 7}})
	path := writeX3F(t, []x3fPart{
		{kind: "IMAG", data: seci(3, 1, 1, 4, tiny)},
		{kind: "IMA2", data: seci(18, 48, 32, 0, jpegBytes)},
	})
	result, err := Build(path)
	if err != nil {
		t.Fatal(err)
	}
	if result.NeedsMac || result.DecodeSupport != "preview_only" || result.Width != 48 || result.Height != 32 {
		t.Fatalf("result %+v", result)
	}
	if edge := jpegLong(t, result.JPEG); edge > 256 || edge == 0 {
		t.Fatalf("long edge %d", edge)
	}
}

func TestX3FBuildLeavesAJPEGOnTheOldPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "plain.jpg")
	if err := os.WriteFile(path, solidJPEG(t, 40, 20), 0o644); err != nil {
		t.Fatal(err)
	}
	result, err := Build(path)
	if err != nil {
		t.Fatal(err)
	}
	if result.NeedsMac || result.DecodeSupport != "full" || result.Width != 40 || result.Height != 20 {
		t.Fatalf("result %+v", result)
	}
}

func TestX3FWithoutAPreviewNeedsMac(t *testing.T) {
	path := filepath.Join(t.TempDir(), "broken.x3f")
	if err := os.WriteFile(path, []byte("FOVbjunk"), 0o644); err != nil {
		t.Fatal(err)
	}
	result, err := Build(path)
	if err != nil {
		t.Fatal(err)
	}
	if !result.NeedsMac || result.JPEG != nil {
		t.Fatalf("result %+v", result)
	}
}

type x3fPart struct {
	kind string
	data []byte
}

func writeX3F(t *testing.T, parts []x3fPart) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sample.x3f")
	if err := os.WriteFile(path, x3fContainer(parts), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func x3fContainer(parts []x3fPart) []byte {
	body := []byte("FOVb")
	type placed struct {
		offset uint32
		length uint32
		kind   string
	}
	var entries []placed
	for _, part := range parts {
		entries = append(entries, placed{offset: uint32(len(body)), length: uint32(len(part.data)), kind: part.kind})
		body = append(body, part.data...)
	}
	directory := uint32(len(body))
	body = append(body, []byte("SECd")...)
	body = append(body, le32(0)...)
	body = append(body, le32(uint32(len(entries)))...)
	for _, item := range entries {
		body = append(body, le32(item.offset)...)
		body = append(body, le32(item.length)...)
		kind := item.kind
		if len(kind) != 4 {
			kind = "IMAG"
		}
		body = append(body, []byte(kind)...)
	}
	body = append(body, le32(directory)...)
	return body
}

func seci(format, columns, rows, rowSize int, payload []byte) []byte {
	header := []byte("SECi")
	header = append(header, le32(0)...)
	header = append(header, le32(2)...)
	header = append(header, le32(uint32(format))...)
	header = append(header, le32(uint32(columns))...)
	header = append(header, le32(uint32(rows))...)
	header = append(header, le32(uint32(rowSize))...)
	return append(header, payload...)
}

func plainRGBPayload(columns, rows, stride int, rowsRGB [][]byte) []byte {
	out := make([]byte, 0, stride*rows)
	for _, row := range rowsRGB {
		line := make([]byte, stride)
		for i := range line {
			line[i] = 0xEE
		}
		copy(line, row)
		out = append(out, line...)
	}
	return out
}

func huffmanPayload(rows [][]byte) []byte {
	table := make([]byte, 256*4)
	for symbol := 0; symbol < 256; symbol++ {
		binary.LittleEndian.PutUint32(table[symbol*4:], uint32(8<<27)|uint32(symbol))
	}
	var encoded []byte
	offsets := make([]byte, 0, len(rows)*4)
	for _, row := range rows {
		offsets = binary.LittleEndian.AppendUint32(offsets, uint32(len(encoded)))
		encoded = append(encoded, row...)
		for len(encoded)%4 != 0 {
			encoded = append(encoded, 0xFF)
		}
	}
	out := append(table, encoded...)
	return append(out, offsets...)
}

func padJPEG(src []byte, extra int) []byte {
	out := append([]byte{}, src[:2]...)
	remaining := extra
	for remaining > 0 {
		payload := remaining
		if payload > 65533 {
			payload = 65533
		}
		length := payload + 2
		out = append(out, 0xFF, 0xFE, byte(length>>8), byte(length))
		out = append(out, bytes.Repeat([]byte{0}, payload)...)
		remaining -= payload
	}
	return append(out, src[2:]...)
}

func le32(value uint32) []byte {
	var buf [4]byte
	binary.LittleEndian.PutUint32(buf[:], value)
	return buf[:]
}

func assertRGB(t *testing.T, img image.Image, x, y int, r, g, b uint32) {
	t.Helper()
	rr, gg, bb, _ := img.At(x, y).RGBA()
	if rr>>8 != r || gg>>8 != g || bb>>8 != b {
		t.Fatalf("pixel %d,%d got %d %d %d", x, y, rr>>8, gg>>8, bb>>8)
	}
}
