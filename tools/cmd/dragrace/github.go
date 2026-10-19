package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"
)

// GitHub is what the racer asks of GitHub: the builds
// build.yml released, and their files. The repository is public, so it
// holds no token.
type GitHub struct {
	repository string // owner/name of this repository
	api        string
	client     *http.Client
	// A call or download that fails for a moment is tried again, waiting
	// first, doubling up to most, for window (retry).
	window, first, most time.Duration
	sleep               func(context.Context, time.Duration) error
}

func newGitHub(repository string) *GitHub {
	return &GitHub{repository: repository, api: "https://api.github.com",
		client: &http.Client{Timeout: 2 * time.Minute}, window: 30 * time.Minute,
		first: 2 * time.Second, most: time.Minute, sleep: sleepContext}
}

// errGitHubMoment is a failure that may pass: a connection dropped, a 5xx,
// a 429.
var errGitHubMoment = errors.New("GitHub, for a moment")

// retry runs attempt until it succeeds, fails otherwise than for a moment,
// or the window passes. GitHub answers 5xx now and then, and a 504 on a
// release's download must not spend the night's check.
func (github *GitHub) retry(ctx context.Context, what string, attempt func() error) error {
	deadline := time.Now().Add(github.window)
	wait := github.first
	for n := 1; ; n++ {
		err := attempt()
		if err == nil || !errors.Is(err, errGitHubMoment) || ctx.Err() != nil {
			return err
		}
		if time.Now().Add(wait).After(deadline) {
			return fmt.Errorf("%s: %d attempts over %s: %w", what, n, github.window, err)
		}
		log.Printf("%s (attempt %d): %v; again in %s", what, n, err, wait)
		if err := github.sleep(ctx, wait); err != nil {
			return err
		}
		wait = min(2*wait, github.most)
	}
}

// statusError is an answer that is not a success; a moment's when 5xx or
// 429.
func statusError(what string, code int, text string) error {
	if code/100 == 5 || code == http.StatusTooManyRequests {
		return fmt.Errorf("%w: %s: %d: %s", errGitHubMoment, what, code, text)
	}
	return fmt.Errorf("%s: %d: %s", what, code, text)
}

// racedRepositories are the repositories a race races, by their names in
// the site's database; each is Eldhus/NAME.
var racedRepositories = []string{"fourneau-dragrace", "fourneau", "roux"}

// upstreamRepositories are the raced repositories build.yml takes at their
// masters. A commit to either is in the next build (hourly), and always
// moves the race key: each competitor's key hashes their whole trees
// (keys.go). The racer asks GitHub for them every ten minutes; a push to
// either could instead tell the racer, one day, and end the polling.
var upstreamRepositories = []string{"fourneau", "roux"}

// githubBranch is what masters reads of a branch.
type githubBranch struct {
	Commit struct {
		SHA string `json:"sha"`
	} `json:"commit"`
}

// masters are the upstream repositories' newest commits on master, by name.
func (github *GitHub) masters(ctx context.Context) (map[string]string, error) {
	owner, _, _ := strings.Cut(github.repository, "/")
	masters := map[string]string{}
	for _, name := range upstreamRepositories {
		var branch githubBranch
		if err := github.get(ctx, "/repos/"+owner+"/"+name+"/branches/master", &branch); err != nil {
			return nil, err
		}
		if branch.Commit.SHA == "" {
			return nil, fmt.Errorf("%s's master: no commit in GitHub's answer", name)
		}
		masters[name] = branch.Commit.SHA
	}
	return masters, nil
}

// BuildInfo is build.json: a release's commits and its files' hashes. The
// release's body is this JSON, so a listing of releases says what each
// built.
type BuildInfo struct {
	Commits map[string]string `json:"commits"`
	BuiltAt time.Time         `json:"built_at"`
	// Each file's SHA-256, hex: race.tar.gz (the racer's), site.tar.gz
	// (the site host's).
	Files map[string]string `json:"files"`
	// Each competitor's key, and the race key over them (keys.go): two
	// builds with one race key race the same.
	Competitors map[string]string `json:"competitors"`
	RaceKey     string            `json:"race_key"`
	// The harness the competitors were smoked with (keys.go, harnessKey);
	// "" before 2026-10-16.
	HarnessKey string `json:"harness_key"`
}

// Build is a release of build.yml.
type Build struct {
	Info   BuildInfo
	Assets map[string]string // file name -> download URL
}

func (github *GitHub) request(ctx context.Context, url string) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	return github.client.Do(request)
}

// get reads path of GitHub's API into into; a moment's failure is tried
// again (retry).
func (github *GitHub) get(ctx context.Context, path string, into any) error {
	what := "GitHub GET " + path
	var text []byte
	err := github.retry(ctx, what, func() error {
		response, err := github.request(ctx, github.api+path)
		if err != nil {
			return fmt.Errorf("%w: %w", errGitHubMoment, err)
		}
		defer response.Body.Close()
		text, err = io.ReadAll(io.LimitReader(response.Body, 16<<20))
		if err != nil {
			return fmt.Errorf("%w: %w", errGitHubMoment, err)
		}
		if response.StatusCode/100 != 2 {
			return statusError(what, response.StatusCode, strings.TrimSpace(string(text)))
		}
		return nil
	})
	if err != nil || into == nil {
		return err
	}
	return json.Unmarshal(text, into)
}

// githubRelease is what builds reads of a release in GitHub's listing.
type githubRelease struct {
	TagName     string `json:"tag_name"`
	PublishedAt string `json:"published_at"`
	Body        string `json:"body"`
	Assets      []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

// builds are the newest releases of build.yml, newest first; a release
// whose body is not a build.json is not one. Newest by when each was
// published: GitHub lists releases by their commit's date, not their
// own, so a build of a commit dated earlier lists before newer builds.
func (github *GitHub) builds(ctx context.Context) ([]Build, error) {
	var releases []githubRelease
	if err := github.get(ctx, "/repos/"+github.repository+"/releases?per_page=30", &releases); err != nil {
		return nil, err
	}
	// RFC 3339 times in UTC sort as text, newest first; a release with
	// none (a draft is never a build) sorts last, and equals keep
	// GitHub's order.
	slices.SortStableFunc(releases, func(a, b githubRelease) int {
		return strings.Compare(b.PublishedAt, a.PublishedAt)
	})
	var builds []Build
	for _, release := range releases {
		if !strings.HasPrefix(release.TagName, "build-") {
			continue
		}
		var info BuildInfo
		if json.Unmarshal([]byte(release.Body), &info) != nil || len(info.Commits) == 0 {
			continue
		}
		build := Build{Info: info, Assets: map[string]string{}}
		for _, asset := range release.Assets {
			build.Assets[asset.Name] = asset.URL
		}
		builds = append(builds, build)
	}
	return builds, nil
}

// download fetches a release file to path, checking its SHA-256; a
// moment's failure is tried again (retry).
func (github *GitHub) download(ctx context.Context, url, sha256Hex, path string) error {
	return github.retry(ctx, "GitHub download", func() error {
		return github.downloadOnce(ctx, url, sha256Hex, path)
	})
}

func (github *GitHub) downloadOnce(ctx context.Context, url, sha256Hex, path string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 20 * time.Minute}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("%w: %w", errGitHubMoment, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return statusError(url, response.StatusCode, "")
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
		return fmt.Errorf("%w: %w", errGitHubMoment, copyErr)
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
