package relink

import (
	"io"
	"os"

	"lukechampine.com/blake3"
)

const (
	firstN = 1 << 20
	lastN  = 64 << 10
)

// FingerprintFile is BLAKE3 of the first 1 MB concatenated with the last 64 KB.
// A short file hashes those ranges with the overlap included twice.
func FingerprintFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	return fingerprint(file, info.Size())
}

func fingerprint(file io.ReadSeeker, size int64) ([]byte, error) {
	sum := blake3.New(32, nil)
	first := size
	if first > firstN {
		first = firstN
	}
	if err := copyExact(sum, file, first); err != nil {
		return nil, err
	}
	last := size
	if last > lastN {
		last = lastN
	}
	if _, err := file.Seek(size-last, io.SeekStart); err != nil {
		return nil, err
	}
	if err := copyExact(sum, file, last); err != nil {
		return nil, err
	}
	return sum.Sum(nil), nil
}

// HashFile is the full-file BLAKE3, 32 bytes, read in 1 MB chunks.
func HashFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	sum := blake3.New(32, nil)
	if _, err := io.CopyBuffer(sum, file, make([]byte, firstN)); err != nil {
		return nil, err
	}
	return sum.Sum(nil), nil
}

func copyExact(dst io.Writer, src io.Reader, n int64) error {
	if n == 0 {
		return nil
	}
	_, err := io.CopyN(dst, src, n)
	return err
}
