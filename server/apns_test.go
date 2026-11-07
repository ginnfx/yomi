package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testSender(t *testing.T, host string) *APNsSender {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &APNsSender{
		Key: key, KeyID: "KEY123", TeamID: "TEAM456", Topic: "com.example.yomi",
		Client: http.DefaultClient, Now: time.Now,
		ProductionHost: host, SandboxHost: host,
	}
}

func TestSplitTokenKinds(t *testing.T) {
	cases := map[string][2]string{
		"apns:abc":         {"apns", "abc"},
		"apns-sandbox:abc": {"apns-sandbox", "abc"},
		"fcm:abc":          {"fcm", "abc"},
		"legacytoken":      {"fcm", "legacytoken"},
	}
	for stored, want := range cases {
		kind, token := splitToken(stored)
		if kind != want[0] || token != want[1] {
			t.Errorf("splitToken(%q) = %q, %q; want %v", stored, kind, token, want)
		}
	}
}

func TestAPNsBearerIsAValidES256Token(t *testing.T) {
	sender := testSender(t, "")
	token, err := sender.bearer()
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token has %d parts", len(parts))
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		t.Fatalf("signature: %v, %d bytes", err, len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&sender.Key.PublicKey, digest[:], r, s) {
		t.Fatal("signature does not verify")
	}
	var header map[string]string
	raw, _ := base64.RawURLEncoding.DecodeString(parts[0])
	json.Unmarshal(raw, &header)
	if header["alg"] != "ES256" || header["kid"] != "KEY123" {
		t.Fatalf("header = %v", header)
	}
	again, _ := sender.bearer()
	if again != token {
		t.Fatal("a fresh token was made within its lifetime")
	}
}

func TestAPNsNotifySendsAndReportsDeadTokens(t *testing.T) {
	var seen []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.URL.Path)
		if r.Header.Get("apns-topic") != "com.example.yomi" || !strings.HasPrefix(r.Header.Get("authorization"), "bearer ") {
			t.Errorf("missing headers: %v", r.Header)
		}
		if strings.HasSuffix(r.URL.Path, "/gone") {
			w.WriteHeader(http.StatusGone)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	sender := testSender(t, server.URL)

	dead, err := sender.Notify(context.Background(), []string{"apns:good", "apns-sandbox:gone", "fcm:ignored"}, "sam")

	if len(seen) != 2 {
		t.Fatalf("requests = %v", seen)
	}
	if len(dead) != 1 || dead[0] != "apns-sandbox:gone" {
		t.Fatalf("dead = %v", dead)
	}
	if err == nil {
		t.Fatal("expected the gone token to be reported as an error")
	}
}
