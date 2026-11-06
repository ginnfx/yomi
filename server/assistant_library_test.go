package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestChatSearchesUnfamiliarArtistAndReadsTracks(t *testing.T) {
	ai := &fakeAI{replies: []string{
		`{"tool":{"name":"search_library","query":"esdeekid","offset":0}}`,
		`{"tool":{"name":"artist_songs","id":"artist-1","offset":0}}`,
		`{"reply":"Here is one from your library.","songs":[{"artist":"EsDeeKid","title":"Library Track"}]}`,
	}}
	ts, server := aiServer(t, ai)
	var paths []string
	catalog := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		if r.URL.Query().Get("u") != "alice" || r.URL.Query().Get("p") != "good" {
			t.Error("caller credentials missing")
		}
		var data string
		switch r.URL.Path {
		case "/rest/search3":
			if r.URL.Query().Get("query") != "esdeekid" {
				t.Error("wrong search")
			}
			data = `"searchResult3":{"artist":[{"id":"artist-1","name":"EsDeeKid","path":"secret-path"}]}`
		case "/rest/getArtist":
			data = `"artist":{"id":"artist-1","name":"EsDeeKid","album":[{"id":"album-1","title":"Album"}]}`
		case "/rest/getAlbum":
			data = `"album":{"song":[{"id":"song-1","title":"Library Track","artist":"EsDeeKid"}]}`
		default:
			t.Error("unexpected endpoint")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"subsonic-response":{"status":"ok",` + data + `}}`))
	}))
	defer catalog.Close()
	server.Config.NavidromeURL = catalog.URL
	resp, body := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", chatBody("suggest some esdeekid songs"), nil)
	if resp.StatusCode != 200 || !strings.Contains(body, "Library Track") {
		t.Fatalf("%d: %s", resp.StatusCode, body)
	}
	if len(paths) != 3 || ai.requestCount() != 3 {
		t.Fatalf("paths %v; AI calls %d", paths, ai.requestCount())
	}
	evidence := ai.requests[2]
	for _, want := range []string{"EsDeeKid", "Library Track", "libraryResults"} {
		if !strings.Contains(evidence, want) {
			t.Errorf("missing %s", want)
		}
	}
	for _, secret := range []string{"secret-path", `p=good`, `\"p\":\"good\"`} {
		if strings.Contains(evidence, secret) {
			t.Errorf("leaked %s", secret)
		}
	}
}

func TestLibraryToolRejectsUnknownAndReportsUpstreamFailure(t *testing.T) {
	server := &Server{}
	lookup := server.assistantLibrary(url.Values{})
	for _, call := range []libraryToolCall{{Name: "delete_song"}, {Name: "search_library", Query: "artist"}, {Name: "search_library", Query: "artist", Offset: -1}} {
		result := lookup(context.Background(), call)
		data, _ := json.Marshal(result)
		if !strings.Contains(string(data), "error") {
			t.Fatalf("expected error: %s", data)
		}
	}
}

func TestChatToolLoopIsBounded(t *testing.T) {
	replies := make([]string, 7)
	for i := range replies {
		replies[i] = `{"tool":{"name":"search_library","query":"x"}}`
	}
	ai := &fakeAI{replies: replies}
	ts, _ := aiServer(t, ai)
	resp, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", chatBody("songs"), nil)
	if resp.StatusCode != http.StatusBadGateway || ai.requestCount() != 7 {
		t.Fatalf("status %d calls %d", resp.StatusCode, ai.requestCount())
	}
}
