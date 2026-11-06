package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const testChunk = 4

// fakeOrigin stands in for Navidrome and counts how often it is bothered.
type fakeOrigin struct {
	cover       []byte
	song        []byte
	version     string
	coverCalls  atomic.Int32
	songCalls   atomic.Int32
	rangeCalls  atomic.Int32
	shortRanges bool
	delay       time.Duration
}

func (o *fakeOrigin) Cover(_ context.Context, _ url.Values, id string, _ int) ([]byte, error) {
	o.coverCalls.Add(1)
	time.Sleep(o.delay)
	if id == "missing" {
		return nil, errPoolNotFound
	}
	return o.cover, nil
}

func (o *fakeOrigin) Song(_ context.Context, _ url.Values, id string) (SongMeta, error) {
	o.songCalls.Add(1)
	if id == "missing" {
		return SongMeta{}, errPoolNotFound
	}
	return SongMeta{Size: int64(len(o.song)), Version: o.version, ContentType: "audio/mpeg"}, nil
}

func (o *fakeOrigin) SongRange(_ context.Context, _ url.Values, _ string, start, length int64) ([]byte, error) {
	o.rangeCalls.Add(1)
	time.Sleep(o.delay)
	end := min(start+length, int64(len(o.song)))
	data := o.song[start:end]
	if o.shortRanges && len(data) > 1 {
		return data[:len(data)-1], nil
	}
	return data, nil
}

func poolTestServer(t *testing.T, origin *fakeOrigin) *httptest.Server {
	t.Helper()
	store, err := openPoolStore(t.TempDir(), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	pool, err := newPool(store, origin, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	pool.ChunkSize = testChunk
	server := newServer(Config{MusicDir: t.TempDir()}, fakeAuth{}, nil, nil)
	server.Pool = pool
	ts := httptest.NewServer(server.routes())
	t.Cleanup(ts.Close)
	return ts
}

func poolGet(t *testing.T, ts *httptest.Server, path string, headers map[string]string) (*http.Response, []byte) {
	t.Helper()
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequest(http.MethodGet, ts.URL+path, nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp, body
}

func authed(path, user string) string {
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	return path + sep + "u=" + user + "&p=good"
}

func TestCoverIsFetchedFromOriginOnceForEveryUser(t *testing.T) {
	origin := &fakeOrigin{cover: pngBytes(t)}
	ts := poolTestServer(t, origin)

	first, _ := poolGet(t, ts, authed("/v1/pool/cover/al-1?size=300", "alice"), nil)
	second, _ := poolGet(t, ts, authed("/v1/pool/cover/al-1?size=300", "bob"), nil)

	if first.StatusCode != http.StatusFound || first.Header.Get("Location") != second.Header.Get("Location") {
		t.Fatalf("both users should be sent to the same blob: %v vs %v", first.Header, second.Header)
	}
	if got := origin.coverCalls.Load(); got != 1 {
		t.Fatalf("origin asked %d times, want 1", got)
	}
}

func TestCoverBlobIsContentAddressedAndImmutable(t *testing.T) {
	image := pngBytes(t)
	ts := poolTestServer(t, &fakeOrigin{cover: image})
	redirect, _ := poolGet(t, ts, authed("/v1/pool/cover/al-1", "alice"), nil)
	want := redirect.Header.Get("Location")
	plain := sha256.Sum256(image)
	if !strings.HasPrefix(want, "/v1/pool/blob/") || strings.HasSuffix(want, hex.EncodeToString(plain[:])) {
		t.Fatalf("location %q must be a keyed hash, not the plain SHA-256", want)
	}

	resp, body := poolGet(t, ts, want, nil)

	if resp.StatusCode != http.StatusOK || !bytes.Equal(body, image) {
		t.Fatalf("status %d, body matches: %v", resp.StatusCode, bytes.Equal(body, image))
	}
	if cc := resp.Header.Get("Cache-Control"); !strings.Contains(cc, "immutable") || !strings.Contains(cc, "public") {
		t.Errorf("Cache-Control %q should be public and immutable", cc)
	}
	if resp.Header.Get("ETag") == "" || resp.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("missing ETag or nosniff: %v", resp.Header)
	}
}

func TestBlobAnswersNotModifiedForRepeatVisits(t *testing.T) {
	ts := poolTestServer(t, &fakeOrigin{cover: pngBytes(t)})
	redirect, _ := poolGet(t, ts, authed("/v1/pool/cover/al-1", "alice"), nil)
	path := redirect.Header.Get("Location")
	first, _ := poolGet(t, ts, path, nil)

	again, _ := poolGet(t, ts, path, map[string]string{"If-None-Match": first.Header.Get("ETag")})

	if again.StatusCode != http.StatusNotModified {
		t.Fatalf("status %d, want 304", again.StatusCode)
	}
}

func TestSeparateSizesOfOneCoverAreSeparateEntries(t *testing.T) {
	origin := &fakeOrigin{cover: pngBytes(t)}
	ts := poolTestServer(t, origin)

	poolGet(t, ts, authed("/v1/pool/cover/al-1?size=100", "alice"), nil)
	poolGet(t, ts, authed("/v1/pool/cover/al-1?size=600", "alice"), nil)

	if got := origin.coverCalls.Load(); got != 2 {
		t.Fatalf("origin asked %d times, want 2", got)
	}
}

func TestConcurrentFirstFetchesShareOneOriginRequest(t *testing.T) {
	origin := &fakeOrigin{cover: pngBytes(t), delay: 50 * time.Millisecond}
	ts := poolTestServer(t, origin)

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			poolGet(t, ts, authed("/v1/pool/cover/al-1", fmt.Sprintf("user%d", i)), nil)
		}()
	}
	wg.Wait()

	if got := origin.coverCalls.Load(); got != 1 {
		t.Fatalf("origin asked %d times, want 1", got)
	}
}

func TestCoverRoutesRequireLoginAndValidInput(t *testing.T) {
	ts := poolTestServer(t, &fakeOrigin{cover: pngBytes(t)})
	cases := []struct {
		path string
		want int
	}{
		{"/v1/pool/cover/al-1", http.StatusUnauthorized},
		{authed("/v1/pool/cover/al-1?size=abc", "alice"), http.StatusBadRequest},
		{authed("/v1/pool/cover/al-1?size=99999", "alice"), http.StatusBadRequest},
		{authed("/v1/pool/cover/missing", "alice"), http.StatusNotFound},
		{"/v1/pool/blob/nothex", http.StatusNotFound},
		{"/v1/pool/blob/" + strings.Repeat("a", 64), http.StatusNotFound},
	}
	for _, c := range cases {
		if resp, _ := poolGet(t, ts, c.path, nil); resp.StatusCode != c.want {
			t.Errorf("%s: status %d, want %d", c.path, resp.StatusCode, c.want)
		}
	}
}

func TestCoverThatIsNotAnImageIsNeverStored(t *testing.T) {
	origin := &fakeOrigin{cover: []byte("<html>login page</html>")}
	ts := poolTestServer(t, origin)

	resp, _ := poolGet(t, ts, authed("/v1/pool/cover/al-1", "alice"), nil)

	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status %d, want 502", resp.StatusCode)
	}
}

var testSong = []byte("0123456789abcdefghij") // 20 bytes = 5 chunks of 4

func TestSongRangeIsAssembledAcrossChunks(t *testing.T) {
	origin := &fakeOrigin{song: testSong, version: "v1"}
	ts := poolTestServer(t, origin)

	resp, body := poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), map[string]string{"Range": "bytes=2-9"})

	if resp.StatusCode != http.StatusPartialContent || string(body) != "23456789" {
		t.Fatalf("status %d body %q", resp.StatusCode, body)
	}
	if resp.Header.Get("Content-Type") != "audio/mpeg" || resp.Header.Get("Accept-Ranges") != "bytes" {
		t.Errorf("headers: %v", resp.Header)
	}
}

func TestWholeSongMatchesOrigin(t *testing.T) {
	ts := poolTestServer(t, &fakeOrigin{song: testSong, version: "v1"})

	resp, body := poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), nil)

	if resp.StatusCode != http.StatusOK || !bytes.Equal(body, testSong) {
		t.Fatalf("status %d body %q", resp.StatusCode, body)
	}
}

func TestSecondListenerNeverTouchesOriginForChunks(t *testing.T) {
	origin := &fakeOrigin{song: testSong, version: "v1"}
	ts := poolTestServer(t, origin)
	poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), nil)
	before := origin.rangeCalls.Load()

	_, body := poolGet(t, ts, authed("/v1/pool/song/s1", "bob"), nil)

	if !bytes.Equal(body, testSong) || origin.rangeCalls.Load() != before {
		t.Fatalf("origin range calls went from %d to %d", before, origin.rangeCalls.Load())
	}
}

func TestOnlyTheChunksNeededAreFetched(t *testing.T) {
	origin := &fakeOrigin{song: testSong, version: "v1"}
	ts := poolTestServer(t, origin)

	poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), map[string]string{"Range": "bytes=16-19"})

	if got := origin.rangeCalls.Load(); got != 1 {
		t.Fatalf("origin range calls %d, want 1", got)
	}
}

func TestReplacedFileGetsFreshChunks(t *testing.T) {
	origin := &fakeOrigin{song: testSong, version: "v1"}
	ts := poolTestServer(t, origin)
	poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), nil)
	origin.song = []byte("ZZZZZZZZZZZZZZZZZZZZ")
	origin.version = "v2"
	// expire the remembered song details by using a fresh server over the same origin
	ts2 := poolTestServer(t, origin)

	_, body := poolGet(t, ts2, authed("/v1/pool/song/s1", "alice"), nil)

	if string(body) != "ZZZZZZZZZZZZZZZZZZZZ" {
		t.Fatalf("served stale audio: %q", body)
	}
}

func TestTruncatedOriginChunkIsNotCached(t *testing.T) {
	origin := &fakeOrigin{song: testSong, version: "v1", shortRanges: true}
	ts := poolTestServer(t, origin)

	_, body1 := poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), map[string]string{"Range": "bytes=0-3"})
	origin.shortRanges = false
	_, body := poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), map[string]string{"Range": "bytes=0-3"})

	if len(body1) >= len("0123") {
		t.Errorf("a truncated chunk was served as if complete: %q", body1)
	}
	if string(body) != "0123" {
		t.Fatalf("a short chunk poisoned the cache: %q", body)
	}
}

func TestChunkRouteServesOnlyChunksAlreadyInThePool(t *testing.T) {
	origin := &fakeOrigin{song: testSong, version: "v1"}
	ts := poolTestServer(t, origin)
	stream, _ := poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), map[string]string{"Range": "bytes=0-3"})
	key := stream.Header.Get("X-Yomi-Pool-Key")
	if key == "" {
		t.Fatal("the stream must advertise its pool key")
	}

	hit, body := poolGet(t, ts, "/v1/pool/audio/"+key+"/0", nil)
	miss, _ := poolGet(t, ts, "/v1/pool/audio/"+key+"/4", nil)

	if hit.StatusCode != http.StatusOK || string(body) != "0123" {
		t.Fatalf("hit: status %d body %q", hit.StatusCode, body)
	}
	if !strings.Contains(hit.Header.Get("Cache-Control"), "immutable") {
		t.Errorf("chunk should be immutable: %v", hit.Header)
	}
	if miss.StatusCode != http.StatusNotFound {
		t.Fatalf("an unfetched chunk should 404, got %d", miss.StatusCode)
	}
}

func TestSongRouteRequiresLoginAndKnownSong(t *testing.T) {
	ts := poolTestServer(t, &fakeOrigin{song: testSong, version: "v1"})

	if resp, _ := poolGet(t, ts, "/v1/pool/song/s1", nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("anonymous status %d", resp.StatusCode)
	}
	if resp, _ := poolGet(t, ts, authed("/v1/pool/song/missing", "alice"), nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("missing song status %d", resp.StatusCode)
	}
	if resp, _ := poolGet(t, ts, authed("/v1/pool/song/bad%2Fid", "alice"), nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("bad id status %d", resp.StatusCode)
	}
}

func TestPoolKeyIsStableAcrossRestartsButNotGuessable(t *testing.T) {
	dir := t.TempDir()
	storeDir := t.TempDir()
	store, _ := openPoolStore(storeDir, 1<<20)
	first, _ := newPool(store, &fakeOrigin{}, dir)
	second, _ := newPool(store, &fakeOrigin{}, dir)
	other, _ := newPool(store, &fakeOrigin{}, t.TempDir())

	if first.songKey("s1", "v1") != second.songKey("s1", "v1") {
		t.Error("key changed after restart")
	}
	if first.songKey("s1", "v1") == other.songKey("s1", "v1") {
		t.Error("key must depend on the server's secret")
	}
	if first.songKey("s1", "v1") == first.songKey("s1", "v2") {
		t.Error("key must depend on the file version")
	}
}

func TestBlobRouteDoesNotExposeInternalPointers(t *testing.T) {
	ts := poolTestServer(t, &fakeOrigin{cover: pngBytes(t), song: testSong, version: "v1"})
	poolGet(t, ts, authed("/v1/pool/cover/al-1", "alice"), nil)
	poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), nil)
	// What an outsider could compute without the server's secret.
	for _, guess := range []string{
		sha256Hex("cover\x00al-1\x00300\x00"),
		sha256Hex("songmeta\x00s1\x00"),
	} {
		if resp, _ := poolGet(t, ts, "/v1/pool/blob/"+guess, nil); resp.StatusCode != http.StatusNotFound {
			t.Errorf("guessable pointer %s answered %d", guess, resp.StatusCode)
		}
	}
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func TestPlaylistCoversStayOutOfThePool(t *testing.T) {
	origin := &fakeOrigin{cover: pngBytes(t)}
	ts := poolTestServer(t, origin)

	resp, body := poolGet(t, ts, authed("/v1/pool/cover/pl-1", "alice"), nil)

	if resp.StatusCode != http.StatusNotFound || !strings.Contains(string(body), "no such cover") || origin.coverCalls.Load() != 0 {
		t.Fatalf("status %d body %s origin calls %d", resp.StatusCode, body, origin.coverCalls.Load())
	}
}

func TestOddCoverSizesShareStandardEntries(t *testing.T) {
	origin := &fakeOrigin{cover: pngBytes(t)}
	ts := poolTestServer(t, origin)

	poolGet(t, ts, authed("/v1/pool/cover/al-1?size=301", "alice"), nil)
	poolGet(t, ts, authed("/v1/pool/cover/al-1?size=450", "alice"), nil)
	poolGet(t, ts, authed("/v1/pool/cover/al-1?size=599", "alice"), nil)

	if got := origin.coverCalls.Load(); got != 1 {
		t.Fatalf("origin asked %d times, want 1 (all snap to 600)", got)
	}
}

func TestChunkRouteRejectsAlternativeNumberSpellings(t *testing.T) {
	ts := poolTestServer(t, &fakeOrigin{song: testSong, version: "v1"})
	stream, _ := poolGet(t, ts, authed("/v1/pool/song/s1", "alice"), map[string]string{"Range": "bytes=0-3"})
	key := stream.Header.Get("X-Yomi-Pool-Key")

	for _, n := range []string{"00", "+0", "-0"} {
		if resp, _ := poolGet(t, ts, "/v1/pool/audio/"+key+"/"+n, nil); resp.StatusCode != http.StatusNotFound {
			t.Errorf("%q answered %d", n, resp.StatusCode)
		}
	}
}

func TestFlightGroupSurvivesAPanickingFill(t *testing.T) {
	var group flightGroup
	_, err := group.Do("k", func() (any, error) { panic("boom") })
	if err == nil {
		t.Fatal("a panic should come back as an error")
	}

	value, err := group.Do("k", func() (any, error) { return "fine", nil })

	if err != nil || value != "fine" {
		t.Fatalf("the key stayed stuck: %v, %v", value, err)
	}
}
