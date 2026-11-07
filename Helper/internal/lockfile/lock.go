// Package lockfile holds the helper's exclusive flock.
// A second start finds the lock held and exits.
package lockfile

import (
	"errors"
	"os"
	"syscall"
)

// ErrHeld is returned when another helper process already holds the lock.
var ErrHeld = errors.New("helper is already running")

// Lock is an exclusive flock on helper.lock.
type Lock struct {
	file *os.File
}

// Acquire creates path if needed and takes a non-blocking exclusive flock.
func Acquire(path string) (*Lock, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err != nil {
		_ = f.Close()
		return nil, ErrHeld
	}
	return &Lock{file: f}, nil
}

// Release drops the flock and closes the file. The lock file stays on disk.
func (l *Lock) Release() error {
	if l == nil || l.file == nil {
		return nil
	}
	err := syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	closeErr := l.file.Close()
	l.file = nil
	if err != nil {
		return err
	}
	return closeErr
}
