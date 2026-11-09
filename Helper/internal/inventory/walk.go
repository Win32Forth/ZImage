// Package inventory walks Photos and inserts catalog rows.
// Dating and moves are later passes. This walk commits every 50 files.
package inventory

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"zimage/helper/internal/db"
	"zimage/helper/internal/relink"
	"zimage/helper/internal/thumb"
)

const batchSize = 50

// Skip directories by name. _Duplicates is not in this set.
var skipDirectories = map[string]bool{
	"@eaDir":          true,
	"#recycle":        true,
	".explorer-trash": true,
	".zimage":         true,
	"Thumbs":          true,
	".thumbnails":     true,
	".TemporaryItems": true,
}

// Options controls the low-priority pause between commits.
// Progress reports files looked at. total is a catalog count taken once at the start, or 0 when that count fails.
// Interrupt names a folder that should be served before the walk continues.
// Needs reports whether that folder still has preview work. It may use the read connection while a batch is open.
// Serve runs only after that batch is committed, while the write connection is free.
type Options struct {
	AfterCommit func()
	Progress    func(done, total int)
	Interrupt   func() string
	Needs       func(prefix string) bool
	Serve       func(prefix string)
}

// Summary is the result of one walk.
type Summary struct {
	Inserted int
	Commits  int
}

// Run inserts new files under root/Photos.
// An existing rel_path is left in place, except a video still marked leave, which becomes move.
func Run(root string, catalog *db.Catalog, opts Options) (Summary, error) {
	var summary Summary
	photos := filepath.Join(root, "Photos")
	info, err := os.Stat(photos)
	if err != nil || !info.IsDir() {
		return summary, nil
	}
	if _, err := catalog.Write.Exec(`PRAGMA synchronous = NORMAL`); err != nil {
		return summary, err
	}
	defer catalog.Write.Exec(`PRAGMA synchronous = FULL`)

	var known int
	if opts.Progress != nil {
		_ = catalog.Read.QueryRow(`SELECT COUNT(*) FROM assets`).Scan(&known)
		opts.Progress(0, known)
	}

	tx, err := catalog.Write.Begin()
	if err != nil {
		return summary, err
	}
	pending := 0
	// focusPrefix is empty for a normal batch. A focused folder is served after
	// the commit and before the next transaction, because Write has one connection.
	commit := func(focusPrefix string) error {
		if pending == 0 {
			return nil
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		summary.Commits++
		pending = 0
		if focusPrefix != "" {
			if opts.Serve != nil {
				opts.Serve(focusPrefix)
			}
		} else if opts.AfterCommit != nil {
			opts.AfterCommit()
		}
		tx, err = catalog.Write.Begin()
		return err
	}
	defer func() { _ = tx.Rollback() }()

	err = filepath.WalkDir(photos, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		name := entry.Name()
		if entry.IsDir() {
			if path != photos && skipDirectory(name) {
				return filepath.SkipDir
			}
			return nil
		}
		if skipFile(name) {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		fileInfo, err := entry.Info()
		if err != nil {
			return nil
		}
		if err := insert(tx, path, rel, fileInfo); err != nil {
			return err
		}
		summary.Inserted++
		pending++
		if opts.Progress != nil {
			opts.Progress(summary.Inserted, known)
		}
		focusPrefix := ""
		if opts.Interrupt != nil && opts.Needs != nil {
			if prefix := opts.Interrupt(); prefix != "" && opts.Needs(prefix) {
				focusPrefix = prefix
			}
		}
		if focusPrefix != "" || pending >= batchSize {
			if err := commit(focusPrefix); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return summary, err
	}
	if err := commit(""); err != nil {
		return summary, err
	}
	return summary, nil
}

func skipDirectory(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	return skipDirectories[name]
}

func skipFile(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	lower := strings.ToLower(name)
	return lower == "thumbs.db" || lower == "desktop.ini"
}

func insert(tx *sql.Tx, path, rel string, info os.FileInfo) error {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(rel), "."))
	class, policy := mediaClass(ext)
	width, height, hasSize := thumb.Dimensions(path)
	var w, h, pixels any
	if hasSize {
		w = width
		h = height
		pixels = int64(width) * int64(height)
	}
	uid, err := newUID()
	if err != nil {
		return err
	}
	var fp []byte
	if sum, err := relink.FingerprintFile(path); err == nil {
		fp = sum
	}
	now := time.Now().UTC().Format(time.RFC3339)
	_, err = tx.Exec(`
		INSERT INTO assets (
			uid, rel_path, byte_size, mtime_ns, ext, media_class, reorg_policy,
			width, height, native_pixels, fast_fp, phase, discovered_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'discovered', ?, ?)
		ON CONFLICT(rel_path) DO UPDATE SET
			ext = excluded.ext,
			media_class = excluded.media_class,
			reorg_policy = excluded.reorg_policy,
			updated_at = excluded.updated_at
		WHERE assets.reorg_policy = 'leave'
			AND excluded.media_class = 'video'
			AND excluded.reorg_policy = 'move'`,
		uid, rel, info.Size(), info.ModTime().UnixNano(), ext, class, policy,
		w, h, pixels, fp, now, now)
	return err
}

func newUID() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}

func mediaClass(ext string) (class, policy string) {
	switch ext {
	case "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif":
		return "image", "move"
	case "raf", "arw", "dng", "cr2", "cr3", "nef", "nrw", "orf", "rw2", "pef", "srw", "erf", "raw", "rwl", "3fr", "fff", "iiq", "mos", "sr2", "x3f":
		return "raw", "move"
	case "mov", "mp4", "m4v", "m4p", "avi", "mkv", "mpg", "mpeg", "mpe", "m2v", "wmv", "flv", "webm", "3gp", "3g2", "mts", "m2ts", "ts", "vob", "ogv", "asf", "divx":
		return "video", "move"
	case "pdf":
		return "pdf", "leave"
	default:
		return "other", "leave"
	}
}
