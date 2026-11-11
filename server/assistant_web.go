package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
)

type webSource struct {
	Title       string `json:"title"`
	URL         string `json:"url"`
	Description string `json:"description,omitempty"`
}
type webSearchResult struct {
	Sources []webSource `json:"sources"`
}

// Only a fixed search API is contacted; the model cannot fetch arbitrary URLs.
func searchWeb(ctx context.Context, client *http.Client, key, query string) any {
	if key == "" {
		return map[string]string{"error": "Web search is not configured on this server."}
	}
	query = strings.TrimSpace(query)
	if query == "" || len(query) > 400 {
		return map[string]string{"error": "Search needs 1–400 bytes of text."}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://api.search.brave.com/res/v1/web/search?"+url.Values{"q": {query}, "count": {"5"}}.Encode(), nil)
	if err != nil {
		return map[string]string{"error": "Web search unavailable."}
	}
	req.Header.Set("X-Subscription-Token", key)
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return map[string]string{"error": "Web search failed; do not invent results."}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return map[string]string{"error": "Web search provider unavailable; do not invent results."}
	}
	var body struct {
		Web struct {
			Results []webSource `json:"results"`
		} `json:"web"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&body) != nil {
		return map[string]string{"error": "Invalid search response."}
	}
	result := webSearchResult{Sources: []webSource{}}
	for _, source := range body.Web.Results {
		parsed, err := url.Parse(source.URL)
		if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") {
			continue
		}
		source.Title = clip(source.Title, 160)
		source.Description = clip(source.Description, 500)
		result.Sources = append(result.Sources, source)
		if len(result.Sources) == 5 {
			break
		}
	}
	return result
}

func (s *Server) assistantTools(credentials url.Values) libraryLookup {
	library := s.assistantLibrary(credentials)
	return func(ctx context.Context, call libraryToolCall) any {
		if call.Name != "web_search" {
			return library(ctx, call)
		}
		client, err := newInternetClient()
		if err != nil {
			return map[string]string{"error": "Web search unavailable."}
		}
		return searchWeb(ctx, client, s.Config.SearchKey, call.Query)
	}
}
