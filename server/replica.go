package main

import (
	"bytes"
	"context"
	"crypto/md5" //nolint:gosec // The Subsonic API defines its token this way.
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	roleReplica         = "replica"
	replicaSyncEvery    = 15 * time.Minute
	backupCacheFor      = 15 * time.Minute
	backupCommandWait   = 5 * time.Minute
	replicaApplyWait    = 2 * time.Minute
	replicaRequestWait  = 30 * time.Minute
	sqliteHeader        = "SQLite format 3\x00"
	maxReplicaIndexSize = 64 << 20
)

var errReadOnly = errors.New("this is the backup server, uploads go to the main one")

// ------- Primary: what a replica may fetch. Everything here needs an admin login. -------

func (s *Server) requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	if _, ok := s.authenticate(w, r); !ok {
		return false
	}
	if !s.isAdmin(r.Context(), r.URL.Query()) {
		writeError(w, http.StatusForbidden, "admin login required")
		return false
	}
	return true
}

func (s *Server) handleReplicaIndex(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	s.Index.Seed()
	entries := s.Index.Entries()
	sort.Slice(entries, func(a, b int) bool { return entries[a].Path < entries[b].Path })
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "seeding": s.Index.Seeding()})
}

func (s *Server) handleReplicaFile(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	entry, found := s.Index.Lookup(r.PathValue("sha256"))
	if !found {
		writeError(w, http.StatusNotFound, "no such file")
		return
	}
	http.ServeFile(w, r, filepath.Join(s.Config.MusicDir, entry.Path))
}

// handleReplicaDatabase serves a consistent copy of Navidrome's database. The live file
// can't simply be read, because SQLite may be mid-write.
func (s *Server) handleReplicaDatabase(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	if s.Backups == nil {
		writeError(w, http.StatusNotImplemented, "database copies are not set up on this server")
		return
	}
	path, err := s.Backups.Latest(r.Context())
	if err != nil {
		log.Printf("replica: backup failed: %v", err)
		writeError(w, http.StatusInternalServerError, "could not copy the database")
		return
	}
	info, err := os.Stat(path)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read the database copy")
		return
	}
	w.Header().Set("ETag", fmt.Sprintf(`"%d-%d"`, info.ModTime().UnixMilli(), info.Size()))
	http.ServeFile(w, r, path)
}

// BackupSource makes database copies with Navidrome's own backup command, at most once per
// cache period so several requests can't stack up work on the phone.
type BackupSource struct {
	Dir     string
	Create  func(context.Context) error
	Now     func() time.Time
	mu      sync.Mutex
	made    time.Time
	current string
}

func newBackupSource(cfg Config) *BackupSource {
	if cfg.BackupCommand == "" || cfg.BackupDir == "" {
		return nil
	}
	return &BackupSource{
		Dir: cfg.BackupDir,
		Now: time.Now,
		Create: func(ctx context.Context) error {
			ctx, cancel := context.WithTimeout(ctx, backupCommandWait)
			defer cancel()
			output, err := exec.CommandContext(ctx, "/system/bin/sh", "-c", cfg.BackupCommand).CombinedOutput()
			if err != nil {
				return fmt.Errorf("%w: %s", err, bytes.TrimSpace(output))
			}
			return nil
		},
	}
}

// Latest returns the newest copy, making one if the last is out of date.
func (b *BackupSource) Latest(ctx context.Context) (string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.current != "" && b.Now().Sub(b.made) < backupCacheFor {
		return b.current, nil
	}
	if err := b.Create(ctx); err != nil {
		return "", err
	}
	entries, err := os.ReadDir(b.Dir)
	if err != nil {
		return "", err
	}
	var newest string
	var newestTime time.Time
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil || entry.IsDir() || !strings.HasSuffix(entry.Name(), ".db") {
			continue
		}
		if info.ModTime().After(newestTime) {
			newest, newestTime = filepath.Join(b.Dir, entry.Name()), info.ModTime()
		}
	}
	if newest == "" {
		return "", errors.New("backup command left no .db file")
	}
	b.current, b.made = newest, b.Now()
	return newest, nil
}

// ------- Replica: pulls from the primary. It never writes to the primary. -------

// ReplicaSync keeps a second server current. Files always arrive before the database that
// refers to them, so the replica never lists a song it can't play.
type ReplicaSync struct {
	PrimaryURL   string
	Login        url.Values
	Root         string
	Index        *HashIndex
	DatabaseFile string
	State        *StateSync
	Apply        func(context.Context) error
	Client       *http.Client
	HasRoomFor   func(int64) bool
	databaseTag  string
}

func newReplicaSync(cfg Config, index *HashIndex) *ReplicaSync {
	return &ReplicaSync{
		PrimaryURL:   strings.TrimRight(cfg.PrimaryURL, "/"),
		Login:        tokenLogin(cfg.ReplicaUser, cfg.ReplicaPassword),
		Root:         cfg.MusicDir,
		Index:        index,
		DatabaseFile: cfg.ReplicaDatabase,
		Client:       &http.Client{Timeout: replicaRequestWait},
		HasRoomFor: func(size int64) bool {
			space := readSpace(cfg.MusicDir)
			return space == nil || space.Free >= uint64(size)+minFreeBytes
		},
		Apply: func(ctx context.Context) error {
			if cfg.ReplicaApply == "" {
				return errors.New("YOMI_REPLICA_APPLY is not set")
			}
			ctx, cancel := context.WithTimeout(ctx, replicaApplyWait)
			defer cancel()
			output, err := exec.CommandContext(ctx, "/bin/sh", "-c", cfg.ReplicaApply).CombinedOutput()
			if err != nil {
				return fmt.Errorf("%w: %s", err, bytes.TrimSpace(output))
			}
			return nil
		},
	}
}

// tokenLogin uses Subsonic's salted token, so the password itself never travels.
func tokenLogin(user, password string) url.Values {
	saltBytes := make([]byte, 8)
	if _, err := rand.Read(saltBytes); err != nil {
		log.Fatalf("replica: no randomness: %v", err)
	}
	salt := hex.EncodeToString(saltBytes)
	token := md5.Sum([]byte(password + salt))
	return url.Values{"u": {user}, "t": {hex.EncodeToString(token[:])}, "s": {salt}}
}

// Run syncs until ctx ends. A failed pass just waits for the next one.
func (r *ReplicaSync) Run(ctx context.Context) {
	for {
		if err := r.Sync(ctx); err != nil {
			log.Printf("replica: sync: %v", redactURL(err))
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(replicaSyncEvery):
		}
	}
}

// Sync copies missing files, then the database if it changed.
func (r *ReplicaSync) Sync(ctx context.Context) error {
	entries, err := r.fetchIndex(ctx)
	if err != nil {
		return err
	}
	failures := 0
	var firstFailure error
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		if local, have := r.Index.LookupPath(entry.Path); have && local.SHA256 == entry.SHA256 {
			continue
		}
		// One bad file must not hold back the rest.
		if err := r.fetchFile(ctx, entry); err != nil {
			failures++
			log.Printf("replica: %s: %v", entry.Path, redactURL(err))
			if firstFailure == nil {
				firstFailure = err
			}
		}
	}
	if failures > 0 {
		// The database has to wait: it would list songs this server doesn't have.
		return fmt.Errorf("%d files failed, first: %w", failures, redactURL(firstFailure))
	}
	if r.State != nil {
		// Chats and history are extras here: failing to copy them can wait for the next
		// sync, and shouldn't hold back the library.
		if err := r.State.Run(ctx); err != nil {
			log.Printf("replica state: %v", redactURL(err))
		}
	}
	return r.syncDatabase(ctx)
}

func (r *ReplicaSync) request(ctx context.Context, path string) (*http.Request, error) {
	return http.NewRequestWithContext(ctx, http.MethodGet, r.PrimaryURL+path+"?"+r.Login.Encode(), nil)
}

func (r *ReplicaSync) fetchIndex(ctx context.Context) ([]indexEntry, error) {
	request, err := r.request(ctx, "/v1/replica/index")
	if err != nil {
		return nil, err
	}
	response, err := r.Client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("primary answered %d", response.StatusCode)
	}
	var body struct {
		Entries []indexEntry `json:"entries"`
		Seeding bool         `json:"seeding"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, maxReplicaIndexSize)).Decode(&body); err != nil {
		return nil, err
	}
	if body.Seeding {
		return nil, errors.New("primary is still indexing its library")
	}
	return body.Entries, nil
}

func (r *ReplicaSync) fetchFile(ctx context.Context, entry indexEntry) error {
	// The primary is trusted, but a bad path must never write outside the music folder.
	if !isSHA256(entry.SHA256) || !filepath.IsLocal(entry.Path) {
		return fmt.Errorf("refusing unsafe index entry")
	}
	if !r.HasRoomFor(entry.Size) {
		return errors.New("no room left on this server")
	}
	request, err := r.request(ctx, "/v1/replica/file/"+entry.SHA256)
	if err != nil {
		return err
	}
	response, err := r.Client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("primary answered %d", response.StatusCode)
	}
	target := filepath.Join(r.Root, entry.Path)
	if err := os.MkdirAll(filepath.Dir(target), 0o777); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(target), tempFilePrefix+"*"+tempFileSuffix)
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	hasher := sha256.New()
	size, err := io.Copy(io.MultiWriter(temp, hasher), response.Body)
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if hex.EncodeToString(hasher.Sum(nil)) != entry.SHA256 {
		return errHashMismatch
	}
	if err := os.Rename(temp.Name(), target); err != nil {
		return err
	}
	return r.Index.Add(indexEntry{SHA256: entry.SHA256, Path: entry.Path, Size: size})
}

func (r *ReplicaSync) syncDatabase(ctx context.Context) error {
	request, err := r.request(ctx, "/v1/replica/database")
	if err != nil {
		return err
	}
	if r.databaseTag != "" {
		request.Header.Set("If-None-Match", r.databaseTag)
	}
	response, err := r.Client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotModified {
		return nil
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("primary answered %d for the database", response.StatusCode)
	}
	incoming := r.DatabaseFile + ".new"
	if err := writeVerifiedDatabase(incoming, response.Body); err != nil {
		os.Remove(incoming)
		return err
	}
	if err := r.Apply(ctx); err != nil {
		return fmt.Errorf("applying database: %w", err)
	}
	r.databaseTag = response.Header.Get("ETag")
	return nil
}

func writeVerifiedDatabase(path string, body io.Reader) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	if _, err := io.Copy(file, body); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	header := make([]byte, len(sqliteHeader))
	check, err := os.Open(path)
	if err != nil {
		return err
	}
	defer check.Close()
	if _, err := io.ReadFull(check, header); err != nil || string(header) != sqliteHeader {
		return errors.New("downloaded database is not a SQLite file")
	}
	return nil
}
