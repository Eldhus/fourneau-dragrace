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

func TestHostAgentMigrates(t *testing.T) {
	published, home, state := t.TempDir(), t.TempDir(), t.TempDir()
	database := []string{"a.sql"} // the first site made it: release one's schema
	var copied []string
	stops, broken := 0, ""
	current := func() string {
		link, _ := os.Readlink(filepath.Join(home, "current"))
		return link
	}
	agent := &HostAgent{config: HostConfig{Home: home, Service: "dragrace-site.service",
		Database: filepath.Join(state, "site.db"), User: "site"},
		fetch: func(_ context.Context, url, path string) error {
			bytes, err := os.ReadFile(filepath.Join(published, filepath.Base(url)))
			if err != nil {
				return err
			}
			return os.WriteFile(path, bytes, 0o644)
		},
		restart: func(context.Context, string) error { return nil },
		stop:    func(context.Context, string) error { stops++; return nil },
		healthy: func(context.Context, string) bool {
			if binary, _ := os.ReadFile(filepath.Join(current(), "dragrace-site")); string(binary) == broken {
				return false
			}
			entries, _ := os.ReadDir(filepath.Join(current(), "migrations"))
			var carried []string
			for _, entry := range entries {
				carried = append(carried, entry.Name())
			}
			return strings.Join(carried, " ") == strings.Join(database, " ")
		},
		sqlite: func(_ context.Context, script string) error {
			switch {
			case strings.HasPrefix(script, "VACUUM INTO '"+filepath.Join(state, "backups")):
				copied = append([]string(nil), database...)
			case strings.HasPrefix(script, ".restore '"+filepath.Join(state, "backups")):
				database = append([]string(nil), copied...)
			case strings.Contains(script, "fails"):
				return fmt.Errorf("Parse error near line 1")
			default:
				database = append(database, script)
			}
			return nil
		},
	}
	ctx := context.Background()
	deploy := func(site string, migrations map[string]string) error {
		t.Helper()
		publishSiteWith(t, published, site, migrations)
		return agent.deploy(ctx)
	}
	one := map[string]string{"a.sql": "a.sql"}
	if err := deploy("one", one); err != nil || stops != 0 {
		t.Fatalf("the first site: %v, %d stops", err, stops)
	}
	two := map[string]string{"a.sql": "a.sql", "b.sql": "b.sql"}
	if err := deploy("two", two); err != nil || stops != 1 || len(copied) != 1 {
		t.Fatalf("one migration: %v, %d stops, copied %v", err, stops, copied)
	}
	serving := current()
	three := map[string]string{"a.sql": "a.sql", "b.sql": "b.sql", "c.sql": "fails"}
	if err := deploy("three", three); err == nil || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("a migration that fails: %v", err)
	}
	if current() != serving || strings.Join(database, " ") != "a.sql b.sql" {
		t.Fatalf("after a failed migration: %s on %v", current(), database)
	}
	four := map[string]string{"a.sql": "a.sql", "b.sql": "b.sql", "d.sql": "d.sql"}
	broken = "four"
	if err := deploy("four", four); err == nil || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("migrated, then not answering: %v", err)
	}
	if current() != serving || strings.Join(database, " ") != "a.sql b.sql" {
		t.Fatalf("after a site that did not answer: %s on %v", current(), database)
	}
	broken = ""
	five := map[string]string{"a.sql": "a.sql", "b.sql": "b.sql", "e.sql": "e.sql"}
	if err := deploy("five", five); err != nil || strings.Join(database, " ") != "a.sql b.sql e.sql" {
		t.Fatalf("the next build: %v, on %v", err, database)
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
