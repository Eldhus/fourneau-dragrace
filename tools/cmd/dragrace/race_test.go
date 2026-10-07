package main

import (
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"testing"
)

func TestCanonicalEntities(t *testing.T) {
	askama := "<td>Fish &#38; chips &#60;b&#62;</td>"
	reference := "<td>Fish &amp; chips &lt;b&gt;</td>"
	if canonicalEntities(askama) != canonicalEntities(reference) {
		t.Fatalf("equivalent escaping should match")
	}
	unescaped := "<td>Fish & chips <b></td>"
	if canonicalEntities(unescaped) == canonicalEntities(reference) {
		t.Fatalf("an unescaped page must not match")
	}
}

// The site (Roc's Json.parse into records) refuses a missing field and a
// null list: a result with no rounds and no note is written with both, as
// an empty list and an empty string.
func TestResultWritesEveryField(t *testing.T) {
	run := Run{Results: []Result{{Competitor: "a"}}}
	run.normalize()
	bytes, err := json.Marshal(run.Results[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"rounds":[]`, `"note":""`} {
		if !strings.Contains(string(bytes), field) {
			t.Fatalf("%s: no %s", bytes, field)
		}
	}
}

// Every environment line of the site's unit is NAME=value with the
// values filled in, none left as a placeholder.
func TestSiteUnitEnvironment(t *testing.T) {
	directory := "https://acme.example/directory"
	service := siteUnits("192.0.2.1", directory)["/etc/systemd/system/dragrace-site.service"]
	for _, want := range []string{
		"Environment=ROUX_ACME_DIRECTORY=" + directory + "\n",
		"Environment=ROUX_ACME_IDENTIFIER=192.0.2.1\n",
		"WorkingDirectory=" + siteState + "\n",
		"ExecStart=" + siteHome + "/current/dragrace-site\n",
		"ConditionPathExists=" + siteHome + "/current/dragrace-site\n",
	} {
		if !strings.Contains(service, want) {
			t.Fatalf("no %q in:\n%s", want, service)
		}
	}
	if strings.Contains(service, "{") {
		t.Fatalf("a placeholder left in:\n%s", service)
	}
}

func TestCheckStream(t *testing.T) {
	reference := "event: a\ndata: x\n\nevent: b\ndata: y\n\n"
	head := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
	good := head + "12\r\nevent: a\ndata: x\n\n\r\n12\r\nevent: b\ndata: y\n\n\r\n0\r\n\r\n"
	if why := checkStream(good, reference); why != "" {
		t.Fatalf("a chunk per event: %s", why)
	}
	cases := map[string]string{
		"one chunk for both": head + "24\r\n" + reference + "\r\n0\r\n\r\n",
		"a whole body": "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" +
			"Content-Length: 36\r\n\r\n" + reference,
		"the wrong type": strings.Replace(good, "text/event-stream", "text/plain", 1),
		"no last chunk":  strings.TrimSuffix(good, "0\r\n\r\n"),
		"a wrong event":  strings.Replace(good, "data: y", "data: z", 1),
		"a 404":          strings.Replace(good, "200 OK", "404 Not Found", 1),
		"a trailer":      strings.TrimSuffix(good, "\r\n") + "X-T: 1\r\n\r\n",
		"an extra event": strings.Replace(good, "0\r\n\r\n", "2\r\n\n\n\r\n0\r\n\r\n", 1),
	}
	for name, raw := range cases {
		if checkStream(raw, reference) == "" {
			t.Errorf("%s: passed the check", name)
		}
	}
}

func TestSplitEvents(t *testing.T) {
	got := splitEvents("a\n\nb\nc\n\n")
	if !slices.Equal(got, []string{"a\n\n", "b\nc\n\n"}) {
		t.Fatalf("got %q", got)
	}
}

// A server that died: every request an error, no status codes at all.
// oha still reports a rate; none of it is work done.
func TestParseOhaCountsGoodAnswersOnly(t *testing.T) {
	dead := `{"summary":{"successRate":0,"requestsPerSec":121539},
		"statusCodeDistribution":{},"errorDistribution":{"connection refused":364708}}`
	round, err := parseOha(dead)
	if err != nil || round.RPS != 0 {
		t.Fatalf("a dead server raced at %v req/s (%v)", round.RPS, err)
	}
	half := `{"summary":{"successRate":0.5,"requestsPerSec":1000},
		"statusCodeDistribution":{"200":400,"503":100},"errorDistribution":{"reset":500}}`
	round, err = parseOha(half)
	if err != nil || round.RPS != 400 {
		t.Fatalf("400 good of 1,000 at 1,000 req/s is 400 req/s, not %v (%v)", round.RPS, err)
	}
}

const snapshotBefore = `@@ clock
1000000000
@@ stat
cpu  100 0 50 1000 0 0 10 0 0 0
cpu0 50 0 25 500 0 0 5 0 0 0
cpu1 50 0 25 500 0 0 5 0 0 0
intr 1
@@ net
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:  500 5 0 0 0 0 0 0  500 5 0 0 0 0 0 0
  eth1: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0
@@ snmp
Ip: Forwarding DefaultTTL
Ip: 1 64
Tcp: RtoAlgorithm RtoMin RetransSegs InErrs
Tcp: 1 200 7 0
@@ status
Name:	go
Threads:	9
voluntary_ctxt_switches:	100
nonvoluntary_ctxt_switches:	10`

// Two seconds later: cpu1 spent 40 jiffies on user, 10 system, 30
// softirq, 20 idle; eth1 took in 250 MB and sent 500 MB; 3 retransmits.
const snapshotAfter = `@@ clock
3000000000
@@ stat
cpu  140 0 60 1020 0 0 40 0 0 0
cpu0 50 0 25 500 0 0 5 0 0 0
cpu1 90 0 35 520 0 0 35 0 0 0
@@ net
    lo:  900 9 0 0 0 0 0 0  900 9 0 0 0 0 0 0
  eth1: 250001000 1010 0 0 0 0 0 0 500002000 2020 0 0 0 0 0 0
@@ snmp
Tcp: RtoAlgorithm RtoMin RetransSegs InErrs
Tcp: 1 200 10 0
@@ status
Threads:	11
voluntary_ctxt_switches:	150
nonvoluntary_ctxt_switches:	13`

func TestServerCost(t *testing.T) {
	before, err := parseSnapshot(snapshotBefore)
	if err != nil {
		t.Fatal(err)
	}
	after, err := parseSnapshot(snapshotAfter)
	if err != nil {
		t.Fatal(err)
	}
	cost := serverCost(before, after, "1", false)
	want := ServerCost{
		Seconds:   2,
		CPU:       CPUShares{Busy: 80, User: 40, System: 10, Softirq: 30},
		NetRxMbps: 1000, NetTxMbps: 2000, NetRxPPS: 500, NetTxPPS: 1000, Retransmits: 3,
		Threads: 11, VoluntarySwitches: 50, InvoluntarySwitches: 3,
	}
	if cost != want {
		t.Fatalf("got %+v\nwant %+v", cost, want)
	}
	// A local race's traffic is loopback's alone.
	local := serverCost(before, after, "1", true)
	if local.NetRxMbps != 400*8/1e6/2 || local.NetTxMbps != 400*8/1e6/2 {
		t.Fatalf("loopback: %+v", local)
	}
}

func TestSnapshotRefusesNoClock(t *testing.T) {
	if _, err := parseSnapshot("@@ stat\ncpu 1 2 3"); err == nil {
		t.Fatal("a snapshot without its clock cannot time a run")
	}
}

// A process gone between snapshots reports no status: its counts are 0,
// never a negative difference read as real.
func TestServerCostWithoutStatus(t *testing.T) {
	before, _ := parseSnapshot(snapshotBefore)
	after, _ := parseSnapshot(strings.Split(snapshotAfter, "@@ status")[0])
	cost := serverCost(before, after, "1", false)
	if cost.Threads != 0 || cost.VoluntarySwitches != 0 || cost.InvoluntarySwitches != 0 {
		t.Fatalf("a vanished process counted: %+v", cost)
	}
}

func TestParseOhaKeepsTheTail(t *testing.T) {
	report := `{"summary":{"successRate":1,"requestsPerSec":1000,"average":0.002,
		"slowest":0.05,"sizePerRequest":13},
		"rps":{"min":800,"stddev":40},
		"details":{"DNSDialup":{"average":0.0001}},
		"latencyPercentiles":{"p50":0.001,"p90":0.002,"p95":0.003,"p99":0.004,
			"p99.9":0.005,"p99.99":0.006},
		"firstBytePercentiles":{"p50":0.0005,"p99":0.002},
		"statusCodeDistribution":{"200":20000},"errorDistribution":{}}`
	round, err := parseOha(report)
	if err != nil {
		t.Fatal(err)
	}
	want := Round{RPS: 1000, SuccessRate: 1, P50Ms: 1, P90Ms: 2, P95Ms: 3, P99Ms: 4,
		P999Ms: 5, P9999Ms: 6, MeanMs: 2, MaxMs: 50, FirstByteP50Ms: 0.5,
		FirstByteP99Ms: 2, RPSPerSecondStddev: 40,
		ConnectMeanMs: 0.1, BytesPerResponse: 13}
	if round != want {
		t.Fatalf("got %+v\nwant %+v", round, want)
	}
}

// Runs stored before p95 and p99.9 had medians get them on publish, from
// their rounds.
func TestNormalizeTakesTheMedians(t *testing.T) {
	run := Run{Results: []Result{{Rounds: []Round{
		{RPS: 3, P95Ms: 30, P999Ms: 300}, {RPS: 1, P95Ms: 10, P999Ms: 100},
		{RPS: 2, P95Ms: 20, P999Ms: 200},
	}}}}
	run.normalize()
	got := run.Results[0]
	if got.MedianRPS != 2 || got.MedianP95Ms != 20 || got.MedianP999Ms != 200 {
		t.Fatalf("medians: %+v", got)
	}
}

// Context switches are every thread's, summed: a Go server's main thread
// sleeps while its workers serve.
func TestSnapshotSumsThreads(t *testing.T) {
	text := "@@ clock\n1\n@@ status\nThreads:\t2\nvoluntary_ctxt_switches:\t3\n" +
		"nonvoluntary_ctxt_switches:\t1\nThreads:\t2\nvoluntary_ctxt_switches:\t40\n" +
		"nonvoluntary_ctxt_switches:\t5"
	snapshot, err := parseSnapshot(text)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Status["Threads"] != 2 || snapshot.Status["voluntary_ctxt_switches"] != 43 ||
		snapshot.Status["nonvoluntary_ctxt_switches"] != 6 {
		t.Fatalf("status: %v", snapshot.Status)
	}
}

func TestCoresApart(t *testing.T) {
	// Siblings 0-1, 2-3, ... (the owner's laptop) and 0-4, 1-5, ... (common
	// elsewhere).
	adjacent := func(cpu string) (string, error) { return "0:" + strconv.Itoa(cpuNumber(cpu)/2), nil }
	spread := func(cpu string) (string, error) { return "0:" + strconv.Itoa(cpuNumber(cpu)%4), nil }
	if err := checkCoresApart("0-1", "2-7", adjacent); err != nil {
		t.Fatalf("adjacent siblings, whole cores: %v", err)
	}
	if err := checkCoresApart("0-1", "2-7", spread); err == nil {
		t.Fatal("0-1 with 2-7 shares cores 0 and 1 when siblings are 0-4, 1-5")
	}
	if err := checkCoresApart("0,4", "1-3,5-7", spread); err != nil {
		t.Fatalf("spread siblings, whole cores: %v", err)
	}
}

func TestCPUMatches(t *testing.T) {
	model := "Intel(R) Xeon(R) Platinum 8168 CPU @ 2.70GHz"
	cases := []struct {
		wanted, model, id string
		match             bool
	}{
		{"", model, "6:85:4", true},
		{"Platinum 8168", model, "6:85:4", true},
		{"Platinum 8168", "Intel(R) Xeon(R) Platinum 8280 CPU @ 2.70GHz", "6:85:7", false},
		{"6:85:4", "DO-Regular", "6:85:4", true},
		{"6:85:4", "DO-Regular", "6:106:6", false},
	}
	for _, c := range cases {
		if cpuMatches(c.wanted, c.model, c.id) != c.match {
			t.Errorf("%q against %q (%s): want %v", c.wanted, c.model, c.id, c.match)
		}
	}
}

func TestDropletImagePinsAgree(t *testing.T) {
	root := "../../.."
	race, err := loadRace(root)
	if err != nil {
		t.Fatal(err)
	}
	versions, err := loadVersions(root)
	if err != nil {
		t.Fatal(err)
	}
	if race.Cloud.Image == "" || race.Cloud.Image != versions.DropletImage {
		t.Fatalf("race.json image %q, versions.json droplet_image %q",
			race.Cloud.Image, versions.DropletImage)
	}
}

// Only DigitalOcean's refusal of a not-yet-registered key is retried;
// any other refusal (a bad size, a quota) fails at once.
func TestKeyNotYetKnown(t *testing.T) {
	refused := fmt.Errorf(`DigitalOcean POST /v2/droplets: 422 Unprocessable Entity: {"id":"unprocessable_entity","message":"59891906 are invalid key identifiers for Droplet creation."}`)
	if !keyNotYetKnown(refused) {
		t.Fatalf("a new key's refusal must be retried")
	}
	quota := fmt.Errorf(`DigitalOcean POST /v2/droplets: 422 Unprocessable Entity: {"message":"creating this/these droplet(s) will exceed your droplet limit"}`)
	if keyNotYetKnown(quota) {
		t.Fatalf("a quota refusal must not be retried")
	}
}
