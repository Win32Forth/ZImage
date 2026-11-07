package httpapi

import (
	"os"
	"strconv"
	"strings"
)

const (
	rssShedBytes  int64 = 256 << 20
	rssBlockBytes int64 = 320 << 20
)

// readRSS reads /proc/self/statm. On macOS the file is absent and the second result is false.
func readRSS() (int64, bool) {
	b, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(b))
	if len(fields) < 2 {
		return 0, false
	}
	pages, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil {
		return 0, false
	}
	return pages * int64(os.Getpagesize()), true
}
