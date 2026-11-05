package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// id3File builds an MP3 with a minimal ID3v2.3 tag, so tag handling runs on real parsing.
func id3File(artist, album, body string) []byte {
	frame := func(id, text string) []byte {
		payload := append([]byte{0}, text...)
		size := len(payload)
		header := []byte{id[0], id[1], id[2], id[3], byte(size >> 24), byte(size >> 16), byte(size >> 8), byte(size), 0, 0}
		return append(header, payload...)
	}
	var frames []byte
	if artist != "" {
		frames = append(frames, frame("TPE1", artist)...)
	}
	if album != "" {
		frames = append(frames, frame("TALB", album)...)
	}
	n := len(frames)
	head := []byte{'I', 'D', '3', 3, 0, 0, byte(n >> 21 & 0x7f), byte(n >> 14 & 0x7f), byte(n >> 7 & 0x7f), byte(n & 0x7f)}
	return append(append(head, frames...), body...)
}

func sum(content []byte) string {
	digest := sha256.Sum256(content)
	return hex.EncodeToString(digest[:])
}

type bulkEnv struct {
	url    string
	dir    string
	server *Server
}

func newBulkEnv(t *testing.T) bulkEnv {
	t.Helper()
	dir := t.TempDir()
	index, err := openHashIndex(dir, filepath.Join(t.TempDir(), "index.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	server := newServer(Config{MusicDir: dir, MaxFileBytes: 1 << 20}, fakeAuth{}, nil, index)
	ts := httptest.NewServer(server.routes())
	t.Cleanup(ts.Close)
	return bulkEnv{url: ts.URL, dir: dir, server: server}
}

func (e bulkEnv) put(t *testing.T, hash, name string, content []byte) (int, map[string]string) {
	t.Helper()
	target := e.url + "/v1/upload/" + hash + "?u=keli&p=good&name=" + url.QueryEscape(name)
	req, err := http.NewRequest(http.MethodPut, target, bytes.NewReader(content))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, body
}

func (e bulkEnv) check(t *testing.T, hashes ...string) []string {
	t.Helper()
	payload, _ := json.Marshal(map[string][]string{"hashes": hashes})
	resp, err := http.Post(e.url+"/v1/check?u=keli&p=good", "application/json", bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("check status = %d", resp.StatusCode)
	}
	var body struct {
		Known []string `json:"known"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body.Known
}

func countAudio(t *testing.T, root string) int {
	t.Helper()
	count := 0
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err == nil && !entry.IsDir() && allowedExt[filepath.Ext(path)] {
			count++
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return count
}

func TestBulkUploadFilesByArtistAndAlbum(t *testing.T) {
	env := newBulkEnv(t)
	content := id3File("Daft Punk", "Discovery", "audio")

	status, body := env.put(t, sum(content), "One More Time.mp3", content)

	if status != http.StatusCreated {
		t.Fatalf("status = %d, body = %v", status, body)
	}
	want := filepath.Join("keli", "Daft Punk", "Discovery", "One More Time.mp3")
	if body["file"] != want {
		t.Fatalf("file = %q, want %q", body["file"], want)
	}
	if _, err := os.Stat(filepath.Join(env.dir, want)); err != nil {
		t.Fatal(err)
	}
}

func TestUntaggedSongGoesInUserFolder(t *testing.T) {
	env := newBulkEnv(t)
	_, body := env.put(t, sum(mp3Bytes), "song.mp3", mp3Bytes)
	if body["file"] != filepath.Join("keli", "song.mp3") {
		t.Fatalf("file = %q", body["file"])
	}
}

func TestSecondUploadOfSameContentStoresNothing(t *testing.T) {
	env := newBulkEnv(t)
	content := id3File("A", "B", "audio")
	hash := sum(content)
	env.put(t, hash, "one.mp3", content)

	status, body := env.put(t, hash, "renamed copy.mp3", content)

	if status != http.StatusOK || body["status"] != "duplicate" {
		t.Fatalf("status = %d, body = %v", status, body)
	}
	if got := countAudio(t, env.dir); got != 1 {
		t.Fatalf("files on disk = %d, want 1", got)
	}
}

func TestCheckReportsKnownHashes(t *testing.T) {
	env := newBulkEnv(t)
	content := id3File("A", "B", "audio")
	known := sum(content)
	env.put(t, known, "one.mp3", content)
	unknown := sum([]byte("something else"))

	got := env.check(t, known, unknown)

	if len(got) != 1 || got[0] != known {
		t.Fatalf("known = %v", got)
	}
}

func TestCheckRejectsBadInput(t *testing.T) {
	env := newBulkEnv(t)
	for name, payload := range map[string]string{
		"not json": "nope",
		"bad hash": `{"hashes":["XYZ"]}`,
		"too many": `{"hashes":[` + strings.TrimSuffix(strings.Repeat(`"a",`, maxCheckHashes+1), ",") + `]}`,
	} {
		resp, err := http.Post(env.url+"/v1/check?u=keli&p=good", "application/json", strings.NewReader(payload))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status = %d", name, resp.StatusCode)
		}
	}
}

func TestBulkRoutesRequireLogin(t *testing.T) {
	env := newBulkEnv(t)
	resp, err := http.Post(env.url+"/v1/check?u=keli&p=wrong", "application/json", strings.NewReader(`{"hashes":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d", resp.StatusCode)
	}
}

func TestCorruptedTransferIsRejectedAndNotKept(t *testing.T) {
	env := newBulkEnv(t)
	status, _ := env.put(t, sum([]byte("expected")), "song.mp3", mp3Bytes)
	if status != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d", status)
	}
	if got := countAudio(t, env.dir); got != 0 {
		t.Fatalf("files on disk = %d", got)
	}
}

func TestNonAudioIsRejected(t *testing.T) {
	env := newBulkEnv(t)
	content := []byte("<html>not a song</html>")
	status, _ := env.put(t, sum(content), "song.mp3", content)
	if status != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d", status)
	}
}

func TestOversizeFileIsRejected(t *testing.T) {
	env := newBulkEnv(t)
	content := append(bytes.Clone(mp3Bytes), make([]byte, 2<<20)...)
	status, _ := env.put(t, sum(content), "big.mp3", content)
	if status != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d", status)
	}
}

func TestBusyServerAsksClientToWait(t *testing.T) {
	env := newBulkEnv(t)
	for range maxConcurrentUploads {
		env.server.slots <- struct{}{}
	}
	req, _ := http.NewRequest(http.MethodPut, env.url+"/v1/upload/"+sum(mp3Bytes)+"?u=keli&p=good&name=a.mp3", bytes.NewReader(mp3Bytes))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("status = %d, retry-after = %q", resp.StatusCode, resp.Header.Get("Retry-After"))
	}
}

func TestFolderNamesCannotEscapeOrBreakFAT32(t *testing.T) {
	env := newBulkEnv(t)
	content := id3File("../../evil", `AC/DC: "Live"?`, "audio")
	_, body := env.put(t, sum(content), "song.mp3", content)
	// Slashes are stripped and edge dots trimmed, so traversal is only ever a harmless name.
	want := filepath.Join("keli", "evil", "ACDC Live", "song.mp3")
	if body["file"] != want {
		t.Fatalf("file = %q, want %q", body["file"], want)
	}
}

func TestSanitizeNameForFAT32(t *testing.T) {
	cases := map[string]string{
		`what? *why*.mp3`:      "what why.mp3",
		`"quote" <a|b>.flac`:   "quote ab.flac",
		`trailing dots....mp3`: "trailing dots.mp3",
		`spaces   .mp3`:        "spaces.mp3",
	}
	for input, want := range cases {
		got, err := sanitizeName(input)
		if err != nil || got != want {
			t.Errorf("sanitizeName(%q) = %q, %v; want %q", input, got, err, want)
		}
	}
	if _, err := sanitizeName("....mp3"); err == nil {
		t.Error("a name of only dots should be refused")
	}
}

func TestSanitizeFolder(t *testing.T) {
	cases := map[string]string{
		"..":                    "",
		" . ":                   "",
		`A/B\C`:                 "ABC",
		"Dotted.":               "Dotted",
		"..Hidden":              "Hidden",
		strings.Repeat("é", 60): strings.Repeat("é", 40),
	}
	for input, want := range cases {
		if got := sanitizeFolder(input); got != want {
			t.Errorf("sanitizeFolder(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestFolderCaseCollisionReusesExisting(t *testing.T) {
	env := newBulkEnv(t)
	first := id3File("The Beatles", "Abbey Road", "one")
	second := id3File("the beatles", "ABBEY ROAD", "two")
	env.put(t, sum(first), "a.mp3", first)
	_, body := env.put(t, sum(second), "b.mp3", second)
	if body["file"] != filepath.Join("keli", "The Beatles", "Abbey Road", "b.mp3") {
		t.Fatalf("file = %q", body["file"])
	}
}

func TestIndexSurvivesRestartAndToleratesDamage(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(t.TempDir(), "index.jsonl")
	index, _ := openHashIndex(root, file)
	song := filepath.Join(root, "a.mp3")
	os.WriteFile(song, mp3Bytes, 0o666)
	hash := sum(mp3Bytes)
	if err := index.Add(indexEntry{SHA256: hash, Path: "a.mp3", Size: 1}); err != nil {
		t.Fatal(err)
	}
	handle, _ := os.OpenFile(file, os.O_APPEND|os.O_WRONLY, 0o666)
	handle.WriteString(`{"sha256":"torn`)
	handle.Close()

	reopened, err := openHashIndex(root, file)
	if err != nil {
		t.Fatal(err)
	}
	if _, found := reopened.Lookup(hash); !found {
		t.Fatal("entry lost after restart")
	}
	if reopened.Count() != 1 {
		t.Fatalf("count = %d", reopened.Count())
	}
}

func TestDeletedFileCanBeUploadedAgain(t *testing.T) {
	env := newBulkEnv(t)
	content := id3File("A", "B", "audio")
	hash := sum(content)
	_, body := env.put(t, hash, "one.mp3", content)
	os.Remove(filepath.Join(env.dir, body["file"]))

	status, _ := env.put(t, hash, "one.mp3", content)

	if status != http.StatusCreated {
		t.Fatalf("status = %d", status)
	}
}

func TestSeedIndexesExistingFilesAndClearsStaleTemps(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "keli"), 0o777)
	os.WriteFile(filepath.Join(root, "keli", "old.mp3"), mp3Bytes, 0o666)
	os.WriteFile(filepath.Join(root, "keli", "cover.jpg"), []byte("img"), 0o666)
	stale := filepath.Join(root, "keli", ".upload-123.tmp")
	os.WriteFile(stale, []byte("partial"), 0o666)
	longAgo := time.Now().Add(-2 * staleTempAfter)
	os.Chtimes(stale, longAgo, longAgo)
	live := filepath.Join(root, "keli", ".upload-456.tmp")
	os.WriteFile(live, []byte("in progress"), 0o666)
	index, _ := openHashIndex(root, filepath.Join(t.TempDir(), "index.jsonl"))

	index.Seed()
	index.Seed() // a second pass must not re-hash or duplicate anything

	if _, found := index.Lookup(sum(mp3Bytes)); !found {
		t.Fatal("existing song was not indexed")
	}
	if index.Count() != 1 {
		t.Fatalf("count = %d", index.Count())
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("stale temp file was left behind")
	}
	if _, err := os.Stat(live); err != nil {
		t.Fatal("removed a temp file that may be an upload in progress")
	}
}

func TestLegacyUploadAlsoCountsAsDuplicate(t *testing.T) {
	env := newBulkEnv(t)
	resp := postFile(t, env.url, "u=keli&p=good", "song.mp3", mp3Bytes)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(env.check(t, sum(mp3Bytes))) == 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("legacy upload never reached the index")
}

func TestScanDebounceFiresOnceAfterQuiet(t *testing.T) {
	var scans atomic.Int32
	debouncer := newScanDebouncer(30*time.Millisecond, func(context.Context, url.Values) { scans.Add(1) })
	for range 5 {
		debouncer.Touch(url.Values{"u": {"keli"}})
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	if scans.Load() != 1 {
		t.Fatalf("scans = %d, want 1", scans.Load())
	}
}

type countingAuth struct {
	calls atomic.Int32
	err   error
}

func (a *countingAuth) Verify(context.Context, url.Values) (string, error) {
	a.calls.Add(1)
	return "keli", a.err
}

func TestAuthCacheAvoidsRepeatLookupsUntilExpiry(t *testing.T) {
	inner := &countingAuth{}
	cached := newCachedAuth(inner)
	now := time.Now()
	cached.now = func() time.Time { return now }
	query := url.Values{"u": {"keli"}, "t": {"tok"}, "s": {"salt"}}

	for range 3 {
		if _, err := cached.Verify(context.Background(), query); err != nil {
			t.Fatal(err)
		}
	}
	if inner.calls.Load() != 1 {
		t.Fatalf("calls = %d", inner.calls.Load())
	}
	now = now.Add(authCacheFor + time.Second)
	cached.Verify(context.Background(), query)
	if inner.calls.Load() != 2 {
		t.Fatalf("calls after expiry = %d", inner.calls.Load())
	}
}

func TestAuthCacheNeverRemembersFailures(t *testing.T) {
	inner := &countingAuth{err: errors.New("wrong")}
	cached := newCachedAuth(inner)
	query := url.Values{"u": {"keli"}, "p": {"bad"}}
	cached.Verify(context.Background(), query)
	cached.Verify(context.Background(), query)
	if inner.calls.Load() != 2 {
		t.Fatalf("calls = %d", inner.calls.Load())
	}
}

func TestDifferentPasswordIsNotServedFromCache(t *testing.T) {
	inner := &countingAuth{}
	cached := newCachedAuth(inner)
	cached.Verify(context.Background(), url.Values{"u": {"keli"}, "p": {"good"}})
	cached.Verify(context.Background(), url.Values{"u": {"keli"}, "p": {"other"}})
	if inner.calls.Load() != 2 {
		t.Fatalf("calls = %d", inner.calls.Load())
	}
}

func TestRequestErrorsNeverContainCredentials(t *testing.T) {
	dead := httptest.NewServer(http.NotFoundHandler())
	address := dead.URL
	dead.Close()
	auth := newNavidromeAuth(address)

	_, err := auth.Verify(context.Background(), url.Values{"u": {"keli"}, "p": {"hunter2"}, "t": {"tok"}, "s": {"salty"}})

	if err == nil {
		t.Fatal("expected an error")
	}
	for _, secret := range []string{"hunter2", "tok", "salty"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error exposes %q: %v", secret, err)
		}
	}
}

func TestWrongPasswordsCannotLockOutSomeoneAlreadyLoggedIn(t *testing.T) {
	dir := t.TempDir()
	index, _ := openHashIndex(dir, filepath.Join(t.TempDir(), "i.jsonl"))
	server := newServer(Config{MusicDir: dir, MaxFileBytes: 1 << 10}, newCachedAuth(fakeAuth{}), nil, index)
	ts := httptest.NewServer(server.routes())
	defer ts.Close()
	check := func(password string) int {
		resp, err := http.Post(ts.URL+"/v1/check?u=keli&p="+password, "application/json", strings.NewReader(`{"hashes":[]}`))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := check("good"); code != http.StatusOK {
		t.Fatalf("login = %d", code)
	}
	for range maxFailedLogins + 1 {
		check("guess")
	}
	if code := check("guess"); code != http.StatusTooManyRequests {
		t.Fatalf("attacker = %d, want locked out", code)
	}
	if code := check("good"); code != http.StatusOK {
		t.Fatalf("real user = %d, want still working", code)
	}
}

func TestGoodLoginsDoNotClearAttemptsAgainstTheAccount(t *testing.T) {
	dir := t.TempDir()
	index, _ := openHashIndex(dir, filepath.Join(t.TempDir(), "i.jsonl"))
	server := newServer(Config{MusicDir: dir, MaxFileBytes: 1 << 10}, newCachedAuth(fakeAuth{}), nil, index)
	ts := httptest.NewServer(server.routes())
	defer ts.Close()
	check := func(password string) int {
		resp, err := http.Post(ts.URL+"/v1/check?u=keli&p="+password, "application/json", strings.NewReader(`{"hashes":[]}`))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	for i := range maxFailedLogins {
		check("guess")
		if i < maxFailedLogins-1 {
			check("good") // The victim's app polling between guesses.
		}
	}
	if code := check("guess"); code != http.StatusTooManyRequests {
		t.Fatalf("code = %d: polling reset the guess counter", code)
	}
}

func TestBulkLongFilenameDoesNotStallQueue(t *testing.T) {
	env := newBulkEnv(t)
	content := id3File("Artist", "Album", strings.Repeat("audio", 100000))
	name := "Monotonously Rings the Little Bell - " + strings.Repeat("Performer, ", 20) + ".mp3"
	status, body := env.put(t, sum(content), name, content)
	if status != http.StatusCreated {
		t.Fatalf("long filename status %d: %v", status, body)
	}
	if len(filepath.Base(body["file"])) > maxNameBytes {
		t.Fatal("stored name exceeds limit")
	}
	if _, err := os.Stat(filepath.Join(env.dir, body["file"])); err != nil {
		t.Fatal(err)
	}
	next := id3File("Artist", "Album", "next track")
	if status, _ := env.put(t, sum(next), "next.mp3", next); status != http.StatusCreated {
		t.Fatalf("next upload status %d", status)
	}
}
