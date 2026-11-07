package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFCMSignsAssertionsGoogleCanVerify(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	sender := &FCMSender{ProjectID: "p", ClientEmail: "bot@p.iam", Key: key, TokenURL: "https://token", Now: time.Now}

	assertion, err := sender.signedAssertion()
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.Split(assertion, ".")
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], sig); err != nil {
		t.Fatalf("signature does not verify: %v", err)
	}
	var claims map[string]any
	raw, _ := base64.RawURLEncoding.DecodeString(parts[1])
	json.Unmarshal(raw, &claims)
	if claims["iss"] != "bot@p.iam" || claims["scope"] != fcmScope || claims["aud"] != "https://token" {
		t.Fatalf("claims = %v", claims)
	}
}

func TestFCMNotifyReusesTokenAndReportsDeadDevices(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	tokenCalls := 0
	oauth := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tokenCalls++
		w.Write([]byte(`{"access_token":"at","expires_in":3600}`))
	}))
	defer oauth.Close()
	var sent []string
	send := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer at" {
			t.Errorf("authorization = %q", r.Header.Get("Authorization"))
		}
		var body struct {
			Message struct {
				Token string `json:"token"`
			} `json:"message"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		sent = append(sent, body.Message.Token)
		if body.Message.Token == "old" {
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"error":{"status":"UNREGISTERED"}}`))
		}
	}))
	defer send.Close()
	sender := &FCMSender{ProjectID: "p", ClientEmail: "bot", Key: key, TokenURL: oauth.URL, SendURL: send.URL, Client: http.DefaultClient, Now: time.Now}

	dead, err := sender.Notify(context.Background(), []string{"new", "old"}, "sam")
	sender.Notify(context.Background(), []string{"new"}, "sam")

	if len(sent) != 3 || tokenCalls != 1 {
		t.Fatalf("sent=%v tokenCalls=%d", sent, tokenCalls)
	}
	if len(dead) != 1 || dead[0] != "old" || err == nil {
		t.Fatalf("dead=%v err=%v", dead, err)
	}
}
