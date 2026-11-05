package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestImportsRoundTripPerUser(t *testing.T) {
	ts, _ := historyServer(t, Config{})
	body := `{"id":"abc","name":"Road trip","entries":[{"title":"One","artist":"A"}]}`
	status, _ := historyCall(t, ts, http.MethodPut, "/v1/imports/abc", "alice", body)
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	status, reply := historyCall(t, ts, http.MethodGet, "/v1/imports", "alice", "")
	if status != http.StatusOK || !strings.Contains(reply, "Road trip") {
		t.Fatalf("status %d reply %s", status, reply)
	}
	var list struct {
		Imports []json.RawMessage `json:"imports"`
	}
	if err := json.Unmarshal([]byte(reply), &list); err != nil || len(list.Imports) != 1 {
		t.Fatalf("list %s err %v", reply, err)
	}
	_, reply = historyCall(t, ts, http.MethodGet, "/v1/imports", "bob", "")
	if strings.Contains(reply, "Road trip") {
		t.Fatal("another user could read it")
	}
	status, _ = historyCall(t, ts, http.MethodDelete, "/v1/imports/abc", "alice", "")
	if status != http.StatusOK {
		t.Fatalf("delete status %d", status)
	}
	_, reply = historyCall(t, ts, http.MethodGet, "/v1/imports", "alice", "")
	if strings.Contains(reply, "Road trip") {
		t.Fatal("still there after delete")
	}
}

func TestImportsRejectBadInput(t *testing.T) {
	ts, _ := historyServer(t, Config{})
	cases := []struct {
		path, body string
		want       int
	}{
		{"/v1/imports/abc", `{not json`, http.StatusBadRequest},
		{"/v1/imports/" + strings.Repeat("x", importMaxIDLength+1), `{}`, http.StatusBadRequest},
		{"/v1/imports/..%2F..%2Fetc", `{}`, http.StatusBadRequest},
		{"/v1/imports/a.b", `{}`, http.StatusBadRequest},
	}
	for _, tc := range cases {
		status, _ := historyCall(t, ts, http.MethodPut, tc.path, "alice", tc.body)
		if status != tc.want {
			t.Errorf("%s: status %d", tc.path, status)
		}
	}
}

func TestImportsAreReadOnlyOnAReplica(t *testing.T) {
	ts, _ := historyServer(t, Config{Role: roleReplica})
	status, _ := historyCall(t, ts, http.MethodPut, "/v1/imports/abc", "alice", `{}`)
	if status != http.StatusServiceUnavailable {
		t.Fatalf("status %d", status)
	}
	status, _ = historyCall(t, ts, http.MethodGet, "/v1/imports", "alice", "")
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
}
