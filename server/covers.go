package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg" // Registers the decoder used to validate downloads.
	_ "image/png"  // Some sources serve PNG under a .jpg name.
	"io"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/dhowden/tag"
)

const (
	coverFileName    = "cover.jpg"
	maxCoverBytes    = 8 << 20
	minCoverPixels   = 200
	coverUserAgent   = "Yomi/1.0 (https://github.com/ginnfx/yomi)"
	coverSweepEvery  = 6 * time.Hour
	firstRetryAfter  = 24 * time.Hour
	longestRetry     = 30 * 24 * time.Hour
	itunesSpacing    = 3 * time.Second
	musicbrainzEvery = 1100 * time.Millisecond
	itunesArtSize    = "600x600bb"
	searchResults    = 10
)

var (
	errNoCoverMatch  = errors.New("no confident match")
	itunesSizeSuffix = regexp.MustCompile(`\d+x\d+bb`)
)

// CoverFetcher fills in missing album art. A wrong cover is worse than none, so it only
// accepts exact artist and album matches and backs off on anything it can't find.
type CoverFetcher struct {
	Root            string
	StateFile       string
	Client          *http.Client
	ITunesURL       string
	MusicBrainzURL  string
	CoverArtURL     string
	ITunesSpacing   time.Duration
	MusicBrainzWait time.Duration
	Now             func() time.Time
	Sleep           func(time.Duration)

	mu     sync.Mutex
	misses map[string]coverMiss
	// OnMiss and OnFound, when set, hear about albums still without art and albums
	// that got some, so they can show up as needed fixes.
	OnMiss     func(dir, artist, album string)
	OnFound    func(dir string)
	lastITunes time.Time
	lastMB     time.Time
}

type coverMiss struct {
	Count int       `json:"count"`
	Next  time.Time `json:"next"`
}

func newCoverFetcher(root, stateFile string, client *http.Client) *CoverFetcher {
	return &CoverFetcher{
		Root:            root,
		StateFile:       stateFile,
		Client:          client,
		ITunesURL:       "https://itunes.apple.com/search",
		MusicBrainzURL:  "https://musicbrainz.org/ws/2/release/",
		CoverArtURL:     "https://coverartarchive.org/release/",
		ITunesSpacing:   itunesSpacing,
		MusicBrainzWait: musicbrainzEvery,
		Now:             time.Now,
		Sleep:           time.Sleep,
	}
}

// Run sweeps the library forever, starting after the index has had a chance to seed.
func (f *CoverFetcher) Run(ctx context.Context) {
	for {
		found, err := f.Sweep(ctx)
		if err != nil {
			log.Printf("covers: sweep stopped: %v", err)
		} else if found > 0 {
			log.Printf("covers: added %d", found)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(coverSweepEvery):
		}
	}
}

// albumFolder is one folder of songs that can safely share a single cover.
type albumFolder struct {
	dir    string
	artist string
	album  string
}

// Sweep looks for art for every eligible album, one at a time, and returns how many
// covers it added.
func (f *CoverFetcher) Sweep(ctx context.Context) (int, error) {
	f.loadMisses()
	albums, err := f.findAlbumsMissingArt()
	if err != nil {
		return 0, err
	}
	added := 0
	for _, album := range albums {
		if err := ctx.Err(); err != nil {
			return added, err
		}
		if !f.isDue(album) {
			continue
		}
		err := f.fetchFor(ctx, album)
		switch {
		case err == nil:
			added++
			f.clearMiss(album)
		case errors.Is(err, errNoCoverMatch):
			f.recordMiss(album)
		default:
			// A network failure says nothing about the album, so it stays due.
			log.Printf("covers: %s: %v", album.dir, err)
		}
	}
	return added, nil
}

// findAlbumsMissingArt only returns folders holding exactly one album, because Navidrome
// applies cover.jpg to everything in a folder. Older uploads in a flat user folder are
// left alone for the same reason.
func (f *CoverFetcher) findAlbumsMissingArt() ([]albumFolder, error) {
	songsByDir := make(map[string][]string)
	hasCover := make(map[string]bool)
	err := filepath.WalkDir(f.Root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			log.Printf("covers: skipping %s: %v", path, err)
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		dir := filepath.Dir(path)
		switch name := strings.ToLower(entry.Name()); {
		case name == coverFileName, name == "cover.png", name == "folder.jpg", name == "front.jpg":
			hasCover[dir] = true
		case allowedExt[filepath.Ext(name)]:
			songsByDir[dir] = append(songsByDir[dir], path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	var albums []albumFolder
	for dir, songs := range songsByDir {
		if hasCover[dir] {
			continue
		}
		if album, ok := inspectAlbumFolder(dir, songs); ok {
			albums = append(albums, album)
		}
	}
	return albums, nil
}

// inspectAlbumFolder needs every song to agree on the album and none to carry its own art.
func inspectAlbumFolder(dir string, songs []string) (albumFolder, bool) {
	album := albumFolder{dir: dir}
	for _, song := range songs {
		tags, ok := readSongTags(song)
		if !ok || tags.album == "" || tags.artist == "" || tags.hasArt {
			return albumFolder{}, false
		}
		if album.album == "" {
			album.album, album.artist = tags.album, tags.artist
		} else if normalizeForMatch(album.album) != normalizeForMatch(tags.album) {
			return albumFolder{}, false
		}
	}
	return album, album.album != ""
}

type songTags struct {
	artist string
	album  string
	hasArt bool
}

func readSongTags(path string) (result songTags, ok bool) {
	defer func() {
		if recovered := recover(); recovered != nil {
			log.Printf("covers: could not parse %s: %v", path, recovered)
			result, ok = songTags{}, false
		}
	}()
	file, err := os.Open(path)
	if err != nil {
		return songTags{}, false
	}
	defer file.Close()
	metadata, err := tag.ReadFrom(file)
	if err != nil {
		return songTags{}, false
	}
	artist := metadata.AlbumArtist()
	if strings.TrimSpace(artist) == "" {
		artist = metadata.Artist()
	}
	return songTags{
		artist: strings.TrimSpace(artist),
		album:  strings.TrimSpace(metadata.Album()),
		hasArt: metadata.Picture() != nil,
	}, true
}

func (f *CoverFetcher) fetchFor(ctx context.Context, album albumFolder) error {
	art, err := f.searchITunes(ctx, album)
	if errors.Is(err, errNoCoverMatch) {
		art, err = f.searchMusicBrainz(ctx, album)
	}
	if err != nil {
		return err
	}
	return writeCover(album.dir, art)
}

func (f *CoverFetcher) searchITunes(ctx context.Context, album albumFolder) ([]byte, error) {
	query := url.Values{
		"term":   {album.artist + " " + album.album},
		"entity": {"album"},
		"limit":  {fmt.Sprint(searchResults)},
	}
	f.waitTurn(&f.lastITunes, f.ITunesSpacing)
	var body struct {
		Results []struct {
			ArtistName     string `json:"artistName"`
			CollectionName string `json:"collectionName"`
			ArtworkURL100  string `json:"artworkUrl100"`
		} `json:"results"`
	}
	if err := f.getJSON(ctx, f.ITunesURL+"?"+query.Encode(), &body); err != nil {
		return nil, err
	}
	for _, result := range body.Results {
		if !isSameName(result.ArtistName, album.artist) || !isSameName(result.CollectionName, album.album) {
			continue
		}
		if result.ArtworkURL100 == "" {
			continue
		}
		return f.download(ctx, itunesSizeSuffix.ReplaceAllString(result.ArtworkURL100, itunesArtSize))
	}
	return nil, errNoCoverMatch
}

func (f *CoverFetcher) searchMusicBrainz(ctx context.Context, album albumFolder) ([]byte, error) {
	lucene := fmt.Sprintf(`release:"%s" AND artist:"%s"`, escapeLucene(album.album), escapeLucene(album.artist))
	query := url.Values{"query": {lucene}, "fmt": {"json"}, "limit": {fmt.Sprint(searchResults)}}
	f.waitTurn(&f.lastMB, f.MusicBrainzWait)
	var body struct {
		Releases []struct {
			ID           string `json:"id"`
			Title        string `json:"title"`
			ArtistCredit []struct {
				Name string `json:"name"`
			} `json:"artist-credit"`
		} `json:"releases"`
	}
	if err := f.getJSON(ctx, f.MusicBrainzURL+"?"+query.Encode(), &body); err != nil {
		return nil, err
	}
	for _, release := range body.Releases {
		if !isSameName(release.Title, album.album) || len(release.ArtistCredit) == 0 ||
			!isSameName(release.ArtistCredit[0].Name, album.artist) {
			continue
		}
		f.waitTurn(&f.lastMB, f.MusicBrainzWait)
		art, err := f.download(ctx, f.CoverArtURL+url.PathEscape(release.ID)+"/front-500")
		if errors.Is(err, errNoCoverMatch) {
			continue // This pressing has no art; another of the same album might.
		}
		return art, err
	}
	return nil, errNoCoverMatch
}

// waitTurn spaces out requests to one service, as its usage rules require.
func (f *CoverFetcher) waitTurn(last *time.Time, spacing time.Duration) {
	if wait := spacing - f.Now().Sub(*last); !last.IsZero() && wait > 0 {
		f.Sleep(wait)
	}
	*last = f.Now()
}

func (f *CoverFetcher) getJSON(ctx context.Context, target string, into any) error {
	response, err := f.get(ctx, target)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("lookup answered %d", response.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(response.Body, maxCoverBytes)).Decode(into)
}

func (f *CoverFetcher) get(ctx context.Context, target string) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", coverUserAgent)
	return f.Client.Do(request)
}

// download returns validated image bytes. A missing image counts as no match; other
// failures are reported so the album stays due for another try.
func (f *CoverFetcher) download(ctx context.Context, target string) ([]byte, error) {
	response, err := f.get(ctx, target)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound {
		return nil, errNoCoverMatch
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("image answered %d", response.StatusCode)
	}
	art, err := io.ReadAll(io.LimitReader(response.Body, maxCoverBytes+1))
	if err != nil {
		return nil, err
	}
	if len(art) > maxCoverBytes {
		return nil, errNoCoverMatch
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(art))
	if err != nil || config.Width < minCoverPixels || config.Height < minCoverPixels {
		return nil, errNoCoverMatch
	}
	return art, nil
}

func writeCover(dir string, art []byte) error {
	temp, err := os.CreateTemp(dir, tempFilePrefix+"*"+tempFileSuffix)
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err := temp.Write(art); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(temp.Name(), 0o666); err != nil && !errors.Is(err, fs.ErrPermission) {
		log.Printf("covers: chmod: %v", err)
	}
	return os.Rename(temp.Name(), filepath.Join(dir, coverFileName))
}

// normalizeForMatch keeps letters and digits only, so punctuation and case can't block
// a match, but "Abbey Road" still never equals "Abbey Road (Remastered)".
func normalizeForMatch(value string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, value)
}

func isSameName(a, b string) bool {
	normalized := normalizeForMatch(a)
	return normalized != "" && normalized == normalizeForMatch(b)
}

func escapeLucene(value string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(value)
}

func (f *CoverFetcher) isDue(album albumFolder) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	miss, known := f.misses[album.dir]
	return !known || !f.Now().Before(miss.Next)
}

// recordMiss doubles the wait each time, from a day up to a month.
func (f *CoverFetcher) recordMiss(album albumFolder) {
	if f.OnMiss != nil {
		f.OnMiss(album.dir, album.artist, album.album)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	miss := f.misses[album.dir]
	wait := firstRetryAfter
	for range miss.Count {
		wait *= 2
		if wait >= longestRetry {
			wait = longestRetry
			break
		}
	}
	f.misses[album.dir] = coverMiss{Count: miss.Count + 1, Next: f.Now().Add(wait)}
	f.saveMissesLocked()
}

func (f *CoverFetcher) clearMiss(album albumFolder) {
	if f.OnFound != nil {
		f.OnFound(album.dir)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, known := f.misses[album.dir]; known {
		delete(f.misses, album.dir)
		f.saveMissesLocked()
	}
}

func (f *CoverFetcher) loadMisses() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.misses = make(map[string]coverMiss)
	data, err := os.ReadFile(f.StateFile)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil {
		log.Printf("covers: reading state: %v", err)
		return
	}
	if err := json.Unmarshal(data, &f.misses); err != nil {
		log.Printf("covers: ignoring damaged state: %v", err)
		f.misses = make(map[string]coverMiss)
	}
}

func (f *CoverFetcher) saveMissesLocked() {
	data, err := json.Marshal(f.misses)
	if err != nil {
		log.Printf("covers: encoding state: %v", err)
		return
	}
	temp := f.StateFile + ".tmp"
	if err := os.WriteFile(temp, data, 0o666); err != nil {
		log.Printf("covers: saving state: %v", err)
		return
	}
	if err := os.Rename(temp, f.StateFile); err != nil {
		log.Printf("covers: saving state: %v", err)
	}
}
