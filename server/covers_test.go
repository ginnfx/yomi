package main

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func jpegBytes(t *testing.T, size int) []byte {
	t.Helper()
	var buffer bytes.Buffer
	if err := jpeg.Encode(&buffer, image.NewRGBA(image.Rect(0, 0, size, size)), nil); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

type coverWorld struct {
	fetcher     *CoverFetcher
	root        string
	itunes      atomic.Int32
	musicbrainz atomic.Int32
	userAgents  atomic.Value
	itunesReply func() string
	mbReply     func() string
	art         []byte
	artStatus   int
	lookupFails atomic.Bool
	slept       time.Duration
	now         time.Time
}

func newCoverWorld(t *testing.T) *coverWorld {
	t.Helper()
	world := &coverWorld{
		root:        t.TempDir(),
		art:         jpegBytes(t, 600),
		artStatus:   http.StatusOK,
		itunesReply: func() string { return `{"results":[]}` },
		mbReply:     func() string { return `{"releases":[]}` },
		now:         time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/itunes", func(w http.ResponseWriter, r *http.Request) {
		world.itunes.Add(1)
		world.userAgents.Store(r.UserAgent())
		if world.lookupFails.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte(world.itunesReply()))
	})
	mux.HandleFunc("/mb/", func(w http.ResponseWriter, r *http.Request) {
		world.musicbrainz.Add(1)
		w.Write([]byte(world.mbReply()))
	})
	mux.HandleFunc("/art/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(world.artStatus)
		w.Write(world.art)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	fetcher := newCoverFetcher(world.root, filepath.Join(t.TempDir(), "covers.json"), server.Client())
	fetcher.ITunesURL = server.URL + "/itunes"
	fetcher.MusicBrainzURL = server.URL + "/mb/"
	fetcher.CoverArtURL = server.URL + "/art/"
	fetcher.Now = func() time.Time { return world.now }
	fetcher.Sleep = func(wait time.Duration) {
		world.slept += wait
		world.now = world.now.Add(wait)
	}
	world.fetcher = fetcher
	return world
}

func (w *coverWorld) itunesMatch(artist, album string) func() string {
	return func() string {
		body, _ := json.Marshal(map[string]any{"results": []map[string]string{{
			"artistName":     artist,
			"collectionName": album,
			"artworkUrl100":  strings.TrimSuffix(w.fetcher.CoverArtURL, "/") + "/x/100x100bb.jpg",
		}}})
		return string(body)
	}
}

func (w *coverWorld) addSong(t *testing.T, relative string, content []byte) string {
	t.Helper()
	path := filepath.Join(w.root, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, content, 0o666); err != nil {
		t.Fatal(err)
	}
	return filepath.Dir(path)
}

func hasCoverFile(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, coverFileName))
	return err == nil
}

func TestCoverComesFromITunesOnExactMatch(t *testing.T) {
	world := newCoverWorld(t)
	dir := world.addSong(t, "k/Daft Punk/Discovery/a.mp3", id3File("Daft Punk", "Discovery", "x"))
	world.itunesReply = world.itunesMatch("DAFT PUNK", "Discovery!")

	added, err := world.fetcher.Sweep(context.Background())

	if err != nil || added != 1 || !hasCoverFile(dir) {
		t.Fatalf("added = %d, err = %v, cover = %v", added, err, hasCoverFile(dir))
	}
	if !strings.Contains(world.userAgents.Load().(string), "Yomi") {
		t.Fatalf("user agent = %v", world.userAgents.Load())
	}
}

func TestDifferentEditionIsNotAccepted(t *testing.T) {
	world := newCoverWorld(t)
	dir := world.addSong(t, "k/A/Album/a.mp3", id3File("A", "Album", "x"))
	world.itunesReply = world.itunesMatch("A", "Album (Live)")

	added, _ := world.fetcher.Sweep(context.Background())

	if added != 0 || hasCoverFile(dir) {
		t.Fatal("accepted the wrong album's art")
	}
}

func TestFallsBackToMusicBrainz(t *testing.T) {
	world := newCoverWorld(t)
	dir := world.addSong(t, "k/A/Album/a.mp3", id3File("A", "Album", "x"))
	world.mbReply = func() string {
		return `{"releases":[{"id":"abc","title":"Album","artist-credit":[{"name":"A"}]}]}`
	}

	added, err := world.fetcher.Sweep(context.Background())

	if err != nil || added != 1 || !hasCoverFile(dir) {
		t.Fatalf("added = %d, err = %v", added, err)
	}
}

func TestMusicBrainzIsLimitedToOneRequestPerSecond(t *testing.T) {
	world := newCoverWorld(t)
	for _, album := range []string{"One", "Two", "Three"} {
		world.addSong(t, "k/A/"+album+"/a.mp3", id3File("A", album, "x"))
	}
	var last time.Time
	var tooFast atomic.Bool
	world.mbReply = func() string {
		if !last.IsZero() && world.now.Sub(last) < time.Second {
			tooFast.Store(true)
		}
		last = world.now
		return `{"releases":[]}`
	}

	world.fetcher.Sweep(context.Background())

	if world.musicbrainz.Load() != 3 {
		t.Fatalf("requests = %d", world.musicbrainz.Load())
	}
	if tooFast.Load() {
		t.Fatal("requests came faster than one per second")
	}
}

func TestAlbumWithArtAlreadyIsLeftAlone(t *testing.T) {
	world := newCoverWorld(t)
	dir := world.addSong(t, "k/A/Album/a.mp3", id3File("A", "Album", "x"))
	os.WriteFile(filepath.Join(dir, "folder.jpg"), []byte("mine"), 0o666)

	world.fetcher.Sweep(context.Background())

	if world.itunes.Load() != 0 {
		t.Fatal("looked up an album that already has art")
	}
}

func TestFlatFolderWithSeveralAlbumsGetsNoSharedCover(t *testing.T) {
	world := newCoverWorld(t)
	dir := world.addSong(t, "k/one.mp3", id3File("A", "First", "x"))
	world.addSong(t, "k/two.mp3", id3File("B", "Second", "y"))
	world.itunesReply = world.itunesMatch("A", "First")

	world.fetcher.Sweep(context.Background())

	if hasCoverFile(dir) {
		t.Fatal("one album's art would have covered another's songs")
	}
}

func TestUntaggedSongsAreNotLookedUp(t *testing.T) {
	world := newCoverWorld(t)
	world.addSong(t, "k/a.mp3", mp3Bytes)
	world.fetcher.Sweep(context.Background())
	if world.itunes.Load() != 0 {
		t.Fatal("looked up an untagged song")
	}
}

func TestMissBacksOffThenRetries(t *testing.T) {
	world := newCoverWorld(t)
	world.addSong(t, "k/A/Album/a.mp3", id3File("A", "Album", "x"))

	world.fetcher.Sweep(context.Background())
	world.fetcher.Sweep(context.Background())
	if world.itunes.Load() != 1 {
		t.Fatalf("retried too soon: %d lookups", world.itunes.Load())
	}

	world.now = world.now.Add(firstRetryAfter + time.Minute)
	world.fetcher.Sweep(context.Background())
	if world.itunes.Load() != 2 {
		t.Fatalf("did not retry after the wait: %d lookups", world.itunes.Load())
	}

	world.now = world.now.Add(firstRetryAfter + time.Minute)
	world.fetcher.Sweep(context.Background())
	if world.itunes.Load() != 2 {
		t.Fatalf("second wait should be longer: %d lookups", world.itunes.Load())
	}
}

func TestNetworkFailureIsNotRecordedAsMiss(t *testing.T) {
	world := newCoverWorld(t)
	world.addSong(t, "k/A/Album/a.mp3", id3File("A", "Album", "x"))
	world.lookupFails.Store(true)

	world.fetcher.Sweep(context.Background())
	world.lookupFails.Store(false)
	world.fetcher.Sweep(context.Background())

	if world.itunes.Load() != 2 {
		t.Fatalf("lookups = %d; a failed request must stay due", world.itunes.Load())
	}
}

func TestBadImagesAreRefused(t *testing.T) {
	for name, art := range map[string]func(*testing.T) []byte{
		"not an image": func(*testing.T) []byte { return []byte("<html>") },
		"too small":    func(t *testing.T) []byte { return jpegBytes(t, 50) },
	} {
		t.Run(name, func(t *testing.T) {
			world := newCoverWorld(t)
			dir := world.addSong(t, "k/A/Album/a.mp3", id3File("A", "Album", "x"))
			world.art = art(t)
			world.itunesReply = world.itunesMatch("A", "Album")

			world.fetcher.Sweep(context.Background())

			if hasCoverFile(dir) {
				t.Fatal("kept a bad image")
			}
		})
	}
}

func TestBackoffSurvivesRestart(t *testing.T) {
	world := newCoverWorld(t)
	world.addSong(t, "k/A/Album/a.mp3", id3File("A", "Album", "x"))
	world.fetcher.Sweep(context.Background())

	world.fetcher.misses = nil
	world.fetcher.Sweep(context.Background())

	if world.itunes.Load() != 1 {
		t.Fatalf("lookups after restart = %d", world.itunes.Load())
	}
}

func TestEmbeddedRootsLoad(t *testing.T) {
	if _, err := newInternetClient(); err != nil {
		t.Fatal(err)
	}
}
