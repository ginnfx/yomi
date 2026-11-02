package main

import (
	"strings"
	"sync"
	"time"
)

const (
	maxFailedLogins = 5
	failureWindow   = 10 * time.Minute
	lockoutDuration = 5 * time.Minute
)

type attempt struct {
	failures    int
	windowStart time.Time
	lockedUntil time.Time
}

// loginLimiter blocks a user name after repeated wrong passwords. It keys on the user name
// rather than the address because requests arriving through Tailscale all appear local.
type loginLimiter struct {
	mu      sync.Mutex
	now     func() time.Time
	entries map[string]attempt
}

func newLoginLimiter() *loginLimiter {
	return &loginLimiter{now: time.Now, entries: make(map[string]attempt)}
}

func limiterKey(user string) string { return strings.ToLower(strings.TrimSpace(user)) }

// Blocked reports whether the user is currently locked out.
func (l *loginLimiter) Blocked(user string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.now().Before(l.entries[limiterKey(user)].lockedUntil)
}

// Fail records a wrong password and locks the user once the limit is reached.
func (l *loginLimiter) Fail(user string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	key, now := limiterKey(user), l.now()
	entry := l.entries[key]
	if now.Sub(entry.windowStart) > failureWindow {
		entry = attempt{windowStart: now}
	}
	entry.failures++
	if entry.failures >= maxFailedLogins {
		entry.lockedUntil = now.Add(lockoutDuration)
		entry.failures = 0
		entry.windowStart = now
	}
	l.entries[key] = entry
}

// Reset clears the user's failures after a successful login.
func (l *loginLimiter) Reset(user string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, limiterKey(user))
}
