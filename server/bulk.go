package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/dhowden/tag"
)

const (
	maxCheckHashes     = 1000
	maxCheckBodyBytes  = 128 << 10
	retryAfterSeconds  = "5"
	minFreeBytes       = 100 << 20
	uploadStallTimeout = 60 * time.Second
)

// authenticate verifies credentials, writing the error response when they fail.
func (s *Server) authenticate(w http.ResponseWriter, r *http.Request) (string, bool) {
	query := r.URL.Query()
	if recent, ok := s.Auth.(interface {
		RecentlyVerified(url.Values) (string, bool)
	}); ok {
		if user, verified := recent.RecentlyVerified(query); verified {
			return user, true
		}
	}
	if s.limits.Blocked(query.Get("u")) {
		writeError(w, http.StatusTooManyRequests, "too many wrong passwords, try again in a few minutes")
		return "", false
	}
	user, err := s.Auth.Verify(r.Context(), query)
	switch {
	case errors.Is(err, errUnauthorized):
		s.limits.Fail(query.Get("u"))
		writeError(w, http.StatusUnauthorized, err.Error())
		return "", false
	case err != nil:
		log.Printf("auth backend error: %v", err)
		writeError(w, http.StatusBadGateway, "music server unavailable")
		return "", false
	}
	return user, true
}

// handleCheck reports which of the given hashes the server already has.
func (s *Server) handleCheck(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authenticate(w, r); !ok {
		return
	}
	var request struct {
		Hashes []string `json:"hashes"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxCheckBodyBytes)
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil || len(request.Hashes) > maxCheckHashes {
		writeError(w, http.StatusBadRequest, "send up to 1000 hashes as JSON")
		return
	}
	known := make([]string, 0)
	for _, hash := range request.Hashes {
		if !isSHA256(hash) {
			writeError(w, http.StatusBadRequest, "hashes must be lowercase SHA-256")
			return
		}
		if _, found := s.Index.Lookup(hash); found {
			known = append(known, hash)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"known": known, "seeding": s.Index.Seeding()})
}

// handleBulkUpload stores a file whose hash the client already computed. It is
// idempotent: uploading content the server has returns the existing file and stores nothing.
func (s *Server) handleBulkUpload(w http.ResponseWriter, r *http.Request) {
	if s.isReplica() {
		writeError(w, http.StatusForbidden, errReadOnly.Error())
		return
	}
	hash := r.PathValue("sha256")
	if !isSHA256(hash) {
		writeError(w, http.StatusBadRequest, "hash must be lowercase SHA-256")
		return
	}
	user, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if entry, found := s.Index.Lookup(hash); found {
		writeDuplicate(w, entry)
		return
	}
	if r.ContentLength <= 0 {
		writeError(w, http.StatusLengthRequired, "send a Content-Length")
		return
	}
	if r.ContentLength > s.Config.MaxFileBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "file is too large")
		return
	}
	if !s.hasRoomFor(r.ContentLength) {
		writeError(w, http.StatusInsufficientStorage, "the server's storage is full")
		return
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		w.Header().Set("Retry-After", retryAfterSeconds)
		writeError(w, http.StatusTooManyRequests, "too many uploads in progress, try again shortly")
		return
	}
	body := &stallGuard{reader: r.Body, controller: http.NewResponseController(w), timeout: uploadStallTimeout}
	stored, status, err := s.storeVerified(user, hash, r.URL.Query().Get("name"), http.MaxBytesReader(w, io.NopCloser(body), s.Config.MaxFileBytes))
	if err != nil {
		code, message := classifySaveError(err)
		if status != 0 {
			code, message = status, err.Error()
		}
		writeError(w, code, message)
		return
	}
	if stored.isDuplicate {
		writeDuplicate(w, stored.entry)
		return
	}
	log.Printf("stored %s for %s", stored.entry.Path, user)
	s.scans.Touch(r.URL.Query())
	writeJSON(w, http.StatusCreated, map[string]string{"status": "ok", "file": stored.entry.Path})
}

func writeDuplicate(w http.ResponseWriter, entry indexEntry) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "duplicate", "file": entry.Path})
}

// hasRoomFor checks free space, leaving a margin so the card never fills completely.
// If the size can't be read the upload goes ahead; a write failure still reports properly.
func (s *Server) hasRoomFor(size int64) bool {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(s.Config.MusicDir, &stat); err != nil {
		log.Printf("free space check failed: %v", err)
		return true
	}
	free := stat.Bavail * uint64(stat.Bsize)
	return free >= uint64(size)+minFreeBytes
}

type storedFile struct {
	entry       indexEntry
	isDuplicate bool
}

var errHashMismatch = errors.New("the file changed in transit, it will be sent again")

// storeVerified writes the upload to a temp file, checks its hash and type, then
// publishes it under <user>/<Artist>/<Album>/ using the file's own tags.
func (s *Server) storeVerified(user, hash, name string, body io.Reader) (storedFile, int, error) {
	safeUser, err := sanitizeUser(user)
	if err != nil {
		return storedFile{}, 0, err
	}
	safeName, err := sanitizeName(name)
	if err != nil {
		return storedFile{}, 0, err
	}
	userDir := filepath.Join(s.Config.MusicDir, safeUser)
	if err := os.MkdirAll(userDir, 0o777); err != nil {
		return storedFile{}, 0, err
	}
	tmp, err := os.CreateTemp(userDir, tempFilePrefix+"*"+tempFileSuffix)
	if err != nil {
		return storedFile{}, 0, err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	hasher := sha256.New()
	size, err := io.Copy(io.MultiWriter(tmp, hasher), body)
	if err != nil {
		tmp.Close()
		return storedFile{}, 0, err
	}
	if hex.EncodeToString(hasher.Sum(nil)) != hash {
		tmp.Close()
		return storedFile{}, http.StatusUnprocessableEntity, errHashMismatch
	}
	artist, album, err := readAudioInfo(tmp, strings.ToLower(filepath.Ext(safeName)))
	if closeErr := tmp.Close(); closeErr != nil {
		return storedFile{}, 0, closeErr
	}
	if err != nil {
		return storedFile{}, 0, err
	}
	if err := os.Chmod(tmpPath, 0o666); err != nil && !errors.Is(err, syscall.EPERM) && !errors.Is(err, syscall.EOPNOTSUPP) {
		return storedFile{}, 0, err
	}
	s.publishMu.Lock()
	defer s.publishMu.Unlock()
	// Two people can send the same song at once; only the first one is kept.
	if entry, found := s.Index.Lookup(hash); found {
		return storedFile{entry: entry, isDuplicate: true}, 0, nil
	}
	dir, relative, err := resolveAlbumDir(userDir, safeUser, artist, album)
	if err != nil {
		return storedFile{}, 0, err
	}
	published, err := linkUnique(tmpPath, dir, safeName, relative)
	if err != nil {
		return storedFile{}, 0, err
	}
	entry := indexEntry{SHA256: hash, Path: published, Size: size}
	if err := s.Index.Add(entry); err != nil {
		// The song is safely stored; the next seed adds it to the index.
		log.Printf("index: could not record %s: %v", published, err)
	}
	return storedFile{entry: entry}, 0, nil
}

// readAudioInfo verifies the file really is audio and returns its artist and album,
// which are empty for untagged files.
func readAudioInfo(file *os.File, ext string) (string, string, error) {
	header := make([]byte, headerSniffBytes)
	n, err := file.ReadAt(header, 0)
	if err != nil && !errors.Is(err, io.EOF) {
		return "", "", err
	}
	if !looksLikeAudio(header[:n], ext) {
		return "", "", errNotAudio
	}
	artist, album := readTags(file)
	return artist, album, nil
}

// readTags treats anything unreadable as untagged. A malformed tag can make the parser
// panic, and a bad tag must never cost a song or a server.
func readTags(file *os.File) (artist, album string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			log.Printf("could not parse tags: %v", recovered)
			artist, album = "", ""
		}
	}()
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", ""
	}
	metadata, err := tag.ReadFrom(file)
	if err != nil {
		return "", ""
	}
	artist = metadata.AlbumArtist()
	if strings.TrimSpace(artist) == "" {
		artist = metadata.Artist()
	}
	return artist, metadata.Album()
}

// resolveAlbumDir creates the folders for a song and returns the directory plus its
// path relative to the music folder. Untagged songs go directly in the user's folder.
func resolveAlbumDir(userDir, safeUser, artist, album string) (string, string, error) {
	folder, relative := userDir, safeUser
	for _, part := range []string{sanitizeFolder(artist), sanitizeFolder(album)} {
		if part == "" {
			return userDir, safeUser, nil
		}
		existing, err := matchExistingFolder(folder, part)
		if err != nil {
			return "", "", err
		}
		folder = filepath.Join(folder, existing)
		relative = filepath.Join(relative, existing)
	}
	if err := os.MkdirAll(folder, 0o777); err != nil {
		return "", "", err
	}
	return folder, relative, nil
}

// matchExistingFolder reuses a folder differing only by case, since FAT32 treats
// "Beatles" and "beatles" as the same place.
func matchExistingFolder(parent, name string) (string, error) {
	entries, err := os.ReadDir(parent)
	if errors.Is(err, os.ErrNotExist) {
		return name, nil
	}
	if err != nil {
		return "", err
	}
	for _, entry := range entries {
		if entry.IsDir() && strings.EqualFold(entry.Name(), name) {
			return entry.Name(), nil
		}
	}
	return name, nil
}

// stallGuard extends the read deadline with each chunk, so a dead connection frees its
// upload slot without limiting how long a slow, healthy upload may take.
type stallGuard struct {
	reader     io.Reader
	controller *http.ResponseController
	timeout    time.Duration
}

func (g *stallGuard) Read(p []byte) (int, error) {
	if err := g.controller.SetReadDeadline(time.Now().Add(g.timeout)); err != nil && !errors.Is(err, http.ErrNotSupported) {
		return 0, err
	}
	return g.reader.Read(p)
}
