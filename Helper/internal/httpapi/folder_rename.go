package httpapi

import (
	"errors"
	"net/http"

	"zimage/helper/internal/inventory"
)

type folderRenameBody struct {
	From string `json:"from"`
	To   string `json:"to"`
}

func (s *Server) renameFolder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	var body folderRenameBody
	if err := readSmallJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
		return
	}
	renamed, err := inventory.RenameFolder(s.Root, s.Catalog, body.From, body.To)
	if err == nil {
		writeJSON(w, http.StatusOK, map[string]int{"renamed": renamed})
		return
	}
	switch {
	case errors.Is(err, inventory.ErrRenamePrefix):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prefix"})
	case errors.Is(err, inventory.ErrRenameKept):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "kept"})
	case errors.Is(err, inventory.ErrRenameMissing):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "missing"})
	case errors.Is(err, inventory.ErrRenameTaken):
		writeJSON(w, http.StatusConflict, map[string]string{"error": "taken"})
	case errors.Is(err, inventory.ErrRenameBusy):
		writeJSON(w, http.StatusConflict, map[string]string{"error": "busy"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
	}
}
