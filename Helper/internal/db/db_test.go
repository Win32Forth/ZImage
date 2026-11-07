package db

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestSchemaJobStateAndPragmas(t *testing.T) {
	if strings.Contains(schemaSQL, "CHECK") || strings.Contains(schemaSQL, "id = 1") {
		t.Fatal("job_state must not be a single checked id")
	}
	for _, name := range []string{
		"dhash_b0", "dhash_b1", "dhash_b2", "dhash_b3", "dhash_b4", "dhash_b5",
		"derivative_groups", "detail_score", "placement", "job_kind TEXT PRIMARY KEY",
	} {
		if !strings.Contains(schemaSQL, name) {
			t.Fatalf("schema missing %s", name)
		}
	}

	catalog, err := Open(filepath.Join(t.TempDir(), "catalog", "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer catalog.Close()

	var version, cache, fk, busy int
	var journal string
	if err := catalog.Read.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil {
		t.Fatal(err)
	}
	if version != SchemaVersion {
		t.Fatalf("user_version %d", version)
	}
	if err := catalog.Read.QueryRow(`PRAGMA cache_size`).Scan(&cache); err != nil || cache != -8000 {
		t.Fatalf("cache %d %v", cache, err)
	}
	if err := catalog.Read.QueryRow(`PRAGMA foreign_keys`).Scan(&fk); err != nil || fk != 1 {
		t.Fatalf("fk %d %v", fk, err)
	}
	if err := catalog.Read.QueryRow(`PRAGMA busy_timeout`).Scan(&busy); err != nil || busy != 5000 {
		t.Fatalf("busy %d %v", busy, err)
	}
	if err := catalog.Read.QueryRow(`PRAGMA journal_mode`).Scan(&journal); err != nil || journal != "wal" {
		t.Fatalf("journal %s %v", journal, err)
	}
	if catalog.Write.Stats().MaxOpenConnections != 1 || catalog.Read.Stats().MaxOpenConnections != 1 || catalog.Watch.Stats().MaxOpenConnections != 1 {
		t.Fatal("expected one write connection, one read connection, and one watch connection")
	}

	var sqlText string
	if err := catalog.Read.QueryRow(`SELECT sql FROM sqlite_master WHERE name = 'job_state'`).Scan(&sqlText); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sqlText, "job_kind TEXT PRIMARY KEY") || strings.Contains(sqlText, "CHECK") {
		t.Fatalf("job_state sql %s", sqlText)
	}

	rows, err := catalog.Read.Query(`SELECT job_kind FROM job_state ORDER BY job_kind`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var kinds []string
	for rows.Next() {
		var kind string
		if err := rows.Scan(&kind); err != nil {
			t.Fatal(err)
		}
		kinds = append(kinds, kind)
	}
	if strings.Join(kinds, ",") != "reorg,trim" {
		t.Fatalf("kinds %v", kinds)
	}
	if _, err := catalog.Write.Exec(`INSERT INTO job_state (job_kind, run_state, pause_requested, safe_to_reboot, phase) VALUES ('reorg', 'idle', 0, 1, 'idle')`); err == nil {
		t.Fatal("duplicate job_kind was accepted")
	}

	res, err := catalog.Write.Exec(`INSERT INTO assets (uid, rel_path, byte_size, ext, media_class, reorg_policy, phase, discovered_at, updated_at) VALUES ('u1', 'Photos/a.jpg', 10, 'jpg', 'image', 'move', 'discovered', '2026-11-04T00:00:00Z', '2026-11-04T00:00:00Z')`)
	if err != nil {
		t.Fatal(err)
	}
	assetID, _ := res.LastInsertId()
	if _, err := catalog.Write.Exec(`INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at) VALUES (?, 'purge', 'purge_planned', 'Photos/_Duplicates/a.jpg', '', 10, '2026-11-04T00:00:00Z')`, assetID); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write.Exec(`INSERT INTO journal (asset_id, job_kind, state, src_rel, dest_rel, byte_size, updated_at) VALUES (99999, 'reorg', 'planned', 'Photos/a.jpg', 'Photos/b.jpg', 1, 't')`); err == nil {
		t.Fatal("foreign key was not enforced")
	}
}
