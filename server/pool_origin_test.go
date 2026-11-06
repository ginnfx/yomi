package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func originServer(t *testing.T, handler http.HandlerFunc) navidromeOrigin {
	t.Helper()
	ts := httptest.NewServer(handler)
	t.Cleanup(ts.Close)
	return newNavidromeOrigin(ts.URL + "/")
}

var originLogin = url.Values{"u": {"alice"}, "p": {"good"}}

func TestOriginCoverForwardsLoginAndReturnsBytes(t *testing.T) {
	var seen url.Values
	origin := originServer(t, func(w http.ResponseWriter, r *http.Request) {
		seen = r.URL.Query()
		w.Write([]byte("image-bytes"))
	})

	data, err := origin.Cover(context.Background(), originLogin, "al-1", 300)

	if err != nil || string(data) != "image-bytes" {
		t.Fatalf("got %q, %v", data, err)
	}
	if seen.Get("u") != "alice" || seen.Get("id") != "al-1" || seen.Get("size") != "300" {
		t.Errorf("forwarded query %v", seen)
	}
}

func TestOriginCoverMapsMissingAndFailures(t *testing.T) {
	status := http.StatusNotFound
	origin := originServer(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) })

	if _, err := origin.Cover(context.Background(), originLogin, "x", 1); err != errPoolNotFound {
		t.Errorf("404 gave %v", err)
	}
	status = http.StatusInternalServerError
	if _, err := origin.Cover(context.Background(), originLogin, "x", 1); err == nil || err == errPoolNotFound {
		t.Errorf("500 gave %v", err)
	}
}

func TestOriginCoverRefusesOversizedPictures(t *testing.T) {
	origin := originServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(strings.Repeat("x", poolMaxCoverBytes+1)))
	})

	if _, err := origin.Cover(context.Background(), originLogin, "x", 1); err == nil {
		t.Fatal("an oversized picture must not be accepted")
	}
}

func TestOriginSongReadsSizeAndVersion(t *testing.T) {
	origin := originServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"subsonic-response":{"status":"ok","song":{"size":1234,"contentType":"audio/flac","created":"2026-01-01","bitRate":900,"duration":200}}}`))
	})

	meta, err := origin.Song(context.Background(), originLogin, "s1")

	if err != nil || meta.Size != 1234 || meta.ContentType != "audio/flac" || meta.Version == "" {
		t.Fatalf("got %+v, %v", meta, err)
	}
}

func TestOriginSongTreatsFailedStatusAsMissing(t *testing.T) {
	origin := originServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"subsonic-response":{"status":"failed"}}`))
	})

	if _, err := origin.Song(context.Background(), originLogin, "s1"); err != errPoolNotFound {
		t.Fatalf("got %v", err)
	}
}

func TestOriginSongRangeAsksForRawBytes(t *testing.T) {
	var rangeHeader, format string
	origin := originServer(t, func(w http.ResponseWriter, r *http.Request) {
		rangeHeader, format = r.Header.Get("Range"), r.URL.Query().Get("format")
		w.WriteHeader(http.StatusPartialContent)
		w.Write([]byte("4567"))
	})

	data, err := origin.SongRange(context.Background(), originLogin, "s1", 4, 4)

	if err != nil || string(data) != "4567" {
		t.Fatalf("got %q, %v", data, err)
	}
	if rangeHeader != "bytes=4-7" || format != "raw" {
		t.Errorf("range %q format %q", rangeHeader, format)
	}
}

func TestOriginSongRangeRefusesLaterChunksWhenRangeIsIgnored(t *testing.T) {
	origin := originServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("0123456789"))
	})

	if _, err := origin.SongRange(context.Background(), originLogin, "s1", 4, 4); err == nil {
		t.Fatal("skipping ahead would re-read the whole file for every chunk")
	}
	data, err := origin.SongRange(context.Background(), originLogin, "s1", 0, 4)
	if err != nil || string(data) != "0123" {
		t.Fatalf("the first chunk can still be cut from a full answer: %q, %v", data, err)
	}
}

func TestOriginErrorsDoNotLeakPasswords(t *testing.T) {
	origin := newNavidromeOrigin("http://127.0.0.1:1")

	_, err := origin.Cover(context.Background(), originLogin, "x", 1)

	if err == nil || strings.Contains(err.Error(), "good") {
		t.Fatalf("error %v should exist and not contain the password", err)
	}
}
