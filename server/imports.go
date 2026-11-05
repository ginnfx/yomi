package main

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

const (
	importMaxIDLength = 64
	importMaxBody     = 4 << 20
)

var importIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// An imported playlist is stored as whatever the app sent, once checked to be JSON. It's the
// source of truth for order, because a Navidrome playlist can't hold songs not in the library.
func (h *HistoryStore) importsDir(user string) string {
	return filepath.Join(h.dir, "imports-"+user)
}

// SaveImport writes one imported playlist.
func (h *HistoryStore) SaveImport(user, id string, data []byte) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !hasFreeSpace(h.dir, historyMinFree+int64(len(data))) {
		return errors.New("the server is out of space")
	}
	dir := h.importsDir(user)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(dir, id+".json")
	temp := path + ".tmp"
	if err := os.WriteFile(temp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

// DeleteImport removes one imported playlist. Removing one that's already gone is fine.
func (h *HistoryStore) DeleteImport(user, id string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	err := os.Remove(filepath.Join(h.importsDir(user), id+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// Imports returns every imported playlist, in a stable order.
func (h *HistoryStore) Imports(user string) ([]json.RawMessage, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	names, err := filepath.Glob(filepath.Join(h.importsDir(user), "*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	imports := make([]json.RawMessage, 0, len(names))
	for _, name := range names {
		data, err := os.ReadFile(name)
		if err != nil {
			return nil, err
		}
		imports = append(imports, data)
	}
	return imports, nil
}

func validImportID(id string) bool {
	return len(id) <= importMaxIDLength && importIDPattern.MatchString(id)
}

func (s *Server) handleSaveImport(w http.ResponseWriter, r *http.Request) {
	user, ok := s.historyUser(w, r)
	if !ok {
		return
	}
	if s.isReplica() {
		writeError(w, http.StatusServiceUnavailable, "this can't be saved on the backup server")
		return
	}
	id := r.PathValue("id")
	if !validImportID(id) {
		writeError(w, http.StatusBadRequest, "that isn't a valid playlist ID")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, importMaxBody)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "that playlist is too large")
		return
	}
	if !json.Valid(data) {
		writeError(w, http.StatusBadRequest, "send valid JSON")
		return
	}
	if err := s.History.SaveImport(user, id, data); err != nil {
		log.Printf("save import: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't save that playlist")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleDeleteImport(w http.ResponseWriter, r *http.Request) {
	user, ok := s.historyUser(w, r)
	if !ok {
		return
	}
	if s.isReplica() {
		writeError(w, http.StatusServiceUnavailable, "this can't be changed on the backup server")
		return
	}
	id := r.PathValue("id")
	if !validImportID(id) {
		writeError(w, http.StatusBadRequest, "that isn't a valid playlist ID")
		return
	}
	if err := s.History.DeleteImport(user, id); err != nil {
		log.Printf("delete import: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't delete that playlist")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleListImports(w http.ResponseWriter, r *http.Request) {
	user, ok := s.historyUser(w, r)
	if !ok {
		return
	}
	imports, err := s.History.Imports(user)
	if err != nil {
		log.Printf("list imports: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't read your playlists")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"imports": imports})
}
