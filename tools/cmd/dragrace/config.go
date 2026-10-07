package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Versions is versions.json: every pin a race depends on.
type Versions struct {
	Zig          Download `json:"zig"`
	Roc          Download `json:"roc"`
	RocMusl      RocMusl  `json:"roc_musl"`
	Oha          Download `json:"oha"`
	Go           Note     `json:"go"`
	Rust         Note     `json:"rust"`
	Axum         Note     `json:"axum"`
	Tokio        Note     `json:"tokio"`
	DropletImage string   `json:"droplet_image"`
	RunnerImage  string   `json:"runner_image"`
	Fourneau     Checkout `json:"fourneau"`
	Roux         Checkout `json:"roux"`
}

type Download struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
}

type RocMusl struct {
	Commit string            `json:"commit"`
	URL    string            `json:"url"`
	Files  map[string]string `json:"files"`
}

type Note struct {
	Version  string `json:"version"`
	PinnedIn string `json:"pinned_in"`
}

// Checkout is a repository raced at its newest commit, cloned beside this
// one: fourneau, and roux on it.
type Checkout struct {
	Repository string `json:"repository"`
	Branch     string `json:"branch"`
	Checkout   string `json:"checkout"`
}

// Race is race.json: what a race is.
type Race struct {
	Port           int        `json:"port"`
	Rounds         int        `json:"rounds"`
	WarmupSeconds  int        `json:"warmup_seconds"`
	MeasureSeconds int        `json:"measure_seconds"`
	Competitors    []string   `json:"competitors"`
	Workloads      []Workload `json:"workloads"`
	Cloud          Cloud      `json:"cloud"`
	Local          Local      `json:"local"`
	OpenLoop       OpenLoop   `json:"open_loop"`
	// The templates workload's page, as every competitor must render it
	// (workloads/menu.html), up to how each engine spells an entity.
	Menu string `json:"-"`
	// The SSE workload's stream, event by event (workloads/sse.txt).
	Stream string `json:"-"`
}

type Workload struct {
	Name        string `json:"name"`
	Title       string `json:"title"`
	Summary     string `json:"summary"`
	Method      string `json:"method"`
	Path        string `json:"path"`
	BodyBytes   int    `json:"body_bytes"`
	ContentType string `json:"content_type"`
	Connections int    `json:"connections"`
	Keepalive   bool   `json:"keepalive"`
	// Mixed, when set, makes this an open-loop-only workload of several
	// parts at once (mixed.go): conduit.
	Mixed *Mixed `json:"mixed,omitempty"`
}

// kind is how the site draws a workload: "closed" (bars of the rounds) or
// "mixed" (a line, latency against the rate offered).
func (workload Workload) kind() string {
	if workload.Mixed != nil {
		return "mixed"
	}
	return "closed"
}

// hasMixed says whether a race needs the conduit database.
func (race Race) hasMixed() bool {
	for _, workload := range race.Workloads {
		if workload.Mixed != nil {
			return true
		}
	}
	return false
}

type Cloud struct {
	Region        string        `json:"region"`
	Image         string        `json:"image"`
	Servers       []ServerClass `json:"servers"`
	Tag           string        `json:"tag"`
	MaxAgeMinutes int           `json:"max_age_minutes"`
}

// ServerClass is one kind of server droplet and the loader that races it:
// a loader with more vCPUs than its server, so that the server, not oha,
// is what runs out (checkSizes).
type ServerClass struct {
	Name string `json:"name"`
	// Label is the class's tab on the site (a size: small, medium);
	// Title, its heading, says what the class is for.
	Label      string `json:"label"`
	Title      string `json:"title"`
	Size       string `json:"size"`
	LoaderSize string `json:"loader_size"`
}

type Local struct {
	ServerCPUs string `json:"server_cpus"`
	LoaderCPUs string `json:"loader_cpus"`
}

// Competitor is competitors/NAME/competitor.json: how to build and run it.
type Competitor struct {
	Name      string            `json:"-"`
	Title     string            `json:"title"`
	Language  string            `json:"language"`
	Framework string            `json:"framework"`
	Links     map[string]string `json:"links"`
	Build     []Step            `json:"build"`
	Run       RunSpec           `json:"run"`
}

type Step struct {
	Cwd  string            `json:"cwd"`
	Argv []string          `json:"argv"`
	Env  map[string]string `json:"env"`
}

type RunSpec struct {
	Argv []string          `json:"argv"`
	Env  map[string]string `json:"env"`
	// FixedPort: the competitor cannot be told a port (its app names it).
	FixedPort int `json:"fixed_port"`
}

func readJSON(path string, into any) error {
	bytes, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(bytes, into); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}

func loadVersions(root string) (Versions, error) {
	var versions Versions
	err := readJSON(filepath.Join(root, "versions.json"), &versions)
	return versions, err
}

func loadRace(root string) (Race, error) {
	var race Race
	if err := readJSON(filepath.Join(root, "race.json"), &race); err != nil {
		return race, err
	}
	if race.Rounds < 1 || race.MeasureSeconds < 1 || len(race.Workloads) == 0 {
		return race, fmt.Errorf("race.json: rounds, measure_seconds and workloads must be set")
	}
	menu, err := os.ReadFile(filepath.Join(root, "workloads", "menu.html"))
	if err != nil {
		return race, err
	}
	if race.OpenLoop.enabled() {
		if _, found := workloadNamed(race, race.OpenLoop.Workload); !found {
			return race, fmt.Errorf("race.json: open_loop names no workload %q", race.OpenLoop.Workload)
		}
	}
	race.Menu = string(menu)
	stream, err := os.ReadFile(filepath.Join(root, "workloads", "sse.txt"))
	if err != nil {
		return race, err
	}
	race.Stream = string(stream)
	return race, nil
}

func loadCompetitors(root string, names []string) ([]Competitor, error) {
	competitors := make([]Competitor, 0, len(names))
	for _, name := range names {
		var competitor Competitor
		path := filepath.Join(root, "competitors", name, "competitor.json")
		if err := readJSON(path, &competitor); err != nil {
			return nil, err
		}
		competitor.Name = name
		if competitor.Run.FixedPort != 0 && competitor.Run.FixedPort != 8080 {
			return nil, fmt.Errorf("%s: a fixed port must be the race's 8080", name)
		}
		competitors = append(competitors, competitor)
	}
	return competitors, nil
}

// checkoutPath is where a raced repository is: beside this one.
func checkoutPath(root string, checkout Checkout) string {
	return filepath.Clean(filepath.Join(root, checkout.Checkout))
}

// OpenLoop is the race's open-loop test (open_loop.go): one workload, at
// fixed offered rates, each a share of the server's own closed-loop
// median, held long enough for a steady state.
type OpenLoop struct {
	Workload       string    `json:"workload"`
	Shares         []float64 `json:"shares"`
	WarmupSeconds  int       `json:"warmup_seconds"`
	MeasureSeconds int       `json:"measure_seconds"`
}

func (open OpenLoop) enabled() bool { return open.Workload != "" && len(open.Shares) > 0 }
