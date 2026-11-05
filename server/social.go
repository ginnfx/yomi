package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	eventsWait        = 25 * time.Second
	nowPlayingLasts   = 15 * time.Minute
	maxReactionBytes  = 32
	maxReactionRunes  = 8
	maxPlayingField   = 200
	reactionsFileName = "reactions.jsonl"
	stateRootMessages = "messages"
	stateRootHistory  = "history"
	stateMaxFileBytes = 64 << 20
	maxStateDepth     = 2
)

// NowPlaying is what someone is listening to, shared only if they turned that on.
type NowPlaying struct {
	SongID string `json:"songId"`
	Title  string `json:"title,omitempty"`
	Artist string `json:"artist,omitempty"`
	AtMs   int64  `json:"atMs"`
}

type reactionLine struct {
	ID    int64  `json:"id"`
	User  string `json:"user"`
	Emoji string `json:"emoji"`
}

func (m *MessageStore) reactionsFile() string { return filepath.Join(m.dir, reactionsFileName) }

func (m *MessageStore) loadReactions() error {
	file, err := os.Open(m.reactionsFile())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, maxLineBytes), maxLineBytes)
	for scanner.Scan() {
		var line reactionLine
		if json.Unmarshal(scanner.Bytes(), &line) != nil {
			log.Printf("messages: skipping damaged reaction")
			continue
		}
		m.applyReactionLocked(line)
	}
	return scanner.Err()
}

func (m *MessageStore) applyReactionLocked(line reactionLine) {
	if line.Emoji == "" {
		delete(m.reactions[line.ID], line.User)
		return
	}
	if m.reactions[line.ID] == nil {
		m.reactions[line.ID] = map[string]string{}
	}
	m.reactions[line.ID][line.User] = line.Emoji
}

// withReactions copies a message and adds who reacted, so the stored one never changes.
func (m *MessageStore) withReactionsLocked(message Message) Message {
	reactions := m.reactions[message.ID]
	if len(reactions) == 0 {
		return message
	}
	message.Reactions = make(map[string]string, len(reactions))
	for user, emoji := range reactions {
		message.Reactions[user] = emoji
	}
	return message
}

var errNoSuchMessage = errors.New("no such message")

// React sets, or with an empty emoji removes, this user's reaction to a message of theirs.
func (m *MessageStore) React(user string, id int64, emoji string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	var target *Message
	for i := range m.messages {
		if m.messages[i].ID == id {
			target = &m.messages[i]
			break
		}
	}
	if target == nil || (target.From != user && target.To != user) {
		return errNoSuchMessage
	}
	line := reactionLine{ID: id, User: user, Emoji: emoji}
	data, err := json.Marshal(line)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(m.reactionsFile(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := file.Write(append(data, '\n')); err != nil {
		return err
	}
	m.applyReactionLocked(line)
	m.bumpLocked(target.From, target.To)
	return nil
}

// bumpLocked tells anyone waiting on these people that something changed.
func (m *MessageStore) bumpLocked(users ...string) {
	for _, user := range users {
		m.revisions[user]++
	}
	close(m.changed)
	m.changed = make(chan struct{})
}

// Revision is a number that changes whenever something new concerns this user.
func (m *MessageStore) Revision(user string) int64 {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.revisions[user]
}

// WaitForChange waits until the user's revision differs from the one given, then returns
// the current one. It also returns when ctx ends. Waiting costs almost nothing, and a
// revision reset by a server restart also counts as a change.
func (m *MessageStore) WaitForChange(ctx context.Context, user string, seen int64) int64 {
	for {
		m.mu.RLock()
		current := m.revisions[user]
		changed := m.changed
		m.mu.RUnlock()
		if current != seen {
			return current
		}
		select {
		case <-ctx.Done():
			return current
		case <-changed:
		}
	}
}

// SetPlaying records what someone is listening to, or clears it with an empty song.
func (m *MessageStore) SetPlaying(user string, playing NowPlaying) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if playing.SongID == "" {
		delete(m.playing, user)
		return
	}
	playing.AtMs = m.now().UnixMilli()
	m.playing[user] = playing
}

func (m *MessageStore) currentPlayingLocked(user string) *NowPlaying {
	playing, ok := m.playing[user]
	if !ok || m.now().Sub(time.UnixMilli(playing.AtMs)) > nowPlayingLasts {
		return nil
	}
	return &playing
}

// Reload reads everything from disk again, after a backup server has copied new files.
func (m *MessageStore) Reload() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.messages = nil
	m.reactions = map[int64]map[string]string{}
	if err := m.loadMessages(); err != nil {
		log.Printf("messages: reload: %v", err)
	}
	if err := m.loadReactions(); err != nil {
		log.Printf("messages: reload reactions: %v", err)
	}
	if err := m.loadState(); err != nil {
		log.Printf("messages: reload state: %v", err)
	}
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialReader(w, r)
	if !ok {
		return
	}
	seen, err := strconv.ParseInt(r.URL.Query().Get("rev"), 10, 64)
	if err != nil {
		seen = -1
	}
	ctx, cancel := context.WithTimeout(r.Context(), eventsWait)
	defer cancel()
	writeJSON(w, http.StatusOK, map[string]int64{"rev": s.Messages.WaitForChange(ctx, user, seen)})
}

func (s *Server) handleReact(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialUser(w, r)
	if !ok {
		return
	}
	var request struct {
		ID    int64  `json:"id"`
		Emoji string `json:"emoji"`
	}
	if !decodeBody(w, r, &request) {
		return
	}
	emoji := strings.TrimSpace(request.Emoji)
	if len(emoji) > maxReactionBytes || utf8.RuneCountInString(emoji) > maxReactionRunes {
		writeError(w, http.StatusBadRequest, "that isn't a reaction")
		return
	}
	switch err := s.Messages.React(user, request.ID, emoji); {
	case errors.Is(err, errNoSuchMessage):
		writeError(w, http.StatusNotFound, err.Error())
	case err != nil:
		log.Printf("messages: react: %v", err)
		writeError(w, http.StatusInternalServerError, "could not save that")
	default:
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func (s *Server) handleSetPlaying(w http.ResponseWriter, r *http.Request) {
	user, ok := s.socialUser(w, r)
	if !ok {
		return
	}
	var request NowPlaying
	if !decodeBody(w, r, &request) {
		return
	}
	for _, field := range []string{request.SongID, request.Title, request.Artist} {
		if utf8.RuneCountInString(field) > maxPlayingField {
			writeError(w, http.StatusBadRequest, "that's too long")
			return
		}
	}
	s.Messages.SetPlaying(user, request)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// socialReader is socialUser for things that only read, which also work on a backup server
// so chats stay visible while the main server is away.
func (s *Server) socialReader(w http.ResponseWriter, r *http.Request) (string, bool) {
	if s.Messages == nil {
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

// stateFile is one file a backup server should keep a copy of.
type stateFile struct {
	Root  string `json:"root"`
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	ModMs int64  `json:"modMs"`
}

func (s *Server) stateRoots() map[string]string {
	roots := map[string]string{}
	if s.Messages != nil {
		roots[stateRootMessages] = s.Messages.dir
	}
	if s.History != nil {
		roots[stateRootHistory] = s.History.dir
	}
	return roots
}

// listStateFiles walks a root, ignoring half-written files.
func listStateFiles(root, label string) ([]stateFile, error) {
	var files []stateFile
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if strings.Count(relative, string(filepath.Separator)) >= maxStateDepth {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(relative, ".tmp") {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		files = append(files, stateFile{Root: label, Name: filepath.ToSlash(relative), Size: info.Size(), ModMs: info.ModTime().UnixMilli()})
		return nil
	})
	return files, err
}

func (s *Server) handleStateIndex(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	files := []stateFile{}
	for label, root := range s.stateRoots() {
		found, err := listStateFiles(root, label)
		if err != nil {
			log.Printf("list state files: %v", err)
			writeError(w, http.StatusInternalServerError, "couldn't list files")
			return
		}
		files = append(files, found...)
	}
	writeJSON(w, http.StatusOK, map[string]any{"files": files})
}

func (s *Server) handleStateFile(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	query := r.URL.Query()
	root, known := s.stateRoots()[query.Get("root")]
	name := filepath.FromSlash(query.Get("name"))
	if !known || !filepath.IsLocal(name) {
		writeError(w, http.StatusNotFound, "no such file")
		return
	}
	http.ServeFile(w, r, filepath.Join(root, name))
}

// StateSync gives a backup server copies of chats and listening history, so they survive
// the main server failing. Music and the library have their own sync in ReplicaSync.
type StateSync struct {
	PrimaryURL string
	Login      url.Values
	Client     *http.Client
	Roots      map[string]string
	OnChanged  func()
	seen       map[string]stateFile
}

// Run copies anything new or changed. One bad file doesn't stop the others.
func (r *StateSync) Run(ctx context.Context) error {
	files, err := r.fetchIndex(ctx)
	if err != nil {
		return err
	}
	if r.seen == nil {
		r.seen = map[string]stateFile{}
	}
	isChanged := false
	var firstFailure error
	for _, file := range files {
		key := file.Root + "/" + file.Name
		if r.seen[key] == file {
			continue
		}
		if err := r.fetchFile(ctx, file); err != nil {
			log.Printf("replica state: %s: %v", key, redactURL(err))
			if firstFailure == nil {
				firstFailure = err
			}
			continue
		}
		r.seen[key] = file
		isChanged = true
	}
	if isChanged && r.OnChanged != nil {
		r.OnChanged()
	}
	return firstFailure
}

func (r *StateSync) get(ctx context.Context, path string, extra url.Values) (*http.Response, error) {
	query := url.Values{}
	for key, values := range r.Login {
		query[key] = values
	}
	for key, values := range extra {
		query[key] = values
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, r.PrimaryURL+path+"?"+query.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := r.Client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("primary answered %d", resp.StatusCode)
	}
	return resp, nil
}

func (r *StateSync) fetchIndex(ctx context.Context) ([]stateFile, error) {
	resp, err := r.get(ctx, "/v1/replica/state", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var reply struct {
		Files []stateFile `json:"files"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&reply); err != nil {
		return nil, err
	}
	return reply.Files, nil
}

func (r *StateSync) fetchFile(ctx context.Context, file stateFile) error {
	root, known := r.Roots[file.Root]
	name := filepath.FromSlash(file.Name)
	// The primary is trusted, but a bad path must never write outside these folders.
	if !known || !filepath.IsLocal(name) || file.Size > stateMaxFileBytes {
		return errors.New("refusing unsafe state file")
	}
	resp, err := r.get(ctx, "/v1/replica/state/file", url.Values{"root": {file.Root}, "name": {file.Name}})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	target := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return err
	}
	temp := target + ".tmp"
	out, err := os.OpenFile(temp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, io.LimitReader(resp.Body, stateMaxFileBytes))
	closeErr := out.Close()
	if copyErr != nil || closeErr != nil {
		os.Remove(temp)
		return errors.Join(copyErr, closeErr)
	}
	return os.Rename(temp, target)
}
