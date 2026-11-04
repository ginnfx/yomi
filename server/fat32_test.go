package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
)

func TestFAT32ConcurrentPublicationKeepsDuplicates(t *testing.T) {
	dir := t.TempDir()
	original := []byte("existing song")
	if err := os.WriteFile(filepath.Join(dir, "song.wav"), original, 0600); err != nil {
		t.Fatal(err)
	}
	const uploads = 12
	var wg sync.WaitGroup
	for i := 0; i < uploads; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			payload := []byte(fmt.Sprintf("complete upload %d", i))
			tmp, err := os.CreateTemp(dir, ".upload-*.tmp")
			if err != nil {
				t.Error(err)
				return
			}
			if _, err = tmp.Write(payload); err != nil {
				t.Error(err)
				return
			}
			if err = tmp.Close(); err != nil {
				t.Error(err)
				return
			}
			relative, err := publishUnique(tmp.Name(), dir, "song.wav", "user", func(string, string) error { return syscall.EOPNOTSUPP })
			if err != nil {
				t.Error(err)
				return
			}
			got, err := os.ReadFile(filepath.Join(dir, filepath.Base(relative)))
			if err != nil || !bytes.Equal(got, payload) {
				t.Errorf("publication mismatch: %v", err)
			}
		}(i)
	}
	wg.Wait()
	got, err := os.ReadFile(filepath.Join(dir, "song.wav"))
	if err != nil || !bytes.Equal(got, original) {
		t.Fatal("existing song overwritten")
	}
	files, err := os.ReadDir(dir)
	if err != nil || len(files) != uploads+1 {
		t.Fatalf("wrong file count: %d, %v", len(files), err)
	}
}
