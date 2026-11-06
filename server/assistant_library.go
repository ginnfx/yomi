package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// This boundary exposes only selected catalog fields, never credentials, paths,
// arbitrary endpoints or database queries. Each chat uses the caller's account.
type libraryToolCall struct {
	Name   string `json:"name"`
	Query  string `json:"query,omitempty"`
	ID     string `json:"id,omitempty"`
	Offset int    `json:"offset"`
}
type libraryLookup func(context.Context, libraryToolCall) any

type libraryRecord struct {
	ID         string `json:"id"`
	Name       string `json:"name,omitempty"`
	Title      string `json:"title,omitempty"`
	Artist     string `json:"artist,omitempty"`
	Album      string `json:"album,omitempty"`
	AlbumCount int    `json:"albumCount,omitempty"`
	SongCount  int    `json:"songCount,omitempty"`
}
type libraryArtist struct {
	libraryRecord
	Albums []libraryRecord `json:"album"`
}
type libraryAlbum struct {
	Songs []libraryRecord `json:"song"`
}

func (s *Server) assistantLibrary(credentials url.Values) libraryLookup {
	client := &http.Client{Timeout: 10 * time.Second}
	return func(ctx context.Context, call libraryToolCall) any {
		fail := func() any {
			return map[string]string{"error": "Library lookup failed; do not interpret this as an empty library."}
		}
		if call.Offset < 0 || call.Offset > 10000 || len(call.Query) > 200 || len(call.ID) > 200 {
			return map[string]string{"error": "Invalid library arguments"}
		}
		query := url.Values{}
		endpoint := ""
		switch call.Name {
		case "search_library":
			if strings.TrimSpace(call.Query) == "" {
				return map[string]string{"error": "Search text is required"}
			}
			endpoint = "search3"
			query.Set("query", call.Query)
			for _, kind := range []string{"artist", "album", "song"} {
				query.Set(kind+"Count", "20")
				query.Set(kind+"Offset", strconv.Itoa(call.Offset))
			}
		case "artist_songs":
			if call.ID == "" {
				return map[string]string{"error": "An artist ID from search_library is required"}
			}
			endpoint = "getArtist"
			query.Set("id", call.ID)
		default:
			return map[string]string{"error": "Unknown tool. Use search_library or artist_songs."}
		}
		if s.Config.NavidromeURL == "" {
			return fail()
		}
		fetch := func(endpoint string, params url.Values, out any) error {
			params.Set("v", "1.16.1")
			params.Set("c", "yomi-assistant")
			params.Set("f", "json")
			for _, key := range []string{"u", "t", "s", "p"} {
				if value := credentials.Get(key); value != "" {
					params.Set(key, value)
				}
			}
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(s.Config.NavidromeURL, "/")+"/rest/"+endpoint+"?"+params.Encode(), nil)
			if err != nil {
				return err
			}
			resp, err := client.Do(req)
			if err != nil {
				return err
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return fmt.Errorf("catalog status %d", resp.StatusCode)
			}
			return json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(out)
		}
		var body struct {
			Response struct {
				Status string `json:"status"`
				Search struct {
					Artists []libraryRecord `json:"artist"`
					Albums  []libraryRecord `json:"album"`
					Songs   []libraryRecord `json:"song"`
				} `json:"searchResult3"`
				Artist libraryArtist `json:"artist"`
			} `json:"subsonic-response"`
		}
		if err := fetch(endpoint, query, &body); err != nil || body.Response.Status != "ok" {
			return fail()
		}
		if call.Name == "search_library" {
			result := body.Response.Search
			// Enforce bounds even if the upstream ignores pagination sizes.
			return map[string]any{"artists": result.Artists[:min(20, len(result.Artists))], "albums": result.Albums[:min(20, len(result.Albums))], "songs": result.Songs[:min(20, len(result.Songs))], "offset": call.Offset, "pageSize": 20, "morePossible": len(result.Artists) >= 20 || len(result.Albums) >= 20 || len(result.Songs) >= 20}
		}
		artist := body.Response.Artist
		start := min(call.Offset, len(artist.Albums))
		end := min(start+5, len(artist.Albums))
		songs := []libraryRecord{}
		truncated := false
		for _, album := range artist.Albums[start:end] {
			var detail struct {
				Response struct {
					Status string       `json:"status"`
					Album  libraryAlbum `json:"album"`
				} `json:"subsonic-response"`
			}
			if err := fetch("getAlbum", url.Values{"id": {album.ID}}, &detail); err != nil || detail.Response.Status != "ok" {
				return fail()
			}
			remaining := 100 - len(songs)
			tracks := detail.Response.Album.Songs
			if len(tracks) > remaining {
				truncated = true
				tracks = tracks[:remaining]
			}
			songs = append(songs, tracks...)
		}
		return map[string]any{"artist": artist.libraryRecord, "songs": songs, "offset": start, "nextOffset": end, "hasMore": end < len(artist.Albums), "songsTruncated": truncated}
	}
}
