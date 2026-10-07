package main

import (
	"math"
	"time"
)

// How long a race took and what its droplets cost, kept with its results
// (the owner, 2026-10-06: track how long races take, without paying for
// idle droplets). A local race has the stages and no droplets.

type Timing struct {
	// The whole race, from the command's start to its results.
	Seconds float64 `json:"seconds"`
	// Building every competitor (the toolchain fetched, if it was not).
	BuildSeconds float64 `json:"build_seconds"`
	// From the first droplet requested to the last answering SSH.
	LaunchSeconds float64 `json:"launch_seconds"`
	// Racing: every class, at once.
	RacingSeconds float64       `json:"racing_seconds"`
	Classes       []ClassTiming `json:"classes"`
	Droplets      []DropletCost `json:"droplets"`
	// The droplets' estimated cost (DropletCost), in US dollars.
	CostUSD float64 `json:"cost_usd"`
}

type ClassTiming struct {
	Class   string  `json:"class"`
	Seconds float64 `json:"seconds"`
}

// DropletCost is one droplet's life: requested to deleted. DigitalOcean
// bills a droplet per second from creation to deletion, at least a minute
// (its pricing page); the estimate uses the size's listed hourly price.
type DropletCost struct {
	Role        string  `json:"role"`
	Class       string  `json:"class"`
	Size        string  `json:"size"`
	PriceHourly float64 `json:"price_hourly"`
	Seconds     float64 `json:"seconds"`
	CostUSD     float64 `json:"cost_usd"`
}

// dropletBilledSecondsMin is the least a droplet is billed for.
const dropletBilledSecondsMin = 60

func dropletCost(priceHourly, seconds float64) float64 {
	billed := math.Max(seconds, dropletBilledSecondsMin)
	return priceHourly * billed / 3600
}

// stopwatch measures the stages of one race.
type stopwatch struct{ start time.Time }

func (watch stopwatch) since() float64 { return time.Since(watch.start).Seconds() }

func secondsBetween(from, to time.Time) float64 { return to.Sub(from).Seconds() }

// normalize writes the lists as empty, never null, as Run.normalize does.
func (timing *Timing) normalize() {
	if timing.Classes == nil {
		timing.Classes = []ClassTiming{}
	}
	if timing.Droplets == nil {
		timing.Droplets = []DropletCost{}
	}
}
