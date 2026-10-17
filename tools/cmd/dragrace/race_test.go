package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
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

// hostFile is one of hosts/'s files: host is its directory there, path its
// install path.
func hostFile(t *testing.T, host, path string) string {
	t.Helper()
	bytes, err := os.ReadFile(filepath.Join("../../../hosts", host, path))
	if err != nil {
		t.Fatal(err)
	}
	return string(bytes)
}

// The site's unit is for the owner's one site: its name, Let's Encrypt's
// production directory, the paths the code uses; the host agent's config
// says the same.
func TestSiteUnitEnvironment(t *testing.T) {
	service := hostFile(t, "site", "/etc/systemd/system/dragrace-site.service")
	for _, want := range []string{
		"Environment=ROUX_ACME_DIRECTORY=https://acme-v02.api.letsencrypt.org/directory\n",
		"Environment=ROUX_ACME_IDENTIFIER=" + siteName + "\n",
		"WorkingDirectory=" + siteState + "\n",
		"ExecStart=" + siteHome + "/current/dragrace-site\n",
		"ConditionPathExists=" + siteHome + "/current/dragrace-site\n",
	} {
		if !strings.Contains(service, want) {
			t.Fatalf("no %q in:\n%s", want, service)
		}
	}
	agent := hostFile(t, "site", "/etc/systemd/system/dragrace-host-agent.service")
	if !strings.Contains(agent, "ExecStart="+hostAgentBinary+" host-agent\n") {
		t.Fatalf("the agent's unit runs another binary:\n%s", agent)
	}
	var config HostConfig
	if err := json.Unmarshal([]byte(hostFile(t, "site", "/etc/dragrace-host/config.json")), &config); err != nil {
		t.Fatal(err)
	}
	if config.Health != "https://"+siteName+"/api/health" || config.Home != siteHome ||
		config.Database != siteState+"/site.db" {
		t.Fatalf("the host agent's config: %+v", config)
	}
}

// The site holds no capability (systemd's sockets bind 80 and 443 for it)
// and reaches no Tailscale address: a site broken into reaches no other
// machine of a tailnet its host might join.
func TestSiteUnitPrivileges(t *testing.T) {
	service := hostFile(t, "site", "/etc/systemd/system/dragrace-site.service")
	for _, want := range []string{
		"CapabilityBoundingSet=\n",
		"IPAddressDeny=100.64.0.0/10 fd7a:115c:a1e0::/48\n",
		"NoNewPrivileges=yes\n",
	} {
		if !strings.Contains(service, want) {
			t.Fatalf("no %q in:\n%s", want, service)
		}
	}
	if strings.Contains(service, "AmbientCapabilities") {
		t.Fatalf("a capability given:\n%s", service)
	}
}

// The site's sockets are systemd's, named as fourneau's listen.zig and
// roux's host look for them, and the service takes both.
func TestSiteSockets(t *testing.T) {
	for _, socket := range []struct{ file, listen, name string }{
		{"dragrace-site-https.socket", "ListenStream=0.0.0.0:443\n", "FileDescriptorName=https\n"},
		{"dragrace-site-http.socket", "ListenStream=0.0.0.0:80\n", "FileDescriptorName=http\n"},
	} {
		unit := hostFile(t, "site", "/etc/systemd/system/"+socket.file)
		for _, want := range []string{socket.listen, socket.name, "Service=dragrace-site.service\n"} {
			if !strings.Contains(unit, want) {
				t.Fatalf("no %q in %s:\n%s", want, socket.file, unit)
			}
		}
	}
	service := hostFile(t, "site", "/etc/systemd/system/dragrace-site.service")
	want := "Sockets=dragrace-site-https.socket dragrace-site-http.socket\n"
	if !strings.Contains(service, want) {
		t.Fatalf("no %q in:\n%s", want, service)
	}
}

// An install's SHA256SUMS lists every file of the host's tree and each
// binary, by path, as sha256sum -c reads it; the tarball it sends holds the
// tree, root's, mode 644, and no directory (extracting one over /etc would
// change /etc's own mode).
func TestHostSums(t *testing.T) {
	files, err := hostTree("../../..", "racer")
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, file := range files {
		names[file.name] = true
	}
	for _, name := range []string{"etc/ssh/sshd_config.d/10-dragrace.conf",
		"etc/systemd/system/dragrace-guard.service", "etc/dragrace-racer/config.json"} {
		if !names[name] {
			t.Fatalf("the racer's tree lacks %s: %v", name, files)
		}
	}
	if names["etc/dragrace-host/config.json"] {
		t.Fatalf("the racer's tree has the site's files")
	}
	binary := filepath.Join(t.TempDir(), "dragrace")
	if err := os.WriteFile(binary, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	sums, err := hostSums(files, map[string]string{guardBinary: binary})
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(sums, "\n"), "\n")
	var paths []string
	for _, line := range lines {
		_, path, _ := strings.Cut(line, "  ")
		paths = append(paths, path)
	}
	if len(lines) != len(files)+1 || !slices.IsSorted(paths) {
		t.Fatalf("%d lines for %d files and a binary, by path:\n%s", len(lines), len(files), sums)
	}
	// sha256 of "x".
	want := "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881  " + guardBinary
	if !slices.Contains(lines, want) {
		t.Fatalf("no %q in:\n%s", want, sums)
	}
	tarball := filepath.Join(t.TempDir(), "host.tar.gz")
	if _, err := writeTarball(tarball, files, nil); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(tarball)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	unzipped, err := gzip.NewReader(file)
	if err != nil {
		t.Fatal(err)
	}
	archive := tar.NewReader(unzipped)
	for count := 0; ; count++ {
		header, err := archive.Next()
		if err == io.EOF {
			if count != len(files) {
				t.Fatalf("%d entries for %d files", count, len(files))
			}
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if header.Typeflag != tar.TypeReg || header.Mode != 0o644 || header.Uid != 0 ||
			header.Gid != 0 || strings.HasPrefix(header.Name, "/") {
			t.Fatalf("not a file of root's, mode 644, below /: %+v", header)
		}
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

// A result is summarized on publish from its rounds: the best round's rate,
// the rounds' median percentiles, a round that answered nothing left out of
// the latencies.
func TestNormalizeTakesTheBestRateAndMedianLatency(t *testing.T) {
	run := Run{Results: []Result{{Rounds: []Round{
		{RPS: 3, P95Ms: 30, P999Ms: 300}, {RPS: 1, P95Ms: 10, P999Ms: 100},
		{RPS: 2, P95Ms: 20, P999Ms: 200}, {RPS: 0, P95Ms: 0, P999Ms: 0},
	}}}}
	run.normalize()
	got := run.Results[0]
	if got.BestRPS != 3 || got.MedianP95Ms != 20 || got.MedianP999Ms != 200 {
		t.Fatalf("summary: %+v", got)
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
	// Siblings 0-1, 2-3, ... (some laptops) and 0-4, 1-5, ... (common
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

// Every host of the owner's refuses root's login and keeps Ubuntu's update
// cycle stock, its reboot at the end of the run turned on; the check at
// 05:00 New York time comes after it.
func TestHostFiles(t *testing.T) {
	sshd := hostFile(t, "common", "/etc/ssh/sshd_config.d/10-dragrace.conf")
	if sshd != "PermitRootLogin no\nPasswordAuthentication no\n" {
		t.Fatalf("sshd: %q", sshd)
	}
	if !strings.Contains(hostFile(t, "common", "/etc/apt/apt.conf.d/52dragrace-reboot"),
		`Automatic-Reboot "true";`) {
		t.Fatalf("unattended-upgrades must reboot at the end of its run")
	}
	var common []string
	err := filepath.WalkDir("../../../hosts/common", func(path string, entry fs.DirEntry, err error) error {
		if err == nil && !entry.IsDir() {
			common = append(common, path)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(common) != 2 {
		t.Fatalf("stock updates: no file but sshd's and the reboot's, got %v", common)
	}
	setup := strings.Join(hostSetup("22", "443"), " && ")
	for _, part := range []string{"ufw default deny incoming", "ufw allow 22/tcp", "ufw allow 443/tcp",
		"ufw --force enable", "grep -q '^Status: active'"} {
		if !strings.Contains(setup, part) {
			t.Fatalf("setup's firewall lacks %q", part)
		}
	}
	if strings.Contains(setup, "80/tcp") {
		t.Fatalf("a port not asked for is open")
	}
	if !strings.Contains(setup, "GRUB_FORCE_PARTUUID=$(findmnt -no PARTUUID /)") ||
		!strings.Contains(setup, "sudo update-grub") {
		t.Fatalf("setup must boot without an initramfs: %s", setup)
	}
	if !strings.Contains(hostFile(t, "racer", "/etc/systemd/system/dragrace-racer-check.timer"),
		"OnCalendar=*-*-* 05:00:00 America/New_York") {
		t.Fatalf("the check must come after the updates' window")
	}
}

// Every server is started the same way: its binary, roux's variables (the
// TLS pair in TLS mode only), a fresh copy of the seeded database, and
// SIGPIPE ignored (basic-webserver dies of one). A script
// stands in for the server and writes down what it was given. A bash
// script: Ubuntu's /bin/sh, dash, puts SIGPIPE back to the default as it
// starts, where a real server, a binary, keeps what it is given. Only
// GitHub's runner (Ubuntu 26.04) runs this against uutils' nohup, which
// unignores SIGPIPE; here, put Ubuntu's rust-coreutils'
// /usr/lib/cargo/bin/coreutils first on PATH.
func TestStartServer(t *testing.T) {
	home := t.TempDir()
	script := "#!/usr/bin/env bash\n" +
		`echo "$ROUX_ADDRESS $ROUX_PORT $ROUX_DATABASE ${ROUX_TLS_CERT:-no} ${ROUX_TLS_KEY:-no}"` + "\n" +
		`cat "$ROUX_DATABASE"` + "\n" +
		`grep '^SigIgn:' /proc/$$/status` + "\n" +
		"echo done\n"
	for path, text := range map[string]string{"bin/x": script, conduitSeedName: "seed\n"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(home, path)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(home, path), []byte(text), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	race := Race{Port: 8123}
	target := Target{Server: LocalMachine{}, ServerHome: home, Address: "127.0.0.1"}
	given := func(competitor Competitor, mode Mode) []string {
		t.Helper()
		os.Remove(filepath.Join(home, "x.log"))
		if _, err := startServer(context.Background(), race, competitor, target, mode); err != nil {
			t.Fatal(err)
		}
		for range 50 {
			log, _ := os.ReadFile(filepath.Join(home, "x.log"))
			if lines := strings.Split(strings.TrimSpace(string(log)), "\n"); lines[len(lines)-1] == "done" {
				return lines
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Fatal("the server never wrote it down")
		return nil
	}
	database := home + "/" + conduitDatabaseName
	lines := given(Competitor{Name: "x"}, plainMode)
	if lines[0] != "127.0.0.1 8123 "+database+" no no" || lines[1] != "seed" {
		t.Fatalf("plain: %q", lines)
	}
	fields := strings.Fields(lines[2])
	ignored, err := strconv.ParseUint(fields[len(fields)-1], 16, 64)
	if err != nil || ignored&(1<<(13-1)) == 0 { // SIGPIPE is 13
		t.Fatalf("SIGPIPE not ignored: %q", lines[2])
	}
	lines = given(Competitor{Name: "x", TLS: true}, tlsMode)
	if lines[0] != "127.0.0.1 8123 "+database+" "+home+"/"+certificateName+" "+home+"/"+keyName {
		t.Fatalf("TLS: %q", lines)
	}
	_, err = startServer(context.Background(), race, Competitor{Name: "x"}, target, tlsMode)
	if err == nil {
		t.Fatal("a competitor with no TLS started in TLS mode")
	}
}

// The competitors in the race build with one command each, which names
// the binary it writes; basic-webserver alone serves no TLS.
func TestCompetitorsLoad(t *testing.T) {
	race, err := loadRace("../../..")
	if err != nil {
		t.Fatal(err)
	}
	competitors, err := loadCompetitors("../../..", race.Competitors)
	if err != nil {
		t.Fatal(err)
	}
	for _, competitor := range competitors {
		if competitor.TLS == (competitor.Name == "basic-webserver") {
			t.Errorf("%s: tls %t", competitor.Name, competitor.TLS)
		}
	}
}

// A smoke race measures smokeWorkloads, each in race.json, at 2 s a cell
// and one rate a ladder, and keeps every workload for the checks.
func TestQuickRace(t *testing.T) {
	race, err := loadRace("../../..")
	if err != nil {
		t.Fatal(err)
	}
	competitors, err := loadCompetitors("../../..", race.Competitors)
	if err != nil {
		t.Fatal(err)
	}
	quick := raceFlags{quick: true}.narrow(race)
	if len(quick.Workloads) != len(race.Workloads) {
		t.Errorf("the checks see %d workloads of %d", len(quick.Workloads), len(race.Workloads))
	}
	for _, name := range smokeWorkloads {
		if !slices.ContainsFunc(race.Workloads, func(w Workload) bool { return w.Name == name }) {
			t.Errorf("smoke workload %s is not in race.json", name)
		}
	}
	measured := map[string]bool{}
	for _, step := range planSteps(quick, competitors, 42) {
		if step.Workload != "" {
			measured[step.Workload] = true
			if rates := len(step.workload.Mixed.Rates); rates != 1 {
				t.Errorf("%s: %d rates", step.Workload, rates)
			}
		}
	}
	if !maps.Equal(measured, map[string]bool{"conduit": true}) {
		t.Errorf("ladders: %v", measured)
	}
	if quick.WarmupSeconds+quick.MeasureSeconds != 2 {
		t.Errorf("a cell is %d s", quick.WarmupSeconds+quick.MeasureSeconds)
	}
}

// Without the kernel's tls, a race refuses at once when fourneau-zig or
// roux would race a TLS workload, and says how to load it; it races when
// neither would.
func TestCheckKernelTLS(t *testing.T) {
	race, err := loadRace("../../..")
	if err != nil {
		t.Fatal(err)
	}
	competitors, err := loadCompetitors("../../..", race.Competitors)
	if err != nil {
		t.Fatal(err)
	}
	err = checkKernelTLS(race, competitors, "espintcp mptcp")
	if err == nil || !strings.Contains(err.Error(), "sudo modprobe tls") ||
		!strings.Contains(err.Error(), "-competitors go,axum,basic-webserver") {
		t.Errorf("no tls: %v", err)
	}
	if err := checkKernelTLS(race, competitors, "espintcp mptcp tls"); err != nil {
		t.Errorf("tls loaded: %v", err)
	}
	others := slices.DeleteFunc(slices.Clone(competitors), func(c Competitor) bool { return c.KernelTLS })
	if len(others) != 3 {
		t.Errorf("%d competitors without kernel TLS", len(others))
	}
	if err := checkKernelTLS(race, others, "espintcp mptcp"); err != nil {
		t.Errorf("go, axum and basic-webserver: %v", err)
	}
	plain := raceFlags{workloads: "plaintext,churn"}.narrow(race)
	if err := checkKernelTLS(plain, competitors, ""); err != nil {
		t.Errorf("no TLS workload: %v", err)
	}
}

// A class's plan is its rounds, every competitor in each round's seeded
// order, then the ladders; each step planned at its loads' seconds.
func TestPlanSteps(t *testing.T) {
	race, err := loadRace("../../..")
	if err != nil {
		t.Fatal(err)
	}
	competitors, err := loadCompetitors("../../..", race.Competitors)
	if err != nil {
		t.Fatal(err)
	}
	plan := planSteps(race, competitors, 42)
	closed, plain, ladders := 0, 0, 0
	for _, workload := range race.Workloads {
		if workload.Mixed == nil {
			closed++
			if !workload.TLS {
				plain++
			}
			continue
		}
		for _, competitor := range competitors {
			if competitor.offers(workload) {
				ladders++
			}
		}
	}
	if ladders == 0 || len(plan) != race.Rounds*len(competitors)+ladders {
		t.Fatalf("%d steps, %d ladders", len(plan), ladders)
	}
	load := float64(race.WarmupSeconds + race.MeasureSeconds)
	for round := 1; round <= race.Rounds; round++ {
		for i, competitor := range shuffled(competitors, 42+int64(round)) {
			step := plan[(round-1)*len(competitors)+i]
			want := load * float64(closed)
			if !competitor.TLS {
				want = load * float64(plain)
			}
			if step.Competitor != competitor.Name || step.Round != round || step.Workload != "" ||
				step.PlannedSeconds != want {
				t.Fatalf("round %d, %d: %+v", round, i, step)
			}
		}
	}
	ladder := plan[race.Rounds*len(competitors)]
	if ladder.Round != 0 || ladder.Workload != "conduit" || ladder.PlannedSeconds != 15*63 {
		t.Fatalf("the first ladder: %+v", ladder)
	}
}

// A class that ends early names the steps it leaves.
func TestNotRaced(t *testing.T) {
	steps := []Step{{Competitor: "go", Round: 3}, {Competitor: "axum", Workload: "conduit-tls"}}
	if got := notRaced(steps); got != "go round 3, axum conduit-tls" {
		t.Fatalf("got %q", got)
	}
	if got := notRaced(nil); got != "no step" {
		t.Fatalf("got %q", got)
	}
}
