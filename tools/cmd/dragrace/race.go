package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"log"
	"math/rand/v2"
	"net"
	"os"
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
}

func (target Target) report(result Result) {
	if target.Report != nil {
		target.Report(result)
	}
}

func (target Target) taskset(cpus string) string {
	if cpus == "" {
		return ""
	}
	return "taskset -c " + cpus + " "
}

// raceTarget races every competitor on every workload, round after round,
// in a new random order each round (the seed is in the results), and
// appends to run.Results.
func raceTarget(ctx context.Context, race Race, competitors []Competitor, target Target,
	run *Run) error {
	bodies, err := putBodies(ctx, race, target, run.Seed)
	if err != nil {
		return err
	}
	valid := map[string]string{} // competitor -> why it is not valid ("" if valid)
	for round := 1; round <= race.Rounds; round++ {
		order := shuffled(competitors, run.Seed+int64(round))
		for _, competitor := range order {
			log.Printf("[%s] round %d/%d: %s", target.Class.Name, round, race.Rounds, competitor.Name)
			if err := raceCompetitor(ctx, race, competitor, target, bodies, round, valid, run); err != nil {
				return err
			}
			for _, result := range run.Results {
				if result.Class == target.Class.Name && result.Competitor == competitor.Name {
					target.report(result)
				}
			}
		}
	}
	if race.OpenLoop.enabled() {
		if err := openLoop(ctx, race, competitors, target, bodies, valid, run); err != nil {
			return err
		}
	}
	return mixedLoop(ctx, race, competitors, target, valid, run)
}

func raceCompetitor(ctx context.Context, race Race, competitor Competitor, target Target,
	bodies map[int]string, round int, valid map[string]string, run *Run) error {
	pid, err := startServer(ctx, race, competitor, target)
	if err != nil {
		return err
	}
	defer stopServer(context.WithoutCancel(ctx), target, pid)
	if err := waitReady(ctx, race, target); err != nil {
		valid[competitor.Name] = "did not start: " + whyNotReady(ctx, competitor, target, pid)
	}
	if round == 1 && valid[competitor.Name] == "" {
		valid[competitor.Name] = validate(ctx, race, target, bodies)
	}
	// Each round and competitor its own order of workloads: in one order
	// always, a server process's drift (memory grown, churn's TIME_WAIT
	// left behind) landed on the same workloads every time. From the seed,
	// so a run replays.
	name := fnv.New64a()
	name.Write([]byte(competitor.Name))
	order := shuffled(race.Workloads, run.Seed+int64(round)*7919+int64(name.Sum64()>>1))
	for _, workload := range order {
		if workload.Mixed != nil {
			continue // open loop only, after the rounds (mixedLoop)
		}
		result := resultFor(run, target.Class.Name, workload.Name, competitor.Name)
		result.Valid = valid[competitor.Name] == ""
		result.Note = valid[competitor.Name]
		if !result.Valid {
			continue
		}
		measured, err := measure(ctx, race, workload, target, bodies, pid)
		if err != nil {
			return fmt.Errorf("%s %s: %w", competitor.Name, workload.Name, err)
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

func startServer(ctx context.Context, race Race, competitor Competitor, target Target) (string, error) {
	values := map[string]string{
		"bin":     target.ServerHome + "/bin/" + competitor.Name,
		"address": target.Address,
		"port":    strconv.Itoa(race.Port),
		"db":      target.ServerHome + "/" + conduitDatabaseName,
	}
	var command strings.Builder
	command.WriteString("cd " + quote(target.ServerHome) + " && ")
	command.WriteString("ulimit -n $(ulimit -Hn); ")
	command.WriteString("env")
	for key, value := range competitor.Run.Env {
		command.WriteString(" " + quote(key+"="+expand(value, values)))
	}
	command.WriteString(" nohup " + target.taskset(target.ServerCPUs))
	for _, arg := range competitor.Run.Argv {
		command.WriteString(quote(expand(arg, values)) + " ")
	}
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
// pushed out of the tail: 2026-10-06, an illegal instruction known only
// as "in cpu_count"), the end of its output, and the kernel's line for an
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

func baseURL(race Race, target Target) string {
	return fmt.Sprintf("http://%s:%d", target.Address, race.Port)
}

func waitReady(ctx context.Context, race Race, target Target) error {
	script := fmt.Sprintf("for i in $(seq 100); do "+
		"[ \"$(curl -s -m 1 -o /dev/null -w '%%{http_code}' %s/plaintext)\" = 200 ] && exit 0; "+
		"sleep 0.1; done; exit 1", baseURL(race, target))
	_, err := target.Loader.Shell(ctx, script)
	return err
}

// validate checks that a competitor does the work: the exact plaintext,
// the echoed body byte for byte, a 404. "" when it does.
func validate(ctx context.Context, race Race, target Target, bodies map[int]string) string {
	url := baseURL(race, target)
	got, err := target.Loader.Shell(ctx, "curl -s -m 5 "+url+"/plaintext")
	if err != nil || got != "Hello, World!" {
		return fmt.Sprintf("/plaintext answered %q", got)
	}
	for _, body := range bodies {
		want, err := target.Loader.Shell(ctx, "sha256sum < "+quote(body)+" | cut -c1-64")
		if err != nil {
			return err.Error()
		}
		got, err := target.Loader.Shell(ctx, "curl -s -m 5 -X POST --data-binary @"+quote(body)+
			" -H 'Content-Type: application/octet-stream' "+url+"/echo | sha256sum | cut -c1-64")
		if err != nil || got != want {
			return "/echo did not answer the body it was sent"
		}
	}
	got, err = target.Loader.Shell(ctx, "curl -s -m 5 "+url+"/menu")
	// Shell trims trailing newlines from what it returns; so is the reference.
	want := strings.TrimRight(canonicalEntities(race.Menu), "\n")
	if err != nil || canonicalEntities(got) != want {
		return "/menu did not render the menu (workloads/menu.html)"
	}
	if why := validateStream(ctx, race, target); why != "" {
		return why
	}
	got, err = target.Loader.Shell(ctx, "curl -s -m 5 -o /dev/null -w '%{http_code}' "+url+"/nope")
	if err != nil || got != "404" {
		return fmt.Sprintf("/nope answered %s, not 404", got)
	}
	return ""
}

// LoadShape is how oha sends: closed loop (rate 0: each connection's next
// request when its answer arrives) or open loop at a fixed rate.
type LoadShape struct {
	Seconds int
	// Requests a second, offered whatever the server does; 0 for a closed
	// loop. Latency is then counted from when each request was due
	// (--latency-correction), so a stall counts against every request it
	// delays (coordinated omission).
	Rate int
}

// ohaCommand is one oha run on the loader. Every run, closed or open:
//   - --disable-compression: oha otherwise asks for gzip and brotli, which
//     a server that compresses (basic-webserver) honours and the others
//     do not, so the race measured compression policy, not serving
//     (found 2026-10-06; the checks, through curl, never ask);
//   - --worker-threads at the loader's CPUs: oha's default is the
//     physical cores it sees, which a VM may report as fewer.
func ohaCommand(race Race, workload Workload, target Target, bodies map[int]string,
	shape LoadShape) string {
	var command strings.Builder
	command.WriteString("ulimit -n $(ulimit -Hn); " + target.taskset(target.LoaderCPUs))
	fmt.Fprintf(&command, "%s/oha -z %ds -c %d --no-tui --output-format json --disable-compression",
		quote(target.LoaderHome), shape.Seconds, workload.Connections)
	if target.LoaderThreads > 0 {
		fmt.Fprintf(&command, " --worker-threads %d", target.LoaderThreads)
	}
	if shape.Rate > 0 {
		fmt.Fprintf(&command, " -q %d --latency-correction", shape.Rate)
	}
	if !workload.Keepalive {
		command.WriteString(" --disable-keepalive")
	}
	if workload.Method != "GET" {
		command.WriteString(" -m " + workload.Method)
	}
	if workload.BodyBytes > 0 {
		command.WriteString(" -D " + quote(bodies[workload.BodyBytes]))
		command.WriteString(" -T " + quote(workload.ContentType))
	}
	command.WriteString(" " + baseURL(race, target) + workload.Path)
	return command.String()
}

func measure(ctx context.Context, race Race, workload Workload, target Target,
	bodies map[int]string, pid string) (Round, error) {
	oha := func(seconds int) string {
		return ohaCommand(race, workload, target, bodies, LoadShape{Seconds: seconds})
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
// calls' round trips (from GitHub's runner to the droplets, about six
// seconds of 26 on 2026-10-06, which read every CPU figure 23% low), so
// rates are taken over oha's own duration (ServerCost.over).
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
	// dead server once raced at 121k requests/s (2026-10-06): the rate is
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
	return info
}

// quote makes a string one shell word.
func quote(text string) string {
	return "'" + strings.ReplaceAll(text, "'", `'\''`) + "'"
}

func newRun(root, where string, race Race) (Run, error) {
	versions, err := loadVersions(root)
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
		fmt.Fprintf(&text, "%-12s %-10s %-14s %12.0f req/s  p99 %7.2f ms%s\n", result.Class,
			result.Workload, result.Competitor, result.MedianRPS, result.MedianP99Ms, mark)
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
func validateStream(ctx context.Context, race Race, target Target) string {
	var workload *Workload
	for i := range race.Workloads {
		if race.Workloads[i].Name == "sse" {
			workload = &race.Workloads[i]
		}
	}
	if workload == nil {
		return ""
	}
	url := baseURL(race, target)
	encoded, err := target.Loader.Shell(ctx, "curl -s -m 5 --include --raw "+
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
	got, err := target.Loader.Shell(ctx, "curl -s -m 5 -o /dev/null -w '%{http_code}' "+url+path)
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

// cpuMatches says whether a machine's CPU is the one a class asks for: a
// part of its model name, or its family:model:stepping exactly.
func cpuMatches(wanted, model, id string) bool {
	if wanted == "" {
		return true
	}
	return strings.Contains(model, wanted) || id == wanted
}
