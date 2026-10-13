package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// raceUserData prepares a race droplet: root's login by the run's own key
// (public, made where the race is driven), no password login, nothing else
// running (no apt timers), and the network limits a load test needs, the
// same on every droplet. The key is cloud-init's to install, so
// DigitalOcean never has it: nothing to register before a race or delete
// after (DigitalOcean's own ssh_keys name only the owner's admin key).
func raceUserData(public string) string {
	keys, _ := json.Marshal([]string{public}) // a JSON list is a YAML flow sequence
	return `#cloud-config
disable_root: false
ssh_pwauth: false
ssh_authorized_keys: ` + string(keys) + `
runcmd:
  - systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer snapd || true
  - systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer || true
  - sysctl -w net.core.somaxconn=65535
  - sysctl -w net.ipv4.tcp_max_syn_backlog=65535
  - sysctl -w net.ipv4.ip_local_port_range="1024 65535"
  - sysctl -w net.ipv4.tcp_tw_reuse=1
  - sysctl -w fs.file-max=2097152
`
}

// Fleet is one race's droplets and key: per class in race.json a server
// and its own loader, all in one region on its private network (the
// racer's raceCloud).
type Fleet struct {
	dir      string
	private  string             // the run's key's private half, in dir
	loaders  map[string]Droplet // by class name
	servers  map[string]Droplet // by class name
	created  []int
	machines map[int]SSHMachine
	// Each droplet's life, for the race's timing and cost; guarded, as
	// classes release their pairs from their own goroutines.
	lives     map[int]*dropletLife
	mutex     sync.Mutex
	destroyed bool
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

func launchFleet(ctx context.Context, do Provider, race Race) (*Fleet, error) {
	fleet := &Fleet{loaders: map[string]Droplet{}, servers: map[string]Droplet{},
		machines: map[int]SSHMachine{}, lives: map[int]*dropletLife{}}
	var err error
	fleet.dir, err = os.MkdirTemp("", "dragrace-cloud-")
	if err != nil {
		return fleet, err
	}
	private, public, err := newKeyPair(ctx, fleet.dir, "dragrace-race")
	if err != nil {
		return fleet, err
	}
	fleet.private = private
	create := func(role, class, size string) (Droplet, error) {
		requested := time.Now()
		droplet, err := do.createDroplet(ctx, DropletRequest{
			Name:   "dragrace-" + role + "-" + class,
			Region: race.Cloud.Region,
			Size:   size,
			Image:  race.Cloud.Image,
			// None: the guard names the admin key.
			SSHKeys:  []int{},
			Tags:     []string{race.Cloud.Tag},
			UserData: raceUserData(public),
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
	return fleet, nil
}

// destroy deletes the droplets, retrying, even after an interrupt (a
// droplet left running costs money every second), then the run's key
// pair's directory.
// Called once a race is over, so its results hold every droplet's life,
// and again by a defer, for a race that ended early: the second does
// nothing.
func (fleet *Fleet) destroy(do Provider) {
	if fleet.destroyed {
		return
	}
	fleet.destroyed = true
	for _, id := range fleet.created {
		fleet.delete(do, id)
	}
	if fleet.dir != "" {
		os.RemoveAll(fleet.dir)
	}
}
