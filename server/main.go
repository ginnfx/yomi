// Command yomi-upload accepts audio uploads for Navidrome using Navidrome's own logins.
package main

import (
	"context"
	"log"
	"net/http"
	"net/url"
	"time"
)

const (
	headerTimeout = 10 * time.Second
	idleTimeout   = 60 * time.Second
)

func main() {
	cfg := loadConfig()
	auth := newCachedAuth(newNavidromeAuth(cfg.NavidromeURL))
	index, err := openHashIndex(cfg.MusicDir, cfg.IndexFile)
	if err != nil {
		log.Fatalf("open index: %v", err)
	}
	go index.Seed()
	server := newServer(cfg, auth, navidromeScan(cfg.NavidromeURL), index)
	httpServer := &http.Server{
		Addr:              cfg.Listen,
		Handler:           server.routes(),
		ReadHeaderTimeout: headerTimeout,
		IdleTimeout:       idleTimeout,
	}
	log.Printf("yomi-upload listening on %s, music dir %s", cfg.Listen, cfg.MusicDir)
	log.Fatal(httpServer.ListenAndServe())
}

// navidromeScan asks Navidrome to rescan using the uploader's own credentials.
// If the account is not allowed to, Navidrome's file watcher or hourly scan still picks files up.
func navidromeScan(baseURL string) func(context.Context, url.Values) {
	client := &http.Client{Timeout: scanTimeout}
	return func(ctx context.Context, query url.Values) {
		forwarded := url.Values{"v": {"1.16.1"}, "c": {"yomi-upload"}, "f": {"json"}}
		for _, key := range []string{"u", "t", "s", "p"} {
			if value := query.Get(key); value != "" {
				forwarded.Set(key, value)
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/rest/startScan?"+forwarded.Encode(), nil)
		if err != nil {
			return
		}
		resp, err := client.Do(req)
		if err != nil {
			log.Printf("startScan: %v", err)
			return
		}
		resp.Body.Close()
	}
}
