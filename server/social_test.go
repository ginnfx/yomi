package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// adminAuth accepts the test password, and adminNavidrome says that account is an admin.
type adminAuth = fakeAuth

func adminNavidrome(t *testing.T) string {
	t.Helper()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"subsonic-response": map[string]any{"status": "ok", "user": map[string]any{"adminRole": true}},
		})
	}))
	t.Cleanup(ts.Close)
	return ts.URL
}

func sendTo(t *testing.T, env socialEnv, from, to string, body map[string]any) Message {
	t.Helper()
	body["to"] = to
	status, data := env.call(t, http.MethodPost, "/v1/messages", from, body)
	if status != http.StatusCreated {
		t.Fatalf("send: status %d %s", status, data)
	}
	var message Message
	if err := json.Unmarshal(data, &message); err != nil {
		t.Fatal(err)
	}
	return message
}

func threadOf(t *testing.T, env socialEnv, user, path string) []Message {
	t.Helper()
	status, data := env.call(t, http.MethodGet, path, user, nil)
	if status != http.StatusOK {
		t.Fatalf("thread: status %d %s", status, data)
	}
	var reply struct {
		Messages []Message `json:"messages"`
	}
	if err := json.Unmarshal(data, &reply); err != nil {
		t.Fatal(err)
	}
	return reply.Messages
}

func TestOlderMessagesCanBeReached(t *testing.T) {
	env := newSocialEnv(t, Config{})
	for i := 0; i < maxThreadPage+5; i++ {
		if _, err := env.store.Send(Message{From: "keli", To: "sam", Text: fmt.Sprint(i)}); err != nil {
			*env.now = env.now.Add(time.Minute) // Stay under the send limit.
			if _, err := env.store.Send(Message{From: "keli", To: "sam", Text: fmt.Sprint(i)}); err != nil {
				t.Fatal(err)
			}
		}
	}
	latest := threadOf(t, env, "sam", "/v1/messages?with=keli")
	if len(latest) != maxThreadPage {
		t.Fatalf("latest page = %d", len(latest))
	}
	older := threadOf(t, env, "sam", fmt.Sprintf("/v1/messages?with=keli&before=%d", latest[0].ID))
	if len(older) != 5 || older[len(older)-1].ID >= latest[0].ID {
		t.Fatalf("older = %d", len(older))
	}
}

func TestSharingAlbumsPlaylistsAndReplies(t *testing.T) {
	env := newSocialEnv(t, Config{})
	album := sendTo(t, env, "keli", "sam", map[string]any{"albumId": "a1", "songTitle": "An album"})
	if album.AlbumID != "a1" {
		t.Fatalf("album = %+v", album)
	}
	playlist := sendTo(t, env, "keli", "sam", map[string]any{"playlistId": "p1", "songTitle": "A list"})
	if playlist.PlaylistID != "p1" {
		t.Fatalf("playlist = %+v", playlist)
	}
	reply := sendTo(t, env, "sam", "keli", map[string]any{"text": "nice", "replyTo": album.ID})
	if reply.ReplyTo != album.ID {
		t.Fatalf("reply = %+v", reply)
	}
	status, _ := env.call(t, http.MethodPost, "/v1/messages", "keli", map[string]any{"to": "sam"})
	if status != http.StatusBadRequest {
		t.Fatalf("empty message: status %d", status)
	}
}

func TestReactionsAreKeptAndCanBeRemoved(t *testing.T) {
	env := newSocialEnv(t, Config{})
	message := sendTo(t, env, "keli", "sam", map[string]any{"text": "hi"})
	react := func(user, emoji string) int {
		status, _ := env.call(t, http.MethodPost, "/v1/messages/react", user, map[string]any{"id": message.ID, "emoji": emoji})
		return status
	}
	if status := react("sam", "🔥"); status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	got := threadOf(t, env, "keli", "/v1/messages?with=sam")
	if got[0].Reactions["sam"] != "🔥" {
		t.Fatalf("reactions = %v", got[0].Reactions)
	}

	reopened, err := openMessageStore(env.store.dir, env.store.now)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.Thread("keli", "sam", 0, 0)[0].Reactions["sam"] != "🔥" {
		t.Fatal("reaction lost in a restart")
	}

	if status := react("sam", ""); status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	got = threadOf(t, env, "keli", "/v1/messages?with=sam")
	if len(got[0].Reactions) != 0 {
		t.Fatalf("reactions = %v", got[0].Reactions)
	}
}

func TestReactionsAreLimited(t *testing.T) {
	env := newSocialEnv(t, Config{})
	message := sendTo(t, env, "keli", "sam", map[string]any{"text": "hi"})
	status, _ := env.call(t, http.MethodPost, "/v1/messages/react", "other", map[string]any{"id": message.ID, "emoji": "🔥"})
	if status != http.StatusNotFound {
		t.Fatalf("outsider: status %d", status)
	}
	status, _ = env.call(t, http.MethodPost, "/v1/messages/react", "sam", map[string]any{"id": 999, "emoji": "🔥"})
	if status != http.StatusNotFound {
		t.Fatalf("no such message: status %d", status)
	}
	status, _ = env.call(t, http.MethodPost, "/v1/messages/react", "sam", map[string]any{"id": message.ID, "emoji": strings.Repeat("x", 40)})
	if status != http.StatusBadRequest {
		t.Fatalf("long emoji: status %d", status)
	}
}

func TestEventsWaitThenWakeForANewMessage(t *testing.T) {
	env := newSocialEnv(t, Config{})
	rev := env.store.Revision("sam")
	done := make(chan int64, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		done <- env.store.WaitForChange(ctx, "sam", rev)
	}()
	select {
	case <-done:
		t.Fatal("returned before anything changed")
	case <-time.After(30 * time.Millisecond):
	}
	if _, err := env.store.Send(Message{From: "keli", To: "sam", Text: "hi"}); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-done:
		if got == rev {
			t.Fatalf("revision unchanged: %d", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("didn't wake")
	}
}

func TestEventsIgnoreOtherPeoplesMessages(t *testing.T) {
	env := newSocialEnv(t, Config{})
	rev := env.store.Revision("sam")
	if _, err := env.store.Send(Message{From: "keli", To: "alex", Text: "not for sam"}); err != nil {
		t.Fatal(err)
	}
	if env.store.Revision("sam") != rev {
		t.Fatal("woken by someone else's message")
	}
}

func TestEventsRouteAnswersStraightAwayWhenBehind(t *testing.T) {
	env := newSocialEnv(t, Config{})
	status, data := env.call(t, http.MethodGet, "/v1/events?rev=-1", "sam", nil)
	if status != http.StatusOK || !strings.Contains(string(data), `"rev"`) {
		t.Fatalf("status %d %s", status, data)
	}
}

func TestEventsRouteStopsWhenTheCallerLeaves(t *testing.T) {
	env := newSocialEnv(t, Config{})
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	rev := env.store.Revision("sam")
	if got := env.store.WaitForChange(ctx, "sam", rev); got != rev {
		t.Fatalf("got %d", got)
	}
}

func TestFriendsCanSeeWhatYouPlayOnlyWhenYouShare(t *testing.T) {
	env := newSocialEnv(t, Config{})
	profiles := func() string {
		_, data := env.call(t, http.MethodGet, "/v1/profiles", "sam", nil)
		return string(data)
	}
	if strings.Contains(profiles(), "nowPlaying") {
		t.Fatal("playing shown before sharing")
	}
	status, _ := env.call(t, http.MethodPut, "/v1/profile/playing", "keli", map[string]any{"songId": "s1", "title": "Song", "artist": "Band"})
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	if !strings.Contains(profiles(), "s1") {
		t.Fatalf("not shown: %s", profiles())
	}
	*env.now = env.now.Add(nowPlayingLasts + time.Minute)
	if strings.Contains(profiles(), "s1") {
		t.Fatal("old listening still shown")
	}
	if _, _ = env.call(t, http.MethodPut, "/v1/profile/playing", "keli", map[string]any{"songId": "s2"}); !strings.Contains(profiles(), "s2") {
		t.Fatal("not updated")
	}
	if _, _ = env.call(t, http.MethodPut, "/v1/profile/playing", "keli", map[string]any{}); strings.Contains(profiles(), "s2") {
		t.Fatal("stopping sharing didn't clear it")
	}
}

func TestBackupServerCanReadChatsButNotChangeThem(t *testing.T) {
	env := newSocialEnv(t, Config{Role: roleReplica})
	if _, err := env.store.Send(Message{From: "keli", To: "sam", Text: "from before"}); err != nil {
		t.Fatal(err)
	}
	if got := threadOf(t, env, "sam", "/v1/messages?with=keli"); len(got) != 1 {
		t.Fatalf("thread = %d", len(got))
	}
	status, _ := env.call(t, http.MethodGet, "/v1/conversations", "sam", nil)
	if status != http.StatusOK {
		t.Fatalf("conversations: status %d", status)
	}
	status, _ = env.call(t, http.MethodPost, "/v1/messages", "sam", map[string]any{"to": "keli", "text": "hi"})
	if status != http.StatusServiceUnavailable {
		t.Fatalf("send: status %d", status)
	}
}

func TestReplicaCopiesChatsAndHistory(t *testing.T) {
	primaryMessages := t.TempDir()
	primaryHistory := t.TempDir()
	store, err := openMessageStore(primaryMessages, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SaveProfile(Profile{User: "keli"}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Send(Message{From: "keli", To: "sam", Text: "hello"}); err != nil {
		t.Fatal(err)
	}
	history, err := openHistoryStore(primaryHistory)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := history.Add("sam", []HistoryEvent{historyEvent("1")}); err != nil {
		t.Fatal(err)
	}
	primary := newServer(Config{MusicDir: t.TempDir(), MaxFileBytes: 1 << 10, NavidromeURL: adminNavidrome(t)}, adminAuth{}, nil, nil)
	primary.Messages = store
	primary.History = history
	ts := httptest.NewServer(primary.routes())
	t.Cleanup(ts.Close)

	replicaMessages, err := openMessageStore(t.TempDir(), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	replicaHistory, err := openHistoryStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	sync := &StateSync{
		PrimaryURL: ts.URL,
		Login:      url.Values{"u": {"admin"}, "p": {"good"}},
		Client:     ts.Client(),
		Roots:      map[string]string{stateRootMessages: replicaMessages.dir, stateRootHistory: replicaHistory.dir},
		OnChanged:  replicaMessages.Reload,
	}
	if err := sync.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := replicaMessages.Thread("sam", "keli", 0, 0); len(got) != 1 || got[0].Text != "hello" {
		t.Fatalf("thread = %v", got)
	}
	if events, _, _ := replicaHistory.Read("sam", 0, 10); len(events) != 1 {
		t.Fatalf("history = %v", events)
	}
	if err := sync.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestStateFilesNeedAnAdmin(t *testing.T) {
	env := newSocialEnv(t, Config{})
	env.server.History = openTestHistory(t)
	status, _ := env.call(t, http.MethodGet, "/v1/replica/state", "sam", nil)
	if status != http.StatusForbidden && status != http.StatusUnauthorized {
		t.Fatalf("status %d", status)
	}
}

func TestStateFileRefusesPathsOutsideItsRoot(t *testing.T) {
	store, err := openMessageStore(t.TempDir(), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(filepath.Dir(store.dir), "secret.txt")
	if err := os.WriteFile(outside, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(outside)
	server := newServer(Config{MusicDir: t.TempDir(), MaxFileBytes: 1 << 10, NavidromeURL: adminNavidrome(t)}, adminAuth{}, nil, nil)
	server.Messages = store
	ts := httptest.NewServer(server.routes())
	t.Cleanup(ts.Close)
	for _, name := range []string{"../secret.txt", "/etc/passwd", "..%2Fsecret.txt"} {
		resp, err := ts.Client().Get(ts.URL + "/v1/replica/state/file?u=admin&p=good&root=messages&name=" + name)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			t.Fatalf("%s was served", name)
		}
	}
	resp, err := ts.Client().Get(ts.URL + "/v1/replica/state/file?u=admin&p=good&root=nope&name=x")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatal("an unknown root was served")
	}
}

func TestReactionsShareTheSendLimit(t *testing.T) {
	env := newSocialEnv(t, Config{})
	message := sendTo(t, env, "keli", "sam", map[string]any{"text": "hi"})
	var last int
	for i := 0; i <= messagesPerMinute; i++ {
		last, _ = env.call(t, http.MethodPost, "/v1/messages/react", "sam", map[string]any{"id": message.ID, "emoji": "🔥"})
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("status %d", last)
	}
}

func TestImportsHaveALimitPerPerson(t *testing.T) {
	store := openTestHistory(t)
	for i := 0; i < importMaxPerUser; i++ {
		if err := store.SaveImport("alice", fmt.Sprintf("p%d", i), []byte(`{}`)); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.SaveImport("alice", "one-more", []byte(`{}`)); !errors.Is(err, errTooManyImports) {
		t.Fatalf("err = %v", err)
	}
	if err := store.SaveImport("alice", "p0", []byte(`{"changed":true}`)); err != nil {
		t.Fatalf("replacing one must still work: %v", err)
	}
}

func TestHistoryHasASizeLimitPerPerson(t *testing.T) {
	store := openTestHistory(t)
	store.maxLogBytes = 200
	if _, err := store.Add("alice", []HistoryEvent{historyEvent("1"), historyEvent("2")}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Add("alice", []HistoryEvent{historyEvent("3")}); !errors.Is(err, errHistoryFull) {
		t.Fatalf("err = %v", err)
	}
}

func TestKnownArtistsAreCapped(t *testing.T) {
	store := openTestTags(t, t.TempDir())
	store.maxArtists = 2
	if _, err := store.Enqueue([]QueuedSong{song("a", "A", "T"), song("b", "B", "T"), song("c", "C", "T")}); err != nil {
		t.Fatal(err)
	}
	if got := len(store.KnownArtists()); got != 2 {
		t.Fatalf("artists = %d", got)
	}
}
