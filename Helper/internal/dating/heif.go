package dating

import (
	"encoding/binary"
	"io"
	"os"
)

const heifMetaCap = 8 << 20
const heifExifCap = 1 << 20

// heifExif returns the TIFF header inside a HEIC or HEIF Exif item.
// It reads the item location and that extent. It does not decode the picture.
func heifExif(file *os.File) ([]byte, bool) {
	info, err := file.Stat()
	if err != nil || info.Size() < 16 || !heifBrand(file) {
		return nil, false
	}
	metaOff, metaSize, ok := topBox(file, info.Size(), "meta")
	if !ok || metaSize < 8 || metaSize > heifMetaCap {
		return nil, false
	}
	meta := make([]byte, metaSize)
	if _, err := file.ReadAt(meta, metaOff); err != nil && err != io.EOF {
		return nil, false
	}
	if len(meta) < 8 {
		return nil, false
	}
	body := meta[4:]
	iinf := childPayload(body, "iinf")
	iloc := childPayload(body, "iloc")
	if iinf == nil || iloc == nil {
		return nil, false
	}
	ids := exifItemIDs(iinf)
	if len(ids) == 0 {
		return nil, false
	}
	ext, ok := ilocExtent(iloc, ids[0])
	if !ok || ext.length <= 4 {
		return nil, false
	}
	length := ext.length
	if length > heifExifCap {
		length = heifExifCap
	}
	var payload []byte
	switch ext.method {
	case 0:
		payload = readSpan(file, ext.offset, length)
	case 1:
		idatOff, _, found := topBox(file, info.Size(), "idat")
		if !found {
			return nil, false
		}
		payload = readSpan(file, idatOff+ext.offset, length)
	default:
		return nil, false
	}
	if len(payload) < 8 {
		return nil, false
	}
	shift := int(binary.BigEndian.Uint32(payload[:4]))
	if shift < 0 || shift > len(payload)-8 || 4+shift > len(payload) {
		return nil, false
	}
	tiff := payload[4+shift:]
	if len(tiff) < 8 {
		return nil, false
	}
	return tiff, true
}

func heifBrand(file *os.File) bool {
	var hdr [12]byte
	if _, err := file.ReadAt(hdr[:], 0); err != nil {
		return false
	}
	if string(hdr[4:8]) != "ftyp" {
		return false
	}
	switch string(hdr[8:12]) {
	case "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1":
		return true
	default:
		return false
	}
}

func topBox(file *os.File, size int64, want string) (int64, int64, bool) {
	var off int64
	for off+8 <= size {
		var hdr [16]byte
		if _, err := file.ReadAt(hdr[:8], off); err != nil {
			return 0, 0, false
		}
		boxSize := int64(binary.BigEndian.Uint32(hdr[0:4]))
		typ := string(hdr[4:8])
		header := int64(8)
		if boxSize == 1 {
			if off+16 > size {
				return 0, 0, false
			}
			if _, err := file.ReadAt(hdr[8:], off+8); err != nil {
				return 0, 0, false
			}
			boxSize = int64(binary.BigEndian.Uint64(hdr[8:16]))
			header = 16
		}
		if boxSize == 0 {
			boxSize = size - off
		}
		if boxSize < header || off > size-boxSize {
			return 0, 0, false
		}
		if typ == want {
			return off + header, boxSize - header, true
		}
		off += boxSize
	}
	return 0, 0, false
}

func childPayload(buf []byte, want string) []byte {
	for off := 0; off+8 <= len(buf); {
		size := int(binary.BigEndian.Uint32(buf[off : off+4]))
		typ := string(buf[off+4 : off+8])
		header := 8
		if size == 1 {
			if off+16 > len(buf) {
				return nil
			}
			size = int(binary.BigEndian.Uint64(buf[off+8 : off+16]))
			header = 16
		}
		if size < header || off+size > len(buf) {
			return nil
		}
		if typ == want {
			return buf[off+header : off+size]
		}
		off += size
	}
	return nil
}

func exifItemIDs(payload []byte) []uint32 {
	if len(payload) < 6 {
		return nil
	}
	ver := payload[0]
	var pos int
	var count int
	if ver == 0 {
		count = int(binary.BigEndian.Uint16(payload[4:6]))
		pos = 6
	} else {
		if len(payload) < 8 {
			return nil
		}
		count = int(binary.BigEndian.Uint32(payload[4:8]))
		pos = 8
	}
	if count <= 0 || count > 4096 {
		return nil
	}
	rest := payload[pos:]
	var ids []uint32
	for off := 0; off+8 <= len(rest) && len(ids) < count; {
		size := int(binary.BigEndian.Uint32(rest[off : off+4]))
		typ := string(rest[off+4 : off+8])
		header := 8
		if size == 1 {
			if off+16 > len(rest) {
				break
			}
			size = int(binary.BigEndian.Uint64(rest[off+8 : off+16]))
			header = 16
		}
		if size < header || off+size > len(rest) {
			break
		}
		if typ == "infe" {
			if id, ok := infeExifID(rest[off+header : off+size]); ok {
				ids = append(ids, id)
			}
		}
		off += size
	}
	return ids
}

func infeExifID(payload []byte) (uint32, bool) {
	if len(payload) < 12 {
		return 0, false
	}
	ver := payload[0]
	body := payload[4:]
	switch ver {
	case 2:
		if len(body) < 8 {
			return 0, false
		}
		if string(body[4:8]) != "Exif" {
			return 0, false
		}
		return uint32(binary.BigEndian.Uint16(body[0:2])), true
	case 3:
		if len(body) < 10 {
			return 0, false
		}
		if string(body[6:10]) != "Exif" {
			return 0, false
		}
		return binary.BigEndian.Uint32(body[0:4]), true
	default:
		return 0, false
	}
}

type heifExtent struct {
	offset int64
	length int64
	method int
}

func ilocExtent(payload []byte, itemID uint32) (heifExtent, bool) {
	if len(payload) < 8 {
		return heifExtent{}, false
	}
	ver := int(payload[0])
	sizes := binary.BigEndian.Uint16(payload[4:6])
	offsetSize := int((sizes >> 12) & 0xF)
	lengthSize := int((sizes >> 8) & 0xF)
	baseSize := int((sizes >> 4) & 0xF)
	indexSize := 0
	if ver > 0 {
		indexSize = int(sizes & 0xF)
	}
	pos := 6
	var count int
	if ver < 2 {
		if pos+2 > len(payload) {
			return heifExtent{}, false
		}
		count = int(binary.BigEndian.Uint16(payload[pos : pos+2]))
		pos += 2
	} else {
		if pos+4 > len(payload) {
			return heifExtent{}, false
		}
		count = int(binary.BigEndian.Uint32(payload[pos : pos+4]))
		pos += 4
	}
	if count <= 0 || count > 4096 {
		return heifExtent{}, false
	}
	for i := 0; i < count; i++ {
		var id uint32
		if ver < 2 {
			if pos+2 > len(payload) {
				return heifExtent{}, false
			}
			id = uint32(binary.BigEndian.Uint16(payload[pos : pos+2]))
			pos += 2
		} else {
			if pos+4 > len(payload) {
				return heifExtent{}, false
			}
			id = binary.BigEndian.Uint32(payload[pos : pos+4])
			pos += 4
		}
		method := 0
		if ver >= 1 {
			if pos+2 > len(payload) {
				return heifExtent{}, false
			}
			method = int(binary.BigEndian.Uint16(payload[pos:pos+2]) & 0xF)
			pos += 2
		}
		if pos+2 > len(payload) {
			return heifExtent{}, false
		}
		pos += 2
		base, ok := takeFixed(payload, &pos, baseSize)
		if !ok {
			return heifExtent{}, false
		}
		if pos+2 > len(payload) {
			return heifExtent{}, false
		}
		extents := int(binary.BigEndian.Uint16(payload[pos : pos+2]))
		pos += 2
		if extents < 0 || extents > 64 {
			return heifExtent{}, false
		}
		var first heifExtent
		have := false
		for j := 0; j < extents; j++ {
			if indexSize > 0 {
				if _, ok := takeFixed(payload, &pos, indexSize); !ok {
					return heifExtent{}, false
				}
			}
			off, ok1 := takeFixed(payload, &pos, offsetSize)
			length, ok2 := takeFixed(payload, &pos, lengthSize)
			if !ok1 || !ok2 {
				return heifExtent{}, false
			}
			if !have {
				first = heifExtent{offset: base + off, length: length, method: method}
				have = true
			}
		}
		if id == itemID && have {
			return first, true
		}
	}
	return heifExtent{}, false
}

func takeFixed(buf []byte, pos *int, size int) (int64, bool) {
	if size == 0 {
		return 0, true
	}
	if size != 4 && size != 8 {
		return 0, false
	}
	if *pos+size > len(buf) {
		return 0, false
	}
	var value int64
	if size == 4 {
		value = int64(binary.BigEndian.Uint32(buf[*pos : *pos+4]))
	} else {
		value = int64(binary.BigEndian.Uint64(buf[*pos : *pos+8]))
	}
	*pos += size
	return value, true
}

func readSpan(file *os.File, offset, length int64) []byte {
	if offset < 0 || length <= 0 || length > heifExifCap {
		return nil
	}
	buf := make([]byte, length)
	n, err := file.ReadAt(buf, offset)
	if n < 8 || (err != nil && err != io.EOF) {
		return nil
	}
	return buf[:n]
}
