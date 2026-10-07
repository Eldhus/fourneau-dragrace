package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// GitHub is what the racer asks of GitHub (docs/self-hosting.md, "Builds
// and deploys"): each repository's newest commit, the builds released by
// build.yml, a build dispatched. Its token is fine-grained: this repository,
// Actions read and write; the repositories are public, so heads and
// downloads need none.
type GitHub struct {
	token      string
	repository string // owner/name of this repository
	api        string
	client     *http.Client
}

func newGitHub(token, repository string) *GitHub {
	return &GitHub{token: token, repository: repository, api: "https://api.github.com",
		client: &http.Client{Timeout: 2 * time.Minute}}
}

// racedRepositories are the repositories a race races, by their names in
// the site's database; each is Eldhus/NAME, raced at main.
var racedRepositories = []string{"fourneau-dragrace", "fourneau", "roux"}

// BuildInfo is build.json: a release's commits and its files' hashes. The
// release's body is this JSON, so a listing of releases says what each
// built.
type BuildInfo struct {
	Commits map[string]string `json:"commits"`
	BuiltAt time.Time         `json:"built_at"`
	// Each file's SHA-256, hex: race.tar.gz (the racer's), site.tar.gz
	// (the site host's).
	Files map[string]string `json:"files"`
}

// Build is a release of build.yml.
type Build struct {
	Info BuildInfo
	// When the release was published. Not GitHub's `created_at`: for a
	// release that is the date of the tagged commit, which can be long
	// before the build (found 2026-10-07: the racer waited on a build of
	// a commit made a minute before its dispatch).
	PublishedAt time.Time
	Assets      map[string]string // file name -> download URL
}

func (github *GitHub) request(ctx context.Context, method, url string, body any) (*http.Response, error) {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, url, reader)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if github.token != "" {
		request.Header.Set("Authorization", "Bearer "+github.token)
	}
	return github.client.Do(request)
}

func (github *GitHub) call(ctx context.Context, method, path string, body, into any) error {
	response, err := github.request(ctx, method, github.api+path, body)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	text, err := io.ReadAll(io.LimitReader(response.Body, 16<<20))
	if err != nil {
		return err
	}
	if response.StatusCode/100 != 2 {
		return fmt.Errorf("GitHub %s %s: %d: %s", method, path, response.StatusCode,
			strings.TrimSpace(string(text)))
	}
	if into == nil {
		return nil
	}
	return json.Unmarshal(text, into)
}

// heads is each raced repository's newest commit on main.
func (github *GitHub) heads(ctx context.Context) (map[string]string, error) {
	heads := map[string]string{}
	for _, name := range racedRepositories {
		var commit struct {
			SHA string `json:"sha"`
		}
		if err := github.call(ctx, http.MethodGet, "/repos/Eldhus/"+name+"/commits/main", nil,
			&commit); err != nil {
			return nil, err
		}
		if len(commit.SHA) != 40 {
			return nil, fmt.Errorf("Eldhus/%s: a head of %q", name, commit.SHA)
		}
		heads[name] = commit.SHA
	}
	return heads, nil
}

// builds are the newest releases of build.yml, newest first; a release
// whose body is not a build.json is not one.
func (github *GitHub) builds(ctx context.Context) ([]Build, error) {
	var releases []struct {
		TagName     string    `json:"tag_name"`
		Body        string    `json:"body"`
		PublishedAt time.Time `json:"published_at"`
		Assets      []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := github.call(ctx, http.MethodGet, "/repos/"+github.repository+"/releases?per_page=30",
		nil, &releases); err != nil {
		return nil, err
	}
	var builds []Build
	for _, release := range releases {
		if !strings.HasPrefix(release.TagName, "build-") {
			continue
		}
		var info BuildInfo
		if json.Unmarshal([]byte(release.Body), &info) != nil || len(info.Commits) == 0 {
			continue
		}
		build := Build{Info: info, PublishedAt: release.PublishedAt, Assets: map[string]string{}}
		for _, asset := range release.Assets {
			build.Assets[asset.Name] = asset.URL
		}
		builds = append(builds, build)
	}
	return builds, nil
}

// building says whether a run of the workflow is queued or in progress:
// a push's build, which will build the heads too.
func (github *GitHub) building(ctx context.Context, workflow string) (bool, error) {
	for _, status := range []string{"queued", "in_progress"} {
		var runs struct {
			TotalCount int `json:"total_count"`
		}
		path := "/repos/" + github.repository + "/actions/workflows/" + workflow +
			"/runs?per_page=1&status=" + status
		if err := github.call(ctx, http.MethodGet, path, nil, &runs); err != nil {
			return false, err
		}
		if runs.TotalCount > 0 {
			return true, nil
		}
	}
	return false, nil
}

// dispatch asks build.yml to build the heads of main.
func (github *GitHub) dispatch(ctx context.Context, workflow string) error {
	return github.call(ctx, http.MethodPost, "/repos/"+github.repository+"/actions/workflows/"+
		workflow+"/dispatches", map[string]string{"ref": "main"}, nil)
}

// download fetches a release file to path, checking its SHA-256.
func (github *GitHub) download(ctx context.Context, url, sha256Hex, path string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 20 * time.Minute}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %d", url, response.StatusCode)
	}
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	hash := sha256.New()
	const downloadBytesMax = 2 << 30
	_, copyErr := io.Copy(io.MultiWriter(file, hash), io.LimitReader(response.Body, downloadBytesMax))
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if got := hex.EncodeToString(hash.Sum(nil)); got != sha256Hex {
		os.Remove(path)
		return fmt.Errorf("%s: SHA-256 %s, build.json says %s", url, got, sha256Hex)
	}
	return nil
}

// sameCommits says whether a build built exactly these heads.
func sameCommits(build, heads map[string]string) bool {
	for _, name := range racedRepositories {
		if build[name] == "" || build[name] != heads[name] {
			return false
		}
	}
	return true
}
