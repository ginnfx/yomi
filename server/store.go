package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"unicode"
	"unicode/utf8"
)

const (
	headerSniffBytes = 12
	maxNameBytes     = 150
	maxUserLength    = 40
	maxDuplicateTry  = 1000
	maxFolderBytes   = 80
	tempFilePrefix   = ".upload-"
	tempFileSuffix   = ".tmp"
	fat32Illegal     = `*?<>|":`
)

var (
	errBadName      = errors.New("unsupported file name")
	errBadUser      = errors.New("invalid user name")
	errNotAudio     = errors.New("file content is not recognised audio")
	errNoUniqueName = errors.New("could not find a free file name")
	userPattern     = regexp.MustCompile(`^[a-z0-9._-]+$`)
	allowedExt      = map[string]bool{".mp3": true, ".flac": true, ".m4a": true, ".aac": true, ".ogg": true, ".opus": true, ".wav": true}
	publicationMu   sync.Mutex
)

// sanitizeUser lowercases and validates a user name for use as a folder name.
func sanitizeUser(user string) (string, error) {
	clean := strings.ToLower(strings.TrimSpace(user))
	if clean == "" || len(clean) > maxUserLength || !userPattern.MatchString(clean) || strings.HasPrefix(clean, ".") {
		return "", errBadUser
	}
	return clean, nil
}

// sanitizeName reduces an uploaded name to a safe base name with an allowed audio extension.
func sanitizeName(name string) (string, error) {
	base := filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	cleaned := strings.Map(func(r rune) rune {
		if isIllegalInName(r) {
			return -1
		}
		return r
	}, base)
	cleaned = strings.TrimSpace(strings.TrimLeft(cleaned, "."))
	ext := filepath.Ext(cleaned)
	if !allowedExt[strings.ToLower(ext)] {
		return "", errBadName
	}
	// FAT32 silently drops dots and spaces before an extension's end of a name.
	stem := strings.TrimRight(strings.TrimSuffix(cleaned, ext), ". ")
	cleaned = stem + ext
	if stem == "" || len(cleaned) > maxNameBytes {
		return "", errBadName
	}
	return cleaned, nil
}

func isIllegalInName(r rune) bool {
	return unicode.IsControl(r) || r == '/' || r == '\\' || strings.ContainsRune(fat32Illegal, r)
}

// sanitizeFolder makes a tag value usable as a folder name, or returns "" if nothing
// usable is left. Dots are trimmed so a tag can never mean "." or "..".
func sanitizeFolder(value string) string {
	cleaned := strings.Map(func(r rune) rune {
		if isIllegalInName(r) {
			return -1
		}
		return r
	}, value)
	cleaned = strings.Trim(cleaned, ". ")
	for len(cleaned) > maxFolderBytes {
		_, size := utf8.DecodeLastRuneInString(cleaned)
		cleaned = cleaned[:len(cleaned)-size]
	}
	return strings.TrimRight(cleaned, ". ")
}

// looksLikeAudio checks the file's magic bytes against its claimed extension.
func looksLikeAudio(header []byte, ext string) bool {
	switch ext {
	case ".mp3":
		return bytes.HasPrefix(header, []byte("ID3")) || (len(header) > 1 && header[0] == 0xFF && header[1]&0xE0 == 0xE0)
	case ".aac":
		return len(header) > 1 && header[0] == 0xFF && header[1]&0xF0 == 0xF0
	case ".flac":
		return bytes.HasPrefix(header, []byte("fLaC"))
	case ".m4a":
		return len(header) >= 8 && string(header[4:8]) == "ftyp"
	case ".ogg", ".opus":
		return bytes.HasPrefix(header, []byte("OggS"))
	case ".wav":
		return len(header) >= 12 && string(header[:4]) == "RIFF" && string(header[8:12]) == "WAVE"
	}
	return false
}

// Store writes uploaded audio into per-user folders under Root.
type Store struct {
	Root string
}

// Save streams r to Root/<user>/<name>, validating content first. It returns the stored
// path relative to Root. Existing files are never overwritten; a numeric suffix is added.
func (s Store) Save(user, name string, r io.Reader) (string, error) {
	safeUser, err := sanitizeUser(user)
	if err != nil {
		return "", err
	}
	safeName, err := sanitizeName(name)
	if err != nil {
		return "", err
	}
	header := make([]byte, headerSniffBytes)
	n, err := io.ReadFull(r, header)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) {
		return "", errNotAudio
	}
	header = header[:n]
	ext := strings.ToLower(filepath.Ext(safeName))
	if !looksLikeAudio(header, ext) {
		return "", errNotAudio
	}

	dir := filepath.Join(s.Root, safeUser)
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(dir, tempFilePrefix+"*"+tempFileSuffix)
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := io.Copy(tmp, io.MultiReader(bytes.NewReader(header), r)); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Chmod(tmpPath, 0o666); err != nil && !errors.Is(err, syscall.EPERM) && !errors.Is(err, syscall.EOPNOTSUPP) {
		return "", err
	}
	return linkUnique(tmpPath, dir, safeName, safeUser)
}

// linkUnique atomically publishes tmpPath as dir/name, adding " (n)" if the name is taken.
func linkUnique(tmpPath, dir, name, user string) (string, error) {
	return publishUnique(tmpPath, dir, name, user, os.Link)
}

// One uploader process owns the library. Serialize publication so FAT32/FUSE can
// use a same-directory atomic rename without overwriting another upload. Native
// filesystems retain the hard-link no-replace behavior, including across processes.
func publishUnique(tmpPath, dir, name, user string, link func(string, string) error) (string, error) {
	publicationMu.Lock()
	defer publicationMu.Unlock()
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for attempt := 0; attempt < maxDuplicateTry; attempt++ {
		candidate := name
		if attempt > 0 {
			candidate = fmt.Sprintf("%s (%d)%s", stem, attempt+1, ext)
		}
		destination := filepath.Join(dir, candidate)
		err := link(tmpPath, destination)
		if err == nil {
			return filepath.Join(user, candidate), nil
		}
		if errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EOPNOTSUPP) || errors.Is(err, syscall.ENOSYS) {
			if _, statErr := os.Lstat(destination); statErr == nil {
				continue
			} else if !errors.Is(statErr, os.ErrNotExist) {
				return "", statErr
			}
			if err := os.Rename(tmpPath, destination); err != nil {
				return "", err
			}
			return filepath.Join(user, candidate), nil
		}
		if !errors.Is(err, os.ErrExist) {
			return "", err
		}
	}
	return "", errNoUniqueName
}
