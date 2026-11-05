package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

type socialEnv struct {
	url    string
	store  *MessageStore
	server *Server
	now    *time.Time
}

func newSocialEnv(t *testing.T, cfg Config) socialEnv {
	t.Helper()
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	store, err := openMessageStore(t.TempDir(), func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	cfg.MusicDir = t.TempDir()
	cfg.MaxFileBytes = 1 << 10
	server := newServer(cfg, fakeAuth{}, nil, nil)
	server.Messages = store
	ts := httptest.NewServer(server.routes())
	t.Cleanup(ts.Close)
	env := socialEnv{url: ts.URL, store: store, server: server, now: &now}
	for _, user := range []string{"keli", "sam"} {
		if err := store.SaveProfile(Profile{User: user}); err != nil {
			t.Fatal(err)
		}
	}
	return env
}

func (e socialEnv) call(t *testing.T, method, path, user string, body any) (int, []byte) {
	t.Helper()
	var reader *bytes.Reader
	switch value := body.(type) {
	case nil:
		reader = bytes.NewReader(nil)
	case []byte:
		reader = bytes.NewReader(value)
	default:
		encoded, _ := json.Marshal(value)
		reader = bytes.NewReader(encoded)
	}
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	request, err := http.NewRequest(method, e.url+path+separator+"u="+user+"&p=good", reader)
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var buffer bytes.Buffer
	buffer.ReadFrom(response.Body)
	return response.StatusCode, buffer.Bytes()
}

func (e socialEnv) send(t *testing.T, from, to, text string) Message {
	t.Helper()
	code, body := e.call(t, http.MethodPost, "/v1/messages", from, map[string]string{"to": to, "text": text})
	if code != http.StatusCreated {
		t.Fatalf("send: %d %s", code, body)
	}
	var message Message
	json.Unmarshal(body, &message)
	return message
}

func (e socialEnv) thread(t *testing.T, user, with string, after int64) []Message {
	t.Helper()
	code, body := e.call(t, http.MethodGet, fmt.Sprintf("/v1/messages?with=%s&after=%d", with, after), user, nil)
	if code != http.StatusOK {
		t.Fatalf("thread: %d %s", code, body)
	}
	var reply struct {
		Messages []Message `json:"messages"`
	}
	json.Unmarshal(body, &reply)
	return reply.Messages
}

func (e socialEnv) conversations(t *testing.T, user string) []Conversation {
	t.Helper()
	_, body := e.call(t, http.MethodGet, "/v1/conversations", user, nil)
	var reply struct {
		Conversations []Conversation `json:"conversations"`
	}
	json.Unmarshal(body, &reply)
	return reply.Conversations
}

func TestMessagesReachBothSidesInOrder(t *testing.T) {
	env := newSocialEnv(t, Config{})
	env.send(t, "keli", "sam", "hi")
	second := env.send(t, "sam", "keli", "hello")

	thread := env.thread(t, "keli", "sam", 0)
	if len(thread) != 2 || thread[0].Text != "hi" || thread[1].Text != "hello" {
		t.Fatalf("thread = %+v", thread)
	}
	if newer := env.thread(t, "sam", "keli", second.ID); len(newer) != 0 {
		t.Fatalf("after latest = %+v", newer)
	}
}

func TestOthersCannotReadAConversation(t *testing.T) {
	env := newSocialEnv(t, Config{})
	env.store.SaveProfile(Profile{User: "eve"})
	env.send(t, "keli", "sam", "private")

	if thread := env.thread(t, "eve", "sam", 0); len(thread) != 0 {
		t.Fatalf("eve read: %+v", thread)
	}
	if list := env.conversations(t, "eve"); len(list) != 0 {
		t.Fatalf("eve sees: %+v", list)
	}
}

func TestSenderComesFromTheLoginNotTheRequest(t *testing.T) {
	env := newSocialEnv(t, Config{})
	code, body := env.call(t, http.MethodPost, "/v1/messages", "keli", map[string]string{"to": "sam", "text": "x", "from": "sam"})
	if code != http.StatusCreated {
		t.Fatalf("code = %d", code)
	}
	var message Message
	json.Unmarshal(body, &message)
	if message.From != "keli" {
		t.Fatalf("from = %q", message.From)
	}
}

func TestUnreadCountsAndMarkRead(t *testing.T) {
	env := newSocialEnv(t, Config{})
	env.send(t, "keli", "sam", "one")
	last := env.send(t, "keli", "sam", "two")

	list := env.conversations(t, "sam")
	if len(list) != 1 || list[0].With != "keli" || list[0].Unread != 2 {
		t.Fatalf("list = %+v", list)
	}
	if own := env.conversations(t, "keli"); own[0].Unread != 0 {
		t.Fatalf("own messages are unread: %+v", own)
	}

	env.call(t, http.MethodPost, "/v1/messages/read", "sam", map[string]any{"with": "keli", "upTo": last.ID})
	if list := env.conversations(t, "sam"); list[0].Unread != 0 {
		t.Fatalf("after read: %+v", list)
	}

	env.call(t, http.MethodPost, "/v1/messages/read", "sam", map[string]any{"with": "keli", "upTo": 1})
	env.send(t, "keli", "sam", "three")
	if list := env.conversations(t, "sam"); list[0].Unread != 1 {
		t.Fatalf("read position went backwards: %+v", list)
	}
}

func TestSendValidation(t *testing.T) {
	env := newSocialEnv(t, Config{})
	for name, body := range map[string]map[string]string{
		"unknown person": {"to": "nobody", "text": "x"},
		"bad name":       {"to": "../etc", "text": "x"},
		"empty":          {"to": "sam", "text": "   "},
		"too long":       {"to": "sam", "text": strings.Repeat("é", maxMessageChars+1)},
	} {
		code, _ := env.call(t, http.MethodPost, "/v1/messages", "keli", body)
		if code == http.StatusCreated {
			t.Errorf("%s: was accepted", name)
		}
	}
}

func TestSongShareNeedsNoText(t *testing.T) {
	env := newSocialEnv(t, Config{})
	code, body := env.call(t, http.MethodPost, "/v1/messages", "keli", map[string]string{"to": "sam", "songId": "s1", "songTitle": "Song"})
	if code != http.StatusCreated {
		t.Fatalf("code = %d %s", code, body)
	}
}

func TestMessagesAreRateLimitedPerPerson(t *testing.T) {
	env := newSocialEnv(t, Config{})
	for range messagesPerMinute {
		env.send(t, "keli", "sam", "x")
	}
	code, _ := env.call(t, http.MethodPost, "/v1/messages", "keli", map[string]string{"to": "sam", "text": "x"})
	if code != http.StatusTooManyRequests {
		t.Fatalf("code = %d", code)
	}
	env.send(t, "sam", "keli", "someone else still can")
	*env.now = env.now.Add(time.Minute + time.Second)
	env.send(t, "keli", "sam", "later")
}

func TestMessagesAndStateSurviveRestart(t *testing.T) {
	env := newSocialEnv(t, Config{})
	message := env.send(t, "keli", "sam", "keep me")
	env.store.MarkRead("sam", "keli", message.ID)
	handle, _ := os.OpenFile(env.store.messagesFile(), os.O_APPEND|os.O_WRONLY, 0o666)
	handle.WriteString(`{"id":99,"fr`)
	handle.Close()

	reopened, err := openMessageStore(env.store.dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	thread := reopened.Thread("keli", "sam", 0, 0)
	if len(thread) != 1 || thread[0].Text != "keep me" {
		t.Fatalf("thread = %+v", thread)
	}
	if list := reopened.Conversations("sam"); list[0].Unread != 0 {
		t.Fatalf("read position lost: %+v", list)
	}
	next, err := reopened.Send(Message{From: "keli", To: "sam", Text: "new"})
	if err != nil || next.ID != message.ID+1 {
		t.Fatalf("next = %+v, err = %v", next, err)
	}
}

func TestProfilesAndAvatars(t *testing.T) {
	env := newSocialEnv(t, Config{})
	code, _ := env.call(t, http.MethodPut, "/v1/profile", "keli", map[string]string{"displayName": "Keli", "bio": "hi"})
	if code != http.StatusOK {
		t.Fatalf("code = %d", code)
	}
	var picture bytes.Buffer
	png.Encode(&picture, image.NewRGBA(image.Rect(0, 0, 4, 4)))
	if code, _ := env.call(t, http.MethodPut, "/v1/profile/avatar", "keli", picture.Bytes()); code != http.StatusOK {
		t.Fatalf("avatar code = %d", code)
	}
	env.call(t, http.MethodPut, "/v1/profile", "keli", map[string]string{"displayName": "Keli 2"})

	_, body := env.call(t, http.MethodGet, "/v1/profiles", "sam", nil)
	var reply struct {
		Profiles []Profile `json:"profiles"`
	}
	json.Unmarshal(body, &reply)
	if reply.Profiles[0].DisplayName != "Keli 2" || !reply.Profiles[0].HasAvatar {
		t.Fatalf("profiles = %+v", reply.Profiles)
	}
	code, data := env.call(t, http.MethodGet, "/v1/profiles/keli/avatar", "sam", nil)
	if code != http.StatusOK || !bytes.Equal(data, picture.Bytes()) {
		t.Fatalf("avatar: %d, %d bytes", code, len(data))
	}
}

func TestAvatarRejectsNonImagesAndBadNames(t *testing.T) {
	env := newSocialEnv(t, Config{})
	if code, _ := env.call(t, http.MethodPut, "/v1/profile/avatar", "keli", []byte("<svg onload=x>")); code != http.StatusUnsupportedMediaType {
		t.Fatalf("code = %d", code)
	}
	big := append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, maxAvatarBytes+1)...)
	if code, _ := env.call(t, http.MethodPut, "/v1/profile/avatar", "keli", big); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("big code = %d", code)
	}
	if code, _ := env.call(t, http.MethodGet, "/v1/profiles/UPPER%2F..%2Fx/avatar", "keli", nil); code == http.StatusOK {
		t.Fatal("served a path outside avatars")
	}
}

func TestMessagesRequireLogin(t *testing.T) {
	env := newSocialEnv(t, Config{})
	response, err := http.Get(env.url + "/v1/conversations?u=keli&p=wrong")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("code = %d", response.StatusCode)
	}
}

func TestReplicaRefusesMessages(t *testing.T) {
	env := newSocialEnv(t, Config{Role: roleReplica})
	code, _ := env.call(t, http.MethodPost, "/v1/messages", "keli", map[string]string{"to": "sam", "text": "x"})
	if code != http.StatusServiceUnavailable {
		t.Fatalf("code = %d", code)
	}
}

func TestDevicesAreCappedAndDeduplicated(t *testing.T) {
	env := newSocialEnv(t, Config{})
	for i := range maxDeviceTokens + 3 {
		env.store.AddDevice("sam", fmt.Sprintf("t%d", i))
	}
	env.store.AddDevice("sam", fmt.Sprintf("t%d", maxDeviceTokens+2))
	devices := env.store.Devices("sam")
	if len(devices) != maxDeviceTokens || devices[len(devices)-1] != fmt.Sprintf("t%d", maxDeviceTokens+2) {
		t.Fatalf("devices = %v", devices)
	}
}

func TestPushSendsNoMessageTextAndForgetsDeadDevices(t *testing.T) {
	var mu sync.Mutex
	var received []byte
	var signature string
	done := make(chan struct{}, 1)
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		var buffer bytes.Buffer
		buffer.ReadFrom(r.Body)
		received = buffer.Bytes()
		signature = r.Header.Get("X-Yomi-Signature")
		w.Write([]byte(`{"deadTokens":["dead"]}`))
		done <- struct{}{}
	}))
	defer relay.Close()
	env := newSocialEnv(t, Config{})
	key := []byte("test-key")
	env.server.Relay = &PushRelay{URL: relay.URL, Key: key, Client: relay.Client(), Now: time.Now}
	env.store.AddDevice("sam", "dead")
	env.store.AddDevice("sam", "alive")

	env.send(t, "keli", "sam", "the secret text")

	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("relay was never called")
	}
	mu.Lock()
	defer mu.Unlock()
	if strings.Contains(string(received), "secret") {
		t.Fatalf("text reached the relay: %s", received)
	}
	if signature != signRelayBody(key, received) {
		t.Fatal("bad signature")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if devices := env.store.Devices("sam"); len(devices) == 1 && devices[0] == "alive" {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("devices = %v", env.store.Devices("sam"))
}

func TestFailedPushDoesNotFailTheMessage(t *testing.T) {
	env := newSocialEnv(t, Config{})
	dead := httptest.NewServer(http.NotFoundHandler())
	address := dead.URL
	dead.Close()
	env.server.Relay = &PushRelay{URL: address, Key: []byte("k"), Client: http.DefaultClient, Now: time.Now}
	env.store.AddDevice("sam", "t")
	env.send(t, "keli", "sam", "still delivered")
	if thread := env.thread(t, "sam", "keli", 0); len(thread) != 1 {
		t.Fatalf("thread = %+v", thread)
	}
}
