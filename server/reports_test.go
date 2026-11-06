package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// reportsEnv is a server whose Navidrome says only "admin" is an admin.
type reportsEnv struct {
	ts       *httptest.Server
	server   *Server
	music    string
	scans    int
	songPath map[string]string
}

func newReportsEnv(t *testing.T) *reportsEnv {
	t.Helper()
	navidrome := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"subsonic-response": map[string]any{
				"status": "ok",
				"user":   map[string]any{"adminRole": r.URL.Query().Get("u") == "admin"},
			},
		})
	}))
	t.Cleanup(navidrome.Close)
	dir := t.TempDir()
	env := &reportsEnv{music: filepath.Join(dir, "music"), songPath: map[string]string{}}
	if err := os.MkdirAll(env.music, 0o755); err != nil {
		t.Fatal(err)
	}
	server := newServer(Config{MusicDir: env.music, NavidromeURL: navidrome.URL}, fakeAuth{}, func(context.Context, url.Values) {
		env.scans++
	}, nil)
	store, err := openReportStore(filepath.Join(dir, "reports"), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	server.Reports = store
	server.SongPath = func(_ context.Context, _ url.Values, id string) (string, error) {
		path, ok := env.songPath[id]
		if !ok {
			return "", errNoSuchSong
		}
		return path, nil
	}
	env.server = server
	env.ts = httptest.NewServer(server.routes())
	t.Cleanup(env.ts.Close)
	return env
}

func (e *reportsEnv) call(t *testing.T, method, path, user string, body any) (int, []byte) {
	t.Helper()
	var payload []byte
	if body != nil {
		var err error
		if payload, err = json.Marshal(body); err != nil {
			t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, e.ts.URL+path+"?u="+user+"&p=good", bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := e.ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	_, _ = buf.ReadFrom(resp.Body)
	return resp.StatusCode, buf.Bytes()
}

func (e *reportsEnv) list(t *testing.T, user string) []Report {
	t.Helper()
	status, data := e.call(t, http.MethodGet, "/v1/reports", user, nil)
	if status != http.StatusOK {
		t.Fatalf("list: %d %s", status, data)
	}
	var body struct {
		Reports []Report `json:"reports"`
	}
	if err := json.Unmarshal(data, &body); err != nil {
		t.Fatal(err)
	}
	return body.Reports
}

func TestReportValidation(t *testing.T) {
	env := newReportsEnv(t)
	long := string(bytes.Repeat([]byte("a"), maxReportNoteChars+1))
	cases := []struct {
		name string
		body map[string]any
		want int
	}{
		{"unknown kind", map[string]any{"kind": "spam", "artist": "A", "title": "T"}, http.StatusBadRequest},
		{"no title", map[string]any{"kind": "missing_song", "artist": "A"}, http.StatusBadRequest},
		{"note too long", map[string]any{"kind": "other", "artist": "A", "title": "T", "note": long}, http.StatusBadRequest},
		{"good", map[string]any{"kind": "explicit_wanted", "songId": "s1", "artist": "A", "title": "T"}, http.StatusCreated},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, data := env.call(t, http.MethodPost, "/v1/reports", "alice", tc.body)
			if status != tc.want {
				t.Fatalf("status %d, want %d: %s", status, tc.want, data)
			}
		})
	}
}

func TestSameProblemFromTwoPeopleIsOneReport(t *testing.T) {
	env := newReportsEnv(t)
	body := map[string]any{"kind": "missing_song", "artist": "Mira", "title": "Blue Hour"}
	env.call(t, http.MethodPost, "/v1/reports", "alice", body)
	body["title"] = "  blue hour "
	status, _ := env.call(t, http.MethodPost, "/v1/reports", "bob", body)
	if status != http.StatusOK {
		t.Fatalf("second report should merge (200), got %d", status)
	}

	reports := env.list(t, "admin")
	if len(reports) != 1 || reports[0].Count != 2 {
		t.Fatalf("want one report asked for by 2, got %+v", reports)
	}
}

func TestPeopleSeeOnlyTheirOwnReports(t *testing.T) {
	env := newReportsEnv(t)
	env.call(t, http.MethodPost, "/v1/reports", "alice", map[string]any{"kind": "cover_wrong", "songId": "s1", "artist": "A", "title": "T"})
	env.call(t, http.MethodPost, "/v1/reports", "bob", map[string]any{"kind": "cover_wrong", "songId": "s2", "artist": "B", "title": "U"})

	mine := env.list(t, "alice")
	if len(mine) != 1 || mine[0].SongID != "s1" {
		t.Fatalf("alice should see only her report, got %+v", mine)
	}
	if len(mine[0].Reporters) != 0 {
		t.Fatalf("who else asked stays private, got %v", mine[0].Reporters)
	}
	if all := env.list(t, "admin"); len(all) != 2 {
		t.Fatalf("admin should see both, got %d", len(all))
	}
}

func TestOnlyAdminsResolveOrDismiss(t *testing.T) {
	env := newReportsEnv(t)
	_, data := env.call(t, http.MethodPost, "/v1/reports", "alice", map[string]any{"kind": "other", "artist": "A", "title": "T"})
	var created Report
	_ = json.Unmarshal(data, &created)

	status, _ := env.call(t, http.MethodPatch, "/v1/reports/"+created.ID, "alice", map[string]any{"status": "resolved"})
	if status != http.StatusForbidden {
		t.Fatalf("non-admin got %d", status)
	}
	status, _ = env.call(t, http.MethodPatch, "/v1/reports/"+created.ID, "admin", map[string]any{"status": "dismissed", "resolution": "it's fine"})
	if status != http.StatusOK {
		t.Fatalf("admin got %d", status)
	}
	if got := env.list(t, "alice")[0]; got.Status != reportDismissed || got.Resolution != "it's fine" {
		t.Fatalf("reporter should see the outcome, got %+v", got)
	}
}

func TestAnyoneCanMarkAMissingSongAdded(t *testing.T) {
	env := newReportsEnv(t)
	_, data := env.call(t, http.MethodPost, "/v1/reports", "alice", map[string]any{"kind": "missing_song", "artist": "A", "title": "T"})
	var created Report
	_ = json.Unmarshal(data, &created)

	status, _ := env.call(t, http.MethodPost, "/v1/reports/"+created.ID+"/added", "bob", map[string]any{"songId": "new1"})

	if status != http.StatusOK {
		t.Fatalf("got %d", status)
	}
	if got := env.list(t, "alice")[0]; got.Status != reportResolved || got.FixedSongID != "new1" {
		t.Fatalf("want resolved with the new song, got %+v", got)
	}
}

func TestReplaceArchivesTheOldCopyAndRescans(t *testing.T) {
	env := newReportsEnv(t)
	old := filepath.Join(env.music, "Artist", "Album", "song.m4a")
	if err := os.MkdirAll(filepath.Dir(old), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(old, []byte("clean"), 0o644); err != nil {
		t.Fatal(err)
	}
	env.songPath["old1"] = "Artist/Album/song.m4a"
	_, data := env.call(t, http.MethodPost, "/v1/reports", "alice", map[string]any{"kind": "explicit_wanted", "songId": "old1", "artist": "A", "title": "T"})
	var created Report
	_ = json.Unmarshal(data, &created)

	status, body := env.call(t, http.MethodPost, "/v1/reports/"+created.ID+"/replace", "admin", map[string]any{"oldSongId": "old1", "newSongId": "new1"})

	if status != http.StatusOK {
		t.Fatalf("got %d %s", status, body)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("the old copy should have moved")
	}
	archived := filepath.Join(env.music, replaceArchiveDir, "Artist", "Album", "song.m4a")
	if _, err := os.Stat(archived); err != nil {
		t.Fatalf("the old copy should be in the archive: %v", err)
	}
	if env.scans != 1 {
		t.Fatalf("want a rescan, got %d", env.scans)
	}
	if got := env.list(t, "admin")[0]; got.Status != reportResolved {
		t.Fatalf("want resolved, got %s", got.Status)
	}
}

func TestReplaceRefusesPathsOutsideTheLibrary(t *testing.T) {
	env := newReportsEnv(t)
	env.songPath["bad"] = "../../etc/passwd"
	_, data := env.call(t, http.MethodPost, "/v1/reports", "alice", map[string]any{"kind": "explicit_wanted", "songId": "bad", "artist": "A", "title": "T"})
	var created Report
	_ = json.Unmarshal(data, &created)

	status, _ := env.call(t, http.MethodPost, "/v1/reports/"+created.ID+"/replace", "admin", map[string]any{"oldSongId": "bad", "newSongId": "new1"})

	if status != http.StatusBadRequest {
		t.Fatalf("got %d", status)
	}
}

func TestReportsSurviveARestart(t *testing.T) {
	dir := t.TempDir()
	store, err := openReportStore(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Add("alice", ReportInput{Kind: "missing_song", Artist: "A", Title: "T"}); err != nil {
		t.Fatal(err)
	}

	reopened, err := openReportStore(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}

	if got := reopened.List("alice", false); len(got) != 1 {
		t.Fatalf("want 1 after restart, got %d", len(got))
	}
	info, err := os.Stat(filepath.Join(dir, reportsFile))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("reports file should be private, got %v", info.Mode().Perm())
	}
}

func TestAutoReportsComeAndGoWithTheCoverFetcher(t *testing.T) {
	store, err := openReportStore(t.TempDir(), time.Now)
	if err != nil {
		t.Fatal(err)
	}

	store.AddAuto(reportCoverMissing, "Artist/Album", "Artist", "Album")
	store.AddAuto(reportCoverMissing, "Artist/Album", "Artist", "Album")
	if got := store.List("", true); len(got) != 1 || !got[0].Auto {
		t.Fatalf("want one automatic report, got %+v", got)
	}
	store.ResolveAuto(reportCoverMissing, "Artist/Album")

	if got := store.List("", true); got[0].Status != reportResolved {
		t.Fatalf("want resolved once the cover was found, got %s", got[0].Status)
	}
}

func TestRateLimitSparesMissingSongRequests(t *testing.T) {
	store, err := openReportStore(t.TempDir(), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	for i := range maxReportsPerMinute + 5 {
		if _, _, err := store.Add("alice", ReportInput{Kind: reportMissingSong, Artist: "A", Title: fmt.Sprint("T", i)}); err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
	}
	for i := range maxReportsPerMinute {
		if _, _, err := store.Add("alice", ReportInput{Kind: reportOther, Artist: "A", Title: fmt.Sprint("O", i)}); err != nil {
			t.Fatalf("report %d: %v", i, err)
		}
	}

	_, _, err = store.Add("alice", ReportInput{Kind: reportOther, Artist: "A", Title: "one too many"})

	if !errors.Is(err, errTooManyReports) {
		t.Fatalf("want the limit, got %v", err)
	}
}
