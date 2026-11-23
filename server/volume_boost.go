package main

import (
	"context"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Rendering a separate copy gives AVPlayer real gain above unity too. The
// original is untouched. Two jobs maximum, bounded duration, no shell commands.
var boostSlots = make(chan struct{}, 2)

func (s *Server) handleVolumeBoost(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authenticate(w, r); !ok {
		return
	}
	if s.SongPath == nil {
		writeError(w, 503, "Volume boost unavailable on this server")
		return
	}
	binary, err := exec.LookPath("ffmpeg")
	if err != nil {
		writeError(w, 503, "Volume boost needs ffmpeg on the server")
		return
	}
	gain := r.URL.Query().Get("gain")
	if gain != "3" && gain != "6" {
		writeError(w, 400, "Choose 3 or 6 dB")
		return
	}
	select {
	case boostSlots <- struct{}{}:
		defer func() { <-boostSlots }()
	default:
		writeError(w, 429, "Volume boost is busy; try again shortly")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	relative, err := s.SongPath(ctx, r.URL.Query(), r.PathValue("id"))
	if err != nil {
		writeError(w, 404, "Song not found")
		return
	}
	path, err := insideLibrary(s.Config.MusicDir, relative)
	if err != nil {
		writeError(w, 400, "Invalid song path")
		return
	}
	root, rootErr := filepath.EvalSymlinks(s.Config.MusicDir)
	real, realErr := filepath.EvalSymlinks(path)
	rel, relErr := filepath.Rel(root, real)
	if rootErr != nil || realErr != nil || relErr != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		writeError(w, 400, "Invalid song path")
		return
	}
	file, err := os.CreateTemp("", "yomi-boost-*.mp3")
	if err != nil {
		writeError(w, 500, "Cannot prepare boost")
		return
	}
	name := file.Name()
	file.Close()
	defer os.Remove(name)
	// Disable automatic makeup gain in the limiter; only selected gain is applied.
	cmd := exec.CommandContext(ctx, binary, "-nostdin", "-v", "error", "-y", "-protocol_whitelist", "file,pipe", "-i", real,
		"-vn", "-af", "volume="+gain+"dB,alimiter=limit=0.95:level=false", "-codec:a", "libmp3lame", "-b:a", "192k", name)
	if cmd.Run() != nil {
		writeError(w, 502, "Could not boost this recording")
		return
	}
	w.Header().Set("Cache-Control", "private, no-store")
	http.ServeFile(w, r, name)
}
