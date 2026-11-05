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
	server.Status = newStatusReader(cfg, index)
	server.Backups = newBackupSource(cfg)
	messages, err := openMessageStore(cfg.MessagesDir, time.Now)
	if err != nil {
		// Music matters more than messages, so the server still starts.
		log.Printf("messages disabled: %v", err)
	} else {
		server.Messages = messages
		server.Relay = newPushRelay(cfg)
	}
	if cfg.Role == roleReplica {
		if cfg.PrimaryURL == "" || cfg.ReplicaUser == "" || cfg.ReplicaPassword == "" || cfg.ReplicaDatabase == "" {
			log.Fatal("replica needs YOMI_PRIMARY, YOMI_REPLICA_USER, YOMI_REPLICA_PASSWORD and YOMI_REPLICA_DB")
		}
		sync := newReplicaSync(cfg, index)
		sync.State = &StateSync{
			PrimaryURL: sync.PrimaryURL,
			Login:      sync.Login,
			Client:     sync.Client,
			Roots:      map[string]string{stateRootMessages: cfg.MessagesDir, stateRootHistory: cfg.HistoryDir},
		}
		if server.Messages != nil {
			sync.State.OnChanged = server.Messages.Reload
		}
		go sync.Run(context.Background())
	}
	if cfg.CoversOn {
		startCovers(cfg)
	}
	startAI(cfg, server)
	history, err := openHistoryStore(cfg.HistoryDir)
	if err != nil {
		// Music matters more than stats, so the server still starts.
		log.Printf("listening history disabled: %v", err)
	} else {
		server.History = history
	}
	httpServer := &http.Server{
		Addr:              cfg.Listen,
		Handler:           server.routes(),
		ReadHeaderTimeout: headerTimeout,
		IdleTimeout:       idleTimeout,
	}
	log.Printf("yomi-upload listening on %s, music dir %s", cfg.Listen, cfg.MusicDir)
	log.Fatal(httpServer.ListenAndServe())
}

// startCovers runs in the background; a failure only means art isn't fetched.
func startCovers(cfg Config) {
	client, err := newInternetClient()
	if err != nil {
		log.Printf("covers disabled: %v", err)
		return
	}
	go newCoverFetcher(cfg.MusicDir, cfg.CoverState, client).Run(context.Background())
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
			log.Printf("startScan: %v", redactURL(err))
			return
		}
		resp.Body.Close()
	}
}
