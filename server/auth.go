package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sync"
	"time"
)

const (
	authCacheFor     = time.Minute
	authCacheEntries = 64
)

// redactURL removes the URL from a request error. Go puts the whole URL in the message,
// and Subsonic logins travel in the query string, so logging it would log passwords.
func redactURL(err error) error {
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return fmt.Errorf("%s request failed: %w", urlErr.Op, urlErr.Err)
	}
	return err
}

var errUnauthorized = errors.New("invalid username or password")

// Authenticator checks Subsonic-style credentials (u + t/s token, or u + p).
type Authenticator interface {
	Verify(ctx context.Context, query url.Values) (string, error)
}

// NavidromeAuth delegates credential checks to Navidrome's own /rest/ping, so
// Yomi never sees or stores a password and uses the same accounts as playback.
type NavidromeAuth struct {
	BaseURL string
	Client  *http.Client
}

func newNavidromeAuth(baseURL string) NavidromeAuth {
	return NavidromeAuth{BaseURL: baseURL, Client: &http.Client{Timeout: 10 * time.Second}}
}

func (a NavidromeAuth) Verify(ctx context.Context, query url.Values) (string, error) {
	user := query.Get("u")
	hasToken := query.Get("t") != "" && query.Get("s") != ""
	if user == "" || (!hasToken && query.Get("p") == "") {
		return "", errUnauthorized
	}
	forwarded := url.Values{"v": {"1.16.1"}, "c": {"yomi-upload"}, "f": {"json"}}
	for _, key := range []string{"u", "t", "s", "p"} {
		if value := query.Get(key); value != "" {
			forwarded.Set(key, value)
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.BaseURL+"/rest/ping?"+forwarded.Encode(), nil)
	if err != nil {
		return "", err
	}
	resp, err := a.Client.Do(req)
	if err != nil {
		return "", fmt.Errorf("navidrome unreachable: %w", redactURL(err))
	}
	defer resp.Body.Close()
	var body struct {
		Response struct {
			Status string `json:"status"`
		} `json:"subsonic-response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", fmt.Errorf("unexpected navidrome reply: %w", err)
	}
	if body.Response.Status != "ok" {
		return "", errUnauthorized
	}
	return user, nil
}

// cachedAuth remembers successful logins briefly, so a bulk upload doesn't ping
// Navidrome for every file. Failures are never cached, and keys are hashed so
// credentials aren't kept in memory longer than the request.
type cachedAuth struct {
	inner Authenticator
	now   func() time.Time
	mu    sync.Mutex
	valid map[[sha256.Size]byte]cachedLogin
}

type cachedLogin struct {
	user    string
	expires time.Time
}

func newCachedAuth(inner Authenticator) *cachedAuth {
	return &cachedAuth{inner: inner, now: time.Now, valid: make(map[[sha256.Size]byte]cachedLogin)}
}

func authCacheKey(query url.Values) [sha256.Size]byte {
	return sha256.Sum256([]byte(query.Get("u") + "\x00" + query.Get("t") + "\x00" + query.Get("s") + "\x00" + query.Get("p")))
}

// RecentlyVerified reports a login that passed moments ago. These skip the lockout, so
// someone guessing a friend's password can't lock that friend out while they're listening.
func (a *cachedAuth) RecentlyVerified(query url.Values) (string, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	login, ok := a.valid[authCacheKey(query)]
	if !ok || !a.now().Before(login.expires) {
		return "", false
	}
	return login.user, true
}

func (a *cachedAuth) Verify(ctx context.Context, query url.Values) (string, error) {
	if user, ok := a.RecentlyVerified(query); ok {
		return user, nil
	}
	key := authCacheKey(query)
	user, err := a.inner.Verify(ctx, query)
	if err != nil {
		return "", err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.valid) >= authCacheEntries {
		a.valid = make(map[[sha256.Size]byte]cachedLogin)
	}
	a.valid[key] = cachedLogin{user: user, expires: a.now().Add(authCacheFor)}
	return user, nil
}
