package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultPoolDir     = "/data/local/tmp/navidrome/yomi-pool"
	defaultPoolMB      = 256
	poolChunkBytes     = 1 << 20
	poolFillTimeout    = 60 * time.Second
	poolCoverFresh     = 15 * time.Minute
	poolSongFresh      = 10 * time.Minute
	poolDefaultCover   = 300
	poolMaxCoverPixels = 2048
	privateCoverPrefix = "pl-"
	poolSecretBytes    = 32
	poolImmutable      = "public, max-age=31536000, immutable"
	poolRedirectCache  = "private, max-age=300"
)

var poolCoverSizes = []int{64, 128, 240, 300, 600, 640, 1200, poolMaxCoverPixels}

var (
	poolIDPattern   = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,128}$`)
	poolHashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
	poolCapPattern  = regexp.MustCompile(`^[a-f0-9]{32}$`)
)

// Pool is the shared cache: the first listener to ask for a cover or a stretch of a song
// fills it from the music server, and everyone after is served from disk.
type Pool struct {
	ChunkSize int64
	store     *PoolStore
	origin    PoolOrigin
	secret    []byte
	now       func() time.Time
	fills     flightGroup
}

func newPool(store *PoolStore, origin PoolOrigin, secretDir string) (*Pool, error) {
	secret, err := loadPoolSecret(secretDir)
	if err != nil {
		return nil, err
	}
	return &Pool{ChunkSize: poolChunkBytes, store: store, origin: origin, secret: secret, now: time.Now}, nil
}

func openPool(cfg Config) (*Pool, error) {
	store, err := openPoolStore(filepath.Join(cfg.PoolDir, "files"), cfg.PoolBytes)
	if err != nil {
		return nil, err
	}
	return newPool(store, newNavidromeOrigin(cfg.NavidromeURL), cfg.PoolDir)
}

// loadPoolSecret keeps one random value across restarts, so audio keys stay stable
// but can't be worked out from a song's ID.
func loadPoolSecret(dir string) ([]byte, error) {
	if err := os.MkdirAll(dir, poolDirMode); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "pool-secret")
	if data, err := os.ReadFile(path); err == nil && len(data) == poolSecretBytes {
		return data, nil
	}
	secret := make([]byte, poolSecretBytes)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	return secret, os.WriteFile(path, secret, poolFileMode)
}

// keyed hashes parts with the server's secret. Pool keys made this way can't be worked
// out by anyone else, so they can't be used to probe for what the pool holds.
func (p *Pool) keyed(parts ...string) string {
	mac := hmac.New(sha256.New, p.secret)
	for _, part := range parts {
		mac.Write([]byte(part))
		mac.Write([]byte{0})
	}
	return hex.EncodeToString(mac.Sum(nil))
}

// songKey names one version of one song. A replaced file gets a new key, so old
// chunks are never mixed with new ones.
func (p *Pool) songKey(songID, version string) string {
	return p.keyed("song", songID, version)[:32]
}

// --- covers ---

type coverPointer struct {
	Hash    string `json:"hash"`
	Fetched int64  `json:"fetched"`
}

func (p *Pool) readJSON(key string, into any) bool {
	file, ok := p.store.Open(key)
	if !ok {
		return false
	}
	defer file.Close()
	return json.NewDecoder(file).Decode(into) == nil
}

func (p *Pool) writeJSON(key string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return p.store.Put(key, data)
}

// resolveCover returns the hash of a cover's picture, asking the origin only when the
// pool has no recent answer.
func (p *Pool) resolveCover(ctx context.Context, query url.Values, id string, size int) (string, error) {
	pointerKey := p.keyed("cover", id, strconv.Itoa(size))
	var pointer coverPointer
	if p.readJSON(pointerKey, &pointer) && poolHashPattern.MatchString(pointer.Hash) &&
		p.now().Sub(time.Unix(pointer.Fetched, 0)) < poolCoverFresh && p.has(pointer.Hash) {
		return pointer.Hash, nil
	}
	value, err := p.fills.Do(pointerKey, func() (any, error) {
		fillCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), poolFillTimeout)
		defer cancel()
		image, err := p.origin.Cover(fillCtx, query, id, size)
		if err != nil {
			return "", err
		}
		if !looksLikeImage(image) {
			return "", errors.New("the music server didn't send a picture")
		}
		hash := p.keyed("blob", string(image))
		if err := p.store.Put(hash, image); err != nil {
			return "", err
		}
		return hash, p.writeJSON(pointerKey, coverPointer{Hash: hash, Fetched: p.now().Unix()})
	})
	hash, _ := value.(string)
	return hash, err
}

func (p *Pool) has(key string) bool {
	file, ok := p.store.Open(key)
	if ok {
		file.Close()
	}
	return ok
}

// --- songs ---

type songPointer struct {
	Size        int64  `json:"size"`
	Version     string `json:"version"`
	ContentType string `json:"contentType"`
	Fetched     int64  `json:"fetched"`
}

func (p *Pool) songMeta(ctx context.Context, query url.Values, id string) (SongMeta, error) {
	pointerKey := p.keyed("songmeta", id)
	var pointer songPointer
	if p.readJSON(pointerKey, &pointer) && p.now().Sub(time.Unix(pointer.Fetched, 0)) < poolSongFresh {
		return SongMeta{Size: pointer.Size, Version: pointer.Version, ContentType: pointer.ContentType}, nil
	}
	meta, err := p.origin.Song(ctx, query, id)
	if err != nil {
		return SongMeta{}, err
	}
	if err := p.writeJSON(pointerKey, songPointer{meta.Size, meta.Version, meta.ContentType, p.now().Unix()}); err != nil {
		log.Printf("pool: remembering song details: %v", err)
	}
	return meta, nil
}

func chunkKey(songKey string, index int64) string {
	return songKey + "-" + strconv.FormatInt(index, 10)
}

// chunk returns one piece of a song, fetching and storing it on first use.
func (p *Pool) chunk(ctx context.Context, query url.Values, id, songKey string, size, index int64) ([]byte, error) {
	key := chunkKey(songKey, index)
	start := index * p.ChunkSize
	length := min(p.ChunkSize, size-start)
	if data, ok := p.readChunk(key, length); ok {
		return data, nil
	}
	value, err := p.fills.Do(key, func() (any, error) {
		if data, ok := p.readChunk(key, length); ok {
			return data, nil
		}
		fillCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), poolFillTimeout)
		defer cancel()
		data, err := p.origin.SongRange(fillCtx, query, id, start, length)
		if err != nil {
			return nil, err
		}
		if int64(len(data)) != length {
			return nil, fmt.Errorf("music server sent %d of %d bytes", len(data), length)
		}
		if err := p.store.Put(key, data); err != nil {
			log.Printf("pool: storing chunk: %v", err)
		}
		return data, nil
	})
	data, _ := value.([]byte)
	return data, err
}

// readChunk returns a stored chunk only if it has the expected length, so a damaged or
// partial file counts as a miss instead of breaking playback.
func (p *Pool) readChunk(key string, length int64) ([]byte, bool) {
	file, ok := p.store.Open(key)
	if !ok {
		return nil, false
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	return data, err == nil && int64(len(data)) == length
}

// songReader presents a song as one seekable file, so http.ServeContent can do the
// Range handling while chunks arrive from the pool or the origin as needed.
type songReader struct {
	ctx    context.Context
	pool   *Pool
	query  url.Values
	id     string
	key    string
	size   int64
	offset int64

	// current is the chunk being read, kept so each Read doesn't reload it from disk.
	current      []byte
	currentIndex int64
}

func (r *songReader) Read(buf []byte) (int, error) {
	if r.offset >= r.size {
		return 0, io.EOF
	}
	index := r.offset / r.pool.ChunkSize
	if r.current == nil || r.currentIndex != index {
		data, err := r.pool.chunk(r.ctx, r.query, r.id, r.key, r.size, index)
		if err != nil {
			return 0, err
		}
		r.current, r.currentIndex = data, index
	}
	data := r.current
	copied := copy(buf, data[r.offset-index*r.pool.ChunkSize:])
	if copied == 0 {
		return 0, io.ErrUnexpectedEOF
	}
	r.offset += int64(copied)
	return copied, nil
}

func (r *songReader) Seek(offset int64, whence int) (int64, error) {
	var next int64
	switch whence {
	case io.SeekStart:
		next = offset
	case io.SeekCurrent:
		next = r.offset + offset
	case io.SeekEnd:
		next = r.size + offset
	default:
		return 0, errors.New("bad seek")
	}
	if next < 0 {
		return 0, errors.New("seek before start")
	}
	r.offset = next
	return next, nil
}

// --- routes ---

func (s *Server) poolUser(w http.ResponseWriter, r *http.Request) bool {
	if s.Pool == nil {
		writeError(w, http.StatusServiceUnavailable, "the shared cache isn't turned on")
		return false
	}
	_, ok := s.authenticate(w, r)
	return ok
}

func poolFailure(w http.ResponseWriter, what string, err error) {
	if errors.Is(err, errPoolNotFound) {
		writeError(w, http.StatusNotFound, "no such "+what)
		return
	}
	log.Printf("pool: %s: %v", what, redactURL(err))
	writeError(w, http.StatusBadGateway, "couldn't get that "+what+" from the music server")
}

// snapCoverSize rounds up to a standard size, so odd requests can't fill the pool
// with a copy of every cover at every pixel size.
func snapCoverSize(size int) int {
	for _, standard := range poolCoverSizes {
		if size <= standard {
			return standard
		}
	}
	return poolMaxCoverPixels
}

func (s *Server) handlePoolCover(w http.ResponseWriter, r *http.Request) {
	if !s.poolUser(w, r) {
		return
	}
	id := r.PathValue("id")
	size := poolDefaultCover
	if raw := r.URL.Query().Get("size"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > poolMaxCoverPixels {
			writeError(w, http.StatusBadRequest, "size must be a number from 1 to "+strconv.Itoa(poolMaxCoverPixels))
			return
		}
		size = parsed
	}
	if !poolIDPattern.MatchString(id) {
		writeError(w, http.StatusBadRequest, "that isn't a cover")
		return
	}
	if strings.HasPrefix(id, privateCoverPrefix) {
		// Playlist pictures belong to their owner, so they never enter the shared pool.
		writeError(w, http.StatusNotFound, "no such cover")
		return
	}
	hash, err := s.Pool.resolveCover(r.Context(), r.URL.Query(), id, snapCoverSize(size))
	if err != nil {
		poolFailure(w, "cover", err)
		return
	}
	w.Header().Set("Cache-Control", poolRedirectCache)
	http.Redirect(w, r, "/v1/pool/blob/"+hash, http.StatusFound)
}

// handlePoolBlob serves a picture by its key. The key is a keyed hash of the picture, so
// only someone who was given the address can ask for it, and the bytes behind it never
// change, so any cache or CDN may keep it forever.
func (s *Server) handlePoolBlob(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	if s.Pool == nil || !poolHashPattern.MatchString(hash) {
		http.NotFound(w, r)
		return
	}
	file, ok := s.Pool.store.Open(hash)
	if !ok {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	w.Header().Set("Cache-Control", poolImmutable)
	w.Header().Set("ETag", `"`+hash+`"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "", time.Time{}, file)
}

func (s *Server) handlePoolSong(w http.ResponseWriter, r *http.Request) {
	if !s.poolUser(w, r) {
		return
	}
	id := r.PathValue("id")
	if !poolIDPattern.MatchString(id) {
		writeError(w, http.StatusBadRequest, "that isn't a song")
		return
	}
	query := r.URL.Query()
	meta, err := s.Pool.songMeta(r.Context(), query, id)
	if err != nil {
		poolFailure(w, "song", err)
		return
	}
	key := s.Pool.songKey(id, meta.Version)
	contentType := meta.ContentType
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("ETag", `"`+key+`"`)
	w.Header().Set("X-Yomi-Pool-Key", key)
	reader := &songReader{ctx: r.Context(), pool: s.Pool, query: query, id: id, key: key, size: meta.Size}
	http.ServeContent(w, r, "", time.Time{}, reader)
}

// handlePoolChunk serves a chunk that is already in the pool and never fills one, so it
// needs no login and a CDN in front can keep every answer.
func (s *Server) handlePoolChunk(w http.ResponseWriter, r *http.Request) {
	key, number := r.PathValue("key"), r.PathValue("n")
	index, err := strconv.ParseInt(number, 10, 32)
	if s.Pool == nil || !poolCapPattern.MatchString(key) || err != nil || strconv.FormatInt(index, 10) != number {
		http.NotFound(w, r)
		return
	}
	file, ok := s.Pool.store.Open(chunkKey(key, index))
	if !ok {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", poolImmutable)
	w.Header().Set("ETag", `"`+chunkKey(key, index)+`"`)
	http.ServeContent(w, r, "", time.Time{}, file)
}

// --- coalescing ---

type flightCall struct {
	done  chan struct{}
	value any
	err   error
}

// flightGroup makes simultaneous requests for the same key share one piece of work.
type flightGroup struct {
	mu    sync.Mutex
	calls map[string]*flightCall
}

func (g *flightGroup) Do(key string, work func() (any, error)) (value any, err error) {
	g.mu.Lock()
	if call, ok := g.calls[key]; ok {
		g.mu.Unlock()
		<-call.done
		return call.value, call.err
	}
	if g.calls == nil {
		g.calls = make(map[string]*flightCall)
	}
	call := &flightCall{done: make(chan struct{})}
	g.calls[key] = call
	g.mu.Unlock()

	defer func() {
		if recovered := recover(); recovered != nil {
			call.err = fmt.Errorf("pool fill failed: %v", recovered)
		}
		value, err = call.value, call.err
		g.mu.Lock()
		delete(g.calls, key)
		g.mu.Unlock()
		close(call.done)
	}()
	call.value, call.err = work()
	return
}
