package dating

import (
	"encoding/binary"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

// Facts is header EXIF. The pixel bitmap is not decoded.
// Video is the container creation time. The picture is not decoded.
type Facts struct {
	Original  *Stamp
	Digitized *Stamp
	DateTime  *Stamp
	Video     *Stamp
	Lat       *float64
	Lon       *float64
}

// ReadFacts reads DateTime tags and GPS from a JPEG APP1 segment, a TIFF header,
// or the Exif item in a HEIC or HEIF container. The picture is not decoded.
func ReadFacts(path string) (Facts, error) {
	file, err := os.Open(path)
	if err != nil {
		return Facts{}, err
	}
	defer file.Close()
	var magic [4]byte
	n, err := io.ReadFull(file, magic[:])
	if err != nil && n < 2 {
		return Facts{}, nil
	}
	if magic[0] == 0xFF && magic[1] == 0xD8 {
		payload, err := jpegExif(file)
		if err != nil || len(payload) < 8 {
			return Facts{}, nil
		}
		return parseTIFF(payload), nil
	}
	if (magic[0] == 'I' && magic[1] == 'I') || (magic[0] == 'M' && magic[1] == 'M') {
		info, err := file.Stat()
		if err != nil {
			return Facts{}, nil
		}
		limit := info.Size()
		if limit > 1<<20 {
			limit = 1 << 20
		}
		buf := make([]byte, limit)
		if _, err := file.ReadAt(buf, 0); err != nil && err != io.EOF {
			return Facts{}, nil
		}
		return parseTIFF(buf), nil
	}
	if tiff, ok := heifExif(file); ok {
		return parseTIFF(tiff), nil
	}
	return Facts{}, nil
}

func jpegExif(file *os.File) ([]byte, error) {
	if _, err := file.Seek(2, io.SeekStart); err != nil {
		return nil, err
	}
	for {
		var marker [2]byte
		if _, err := io.ReadFull(file, marker[:]); err != nil {
			return nil, err
		}
		if marker[0] != 0xFF {
			return nil, nil
		}
		for marker[1] == 0xFF {
			if _, err := io.ReadFull(file, marker[1:]); err != nil {
				return nil, err
			}
		}
		if marker[1] == 0xD9 || marker[1] == 0xDA {
			return nil, nil
		}
		var lengthBuf [2]byte
		if _, err := io.ReadFull(file, lengthBuf[:]); err != nil {
			return nil, err
		}
		length := int(lengthBuf[0])<<8 | int(lengthBuf[1])
		if length < 2 {
			return nil, nil
		}
		payloadLen := length - 2
		if marker[1] != 0xE1 {
			if _, err := file.Seek(int64(payloadLen), io.SeekCurrent); err != nil {
				return nil, err
			}
			continue
		}
		want := payloadLen
		if want > 512<<10 {
			want = 512 << 10
		}
		payload := make([]byte, want)
		if _, err := io.ReadFull(file, payload); err != nil {
			return nil, err
		}
		if len(payload) >= 6 && string(payload[:6]) == "Exif\x00\x00" {
			return payload[6:], nil
		}
		if rest := payloadLen - want; rest > 0 {
			if _, err := file.Seek(int64(rest), io.SeekCurrent); err != nil {
				return nil, err
			}
		}
	}
}

func parseTIFF(data []byte) Facts {
	if len(data) < 8 {
		return Facts{}
	}
	var order binary.ByteOrder
	switch string(data[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return Facts{}
	}
	if order.Uint16(data[2:4]) != 42 {
		return Facts{}
	}
	var facts Facts
	var lat, lon float64
	var latRef, lonRef string
	var haveLat, haveLon bool
	var walk func(offset, depth int)
	walk = func(offset, depth int) {
		if depth > 6 || offset < 0 || offset+2 > len(data) {
			return
		}
		count := int(order.Uint16(data[offset : offset+2]))
		if count <= 0 || count > 512 {
			return
		}
		cursor := offset + 2
		var next int
		for i := 0; i < count; i++ {
			if cursor+12 > len(data) {
				return
			}
			entry := data[cursor : cursor+12]
			cursor += 12
			tag := order.Uint16(entry[0:2])
			typ := order.Uint16(entry[2:4])
			n := order.Uint32(entry[4:8])
			text := asciiValue(data, order, entry, typ, n)
			switch tag {
			case 0x0132:
				if stamp, ok := parseEXIFTime(text, ""); ok {
					facts.DateTime = &stamp
				}
			case 0x9003:
				if stamp, ok := parseEXIFTime(text, ""); ok {
					facts.Original = &stamp
				}
			case 0x9004:
				if stamp, ok := parseEXIFTime(text, ""); ok {
					facts.Digitized = &stamp
				}
			case 0x9011:
				if facts.Original != nil {
					if stamp, ok := parseEXIFTime(facts.Original.Time.Format("2006:01:02 15:04:05"), text); ok {
						facts.Original = &stamp
					}
				}
			case 0x0001:
				latRef = text
			case 0x0003:
				lonRef = text
			case 0x0002:
				if v, ok := rationals(data, order, entry, n); ok && len(v) >= 3 {
					lat = v[0] + v[1]/60 + v[2]/3600
					haveLat = true
				}
			case 0x0004:
				if v, ok := rationals(data, order, entry, n); ok && len(v) >= 3 {
					lon = v[0] + v[1]/60 + v[2]/3600
					haveLon = true
				}
			case 0x8769, 0x8825:
				if typ == 4 && n >= 1 {
					walk(int(order.Uint32(entry[8:12])), depth+1)
				}
			}
		}
		if cursor+4 <= len(data) {
			next = int(order.Uint32(data[cursor : cursor+4]))
		}
		if next > 0 {
			walk(next, depth+1)
		}
	}
	walk(int(order.Uint32(data[4:8])), 0)
	if haveLat {
		if strings.HasPrefix(strings.ToUpper(latRef), "S") {
			lat = -lat
		}
		facts.Lat = &lat
	}
	if haveLon {
		if strings.HasPrefix(strings.ToUpper(lonRef), "W") {
			lon = -lon
		}
		facts.Lon = &lon
	}
	return facts
}

func asciiValue(data []byte, order binary.ByteOrder, entry []byte, typ uint16, count uint32) string {
	if typ != 2 || count == 0 {
		return ""
	}
	size := int(count)
	var raw []byte
	if size <= 4 {
		raw = entry[8 : 8+size]
	} else {
		off := int(order.Uint32(entry[8:12]))
		if off < 0 || off+size > len(data) {
			return ""
		}
		raw = data[off : off+size]
	}
	return strings.TrimRight(string(raw), "\x00 ")
}

func rationals(data []byte, order binary.ByteOrder, entry []byte, count uint32) ([]float64, bool) {
	if count == 0 || count > 6 {
		return nil, false
	}
	off := int(order.Uint32(entry[8:12]))
	need := int(count) * 8
	if off < 0 || off+need > len(data) {
		return nil, false
	}
	out := make([]float64, count)
	for i := 0; i < int(count); i++ {
		num := order.Uint32(data[off+i*8 : off+i*8+4])
		den := order.Uint32(data[off+i*8+4 : off+i*8+8])
		if den == 0 {
			out[i] = 0
			continue
		}
		out[i] = float64(num) / float64(den)
	}
	return out, true
}

func parseEXIFTime(text, offset string) (Stamp, bool) {
	text = strings.TrimSpace(text)
	if len(text) < 19 {
		return Stamp{}, false
	}
	wall, err := time.Parse("2006:01:02 15:04:05", text[:19])
	if err != nil {
		return Stamp{}, false
	}
	offset = strings.TrimSpace(strings.TrimRight(offset, "\x00"))
	if len(offset) >= 6 && (offset[0] == '+' || offset[0] == '-') {
		hours, errH := strconv.Atoi(offset[1:3])
		mins, errM := strconv.Atoi(offset[4:6])
		if errH == nil && errM == nil {
			sign := 1
			if offset[0] == '-' {
				sign = -1
			}
			loc := time.FixedZone("exif", sign*(hours*3600+mins*60))
			local := time.Date(wall.Year(), wall.Month(), wall.Day(), wall.Hour(), wall.Minute(), wall.Second(), 0, loc)
			return Stamp{Time: local, OffsetKnown: true}, true
		}
	}
	return Stamp{Time: time.Date(wall.Year(), wall.Month(), wall.Day(), wall.Hour(), wall.Minute(), wall.Second(), 0, time.UTC)}, true
}
