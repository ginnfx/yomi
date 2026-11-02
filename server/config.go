package main

import (
	"os"
	"strconv"
)

const (
	defaultListen        = "0.0.0.0:4534"
	defaultNavidromeURL  = "http://127.0.0.1:4533"
	defaultMusicDir      = "/data/local/tmp/navidrome/music"
	defaultMaxFileMB     = 150
	maxConcurrentUploads = 2
)

// Config holds runtime settings, all overridable through YOMI_* environment variables.
type Config struct {
	Listen       string
	NavidromeURL string
	MusicDir     string
	MaxFileBytes int64
}

func loadConfig() Config {
	return Config{
		Listen:       envOr("YOMI_LISTEN", defaultListen),
		NavidromeURL: envOr("YOMI_NAVIDROME", defaultNavidromeURL),
		MusicDir:     envOr("YOMI_MUSIC", defaultMusicDir),
		MaxFileBytes: int64(envInt("YOMI_MAX_FILE_MB", defaultMaxFileMB)) << 20,
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
