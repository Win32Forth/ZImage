package httpapi

import (
	"fmt"
	"os"
	"path/filepath"
)

const defaultLogBytes int64 = 10 << 20

// AppendLog writes one line and rotates at max bytes, keeping five older files.
// The caller must not put a bearer token or a pixel buffer in the line.
func AppendLog(path, line string, max int64) error {
	if path == "" {
		return nil
	}
	if max <= 0 {
		max = defaultLogBytes
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	if info, err := os.Stat(path); err == nil && info.Size()+int64(len(line)) > max {
		if err := rotateLog(path); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(line)
	return err
}

func rotateLog(path string) error {
	_ = os.Remove(path + ".5")
	for i := 4; i >= 1; i-- {
		_ = os.Rename(fmt.Sprintf("%s.%d", path, i), fmt.Sprintf("%s.%d", path, i+1))
	}
	return os.Rename(path, path+".1")
}
