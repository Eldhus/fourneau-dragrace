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
	Class  string `json:"class"` // the server class; a loader's is the class it loads
	Size   string `json:"size"`
	CPU    string `json:"cpu"`
	CPUs   int    `json:"cpus"`
	Kernel string `json:"kernel"`
	// family:model:stepping, from /proc/cpuinfo: the CPU's generation
	// even where the model name is hidden ("DO-Regular").
	CPUID string `json:"cpu_id"`
	// MemTotal from /proc/meminfo, MiB: what the kernel has, a little under
	// the size's nominal memory.
	MemoryMiB int `json:"memory_mib"`
}

// Result is one competitor on one workload on one server class.
type Result struct {
	Class      string  `json:"class"`
	Workload   string  `json:"workload"`
	Competitor string  `json:"competitor"`
	Valid      bool    `json:"valid"`
	Note       string  `json:"note"` // always present: the site reads it as a field
	Rounds     []Round `json:"rounds"`
	// The rounds summarized (summarize), as the site's pages do: the best
	// round's rate, the rounds' median percentiles.
	BestRPS      float64 `json:"best_rps"`
	MedianP50Ms  float64 `json:"median_p50_ms"`
	MedianP95Ms  float64 `json:"median_p95_ms"`
	MedianP99Ms  float64 `json:"median_p99_ms"`
	MedianP999Ms float64 `json:"median_p999_ms"`
	// The open-loop ladder (open_loop.go), on the open-loop workload only.
	OpenLoop []OpenStep `json:"open_loop"`
}

// Round is one measured run.
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

// summarize, as the site's Data.Result: the rate is the
// best round's, as a benchmark takes the fastest of its repeats (a server
// can do no more than it did; a round short of it met noise). Each latency
// percentile is the rounds' median: a tail is the server's own rare stalls,
// so the least would report the round that missed them, the most the round
// a neighbour hit. A round that answered nothing has no latency.
func (result *Result) summarize() {
	if len(result.Rounds) == 0 {
		return
	}
	answered := []Round{}
	result.BestRPS = 0
	for _, round := range result.Rounds {
		result.BestRPS = math.Max(result.BestRPS, round.RPS)
		if round.RPS > 0 {
			answered = append(answered, round)
		}
	}
	if len(answered) == 0 {
		return
	}
	of := func(field func(Round) float64) float64 {
		values := make([]float64, len(answered))
		for i, round := range answered {
			values[i] = field(round)
		}
		return median(values)
	}
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
// a null where a list is due. It also summarizes each result.
func (run *Run) normalize() {
	for i := range run.Results {
		if run.Results[i].Rounds == nil {
			run.Results[i].Rounds = []Round{}
		}
		if run.Results[i].OpenLoop == nil {
			run.Results[i].OpenLoop = []OpenStep{}
		}
		run.Results[i].summarize()
	}
	run.Timing.normalize()
}
