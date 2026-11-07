package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// Kinds of song problems people can report.
const (
	reportExplicitWanted = "explicit_wanted"
	reportCoverMissing   = "cover_missing"
	reportCoverWrong     = "cover_wrong"
	reportMissingSong    = "missing_song"
	reportOther          = "other"
)

// Where a report stands.
const (
	reportOpen      = "open"
	reportResolved  = "resolved"
	reportDismissed = "dismissed"
)

const (
	reportsFile            = "reports.json"
	maxReportNoteChars     = 300
	maxReportNotes         = 20
	maxReportTextChars     = 200
	maxOpenReportsPerUser  = 200
	maxStoredReports       = 5000
	maxReportsPerMinute    = 20
	replaceArchiveDir      = ".yomi-replaced"
	autoReporter           = "yomi"
	reportRateWindow       = time.Minute
	reportIDBytes          = 6
	maxReportRequestBytes  = 8 << 10
	reportArchiveIgnore    = ".ndignore"
	reportArchiveIgnoreAll = "*\n"
)

var (
	reportKinds = map[string]bool{
		reportExplicitWanted: true, reportCoverMissing: true, reportCoverWrong: true,
		reportMissingSong: true, reportOther: true,
	}
	errBadReport       = errors.New("bad report")
	errTooManyReports  = errors.New("too many reports")
	errNoSuchReport    = errors.New("no such report")
	errReportNotOpen   = errors.New("report already closed")
	errWrongReportKind = errors.New("not that kind of report")
	errNoSuchSong      = errors.New("no such song")
)

// ReportNote is one person's words on a report; only admins see them.
type ReportNote struct {
	User string `json:"user"`
	Text string `json:"text"`
	AtMs int64  `json:"atMs"`
}

// Report is one song problem, merged across everyone who reported it.
type Report struct {
	ID          string       `json:"id"`
	Kind        string       `json:"kind"`
	SongID      string       `json:"songId,omitempty"`
	Artist      string       `json:"artist"`
	Title       string       `json:"title"`
	Album       string       `json:"album,omitempty"`
	Reporters   []string     `json:"reporters,omitempty"`
	Count       int          `json:"count"`
	Notes       []ReportNote `json:"notes,omitempty"`
	Status      string       `json:"status"`
	Resolution  string       `json:"resolution,omitempty"`
	FixedSongID string       `json:"fixedSongId,omitempty"`
	Auto        bool         `json:"auto,omitempty"`
	CreatedMs   int64        `json:"createdMs"`
	UpdatedMs   int64        `json:"updatedMs"`
	// Key groups reports about the same problem; apps ignore it.
	Key string `json:"key"`
}

// ReportInput is what an app sends.
type ReportInput struct {
	Kind   string `json:"kind"`
	SongID string `json:"songId"`
	Artist string `json:"artist"`
	Title  string `json:"title"`
	Album  string `json:"album"`
	Note   string `json:"note"`
}

// ReportStore keeps every report in one private JSON file, rewritten atomically.
type ReportStore struct {
	dir     string
	now     func() time.Time
	mu      sync.Mutex
	reports []Report
	recent  map[string][]time.Time
}

func openReportStore(dir string, now func() time.Time) (*ReportStore, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	store := &ReportStore{dir: dir, now: now, recent: map[string][]time.Time{}}
	data, err := os.ReadFile(filepath.Join(dir, reportsFile))
	switch {
	case errors.Is(err, os.ErrNotExist):
		return store, nil
	case err != nil:
		return nil, err
	}
	if err := json.Unmarshal(data, &store.reports); err != nil {
		return nil, fmt.Errorf("reports file is damaged: %w", err)
	}
	return store, nil
}

func reportKey(kind, songID, artist, title string) string {
	if songID != "" {
		return kind + "|id|" + songID
	}
	return kind + "|" + normalizeReportText(artist) + "|" + normalizeReportText(title)
}

func normalizeReportText(text string) string {
	return strings.Join(strings.Fields(strings.ToLower(text)), " ")
}

func validateReport(input ReportInput) (ReportInput, error) {
	input.Kind = strings.TrimSpace(input.Kind)
	input.Artist = strings.TrimSpace(input.Artist)
	input.Title = strings.TrimSpace(input.Title)
	input.Album = strings.TrimSpace(input.Album)
	input.Note = strings.TrimSpace(input.Note)
	input.SongID = strings.TrimSpace(input.SongID)
	switch {
	case !reportKinds[input.Kind]:
		return input, fmt.Errorf("%w: unknown kind", errBadReport)
	case input.Title == "":
		return input, fmt.Errorf("%w: a title is needed", errBadReport)
	case utf8.RuneCountInString(input.Note) > maxReportNoteChars:
		return input, fmt.Errorf("%w: the note is too long", errBadReport)
	case utf8.RuneCountInString(input.Artist) > maxReportTextChars,
		utf8.RuneCountInString(input.Title) > maxReportTextChars,
		utf8.RuneCountInString(input.Album) > maxReportTextChars,
		len(input.SongID) > maxReportTextChars:
		return input, fmt.Errorf("%w: a name is too long", errBadReport)
	}
	return input, nil
}

// Add records a report, or adds the user to an open report about the same problem.
// It returns the report and whether it is new.
func (s *ReportStore) Add(user string, input ReportInput) (Report, bool, error) {
	input, err := validateReport(input)
	if err != nil {
		return Report{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Imports request many missing songs at once; the open-report cap still bounds them.
	if input.Kind != reportMissingSong && !s.allowLocked(user) {
		return Report{}, false, errTooManyReports
	}
	now := s.now().UnixMilli()
	key := reportKey(input.Kind, input.SongID, input.Artist, input.Title)
	note := func() []ReportNote {
		if input.Note == "" {
			return nil
		}
		return []ReportNote{{User: user, Text: input.Note, AtMs: now}}
	}
	if index := s.openIndexLocked(key); index >= 0 {
		updated := s.reports[index]
		if !slices.Contains(updated.Reporters, user) {
			updated.Reporters = append(slices.Clone(updated.Reporters), user)
		}
		// Repeated import retries must not grow the report indefinitely.
		if input.Note != "" && !slices.ContainsFunc(updated.Notes, func(n ReportNote) bool { return n.User == user && n.Text == input.Note }) {
			if len(updated.Notes) >= maxReportNotes {
				return Report{}, false, errTooManyReports
			}
			updated.Notes = append(slices.Clone(updated.Notes), note()...)
		}
		updated.UpdatedMs = now
		updated.Count = len(updated.Reporters)
		s.reports = slices.Clone(s.reports)
		s.reports[index] = updated
		return updated, false, s.saveLocked()
	}
	if s.openCountLocked(user) >= maxOpenReportsPerUser {
		return Report{}, false, errTooManyReports
	}
	report := Report{
		ID: newReportID(), Kind: input.Kind, SongID: input.SongID,
		Artist: input.Artist, Title: input.Title, Album: input.Album,
		Reporters: []string{user}, Count: 1, Notes: note(), Status: reportOpen,
		CreatedMs: now, UpdatedMs: now, Key: key,
	}
	s.reports = append(slices.Clone(s.reports), report)
	s.trimLocked()
	return report, true, s.saveLocked()
}

// AddAuto opens a report the server noticed itself, such as an album with no cover.
func (s *ReportStore) AddAuto(kind, ref, artist, title string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := kind + "|auto|" + ref
	if s.openIndexLocked(key) >= 0 {
		return
	}
	now := s.now().UnixMilli()
	s.reports = append(slices.Clone(s.reports), Report{
		ID: newReportID(), Kind: kind, Artist: artist, Title: title,
		Reporters: []string{autoReporter}, Count: 1, Status: reportOpen,
		Auto: true, CreatedMs: now, UpdatedMs: now, Key: key,
	})
	s.trimLocked()
	if err := s.saveLocked(); err != nil {
		log.Printf("reports: save automatic report: %v", err)
	}
}

// ResolveAuto closes an automatic report once the problem went away.
func (s *ReportStore) ResolveAuto(kind, ref string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	index := s.openIndexLocked(kind + "|auto|" + ref)
	if index < 0 {
		return
	}
	s.closeLocked(index, reportResolved, "Fixed automatically", "")
	if err := s.saveLocked(); err != nil {
		log.Printf("reports: save automatic fix: %v", err)
	}
}

// List returns everything for an admin, otherwise only the user's own reports without
// saying who else asked.
func (s *ReportStore) List(user string, isAdmin bool) []Report {
	s.mu.Lock()
	defer s.mu.Unlock()
	views := make([]Report, 0, len(s.reports))
	for i := len(s.reports) - 1; i >= 0; i-- {
		report := s.reports[i]
		report.Count = len(report.Reporters)
		if isAdmin {
			views = append(views, report)
			continue
		}
		if !slices.Contains(report.Reporters, user) {
			continue
		}
		report.Reporters = nil
		report.Notes = nil
		views = append(views, report)
	}
	return views
}

// Close resolves or dismisses a report.
func (s *ReportStore) Close(id, status, resolution, fixedSongID string) (Report, error) {
	if status != reportResolved && status != reportDismissed && status != reportOpen {
		return Report{}, fmt.Errorf("%w: unknown status", errBadReport)
	}
	if utf8.RuneCountInString(resolution) > maxReportNoteChars {
		return Report{}, fmt.Errorf("%w: the note is too long", errBadReport)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	index := s.indexLocked(id)
	if index < 0 {
		return Report{}, errNoSuchReport
	}
	s.closeLocked(index, status, strings.TrimSpace(resolution), fixedSongID)
	return s.reports[index], s.saveLocked()
}

// Get returns one report.
func (s *ReportStore) Get(id string) (Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	index := s.indexLocked(id)
	if index < 0 {
		return Report{}, errNoSuchReport
	}
	return s.reports[index], nil
}

func (s *ReportStore) closeLocked(index int, status, resolution, fixedSongID string) {
	updated := s.reports[index]
	updated.Status = status
	updated.Resolution = resolution
	updated.FixedSongID = fixedSongID
	updated.UpdatedMs = s.now().UnixMilli()
	s.reports = slices.Clone(s.reports)
	s.reports[index] = updated
}

func (s *ReportStore) indexLocked(id string) int {
	return slices.IndexFunc(s.reports, func(r Report) bool { return r.ID == id })
}

func (s *ReportStore) openIndexLocked(key string) int {
	return slices.IndexFunc(s.reports, func(r Report) bool { return r.Key == key && r.Status == reportOpen })
}

func (s *ReportStore) openCountLocked(user string) int {
	count := 0
	for _, report := range s.reports {
		if report.Status == reportOpen && slices.Contains(report.Reporters, user) {
			count++
		}
	}
	return count
}

func (s *ReportStore) allowLocked(user string) bool {
	cutoff := s.now().Add(-reportRateWindow)
	recent := slices.DeleteFunc(slices.Clone(s.recent[user]), func(at time.Time) bool { return at.Before(cutoff) })
	if len(recent) >= maxReportsPerMinute {
		s.recent[user] = recent
		return false
	}
	s.recent[user] = append(recent, s.now())
	return true
}

// trimLocked drops the oldest closed reports once there are too many.
func (s *ReportStore) trimLocked() {
	for len(s.reports) > maxStoredReports {
		index := slices.IndexFunc(s.reports, func(r Report) bool { return r.Status != reportOpen })
		if index < 0 {
			index = 0
		}
		s.reports = slices.Delete(slices.Clone(s.reports), index, index+1)
	}
}

func (s *ReportStore) saveLocked() error {
	data, err := json.Marshal(s.reports)
	if err != nil {
		return err
	}
	path := filepath.Join(s.dir, reportsFile)
	temp := path + ".tmp"
	if err := os.WriteFile(temp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

func newReportID() string {
	buf := make([]byte, reportIDBytes)
	_, _ = rand.Read(buf)
	return hex.EncodeToString(buf)
}

// ------- HTTP -------

func (s *Server) reportsUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	if s.Reports == nil || s.isReplica() {
		writeError(w, http.StatusServiceUnavailable, "reports aren't available on this server")
		return "", false
	}
	return s.authenticate(w, r)
}

func (s *Server) handleAddReport(w http.ResponseWriter, r *http.Request) {
	user, ok := s.reportsUser(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxReportRequestBytes)
	var input ReportInput
	if !decodeBody(w, r, &input) {
		return
	}
	report, isNew, err := s.Reports.Add(user, input)
	if !s.writeReportError(w, err) {
		return
	}
	report.Reporters, report.Notes = nil, nil
	status := http.StatusOK
	if isNew {
		status = http.StatusCreated
	}
	writeJSON(w, status, report)
}

func (s *Server) handleListReports(w http.ResponseWriter, r *http.Request) {
	user, ok := s.reportsUser(w, r)
	if !ok {
		return
	}
	isAdmin := s.isAdmin(r.Context(), r.URL.Query())
	writeJSON(w, http.StatusOK, map[string]any{
		"reports": s.Reports.List(user, isAdmin),
		"isAdmin": isAdmin,
	})
}

func (s *Server) handleCloseReport(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.reportsUser(w, r); !ok {
		return
	}
	if !s.isAdmin(r.Context(), r.URL.Query()) {
		writeError(w, http.StatusForbidden, "only the server admin can close reports")
		return
	}
	var body struct {
		Status     string `json:"status"`
		Resolution string `json:"resolution"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	report, err := s.Reports.Close(r.PathValue("id"), body.Status, body.Resolution, "")
	if !s.writeReportError(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, report)
}

// handleReportAdded lets anyone say a missing song is now in the library.
func (s *Server) handleReportAdded(w http.ResponseWriter, r *http.Request) {
	user, ok := s.reportsUser(w, r)
	if !ok {
		return
	}
	var body struct {
		SongID string `json:"songId"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	id := r.PathValue("id")
	report, err := s.Reports.Get(id)
	if !s.writeReportError(w, err) {
		return
	}
	if report.Kind != reportMissingSong {
		s.writeReportError(w, errWrongReportKind)
		return
	}
	if report.Status != reportOpen {
		s.writeReportError(w, errReportNotOpen)
		return
	}
	songID := strings.TrimSpace(body.SongID)
	if songID == "" || s.SongPath == nil {
		writeError(w, http.StatusBadRequest, "a song in the library is needed")
		return
	}
	if _, err := s.SongPath(r.Context(), r.URL.Query(), songID); err != nil {
		writeError(w, http.StatusBadRequest, "that song isn't in the library")
		return
	}
	report, err = s.Reports.Close(id, reportResolved, "Added by "+user, songID)
	if !s.writeReportError(w, err) {
		return
	}
	report.Reporters, report.Notes = nil, nil
	writeJSON(w, http.StatusOK, report)
}

// writeReportError reports err to the app and returns whether there was none.
func (s *Server) writeReportError(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return true
	case errors.Is(err, errBadReport):
		writeError(w, http.StatusBadRequest, strings.TrimPrefix(err.Error(), errBadReport.Error()+": "))
	case errors.Is(err, errTooManyReports):
		writeError(w, http.StatusTooManyRequests, "that's a lot of reports; try again later")
	case errors.Is(err, errNoSuchReport):
		writeError(w, http.StatusNotFound, "that report doesn't exist")
	case errors.Is(err, errReportNotOpen):
		writeError(w, http.StatusConflict, "that report is already closed")
	case errors.Is(err, errWrongReportKind):
		writeError(w, http.StatusBadRequest, "that can't be done for this kind of report")
	default:
		log.Printf("reports: %v", err)
		writeError(w, http.StatusInternalServerError, "could not save the report")
	}
	return false
}
