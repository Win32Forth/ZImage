package lockfile_test

import (
	"errors"
	"path/filepath"
	"testing"

	"zimage/helper/internal/lockfile"
)

func TestSecondAcquireFailsWhileHeld(t *testing.T) {
	path := filepath.Join(t.TempDir(), "helper.lock")
	first, err := lockfile.Acquire(path)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Release()

	_, err = lockfile.Acquire(path)
	if !errors.Is(err, lockfile.ErrHeld) {
		t.Fatalf("second start err = %v", err)
	}
	if err := first.Release(); err != nil {
		t.Fatal(err)
	}
	second, err := lockfile.Acquire(path)
	if err != nil {
		t.Fatal(err)
	}
	second.Release()
}
