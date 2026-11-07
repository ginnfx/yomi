package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	fcmScope       = "https://www.googleapis.com/auth/firebase.messaging"
	fcmSendFormat  = "https://fcm.googleapis.com/v1/projects/%s/messages:send"
	fcmTokenMargin = 5 * time.Minute
)

// FCMSender pushes to Android phones straight from this server using a Firebase
// service account, so no relay needs hosting. Only "New message" and the sender's
// name leave the server, never the text.
type FCMSender struct {
	ProjectID   string
	ClientEmail string
	Key         *rsa.PrivateKey
	TokenURL    string
	Client      *http.Client
	Now         func() time.Time

	// SendURL replaces Google's address, for tests.
	SendURL string

	mu          sync.Mutex
	accessToken string
	expiresAt   time.Time
}

type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

func loadServiceAccount(path string) (*FCMSender, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var account serviceAccount
	if err := json.Unmarshal(raw, &account); err != nil {
		return nil, err
	}
	if account.ProjectID == "" || account.ClientEmail == "" || account.PrivateKey == "" {
		return nil, errors.New("service account file is missing project_id, client_email or private_key")
	}
	block, _ := pem.Decode([]byte(account.PrivateKey))
	if block == nil {
		return nil, errors.New("service account key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("service account key is not RSA")
	}
	tokenURL := account.TokenURI
	if tokenURL == "" {
		tokenURL = "https://oauth2.googleapis.com/token"
	}
	return &FCMSender{ProjectID: account.ProjectID, ClientEmail: account.ClientEmail, Key: key, TokenURL: tokenURL, Now: time.Now}, nil
}

func newFCMSender(cfg Config) *FCMSender {
	if cfg.FCMServiceAccount == "" {
		return nil
	}
	sender, err := loadServiceAccount(cfg.FCMServiceAccount)
	if err != nil {
		log.Printf("fcm disabled: %v", err)
		return nil
	}
	client, err := newInternetClient()
	if err != nil {
		log.Printf("fcm disabled: %v", err)
		return nil
	}
	sender.Client = client
	log.Printf("fcm: pushing through project %s", sender.ProjectID)
	return sender
}

func (f *FCMSender) signedAssertion() (string, error) {
	enc := base64.RawURLEncoding
	now := f.Now()
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{
		"iss": f.ClientEmail, "scope": fcmScope, "aud": f.TokenURL,
		"iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	})
	signing := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.Key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	return signing + "." + enc.EncodeToString(sig), nil
}

// token returns a Google access token, asking for a new one shortly before it runs out.
func (f *FCMSender) token(ctx context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.accessToken != "" && f.Now().Add(fcmTokenMargin).Before(f.expiresAt) {
		return f.accessToken, nil
	}
	assertion, err := f.signedAssertion()
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, f.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := f.Client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 1<<16))
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("google token answered %d", response.StatusCode)
	}
	var reply struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &reply); err != nil || reply.AccessToken == "" {
		return "", errors.New("google token reply was unreadable")
	}
	f.accessToken = reply.AccessToken
	f.expiresAt = f.Now().Add(time.Duration(reply.ExpiresIn) * time.Second)
	return f.accessToken, nil
}

// Notify sends to raw FCM tokens and returns the ones Google says are gone for good.
func (f *FCMSender) Notify(ctx context.Context, tokens []string, from string) ([]string, error) {
	access, err := f.token(ctx)
	if err != nil {
		return nil, err
	}
	var dead []string
	var firstErr error
	for _, token := range tokens {
		isDead, err := f.send(ctx, access, token, from)
		if isDead {
			dead = append(dead, token)
		}
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return dead, firstErr
}

func (f *FCMSender) send(ctx context.Context, access, token, from string) (bool, error) {
	body, err := json.Marshal(map[string]any{"message": map[string]any{
		"token":        token,
		"notification": map[string]string{"title": from, "body": "New message"},
		"data":         map[string]string{"from": from},
		"android": map[string]any{
			"priority":     "HIGH",
			"notification": map[string]string{"channel_id": "messages", "tag": from},
		},
	}})
	if err != nil {
		return false, err
	}
	target := f.SendURL
	if target == "" {
		target = fmt.Sprintf(fcmSendFormat, f.ProjectID)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	request.Header.Set("Authorization", "Bearer "+access)
	request.Header.Set("Content-Type", "application/json")
	response, err := f.Client.Do(request)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusOK {
		return false, nil
	}
	raw, _ := io.ReadAll(io.LimitReader(response.Body, 2048))
	var reply struct {
		Error struct {
			Status string `json:"status"`
		} `json:"error"`
	}
	json.Unmarshal(raw, &reply)
	isDead := response.StatusCode == http.StatusNotFound || reply.Error.Status == "UNREGISTERED"
	return isDead, fmt.Errorf("fcm answered %d %s", response.StatusCode, reply.Error.Status)
}
