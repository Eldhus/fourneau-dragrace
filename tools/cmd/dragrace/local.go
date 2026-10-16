package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// LocalMachine is this computer.
type LocalMachine struct{}

func (LocalMachine) Shell(ctx context.Context, script string) (string, error) {
	cmd := exec.CommandContext(ctx, "bash", "-c", script)
	cmd.Stderr = os.Stderr
	bytes, err := cmd.Output()
	return strings.TrimRight(string(bytes), "\n"), err
}

func (LocalMachine) Put(ctx context.Context, local, remote string) error {
	if local == remote {
		return nil
	}
	bytes, err := os.ReadFile(local)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(remote), 0o755); err != nil {
		return err
	}
	return os.WriteFile(remote, bytes, 0o755)
}

// raceFlags are race local's flags.
type raceFlags struct {
	serverCPUs  string
	loaderCPUs  string
	quick       bool
	competitors string
	workloads   string
	results     string
	since       string
}

// smokeWorkloads are what -quick races, unless -workloads says: a cell of
// each protocol, connections made and closed, and the database. The
// checks before each server's cells (race.go, checkServer) ask every
// workload's path in each mode, so a wrong answer anywhere fails without
// loading it.
var smokeWorkloads = []string{"plaintext", "plaintext-h2", "plaintext-tls", "churn", "conduit"}

func parseRaceFlags(name, root string, args []string) raceFlags {
	flags := newFlags(name)
	var parsed raceFlags
	flags.BoolVar(&parsed.quick, "quick", false,
		"a smoke test, not a result: one 2 s round of a few workloads; any invalid result fails it")
	flags.StringVar(&parsed.since, "since", "",
		"a release's build.json: race only the competitors that moved since (keys.go, smokeSet); a missing file races all")
	flags.StringVar(&parsed.serverCPUs, "server-cpus", "", "local race: the server's CPUs (default race.json's)")
	flags.StringVar(&parsed.loaderCPUs, "loader-cpus", "", "local race: oha's CPUs (default race.json's)")
	flags.StringVar(&parsed.competitors, "competitors", "", "comma-separated (default: all)")
	flags.StringVar(&parsed.workloads, "workloads", "", "comma-separated (default: all)")
	flags.StringVar(&parsed.results, "results", filepath.Join(outDir(root), "results"),
		"directory for the results file")
	flags.Parse(args)
	return parsed
}

// narrow applies the flags to race.json.
func (flags raceFlags) narrow(race Race) Race {
	if flags.serverCPUs != "" {
		race.Local.ServerCPUs = flags.serverCPUs
	}
	if flags.loaderCPUs != "" {
		race.Local.LoaderCPUs = flags.loaderCPUs
	}
	if flags.quick {
		race.Rounds, race.WarmupSeconds, race.MeasureSeconds = 1, 1, 1
		workloads := append([]Workload(nil), race.Workloads...)
		for i, workload := range workloads {
			if workload.Mixed == nil {
				continue
			}
			mixed := *workload.Mixed
			mixed.Rates = mixed.Rates[:min(1, len(mixed.Rates))]
			mixed.WarmupSeconds, mixed.MeasureSeconds = 1, 1
			workloads[i].Mixed = &mixed
		}
		race.Workloads = workloads
		if flags.workloads == "" {
			race.loaded = smokeWorkloads
		}
	}
	if flags.competitors != "" {
		race.Competitors = strings.Split(flags.competitors, ",")
	}
	if flags.workloads != "" {
		keep := map[string]bool{}
		for _, name := range strings.Split(flags.workloads, ",") {
			keep[name] = true
		}
		var workloads []Workload
		for _, workload := range race.Workloads {
			if keep[workload.Name] {
				workloads = append(workloads, workload)
			}
		}
		race.Workloads = workloads
	}
	return race
}

// commandRaceLocal races on this machine: the servers on race.json's
// local.server_cpus, oha on local.loader_cpus, over loopback. Loopback is
// not a network: the numbers compare competitors, not deployments.
func commandRaceLocal(ctx context.Context, root string, args []string) error {
	flags := parseRaceFlags("race local", root, args)
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	race = flags.narrow(race)
	watch := stopwatch{start: time.Now()}
	if race.Local.ServerCPUs != "" && race.Local.LoaderCPUs != "" {
		if err := checkCoresApart(race.Local.ServerCPUs, race.Local.LoaderCPUs, sysfsCore); err != nil {
			return err
		}
	}
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return err
	}
	competitors, err := loadCompetitors(root, race.Competitors)
	if err != nil {
		return err
	}
	// Before the build, which can take minutes; with -since, once the
	// competitors raced are known.
	if flags.since == "" {
		if err := checkKernelTLS(race, competitors, readULPs()); err != nil {
			return err
		}
	}
	if err := buildAll(ctx, root, tools, competitors); err != nil {
		return err
	}
	if flags.since != "" {
		// Every competitor is built (the bundle takes them all); only
		// those that moved are raced.
		if competitors, err = movedSince(ctx, root, flags.since, competitors); err != nil {
			return err
		}
		if len(competitors) == 0 {
			fmt.Println("nothing to race: no competitor and not the harness moved since", flags.since)
			return nil
		}
		race.Competitors = nil
		for _, competitor := range competitors {
			race.Competitors = append(race.Competitors, competitor.Name)
		}
		log.Printf("racing what moved since %s: %s", flags.since, strings.Join(race.Competitors, ", "))
		if err := checkKernelTLS(race, competitors, readULPs()); err != nil {
			return err
		}
	}
	run, err := newRun(root, "local", race)
	if err != nil {
		return err
	}
	oha, err := fetchOha(ctx, race.Oha)
	if err != nil {
		return err
	}
	run.Timing.BuildSeconds = watch.since()
	machine := LocalMachine{}
	loaderHome := filepath.Join(outDir(root), "loader")
	if err := machine.Put(ctx, oha, filepath.Join(loaderHome, "oha")); err != nil {
		return err
	}
	cpu, _ := machine.Shell(ctx, "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'")
	target := Target{
		Class: ServerClass{
			Name:  "local",
			Title: fmt.Sprintf("%s: server on CPUs %s, loader on %s", cpu, race.Local.ServerCPUs, race.Local.LoaderCPUs),
		},
		Server:        machine,
		Loader:        machine,
		ServerHome:    outDir(root),
		LoaderHome:    loaderHome,
		Address:       "127.0.0.1",
		ServerCPUs:    race.Local.ServerCPUs,
		LoaderCPUs:    race.Local.LoaderCPUs,
		LoaderThreads: len(cpuSet(race.Local.LoaderCPUs)),
	}
	if err := putConduitSeed(ctx, root, target); err != nil {
		return err
	}
	run.Machines = []MachineInfo{machineInfo(ctx, machine, "server", "local", "this computer")}
	raced := time.Now()
	if err := raceTarget(ctx, race, competitors, target, &run); err != nil {
		return err
	}
	run.Timing.RacingSeconds = time.Since(raced).Seconds()
	run.Timing.Classes = []ClassTiming{{Class: "local", Seconds: run.Timing.RacingSeconds}}
	run.Timing.Seconds = watch.since()
	run.FinishedAt = time.Now().UTC()
	path, err := saveRun(flags.results, run)
	if err != nil {
		return err
	}
	fmt.Print(summaryTable(run))
	fmt.Println("results:", path)
	if flags.quick {
		return invalidResults(run)
	}
	return nil
}

// ulpsPath lists the kernel's TCP upper-layer protocols: `tls` once its
// module is loaded.
const ulpsPath = "/proc/sys/net/ipv4/tcp_available_ulp"

// readULPs is ulpsPath's list, "" when it cannot be read.
func readULPs() string {
	bytes, err := os.ReadFile(ulpsPath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(bytes))
}

// checkKernelTLS refuses a race whose kernel-TLS competitors (KernelTLS)
// would race a TLS workload on a kernel without `tls` in ulps: each would
// not start, and say so only in its results, after the race.
func checkKernelTLS(race Race, competitors []Competitor, ulps string) error {
	if slices.Contains(strings.Fields(ulps), "tls") {
		return nil
	}
	if !slices.ContainsFunc(race.Workloads, func(w Workload) bool { return w.TLS && race.loads(w) }) {
		return nil
	}
	var need, rest []string
	for _, competitor := range competitors {
		if competitor.TLS && competitor.KernelTLS {
			need = append(need, competitor.Name)
		} else {
			rest = append(rest, competitor.Name)
		}
	}
	if len(need) == 0 {
		return nil
	}
	escape := ""
	if len(rest) > 0 {
		escape = "\nor race without them: -competitors " + strings.Join(rest, ",")
	}
	return fmt.Errorf("%s serve HTTPS through the kernel's TLS, which this kernel has not loaded "+
		"(%s lists %q). Load it:\n"+
		"  sudo modprobe tls                                 # now\n"+
		"  echo tls | sudo tee /etc/modules-load.d/tls.conf  # and at every boot%s",
		strings.Join(need, " and "), ulpsPath, ulps, escape)
}

// movedSince keeps the competitors smokeSet picks against a release's
// build.json; a missing file is no release yet, and races them all.
func movedSince(ctx context.Context, root, since string, competitors []Competitor) ([]Competitor,
	error) {
	var last *BuildInfo
	var info BuildInfo
	if err := readJSON(since, &info); err == nil {
		last = &info
	} else if errors.Is(err, fs.ErrNotExist) {
		log.Printf("%s: none, so every competitor races", since)
	} else {
		return nil, err
	}
	var keys map[string]string
	if err := readJSON(competitorKeysPath(root), &keys); err != nil {
		return nil, err
	}
	harness, err := harnessKey(ctx, root)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(competitors))
	for _, competitor := range competitors {
		names = append(names, competitor.Name)
	}
	picked := smokeSet(names, keys, harness, last)
	return slices.DeleteFunc(competitors, func(c Competitor) bool {
		return !slices.Contains(picked, c.Name)
	}), nil
}

// invalidResults is a smoke race's verdict: an error naming every result
// that is not valid, nil when all are.
func invalidResults(run Run) error {
	var invalid []string
	for _, result := range run.Results {
		if !result.Valid {
			invalid = append(invalid, fmt.Sprintf("%s %s: %s", result.Competitor, result.Workload, result.Note))
		}
	}
	if len(invalid) == 0 {
		return nil
	}
	return fmt.Errorf("%d results not valid:\n  %s", len(invalid), strings.Join(invalid, "\n  "))
}
