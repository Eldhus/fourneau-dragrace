package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// The site (site/, a roux app) reads data/latest.json (the newest run,
// whole) and data/index.json (every run, summarized) on each request and
// renders them. publish files runs into a data directory: site/data here,
// the results branch in the nightly.
//
//	dragrace publish [-into DIR] RUN.json...
func commandPublish(root string, args []string) error {
	flags := newFlags("publish")
	into := flags.String("into", filepath.Join(root, "site", "data"), "the data directory")
	flags.Parse(args)
	runs := filepath.Join(*into, "runs")
	if err := os.MkdirAll(runs, 0o755); err != nil {
		return err
	}
	for _, path := range flags.Args() {
		var run Run
		if err := readJSON(path, &run); err != nil {
			return err
		}
		if run.ID == "" || len(run.Results) == 0 {
			return fmt.Errorf("%s: not a run", path)
		}
		if _, err := saveRun(runs, run); err != nil {
			return err
		}
	}
	current, err := loadRace(root)
	if err != nil {
		return err
	}
	return writeIndex(*into, current)
}

// IndexEntry is one run in data/index.json: enough to draw history.
type IndexEntry struct {
	ID          string        `json:"id"`
	Where       string        `json:"where"`
	StartedAt   string        `json:"started_at"`
	Fingerprint Fingerprint   `json:"fingerprint"`
	Results     []IndexResult `json:"results"`
}

type IndexResult struct {
	Class       string  `json:"class"`
	Workload    string  `json:"workload"`
	Competitor  string  `json:"competitor"`
	Valid       bool    `json:"valid"`
	MedianRPS   float64 `json:"median_rps"`
	MedianP99Ms float64 `json:"median_p99_ms"`
}

func writeIndex(dir string, current Race) error {
	runs, err := loadRuns(filepath.Join(dir, "runs"))
	if err != nil {
		return err
	}
	for i := range runs {
		runs[i].relabel(current)
	}
	index := make([]IndexEntry, 0, len(runs))
	for _, run := range runs {
		entry := IndexEntry{ID: run.ID, Where: run.Where, Fingerprint: run.Fingerprint,
			StartedAt: run.StartedAt.Format("2006-01-02T15:04:05Z")}
		for _, result := range run.Results {
			entry.Results = append(entry.Results, IndexResult{Class: result.Class,
				Workload: result.Workload, Competitor: result.Competitor, Valid: result.Valid,
				MedianRPS: result.MedianRPS, MedianP99Ms: result.MedianP99Ms})
		}
		index = append(index, entry)
	}
	if err := writeJSON(filepath.Join(dir, "index.json"), index); err != nil {
		return err
	}
	if len(runs) == 0 {
		return nil
	}
	latest := runs[len(runs)-1]
	latest.normalize()
	if err := writeJSON(filepath.Join(dir, "latest.json"), latest); err != nil {
		return err
	}
	return writeClasses(filepath.Join(dir, "classes"), runs)
}

// writeClasses writes classes/RUN/CLASS.json for every run: each server
// class's part alone, which is what the site links as a class's raw data.
// Rewritten whole each time, so a class file never outlives its run.
func writeClasses(dir string, runs []Run) error {
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	for _, run := range runs {
		for _, class := range run.classes() {
			part := run.forClass(class)
			part.normalize()
			if err := os.MkdirAll(filepath.Join(dir, run.ID), 0o755); err != nil {
				return err
			}
			if err := writeJSON(filepath.Join(dir, run.ID, class+".json"), part); err != nil {
				return err
			}
		}
	}
	return nil
}

func writeJSON(path string, value any) error {
	bytes, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	partial := path + ".partial"
	if err := os.WriteFile(partial, append(bytes, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(partial, path) // a reader never sees half a file
}

// relabel gives a run's server classes the current race.json's label and
// title, by name: presentation, not results, so a heading reworded today
// reads the same on every run. A class no longer raced keeps its title,
// and its name as its label.
func (run *Run) relabel(current Race) {
	for i := range run.Race.Cloud.Servers {
		class := &run.Race.Cloud.Servers[i]
		for _, now := range append(append([]ServerClass(nil), current.Cloud.Servers...), current.Cloud.Retired...) {
			if now.Name == class.Name {
				class.Label, class.Title = now.Label, now.Title
			}
		}
		if class.Label == "" {
			class.Label = class.Name
		}
	}
}
