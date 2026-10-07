package main

import (
	"context"
	"fmt"
	"log"
	"math"
	"net"
)

// The open-loop test (the owner, 2026-10-06: tail latency and saturation).
//
// The race's rounds are a closed loop: oha keeps N requests in flight, and
// each connection's next request waits for its answer, so a server that
// stalls is sent less, and its stall never shows in the percentiles
// (coordinated omission). Real users arrive whatever the server does. So,
// after the rounds, one workload again at fixed offered rates: a ladder of
// steps, each a share of the server's own closed-loop median (half, three
// quarters, ..., and past it), held long enough to settle, with latency
// counted from when each request was due (oha -q, --latency-correction).
// Steps rather than a continuous ramp: a ramp never holds a rate long
// enough for its percentiles to mean that rate. Relative steps sample
// every server around its own knee; the site plots them on an absolute
// axis, so a slow server's comfortable half is not mistaken for speed.

// OpenStep is one rate of the ladder.
type OpenStep struct {
	// The share of the closed-loop median this step offered, and the rate.
	Share      float64 `json:"share"`
	OfferedRPS float64 `json:"offered_rps"`
	// Good (2xx) answers a second: below the offered rate, the server (or
	// the loader: its CPU says which) could not keep up.
	AchievedRPS float64 `json:"achieved_rps"`
	// Latency from when each request was due, not when it was sent.
	P50Ms            float64 `json:"p50_ms"`
	P90Ms            float64 `json:"p90_ms"`
	P99Ms            float64 `json:"p99_ms"`
	P999Ms           float64 `json:"p999_ms"`
	Errors           int     `json:"errors"`
	Non2xx           int     `json:"non_2xx"`
	CPUBusyPct       float64 `json:"cpu_busy_pct"`
	LoaderCPUBusyPct float64 `json:"loader_cpu_busy_pct"`
	NetRxMbps        float64 `json:"net_rx_mbps"`
	NetTxMbps        float64 `json:"net_tx_mbps"`
	// A mixed workload's step: the mean over every request, and each part
	// (mixed.go). Empty on a ladder of one workload.
	MeanMs float64    `json:"mean_ms"`
	Parts  []OpenPart `json:"parts"`
}

// openLoop climbs the ladder for every valid competitor, after the rounds,
// in a seeded order of its own.
func openLoop(ctx context.Context, race Race, competitors []Competitor, target Target,
	bodies map[int]string, valid map[string]string, run *Run) error {
	workload, found := workloadNamed(race, race.OpenLoop.Workload)
	if !found {
		// Narrowed away (-workloads); race.json itself is checked on load.
		return nil
	}
	for _, competitor := range shuffled(competitors, run.Seed+int64(race.Rounds)+1) {
		if valid[competitor.Name] != "" {
			continue
		}
		result := resultFor(run, target.Class.Name, workload.Name, competitor.Name)
		if result.MedianRPS <= 0 {
			continue
		}
		log.Printf("[%s] open loop: %s", target.Class.Name, competitor.Name)
		steps, err := climb(ctx, race, workload, competitor, target, bodies, result.MedianRPS)
		if err != nil {
			return fmt.Errorf("%s open loop: %w", competitor.Name, err)
		}
		result.OpenLoop = steps
		target.report(*result)
	}
	return nil
}

func climb(ctx context.Context, race Race, workload Workload, competitor Competitor,
	target Target, bodies map[int]string, median float64) ([]OpenStep, error) {
	pid, err := startServer(ctx, race, competitor, target)
	if err != nil {
		return nil, err
	}
	defer stopServer(context.WithoutCancel(ctx), target, pid)
	if err := waitReady(ctx, race, target); err != nil {
		return nil, fmt.Errorf("did not start")
	}
	local := net.ParseIP(target.Address).IsLoopback()
	steps := []OpenStep{}
	for _, share := range race.OpenLoop.Shares {
		rate := int(math.Round(share * median))
		if rate < 1 {
			continue
		}
		warm := LoadShape{Seconds: race.OpenLoop.WarmupSeconds, Rate: rate}
		if _, err := target.Loader.Shell(ctx, ohaCommand(race, workload, target, bodies, warm)); err != nil {
			return nil, fmt.Errorf("warmup at %d/s: %w", rate, err)
		}
		serverBefore, loaderBefore, err := snapshots(ctx, target, pid, true)
		if err != nil {
			return nil, err
		}
		shape := LoadShape{Seconds: race.OpenLoop.MeasureSeconds, Rate: rate}
		report, err := target.Loader.Shell(ctx, ohaCommand(race, workload, target, bodies, shape))
		if err != nil {
			return nil, fmt.Errorf("oha at %d/s: %w", rate, err)
		}
		serverAfter, loaderAfter, err := snapshots(ctx, target, pid, false)
		if err != nil {
			return nil, err
		}
		round, err := parseOha(report)
		if err != nil {
			return nil, err
		}
		cost := serverCost(serverBefore, serverAfter, target.ServerCPUs, local).over(round.LoadSeconds)
		step := OpenStep{Share: share, OfferedRPS: float64(rate), AchievedRPS: round.RPS,
			P50Ms: round.P50Ms, P90Ms: round.P90Ms, P99Ms: round.P99Ms, P999Ms: round.P999Ms,
			Errors: round.Errors, Non2xx: round.Non2xx, CPUBusyPct: cost.CPU.Busy,
			LoaderCPUBusyPct: loaderBusy(loaderBefore, loaderAfter, target.LoaderCPUs, round.LoadSeconds),
			NetRxMbps:        cost.NetRxMbps, NetTxMbps: cost.NetTxMbps}
		log.Printf("    %3.0f%%  %8d/s offered  %8.0f/s good  p99 %.2f ms  p99.9 %.2f ms",
			share*100, rate, step.AchievedRPS, step.P99Ms, step.P999Ms)
		steps = append(steps, step)
	}
	return steps, nil
}

func workloadNamed(race Race, name string) (Workload, bool) {
	for _, workload := range race.Workloads {
		if workload.Name == name {
			return workload, true
		}
	}
	return Workload{}, false
}
