package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"time"
)

// Run is one race's results file: everything needed to read it later
// without this repository at that commit.
type Run struct {
	ID          string        `json:"id"`
	Where       string        `json:"where"` // "cloud" or "local"
	StartedAt   time.Time     `json:"started_at"`
	FinishedAt  time.Time     `json:"finished_at"`
	Seed        int64         `json:"seed"`
	Fingerprint Fingerprint   `json:"fingerprint"`
	Versions    Versions      `json:"versions"`
	Race        Race          `json:"race"`
	Machines    []MachineInfo `json:"machines"`
	Results     []Result      `json:"results"`
	Timing      Timing        `json:"timing"`
}

type MachineInfo struct {
	Role   string `json:"role"`  // "server" or "loader"
	Class  string `json:"class"` // the server class ("loader" before 2026-10-06: one loader for all)
	Size   string `json:"size"`
	CPU    string `json:"cpu"`
	CPUs   int    `json:"cpus"`
	Kernel string `json:"kernel"`
	// family:model:stepping, from /proc/cpuinfo: the CPU's generation
	// even where the model name is hidden ("DO-Regular").
	CPUID string `json:"cpu_id"`
}

// Result is one competitor on one workload on one server class.
type Result struct {
	Class      string  `json:"class"`
	Workload   string  `json:"workload"`
	Competitor string  `json:"competitor"`
	Valid      bool    `json:"valid"`
	Note       string  `json:"note"` // always present: the site reads it as a field
	Rounds     []Round `json:"rounds"`
	// The medians of the rounds (summarize). A run published before a
	// percentile was recorded shows it as 0.
	MedianRPS    float64 `json:"median_rps"`
	MedianP50Ms  float64 `json:"median_p50_ms"`
	MedianP95Ms  float64 `json:"median_p95_ms"`
	MedianP99Ms  float64 `json:"median_p99_ms"`
	MedianP999Ms float64 `json:"median_p999_ms"`
	// The open-loop ladder (open_loop.go), on the open-loop workload only.
	OpenLoop []OpenStep `json:"open_loop"`
}

// Round is one measured run. The fields after rss_kib were added on
// 2026-10-06 and are 0 in older runs.
type Round struct {
	RPS         float64 `json:"rps"`
	P50Ms       float64 `json:"p50_ms"`
	P99Ms       float64 `json:"p99_ms"`
	P999Ms      float64 `json:"p999_ms"`
	SuccessRate float64 `json:"success_rate"`
	Errors      int     `json:"errors"`
	Non2xx      int     `json:"non_2xx"`
	CPUBusyPct  float64 `json:"cpu_busy_pct"`
	StealPct    float64 `json:"steal_pct"`
	RSSKiB      int     `json:"rss_kib"`

	// Latency, from oha: the tail beyond p99.9, and the mean and worst.
	P90Ms   float64 `json:"p90_ms"`
	P95Ms   float64 `json:"p95_ms"`
	P9999Ms float64 `json:"p9999_ms"`
	MeanMs  float64 `json:"mean_ms"`
	MaxMs   float64 `json:"max_ms"`
	// Time to the response's first byte: for a stream (sse), when the
	// client starts seeing events, apart from when the stream ends.
	FirstByteP50Ms float64 `json:"first_byte_p50_ms"`
	FirstByteP99Ms float64 `json:"first_byte_p99_ms"`
	// Throughput second by second, its spread: a stall widens it where the
	// mean hides it. (Not its minimum: the run's last second is partial.)
	RPSPerSecondStddev float64 `json:"rps_per_second_stddev"`
	// The mean time to open a connection (churn opens one per request).
	ConnectMeanMs    float64 `json:"connect_mean_ms"`
	BytesPerResponse float64 `json:"bytes_per_response"`
	// Where the server machine's CPUs went (busy is the sum but steal),
	// and the loader's: a busy loader means the server was not the limit.
	CPUUserPct       float64 `json:"cpu_user_pct"`
	CPUSystemPct     float64 `json:"cpu_system_pct"`
	CPUIrqPct        float64 `json:"cpu_irq_pct"`
	CPUSoftirqPct    float64 `json:"cpu_softirq_pct"`
	LoaderCPUBusyPct float64 `json:"loader_cpu_busy_pct"`
	// The server machine's network, both ways, and TCP's retransmits: a
	// result at the droplet's link, not the server's limit, shows here.
	NetRxMbps   float64 `json:"net_rx_mbps"`
	NetTxMbps   float64 `json:"net_tx_mbps"`
	NetRxPPS    float64 `json:"net_rx_pps"`
	NetTxPPS    float64 `json:"net_tx_pps"`
	Retransmits int64   `json:"tcp_retransmits"`
	// The server process at the end, and its context switches during.
	Threads             int64 `json:"threads"`
	VoluntarySwitches   int64 `json:"voluntary_switches"`
	InvoluntarySwitches int64 `json:"involuntary_switches"`
	// How long oha ran (its own count): the rates above are over this.
	LoadSeconds float64 `json:"load_seconds"`
	// How long the measured run took on the server's clock.
	Seconds float64 `json:"seconds"`
}

// summarize fills the medians: the middle round, so one noisy round of
// three moves nothing.
func (result *Result) summarize() {
	if len(result.Rounds) == 0 {
		return
	}
	of := func(field func(Round) float64) float64 {
		values := make([]float64, len(result.Rounds))
		for i, round := range result.Rounds {
			values[i] = field(round)
		}
		return median(values)
	}
	result.MedianRPS = of(func(round Round) float64 { return round.RPS })
	result.MedianP50Ms = of(func(round Round) float64 { return round.P50Ms })
	result.MedianP95Ms = of(func(round Round) float64 { return round.P95Ms })
	result.MedianP99Ms = of(func(round Round) float64 { return round.P99Ms })
	result.MedianP999Ms = of(func(round Round) float64 { return round.P999Ms })
}

func median(values []float64) float64 {
	sorted := slices.Clone(values)
	sort.Float64s(sorted)
	middle := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[middle]
	}
	return (sorted[middle-1] + sorted[middle]) / 2
}

func saveRun(dir string, run Run) (string, error) {
	run.normalize()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	bytes, err := json.MarshalIndent(run, "", "  ")
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, run.ID+".json")
	if err := os.WriteFile(path, bytes, 0o644); err != nil {
		return "", err
	}
	return path, nil
}

func runID(where string, started time.Time) string {
	return fmt.Sprintf("%s-%s", started.UTC().Format("2006-01-02T150405Z"), where)
}

// normalize writes "no rounds" as an empty list, not null: Go marshals a
// nil slice as null, and the site (Roc's Json.parse into a List) refuses
// a null where a list is due. Applied to every run saved or published, so
// runs stored with null are mended when the site is next published. The
// medians are taken again from the rounds, so a run stored before a median
// was recorded (p95, p99.9: 2026-10-06) has it, from rounds that have it.
func (run *Run) normalize() {
	for i := range run.Results {
		if run.Results[i].Rounds == nil {
			run.Results[i].Rounds = []Round{}
		}
		if run.Results[i].OpenLoop == nil {
			run.Results[i].OpenLoop = []OpenStep{}
		}
		for j := range run.Results[i].Rounds {
			run.Results[i].Rounds[j].correctWindow(run.Race.MeasureSeconds)
		}
		run.Results[i].summarize()
	}
	run.Timing.normalize()
}

// correctWindow mends a round measured before its rates were taken over
// the load's duration (2026-10-06, the first races to record the network
// and the loader): its window held the shell calls around the load too,
// about 26 s for 20 s of load, so its shares and rates read low. The load
// lasted the race's measuring time; the round is marked with it, so it is
// mended once.
func (round *Round) correctWindow(measureSeconds int) {
	if round.LoadSeconds > 0 || round.Seconds <= 0 || measureSeconds <= 0 {
		return
	}
	load := float64(measureSeconds)
	cost := ServerCost{Seconds: round.Seconds, NetRxMbps: round.NetRxMbps,
		NetTxMbps: round.NetTxMbps, NetRxPPS: round.NetRxPPS, NetTxPPS: round.NetTxPPS,
		CPU: CPUShares{Busy: round.CPUBusyPct, User: round.CPUUserPct,
			System: round.CPUSystemPct, Irq: round.CPUIrqPct, Softirq: round.CPUSoftirqPct,
			Steal: round.StealPct}}.over(load)
	round.CPUBusyPct, round.StealPct = cost.CPU.Busy, cost.CPU.Steal
	round.CPUUserPct, round.CPUSystemPct = cost.CPU.User, cost.CPU.System
	round.CPUIrqPct, round.CPUSoftirqPct = cost.CPU.Irq, cost.CPU.Softirq
	round.NetRxMbps, round.NetTxMbps = cost.NetRxMbps, cost.NetTxMbps
	round.NetRxPPS, round.NetTxPPS = cost.NetRxPPS, cost.NetTxPPS
	// The loader's window was much the same length.
	round.LoaderCPUBusyPct = math.Min(100, round.LoaderCPUBusyPct*round.Seconds/load)
	round.LoadSeconds = load
}
