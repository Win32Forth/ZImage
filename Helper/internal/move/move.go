// Package move is the journaled reorg. One file is in flight at a time.
// Nothing is copied until Start. Boot finishes an open row before the next file.
package move

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/db"
	"zimage/helper/internal/detail"
	"zimage/helper/internal/pathsafe"
)

const (
	actionNone           = "none"
	actionPlannedKept    = "planned_kept"
	actionScratchReset   = "scratch_reset"
	actionCatalogUpdated = "catalog_updated"
	actionSourceDetached = "source_detached"
	actionBackupUnlinked = "backup_unlinked"
	actionSourceRestored = "source_restored"
)

// ErrCrashed stops the current file after a durable state. Recovery performs the next action.
var ErrCrashed = errors.New("crashed")

// ErrBlocked means the volume cannot hold the file plus 1 GB. The source is untouched.
var ErrBlocked = errors.New("blocked")

// ErrBusy means a reorg loop is already running in this process.
var ErrBusy = errors.New("reorg busy")

// Runner moves planned rows for one job kind. An empty JobKind is reorg.
type Runner struct {
	Root      string
	Catalog   *db.Catalog
	JobKind   string
	Note      func(string)
	After     func(state string) error
	CopySleep func()
	Free      func(string) (uint64, error)
	Shed      func() bool

	mu      sync.Mutex
	running bool
	last    string
}

func (r *Runner) kind() string {
	if r.JobKind == "" || r.JobKind == "reorg" {
		return "reorg"
	}
	return r.JobKind
}

type queryer interface {
	QueryRow(query string, args ...any) *sql.Row
}

type journalRow struct {
	ID      int64
	AssetID int64
	State   string
	Src     string
	Dest    string
	Blake   []byte
	Bytes   int64
	Scratch sql.NullString
	Backup  sql.NullString
}

// ReorgSafe is false while a reorg row is open or the job is running, pausing, or recovering.
// A planned row does not clear it.
func ReorgSafe(catalog *db.Catalog) (bool, error) {
	return liveSafe(catalog.Read, "reorg")
}

// ReorgSafeConn is ReorgSafe on one connection.
// Status passes the watch connection so a plan count holding Read does not hide the state.
func ReorgSafeConn(q queryer) (bool, error) {
	return liveSafe(q, "reorg")
}

// TrimLive is the trim open-row predicate. It does not read the stored bit.
func TrimLive(catalog *db.Catalog) (bool, error) {
	return liveSafe(catalog.Read, "trim")
}

// TrimQuiescent reports whether reorg Start is allowed. It does not write Trim's pause flag.
func TrimQuiescent(catalog *db.Catalog) (bool, error) {
	var run string
	err := catalog.Read.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = 'trim'`).Scan(&run)
	if err == sql.ErrNoRows {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	switch run {
	case "idle", "paused", "completed", "blocked":
		return true, nil
	default:
		return false, nil
	}
}

func liveSafe(q queryer, kind string) (bool, error) {
	var run string
	err := q.QueryRow(`SELECT run_state FROM job_state WHERE job_kind = ?`, kind).Scan(&run)
	if err == sql.ErrNoRows {
		run = "idle"
	} else if err != nil {
		return false, err
	}
	var open int
	if err := q.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE job_kind = ? AND state NOT IN ('planned', 'done', 'failed')`, kind).Scan(&open); err != nil {
		return false, err
	}
	if open > 0 {
		return false, nil
	}
	switch run {
	case "running", "pause_requested", "recovering":
		return false, nil
	default:
		return true, nil
	}
}

// Recovery is the last crash-table action in this process, or none.
func (r *Runner) Recovery() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.last == "" {
		return actionNone
	}
	return r.last
}

// Boot finishes open reorg rows before any new file. A pause flag stays paused.
// idle and plan_ready do not copy. A running job with a clear pause flag continues.
func (r *Runner) Boot() error {
	_ = r.pruneDone()
	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		return nil
	}
	start, err := r.bootLocked()
	if err != nil {
		r.mu.Unlock()
		return err
	}
	if start {
		r.running = true
	}
	r.mu.Unlock()
	if start {
		go r.finish(r.loop)
	}
	return nil
}

func (r *Runner) bootLocked() (bool, error) {
	var run, phase string
	var pause int
	if r.kind() == "reorg" {
		if err := r.finishPurges(); err != nil {
			return false, err
		}
		if err := r.finishKind("manual_duplicate"); err != nil {
			return false, err
		}
		if err := r.finishKind("restore"); err != nil {
			return false, err
		}
	}
	if err := r.Catalog.Read.QueryRow(`
		SELECT run_state, pause_requested, phase FROM job_state WHERE job_kind = ?`, r.kind()).Scan(&run, &pause, &phase); err != nil {
		return false, err
	}
	open, err := r.hasOpen()
	if err != nil {
		return false, err
	}
	if run == "planning" && !open {
		r.last = actionNone
		return false, r.setRun("idle")
	}
	active := run == "running" || run == "pause_requested" || run == "recovering" || run == "paused"
	if !active && !open {
		r.last = actionNone
		return false, nil
	}
	if _, err := r.Catalog.Write.Exec(`
		UPDATE job_state SET run_state = 'recovering', safe_to_reboot = 0 WHERE job_kind = ?`, r.kind()); err != nil {
		return false, err
	}
	last := actionNone
	for i := 0; i < 8; i++ {
		action, ok, err := r.recoverNext()
		if err != nil {
			return false, err
		}
		if !ok {
			break
		}
		last = action
		r.note("journal_recovery")
	}
	r.last = last
	if pause == 1 {
		return false, r.enterPaused()
	}
	switch run {
	case "blocked":
		return false, r.setRun("blocked")
	case "completed", "idle", "plan_ready":
		return false, r.setRun(run)
	}
	if r.kind() == "reorg" {
		if _, err := dating.CleanPrefix(phase); err != nil {
			return false, r.enterPaused()
		}
	}
	if _, err := r.Catalog.Write.Exec(`
		UPDATE job_state
		SET run_state = 'running', pause_requested = 0, safe_to_reboot = 0
		WHERE job_kind = ?`, r.kind()); err != nil {
		return false, err
	}
	return true, nil
}

// Start runs planned rows under the stored prefix. It refuses a second loop.
func (r *Runner) Start() error {
	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		return ErrBusy
	}
	if r.kind() == "reorg" {
		var phase string
		if err := r.Catalog.Read.QueryRow(`SELECT phase FROM job_state WHERE job_kind = 'reorg'`).Scan(&phase); err != nil {
			r.mu.Unlock()
			return err
		}
		if _, err := dating.CleanPrefix(phase); err != nil {
			r.mu.Unlock()
			return err
		}
	}
	if _, err := r.Catalog.Write.Exec(`
		UPDATE job_state
		SET run_state = 'running', pause_requested = 0, safe_to_reboot = 0
		WHERE job_kind = ?`, r.kind()); err != nil {
		r.mu.Unlock()
		return err
	}
	r.running = true
	r.mu.Unlock()
	go r.finish(r.loop)
	return nil
}

// Pause sets the reorg pause flag. The open file still runs to done.
func (r *Runner) Pause() error {
	_, err := r.Catalog.Write.Exec(`
		UPDATE job_state
		SET pause_requested = 1,
			run_state = CASE WHEN run_state = 'running' THEN 'pause_requested' ELSE run_state END,
			safe_to_reboot = 0
		WHERE job_kind = ?`, r.kind())
	return err
}

// Resume clears the pause flag. A paused job continues. An idle plan does not start.
func (r *Runner) Resume() error {
	r.mu.Lock()
	var run, phase string
	if err := r.Catalog.Read.QueryRow(`
		SELECT run_state, phase FROM job_state WHERE job_kind = ?`, r.kind()).Scan(&run, &phase); err != nil {
		r.mu.Unlock()
		return err
	}
	if run != "paused" && run != "pause_requested" {
		_, err := r.Catalog.Write.Exec(`UPDATE job_state SET pause_requested = 0 WHERE job_kind = ?`, r.kind())
		r.mu.Unlock()
		return err
	}
	if r.kind() == "reorg" {
		if _, err := dating.CleanPrefix(phase); err != nil {
			_, err = r.Catalog.Write.Exec(`UPDATE job_state SET pause_requested = 0 WHERE job_kind = ?`, r.kind())
			r.mu.Unlock()
			return err
		}
	}
	if _, err := r.Catalog.Write.Exec(`
		UPDATE job_state
		SET run_state = 'running', pause_requested = 0, safe_to_reboot = 0
		WHERE job_kind = ?`, r.kind()); err != nil {
		r.mu.Unlock()
		return err
	}
	if r.running {
		r.mu.Unlock()
		return nil
	}
	r.running = true
	r.mu.Unlock()
	go r.finish(r.loop)
	return nil
}

func (r *Runner) finish(work func() error) {
	_ = work()
	r.mu.Lock()
	r.running = false
	r.mu.Unlock()
}

func (r *Runner) loop() error {
	for {
		stop, err := r.paused()
		if err != nil {
			return err
		}
		if stop {
			return r.enterPaused()
		}
		id, ok, err := r.nextPlanned()
		if err != nil {
			return err
		}
		if !ok {
			return r.enterCompleted()
		}
		err = r.advance(id)
		if errors.Is(err, ErrBlocked) {
			_ = r.enterBlocked()
			return err
		}
		if err != nil {
			return err
		}
	}
}

func (r *Runner) paused() (bool, error) {
	var run string
	var pause int
	if err := r.Catalog.Read.QueryRow(`
		SELECT run_state, pause_requested FROM job_state WHERE job_kind = ?`, r.kind()).Scan(&run, &pause); err != nil {
		return false, err
	}
	return pause == 1 || run == "pause_requested" || run == "paused", nil
}

func (r *Runner) nextPlanned() (int64, bool, error) {
	if r.kind() != "reorg" {
		var id int64
		err := r.Catalog.Read.QueryRow(`
			SELECT id FROM journal
			WHERE job_kind = ? AND state = 'planned'
			ORDER BY id LIMIT 1`, r.kind()).Scan(&id)
		if err == sql.ErrNoRows {
			return 0, false, nil
		}
		if err != nil {
			return 0, false, err
		}
		return id, true, nil
	}
	var phase string
	if err := r.Catalog.Read.QueryRow(`SELECT phase FROM job_state WHERE job_kind = 'reorg'`).Scan(&phase); err != nil {
		return 0, false, err
	}
	prefix, err := dating.CleanPrefix(phase)
	if err != nil {
		return 0, false, nil
	}
	var id int64
	err = r.Catalog.Read.QueryRow(`
		SELECT id FROM journal
		WHERE job_kind = 'reorg' AND state = 'planned'
		AND (src_rel = ? OR src_rel LIKE ? ESCAPE '\')
		ORDER BY id LIMIT 1`, prefix, likeUnder(prefix)).Scan(&id)
	if err == sql.ErrNoRows {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return id, true, nil
}

func (r *Runner) advance(id int64) error {
	row, err := r.load(id)
	if err != nil {
		return err
	}
	if row.State != "planned" {
		return nil
	}
	rel, err := r.assetPath(row.AssetID)
	if err != nil {
		return err
	}
	if r.kind() == "reorg" && dating.UnderDuplicates(rel) {
		return r.fail(id, "duplicates")
	}
	if !r.allowsDest(row.Dest) {
		return r.fail(id, "dest_rejected")
	}
	if r.Shed != nil && r.Shed() {
		_ = r.enterBlocked()
		return ErrBlocked
	}
	others, err := r.otherOpen(row.AssetID, id)
	if err != nil {
		return err
	}
	if others > 0 {
		return r.fail(id, "second_open")
	}
	srcAbs, err := r.abs(rel)
	if err != nil {
		return r.fail(id, "dest_rejected")
	}
	info, err := os.Stat(srcAbs)
	if err != nil {
		return r.fail(id, "missing")
	}
	if path.Clean(rel) == path.Clean(row.Dest) {
		return r.finishInPlace(row, rel)
	}
	if err := r.after("planned"); err != nil {
		return ErrCrashed
	}
	free, freeErr := r.freeBytes()
	if freeErr != nil || free < uint64(info.Size())+spareBytes {
		_ = r.enterBlocked()
		return ErrBlocked
	}
	sum, err := hashFile(srcAbs)
	if err != nil {
		return err
	}
	var assetHash []byte
	if err := r.Catalog.Read.QueryRow(`SELECT blake3 FROM assets WHERE id = ?`, row.AssetID).Scan(&assetHash); err != nil {
		return err
	}
	if len(assetHash) == 32 && !bytesEqual(assetHash, sum) {
		return r.fail(id, "hash_mismatch")
	}
	scratchRel := scratchRelFor(id)
	backupRel := backupRelFor(id)
	if err := r.commitCopying(id, rel, scratchRel, sum, info.Size()); err != nil {
		return err
	}
	scratchAbs, err := r.abs(scratchRel)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(scratchAbs), 0o750); err != nil {
		return err
	}
	if err := os.WriteFile(scratchAbs, nil, 0o644); err != nil {
		return err
	}
	if r.CopySleep != nil {
		r.CopySleep()
	}
	if err := r.after("copying"); err != nil {
		_ = os.WriteFile(scratchAbs, []byte{0}, 0o644)
		return ErrCrashed
	}
	if err := streamCopy(scratchAbs, srcAbs); err != nil {
		return err
	}
	if err := fsyncDir(filepath.Dir(scratchAbs)); err != nil {
		return err
	}
	got, err := hashFile(scratchAbs)
	if err != nil {
		return err
	}
	if !bytesEqual(got, sum) {
		_ = os.Remove(scratchAbs)
		return r.fail(id, "hash_mismatch")
	}
	if err := r.commitState(id, "dest_verified"); err != nil {
		return err
	}
	destAbs, err := r.abs(row.Dest)
	if err != nil {
		return r.fail(id, "dest_rejected")
	}
	if _, err := os.Stat(destAbs); err == nil {
		_ = os.Remove(scratchAbs)
		return r.fail(id, "dest_exists")
	}
	if err := os.MkdirAll(filepath.Dir(destAbs), 0o750); err != nil {
		return err
	}
	if err := os.Rename(scratchAbs, destAbs); err != nil {
		return err
	}
	if err := fsyncDir(filepath.Dir(destAbs)); err != nil {
		return err
	}
	if err := r.after("dest_verified"); err != nil {
		return ErrCrashed
	}
	if err := r.commitCatalog(row.AssetID, id, row.Dest); err != nil {
		return err
	}
	if err := r.after("catalog_updated"); err != nil {
		return ErrCrashed
	}
	backupAbs, err := r.abs(backupRel)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(backupAbs), 0o750); err != nil {
		return err
	}
	if err := os.Rename(srcAbs, backupAbs); err != nil {
		return err
	}
	if err := fsyncDir(filepath.Dir(srcAbs)); err != nil {
		return err
	}
	if err := fsyncDir(filepath.Dir(backupAbs)); err != nil {
		return err
	}
	if err := r.commitDetached(id, backupRel); err != nil {
		return err
	}
	if err := r.after("source_detached"); err != nil {
		return ErrCrashed
	}
	match, err := sameEdges(destAbs, backupAbs)
	if err != nil {
		return err
	}
	if !match {
		return r.fail(id, "hash_mismatch")
	}
	if err := os.Remove(backupAbs); err != nil {
		return err
	}
	if err := fsyncDir(filepath.Dir(backupAbs)); err != nil {
		return err
	}
	if err := r.commitDone(id); err != nil {
		return err
	}
	r.note("move_done")
	if err := r.after("done"); err != nil {
		return ErrCrashed
	}
	return nil
}

func (r *Runner) finishInPlace(row journalRow, rel string) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	now := now()
	phase := placePhase(rel)
	if _, err := tx.Exec(`UPDATE assets SET phase = ?, updated_at = ? WHERE id = ?`, phase, now, row.AssetID); err != nil {
		return err
	}
	if _, err := tx.Exec(`
		UPDATE journal
		SET state = 'done', src_rel = ?, dest_rel = ?, scratch_rel = NULL, updated_at = ?
		WHERE id = ?`, rel, rel, now, row.ID); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	r.note("move_done")
	return nil
}

func (r *Runner) commitCopying(id int64, src, scratch string, sum []byte, size int64) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`
		UPDATE journal
		SET state = 'copying', src_rel = ?, scratch_rel = ?, blake3 = ?, byte_size = ?, updated_at = ?
		WHERE id = ? AND state = 'planned'`, src, scratch, sum, size, now(), id); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) commitState(id int64, state string) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`UPDATE journal SET state = ?, updated_at = ? WHERE id = ?`, state, now(), id); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) commitCatalog(assetID, journalID int64, dest string) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	now := now()
	switch r.kind() {
	case "trim", "manual_duplicate":
		reason := "manual"
		if r.kind() == "trim" {
			reason = r.reasonTrim(tx, assetID, journalID)
		}
		if _, err := tx.Exec(`
			UPDATE assets
			SET rel_path = ?, phase = ?, placement = 'duplicates', duplicate_reason = ?, updated_at = ?
			WHERE id = ?`, dest, placePhase(dest), reason, now, assetID); err != nil {
			return err
		}
		if err := detail.RecomputeTx(tx, assetID); err != nil {
			return err
		}
	case "restore":
		if _, err := tx.Exec(`
			UPDATE assets
			SET rel_path = ?, phase = ?, placement = 'active', pinned = 1, duplicate_reason = 'restored', updated_at = ?
			WHERE id = ?`, dest, placePhase(dest), now, assetID); err != nil {
			return err
		}
		if err := detail.RecomputeTx(tx, assetID); err != nil {
			return err
		}
	default:
		if _, err := tx.Exec(`
			UPDATE assets SET rel_path = ?, phase = ?, updated_at = ? WHERE id = ?`,
			dest, placePhase(dest), now, assetID); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`
		UPDATE journal SET state = 'catalog_updated', updated_at = ? WHERE id = ?`, now, journalID); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) reasonTrim(tx *sql.Tx, assetID, journalID int64) string {
	var mine []byte
	if err := tx.QueryRow(`SELECT blake3 FROM journal WHERE id = ?`, journalID).Scan(&mine); err != nil {
		return "trim"
	}
	var keepHash []byte
	var keepRel string
	err := tx.QueryRow(`
		SELECT k.blake3, k.rel_path
		FROM assets me
		JOIN assets k ON k.derivative_group_id = me.derivative_group_id AND k.is_keeper = 1 AND k.id != me.id
		WHERE me.id = ?`, assetID).Scan(&keepHash, &keepRel)
	if err != nil {
		return "trim"
	}
	if len(mine) == 32 && len(keepHash) == 32 && bytesEqual(mine, keepHash) {
		return "same_resolution"
	}
	if keepRel != "" {
		abs, err := r.abs(keepRel)
		if err != nil {
			return "trim"
		}
		sum, err := hashFile(abs)
		if err == nil && bytesEqual(sum, mine) {
			return "same_resolution"
		}
	}
	return "trim"
}

func (r *Runner) commitDetached(id int64, backup string) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`
		UPDATE journal SET state = 'source_detached', backup_rel = ?, updated_at = ? WHERE id = ?`,
		backup, now(), id); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) commitDone(id int64) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`
		UPDATE journal SET state = 'done', scratch_rel = NULL, updated_at = ? WHERE id = ?`, now(), id); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) fail(id int64, code string) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`
		UPDATE journal SET state = 'failed', error = ?, updated_at = ? WHERE id = ?`, code, now(), id); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) enterPaused() error {
	return r.setRunPaused()
}

func (r *Runner) enterCompleted() error {
	return r.setRun("completed")
}

func (r *Runner) enterBlocked() error {
	return r.setRun("blocked")
}

func (r *Runner) setRun(state string) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`UPDATE job_state SET run_state = ? WHERE job_kind = ?`, state, r.kind()); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) setRunPaused() error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`
		UPDATE job_state SET run_state = 'paused', pause_requested = 1 WHERE job_kind = ?`, r.kind()); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) storeSafe(tx *sql.Tx) error {
	safe, err := liveSafe(tx, r.kind())
	if err != nil {
		return err
	}
	bit := 0
	if safe {
		bit = 1
	}
	_, err = tx.Exec(`UPDATE job_state SET safe_to_reboot = ? WHERE job_kind = ?`, bit, r.kind())
	return err
}

func (r *Runner) allowsDest(rel string) bool {
	rel = path.Clean(strings.TrimPrefix(rel, "/"))
	switch r.kind() {
	case "trim", "manual_duplicate":
		return dating.UnderDuplicates(rel)
	case "restore":
		if rel != "Photos" && !strings.HasPrefix(rel, "Photos/") {
			return false
		}
		return !dating.UnderDuplicates(rel)
	default:
		return destAllowed(rel)
	}
}

func (r *Runner) begin() (*sql.Tx, error) {
	if _, err := r.Catalog.Write.Exec(`PRAGMA synchronous = FULL`); err != nil {
		return nil, err
	}
	return r.Catalog.Write.Begin()
}

func (r *Runner) after(state string) error {
	if r.After == nil {
		return nil
	}
	return r.After(state)
}

func (r *Runner) note(event string) {
	if r.Note != nil {
		r.Note(event)
	}
}

func (r *Runner) pruneDone() error {
	cutoff := time.Now().UTC().Add(-30 * 24 * time.Hour).Format(time.RFC3339)
	_, err := r.Catalog.Write.Exec(`DELETE FROM journal WHERE state = 'done' AND updated_at < ?`, cutoff)
	return err
}

func (r *Runner) hasOpen() (bool, error) {
	var n int
	err := r.Catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE job_kind = ? AND state NOT IN ('planned', 'done', 'failed')`, r.kind()).Scan(&n)
	return n > 0, err
}

func (r *Runner) otherOpen(assetID, journalID int64) (int, error) {
	var n int
	err := r.Catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM journal
		WHERE asset_id = ? AND id != ? AND state NOT IN ('done', 'failed')`, assetID, journalID).Scan(&n)
	return n, err
}

func (r *Runner) assetPath(id int64) (string, error) {
	var rel string
	err := r.Catalog.Read.QueryRow(`SELECT rel_path FROM assets WHERE id = ?`, id).Scan(&rel)
	return rel, err
}

func (r *Runner) load(id int64) (journalRow, error) {
	var row journalRow
	err := r.Catalog.Read.QueryRow(`
		SELECT id, asset_id, state, src_rel, dest_rel, blake3, byte_size, scratch_rel, backup_rel
		FROM journal WHERE id = ?`, id).Scan(
		&row.ID, &row.AssetID, &row.State, &row.Src, &row.Dest, &row.Blake, &row.Bytes, &row.Scratch, &row.Backup)
	return row, err
}

func (r *Runner) abs(rel string) (string, error) {
	rel = path.Clean(strings.TrimPrefix(rel, "/"))
	if err := pathsafe.MoveDestination(r.Root, rel); err != nil {
		return "", err
	}
	return filepath.Join(r.Root, filepath.FromSlash(rel)), nil
}

func destAllowed(rel string) bool {
	rel = path.Clean(strings.TrimPrefix(rel, "/"))
	if rel != "Photos" && !strings.HasPrefix(rel, "Photos/") {
		return false
	}
	return !dating.UnderDuplicates(rel)
}

func placePhase(rel string) string {
	if strings.Contains(rel, "/_Review/") {
		return "parked"
	}
	return "placed"
}

func scratchRelFor(id int64) string {
	return fmt.Sprintf(".zimage/move-scratch/%d", id)
}

func backupRelFor(id int64) string {
	return fmt.Sprintf(".zimage/move-backup/%d", id)
}

func likeUnder(prefix string) string {
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(prefix)
	return escaped + "/%"
}

func now() string {
	return time.Now().UTC().Format(time.RFC3339)
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
