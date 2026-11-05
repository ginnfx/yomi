package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxPlaylistCoverBytes = 2 << 20
	playlistOwnerTimeout  = 10 * time.Second
)

var (
	playlistIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	errNoSuchPlaylist = errors.New("no such playlist")
)

// PlaylistCoverStore keeps pictures people chose for their playlists, one file each.
type PlaylistCoverStore struct {
	dir string
	mu  sync.Mutex
}

func openPlaylistCoverStore(dir string) (*PlaylistCoverStore, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &PlaylistCoverStore{dir: dir}, nil
}

func (p *PlaylistCoverStore) file(id string) string { return filepath.Join(p.dir, id+".img") }

// Save stores a picture and returns its version, which changes with every new picture.
func (p *PlaylistCoverStore) Save(id string, image []byte) (int64, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	temp := p.file(id) + ".tmp"
	if err := os.WriteFile(temp, image, 0o600); err != nil {
		return 0, err
	}
	if err := os.Rename(temp, p.file(id)); err != nil {
		return 0, err
	}
	info, err := os.Stat(p.file(id))
	if err != nil {
		return 0, err
	}
	return info.ModTime().UnixMilli(), nil
}

func (p *PlaylistCoverStore) Delete(id string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if err := os.Remove(p.file(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (p *PlaylistCoverStore) Read(id string) ([]byte, int64, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	info, err := os.Stat(p.file(id))
	if err != nil {
		return nil, 0, err
	}
	data, err := os.ReadFile(p.file(id))
	return data, info.ModTime().UnixMilli(), err
}

// Versions lists every playlist with a picture, and its version.
func (p *PlaylistCoverStore) Versions() (map[string]int64, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	entries, err := os.ReadDir(p.dir)
	if err != nil {
		return nil, err
	}
	versions := map[string]int64{}
	for _, entry := range entries {
		id, ok := strings.CutSuffix(entry.Name(), ".img")
		if !ok || !playlistIDPattern.MatchString(id) {
			continue
		}
		if info, err := entry.Info(); err == nil {
			versions[id] = info.ModTime().UnixMilli()
		}
	}
	return versions, nil
}

// navidromePlaylistOwner asks Navidrome, as the caller, who owns a playlist.
func navidromePlaylistOwner(baseURL string, client *http.Client) func(context.Context, url.Values, string) (string, error) {
	return func(ctx context.Context, query url.Values, id string) (string, error) {
		forwarded := url.Values{"v": {"1.16.1"}, "c": {"yomi-upload"}, "f": {"json"}, "id": {id}}
		for _, key := range []string{"u", "t", "s", "p"} {
			if value := query.Get(key); value != "" {
				forwarded.Set(key, value)
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/rest/getPlaylist?"+forwarded.Encode(), nil)
		if err != nil {
			return "", err
		}
		resp, err := client.Do(req)
		if err != nil {
			return "", fmt.Errorf("navidrome unreachable: %w", redactURL(err))
		}
		defer resp.Body.Close()
		var body struct {
			Response struct {
				Status   string `json:"status"`
				Playlist struct {
					Owner string `json:"owner"`
				} `json:"playlist"`
			} `json:"subsonic-response"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return "", fmt.Errorf("unexpected navidrome reply: %w", err)
		}
		if body.Response.Status != "ok" || body.Response.Playlist.Owner == "" {
			return "", errNoSuchPlaylist
		}
		return body.Response.Playlist.Owner, nil
	}
}

// coverTarget checks the login and playlist ID. Changes also need the caller to own it.
func (s *Server) coverTarget(w http.ResponseWriter, r *http.Request, isChange bool) (string, bool) {
	user, ok := s.authenticate(w, r)
	if !ok {
		return "", false
	}
	if s.PlaylistCovers == nil || (isChange && (s.PlaylistOwner == nil || s.isReplica())) {
		writeError(w, http.StatusServiceUnavailable, "playlist pictures aren't available on this server")
		return "", false
	}
	id := r.PathValue("id")
	if !playlistIDPattern.MatchString(id) {
		writeError(w, http.StatusBadRequest, "that isn't a playlist")
		return "", false
	}
	if !isChange {
		return id, true
	}
	// A playlist imported from Spotify belongs to whoever imported it.
	if s.History != nil {
		if safe, err := sanitizeUser(user); err == nil && s.History.HasImport(safe, id) {
			return id, true
		}
	}
	owner, err := s.PlaylistOwner(r.Context(), r.URL.Query(), id)
	switch {
	case errors.Is(err, errNoSuchPlaylist):
		writeError(w, http.StatusNotFound, "no such playlist")
		return "", false
	case err != nil:
		log.Printf("playlist owner: %v", err)
		writeError(w, http.StatusBadGateway, "couldn't check that playlist")
		return "", false
	case !strings.EqualFold(owner, user):
		writeError(w, http.StatusForbidden, "only the playlist's owner can change its picture")
		return "", false
	}
	return id, true
}

func (s *Server) handleSavePlaylistCover(w http.ResponseWriter, r *http.Request) {
	id, ok := s.coverTarget(w, r, true)
	if !ok {
		return
	}
	image, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxPlaylistCoverBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "that picture is too big")
		return
	}
	if !looksLikeImage(image) {
		writeError(w, http.StatusBadRequest, "send a JPEG, PNG or WebP picture")
		return
	}
	version, err := s.PlaylistCovers.Save(id, image)
	if err != nil {
		log.Printf("save playlist cover: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't save the picture")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{"version": version})
}

func (s *Server) handleDeletePlaylistCover(w http.ResponseWriter, r *http.Request) {
	id, ok := s.coverTarget(w, r, true)
	if !ok {
		return
	}
	if err := s.PlaylistCovers.Delete(id); err != nil {
		log.Printf("delete playlist cover: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't remove the picture")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handlePlaylistCover(w http.ResponseWriter, r *http.Request) {
	id, ok := s.coverTarget(w, r, false)
	if !ok {
		return
	}
	image, version, err := s.PlaylistCovers.Read(id)
	if errors.Is(err, os.ErrNotExist) {
		writeError(w, http.StatusNotFound, "this playlist has no picture")
		return
	}
	if err != nil {
		log.Printf("read playlist cover: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't read the picture")
		return
	}
	etag := `"` + strconv.FormatInt(version, 10) + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", http.DetectContentType(image))
	if _, err := w.Write(image); err != nil {
		log.Printf("write playlist cover: %v", err)
	}
}

func (s *Server) handlePlaylistCovers(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authenticate(w, r); !ok {
		return
	}
	if s.PlaylistCovers == nil {
		writeJSON(w, http.StatusOK, map[string]any{"covers": map[string]int64{}})
		return
	}
	versions, err := s.PlaylistCovers.Versions()
	if err != nil {
		log.Printf("list playlist covers: %v", err)
		writeError(w, http.StatusInternalServerError, "couldn't list the pictures")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"covers": versions})
}
