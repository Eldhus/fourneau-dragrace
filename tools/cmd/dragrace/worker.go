package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// A worker races one server class from its loader (docs/self-hosting.md,
// "A run"): the racer starts it on the loader droplet with the run's
// build unpacked as a checkout (race.json, competitors/, out/bin), and a
// config. It drives the server over the private network, as raceClass
// does from afar, and posts each result to the site as it grows, through
// a queue, so a site restarting never holds the race up. Every result is
// also kept in a file, which the racer posts again when the worker is done.

// WorkerConfig is what the racer writes for a worker.
type WorkerConfig struct {
	RunID string      `json:"run_id"`
	Class ServerClass `json:"class"`
	Seed  int64       `json:"seed"`
	Site  string      `json:"site"`
	Token string      `json:"token"`
	// The server's private address; "" races on this machine (a test of
	// the worker: race.json's local CPUs).
	ServerHost string `json:"server_host"`
	Key        string `json:"key"`
	KnownHosts string `json:"known_hosts"`
	// Droplets the racer tried for the server's CPU (pinServerCPU).
	Attempts int `json:"attempts"`
	// Where every result is kept as raced, for the racer.
	Results string `json:"results"`
}

func commandWorker(ctx context.Context, root string, args []string) error {
	flags := newFlags("worker")
	path := flags.String("config", "worker.json", "the racer's config for this worker")
	flags.Parse(args)
	var config WorkerConfig
	if err := readJSON(*path, &config); err != nil {
		return err
	}
	if config.RunID == "" || config.Site == "" || config.Token == "" || config.Results == "" {
		return fmt.Errorf("%s: run_id, site, token and results are required", *path)
	}
	return runWorker(ctx, root, config)
}

func runWorker(ctx context.Context, root string, config WorkerConfig) error {
	site := newSiteClient(config.Site, config.Token)
	classPath := "/api/runs/" + config.RunID + "/classes/" + url.PathEscape(config.Class.Name)
	started := time.Now()
	if err := site.post(ctx, classPath, map[string]any{"status": "racing", "reason": "",
		"seconds": 0.0}, nil); err != nil {
		return err
	}
	poster := newPoster(ctx, site, config)
	raceErr := workerRace(ctx, root, config, site, poster)
	postErr := poster.close()
	status, reason := "done", ""
	if raceErr != nil {
		status, reason = "failed", raceErr.Error()
	} else if postErr != nil {
		status, reason = "failed", "results not all posted: "+postErr.Error()
	}
	// Past a cancel too: the site should hear how the class ended.
	end := context.WithoutCancel(ctx)
	if err := site.post(end, classPath, map[string]any{"status": status, "reason": reason,
		"seconds": time.Since(started).Seconds()}, nil); err != nil {
		log.Printf("the class's end: %v", err)
	}
	if raceErr != nil {
		return raceErr
	}
	return postErr
}

func workerRace(ctx context.Context, root string, config WorkerConfig, site *SiteClient,
	poster *Poster) error {
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	competitors, err := loadCompetitors(root, race.Competitors)
	if err != nil {
		return err
	}
	loader := LocalMachine{}
	const home = "/root/dragrace"
	target := Target{Class: config.Class, Loader: loader, Report: poster.send}
	var server Machine = loader
	if config.ServerHost == "" {
		target.ServerHome, target.LoaderHome = outDir(root), filepath.Join(outDir(root), "loader")
		target.Address = "127.0.0.1"
		target.ServerCPUs, target.LoaderCPUs = race.Local.ServerCPUs, race.Local.LoaderCPUs
		target.LoaderThreads = len(cpuSet(race.Local.LoaderCPUs))
	} else {
		server = SSHMachine{User: "root", Host: config.ServerHost, Key: config.Key,
			KnownHosts: config.KnownHosts}
		target.ServerHome, target.LoaderHome = home, home+"/loader"
		target.Address = config.ServerHost
		for _, competitor := range competitors {
			binary := filepath.Join(binDir(root), competitor.Name)
			if err := server.Put(ctx, binary, home+"/bin/"+competitor.Name); err != nil {
				return err
			}
		}
		if _, err := server.Shell(ctx, "chmod +x "+home+"/bin/*"); err != nil {
			return err
		}
	}
	target.Server = server
	if err := loader.Put(ctx, filepath.Join(binDir(root), "oha"), target.LoaderHome+"/oha"); err != nil {
		return err
	}
	if err := putConduitSeed(ctx, root, race, target); err != nil {
		return err
	}
	loaderInfo := machineInfo(ctx, loader, "loader", config.Class.Name, config.Class.LoaderSize)
	if config.ServerHost != "" {
		target.LoaderThreads = loaderInfo.CPUs
	}
	serverInfo := machineInfo(ctx, server, "server", config.Class.Name, config.Class.Size)
	serverInfo.CPUWanted = config.Class.ServerCPU
	serverInfo.CPUMatched = cpuMatches(config.Class.ServerCPU, serverInfo.CPU, serverInfo.CPUID)
	serverInfo.Attempts = max(config.Attempts, 1)
	machines := []MachineInfo{loaderInfo, serverInfo}
	if err := site.post(ctx, "/api/runs/"+config.RunID+"/machines", machines, nil); err != nil {
		return err
	}
	run := Run{ID: config.RunID, Seed: config.Seed, Race: race}
	return raceTarget(ctx, race, competitors, target, &run)
}

// Poster posts results in the background, the newest of each only, and
// keeps them all in the results file.
type Poster struct {
	site    *SiteClient
	config  WorkerConfig
	mutex   sync.Mutex
	latest  map[string]Result // by class/workload/competitor
	pending map[string]bool
	wake    chan struct{}
	done    chan struct{}
	closing bool
	err     error
}

func newPoster(ctx context.Context, site *SiteClient, config WorkerConfig) *Poster {
	poster := &Poster{site: site, config: config, latest: map[string]Result{},
		pending: map[string]bool{}, wake: make(chan struct{}, 1), done: make(chan struct{})}
	go poster.loop(ctx)
	return poster
}

func resultKey(result Result) string {
	return result.Class + "/" + result.Workload + "/" + result.Competitor
}

// send queues a result (a copy: the race goes on changing its own).
func (poster *Poster) send(result Result) {
	result = normalizedResult(result)
	poster.mutex.Lock()
	key := resultKey(result)
	poster.latest[key] = result
	poster.pending[key] = true
	all := make([]Result, 0, len(poster.latest))
	for _, kept := range poster.latest {
		all = append(all, kept)
	}
	poster.mutex.Unlock()
	if err := writeResults(poster.config.Results, all); err != nil {
		log.Printf("keeping results: %v", err)
	}
	select {
	case poster.wake <- struct{}{}:
	default:
	}
}

// normalizedResult is a copy with lists empty, never null (the site's
// JSON parser refuses null for a list), and its medians taken.
func normalizedResult(result Result) Result {
	result.Rounds = append([]Round{}, result.Rounds...)
	result.OpenLoop = append([]OpenStep{}, result.OpenLoop...)
	for i := range result.OpenLoop {
		result.OpenLoop[i].Parts = append([]OpenPart{}, result.OpenLoop[i].Parts...)
	}
	result.summarize()
	return result
}

func writeResults(path string, results []Result) error {
	bytes, err := json.MarshalIndent(results, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".new"
	if err := os.WriteFile(temporary, bytes, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

func (poster *Poster) loop(ctx context.Context) {
	defer close(poster.done)
	for {
		poster.mutex.Lock()
		var key string
		for pending := range poster.pending {
			key = pending
			break
		}
		closing := poster.closing
		var result Result
		if key != "" {
			result = poster.latest[key]
			delete(poster.pending, key)
		}
		poster.mutex.Unlock()
		if key == "" {
			if closing {
				return
			}
			select {
			case <-poster.wake:
			case <-ctx.Done():
				return
			}
			continue
		}
		err := poster.site.post(ctx, "/api/runs/"+poster.config.RunID+"/results", result, nil)
		if err != nil {
			log.Printf("posting %s: %v (the racer posts it again from the file)", key, err)
			poster.mutex.Lock()
			poster.err = err
			poster.mutex.Unlock()
		}
	}
}

// close waits for the queue to empty; it says the last post that failed.
func (poster *Poster) close() error {
	poster.mutex.Lock()
	poster.closing = true
	poster.mutex.Unlock()
	select {
	case poster.wake <- struct{}{}:
	default:
	}
	<-poster.done
	poster.mutex.Lock()
	defer poster.mutex.Unlock()
	return poster.err
}
