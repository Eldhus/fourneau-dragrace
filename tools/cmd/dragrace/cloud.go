package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// raceUserData prepares a race droplet: nothing else running (no apt timers),
// and the network limits a load test needs, the same on every droplet.
const raceUserData = `#cloud-config
runcmd:
  - systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer snapd || true
  - systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer || true
  - sysctl -w net.core.somaxconn=65535
  - sysctl -w net.ipv4.tcp_max_syn_backlog=65535
  - sysctl -w net.ipv4.ip_local_port_range="1024 65535"
  - sysctl -w net.ipv4.tcp_tw_reuse=1
  - sysctl -w fs.file-max=2097152
`

const sshKeyPrefix = "fourneau-dragrace-"

// commandRaceCloud races on fresh droplets: per class in race.json a server
// and its own loader, all in one region on its private network, the
// classes at the same time (each pair is its own two machines; racing them
// one after another would keep every droplet up three times as long). Every
// droplet and the run's SSH key are deleted when the race ends, however it
// ends; `dragrace reap` catches what a killed process could not.
func commandRaceCloud(ctx context.Context, root string, args []string) error {
	flags := parseRaceFlags("race cloud", root, args)
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	race = flags.narrow(race)
	do, err := newDigitalOcean()
	if err != nil {
		return err
	}
	// Before ten minutes of builds and any droplet: every size the race
	// needs must exist in its region (2026-10-06: nyc3 refused one only
	// after everything was built).
	watch := stopwatch{start: time.Now()}
	prices, err := checkSizes(ctx, do, race.Cloud)
	if err != nil {
		return err
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
	run, err := newRun(root, "cloud", race)
	if err != nil {
		return err
	}
	run.Timing.BuildSeconds = watch.since()
	launched := time.Now()
	fleet, err := launchFleet(ctx, do, race, run.ID)
	// Each class deletes its pair when it is done (raceFleet); this, the
	// rest, however the race ends.
	defer fleet.destroy(do)
	if err != nil {
		return err
	}
	run.Timing.LaunchSeconds = time.Since(launched).Seconds()
	raced := time.Now()
	if err := raceFleet(ctx, root, tools, race, competitors, fleet, do, &run); err != nil {
		return err
	}
	run.Timing.RacingSeconds = time.Since(raced).Seconds()
	// Before the results are saved, so they hold every droplet's life.
	fleet.destroy(do)
	run.Timing.Droplets = fleet.costs(prices)
	for _, droplet := range run.Timing.Droplets {
		run.Timing.CostUSD += droplet.CostUSD
	}
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

// Fleet is one race's droplets and key.
type Fleet struct {
	dir      string
	key      SSHKey
	private  string             // the key's private half, in dir
	loaders  map[string]Droplet // by class name
	servers  map[string]Droplet // by class name
	created  []int
	machines map[int]SSHMachine
	// Each droplet's life, for the race's timing and cost; guarded, as
	// classes release their pairs from their own goroutines.
	// Droplets each class's server took to get its CPU (pinServerCPU).
	serverAttempts map[string]int
	lives          map[int]*dropletLife
	mutex          sync.Mutex
	destroyed      bool
}

type dropletLife struct {
	role, class, size string
	created, deleted  time.Time
}

// releaseClass deletes one class's pair as soon as its racing is over:
// classes finish at different times, and a droplet waiting for the
// slowest class is paid for doing nothing.
func (fleet *Fleet) releaseClass(do Provider, class string) {
	for _, droplet := range []Droplet{fleet.loaders[class], fleet.servers[class]} {
		if droplet.ID != 0 {
			fleet.delete(do, droplet.ID)
		}
	}
}

// delete deletes one droplet, retrying, unless it is deleted already, and
// records when.
func (fleet *Fleet) delete(do Provider, id int) {
	fleet.mutex.Lock()
	life := fleet.lives[id]
	done := life != nil && !life.deleted.IsZero()
	fleet.mutex.Unlock()
	if done {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	for attempt := range 5 {
		err := do.deleteDroplet(ctx, id)
		if err == nil || strings.Contains(err.Error(), "404") {
			log.Printf("droplet %d deleted", id)
			break
		}
		log.Printf("deleting droplet %d (attempt %d): %v", id, attempt+1, err)
		time.Sleep(10 * time.Second)
	}
	fleet.mutex.Lock()
	if life != nil {
		life.deleted = time.Now()
	}
	fleet.mutex.Unlock()
}

// costs is every droplet's life and estimated cost, in the order created;
// one not deleted yet counts until now.
func (fleet *Fleet) costs(prices map[string]float64) []DropletCost {
	fleet.mutex.Lock()
	defer fleet.mutex.Unlock()
	costs := []DropletCost{}
	for _, id := range fleet.created {
		life := fleet.lives[id]
		if life == nil {
			continue
		}
		end := life.deleted
		if end.IsZero() {
			end = time.Now()
		}
		seconds := secondsBetween(life.created, end)
		costs = append(costs, DropletCost{Role: life.role, Class: life.class, Size: life.size,
			PriceHourly: prices[life.size], Seconds: seconds,
			CostUSD: dropletCost(prices[life.size], seconds)})
	}
	return costs
}

func launchFleet(ctx context.Context, do Provider, race Race, id string) (*Fleet, error) {
	fleet := &Fleet{loaders: map[string]Droplet{}, servers: map[string]Droplet{},
		machines: map[int]SSHMachine{}, lives: map[int]*dropletLife{},
		serverAttempts: map[string]int{}}
	var err error
	fleet.dir, err = os.MkdirTemp("", "dragrace-cloud-")
	if err != nil {
		return fleet, err
	}
	name := sshKeyPrefix + strconv.FormatInt(time.Now().Unix(), 10)
	private, public, err := newKeyPair(ctx, fleet.dir, name)
	if err != nil {
		return fleet, err
	}
	fleet.private = private
	fleet.key, err = do.createKey(ctx, name, public)
	if err != nil {
		return fleet, err
	}
	create := func(role, class, size string) (Droplet, error) {
		requested := time.Now()
		droplet, err := do.createDroplet(ctx, DropletRequest{
			Name:     "dragrace-" + role + "-" + class,
			Region:   race.Cloud.Region,
			Size:     size,
			Image:    race.Cloud.Image,
			SSHKeys:  []int{fleet.key.ID},
			Tags:     []string{race.Cloud.Tag},
			UserData: raceUserData,
		})
		if err == nil {
			fleet.created = append(fleet.created, droplet.ID)
			fleet.lives[droplet.ID] = &dropletLife{role: role, class: class, size: size,
				created: requested}
			log.Printf("droplet %d: %s (%s)", droplet.ID, role, size)
		}
		return droplet, err
	}
	for _, class := range race.Cloud.Servers {
		if fleet.loaders[class.Name], err = create("loader", class.Name, class.LoaderSize); err != nil {
			return fleet, err
		}
		if fleet.servers[class.Name], err = create("server", class.Name, class.Size); err != nil {
			return fleet, err
		}
	}
	// Active, answering SSH, and in the fleet's maps with its addresses.
	ready := func(id int) error {
		droplet, err := waitActive(ctx, do, id)
		if err != nil {
			return err
		}
		machine := SSHMachine{User: "root", Host: droplet.address("public"), Key: private,
			KnownHosts: filepath.Join(fleet.dir, "known_hosts")}
		if err := waitSSH(ctx, machine); err != nil {
			return err
		}
		fleet.machines[id] = machine
		for class, loader := range fleet.loaders {
			if loader.ID == id {
				fleet.loaders[class] = droplet
			}
		}
		for class, server := range fleet.servers {
			if server.ID == id {
				fleet.servers[class] = droplet
			}
		}
		return nil
	}
	for _, id := range append([]int(nil), fleet.created...) {
		if err := ready(id); err != nil {
			return fleet, err
		}
	}
	for _, class := range race.Cloud.Servers {
		if err := pinServerCPU(ctx, do, fleet, class, create, ready); err != nil {
			return fleet, err
		}
	}
	_ = id
	return fleet, nil
}

// serverCPUAttemptsMax bounds the droplets tried for one server's CPU:
// past it the race goes on, on the CPU it has, and the run says so.
const serverCPUAttemptsMax = 6

// pinServerCPU replaces a class's server until it has the CPU the class
// asks for (ServerCPU), at most serverCPUAttemptsMax droplets in all.
func pinServerCPU(ctx context.Context, do Provider, fleet *Fleet, class ServerClass,
	create func(role, class, size string) (Droplet, error), ready func(id int) error) error {
	fleet.serverAttempts[class.Name] = 1
	if class.ServerCPU == "" {
		return nil
	}
	for attempt := 1; attempt <= serverCPUAttemptsMax; attempt++ {
		fleet.serverAttempts[class.Name] = attempt
		droplet := fleet.servers[class.Name]
		machine := fleet.machines[droplet.ID]
		model, _ := machine.Shell(ctx, "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'")
		id := cpuID(ctx, machine)
		if cpuMatches(class.ServerCPU, model, id) {
			log.Printf("[%s] server on %s (%s), as asked, droplet %d of %d", class.Name, model, id,
				attempt, serverCPUAttemptsMax)
			return nil
		}
		if attempt == serverCPUAttemptsMax {
			log.Printf("[%s] server on %s (%s), not %s, after %d droplets: racing on it",
				class.Name, model, id, class.ServerCPU, attempt)
			return nil
		}
		log.Printf("[%s] server on %s (%s), not %s: another droplet", class.Name, model, id,
			class.ServerCPU)
		fleet.delete(do, droplet.ID)
		next, err := create("server", class.Name, class.Size)
		if err != nil {
			return err
		}
		fleet.servers[class.Name] = next
		if err := ready(next.ID); err != nil {
			return err
		}
	}
	return nil
}

// destroy deletes the droplets and the key, retrying, even after an
// interrupt: a droplet left running costs money every second.
// Called once a race is over, so its results hold every droplet's life,
// and again by a defer, for a race that ended early: the second does
// nothing.
func (fleet *Fleet) destroy(do Provider) {
	if fleet.destroyed {
		return
	}
	fleet.destroyed = true
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	for _, id := range fleet.created {
		fleet.delete(do, id)
	}
	if fleet.key.ID != 0 {
		if err := do.deleteKey(ctx, fleet.key.ID); err != nil {
			log.Printf("deleting key %d: %v (dragrace reap will)", fleet.key.ID, err)
		}
	}
	if fleet.dir != "" {
		os.RemoveAll(fleet.dir)
	}
}

// raceFleet races every class on its own pair at once. Each class races
// into its own Run (same seed), merged afterwards in race.json's order, so
// the results do not depend on which class finished first.
func raceFleet(ctx context.Context, root string, tools Toolchain, race Race,
	competitors []Competitor, fleet *Fleet, do Provider, run *Run) error {
	classes := race.Cloud.Servers
	parts := make([]Run, len(classes))
	errs := make([]error, len(classes))
	seconds := make([]float64, len(classes))
	var wait sync.WaitGroup
	for i, class := range classes {
		parts[i] = Run{Seed: run.Seed}
		wait.Add(1)
		go func() {
			defer wait.Done()
			started := time.Now()
			errs[i] = raceClass(ctx, root, tools, race, competitors, fleet, class, &parts[i])
			seconds[i] = time.Since(started).Seconds()
			// Done, however it went: its pair costs money from here on.
			fleet.releaseClass(do, class.Name)
			if errs[i] != nil {
				errs[i] = fmt.Errorf("%s: %w", class.Name, errs[i])
			}
		}()
	}
	wait.Wait()
	for i := range classes {
		run.Machines = append(run.Machines, parts[i].Machines...)
		run.Results = append(run.Results, parts[i].Results...)
		run.Timing.Classes = append(run.Timing.Classes,
			ClassTiming{Class: classes[i].Name, Seconds: seconds[i]})
	}
	return errors.Join(errs...)
}

func raceClass(ctx context.Context, root string, tools Toolchain, race Race,
	competitors []Competitor, fleet *Fleet, class ServerClass, run *Run) error {
	const home = "/root/dragrace"
	loader := fleet.machines[fleet.loaders[class.Name].ID]
	if err := loader.Put(ctx, tools.Oha, home+"/oha"); err != nil {
		return err
	}
	loaderInfo := machineInfo(ctx, loader, "loader", class.Name, class.LoaderSize)
	run.Machines = append(run.Machines, loaderInfo)
	droplet := fleet.servers[class.Name]
	server := fleet.machines[droplet.ID]
	for _, competitor := range competitors {
		binary := filepath.Join(binDir(root), competitor.Name)
		if err := server.Put(ctx, binary, home+"/bin/"+competitor.Name); err != nil {
			return err
		}
	}
	if _, err := server.Shell(ctx, "chmod +x "+home+"/bin/*"); err != nil {
		return err
	}
	if race.hasMixed() {
		if err := server.Put(ctx, conduitDatabase(root), home+"/"+conduitSeedName); err != nil {
			return err
		}
	}
	serverInfo := machineInfo(ctx, server, "server", class.Name, class.Size)
	serverInfo.CPUWanted = class.ServerCPU
	serverInfo.CPUMatched = cpuMatches(class.ServerCPU, serverInfo.CPU, serverInfo.CPUID)
	serverInfo.Attempts = fleet.serverAttempts[class.Name]
	run.Machines = append(run.Machines, serverInfo)
	target := Target{
		Class:         class,
		Server:        server,
		Loader:        loader,
		ServerHome:    home,
		LoaderHome:    home,
		Address:       droplet.address("private"),
		LoaderThreads: loaderInfo.CPUs,
	}
	return raceTarget(ctx, race, competitors, target, run)
}

// commandReap deletes race droplets older than race.json's max_age_minutes
// (or all of them, with -all) and this tool's SSH keys as old.
func commandReap(ctx context.Context, root string, args []string) error {
	flags := newFlags("reap")
	all := flags.Bool("all", false, "every race droplet, whatever its age")
	flags.Parse(args)
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	do, err := newDigitalOcean()
	if err != nil {
		return err
	}
	maxAge := time.Duration(race.Cloud.MaxAgeMinutes) * time.Minute
	droplets, err := do.dropletsTagged(ctx, race.Cloud.Tag)
	if err != nil {
		return err
	}
	for _, droplet := range droplets {
		if *all || time.Since(droplet.CreatedAt) > maxAge {
			log.Printf("reaping droplet %d %s (created %s)", droplet.ID, droplet.Name, droplet.CreatedAt)
			if err := do.deleteDroplet(ctx, droplet.ID); err != nil {
				return err
			}
		}
	}
	keys, err := do.keys(ctx)
	if err != nil {
		return err
	}
	for _, key := range keys {
		stamp, found := strings.CutPrefix(key.Name, sshKeyPrefix)
		seconds, parseErr := strconv.ParseInt(stamp, 10, 64)
		if !found || parseErr != nil {
			continue // not ours
		}
		if *all || time.Since(time.Unix(seconds, 0)) > maxAge {
			log.Printf("reaping key %d %s", key.ID, key.Name)
			if err := do.deleteKey(ctx, key.ID); err != nil {
				return err
			}
		}
	}
	return nil
}
