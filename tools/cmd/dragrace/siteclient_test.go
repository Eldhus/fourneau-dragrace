package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// A site that answers each attempt with the next status of a script.
func scriptedSite(t *testing.T, statuses ...int) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer secret" {
			t.Errorf("token %q", r.Header.Get("Authorization"))
		}
		n := int(calls.Add(1)) - 1
		status := statuses[min(n, len(statuses)-1)]
		w.WriteHeader(status)
		w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(server.Close)
	return server, &calls
}

func instantClient(base string) (*SiteClient, *[]time.Duration) {
	site := newSiteClient(base, "secret")
	var waits []time.Duration
	site.sleep = func(_ context.Context, wait time.Duration) error {
		waits = append(waits, wait)
		return nil
	}
	return site, &waits
}

func TestSiteClientRetriesThroughADeploy(t *testing.T) {
	server, calls := scriptedSite(t, 502, 503, 500, 200)
	site, waits := instantClient(server.URL)
	var answer struct{ OK bool }
	if err := site.post(context.Background(), "/api/x", map[string]int{"a": 1}, &answer); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 4 || !answer.OK {
		t.Fatalf("%d calls, answer %v", calls.Load(), answer)
	}
	if want := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second}; len(*waits) != 3 ||
		(*waits)[0] != want[0] || (*waits)[2] != want[2] {
		t.Fatalf("waits %v, want %v", *waits, want)
	}
}

func TestSiteClientNeverRetriesARefusal(t *testing.T) {
	server, calls := scriptedSite(t, 409, 200)
	site, _ := instantClient(server.URL)
	err := site.post(context.Background(), "/api/x", nil, nil)
	if !errors.Is(err, errSiteRefused) || calls.Load() != 1 {
		t.Fatalf("%v after %d calls", err, calls.Load())
	}
}

func TestSiteClientGivesUpAfterItsWindow(t *testing.T) {
	server, calls := scriptedSite(t, 503)
	site, _ := instantClient(server.URL)
	// Real waits, a window of milliseconds.
	start := time.Now()
	site.window = 30 * time.Millisecond
	site.first, site.most = 5*time.Millisecond, 10*time.Millisecond
	site.sleep = func(_ context.Context, wait time.Duration) error { time.Sleep(wait); return nil }
	err := site.post(context.Background(), "/api/x", nil, nil)
	if err == nil || errors.Is(err, errSiteRefused) {
		t.Fatalf("%v", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second || calls.Load() < 3 {
		t.Fatalf("gave up after %s and %d calls", elapsed, calls.Load())
	}
}

func TestSiteClientRetriesASiteThatIsDown(t *testing.T) {
	server, _ := scriptedSite(t, 200)
	address := server.URL
	server.Close() // nothing listens: connection refused
	site, waits := instantClient(address)
	site.window = 10 * time.Second
	err := site.get(context.Background(), "/api/health", nil)
	if err == nil || len(*waits) < 3 {
		t.Fatalf("%v after %d waits", err, len(*waits))
	}
}
