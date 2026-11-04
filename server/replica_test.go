package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type replicaWorld struct {
	navidrome  *fakeNavidrome
	primary    *Server
	primaryURL string
	sync       *ReplicaSync
	applied    int
	root       string
}

func newReplicaWorld(t *testing.T) *replicaWorld {
	t.Helper()
	navidrome := newFakeNavidrome(t)
	navidrome.isAdmin.Store(true)
	primaryDir := t.TempDir()
	primaryIndex, _ := openHashIndex(primaryDir, filepath.Join(t.TempDir(), "i.jsonl"))
	backupDir := t.TempDir()
	primary := newServer(Config{MusicDir: primaryDir, NavidromeURL: navidrome.url, MaxFileBytes: 1 << 20}, fakeAuth{}, nil, primaryIndex)
	primary.Backups = &BackupSource{
		Dir: backupDir,
		Now: time.Now,
		Create: func(context.Context) error {
			return os.WriteFile(filepath.Join(backupDir, "navidrome.db"), []byte(sqliteHeader+"data"), 0o666)
		},
	}
	ts := httptest.NewServer(primary.routes())
	t.Cleanup(ts.Close)
	root := t.TempDir()
	replicaIndex, _ := openHashIndex(root, filepath.Join(t.TempDir(), "i.jsonl"))
	world := &replicaWorld{navidrome: navidrome, primary: primary, primaryURL: ts.URL, root: root}
	world.sync = &ReplicaSync{
		PrimaryURL:   ts.URL,
		Login:        map[string][]string{"u": {"keli"}, "p": {"good"}},
		Root:         root,
		Index:        replicaIndex,
		DatabaseFile: filepath.Join(t.TempDir(), "navidrome.db"),
		Client:       ts.Client(),
		HasRoomFor:   func(int64) bool { return true },
		Apply: func(context.Context) error {
			world.applied++
			return nil
		},
	}
	return world
}

func (w *replicaWorld) addToPrimary(t *testing.T, relative string, content []byte) {
	t.Helper()
	path := filepath.Join(w.primary.Config.MusicDir, relative)
	os.MkdirAll(filepath.Dir(path), 0o777)
	os.WriteFile(path, content, 0o666)
	if err := w.primary.Index.Add(indexEntry{SHA256: sum(content), Path: relative, Size: int64(len(content))}); err != nil {
		t.Fatal(err)
	}
}

func TestReplicaCopiesFilesToTheSamePaths(t *testing.T) {
	world := newReplicaWorld(t)
	world.addToPrimary(t, "keli/A/B/song.mp3", mp3Bytes)

	if err := world.sync.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}

	copied, err := os.ReadFile(filepath.Join(world.root, "keli/A/B/song.mp3"))
	if err != nil || sum(copied) != sum(mp3Bytes) {
		t.Fatalf("copy wrong: %v", err)
	}
	if _, found := world.sync.Index.Lookup(sum(mp3Bytes)); !found {
		t.Fatal("copied file is not indexed")
	}
}

func TestReplicaAppliesDatabaseOnceUntilItChanges(t *testing.T) {
	world := newReplicaWorld(t)
	world.addToPrimary(t, "keli/song.mp3", mp3Bytes)

	world.sync.Sync(context.Background())
	world.sync.Sync(context.Background())
	if world.applied != 1 {
		t.Fatalf("applied = %d, want 1", world.applied)
	}

	world.primary.Backups.made = time.Time{}
	time.Sleep(5 * time.Millisecond)
	os.WriteFile(filepath.Join(world.primary.Backups.Dir, "navidrome.db"), []byte(sqliteHeader+"newer"), 0o666)
	world.sync.Sync(context.Background())
	if world.applied != 2 {
		t.Fatalf("applied after change = %d, want 2", world.applied)
	}
}

func TestDatabaseWaitsUntilEveryFileArrived(t *testing.T) {
	world := newReplicaWorld(t)
	world.addToPrimary(t, "keli/song.mp3", mp3Bytes)
	world.sync.HasRoomFor = func(int64) bool { return false }

	err := world.sync.Sync(context.Background())

	if err == nil || world.applied != 0 {
		t.Fatalf("err = %v, applied = %d", err, world.applied)
	}
}

func TestNotADatabaseIsRefused(t *testing.T) {
	world := newReplicaWorld(t)
	dir := world.primary.Backups.Dir
	world.primary.Backups.Create = func(context.Context) error {
		return os.WriteFile(filepath.Join(dir, "navidrome.db"), []byte("<html>"), 0o666)
	}

	err := world.sync.Sync(context.Background())

	if err == nil || world.applied != 0 {
		t.Fatalf("err = %v, applied = %d", err, world.applied)
	}
}

func TestFailedApplyIsRetriedNextPass(t *testing.T) {
	world := newReplicaWorld(t)
	calls := 0
	world.sync.Apply = func(context.Context) error {
		calls++
		if calls == 1 {
			return errors.New("navidrome would not stop")
		}
		return nil
	}
	if err := world.sync.Sync(context.Background()); err == nil {
		t.Fatal("expected the failure to be reported")
	}
	if err := world.sync.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("calls = %d", calls)
	}
}

func TestUnsafePathsFromTheIndexAreRefused(t *testing.T) {
	world := newReplicaWorld(t)
	for _, path := range []string{"../../etc/evil.mp3", "/etc/evil.mp3"} {
		err := world.sync.fetchFile(context.Background(), indexEntry{SHA256: sum(mp3Bytes), Path: path})
		if err == nil || !strings.Contains(err.Error(), "unsafe") {
			t.Errorf("%s: err = %v", path, err)
		}
	}
}

func TestCorruptedCopyIsNotKept(t *testing.T) {
	world := newReplicaWorld(t)
	world.addToPrimary(t, "keli/song.mp3", mp3Bytes)
	wrong := indexEntry{SHA256: sum(mp3Bytes), Path: "keli/song.mp3"}
	os.WriteFile(filepath.Join(world.primary.Config.MusicDir, "keli/song.mp3"), []byte("damaged"), 0o666)

	err := world.sync.fetchFile(context.Background(), wrong)

	if !errors.Is(err, errHashMismatch) {
		t.Fatalf("err = %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(world.root, "keli/song.mp3")); statErr == nil {
		t.Fatal("kept a damaged copy")
	}
}

func TestReplicaRoutesAreAdminOnly(t *testing.T) {
	world := newReplicaWorld(t)
	world.navidrome.isAdmin.Store(false)
	for _, path := range []string{"/v1/replica/index", "/v1/replica/database", "/v1/replica/file/" + sum(mp3Bytes)} {
		response, err := http.Get(world.primaryURL + path + "?u=friend&p=good")
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusForbidden {
			t.Errorf("%s: status = %d", path, response.StatusCode)
		}
	}
}

func TestReplicaRefusesUploadsAndSaysWhatItIs(t *testing.T) {
	dir := t.TempDir()
	index, _ := openHashIndex(dir, filepath.Join(t.TempDir(), "i.jsonl"))
	server := newServer(Config{MusicDir: dir, MaxFileBytes: 1 << 20, Role: roleReplica}, fakeAuth{}, nil, index)
	ts := httptest.NewServer(server.routes())
	defer ts.Close()

	resp := postFile(t, ts.URL, "u=keli&p=good", "song.mp3", mp3Bytes)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("legacy status = %d", resp.StatusCode)
	}
	env := bulkEnv{url: ts.URL, dir: dir, server: server}
	if status, _ := env.put(t, sum(mp3Bytes), "song.mp3", mp3Bytes); status != http.StatusForbidden {
		t.Fatalf("bulk status = %d", status)
	}
	health, err := http.Get(ts.URL + "/health")
	if err != nil {
		t.Fatal(err)
	}
	defer health.Body.Close()
	var body map[string]string
	json.NewDecoder(health.Body).Decode(&body)
	if body["role"] != roleReplica {
		t.Fatalf("health = %v", body)
	}
}

func TestBackupsAreCachedBriefly(t *testing.T) {
	dir := t.TempDir()
	creates := 0
	now := time.Now()
	source := &BackupSource{
		Dir: dir,
		Now: func() time.Time { return now },
		Create: func(context.Context) error {
			creates++
			return os.WriteFile(filepath.Join(dir, "a.db"), []byte(sqliteHeader), 0o666)
		},
	}
	source.Latest(context.Background())
	source.Latest(context.Background())
	if creates != 1 {
		t.Fatalf("creates = %d", creates)
	}
	now = now.Add(backupCacheFor + time.Second)
	source.Latest(context.Background())
	if creates != 2 {
		t.Fatalf("creates after expiry = %d", creates)
	}
}
