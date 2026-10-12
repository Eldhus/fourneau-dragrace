package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
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

// A run the site refuses is not recorded: the request stays, no backup is
// asked for, and the racer asks again later and later.
func TestARefusedRunIsNotBackedUp(t *testing.T) {
	head := strings.Repeat("a", 40)
	refuse, backups := true, 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/repos/Eldhus/"):
			fmt.Fprintf(w, `{"sha":%q}`, head)
		case r.URL.Path == "/api/racer/next":
			raced := ""
			for i, name := range racedRepositories {
				if i > 0 {
					raced += ","
				}
				raced += fmt.Sprintf(`{"repository":%q,"commit_sha":%q}`, name, head)
			}
			fmt.Fprintf(w, `{"waiting":[{"id":1,"kind":"check"}],"raced":[%s]}`, raced)
		case r.URL.Path == "/api/runs" && refuse:
			http.Error(w, `the body: MissingRequiredField("section")`, http.StatusBadRequest)
		case r.URL.Path == "/api/backup":
			backups++
		}
	}))
	defer server.Close()
	github := newGitHub("", "Eldhus/fourneau-dragrace")
	github.api = server.URL
	racer := &Racer{site: newSiteClient(server.URL, "token"), github: github}
	handled, err := racer.handleNext(context.Background())
	if !handled || !errors.Is(err, errRunNotRecorded) || backups != 0 {
		t.Fatalf("refused: handled %v, %v, %d backups", handled, err, backups)
	}
	refuse = false
	handled, err = racer.handleNext(context.Background())
	if !handled || err != nil || backups != 1 {
		t.Fatalf("a skipped run, recorded: handled %v, %v, %d backups", handled, err, backups)
	}
	var waits []string
	for refused := range 9 {
		waits = append(waits, requestWait(refused).String())
	}
	if got := strings.Join(waits, " "); got != "30s 1m0s 2m0s 4m0s 8m0s 16m0s 30m0s 30m0s 30m0s" {
		t.Fatalf("waits: %s", got)
	}
}

// GitHub's 5xx is a moment's: tried again, the waits doubling, until the
// window passes; a 404 or a file not the build's fails at once.
func TestGitHubRetriesAMoment(t *testing.T) {
	failures := map[string]int{}
	content := "race"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if failures[r.URL.Path] > 0 {
			failures[r.URL.Path]--
			http.Error(w, "upstream", http.StatusGatewayTimeout)
			return
		}
		switch r.URL.Path {
		case "/race.tar.gz":
			w.Write([]byte(content))
		case "/repos/Eldhus/fourneau/commits/master":
			fmt.Fprintf(w, `{"sha":%q}`, strings.Repeat("b", 40))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	github := newGitHub("", "Eldhus/fourneau-dragrace")
	github.api = server.URL
	var waits []string
	github.sleep = func(_ context.Context, wait time.Duration) error {
		waits = append(waits, wait.String())
		return nil
	}
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "race.tar.gz")
	sum := sha256.Sum256([]byte(content))
	failures["/race.tar.gz"] = 2
	if err := github.download(ctx, server.URL+"/race.tar.gz", hex.EncodeToString(sum[:]), path); err != nil {
		t.Fatalf("after two 504s: %v", err)
	}
	if strings.Join(waits, " ") != "2s 4s" {
		t.Fatalf("waits %v", waits)
	}
	waits = nil
	var commit struct{ SHA string }
	failures["/repos/Eldhus/fourneau/commits/master"] = 1
	if err := github.call(ctx, http.MethodGet, "/repos/Eldhus/fourneau/commits/master", nil, &commit); err != nil ||
		len(commit.SHA) != 40 || len(waits) != 1 {
		t.Fatalf("a call after a 504: %v %q %v", err, commit.SHA, waits)
	}
	waits = nil
	if err := github.download(ctx, server.URL+"/gone", "00", path); err == nil || len(waits) != 0 {
		t.Fatalf("a 404 is not a moment's: %v, %v", err, waits)
	}
	if err := github.download(ctx, server.URL+"/race.tar.gz", "00", path); err == nil || len(waits) != 0 {
		t.Fatalf("a file not the build's is not a moment's: %v, %v", err, waits)
	}
	github.window = 10 * time.Second
	failures["/race.tar.gz"] = 100
	err := github.download(ctx, server.URL+"/race.tar.gz", hex.EncodeToString(sum[:]), path)
	// The sleep stands still, so the window ends at the first wait past
	// it: 2, 4, 8 s, then not 16.
	if err == nil || !strings.Contains(err.Error(), "4 attempts over 10s") || len(waits) != 3 {
		t.Fatalf("past the window: %v, %v", err, waits)
	}
}

// The racer reads the commit the site serves; a site from before
// site.json (404) says nothing, so the racer holds.
func TestSiteCommit(t *testing.T) {
	serving := `{"fourneau-dragrace":"c6d7919"}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/site.json" || serving == "" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(serving))
	}))
	defer server.Close()
	racer := &Racer{site: newSiteClient(server.URL, "token")}
	if got := racer.siteCommit(context.Background()); got != "c6d7919" {
		t.Fatalf("served %q", got)
	}
	serving = ""
	if got := racer.siteCommit(context.Background()); got != "" {
		t.Fatalf("a site without site.json: %q", got)
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
