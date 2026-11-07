package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestReportCompletionValidatesSongAndRedactsPrivateDetails(t *testing.T) {
	e := newReportsEnv(t)
	report, _, err := e.server.Reports.Add("alice", ReportInput{Kind: reportMissingSong, Title: "wanted", Note: "private"})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"", "nonexistent"} {
		status, _ := e.call(t, http.MethodPost, "/v1/reports/"+report.ID+"/added", "bob", map[string]string{"songId": id})
		if status != 400 {
			t.Fatalf("invalid song accepted: %d", status)
		}
	}
	e.songPath["present"] = "song.mp3"
	status, data := e.call(t, http.MethodPost, "/v1/reports/"+report.ID+"/added", "bob", map[string]string{"songId": "present"})
	if status != 200 {
		t.Fatalf("%d %s", status, data)
	}
	var got Report
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Reporters) != 0 || len(got.Notes) != 0 || got.Status != reportResolved {
		t.Fatalf("private completion: %+v", got)
	}
}

func TestImportedCoverIDsAreScopedToTheirUser(t *testing.T) {
	ts := coverServer(t)
	picture := pngBytes(t)
	if status, b := coverCall(t, ts, http.MethodPut, "/v1/playlists/imported1/cover", "alice", picture); status != 200 {
		t.Fatalf("%d %s", status, b)
	}
	if status, b := coverCall(t, ts, http.MethodPut, "/v1/imports/imported1", "bob", []byte(`{"id":"imported1"}`)); status != 200 {
		t.Fatalf("%d %s", status, b)
	}
	if status, b := coverCall(t, ts, http.MethodDelete, "/v1/playlists/imported1/cover", "bob", nil); status != 200 {
		t.Fatalf("%d %s", status, b)
	}
	status, b := coverCall(t, ts, http.MethodGet, "/v1/playlists/imported1/cover", "alice", nil)
	if status != 200 || !bytes.Equal(b, picture) {
		t.Fatalf("Alice's cover removed: %d", status)
	}
	_, b = coverCall(t, ts, http.MethodGet, "/v1/playlist-covers", "bob", nil)
	var list struct {
		Covers map[string]int64 `json:"covers"`
	}
	json.Unmarshal(b, &list)
	if list.Covers["imported1"] != 0 {
		t.Fatal("Bob saw Alice's imported cover")
	}
}

func TestMissingSongNotesAreDeduplicatedAndBounded(t *testing.T) {
	e := newReportsEnv(t)
	for j := 0; j < 250; j++ {
		if _, _, err := e.server.Reports.Add("alice", ReportInput{Kind: reportMissingSong, Title: "same", Note: "repeat"}); err != nil {
			t.Fatal(err)
		}
	}
	reports := e.server.Reports.List("admin", true)
	if len(reports[0].Notes) != 1 {
		t.Fatal("retry duplicated notes")
	}
	for j := 1; j < maxReportNotes; j++ {
		if _, _, err := e.server.Reports.Add("alice", ReportInput{Kind: reportMissingSong, Title: "same", Note: fmt.Sprint(j)}); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := e.server.Reports.Add("alice", ReportInput{Kind: reportMissingSong, Title: "same", Note: "overflow"}); err != errTooManyReports {
		t.Fatalf("unbounded notes: %v", err)
	}
}

func TestReplicaPreservesDuplicateContentPaths(t *testing.T) {
	w := newReplicaWorld(t)
	w.addToPrimary(t, "alice/song.mp3", mp3Bytes)
	w.addToPrimary(t, "bob/song.mp3", mp3Bytes)
	if err := w.sync.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"alice/song.mp3", "bob/song.mp3"} {
		data, err := os.ReadFile(filepath.Join(w.root, path))
		if err != nil || !bytes.Equal(data, mp3Bytes) {
			t.Fatalf("missing duplicate %s: %v", path, err)
		}
	}
	if err := w.sync.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestChangedLibraryFileReplacesPersistedHash(t *testing.T) {
	w := newReplicaWorld(t)
	w.addToPrimary(t, "alice/song.mp3", mp3Bytes)
	changed := append([]byte(nil), mp3Bytes...)
	changed[len(changed)-1]++
	if err := os.WriteFile(filepath.Join(w.primary.Config.MusicDir, "alice/song.mp3"), changed, 0600); err != nil {
		t.Fatal(err)
	}
	w.primary.Index.Seed()
	if _, ok := w.primary.Index.Lookup(sum(mp3Bytes)); ok {
		t.Fatal("old hash retained")
	}
	index, err := openHashIndex(w.primary.Config.MusicDir, w.primary.Index.file)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := index.Lookup(sum(mp3Bytes)); ok {
		t.Fatal("old hash restored on restart")
	}
	if _, ok := index.Lookup(sum(changed)); !ok {
		t.Fatal("new hash absent")
	}
	if err := w.sync.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestStateDeletionPropagatesAcrossReplicaRestart(t *testing.T) {
	primaryH := openTestHistory(t)
	replicaH := openTestHistory(t)
	if err := primaryH.SaveImport("alice", "playlist", []byte(`{"id":"playlist"}`)); err != nil {
		t.Fatal(err)
	}
	primary := newServer(Config{NavidromeURL: adminNavidrome(t)}, adminAuth{}, nil, nil)
	primary.History = primaryH
	ts := httptest.NewServer(primary.routes())
	defer ts.Close()
	syncer := &StateSync{PrimaryURL: ts.URL, Login: url.Values{"u": {"admin"}, "p": {"good"}}, Client: ts.Client(), Roots: map[string]string{stateRootHistory: replicaH.dir}}
	if err := syncer.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := primaryH.DeleteImport("alice", "playlist"); err != nil {
		t.Fatal(err)
	}
	syncer.seen = nil
	if err := syncer.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if replicaH.HasImport("alice", "playlist") {
		t.Fatal("deleted playlist remains")
	}
}

func TestProfileImageDeleteAndDeviceUnregister(t *testing.T) {
	env := newSocialEnv(t, Config{})
	if err := env.store.SaveAvatar("keli", pngBytes(t)); err != nil {
		t.Fatal(err)
	}
	if err := env.store.SaveBanner("keli", pngBytes(t)); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"avatar", "banner"} {
		status, b := env.call(t, http.MethodDelete, "/v1/profile/"+kind, "keli", nil)
		if status != 200 {
			t.Fatalf("delete %s: %d %s", kind, status, b)
		}
	}
	for _, profile := range env.store.Profiles() {
		if profile.User == "keli" && (profile.HasAvatar || profile.HasBanner) {
			t.Fatal("image metadata retained")
		}
	}
	if err := env.store.AddDevice("keli", "apns:device"); err != nil {
		t.Fatal(err)
	}
	if err := env.store.AddDevice("sam", "apns:device"); err != nil {
		t.Fatal(err)
	}
	if len(env.store.Devices("keli")) != 0 {
		t.Fatal("device retained by old account")
	}
	status, b := env.call(t, http.MethodDelete, "/v1/devices", "sam", map[string]string{"token": "device", "kind": "apns"})
	if status != 200 {
		t.Fatalf("unregister: %d %s", status, b)
	}
	if len(env.store.Devices("sam")) != 0 {
		t.Fatal("device not removed")
	}
}

func TestLegacyImportedCoverRemainsReadableWithoutSharedMutation(t *testing.T) {
	// A standalone server exposes the store for constructing legacy state.
	dir := t.TempDir()
	server := newServer(Config{}, fakeAuth{}, nil, nil)
	server.PlaylistCovers, _ = openPlaylistCoverStore(filepath.Join(dir, "covers"))
	server.History, _ = openHistoryStore(filepath.Join(dir, "history"))
	server.History.SaveImport("alice", "legacy", []byte(`{}`))
	server.PlaylistOwner = func(context.Context, url.Values, string) (string, error) { return "", errNoSuchPlaylist }
	picture := pngBytes(t)
	server.PlaylistCovers.Save("legacy", picture)
	legacy := httptest.NewServer(server.routes())
	defer legacy.Close()
	status, b := coverCall(t, legacy, http.MethodGet, "/v1/playlists/legacy/cover", "alice", nil)
	if status != 200 || !bytes.Equal(b, picture) {
		t.Fatalf("legacy lost: %d", status)
	}
	status, b = coverCall(t, legacy, http.MethodDelete, "/v1/playlists/legacy/cover", "alice", nil)
	if status != 200 {
		t.Fatalf("delete %d %s", status, b)
	}
	status, _ = coverCall(t, legacy, http.MethodGet, "/v1/playlists/legacy/cover", "alice", nil)
	if status != 404 {
		t.Fatal("legacy fallback resurrected after delete")
	}
	if _, _, err := server.PlaylistCovers.Read("legacy"); err != nil {
		t.Fatal("global cover modified")
	}
}
