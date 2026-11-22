package thumb

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/jpeg"
	"io"
	"os"
)

const (
	x3fReadBudget = 128 << 20
	x3fMaxEdge    = 20_000
	x3fMaxPixels  = 48_000_000
	// A decoded JPEG above this is left for the Mac. 16 MP of RGBA is 64 MB.
	x3fJPEGPixels = 16_000_000
)

// x3fPreview reads the largest type-2 preview and scales it to maxEdge.
// width and height are the preview's own size. ok is false when the file has none.
func x3fPreview(file *os.File, maxEdge int) (image.Image, int, int, bool) {
	info, err := file.Stat()
	if err != nil || info.Size() < 8 || info.Size() > int64(^uint64(0)>>1) {
		return nil, 0, 0, false
	}
	size := info.Size()
	var magic [4]byte
	if _, err := file.ReadAt(magic[:], 0); err != nil || string(magic[:]) != "FOVb" {
		return nil, 0, 0, false
	}
	choices := x3fChoices(file, size)
	if len(choices) == 0 {
		return nil, 0, 0, false
	}
	for _, choice := range choices {
		img, width, height := x3fDecode(file, choice, maxEdge)
		if img == nil {
			continue
		}
		return img, width, height, true
	}
	return nil, 0, 0, false
}

type x3fChoice struct {
	offset  int64
	length  int
	pixels  int
	format  int
	columns int
	rows    int
	rowSize int
	seci    bool
}

func (c x3fChoice) payloadOffset() int64 {
	if c.seci {
		return c.offset + 28
	}
	return c.offset
}

func (c x3fChoice) payloadCount() int {
	if c.seci {
		return c.length - 28
	}
	return c.length
}

func x3fChoices(file *os.File, size int64) []x3fChoice {
	var tail [4]byte
	if _, err := file.ReadAt(tail[:], size-4); err != nil {
		return nil
	}
	directory := int64(binary.LittleEndian.Uint32(tail[:]))
	header := make([]byte, 12)
	if _, err := file.ReadAt(header, directory); err != nil || string(header[:4]) != "SECd" {
		return nil
	}
	count := int(binary.LittleEndian.Uint32(header[8:]))
	if count < 0 || count > 4096 {
		return nil
	}
	table := make([]byte, count*12)
	if count > 0 {
		if directory < 0 || directory+12+int64(len(table)) > size {
			return nil
		}
		if _, err := file.ReadAt(table, directory+12); err != nil {
			return nil
		}
	}
	var choices []x3fChoice
	for index := 0; index < count; index++ {
		entry := table[index*12 : (index+1)*12]
		offset := int64(binary.LittleEndian.Uint32(entry[0:]))
		length := int64(binary.LittleEndian.Uint32(entry[4:]))
		if length < 4 || length > x3fReadBudget || offset < 0 || offset > size || length > size-offset {
			continue
		}
		peekN := int(length)
		if peekN > 28 {
			peekN = 28
		}
		peek := make([]byte, peekN)
		if _, err := file.ReadAt(peek, offset); err != nil {
			continue
		}
		if peek[0] == 0xFF && peek[1] == 0xD8 {
			cols, rows := x3fJPEGSize(file, offset, int(length))
			choices = append(choices, x3fChoice{
				offset: offset, length: int(length), pixels: cols * rows,
				format: 18, columns: cols, rows: rows,
			})
			continue
		}
		if len(peek) < 28 || string(peek[:4]) != "SECi" {
			continue
		}
		imageType := binary.LittleEndian.Uint32(peek[8:])
		format := binary.LittleEndian.Uint32(peek[12:])
		if imageType != 2 || (format != 3 && format != 11 && format != 18) {
			continue
		}
		columns := int(binary.LittleEndian.Uint32(peek[16:]))
		rows := int(binary.LittleEndian.Uint32(peek[20:]))
		pixels := 0
		if x3fLegal(columns, rows) {
			pixels = columns * rows
		}
		if format == 18 && pixels == 0 {
			columns, rows = x3fJPEGSize(file, offset+28, int(length-28))
			if x3fLegal(columns, rows) {
				pixels = columns * rows
			}
		}
		choices = append(choices, x3fChoice{
			offset: offset, length: int(length), pixels: pixels, format: int(format),
			columns: columns, rows: rows, rowSize: int(binary.LittleEndian.Uint32(peek[24:])),
			seci: true,
		})
	}
	// Most pixels first. A known size beats an unknown one because unknown is zero.
	for i := 1; i < len(choices); i++ {
		item := choices[i]
		j := i
		for j > 0 && x3fBetter(item, choices[j-1]) {
			choices[j] = choices[j-1]
			j--
		}
		choices[j] = item
	}
	return choices
}

func x3fBetter(a, b x3fChoice) bool {
	if a.pixels != b.pixels {
		return a.pixels > b.pixels
	}
	return a.payloadCount() > b.payloadCount()
}

func x3fLegal(columns, rows int) bool {
	return columns > 0 && rows > 0 && columns <= x3fMaxEdge && rows <= x3fMaxEdge && rows <= x3fMaxPixels/columns
}

func x3fDecode(file *os.File, choice x3fChoice, maxEdge int) (image.Image, int, int) {
	payload := x3fRead(file, choice.payloadOffset(), choice.payloadCount())
	if payload == nil {
		return nil, 0, 0
	}
	switch choice.format {
	case 18:
		if len(payload) < 2 || payload[0] != 0xFF || payload[1] != 0xD8 {
			return nil, 0, 0
		}
		cfg, err := jpeg.DecodeConfig(bytes.NewReader(payload))
		if err != nil || !x3fLegal(cfg.Width, cfg.Height) || cfg.Width*cfg.Height > x3fJPEGPixels {
			return nil, 0, 0
		}
		img, err := jpeg.Decode(bytes.NewReader(payload))
		if err != nil {
			return nil, 0, 0
		}
		return scale(img, maxEdge), cfg.Width, cfg.Height
	case 3:
		if !x3fLegal(choice.columns, choice.rows) {
			return nil, 0, 0
		}
		return x3fPlain(payload, choice, maxEdge), choice.columns, choice.rows
	case 11:
		if !x3fLegal(choice.columns, choice.rows) {
			return nil, 0, 0
		}
		return x3fHuffman(payload, choice, maxEdge), choice.columns, choice.rows
	default:
		return nil, 0, 0
	}
}

// x3fFit is the long-edge fit used by scale. A small preview stays its own size.
func x3fFit(width, height, edge int) (int, int) {
	if width <= 0 || height <= 0 || edge <= 0 {
		return width, height
	}
	long := width
	if height > long {
		long = height
	}
	if long <= edge {
		return width, height
	}
	if width >= height {
		nh := height * edge / width
		if nh < 1 {
			nh = 1
		}
		return edge, nh
	}
	nw := width * edge / height
	if nw < 1 {
		nw = 1
	}
	return nw, edge
}

func x3fPlain(payload []byte, choice x3fChoice, maxEdge int) image.Image {
	packed := choice.columns * 3
	stride := choice.rowSize
	if stride == 0 {
		stride = (packed + 3) &^ 3
	}
	if stride < packed || choice.rows > len(payload)/stride {
		return nil
	}
	dstW, dstH := x3fFit(choice.columns, choice.rows, maxEdge)
	full := image.NewRGBA(image.Rect(0, 0, dstW, dstH))
	for y := 0; y < dstH; y++ {
		sy := y * choice.rows / dstH
		row := payload[sy*stride : sy*stride+packed]
		for x := 0; x < dstW; x++ {
			sx := x * choice.columns / dstW
			i := full.PixOffset(x, y)
			full.Pix[i] = row[sx*3]
			full.Pix[i+1] = row[sx*3+1]
			full.Pix[i+2] = row[sx*3+2]
			full.Pix[i+3] = 255
		}
	}
	return full
}

func x3fHuffman(payload []byte, choice x3fChoice, maxEdge int) image.Image {
	tableBytes := 256 * 4
	offsetBytes := choice.rows * 4
	if len(payload) <= tableBytes+offsetBytes {
		return nil
	}
	nodes, ok := x3fTree(payload[:tableBytes])
	if !ok {
		return nil
	}
	encoded := payload[tableBytes : len(payload)-offsetBytes]
	offsets := payload[len(payload)-offsetBytes:]
	dstW, dstH := x3fFit(choice.columns, choice.rows, maxEdge)
	full := image.NewRGBA(image.Rect(0, 0, dstW, dstH))
	row := make([]byte, choice.columns*3)
	for y := 0; y < dstH; y++ {
		sy := y * choice.rows / dstH
		rowAt := int(binary.LittleEndian.Uint32(offsets[sy*4:]))
		if !x3fDecodeRow(nodes, encoded, rowAt, choice.columns, row) {
			return nil
		}
		for x := 0; x < dstW; x++ {
			sx := x * choice.columns / dstW
			i := full.PixOffset(x, y)
			full.Pix[i] = row[sx*3]
			full.Pix[i+1] = row[sx*3+1]
			full.Pix[i+2] = row[sx*3+2]
			full.Pix[i+3] = 255
		}
	}
	return full
}

type x3fNode struct {
	zero, one int
	symbol    int
}

func x3fTree(table []byte) ([]x3fNode, bool) {
	nodes := []x3fNode{{zero: -1, one: -1, symbol: -1}}
	for symbol := 0; symbol < 256; symbol++ {
		entry := binary.LittleEndian.Uint32(table[symbol*4:])
		if entry == 0 {
			continue
		}
		length := int(entry >> 27)
		code := entry & 0x07ffffff
		if length < 1 || length > 27 {
			continue
		}
		node := 0
		for step := 0; step < length; step++ {
			if nodes[node].symbol >= 0 {
				return nil, false
			}
			bit := (code >> (length - 1 - step)) & 1
			next := nodes[node].zero
			if bit == 1 {
				next = nodes[node].one
			}
			if next < 0 {
				nodes = append(nodes, x3fNode{zero: -1, one: -1, symbol: -1})
				next = len(nodes) - 1
				if bit == 0 {
					nodes[node].zero = next
				} else {
					nodes[node].one = next
				}
			}
			node = next
		}
		if nodes[node].symbol >= 0 || nodes[node].zero >= 0 || nodes[node].one >= 0 {
			return nil, false
		}
		nodes[node].symbol = symbol
	}
	return nodes, true
}

func x3fDecodeRow(nodes []x3fNode, encoded []byte, at, columns int, row []byte) bool {
	if at < 0 || at > len(encoded) {
		return false
	}
	byteIndex := at
	bitIndex := 8
	var current byte
	nextBit := func() (int, bool) {
		if bitIndex == 8 {
			if byteIndex >= len(encoded) {
				return 0, false
			}
			current = encoded[byteIndex]
			byteIndex++
			bitIndex = 0
		}
		value := int((current >> (7 - bitIndex)) & 1)
		bitIndex++
		return value, true
	}
	var predictor [3]byte
	for column := 0; column < columns; column++ {
		for channel := 0; channel < 3; channel++ {
			node := 0
			var symbol int
			found := false
			for guard := 0; guard < 32; guard++ {
				if nodes[node].symbol >= 0 {
					symbol = nodes[node].symbol
					found = true
					break
				}
				bit, ok := nextBit()
				if !ok {
					return false
				}
				next := nodes[node].zero
				if bit == 1 {
					next = nodes[node].one
				}
				if next < 0 {
					return false
				}
				node = next
			}
			if !found {
				return false
			}
			predictor[channel] += byte(symbol)
			row[column*3+channel] = predictor[channel]
		}
	}
	return true
}

func x3fJPEGSize(file *os.File, offset int64, count int) (int, int) {
	if count < 4 || offset < 0 {
		return 0, 0
	}
	prefix := count
	if prefix > 256*1024 {
		prefix = 256 * 1024
	}
	buf := make([]byte, prefix)
	n, err := file.ReadAt(buf, offset)
	if n < 4 || (err != nil && err != io.EOF) {
		return 0, 0
	}
	buf = buf[:n]
	if buf[0] != 0xFF || buf[1] != 0xD8 {
		return 0, 0
	}
	index := 2
	for index+3 < len(buf) {
		if buf[index] != 0xFF {
			return 0, 0
		}
		index++
		for index < len(buf) && buf[index] == 0xFF {
			index++
		}
		if index >= len(buf) {
			return 0, 0
		}
		marker := buf[index]
		index++
		if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
			continue
		}
		if marker == 0xD9 || marker == 0xDA {
			return 0, 0
		}
		if index+1 >= len(buf) {
			return 0, 0
		}
		length := int(buf[index])<<8 | int(buf[index+1])
		if length < 2 {
			return 0, 0
		}
		sof := marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
		if sof {
			if index+6 >= len(buf) {
				return 0, 0
			}
			height := int(buf[index+3])<<8 | int(buf[index+4])
			width := int(buf[index+5])<<8 | int(buf[index+6])
			if !x3fLegal(width, height) {
				return 0, 0
			}
			return width, height
		}
		if index+length > len(buf) {
			return 0, 0
		}
		index += length
	}
	return 0, 0
}

func x3fRead(file *os.File, offset int64, count int) []byte {
	if count <= 0 || count > x3fReadBudget || offset < 0 {
		return nil
	}
	buf := make([]byte, count)
	n, err := file.ReadAt(buf, offset)
	if n != count || (err != nil && err != io.EOF) {
		return nil
	}
	return buf
}
