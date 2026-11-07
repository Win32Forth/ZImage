// Package cacheledger records thumbnail, embedding, and scratch bytes.
// Catalog rows, the journal, .zimg edits, and move-backup are not ledger
// objects and are not deleted from here.
package cacheledger

import (
	"database/sql"
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/pathsafe"
)

const (
	// DefaultOperating is the 200 GB target. Eviction runs until a new object fits under it.
	DefaultOperating int64 = 200_000_000_000
	// DefaultHard is the 1 TB cap. A single object that cannot fit under it is refused.
	DefaultHard int64 = 1_000_000_000_000
	scratchMax  int64 = 64 << 20
)

// ErrRefuse means the object does not fit under the hard cap, or scratch is over 64 MB.
var ErrRefuse = errors.New("cache_refuse")

// Limits overrides the production caps. Zero uses the production value.
type Limits struct {
	Operating int64
	Hard      int64
}

func (l Limits) operating() int64 {
	if l.Operating > 0 {
		return l.Operating
	}
	return DefaultOperating
}

func (l Limits) hard() int64 {
	if l.Hard > 0 {
		return l.Hard
	}
	return DefaultHard
}

// Put evicts until the new object fits, records the ledger row, then writes the bytes.
// The summed ledger stays at or under the hard cap. A refused write leaves prior bytes in place.
func Put(root string, catalog *db.Catalog, rel, class string, assetID int64, body []byte, limits Limits) error {
	rel = path.Clean(strings.TrimPrefix(rel, "/"))
	if !underCache(rel) || !knownClass(class) {
		return ErrRefuse
	}
	incoming := int64(len(body))
	if incoming > limits.hard() || (class == "scratch" && incoming > scratchMax) {
		return ErrRefuse
	}
	if err := pathsafe.Jail(root, rel); err != nil {
		return ErrRefuse
	}
	tx, err := catalog.Write.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	var existing int64
	if err := tx.QueryRow(`SELECT COALESCE(bytes, 0) FROM cache_objects WHERE rel_path = ?`, rel).Scan(&existing); err != nil && err != sql.ErrNoRows {
		return err
	}
	victims, err := evict(tx, rel, incoming, existing, limits)
	if err != nil {
		return err
	}
	var asset any
	if assetID > 0 {
		asset = assetID
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.Exec(`
		INSERT INTO cache_objects (rel_path, class, bytes, asset_id, last_access)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(rel_path) DO UPDATE SET
			class = excluded.class,
			bytes = excluded.bytes,
			asset_id = excluded.asset_id,
			last_access = excluded.last_access`,
		rel, class, incoming, asset, now); err != nil {
		return err
	}
	var total int64
	if err := tx.QueryRow(`SELECT COALESCE(SUM(bytes), 0) FROM cache_objects`).Scan(&total); err != nil {
		return err
	}
	if total > limits.hard() {
		return ErrRefuse
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	for _, victim := range victims {
		if underCache(victim) {
			_ = os.Remove(filepath.Join(root, filepath.FromSlash(victim)))
		}
	}
	abs := filepath.Join(root, filepath.FromSlash(rel))
	if err := writeSynced(abs, body); err != nil {
		_, _ = catalog.Write.Exec(`DELETE FROM cache_objects WHERE rel_path = ?`, rel)
		return err
	}
	return nil
}

func evict(tx *sql.Tx, replacing string, incoming, existing int64, limits Limits) ([]string, error) {
	var victims []string
	skipped := map[string]bool{}
	for {
		var total int64
		if err := tx.QueryRow(`SELECT COALESCE(SUM(bytes), 0) FROM cache_objects`).Scan(&total); err != nil {
			return nil, err
		}
		used := total - existing
		if used < 0 {
			used = 0
		}
		if used+incoming < limits.operating() {
			return victims, nil
		}
		victim, ok, err := nextVictim(tx, replacing, skipped)
		if err != nil {
			return nil, err
		}
		if !ok {
			if used+incoming > limits.hard() {
				return nil, ErrRefuse
			}
			return victims, nil
		}
		if !underCache(victim) {
			skipped[victim] = true
			continue
		}
		if _, err := tx.Exec(`DELETE FROM cache_objects WHERE rel_path = ?`, victim); err != nil {
			return nil, err
		}
		if victim == replacing {
			existing = 0
		}
		victims = append(victims, victim)
	}
}

func nextVictim(tx *sql.Tx, replacing string, skipped map[string]bool) (string, bool, error) {
	rows, err := tx.Query(`
		SELECT rel_path FROM cache_objects
		WHERE rel_path != ?
		ORDER BY CASE class
			WHEN 'scratch' THEN 0
			WHEN 'embedding' THEN 1
			WHEN 'thumbnail' THEN 2
			ELSE 3 END,
			last_access ASC, rel_path ASC`, replacing)
	if err != nil {
		return "", false, err
	}
	defer rows.Close()
	for rows.Next() {
		var rel string
		if err := rows.Scan(&rel); err != nil {
			return "", false, err
		}
		if skipped[rel] {
			continue
		}
		return rel, true, nil
	}
	return "", false, rows.Err()
}

func writeSynced(abs string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(abs), 0o750); err != nil {
		return err
	}
	if err := os.WriteFile(abs, body, 0o644); err != nil {
		return err
	}
	file, err := os.Open(abs)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}

func knownClass(class string) bool {
	switch class {
	case "thumbnail", "embedding", "scratch":
		return true
	default:
		return false
	}
}

func underCache(rel string) bool {
	rel = path.Clean(strings.TrimPrefix(rel, "/"))
	return strings.HasPrefix(rel, ".zimage/cache/")
}
