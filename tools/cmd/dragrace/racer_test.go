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

// releasesServer answers GitHub's releases listing with these builds,
// newest first, and the site's /api/racer/next with the raced commits.
func releasesServer(t *testing.T, builds []BuildInfo, raced map[string]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/Eldhus/fourneau-dragrace/releases":
			var releases []map[string]any
			for i, info := range builds {
				body, _ := json.Marshal(info)
				releases = append(releases, map[string]any{"tag_name": fmt.Sprintf("build-%d", i),
					"body": string(body), "assets": []map[string]string{}})
			}
			json.NewEncoder(w).Encode(releases)
		case "/api/racer/next":
			var commits []map[string]string
			for name, commit := range raced {
				commits = append(commits, map[string]string{"repository": name, "commit_sha": commit})
			}
			json.NewEncoder(w).Encode(map[string]any{"waiting": []any{}, "raced": commits})
		default:
			http.NotFound(w, r)
		}
	}))
}

// Tonight's build is the newest of the racer's own commit; it is new when
// its race key is not the key of the build the last race raced.
func TestTonight(t *testing.T) {
	commits := func(dragrace, roux string) map[string]string {
		return map[string]string{"fourneau-dragrace": dragrace, "fourneau": "f", "roux": roux}
	}
	defer func(saved string) { buildCommit = saved }(buildCommit)
	cases := []struct {
		name   string
		own    string
		builds []BuildInfo
		raced  map[string]string
		want   string // the roux commit of tonight's build, or "error"
		isNew  bool
	}{
		{"a site change: the same race key", "a2",
			[]BuildInfo{{Commits: commits("a2", "r1"), RaceKey: "k1"}, {Commits: commits("a1", "r1"), RaceKey: "k1"}},
			commits("a1", "r1"), "r1", false},
		{"a new roux build of the same commit", "a1",
			[]BuildInfo{{Commits: commits("a1", "r2"), RaceKey: "k2"}, {Commits: commits("a1", "r1"), RaceKey: "k1"}},
			commits("a1", "r1"), "r2", true},
		{"raced already", "a1",
			[]BuildInfo{{Commits: commits("a1", "r1"), RaceKey: "k1"}}, commits("a1", "r1"), "r1", false},
		{"the last race's build gone", "a1",
			[]BuildInfo{{Commits: commits("a1", "r1"), RaceKey: "k1"}}, commits("a0", "r0"), "r1", true},
		{"the last race's build from before race keys", "a1",
			[]BuildInfo{{Commits: commits("a1", "r1"), RaceKey: "k1"}, {Commits: commits("a0", "r1")}},
			commits("a0", "r1"), "r1", true},
		{"nothing raced yet", "a1",
			[]BuildInfo{{Commits: commits("a1", "r1"), RaceKey: "k1"}}, map[string]string{}, "r1", true},
		{"a racer built by hand", "",
			[]BuildInfo{{Commits: commits("a1", "r1"), RaceKey: "k1"}}, commits("a1", "r1"), "error", false},
		{"no build of the racer's commit", "a9",
			[]BuildInfo{{Commits: commits("a1", "r1"), RaceKey: "k1"}}, commits("a1", "r1"), "error", false},
	}
	for _, c := range cases {
		server := releasesServer(t, c.builds, c.raced)
		github := newGitHub("Eldhus/fourneau-dragrace")
		github.api = server.URL
		racer := &Racer{site: newSiteClient(server.URL, "token"), github: github}
		buildCommit = c.own
		tonight, err := racer.tonight(context.Background(), c.raced)
		switch {
		case c.want == "error":
			if err == nil {
				t.Errorf("%s: no error", c.name)
			}
		case err != nil:
			t.Errorf("%s: %v", c.name, err)
		case tonight.Commits["roux"] != c.want || tonight.Build.Info.Commits["roux"] != c.want ||
			tonight.New != c.isNew:
			t.Errorf("%s: roux %s, new %v; want %s, %v", c.name, tonight.Commits["roux"], tonight.New,
				c.want, c.isNew)
		case c.isNew && !sameCommits(tonight.posted(), tonight.Commits),
			!c.isNew && !sameCommits(tonight.posted(), c.raced):
			t.Errorf("%s: the site told %v", c.name, tonight.posted())
		}
		server.Close()
	}
}

// A run the site refuses is not recorded: the request stays, no backup is
// asked for, and the racer asks again later and later.
func TestARefusedRunIsNotBackedUp(t *testing.T) {
	head := strings.Repeat("a", 40)
	defer func(saved string) { buildCommit = saved }(buildCommit)
	buildCommit = head
	refuse, backups := true, 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/Eldhus/fourneau-dragrace/releases":
			body, _ := json.Marshal(BuildInfo{RaceKey: "k", Commits: map[string]string{
				"fourneau-dragrace": head, "fourneau": head, "roux": head}})
			json.NewEncoder(w).Encode([]map[string]any{{"tag_name": "build-1", "body": string(body)}})
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
	github := newGitHub("Eldhus/fourneau-dragrace")
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
		case "/repos/Eldhus/fourneau-dragrace/releases/latest":
			fmt.Fprintf(w, `{"tag_name":%q}`, strings.Repeat("b", 40))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	github := newGitHub("Eldhus/fourneau-dragrace")
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
	var release struct {
		TagName string `json:"tag_name"`
	}
	failures["/repos/Eldhus/fourneau-dragrace/releases/latest"] = 1
	if err := github.get(ctx, "/repos/Eldhus/fourneau-dragrace/releases/latest",
		&release); err != nil || len(release.TagName) != 40 || len(waits) != 1 {
		t.Fatalf("a get after a 504: %v %q %v", err, release.TagName, waits)
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

// A race's versions are the build's record and race.json's, under the
// names the site reads (Store.roc).
func TestVersionRows(t *testing.T) {
	root := t.TempDir()
	writeFile(t, toolchainRecord(root), `{"zig":"0.17.0","roc":"nightly-1","go":"1.27.1",`+
		`"rust":"1.94.1","axum":"0.8.9","tokio":"1.53.2"}`)
	race := Race{Oha: Download{Version: "1.16.0"}, Cloud: Cloud{Image: "ubuntu-26-04-x64"}}
	rows, err := versionRows(root, race)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, row := range rows {
		got = append(got, row.Name+" "+row.Version)
	}
	want := "zig 0.17.0, roc nightly-1, oha 1.16.0, go 1.27.1, rust 1.94.1, axum 0.8.9, " +
		"tokio 1.53.2, droplet_image ubuntu-26-04-x64"
	if strings.Join(got, ", ") != want {
		t.Fatalf("rows %s, want %s", strings.Join(got, ", "), want)
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
			{"tag_name": "build-20261007T060000Z", "body": string(body),
				"assets": []map[string]string{{"name": "race.tar.gz", "browser_download_url": "u"}}},
			{"tag_name": "v1", "body": string(body)},
			{"tag_name": "build-broken", "body": "not json"},
		})
	}))
	defer server.Close()
	github := newGitHub("Eldhus/fourneau-dragrace")
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
