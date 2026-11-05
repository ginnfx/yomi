package main

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"testing"
)

func pngBytes(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// coverServer has two playlists: "mine" owned by alice and "theirs" owned by bob.
func coverServer(t *testing.T) *httptest.Server {
	t.Helper()
	dir := t.TempDir()
	server := newServer(Config{MusicDir: dir, MaxFileBytes: 1 << 10}, fakeAuth{}, nil, nil)
	store, err := openPlaylistCoverStore(filepath.Join(dir, "covers"))
	if err != nil {
		t.Fatal(err)
	}
	server.PlaylistCovers = store
	history, err := openHistoryStore(filepath.Join(dir, "history"))
	if err != nil {
		t.Fatal(err)
	}
	if err := history.SaveImport("alice", "imported1", []byte(`{"id":"imported1"}`)); err != nil {
		t.Fatal(err)
	}
	server.History = history
	server.PlaylistOwner = func(_ context.Context, _ url.Values, id string) (string, error) {
		switch id {
		case "mine":
			return "alice", nil
		case "theirs":
			return "bob", nil
		}
		return "", errNoSuchPlaylist
	}
	ts := httptest.NewServer(server.routes())
	t.Cleanup(ts.Close)
	return ts
}

func coverCall(t *testing.T, ts *httptest.Server, method, path, user string, body []byte) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, ts.URL+path+"?u="+user+"&p=good", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

func TestOwnerSetsACoverEveryoneSees(t *testing.T) {
	ts := coverServer(t)
	picture := pngBytes(t)
	if status, body := coverCall(t, ts, http.MethodPut, "/v1/playlists/mine/cover", "alice", picture); status != http.StatusOK {
		t.Fatalf("save: %d %s", status, body)
	}
	status, body := coverCall(t, ts, http.MethodGet, "/v1/playlists/mine/cover", "bob", nil)
	if status != http.StatusOK || !bytes.Equal(body, picture) {
		t.Fatalf("read: %d, %d bytes", status, len(body))
	}
	status, body = coverCall(t, ts, http.MethodGet, "/v1/playlist-covers", "bob", nil)
	var list struct {
		Covers map[string]int64 `json:"covers"`
	}
	if status != http.StatusOK || json.Unmarshal(body, &list) != nil || list.Covers["mine"] == 0 {
		t.Fatalf("list: %d %s", status, body)
	}
}

func TestOnlyTheOwnerChangesACover(t *testing.T) {
	ts := coverServer(t)
	if status, _ := coverCall(t, ts, http.MethodPut, "/v1/playlists/theirs/cover", "alice", pngBytes(t)); status != http.StatusForbidden {
		t.Fatalf("someone else's playlist: %d", status)
	}
	if status, _ := coverCall(t, ts, http.MethodPut, "/v1/playlists/nope/cover", "alice", pngBytes(t)); status != http.StatusNotFound {
		t.Fatalf("missing playlist: %d", status)
	}
	if status, _ := coverCall(t, ts, http.MethodDelete, "/v1/playlists/theirs/cover", "alice", nil); status != http.StatusForbidden {
		t.Fatalf("delete someone else's: %d", status)
	}
}

func TestRemovingACover(t *testing.T) {
	ts := coverServer(t)
	coverCall(t, ts, http.MethodPut, "/v1/playlists/mine/cover", "alice", pngBytes(t))
	if status, _ := coverCall(t, ts, http.MethodDelete, "/v1/playlists/mine/cover", "alice", nil); status != http.StatusOK {
		t.Fatalf("delete: %d", status)
	}
	if status, _ := coverCall(t, ts, http.MethodGet, "/v1/playlists/mine/cover", "bob", nil); status != http.StatusNotFound {
		t.Fatalf("after delete: %d", status)
	}
}

func TestCoverRejectsNonImagesBadIDsAndStrangers(t *testing.T) {
	ts := coverServer(t)
	if status, _ := coverCall(t, ts, http.MethodPut, "/v1/playlists/mine/cover", "alice", []byte("not a picture")); status != http.StatusBadRequest {
		t.Fatalf("text: %d", status)
	}
	if status, _ := coverCall(t, ts, http.MethodGet, "/v1/playlists/..%2Fetc/cover", "alice", nil); status != http.StatusBadRequest && status != http.StatusNotFound {
		t.Fatalf("bad id: %d", status)
	}
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/playlist-covers?u=alice&p=bad", nil)
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no login: %d", resp.StatusCode)
	}
}

func TestImportedPlaylistsTakePicturesFromTheirOwnerOnly(t *testing.T) {
	ts := coverServer(t)
	if status, body := coverCall(t, ts, http.MethodPut, "/v1/playlists/imported1/cover", "alice", pngBytes(t)); status != http.StatusOK {
		t.Fatalf("owner: %d %s", status, body)
	}
	if status, _ := coverCall(t, ts, http.MethodPut, "/v1/playlists/imported1/cover", "bob", pngBytes(t)); status != http.StatusNotFound {
		t.Fatalf("someone else: %d", status)
	}
}
