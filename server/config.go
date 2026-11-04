package main

import (
	"os"
	"strconv"
	"time"
)

const (
	defaultListen        = "0.0.0.0:4534"
	defaultNavidromeURL  = "http://127.0.0.1:4533"
	defaultMusicDir      = "/data/local/tmp/navidrome/music"
	defaultIndexFile     = "/data/local/tmp/navidrome/yomi-index.jsonl"
	defaultCoverState    = "/data/local/tmp/navidrome/yomi-covers.json"
	defaultBatteryFile   = "/data/local/tmp/yomi/battery.json"
	defaultTailscaleBin  = "/data/local/tmp/tailscale/tailscale"
	defaultTailscaleSock = "/data/local/tmp/tailscale/tailscaled.sock"
	defaultMaxFileMB     = 150
	defaultScanDebounce  = 5 * time.Minute
	maxConcurrentUploads = 2
)

// Config holds runtime settings, all overridable through YOMI_* environment variables.
type Config struct {
	Listen          string
	NavidromeURL    string
	MusicDir        string
	IndexFile       string
	CoverState      string
	CoversOn        bool
	BatteryFile     string
	TailscaleBin    string
	TailscaleSocket string
	Role            string
	PrimaryURL      string
	ReplicaUser     string
	ReplicaPassword string
	ReplicaDatabase string
	ReplicaApply    string
	BackupCommand   string
	BackupDir       string
	MaxFileBytes    int64
	ScanDebounce    time.Duration
}

func loadConfig() Config {
	return Config{
		Listen:          envOr("YOMI_LISTEN", defaultListen),
		NavidromeURL:    envOr("YOMI_NAVIDROME", defaultNavidromeURL),
		MusicDir:        envOr("YOMI_MUSIC", defaultMusicDir),
		IndexFile:       envOr("YOMI_INDEX", defaultIndexFile),
		CoverState:      envOr("YOMI_COVER_STATE", defaultCoverState),
		CoversOn:        envOr("YOMI_COVERS", "on") != "off",
		BatteryFile:     envOr("YOMI_BATTERY_FILE", defaultBatteryFile),
		TailscaleBin:    envOr("YOMI_TAILSCALE", defaultTailscaleBin),
		TailscaleSocket: envOr("YOMI_TAILSCALE_SOCKET", defaultTailscaleSock),
		Role:            os.Getenv("YOMI_ROLE"),
		PrimaryURL:      os.Getenv("YOMI_PRIMARY"),
		ReplicaUser:     os.Getenv("YOMI_REPLICA_USER"),
		ReplicaPassword: os.Getenv("YOMI_REPLICA_PASSWORD"),
		ReplicaDatabase: os.Getenv("YOMI_REPLICA_DB"),
		ReplicaApply:    os.Getenv("YOMI_REPLICA_APPLY"),
		BackupCommand:   os.Getenv("YOMI_BACKUP_CMD"),
		BackupDir:       os.Getenv("YOMI_BACKUP_DIR"),
		MaxFileBytes:    int64(envInt("YOMI_MAX_FILE_MB", defaultMaxFileMB)) << 20,
		ScanDebounce:    defaultScanDebounce,
	}
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envInt(key string, fallback int) int {
	parsed, err := strconv.Atoi(os.Getenv(key))
	if err != nil || parsed <= 0 {
		return fallback
	}
	return parsed
}
