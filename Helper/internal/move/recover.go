package move

import (
	"database/sql"
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"

	"zimage/helper/internal/dating"
)

// RecoverID performs the single crash-table action for one journal row.
func (r *Runner) RecoverID(id int64) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	row, err := r.load(id)
	if err != nil {
		return actionNone, err
	}
	if row.State == "done" || row.State == "failed" {
		return actionNone, nil
	}
	if row.State == "planned" && (!row.Scratch.Valid || row.Scratch.String == "") {
		return actionNone, nil
	}
	action, err := r.recover(row)
	if err != nil {
		return actionNone, err
	}
	r.last = action
	r.note("journal_recovery")
	return action, nil
}

// RecoverOne performs the single crash-table action for the oldest open reorg row.
func (r *Runner) RecoverOne() (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	action, ok, err := r.recoverNext()
	if err != nil {
		return actionNone, err
	}
	if !ok {
		return actionNone, nil
	}
	r.last = action
	r.note("journal_recovery")
	return action, nil
}

func (r *Runner) recoverNext() (string, bool, error) {
	row, err := r.selectRecoverable()
	if err == sql.ErrNoRows {
		return actionNone, false, nil
	}
	if err != nil {
		return actionNone, false, err
	}
	action, err := r.recover(row)
	if err != nil {
		return actionNone, false, err
	}
	return action, true, nil
}

func (r *Runner) selectRecoverable() (journalRow, error) {
	var row journalRow
	err := r.Catalog.Read.QueryRow(`
		SELECT id, asset_id, state, src_rel, dest_rel, blake3, byte_size, scratch_rel, backup_rel
		FROM journal
		WHERE job_kind = ?
		AND state NOT IN ('done', 'failed')
		AND NOT (state = 'planned' AND (scratch_rel IS NULL OR scratch_rel = ''))
		ORDER BY id
		LIMIT 1`, r.kind()).Scan(
		&row.ID, &row.AssetID, &row.State, &row.Src, &row.Dest, &row.Blake, &row.Bytes, &row.Scratch, &row.Backup)
	return row, err
}

func (r *Runner) recover(row journalRow) (string, error) {
	switch row.State {
	case "planned":
		return r.recoverPlanned(row)
	case "copying":
		return r.recoverCopying(row)
	case "dest_verified":
		return r.recoverVerified(row)
	case "catalog_updated":
		return r.recoverCatalog(row)
	case "source_detached":
		return r.recoverDetached(row)
	case "purge_planned", "unlinked":
		return r.recoverPurge(row)
	default:
		return r.failed(row.ID, "failed")
	}
}

func (r *Runner) recoverPlanned(row journalRow) (string, error) {
	if err := r.removeScratch(row); err != nil {
		return "", err
	}
	if err := r.clearScratch(row.ID, "planned"); err != nil {
		return "", err
	}
	return actionPlannedKept, nil
}

func (r *Runner) recoverCopying(row journalRow) (string, error) {
	if r.finalReady(row) && r.catalogAt(row.AssetID, row.Src) {
		if err := r.commitCatalog(row.AssetID, row.ID, row.Dest); err != nil {
			return "", err
		}
		return actionCatalogUpdated, nil
	}
	if r.scratchReady(row) && !r.finalReady(row) {
		if err := r.renameScratchToFinal(row); err != nil {
			return "", err
		}
		if err := r.commitState(row.ID, "dest_verified"); err != nil {
			return "", err
		}
		return actionCatalogUpdated, nil
	}
	if err := r.removeScratch(row); err != nil {
		return "", err
	}
	if err := r.clearScratch(row.ID, "planned"); err != nil {
		return "", err
	}
	return actionScratchReset, nil
}

func (r *Runner) recoverVerified(row journalRow) (string, error) {
	if r.finalReady(row) && r.catalogAt(row.AssetID, row.Src) {
		if err := r.commitCatalog(row.AssetID, row.ID, row.Dest); err != nil {
			return "", err
		}
		return actionCatalogUpdated, nil
	}
	if !r.finalReady(row) && r.scratchReady(row) {
		if err := r.renameScratchToFinal(row); err != nil {
			return "", err
		}
		return actionCatalogUpdated, nil
	}
	if err := r.removeScratch(row); err != nil {
		return "", err
	}
	if err := r.clearScratch(row.ID, "planned"); err != nil {
		return "", err
	}
	return actionScratchReset, nil
}

func (r *Runner) recoverCatalog(row journalRow) (string, error) {
	if !r.finalReady(row) {
		return r.failed(row.ID, "hash_mismatch")
	}
	srcAbs, err := r.abs(row.Src)
	if err != nil {
		return "", err
	}
	backupRel := backupRelFor(row.ID)
	if row.Backup.Valid && row.Backup.String != "" {
		backupRel = row.Backup.String
	}
	_, statErr := os.Stat(srcAbs)
	if statErr == nil {
		backupAbs, err := r.abs(backupRel)
		if err != nil {
			return "", err
		}
		if err := os.MkdirAll(filepath.Dir(backupAbs), 0o750); err != nil {
			return "", err
		}
		if err := os.Rename(srcAbs, backupAbs); err != nil {
			return "", err
		}
		if err := fsyncDir(filepath.Dir(srcAbs)); err != nil {
			return "", err
		}
		if err := fsyncDir(filepath.Dir(backupAbs)); err != nil {
			return "", err
		}
		if err := r.commitDetached(row.ID, backupRel); err != nil {
			return "", err
		}
		return actionSourceDetached, nil
	}
	if !errors.Is(statErr, os.ErrNotExist) {
		return "", statErr
	}
	if err := r.commitDetached(row.ID, backupRel); err != nil {
		return "", err
	}
	return actionSourceDetached, nil
}

func (r *Runner) recoverDetached(row journalRow) (string, error) {
	destAbs, err := r.abs(row.Dest)
	if err != nil {
		return "", err
	}
	backupRel := backupRelFor(row.ID)
	if row.Backup.Valid && row.Backup.String != "" && backupRel == backupRelFor(row.ID) {
		backupRel = row.Backup.String
	}
	if pathAllowedBackup(backupRel, row.ID) {
		backupRel = backupRelFor(row.ID)
	}
	backupAbs, err := r.abs(backupRelFor(row.ID))
	if err != nil {
		return "", err
	}
	_, destErr := os.Stat(destAbs)
	if destErr == nil {
		if _, err := os.Stat(backupAbs); err == nil {
			match, err := sameEdges(destAbs, backupAbs)
			if err != nil {
				return "", err
			}
			if !match || !r.finalReady(row) {
				return r.failed(row.ID, "hash_mismatch")
			}
			if err := os.Remove(backupAbs); err != nil {
				return "", err
			}
			if err := fsyncDir(filepath.Dir(backupAbs)); err != nil {
				return "", err
			}
		} else if !r.finalReady(row) {
			return r.failed(row.ID, "hash_mismatch")
		}
		if err := r.commitDone(row.ID); err != nil {
			return "", err
		}
		return actionBackupUnlinked, nil
	}
	if destErr != nil && !errors.Is(destErr, os.ErrNotExist) {
		return "", destErr
	}
	if _, err := os.Stat(backupAbs); err != nil {
		return r.failed(row.ID, "missing")
	}
	srcAbs, err := r.abs(row.Src)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(srcAbs), 0o750); err != nil {
		return "", err
	}
	if _, err := os.Stat(srcAbs); err == nil {
		return r.failed(row.ID, "dest_exists")
	}
	if err := os.Rename(backupAbs, srcAbs); err != nil {
		return "", err
	}
	if err := fsyncDir(filepath.Dir(srcAbs)); err != nil {
		return "", err
	}
	if err := fsyncDir(filepath.Dir(backupAbs)); err != nil {
		return "", err
	}
	tx, err := r.begin()
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback() }()
	stamp := now()
	if _, err := tx.Exec(`
		UPDATE assets SET rel_path = ?, phase = 'planned', updated_at = ? WHERE id = ?`,
		row.Src, stamp, row.AssetID); err != nil {
		return "", err
	}
	if _, err := tx.Exec(`
		UPDATE journal
		SET state = 'planned', backup_rel = NULL, scratch_rel = NULL, updated_at = ?
		WHERE id = ?`, stamp, row.ID); err != nil {
		return "", err
	}
	if err := r.storeSafe(tx); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return actionSourceRestored, nil
}

func (r *Runner) failed(id int64, code string) (string, error) {
	if err := r.fail(id, code); err != nil {
		return "", err
	}
	return "failed", nil
}

func (r *Runner) clearScratch(id int64, state string) error {
	tx, err := r.begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`
		UPDATE journal SET state = ?, scratch_rel = NULL, updated_at = ? WHERE id = ?`, state, now(), id); err != nil {
		return err
	}
	if err := r.storeSafe(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Runner) removeScratch(row journalRow) error {
	if !row.Scratch.Valid || row.Scratch.String == "" {
		return nil
	}
	if row.Scratch.String != scratchRelFor(row.ID) {
		return nil
	}
	abs, err := r.abs(row.Scratch.String)
	if err != nil {
		return nil
	}
	if _, err := os.Stat(abs); err != nil {
		return nil
	}
	return os.Remove(abs)
}

func (r *Runner) scratchReady(row journalRow) bool {
	if !row.Scratch.Valid || row.Scratch.String != scratchRelFor(row.ID) || len(row.Blake) != 32 {
		return false
	}
	abs, err := r.abs(row.Scratch.String)
	if err != nil {
		return false
	}
	return fileMatches(abs, row.Bytes, row.Blake)
}

func (r *Runner) finalReady(row journalRow) bool {
	if !r.allowsDest(row.Dest) || len(row.Blake) != 32 {
		return false
	}
	abs, err := r.abs(row.Dest)
	if err != nil {
		return false
	}
	return fileMatches(abs, row.Bytes, row.Blake)
}

func fileMatches(path string, size int64, sum []byte) bool {
	info, err := os.Stat(path)
	if err != nil || info.Size() != size {
		return false
	}
	got, err := hashFile(path)
	if err != nil {
		return false
	}
	return bytesEqual(got, sum)
}

func (r *Runner) catalogAt(assetID int64, rel string) bool {
	got, err := r.assetPath(assetID)
	if err != nil {
		return false
	}
	return got == rel
}

// Execute runs one planned row for this runner's job kind. It does not start the loop.
func (r *Runner) Execute(id int64) error {
	return r.advance(id)
}

// FinishPurge completes one purge row. A path outside the store is marked failed and left in place.
func (r *Runner) FinishPurge(id int64) error {
	row, err := r.load(id)
	if err != nil {
		return err
	}
	_, err = r.recoverPurge(row)
	return err
}

func (r *Runner) finishKind(kind string) error {
	other := &Runner{Root: r.Root, Catalog: r.Catalog, JobKind: kind, Note: r.Note}
	var previous int64
	for range 10000 {
		row, err := other.selectRecoverable()
		if err == sql.ErrNoRows {
			return nil
		}
		if err != nil {
			return err
		}
		if row.ID == previous {
			return errors.New("journal")
		}
		previous = row.ID
		if _, err := other.recover(row); err != nil {
			return err
		}
		other.note("journal_recovery")
	}
	return errors.New("journal")
}

func (r *Runner) finishPurges() error {
	var previous int64
	for range 10000 {
		row, err := r.selectPurge()
		if err == sql.ErrNoRows {
			return nil
		}
		if err != nil {
			return err
		}
		if row.ID == previous {
			return errors.New("purge")
		}
		previous = row.ID
		action, err := r.recover(row)
		if err != nil {
			return err
		}
		r.last = action
		r.note("journal_recovery")
	}
	return errors.New("purge")
}

func (r *Runner) selectPurge() (journalRow, error) {
	var row journalRow
	err := r.Catalog.Read.QueryRow(`
		SELECT id, asset_id, state, src_rel, dest_rel, blake3, byte_size, scratch_rel, backup_rel
		FROM journal
		WHERE job_kind = 'purge'
		AND state NOT IN ('done', 'failed')
		ORDER BY id
		LIMIT 1`).Scan(
		&row.ID, &row.AssetID, &row.State, &row.Src, &row.Dest, &row.Blake, &row.Bytes, &row.Scratch, &row.Backup)
	return row, err
}

func (r *Runner) recoverPurge(row journalRow) (string, error) {
	rel := path.Clean(strings.TrimPrefix(row.Src, "/"))
	if !dating.UnderDuplicates(rel) {
		r.note("purge_refused")
		return r.failed(row.ID, "purge_refused")
	}
	abs, err := r.abs(rel)
	if err != nil {
		r.note("purge_refused")
		return r.failed(row.ID, "purge_refused")
	}
	if _, err := os.Stat(abs); err == nil {
		if err := os.Remove(abs); err != nil {
			return "", err
		}
		if err := fsyncDir(filepath.Dir(abs)); err != nil {
			return "", err
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}
	return r.tombstone(row)
}

func (r *Runner) tombstone(row journalRow) (string, error) {
	var uid string
	if err := r.Catalog.Read.QueryRow(`SELECT uid FROM assets WHERE id = ?`, row.AssetID).Scan(&uid); err != nil {
		return "", err
	}
	tomb := ".zimage/purged/" + uid
	tx, err := r.begin()
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback() }()
	stamp := now()
	if _, err := tx.Exec(`
		UPDATE assets SET placement = 'purged', rel_path = ?, updated_at = ? WHERE id = ?`,
		tomb, stamp, row.AssetID); err != nil {
		return "", err
	}
	if _, err := tx.Exec(`UPDATE journal SET state = 'done', updated_at = ? WHERE id = ?`, stamp, row.ID); err != nil {
		return "", err
	}
	if err := r.storeSafe(tx); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	r.note("purge_done")
	return "purge_done", nil
}

func (r *Runner) renameScratchToFinal(row journalRow) error {
	if !row.Scratch.Valid || row.Scratch.String != scratchRelFor(row.ID) {
		return errors.New("scratch")
	}
	scratchAbs, err := r.abs(row.Scratch.String)
	if err != nil {
		return err
	}
	destAbs, err := r.abs(row.Dest)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(destAbs), 0o750); err != nil {
		return err
	}
	if err := os.Rename(scratchAbs, destAbs); err != nil {
		return err
	}
	return fsyncDir(filepath.Dir(destAbs))
}

func pathAllowedBackup(rel string, id int64) bool {
	return rel == backupRelFor(id)
}
