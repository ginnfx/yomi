package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
	"time"
)

func TestLoadConfigUsesDefaultsAndOverrides(t *testing.T) {
	t.Setenv("YOMI_LISTEN", "")
	t.Setenv("YOMI_MAX_FILE_MB", "not-a-number")
	defaults := loadConfig()
	if defaults.Listen != defaultListen || defaults.MaxFileBytes != int64(defaultMaxFileMB)<<20 {
		t.Fatalf("unexpected defaults: %+v", defaults)
	}

	t.Setenv("YOMI_LISTEN", "127.0.0.1:9")
	t.Setenv("YOMI_MAX_FILE_MB", "5")
	t.Setenv("YOMI_MUSIC", "/tmp/music")
	got := loadConfig()
	if got.Listen != "127.0.0.1:9" || got.MaxFileBytes != 5<<20 || got.MusicDir != "/tmp/music" {
		t.Fatalf("overrides ignored: %+v", got)
	}
}

func TestUploadReportsBadGatewayWhenMusicServerIsDown(t *testing.T) {
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	srv := newServer(Config{MusicDir: t.TempDir(), MaxFileBytes: 1 << 10}, newNavidromeAuth(dead.URL), nil)
	ts := httptest.NewServer(srv.routes())
	defer ts.Close()

	resp := postFile(t, ts.URL, "u=keli&p=good", "song.mp3", mp3Bytes)

	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
}

func TestSuccessfulUploadTriggersRescan(t *testing.T) {
	var scans atomic.Int32
	done := make(chan struct{}, 1)
	srv := newServer(Config{MusicDir: t.TempDir(), MaxFileBytes: 1 << 10}, fakeAuth{},
		func(_ context.Context, q url.Values) {
			if q.Get("u") == "keli" {
				scans.Add(1)
			}
			done <- struct{}{}
		})
	ts := httptest.NewServer(srv.routes())
	defer ts.Close()

	postFile(t, ts.URL, "u=keli&p=good", "song.mp3", mp3Bytes)

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("rescan was not triggered")
	}
	if scans.Load() != 1 {
		t.Fatalf("scans = %d, want 1", scans.Load())
	}
}

func TestNavidromeScanCallsStartScanWithCredentials(t *testing.T) {
	got := make(chan url.Values, 1)
	nd := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/rest/startScan" {
			got <- r.URL.Query()
		}
	}))
	defer nd.Close()

	navidromeScan(nd.URL)(context.Background(), url.Values{"u": {"keli"}, "t": {"tok"}, "s": {"salt"}, "junk": {"x"}})

	q := <-got
	if q.Get("u") != "keli" || q.Get("t") != "tok" || q.Get("s") != "salt" || q.Get("junk") != "" {
		t.Fatalf("unexpected forwarded query: %v", q)
	}
}

func TestNavidromeScanToleratesUnreachableServer(t *testing.T) {
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	navidromeScan(dead.URL)(context.Background(), url.Values{"u": {"keli"}})
}

func TestAuthRejectsGarbageReplies(t *testing.T) {
	nd := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("<html>not json</html>"))
	}))
	defer nd.Close()

	_, err := newNavidromeAuth(nd.URL).Verify(context.Background(), url.Values{"u": {"a"}, "p": {"x"}})

	if err == nil || errors.Is(err, errUnauthorized) {
		t.Fatalf("want a backend error, got %v", err)
	}
}

func TestHealthEndpoint(t *testing.T) {
	ts, _ := newTestServer(t)
	resp, err := http.Get(ts.URL + "/health")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("health failed: %v %v", err, resp)
	}
	resp.Body.Close()
}
