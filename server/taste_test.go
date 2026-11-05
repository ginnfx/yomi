package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func profileOf(t *testing.T, env socialEnv, viewer, user string) Profile {
	t.Helper()
	status, body := env.call(t, http.MethodGet, "/v1/profiles", viewer, nil)
	if status != http.StatusOK {
		t.Fatalf("profiles: status %d", status)
	}
	var got struct {
		Profiles []Profile `json:"profiles"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	for _, profile := range got.Profiles {
		if profile.User == user {
			return profile
		}
	}
	t.Fatalf("no profile for %s", user)
	return Profile{}
}

func TestFriendsSeeEachOthersTaste(t *testing.T) {
	env := newSocialEnv(t, Config{})
	status, _ := env.call(t, http.MethodPut, "/v1/profile/taste", "keli",
		map[string]any{"topArtists": []string{"Nujabes", "Yoko Shimomura"}, "topMoods": []string{"calm", "nonsense"}})
	if status != http.StatusOK {
		t.Fatalf("save taste: status %d", status)
	}
	taste := profileOf(t, env, "sam", "keli").Taste
	if taste == nil || len(taste.TopArtists) != 2 || taste.TopArtists[0] != "Nujabes" {
		t.Fatalf("taste %+v", taste)
	}
	if len(taste.TopMoods) != 1 || taste.TopMoods[0] != "calm" {
		t.Fatalf("moods %v", taste.TopMoods)
	}
	if taste.UpdatedMs == 0 {
		t.Fatal("no time saved")
	}
}

func TestSavingTheProfileKeepsTheTaste(t *testing.T) {
	env := newSocialEnv(t, Config{})
	env.call(t, http.MethodPut, "/v1/profile/taste", "keli", map[string]any{"topArtists": []string{"Adele"}})
	env.call(t, http.MethodPut, "/v1/profile", "keli", map[string]any{"displayName": "Keli", "bio": "hi"})
	profile := profileOf(t, env, "sam", "keli")
	if profile.DisplayName != "Keli" || profile.Taste == nil || profile.Taste.TopArtists[0] != "Adele" {
		t.Fatalf("profile %+v", profile)
	}
}

func TestSharingNothingClearsTheTaste(t *testing.T) {
	env := newSocialEnv(t, Config{})
	env.call(t, http.MethodPut, "/v1/profile/taste", "keli", map[string]any{"topArtists": []string{"Adele"}})
	env.call(t, http.MethodPut, "/v1/profile/taste", "keli", map[string]any{"topArtists": []string{}})
	if taste := profileOf(t, env, "sam", "keli").Taste; taste != nil {
		t.Fatalf("still shared: %+v", taste)
	}
}

func TestTasteRejectsTooMuch(t *testing.T) {
	env := newSocialEnv(t, Config{})
	many := make([]string, tasteMaxArtists+1)
	for i := range many {
		many[i] = "a"
	}
	for _, body := range []map[string]any{
		{"topArtists": many},
		{"topArtists": []string{strings.Repeat("x", maxNameChars*3)}},
	} {
		if status, _ := env.call(t, http.MethodPut, "/v1/profile/taste", "keli", body); status != http.StatusBadRequest {
			t.Fatalf("status %d for %v", status, body)
		}
	}
}

func TestTasteSurvivesARestart(t *testing.T) {
	env := newSocialEnv(t, Config{})
	env.call(t, http.MethodPut, "/v1/profile/taste", "keli", map[string]any{"topArtists": []string{"Adele"}})
	reopened, err := openMessageStore(env.store.dir, env.store.now)
	if err != nil {
		t.Fatal(err)
	}
	for _, profile := range reopened.Profiles() {
		if profile.User == "keli" && (profile.Taste == nil || profile.Taste.TopArtists[0] != "Adele") {
			t.Fatalf("lost: %+v", profile)
		}
	}
}
