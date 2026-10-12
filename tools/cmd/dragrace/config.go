package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Versions is versions.json: every pin a race depends on but Zig and roc,
// which are roux's (RouxPins).
type Versions struct {
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
	Port           int      `json:"port"`
	Rounds         int      `json:"rounds"`
	WarmupSeconds  int      `json:"warmup_seconds"`
	MeasureSeconds int      `json:"measure_seconds"`
	Competitors    []string `json:"competitors"`
	// Tests are race.json's workloads, each sent each of its variants'
	// ways; Workloads are what is raced, a test in one variant, made by
	// loadRace (expand).
	Tests     []Test     `json:"workloads"`
	Workloads []Workload `json:"-"`
	Cloud     Cloud      `json:"cloud"`
	Local     Local      `json:"local"`
	OpenLoop  OpenLoop   `json:"open_loop"`
	// The templates workload's page, as every competitor must render it
	// (workloads/menu.html), up to how each engine spells an entity.
	Menu string `json:"-"`
	// The SSE workload's stream, event by event (workloads/sse.txt).
	Stream string `json:"-"`
}

// Test is one of race.json's workloads: one request, checked the same and
// answered the same, sent each of its variants' ways (the protocol is a dimension of the test, not a test).
type Test struct {
	Name  string `json:"name"`
	Title string `json:"title"`
	// Summary is the one line under each of the test's charts; Detail is
	// the Workloads page's longer text after it (the site reads it from
	// the run's race.json).
	Summary     string `json:"summary"`
	Detail      string `json:"detail"`
	Method      string `json:"method"`
	Path        string `json:"path"`
	BodyBytes   int    `json:"body_bytes,omitempty"`
	ContentType string `json:"content_type,omitempty"`
	Keepalive   bool   `json:"keepalive"`
	// Ladder, when set, climbs the open-loop ladder after the rounds
	// (open_loop.go).
	Ladder bool `json:"ladder,omitempty"`
	// Mixed, when set, makes this an open-loop-only test of several parts
	// at once (mixed.go): conduit.
	Mixed    *Mixed    `json:"mixed,omitempty"`
	Variants []Variant `json:"variants"`
}

// Variant is one way a test is sent: its protocol and the loader's
// connections.
type Variant struct {
	// Protocol is "http1" (HTTP/1.1), "h2c" (HTTP/2 without TLS, by prior
	// knowledge) or "tls" (the competitor's HTTPS mode: HTTP/2
	// by ALPN when Streams is set, else HTTP/1.1).
	Protocol    string `json:"protocol"`
	Connections int    `json:"connections"`
	// Streams is HTTP/2's requests at once a connection (oha --http2 -p);
	// 0 is HTTP/1.1.
	Streams int `json:"streams,omitempty"`
}

// protocols are a variant's, in the site's order, each with what it adds
// to its test's name: `plaintext`, `plaintext-h2`, `plaintext-tls`, the
// names the races had before tests had variants.
var protocols = []struct{ name, suffix string }{{"http1", ""}, {"h2c", "-h2"}, {"tls", "-tls"}}

// Workload is what is raced: a test in one variant.
type Workload struct {
	Name string `json:"name"`
	// Test is the test's name: the HTTP/1.1 variant's own.
	Test        string `json:"test"`
	Title       string `json:"title"`
	Summary     string `json:"summary"`
	Method      string `json:"method"`
	Path        string `json:"path"`
	BodyBytes   int    `json:"body_bytes"`
	ContentType string `json:"content_type"`
	Connections int    `json:"connections"`
	Keepalive   bool   `json:"keepalive"`
	// HTTP2, when set, sends over HTTP/2, each connection carrying
	// Streams requests at once (oha --http2 -p): by prior knowledge (h2c),
	// or by ALPN when TLS is set too.
	HTTP2   bool `json:"http2,omitempty"`
	Streams int  `json:"streams,omitempty"`
	// TLS, when set, races the competitor's HTTPS mode (CONTRIBUTING.md, "The contract");
	// a competitor without one sits the workload out.
	TLS bool `json:"tls,omitempty"`
	// Protocol is the variant's (Variant.Protocol).
	Protocol string `json:"protocol"`
	Ladder   bool   `json:"ladder,omitempty"`
	Mixed    *Mixed `json:"mixed,omitempty"`
}

// expand makes a test's workloads, a variant each, in protocols' order.
// A test has a summary and a detail, and an HTTP/1.1 variant: its name is
// the test's.
func (test Test) expand() ([]Workload, error) {
	if test.Name == "" || test.Summary == "" || test.Detail == "" {
		return nil, fmt.Errorf("race.json: %q: a name, a summary and a detail", test.Name)
	}
	var workloads []Workload
	for _, protocol := range protocols {
		i := slices.IndexFunc(test.Variants, func(v Variant) bool { return v.Protocol == protocol.name })
		if i < 0 {
			continue
		}
		variant := test.Variants[i]
		name := test.Name + protocol.suffix
		if variant.Connections < 1 {
			return nil, fmt.Errorf("race.json: %s: no connections", name)
		}
		if (protocol.name == "http1" && variant.Streams != 0) || (protocol.name == "h2c" && variant.Streams < 1) {
			return nil, fmt.Errorf("race.json: %s: HTTP/1.1 has no streams, h2c has", name)
		}
		if variant.Streams > 0 && !test.Keepalive {
			return nil, fmt.Errorf("race.json: %s: oha's HTTP/2 always keeps connections", name)
		}
		title := test.Title
		if protocol.name != "http1" {
			title += ", " + protocolLabel(protocol.name, variant.Streams > 0)
		}
		workloads = append(workloads, Workload{Name: name, Test: test.Name, Title: title,
			Summary: test.Summary, Method: test.Method, Path: test.Path,
			BodyBytes: test.BodyBytes, ContentType: test.ContentType,
			Connections: variant.Connections, Keepalive: test.Keepalive,
			HTTP2: variant.Streams > 0, Streams: variant.Streams, TLS: protocol.name == "tls",
			Protocol: protocol.name, Ladder: test.Ladder, Mixed: test.Mixed})
	}
	if len(workloads) != len(test.Variants) || len(workloads) == 0 || workloads[0].Protocol != "http1" {
		return nil, fmt.Errorf("race.json: %s: an HTTP/1.1 variant, and each protocol once of %v",
			test.Name, protocols)
	}
	return workloads, nil
}

// protocolLabel is how the site names a variant's protocol: "HTTP/2 + TLS",
// or "HTTP/1.1 + TLS" over TLS without HTTP/2 (churn).
func protocolLabel(protocol string, http2 bool) string {
	switch {
	case protocol == "h2c":
		return "HTTP/2 (h2c)"
	case protocol == "tls" && http2:
		return "HTTP/2 + TLS"
	case protocol == "tls":
		return "HTTP/1.1 + TLS"
	}
	return "HTTP/1.1"
}

// hasH2C says whether a race checks that competitors speak h2c.
func (race Race) hasH2C() bool {
	for _, workload := range race.Workloads {
		if workload.HTTP2 && !workload.TLS {
			return true
		}
	}
	return false
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

// opensDatabase: the competitor's command names {db}, so it opens the
// seeded database at start whatever the race's workloads.
func (competitor Competitor) opensDatabase() bool {
	names := func(args []string, env map[string]string) bool {
		for _, arg := range args {
			if strings.Contains(arg, "{db}") {
				return true
			}
		}
		for _, value := range env {
			if strings.Contains(value, "{db}") {
				return true
			}
		}
		return false
	}
	run := competitor.Run
	return names(run.Argv, run.Env) || run.TLS != nil && names(run.TLS.Argv, run.TLS.Env)
}

// needsDatabase: the server gets the seeded database, for a mixed workload
// or for a competitor that opens it at start.
func needsDatabase(race Race, competitors []Competitor) bool {
	return race.hasMixed() || slices.ContainsFunc(competitors, Competitor.opensDatabase)
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
	// TLS is how the competitor serves HTTPS on the same port: arguments
	// appended and environment added ({cert}, {key}: PEM files). Absent:
	// it serves no TLS, and sits the TLS workloads out.
	TLS *RunTLS `json:"tls,omitempty"`
}

type RunTLS struct {
	Argv []string          `json:"argv"`
	Env  map[string]string `json:"env"`
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
	if race.Rounds < 1 || race.MeasureSeconds < 1 || len(race.Tests) == 0 {
		return race, fmt.Errorf("race.json: rounds, measure_seconds and workloads must be set")
	}
	menu, err := os.ReadFile(filepath.Join(root, "workloads", "menu.html"))
	if err != nil {
		return race, err
	}
	for _, test := range race.Tests {
		if test.Ladder && (test.Mixed != nil || len(race.OpenLoop.Shares) == 0) {
			return race, fmt.Errorf("race.json: %s: a ladder needs rounds and open_loop's shares",
				test.Name)
		}
		workloads, err := test.expand()
		if err != nil {
			return race, err
		}
		race.Workloads = append(race.Workloads, workloads...)
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

// OpenLoop is the race's open-loop test (open_loop.go): each workload
// marked `ladder`, at fixed offered rates, each a share of the server's
// own closed-loop best, held long enough for a steady state.
type OpenLoop struct {
	Shares         []float64 `json:"shares"`
	WarmupSeconds  int       `json:"warmup_seconds"`
	MeasureSeconds int       `json:"measure_seconds"`
}
