package events

import (
	"errors"
	"strings"
	"unicode/utf8"

	"zimage/helper/internal/db"
)

// ErrNotFound means the event uid is not in the catalog.
var ErrNotFound = errors.New("event not found")

// ErrName means the typed name cannot be stored.
var ErrName = errors.New("event name")

// Rename sets the event name and name_source = user.
// It does not move a photo and it does not change folder_rel.
// A later plan keeps this name.
func Rename(catalog *db.Catalog, uid, name string) error {
	name = strings.TrimSpace(name)
	if uid == "" || name == "" || utf8.RuneCountInString(name) > 80 || strings.ContainsAny(name, "\r\n\x00") {
		return ErrName
	}
	res, err := catalog.Write.Exec(
		`UPDATE events SET name = ?, name_source = 'user', slug = ? WHERE uid = ?`,
		name, Slug(name), uid)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
