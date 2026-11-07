package httpapi

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
)

// EnsureToken reads .zimage/auth.token or writes 32 random bytes as base64url.
// The pairing file is written once, mode 0600, and claim deletes it.
func EnsureToken(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return "", err
	}
	tokenPath := filepath.Join(dir, "auth.token")
	if b, err := os.ReadFile(tokenPath); err == nil {
		token := strings.TrimSpace(string(b))
		if token != "" {
			return token, nil
		}
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(buf)
	if err := writeSecret(tokenPath, token); err != nil {
		return "", err
	}
	pairing := filepath.Join(dir, "PAIRING-TOKEN")
	if _, err := os.Stat(pairing); os.IsNotExist(err) {
		if err := writeSecret(pairing, token); err != nil {
			return "", err
		}
	}
	return token, nil
}

func writeSecret(path, token string) error {
	if err := os.WriteFile(path, []byte(token+"\n"), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func tokensEqual(got, want string) bool {
	if want == "" || got == "" {
		subtle.ConstantTimeCompare([]byte(got), []byte(got))
		return false
	}
	gb := []byte(got)
	wb := []byte(want)
	if len(gb) != len(wb) {
		dummy := make([]byte, len(gb))
		subtle.ConstantTimeCompare(gb, dummy)
		return false
	}
	return subtle.ConstantTimeCompare(gb, wb) == 1
}

func bearerToken(header string) string {
	header = strings.TrimSpace(header)
	const prefix = "Bearer "
	if len(header) < len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(header[len(prefix):])
}
