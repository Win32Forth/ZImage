// Package organize runs one dating pass. It plans destinations and does not move files.
package organize

import (
	"sync"

	"zimage/helper/internal/dating"
	"zimage/helper/internal/db"
	"zimage/helper/internal/detail"
	"zimage/helper/internal/dhashindex"
	"zimage/helper/internal/events"
)

// passMu keeps the startup pass and an on-demand duplicate scan from regrouping at the same time.
var passMu sync.Mutex

// Hold is the scan's claim on passMu. Release unlocks it.
func Hold() bool { return passMu.TryLock() }

// Release unlocks a Hold. The startup pass uses its own lock.
func Release() { passMu.Unlock() }

// Pass dates files, fills dHashes, clusters events, scores detail, groups derivatives, and plans paths.
// pause runs between batches. A shedding helper waits there instead of aborting the pass.
// note receives short events. Failures are returned so the caller can log dating_failed.
func Pass(root string, catalog *db.Catalog, pause func(), note func(string)) error {
	return PassProgress(root, catalog, pause, note, nil)
}

// PassProgress is Pass. progress reports the current task. It does no extra catalog work.
func PassProgress(root string, catalog *db.Catalog, pause func(), note func(string), progress func(phase string, done, total int)) error {
	passMu.Lock()
	defer passMu.Unlock()
	return pass(root, catalog, pause, note, progress)
}

func pass(root string, catalog *db.Catalog, pause func(), note func(string), progress func(phase string, done, total int)) error {
	report := func(phase string, done, total int) {
		if progress != nil {
			progress(phase, done, total)
		}
	}
	opts := dating.Options{Pause: pause, Note: note, Progress: func(done, total int) {
		report("dating", done, total)
	}}
	if err := dating.Assign(root, catalog, opts); err != nil {
		return err
	}
	if err := dhashindex.IndexThumbsProgress(root, catalog, pause, func(done, total int) {
		report("hashing", done, total)
	}); err != nil {
		return err
	}
	neighbors := opts
	neighbors.Progress = func(done, total int) {
		report("neighbors", done, total)
	}
	if err := dating.InheritNeighbors(catalog, neighbors); err != nil {
		return err
	}
	if err := events.ApplyProgress(root, catalog, pause, func(done, total int) {
		report("events", done, total)
	}); err != nil {
		return err
	}
	if err := detail.ScoreFilesProgress(root, catalog, note, pause, func(done, total int) {
		report("scoring", done, total)
	}); err != nil {
		return err
	}
	if err := dhashindex.GroupProgress(catalog, note, func(phase string, done, total int) {
		report(phase, done, total)
	}); err != nil {
		return err
	}
	_, err := dating.PlanPrefixRootProgress(catalog, "Photos", "", func(counts dating.Counts) {
		report("planning", counts.Seen, 0)
	})
	return err
}
