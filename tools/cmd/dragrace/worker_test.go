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

// The step begun is posted after the results before it, the newest only;
// a site that refuses it (one older than the worker) fails nothing.
func TestPosterSendsTheStepAfterTheResults(t *testing.T) {
	var mutex sync.Mutex
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mutex.Lock()
		defer mutex.Unlock()
		paths = append(paths, r.URL.Path)
		if r.URL.Path == "/api/runs/r/classes/c/steps" {
			http.Error(w, "no such API route", http.StatusNotFound)
			return
		}
		w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()
	site, _ := instantClient(server.URL)
	file := filepath.Join(t.TempDir(), "results.json")
	config := WorkerConfig{RunID: "r", Class: ServerClass{Name: "c"}, Results: file}
	// Not started: what is queued before the loop runs is what it sees.
	poster := &Poster{site: site, config: config, latest: map[string]Result{},
		pending: map[string]bool{}, wake: make(chan struct{}, 1), done: make(chan struct{})}
	plan := []Step{{Competitor: "go", Round: 1}, {Competitor: "roux", Round: 1}}
	poster.begin(plan, 0)
	poster.send(Result{Class: "c", Workload: "w", Competitor: "go", Valid: true})
	poster.begin(plan, 1)
	go poster.loop(context.Background())
	if err := poster.close(); err != nil {
		t.Fatal(err)
	}
	want := []string{"/api/runs/r/results", "/api/runs/r/classes/c/steps"}
	if len(paths) != len(want) || paths[0] != want[0] || paths[1] != want[1] {
		t.Fatalf("posted %v", paths)
	}
}

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
		if result.Competitor == "go" && (len(result.Rounds) != 1 || result.BestRPS != 100) {
			t.Fatalf("the newest go result was not kept: %+v", result)
		}
	}
}
