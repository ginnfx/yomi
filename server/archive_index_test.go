package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestIndexExcludesReplacedSongsAndOldArchiveEntries(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "user", "old.mp3")
	if err := os.MkdirAll(filepath.Dir(source), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(source, []byte("old audio"), 0644); err != nil {
		t.Fatal(err)
	}
	hash, size, err := hashFile(source)
	if err != nil {
		t.Fatal(err)
	}
	if err := archiveSong(root, "user/old.mp3"); err != nil {
		t.Fatal(err)
	}
	archived := filepath.Join(replaceArchiveDir, "user", "old.mp3")
	// Simulate an index log created by the previous release.
	entry := indexEntry{SHA256: hash, Path: archived, Size: size}
	line, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(t.TempDir(), "index.jsonl")
	if err := os.WriteFile(logPath, append(line, '\n'), 0644); err != nil {
		t.Fatal(err)
	}
	idx, err := openHashIndex(root, logPath)
	if err != nil {
		t.Fatal(err)
	}
	idx.Seed()
	if _, found := idx.Lookup(hash); found {
		t.Fatal("archived song blocks restoration as a duplicate")
	}
	if entries := idx.Entries(); len(entries) != 0 {
		t.Fatalf("archive exported to replicas: %+v", entries)
	}
	if _, found := idx.LookupPath(archived); found {
		t.Fatal("archive can be reindexed by path lookup")
	}
	if err := idx.Add(entry); err != nil {
		t.Fatal(err)
	}
	if idx.Count() != 0 {
		t.Fatal("archive can be reindexed by Add")
	}
	// The same bytes restored to a live path must still be indexed normally.
	if err := os.WriteFile(source, []byte("old audio"), 0644); err != nil {
		t.Fatal(err)
	}
	idx.Seed()
	if got, found := idx.Lookup(hash); !found || got.Path != filepath.Join("user", "old.mp3") {
		t.Fatalf("restored live song missing: %+v %v", got, found)
	}
}
