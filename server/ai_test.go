package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAI answers like DeepSeek's chat API with whatever the test queues up.
type fakeAI struct {
	mu       sync.Mutex
	replies  []string
	requests []string
	headers  []http.Header
	status   int
}

func (f *fakeAI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	body, _ := io.ReadAll(r.Body)
	f.requests = append(f.requests, string(body))
	f.headers = append(f.headers, r.Header.Clone())
	if f.status != 0 {
		w.WriteHeader(f.status)
		return
	}
	reply := `{}`
	if len(f.replies) > 0 {
		reply = f.replies[0]
		f.replies = f.replies[1:]
	}
	_ = json.NewEncoder(w).Encode(map[string]any{
		"choices": []map[string]any{
			{"message": map[string]string{"content": reply}, "finish_reason": "stop"},
		},
	})
}

func (f *fakeAI) requestCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

func newTestLLM(t *testing.T, ai *fakeAI) *LLMClient {
	t.Helper()
	ts := httptest.NewServer(ai)
	t.Cleanup(ts.Close)
	return &LLMClient{URL: ts.URL, Key: "secret-key", Model: "test-model", HTTP: ts.Client(), RetryDelay: time.Millisecond}
}

func TestLLMSendsKeyModelAndJSONMode(t *testing.T) {
	ai := &fakeAI{replies: []string{`{"ok":true}`}}
	var out struct {
		OK bool `json:"ok"`
	}
	if err := newTestLLM(t, ai).JSON(context.Background(), "system", "user", &out); err != nil {
		t.Fatal(err)
	}
	if !out.OK {
		t.Fatal("reply not decoded")
	}
	if got := ai.headers[0].Get("Authorization"); got != "Bearer secret-key" {
		t.Fatalf("Authorization = %q", got)
	}
	for _, want := range []string{`"test-model"`, `"json_object"`, "json"} {
		if !strings.Contains(ai.requests[0], want) {
			t.Fatalf("request missing %s: %s", want, ai.requests[0])
		}
	}
}

// DeepSeek thinks by default, which spends the reply on hidden reasoning: in a real check,
// 197 of 200 tokens went there and the JSON was cut off.
func TestLLMTurnsThinkingOff(t *testing.T) {
	ai := &fakeAI{replies: []string{`{}`}}
	var out map[string]any
	if err := newTestLLM(t, ai).JSON(context.Background(), "system", "user", &out); err != nil {
		t.Fatal(err)
	}
	var sent struct {
		Thinking struct {
			Type string `json:"type"`
		} `json:"thinking"`
	}
	if err := json.Unmarshal([]byte(ai.requests[0]), &sent); err != nil {
		t.Fatal(err)
	}
	if sent.Thinking.Type != "disabled" {
		t.Fatalf("thinking = %q, want disabled: %s", sent.Thinking.Type, ai.requests[0])
	}
}

func TestLLMRetriesBlankReplies(t *testing.T) {
	ai := &fakeAI{replies: []string{"   ", "", `{"ok":true}`}}
	var out struct {
		OK bool `json:"ok"`
	}
	if err := newTestLLM(t, ai).JSON(context.Background(), "s", "u", &out); err != nil {
		t.Fatal(err)
	}
	if !out.OK || ai.requestCount() != 3 {
		t.Fatalf("ok=%v requests=%d", out.OK, ai.requestCount())
	}
}

func TestLLMGivesUpOnEndlessBlankReplies(t *testing.T) {
	ai := &fakeAI{replies: []string{"", "", "", "", ""}}
	var out map[string]any
	if err := newTestLLM(t, ai).JSON(context.Background(), "s", "u", &out); err == nil {
		t.Fatal("expected an error")
	}
	if ai.requestCount() != llmAttempts {
		t.Fatalf("requests = %d", ai.requestCount())
	}
}

func TestLLMErrorNeverContainsTheKey(t *testing.T) {
	ai := &fakeAI{status: http.StatusUnauthorized}
	var out map[string]any
	err := newTestLLM(t, ai).JSON(context.Background(), "s", "u", &out)
	if err == nil || strings.Contains(err.Error(), "secret-key") {
		t.Fatalf("err = %v", err)
	}
}

func openTestTags(t *testing.T, dir string) *TagStore {
	t.Helper()
	store, err := openTagStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func queueSongs(t *testing.T, store *TagStore, songs ...QueuedSong) {
	t.Helper()
	if _, err := store.Enqueue(songs); err != nil {
		t.Fatal(err)
	}
}

func song(key, artist, title string) QueuedSong {
	return QueuedSong{Key: key, Artist: artist, Title: title}
}

func TestTaggerKeepsOnlyAllowedMoodsAndKnownArtists(t *testing.T) {
	store := openTestTags(t, t.TempDir())
	queueSongs(t, store, song("a|one", "Adele", "One"), song("b|two", "Bjork", "Two"))
	ai := &fakeAI{replies: []string{`{
		"songs": [
			{"i": 0, "moods": ["sad", "banana", "SAD"], "energy": "low"},
			{"i": 1, "moods": ["happy"], "energy": "extreme"},
			{"i": 7, "moods": ["happy"], "energy": "low"}
		],
		"artists": {
			"Adele": ["Bjork", "Invented Artist", "Adele"],
			"Nobody": ["Bjork"]
		}
	}`}}
	tagger := newTagger(store, newTestLLM(t, ai))
	worked, err := tagger.RunBatch(context.Background())
	if err != nil || !worked {
		t.Fatalf("worked=%v err=%v", worked, err)
	}
	tags := store.Snapshot()
	if got := tags.Songs["a|one"]; len(got.Moods) != 1 || got.Moods[0] != "sad" || got.Energy != "low" {
		t.Fatalf("a|one = %+v", got)
	}
	if got := tags.Songs["b|two"]; got.Energy != "" || got.Moods[0] != "happy" {
		t.Fatalf("b|two = %+v", got)
	}
	if got := tags.Artists["Adele"]; len(got) != 1 || got[0] != "Bjork" {
		t.Fatalf("Adele = %v", got)
	}
	if _, ok := tags.Artists["Nobody"]; ok {
		t.Fatal("an artist not in the library was kept")
	}
	if store.PendingCount() != 0 {
		t.Fatalf("pending = %d", store.PendingCount())
	}
}

func TestTaggerResumesAfterARestart(t *testing.T) {
	dir := t.TempDir()
	store := openTestTags(t, dir)
	var songs []QueuedSong
	for i := 0; i < tagBatchSize+5; i++ {
		songs = append(songs, song(fmt.Sprintf("k%d", i), "A", fmt.Sprintf("T%d", i)))
	}
	queueSongs(t, store, songs...)
	var labels []string
	for i := 0; i < tagBatchSize; i++ {
		labels = append(labels, fmt.Sprintf(`{"i":%d,"moods":["calm"],"energy":"low"}`, i))
	}
	ai := &fakeAI{replies: []string{`{"songs":[` + strings.Join(labels, ",") + `]}`}}
	if _, err := newTagger(store, newTestLLM(t, ai)).RunBatch(context.Background()); err != nil {
		t.Fatal(err)
	}

	reopened := openTestTags(t, dir)
	if reopened.PendingCount() != 5 {
		t.Fatalf("pending after restart = %d", reopened.PendingCount())
	}
	if len(reopened.Snapshot().Songs) != tagBatchSize {
		t.Fatalf("songs after restart = %d", len(reopened.Snapshot().Songs))
	}
}

func TestTaggerFailureKeepsSongsAndEventuallyGivesUp(t *testing.T) {
	store := openTestTags(t, t.TempDir())
	queueSongs(t, store, song("a", "A", "One"))
	ai := &fakeAI{status: http.StatusInternalServerError}
	tagger := newTagger(store, newTestLLM(t, ai))
	if _, err := tagger.RunBatch(context.Background()); err == nil {
		t.Fatal("expected an error")
	}
	if store.PendingCount() != 1 {
		t.Fatal("a failed batch lost its songs")
	}

	// A reply that never mentions a song can't go round for ever.
	ai.status = 0
	for i := 0; i < tagMaxAttempts; i++ {
		ai.replies = append(ai.replies, `{"songs":[]}`)
		if _, err := tagger.RunBatch(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if store.PendingCount() != 0 {
		t.Fatalf("pending = %d", store.PendingCount())
	}
}

func TestEnqueueSkipsKnownSongsAndCaps(t *testing.T) {
	store := openTestTags(t, t.TempDir())
	queueSongs(t, store, song("a", "A", "One"))
	ai := &fakeAI{replies: []string{`{"songs":[{"i":0,"moods":["calm"],"energy":"low"}]}`}}
	if _, err := newTagger(store, newTestLLM(t, ai)).RunBatch(context.Background()); err != nil {
		t.Fatal(err)
	}
	added, err := store.Enqueue([]QueuedSong{song("a", "A", "One"), song("b", "B", "Two"), song("b", "B", "Two")})
	if err != nil {
		t.Fatal(err)
	}
	if added != 1 {
		t.Fatalf("added = %d", added)
	}
}

func TestEnqueueRejectsOversizedFields(t *testing.T) {
	store := openTestTags(t, t.TempDir())
	long := strings.Repeat("x", tagMaxFieldBytes+1)
	added, err := store.Enqueue([]QueuedSong{song("a", long, "T"), song(long, "A", "T"), song("", "A", "T")})
	if err != nil {
		t.Fatal(err)
	}
	if added != 0 {
		t.Fatalf("added = %d", added)
	}
}

func TestPeakHoursFollowDeepSeekPricing(t *testing.T) {
	cases := []struct {
		at   string
		peak bool
	}{
		{"2026-11-04T02:00:00Z", true},  // Wednesday, peak
		{"2026-11-04T04:00:00Z", false}, // the end is exclusive
		{"2026-11-04T07:30:00Z", true},
		{"2026-11-04T12:00:00Z", false},
		{"2026-11-07T07:30:00Z", false}, // Saturday
	}
	for _, tc := range cases {
		at, _ := time.Parse(time.RFC3339, tc.at)
		if got := isLLMPeak(at); got != tc.peak {
			t.Errorf("%s peak = %v", tc.at, got)
		}
	}
}

func TestTaggerWaitsForOffPeakAndDailyLimit(t *testing.T) {
	store := openTestTags(t, t.TempDir())
	queueSongs(t, store, song("a", "A", "One"), song("b", "B", "Two"))
	ai := &fakeAI{}
	tagger := newTagger(store, newTestLLM(t, ai))
	peak, _ := time.Parse(time.RFC3339, "2026-11-04T02:00:00Z")
	tagger.now = func() time.Time { return peak }
	if tagger.shouldRun() {
		t.Fatal("ran at peak prices")
	}
	offPeak, _ := time.Parse(time.RFC3339, "2026-11-04T12:00:00Z")
	tagger.now = func() time.Time { return offPeak }
	if !tagger.shouldRun() {
		t.Fatal("didn't run off-peak")
	}
	tagger.batchesToday = tagMaxBatchesPerDay
	tagger.day = offPeak.YearDay()
	if tagger.shouldRun() {
		t.Fatal("ignored the daily limit")
	}
	nextDay := offPeak.Add(24 * time.Hour)
	tagger.now = func() time.Time { return nextDay }
	if !tagger.shouldRun() {
		t.Fatal("the daily limit didn't reset")
	}
}

func aiServer(t *testing.T, ai *fakeAI) (*httptest.Server, *Server) {
	t.Helper()
	dir := t.TempDir()
	server := newServer(Config{MusicDir: dir, MaxFileBytes: 1 << 10}, fakeAuth{}, nil, nil)
	if ai != nil {
		server.Tags = openTestTags(t, filepath.Join(dir, "ai"))
		server.LLM = newTestLLM(t, ai)
		server.interpreter = newInterpreter(server.LLM, server.Tags)
	}
	ts := httptest.NewServer(server.routes())
	t.Cleanup(ts.Close)
	return ts, server
}

func aiCall(t *testing.T, ts *httptest.Server, method, path, body string, headers map[string]string) (*http.Response, string) {
	t.Helper()
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	req, err := http.NewRequest(method, ts.URL+path+separator+"u=alice&p=good", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, string(data)
}

func TestAIRoutesReportUnavailableWithoutAKey(t *testing.T) {
	ts, _ := aiServer(t, nil)
	resp, body := aiCall(t, ts, http.MethodGet, "/v1/tags", "", nil)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, `"available":false`) {
		t.Fatalf("status %d body %s", resp.StatusCode, body)
	}
	resp, _ = aiCall(t, ts, http.MethodPost, "/v1/search/interpret", `{"query":"sad songs"}`, nil)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestTagsRouteUsesETag(t *testing.T) {
	ts, _ := aiServer(t, &fakeAI{})
	resp, body := aiCall(t, ts, http.MethodGet, "/v1/tags", "", nil)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, `"available":true`) {
		t.Fatalf("status %d body %s", resp.StatusCode, body)
	}
	etag := resp.Header.Get("ETag")
	if etag == "" {
		t.Fatal("no ETag")
	}
	resp, _ = aiCall(t, ts, http.MethodGet, "/v1/tags", "", map[string]string{"If-None-Match": etag})
	if resp.StatusCode != http.StatusNotModified {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestQueueRouteAcceptsSongsAndRejectsBadJSON(t *testing.T) {
	ts, server := aiServer(t, &fakeAI{})
	resp, body := aiCall(t, ts, http.MethodPost, "/v1/tags/songs", `{"songs":[{"key":"a|b","artist":"A","title":"B"}]}`, nil)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, `"pending":1`) {
		t.Fatalf("status %d body %s", resp.StatusCode, body)
	}
	if server.Tags.PendingCount() != 1 {
		t.Fatal("not queued")
	}
	resp, _ = aiCall(t, ts, http.MethodPost, "/v1/tags/songs", `{not json`, nil)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestInterpretValidatesWhatTheAIReturns(t *testing.T) {
	ai := &fakeAI{}
	ts, server := aiServer(t, ai)
	queueSongs(t, server.Tags, song("a", "Adele", "One"))
	ai.replies = []string{`{"moods":["sad","evil"],"energy":"low","artists":["Adele","Made Up"],"genres":["Pop"],"excludeMoods":["happy","nope"]}`}
	resp, body := aiCall(t, ts, http.MethodPost, "/v1/search/interpret", `{"query":"sad rainy night"}`, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d body %s", resp.StatusCode, body)
	}
	var got SearchFilters
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Moods) != 1 || got.Moods[0] != "sad" {
		t.Fatalf("moods %v", got.Moods)
	}
	if len(got.Artists) != 1 || got.Artists[0] != "Adele" {
		t.Fatalf("artists %v", got.Artists)
	}
	if len(got.ExcludeMoods) != 1 || got.ExcludeMoods[0] != "happy" {
		t.Fatalf("exclude %v", got.ExcludeMoods)
	}
}

func TestInterpretSendsNoUserNameAndCachesRepeats(t *testing.T) {
	ai := &fakeAI{replies: []string{`{"moods":["calm"]}`}}
	ts, _ := aiServer(t, ai)
	for i := 0; i < 2; i++ {
		resp, _ := aiCall(t, ts, http.MethodPost, "/v1/search/interpret", `{"query":"Calm Evening"}`, nil)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status %d", resp.StatusCode)
		}
	}
	if ai.requestCount() != 1 {
		t.Fatalf("AI asked %d times", ai.requestCount())
	}
	if strings.Contains(ai.requests[0], "alice") {
		t.Fatal("the user name reached the AI")
	}
}

func TestInterpretRejectsEmptyAndOverlongQueries(t *testing.T) {
	ai := &fakeAI{}
	ts, _ := aiServer(t, ai)
	for _, query := range []string{"", "   ", strings.Repeat("x", interpretMaxQuery+1)} {
		body, _ := json.Marshal(map[string]string{"query": query})
		resp, _ := aiCall(t, ts, http.MethodPost, "/v1/search/interpret", string(body), nil)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("query %q: status %d", query[:min(len(query), 5)], resp.StatusCode)
		}
	}
	if ai.requestCount() != 0 {
		t.Fatal("a bad query reached the AI")
	}
}

func TestInterpretRateLimitsEachUser(t *testing.T) {
	ai := &fakeAI{}
	ts, _ := aiServer(t, ai)
	var last int
	for i := 0; i <= interpretPerMinute; i++ {
		ai.replies = append(ai.replies, `{"moods":["calm"]}`)
		body, _ := json.Marshal(map[string]string{"query": fmt.Sprintf("query %d", i)})
		resp, _ := aiCall(t, ts, http.MethodPost, "/v1/search/interpret", string(body), nil)
		last = resp.StatusCode
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("status %d", last)
	}
}

func TestInterpretFailureIsAPlainError(t *testing.T) {
	ai := &fakeAI{status: http.StatusBadGateway}
	ts, _ := aiServer(t, ai)
	resp, body := aiCall(t, ts, http.MethodPost, "/v1/search/interpret", `{"query":"anything at all"}`, nil)
	if resp.StatusCode != http.StatusBadGateway || strings.Contains(body, "secret-key") {
		t.Fatalf("status %d body %s", resp.StatusCode, body)
	}
}

func TestLLMClientFromConfigNeedsAKey(t *testing.T) {
	if newLLMClient(Config{}, nil) != nil {
		t.Fatal("made a client with no key")
	}
	client := newLLMClient(Config{LLMKey: "k"}, http.DefaultClient)
	if client == nil || client.Model != defaultLLMModel || client.URL != defaultLLMURL {
		t.Fatalf("client = %+v", client)
	}
}

func TestTagsFileIsNotWorldReadable(t *testing.T) {
	dir := t.TempDir()
	store := openTestTags(t, dir)
	queueSongs(t, store, song("a", "A", "One"))
	info, err := os.Stat(filepath.Join(dir, tagsFileName))
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() == 0 {
		t.Fatal("nothing saved")
	}
}
