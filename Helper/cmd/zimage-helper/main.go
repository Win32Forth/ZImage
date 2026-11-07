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
			if err := cacheledger.Reconcile(cfg.LibraryRoot, catalog, cacheledger.Limits{}); err != nil {
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
	// The grid's first page is the oldest rows. Write those previews before the
	// rest of the walk, or a large library stays blank until the last file.
	if n, err := thumb.ApplyNext(root, catalog, srv.Shedding, 200); err != nil {
		srv.Note("thumb_failed")
	} else if n > 0 {
		srv.Note("thumb_batch")
	}
	if err := relink.Pass(root, catalog, relink.Options{Copying: func() bool {
		var n int
		if err := catalog.Read.QueryRow(`SELECT COUNT(*) FROM journal WHERE state = 'copying'`).Scan(&n); err != nil {
			return false
		}
		return n > 0
	}}); err != nil {
		srv.Note("relink_failed")
	}
	_, err := inventory.Run(root, catalog, inventory.Options{AfterCommit: func() {
		time.Sleep(200 * time.Millisecond)
		srv.Note("inventory_commit")
		if _, err := thumb.ApplyNext(root, catalog, srv.Shedding, 8); err != nil {
			srv.Note("thumb_failed")
		}
	}})
	if err != nil {
		srv.Note("inventory_failed")
		return
	}
	if err := thumb.Apply(root, catalog, srv.Shedding); err != nil {
		srv.Note("thumb_failed")
	}
	// Dates, groups, and planned paths. This pass does not move or delete library files.
	if err := organize.Pass(root, catalog, func() {
		for srv.Shedding() {
			time.Sleep(200 * time.Millisecond)
		}
		time.Sleep(200 * time.Millisecond)
	}, srv.Note); err != nil {
		srv.Note("dating_failed")
	}
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
