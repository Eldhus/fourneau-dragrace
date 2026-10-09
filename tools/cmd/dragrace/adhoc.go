package main

// Ad-hoc races: two (or more) builds of a competitor, each at its own
// commits of this repository, fourneau and roux, raced against each other
// on one server droplet, in under a minute once the machines are up
// (docs/adhoc.md).
//
//	dragrace adhoc race -workloads templates \
//	    roux:roux=templates,dragrace=templates \
//	    roux:roux=templates-vm,dragrace=templates-vm
//	dragrace adhoc down
//
// What makes it fast: the machines are a session, kept warm between races
// and deleted after 20 minutes unused (a user systemd timer, re-armed by
// every race; `dragrace reap` is the backstop); a variant is built once
// per content, locally, in its own checkout updated in place, and
// uploaded once per session, stripped and compressed; every ssh call to
// the session shares one kept connection; and the race is short and
// interleaved (rounds of every variant in a new order each).
//
// Standard output is a stream of events, one JSON object a line, for an
// agent or a script: resolved, built, session, uploaded, round, result.
// Standard error has the same for people, and the final table.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	adhocHome      = "/root/dragrace"
	adhocReapUnit  = "dragrace-adhoc-reap"
	adhocKeyPrefix = sshKeyPrefix + "adhoc-"
	// Its own tag: the nightly race's guard and racer never see a session,
	// and `dragrace reap` sweeps both.
	adhocTag = "fourneau-dragrace-adhoc"
)

func adhocDir(root string) string { return filepath.Join(outDir(root), "adhoc") }

func commandAdhoc(ctx context.Context, root string, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: dragrace adhoc race [-workloads W] [-rounds N] VARIANT... | adhoc down")
	}
	switch args[0] {
	case "race":
		return adhocRace(ctx, root, args[1:])
	case "down":
		return adhocDown(ctx, root, args[1:])
	}
	return fmt.Errorf("adhoc: no command %q (race, down)", args[0])
}

// --- events -------------------------------------------------------------------

// events writes the stream: a JSON object a line on standard output, the
// seconds since the command started in "t".
type events struct {
	start time.Time
	mutex sync.Mutex
}

func (e *events) emit(kind string, fields map[string]any) {
	e.mutex.Lock()
	defer e.mutex.Unlock()
	line := map[string]any{"event": kind, "t": round2(time.Since(e.start).Seconds())}
	for key, value := range fields {
		line[key] = value
	}
	bytes, err := json.Marshal(line)
	if err != nil {
		log.Printf("event %s: %v", kind, err)
		return
	}
	os.Stdout.Write(append(bytes, '\n'))
}

func round2(value float64) float64 { return float64(int64(value*100+0.5)) / 100 }

// --- variants -----------------------------------------------------------------

// variant is one build to race: a competitor at chosen commits.
type variant struct {
	label      string            // as given: roux:roux=templates-vm
	competitor string            // roux
	refs       map[string]string // dragrace, fourneau, roux -> ref ("HEAD" by default)
	commits    map[string]string // the refs resolved
	key        string            // a hash of the competitor and the commits
	binary     string            // the stripped, compressed build, cached
}

var adhocRepositories = []string{"dragrace", "fourneau", "roux"}

func parseVariant(text string) (variant, error) {
	name, refs, _ := strings.Cut(text, ":")
	v := variant{label: text, competitor: name, refs: map[string]string{}}
	for _, repository := range adhocRepositories {
		v.refs[repository] = "HEAD"
	}
	if refs == "" {
		return v, nil
	}
	for _, pair := range strings.Split(refs, ",") {
		repository, ref, ok := strings.Cut(pair, "=")
		if !ok || !slices.Contains(adhocRepositories, repository) || ref == "" {
			return v, fmt.Errorf("variant %q: %q is not REPOSITORY=REF (dragrace, fourneau, roux)",
				text, pair)
		}
		v.refs[repository] = ref
	}
	return v, nil
}

// repositoryDirs is where each repository is checked out on this machine.
func repositoryDirs(root string) (map[string]string, error) {
	versions, err := loadVersions(root)
	if err != nil {
		return nil, err
	}
	return map[string]string{
		"dragrace": root,
		"fourneau": checkoutPath(root, versions.Fourneau),
		"roux":     checkoutPath(root, versions.Roux),
	}, nil
}

// resolve finds a ref's commit in the local repository, fetching origin
// once when it is not there (a branch pushed from elsewhere). Anything
// git knows works: a branch, a tag, a hash, origin/main.
func resolve(ctx context.Context, dir, ref string) (string, error) {
	verify := func() (string, error) {
		return output(ctx, dir, "git", "rev-parse", "--verify", "--quiet", ref+"^{commit}")
	}
	if commit, err := verify(); err == nil {
		return commit, nil
	}
	if err := run(ctx, dir, nil, "git", "fetch", "--quiet", "origin"); err != nil {
		return "", err
	}
	if commit, err := verify(); err == nil {
		return commit, nil
	}
	commit, err := output(ctx, dir, "git", "rev-parse", "--verify", "--quiet", "origin/"+ref+"^{commit}")
	if err != nil {
		return "", fmt.Errorf("%s: no commit %q, here or on origin", dir, ref)
	}
	return commit, nil
}

// resolve finds the variant's commits, and its key: a hash of what the
// build reads, every file of the three trees but Markdown, so a commit of
// documentation only (a TODO) keeps its build.
func (v *variant) resolve(ctx context.Context, dirs map[string]string) error {
	v.commits = map[string]string{}
	hash := sha256.New()
	hash.Write([]byte(v.competitor))
	for _, repository := range adhocRepositories {
		commit, err := resolve(ctx, dirs[repository], v.refs[repository])
		if err != nil {
			return fmt.Errorf("variant %s: %w", v.label, err)
		}
		v.commits[repository] = commit
		files, err := output(ctx, dirs[repository], "git", "ls-tree", "-r", commit)
		if err != nil {
			return err
		}
		hash.Write([]byte(repository))
		for _, line := range strings.Split(files, "\n") {
			if !strings.HasSuffix(line, ".md") {
				hash.Write([]byte(line + "\n"))
			}
		}
	}
	v.key = hex.EncodeToString(hash.Sum(nil))[:12]
	return nil
}

// name is the variant's binary on the server, and its competitor name in
// the race: short, path-safe, unique per build.
func (v variant) name() string { return v.competitor + "-" + v.key[:8] }

// tree is where the variant is built: one directory per label, re-exported
// in place for each new key. Zig's cache knows a file by its path, so a
// new directory each time compiled everything again (roux's host and
// tools, 117 s); the same path hits wherever the files did not change.
func (v variant) tree(root string) string {
	label := sha256.Sum256([]byte(v.label))
	return filepath.Join(adhocDir(root), "tree", hex.EncodeToString(label[:])[:12])
}

// build makes the variant's binary unless the cache has it: the three
// repositories exported at their commits side by side (as RACING.md's
// layout), the competitor built there with its own competitor.json and
// pins, then stripped and compressed for the upload.
func (v *variant) build(ctx context.Context, root string, dirs map[string]string, ev *events) error {
	cache := filepath.Join(adhocDir(root), "bin")
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return err
	}
	v.binary = filepath.Join(cache, v.name()+".zst")
	if _, err := os.Stat(v.binary); err == nil {
		ev.emit("built", map[string]any{"variant": v.label, "cached": true, "seconds": 0})
		return nil
	}
	started := time.Now()
	tree := v.tree(root)
	treeRoot := filepath.Join(tree, "fourneau-dragrace")
	if err := checkoutAt(ctx, dirs["dragrace"], v.commits["dragrace"], treeRoot); err != nil {
		return err
	}
	// Where the checked-out dragrace expects its siblings: its own pins.
	versions, err := loadVersions(treeRoot)
	if err != nil {
		return err
	}
	for repository, checkout := range map[string]Checkout{"fourneau": versions.Fourneau,
		"roux": versions.Roux} {
		if err := checkoutAt(ctx, dirs[repository], v.commits[repository],
			checkoutPath(treeRoot, checkout)); err != nil {
			return err
		}
	}
	tools, err := loadToolchain(ctx, treeRoot)
	if err != nil {
		return err
	}
	competitors, err := loadCompetitors(treeRoot, []string{v.competitor})
	if err != nil {
		return err
	}
	if err := buildCompetitor(ctx, treeRoot, tools, competitors[0]); err != nil {
		return fmt.Errorf("variant %s: %w", v.label, err)
	}
	// Stripped (symbols only: the code is the same) and compressed: 17 MB
	// of roux is 1.6 MB to send.
	stripped := filepath.Join(tree, v.name())
	built := filepath.Join(binDir(treeRoot), v.competitor)
	if err := run(ctx, tree, nil, "strip", "-o", stripped, built); err != nil {
		return err
	}
	if err := run(ctx, tree, nil, "zstd", "-q", "-f", "-3", stripped, "-o", v.binary+".tmp"); err != nil {
		return err
	}
	if err := os.Rename(v.binary+".tmp", v.binary); err != nil {
		return err
	}
	ev.emit("built", map[string]any{"variant": v.label, "cached": false,
		"seconds": round2(time.Since(started).Seconds())})
	return nil
}

// checkoutAt makes dir a checkout of repository at commit, updated in
// place: a clone sharing the repository's objects (no copy), then a
// forced checkout and a clean of untracked files, ignored ones kept
// (zig-out, .roux). git rewrites only the files that differ, so a file
// unchanged keeps its inode and Zig's cache still knows it: an export
// written afresh each build missed every time (roux's host and tools,
// 117 s, for identical sources).
func checkoutAt(ctx context.Context, repository, commit, dir string) error {
	if _, err := os.Stat(filepath.Join(dir, ".git")); err != nil {
		if err := os.RemoveAll(dir); err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
			return err
		}
		if err := run(ctx, filepath.Dir(dir), nil, "git", "clone", "--quiet", "--shared",
			"--no-checkout", repository, dir); err != nil {
			return err
		}
	}
	if err := run(ctx, dir, nil, "git", "checkout", "--quiet", "--force", "--detach", commit); err != nil {
		return err
	}
	return run(ctx, dir, nil, "git", "clean", "-fdq")
}

// exportPath writes one path of a repository at a commit (all of it for
// "") into dir.
func exportPath(ctx context.Context, repository, commit, path, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	argv := []string{"-C", repository, "archive", "--format=tar", commit}
	if path != "" {
		argv = append(argv, path)
	}
	archive := exec.CommandContext(ctx, "git", argv...)
	untar := exec.CommandContext(ctx, "tar", "-x", "-C", dir)
	pipe, err := archive.StdoutPipe()
	if err != nil {
		return err
	}
	untar.Stdin = pipe
	archive.Stderr, untar.Stderr = os.Stderr, os.Stderr
	if err := untar.Start(); err != nil {
		return err
	}
	if err := archive.Run(); err != nil {
		return fmt.Errorf("git archive %s in %s: %w", commit, repository, err)
	}
	return untar.Wait()
}

// --- the session --------------------------------------------------------------

// adhocSession is the warm pair, kept in out/adhoc/session.json.
type adhocSession struct {
	Class      string        `json:"class"`
	Region     string        `json:"region"`
	KeyID      int           `json:"key_id"`
	Server     adhocNode     `json:"server"`
	Loader     adhocNode     `json:"loader"`
	Created    time.Time     `json:"created"`
	Used       time.Time     `json:"used"`
	IdleMinute int           `json:"idle_minutes"`
	Machines   []MachineInfo `json:"machines"`
}

type adhocNode struct {
	ID      int    `json:"id"`
	Size    string `json:"size"`
	Public  string `json:"public"`
	Private string `json:"private"`
}

func sessionPath(root string) string { return filepath.Join(adhocDir(root), "session.json") }
func sessionKey(root string) string  { return filepath.Join(adhocDir(root), "key") }

func loadSession(root string) (*adhocSession, error) {
	var session adhocSession
	if err := readJSON(sessionPath(root), &session); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	return &session, nil
}

func (session *adhocSession) save(root string) error {
	bytes, err := json.MarshalIndent(session, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(sessionPath(root), append(bytes, '\n'), 0o600)
}

func (session *adhocSession) machine(root string, node adhocNode) SSHMachine {
	return SSHMachine{
		User:       "root",
		Host:       node.Public,
		Key:        sessionKey(root),
		KnownHosts: filepath.Join(adhocDir(root), "known_hosts"),
		// A socket path must stay short (108 bytes): not under out/.
		Control: filepath.Join(os.TempDir(), fmt.Sprintf("dragrace-adhoc-%d", node.ID)),
	}
}

// lockSession holds out/adhoc/lock for the command's life: one command at
// a time on the session (the idle reaper never deletes it mid-race).
func lockSession(root string, wait bool) (func(), error) {
	if err := os.MkdirAll(adhocDir(root), 0o755); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(adhocDir(root), "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	how := syscall.LOCK_EX
	if !wait {
		how |= syscall.LOCK_NB
	}
	if err := syscall.Flock(int(file.Fd()), how); err != nil {
		file.Close()
		return nil, err
	}
	return func() { file.Close() }, nil
}

// adhocProvider is DigitalOcean with the owner's token: from the
// environment, or the keyring (never a command line, SECURITY.md).
func adhocProvider(ctx context.Context) (*DigitalOcean, error) {
	if os.Getenv("DIGITALOCEAN_TOKEN") == "" {
		token, err := exec.CommandContext(ctx, "secret-tool", "lookup", "service", "digitalocean",
			"name", "fourneau-dragrace").Output()
		if err != nil {
			return nil, fmt.Errorf("no DIGITALOCEAN_TOKEN and none in the keyring: %w", err)
		}
		os.Setenv("DIGITALOCEAN_TOKEN", strings.TrimSpace(string(token)))
	}
	return newDigitalOcean()
}

// upFlags is the session's setup, one for every ad-hoc race (owner,
// 2026-10-08: "simple"): dedicated cores, so a difference is the builds';
// race.json's region; deleted after 20 minutes unused.
type upFlags struct {
	class, region string
	idle          int
}

var adhocSetup = upFlags{class: "dedicated-2", idle: 20}

// ensureSession returns the warm session, making it if there is none (or
// the one there is for another class or region, or gone).
func ensureSession(ctx context.Context, root string, up upFlags, ev *events) (*adhocSession, error) {
	race, err := loadRace(root)
	if err != nil {
		return nil, err
	}
	if up.region == "" {
		up.region = race.Cloud.Region
	}
	var class ServerClass
	for _, c := range race.Cloud.Servers {
		if c.Name == up.class {
			class = c
		}
	}
	if class.Name == "" {
		return nil, fmt.Errorf("no server class %q in race.json", up.class)
	}
	do, err := adhocProvider(ctx)
	if err != nil {
		return nil, err
	}
	session, err := loadSession(root)
	if err != nil {
		return nil, err
	}
	if session != nil && (session.Class != up.class || session.Region != up.region) {
		log.Printf("adhoc: the session is %s in %s; replacing it", session.Class, session.Region)
		deleteSession(ctx, root, do, session)
		session = nil
	}
	if session != nil {
		// Still there, and answering?
		if _, err := do.droplet(ctx, session.Server.ID); err == nil {
			server := session.machine(root, session.Server)
			if _, err := server.Shell(ctx, "true"); err == nil {
				session.Used = time.Now().UTC()
				session.IdleMinute = up.idle
				if err := session.save(root); err != nil {
					return nil, err
				}
				armReaper(root, up.idle)
				logMachines(session, true)
				ev.emit("session", map[string]any{"reused": true, "class": session.Class,
					"machines": session.Machines})
				return session, nil
			}
		}
		log.Printf("adhoc: the session's droplets do not answer; making new ones")
		deleteSession(ctx, root, do, session)
	}
	started := time.Now()
	session, err = makeSession(ctx, root, do, race, class, up)
	if err != nil {
		return nil, err
	}
	armReaper(root, up.idle)
	logMachines(session, false)
	ev.emit("session", map[string]any{"reused": false, "class": session.Class,
		"seconds": round2(time.Since(started).Seconds()), "machines": session.Machines})
	return session, nil
}

// logMachines says which machines race (there is no status command).
func logMachines(session *adhocSession, reused bool) {
	how := "new"
	if reused {
		how = "warm"
	}
	for _, machine := range session.Machines {
		log.Printf("adhoc: %s %s, %s: %s, %d CPUs (%s); deleted after %d min unused",
			how, machine.Role, machine.Size, machine.CPU, machine.CPUs, machine.CPUID,
			session.IdleMinute)
	}
}

func makeSession(ctx context.Context, root string, do Provider, race Race, class ServerClass,
	up upFlags) (*adhocSession, error) {
	os.Remove(sessionKey(root))
	os.Remove(sessionKey(root) + ".pub")
	os.Remove(filepath.Join(adhocDir(root), "known_hosts"))
	name := adhocKeyPrefix + strconv.FormatInt(time.Now().Unix(), 10)
	if err := run(ctx, adhocDir(root), nil, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name,
		"-f", sessionKey(root)); err != nil {
		return nil, err
	}
	public, err := os.ReadFile(sessionKey(root) + ".pub")
	if err != nil {
		return nil, err
	}
	key, err := do.createKey(ctx, name, strings.TrimSpace(string(public)))
	if err != nil {
		return nil, err
	}
	session := &adhocSession{Class: class.Name, Region: up.region, KeyID: key.ID,
		Created: time.Now().UTC(), Used: time.Now().UTC(), IdleMinute: up.idle}
	create := func(role, size string) (adhocNode, error) {
		droplet, err := do.createDroplet(ctx, DropletRequest{
			Name: "dragrace-adhoc-" + role, Region: up.region, Size: size, Image: race.Cloud.Image,
			SSHKeys: []int{key.ID}, Tags: []string{adhocTag}, UserData: raceUserData,
		})
		return adhocNode{ID: droplet.ID, Size: size}, err
	}
	// Saved as soon as a droplet exists, so `adhoc down` finds it whatever
	// happens next.
	if session.Server, err = create("server", class.Size); err != nil {
		return nil, err
	}
	if err := session.save(root); err != nil {
		return nil, err
	}
	if session.Loader, err = create("loader", class.LoaderSize); err != nil {
		deleteSession(ctx, root, do, session)
		return nil, err
	}
	if err := session.save(root); err != nil {
		return nil, err
	}
	for _, node := range []*adhocNode{&session.Server, &session.Loader} {
		droplet, err := waitActive(ctx, do, node.ID)
		if err != nil {
			deleteSession(ctx, root, do, session)
			return nil, err
		}
		node.Public, node.Private = droplet.address("public"), droplet.address("private")
	}
	if err := session.save(root); err != nil {
		return nil, err
	}
	server, loader := session.machine(root, session.Server), session.machine(root, session.Loader)
	errs := make([]error, 2)
	var wait sync.WaitGroup
	for i, machine := range []SSHMachine{server, loader} {
		wait.Add(1)
		go func() {
			defer wait.Done()
			errs[i] = waitSSH(ctx, machine)
		}()
	}
	wait.Wait()
	if err := errors.Join(errs...); err != nil {
		deleteSession(ctx, root, do, session)
		return nil, err
	}
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return nil, err
	}
	if err := loader.Put(ctx, tools.Oha, adhocHome+"/oha"); err != nil {
		return nil, err
	}
	if _, err := server.Shell(ctx, "mkdir -p "+adhocHome+"/bin && command -v zstd >/dev/null || "+
		"(apt-get update -q && apt-get install -yq zstd) >/dev/null"); err != nil {
		return nil, err
	}
	session.Machines = []MachineInfo{
		machineInfo(ctx, server, "server", class.Name, class.Size),
		machineInfo(ctx, loader, "loader", class.Name, class.LoaderSize),
	}
	return session, session.save(root)
}

// deleteSession deletes the droplets and the key, retrying, and forgets
// the session.
func deleteSession(ctx context.Context, root string, do Provider, session *adhocSession) {
	ctx = context.WithoutCancel(ctx)
	for _, node := range []adhocNode{session.Server, session.Loader} {
		if node.ID == 0 {
			continue
		}
		for attempt := range 5 {
			err := do.deleteDroplet(ctx, node.ID)
			if err == nil || strings.Contains(err.Error(), "404") {
				log.Printf("adhoc: droplet %d deleted", node.ID)
				break
			}
			log.Printf("adhoc: deleting droplet %d (attempt %d): %v", node.ID, attempt+1, err)
			time.Sleep(5 * time.Second)
		}
		exec.Command("ssh", "-o", "ControlPath="+session.machine(root, node).Control, "-O", "exit",
			"x").Run()
	}
	if session.KeyID != 0 {
		if err := do.deleteKey(ctx, session.KeyID); err != nil {
			log.Printf("adhoc: deleting key %d: %v (dragrace reap will)", session.KeyID, err)
		}
	}
	os.Remove(sessionPath(root))
}

// armReaper (re)starts a user timer that runs `adhoc down -if-idle` once
// the session has been idle long enough. A laptop asleep runs it on
// waking; `dragrace reap` (180 minutes) is the backstop.
func armReaper(root string, idle int) {
	exec.Command("systemctl", "--user", "stop", adhocReapUnit+".timer").Run()
	exec.Command("systemctl", "--user", "reset-failed", adhocReapUnit+".service").Run()
	self, err := os.Executable()
	if err != nil {
		log.Printf("adhoc: no idle reaper (%v): `dragrace adhoc down` when done", err)
		return
	}
	cmd := exec.Command("systemd-run", "--user", "--quiet", "--collect", "--unit="+adhocReapUnit,
		fmt.Sprintf("--on-active=%dm", idle+1), "--working-directory="+root,
		self, "adhoc", "down", "-if-idle")
	if out, err := cmd.CombinedOutput(); err != nil {
		log.Printf("adhoc: no idle reaper (%v: %s): `dragrace adhoc down` when done", err,
			strings.TrimSpace(string(out)))
	}
}

func adhocDown(ctx context.Context, root string, args []string) error {
	flags := newFlags("adhoc down")
	ifIdle := flags.Bool("if-idle", false, "only when unused for the session's idle minutes (the timer)")
	flags.Parse(args)
	unlock, err := lockSession(root, !*ifIdle)
	if err != nil {
		if *ifIdle {
			armReaper(root, 5) // a race holds it: look again later
			return nil
		}
		return err
	}
	defer unlock()
	session, err := loadSession(root)
	if err != nil || session == nil {
		return err
	}
	idleFor := time.Since(session.Used)
	if *ifIdle && idleFor < time.Duration(session.IdleMinute)*time.Minute {
		armReaper(root, session.IdleMinute-int(idleFor.Minutes()))
		return nil
	}
	do, err := adhocProvider(ctx)
	if err != nil {
		return err
	}
	deleteSession(ctx, root, do, session)
	exec.Command("systemctl", "--user", "stop", adhocReapUnit+".timer").Run()
	log.Printf("adhoc: session deleted (it lived %s)", time.Since(session.Created).Round(time.Second))
	return nil
}

// --- the race -----------------------------------------------------------------

// A workload's warmup and measure, seconds: short, since rounds interleave.
const adhocWarmup, adhocMeasure = 1, 4

func adhocRace(ctx context.Context, root string, args []string) error {
	flags := newFlags("adhoc race")
	up := adhocSetup
	workloads := flags.String("workloads", workloadNames(root), "comma-separated")
	rounds := flags.Int("rounds", 3, "rounds, each variant once a round in a new order")
	open := flags.Bool("open", false, "then race.json's open-loop ladder on each workload, "+
		"every variant at the same offered rates (shares of the first variant's median)")
	flags.Parse(args)
	ev := &events{start: time.Now()}
	if flags.NArg() < 1 {
		return errors.New("adhoc race: at least one VARIANT " +
			"(competitor[:dragrace=REF,fourneau=REF,roux=REF])")
	}
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	race.Rounds, race.WarmupSeconds, race.MeasureSeconds = *rounds, adhocWarmup, adhocMeasure
	// The nightly's ladder is each server's own (a share of its own median),
	// which suits a league table; an A/B wants every variant at the same
	// rates, so the ladder is climbed here after the rounds (`-open`).
	ladder := race.OpenLoop
	race.OpenLoop = OpenLoop{}
	var picked []Workload
	for _, name := range strings.Split(*workloads, ",") {
		name = strings.TrimSpace(name)
		i := slices.IndexFunc(race.Workloads, func(w Workload) bool { return w.Name == name })
		if i < 0 {
			return fmt.Errorf("no workload %q (%s)", name, workloadNames(root))
		}
		if race.Workloads[i].Mixed != nil {
			return fmt.Errorf("%s is open loop only, not raced ad hoc: a nightly, or "+
				"`race cloud -workloads %s` (docs/adhoc.md)", name, name)
		}
		picked = append(picked, race.Workloads[i])
	}
	race.Workloads = picked

	dirs, err := repositoryDirs(root)
	if err != nil {
		return err
	}
	variants := make([]*variant, flags.NArg())
	for i, text := range flags.Args() {
		v, err := parseVariant(text)
		if err != nil {
			return err
		}
		if err := v.resolve(ctx, dirs); err != nil {
			return err
		}
		variants[i] = &v
		ev.emit("resolved", map[string]any{"variant": v.label, "commits": v.commits, "key": v.key})
	}
	unlock, err := lockSession(root, true)
	if err != nil {
		return err
	}
	defer unlock()
	// The builds and the machines at once: a new session's droplets take
	// about a minute to boot, a build as much the first time.
	os.Setenv("ZIG_LOCAL_CACHE_DIR", filepath.Join(adhocDir(root), "zig-cache"))
	var session *adhocSession
	var sessionErr error
	sessionDone := make(chan struct{})
	go func() {
		defer close(sessionDone)
		session, sessionErr = ensureSession(ctx, root, up, ev)
	}()
	for _, v := range variants {
		// One at a time: two Zig builds at once only fight for the CPUs.
		if err := v.build(ctx, root, dirs, ev); err != nil {
			<-sessionDone
			return err
		}
	}
	<-sessionDone
	if sessionErr != nil {
		return sessionErr
	}
	server := session.machine(root, session.Server)
	loader := session.machine(root, session.Loader)
	if err := upload(ctx, server, variants, ev); err != nil {
		return err
	}

	competitors := make([]Competitor, len(variants))
	for i, v := range variants {
		// How to run it: its competitor.json at its own dragrace commit.
		specRoot := filepath.Join(adhocDir(root), "spec", v.key)
		os.RemoveAll(specRoot)
		if err := exportPath(ctx, dirs["dragrace"], v.commits["dragrace"],
			"competitors/"+v.competitor+"/competitor.json", specRoot); err != nil {
			return err
		}
		spec, err := loadCompetitors(specRoot, []string{v.competitor})
		if err != nil {
			return err
		}
		competitors[i] = spec[0]
		competitors[i].Name = v.name()
	}
	labelOf := map[string]string{}
	for _, v := range variants {
		labelOf[v.name()] = v.label
	}
	class := ServerClass{Name: session.Class}
	for _, c := range race.Cloud.Servers {
		if c.Name == session.Class {
			class = c
		}
	}
	threads := 0
	for _, machine := range session.Machines {
		if machine.Role == "loader" {
			threads = machine.CPUs
		}
	}
	reported := map[string]int{}
	target := Target{
		Class: class, Server: server, Loader: loader,
		ServerHome: adhocHome, LoaderHome: adhocHome,
		Address: session.Server.Private, LoaderThreads: threads,
		Report: func(result Result) {
			key := result.Workload + "/" + result.Competitor
			for _, r := range result.Rounds[reported[key]:] {
				ev.emit("round", map[string]any{"variant": labelOf[result.Competitor],
					"workload": result.Workload, "round": reported[key] + 1, "rps": round2(r.RPS),
					"p50_ms": r.P50Ms, "p99_ms": r.P99Ms, "cpu_busy_pct": round2(r.CPUBusyPct),
					"errors": r.Errors, "non_2xx": r.Non2xx})
				reported[key]++
			}
			if !result.Valid {
				ev.emit("invalid", map[string]any{"variant": labelOf[result.Competitor],
					"workload": result.Workload, "why": result.Note})
			}
		},
	}
	runResult := Run{ID: runID("adhoc", time.Now().UTC()), Where: "adhoc",
		StartedAt: time.Now().UTC(), Seed: time.Now().UnixNano(), Race: race,
		Machines: session.Machines}
	raced := time.Now()
	if err := raceTarget(ctx, race, competitors, target, &runResult); err != nil {
		return err
	}
	if err := rerunUnsaturated(ctx, race, competitors, target, &runResult, labelOf, ev); err != nil {
		return err
	}
	var openRows []openRow
	if *open {
		withLadder := race
		withLadder.OpenLoop = ladder
		openRows, err = adhocOpen(ctx, withLadder, competitors, target, &runResult, labelOf, ev)
		if err != nil {
			return err
		}
	}
	runResult.FinishedAt = time.Now().UTC()
	session.Used = time.Now().UTC()
	if err := session.save(root); err != nil {
		return err
	}
	armReaper(root, session.IdleMinute)

	comparison := compare(runResult, class.Name, variants, labelOf)
	path, err := saveRun(filepath.Join(adhocDir(root), "results"), runResult)
	if err != nil {
		return err
	}
	ev.emit("result", map[string]any{"race_seconds": round2(time.Since(raced).Seconds()),
		"comparison": comparison, "open_loop": openRows, "results_file": path,
		"machines": session.Machines})
	fmt.Fprint(os.Stderr, comparisonTable(comparison))
	if *open {
		fmt.Fprint(os.Stderr, openTable(openRows))
	}
	return nil
}

// openRow is one variant at one rate of the ladder.
type openRow struct {
	Workload    string  `json:"workload"`
	Share       float64 `json:"share"`
	OfferedRPS  float64 `json:"offered_rps"`
	Variant     string  `json:"variant"`
	AchievedRPS float64 `json:"achieved_rps"`
	P99Ms       float64 `json:"p99_ms"`
	P999Ms      float64 `json:"p999_ms"`
	CPUBusyPct  float64 `json:"cpu_busy_pct"`
	LoaderPct   float64 `json:"loader_cpu_busy_pct"`
}

// adhocOpen climbs the ladder (open_loop.go's `climb`) for every variant
// on each workload, in a seeded order, at the same offered rates: the
// shares of the first variant's closed-loop median. Latency is counted
// from when each request was due, so a variant that stalls shows it.
func adhocOpen(ctx context.Context, race Race, competitors []Competitor, target Target,
	run *Run, labelOf map[string]string, ev *events) ([]openRow, error) {
	if !race.OpenLoop.enabled() {
		return nil, errors.New("-open: race.json has no open_loop ladder")
	}
	bodies, err := putBodies(ctx, race, target, run.Seed)
	if err != nil {
		return nil, err
	}
	var rows []openRow
	for _, workload := range race.Workloads {
		median := resultFor(run, target.Class.Name, workload.Name, competitors[0].Name).MedianRPS
		if median <= 0 {
			continue
		}
		for _, competitor := range shuffled(competitors, run.Seed+int64(race.Rounds)+1) {
			log.Printf("[%s] open loop: %s at the first's rates", target.Class.Name, competitor.Name)
			steps, err := climb(ctx, race, workload, competitor, target, bodies, median)
			if err != nil {
				return nil, fmt.Errorf("%s open loop: %w", competitor.Name, err)
			}
			resultFor(run, target.Class.Name, workload.Name, competitor.Name).OpenLoop = steps
			for _, s := range steps {
				row := openRow{Workload: workload.Name, Share: s.Share, OfferedRPS: s.OfferedRPS,
					Variant: labelOf[competitor.Name], AchievedRPS: round2(s.AchievedRPS),
					P99Ms: s.P99Ms, P999Ms: s.P999Ms, CPUBusyPct: round2(s.CPUBusyPct),
					LoaderPct: round2(s.LoaderCPUBusyPct)}
				rows = append(rows, row)
				ev.emit("open_step", map[string]any{"variant": row.Variant,
					"workload": row.Workload, "share": row.Share, "offered_rps": row.OfferedRPS,
					"achieved_rps": row.AchievedRPS, "p99_ms": row.P99Ms, "p999_ms": row.P999Ms,
					"cpu_busy_pct": row.CPUBusyPct, "loader_cpu_busy_pct": row.LoaderPct})
			}
		}
	}
	return rows, nil
}

// openTable: a block per workload and rate, a line per variant, in the
// variants' order on the command line.
func openTable(rows []openRow) string {
	sorted := slices.Clone(rows)
	slices.SortStableFunc(sorted, func(a, b openRow) int {
		if a.Workload != b.Workload {
			return strings.Compare(a.Workload, b.Workload)
		}
		return int(a.OfferedRPS - b.OfferedRPS)
	})
	var text strings.Builder
	fmt.Fprintf(&text, "\nopen loop, the same rates for every variant (shares of the first's median)\n")
	fmt.Fprintf(&text, "%-10s %5s %9s  %-48s %9s %9s %9s %6s\n", "workload", "share", "offered",
		"variant", "good/s", "p99 ms", "p99.9 ms", "cpu %")
	for _, row := range sorted {
		fmt.Fprintf(&text, "%-10s %4.0f%% %9.0f  %-48s %9.0f %9.2f %9.2f %6.1f\n", row.Workload,
			row.Share*100, row.OfferedRPS, row.Variant, row.AchievedRPS, row.P99Ms, row.P999Ms,
			row.CPUBusyPct)
	}
	return text.String()
}

// saturated is the server CPU a round needs to measure the server: below
// it something else held the load back (on 2026-10-08 two rounds of six
// read 76% and 83%, the loader dipping with them, no retransmits: the
// network or a neighbour), and the round measured that.
const saturated = 95.0

// rerunUnsaturated races again, up to twice, every competitor with a
// round in which its server was not the limit, and drops such rounds
// where enough others remain.
func rerunUnsaturated(ctx context.Context, race Race, competitors []Competitor, target Target,
	run *Run, labelOf map[string]string, ev *events) error {
	bodies, err := putBodies(ctx, race, target, run.Seed)
	if err != nil {
		return err
	}
	valid := map[string]string{}
	for _, result := range run.Results {
		if !result.Valid {
			valid[result.Competitor] = result.Note
		}
	}
	// The saturated rounds a competitor still lacks, on its worst workload.
	missing := func(competitor string) int {
		worst := 0
		for _, result := range run.Results {
			if result.Competitor != competitor || !result.Valid {
				continue
			}
			good := 0
			for _, r := range result.Rounds {
				if r.CPUBusyPct >= saturated {
					good++
				}
			}
			worst = max(worst, race.Rounds-good)
		}
		return worst
	}
	for _, competitor := range competitors {
		for attempt := 0; attempt < 2 && missing(competitor.Name) > 0; attempt++ {
			ev.emit("rerun", map[string]any{"variant": labelOf[competitor.Name],
				"why": fmt.Sprintf("a round's server under %.0f%% CPU", saturated)})
			round := race.Rounds + 1 + attempt
			if err := raceCompetitor(ctx, race, competitor, target, bodies, round, valid,
				run); err != nil {
				return err
			}
		}
	}
	// Keep the saturated rounds, as many as asked for when there are.
	for i := range run.Results {
		result := &run.Results[i]
		var kept, dropped []Round
		for _, r := range result.Rounds {
			if r.CPUBusyPct >= saturated && len(kept) < race.Rounds {
				kept = append(kept, r)
			} else {
				dropped = append(dropped, r)
			}
		}
		for len(kept) < race.Rounds && len(dropped) > 0 {
			kept, dropped = append(kept, dropped[0]), dropped[1:]
		}
		if len(dropped) > 0 {
			ev.emit("dropped", map[string]any{"variant": labelOf[result.Competitor],
				"workload": result.Workload, "rounds": len(dropped)})
		}
		result.Rounds = kept
		result.summarize()
	}
	return nil
}

func workloadNames(root string) string {
	race, err := loadRace(root)
	if err != nil {
		return "?"
	}
	var names []string
	for _, w := range race.Workloads {
		if w.Mixed == nil {
			names = append(names, w.Name)
		}
	}
	return strings.Join(names, ",")
}

// upload sends each variant's binary the server does not have yet.
func upload(ctx context.Context, server SSHMachine, variants []*variant, ev *events) error {
	have, err := server.Shell(ctx, "ls "+adhocHome+"/bin")
	if err != nil {
		return err
	}
	present := map[string]bool{}
	for _, name := range strings.Fields(have) {
		present[name] = true
	}
	for _, v := range variants {
		if present[v.name()] {
			continue
		}
		started := time.Now()
		remote := adhocHome + "/bin/" + v.name()
		if err := server.Put(ctx, v.binary, remote+".zst"); err != nil {
			return err
		}
		if _, err := server.Shell(ctx, "zstd -q -d -f "+quote(remote+".zst")+" -o "+quote(remote)+
			" && rm "+quote(remote+".zst")+" && chmod +x "+quote(remote)); err != nil {
			return err
		}
		info, _ := os.Stat(v.binary)
		ev.emit("uploaded", map[string]any{"variant": v.label, "bytes": info.Size(),
			"seconds": round2(time.Since(started).Seconds())})
		present[v.name()] = true
	}
	return nil
}

// comparisonRow is one variant on one workload, against the first variant.
type comparisonRow struct {
	Workload    string    `json:"workload"`
	Variant     string    `json:"variant"`
	Valid       bool      `json:"valid"`
	MedianRPS   float64   `json:"median_rps"`
	RPS         []float64 `json:"rps"` // every round
	MedianP99Ms float64   `json:"median_p99_ms"`
	// Against the first variant: the medians' difference, and whether the
	// rounds' ranges are apart (every round of one above every round of
	// the other) or overlap (within this race's noise).
	DeltaPct float64 `json:"delta_pct"`
	Apart    bool    `json:"apart"`
}

func compare(run Run, class string, variants []*variant, labelOf map[string]string) []comparisonRow {
	var rows []comparisonRow
	for _, workload := range run.Race.Workloads {
		var base *comparisonRow
		for _, v := range variants {
			result := resultFor(&run, class, workload.Name, v.name())
			row := comparisonRow{Workload: workload.Name, Variant: labelOf[v.name()],
				Valid: result.Valid, MedianRPS: round2(result.MedianRPS),
				MedianP99Ms: result.MedianP99Ms}
			for _, r := range result.Rounds {
				row.RPS = append(row.RPS, round2(r.RPS))
			}
			if base == nil {
				rows = append(rows, row)
				base = &rows[len(rows)-1]
				continue
			}
			if base.MedianRPS > 0 {
				row.DeltaPct = round2(100 * (row.MedianRPS - base.MedianRPS) / base.MedianRPS)
			}
			if len(row.RPS) > 0 && len(base.RPS) > 0 {
				row.Apart = slices.Min(row.RPS) > slices.Max(base.RPS) ||
					slices.Max(row.RPS) < slices.Min(base.RPS)
			}
			rows = append(rows, row)
		}
	}
	return rows
}

func comparisonTable(rows []comparisonRow) string {
	var text strings.Builder
	fmt.Fprintf(&text, "\n%-10s %-48s %10s %8s %9s  %s\n", "workload", "variant", "req/s", "vs 1st",
		"p99 ms", "rounds")
	overlap := false
	for _, row := range rows {
		delta := ""
		if row.DeltaPct != 0 || row.Apart {
			delta = fmt.Sprintf("%+.1f%%", row.DeltaPct)
			if !row.Apart {
				delta += "~"
				overlap = true
			}
		}
		if !row.Valid {
			delta = "INVALID"
		}
		rounds := make([]string, len(row.RPS))
		for i, value := range row.RPS {
			rounds[i] = strconv.FormatFloat(value, 'f', 0, 64)
		}
		fmt.Fprintf(&text, "%-10s %-48s %10.0f %8s %9.2f  %s\n", row.Workload, row.Variant,
			row.MedianRPS, delta, row.MedianP99Ms, strings.Join(rounds, " "))
	}
	if overlap {
		text.WriteString("(~: the rounds' ranges overlap, within this race's noise)\n")
	}
	return text.String()
}
