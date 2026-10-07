package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// The racer (docs/self-hosting.md, "A run") takes what the site was asked
// (a check or a race), finds or dispatches the build of the heads, races
// it through the guard with a worker on each loader, and tells the site
// how it went. It holds no DigitalOcean token: the guard does.

// RacerConfig is the owner's, on the racer (/etc/dragrace-racer).
type RacerConfig struct {
	Site       string `json:"site"`
	Guard      string `json:"guard"`
	Repository string `json:"repository"`
	Workflow   string `json:"workflow"`
	State      string `json:"state"`
}

// buildCommit is the commit this binary was built from (build.yml sets it
// with -ldflags), so the racer knows a newer build of itself.
var buildCommit = ""

// Racer is one racer: its site, GitHub, and the droplets' provider. A
// local racer (a test) races on this machine, the checkout as its build.
type Racer struct {
	config   RacerConfig
	site     *SiteClient
	github   *GitHub
	provider Provider
	local    string // the checkout, for a local racer; "" in the cloud
}

// Request is one thing asked of the racer, as the site lists it.
type Request struct {
	ID      int64  `json:"id"`
	Kind    string `json:"kind"`
	AskedBy string `json:"asked_by"`
	AskedAt string `json:"asked_at"`
}

// Next is the site's answer to /api/racer/next.
type Next struct {
	Waiting []Request `json:"waiting"`
	Raced   []struct {
		Repository string `json:"repository"`
		CommitSHA  string `json:"commit_sha"`
	} `json:"raced"`
}

// RunPost and the types below are the site's API bodies (site/Api.roc).
type RunPost struct {
	ID          string       `json:"id"`
	RequestID   int64        `json:"request_id"`
	Trigger     string       `json:"trigger"`
	Status      string       `json:"status"`
	Reason      string       `json:"reason"`
	WhereRaced  string       `json:"where_raced"`
	StartedAt   string       `json:"started_at"`
	WorkerToken string       `json:"worker_token"`
	Commits     []CommitPost `json:"commits"`
	Race        *RacePost    `json:"race,omitempty"`
}

type CommitPost struct {
	Repository string `json:"repository"`
	CommitSHA  string `json:"commit_sha"`
	New        bool   `json:"new"`
}

type RacePost struct {
	Seed           int64  `json:"seed"`
	Region         string `json:"region"`
	Image          string `json:"image"`
	Port           int    `json:"port"`
	Rounds         int    `json:"rounds"`
	WarmupSeconds  int    `json:"warmup_seconds"`
	MeasureSeconds int    `json:"measure_seconds"`
	OpenLoop       struct {
		Workload       string    `json:"workload"`
		Shares         []float64 `json:"shares"`
		WarmupSeconds  int       `json:"warmup_seconds"`
		MeasureSeconds int       `json:"measure_seconds"`
	} `json:"open_loop"`
	RaceJSON     string            `json:"race_json"`
	VersionsJSON string            `json:"versions_json"`
	Versions     []NameVersion     `json:"versions"`
	Competitors  []CompetitorPost  `json:"competitors"`
	Workloads    []WorkloadPost    `json:"workloads"`
	Classes      []ServerClassPost `json:"classes"`
}

// WorkloadPost is a Workload as the site keeps it: its kind, not its mix.
type WorkloadPost struct {
	Name        string `json:"name"`
	Kind        string `json:"kind"`
	Title       string `json:"title"`
	Summary     string `json:"summary"`
	Method      string `json:"method"`
	Path        string `json:"path"`
	BodyBytes   int    `json:"body_bytes"`
	ContentType string `json:"content_type"`
	Connections int    `json:"connections"`
	Keepalive   bool   `json:"keepalive"`
}

type NameVersion struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type CompetitorPost struct {
	Name      string `json:"name"`
	Title     string `json:"title"`
	Language  string `json:"language"`
	Framework string `json:"framework"`
}

// ServerClassPost is a ServerClass with every field present.
type ServerClassPost struct {
	Name       string `json:"name"`
	Label      string `json:"label"`
	Title      string `json:"title"`
	Size       string `json:"size"`
	LoaderSize string `json:"loader_size"`
	ServerCPU  string `json:"server_cpu"`
}

type EndPost struct {
	Status     string `json:"status"`
	Reason     string `json:"reason"`
	FinishedAt string `json:"finished_at"`
	Timing     Timing `json:"timing"`
}

func commandRacer(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: dragrace racer serve|check|once [-config F]")
	}
	flags := newFlags("racer " + args[0])
	path := flags.String("config", "/etc/dragrace-racer/config.json", "the owner's config")
	local := flags.String("local", "", "race on this machine, this checkout as the build (a test)")
	flags.Parse(args[1:])
	var config RacerConfig
	if err := readJSON(*path, &config); err != nil {
		return err
	}
	for variable, credential := range map[string]string{"RACER_TOKEN": "racer-token",
		"GITHUB_TOKEN": "github-token"} {
		if err := tokenFromCredential(variable, credential); err != nil {
			return err
		}
	}
	token := strings.TrimSpace(os.Getenv("RACER_TOKEN"))
	if config.Site == "" || token == "" {
		return fmt.Errorf("the site and its racer token (RACER_TOKEN) are required")
	}
	racer := &Racer{config: config, site: newSiteClient(config.Site, token),
		github: newGitHub(strings.TrimSpace(os.Getenv("GITHUB_TOKEN")), config.Repository),
		local:  *local}
	if racer.local == "" {
		racer.provider = newGuardClient(config.Guard)
	}
	switch args[0] {
	case "check":
		return racer.site.post(ctx, "/api/requests?kind=check", nil, nil)
	case "once":
		return racer.once(ctx)
	case "serve":
		return racer.serve(ctx)
	}
	return fmt.Errorf("unknown: dragrace racer %s", args[0])
}

// serve takes requests until stopped: every 30 s it asks the site, every
// 10 minutes it tells the site the heads, and, idle, it updates itself.
func (racer *Racer) serve(ctx context.Context) error {
	racer.recover(ctx)
	var headsAt, updateAt time.Time
	for {
		if time.Since(headsAt) > 10*time.Minute {
			headsAt = time.Now()
			if err := racer.postHeads(ctx); err != nil {
				log.Printf("heads: %v", err)
			}
		}
		handled, err := racer.handleNext(ctx)
		if err != nil {
			log.Printf("request: %v", err)
		}
		if !handled && racer.local == "" && time.Since(updateAt) > 10*time.Minute {
			updateAt = time.Now()
			if err := racer.update(ctx); err != nil {
				log.Printf("update: %v", err)
			}
		}
		if err := sleepContext(ctx, 30*time.Second); err != nil {
			return nil
		}
	}
}

// once takes the oldest request, if there is one.
func (racer *Racer) once(ctx context.Context) error {
	handled, err := racer.handleNext(ctx)
	if err == nil && !handled {
		log.Printf("no request waiting")
	}
	return err
}

func (racer *Racer) handleNext(ctx context.Context) (bool, error) {
	var next Next
	if err := racer.site.get(ctx, "/api/racer/next", &next); err != nil {
		return false, err
	}
	if len(next.Waiting) == 0 {
		return false, nil
	}
	raced := map[string]string{}
	for _, commit := range next.Raced {
		raced[commit.Repository] = commit.CommitSHA
	}
	err := racer.handle(ctx, next.Waiting[0], raced)
	if backupErr := racer.site.post(ctx, "/api/backup", nil, nil); backupErr != nil {
		log.Printf("backup: %v", backupErr)
	}
	return true, err
}

func (racer *Racer) heads(ctx context.Context) (map[string]string, error) {
	if racer.local != "" {
		fingerprint, err := fingerprintOf(racer.local)
		if err != nil {
			return nil, err
		}
		return map[string]string{"fourneau-dragrace": fingerprint.Dragrace,
			"fourneau": fingerprint.Fourneau, "roux": fingerprint.Roux}, nil
	}
	return racer.github.heads(ctx)
}

func (racer *Racer) postHeads(ctx context.Context) error {
	heads, err := racer.heads(ctx)
	if err != nil {
		return err
	}
	return racer.postHeadsOf(ctx, heads)
}

func (racer *Racer) postHeadsOf(ctx context.Context, heads map[string]string) error {
	var posts []map[string]string
	for _, name := range racedRepositories {
		posts = append(posts, map[string]string{"repository": name, "commit_sha": heads[name]})
	}
	return racer.site.post(ctx, "/api/heads", posts, nil)
}

func commitsPost(heads, raced map[string]string) ([]CommitPost, bool) {
	anyNew := false
	var commits []CommitPost
	for _, name := range racedRepositories {
		isNew := heads[name] != raced[name]
		anyNew = anyNew || isNew
		commits = append(commits, CommitPost{Repository: name, CommitSHA: heads[name], New: isNew})
	}
	return commits, anyNew
}

// handle does one request: a check with nothing new is a skipped run;
// anything else builds and races.
func (racer *Racer) handle(ctx context.Context, request Request, raced map[string]string) error {
	watch := stopwatch{start: time.Now()}
	trigger := "timer"
	if request.AskedBy == "owner" {
		trigger = "manual"
	}
	where := "cloud"
	if racer.local != "" {
		where = "local"
	}
	started := time.Now().UTC()
	run := RunPost{ID: runID(where, started), RequestID: request.ID, Trigger: trigger,
		WhereRaced: where, StartedAt: started.Format(time.RFC3339)}
	heads, err := racer.heads(ctx)
	if err != nil {
		return racer.notRaced(ctx, run, "failed", "the heads: "+err.Error())
	}
	// The race page's line on tonight shows these heads at once: posted
	// from the idle loop only, they would stand still for the hour a
	// request takes (seen live, 2026-10-07).
	if err := racer.postHeadsOf(ctx, heads); err != nil {
		log.Printf("heads: %v", err)
	}
	commits, anyNew := commitsPost(heads, raced)
	run.Commits = commits
	if request.Kind == "check" && !anyNew {
		log.Printf("check: nothing new since the last finished run: skipped")
		return racer.notRaced(ctx, run, "skipped", "nothing new since the last finished race")
	}
	root, built, err := racer.build(ctx, run.ID, heads)
	if err != nil {
		return racer.notRaced(ctx, run, "failed", "the build: "+err.Error())
	}
	run.Commits, _ = commitsPost(built, raced)
	buildSeconds := watch.since()
	return racer.race(ctx, root, run, watch, buildSeconds)
}

// notRaced records a run that did not race: skipped, refused, or failed
// before its droplets.
func (racer *Racer) notRaced(ctx context.Context, run RunPost, status, reason string) error {
	run.Status, run.Reason = status, reason
	if err := racer.site.post(ctx, "/api/runs", run, nil); err != nil {
		return err
	}
	if status == "failed" {
		return errors.New(reason)
	}
	return nil
}

// build is the checkout to race: this one, for a local racer; otherwise
// the release built from the heads (dispatched if there is none), unpacked.
// It returns the commits the build has.
func (racer *Racer) build(ctx context.Context, id string, heads map[string]string) (string,
	map[string]string, error) {
	if racer.local != "" {
		tools, err := loadToolchain(ctx, racer.local)
		if err != nil {
			return "", nil, err
		}
		if err := copyFile(tools.Oha, filepath.Join(binDir(racer.local), "oha")); err != nil {
			return "", nil, err
		}
		return racer.local, heads, nil
	}
	build, err := racer.findBuild(ctx, heads)
	if err != nil {
		return "", nil, err
	}
	dir := filepath.Join(racer.config.State, "runs", id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", nil, err
	}
	pruneRuns(filepath.Join(racer.config.State, "runs"), 5)
	tarball := filepath.Join(dir, "race.tar.gz")
	if err := racer.github.download(ctx, build.Assets["race.tar.gz"], build.Info.Files["race.tar.gz"],
		tarball); err != nil {
		return "", nil, err
	}
	root := filepath.Join(dir, "bundle")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", nil, err
	}
	if err := run(ctx, root, nil, "tar", "-xzf", tarball); err != nil {
		return "", nil, err
	}
	return root, build.Info.Commits, nil
}

// buildWaitMax bounds the wait for build.yml (it takes about 15 minutes).
const buildWaitMax = 45 * time.Minute

func (racer *Racer) findBuild(ctx context.Context, heads map[string]string) (Build, error) {
	builds, err := racer.github.builds(ctx)
	if err != nil {
		return Build{}, err
	}
	for _, build := range builds {
		if sameCommits(build.Info.Commits, heads) {
			return build, nil
		}
	}
	dispatched := time.Now()
	log.Printf("no build of these heads: dispatching %s", racer.config.Workflow)
	if err := racer.github.dispatch(ctx, racer.config.Workflow); err != nil {
		return Build{}, err
	}
	for time.Since(dispatched) < buildWaitMax {
		if err := sleepContext(ctx, 30*time.Second); err != nil {
			return Build{}, err
		}
		builds, err := racer.github.builds(ctx)
		if err != nil {
			log.Printf("builds: %v", err)
			continue
		}
		// The heads may have moved since: the newest build made after the
		// dispatch is the one, whatever it built.
		for _, build := range builds {
			if build.CreatedAt.After(dispatched.Add(-time.Minute)) {
				return build, nil
			}
		}
	}
	return Build{}, fmt.Errorf("no build after %s", buildWaitMax)
}

// pruneRuns keeps the newest `keep` run directories.
func pruneRuns(dir string, keep int) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names) // run IDs sort as their times
	for len(names) > keep {
		os.RemoveAll(filepath.Join(dir, names[0]))
		names = names[1:]
	}
}

func copyFile(from, to string) error {
	bytes, err := os.ReadFile(from)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	return os.WriteFile(to, bytes, 0o755)
}

// racePost is race.json and versions.json, as the site keeps them.
func racePost(root string, race Race, competitors []Competitor, seed int64) (*RacePost, error) {
	raceJSON, err := os.ReadFile(filepath.Join(root, "race.json"))
	if err != nil {
		return nil, err
	}
	versionsJSON, err := os.ReadFile(filepath.Join(root, "versions.json"))
	if err != nil {
		return nil, err
	}
	versions, err := loadVersions(root)
	if err != nil {
		return nil, err
	}
	post := &RacePost{Seed: seed, Region: race.Cloud.Region, Image: race.Cloud.Image,
		Port: race.Port, Rounds: race.Rounds, WarmupSeconds: race.WarmupSeconds,
		MeasureSeconds: race.MeasureSeconds, RaceJSON: string(raceJSON),
		VersionsJSON: string(versionsJSON)}
	for _, workload := range race.Workloads {
		post.Workloads = append(post.Workloads, WorkloadPost{Name: workload.Name,
			Kind: workload.kind(), Title: workload.Title, Summary: workload.Summary,
			Method: workload.Method, Path: workload.Path, BodyBytes: workload.BodyBytes,
			ContentType: workload.ContentType, Connections: workload.Connections,
			Keepalive: workload.Keepalive})
	}
	post.OpenLoop.Workload, post.OpenLoop.Shares = race.OpenLoop.Workload, race.OpenLoop.Shares
	post.OpenLoop.WarmupSeconds = race.OpenLoop.WarmupSeconds
	post.OpenLoop.MeasureSeconds = race.OpenLoop.MeasureSeconds
	if post.OpenLoop.Shares == nil {
		post.OpenLoop.Shares = []float64{}
	}
	post.Versions = []NameVersion{{"zig", versions.Zig.Version}, {"roc", versions.Roc.Version},
		{"roc_musl", versions.RocMusl.Commit}, {"oha", versions.Oha.Version},
		{"go", versions.Go.Version}, {"rust", versions.Rust.Version},
		{"axum", versions.Axum.Version}, {"tokio", versions.Tokio.Version},
		{"droplet_image", versions.DropletImage}}
	for _, competitor := range competitors {
		post.Competitors = append(post.Competitors, CompetitorPost{Name: competitor.Name,
			Title: competitor.Title, Language: competitor.Language, Framework: competitor.Framework})
	}
	for _, class := range race.Cloud.Servers {
		post.Classes = append(post.Classes, ServerClassPost(class))
	}
	return post, nil
}

func randomToken() string {
	bytes := make([]byte, 32)
	rand.Read(bytes)
	return hex.EncodeToString(bytes)
}

// race makes the run at the site, races it, posts every result again, and
// ends it.
func (racer *Racer) race(ctx context.Context, root string, run RunPost, watch stopwatch,
	buildSeconds float64) error {
	race, err := loadRace(root)
	if err != nil {
		return racer.notRaced(ctx, run, "failed", err.Error())
	}
	competitors, err := loadCompetitors(root, race.Competitors)
	if err != nil {
		return racer.notRaced(ctx, run, "failed", err.Error())
	}
	seed := time.Now().UnixNano()
	run.Race, err = racePost(root, race, competitors, seed)
	if err != nil {
		return racer.notRaced(ctx, run, "failed", err.Error())
	}
	if racer.local != "" {
		run.Race.Classes = []ServerClassPost{{Name: "local", Label: "local", Title: "this computer"}}
	}
	run.Status, run.WorkerToken = "racing", randomToken()
	if err := racer.site.post(ctx, "/api/runs", run, nil); err != nil {
		return err
	}
	racer.remember(run.ID)
	defer racer.forget()
	timing := Timing{BuildSeconds: buildSeconds}
	var results []Result
	var raceErr error
	if racer.local != "" {
		results, raceErr = racer.raceLocal(ctx, root, run, seed, &timing)
	} else {
		results, raceErr = racer.raceCloud(ctx, root, run, race, seed, &timing)
	}
	// Every result again, as the workers kept them: whatever a worker could
	// not post is posted now, the rest replaces itself.
	end := context.WithoutCancel(ctx)
	for _, result := range results {
		path := "/api/runs/" + run.ID + "/results"
		if err := racer.site.post(end, path, normalizedResult(result), nil); err != nil {
			log.Printf("result %s: %v", resultKey(result), err)
		}
	}
	timing.Seconds = watch.since()
	timing.normalize()
	for _, droplet := range timing.Droplets {
		timing.CostUSD += droplet.CostUSD
	}
	status, reason := "finished", ""
	switch {
	case errors.Is(raceErr, errRefused):
		status, reason = "refused", raceErr.Error()
	case raceErr != nil:
		status, reason = "failed", raceErr.Error()
	}
	finished := EndPost{Status: status, Reason: reason,
		FinishedAt: time.Now().UTC().Format(time.RFC3339), Timing: timing}
	if err := racer.site.post(end, "/api/runs/"+run.ID+"/end", finished, nil); err != nil {
		return err
	}
	log.Printf("run %s: %s %s", run.ID, status, reason)
	return raceErr
}

// raceLocal races on this machine: one worker, in this process.
func (racer *Racer) raceLocal(ctx context.Context, root string, run RunPost, seed int64,
	timing *Timing) ([]Result, error) {
	file := filepath.Join(outDir(root), "worker-results.json")
	os.Remove(file)
	raced := time.Now()
	err := runWorker(ctx, root, WorkerConfig{RunID: run.ID,
		Class: ServerClass{Name: "local", Label: "local", Title: "this computer"},
		Seed:  seed, Site: racer.site.base, Token: run.WorkerToken, Results: file})
	timing.RacingSeconds = time.Since(raced).Seconds()
	timing.Classes = []ClassTiming{{Class: "local", Seconds: timing.RacingSeconds}}
	results, readErr := readResults(file)
	if err == nil {
		err = readErr
	}
	return results, err
}

func readResults(path string) ([]Result, error) {
	var results []Result
	bytes, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return results, json.Unmarshal(bytes, &results)
}

// The class's worker runs this long at most (the guard deletes droplets at
// three hours whatever happens).
const workerTimeMax = 150 * time.Minute

// raceCloud races every class on its own pair of droplets at once, a worker
// on each loader.
func (racer *Racer) raceCloud(ctx context.Context, root string, run RunPost, race Race,
	seed int64, timing *Timing) ([]Result, error) {
	prices, err := checkSizes(ctx, racer.provider, race.Cloud)
	if err != nil {
		return nil, err
	}
	tarball := filepath.Join(filepath.Dir(root), "race.tar.gz")
	launched := time.Now()
	fleet, err := launchFleet(ctx, racer.provider, race, run.ID)
	defer fleet.destroy(racer.provider)
	if err != nil {
		return nil, err
	}
	timing.LaunchSeconds = time.Since(launched).Seconds()
	raced := time.Now()
	classes := race.Cloud.Servers
	parts := make([][]Result, len(classes))
	errs := make([]error, len(classes))
	seconds := make([]float64, len(classes))
	var wait sync.WaitGroup
	for i, class := range classes {
		wait.Add(1)
		go func() {
			defer wait.Done()
			started := time.Now()
			parts[i], errs[i] = racer.raceClassWorker(ctx, fleet, class, run, seed, tarball)
			seconds[i] = time.Since(started).Seconds()
			fleet.releaseClass(racer.provider, class.Name)
			if errs[i] != nil {
				errs[i] = fmt.Errorf("%s: %w", class.Name, errs[i])
			}
		}()
	}
	wait.Wait()
	timing.RacingSeconds = time.Since(raced).Seconds()
	var results []Result
	for i, class := range classes {
		results = append(results, parts[i]...)
		timing.Classes = append(timing.Classes, ClassTiming{Class: class.Name, Seconds: seconds[i]})
	}
	fleet.destroy(racer.provider)
	timing.Droplets = fleet.costs(prices)
	return results, errors.Join(errs...)
}

// raceClassWorker starts a class's worker on its loader, waits for it, and
// reads back its results.
func (racer *Racer) raceClassWorker(ctx context.Context, fleet *Fleet, class ServerClass,
	run RunPost, seed int64, tarball string) ([]Result, error) {
	const home = "/root/dragrace"
	loader := fleet.machines[fleet.loaders[class.Name].ID]
	server := fleet.servers[class.Name]
	if err := loader.Put(ctx, tarball, home+"/race.tar.gz"); err != nil {
		return nil, err
	}
	if err := loader.Put(ctx, fleet.private, home+"/key"); err != nil {
		return nil, err
	}
	config := WorkerConfig{RunID: run.ID, Class: class, Seed: seed, Site: racer.site.base,
		Token: run.WorkerToken, ServerHost: server.address("private"), Key: home + "/key",
		KnownHosts: home + "/known_hosts", Attempts: fleet.serverAttempts[class.Name],
		Results: home + "/results.json"}
	encoded, err := json.Marshal(config)
	if err != nil {
		return nil, err
	}
	local := filepath.Join(fleet.dir, "worker-"+class.Name+".json")
	if err := os.WriteFile(local, encoded, 0o600); err != nil {
		return nil, err
	}
	if err := loader.Put(ctx, local, home+"/worker.json"); err != nil {
		return nil, err
	}
	start := strings.Join([]string{
		"chmod 600 " + home + "/key " + home + "/worker.json",
		"mkdir -p " + home + "/bundle",
		"tar -xzf " + home + "/race.tar.gz -C " + home + "/bundle",
		"systemd-run --unit=dragrace-worker --working-directory=" + home + "/bundle " +
			home + "/bundle/out/bin/dragrace worker -config " + home + "/worker.json",
	}, " && ")
	if _, err := loader.Shell(ctx, start); err != nil {
		return nil, err
	}
	log.Printf("[%s] worker started on its loader", class.Name)
	deadline := time.Now().Add(workerTimeMax)
	for {
		if err := sleepContext(ctx, 30*time.Second); err != nil {
			return nil, err
		}
		state, _ := loader.Shell(ctx, "systemctl is-active dragrace-worker; true")
		if state != "active" && state != "activating" {
			break
		}
		if time.Now().After(deadline) {
			loader.Shell(ctx, "systemctl stop dragrace-worker")
			return nil, fmt.Errorf("the worker ran past %s", workerTimeMax)
		}
	}
	text, err := loader.Shell(ctx, "cat "+home+"/results.json")
	if err != nil {
		return nil, fmt.Errorf("the worker's results: %w", err)
	}
	var results []Result
	if err := json.Unmarshal([]byte(text), &results); err != nil {
		return nil, err
	}
	logs, _ := loader.Shell(ctx, "journalctl -u dragrace-worker --no-pager -n 5 -o cat; true")
	log.Printf("[%s] worker done: %d results; its last lines:\n%s", class.Name, len(results), logs)
	return results, nil
}

// remember and forget keep the run racing on the racer's disk: a racer
// restarted mid-run finds it (recover).
func (racer *Racer) remember(id string) {
	if racer.config.State == "" {
		return
	}
	os.WriteFile(filepath.Join(racer.config.State, "racing"), []byte(id), 0o600)
}

func (racer *Racer) forget() {
	if racer.config.State == "" {
		return
	}
	os.Remove(filepath.Join(racer.config.State, "racing"))
}

// recover ends a run a previous racer did not finish (interrupted), and
// deletes every race droplet and key it may have left.
func (racer *Racer) recover(ctx context.Context) {
	if racer.config.State == "" {
		return
	}
	bytes, err := os.ReadFile(filepath.Join(racer.config.State, "racing"))
	if err != nil {
		return
	}
	id := strings.TrimSpace(string(bytes))
	log.Printf("run %s was racing when the racer stopped: ending it", id)
	if racer.provider != nil {
		droplets, _ := racer.provider.dropletsTagged(ctx, "")
		for _, droplet := range droplets {
			racer.provider.deleteDroplet(ctx, droplet.ID)
		}
		keys, _ := racer.provider.keys(ctx)
		for _, key := range keys {
			racer.provider.deleteKey(ctx, key.ID)
		}
	}
	end := EndPost{Status: "interrupted", Reason: "the racer stopped during the run",
		FinishedAt: time.Now().UTC().Format(time.RFC3339), Timing: Timing{}}
	end.Timing.normalize()
	if err := racer.site.post(ctx, "/api/runs/"+url.PathEscape(id)+"/end", end, nil); err != nil {
		log.Printf("ending %s: %v", id, err)
	}
	racer.forget()
}

// update replaces this racer's binary with the newest build's, when that
// is of a newer commit, and exits for systemd to start it again.
func (racer *Racer) update(ctx context.Context) error {
	if buildCommit == "" {
		return nil // built by hand: not updated
	}
	builds, err := racer.github.builds(ctx)
	if err != nil || len(builds) == 0 {
		return err
	}
	newest := builds[0]
	if newest.Info.Commits["fourneau-dragrace"] == buildCommit {
		return nil
	}
	dir := filepath.Join(racer.config.State, "update")
	os.RemoveAll(dir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tarball := filepath.Join(dir, "race.tar.gz")
	if err := racer.github.download(ctx, newest.Assets["race.tar.gz"],
		newest.Info.Files["race.tar.gz"], tarball); err != nil {
		return err
	}
	if err := exec.CommandContext(ctx, "tar", "-xzf", tarball, "-C", dir, "out/bin/dragrace").Run(); err != nil {
		return err
	}
	binary := filepath.Join(racer.config.State, "bin", "dragrace")
	if err := os.MkdirAll(filepath.Dir(binary), 0o755); err != nil {
		return err
	}
	if err := os.Rename(filepath.Join(dir, "out", "bin", "dragrace"), binary+".new"); err != nil {
		return err
	}
	if err := os.Rename(binary+".new", binary); err != nil {
		return err
	}
	log.Printf("updated to %s: restarting", newest.Info.Commits["fourneau-dragrace"])
	os.Exit(0)
	return nil
}
