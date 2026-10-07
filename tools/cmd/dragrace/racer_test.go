package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCommitsSayWhichAreNew(t *testing.T) {
	heads := map[string]string{"fourneau-dragrace": "a", "fourneau": "b", "roux": "c"}
	commits, anyNew := commitsPost(heads, map[string]string{"fourneau-dragrace": "a",
		"fourneau": "b", "roux": "old"})
	if !anyNew || len(commits) != 3 || commits[0].New || commits[1].New || !commits[2].New {
		t.Fatalf("%v %v", commits, anyNew)
	}
	if _, anyNew := commitsPost(heads, heads); anyNew {
		t.Fatal("the same heads are new")
	}
	// Before the first finished run everything is new.
	if _, anyNew := commitsPost(heads, map[string]string{}); !anyNew {
		t.Fatal("nothing raced yet, and nothing new")
	}
}

func TestBuildsAreReleasesWithABuildJSON(t *testing.T) {
	info := BuildInfo{Commits: map[string]string{"fourneau-dragrace": "a", "fourneau": "b",
		"roux": "c"}, Files: map[string]string{"race.tar.gz": "00"}}
	body, _ := json.Marshal(info)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/Eldhus/fourneau-dragrace/releases" {
			t.Errorf("path %s", r.URL.Path)
		}
		json.NewEncoder(w).Encode([]map[string]any{
			{"tag_name": "build-20261007T060000Z", "body": string(body), "created_at": time.Now(),
				"assets": []map[string]string{{"name": "race.tar.gz", "browser_download_url": "u"}}},
			{"tag_name": "v1", "body": string(body)},
			{"tag_name": "build-broken", "body": "not json"},
		})
	}))
	defer server.Close()
	github := newGitHub("", "Eldhus/fourneau-dragrace")
	github.api = server.URL
	builds, err := github.builds(context.Background())
	if err != nil || len(builds) != 1 || builds[0].Assets["race.tar.gz"] != "u" {
		t.Fatalf("%v %v", builds, err)
	}
	if !sameCommits(builds[0].Info.Commits, info.Commits) {
		t.Fatal("not the same commits")
	}
	if sameCommits(builds[0].Info.Commits, map[string]string{"fourneau-dragrace": "a"}) {
		t.Fatal("a missing head matched")
	}
}
