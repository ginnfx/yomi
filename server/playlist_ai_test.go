package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestMixNamesGivesOneNamePerMix(t *testing.T) {
	ai := &fakeAI{replies: []string{`{"names":[{"name":"Rainy JRPG Evenings","description":"Soft game music."},{"name":"` + strings.Repeat("x", 200) + `"}]}`}}
	ts, _ := aiServer(t, ai)
	resp, body := aiCall(t, ts, http.MethodPost, "/v1/ai/names",
		`{"mixes":[{"moods":["calm","sad"],"artists":["Yoko Shimomura"]},{"moods":["party"],"artists":["Future"]},{"moods":["dreamy"],"artists":[]}]}`, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d body %s", resp.StatusCode, body)
	}
	var got struct {
		Names []MixName `json:"names"`
	}
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Names) != 3 {
		t.Fatalf("names %+v", got.Names)
	}
	if got.Names[0].Name != "Rainy JRPG Evenings" {
		t.Fatalf("first %+v", got.Names[0])
	}
	if len([]rune(got.Names[1].Name)) > mixNameMaxChars || got.Names[1].Name == "" {
		t.Fatalf("second name not trimmed to size: %q", got.Names[1].Name)
	}
	if got.Names[2].Name == "" {
		t.Fatal("a missing name should get a plain one")
	}
}

func TestMixNamesCheckInputAndNeedAI(t *testing.T) {
	ts, _ := aiServer(t, nil)
	resp, _ := aiCall(t, ts, http.MethodPost, "/v1/ai/names", `{"mixes":[{"moods":["calm"]}]}`, nil)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("without AI: status %d", resp.StatusCode)
	}
	ai := &fakeAI{}
	ts, _ = aiServer(t, ai)
	tooMany := `{"mixes":[` + strings.TrimSuffix(strings.Repeat(`{"moods":["calm"]},`, mixMaxCount+1), ",") + `]}`
	resp, _ = aiCall(t, ts, http.MethodPost, "/v1/ai/names", tooMany, nil)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("too many mixes: status %d", resp.StatusCode)
	}
	if ai.requestCount() != 0 {
		t.Fatal("bad input reached the AI")
	}
}
