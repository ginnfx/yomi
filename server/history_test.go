package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func historyEvent(id string) HistoryEvent {
	return HistoryEvent{
		ID: id, SongID: "song-" + id, Artist: "A", Title: "T", AtMs: time.Now().UnixMilli(), Kind: "completed", Seconds: 200,
	}
}

func openTestHistory(t *testing.T) *HistoryStore {
	t.Helper()
	store, err := openHistoryStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func TestHistoryRoundTripAndCursor(t *testing.T) {
	store := openTestHistory(t)
	added, err := store.Add("alice", []HistoryEvent{historyEvent("1"), historyEvent("2")})
	if err != nil || added != 2 {
		t.Fatalf("added=%d err=%v", added, err)
	}
	first, next, err := store.Read("alice", 0, 1)
	if err != nil || len(first) != 1 || first[0].ID != "1" {
		t.Fatalf("first=%v err=%v", first, err)
	}
	second, next2, err := store.Read("alice", next, 10)
	if err != nil || len(second) != 1 || second[0].ID != "2" {
		t.Fatalf("second=%v err=%v", second, err)
	}
	empty, next3, err := store.Read("alice", next2, 10)
	if err != nil || len(empty) != 0 || next3 != next2 {
		t.Fatalf("empty=%v next=%d err=%v", empty, next3, err)
	}
}

func TestHistoryRetriesDoNotDoubleCount(t *testing.T) {
	store := openTestHistory(t)
	batch := []HistoryEvent{historyEvent("1"), historyEvent("2")}
	if _, err := store.Add("alice", batch); err != nil {
		t.Fatal(err)
	}
	added, err := store.Add("alice", append(batch, historyEvent("2"), historyEvent("3")))
	if err != nil {
		t.Fatal(err)
	}
	if added != 1 {
		t.Fatalf("added = %d", added)
	}
	events, _, _ := store.Read("alice", 0, 100)
	if len(events) != 3 {
		t.Fatalf("events = %d", len(events))
	}
}

func TestHistoryIsSeparatePerUser(t *testing.T) {
	store := openTestHistory(t)
	if _, err := store.Add("alice", []HistoryEvent{historyEvent("1")}); err != nil {
		t.Fatal(err)
	}
	events, _, err := store.Read("bob", 0, 10)
	if err != nil || len(events) != 0 {
		t.Fatalf("events=%v err=%v", events, err)
	}
}

func TestHistoryDropsInvalidEvents(t *testing.T) {
	store := openTestHistory(t)
	bad := []HistoryEvent{
		{ID: "", SongID: "s", AtMs: time.Now().UnixMilli(), Kind: "completed"},
		{ID: "1", SongID: "", AtMs: time.Now().UnixMilli(), Kind: "completed"},
		{ID: "2", SongID: "s", AtMs: 5, Kind: "completed"},
		{ID: "3", SongID: "s", AtMs: time.Now().Add(72 * time.Hour).UnixMilli(), Kind: "completed"},
		{ID: "4", SongID: "s", AtMs: time.Now().UnixMilli(), Kind: "banana"},
		{ID: strings.Repeat("x", historyMaxField+1), SongID: "s", AtMs: time.Now().UnixMilli(), Kind: "completed"},
		{ID: "5", SongID: "s", Artist: strings.Repeat("x", historyMaxField+1), AtMs: time.Now().UnixMilli(), Kind: "completed"},
	}
	added, err := store.Add("alice", bad)
	if err != nil || added != 0 {
		t.Fatalf("added=%d err=%v", added, err)
	}
}

func TestHistoryIgnoresADamagedLine(t *testing.T) {
	store := openTestHistory(t)
	if _, err := store.Add("alice", []HistoryEvent{historyEvent("1")}); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(store.logFile("alice"), os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("{not json\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()
	if _, err := store.Add("alice", []HistoryEvent{historyEvent("2")}); err != nil {
		t.Fatal(err)
	}
	events, _, err := store.Read("alice", 0, 10)
	if err != nil || len(events) != 2 {
		t.Fatalf("events=%v err=%v", events, err)
	}
}

func TestHistoryCursorBeyondTheEndStartsAgain(t *testing.T) {
	store := openTestHistory(t)
	if _, err := store.Add("alice", []HistoryEvent{historyEvent("1")}); err != nil {
		t.Fatal(err)
	}
	events, _, err := store.Read("alice", 1<<40, 10)
	if err != nil || len(events) != 1 {
		t.Fatalf("events=%v err=%v", events, err)
	}
}

func historyServer(t *testing.T, cfg Config) (*httptest.Server, *Server) {
	t.Helper()
	cfg.MusicDir = t.TempDir()
	cfg.MaxFileBytes = 1 << 10
	server := newServer(cfg, fakeAuth{}, nil, nil)
	server.History = openTestHistory(t)
	ts := httptest.NewServer(server.routes())
	t.Cleanup(ts.Close)
	return ts, server
}

func historyCall(t *testing.T, ts *httptest.Server, method, path, user, body string) (int, string) {
	t.Helper()
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	req, err := http.NewRequest(method, fmt.Sprintf("%s%s%su=%s&p=good", ts.URL, path, separator, user), strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	buffer := new(strings.Builder)
	var chunk [4096]byte
	for {
		n, readErr := resp.Body.Read(chunk[:])
		buffer.Write(chunk[:n])
		if readErr != nil {
			break
		}
	}
	return resp.StatusCode, buffer.String()
}

func TestHistoryRoutes(t *testing.T) {
	ts, _ := historyServer(t, Config{})
	body, _ := json.Marshal(map[string]any{"events": []HistoryEvent{historyEvent("1")}})
	status, reply := historyCall(t, ts, http.MethodPost, "/v1/history", "alice", string(body))
	if status != http.StatusOK || !strings.Contains(reply, `"added":1`) {
		t.Fatalf("status %d reply %s", status, reply)
	}
	status, reply = historyCall(t, ts, http.MethodGet, "/v1/history?after=0", "alice", "")
	if status != http.StatusOK || !strings.Contains(reply, "song-1") || !strings.Contains(reply, `"next"`) {
		t.Fatalf("status %d reply %s", status, reply)
	}
	status, reply = historyCall(t, ts, http.MethodGet, "/v1/history", "bob", "")
	if status != http.StatusOK || strings.Contains(reply, "song-1") {
		t.Fatalf("another user could read it: %d %s", status, reply)
	}
}

func TestHistoryRoutesNeedALogin(t *testing.T) {
	ts, _ := historyServer(t, Config{})
	resp, err := ts.Client().Get(ts.URL + "/v1/history?u=alice&p=wrong")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestHistoryRejectsAnOversizedBatch(t *testing.T) {
	ts, _ := historyServer(t, Config{})
	events := make([]HistoryEvent, historyMaxBatch+1)
	for i := range events {
		events[i] = historyEvent(fmt.Sprint(i))
	}
	body, _ := json.Marshal(map[string]any{"events": events})
	status, _ := historyCall(t, ts, http.MethodPost, "/v1/history", "alice", string(body))
	if status != http.StatusBadRequest {
		t.Fatalf("status %d", status)
	}
}

func TestImportedHistoryReplacesAndStaysPrivate(t *testing.T) {
	ts, server := historyServer(t, Config{})
	status, _ := historyCall(t, ts, http.MethodPut, "/v1/history/imported", "alice", `{"totals":[1]}`)
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	status, _ = historyCall(t, ts, http.MethodPut, "/v1/history/imported", "alice", `{"totals":[2]}`)
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	status, reply := historyCall(t, ts, http.MethodGet, "/v1/history/imported", "alice", "")
	if status != http.StatusOK || !strings.Contains(reply, "[2]") {
		t.Fatalf("status %d reply %s", status, reply)
	}
	status, reply = historyCall(t, ts, http.MethodGet, "/v1/history/imported", "bob", "")
	if status != http.StatusOK || strings.TrimSpace(reply) != "{}" {
		t.Fatalf("status %d reply %s", status, reply)
	}
	status, _ = historyCall(t, ts, http.MethodPut, "/v1/history/imported", "alice", `{not json`)
	if status != http.StatusBadRequest {
		t.Fatalf("status %d", status)
	}
	info, err := os.Stat(filepath.Join(server.History.dir, "imported-alice.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		t.Fatalf("mode %v", info.Mode())
	}
}

func TestHistoryWritesAreRefusedOnAReplica(t *testing.T) {
	ts, _ := historyServer(t, Config{Role: roleReplica})
	body, _ := json.Marshal(map[string]any{"events": []HistoryEvent{historyEvent("1")}})
	status, _ := historyCall(t, ts, http.MethodPost, "/v1/history", "alice", string(body))
	if status != http.StatusServiceUnavailable {
		t.Fatalf("status %d", status)
	}
	status, _ = historyCall(t, ts, http.MethodGet, "/v1/history", "alice", "")
	if status != http.StatusOK {
		t.Fatalf("reading from a replica: status %d", status)
	}
}
