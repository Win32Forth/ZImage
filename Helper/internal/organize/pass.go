// Package organize runs one dating pass. It plans destinations and does not move files.
package organize

import (
	"zimage/helper/internal/dating"
	"zimage/helper/internal/db"
	"zimage/helper/internal/detail"
	"zimage/helper/internal/dhashindex"
	"zimage/helper/internal/events"
)

// Pass dates files, fills dHashes, clusters events, scores detail, groups derivatives, and plans paths.
// pause runs between batches. A shedding helper waits there instead of aborting the pass.
// note receives short events. Failures are returned so the caller can log dating_failed.
func Pass(root string, catalog *db.Catalog, pause func(), note func(string)) error {
	opts := dating.Options{Pause: pause, Note: note}
	if err := dating.Assign(root, catalog, opts); err != nil {
		return err
	}
	if err := dhashindex.IndexThumbs(root, catalog, pause); err != nil {
		return err
	}
	if err := dating.InheritNeighbors(catalog, opts); err != nil {
		return err
	}
	if err := events.Apply(root, catalog, pause); err != nil {
		return err
	}
	if err := detail.ScoreFiles(root, catalog, note, pause); err != nil {
		return err
	}
	if err := dhashindex.Group(catalog, note); err != nil {
		return err
	}
	return dating.Plan(catalog)
}
