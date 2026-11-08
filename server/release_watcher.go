package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	releaseCheckEvery = 3 * time.Hour
	releaseAPIHost    = "https://api.github.com"
	releaseBodyLimit  = 1 << 20
	releaseBodyChars  = 120
)

var releaseTagPattern = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)$`)

// ReleaseWatcher notices a newer GitHub release than the last one it announced. The
// first run only records the current release, so deploying it never wakes every phone.
type ReleaseWatcher struct {
	Repo      string // "owner/name"
	StateFile string // remembers the newest version already announced
	APIURL    string // replaces GitHub's address, for tests
	Client    *http.Client

	// Announce tells people. Returning an error leaves the version unannounced, so the
	// next check tries again.
	Announce func(ctx context.Context, version, notes string) error
}

type releaseVersion [3]int

func parseReleaseTag(tag string) (releaseVersion, bool) {
	match := releaseTagPattern.FindStringSubmatch(strings.TrimSpace(tag))
	if match == nil {
		return releaseVersion{}, false
	}
	var v releaseVersion
	for i := range v {
		n, err := strconv.Atoi(match[i+1])
		if err != nil {
			return releaseVersion{}, false
		}
		v[i] = n
	}
	return v, true
}

func (v releaseVersion) newerThan(o releaseVersion) bool {
	for i := range v {
		if v[i] != o[i] {
			return v[i] > o[i]
		}
	}
	return false
}

func (v releaseVersion) String() string { return fmt.Sprintf("%d.%d.%d", v[0], v[1], v[2]) }

// Check looks at the latest release once and announces it if it is new.
func (w *ReleaseWatcher) Check(ctx context.Context) error {
	tag, notes, err := w.latest(ctx)
	if err != nil {
		return err
	}
	latest, ok := parseReleaseTag(tag)
	if !ok {
		return nil
	}
	seen, hasSeen := w.readState()
	if !hasSeen {
		return w.writeState(latest)
	}
	if !latest.newerThan(seen) {
		return nil
	}
	if err := w.Announce(ctx, latest.String(), notes); err != nil {
		return err
	}
	return w.writeState(latest)
}

func (w *ReleaseWatcher) latest(ctx context.Context) (tag, notes string, err error) {
	host := w.APIURL
	if host == "" {
		host = releaseAPIHost
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, host+"/repos/"+w.Repo+"/releases/latest", nil)
	if err != nil {
		return "", "", err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	response, err := w.Client.Do(request)
	if err != nil {
		return "", "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("github answered %d", response.StatusCode)
	}
	var release struct {
		Tag  string `json:"tag_name"`
		Body string `json:"body"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, releaseBodyLimit)).Decode(&release); err != nil {
		return "", "", err
	}
	return release.Tag, release.Body, nil
}

func (w *ReleaseWatcher) readState() (releaseVersion, bool) {
	raw, err := os.ReadFile(w.StateFile)
	if err != nil {
		return releaseVersion{}, false
	}
	return parseReleaseTag(string(raw))
}

func (w *ReleaseWatcher) writeState(v releaseVersion) error {
	if err := os.MkdirAll(filepath.Dir(w.StateFile), 0o755); err != nil {
		return err
	}
	temp := w.StateFile + ".tmp"
	if err := os.WriteFile(temp, []byte(v.String()), 0o600); err != nil {
		return err
	}
	return os.Rename(temp, w.StateFile)
}

// Run checks now and then on a timer until ctx ends.
func (w *ReleaseWatcher) Run(ctx context.Context) {
	ticker := time.NewTicker(releaseCheckEvery)
	defer ticker.Stop()
	for {
		if err := w.Check(ctx); err != nil {
			log.Printf("release watcher: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// alertPusher sends one alert to a user's tokens and reports the dead ones.
type alertPusher interface {
	push(ctx context.Context, tokens []string, alert Alert) ([]string, error)
}

// announceRelease pushes "a new version is out" to every registered device, one send per
// person, and reports the tokens the push services say are gone.
func announceRelease(ctx context.Context, version, notes string, devices map[string][]string, pusher alertPusher, forget func(user string, dead []string)) error {
	alert := Alert{
		Title:  "Yomi " + version + " is available",
		Body:   releaseSummary(notes),
		Thread: "update",
		Data:   map[string]string{"update": version},
	}
	var firstErr error
	sent := 0
	for user, tokens := range devices {
		if len(tokens) == 0 {
			continue
		}
		dead, err := pusher.push(ctx, tokens, alert)
		if err != nil && firstErr == nil {
			firstErr = err
		}
		if err == nil {
			sent++
		}
		if len(dead) > 0 {
			forget(user, dead)
		}
	}
	if sent == 0 && firstErr != nil {
		return firstErr
	}
	return nil
}

// releaseSummary is the first meaningful line of the release notes.
func releaseSummary(notes string) string {
	for _, line := range strings.Split(notes, "\n") {
		line = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(line), "#-* \t"))
		if line == "" {
			continue
		}
		runes := []rune(line)
		if len(runes) > releaseBodyChars {
			return string(runes[:releaseBodyChars-1]) + "…"
		}
		return line
	}
	return "Open Yomi to update."
}

// serverPusher sends through Apple for iPhones and Google for everything else.
type serverPusher struct{ server *Server }

func (p serverPusher) push(ctx context.Context, stored []string, alert Alert) ([]string, error) {
	var apple, other []string
	for _, entry := range stored {
		if kind, _ := splitToken(entry); kind == tokenKindAPNs || kind == tokenKindAPNsSandbox {
			apple = append(apple, entry)
		} else {
			other = append(other, entry)
		}
	}
	var dead []string
	var firstErr error
	if len(apple) > 0 && p.server.APNs != nil {
		gone, err := p.server.APNs.NotifyAlert(ctx, apple, alert)
		dead = append(dead, gone...)
		firstErr = err
	}
	if len(other) > 0 && p.server.FCM != nil {
		raw := make([]string, len(other))
		for i, entry := range other {
			_, raw[i] = splitToken(entry)
		}
		gone, err := p.server.FCM.NotifyAlert(ctx, raw, alert)
		dead = append(dead, gone...)
		if firstErr == nil {
			firstErr = err
		}
	}
	return dead, firstErr
}

// startReleaseWatcher runs on one server only (the one with YOMI_RELEASE_REPO set), or
// everyone would get the same alert once per server.
func startReleaseWatcher(cfg Config, server *Server) {
	if cfg.ReleaseRepo == "" {
		return
	}
	if server.Messages == nil || (server.APNs == nil && server.FCM == nil) {
		log.Printf("release alerts off: this server has no Apple or Firebase push set up")
		return
	}
	client, err := newInternetClient()
	if err != nil {
		log.Printf("release alerts off: %v", err)
		return
	}
	state := cfg.ReleaseState
	if state == "" {
		state = filepath.Join(filepath.Dir(cfg.IndexFile), "release-announced")
	}
	watcher := &ReleaseWatcher{
		Repo:      cfg.ReleaseRepo,
		StateFile: state,
		Client:    client,
		Announce: func(ctx context.Context, version, notes string) error {
			return announceRelease(ctx, version, notes, server.Messages.AllDevices(), serverPusher{server}, func(user string, dead []string) {
				if err := server.Messages.RemoveDevices(user, dead); err != nil {
					log.Printf("release alerts: forgetting dead devices: %v", err)
				}
			})
		},
	}
	log.Printf("release alerts: watching %s", cfg.ReleaseRepo)
	go watcher.Run(context.Background())
}
