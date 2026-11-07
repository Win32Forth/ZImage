package move

import (
	"bytes"
	"errors"
	"io"
	"os"

	"lukechampine.com/blake3"
)

const copyBuffer = 1 << 20

func hashFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	sum := blake3.New(32, nil)
	if _, err := io.CopyBuffer(sum, file, make([]byte, copyBuffer)); err != nil {
		return nil, err
	}
	return sum.Sum(nil), nil
}

// streamCopy writes src to dst. A same-volume clone is attempted first.
// The destination is then read back and its BLAKE3 must match the source.
func streamCopy(dstPath, srcPath string) error {
	src, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer src.Close()
	dst, err := os.OpenFile(dstPath, os.O_CREATE|os.O_TRUNC|os.O_RDWR, 0o644)
	if err != nil {
		return err
	}
	defer dst.Close()
	if err := tryClone(dst, src); err != nil {
		if _, err := src.Seek(0, io.SeekStart); err != nil {
			return err
		}
		if err := dst.Truncate(0); err != nil {
			return err
		}
		buf := make([]byte, copyBuffer)
		for {
			n, readErr := src.Read(buf)
			if n > 0 {
				if _, err := dst.Write(buf[:n]); err != nil {
					return err
				}
			}
			if readErr == io.EOF {
				break
			}
			if readErr != nil {
				return readErr
			}
		}
	}
	if err := dst.Sync(); err != nil {
		return err
	}
	got, err := hashFile(dstPath)
	if err != nil {
		return err
	}
	want, err := hashFile(srcPath)
	if err != nil {
		return err
	}
	if !bytes.Equal(got, want) {
		return errors.New("hash_mismatch")
	}
	return nil
}

func fsyncDir(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func sameEdges(a, b string) (bool, error) {
	af, err := os.Open(a)
	if err != nil {
		return false, err
	}
	defer af.Close()
	bf, err := os.Open(b)
	if err != nil {
		return false, err
	}
	defer bf.Close()
	ai, err := af.Stat()
	if err != nil {
		return false, err
	}
	bi, err := bf.Stat()
	if err != nil {
		return false, err
	}
	if ai.Size() != bi.Size() {
		return false, nil
	}
	n := ai.Size()
	if n > 65536 {
		n = 65536
	}
	if n == 0 {
		return true, nil
	}
	left := make([]byte, n)
	right := make([]byte, n)
	if _, err := io.ReadFull(af, left); err != nil {
		return false, err
	}
	if _, err := io.ReadFull(bf, right); err != nil {
		return false, err
	}
	if !bytes.Equal(left, right) {
		return false, nil
	}
	if ai.Size() <= 65536 {
		return true, nil
	}
	if _, err := af.Seek(-65536, io.SeekEnd); err != nil {
		return false, err
	}
	if _, err := bf.Seek(-65536, io.SeekEnd); err != nil {
		return false, err
	}
	if _, err := io.ReadFull(af, left); err != nil {
		return false, err
	}
	if _, err := io.ReadFull(bf, right); err != nil {
		return false, err
	}
	return bytes.Equal(left, right), nil
}
