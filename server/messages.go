package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	maxMessageChars     = 4000
	maxMessageBody      = 32 << 10
	maxThreadPage       = 200
	maxNameChars        = 40
	maxBioChars         = 160
	maxAvatarBytes      = 1 << 20
	maxDeviceTokens     = 8
	maxTokenBytes       = 4096
	messagesPerMinute   = 30
	maxLineBytes        = 64 << 10
	maxReferenceIDBytes = 400
	relayTimeout        = 15 * time.Second
)

// Message is one text, optionally sharing a song.
type Message struct {
	ID        int64  `json:"id"`
	From      string `json:"from"`
	To        string `json:"to"`
	Text      string `json:"text"`
	SongID    string `json:"songId,omitempty"`
	SongTitle string `json:"songTitle,omitempty"`
	SentMs    int64  `json:"sentMs"`

	// A shared album or playlist, named by SongTitle.
	AlbumID    string `json:"albumId,omitempty"`
	PlaylistID string `json:"playlistId,omitempty"`
	ReplyTo    int64  `json:"replyTo,omitempty"`

	// Who reacted with what. Added when sending to the app, never saved in the message.
	Reactions map[string]string `json:"reactions,omitempty"`
}

// Profile is what others see of a user.
type Profile struct {
	User        string `json:"user"`
	DisplayName string `json:"displayName"`
	Bio         string `json:"bio"`
	HasAvatar   bool   `json:"hasAvatar"`

	// What they share about their listening, if anything.
	Taste *Taste `json:"taste,omitempty"`

	// Only present while someone who chose to share is listening. Never saved.
	NowPlaying *NowPlaying `json:"nowPlaying,omitempty"`
}

// Conversation summarises a thread for the list screen.
type Conversation struct {
	With   string  `json:"with"`
	Last   Message `json:"last"`
	Unread int     `json:"unread"`
}

// socialState is everything but messages, saved as one small JSON file.
type socialState struct {
	Profiles map[string]Profile  `json:"profiles"`
	ReadUpTo map[string]int64    `json:"readUpTo"`
	Devices  map[string][]string `json:"devices"`
}

// MessageStore keeps messages as an append-only JSONL file on internal storage, with
// everything in memory. A few friends' texts are small enough that this beats running a
// database on the server phone.
type MessageStore struct {
	dir      string
	now      func() time.Time
	mu       sync.RWMutex
	messages []Message
	state    socialState
	sent     map[string][]time.Time

	reactions map[int64]map[string]string
	revisions map[string]int64
	changed   chan struct{}
	playing   map[string]NowPlaying
}

func openMessageStore(dir string, now func() time.Time) (*MessageStore, error) {
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return nil, err
	}
	store := &MessageStore{
		dir: dir,
		now: now,
		state: socialState{
			Profiles: make(map[string]Profile),
			ReadUpTo: make(map[string]int64),
			Devices:  make(map[string][]string),
		},
		sent:      make(map[string][]time.Time),
		reactions: make(map[int64]map[string]string),
		revisions: make(map[string]int64),
		changed:   make(chan struct{}),
		playing:   make(map[string]NowPlaying),
	}
	if err := store.loadMessages(); err != nil {
		return nil, err
	}
	if err := store.loadReactions(); err != nil {
		return nil, err
	}
	if err := store.loadState(); err != nil {
		return nil, err
	}
	return store, nil
}

func (m *MessageStore) messagesFile() string { return filepath.Join(m.dir, "messages.jsonl") }
func (m *MessageStore) stateFile() string    { return filepath.Join(m.dir, "social.json") }
func (m *MessageStore) avatarFile(user string) string {
	return filepath.Join(m.dir, "avatar-"+user+".img")
}

func (m *MessageStore) loadMessages() error {
	file, err := os.Open(m.messagesFile())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer file.Close()
	return forEachLine(file, maxLineBytes, func(data []byte) {
		var message Message
		if err := json.Unmarshal(data, &message); err != nil {
			log.Printf("messages: skipping damaged line")
			return
		}
		m.messages = append(m.messages, message)
	})
}

func (m *MessageStore) loadState() error {
	data, err := os.ReadFile(m.stateFile())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, &m.state); err != nil {
		log.Printf("messages: ignoring damaged profile state: %v", err)
	}
	if m.state.Profiles == nil {
		m.state.Profiles = make(map[string]Profile)
	}
	if m.state.ReadUpTo == nil {
		m.state.ReadUpTo = make(map[string]int64)
	}
	if m.state.Devices == nil {
		m.state.Devices = make(map[string][]string)
	}
	return nil
}

func (m *MessageStore) saveStateLocked() error {
	data, err := json.Marshal(m.state)
	if err != nil {
		return err
	}
	temp := m.stateFile() + ".tmp"
	if err := os.WriteFile(temp, data, 0o666); err != nil {
		return err
	}
	return os.Rename(temp, m.stateFile())
}

var errRateLimited = errors.New("too many messages, slow down a little")

// Send stores a message. The caller has already validated it.
func (m *MessageStore) Send(message Message) (Message, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.allowLocked(message.From) {
		return Message{}, errRateLimited
	}
	now := m.now()
	message.ID = int64(len(m.messages)) + 1
	if len(m.messages) > 0 {
		message.ID = m.messages[len(m.messages)-1].ID + 1
	}
	message.SentMs = now.UnixMilli()
	line, err := json.Marshal(message)
	if err != nil {
		return Message{}, err
	}
	file, err := os.OpenFile(m.messagesFile(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o666)
	if err != nil {
		return Message{}, err
	}
	defer file.Close()
	if _, err := file.Write(append(line, '\n')); err != nil {
		return Message{}, err
	}
	m.messages = append(m.messages, message)
	m.bumpLocked(message.From, message.To)
	return message, nil
}

// allowLocked counts one more message or reaction, if this user is within the limit.
func (m *MessageStore) allowLocked(user string) bool {
	now := m.now()
	recent := m.sent[user][:0]
	for _, at := range m.sent[user] {
		if now.Sub(at) < time.Minute {
			recent = append(recent, at)
		}
	}
	if len(recent) >= messagesPerMinute {
		m.sent[user] = recent
		return false
	}
	m.sent[user] = append(recent, now)
	return true
}

func isBetween(message Message, a, b string) bool {
	return (message.From == a && message.To == b) || (message.From == b && message.To == a)
}

// Thread returns up to one page of messages between two users, oldest first. With no
// after, it returns the most recent page, or the page just older than before if set.
func (m *MessageStore) Thread(user, with string, after, before int64) []Message {
	m.mu.RLock()
	defer m.mu.RUnlock()
	found := make([]Message, 0)
	for _, message := range m.messages {
		if message.ID > after && (before == 0 || message.ID < before) && isBetween(message, user, with) {
			found = append(found, m.withReactionsLocked(message))
		}
	}
	// Without a starting point, the page nearest the newest message is what's wanted.
	if after == 0 && len(found) > maxThreadPage {
		return found[len(found)-maxThreadPage:]
	}
	if len(found) > maxThreadPage {
		return found[:maxThreadPage]
	}
	return found
}

func readKey(user, with string) string { return user + "\x00" + with }

// Conversations lists a user's threads, most recent first.
func (m *MessageStore) Conversations(user string) []Conversation {
	m.mu.RLock()
	defer m.mu.RUnlock()
	byPartner := make(map[string]*Conversation)
	for _, message := range m.messages {
		var partner string
		switch user {
		case message.From:
			partner = message.To
		case message.To:
			partner = message.From
		default:
			continue
		}
		conversation := byPartner[partner]
		if conversation == nil {
			conversation = &Conversation{With: partner}
			byPartner[partner] = conversation
		}
		conversation.Last = m.withReactionsLocked(message)
		if message.To == user && message.ID > m.state.ReadUpTo[readKey(user, partner)] {
			conversation.Unread++
		}
	}
	result := make([]Conversation, 0, len(byPartner))
	for _, conversation := range byPartner {
		result = append(result, *conversation)
	}
	sort.Slice(result, func(a, b int) bool { return result[a].Last.ID > result[b].Last.ID })
	return result
}

// MarkRead moves the read position forward; it never goes back.
func (m *MessageStore) MarkRead(user, with string, upTo int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := readKey(user, with)
	if upTo <= m.state.ReadUpTo[key] {
		return nil
	}
	m.state.ReadUpTo[key] = upTo
	return m.saveStateLocked()
}

// IsKnownUser reports whether someone has opened the app, which is how users appear.
func (m *MessageStore) IsKnownUser(user string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	_, known := m.state.Profiles[user]
	return known
}

// SaveProfile records a user's public details, keeping their avatar flag.
func (m *MessageStore) SaveProfile(profile Profile) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	profile.HasAvatar = m.state.Profiles[profile.User].HasAvatar
	profile.Taste = m.state.Profiles[profile.User].Taste
	m.state.Profiles[profile.User] = profile
	return m.saveStateLocked()
}

// Profiles lists everyone, sorted by user name.
func (m *MessageStore) Profiles() []Profile {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := make([]Profile, 0, len(m.state.Profiles))
	for _, profile := range m.state.Profiles {
		profile.NowPlaying = m.currentPlayingLocked(profile.User)
		result = append(result, profile)
	}
	sort.Slice(result, func(a, b int) bool { return result[a].User < result[b].User })
	return result
}

// SaveAvatar stores image bytes for a user.
func (m *MessageStore) SaveAvatar(user string, image []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	temp := m.avatarFile(user) + ".tmp"
	if err := os.WriteFile(temp, image, 0o666); err != nil {
		return err
	}
	if err := os.Rename(temp, m.avatarFile(user)); err != nil {
		return err
	}
	profile := m.state.Profiles[user]
	profile.User = user
	profile.HasAvatar = true
	m.state.Profiles[user] = profile
	return m.saveStateLocked()
}

// AddDevice remembers where to push for a user, dropping their oldest beyond the limit.
func (m *MessageStore) AddDevice(user, token string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	kept := make([]string, 0, maxDeviceTokens)
	for _, existing := range m.state.Devices[user] {
		if existing != token {
			kept = append(kept, existing)
		}
	}
	kept = append(kept, token)
	if len(kept) > maxDeviceTokens {
		kept = kept[len(kept)-maxDeviceTokens:]
	}
	m.state.Devices[user] = kept
	return m.saveStateLocked()
}

// RemoveDevices forgets tokens the push service says are dead.
func (m *MessageStore) RemoveDevices(user string, dead []string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	gone := make(map[string]bool, len(dead))
	for _, token := range dead {
		gone[token] = true
	}
	kept := make([]string, 0)
	for _, token := range m.state.Devices[user] {
		if !gone[token] {
			kept = append(kept, token)
		}
	}
	m.state.Devices[user] = kept
	return m.saveStateLocked()
}

// Devices returns a copy of a user's push tokens.
func (m *MessageStore) Devices(user string) []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return append([]string(nil), m.state.Devices[user]...)
}

// ------- Push relay -------

// PushRelay tells the relay that someone has a message. Only device tokens and a thread
// name leave the server: never the text. The relay proves nothing but "new message".
type PushRelay struct {
	URL    string
	Key    []byte
	Client *http.Client
	Now    func() time.Time
}

type relayRequest struct {
	Tokens         []string `json:"tokens"`
	ConversationID string   `json:"conversationId"`
	TimestampMs    int64    `json:"timestampMs"`
}

// signRelayBody is the same calculation the relay verifies.
func signRelayBody(key, body []byte) string {
	mac := hmac.New(sha256.New, key)
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

// Notify returns tokens the relay reported as dead.
func (r *PushRelay) Notify(ctx context.Context, tokens []string, conversationID string) ([]string, error) {
	body, err := json.Marshal(relayRequest{
		Tokens:         tokens,
		ConversationID: conversationID,
		TimestampMs:    r.Now().UnixMilli(),
	})
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, r.URL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Yomi-Signature", signRelayBody(r.Key, body))
	response, err := r.Client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("relay answered %d", response.StatusCode)
	}
	var reply struct {
		DeadTokens []string `json:"deadTokens"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, maxMessageBody)).Decode(&reply); err != nil {
		return nil, err
	}
	return reply.DeadTokens, nil
}

func newPushRelay(cfg Config) *PushRelay {
	if cfg.RelayURL == "" || cfg.RelayKey == "" {
		return nil
	}
	client, err := newInternetClient()
	if err != nil {
		log.Printf("push disabled: %v", err)
		return nil
	}
	return &PushRelay{URL: cfg.RelayURL, Key: []byte(cfg.RelayKey), Client: client, Now: time.Now}
}

// ------- HTTP -------

// socialUser authenticates and returns the normalised user, refusing on a replica: its
// messages wouldn't reach the main server, so they'd vanish on the way back.
func (s *Server) socialUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	if s.Messages == nil || s.isReplica() {
		writeError(w, http.StatusServiceUnavailable, "messages aren't available on this server")
		return "", false
	}
	user, ok := s.authenticate(w, r)
	if !ok {
		return "", false
	}
	safe, err := sanitizeUser(user)
	if err != nil {
		writeError(w, http.StatusBadRequest, "this account's name can't be used for messages")
		return "", false
	}
	return safe, true
}

func decodeBody(w http.ResponseWriter, r *http.Request, into any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxMessageBody)
	if err := json.NewDecoder(r.Body).Decode(into); err != nil {
		writeError(w, http.StatusBadRequest, "send valid JSON")
		return false
	}
	return true
}

func (s *Server) handleSend(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialUser(w, r)
	if !ok {
		return
	}
	var request struct {
		To         string `json:"to"`
		Text       string `json:"text"`
		SongID     string `json:"songId"`
		SongTitle  string `json:"songTitle"`
		AlbumID    string `json:"albumId"`
		PlaylistID string `json:"playlistId"`
		ReplyTo    int64  `json:"replyTo"`
	}
	if !decodeBody(w, r, &request) {
		return
	}
	to, err := sanitizeUser(request.To)
	if err != nil || !s.Messages.IsKnownUser(to) {
		writeError(w, http.StatusNotFound, "no such person")
		return
	}
	text := strings.TrimSpace(request.Text)
	if (text == "" && request.SongID == "" && request.AlbumID == "" && request.PlaylistID == "") || utf8.RuneCountInString(text) > maxMessageChars ||
		utf8.RuneCountInString(request.SongTitle) > maxNameChars*5 {
		writeError(w, http.StatusBadRequest, "a message needs text or a song, up to 4000 characters")
		return
	}
	if len(request.SongID) > maxReferenceIDBytes || len(request.AlbumID) > maxReferenceIDBytes ||
		len(request.PlaylistID) > maxReferenceIDBytes {
		writeError(w, http.StatusBadRequest, "that song, album or playlist ID is too long")
		return
	}
	message, err := s.Messages.Send(Message{
		From: user, To: to, Text: text, SongID: request.SongID, SongTitle: request.SongTitle,
		AlbumID: request.AlbumID, PlaylistID: request.PlaylistID, ReplyTo: request.ReplyTo,
	})
	switch {
	case errors.Is(err, errRateLimited):
		w.Header().Set("Retry-After", "30")
		writeError(w, http.StatusTooManyRequests, err.Error())
		return
	case err != nil:
		log.Printf("messages: send: %v", err)
		writeError(w, http.StatusInternalServerError, "could not save the message")
		return
	}
	go s.pushNewMessage(to, user)
	writeJSON(w, http.StatusCreated, message)
}

// pushNewMessage is best effort: the app also polls, so a failed push only delays a message.
func (s *Server) pushNewMessage(to, from string) {
	if s.Relay == nil {
		return
	}
	tokens := s.Messages.Devices(to)
	if len(tokens) == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), relayTimeout)
	defer cancel()
	dead, err := s.Relay.Notify(ctx, tokens, from)
	if err != nil {
		log.Printf("push: %v", err)
		return
	}
	if len(dead) > 0 {
		if err := s.Messages.RemoveDevices(to, dead); err != nil {
			log.Printf("push: forgetting dead devices: %v", err)
		}
	}
}

func (s *Server) handleThread(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialReader(w, r)
	if !ok {
		return
	}
	with, err := sanitizeUser(r.URL.Query().Get("with"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "say who the conversation is with")
		return
	}
	after, err := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	if err != nil {
		after = 0
	}
	before, err := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	if err != nil {
		before = 0
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": s.Messages.Thread(user, with, after, before)})
}

func (s *Server) handleConversations(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialReader(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"conversations": s.Messages.Conversations(user)})
}

func (s *Server) handleMarkRead(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialUser(w, r)
	if !ok {
		return
	}
	var request struct {
		With string `json:"with"`
		UpTo int64  `json:"upTo"`
	}
	if !decodeBody(w, r, &request) {
		return
	}
	with, err := sanitizeUser(request.With)
	if err != nil {
		writeError(w, http.StatusBadRequest, "say who the conversation is with")
		return
	}
	if err := s.Messages.MarkRead(user, with, request.UpTo); err != nil {
		log.Printf("messages: mark read: %v", err)
		writeError(w, http.StatusInternalServerError, "could not save that")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleSaveProfile(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialUser(w, r)
	if !ok {
		return
	}
	var request struct {
		DisplayName string `json:"displayName"`
		Bio         string `json:"bio"`
	}
	if !decodeBody(w, r, &request) {
		return
	}
	name := strings.TrimSpace(request.DisplayName)
	bio := strings.TrimSpace(request.Bio)
	if utf8.RuneCountInString(name) > maxNameChars || utf8.RuneCountInString(bio) > maxBioChars {
		writeError(w, http.StatusBadRequest, "name or bio is too long")
		return
	}
	if err := s.Messages.SaveProfile(Profile{User: user, DisplayName: name, Bio: bio}); err != nil {
		log.Printf("messages: save profile: %v", err)
		writeError(w, http.StatusInternalServerError, "could not save your profile")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleProfiles(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.socialUser(w, r); !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"profiles": s.Messages.Profiles()})
}

func looksLikeImage(data []byte) bool {
	switch http.DetectContentType(data) {
	case "image/jpeg", "image/png", "image/webp":
		return true
	}
	return false
}

func (s *Server) handleSaveAvatar(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialUser(w, r)
	if !ok {
		return
	}
	image, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAvatarBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "that picture is too large")
		return
	}
	if !looksLikeImage(image) {
		writeError(w, http.StatusUnsupportedMediaType, "send a JPEG, PNG or WebP picture")
		return
	}
	if err := s.Messages.SaveAvatar(user, image); err != nil {
		log.Printf("messages: save avatar: %v", err)
		writeError(w, http.StatusInternalServerError, "could not save the picture")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleAvatar(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.socialUser(w, r); !ok {
		return
	}
	target, err := sanitizeUser(r.PathValue("user"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad user name")
		return
	}
	data, err := os.ReadFile(s.Messages.avatarFile(target))
	if err != nil {
		writeError(w, http.StatusNotFound, "no picture")
		return
	}
	w.Header().Set("Content-Type", http.DetectContentType(data))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Write(data)
}

func (s *Server) handleRegisterDevice(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialUser(w, r)
	if !ok {
		return
	}
	var request struct {
		Token string `json:"token"`
	}
	if !decodeBody(w, r, &request) {
		return
	}
	token := strings.TrimSpace(request.Token)
	if token == "" || len(token) > maxTokenBytes {
		writeError(w, http.StatusBadRequest, "send a device token")
		return
	}
	if err := s.Messages.AddDevice(user, token); err != nil {
		log.Printf("messages: add device: %v", err)
		writeError(w, http.StatusInternalServerError, "could not save the device")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
