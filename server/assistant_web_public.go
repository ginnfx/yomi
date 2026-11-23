package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"golang.org/x/net/html"
)

// Public search is the no-key default for this personal music assistant. Only
// search-result snippets are read; result URLs are never fetched by the server.
func searchPublicWeb(ctx context.Context, client *http.Client, query string) any {
	fail := func(reason string) any {
		return map[string]string{"error": "Web search could not retrieve results: " + reason + ". Do not invent results."}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://search.yahoo.com/search?"+url.Values{"p": {query}}.Encode(), nil)
	if err != nil {
		return fail("request failed")
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	var response *http.Response
	for attempt := 0; attempt < 2; attempt++ {
		response, err = client.Do(req.Clone(ctx))
		if err != nil {
			return fail(redactURL(err).Error())
		}
		if response.StatusCode >= 500 && attempt == 0 {
			response.Body.Close()
			continue
		}
		break
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fail(fmt.Sprintf("provider returned HTTP %d", response.StatusCode))
	}
	const maxPage = 2 << 20
	body, err := io.ReadAll(io.LimitReader(response.Body, maxPage+1))
	if err != nil || len(body) > maxPage {
		return fail("response too large or incomplete")
	}
	sources, err := publicSearchSources(string(body))
	if err != nil {
		return fail("provider page has no recognized result records")
	}
	return webSearchResult{Sources: sources}
}

func publicSearchSources(page string) ([]webSource, error) {
	root, err := html.Parse(strings.NewReader(page))
	if err != nil {
		return nil, err
	}
	attr := func(node *html.Node, name string) string {
		for _, a := range node.Attr {
			if a.Key == name {
				return a.Val
			}
		}
		return ""
	}
	hasClass := func(node *html.Node, name string) bool {
		for _, class := range strings.Fields(attr(node, "class")) {
			if class == name {
				return true
			}
		}
		return false
	}
	var text func(*html.Node) string
	text = func(node *html.Node) string {
		if node.Type == html.TextNode {
			return node.Data
		}
		if node.Type == html.ElementNode && (node.Data == "script" || node.Data == "style") {
			return ""
		}
		var b strings.Builder
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			b.WriteString(text(child))
			b.WriteByte(' ')
		}
		return strings.Join(strings.Fields(b.String()), " ")
	}
	sources := []webSource{}
	seen := map[string]bool{}
	var visit func(*html.Node)
	visit = func(node *html.Node) {
		if len(sources) >= 5 {
			return
		}
		if node.Type == html.ElementNode && hasClass(node, "algo") {
			var title, link, description string
			var scan func(*html.Node)
			scan = func(n *html.Node) {
				if n.Type == html.ElementNode {
					if n.Data == "a" && attr(n, "data-matarget") == "algo" && link == "" {
						link = attr(n, "href")
					}
					if n.Data == "h3" && title == "" {
						title = text(n)
					}
					if hasClass(n, "compText") && description == "" {
						description = text(n)
					}
				}
				for child := n.FirstChild; child != nil; child = child.NextSibling {
					scan(child)
				}
			}
			scan(node)
			if link = publicResultURL(link); link != "" && title != "" && !seen[link] {
				seen[link] = true
				sources = append(sources, webSource{Title: clip(title, 160), URL: link, Description: clip(description, 500)})
			}
			return
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			visit(child)
		}
	}
	visit(root)
	if len(sources) == 0 {
		plain := strings.ToLower(text(root))
		if !strings.Contains(plain, "no results found") && !strings.Contains(plain, "we did not find results") {
			return nil, fmt.Errorf("search page has no recognized result records")
		}
	}
	return sources, nil
}

func publicResultURL(raw string) string {
	if len(raw) > 4096 {
		return ""
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	if parsed.Hostname() == "r.search.yahoo.com" {
		_, tail, ok := strings.Cut(raw, "/RU=")
		if !ok {
			return ""
		}
		encoded, _, ok := strings.Cut(tail, "/RK=")
		if !ok {
			return ""
		}
		raw, err = url.PathUnescape(encoded)
		if err != nil {
			return ""
		}
		parsed, err = url.Parse(raw)
	}
	if err != nil || parsed.Host == "" || parsed.User != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return ""
	}
	return parsed.String()
}
