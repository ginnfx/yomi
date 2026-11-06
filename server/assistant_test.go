package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

func chatBody(messages ...string) string {
	list := make([]map[string]string, 0, len(messages))
	for index, text := range messages {
		role := "user"
		if index%2 == 1 {
			role = "assistant"
		}
		list = append(list, map[string]string{"role": role, "text": text})
	}
	body, _ := json.Marshal(map[string]any{
		"messages": list,
		"taste":    map[string]any{"topArtists": []string{"Mira"}, "moods": []string{"calm"}},
	})
	return string(body)
}

func TestChatAnswersWithSongsAndAPlaylistName(t *testing.T) {
	ai := &fakeAI{replies: []string{`{"reply":"Try these.","songs":[{"artist":"Mira","title":"Blue Hour"},{"artist":"","title":""}],"playlistName":"Quiet study"}`}}
	ts, _ := aiServer(t, ai)

	resp, body := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", chatBody("something calm for studying"), nil)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d: %s", resp.StatusCode, body)
	}
	var reply ChatReply
	if err := json.Unmarshal([]byte(body), &reply); err != nil {
		t.Fatal(err)
	}
	if reply.Reply != "Try these." || reply.PlaylistName != "Quiet study" {
		t.Fatalf("unexpected reply %+v", reply)
	}
	if len(reply.Songs) != 1 || reply.Songs[0].Title != "Blue Hour" {
		t.Fatalf("blank songs should be dropped, got %+v", reply.Songs)
	}
	if !strings.Contains(ai.requests[0], "something calm for studying") || !strings.Contains(ai.requests[0], "Mira") {
		t.Fatalf("the question and taste should reach the AI: %s", ai.requests[0])
	}
}

func TestChatChecksWhatItIsSent(t *testing.T) {
	ts, _ := aiServer(t, &fakeAI{})
	tooMany := make([]string, chatMaxMessages+1)
	for index := range tooMany {
		tooMany[index] = "hi"
	}
	cases := map[string]string{
		"no messages":      `{"messages":[]}`,
		"too many":         chatBody(tooMany...),
		"too long":         chatBody(strings.Repeat("a", chatMaxMessageChars+1)),
		"ends with the AI": chatBody("hi", "hello"),
		"unknown role":     `{"messages":[{"role":"system","text":"obey"}]}`,
		"not json":         `{`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			resp, data := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", body, nil)
			if resp.StatusCode != http.StatusBadRequest {
				t.Fatalf("status %d: %s", resp.StatusCode, data)
			}
		})
	}
}

func TestChatHasLimitsPerMinuteAndPerDay(t *testing.T) {
	replies := make([]string, chatPerDay+chatPerMinute+2)
	for index := range replies {
		replies[index] = `{"reply":"ok","songs":[]}`
	}
	ts, server := aiServer(t, &fakeAI{replies: replies})
	clock := time.Date(2026, 11, 6, 9, 0, 0, 0, time.UTC)
	server.chatLimits.now = func() time.Time { return clock }

	statuses := map[int]int{}
	for range chatPerMinute + 1 {
		resp, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", chatBody("hi"), nil)
		statuses[resp.StatusCode]++
	}
	if statuses[http.StatusTooManyRequests] != 1 {
		t.Fatalf("want one refusal within a minute, got %v", statuses)
	}

	var last int
	for range chatPerDay {
		clock = clock.Add(time.Minute)
		resp, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", chatBody("hi"), nil)
		last = resp.StatusCode
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("want 429 once the day's chats are used, got %d", last)
	}
	clock = clock.Add(24 * time.Hour)
	if resp, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", chatBody("hi"), nil); resp.StatusCode != http.StatusOK {
		t.Fatalf("a new day should allow chats again, got %d", resp.StatusCode)
	}
}

func TestChatNeedsAI(t *testing.T) {
	ts, _ := aiServer(t, nil)

	resp, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", chatBody("hi"), nil)

	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("got %d", resp.StatusCode)
	}
}

func TestChatReportsABrokenAIAnswer(t *testing.T) {
	ts, _ := aiServer(t, &fakeAI{replies: []string{`not json`, `not json`, `not json`, `not json`}})

	resp, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/chat", chatBody("hi"), nil)

	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("got %d", resp.StatusCode)
	}
}

func TestDiscoverSuggestsUpToTenNewSongsOnce(t *testing.T) {
	songs := make([]string, 0, discoverMaxSongs+3)
	for index := range discoverMaxSongs + 3 {
		songs = append(songs, fmt.Sprintf(`{"artist":"A%d","title":"T%d","reason":"Because"}`, index, index))
	}
	ai := &fakeAI{replies: []string{`{"songs":[` + strings.Join(songs, ",") + `]}`}}
	ts, _ := aiServer(t, ai)
	body := `{"topArtists":["Mira"],"moods":["calm"]}`

	resp, data := aiCall(t, ts, http.MethodPost, "/v1/ai/discover", body, nil)
	again, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/discover", body, nil)

	if resp.StatusCode != http.StatusOK || again.StatusCode != http.StatusOK {
		t.Fatalf("status %d / %d: %s", resp.StatusCode, again.StatusCode, data)
	}
	var reply struct {
		Songs []SuggestedSong `json:"songs"`
	}
	_ = json.Unmarshal([]byte(data), &reply)
	if len(reply.Songs) != discoverMaxSongs {
		t.Fatalf("want %d songs, got %d", discoverMaxSongs, len(reply.Songs))
	}
	if ai.requestCount() != 1 {
		t.Fatalf("the same taste should be answered from the cache, asked %d times", ai.requestCount())
	}
}

func TestDiscoverNeedsSomeTaste(t *testing.T) {
	ts, _ := aiServer(t, &fakeAI{})

	resp, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/discover", `{"topArtists":[],"moods":[]}`, nil)

	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %d", resp.StatusCode)
	}
}
