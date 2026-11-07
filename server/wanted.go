package main

import (
	"net/http"
	"sort"
)

// WantedSong is a song people have asked for that the library doesn't have. It says how
// many people want it, never who or why, so everyone can see it without exposing anyone.
type WantedSong struct {
	ID        string `json:"id"`
	Artist    string `json:"artist"`
	Title     string `json:"title"`
	Count     int    `json:"count"`
	CreatedMs int64  `json:"createdMs"`
}

// Wanted lists the open missing-song requests from everyone, most wanted first and then
// newest first.
func (s *ReportStore) Wanted() []WantedSong {
	s.mu.Lock()
	defer s.mu.Unlock()
	songs := make([]WantedSong, 0)
	for _, report := range s.reports {
		if report.Kind != reportMissingSong || report.Status != reportOpen {
			continue
		}
		songs = append(songs, WantedSong{
			ID:        report.ID,
			Artist:    report.Artist,
			Title:     report.Title,
			Count:     len(report.Reporters),
			CreatedMs: report.CreatedMs,
		})
	}
	sort.SliceStable(songs, func(i, j int) bool {
		if songs[i].Count != songs[j].Count {
			return songs[i].Count > songs[j].Count
		}
		return songs[i].CreatedMs > songs[j].CreatedMs
	})
	return songs
}

func (s *Server) handleWanted(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.reportsUser(w, r); !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"songs": s.Reports.Wanted()})
}
