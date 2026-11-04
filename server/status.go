package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	statusCacheFor     = 10 * time.Second
	navidromeCheckWait = 5 * time.Second
	tailscaleCheckWait = 5 * time.Second
	batteryStaleAfter  = 5 * time.Minute
	kilobyte           = 1024
)

// ServerStatus is what the dashboard shows. Fields it can't determine stay null, so the
// app can say "unknown" instead of showing a made-up zero.
type ServerStatus struct {
	Online    bool           `json:"online"`
	Detailed  bool           `json:"detailed"`
	Uptime    *int64         `json:"uptimeSeconds,omitempty"`
	Load      *float64       `json:"load1,omitempty"`
	Memory    *SpaceUsage    `json:"memory,omitempty"`
	Card      *SpaceUsage    `json:"card,omitempty"`
	Internal  *SpaceUsage    `json:"internal,omitempty"`
	Battery   *BatteryInfo   `json:"battery,omitempty"`
	Navidrome *NavidromeInfo `json:"navidrome,omitempty"`
	Tailscale *string        `json:"tailscale,omitempty"`
	Indexed   *int           `json:"indexedSongs,omitempty"`
	Indexing  bool           `json:"indexing,omitempty"`
}

// SpaceUsage is a total and how much of it is free, in bytes.
type SpaceUsage struct {
	Total uint64 `json:"total"`
	Free  uint64 `json:"free"`
}

// BatteryInfo comes from the Keeper app, or just a percentage from the kernel without it.
type BatteryInfo struct {
	Level       int      `json:"level"`
	IsCharging  *bool    `json:"charging,omitempty"`
	Health      string   `json:"health,omitempty"`
	Temperature *float64 `json:"temperatureC,omitempty"`
	IsStale     bool     `json:"stale,omitempty"`
}

// NavidromeInfo reports a real request, because a hung Navidrome still has a process
// and so looks fine to the watchdog.
type NavidromeInfo struct {
	IsHealthy  bool  `json:"healthy"`
	LatencyMs  int64 `json:"latencyMs"`
	IsScanning bool  `json:"scanning"`
	SongCount  *int  `json:"songCount,omitempty"`
}

// StatusReader gathers the server's health. Paths and commands are fields so tests can
// point them at fakes.
type StatusReader struct {
	ProcRoot       string
	PowerFile      string
	BatteryFile    string
	MusicDir       string
	InternalDir    string
	NavidromeURL   string
	Client         *http.Client
	Index          *HashIndex
	TailscaleState func(context.Context) (string, error)
	Now            func() time.Time

	mu       sync.Mutex
	cached   ServerStatus
	cachedAt time.Time
}

func newStatusReader(cfg Config, index *HashIndex) *StatusReader {
	return &StatusReader{
		ProcRoot:     "/proc",
		PowerFile:    "/sys/class/power_supply/battery/capacity",
		BatteryFile:  cfg.BatteryFile,
		MusicDir:     cfg.MusicDir,
		InternalDir:  filepath.Dir(cfg.IndexFile),
		NavidromeURL: cfg.NavidromeURL,
		Client:       &http.Client{Timeout: navidromeCheckWait},
		Index:        index,
		TailscaleState: func(ctx context.Context) (string, error) {
			return readTailscaleState(ctx, cfg.TailscaleBin, cfg.TailscaleSocket)
		},
		Now: time.Now,
	}
}

// Read returns a recent status, gathered at most once per cache period so an open
// dashboard can't add load to a struggling server.
func (r *StatusReader) Read(ctx context.Context, query url.Values) ServerStatus {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.cachedAt.IsZero() && r.Now().Sub(r.cachedAt) < statusCacheFor {
		return r.cached
	}
	r.cached = r.gather(ctx, query)
	r.cachedAt = r.Now()
	return r.cached
}

func (r *StatusReader) gather(ctx context.Context, query url.Values) ServerStatus {
	status := ServerStatus{
		Online:    true,
		Detailed:  true,
		Uptime:    r.readUptime(),
		Load:      r.readLoad(),
		Memory:    r.readMemory(),
		Card:      readSpace(r.MusicDir),
		Internal:  readSpace(r.InternalDir),
		Battery:   r.readBattery(),
		Navidrome: r.readNavidrome(ctx, query),
	}
	if r.TailscaleState != nil {
		state, err := r.TailscaleState(ctx)
		if err != nil {
			log.Printf("status: tailscale: %v", err)
		} else {
			status.Tailscale = &state
		}
	}
	if r.Index != nil {
		count := r.Index.Count()
		status.Indexed = &count
		status.Indexing = r.Index.Seeding()
	}
	return status
}

func (r *StatusReader) readUptime() *int64 {
	data, err := os.ReadFile(filepath.Join(r.ProcRoot, "uptime"))
	if err != nil {
		return nil
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return nil
	}
	seconds, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return nil
	}
	whole := int64(seconds)
	return &whole
}

func (r *StatusReader) readLoad() *float64 {
	data, err := os.ReadFile(filepath.Join(r.ProcRoot, "loadavg"))
	if err != nil {
		return nil
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return nil
	}
	load, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return nil
	}
	return &load
}

// readMemory falls back to free plus cache, since kernel 3.4 has no MemAvailable.
func (r *StatusReader) readMemory() *SpaceUsage {
	file, err := os.Open(filepath.Join(r.ProcRoot, "meminfo"))
	if err != nil {
		return nil
	}
	defer file.Close()
	values := make(map[string]uint64)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}
		if value, err := strconv.ParseUint(fields[1], 10, 64); err == nil {
			values[strings.TrimSuffix(fields[0], ":")] = value * kilobyte
		}
	}
	if values["MemTotal"] == 0 {
		return nil
	}
	free, hasAvailable := values["MemAvailable"]
	if !hasAvailable {
		free = values["MemFree"] + values["Buffers"] + values["Cached"]
	}
	return &SpaceUsage{Total: values["MemTotal"], Free: free}
}

func readSpace(path string) *SpaceUsage {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return nil
	}
	size := uint64(stat.Bsize)
	return &SpaceUsage{Total: stat.Blocks * size, Free: stat.Bavail * size}
}

func (r *StatusReader) readBattery() *BatteryInfo {
	if info := r.readKeeperBattery(); info != nil {
		return info
	}
	data, err := os.ReadFile(r.PowerFile)
	if err != nil {
		return nil
	}
	level, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return nil
	}
	return &BatteryInfo{Level: level}
}

func (r *StatusReader) readKeeperBattery() *BatteryInfo {
	data, err := os.ReadFile(r.BatteryFile)
	if err != nil {
		return nil
	}
	var report struct {
		Level       *int     `json:"level"`
		IsCharging  *bool    `json:"charging"`
		Health      string   `json:"health"`
		Temperature *float64 `json:"temperatureC"`
		UpdatedMs   int64    `json:"updatedMs"`
	}
	if err := json.Unmarshal(data, &report); err != nil || report.Level == nil {
		return nil
	}
	return &BatteryInfo{
		Level:       *report.Level,
		IsCharging:  report.IsCharging,
		Health:      report.Health,
		Temperature: report.Temperature,
		IsStale:     r.Now().Sub(time.UnixMilli(report.UpdatedMs)) > batteryStaleAfter,
	}
}

func (r *StatusReader) readNavidrome(ctx context.Context, query url.Values) *NavidromeInfo {
	checkCtx, cancel := context.WithTimeout(ctx, navidromeCheckWait)
	defer cancel()
	started := r.Now()
	var ping struct {
		Response struct {
			Status string `json:"status"`
		} `json:"subsonic-response"`
	}
	err := r.callNavidrome(checkCtx, "ping", query, &ping)
	info := &NavidromeInfo{LatencyMs: r.Now().Sub(started).Milliseconds()}
	if err != nil || ping.Response.Status != "ok" {
		if err != nil {
			log.Printf("status: navidrome: %v", redactURL(err))
		}
		return info
	}
	info.IsHealthy = true
	var scan struct {
		Response struct {
			ScanStatus struct {
				IsScanning bool `json:"scanning"`
				Count      *int `json:"count"`
			} `json:"scanStatus"`
		} `json:"subsonic-response"`
	}
	if err := r.callNavidrome(checkCtx, "getScanStatus", query, &scan); err != nil {
		log.Printf("status: scan status: %v", redactURL(err))
		return info
	}
	info.IsScanning = scan.Response.ScanStatus.IsScanning
	info.SongCount = scan.Response.ScanStatus.Count
	return info
}

func (r *StatusReader) callNavidrome(ctx context.Context, endpoint string, query url.Values, into any) error {
	target := r.NavidromeURL + "/rest/" + endpoint + "?" + subsonicQuery(query).Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return err
	}
	response, err := r.Client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("%s answered %d", endpoint, response.StatusCode)
	}
	return json.NewDecoder(response.Body).Decode(into)
}

// subsonicQuery forwards only the login fields, so nothing else from a request reaches Navidrome.
func subsonicQuery(query url.Values) url.Values {
	forwarded := url.Values{"v": {"1.16.1"}, "c": {"yomi-upload"}, "f": {"json"}}
	for _, key := range []string{"u", "t", "s", "p"} {
		if value := query.Get(key); value != "" {
			forwarded.Set(key, value)
		}
	}
	return forwarded
}

func readTailscaleState(ctx context.Context, bin, socket string) (string, error) {
	checkCtx, cancel := context.WithTimeout(ctx, tailscaleCheckWait)
	defer cancel()
	output, err := exec.CommandContext(checkCtx, bin, "--socket="+socket, "status", "--json").Output()
	if err != nil {
		return "", err
	}
	var status struct {
		BackendState string `json:"BackendState"`
	}
	if err := json.Unmarshal(output, &status); err != nil {
		return "", err
	}
	if status.BackendState == "" {
		return "", errors.New("tailscale reported no state")
	}
	return status.BackendState, nil
}

// isAdmin asks Navidrome, which is the only place that knows. Anything other than a clear
// yes means no, since server details aren't for everyone.
func (s *Server) isAdmin(ctx context.Context, query url.Values) bool {
	request, err := http.NewRequestWithContext(
		ctx, http.MethodGet,
		s.Config.NavidromeURL+"/rest/getUser?"+withUsername(query).Encode(), nil,
	)
	if err != nil {
		return false
	}
	client := &http.Client{Timeout: navidromeCheckWait}
	response, err := client.Do(request)
	if err != nil {
		log.Printf("status: admin check: %v", redactURL(err))
		return false
	}
	defer response.Body.Close()
	var body struct {
		Response struct {
			User struct {
				IsAdmin bool `json:"adminRole"`
			} `json:"user"`
		} `json:"subsonic-response"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		return false
	}
	return body.Response.User.IsAdmin
}

func withUsername(query url.Values) url.Values {
	forwarded := subsonicQuery(query)
	forwarded.Set("username", query.Get("u"))
	return forwarded
}

// handleStatus gives admins the details and everyone else only "online".
func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authenticate(w, r); !ok {
		return
	}
	query := r.URL.Query()
	if s.Status == nil || !s.isAdmin(r.Context(), query) {
		writeJSON(w, http.StatusOK, ServerStatus{Online: true})
		return
	}
	writeJSON(w, http.StatusOK, s.Status.Read(r.Context(), query))
}
