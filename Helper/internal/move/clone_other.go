//go:build !linux

package move

import (
	"errors"
	"os"
)

func tryClone(dst, src *os.File) error {
	return errors.New("reflink")
}
