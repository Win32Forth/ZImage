package pathsafe_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/pathsafe"
)

func TestJailRejectsDotDotAbsoluteAndEscapingSymlink(t *testing.T) {
	root := t.TempDir()
	photos := filepath.Join(root, "Photos")
	if err := os.Mkdir(photos, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(photos, "escape")); err != nil {
		t.Fatal(err)
	}

	cases := []string{
		"..",
		"../outside",
		"Photos/../../outside",
		"/etc/passwd",
		"Photos/escape",
		"Photos/escape/note.txt",
	}
	for _, rel := range cases {
		if err := pathsafe.Jail(root, rel); !errors.Is(err, pathsafe.ErrRejected) {
			t.Fatalf("%q err = %v", rel, err)
		}
	}
	if err := pathsafe.Jail(root, "Photos/a.jpg"); err != nil {
		t.Fatal(err)
	}
	inside := filepath.Join(photos, "keep")
	if err := os.Mkdir(inside, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(inside, filepath.Join(photos, "alias")); err != nil {
		t.Fatal(err)
	}
	if err := pathsafe.Jail(root, "Photos/alias"); err != nil {
		t.Fatal(err)
	}
}

func TestMoveDestinationStaysUnderPhotosOrZimage(t *testing.T) {
	root := t.TempDir()
	if err := pathsafe.MoveDestination(root, "Photos/1999/a.jpg"); err != nil {
		t.Fatal(err)
	}
	if err := pathsafe.MoveDestination(root, ".zimage/cache/scratch/1"); err != nil {
		t.Fatal(err)
	}
	if err := pathsafe.MoveDestination(root, "Audio/a.mp3"); !errors.Is(err, pathsafe.ErrDestination) {
		t.Fatalf("audio err = %v", err)
	}
	if err := pathsafe.MoveDestination(root, "../x"); !errors.Is(err, pathsafe.ErrRejected) {
		t.Fatalf("dotdot err = %v", err)
	}
}
