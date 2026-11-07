package httpapi

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"zimage/helper/internal/events"
	"zimage/helper/internal/pathsafe"
)

// zimgMagic is the ZImage RAW envelope. The helper stores the rest as opaque bytes.
var zimgMagic = []byte{0x5A, 0x49, 0x4D, 0x47, 0x52, 0x41, 0x57, 0x01}

const defaultMaxEditBytes int64 = 256 << 20

var errEditRejected = errors.New("edit rejected")

func (s *Server) editLimit() int64 {
	if s.MaxEditBytes > 0 {
		return s.MaxEditBytes
	}
	return defaultMaxEditBytes
}

func (s *Server) edits(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPut:
		s.putEdit(w, r)
	case http.MethodGet:
		s.getEdit(w, r)
	default:
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
	}
}

func (s *Server) putEdit(w http.ResponseWriter, r *http.Request) {
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	uid := r.PathValue("uid")
	if !plainUID(uid) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	var id int64
	err := s.Catalog.Read.QueryRow(`SELECT id FROM assets WHERE uid = ?`, uid).Scan(&id)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	rel := ".zimage/edits/" + uid + ".zimg"
	if err := pathsafe.Jail(s.Root, rel); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "path"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, s.editLimit())
	if err := storeEdit(s.Root, rel, r.Body); err != nil {
		if isMaxBytes(err) {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "too_large"})
			return
		}
		if errors.Is(err, errEditRejected) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "edit"})
		return
	}
	now := s.now().UTC().Format(time.RFC3339)
	if _, err := s.Catalog.Write.Exec(`UPDATE assets SET edit_rel = ?, updated_at = ? WHERE id = ?`, rel, now, id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) getEdit(w http.ResponseWriter, r *http.Request) {
	uid := r.PathValue("uid")
	if !plainUID(uid) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	rel := ".zimage/edits/" + uid + ".zimg"
	if err := pathsafe.Jail(s.Root, rel); err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	f, err := os.Open(filepath.Join(s.Root, filepath.FromSlash(rel)))
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = io.Copy(w, f)
}

func (s *Server) eventRename(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method"})
		return
	}
	if s.Catalog == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "library_unavailable"})
		return
	}
	uid := r.PathValue("uid")
	if !plainUID(uid) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body"})
		return
	}
	if err := events.Rename(s.Catalog, uid, body.Name); err != nil {
		if errors.Is(err, events.ErrNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		if errors.Is(err, events.ErrName) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return
	}
	item, ok := s.loadEvent(w, uid)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (s *Server) loadEvent(w http.ResponseWriter, uid string) (eventRow, bool) {
	var item eventRow
	var start, end, folder sql.NullString
	var lat, lon sql.NullFloat64
	err := s.Catalog.Read.QueryRow(`
		SELECT uid, name, name_source, start_time, end_time, slug, folder_rel, gps_lat, gps_lon
		FROM events WHERE uid = ?`, uid).Scan(
		&item.UID, &item.Name, &item.NameSource, &start, &end, &item.Slug, &folder, &lat, &lon)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog"})
		return eventRow{}, false
	}
	if start.Valid {
		item.StartTime = &start.String
	}
	if end.Valid {
		item.EndTime = &end.String
	}
	if folder.Valid {
		item.FolderRel = &folder.String
	}
	if lat.Valid {
		item.GPSLat = &lat.Float64
	}
	if lon.Valid {
		item.GPSLon = &lon.Float64
	}
	return item, true
}

type eventRow struct {
	UID        string   `json:"uid"`
	Name       string   `json:"name"`
	NameSource string   `json:"nameSource"`
	StartTime  *string  `json:"startTime"`
	EndTime    *string  `json:"endTime"`
	Slug       string   `json:"slug"`
	FolderRel  *string  `json:"folderRel"`
	GPSLat     *float64 `json:"gpsLat"`
	GPSLon     *float64 `json:"gpsLon"`
}

func storeEdit(root, rel string, src io.Reader) error {
	final := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(final), 0o750); err != nil {
		return err
	}
	tmp := final + ".partial"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	stored := false
	defer func() {
		if !stored {
			_ = os.Remove(tmp)
		}
	}()
	var magic [8]byte
	if _, err := io.ReadFull(src, magic[:]); err != nil {
		_ = f.Close()
		if isMaxBytes(err) {
			return err
		}
		return errEditRejected
	}
	if !bytes.Equal(magic[:], zimgMagic) {
		_ = f.Close()
		return errEditRejected
	}
	if _, err := f.Write(magic[:]); err != nil {
		_ = f.Close()
		return err
	}
	if _, err := io.Copy(f, src); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, final); err != nil {
		return err
	}
	stored = true
	if dir, err := os.Open(filepath.Dir(final)); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return nil
}

func isMaxBytes(err error) bool {
	var max *http.MaxBytesError
	return errors.As(err, &max)
}
