package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// The poster sends the newest of each result, lists never null, and keeps
// every result in its file; the site down for a while loses nothing.
func TestPosterSendsTheNewestOfEachResult(t *testing.T) {
	var mutex sync.Mutex
	got := map[string]map[string]any{}
	failures := 2
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mutex.Lock()
		defer mutex.Unlock()
		if failures > 0 {
			failures--
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if body["rounds"] == nil || body["open_loop"] == nil {
			t.Errorf("a null list: %v", body)
		}
		got[body["competitor"].(string)] = body
		w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()
	site, _ := instantClient(server.URL)
	file := filepath.Join(t.TempDir(), "results.json")
	poster := newPoster(context.Background(), site, WorkerConfig{RunID: "r", Results: file})
	result := Result{Class: "c", Workload: "w", Competitor: "go", Valid: true}
	poster.send(result)
	result.Rounds = append(result.Rounds, Round{RPS: 100})
	poster.send(result)
	poster.send(Result{Class: "c", Workload: "w", Competitor: "roux", Note: "did not start"})
	if err := poster.close(); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("posted %v", got)
	}
	var kept []Result
	bytes, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(bytes, &kept); err != nil || len(kept) != 2 {
		t.Fatalf("kept %v %v", kept, err)
	}
	for _, result := range kept {
		if result.Competitor == "go" && (len(result.Rounds) != 1 || result.MedianRPS != 100) {
			t.Fatalf("the newest go result was not kept: %+v", result)
		}
	}
}
