package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	poolEvictTo    = 0.9
	poolTempPrefix = ".tmp-"
	poolFileMode   = 0o600
	poolDirMode    = 0o700
	poolBlockBytes = 4096
)

// poolKeyPattern allows lowercase hex, optionally followed by a chunk number.
// Keeping keys this narrow means a key can never name a path outside the pool.
var poolKeyPattern = regexp.MustCompile(`^[a-f0-9]{1,64}(-[0-9]{1,6})?$`)

var errPoolKey = errors.New("invalid pool key")

// PoolStore keeps shared files on disk under a size cap, dropping the least recently
// used ones first. Files are written whole and never changed afterwards.
type PoolStore struct {
	dir   string
	limit int64
	mu    sync.Mutex
	used  int64
}

func openPoolStore(dir string, limit int64) (*PoolStore, error) {
	if err := os.MkdirAll(dir, poolDirMode); err != nil {
		return nil, err
	}
	store := &PoolStore{dir: dir, limit: limit}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), poolTempPrefix) {
			os.Remove(filepath.Join(dir, entry.Name()))
			continue
		}
		if info, err := entry.Info(); err == nil && poolKeyPattern.MatchString(entry.Name()) {
			store.used += diskSize(info.Size())
		}
	}
	return store, nil
}

// diskSize is what a file really takes up: every file costs at least one block, so lots
// of tiny files can't use far more disk than the limit says.
func diskSize(size int64) int64 {
	return (size + poolBlockBytes - 1) / poolBlockBytes * poolBlockBytes
}

func (p *PoolStore) path(key string) string { return filepath.Join(p.dir, key) }

// Open returns the file for a key and marks it as recently used.
func (p *PoolStore) Open(key string) (*os.File, bool) {
	if !poolKeyPattern.MatchString(key) {
		return nil, false
	}
	file, err := os.Open(p.path(key))
	if err != nil {
		return nil, false
	}
	now := time.Now()
	os.Chtimes(p.path(key), now, now)
	return file, true
}

// Put stores data under key, then evicts old entries if the pool is over its cap.
func (p *PoolStore) Put(key string, data []byte) error {
	if !poolKeyPattern.MatchString(key) {
		return errPoolKey
	}
	size := diskSize(int64(len(data)))
	if size > p.limit {
		return fmt.Errorf("entry of %d bytes is bigger than the whole pool", size)
	}
	temp, err := os.CreateTemp(p.dir, poolTempPrefix+"*")
	if err != nil {
		return err
	}
	_, writeErr := temp.Write(data)
	closeErr := temp.Close()
	if err := errors.Join(writeErr, closeErr, os.Chmod(temp.Name(), poolFileMode)); err != nil {
		os.Remove(temp.Name())
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	var replaced int64
	if info, err := os.Stat(p.path(key)); err == nil {
		replaced = diskSize(info.Size())
	}
	if err := os.Rename(temp.Name(), p.path(key)); err != nil {
		os.Remove(temp.Name())
		return err
	}
	p.used += size - replaced
	if p.used > p.limit {
		p.evictLocked(key)
	}
	return nil
}

type poolEntry struct {
	name    string
	size    int64
	modTime time.Time
}

// evictLocked removes the least recently used entries, never the one just written.
func (p *PoolStore) evictLocked(keep string) {
	entries, err := os.ReadDir(p.dir)
	if err != nil {
		return
	}
	var all []poolEntry
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil || !poolKeyPattern.MatchString(entry.Name()) || entry.Name() == keep {
			continue
		}
		all = append(all, poolEntry{entry.Name(), diskSize(info.Size()), info.ModTime()})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].modTime.Before(all[j].modTime) })
	target := int64(float64(p.limit) * poolEvictTo)
	for _, entry := range all {
		if p.used <= target {
			return
		}
		if err := os.Remove(p.path(entry.name)); err == nil || errors.Is(err, os.ErrNotExist) {
			p.used -= entry.size
		}
	}
}
