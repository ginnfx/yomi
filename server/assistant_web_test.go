package main

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

type webTestTransport func(*http.Request) (*http.Response, error)

func (f webTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestWebSearchBoundaries(t *testing.T) {
	calls := 0
	client := &http.Client{Transport: webTestTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Host != "api.search.brave.com" || r.URL.Query().Get("q") != "東京 lyrics" || r.Header.Get("X-Subscription-Token") != "secret" {
			t.Fatal("incorrect provider request")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"web":{"results":[{"title":"Evidence","url":"https://example.com/song","description":"text"},{"title":"Unsafe","url":"javascript:alert(1)"}]}}`)), Header: http.Header{}}, nil
	})}
	for _, args := range [][2]string{{"secret", ""}, {"secret", strings.Repeat("x", 401)}} {
		if _, ok := searchWeb(context.Background(), client, args[0], args[1]).(map[string]string); !ok {
			t.Fatal("expected explicit unavailable/argument error")
		}
	}
	if calls != 0 {
		t.Fatal("invalid searches reached provider")
	}
	got := searchWeb(context.Background(), client, "secret", "東京 lyrics").(webSearchResult)
	if len(got.Sources) != 1 || got.Sources[0].URL != "https://example.com/song" {
		t.Fatalf("bad sources: %+v", got)
	}
}
