package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A release in a directory, as GitHub's latest/download serves it.
func publishSite(t *testing.T, dir, content string) string {
	t.Helper()
	sitePath := filepath.Join(t.TempDir(), "dragrace-site")
	if err := os.WriteFile(sitePath, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	tarball := filepath.Join(dir, "site.tar.gz")
	digest, err := writeTarball(tarball, []bundled{{"dragrace-site", sitePath}}, nil)
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
