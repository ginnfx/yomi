package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Device tokens are stored as "kind:token". Anything without a known kind is an FCM
// token from before kinds existed, and goes through the relay.
const (
	tokenKindAPNs        = "apns"
	tokenKindAPNsSandbox = "apns-sandbox"

	apnsHost        = "https://api.push.apple.com"
	apnsSandboxHost = "https://api.sandbox.push.apple.com"

	// Apple wants the signing token refreshed between 20 and 60 minutes.
	apnsTokenLife = 45 * time.Minute
)

// splitToken returns the kind and raw token of a stored device token.
func splitToken(stored string) (kind, token string) {
	for _, known := range []string{tokenKindAPNsSandbox, tokenKindAPNs} {
		if rest, ok := strings.CutPrefix(stored, known+":"); ok {
			return known, rest
		}
	}
	return "fcm", strings.TrimPrefix(stored, "fcm:")
}

// APNsSender pushes to iPhones straight from this server, with no Firebase in between.
// Only "new message" and the sender's name leave the server, never the text.
type APNsSender struct {
	Key    *ecdsa.PrivateKey
	KeyID  string
	TeamID string
	Topic  string // the app's bundle id
	Client *http.Client
	Now    func() time.Time

	// Hosts replace Apple's addresses, for tests.
	ProductionHost, SandboxHost string

	mu        sync.Mutex
	jwt       string
	jwtMadeAt time.Time
}

// loadAPNsKey reads the .p8 file Apple gives out (a PKCS#8 EC private key).
func loadAPNsKey(path string) (*ecdsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("not a PEM file")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("not an EC key")
	}
	return key, nil
}

// newAPNsClient needs HTTP/2, which Apple requires, so unlike newInternetClient it
// asks for it explicitly (a custom dialer switches it off otherwise).
func newAPNsClient() (*http.Client, error) {
	roots, err := embeddedRoots()
	if err != nil {
		return nil, err
	}
	dialer := &net.Dialer{Timeout: dnsTimeout, Resolver: publicResolver()}
	transport := &http.Transport{
		DialContext:         dialer.DialContext,
		ForceAttemptHTTP2:   true,
		TLSClientConfig:     &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 15 * time.Second,
		IdleConnTimeout:     60 * time.Second,
		MaxIdleConns:        2,
	}
	return &http.Client{Transport: transport, Timeout: internetTimeout}, nil
}

func newAPNsSender(cfg Config) *APNsSender {
	if cfg.APNsKeyFile == "" {
		return nil
	}
	if cfg.APNsKeyID == "" || cfg.APNsTeamID == "" || cfg.APNsTopic == "" {
		log.Printf("apns disabled: set YOMI_APNS_KEY_ID, YOMI_APNS_TEAM_ID and YOMI_APNS_TOPIC")
		return nil
	}
	key, err := loadAPNsKey(cfg.APNsKeyFile)
	if err != nil {
		log.Printf("apns disabled: %v", err)
		return nil
	}
	client, err := newAPNsClient()
	if err != nil {
		log.Printf("apns disabled: %v", err)
		return nil
	}
	log.Printf("apns: pushing to %s as team %s", cfg.APNsTopic, cfg.APNsTeamID)
	return &APNsSender{Key: key, KeyID: cfg.APNsKeyID, TeamID: cfg.APNsTeamID, Topic: cfg.APNsTopic, Client: client, Now: time.Now}
}

// bearer returns the signed token Apple expects, made fresh every 45 minutes.
func (a *APNsSender) bearer() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.Now()
	if a.jwt != "" && now.Sub(a.jwtMadeAt) < apnsTokenLife {
		return a.jwt, nil
	}
	enc := base64.RawURLEncoding
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": a.TeamID, "iat": now.Unix()})
	signing := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.Key, digest[:])
	if err != nil {
		return "", err
	}
	// ES256 wants r and s as two fixed 32-byte numbers side by side.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	a.jwt = signing + "." + enc.EncodeToString(sig)
	a.jwtMadeAt = now
	return a.jwt, nil
}

// Notify sends to stored tokens of the apns kinds and returns the stored tokens Apple
// says are gone for good.
func (a *APNsSender) Notify(ctx context.Context, stored []string, from string) ([]string, error) {
	bearer, err := a.bearer()
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(map[string]any{
		"aps": map[string]any{
			"alert":     map[string]string{"title": from, "body": "New message"},
			"sound":     "default",
			"thread-id": from,
		},
		"from": from,
	})
	if err != nil {
		return nil, err
	}
	var dead []string
	var firstErr error
	for _, entry := range stored {
		kind, token := splitToken(entry)
		var host string
		switch kind {
		case tokenKindAPNsSandbox:
			host = firstNonEmpty(a.SandboxHost, apnsSandboxHost)
		case tokenKindAPNs:
			host = firstNonEmpty(a.ProductionHost, apnsHost)
		default:
			continue
		}
		isDead, err := a.send(ctx, host, token, bearer, payload)
		if isDead {
			dead = append(dead, entry)
		}
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return dead, firstErr
}

func (a *APNsSender) send(ctx context.Context, host, token, bearer string, payload []byte) (bool, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+token, bytes.NewReader(payload))
	if err != nil {
		return false, err
	}
	request.Header.Set("authorization", "bearer "+bearer)
	request.Header.Set("apns-topic", a.Topic)
	request.Header.Set("apns-push-type", "alert")
	request.Header.Set("apns-priority", "10")
	response, err := a.Client.Do(request)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusOK {
		return false, nil
	}
	body, _ := io.ReadAll(io.LimitReader(response.Body, 1024))
	var reason struct {
		Reason string `json:"reason"`
	}
	json.Unmarshal(body, &reason)
	// 410 means unregistered; these two reasons mean the token can never work.
	isDead := response.StatusCode == http.StatusGone ||
		reason.Reason == "BadDeviceToken" || reason.Reason == "DeviceTokenNotForTopic"
	return isDead, fmt.Errorf("apns answered %d %s", response.StatusCode, reason.Reason)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
