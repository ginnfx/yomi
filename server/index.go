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
		index.byHash[entry.SHA256] = entry
		index.byPath[entry.Path] = entry
	}
	return index, scanner.Err()
}

// Lookup returns the stored file for hash. A file deleted since it was indexed doesn't
// count, otherwise it could never be uploaded again.
func (i *HashIndex) Lookup(hash string) (indexEntry, bool) {
	i.mu.RLock()
	entry, ok := i.byHash[hash]
	i.mu.RUnlock()
	if !ok {
		return indexEntry{}, false
	}
	if _, err := os.Stat(filepath.Join(i.root, entry.Path)); err != nil {
		i.mu.Lock()
		delete(i.byHash, hash)
		delete(i.byPath, entry.Path)
		i.mu.Unlock()
		return indexEntry{}, false
	}
	return entry, true
}

// Add records a stored file and appends it to the index file.
func (i *HashIndex) Add(entry indexEntry) error {
	line, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	handle, err := os.OpenFile(i.file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o666)
	if err != nil {
		return err
	}
	defer handle.Close()
	if _, err := handle.Write(append(line, '\n')); err != nil {
		return err
	}
	i.byHash[entry.SHA256] = entry
	i.byPath[entry.Path] = entry
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
	defer i.mu.RUnlock()
	entries := make([]indexEntry, 0, len(i.byHash))
	for _, entry := range i.byHash {
		entries = append(entries, entry)
	}
	return entries
}

// Seed hashes audio files not yet in the index and removes temp files left by a crash.
// It runs one file at a time because the server's CPU is shared with playback.
func (i *HashIndex) Seed() {
	i.isSeeding.Store(true)
	defer i.isSeeding.Store(false)
	err := filepath.WalkDir(i.root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			log.Printf("index: skipping %s: %v", path, err)
			return nil
		}
		if entry.IsDir() {
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
	_, known := i.byPath[relative]
	i.mu.RUnlock()
	if known {
		return
	}
	hash, size, err := hashFile(path)
	if err != nil {
		log.Printf("index: could not hash %s: %v", relative, err)
		return
	}
	if err := i.Add(indexEntry{SHA256: hash, Path: relative, Size: size}); err != nil {
		log.Printf("index: could not record %s: %v", relative, err)
	}
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
