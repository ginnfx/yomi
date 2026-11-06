package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func poolKey(c byte) string { return strings.Repeat(string(c), 64) }

func readPoolFile(t *testing.T, store *PoolStore, key string) ([]byte, bool) {
	t.Helper()
	file, ok := store.Open(key)
	if !ok {
		return nil, false
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		t.Fatal(err)
	}
	return data, true
}

func TestPoolStoreReturnsWhatWasPut(t *testing.T) {
	store, err := openPoolStore(t.TempDir(), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(poolKey('a'), []byte("hello")); err != nil {
		t.Fatal(err)
	}

	data, ok := readPoolFile(t, store, poolKey('a'))

	if !ok || string(data) != "hello" {
		t.Fatalf("got %q, %v", data, ok)
	}
}

func TestPoolStoreMissesUnknownKey(t *testing.T) {
	store, _ := openPoolStore(t.TempDir(), 1<<20)

	if _, ok := store.Open(poolKey('b')); ok {
		t.Fatal("expected a miss")
	}
}

func TestPoolStoreRejectsKeysThatCouldEscapeTheFolder(t *testing.T) {
	dir := t.TempDir()
	store, _ := openPoolStore(filepath.Join(dir, "pool"), 1<<20)

	for _, key := range []string{"../escape", "a/b", "", "UPPER", strings.Repeat("a", 65)} {
		if err := store.Put(key, []byte("x")); err == nil {
			t.Errorf("Put(%q) should fail", key)
		}
		if _, ok := store.Open(key); ok {
			t.Errorf("Open(%q) should miss", key)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "escape")); err == nil {
		t.Fatal("a file escaped the pool folder")
	}
}

func TestPoolStoreEvictsLeastRecentlyUsedWhenFull(t *testing.T) {
	dir := t.TempDir()
	store, _ := openPoolStore(dir, 3*poolBlockBytes)
	old := time.Now().Add(-time.Hour)
	for _, c := range []byte("ab") {
		if err := store.Put(poolKey(c), make([]byte, poolBlockBytes)); err != nil {
			t.Fatal(err)
		}
	}
	// "a" is the stalest, then reading "b" makes it the freshest.
	os.Chtimes(filepath.Join(dir, poolKey('a')), old, old)
	os.Chtimes(filepath.Join(dir, poolKey('b')), old.Add(time.Minute), old.Add(time.Minute))
	readPoolFile(t, store, poolKey('b'))

	if err := store.Put(poolKey('c'), make([]byte, 2*poolBlockBytes)); err != nil {
		t.Fatal(err)
	}

	if _, ok := store.Open(poolKey('a')); ok {
		t.Error("the stalest entry should have been evicted")
	}
	if _, ok := store.Open(poolKey('c')); !ok {
		t.Error("the newest entry must survive eviction")
	}
}

func TestPoolStoreCountsExistingFilesOnOpen(t *testing.T) {
	dir := t.TempDir()
	first, _ := openPoolStore(dir, poolBlockBytes+poolBlockBytes/2)
	first.Put(poolKey('a'), make([]byte, 10))

	second, _ := openPoolStore(dir, poolBlockBytes+poolBlockBytes/2)
	second.Put(poolKey('b'), make([]byte, 10))

	if _, ok := second.Open(poolKey('a')); ok {
		t.Fatal("reopened store forgot how much was already stored")
	}
}

func TestPoolStoreSkipsOversizedEntries(t *testing.T) {
	store, _ := openPoolStore(t.TempDir(), poolBlockBytes)

	if err := store.Put(poolKey('a'), make([]byte, poolBlockBytes+1)); err == nil {
		t.Fatal("an entry bigger than the whole pool should be refused")
	}
}

func TestPoolStoreCountsTinyFilesAsWholeBlocks(t *testing.T) {
	store, _ := openPoolStore(t.TempDir(), 2*poolBlockBytes)
	for _, c := range []byte("abc") {
		if err := store.Put(poolKey(c), []byte("x")); err != nil {
			t.Fatal(err)
		}
	}

	hits := 0
	for _, c := range []byte("abc") {
		if _, ok := store.Open(poolKey(c)); ok {
			hits++
		}
	}

	if hits > 2 {
		t.Fatalf("%d one-byte files fit in a two-block pool", hits)
	}
}
