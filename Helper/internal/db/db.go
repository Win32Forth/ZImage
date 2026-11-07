// Package db opens the catalog. The Mac never opens this file.
// job_state is keyed by job_kind. There is no CHECK (id = 1).
// Later PRs must not collapse reorg and trim onto one row.
package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	_ "modernc.org/sqlite"
)

// SchemaVersion is the catalog user_version. It is not the .zimg schemaVersion.
const SchemaVersion = 1

// Catalog is one write connection, one read connection, and one watch connection.
// Read stays at one connection so a nested query on it waits instead of hiding the bug.
// Watch is a separate read connection. Status uses it while a plan count holds Read.
type Catalog struct {
	Write *sql.DB
	Read  *sql.DB
	Watch *sql.DB
	Path  string
}

// Open creates the database if needed, sets the SQLite pragmas, and migrates forward.
func Open(path string) (*Catalog, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, err
	}
	dsn := "file:" + path + "?mode=rwc"
	write, err := openConn(dsn)
	if err != nil {
		return nil, err
	}
	if err := migrate(write); err != nil {
		_ = write.Close()
		return nil, err
	}
	read, err := openConn(dsn)
	if err != nil {
		_ = write.Close()
		return nil, err
	}
	watch, err := openConn(dsn)
	if err != nil {
		_ = read.Close()
		_ = write.Close()
		return nil, err
	}
	return &Catalog{Write: write, Read: read, Watch: watch, Path: path}, nil
}

func openConn(dsn string) (*sql.DB, error) {
	conn, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	conn.SetMaxOpenConns(1)
	if err := tune(conn); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

// Close closes the watch, read, and write connections.
func (c *Catalog) Close() error {
	if c == nil {
		return nil
	}
	var err error
	if c.Watch != nil {
		err = c.Watch.Close()
	}
	if c.Read != nil {
		if e := c.Read.Close(); err == nil {
			err = e
		}
	}
	if c.Write != nil {
		if e := c.Write.Close(); err == nil {
			err = e
		}
	}
	return err
}

func tune(db *sql.DB) error {
	if _, err := db.Exec(`PRAGMA busy_timeout = 5000`); err != nil {
		return err
	}
	if _, err := db.Exec(`PRAGMA foreign_keys = ON`); err != nil {
		return err
	}
	if _, err := db.Exec(`PRAGMA cache_size = -8000`); err != nil {
		return err
	}
	var mode string
	if err := db.QueryRow(`PRAGMA journal_mode = WAL`).Scan(&mode); err != nil {
		return err
	}
	if mode != "wal" {
		return fmt.Errorf("journal_mode %s", mode)
	}
	return nil
}

func migrate(db *sql.DB) error {
	var version int
	if err := db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil {
		return err
	}
	if version == SchemaVersion {
		return nil
	}
	if version > SchemaVersion {
		return fmt.Errorf("catalog schema %d is newer than this helper", version)
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	if err := execScript(tx, schemaSQL); err != nil {
		_ = tx.Rollback()
		return err
	}
	if _, err := tx.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, SchemaVersion)); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

func execScript(tx *sql.Tx, script string) error {
	for _, stmt := range strings.Split(script, ";") {
		stmt = strings.TrimSpace(stmt)
		if stmt == "" {
			continue
		}
		if _, err := tx.Exec(stmt); err != nil {
			return err
		}
	}
	return nil
}

// schemaSQL is the full data model. Column order matches the design.
// job_kind is the primary key of job_state. Do not add CHECK (id = 1).
const schemaSQL = `
CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  uid TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  name_source TEXT NOT NULL,
  start_time TEXT,
  end_time TEXT,
  slug TEXT NOT NULL,
  folder_rel TEXT,
  gps_lat REAL,
  gps_lon REAL
);

CREATE TABLE derivative_groups (
  id INTEGER PRIMARY KEY,
  uid TEXT NOT NULL UNIQUE,
  keeper_asset_id INTEGER,
  eligible INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE assets (
  id INTEGER PRIMARY KEY,
  uid TEXT NOT NULL UNIQUE,
  rel_path TEXT NOT NULL UNIQUE,
  byte_size INTEGER NOT NULL,
  mtime_ns INTEGER,
  ext TEXT NOT NULL,
  media_class TEXT NOT NULL,
  reorg_policy TEXT NOT NULL,
  width INTEGER,
  height INTEGER,
  blake3 BLOB,
  fast_fp BLOB,
  dhash INTEGER,
  dhash_b0 INTEGER,
  dhash_b1 INTEGER,
  dhash_b2 INTEGER,
  dhash_b3 INTEGER,
  dhash_b4 INTEGER,
  dhash_b5 INTEGER,
  capture_time TEXT,
  capture_offset_known INTEGER NOT NULL DEFAULT 0,
  capture_source TEXT,
  capture_confidence REAL NOT NULL DEFAULT 0,
  candidate_capture_time TEXT,
  event_id INTEGER REFERENCES events(id),
  derivative_group_id INTEGER REFERENCES derivative_groups(id),
  is_keeper INTEGER NOT NULL DEFAULT 0,
  native_pixels INTEGER,
  detail_score REAL,
  detail_source TEXT,
  placement TEXT NOT NULL DEFAULT 'active',
  duplicate_reason TEXT,
  pinned INTEGER NOT NULL DEFAULT 0,
  phase TEXT NOT NULL,
  missing INTEGER NOT NULL DEFAULT 0,
  identity_ambiguous INTEGER NOT NULL DEFAULT 0,
  decode_support TEXT,
  thumb_rel TEXT,
  edit_rel TEXT,
  discovered_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE journal (
  id INTEGER PRIMARY KEY,
  asset_id INTEGER NOT NULL REFERENCES assets(id),
  job_kind TEXT NOT NULL,
  state TEXT NOT NULL,
  src_rel TEXT NOT NULL,
  dest_rel TEXT NOT NULL,
  blake3 BLOB,
  byte_size INTEGER NOT NULL,
  scratch_rel TEXT,
  backup_rel TEXT,
  error TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE job_state (
  job_kind TEXT PRIMARY KEY,
  run_state TEXT NOT NULL,
  pause_requested INTEGER NOT NULL,
  safe_to_reboot INTEGER NOT NULL,
  phase TEXT NOT NULL
);

CREATE TABLE cache_objects (
  rel_path TEXT PRIMARY KEY,
  class TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  asset_id INTEGER,
  last_access TEXT NOT NULL
);

CREATE INDEX blake3 ON assets(blake3);
CREATE INDEX byte_size_fast_fp ON assets(byte_size, fast_fp);
CREATE INDEX phase ON assets(phase);
CREATE INDEX event_id ON assets(event_id);
CREATE INDEX capture_time ON assets(capture_time);
CREATE INDEX missing ON assets(missing);
CREATE INDEX dhash ON assets(dhash);
CREATE INDEX dhash_b0 ON assets(dhash_b0);
CREATE INDEX dhash_b1 ON assets(dhash_b1);
CREATE INDEX dhash_b2 ON assets(dhash_b2);
CREATE INDEX dhash_b3 ON assets(dhash_b3);
CREATE INDEX dhash_b4 ON assets(dhash_b4);
CREATE INDEX dhash_b5 ON assets(dhash_b5);
CREATE INDEX derivative_group_id ON assets(derivative_group_id);
CREATE INDEX placement ON assets(placement);
CREATE INDEX detail_score ON assets(detail_score);

INSERT INTO job_state (job_kind, run_state, pause_requested, safe_to_reboot, phase)
VALUES ('reorg', 'idle', 0, 1, 'idle');
INSERT INTO job_state (job_kind, run_state, pause_requested, safe_to_reboot, phase)
VALUES ('trim', 'idle', 0, 1, 'idle');
`
