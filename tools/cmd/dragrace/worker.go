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

// A worker races one server class from its loader: the racer starts it on the loader droplet with the run's
// build unpacked as a checkout (race.json, competitors/, out/bin), and a
// config. It drives the server over the private network, and posts each
// result to the site as it grows, through a queue, so a site restarting
// never holds the race up. Every result is also kept in a file, which the
// racer posts again when the worker is done.

// WorkerConfig is what the racer writes for a worker.
type WorkerConfig struct {
	RunID string      `json:"run_id"`
	Class ServerClass `json:"class"`
	Seed  int64       `json:"seed"`
	Site  string      `json:"site"`
	Token string      `json:"token"`
	// The server's private address.
	ServerHost string `json:"server_host"`
	Key        string `json:"key"`
	KnownHosts string `json:"known_hosts"`
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
	if config.RunID == "" || config.Site == "" || config.Token == "" || config.ServerHost == "" ||
		config.Results == "" {
		return fmt.Errorf("%s: run_id, site, token, server_host and results are required", *path)
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
	// The plan before the machines are readied, no step begun: the site
	// says the class is readying. raceTarget plans the same, from the seed.
	poster.begin(planSteps(race, competitors, config.Seed), -1)
	loader := LocalMachine{}
	const home = "/root/dragrace"
	server := SSHMachine{User: "root", Host: config.ServerHost, Key: config.Key,
		KnownHosts: config.KnownHosts}
	target := Target{Class: config.Class, Server: server, Loader: loader, ServerHome: home,
		LoaderHome: home + "/loader", Address: config.ServerHost, Report: poster.send,
		Begin: poster.begin}
	// The racer reached the server, but its sshd can still reset a new
	// connection for a moment after (2026-10-16): wait, as the racer does.
	if err := waitSSH(ctx, server); err != nil {
		return err
	}
	for _, competitor := range competitors {
		binary := filepath.Join(binDir(root), competitor.Name)
		if err := server.Put(ctx, binary, home+"/bin/"+competitor.Name); err != nil {
			return err
		}
	}
	if _, err := server.Shell(ctx, "chmod +x "+home+"/bin/*"); err != nil {
		return err
	}
	if err := loader.Put(ctx, filepath.Join(binDir(root), "oha"), target.LoaderHome+"/oha"); err != nil {
		return err
	}
	if err := putConduitSeed(ctx, root, target); err != nil {
		return err
	}
	loaderInfo := machineInfo(ctx, loader, "loader", config.Class.Name, config.Class.LoaderSize)
	target.LoaderThreads = loaderInfo.CPUs
	serverInfo := machineInfo(ctx, server, "server", config.Class.Name, config.Class.Size)
	machines := []MachineInfo{loaderInfo, serverInfo}
	if err := site.post(ctx, "/api/runs/"+config.RunID+"/machines", machines, nil); err != nil {
		return err
	}
	// The black box only explains a failure: without it, the class races.
	target.BlackBox = filepath.Join(filepath.Dir(config.Results), "server.log")
	if stop, err := followServer(ctx, server, target.BlackBox); err != nil {
		log.Printf("the black box: %v; racing without it", err)
		target.BlackBox = ""
	} else {
		defer stop()
	}
	run := Run{ID: config.RunID, Seed: config.Seed, Race: race}
	return raceTarget(ctx, race, competitors, target, &run)
}

// Poster posts results in the background, the newest of each only, and
// keeps them all in the results file. It posts the step begun too, after
// the results before it: the live banner's (StepsPost).
type Poster struct {
	site    *SiteClient
	config  WorkerConfig
	mutex   sync.Mutex
	latest  map[string]Result // by class/workload/competitor
	pending map[string]bool
	step    *StepsPost // begun and not posted yet
	wake    chan struct{}
	done    chan struct{}
	closing bool
	err     error
}

// StepsPost is a class's plan and the step begun, 1 for the first (0:
// none yet).
type StepsPost struct {
	Step  int    `json:"step"`
	Steps []Step `json:"steps"`
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

// begin queues the step begun, replacing one not posted yet.
func (poster *Poster) begin(plan []Step, step int) {
	poster.mutex.Lock()
	poster.step = &StepsPost{Step: step + 1, Steps: plan}
	poster.mutex.Unlock()
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
		step := poster.step
		if key != "" {
			result = poster.latest[key]
			delete(poster.pending, key)
		} else {
			poster.step = nil
		}
		poster.mutex.Unlock()
		if key == "" && step != nil {
			// Only the banner's: a site without the route (one older than
			// this worker) or a failed post fails nothing.
			path := "/api/runs/" + poster.config.RunID + "/classes/" +
				url.PathEscape(poster.config.Class.Name) + "/steps"
			if err := poster.site.post(ctx, path, step, nil); err != nil {
				log.Printf("posting step %d: %v", step.Step, err)
			}
			continue
		}
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
