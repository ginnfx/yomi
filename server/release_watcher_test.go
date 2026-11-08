package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type announcement struct{ version, notes string }

func newWatcherFixture(t *testing.T, tag, body string) (*ReleaseWatcher, *[]announcement, *string) {
	t.Helper()
	latest := tag
	notes := body
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/owner/app/releases/latest" {
			t.Errorf("path = %s", r.URL.Path)
		}
		w.Write([]byte(`{"tag_name":"` + latest + `","body":"` + notes + `"}`))
	}))
	t.Cleanup(api.Close)
	var got []announcement
	watcher := &ReleaseWatcher{
		Repo:      "owner/app",
		StateFile: filepath.Join(t.TempDir(), "state"),
		APIURL:    api.URL,
		Client:    api.Client(),
		Announce: func(_ context.Context, version, notes string) error {
			got = append(got, announcement{version, notes})
			return nil
		},
	}
	return watcher, &got, &latest
}

func TestReleaseWatcherStaysQuietOnFirstRun(t *testing.T) {
	watcher, got, _ := newWatcherFixture(t, "v1.1.6", "notes")

	if err := watcher.Check(context.Background()); err != nil {
		t.Fatal(err)
	}

	if len(*got) != 0 {
		t.Fatalf("announced %v on first run", *got)
	}
	saved, _ := os.ReadFile(watcher.StateFile)
	if string(saved) != "1.1.6" {
		t.Fatalf("state = %q", saved)
	}
}

func TestReleaseWatcherAnnouncesANewerVersionOnce(t *testing.T) {
	watcher, got, latest := newWatcherFixture(t, "v1.1.6", "")
	watcher.Check(context.Background())
	*latest = "v1.1.7"

	watcher.Check(context.Background())
	watcher.Check(context.Background())

	if len(*got) != 1 || (*got)[0].version != "1.1.7" {
		t.Fatalf("announcements = %v", *got)
	}
}

func TestReleaseWatcherIgnoresOlderAndSameVersions(t *testing.T) {
	watcher, got, latest := newWatcherFixture(t, "v1.1.6", "")
	watcher.Check(context.Background())

	*latest = "v1.1.6"
	watcher.Check(context.Background())
	*latest = "v1.0.9"
	watcher.Check(context.Background())

	if len(*got) != 0 {
		t.Fatalf("announced %v", *got)
	}
}

func TestReleaseWatcherComparesNumbersNotText(t *testing.T) {
	watcher, got, latest := newWatcherFixture(t, "v1.1.9", "")
	watcher.Check(context.Background())
	*latest = "v1.1.10"

	watcher.Check(context.Background())

	if len(*got) != 1 {
		t.Fatalf("1.1.10 should be newer than 1.1.9, got %v", *got)
	}
}

func TestReleaseWatcherRetriesWhenAnnouncingFails(t *testing.T) {
	watcher, got, latest := newWatcherFixture(t, "v1.1.6", "")
	watcher.Check(context.Background())
	*latest = "v1.1.7"
	fail := true
	watcher.Announce = func(_ context.Context, version, notes string) error {
		if fail {
			return errors.New("push is down")
		}
		*got = append(*got, announcement{version, notes})
		return nil
	}

	if err := watcher.Check(context.Background()); err == nil {
		t.Fatal("expected the failure to be reported")
	}
	fail = false
	watcher.Check(context.Background())

	if len(*got) != 1 {
		t.Fatalf("announcements = %v", *got)
	}
}

func TestReleaseWatcherIgnoresUnparsableTags(t *testing.T) {
	watcher, got, latest := newWatcherFixture(t, "v1.1.6", "")
	watcher.Check(context.Background())
	*latest = "nightly"

	if err := watcher.Check(context.Background()); err != nil {
		t.Fatal(err)
	}

	if len(*got) != 0 {
		t.Fatalf("announced %v", *got)
	}
}

func TestReleaseWatcherReportsAnUnreachableAPI(t *testing.T) {
	watcher, _, _ := newWatcherFixture(t, "v1.1.6", "")
	watcher.APIURL = "http://127.0.0.1:1"
	watcher.Client = &http.Client{Timeout: time.Second}

	if err := watcher.Check(context.Background()); err == nil {
		t.Fatal("expected an error")
	}
}

func TestAnnounceReleaseSendsToEveryDeviceAndForgetsDeadOnes(t *testing.T) {
	alerts := &recordingPusher{dead: []string{"gone"}}
	devices := map[string][]string{"ana": {"a1", "gone"}, "bo": {"b1"}}
	forgotten := map[string][]string{}

	err := announceRelease(context.Background(), "1.1.7", "## Faster downloads", devices, alerts, func(user string, dead []string) {
		forgotten[user] = dead
	})

	if err != nil {
		t.Fatal(err)
	}
	if alerts.title != "Yomi 1.1.7 is available" || alerts.body != "Faster downloads" {
		t.Fatalf("alert = %q / %q", alerts.title, alerts.body)
	}
	if alerts.data["update"] != "1.1.7" {
		t.Fatalf("data = %v", alerts.data)
	}
	if alerts.calls != 2 {
		t.Fatalf("expected one send per user, got %d", alerts.calls)
	}
	if len(forgotten["ana"]) != 1 || forgotten["ana"][0] != "gone" {
		t.Fatalf("forgotten = %v", forgotten)
	}
}

type recordingPusher struct {
	dead        []string
	title, body string
	data        map[string]string
	calls       int
}

func (r *recordingPusher) push(_ context.Context, tokens []string, alert Alert) ([]string, error) {
	r.calls++
	r.title, r.body, r.data = alert.Title, alert.Body, alert.Data
	var gone []string
	for _, token := range tokens {
		for _, d := range r.dead {
			if token == d {
				gone = append(gone, token)
			}
		}
	}
	return gone, nil
}
