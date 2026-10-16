package main

import (
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"log"
	"math/rand/v2"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Machine runs shell scripts and receives files: this computer, or a
// droplet over SSH. The race is the same on either.
type Machine interface {
	Shell(ctx context.Context, script string) (string, error)
	Put(ctx context.Context, local, remote string) error
}

// Target is one server class to race on: where the server runs and where
// the loader runs, and the CPUs each may use ("" for all).
type Target struct {
	Class      ServerClass
	Server     Machine
	Loader     Machine
	ServerHome string // holds bin/
	LoaderHome string // holds oha and the request bodies
	Address    string // where servers listen, as the loader reaches them
	ServerCPUs string
	LoaderCPUs string
	// oha's threads: the loader's CPUs (0: oha's default).
	LoaderThreads int
	// Report, if set, is told each result as it grows: after each round of
	// a competitor, and after its open loop (a worker posts it to the site).
	Report func(Result)
	// Begin, if set, is told the class's plan as each step starts (its
	// index in the plan; a worker posts it to the site).
	Begin func(plan []Step, step int)
	// BlackBox, if set, is the file on this machine that follows the
	// server's (followServer).
	BlackBox string
}

func (target Target) report(result Result) {
	if target.Report != nil {
		target.Report(result)
	}
}

func (target Target) begin(plan []Step, step int) {
	if target.Begin != nil {
		target.Begin(plan, step)
	}
}

func (target Target) taskset(cpus string) string {
	if cpus == "" {
		return ""
	}
	return "taskset -c " + cpus + " "
}

// Step is a class's race between two reports: a competitor's round of the
// closed workloads, or its climb of one mixed workload's ladder. The whole
// plan is told to the site as each step starts (Target.Begin), so the
// live banner shows each step's progress and name.
type Step struct {
	Competitor string `json:"competitor"`
	// 1 to the race's rounds; 0 for a ladder.
	Round int `json:"round"`
	// "" for a round; the mixed workload for a ladder.
	Workload string `json:"workload"`
	// Its loads' seconds, warmups included; a ladder's climbed to its top
	// rate, which most stop short of. The site's estimate when the run
	// before had no such step.
	PlannedSeconds float64 `json:"planned_seconds"`

	competitor Competitor
	workload   Workload // a ladder's
}

// planSteps is the order a class races in: round after round, every
// competitor in a new random order each round (the seed is in the
// results), then each mixed workload's ladders.
func planSteps(race Race, competitors []Competitor, seed int64) []Step {
	var steps []Step
	for round := 1; round <= race.Rounds; round++ {
		for _, competitor := range shuffled(competitors, seed+int64(round)) {
			seconds := 0
			for _, workload := range race.Workloads {
				// A mixed workload is open loop only, after the rounds.
				if workload.Mixed == nil && competitor.offers(workload) && race.loads(workload) {
					seconds += race.WarmupSeconds + race.MeasureSeconds
				}
			}
			steps = append(steps, Step{Competitor: competitor.Name, Round: round,
				PlannedSeconds: float64(seconds), competitor: competitor})
		}
	}
	for _, workload := range race.Workloads {
		if workload.Mixed == nil || !race.loads(workload) {
			continue
		}
		mixed := workload.Mixed
		seconds := len(mixed.Rates) * (mixed.WarmupSeconds + mixed.MeasureSeconds)
		for _, competitor := range shuffled(competitors, seed+int64(race.Rounds)+2) {
			if competitor.offers(workload) {
				steps = append(steps, Step{Competitor: competitor.Name, Workload: workload.Name,
					PlannedSeconds: float64(seconds), competitor: competitor, workload: workload})
			}
		}
	}
	return steps
}

// raceTarget races the class's plan (planSteps), and appends to
// run.Results.
func raceTarget(ctx context.Context, race Race, competitors []Competitor, target Target,
	run *Run) error {
	bodies, err := putBodies(ctx, race, target, run.Seed)
	if err != nil {
		return err
	}
	if race.hasTLS() {
		if err := putCertificate(ctx, target); err != nil {
			return err
		}
	}
	// validKey(competitor, mode) -> why it is not valid ("" if valid).
	valid := map[string]string{}
	plan := planSteps(race, competitors, run.Seed)
	failed := 0
	for i, step := range plan {
		target.begin(plan, i)
		var err error
		if step.Workload != "" {
			err = climbStep(ctx, race, step, target, valid, run)
		} else {
			competitor := step.competitor
			log.Printf("[%s] round %d/%d: %s", target.Class.Name, step.Round, race.Rounds, competitor.Name)
			err = raceCompetitor(ctx, race, competitor, target, bodies, step.Round, valid, run)
			for _, result := range run.Results {
				if result.Class == target.Class.Name && result.Competitor == competitor.Name {
					target.report(result)
				}
			}
		}
		if err == nil {
			continue
		}
		// A step's error is that step's: its result's note says why, and
		// the class races on while the server answers. The class fails only
		// when it ends early, saying why and which steps it leaves.
		log.Printf("[%s] step %d of %d: %v", target.Class.Name, i+1, len(plan), err)
		if ctx.Err() != nil {
			return fmt.Errorf("stopped at step %d of %d: %w", i+1, len(plan), ctx.Err())
		}
		if lost := serverAnswers(ctx, target); lost != nil {
			return fmt.Errorf("the server stopped answering at step %d of %d (%w), after: %v; "+
				"its black box ends: %s; %s not raced", i+1, len(plan), lost, err,
				blackBoxTail(target.BlackBox, 6), notRaced(plan[i+1:]))
		}
		failed++
		log.Printf("[%s] the server after step %d: %s", target.Class.Name, i+1, serverState(ctx, target))
	}
	if failed > 0 {
		log.Printf("[%s] %d of %d steps failed; each result's note says why", target.Class.Name,
			failed, len(plan))
	}
	return nil
}

// serverAnswers waits up to about a minute and a half for the server
// machine to answer SSH: a step may fail with the machine itself fine.
func serverAnswers(ctx context.Context, target Target) error {
	var err error
	for try := range 4 {
		if try > 0 {
			if err := sleepContext(ctx, 15*time.Second); err != nil {
				return err
			}
		}
		if _, err = target.Server.Shell(ctx, "true"); err == nil {
			return nil
		}
	}
	return err
}

// notRaced names the steps a class leaves.
func notRaced(steps []Step) string {
	if len(steps) == 0 {
		return "no step"
	}
	names := make([]string, len(steps))
	for i, step := range steps {
		names[i] = step.Competitor + " " + cmp.Or(step.Workload, "round "+strconv.Itoa(step.Round))
	}
	return strings.Join(names, ", ")
}

// Mode is how a competitor is started: plain HTTP (HTTP/1.1 and h2c), or
// its HTTPS mode, on the same port. A round starts it once in each mode
// its workloads need, in a seeded order.
type Mode bool

const (
	plainMode Mode = false
	tlsMode   Mode = true
)

func (workload Workload) mode() Mode { return Mode(workload.TLS) }

// validKey is a competitor's entry in the valid map: each mode is checked
// on its own, so one that fails TLS still races plain HTTP.
func validKey(competitor string, mode Mode) string {
	if mode == tlsMode {
		return competitor + " (TLS)"
	}
	return competitor
}

// offers says whether a competitor races a workload: one with no HTTPS
// mode sits the TLS workloads out, with no result.
func (competitor Competitor) offers(workload Workload) bool {
	return workload.mode() == plainMode || competitor.TLS
}

func (race Race) hasTLS() bool {
	return slices.ContainsFunc(race.Workloads, func(w Workload) bool { return w.TLS })
}

func raceCompetitor(ctx context.Context, race Race, competitor Competitor, target Target,
	bodies map[int]string, round int, valid map[string]string, run *Run) error {
	// Each round and competitor its own order of workloads: in one order
	// always, a server process's drift (memory grown, churn's TIME_WAIT
	// left behind) landed on the same workloads every time. From the seed,
	// so a run replays.
	name := fnv.New64a()
	name.Write([]byte(competitor.Name))
	seed := run.Seed + int64(round)*7919 + int64(name.Sum64()>>1)
	var errs []error
	for _, mode := range shuffled([]Mode{plainMode, tlsMode}, seed+1) {
		var workloads []Workload
		for _, workload := range shuffled(race.Workloads, seed) {
			// A mixed workload is open loop only, after the rounds (mixedLoop).
			if workload.Mixed == nil && workload.mode() == mode && competitor.offers(workload) &&
				race.loads(workload) {
				workloads = append(workloads, workload)
			}
		}
		if len(workloads) == 0 {
			continue
		}
		// One mode's error leaves the other to race (raceTarget decides
		// whether the class goes on).
		err := raceMode(ctx, race, competitor, target, bodies, round, valid, run, mode, workloads)
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// raceMode starts the competitor in one mode and races its workloads.
func raceMode(ctx context.Context, race Race, competitor Competitor, target Target,
	bodies map[int]string, round int, valid map[string]string, run *Run, mode Mode,
	workloads []Workload) error {
	key := validKey(competitor.Name, mode)
	pid, err := startServer(ctx, race, competitor, target, mode)
	if err != nil {
		// As a measurement's error: each workload's note says why its round
		// is missing.
		err = fmt.Errorf("%s round %d: starting it: %w", competitor.Name, round, err)
		for _, workload := range workloads {
			result := resultFor(run, target.Class.Name, workload.Name, competitor.Name)
			result.Valid, result.Note = len(result.Rounds) > 0, "stopped: "+err.Error()
		}
		return err
	}
	defer stopServer(context.WithoutCancel(ctx), target, pid)
	if err := waitReady(ctx, race, target, mode); err != nil {
		valid[key] = "did not start: " + whyNotReady(ctx, competitor, target, pid)
	}
	if round == 1 && valid[key] == "" {
		valid[key] = validate(ctx, race, target, bodies, mode)
	}
	for _, workload := range workloads {
		result := resultFor(run, target.Class.Name, workload.Name, competitor.Name)
		result.Valid = valid[key] == ""
		if !result.Valid {
			result.Note = valid[key]
			continue
		}
		measured, err := measure(ctx, race, workload, target, bodies, pid)
		if err != nil {
			// The rounds measured stand, and the note (kept through the
			// rounds after) says why one is missing; none, no result.
			err = fmt.Errorf("%s %s round %d: %w", competitor.Name, workload.Name, round, err)
			result.Valid, result.Note = len(result.Rounds) > 0, "stopped: "+err.Error()
			return err
		}
		result.Rounds = append(result.Rounds, measured)
		result.summarize()
	}
	return nil
}

// shuffled is a copy of items in an order the seed decides.
func shuffled[T any](items []T, seed int64) []T {
	order := append([]T(nil), items...)
	random := rand.New(rand.NewPCG(uint64(seed), 0x6472616772616365))
	random.Shuffle(len(order), func(i, j int) { order[i], order[j] = order[j], order[i] })
	return order
}

func resultFor(run *Run, class, workload, competitor string) *Result {
	for i := range run.Results {
		result := &run.Results[i]
		if result.Class == class && result.Workload == workload && result.Competitor == competitor {
			return result
		}
	}
	run.Results = append(run.Results, Result{Class: class, Workload: workload, Competitor: competitor})
	return &run.Results[len(run.Results)-1]
}

// putBodies writes each request body size the workloads need to the
// loader: bytes from the seed, so a run can be repeated exactly.
func putBodies(ctx context.Context, race Race, target Target, seed int64) (map[int]string, error) {
	bodies := map[int]string{}
	for _, workload := range race.Workloads {
		size := workload.BodyBytes
		if size == 0 || bodies[size] != "" {
			continue
		}
		bytes := make([]byte, size)
		random := rand.New(rand.NewPCG(uint64(seed), uint64(size)))
		for i := range bytes {
			bytes[i] = byte(random.Uint32())
		}
		local, err := os.CreateTemp("", "dragrace-body-*")
		if err != nil {
			return nil, err
		}
		if _, err := local.Write(bytes); err != nil {
			return nil, err
		}
		local.Close()
		defer os.Remove(local.Name())
		remote := fmt.Sprintf("%s/body-%d", target.LoaderHome, size)
		if err := target.Loader.Put(ctx, local.Name(), remote); err != nil {
			return nil, err
		}
		bodies[size] = remote
	}
	return bodies, nil
}

func startServer(ctx context.Context, race Race, competitor Competitor, target Target,
	mode Mode) (string, error) {
	// Every server the same way (CONTRIBUTING.md, "The contract"): its binary,
	// told where to serve by the variables roux's host reads, on a fresh
	// copy of the seeded database. SIGPIPE ignored, as systemd starts a
	// service: a server that leaves it at the default dies when a client
	// closes a connection it is writing to (basic-webserver does).
	// Go's and Rust's runtimes never die of it on a socket already, and
	// fourneau's sends carry MSG_NOSIGNAL. Ignored last, by a shell that
	// execs the server: Ubuntu 26.04's nohup (uutils, Rust) puts SIGPIPE
	// back to the default for what it starts (GitHub's runner and the
	// droplets run that image). Every step execs, so $! is the
	// server's pid.
	if _, err := target.Server.Shell(ctx, freshDatabase(target)); err != nil {
		return "", fmt.Errorf("the database for %s: %w", competitor.Name, err)
	}
	env := []string{"ROUX_ADDRESS=" + target.Address, "ROUX_PORT=" + strconv.Itoa(race.Port),
		"ROUX_DATABASE=" + target.ServerHome + "/" + conduitDatabaseName}
	if mode == tlsMode {
		if !competitor.TLS {
			return "", fmt.Errorf("%s serves no TLS", competitor.Name)
		}
		env = append(env, "ROUX_TLS_CERT="+target.ServerHome+"/"+certificateName,
			"ROUX_TLS_KEY="+target.ServerHome+"/"+keyName)
	}
	var command strings.Builder
	command.WriteString("cd " + quote(target.ServerHome) + " && ")
	command.WriteString("ulimit -n $(ulimit -Hn); env")
	for _, variable := range env {
		command.WriteString(" " + quote(variable))
	}
	command.WriteString(" nohup " + target.taskset(target.ServerCPUs))
	command.WriteString("sh -c " + quote(`trap '' PIPE; exec "$0"`) + " ")
	command.WriteString(quote(target.ServerHome+"/bin/"+competitor.Name) + " ")
	command.WriteString("> " + quote(competitor.Name+".log") + " 2>&1 < /dev/null & echo $!")
	pid, err := target.Server.Shell(ctx, command.String())
	if err != nil {
		return "", fmt.Errorf("starting %s: %w", competitor.Name, err)
	}
	return strings.TrimSpace(pid), nil
}

func stopServer(ctx context.Context, target Target, pid string) {
	script := fmt.Sprintf("kill %[1]s 2>/dev/null; for i in $(seq 50); do "+
		"kill -0 %[1]s 2>/dev/null || exit 0; sleep 0.1; done; kill -9 %[1]s", pid)
	if _, err := target.Server.Shell(ctx, script); err != nil {
		log.Printf("stopping %s: %v", pid, err)
	}
}

// whyNotReady says what the server machine knows about a server that never
// answered: whether it is still running, its output's first lines that
// name a failure (a panic's own message, which a stack trace after it
// can push out of the tail), the end of its output, and the kernel's line for an
// out-of-memory kill, an invalid opcode or a segfault.
func whyNotReady(ctx context.Context, competitor Competitor, target Target, pid string) string {
	log := quote(competitor.Name + ".log")
	script := fmt.Sprintf("cd %s; if kill -0 %s 2>/dev/null; then echo 'running, not answering;'; "+
		"else echo 'exited;'; fi; "+
		"{ grep -m 3 -iE 'panic|illegal|segmentation|fault|error' %s; echo '...'; tail -c 600 %s; } "+
		"| tr '\\n' ' '; "+
		"dmesg 2>/dev/null | grep -iE 'out of memory|invalid opcode|segfault' | tail -n 2",
		quote(target.ServerHome), pid, log, log)
	why, err := target.Server.Shell(ctx, script)
	if err != nil {
		return "no answer in 10 s (" + err.Error() + ")"
	}
	return "no answer in 10 s: " + strings.Join(strings.Fields(why), " ")
}

func baseURL(race Race, target Target, mode Mode) string {
	scheme := "http"
	if mode == tlsMode {
		scheme = "https"
	}
	return fmt.Sprintf("%s://%s:%d", scheme, target.Address, race.Port)
}

// curlFor is curl as the checks run it: over TLS it takes the race's own
// certificate (-k) and offers oha's ciphers in oha's order (rustls's:
// AES-256-GCM first), so the cipher a check sees is the one the race uses.
func curlFor(mode Mode) string {
	if mode == tlsMode {
		return "curl -s -m 5 -k --tls13-ciphers " +
			"TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256 "
	}
	return "curl -s -m 5 "
}

func waitReady(ctx context.Context, race Race, target Target, mode Mode) error {
	curl := strings.Replace(curlFor(mode), "-m 5", "-m 1", 1)
	script := fmt.Sprintf("for i in $(seq 100); do "+
		"[ \"$(%s-o /dev/null -w '%%{http_code}' %s/plaintext)\" = 200 ] && exit 0; "+
		"sleep 0.1; done; exit 1", curl, baseURL(race, target, mode))
	_, err := target.Loader.Shell(ctx, script)
	return err
}

// validate checks that a competitor does the work: the exact plaintext,
// the echoed body byte for byte, a 404. "" when it does. In TLS mode, the
// same over HTTPS, HTTP/2 by ALPN, and what TLS was agreed (validateTLS).
func validate(ctx context.Context, race Race, target Target, bodies map[int]string,
	mode Mode) string {
	url := baseURL(race, target, mode)
	curl := curlFor(mode)
	got, err := target.Loader.Shell(ctx, curl+url+"/plaintext")
	if err != nil || got != "Hello, World!" {
		return fmt.Sprintf("/plaintext answered %q", got)
	}
	if mode == tlsMode {
		if why := validateTLS(ctx, target, url); why != "" {
			return why
		}
	}
	for _, body := range bodies {
		want, err := target.Loader.Shell(ctx, "sha256sum < "+quote(body)+" | cut -c1-64")
		if err != nil {
			return err.Error()
		}
		got, err := target.Loader.Shell(ctx, curl+"-X POST --data-binary @"+quote(body)+
			" -H 'Content-Type: application/octet-stream' "+url+"/echo | sha256sum | cut -c1-64")
		if err != nil || got != want {
			return "/echo did not answer the body it was sent"
		}
	}
	got, err = target.Loader.Shell(ctx, curl+url+"/menu")
	// Shell trims trailing newlines from what it returns; so is the reference.
	want := strings.TrimRight(canonicalEntities(race.Menu), "\n")
	if err != nil || canonicalEntities(got) != want {
		return "/menu did not render the menu (workloads/menu.html)"
	}
	if why := validateStream(ctx, race, target, mode); why != "" {
		return why
	}
	if mode == plainMode && race.hasH2C() {
		got, err = target.Loader.Shell(ctx, curl+"--http2-prior-knowledge "+url+"/plaintext")
		if err != nil || got != "Hello, World!" {
			return fmt.Sprintf("/plaintext over HTTP/2 (h2c) answered %q", got)
		}
	}
	got, err = target.Loader.Shell(ctx, curl+"-o /dev/null -w '%{http_code}' "+url+"/nope")
	if err != nil || got != "404" {
		return fmt.Sprintf("/nope answered %s, not 404", got)
	}
	return ""
}

// ohaCommand is one oha run on the loader, closed loop: each connection's
// next request when its answer arrives (mixed.go's partCommand is the open
// loop). Every run:
//   - --disable-compression: oha otherwise asks for gzip and brotli, which
//     a server that compresses (basic-webserver) honours and the others
//     do not, so the race would measure compression policy, not serving
//     (the checks, through curl, never ask);
//   - --worker-threads at the loader's CPUs: oha's default is the
//     physical cores it sees, which a VM may report as fewer.
func ohaCommand(race Race, workload Workload, target Target, bodies map[int]string,
	seconds int) string {
	var command strings.Builder
	command.WriteString("ulimit -n $(ulimit -Hn); " + target.taskset(target.LoaderCPUs))
	fmt.Fprintf(&command, "%s/oha -z %ds -c %d --no-tui --output-format json --disable-compression",
		quote(target.LoaderHome), seconds, workload.Connections)
	if target.LoaderThreads > 0 {
		fmt.Fprintf(&command, " --worker-threads %d", target.LoaderThreads)
	}
	if !workload.Keepalive {
		command.WriteString(" --disable-keepalive")
	}
	if workload.HTTP2 {
		fmt.Fprintf(&command, " --http2 -p %d", max(1, workload.Streams))
	}
	if workload.TLS {
		// The race's own certificate. oha offers HTTP/2 by ALPN only with
		// --http2; churn-tls, without it, is HTTP/1.1 over TLS.
		command.WriteString(" --insecure")
	}
	if workload.Method != "GET" {
		command.WriteString(" -m " + workload.Method)
	}
	if workload.BodyBytes > 0 {
		command.WriteString(" -D " + quote(bodies[workload.BodyBytes]))
		command.WriteString(" -T " + quote(workload.ContentType))
	}
	command.WriteString(" " + baseURL(race, target, workload.mode()) + workload.Path)
	return command.String()
}

func measure(ctx context.Context, race Race, workload Workload, target Target,
	bodies map[int]string, pid string) (Round, error) {
	oha := func(seconds int) string {
		return ohaCommand(race, workload, target, bodies, seconds)
	}
	if _, err := target.Loader.Shell(ctx, oha(race.WarmupSeconds)); err != nil {
		return Round{}, fmt.Errorf("warmup: %w", err)
	}
	serverBefore, loaderBefore, err := snapshots(ctx, target, pid, true)
	if err != nil {
		return Round{}, err
	}
	report, err := target.Loader.Shell(ctx, oha(race.MeasureSeconds))
	if err != nil {
		return Round{}, fmt.Errorf("oha: %w", err)
	}
	serverAfter, loaderAfter, err := snapshots(ctx, target, pid, false)
	if err != nil {
		return Round{}, err
	}
	round, err := parseOha(report)
	if err != nil {
		return Round{}, err
	}
	local := net.ParseIP(target.Address).IsLoopback()
	cost := serverCost(serverBefore, serverAfter, target.ServerCPUs, local)
	round.addServerCost(cost.over(round.LoadSeconds))
	round.LoaderCPUBusyPct = loaderBusy(loaderBefore, loaderAfter, target.LoaderCPUs, round.LoadSeconds)
	hwm, err := target.Server.Shell(ctx, "awk '/VmHWM/ {print $2}' /proc/"+pid+"/status")
	if err == nil {
		round.RSSKiB, _ = strconv.Atoi(strings.TrimSpace(hwm))
	}
	log.Printf("    %-10s %10.0f req/s  p99 %.2f ms  cpu %.0f%%", workload.Name, round.RPS,
		round.P99Ms, round.CPUBusyPct)
	return round, nil
}

// snapshots of the server and of the loader, one shell call each, the
// server's nearest the load: before it, the loader's first; after it,
// the server's first. Even so a window outlasts the load by the shell
// calls' round trips, so rates are taken over oha's own duration
// (ServerCost.over).
func snapshots(ctx context.Context, target Target, pid string, before bool) (server, loader Snapshot, err error) {
	takeServer := func() error {
		text, err := target.Server.Shell(ctx, snapshotCommand(pid))
		if err == nil {
			server, err = parseSnapshot(text)
		}
		return err
	}
	takeLoader := func() error {
		text, err := target.Loader.Shell(ctx, snapshotCommand(""))
		if err == nil {
			loader, err = parseSnapshot(text)
		}
		return err
	}
	first, second := takeServer, takeLoader
	if before {
		first, second = takeLoader, takeServer
	}
	if err := first(); err != nil {
		return server, loader, err
	}
	err = second()
	return server, loader, err
}

func (round *Round) addServerCost(cost ServerCost) {
	round.CPUBusyPct = cost.CPU.Busy
	round.StealPct = cost.CPU.Steal
	round.CPUUserPct = cost.CPU.User
	round.CPUSystemPct = cost.CPU.System
	round.CPUIrqPct = cost.CPU.Irq
	round.CPUSoftirqPct = cost.CPU.Softirq
	round.NetRxMbps = cost.NetRxMbps
	round.NetTxMbps = cost.NetTxMbps
	round.NetRxPPS = cost.NetRxPPS
	round.NetTxPPS = cost.NetTxPPS
	round.Retransmits = cost.Retransmits
	round.Threads = cost.Threads
	round.VoluntarySwitches = cost.VoluntarySwitches
	round.InvoluntarySwitches = cost.InvoluntarySwitches
	round.Seconds = cost.Seconds
}

// ohaReport is the part of oha's JSON output a round keeps (oha 1.16;
// times in seconds).
type ohaReport struct {
	Summary struct {
		SuccessRate    float64 `json:"successRate"`
		RequestsPerSec float64 `json:"requestsPerSec"`
		Total          float64 `json:"total"`
		Average        float64 `json:"average"`
		Slowest        float64 `json:"slowest"`
		SizePerRequest float64 `json:"sizePerRequest"`
	} `json:"summary"`
	RPS struct {
		Stddev float64 `json:"stddev"`
	} `json:"rps"`
	Details struct {
		DNSDialup struct {
			Average float64 `json:"average"`
		} `json:"DNSDialup"`
	} `json:"details"`
	LatencyPercentiles   map[string]float64 `json:"latencyPercentiles"`
	FirstBytePercentiles map[string]float64 `json:"firstBytePercentiles"`
	StatusCodes          map[string]int     `json:"statusCodeDistribution"`
	Errors               map[string]int     `json:"errorDistribution"`
}

func parseOha(text string) (Round, error) {
	var report ohaReport
	if err := json.Unmarshal([]byte(text), &report); err != nil {
		return Round{}, fmt.Errorf("oha output: %w", err)
	}
	round := Round{
		RPS:         report.Summary.RequestsPerSec,
		SuccessRate: report.Summary.SuccessRate,
		P50Ms:       report.LatencyPercentiles["p50"] * 1000,
		P99Ms:       report.LatencyPercentiles["p99"] * 1000,
		P999Ms:      report.LatencyPercentiles["p99.9"] * 1000,
		LoadSeconds: report.Summary.Total,

		P90Ms:              report.LatencyPercentiles["p90"] * 1000,
		P95Ms:              report.LatencyPercentiles["p95"] * 1000,
		P9999Ms:            report.LatencyPercentiles["p99.99"] * 1000,
		MeanMs:             report.Summary.Average * 1000,
		MaxMs:              report.Summary.Slowest * 1000,
		FirstByteP50Ms:     report.FirstBytePercentiles["p50"] * 1000,
		FirstByteP99Ms:     report.FirstBytePercentiles["p99"] * 1000,
		RPSPerSecondStddev: report.RPS.Stddev,
		ConnectMeanMs:      report.Details.DNSDialup.Average * 1000,
		BytesPerResponse:   report.Summary.SizePerRequest,
	}
	for status, count := range report.StatusCodes {
		if !strings.HasPrefix(status, "2") {
			round.Non2xx += count
		}
	}
	for kind, count := range report.Errors {
		// Requests still in flight when the clock runs out are not errors.
		if kind != "aborted due to deadline" {
			round.Errors += count
		}
	}
	// Throughput counts good answers only: errors and non-2xx are no work
	// done. oha's rate counts every request that ended, errors too, so a
	// dead server would race at 121k requests/s: the rate is
	// scaled by the share of good answers among all, errors included.
	answered, ended := 0, 0
	for _, count := range report.StatusCodes {
		answered += count
	}
	ended = answered
	for _, count := range report.Errors {
		ended += count
	}
	if ended == 0 {
		round.RPS = 0
	} else {
		round.RPS *= float64(answered-round.Non2xx) / float64(ended)
	}
	return round, nil
}

// cpuSet parses "0-1,4" into a set of ids; nil for "" (the whole machine).
func cpuSet(cpus string) map[string]bool {
	if cpus == "" {
		return nil
	}
	set := map[string]bool{}
	for _, part := range strings.Split(cpus, ",") {
		low, high, found := strings.Cut(part, "-")
		first, _ := strconv.Atoi(low)
		last := first
		if found {
			last, _ = strconv.Atoi(high)
		}
		for id := first; id <= last; id++ {
			set[strconv.Itoa(id)] = true
		}
	}
	return set
}

// machineInfo asks a machine what it is.
func machineInfo(ctx context.Context, machine Machine, role, class, size string) MachineInfo {
	info := MachineInfo{Role: role, Class: class, Size: size}
	info.CPU, _ = machine.Shell(ctx, "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'")
	cpus, _ := machine.Shell(ctx, "nproc")
	info.CPUs, _ = strconv.Atoi(strings.TrimSpace(cpus))
	info.Kernel, _ = machine.Shell(ctx, "uname -r")
	info.CPUID = cpuID(ctx, machine)
	memory, _ := machine.Shell(ctx, "awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo")
	info.MemoryMiB, _ = strconv.Atoi(strings.TrimSpace(memory))
	return info
}

// quote makes a string one shell word.
func quote(text string) string {
	return "'" + strings.ReplaceAll(text, "'", `'\''`) + "'"
}

func newRun(root, where string, race Race) (Run, error) {
	versions, err := versionRows(root, race)
	if err != nil {
		return Run{}, err
	}
	fingerprint, err := fingerprintOf(root)
	if err != nil {
		return Run{}, err
	}
	started := time.Now().UTC()
	return Run{
		ID:          runID(where, started),
		Where:       where,
		StartedAt:   started,
		Seed:        started.UnixNano(),
		Fingerprint: fingerprint,
		Versions:    versions,
		Race:        race,
	}, nil
}

func summaryTable(run Run) string {
	var text strings.Builder
	for _, result := range run.Results {
		mark := ""
		if !result.Valid {
			mark = "  INVALID: " + result.Note
		}
		if len(result.Rounds) == 0 && len(result.OpenLoop) > 0 {
			// A mixed workload: its top step, its mean.
			top := result.OpenLoop[len(result.OpenLoop)-1]
			fmt.Fprintf(&text, "%-12s %-10s %-14s %12.0f req/s  mean %6.2f ms at %.0f/s offered%s\n",
				result.Class, result.Workload, result.Competitor, top.AchievedRPS, top.MeanMs,
				top.OfferedRPS, mark)
			continue
		}
		fmt.Fprintf(&text, "%-12s %-10s %-14s %12.0f req/s  p99 %7.2f ms%s\n", result.Class,
			result.Workload, result.Competitor, result.BestRPS, result.MedianP99Ms, mark)
	}
	return text.String()
}

// entitySpellings is every way the competitors' engines write the five
// characters HTML escaping is about, mapped to one: html/template writes
// &#34;, askama &#38;, rocstache &amp;. A character left raw stays raw, so
// a page that does not escape still fails.
var entitySpellings = strings.NewReplacer(
	"&#38;", "&amp;", "&#x26;", "&amp;",
	"&#60;", "&lt;", "&#x3c;", "&lt;", "&#x3C;", "&lt;",
	"&#62;", "&gt;", "&#x3e;", "&gt;", "&#x3E;", "&gt;",
	"&#34;", "&quot;", "&#x22;", "&quot;",
	"&#x27;", "&#39;", "&apos;", "&#39;",
)

func canonicalEntities(page string) string { return entitySpellings.Replace(page) }

// validateStream checks the SSE workload's route when the race runs it:
// the stream, sent a chunk per event (checkStream), and 400 for a request
// without signals. Raw bytes cross the shell as base64: it trims newlines.
// Over TLS too in HTTP/1.1, whose chunks show how the events were sent.
func validateStream(ctx context.Context, race Race, target Target, mode Mode) string {
	var workload *Workload
	for i := range race.Workloads {
		if race.Workloads[i].Name == "sse" {
			workload = &race.Workloads[i]
		}
	}
	if workload == nil {
		return ""
	}
	url := baseURL(race, target, mode)
	curl := curlFor(mode)
	encoded, err := target.Loader.Shell(ctx, curl+"--http1.1 --include --raw "+
		quote(url+workload.Path)+" | base64 -w0")
	if err != nil {
		return "/sse: " + err.Error()
	}
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "/sse: " + err.Error()
	}
	if why := checkStream(string(raw), race.Stream); why != "" {
		return "/sse: " + why
	}
	path, _, _ := strings.Cut(workload.Path, "?")
	got, err := target.Loader.Shell(ctx, curl+"-o /dev/null -w '%{http_code}' "+url+path)
	if err != nil || got != "400" {
		return fmt.Sprintf("%s without signals answered %s, not 400", path, got)
	}
	return ""
}

// cpuID is the first CPU's family:model:stepping.
func cpuID(ctx context.Context, machine Machine) string {
	id, err := machine.Shell(ctx, "awk -F': *' '/^cpu family/ && !f {f=$2} "+
		"/^model[ \\t]*:/ && !m {m=$2} /^stepping/ && !s {s=$2} END {print f\":\"m\":\"s}' /proc/cpuinfo")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(id)
}
