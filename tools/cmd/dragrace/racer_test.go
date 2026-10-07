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

// The build of the heads is taken whatever its dates; after asking, the
// newest published since; a release dated by an old commit never counts.
func TestBuildOfTheHeads(t *testing.T) {
	heads := map[string]string{"fourneau-dragrace": "a", "fourneau": "b", "roux": "c"}
	asked := time.Date(2026, 10, 7, 10, 49, 0, 0, time.UTC)
	exact := Build{Info: BuildInfo{Commits: heads}, PublishedAt: asked.Add(-time.Hour)}
	newer := Build{Info: BuildInfo{Commits: map[string]string{"fourneau-dragrace": "d",
		"fourneau": "b", "roux": "c"}}, PublishedAt: asked.Add(8 * time.Minute)}
	older := Build{Info: BuildInfo{Commits: map[string]string{"fourneau-dragrace": "z"}},
		PublishedAt: asked.Add(-time.Hour)}
	if build, found := buildOf([]Build{older, exact}, heads, time.Time{}); !found ||
		build.Info.Commits["fourneau-dragrace"] != "a" {
		t.Fatal("the build of the heads, published long ago, was not taken")
	}
	if _, found := buildOf([]Build{older}, heads, time.Time{}); found {
		t.Fatal("another build taken before asking")
	}
	if build, found := buildOf([]Build{newer, older}, heads, asked); !found ||
		build.Info.Commits["fourneau-dragrace"] != "d" {
		t.Fatal("the build published after asking was not taken")
	}
	if _, found := buildOf([]Build{older}, heads, asked); found {
		t.Fatal("a build published before asking was taken")
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
			{"tag_name": "build-20261007T060000Z", "body": string(body), "published_at": time.Now(),
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
