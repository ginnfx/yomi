package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	maxIndexLineBytes = 8 << 10
	// A temp file this long untouched belongs to a crash, not to an upload in progress.
	staleTempAfter = time.Hour
)

// indexEntry records one stored file. Path is relative to the music folder.
type indexEntry struct {
	SHA256 string `json:"sha256"`
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	ModNs  int64  `json:"modNs,omitempty"`
}

// HashIndex maps content hashes to stored files, persisted as an append-only JSONL file
// on internal storage. It's the source of truth for "do we already have this song?".
type HashIndex struct {
	root      string
	file      string
	mu        sync.RWMutex
	byHash    map[string]indexEntry
	byPath    map[string]indexEntry
	isSeeding atomic.Bool
	seedMu    sync.Mutex
	refreshMu sync.Mutex
}

// openHashIndex loads the index file, skipping damaged lines such as a torn final write.
func openHashIndex(root, file string) (*HashIndex, error) {
	index := &HashIndex{
		root:   root,
		file:   file,
		byHash: make(map[string]indexEntry),
		byPath: make(map[string]indexEntry),
	}
	handle, err := os.Open(file)
	if errors.Is(err, os.ErrNotExist) {
		return index, nil
	}
	if err != nil {
		return nil, err
	}
	defer handle.Close()
	scanner := bufio.NewScanner(handle)
	scanner.Buffer(make([]byte, 0, maxIndexLineBytes), maxIndexLineBytes)
	for scanner.Scan() {
		var entry indexEntry
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil || !isSHA256(entry.SHA256) {
			log.Printf("index: skipping damaged line")
			continue
		}
		index.setLocked(entry)
	}
	return index, scanner.Err()
}

// Lookup returns the stored file for hash. A file deleted since it was indexed doesn't
// count, otherwise it could never be uploaded again.
func (i *HashIndex) Lookup(hash string) (indexEntry, bool) {
	for {
		i.mu.RLock()
		entry, ok := i.byHash[hash]
		i.mu.RUnlock()
		if !ok {
			return indexEntry{}, false
		}
		info, err := os.Stat(filepath.Join(i.root, entry.Path))
		if err == nil && info.Size() == entry.Size && info.ModTime().UnixNano() == entry.ModNs {
			return entry, true
		}
		i.refresh(entry.Path)
		i.mu.RLock()
		next, exists := i.byHash[hash]
		i.mu.RUnlock()
		// An unreadable or actively changing file cannot establish a duplicate.
		if exists && next == entry {
			return indexEntry{}, false
		}
	}
}

// Archived replacements are not part of the playable library, even in older index logs.
func isArchivedSong(path string) bool {
	clean := filepath.Clean(filepath.FromSlash(path))
	return clean == replaceArchiveDir || strings.HasPrefix(clean, replaceArchiveDir+string(filepath.Separator))
}

func (i *HashIndex) setLocked(entry indexEntry) {
	if isArchivedSong(entry.Path) {
		return
	}
	if old, ok := i.byPath[entry.Path]; ok && old.SHA256 != entry.SHA256 {
		delete(i.byHash, old.SHA256)
		for path, other := range i.byPath {
			if path != entry.Path && other.SHA256 == old.SHA256 {
				i.byHash[other.SHA256] = other
				break
			}
		}
	}
	i.byPath[entry.Path] = entry
	i.byHash[entry.SHA256] = entry
}

func (i *HashIndex) refresh(path string) {
	i.refreshMu.Lock()
	defer i.refreshMu.Unlock()
	full := filepath.Join(i.root, path)
	info, err := os.Stat(full)
	if err != nil {
		i.mu.Lock()
		if old, ok := i.byPath[path]; ok {
			delete(i.byPath, path)
			delete(i.byHash, old.SHA256)
			for _, other := range i.byPath {
				if other.SHA256 == old.SHA256 {
					i.byHash[other.SHA256] = other
					break
				}
			}
		}
		i.mu.Unlock()
		return
	}
	hash, size, err := hashFile(full)
	if err != nil {
		return
	}
	after, err := os.Stat(full)
	if err != nil || info.Size() != after.Size() || info.ModTime() != after.ModTime() {
		return
	}
	if err := i.Add(indexEntry{SHA256: hash, Path: path, Size: size, ModNs: info.ModTime().UnixNano()}); err != nil {
		log.Printf("index: refresh %s: %v", path, err)
	}
}

// LookupPath checks a particular replica destination, including duplicate content paths.
func (i *HashIndex) LookupPath(path string) (indexEntry, bool) {
	i.mu.RLock()
	entry, ok := i.byPath[path]
	i.mu.RUnlock()
	info, err := os.Stat(filepath.Join(i.root, path))
	if err != nil {
		return indexEntry{}, false
	}
	if !ok || info.Size() != entry.Size || info.ModTime().UnixNano() != entry.ModNs {
		i.refresh(path)
		i.mu.RLock()
		entry, ok = i.byPath[path]
		i.mu.RUnlock()
	}
	if !ok {
		return indexEntry{}, false
	}
	info, err = os.Stat(filepath.Join(i.root, path))
	return entry, err == nil && info.Size() == entry.Size && info.ModTime().UnixNano() == entry.ModNs
}

// Add records a stored file and appends it to the index file.
func (i *HashIndex) Add(entry indexEntry) error {
	if isArchivedSong(entry.Path) {
		return nil
	}
	if info, err := os.Stat(filepath.Join(i.root, entry.Path)); err == nil && entry.ModNs == 0 {
		entry.ModNs = info.ModTime().UnixNano()
	}
	line, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.file == "" {
		i.setLocked(entry)
		return nil
	}
	handle, err := os.OpenFile(i.file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o666)
	if err != nil {
		return err
	}
	defer handle.Close()
	if _, err := handle.Write(append(line, '\n')); err != nil {
		return err
	}
	i.setLocked(entry)
	return nil
}

// Seeding reports whether files from before the index existed are still being hashed.
func (i *HashIndex) Seeding() bool { return i.isSeeding.Load() }

// Count returns the number of indexed files.
func (i *HashIndex) Count() int {
	i.mu.RLock()
	defer i.mu.RUnlock()
	return len(i.byHash)
}

// Entries returns a copy of every indexed file.
func (i *HashIndex) Entries() []indexEntry {
	i.mu.RLock()
	paths := make([]string, 0, len(i.byPath))
	for path := range i.byPath {
		paths = append(paths, path)
	}
	i.mu.RUnlock()
	for _, path := range paths {
		i.mu.RLock()
		entry := i.byPath[path]
		i.mu.RUnlock()
		info, err := os.Stat(filepath.Join(i.root, path))
		if err != nil || info.Size() != entry.Size || info.ModTime().UnixNano() != entry.ModNs {
			i.refresh(path)
		}
	}
	i.mu.RLock()
	defer i.mu.RUnlock()
	entries := make([]indexEntry, 0, len(i.byPath))
	for _, entry := range i.byPath {
		entries = append(entries, entry)
	}
	return entries
}

// Seed hashes audio files not yet in the index and removes temp files left by a crash.
// It runs one file at a time because the server's CPU is shared with playback.
func (i *HashIndex) Seed() {
	i.seedMu.Lock()
	defer i.seedMu.Unlock()
	i.isSeeding.Store(true)
	defer i.isSeeding.Store(false)
	err := filepath.WalkDir(i.root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			log.Printf("index: skipping %s: %v", path, err)
			return nil
		}
		if entry.IsDir() {
			if path == filepath.Join(i.root, replaceArchiveDir) {
				return filepath.SkipDir
			}
			return nil
		}
		if isTempFile(entry.Name()) {
			removeIfStale(path, entry)
			return nil
		}
		if !allowedExt[strings.ToLower(filepath.Ext(entry.Name()))] {
			return nil
		}
		relative, err := filepath.Rel(i.root, path)
		if err != nil {
			return nil
		}
		i.seedFile(path, relative)
		return nil
	})
	if err != nil {
		log.Printf("index: walk stopped: %v", err)
	}
}

func (i *HashIndex) seedFile(path, relative string) {
	i.mu.RLock()
	entry, known := i.byPath[relative]
	i.mu.RUnlock()
	info, err := os.Stat(path)
	if err != nil {
		return
	}
	if known && entry.Size == info.Size() && entry.ModNs == info.ModTime().UnixNano() {
		return
	}
	i.refresh(relative)
}

func isTempFile(name string) bool {
	return strings.HasPrefix(name, tempFilePrefix) && strings.HasSuffix(name, tempFileSuffix)
}

func removeIfStale(path string, entry fs.DirEntry) {
	info, err := entry.Info()
	if err != nil || time.Since(info.ModTime()) < staleTempAfter {
		return
	}
	if err := os.Remove(path); err != nil {
		log.Printf("index: could not remove %s: %v", path, err)
	}
}

func hashFile(path string) (string, int64, error) {
	handle, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer handle.Close()
	hasher := sha256.New()
	size, err := io.Copy(hasher, handle)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(hasher.Sum(nil)), size, nil
}

func isSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	for _, r := range value {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}
