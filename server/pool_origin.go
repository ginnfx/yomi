package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	poolOriginTimeout = 30 * time.Second
	poolMaxCoverBytes = 8 << 20
)

var errPoolNotFound = errors.New("not found on the music server")

// SongMeta describes one original audio file. Version changes when the file does.
type SongMeta struct {
	Size        int64
	Version     string
	ContentType string
}

// PoolOrigin is where the pool goes on a miss. It acts as the person asking, so the
// music server still decides who may see what.
type PoolOrigin interface {
	Cover(ctx context.Context, query url.Values, id string, size int) ([]byte, error)
	Song(ctx context.Context, query url.Values, id string) (SongMeta, error)
	SongRange(ctx context.Context, query url.Values, id string, start, length int64) ([]byte, error)
}

type navidromeOrigin struct {
	baseURL string
	client  *http.Client
}

func newNavidromeOrigin(baseURL string) navidromeOrigin {
	return navidromeOrigin{baseURL: strings.TrimRight(baseURL, "/"), client: &http.Client{Timeout: poolOriginTimeout}}
}

func (o navidromeOrigin) request(ctx context.Context, endpoint string, query url.Values, params url.Values) (*http.Request, error) {
	forwarded := url.Values{"v": {"1.16.1"}, "c": {"yomi-upload"}}
	for _, key := range []string{"u", "t", "s", "p"} {
		if value := query.Get(key); value != "" {
			forwarded.Set(key, value)
		}
	}
	for key, values := range params {
		forwarded[key] = values
	}
	return http.NewRequestWithContext(ctx, http.MethodGet, o.baseURL+"/rest/"+endpoint+"?"+forwarded.Encode(), nil)
}

func (o navidromeOrigin) do(req *http.Request) (*http.Response, error) {
	resp, err := o.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("navidrome unreachable: %w", redactURL(err))
	}
	return resp, nil
}

func (o navidromeOrigin) Cover(ctx context.Context, query url.Values, id string, size int) ([]byte, error) {
	req, err := o.request(ctx, "getCoverArt", query, url.Values{"id": {id}, "size": {strconv.Itoa(size)}})
	if err != nil {
		return nil, err
	}
	resp, err := o.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, errPoolNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("cover art: navidrome answered %d", resp.StatusCode)
	}
	data, err := readLimited(resp.Body, poolMaxCoverBytes+1)
	if err != nil {
		return nil, err
	}
	if len(data) > poolMaxCoverBytes {
		return nil, errors.New("cover art is too big")
	}
	return data, nil
}

func (o navidromeOrigin) Song(ctx context.Context, query url.Values, id string) (SongMeta, error) {
	req, err := o.request(ctx, "getSong", query, url.Values{"id": {id}, "f": {"json"}})
	if err != nil {
		return SongMeta{}, err
	}
	resp, err := o.do(req)
	if err != nil {
		return SongMeta{}, err
	}
	defer resp.Body.Close()
	var body struct {
		Response struct {
			Status string `json:"status"`
			Song   struct {
				Size        int64   `json:"size"`
				ContentType string  `json:"contentType"`
				Created     string  `json:"created"`
				BitRate     int     `json:"bitRate"`
				Duration    float64 `json:"duration"`
			} `json:"song"`
		} `json:"subsonic-response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return SongMeta{}, fmt.Errorf("unexpected navidrome reply: %w", err)
	}
	song := body.Response.Song
	if body.Response.Status != "ok" || song.Size <= 0 {
		return SongMeta{}, errPoolNotFound
	}
	version := fmt.Sprintf("%d|%s|%d|%.0f", song.Size, song.Created, song.BitRate, song.Duration)
	return SongMeta{Size: song.Size, Version: version, ContentType: song.ContentType}, nil
}

// SongRange fetches the original bytes with format=raw, so nothing is transcoded.
// If Navidrome ignores the Range header, any chunk after the first is refused: skipping
// ahead would re-read the whole file for every chunk.
func (o navidromeOrigin) SongRange(ctx context.Context, query url.Values, id string, start, length int64) ([]byte, error) {
	req, err := o.request(ctx, "stream", query, url.Values{"id": {id}, "format": {"raw"}})
	if err != nil {
		return nil, err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, start+length-1))
	resp, err := o.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusPartialContent:
	case http.StatusOK:
		if start > 0 {
			return nil, errors.New("navidrome ignored the Range header")
		}
	case http.StatusNotFound:
		return nil, errPoolNotFound
	default:
		return nil, fmt.Errorf("song: navidrome answered %d", resp.StatusCode)
	}
	return readLimited(resp.Body, length)
}

// readLimited reads up to limit bytes and ignores anything after them.
func readLimited(r io.Reader, limit int64) ([]byte, error) {
	return io.ReadAll(io.LimitReader(r, limit))
}
