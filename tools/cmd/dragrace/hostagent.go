package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// The host agent deploys the site. A timer runs it every minute, as root: it reads the newest
// release's build.json; a site not yet deployed is downloaded, checked,
// unpacked beside the others, made current, and the site restarted; if it
// does not answer /api/health within 30 s, the previous one is made
// current again and that build is never tried again. Installed by the
// owner (dragrace site install-server), never updated by a build.
//
// A release carries the site's migrations (site/migrations). The site
// serving answered its health, so its database holds every migration its
// release carries: those the new release carries beyond them are run,
// with the site stopped, after a copy of the database; if the new site
// then does not answer, the copy is put back with the old site.

// HostConfig is the owner's, on the site host (/etc/dragrace-host).
type HostConfig struct {
	Repository string `json:"repository"` // owner/name
	// The site's code: releases/ID, and current, a link to one of them.
	Home    string `json:"home"`
	Service string `json:"service"`
	// The site's health, as the agent asks it (its certificate is for the
	// host's address).
	Health string `json:"health"`
	// The site's database and the user it runs as, for migrations; empty in
	// a config from before 2026-10-12, which migrates nothing.
	Database string `json:"database"`
	User     string `json:"user"`
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
		stop: systemctlStop, healthy: httpHealthy,
		sqlite: func(ctx context.Context, script string) error {
			return runSQLite(ctx, config.User, config.Database, script)
		}}
	return agent.deploy(ctx)
}

// HostAgent is the agent, its effects apart so a test can stand in.
type HostAgent struct {
	config  HostConfig
	fetch   func(ctx context.Context, url, path string) error
	restart func(ctx context.Context, service string) error
	stop    func(ctx context.Context, service string) error
	healthy func(ctx context.Context, url string) bool
	// sqlite runs a script on the site's database as the site's user,
	// stopping at the first statement that fails.
	sqlite func(ctx context.Context, script string) error
}

func (agent *HostAgent) latest(name string) string {
	return "https://github.com/" + agent.config.Repository + "/releases/latest/download/" + name
}

// deploy makes the newest build's site current, unless it is, or failed.
// A deploy the agent did not finish is ended first.
func (agent *HostAgent) deploy(ctx context.Context) error {
	if found, err := agent.finishInterrupted(ctx); found {
		return err
	}
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
	pending := pendingMigrations(current, release)
	if len(pending) > 0 && agent.config.Database == "" {
		log.Printf("site %s carries migrations %v, but this agent's config names no database: "+
			"site install-server again", id, pending)
		pending = nil
	}
	backup := ""
	if len(pending) > 0 {
		backup = filepath.Join(filepath.Dir(agent.config.Database), "backups", "pre-migration-"+id+".db")
		journal := deployJournal{Build: id, Release: release, Previous: current, Backup: backup}
		if err := agent.writeJournal(journal); err != nil {
			return err
		}
		// A request on the site's socket starts the site while it is
		// stopped: let that be the new one, which waits for the lock.
		if err := agent.link(release); err != nil {
			return err
		}
		if err := agent.migrate(ctx, release, pending, backup); err != nil {
			log.Printf("site %s: %v", id, err)
			return agent.rollBack(ctx, id, current, backup)
		}
	}
	if err := agent.switchTo(ctx, release); err != nil {
		return err
	}
	if agent.healthy(ctx, agent.config.Health) {
		log.Printf("site %s is serving", id)
		if err := agent.removeJournal(); err != nil {
			return err
		}
		pruneReleases(filepath.Join(home, "releases"), filepath.Base(release), filepath.Base(current))
		return nil
	}
	log.Printf("site %s did not answer in %s: back to %s", id, healthWait, filepath.Base(current))
	return agent.rollBack(ctx, id, current, backup)
}

// deployJournal is a deploy with migrations under way: written beside the
// database before the site stops, removed when the deploy ends either way.
// An agent killed or a host rebooted mid-way leaves it, and the next run
// ends that deploy (finishInterrupted): no state but this, the release
// serving, and the copy.
type deployJournal struct {
	Build    string `json:"build"`
	Release  string `json:"release"`
	Previous string `json:"previous"`
	Backup   string `json:"backup"` // whole when it exists (migrate)
}

func (agent *HostAgent) journalPath() string {
	return filepath.Join(filepath.Dir(agent.config.Database), "deploying.json")
}

// writeJournal writes the journal whole or not at all.
func (agent *HostAgent) writeJournal(journal deployJournal) error {
	encoded, err := json.Marshal(journal)
	if err != nil {
		return err
	}
	path := agent.journalPath()
	if err := os.WriteFile(path+".new", encoded, 0o600); err != nil {
		return err
	}
	return os.Rename(path+".new", path)
}

func (agent *HostAgent) removeJournal() error {
	if agent.config.Database == "" {
		return nil // no migrations, so no journal
	}
	if err := os.Remove(agent.journalPath()); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// finishInterrupted ends a deploy the journal says did not finish: the new
// release, if it is linked and answers once started (every migration had
// run); otherwise the copy put back, when there is one, and the previous
// release. Not marked failed: the next run tries the build again from the
// start (a reboot is the likely cause, not the build). Found is whether
// there was one; a failure leaves the journal for the next run.
func (agent *HostAgent) finishInterrupted(ctx context.Context) (found bool, err error) {
	if agent.config.Database == "" {
		return false, nil
	}
	var journal deployJournal
	if err := readJSON(agent.journalPath(), &journal); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return false, nil
		}
		return true, err
	}
	log.Printf("site %s: a deploy that did not finish (the agent stopped mid-way): ending it",
		journal.Build)
	current, _ := os.Readlink(filepath.Join(agent.config.Home, "current"))
	if current == journal.Release {
		if err := agent.restart(ctx, agent.config.Service); err == nil &&
			agent.healthy(ctx, agent.config.Health) {
			log.Printf("site %s is serving: its migrations had all run", journal.Build)
			return true, agent.removeJournal()
		}
	}
	backup := journal.Backup
	if _, err := os.Stat(backup); err != nil {
		backup = "" // the copy did not finish, so no migration ran
	}
	if err := agent.undo(ctx, journal.Build, journal.Previous, backup); err != nil {
		return true, err
	}
	return true, fmt.Errorf("site %s: the deploy that did not finish is undone; tried again next", journal.Build)
}

// rollBack marks a build failed and serves the previous site again, on
// the database as it was before the migrations, when there were any.
func (agent *HostAgent) rollBack(ctx context.Context, id, current, backup string) error {
	home := agent.config.Home
	os.MkdirAll(filepath.Join(home, "failed"), 0o755)
	os.WriteFile(filepath.Join(home, "failed", id), []byte(time.Now().UTC().Format(time.RFC3339)), 0o644)
	if err := agent.undo(ctx, id, current, backup); err != nil {
		return err
	}
	return fmt.Errorf("site %s rolled back", id)
}

// undo serves the previous site again, on the copy when there is one, and
// ends the journal. A failure before the previous site is linked leaves
// the journal, so the next run tries again.
func (agent *HostAgent) undo(ctx context.Context, id, current, backup string) error {
	if backup != "" {
		if err := agent.stop(ctx, agent.config.Service); err != nil {
			return err
		}
		if err := agent.sqlite(ctx, ".restore '"+backup+"'\n"); err != nil {
			return fmt.Errorf("site %s: putting the database back from %s: %w", id, backup, err)
		}
		log.Printf("site %s: the database put back from %s", id, backup)
	}
	if current == "" {
		return fmt.Errorf("site %s failed, and there is no previous one", id)
	}
	if err := agent.switchTo(ctx, current); err != nil {
		return err
	}
	if err := agent.removeJournal(); err != nil {
		return err
	}
	if !agent.healthy(ctx, agent.config.Health) {
		return fmt.Errorf("the previous site does not answer either")
	}
	return nil
}

// migrate stops the site, copies its database to backup, and runs the
// migrations named, in order, each with -bail.
func (agent *HostAgent) migrate(ctx context.Context, release string, pending []string,
	backup string) error {
	if err := agent.stop(ctx, agent.config.Service); err != nil {
		return err
	}
	// The copy exists only whole: an agent stopped while copying leaves a
	// .partial, and no migration ran (finishInterrupted).
	partial := backup + ".partial"
	os.Remove(partial) // VACUUM INTO refuses a file that exists
	if err := agent.sqlite(ctx, "VACUUM INTO '"+partial+"';\n"); err != nil {
		return fmt.Errorf("the copy before migrating: %w", err)
	}
	if err := os.Rename(partial, backup); err != nil {
		return err
	}
	for _, name := range pending {
		script, err := os.ReadFile(filepath.Join(release, "migrations", name))
		if err != nil {
			return err
		}
		if err := agent.sqlite(ctx, string(script)); err != nil {
			return fmt.Errorf("migration %s: %w", name, err)
		}
		log.Printf("migrated: %s", name)
	}
	return nil
}

// pendingMigrations are the migrations release carries that current does
// not, by name, in order. None when current carries no migrations
// directory: a release from before 2026-10-12, whose database's migrations
// are unknown (the first release that carries them deploys without any).
func pendingMigrations(current, release string) []string {
	if current == "" {
		return nil // a first site makes its database from schema.sql
	}
	have, err := os.ReadDir(filepath.Join(current, "migrations"))
	if err != nil {
		return nil
	}
	ran := map[string]bool{}
	for _, entry := range have {
		ran[entry.Name()] = true
	}
	carried, _ := os.ReadDir(filepath.Join(release, "migrations"))
	var pending []string
	for _, entry := range carried { // ReadDir sorts by name: by date
		if strings.HasSuffix(entry.Name(), ".sql") && !ran[entry.Name()] {
			pending = append(pending, entry.Name())
		}
	}
	return pending
}

func short(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

// switchTo points current at a release, atomically, and restarts the site.
func (agent *HostAgent) switchTo(ctx context.Context, release string) error {
	if err := agent.link(release); err != nil {
		return err
	}
	return agent.restart(ctx, agent.config.Service)
}

// link points current at a release, atomically.
func (agent *HostAgent) link(release string) error {
	link := filepath.Join(agent.config.Home, "current")
	os.Remove(link + ".new")
	if err := os.Symlink(release, link+".new"); err != nil {
		return err
	}
	return os.Rename(link+".new", link)
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
	return systemctl(ctx, "restart", service)
}

// systemctlStop stops the site; systemd keeps its sockets, so a client
// waits in their queue (and starts it again: see deploy).
func systemctlStop(ctx context.Context, service string) error {
	return systemctl(ctx, "stop", service)
}

func systemctl(ctx context.Context, verb, service string) error {
	output, err := exec.CommandContext(ctx, "systemctl", verb, service).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl %s %s: %v: %s", verb, service, err, strings.TrimSpace(string(output)))
	}
	return nil
}

// runSQLite runs a script with sqlite3 as the site's user (the files it
// makes are the site's), -bail stopping at the first failed statement
// (without it a migration runs on to its DROP and COMMIT),
// waiting up to 10 s for a lock.
func runSQLite(ctx context.Context, user, database, script string) error {
	command := exec.CommandContext(ctx, "runuser", "-u", user, "--", "sqlite3", "-bail", database)
	command.Stdin = strings.NewReader(".timeout 10000\n" + script)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("sqlite3: %v: %s", err, strings.TrimSpace(string(output)))
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
