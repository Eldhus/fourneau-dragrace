package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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

// raceFlags are the flags both races take.
type raceFlags struct {
	serverCPUs  string
	loaderCPUs  string
	quick       bool
	competitors string
	workloads   string
	results     string
}

func parseRaceFlags(name, root string, args []string) raceFlags {
	flags := newFlags(name)
	var parsed raceFlags
	flags.BoolVar(&parsed.quick, "quick", false, "one short round: a smoke test, not a result")
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
		race.Rounds, race.WarmupSeconds, race.MeasureSeconds = 1, 1, 3
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
	if err := buildAll(ctx, root, tools, competitors); err != nil {
		return err
	}
	run, err := newRun(root, "local", race)
	if err != nil {
		return err
	}
	run.Timing.BuildSeconds = watch.since()
	machine := LocalMachine{}
	loaderHome := filepath.Join(outDir(root), "loader")
	if err := machine.Put(ctx, tools.Oha, filepath.Join(loaderHome, "oha")); err != nil {
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
	return nil
}
