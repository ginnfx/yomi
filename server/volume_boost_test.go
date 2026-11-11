package main

import (
	"context"
	"encoding/binary"
	"math"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Exercise the actual ffmpeg filter and HTTP result, rather than just its args.
func TestVolumeBoostAddsRealGainAndKeepsOriginal(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	root := t.TempDir()
	original := filepath.Join(root, "quiet.wav")
	if out, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-af", "volume=0.1", original).CombinedOutput(); err != nil {
		t.Fatalf("fixture: %v %s", err, out)
	}
	before, _ := os.ReadFile(original)
	server := newServer(Config{MusicDir: root}, fakeAuth{}, nil, nil)
	server.SongPath = func(context.Context, url.Values, string) (string, error) { return "quiet.wav", nil }
	request := httptest.NewRequest("GET", "/v1/audio/boost/song?u=listener&p=good&gain=6", nil)
	response := httptest.NewRecorder()
	server.routes().ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("boost status %d: %s", response.Code, response.Body.String())
	}
	boosted := filepath.Join(root, "boosted.mp3")
	os.WriteFile(boosted, response.Body.Bytes(), 0600)
	rms := func(path string) (float64, int) {
		t.Helper()
		pcm, err := exec.Command(ffmpeg, "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", "44100", "-").Output()
		if err != nil {
			t.Fatal(err)
		}
		sum := 0.0
		for i := 0; i+1 < len(pcm); i += 2 {
			sample := float64(int16(binary.LittleEndian.Uint16(pcm[i:])))
			sum += sample * sample
		}
		return math.Sqrt(sum / float64(len(pcm)/2)), len(pcm) / 2
	}
	quietRMS, quietLength := rms(original)
	loudRMS, loudLength := rms(boosted)
	if loudRMS/quietRMS < 1.8 || loudRMS/quietRMS > 2.2 {
		t.Fatalf("expected ~2x amplitude, got %.2fx", loudRMS/quietRMS)
	}
	if math.Abs(float64(quietLength-loudLength)) > 1000 {
		t.Fatalf("duration changed: %d -> %d samples", quietLength, loudLength)
	}
	after, _ := os.ReadFile(original)
	if string(before) != string(after) {
		t.Fatal("original audio changed")
	}
}

func TestVolumeBoostRejectsUnauthenticatedRequests(t *testing.T) {
	server := newServer(Config{}, fakeAuth{}, nil, nil)
	request := httptest.NewRequest("GET", "/v1/audio/boost/song?gain=6", nil)
	response := httptest.NewRecorder()
	server.routes().ServeHTTP(response, request)
	if response.Code == 200 {
		t.Fatal("unauthenticated boost allowed")
	}
}
