package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

type fakeNavidrome struct {
	url     string
	isAdmin atomic.Bool
	isHung  atomic.Bool
	pings   atomic.Int32
}

func newFakeNavidrome(t *testing.T) *fakeNavidrome {
	t.Helper()
	fake := &fakeNavidrome{}
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/ping", func(w http.ResponseWriter, r *http.Request) {
		fake.pings.Add(1)
		if fake.isHung.Load() {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		w.Write([]byte(`{"subsonic-response":{"status":"ok"}}`))
	})
	mux.HandleFunc("/rest/getScanStatus", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"subsonic-response":{"status":"ok","scanStatus":{"scanning":true,"count":282}}}`))
	})
	mux.HandleFunc("/rest/getUser", func(w http.ResponseWriter, r *http.Request) {
		body, _ := json.Marshal(map[string]any{"subsonic-response": map[string]any{
			"status": "ok", "user": map[string]any{"adminRole": fake.isAdmin.Load()},
		}})
		w.Write(body)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	fake.url = server.URL
	return fake
}

func fakeProc(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"uptime":  "86400.50 100.00\n",
		"loadavg": "1.25 1.00 0.75 1/100 1234\n",
		"meminfo": "MemTotal:       1000 kB\nMemFree:         100 kB\nBuffers:          50 kB\nCached:          150 kB\n",
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o666); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func newTestReader(t *testing.T, navidrome string) *StatusReader {
	t.Helper()
	music := t.TempDir()
	return &StatusReader{
		ProcRoot:       fakeProc(t),
		PowerFile:      filepath.Join(t.TempDir(), "missing"),
		BatteryFile:    filepath.Join(t.TempDir(), "missing.json"),
		MusicDir:       music,
		InternalDir:    music,
		NavidromeURL:   navidrome,
		Client:         &http.Client{Timeout: time.Second},
		TailscaleState: func(context.Context) (string, error) { return "Running", nil },
		Now:            time.Now,
	}
}

func TestStatusReadsSystemFacts(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	status := newTestReader(t, navidrome.url).Read(context.Background(), url.Values{})

	if *status.Uptime != 86400 || *status.Load != 1.25 {
		t.Fatalf("uptime = %v, load = %v", *status.Uptime, *status.Load)
	}
	if status.Memory.Total != 1000*kilobyte || status.Memory.Free != 300*kilobyte {
		t.Fatalf("memory = %+v", status.Memory)
	}
	if status.Card == nil || status.Card.Total == 0 {
		t.Fatalf("card = %+v", status.Card)
	}
	if !status.Navidrome.IsHealthy || !status.Navidrome.IsScanning || *status.Navidrome.SongCount != 282 {
		t.Fatalf("navidrome = %+v", status.Navidrome)
	}
	if *status.Tailscale != "Running" {
		t.Fatalf("tailscale = %v", *status.Tailscale)
	}
}

func TestHungNavidromeShowsUnhealthy(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	navidrome.isHung.Store(true)
	status := newTestReader(t, navidrome.url).Read(context.Background(), url.Values{})
	if status.Navidrome.IsHealthy {
		t.Fatal("a failing Navidrome reported healthy")
	}
}

func TestStoppedNavidromeShowsUnhealthy(t *testing.T) {
	dead := httptest.NewServer(http.NotFoundHandler())
	address := dead.URL
	dead.Close()
	status := newTestReader(t, address).Read(context.Background(), url.Values{})
	if status.Navidrome.IsHealthy {
		t.Fatal("a stopped Navidrome reported healthy")
	}
}

func TestUnknownValuesStayNull(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	reader := newTestReader(t, navidrome.url)
	reader.ProcRoot = filepath.Join(t.TempDir(), "missing")
	reader.TailscaleState = func(context.Context) (string, error) { return "", errors.New("no socket") }

	status := reader.Read(context.Background(), url.Values{})

	if status.Uptime != nil || status.Memory != nil || status.Battery != nil || status.Tailscale != nil {
		t.Fatalf("status = %+v", status)
	}
}

func TestBatteryPrefersKeeperReport(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	reader := newTestReader(t, navidrome.url)
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	reader.Now = func() time.Time { return now }
	report, _ := json.Marshal(map[string]any{
		"level": 80, "charging": true, "health": "good", "temperatureC": 31.5, "updatedMs": now.UnixMilli(),
	})
	os.WriteFile(reader.BatteryFile, report, 0o666)

	battery := reader.readBattery()

	if battery.Level != 80 || !*battery.IsCharging || battery.Health != "good" || *battery.Temperature != 31.5 || battery.IsStale {
		t.Fatalf("battery = %+v", battery)
	}

	now = now.Add(batteryStaleAfter + time.Minute)
	if !reader.readBattery().IsStale {
		t.Fatal("an old report should be marked stale")
	}
}

func TestBatteryFallsBackToKernelPercentage(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	reader := newTestReader(t, navidrome.url)
	os.WriteFile(reader.PowerFile, []byte("94\n"), 0o666)
	battery := reader.readBattery()
	if battery.Level != 94 || battery.IsCharging != nil {
		t.Fatalf("battery = %+v", battery)
	}
}

func TestStatusIsCachedBriefly(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	reader := newTestReader(t, navidrome.url)
	now := time.Now()
	reader.Now = func() time.Time { return now }

	reader.Read(context.Background(), url.Values{})
	reader.Read(context.Background(), url.Values{})
	if navidrome.pings.Load() != 1 {
		t.Fatalf("pings = %d", navidrome.pings.Load())
	}
	now = now.Add(statusCacheFor + time.Second)
	reader.Read(context.Background(), url.Values{})
	if navidrome.pings.Load() != 2 {
		t.Fatalf("pings after expiry = %d", navidrome.pings.Load())
	}
}

func statusFromServer(t *testing.T, navidrome *fakeNavidrome, query string) (int, ServerStatus) {
	t.Helper()
	dir := t.TempDir()
	server := newServer(Config{MusicDir: dir, NavidromeURL: navidrome.url, MaxFileBytes: 1 << 10}, fakeAuth{}, nil, nil)
	server.Status = newTestReader(t, navidrome.url)
	ts := httptest.NewServer(server.routes())
	t.Cleanup(ts.Close)
	response, err := http.Get(ts.URL + "/v1/status?" + query)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var status ServerStatus
	json.NewDecoder(response.Body).Decode(&status)
	return response.StatusCode, status
}

func TestAdminsGetDetails(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	navidrome.isAdmin.Store(true)
	code, status := statusFromServer(t, navidrome, "u=keli&p=good")
	if code != http.StatusOK || !status.Detailed || status.Memory == nil {
		t.Fatalf("code = %d, status = %+v", code, status)
	}
}

func TestOtherUsersOnlySeeOnline(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	code, status := statusFromServer(t, navidrome, "u=friend&p=good")
	if code != http.StatusOK || !status.Online || status.Detailed || status.Memory != nil || status.Battery != nil {
		t.Fatalf("code = %d, status = %+v", code, status)
	}
}

func TestStatusRequiresLogin(t *testing.T) {
	navidrome := newFakeNavidrome(t)
	code, _ := statusFromServer(t, navidrome, "u=keli&p=wrong")
	if code != http.StatusUnauthorized {
		t.Fatalf("code = %d", code)
	}
}
