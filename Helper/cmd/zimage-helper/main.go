// Command zimage-helper is the DS423 catalog service.
// DSM Task Scheduler starts it at boot as a non-admin user, not root.
// Set GOMEMLIMIT=160MiB in that task. The binary lives at
// PhotoVideoAudio/.zimage/bin/zimage-helper because a DSM update can clear /usr/local.
//
// Cross-compile on the Mac:
//
//	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o zimage-helper ./cmd/zimage-helper
//
// Before the first catalog.db on btrfs, turn copy-on-write off. This process does not run chattr:
//
//	mkdir -p <library_root_local>/.zimage/catalog
//	chattr +C <library_root_local>/.zimage/catalog
//
// This process walks Photos and writes thumbnails.
// It does not move files until POST /v1/reorg/start or POST /v1/trim/start.
// Boot recovery finishes an open journal row before that work is accepted.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"time"

	"zimage/helper/internal/cacheledger"
	"zimage/helper/internal/config"
	"zimage/helper/internal/db"
	"zimage/helper/internal/httpapi"
	"zimage/helper/internal/inventory"
	"zimage/helper/internal/lockfile"
	"zimage/helper/internal/move"
	"zimage/helper/internal/organize"
	"zimage/helper/internal/relink"
	"zimage/helper/internal/thumb"
)

func main() {
	configPath := flag.String("config", "config.yaml", "path to config.yaml")
	flag.Parse()
	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config")
		os.Exit(1)
	}
	if err := run(cfg); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
}

func run(cfg config.Config) error {
	ok := config.PhotosWritable(cfg.LibraryRoot)
	var (
		catalog *db.Catalog
		token   string
		held    *lockfile.Lock
	)
	pair, leaf, err := httpapi.GenerateCert()
	if err != nil {
		return err
	}
	if ok {
		if err := layout(cfg.LibraryRoot); err != nil {
			return err
		}
		zdir := filepath.Join(cfg.LibraryRoot, ".zimage")
		held, err = lockfile.Acquire(filepath.Join(zdir, "helper.lock"))
		if err != nil {
			return err
		}
		defer held.Release()
		pid := strconv.Itoa(os.Getpid()) + "\n"
		if err := os.WriteFile(filepath.Join(zdir, "helper.pid"), []byte(pid), 0o600); err != nil {
			return err
		}
		catalog, err = db.Open(filepath.Join(zdir, "catalog", "catalog.db"))
		if err != nil {
			return err
		}
		defer catalog.Close()
		token, err = httpapi.EnsureToken(zdir)
		if err != nil {
			return err
		}
		pair, leaf, err = httpapi.EnsureCert(filepath.Join(zdir, "tls"))
		if err != nil {
			return err
		}
	}
	srv := httpapi.NewServer(cfg.LibraryRoot, ok, cfg.AllowLoopback, token, catalog, pair, leaf)
	if ok {
		srv.LogPath = filepath.Join(cfg.LibraryRoot, ".zimage", "logs", "helper.log")
		runner := &move.Runner{Root: cfg.LibraryRoot, Catalog: catalog, Note: srv.Note, Shed: srv.Shedding}
		trimmer := &move.Runner{Root: cfg.LibraryRoot, Catalog: catalog, JobKind: "trim", Note: srv.Note, Shed: srv.Shedding}
		srv.UseRunner(runner)
		srv.UseTrim(trimmer)
		if err := runner.Boot(); err != nil {
			srv.Note("journal_recovery")
		}
		if err := trimmer.Boot(); err != nil {
			srv.Note("journal_recovery")
		}
		// The port opens before this walk. Existing previews are recorded, not rewritten.
		go func() {
			defer srv.ClearPass()
			srv.SetPass("cache", 0, 0)
			if err := cacheledger.ReconcileProgress(cfg.LibraryRoot, catalog, cacheledger.Limits{}, func(done int) {
				srv.SetPass("cache", done, 0)
			}); err != nil {
				srv.Note("cache_reconcile")
			}
			catalogPass(cfg.LibraryRoot, catalog, srv)
		}()
	}
	ln, err := httpapi.ListenIPv4(cfg.Listen)
	if err != nil {
		return err
	}
	return srv.Serve(ln)
}

func catalogPass(root string, catalog *db.Catalog, srv *httpapi.Server) {
	// The folder on screen is previewed before the oldest catalog rows.
	// With no folder set, the first pages stay oldest-id, 200 of them, then the walk.
	previewDone := 0
	previewTotal := countPreviewsLeft(catalog)
	step := func() {
		previewDone++
		srv.SetPass("previews", previewDone, previewTotal)
	}
	idleFocus := ""
	folderPrefix := ""
	folderDone := 0
	serveFocus := func(limit int) int {
		prefix := srv.Focus()
		if prefix == "" || prefix == idleFocus || limit <= 0 {
			return 0
		}
		if prefix != folderPrefix {
			folderPrefix = prefix
			folderDone = 0
		}
		left := countPreviewsUnder(catalog, prefix)
		if left == 0 {
			idleFocus = prefix
			return 0
		}
		total := folderDone + left
		srv.SetPass("folder", folderDone, total)
		n, err := thumb.ApplyNextUnder(root, catalog, srv.Shedding, limit, prefix, func() {
			folderDone++
			srv.SetPass("folder", folderDone, total)
		})
		if err != nil {
			srv.Note("thumb_failed")
			return n
		}
		// A short batch that finished nothing, or a folder with nothing left, can wait.
		// A short batch that finished some files is tried again, so one unreadable file
		// does not hide the rest of the folder.
		if n < limit && !srv.Shedding() && (n == 0 || countPreviewsUnder(catalog, prefix) == 0) {
			idleFocus = prefix
		}
		return n
	}
	if previewTotal > 0 {
		srv.SetPass("previews", 0, previewTotal)
	}
	globalLeft := 200
	batched := false
	for globalLeft > 0 {
		if srv.Shedding() {
			break
		}
		if serveFocus(8) > 0 {
			continue
		}
		chunk := 8
		if chunk > globalLeft {
			chunk = globalLeft
		}
		n, err := thumb.ApplyNextStep(root, catalog, srv.Shedding, chunk, step)
		if err != nil {
			srv.Note("thumb_failed")
			break
		}
		if n == 0 {
			break
		}
		batched = true
		globalLeft -= n
	}
	if batched {
		srv.Note("thumb_batch")
	}
	known := countAssets(catalog)
	srv.SetPass("relink", 0, known)
	if err := relink.Pass(root, catalog, relink.Options{
		Copying: func() bool {
			var n int
			if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE state = 'copying'`).Scan(&n); err != nil {
				return false
			}
			return n > 0
		},
		Progress: func(done int) {
			srv.SetPass("relink", done, known)
			if done%10 == 0 {
				serveFocus(4)
			}
		},
		Stage: func(name string, done, total int) {
			srv.SetPass(name, done, total)
			if name == "presence" || done%10 == 0 {
				serveFocus(4)
			}
		},
	}); err != nil {
		srv.Note("relink_failed")
	}
	_, err := inventory.Run(root, catalog, inventory.Options{
		Progress: func(done, total int) {
			srv.SetPass("inventory", done, total)
		},
		Interrupt: srv.Focus,
		Needs: func(prefix string) bool {
			if prefix == "" || prefix == idleFocus {
				return false
			}
			return countPreviewsUnder(catalog, prefix) > 0
		},
		Serve: func(_ string) {
			idleFocus = ""
			serveFocus(8)
		},
		AfterCommit: func() {
			idleFocus = ""
			time.Sleep(200 * time.Millisecond)
			srv.Note("inventory_commit")
			if serveFocus(8) > 0 {
				return
			}
			if _, err := thumb.ApplyNextStep(root, catalog, srv.Shedding, 8, step); err != nil {
				srv.Note("thumb_failed")
			}
		},
	})
	if err != nil {
		srv.Note("inventory_failed")
		return
	}
	left := countPreviewsLeft(catalog)
	if left > 0 || previewDone > 0 {
		previewTotal = previewDone + left
		srv.SetPass("previews", previewDone, previewTotal)
	}
	for {
		if srv.Shedding() {
			break
		}
		if serveFocus(16) > 0 {
			continue
		}
		n, err := thumb.ApplyNextStep(root, catalog, srv.Shedding, 16, step)
		if err != nil {
			srv.Note("thumb_failed")
			break
		}
		if n == 0 {
			break
		}
	}
	// Dates, groups, and planned paths. This pass does not move or delete library files.
	if err := organize.PassProgress(root, catalog, func() {
		for srv.Shedding() {
			time.Sleep(200 * time.Millisecond)
		}
		time.Sleep(200 * time.Millisecond)
	}, srv.Note, func(phase string, done, total int) {
		srv.SetPass(phase, done, total)
	}); err != nil {
		srv.Note("dating_failed")
	}
}

func countAssets(catalog *db.Catalog) int {
	var n int
	if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets`).Scan(&n); err != nil {
		return 0
	}
	return n
}

func countPreviewsLeft(catalog *db.Catalog) int {
	var n int
	err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM assets
		WHERE phase = 'discovered' AND thumb_rel IS NULL
		AND media_class IN ('image', 'raw')`).Scan(&n)
	if err != nil {
		return 0
	}
	return n
}

func countPreviewsUnder(catalog *db.Catalog, prefix string) int {
	var n int
	err := catalog.Read.QueryRow(`
		SELECT COUNT(*) FROM assets
		WHERE phase = 'discovered' AND thumb_rel IS NULL
		AND media_class IN ('image', 'raw')
		AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\')`,
		prefix, thumb.PathLike(prefix)).Scan(&n)
	if err != nil {
		return 0
	}
	return n
}

func layout(root string) error {
	for _, dir := range []string{
		".zimage/bin",
		".zimage/tls",
		".zimage/catalog",
		".zimage/logs",
		".zimage/edits",
		".zimage/cache/thumbs",
		".zimage/cache/embeddings",
		".zimage/cache/scratch",
		".zimage/move-scratch",
		".zimage/move-backup",
	} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o750); err != nil {
			return err
		}
	}
	return nil
}
