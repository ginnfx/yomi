package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"mime/multipart"
	"net/http"
	"net/url"
	"path/filepath"
	"sync"
	"time"
)

const (
	multipartOverheadBytes = 1 << 20
	scanTimeout            = 10 * time.Second
	filePartName           = "file"
)

// Server wires authentication, storage and the post-upload library rescan together.
type Server struct {
	Config      Config
	Auth        Authenticator
	Store       Store
	Scan        func(ctx context.Context, query url.Values)
	Index       *HashIndex
	Status      *StatusReader
	Backups     *BackupSource
	Messages    *MessageStore
	Relay       *PushRelay
	History     *HistoryStore
	Tags        *TagStore
	LLM         *LLMClient
	interpreter *Interpreter

	PlaylistCovers *PlaylistCoverStore
	PlaylistOwner  func(ctx context.Context, query url.Values, id string) (string, error)
	Reports        *ReportStore
	SongPath       func(ctx context.Context, query url.Values, id string) (string, error)
	chatLimits     *chatLimiter
	slots          chan struct{}
	limits         *loginLimiter
	scans          *scanDebouncer
	publishMu      sync.Mutex
}

func newServer(cfg Config, auth Authenticator, scan func(context.Context, url.Values), index *HashIndex) *Server {
	return &Server{
		Config:     cfg,
		Auth:       auth,
		Store:      Store{Root: cfg.MusicDir},
		Scan:       scan,
		Index:      index,
		slots:      make(chan struct{}, maxConcurrentUploads),
		limits:     newLoginLimiter(),
		chatLimits: newChatLimiter(time.Now),
		scans:      newScanDebouncer(cfg.ScanDebounce, scan),
	}
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		body := map[string]string{"status": "ok"}
		if s.isReplica() {
			body["role"] = roleReplica
		}
		writeJSON(w, http.StatusOK, body)
	})
	mux.HandleFunc("/upload", s.handleUpload)
	mux.HandleFunc("POST /v1/check", s.handleCheck)
	mux.HandleFunc("GET /v1/status", s.handleStatus)
	mux.HandleFunc("POST /v1/messages", s.handleSend)
	mux.HandleFunc("GET /v1/messages", s.handleThread)
	mux.HandleFunc("POST /v1/messages/read", s.handleMarkRead)
	mux.HandleFunc("GET /v1/conversations", s.handleConversations)
	mux.HandleFunc("GET /v1/events", s.handleEvents)
	mux.HandleFunc("POST /v1/messages/react", s.handleReact)
	mux.HandleFunc("PUT /v1/profile/playing", s.handleSetPlaying)
	mux.HandleFunc("GET /v1/replica/state", s.handleStateIndex)
	mux.HandleFunc("GET /v1/replica/state/file", s.handleStateFile)
	mux.HandleFunc("PUT /v1/profile", s.handleSaveProfile)
	mux.HandleFunc("PUT /v1/profile/taste", s.handleSaveTaste)
	mux.HandleFunc("GET /v1/profiles", s.handleProfiles)
	mux.HandleFunc("PUT /v1/profile/avatar", s.handleSaveAvatar)
	mux.HandleFunc("GET /v1/profiles/{user}/avatar", s.handleAvatar)
	mux.HandleFunc("POST /v1/devices", s.handleRegisterDevice)
	mux.HandleFunc("GET /v1/replica/index", s.handleReplicaIndex)
	mux.HandleFunc("GET /v1/replica/file/{sha256}", s.handleReplicaFile)
	mux.HandleFunc("GET /v1/replica/database", s.handleReplicaDatabase)
	mux.HandleFunc("PUT /v1/upload/{sha256}", s.handleBulkUpload)
	mux.HandleFunc("POST /v1/history", s.handleAddHistory)
	mux.HandleFunc("GET /v1/history", s.handleReadHistory)
	mux.HandleFunc("PUT /v1/history/imported", s.handleSaveImported)
	mux.HandleFunc("GET /v1/history/imported", s.handleReadImported)
	mux.HandleFunc("GET /v1/imports", s.handleListImports)
	mux.HandleFunc("PUT /v1/imports/{id}", s.handleSaveImport)
	mux.HandleFunc("DELETE /v1/imports/{id}", s.handleDeleteImport)
	mux.HandleFunc("GET /v1/tags", s.handleTags)
	mux.HandleFunc("POST /v1/tags/songs", s.handleQueueTags)
	mux.HandleFunc("POST /v1/search/interpret", s.handleInterpret)
	mux.HandleFunc("GET /v1/playlist-covers", s.handlePlaylistCovers)
	mux.HandleFunc("GET /v1/playlists/{id}/cover", s.handlePlaylistCover)
	mux.HandleFunc("PUT /v1/playlists/{id}/cover", s.handleSavePlaylistCover)
	mux.HandleFunc("DELETE /v1/playlists/{id}/cover", s.handleDeletePlaylistCover)
	mux.HandleFunc("POST /v1/ai/names", s.handleMixNames)
	mux.HandleFunc("POST /v1/ai/chat", s.handleChat)
	mux.HandleFunc("POST /v1/ai/discover", s.handleDiscover)
	mux.HandleFunc("POST /v1/reports", s.handleAddReport)
	mux.HandleFunc("GET /v1/reports", s.handleListReports)
	mux.HandleFunc("PATCH /v1/reports/{id}", s.handleCloseReport)
	mux.HandleFunc("POST /v1/reports/{id}/added", s.handleReportAdded)
	mux.HandleFunc("POST /v1/reports/{id}/replace", s.handleReplaceReport)
	return mux
}

func (s *Server) isReplica() bool { return s.Config.Role == roleReplica }

func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "use POST")
		return
	}
	if s.isReplica() {
		writeError(w, http.StatusForbidden, errReadOnly.Error())
		return
	}
	user, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		writeError(w, http.StatusTooManyRequests, "too many uploads in progress, try again shortly")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, s.Config.MaxFileBytes+multipartOverheadBytes)
	part, err := firstFilePart(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "send one multipart field named 'file'")
		return
	}
	stored, err := s.Store.Save(user, part.FileName(), part)
	if err != nil {
		status, message := classifySaveError(err)
		writeError(w, status, message)
		return
	}
	log.Printf("stored %s for %s", stored, user)
	s.scans.Touch(r.URL.Query())
	if s.Index != nil {
		// Older apps still use this route; their songs must count as duplicates too.
		go s.Index.seedFile(filepath.Join(s.Config.MusicDir, stored), stored)
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "file": stored})
}

func firstFilePart(r *http.Request) (*multipart.Part, error) {
	reader, err := r.MultipartReader()
	if err != nil {
		return nil, err
	}
	for {
		part, err := reader.NextPart()
		if err != nil {
			return nil, err
		}
		if part.FormName() == filePartName && part.FileName() != "" {
			return part, nil
		}
	}
}

func classifySaveError(err error) (int, string) {
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		return http.StatusRequestEntityTooLarge, "file is too large"
	case errors.Is(err, errBadName), errors.Is(err, errNotAudio), errors.Is(err, errBadUser):
		return http.StatusUnsupportedMediaType, err.Error()
	default:
		log.Printf("save failed: %v", err)
		return http.StatusInternalServerError, "could not save the file"
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"status": "error", "message": message})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("write response: %v", err)
	}
}
