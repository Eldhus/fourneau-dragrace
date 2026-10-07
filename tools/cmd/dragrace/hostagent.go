package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// The host agent deploys the site (docs/self-hosting.md, "Builds and
// deploys"). A timer runs it every minute, as root: it reads the newest
// release's build.json; a site not yet deployed is downloaded, checked,
// unpacked beside the others, made current, and the site restarted; if it
// does not answer /api/health within 30 s, the previous one is made
// current again and that build is never tried again. Installed by the
// owner (dragrace site install-host), never updated by a build.

// HostConfig is the owner's, on the site host (/etc/dragrace-host).
type HostConfig struct {
	Repository string `json:"repository"` // owner/name
	// The site's code: releases/ID, and current, a link to one of them.
	Home    string `json:"home"`
	Service string `json:"service"`
	// The site's health, as the agent asks it (its certificate is for the
	// host's address).
	Health string `json:"health"`
}

// healthWait is how long a new site has to answer.
const healthWait = 30 * time.Second

func commandHostAgent(ctx context.Context, args []string) error {
	flags := newFlags("host-agent")
	path := flags.String("config", "/etc/dragrace-host/config.json", "the owner's config")
	flags.Parse(args)
	var config HostConfig
	if err := readJSON(*path, &config); err != nil {
		return err
	}
	agent := &HostAgent{config: config, fetch: httpFetch, restart: systemctlRestart,
		healthy: httpHealthy}
	return agent.deploy(ctx)
}

// HostAgent is the agent, its effects apart so a test can stand in.
type HostAgent struct {
	config  HostConfig
	fetch   func(ctx context.Context, url, path string) error
	restart func(ctx context.Context, service string) error
	healthy func(ctx context.Context, url string) bool
}

func (agent *HostAgent) latest(name string) string {
	return "https://github.com/" + agent.config.Repository + "/releases/latest/download/" + name
}

// deploy makes the newest build's site current, unless it is, or failed.
func (agent *HostAgent) deploy(ctx context.Context) error {
	home := agent.config.Home
	work := filepath.Join(home, "download")
	if err := os.MkdirAll(work, 0o755); err != nil {
		return err
	}
	infoPath := filepath.Join(work, "build.json")
	if err := agent.fetch(ctx, agent.latest("build.json"), infoPath); err != nil {
		return err
	}
	var info BuildInfo
	if err := readJSON(infoPath, &info); err != nil {
		return err
	}
	digest := info.Files["site.tar.gz"]
	if len(digest) != 64 {
		return fmt.Errorf("build.json: no site.tar.gz")
	}
	id := digest[:16]
	if _, err := os.Stat(filepath.Join(home, "failed", id)); err == nil {
		return nil // tried, and it did not answer: the next build will do
	}
	current, _ := os.Readlink(filepath.Join(home, "current"))
	if filepath.Base(current) == id {
		return nil
	}
	tarball := filepath.Join(work, "site.tar.gz")
	if err := agent.fetch(ctx, agent.latest("site.tar.gz"), tarball); err != nil {
		return err
	}
	if got, err := fileSHA256(tarball); err != nil || got != digest {
		// The latest release moved between the two downloads: next minute.
		return fmt.Errorf("site.tar.gz: SHA-256 %s, build.json says %s (%v)", got, digest, err)
	}
	release := filepath.Join(home, "releases", id)
	os.RemoveAll(release + ".new")
	if err := os.MkdirAll(release+".new", 0o755); err != nil {
		return err
	}
	if err := exec.CommandContext(ctx, "tar", "-xzf", tarball, "-C", release+".new").Run(); err != nil {
		return err
	}
	os.RemoveAll(release)
	if err := os.Rename(release+".new", release); err != nil {
		return err
	}
	log.Printf("deploying site %s (dragrace %s, roux %s)", id, short(info.Commits["fourneau-dragrace"]),
		short(info.Commits["roux"]))
	if err := agent.switchTo(ctx, release); err != nil {
		return err
	}
	if agent.healthy(ctx, agent.config.Health) {
		log.Printf("site %s is serving", id)
		pruneReleases(filepath.Join(home, "releases"), filepath.Base(release), filepath.Base(current))
		return nil
	}
	log.Printf("site %s did not answer in %s: back to %s (a schema change wants a migration "+
		"over SSH: SECURITY.md)", id, healthWait, filepath.Base(current))
	os.MkdirAll(filepath.Join(home, "failed"), 0o755)
	os.WriteFile(filepath.Join(home, "failed", id), []byte(time.Now().UTC().Format(time.RFC3339)), 0o644)
	if current == "" {
		return fmt.Errorf("site %s failed, and there is no previous one", id)
	}
	if err := agent.switchTo(ctx, current); err != nil {
		return err
	}
	if !agent.healthy(ctx, agent.config.Health) {
		return fmt.Errorf("the previous site does not answer either")
	}
	return fmt.Errorf("site %s rolled back", id)
}

func short(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

// switchTo points current at a release, atomically, and restarts the site.
func (agent *HostAgent) switchTo(ctx context.Context, release string) error {
	link := filepath.Join(agent.config.Home, "current")
	os.Remove(link + ".new")
	if err := os.Symlink(release, link+".new"); err != nil {
		return err
	}
	if err := os.Rename(link+".new", link); err != nil {
		return err
	}
	return agent.restart(ctx, agent.config.Service)
}

// pruneReleases keeps the releases named, and deletes the rest.
func pruneReleases(dir string, keep ...string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		kept := false
		for _, wanted := range keep {
			kept = kept || name == wanted
		}
		if !kept {
			os.RemoveAll(filepath.Join(dir, name))
		}
	}
}

func httpFetch(ctx context.Context, url, path string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 10 * time.Minute}
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
	_, copyErr := io.Copy(file, io.LimitReader(response.Body, 1<<30))
	if err := file.Close(); err != nil {
		return err
	}
	return copyErr
}

func systemctlRestart(ctx context.Context, service string) error {
	output, err := exec.CommandContext(ctx, "systemctl", "restart", service).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl restart %s: %v: %s", service, err, strings.TrimSpace(string(output)))
	}
	return nil
}

// httpHealthy asks the health URL until it answers 200 with {"ok":true},
// for healthWait.
func httpHealthy(ctx context.Context, url string) bool {
	client := &http.Client{Timeout: 5 * time.Second}
	deadline := time.Now().Add(healthWait)
	for time.Now().Before(deadline) {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return false
		}
		if response, err := client.Do(request); err == nil {
			var answer struct{ OK bool }
			decodeErr := json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&answer)
			response.Body.Close()
			if response.StatusCode == http.StatusOK && decodeErr == nil && answer.OK {
				return true
			}
		}
		if sleepContext(ctx, time.Second) != nil {
			return false
		}
	}
	return false
}
