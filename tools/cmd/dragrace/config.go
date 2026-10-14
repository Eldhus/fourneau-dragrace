package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
)

// Download is a pinned file: oha (race.json), Zig and roc (RouxPins).
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

// Race is race.json: what a race is.
type Race struct {
	Port           int      `json:"port"`
	Rounds         int      `json:"rounds"`
	WarmupSeconds  int      `json:"warmup_seconds"`
	MeasureSeconds int      `json:"measure_seconds"`
	Competitors    []string `json:"competitors"`
	// Oha is the loader's pin (fetchOha): in race.json, so a new oha moves
	// the race key and no competitor's.
	Oha Download `json:"oha"`
	// Tests are race.json's workloads, each sent each of its variants'
	// ways; Workloads are what is raced, a test in one variant, made by
	// loadRace (expand).
	Tests     []Test     `json:"workloads"`
	Workloads []Workload `json:"-"`
	Cloud     Cloud      `json:"cloud"`
	Local     Local      `json:"local"`
	// The templates workload's page, as every competitor must render it
	// (workloads/menu.html), up to how each engine spells an entity.
	Menu string `json:"-"`
	// The SSE workload's stream, event by event (workloads/sse.txt).
	Stream string `json:"-"`
}

// Test is one of race.json's workloads: one request, checked the same and
// answered the same, sent each of its variants' ways (the protocol is a
// dimension of the test, not a test).
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
	// TLS, when set, races the competitor's HTTPS mode (CONTRIBUTING.md);
	// a competitor without one sits the workload out.
	TLS bool `json:"tls,omitempty"`
	// Protocol is the variant's (Variant.Protocol).
	Protocol string `json:"protocol"`
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
			Protocol: protocol.name, Mixed: test.Mixed})
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
	// Label is the class's tab on the site (its size: 512MB/1vCPU);
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

// Competitor is competitors/NAME/competitor.json: how to build it, and
// whether it serves TLS. Every competitor is started the same way
// (startServer): its binary, with roux's variables in its environment.
type Competitor struct {
	Name      string `json:"-"`
	Title     string `json:"title"`
	Language  string `json:"language"`
	Framework string `json:"framework"`
	// Inputs are what its build reads by path outside its directory,
	// relative to this repository (fourneau-zig: fourneau, and roux's
	// vendored SQLite): they make its key (keys.go).
	Inputs []string        `json:"inputs"`
	Build  CompetitorBuild `json:"build"`
	// TLS: it serves HTTPS on the same port when given a certificate and
	// key. false: it sits the TLS workloads out.
	TLS bool `json:"tls"`
}

// CompetitorBuild is one command, run in competitors/NAME
// (buildCompetitor), that writes Binary, a path in that directory.
type CompetitorBuild struct {
	Argv   []string          `json:"argv"`
	Env    map[string]string `json:"env"`
	Binary string            `json:"binary"`
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

func loadRace(root string) (Race, error) {
	var race Race
	if err := readJSON(filepath.Join(root, "race.json"), &race); err != nil {
		return race, err
	}
	if race.Rounds < 1 || race.MeasureSeconds < 1 || len(race.Tests) == 0 || race.Oha.SHA256 == "" {
		return race, fmt.Errorf("race.json: rounds, measure_seconds, workloads and oha must be set")
	}
	menu, err := os.ReadFile(filepath.Join(root, "workloads", "menu.html"))
	if err != nil {
		return race, err
	}
	for _, test := range race.Tests {
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

func workloadNamed(race Race, name string) (Workload, bool) {
	for _, workload := range race.Workloads {
		if workload.Name == name {
			return workload, true
		}
	}
	return Workload{}, false
}

func loadCompetitors(root string, names []string) ([]Competitor, error) {
	competitors := make([]Competitor, 0, len(names))
	for _, name := range names {
		var competitor Competitor
		path := filepath.Join(root, "competitors", name, "competitor.json")
		if err := readJSON(path, &competitor); err != nil {
			return nil, err
		}
		if len(competitor.Build.Argv) == 0 || !filepath.IsLocal(competitor.Build.Binary) {
			return nil, fmt.Errorf("%s: build.argv and build.binary, a path in its directory, "+
				"must be set", path)
		}
		competitor.Name = name
		competitors = append(competitors, competitor)
	}
	return competitors, nil
}

// checkoutPath is where a raced repository is, fourneau or roux: beside
// this one (README, Use it). Each is raced at its newest commit on
// master, which the race records.
func checkoutPath(root, repository string) string {
	return filepath.Clean(filepath.Join(root, "..", repository))
}
