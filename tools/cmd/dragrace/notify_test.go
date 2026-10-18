package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ntfyStandIn records what was posted to it.
type ntfyStandIn struct {
	paths, titles, priorities, bodies []string
}

func (stand *ntfyStandIn) server(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		stand.paths = append(stand.paths, r.URL.Path)
		stand.titles = append(stand.titles, r.Header.Get("Title"))
		stand.priorities = append(stand.priorities, r.Header.Get("Priority"))
		stand.bodies = append(stand.bodies, string(body))
		w.Write([]byte(`{"id":"x"}`))
	}))
	t.Cleanup(server.Close)
	return server
}

var abort = siteFailure{Unit: "dragrace-site.service", Result: "core-dump", Code: "dumped",
	Status: "ABRT", Restarts: "3"}

func TestNotifySendsThenKeepsQuiet(t *testing.T) {
	stand := &ntfyStandIn{}
	server := stand.server(t)
	clock := time.Date(2026, 10, 18, 4, 0, 0, 0, time.UTC)
	alert := notifier{server: server.URL + "/", topic: "dragrace-crash-abc", state: t.TempDir(),
		now: func() time.Time { return clock }, client: server.Client()}
	ctx := context.Background()
	if err := alert.send(ctx, abort); err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(notifyQuiet - time.Second)
	if err := alert.send(ctx, abort); err != nil {
		t.Fatal(err)
	}
	if len(stand.paths) != 1 {
		t.Fatalf("%d alerts within the quiet time, want 1", len(stand.paths))
	}
	clock = clock.Add(time.Second)
	if err := alert.send(ctx, abort); err != nil {
		t.Fatal(err)
	}
	if len(stand.paths) != 2 {
		t.Fatalf("%d alerts after the quiet time, want 2", len(stand.paths))
	}
	if stand.paths[0] != "/dragrace-crash-abc" || stand.priorities[0] != "5" ||
		stand.titles[0] != "dragrace site crashed" {
		t.Fatalf("posted %q, priority %q, title %q", stand.paths[0], stand.priorities[0],
			stand.titles[0])
	}
	want := "dragrace-site.service: core-dump (dumped ABRT); restarted 3 times"
	if !strings.HasPrefix(stand.bodies[0], want) {
		t.Fatalf("body %q, want it to start %q", stand.bodies[0], want)
	}
}

func TestNotifyRefusedIsAnErrorAndNotQuiet(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "limit reached", http.StatusTooManyRequests)
	}))
	defer server.Close()
	state := t.TempDir()
	alert := notifier{server: server.URL + "/", topic: "secret-topic", state: state,
		now: time.Now, client: server.Client()}
	err := alert.send(context.Background(), abort)
	if err == nil || strings.Contains(err.Error(), "secret-topic") {
		t.Fatalf("err %v: want an error that does not show the topic", err)
	}
	if _, err := os.Stat(filepath.Join(state, "last-sent")); err == nil {
		t.Fatal("a refused alert started the quiet time")
	}
}

func TestFailureMessageSaysFailedForAnExit(t *testing.T) {
	title, body := failureMessage(siteFailure{Unit: "dragrace-site.service",
		Result: "exit-code", Code: "exited", Status: "1", Restarts: "0"})
	if title != "dragrace site failed" {
		t.Fatalf("title %q", title)
	}
	if !strings.Contains(body, "exit-code (exited 1)") ||
		!strings.Contains(body, "journalctl -u dragrace-site.service") {
		t.Fatalf("body %q", body)
	}
}

func TestReadTopicChecksTheGrammarAndHidesIt(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good")
	os.WriteFile(good, []byte("dragrace-crash-0123abcd\n"), 0o600)
	if topic, err := readTopic(good); err != nil || topic != "dragrace-crash-0123abcd" {
		t.Fatalf("topic %q, err %v", topic, err)
	}
	bad := filepath.Join(dir, "bad")
	os.WriteFile(bad, []byte("not/a topic\n"), 0o600)
	if _, err := readTopic(bad); err == nil || strings.Contains(err.Error(), "not/a") {
		t.Fatalf("err %v: want a refusal that does not show the topic", err)
	}
}
