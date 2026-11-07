// Package config reads the helper's YAML settings.
// The parser accepts the example file's key: value lines and # comments.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config is the NAS helper's startup file.
type Config struct {
	Listen              string
	LibraryRoot         string
	ScopeRelative       string
	CacheOperatingBytes int64
	CacheHardBytes      int64
	// AllowLoopback is for tests. Production leaves it false so a guest
	// on a public address is rejected, and so is 127.0.0.1.
	AllowLoopback bool
}

// Load reads a config file.
func Load(path string) (Config, error) {
	text, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	return Parse(string(text))
}

// Parse reads key: value lines. A value may be quoted. A # starts a comment.
func Parse(text string) (Config, error) {
	cfg := Config{
		Listen:              "0.0.0.0:8742",
		ScopeRelative:       "Photos",
		CacheOperatingBytes: 200_000_000_000,
		CacheHardBytes:      1_000_000_000_000,
	}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(strings.TrimRight(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.Index(line, " #"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		key, val, ok := strings.Cut(line, ":")
		if !ok {
			return Config{}, fmt.Errorf("bad config line")
		}
		key = strings.TrimSpace(key)
		val = strings.Trim(strings.TrimSpace(val), `"'`)
		switch key {
		case "listen":
			cfg.Listen = val
		case "library_root_local":
			cfg.LibraryRoot = val
		case "scope_relative":
			cfg.ScopeRelative = val
		case "cache_operating_bytes":
			n, err := strconv.ParseInt(val, 10, 64)
			if err != nil {
				return Config{}, err
			}
			cfg.CacheOperatingBytes = n
		case "cache_hard_bytes":
			n, err := strconv.ParseInt(val, 10, 64)
			if err != nil {
				return Config{}, err
			}
			cfg.CacheHardBytes = n
		case "allow_loopback":
			cfg.AllowLoopback = val == "true"
		default:
			return Config{}, fmt.Errorf("unknown config key %s", key)
		}
	}
	if cfg.LibraryRoot == "" {
		return Config{}, fmt.Errorf("library_root_local is required")
	}
	if cfg.Listen == "" {
		return Config{}, fmt.Errorf("listen is required")
	}
	return cfg, nil
}
