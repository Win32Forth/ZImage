package config

import (
	"os"
	"path/filepath"
)

// PhotosWritable reports whether root/Photos exists and this process can create a file there.
// A failed check still lets the process serve /v1/health. It does not create Photos.
func PhotosWritable(root string) bool {
	photos := filepath.Join(root, "Photos")
	info, err := os.Stat(photos)
	if err != nil || !info.IsDir() {
		return false
	}
	f, err := os.CreateTemp(photos, ".zimage-writecheck-*")
	if err != nil {
		return false
	}
	name := f.Name()
	_ = f.Close()
	return os.Remove(name) == nil
}
