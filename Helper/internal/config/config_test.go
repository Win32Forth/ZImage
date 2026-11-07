package config_test

import (
	"os"
	"path/filepath"
	"testing"

	"zimage/helper/internal/config"
)

func TestExampleConfig(t *testing.T) {
	cfg, err := config.Load(filepath.Join("..", "..", "config.example.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Listen != "0.0.0.0:8742" {
		t.Fatalf("listen %q", cfg.Listen)
	}
	if cfg.LibraryRoot != "/volume1/BackupData/PhotoVideoAudio" {
		t.Fatalf("root %q", cfg.LibraryRoot)
	}
	if cfg.ScopeRelative != "Photos" {
		t.Fatalf("scope %q", cfg.ScopeRelative)
	}
	if cfg.AllowLoopback {
		t.Fatal("example config must leave loopback off")
	}
	if cfg.CacheOperatingBytes != 200_000_000_000 || cfg.CacheHardBytes != 1_000_000_000_000 {
		t.Fatalf("cache %d %d", cfg.CacheOperatingBytes, cfg.CacheHardBytes)
	}
}

func TestPhotosWritable(t *testing.T) {
	root := t.TempDir()
	if config.PhotosWritable(root) {
		t.Fatal("missing Photos was writable")
	}
	if err := os.Mkdir(filepath.Join(root, "Photos"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !config.PhotosWritable(root) {
		t.Fatal("Photos was not writable")
	}
	entries, err := os.ReadDir(filepath.Join(root, "Photos"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("writecheck file left behind: %v", entries)
	}
}
