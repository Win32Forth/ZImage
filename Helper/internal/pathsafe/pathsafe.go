// Package pathsafe keeps helper paths inside the library root.
// A parameter is rejected when, after path.Clean, it is absolute, still
// contains "..", or a symlink resolves outside the root.
package pathsafe

import (
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// ErrRejected means the path leaves the library root or is not a relative path.
var ErrRejected = errors.New("path rejected")

// ErrDestination means a move target is inside the root but outside Photos and .zimage.
var ErrDestination = errors.New("move destination must stay under Photos or .zimage")

// Jail reports whether rel stays under root.
// Move destinations that pass Jail still need MoveDestination.
func Jail(root, rel string) error {
	if rel == "" || strings.Contains(rel, `\`) || strings.Contains(rel, "\x00") {
		return ErrRejected
	}
	if path.IsAbs(rel) || filepath.IsAbs(rel) {
		return ErrRejected
	}
	cleaned := path.Clean(rel)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") || strings.Contains(cleaned, "..") {
		return ErrRejected
	}
	root = filepath.Clean(root)
	if resolved, err := filepath.EvalSymlinks(root); err == nil {
		root = resolved
	}
	current := root
	for _, part := range strings.Split(cleaned, "/") {
		if part == "" || part == "." || part == ".." {
			return ErrRejected
		}
		next := filepath.Join(current, part)
		info, err := os.Lstat(next)
		if err != nil {
			if os.IsNotExist(err) {
				current = next
				continue
			}
			return ErrRejected
		}
		if info.Mode()&os.ModeSymlink != 0 {
			dest, err := filepath.EvalSymlinks(next)
			if err != nil || !inside(root, dest) {
				return ErrRejected
			}
			current = dest
			continue
		}
		current = next
	}
	if !inside(root, current) {
		return ErrRejected
	}
	return nil
}

// MoveDestination allows a jailed path under Photos or .zimage only.
// Scratch and backup stay under .zimage. Library files stay under Photos.
func MoveDestination(root, rel string) error {
	if err := Jail(root, rel); err != nil {
		return err
	}
	cleaned := path.Clean(rel)
	if cleaned == "Photos" || strings.HasPrefix(cleaned, "Photos/") || cleaned == ".zimage" || strings.HasPrefix(cleaned, ".zimage/") {
		return nil
	}
	return ErrDestination
}

func inside(root, full string) bool {
	root = filepath.Clean(root)
	full = filepath.Clean(full)
	if full == root {
		return true
	}
	sep := string(os.PathSeparator)
	return strings.HasPrefix(full, root+sep)
}
