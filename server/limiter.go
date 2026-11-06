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

	// maxLimiterEntries bounds memory, since user names come from the caller.
	maxLimiterEntries = 10000
)

type attempt struct {
	failures    int
	windowStart time.Time
	lockedUntil time.Time
}

// loginLimiter blocks a user name after repeated wrong passwords. It keys on the user name
// rather than the address because requests arriving through Tailscale all appear local.
type loginLimiter struct {
	mu        sync.Mutex
	now       func() time.Time
	entries   map[string]attempt
	lastPrune time.Time
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
	entry, known := l.entries[key]
	if !known {
		l.makeRoomLocked(now)
	}
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

// makeRoomLocked drops entries that no longer matter and, if the table is still full,
// evicts unlocked ones so a flood of made-up names can't grow it or lock out real users.
func (l *loginLimiter) makeRoomLocked(now time.Time) {
	if len(l.entries) < maxLimiterEntries && now.Sub(l.lastPrune) <= failureWindow {
		return
	}
	l.lastPrune = now
	for key, entry := range l.entries {
		if !now.Before(entry.lockedUntil) && now.Sub(entry.windowStart) > failureWindow {
			delete(l.entries, key)
		}
	}
	for key, entry := range l.entries {
		if len(l.entries) < maxLimiterEntries {
			return
		}
		if !now.Before(entry.lockedUntil) {
			delete(l.entries, key)
		}
	}
}
