// Package thumb builds one JPEG at a time. A frame above 32 million pixels is
// never decoded, so a crafted 100 MP header stays a header read. File byte size
// does not decide that.
package thumb

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"io"
	"os"
	"strings"
)

const (
	// maxPixels covers a 30 MP camera file such as 6720×4480. The check is
	// width times height. The file's byte size is not a limit.
	maxPixels   = 32_000_000
	maxPreview  = 4 << 20
	longEdge    = 256
	jpegQuality = 70
)

// Result is a thumbnail or a needs_mac mark. JPEG is nil when NeedsMac is set.
type Result struct {
	JPEG          []byte
	NeedsMac      bool
	Width         int
	Height        int
	DecodeSupport string
}

// OpenDecoded decodes a JPEG, PNG, GIF, or BMP. The caller must already know
// the pixel count is at or under its own ceiling. Detail scoring uses 4 MP.
func OpenDecoded(path string) (image.Image, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	img, ok := decodeSmall(file, path)
	if !ok || img == nil {
		return nil, io.ErrUnexpectedEOF
	}
	return img, nil
}

// Dimensions reads a header only. It does not decode pixels.
func Dimensions(path string) (int, int, bool) {
	file, err := os.Open(path)
	if err != nil {
		return 0, 0, false
	}
	defer file.Close()
	w, h, _, ok := header(file)
	return w, h, ok && w > 0 && h > 0
}

// Build scales one file to a long edge of 256. A header above maxPixels returns NeedsMac.
func Build(path string) (Result, error) {
	file, err := os.Open(path)
	if err != nil {
		return Result{}, err
	}
	defer file.Close()
	width, height, preview, ok := header(file)
	if preview != nil {
		img, err := jpeg.Decode(bytes.NewReader(preview))
		if err != nil {
			return Result{NeedsMac: true, Width: width, Height: height, DecodeSupport: "unknown"}, nil
		}
		encoded, err := encode(scale(img, longEdge))
		if err != nil {
			return Result{}, err
		}
		return Result{JPEG: encoded, Width: width, Height: height, DecodeSupport: "preview_only"}, nil
	}
	if !ok || tooBig(width, height) {
		return Result{NeedsMac: true, Width: width, Height: height, DecodeSupport: "unknown"}, nil
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return Result{}, err
	}
	img, decoded := decodeSmall(file, path)
	if !decoded {
		return Result{NeedsMac: true, Width: width, Height: height, DecodeSupport: "unknown"}, nil
	}
	encoded, err := encode(scale(img, longEdge))
	if err != nil {
		return Result{}, err
	}
	nativeW, nativeH := width, height
	if nativeW <= 0 || nativeH <= 0 {
		nativeW, nativeH = img.Bounds().Dx(), img.Bounds().Dy()
	}
	return Result{JPEG: encoded, Width: nativeW, Height: nativeH, DecodeSupport: "full"}, nil
}

func tooBig(width, height int) bool {
	if width <= 0 || height <= 0 {
		return true
	}
	return int64(width)*int64(height) > maxPixels
}

func header(file *os.File) (int, int, []byte, bool) {
	var magic [8]byte
	n, err := io.ReadFull(file, magic[:])
	if err != nil && n < 2 {
		return 0, 0, nil, false
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return 0, 0, nil, false
	}
	if magic[0] == 0xFF && magic[1] == 0xD8 {
		return jpegHeader(file)
	}
	if string(magic[:4]) == "\x89PNG" {
		cfg, err := png.DecodeConfig(file)
		if err != nil {
			return 0, 0, nil, false
		}
		return cfg.Width, cfg.Height, nil, true
	}
	if string(magic[:3]) == "GIF" {
		cfg, err := gif.DecodeConfig(file)
		if err != nil {
			return 0, 0, nil, false
		}
		return cfg.Width, cfg.Height, nil, true
	}
	if magic[0] == 'B' && magic[1] == 'M' {
		w, h, ok := bmpSize(file)
		return w, h, nil, ok
	}
	if (magic[0] == 'I' && magic[1] == 'I') || (magic[0] == 'M' && magic[1] == 'M') {
		w, h, preview, ok := tiffPreview(file)
		return w, h, preview, ok
	}
	return 0, 0, nil, false
}

func jpegHeader(file *os.File) (int, int, []byte, bool) {
	cfg, err := jpeg.DecodeConfig(file)
	width, height, ok := 0, 0, false
	if err == nil {
		width, height, ok = cfg.Width, cfg.Height, true
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return width, height, nil, ok
	}
	preview := jpegPreview(file)
	if preview != nil && len(preview) <= maxPreview {
		if pcfg, err := jpeg.DecodeConfig(bytes.NewReader(preview)); err == nil && (width == 0 || height == 0) {
			width, height, ok = pcfg.Width, pcfg.Height, true
		}
		return width, height, preview, true
	}
	return width, height, nil, ok
}

// jpegPreview returns the EXIF JPEGInterchangeFormat payload when it is present.
func jpegPreview(file *os.File) []byte {
	header := make([]byte, 2)
	if _, err := io.ReadFull(file, header); err != nil || header[0] != 0xFF || header[1] != 0xD8 {
		return nil
	}
	for {
		var marker [2]byte
		if _, err := io.ReadFull(file, marker[:]); err != nil {
			return nil
		}
		if marker[0] != 0xFF {
			return nil
		}
		for marker[1] == 0xFF {
			if _, err := io.ReadFull(file, marker[1:]); err != nil {
				return nil
			}
		}
		if marker[1] == 0xD9 || marker[1] == 0xDA {
			return nil
		}
		var lengthBuf [2]byte
		if _, err := io.ReadFull(file, lengthBuf[:]); err != nil {
			return nil
		}
		length := int(lengthBuf[0])<<8 | int(lengthBuf[1])
		if length < 2 {
			return nil
		}
		payloadLen := length - 2
		if payloadLen > maxPreview {
			if _, err := file.Seek(int64(payloadLen), io.SeekCurrent); err != nil {
				return nil
			}
			continue
		}
		payload := make([]byte, payloadLen)
		if _, err := io.ReadFull(file, payload); err != nil {
			return nil
		}
		if marker[1] != 0xE1 || len(payload) < 14 || string(payload[:6]) != "Exif\x00\x00" {
			continue
		}
		if preview := exifJPEG(payload[6:]); len(preview) > 0 && len(preview) <= maxPreview {
			return preview
		}
	}
}

func exifJPEG(data []byte) []byte {
	if len(data) < 8 {
		return nil
	}
	var order binary.ByteOrder
	switch string(data[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return nil
	}
	if order.Uint16(data[2:4]) != 42 || len(data) < 8 {
		return nil
	}
	return walkIFD(data, order, int(order.Uint32(data[4:8])), 0)
}

func walkIFD(data []byte, order binary.ByteOrder, offset, depth int) []byte {
	if depth > 4 || offset < 0 || offset+2 > len(data) {
		return nil
	}
	count := int(order.Uint16(data[offset : offset+2]))
	cursor := offset + 2
	var jpegOff, jpegLen int
	var next int
	for i := 0; i < count; i++ {
		if cursor+12 > len(data) {
			return nil
		}
		entry := data[cursor : cursor+12]
		cursor += 12
		tag := order.Uint16(entry[0:2])
		value := int(order.Uint32(entry[8:12]))
		switch tag {
		case 0x0201:
			jpegOff = value
		case 0x0202:
			jpegLen = value
		case 0x8769:
			if found := walkIFD(data, order, value, depth+1); len(found) > 0 {
				return found
			}
		}
	}
	if cursor+4 <= len(data) {
		next = int(order.Uint32(data[cursor : cursor+4]))
	}
	if jpegOff > 0 && jpegLen > 0 && jpegLen <= maxPreview && jpegOff+jpegLen <= len(data) {
		return data[jpegOff : jpegOff+jpegLen]
	}
	if next > 0 {
		return walkIFD(data, order, next, depth+1)
	}
	return nil
}

func bmpSize(file *os.File) (int, int, bool) {
	var buf [26]byte
	if _, err := file.ReadAt(buf[:], 0); err != nil {
		return 0, 0, false
	}
	w := int(int32(binary.LittleEndian.Uint32(buf[18:22])))
	h := int(int32(binary.LittleEndian.Uint32(buf[22:26])))
	if h < 0 {
		h = -h
	}
	return w, h, w > 0 && h > 0
}

func tiffPreview(file *os.File) (int, int, []byte, bool) {
	info, err := file.Stat()
	if err != nil || info.Size() > 8<<20 && info.Size() > maxPreview {
		// Large TIFFs are read only at the header and at one embedded JPEG.
	}
	var header [8]byte
	if _, err := file.ReadAt(header[:], 0); err != nil {
		return 0, 0, nil, false
	}
	var order binary.ByteOrder
	switch string(header[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return 0, 0, nil, false
	}
	offset := int64(order.Uint32(header[4:8]))
	width, height, preview := readTIFFIFD(file, order, offset, info.Size(), 0)
	return width, height, preview, width > 0 && height > 0
}

func readTIFFIFD(file *os.File, order binary.ByteOrder, offset, size int64, depth int) (int, int, []byte) {
	if depth > 4 || offset < 0 || offset+2 > size {
		return 0, 0, nil
	}
	var countBuf [2]byte
	if _, err := file.ReadAt(countBuf[:], offset); err != nil {
		return 0, 0, nil
	}
	count := int(order.Uint16(countBuf[:]))
	if count <= 0 || count > 256 {
		return 0, 0, nil
	}
	var width, height, jpegOff, jpegLen int
	var subs []int64
	for i := 0; i < count; i++ {
		var entry [12]byte
		at := offset + 2 + int64(i*12)
		if at+12 > size {
			break
		}
		if _, err := file.ReadAt(entry[:], at); err != nil {
			break
		}
		tag := order.Uint16(entry[0:2])
		value := int(order.Uint32(entry[8:12]))
		switch tag {
		case 256:
			width = value
		case 257:
			height = value
		case 273, 513:
			jpegOff = value
		case 279, 514:
			jpegLen = value
		case 330:
			subs = append(subs, int64(value))
		}
	}
	if jpegOff > 0 && jpegLen > 0 && jpegLen <= maxPreview && int64(jpegOff)+int64(jpegLen) <= size {
		buf := make([]byte, jpegLen)
		if _, err := file.ReadAt(buf, int64(jpegOff)); err == nil && len(buf) > 2 && buf[0] == 0xFF && buf[1] == 0xD8 {
			return width, height, buf
		}
	}
	for _, sub := range subs {
		w, h, preview := readTIFFIFD(file, order, sub, size, depth+1)
		if preview != nil {
			if width == 0 {
				width, height = w, h
			}
			return width, height, preview
		}
		if width == 0 && w > 0 {
			width, height = w, h
		}
	}
	return width, height, nil
}

func decodeSmall(file *os.File, path string) (image.Image, bool) {
	ext := strings.ToLower(strings.TrimPrefix(pathExt(path), "."))
	switch ext {
	case "jpg", "jpeg":
		img, err := jpeg.Decode(file)
		return img, err == nil
	case "png":
		img, err := png.Decode(file)
		return img, err == nil
	case "gif":
		img, err := gif.Decode(file)
		return img, err == nil
	case "bmp":
		img, err := decodeBMP(file)
		return img, err == nil
	default:
		return nil, false
	}
}

func pathExt(path string) string {
	slash := strings.LastIndexAny(path, `/\`)
	base := path
	if slash >= 0 {
		base = path[slash+1:]
	}
	dot := strings.LastIndex(base, ".")
	if dot < 0 {
		return ""
	}
	return base[dot:]
}

func scale(src image.Image, edge int) image.Image {
	bounds := src.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	if width <= 0 || height <= 0 {
		return src
	}
	long := width
	if height > long {
		long = height
	}
	if long <= edge {
		return src
	}
	nw, nh := edge, edge
	if width >= height {
		nh = height * edge / width
		if nh < 1 {
			nh = 1
		}
		nw = edge
	} else {
		nw = width * edge / height
		if nw < 1 {
			nw = 1
		}
		nh = edge
	}
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		sy := bounds.Min.Y + y*height/nh
		for x := 0; x < nw; x++ {
			sx := bounds.Min.X + x*width/nw
			dst.Set(x, y, src.At(sx, sy))
		}
	}
	return dst
}

func encode(img image.Image) ([]byte, error) {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: jpegQuality}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func decodeBMP(file *os.File) (image.Image, error) {
	var hdr [54]byte
	if _, err := io.ReadFull(file, hdr[:]); err != nil {
		return nil, err
	}
	if hdr[0] != 'B' || hdr[1] != 'M' {
		return nil, io.ErrUnexpectedEOF
	}
	offset := int(binary.LittleEndian.Uint32(hdr[10:14]))
	w := int(int32(binary.LittleEndian.Uint32(hdr[18:22])))
	h := int(int32(binary.LittleEndian.Uint32(hdr[22:26])))
	bottomUp := true
	if h < 0 {
		h = -h
		bottomUp = false
	}
	bpp := binary.LittleEndian.Uint16(hdr[28:30])
	compression := binary.LittleEndian.Uint32(hdr[30:34])
	if compression != 0 || (bpp != 24 && bpp != 32) || tooBig(w, h) || offset < 54 {
		return nil, io.ErrUnexpectedEOF
	}
	stride := ((w*int(bpp)/8 + 3) / 4) * 4
	need := int64(offset) + int64(stride)*int64(h)
	// Bound the read by the pixel ceiling, not by the file's byte size.
	if stride <= 0 || need < int64(offset) || need > int64(maxPixels)*4+4096 {
		return nil, io.ErrUnexpectedEOF
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(file, need))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) < need || offset > len(data) {
		return nil, io.ErrUnexpectedEOF
	}
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for row := 0; row < h; row++ {
		srcRow := row
		if bottomUp {
			srcRow = h - 1 - row
		}
		start := offset + srcRow*stride
		for col := 0; col < w; col++ {
			i := start + col*int(bpp)/8
			if i+2 >= len(data) {
				return nil, io.ErrUnexpectedEOF
			}
			img.SetRGBA(col, row, color.RGBA{R: data[i+2], G: data[i+1], B: data[i], A: 255})
		}
	}
	return img, nil
}
