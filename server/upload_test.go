package main

import (
	"bytes"
	"context"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var (
	mp3Bytes  = append([]byte("ID3\x04\x00\x00\x00\x00\x00\x00"), bytes.Repeat([]byte{0x01}, 64)...)
	flacBytes = append([]byte("fLaC"), bytes.Repeat([]byte{0x02}, 64)...)
)

type fakeAuth struct{}

func (fakeAuth) Verify(_ context.Context, q url.Values) (string, error) {
	if q.Get("p") == "good" {
		return q.Get("u"), nil
	}
	return "", errUnauthorized
}

func newTestServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	dir := t.TempDir()
	srv := newServer(Config{MusicDir: dir, MaxFileBytes: 1 << 10}, fakeAuth{}, nil)
	ts := httptest.NewServer(srv.routes())
	t.Cleanup(ts.Close)
	return ts, dir
}

func postFile(t *testing.T, base, query, filename string, content []byte) *http.Response {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		t.Fatal(err)
	}
	part.Write(content)
	writer.Close()
	resp, err := http.Post(base+"/upload?"+query, writer.FormDataContentType(), &body)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func TestUploadStoresFileInUserFolder(t *testing.T) {
	ts, dir := newTestServer(t)

	resp := postFile(t, ts.URL, "u=Keli&p=good", "song.mp3", mp3Bytes)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	got, err := os.ReadFile(filepath.Join(dir, "keli", "song.mp3"))
	if err != nil || !bytes.Equal(got, mp3Bytes) {
		t.Fatalf("stored file missing or altered: %v", err)
	}
}

func TestUploadRejectsBadCredentials(t *testing.T) {
	ts, dir := newTestServer(t)

	resp := postFile(t, ts.URL, "u=keli&p=wrong", "song.mp3", mp3Bytes)

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("nothing should be written, found %d entries", len(entries))
	}
}

func TestUploadRejectsNonAudioExtension(t *testing.T) {
	ts, _ := newTestServer(t)

	resp := postFile(t, ts.URL, "u=keli&p=good", "run.sh", []byte("#!/bin/sh\n"))

	if resp.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want 415", resp.StatusCode)
	}
}

func TestUploadRejectsContentThatDoesNotMatchExtension(t *testing.T) {
	ts, dir := newTestServer(t)

	resp := postFile(t, ts.URL, "u=keli&p=good", "fake.mp3", []byte("MZ this is an executable"))

	if resp.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want 415", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(dir, "keli", "fake.mp3")); err == nil {
		t.Fatal("fake file must not be stored")
	}
}

func TestUploadNeverEscapesUserFolder(t *testing.T) {
	ts, dir := newTestServer(t)

	resp := postFile(t, ts.URL, "u=keli&p=good", "../../evil.mp3", mp3Bytes)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (name sanitised)", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(dir, "keli", "evil.mp3")); err != nil {
		t.Fatalf("expected sanitised file inside user folder: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "evil.mp3")); err == nil {
		t.Fatal("file escaped the music directory")
	}
}

func TestUploadRejectsUnsafeUserName(t *testing.T) {
	ts, _ := newTestServer(t)

	resp := postFile(t, ts.URL, "u=..%2F..%2Fetc&p=good", "song.mp3", mp3Bytes)

	if resp.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want 415", resp.StatusCode)
	}
}

func TestDuplicateNamesAreNotOverwritten(t *testing.T) {
	ts, dir := newTestServer(t)

	postFile(t, ts.URL, "u=keli&p=good", "song.flac", flacBytes)
	second := append(append([]byte{}, flacBytes...), 0x09)
	postFile(t, ts.URL, "u=keli&p=good", "song.flac", second)

	first, _ := os.ReadFile(filepath.Join(dir, "keli", "song.flac"))
	copy2, err := os.ReadFile(filepath.Join(dir, "keli", "song (2).flac"))
	if err != nil || !bytes.Equal(first, flacBytes) || !bytes.Equal(copy2, second) {
		t.Fatalf("duplicate handling wrong: %v", err)
	}
}

func TestOversizedFileIsRejectedAndLeavesNoPartialFile(t *testing.T) {
	ts, dir := newTestServer(t)
	big := append([]byte("ID3\x04\x00\x00\x00\x00\x00\x00"), bytes.Repeat([]byte{1}, 3<<20)...)

	resp := postFile(t, ts.URL, "u=keli&p=good", "big.mp3", big)

	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413", resp.StatusCode)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "keli", "*"))
	hidden, _ := filepath.Glob(filepath.Join(dir, "keli", ".*"))
	if len(files)+len(hidden) != 0 {
		t.Fatalf("partial files left behind: %v %v", files, hidden)
	}
}

func TestUploadRequiresPost(t *testing.T) {
	ts, _ := newTestServer(t)

	resp, err := http.Get(ts.URL + "/upload?u=keli&p=good")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", resp.StatusCode)
	}
}

func TestSanitizeNameKeepsUnicodeTitles(t *testing.T) {
	got, err := sanitizeName("全ての人の魂の戦い.mp3")
	if err != nil || got != "全ての人の魂の戦い.mp3" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := sanitizeName(strings.Repeat("a", 200) + ".mp3"); err == nil {
		t.Fatal("overlong names must be rejected")
	}
}

func TestNavidromeAuthAcceptsOnlyOkStatus(t *testing.T) {
	nd := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		status := "failed"
		if r.URL.Query().Get("t") == "goodtoken" {
			status = "ok"
		}
		w.Write([]byte(`{"subsonic-response":{"status":"` + status + `"}}`))
	}))
	defer nd.Close()
	auth := newNavidromeAuth(nd.URL)

	if _, err := auth.Verify(context.Background(), url.Values{"u": {"a"}, "t": {"goodtoken"}, "s": {"x"}}); err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if _, err := auth.Verify(context.Background(), url.Values{"u": {"a"}, "t": {"bad"}, "s": {"x"}}); err == nil {
		t.Fatal("bad token accepted")
	}
	if _, err := auth.Verify(context.Background(), url.Values{"u": {"a"}}); err == nil {
		t.Fatal("missing credentials accepted")
	}
}
