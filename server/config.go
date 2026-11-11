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
	defaultMessagesDir   = "/data/local/tmp/navidrome/yomi-messages"
	defaultTagsDir       = "/data/local/tmp/navidrome/yomi-ai"
	defaultMaxFileMB     = 150
	defaultScanDebounce  = 5 * time.Minute
	maxConcurrentUploads = 2
)

// Config holds runtime settings, all overridable through YOMI_* environment variables.
type Config struct {
	Listen            string
	NavidromeURL      string
	MusicDir          string
	IndexFile         string
	CoverState        string
	CoversOn          bool
	BatteryFile       string
	TailscaleBin      string
	TailscaleSocket   string
	Role              string
	PrimaryURL        string
	ReplicaUser       string
	ReplicaPassword   string
	ReplicaDatabase   string
	ReplicaApply      string
	BackupCommand     string
	BackupDir         string
	MessagesDir       string
	RelayURL          string
	RelayKey          string
	APNsKeyFile       string
	APNsKeyID         string
	APNsTeamID        string
	APNsTopic         string
	FCMServiceAccount string
	ReleaseRepo       string
	ReleaseState      string
	LLMURL            string
	SearchKey         string
	LLMKey            string
	LLMModel          string
	TagsDir           string
	PoolDir           string
	PoolOn            bool
	PoolBytes         int64
	HistoryDir        string
	MaxFileBytes      int64
	ScanDebounce      time.Duration
}

func loadConfig() Config {
	return Config{
		Listen:            envOr("YOMI_LISTEN", defaultListen),
		NavidromeURL:      envOr("YOMI_NAVIDROME", defaultNavidromeURL),
		MusicDir:          envOr("YOMI_MUSIC", defaultMusicDir),
		IndexFile:         envOr("YOMI_INDEX", defaultIndexFile),
		CoverState:        envOr("YOMI_COVER_STATE", defaultCoverState),
		CoversOn:          envOr("YOMI_COVERS", "on") != "off",
		BatteryFile:       envOr("YOMI_BATTERY_FILE", defaultBatteryFile),
		TailscaleBin:      envOr("YOMI_TAILSCALE", defaultTailscaleBin),
		TailscaleSocket:   envOr("YOMI_TAILSCALE_SOCKET", defaultTailscaleSock),
		Role:              os.Getenv("YOMI_ROLE"),
		PrimaryURL:        os.Getenv("YOMI_PRIMARY"),
		ReplicaUser:       os.Getenv("YOMI_REPLICA_USER"),
		ReplicaPassword:   os.Getenv("YOMI_REPLICA_PASSWORD"),
		ReplicaDatabase:   os.Getenv("YOMI_REPLICA_DB"),
		ReplicaApply:      os.Getenv("YOMI_REPLICA_APPLY"),
		BackupCommand:     os.Getenv("YOMI_BACKUP_CMD"),
		BackupDir:         os.Getenv("YOMI_BACKUP_DIR"),
		MessagesDir:       envOr("YOMI_MESSAGES_DIR", defaultMessagesDir),
		RelayURL:          os.Getenv("YOMI_RELAY_URL"),
		RelayKey:          os.Getenv("YOMI_RELAY_KEY"),
		APNsKeyFile:       os.Getenv("YOMI_APNS_KEY_FILE"),
		APNsKeyID:         os.Getenv("YOMI_APNS_KEY_ID"),
		APNsTeamID:        os.Getenv("YOMI_APNS_TEAM_ID"),
		APNsTopic:         os.Getenv("YOMI_APNS_TOPIC"),
		FCMServiceAccount: os.Getenv("YOMI_FCM_SERVICE_ACCOUNT"),
		ReleaseRepo:       os.Getenv("YOMI_RELEASE_REPO"),
		ReleaseState:      os.Getenv("YOMI_RELEASE_STATE"),
		LLMURL:            os.Getenv("YOMI_LLM_URL"),
		SearchKey:         os.Getenv("YOMI_SEARCH_KEY"),
		LLMKey:            os.Getenv("YOMI_LLM_KEY"),
		LLMModel:          os.Getenv("YOMI_LLM_MODEL"),
		TagsDir:           envOr("YOMI_TAGS_DIR", defaultTagsDir),
		PoolDir:           envOr("YOMI_POOL_DIR", defaultPoolDir),
		PoolOn:            envOr("YOMI_POOL", "on") != "off",
		PoolBytes:         int64(envInt("YOMI_POOL_MB", defaultPoolMB)) << 20,
		HistoryDir:        envOr("YOMI_HISTORY_DIR", defaultHistoryDir),
		MaxFileBytes:      int64(envInt("YOMI_MAX_FILE_MB", defaultMaxFileMB)) << 20,
		ScanDebounce:      defaultScanDebounce,
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
