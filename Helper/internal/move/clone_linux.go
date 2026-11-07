//go:build linux

package move

import (
	"os"

	"golang.org/x/sys/unix"
)

func tryClone(dst, src *os.File) error {
	return unix.IoctlFileClone(int(dst.Fd()), int(src.Fd()))
}
