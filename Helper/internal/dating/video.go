package dating

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"
	"time"
)

const movieWindow = 1 << 20

var quickTimeEpoch = time.Date(1904, 1, 1, 0, 0, 0, 0, time.UTC)

// readMovieCreation reads an ISO BMFF movie-header creation time.
// It looks at the first 1 MB and the last 1 MB. It does not decode frames.
func readMovieCreation(path string) (time.Time, bool) {
	file, err := os.Open(path)
	if err != nil {
		return time.Time{}, false
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() < 16 {
		return time.Time{}, false
	}
	headLen := info.Size()
	if headLen > movieWindow {
		headLen = movieWindow
	}
	head := make([]byte, headLen)
	if _, err := file.ReadAt(head, 0); err != nil && err != io.EOF {
		return time.Time{}, false
	}
	if when, ok := creationIn(head); ok {
		return when, true
	}
	if info.Size() <= movieWindow {
		return time.Time{}, false
	}
	tail := make([]byte, movieWindow)
	if _, err := file.ReadAt(tail, info.Size()-movieWindow); err != nil && err != io.EOF {
		return time.Time{}, false
	}
	return creationIn(tail)
}

func creationIn(buf []byte) (time.Time, bool) {
	if when, ok := walkBoxes(buf, 0); ok {
		return when, true
	}
	needle := []byte("mvhd")
	for i := 0; i+8 <= len(buf); {
		j := bytes.Index(buf[i:], needle)
		if j < 0 {
			return time.Time{}, false
		}
		i += j
		if when, ok := mvhdTime(buf[i+4:]); ok {
			return when, true
		}
		i += 4
	}
	return time.Time{}, false
}

func walkBoxes(buf []byte, depth int) (time.Time, bool) {
	if depth > 8 {
		return time.Time{}, false
	}
	for off := 0; off+8 <= len(buf); {
		size64 := uint64(binary.BigEndian.Uint32(buf[off : off+4]))
		typ := string(buf[off+4 : off+8])
		header := 8
		if size64 == 1 {
			if off+16 > len(buf) {
				break
			}
			size64 = binary.BigEndian.Uint64(buf[off+8 : off+16])
			header = 16
		}
		if size64 < uint64(header) || size64 > uint64(len(buf)-off) {
			if typ == "moov" {
				return walkBoxes(buf[off+header:], depth+1)
			}
			if typ == "mvhd" {
				return mvhdTime(buf[off+header:])
			}
			break
		}
		size := int(size64)
		payload := buf[off+header : off+size]
		if typ == "mvhd" {
			return mvhdTime(payload)
		}
		if typ == "moov" || typ == "trak" || typ == "mdia" {
			if when, ok := walkBoxes(payload, depth+1); ok {
				return when, true
			}
		}
		off += size
	}
	return time.Time{}, false
}

func mvhdTime(payload []byte) (time.Time, bool) {
	if len(payload) < 8 {
		return time.Time{}, false
	}
	var seconds uint64
	switch payload[0] {
	case 0:
		seconds = uint64(binary.BigEndian.Uint32(payload[4:8]))
	case 1:
		if len(payload) < 12 {
			return time.Time{}, false
		}
		seconds = binary.BigEndian.Uint64(payload[4:12])
	default:
		return time.Time{}, false
	}
	if seconds == 0 || seconds > 200*365*24*3600 {
		return time.Time{}, false
	}
	return quickTimeEpoch.Add(time.Duration(seconds) * time.Second).UTC(), true
}
