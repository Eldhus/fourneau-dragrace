package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A release in a directory, as GitHub's latest/download serves it.
func publishSite(t *testing.T, dir, content string) string {
	t.Helper()
	return publishSiteWith(t, dir, content, nil)
}

// A release carrying migrations (name: script), as the bundle does.
func publishSiteWith(t *testing.T, dir, content string, migrations map[string]string) string {
	t.Helper()
	sitePath := filepath.Join(t.TempDir(), "dragrace-site")
	if err := os.WriteFile(sitePath, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	var trees []bundledTree
	if migrations != nil {
		migrationsDir := t.TempDir()
		for name, script := range migrations {
			if err := os.WriteFile(filepath.Join(migrationsDir, name), []byte(script), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		trees = append(trees, bundledTree{"migrations", migrationsDir})
	}
	tarball := filepath.Join(dir, "site.tar.gz")
	digest, err := writeTarball(tarball, []bundled{{"dragrace-site", sitePath}}, trees)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := json.Marshal(BuildInfo{Commits: map[string]string{"fourneau-dragrace": content},
		Files: map[string]string{"site.tar.gz": digest}})
	if err := os.WriteFile(filepath.Join(dir, "build.json"), info, 0o644); err != nil {
		t.Fatal(err)
	}
	return digest[:16]
}

func TestHostAgentDeploysAndRollsBack(t *testing.T) {
	published, home := t.TempDir(), t.TempDir()
	restarts, broken := 0, ""
	agent := &HostAgent{config: HostConfig{Repository: "Eldhus/fourneau-dragrace", Home: home,
		Service: "dragrace-site.service", Health: "https://site/api/health"},
		fetch: func(_ context.Context, url, path string) error {
			bytes, err := os.ReadFile(filepath.Join(published, filepath.Base(url)))
			if err != nil {
				return err
			}
			return os.WriteFile(path, bytes, 0o644)
		},
		restart: func(context.Context, string) error { restarts++; return nil },
	}
	ctx := context.Background()
	current := func() string {
		link, _ := os.Readlink(filepath.Join(home, "current"))
		return filepath.Base(link)
	}
	// Every site answers but a broken one.
	agent.healthy = func(context.Context, string) bool { return current() != broken }
	first := publishSite(t, published, "one")
	if err := agent.deploy(ctx); err != nil || current() != first || restarts != 1 {
		t.Fatalf("first: %v, current %s, %d restarts", err, current(), restarts)
	}
	if err := agent.deploy(ctx); err != nil || restarts != 1 {
		t.Fatalf("the same build again: %v, %d restarts", err, restarts)
	}
	second := publishSite(t, published, "two")
	broken = second
	if err := agent.deploy(ctx); err == nil || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("a site that does not answer: %v", err)
	}
	if current() != first || restarts != 3 {
		t.Fatalf("after a failed deploy: current %s, %d restarts", current(), restarts)
	}
	if _, err := os.Stat(filepath.Join(home, "failed", second)); err != nil {
		t.Fatal("the failed build was not marked")
	}
	if err := agent.deploy(ctx); err != nil || restarts != 3 {
		t.Fatalf("a failed build is not tried again: %v, %d restarts", err, restarts)
	}
	third := publishSite(t, published, "three")
	if err := agent.deploy(ctx); err != nil || current() != third {
		t.Fatalf("the next build: %v, current %s", err, current())
	}
	bytes, err := os.ReadFile(filepath.Join(home, "current", "dragrace-site"))
	if err != nil || string(bytes) != "three" {
		t.Fatalf("current's binary %q %v", bytes, err)
	}
	entries, _ := os.ReadDir(filepath.Join(home, "releases"))
	if len(entries) != 2 {
		t.Fatalf("releases kept: %d, want the current and the one before", len(entries))
	}
}

// siteHost is a site host for the agent: a fake database that holds the
// migrations run on it (its copy a file, so a .partial one is never
// read), and a site that answers only on a database holding exactly its
// release's migrations, as roux opens only the schema it was built with.
// Each effect counts a step; at crashAt it panics, as an agent killed.
type siteHost struct {
	t                      *testing.T
	published, home, state string
	database               []string
	stops, steps, crashAt  int
	broken                 string
	agent                  *HostAgent
}

type crashed struct{}

func newSiteHost(t *testing.T) *siteHost {
	host := &siteHost{t: t, published: t.TempDir(), home: t.TempDir(), state: t.TempDir(),
		database: []string{"a.sql"}} // the first site made it: release one's schema
	os.MkdirAll(filepath.Join(host.state, "backups"), 0o755)
	host.agent = &HostAgent{config: HostConfig{Home: host.home, Service: "dragrace-site.service",
		Database: filepath.Join(host.state, "site.db"), User: "site"},
		fetch: func(_ context.Context, url, path string) error {
			bytes, err := os.ReadFile(filepath.Join(host.published, filepath.Base(url)))
			if err != nil {
				return err
			}
			return os.WriteFile(path, bytes, 0o644)
		},
		restart: func(context.Context, string) error { host.step(); return nil },
		stop:    func(context.Context, string) error { host.step(); host.stops++; return nil },
		healthy: func(context.Context, string) bool { host.step(); return host.answers() },
		sqlite:  host.sqlite,
	}
	return host
}

func (host *siteHost) step() {
	host.steps++
	if host.steps == host.crashAt {
		panic(crashed{})
	}
}

func (host *siteHost) current() string {
	link, _ := os.Readlink(filepath.Join(host.home, "current"))
	return link
}

func (host *siteHost) answers() bool {
	binary, _ := os.ReadFile(filepath.Join(host.current(), "dragrace-site"))
	if string(binary) == host.broken {
		return false
	}
	entries, _ := os.ReadDir(filepath.Join(host.current(), "migrations"))
	var carried []string
	for _, entry := range entries {
		carried = append(carried, entry.Name())
	}
	return strings.Join(carried, " ") == host.holds()
}

func (host *siteHost) holds() string { return strings.Join(host.database, " ") }

func (host *siteHost) sqlite(_ context.Context, script string) error {
	host.step()
	quoted := func() string { return script[strings.Index(script, "'")+1 : strings.LastIndex(script, "'")] }
	switch {
	case strings.HasPrefix(script, "VACUUM INTO '"):
		return os.WriteFile(quoted(), []byte(host.holds()), 0o644)
	case strings.HasPrefix(script, ".restore '"):
		bytes, err := os.ReadFile(quoted())
		if err != nil {
			return err
		}
		host.database = strings.Fields(string(bytes))
	case strings.Contains(script, "fails"):
		return fmt.Errorf("Parse error near line 1")
	default:
		host.database = append(host.database, script)
	}
	return nil
}

// deploy publishes a site carrying migrations (each script its own name),
// and runs the agent once; a crash is reported, not raised.
func (host *siteHost) deploy(site string, migrations ...string) (err error, crash bool) {
	host.t.Helper()
	scripts := map[string]string{}
	for _, name := range migrations {
		scripts[name] = name
	}
	if site != "" {
		publishSiteWith(host.t, host.published, site, scripts)
	}
	defer func() {
		if recovered := recover(); recovered != nil {
			if _, ok := recovered.(crashed); !ok {
				panic(recovered)
			}
			crash = true
		}
	}()
	return host.agent.deploy(context.Background()), false
}

func TestHostAgentMigrates(t *testing.T) {
	host := newSiteHost(t)
	if err, _ := host.deploy("one", "a.sql"); err != nil || host.stops != 0 {
		t.Fatalf("the first site: %v, %d stops", err, host.stops)
	}
	if err, _ := host.deploy("two", "a.sql", "b.sql"); err != nil || host.stops != 1 {
		t.Fatalf("one migration: %v, %d stops", err, host.stops)
	}
	copies, _ := filepath.Glob(filepath.Join(host.state, "backups", "pre-migration-*.db"))
	if len(copies) != 1 {
		t.Fatalf("copies %v", copies)
	}
	serving := host.current()
	host.agent.sqlite = func(ctx context.Context, script string) error {
		if strings.TrimSpace(script) == "c.sql" {
			script = "fails"
		}
		return host.sqlite(ctx, script)
	}
	err, _ := host.deploy("three", "a.sql", "b.sql", "c.sql")
	if err == nil || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("a migration that fails: %v", err)
	}
	if host.current() != serving || host.holds() != "a.sql b.sql" {
		t.Fatalf("after a failed migration: %s on %v", host.current(), host.database)
	}
	host.broken = "four"
	err, _ = host.deploy("four", "a.sql", "b.sql", "d.sql")
	if err == nil || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("migrated, then not answering: %v", err)
	}
	if host.current() != serving || host.holds() != "a.sql b.sql" {
		t.Fatalf("after a site that did not answer: %s on %v", host.current(), host.database)
	}
	host.broken = ""
	if err, _ := host.deploy("five", "a.sql", "b.sql", "e.sql"); err != nil || host.holds() != "a.sql b.sql e.sql" {
		t.Fatalf("the next build: %v, on %v", err, host.database)
	}
	if _, err := os.Stat(host.agent.journalPath()); err == nil {
		t.Fatal("a journal left after deploys that ended")
	}
}

// An agent killed at any step of a deploy with migrations (a reboot) is
// ended by the next run, and the build tried again: the host ends serving
// the new site on its migrations, never a site on a database not its own.
func TestHostAgentFinishesAnInterruptedDeploy(t *testing.T) {
	for crashAt := 1; ; crashAt++ {
		host := newSiteHost(t)
		if err, _ := host.deploy("one", "a.sql"); err != nil {
			t.Fatal(err)
		}
		host.steps, host.crashAt = 0, crashAt
		_, crash := host.deploy("two", "a.sql", "b.sql", "c.sql")
		if !crash {
			if crashAt < 4 {
				t.Fatalf("a deploy of %d steps", crashAt)
			}
			break // every step has been a crash
		}
		host.crashAt = 0
		for run := 1; ; run++ {
			if run > 3 {
				t.Fatalf("crash at step %d: not ended in 3 runs: %s on %v", crashAt,
					filepath.Base(host.current()), host.database)
			}
			host.deploy("")
			if host.answers() && host.holds() == "a.sql b.sql c.sql" {
				break
			}
		}
		if _, err := os.Stat(host.agent.journalPath()); err == nil {
			t.Fatalf("crash at step %d: the journal left", crashAt)
		}
		failed, _ := os.ReadDir(filepath.Join(host.home, "failed"))
		if len(failed) != 0 {
			t.Fatalf("crash at step %d: the build marked failed", crashAt)
		}
	}
}

// A release from before the bundle carried migrations says nothing about
// its database's: nothing is pending, whatever the new release carries.
func TestPendingMigrations(t *testing.T) {
	old, current, release := t.TempDir(), t.TempDir(), t.TempDir()
	for _, dir := range []string{current, release} {
		os.MkdirAll(filepath.Join(dir, "migrations"), 0o755)
	}
	for _, name := range []string{"2026-10-10-a.sql", "2026-10-11-b.sql"} {
		os.WriteFile(filepath.Join(current, "migrations", name), nil, 0o644)
	}
	for _, name := range []string{"2026-10-10-a.sql", "2026-10-11-b.sql", "2026-10-13-d.sql",
		"2026-10-12-c.sql", "README"} {
		os.WriteFile(filepath.Join(release, "migrations", name), nil, 0o644)
	}
	got := strings.Join(pendingMigrations(current, release), " ")
	if got != "2026-10-12-c.sql 2026-10-13-d.sql" {
		t.Fatalf("pending: %q", got)
	}
	if pending := pendingMigrations(old, release); pending != nil {
		t.Fatalf("from a release without migrations/: %v", pending)
	}
	if pending := pendingMigrations("", release); pending != nil {
		t.Fatalf("a first site: %v", pending)
	}
}

func TestHostAgentRefusesATarballThatIsNotTheBuilds(t *testing.T) {
	published, home := t.TempDir(), t.TempDir()
	publishSite(t, published, "one")
	os.WriteFile(filepath.Join(published, "site.tar.gz"), []byte("tampered"), 0o644)
	agent := &HostAgent{config: HostConfig{Home: home},
		fetch: func(_ context.Context, url, path string) error {
			bytes, _ := os.ReadFile(filepath.Join(published, filepath.Base(url)))
			return os.WriteFile(path, bytes, 0o644)
		},
		restart: func(context.Context, string) error { t.Fatal("restarted"); return nil },
		healthy: func(context.Context, string) bool { return true },
	}
	if err := agent.deploy(context.Background()); err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("%v", err)
	}
}
