package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"mime/multipart"
	"net/http"
	"net/url"
	"time"
)

const (
	multipartOverheadBytes = 1 << 20
	scanTimeout            = 10 * time.Second
	filePartName           = "file"
)

// Server wires authentication, storage and the post-upload library rescan together.
type Server struct {
	Config Config
	Auth   Authenticator
	Store  Store
	Scan   func(ctx context.Context, query url.Values)
	slots  chan struct{}
	limits *loginLimiter
}

func newServer(cfg Config, auth Authenticator, scan func(context.Context, url.Values)) *Server {
	return &Server{
		Config: cfg,
		Auth:   auth,
		Store:  Store{Root: cfg.MusicDir},
		Scan:   scan,
		slots:  make(chan struct{}, maxConcurrentUploads),
		limits: newLoginLimiter(),
	}
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/upload", s.handleUpload)
	return mux
}

func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "use POST")
		return
	}
	query := r.URL.Query()
	if s.limits.Blocked(query.Get("u")) {
		writeError(w, http.StatusTooManyRequests, "too many wrong passwords, try again in a few minutes")
		return
	}
	user, err := s.Auth.Verify(r.Context(), query)
	switch {
	case errors.Is(err, errUnauthorized):
		s.limits.Fail(query.Get("u"))
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	case err != nil:
		log.Printf("auth backend error: %v", err)
		writeError(w, http.StatusBadGateway, "music server unavailable")
		return
	}

	s.limits.Reset(user)
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
	go s.triggerScan(query)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "file": stored})
}

func (s *Server) triggerScan(query url.Values) {
	if s.Scan == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), scanTimeout)
	defer cancel()
	s.Scan(ctx, query)
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
