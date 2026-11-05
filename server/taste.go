package main

import (
	"log"
	"net/http"
	"strings"
	"unicode/utf8"
)

const (
	tasteMaxArtists = 10
	tasteMaxMoods   = 5
)

// Taste is what someone shares with friends about their listening: a few names, never
// individual plays.
type Taste struct {
	TopArtists []string `json:"topArtists"`
	TopMoods   []string `json:"topMoods"`
	UpdatedMs  int64    `json:"updatedMs"`
}

// SaveTaste replaces what a user shares. A nil taste stops sharing.
func (m *MessageStore) SaveTaste(user string, taste *Taste) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	profile, ok := m.state.Profiles[user]
	if !ok {
		profile = Profile{User: user}
	}
	if taste != nil {
		taste.UpdatedMs = m.now().UnixMilli()
	}
	profile.Taste = taste
	m.state.Profiles[user] = profile
	return m.saveStateLocked()
}

func (s *Server) handleSaveTaste(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialUser(w, r)
	if !ok {
		return
	}
	var request Taste
	if !decodeBody(w, r, &request) {
		return
	}
	if len(request.TopArtists) > tasteMaxArtists || len(request.TopMoods) > tasteMaxMoods*3 {
		writeError(w, http.StatusBadRequest, "that's more than a profile shows")
		return
	}
	artists := make([]string, 0, len(request.TopArtists))
	for _, artist := range request.TopArtists {
		artist = strings.TrimSpace(artist)
		if utf8.RuneCountInString(artist) > maxNameChars*2 {
			writeError(w, http.StatusBadRequest, "an artist name is too long")
			return
		}
		if artist != "" {
			artists = append(artists, artist)
		}
	}
	moods := onlyAllowed(request.TopMoods, allowedMoods)
	if len(moods) > tasteMaxMoods {
		moods = moods[:tasteMaxMoods]
	}
	var taste *Taste
	if len(artists) > 0 || len(moods) > 0 {
		taste = &Taste{TopArtists: artists, TopMoods: moods}
	}
	if err := s.Messages.SaveTaste(user, taste); err != nil {
		log.Printf("messages: save taste: %v", err)
		writeError(w, http.StatusInternalServerError, "could not save your taste")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
