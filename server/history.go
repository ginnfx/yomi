package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const (
	defaultHistoryDir  = "/data/local/tmp/navidrome/yomi-history"
	historyMaxField    = 400
	historyMaxBatch    = 500
	historyMaxLimit    = 2000
	historyDefaultPage = 1000
	historyMaxBody     = 1 << 20
	importedMaxBody    = 16 << 20
	historyMaxLine     = 8 << 10
	historyOldestYear  = 2000
	historyFutureSlack = 48 * time.Hour
	historyMinFree     = 20 << 20
)

// HistoryEvent is one play, carrying the song's names so stats still make sense after the
// song has left the library.
type HistoryEvent struct {
	ID      string `json:"id"`
	SongID  string `json:"songId"`
	Artist  string `json:"artist,omitempty"`
	Title   string `json:"title,omitempty"`
	Album   string `json:"album,omitempty"`
	Genre   string `json:"genre,omitempty"`
	AtMs    int64  `json:"atMs"`
	Kind    string `json:"kind"`
	Seconds int    `json:"seconds,omitempty"`
}

func (e HistoryEvent) isValid(now time.Time) bool {
	if e.ID == "" || e.SongID == "" || (e.Kind != "completed" && e.Kind != "skipped") {
		return false
	}
	for _, field := range []string{e.ID, e.SongID, e.Artist, e.Title, e.Album, e.Genre} {
		if len(field) > historyMaxField {
			return false
		}
	}
	at := time.UnixMilli(e.AtMs)
	return at.Year() >= historyOldestYear && at.Before(now.Add(historyFutureSlack)) && e.Seconds >= 0
}

// HistoryStore keeps each person's plays in an append-only log and never holds them in
// memory. A reader's position is a byte offset, so it can't miss a play uploaded late.
type HistoryStore struct {
	mu  sync.Mutex
	dir string
	now func() time.Time
}

func openHistoryStore(dir string) (*HistoryStore, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &HistoryStore{dir: dir, now: time.Now}, nil
}

func (h *HistoryStore) logFile(user string) string {
	return filepath.Join(h.dir, "plays-"+user+".jsonl")
}

func (h *HistoryStore) importedFile(user string) string {
	return filepath.Join(h.dir, "imported-"+user+".json")
}

// knownIDs reads the IDs already saved. A log grows by about a megabyte a year.
func (h *HistoryStore) knownIDs(user string) (map[string]bool, error) {
	known := map[string]bool{}
	file, err := os.Open(h.logFile(user))
	if errors.Is(err, os.ErrNotExist) {
		return known, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, historyMaxLine), historyMaxLine)
	for scanner.Scan() {
		var line struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(scanner.Bytes(), &line) == nil && line.ID != "" {
			known[line.ID] = true
		}
	}
	return known, scanner.Err()
}

// Add saves new plays and returns how many there were. Sending the same one twice is safe.
func (h *HistoryStore) Add(user string, events []HistoryEvent) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	known, err := h.knownIDs(user)
	if err != nil {
		return 0, err
	}
	now := h.now()
	var lines bytes.Buffer
	added := 0
	for _, event := range events {
		if known[event.ID] || !event.isValid(now) {
			continue
		}
		known[event.ID] = true
		line, err := json.Marshal(event)
		if err != nil {
			return 0, err
		}
		lines.Write(line)
		lines.WriteByte('\n')
		added++
	}
	if added == 0 {
		return 0, nil
	}
	if !hasFreeSpace(h.dir, historyMinFree) {
		return 0, errors.New("the server is out of space")
	}
	file, err := os.OpenFile(h.logFile(user), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, err
	}
	defer file.Close()
	if _, err := file.Write(lines.Bytes()); err != nil {
		return 0, err
	}
	return added, file.Sync()
}

// Read returns up to limit plays from a position, and the position to continue from.
func (h *HistoryStore) Read(user string, after int64, limit int) ([]HistoryEvent, int64, error) {
	file, err := os.Open(h.logFile(user))
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, nil
	}
	if err != nil {
		return nil, after, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, after, err
	}
	// A position past the end means this log isn't the one it came from, so start over.
	if after < 0 || after > info.Size() {
		after = 0
	}
	if _, err := file.Seek(after, io.SeekStart); err != nil {
		return nil, after, err
	}
	reader := bufio.NewReader(file)
	position := after
	events := []HistoryEvent{}
	for len(events) < limit {
		line, err := reader.ReadBytes('\n')
		if errors.Is(err, io.EOF) {
			break // Anything without a line ending is still being written.
		}
		if err != nil {
			return nil, after, err
		}
		position += int64(len(line))
		var event HistoryEvent
		if json.Unmarshal(line, &event) == nil && event.ID != "" {
			events = append(events, event)
		}
	}
	return events, position, nil
}

// SaveImported replaces this person's imported totals. The app works these out from the
// whole export each time, so replacing can't double-count.
func (h *HistoryStore) SaveImported(user string, data []byte) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !hasFreeSpace(h.dir, historyMinFree+int64(len(data))) {
		return errors.New("the server is out of space")
	}
	path := h.importedFile(user)
	temp := path + ".tmp"
	if err := os.WriteFile(temp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

// Imported returns the saved totals, or an empty object when there are none.
func (h *HistoryStore) Imported(user string) ([]byte, error) {
	data, err := os.ReadFile(h.importedFile(user))
	if errors.Is(err, os.ErrNotExist) {
		return []byte("{}"), nil
	}
	return data, err
}

func (s *Server) historyUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	if s.History == nil {
		writeError(w, http.StatusServiceUnavailable, "listening history isn't available on this server")
		return "", false
	}
	user, ok := s.authenticate(w, r)
	if !ok {
		return "", false
	}
	safe, err := sanitizeUser(user)
	if err != nil {
		writeError(w, http.StatusBadRequest, "this account's name can't be used for history")
		return "", false
	}
	return safe, true
}

func (s *Server) handleAddHistory(w http.ResponseWriter, r *http.Request) {
	user, ok := s.historyUser(w, r)
	if !ok {
		return
	}
	if s.isReplica() {
		writeError(w, http.StatusServiceUnavailable, "plays wait until the main server is back")
		return
	}
	var request struct {
		Events []HistoryEvent `json:"events"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, historyMaxBody)
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "send valid JSON")
		return
	}
	if len(request.Events) > historyMaxBatch {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("send at most %d plays at a time", historyMaxBatch))
		return
	}
	added, err := s.History.Add(user, request.Events)
	if err != nil {
		log.Printf("save history: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't save your plays")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"added": added})
}

func (s *Server) handleReadHistory(w http.ResponseWriter, r *http.Request) {
	user, ok := s.historyUser(w, r)
	if !ok {
		return
	}
	query := r.URL.Query()
	after, _ := strconv.ParseInt(query.Get("after"), 10, 64)
	limit, err := strconv.Atoi(query.Get("limit"))
	if err != nil || limit <= 0 {
		limit = historyDefaultPage
	}
	events, next, err := s.History.Read(user, after, min(limit, historyMaxLimit))
	if err != nil {
		log.Printf("read history: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't read your plays")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": events, "next": next})
}

func (s *Server) handleSaveImported(w http.ResponseWriter, r *http.Request) {
	user, ok := s.historyUser(w, r)
	if !ok {
		return
	}
	if s.isReplica() {
		writeError(w, http.StatusServiceUnavailable, "this can't be saved on the backup server")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, importedMaxBody)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "that's too large")
		return
	}
	if !json.Valid(data) {
		writeError(w, http.StatusBadRequest, "send valid JSON")
		return
	}
	if err := s.History.SaveImported(user, data); err != nil {
		log.Printf("save imported history: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't save your history")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleReadImported(w http.ResponseWriter, r *http.Request) {
	user, ok := s.historyUser(w, r)
	if !ok {
		return
	}
	data, err := s.History.Imported(user)
	if err != nil {
		log.Printf("read imported history: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't read your history")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if _, err := w.Write(data); err != nil {
		log.Printf("write imported history: %v", err)
	}
}

// hasFreeSpace checks room on the phone's internal storage. If it can't tell, the write goes
// ahead, and a real failure is still reported.
func hasFreeSpace(dir string, needed int64) bool {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(dir, &stat); err != nil {
		log.Printf("free space check failed: %v", err)
		return true
	}
	return stat.Bavail*uint64(stat.Bsize) >= uint64(needed)
}
