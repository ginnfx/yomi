package main

import (
	"net/http"
	"testing"
	"time"
)

func TestLimiterLocksAfterRepeatedFailuresAndRecovers(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	l := newLoginLimiter()
	l.now = func() time.Time { return now }

	for i := 0; i < maxFailedLogins-1; i++ {
		l.Fail("Keli")
	}
	if l.Blocked("keli") {
		t.Fatal("must not lock before the limit")
	}
	l.Fail("KELI")
	if !l.Blocked("keli") {
		t.Fatal("must lock at the limit, case-insensitively")
	}
	now = now.Add(lockoutDuration + time.Second)
	if l.Blocked("keli") {
		t.Fatal("lock must expire")
	}
}

func TestLimiterForgetsOldFailuresAndResetsOnSuccess(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	l := newLoginLimiter()
	l.now = func() time.Time { return now }

	for i := 0; i < maxFailedLogins-1; i++ {
		l.Fail("a")
	}
	now = now.Add(failureWindow + time.Second)
	l.Fail("a")
	if l.Blocked("a") {
		t.Fatal("failures outside the window must not count")
	}

	for i := 0; i < maxFailedLogins-1; i++ {
		l.Fail("b")
	}
	l.Reset("b")
	l.Fail("b")
	if l.Blocked("b") {
		t.Fatal("reset must clear the counter")
	}
}

func TestUploadLocksOutAfterRepeatedWrongPasswords(t *testing.T) {
	ts, _ := newTestServer(t)

	for i := 0; i < maxFailedLogins; i++ {
		resp := postFile(t, ts.URL, "u=keli&p=wrong", "song.mp3", mp3Bytes)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("attempt %d: status = %d, want 401", i, resp.StatusCode)
		}
	}
	locked := postFile(t, ts.URL, "u=keli&p=good", "song.mp3", mp3Bytes)

	if locked.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 even with the right password while locked", locked.StatusCode)
	}
	other := postFile(t, ts.URL, "u=friend&p=good", "song.mp3", mp3Bytes)
	if other.StatusCode != http.StatusOK {
		t.Fatalf("other users must be unaffected, got %d", other.StatusCode)
	}
}
