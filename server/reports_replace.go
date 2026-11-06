package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dhowden/tag"
)

const songLookupTimeout = 10 * time.Second

var errOutsideLibrary = errors.New("path is outside the music folder")

// handleReplaceReport swaps a song for a better copy (usually the explicit version):
// the old file moves to a hidden archive inside the music folder and Navidrome rescans.
func (s *Server) handleReplaceReport(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.reportsUser(w, r); !ok {
		return
	}
	if !s.isAdmin(r.Context(), r.URL.Query()) {
		writeError(w, http.StatusForbidden, "only the server admin can replace songs")
		return
	}
	var body struct {
		OldSongID string `json:"oldSongId"`
		NewSongID string `json:"newSongId"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	id := r.PathValue("id")
	report, err := s.Reports.Get(id)
	if !s.writeReportError(w, err) {
		return
	}
	if report.Status != reportOpen {
		s.writeReportError(w, errReportNotOpen)
		return
	}
	if s.SongPath == nil || body.OldSongID == "" || body.NewSongID == "" {
		writeError(w, http.StatusBadRequest, "both the old and the new song are needed")
		return
	}
	relative, err := s.SongPath(r.Context(), r.URL.Query(), body.OldSongID)
	if err != nil {
		writeError(w, http.StatusNotFound, "couldn't find the old song's file")
		return
	}
	if err := archiveSong(s.Config.MusicDir, relative); err != nil {
		if errors.Is(err, errOutsideLibrary) {
			writeError(w, http.StatusBadRequest, "that file isn't in the music folder")
			return
		}
		log.Printf("reports: archive %q: %v", relative, err)
		writeError(w, http.StatusInternalServerError, "couldn't move the old song")
		return
	}
	if s.Scan != nil {
		s.Scan(r.Context(), r.URL.Query())
	}
	report, err = s.Reports.Close(id, reportResolved, "Replaced with a better copy", body.NewSongID)
	if !s.writeReportError(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, report)
}

// archiveSong moves root/relative to root/.yomi-replaced/relative. Renaming to a sibling
// folder fails on the server's SD card, so the archive lives inside the music folder,
// hidden from Navidrome by an .ndignore file.
func archiveSong(root, relative string) error {
	source, err := insideLibrary(root, relative)
	if err != nil {
		return err
	}
	clean, _ := filepath.Rel(root, source)
	archive := filepath.Join(root, replaceArchiveDir)
	target := filepath.Join(archive, clean)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	ignore := filepath.Join(archive, reportArchiveIgnore)
	if _, err := os.Stat(ignore); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(ignore, []byte(reportArchiveIgnoreAll), 0o644); err != nil {
			return err
		}
	}
	return os.Rename(source, target)
}

func insideLibrary(root, relative string) (string, error) {
	if relative == "" || filepath.IsAbs(relative) {
		return "", errOutsideLibrary
	}
	full := filepath.Join(root, filepath.FromSlash(relative))
	rel, err := filepath.Rel(root, full)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") || strings.HasPrefix(rel, replaceArchiveDir) {
		return "", errOutsideLibrary
	}
	return full, nil
}

// navidromeSongPath finds a song's file. Navidrome may report a made-up path, so a path
// that doesn't exist falls back to the indexed file of the same size whose title tag
// matches.
func navidromeSongPath(baseURL, root string, index *HashIndex, client *http.Client) func(context.Context, url.Values, string) (string, error) {
	return func(ctx context.Context, query url.Values, id string) (string, error) {
		forwarded := withUsername(query)
		forwarded.Set("id", id)
		ctx, cancel := context.WithTimeout(ctx, songLookupTimeout)
		defer cancel()
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/rest/getSong?"+forwarded.Encode(), nil)
		if err != nil {
			return "", err
		}
		response, err := client.Do(request)
		if err != nil {
			return "", fmt.Errorf("getSong: %w", redactURL(err))
		}
		defer response.Body.Close()
		var body struct {
			Response struct {
				Song struct {
					Path  string `json:"path"`
					Size  int64  `json:"size"`
					Title string `json:"title"`
				} `json:"song"`
			} `json:"subsonic-response"`
		}
		if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
			return "", err
		}
		song := body.Response.Song
		if song.Title == "" {
			return "", errNoSuchSong
		}
		if full, err := insideLibrary(root, song.Path); err == nil {
			if info, err := os.Stat(full); err == nil && (song.Size == 0 || info.Size() == song.Size) {
				return song.Path, nil
			}
		}
		return findBySizeAndTitle(root, index, song.Size, song.Title)
	}
}

func findBySizeAndTitle(root string, index *HashIndex, size int64, title string) (string, error) {
	if index == nil || size == 0 {
		return "", errNoSuchSong
	}
	for _, entry := range index.Entries() {
		if entry.Size != size {
			continue
		}
		file, err := os.Open(filepath.Join(root, entry.Path))
		if err != nil {
			continue
		}
		metadata, err := tag.ReadFrom(file)
		file.Close()
		if err == nil && strings.EqualFold(strings.TrimSpace(metadata.Title()), strings.TrimSpace(title)) {
			return entry.Path, nil
		}
	}
	return "", errNoSuchSong
}
