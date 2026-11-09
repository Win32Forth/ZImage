package httpapi

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
)

type focusBody struct {
	Prefix string `json:"prefix"`
}

func (s *Server) focus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, focusBody{Prefix: s.Focus()})
		return
	}
	var body focusBody
	dec := json.NewDecoder(io.LimitReader(r.Body, 4096))
	if err := dec.Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	prefix, ok := cleanFocus(body.Prefix)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	s.SetFocus(prefix)
	writeJSON(w, http.StatusOK, focusBody{Prefix: prefix})
}

// cleanFocus accepts an empty prefix, Photos, or a path under Photos.
// Photos/_Duplicates is allowed. A ".." segment is refused.
func cleanFocus(prefix string) (string, bool) {
	prefix = strings.TrimSpace(prefix)
	if prefix == "" {
		return "", true
	}
	prefix = strings.Trim(prefix, "/")
	if prefix == "" || strings.Contains(prefix, "\\") {
		return "", false
	}
	parts := strings.Split(prefix, "/")
	if parts[0] != "Photos" {
		return "", false
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return "", false
		}
	}
	return prefix, true
}
