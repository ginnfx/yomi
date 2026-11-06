package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

func (e *reportsEnv) wanted(t *testing.T, user string) (int, []WantedSong) {
	t.Helper()
	status, data := e.call(t, http.MethodGet, "/v1/reports/wanted", user, nil)
	var body struct {
		Songs []WantedSong `json:"songs"`
	}
	if status == http.StatusOK {
		if err := json.Unmarshal(data, &body); err != nil {
			t.Fatal(err)
		}
	}
	return status, body.Songs
}

func (e *reportsEnv) want(t *testing.T, user, artist, title, note string) {
	t.Helper()
	e.call(t, http.MethodPost, "/v1/reports", user, map[string]any{
		"kind": "missing_song", "artist": artist, "title": title, "note": note,
	})
}

func TestEveryoneSeesTheSongsEveryoneWants(t *testing.T) {
	env := newReportsEnv(t)
	env.want(t, "alice", "Mira", "Blue Hour", "")
	env.want(t, "bob", "Oak", "Green Room", "")

	status, songs := env.wanted(t, "carol")

	if status != http.StatusOK || len(songs) != 2 {
		t.Fatalf("a third person should see both requests, got %d %+v", status, songs)
	}
}

func TestWantedCountsPeopleWithoutNamingThem(t *testing.T) {
	env := newReportsEnv(t)
	env.want(t, "alice", "Mira", "Blue Hour", "In Alice's secret mix")
	env.want(t, "bob", "mira", " blue hour ", "")

	status, data := env.call(t, http.MethodGet, "/v1/reports/wanted", "carol", nil)

	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	var songs struct {
		Songs []WantedSong `json:"songs"`
	}
	if err := json.Unmarshal(data, &songs); err != nil {
		t.Fatal(err)
	}
	if len(songs.Songs) != 1 || songs.Songs[0].Count != 2 {
		t.Fatalf("want one song asked for by 2, got %+v", songs.Songs)
	}
	for _, secret := range []string{"alice", "bob", "secret", "mix"} {
		if bytes.Contains(bytes.ToLower(data), []byte(secret)) {
			t.Errorf("the shared list leaked %q: %s", secret, data)
		}
	}
}

func TestWantedLeavesOutOtherKindsAndClosedRequests(t *testing.T) {
	env := newReportsEnv(t)
	env.call(t, http.MethodPost, "/v1/reports", "alice", map[string]any{"kind": "cover_wrong", "songId": "s1", "artist": "A", "title": "T"})
	env.want(t, "alice", "Mira", "Blue Hour", "")
	env.want(t, "alice", "Oak", "Done Already", "")
	for _, r := range env.list(t, "admin") {
		if r.Title == "Done Already" {
			env.call(t, http.MethodPatch, "/v1/reports/"+r.ID, "admin", map[string]any{"status": "resolved"})
		}
	}

	_, songs := env.wanted(t, "bob")

	if len(songs) != 1 || songs[0].Title != "Blue Hour" {
		t.Fatalf("only the open missing song belongs here, got %+v", songs)
	}
}

func TestWantedListsTheMostWantedFirst(t *testing.T) {
	env := newReportsEnv(t)
	env.want(t, "alice", "A", "Once", "")
	env.want(t, "alice", "B", "Twice", "")
	env.want(t, "bob", "B", "Twice", "")

	_, songs := env.wanted(t, "carol")

	if len(songs) != 2 || songs[0].Title != "Twice" {
		t.Fatalf("most wanted should come first, got %+v", songs)
	}
}

func TestWantedNeedsALogin(t *testing.T) {
	env := newReportsEnv(t)

	req, _ := http.NewRequest(http.MethodGet, env.ts.URL+"/v1/reports/wanted", nil)
	resp, err := env.ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status %d, want 401", resp.StatusCode)
	}
}
