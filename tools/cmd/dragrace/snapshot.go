package main

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// A snapshot is what a machine's kernel says at one moment, taken in one
// shell call before and after each measured run: the difference is what
// the run cost. The race always read /proc/stat this way; the rest rides
// along in the same call (2026-10-06): the network (bytes, so a result
// that is the droplet's link and not the server says so), TCP
// retransmits, and the server process's threads and context switches.

// snapshotCommand prints the snapshot, sections marked by "@@ name" lines;
// pid is the server's, or "" for a machine with no process of interest.
func snapshotCommand(pid string) string {
	command := "echo '@@ clock'; date +%s%N; echo '@@ stat'; cat /proc/stat; " +
		"echo '@@ net'; cat /proc/net/dev; echo '@@ snmp'; cat /proc/net/snmp"
	if pid != "" {
		// Every thread's: a thread's switches are its own, and a server's
		// main thread may sleep while its workers serve (Go's does).
		command += "; echo '@@ status'; cat /proc/" + pid + "/task/*/status 2>/dev/null"
	}
	return command
}

type Snapshot struct {
	ClockNs int64
	Stat    string
	// Bytes received and sent, per interface.
	NetRx, NetTx map[string]uint64
	// Packets received and sent, per interface: DigitalOcean also limits
	// packets a second, which small responses reach before bytes.
	PacketsRx, PacketsTx map[string]uint64
	Retransmits          uint64
	// From /proc/PID/task/*/status: Threads, and the voluntary and
	// involuntary context switches of all threads; absent when the
	// process is gone.
	Status map[string]int64
}

func parseSnapshot(text string) (Snapshot, error) {
	snapshot := Snapshot{NetRx: map[string]uint64{}, NetTx: map[string]uint64{},
		PacketsRx: map[string]uint64{}, PacketsTx: map[string]uint64{},
		Status: map[string]int64{}}
	sections := map[string][]string{}
	section := ""
	for _, line := range strings.Split(text, "\n") {
		if name, found := strings.CutPrefix(line, "@@ "); found {
			section = name
			continue
		}
		sections[section] = append(sections[section], line)
	}
	clock := strings.TrimSpace(strings.Join(sections["clock"], ""))
	nanoseconds, err := strconv.ParseInt(clock, 10, 64)
	if err != nil {
		return snapshot, fmt.Errorf("snapshot clock %q: %w", clock, err)
	}
	snapshot.ClockNs = nanoseconds
	snapshot.Stat = strings.Join(sections["stat"], "\n")
	for _, line := range sections["net"] {
		name, counters, found := strings.Cut(line, ":")
		fields := strings.Fields(counters)
		if !found || len(fields) < 9 {
			continue // the two header lines
		}
		interfaceName := strings.TrimSpace(name)
		snapshot.NetRx[interfaceName], _ = strconv.ParseUint(fields[0], 10, 64)
		snapshot.NetTx[interfaceName], _ = strconv.ParseUint(fields[8], 10, 64)
		snapshot.PacketsRx[interfaceName], _ = strconv.ParseUint(fields[1], 10, 64)
		snapshot.PacketsTx[interfaceName], _ = strconv.ParseUint(fields[9], 10, 64)
	}
	snapshot.Retransmits = retransmits(sections["snmp"])
	for _, line := range sections["status"] {
		name, value, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		count, _ := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
		switch name {
		case "Threads": // the process's, repeated in every thread's status
			snapshot.Status[name] = count
		case "voluntary_ctxt_switches", "nonvoluntary_ctxt_switches":
			// Summed over the threads alive now: one that exits between
			// two snapshots takes its count with it (servers keep theirs).
			snapshot.Status[name] += count
		}
	}
	return snapshot, nil
}

// retransmits is Tcp's RetransSegs: /proc/net/snmp gives each protocol
// two lines, the names and then the values.
func retransmits(lines []string) uint64 {
	for i := 0; i+1 < len(lines); i++ {
		names := strings.Fields(lines[i])
		values := strings.Fields(lines[i+1])
		if len(names) == 0 || names[0] != "Tcp:" || len(values) != len(names) ||
			values[0] != "Tcp:" {
			continue
		}
		for j, name := range names {
			if name == "RetransSegs" {
				count, _ := strconv.ParseUint(values[j], 10, 64)
				return count
			}
		}
	}
	return 0
}

// CPUShares is how a set of CPUs spent a run, in percent of their time.
type CPUShares struct {
	Busy, User, System, Irq, Softirq, Steal float64
}

// cpuShares reads the difference of two /proc/stat texts on the CPUs given
// ("0-1,4"; "" for the whole machine). Busy is user, nice, system, irq
// and softirq: softirq is the network stack's work for the server, which
// no per-process count sees (the benchmarking skill: charge the server
// everything).
func cpuShares(before, after, cpus string) CPUShares {
	wanted := cpuSet(cpus)
	// user nice system idle iowait irq softirq steal
	sum := func(stat string) (fields [8]float64) {
		for _, line := range strings.Split(stat, "\n") {
			words := strings.Fields(line)
			if len(words) < 9 || !strings.HasPrefix(words[0], "cpu") {
				continue
			}
			id := strings.TrimPrefix(words[0], "cpu")
			if (wanted == nil) != (id == "") || (wanted != nil && !wanted[id]) {
				continue
			}
			for i := range fields {
				value, _ := strconv.ParseFloat(words[i+1], 64)
				fields[i] += value
			}
		}
		return fields
	}
	first, last := sum(before), sum(after)
	var delta [8]float64
	total := 0.0
	for i := range delta {
		delta[i] = last[i] - first[i]
		total += delta[i]
	}
	if total <= 0 {
		return CPUShares{}
	}
	share := func(value float64) float64 { return 100 * value / total }
	return CPUShares{
		Busy:    share(delta[0] + delta[1] + delta[2] + delta[5] + delta[6]),
		User:    share(delta[0] + delta[1]),
		System:  share(delta[2]),
		Irq:     share(delta[5]),
		Softirq: share(delta[6]),
		Steal:   share(delta[7]),
	}
}

// ServerCost is what a measured run cost the server machine.
type ServerCost struct {
	Seconds             float64
	CPU                 CPUShares
	NetRxMbps           float64
	NetTxMbps           float64
	NetRxPPS            float64
	NetTxPPS            float64
	Retransmits         int64
	Threads             int64
	VoluntarySwitches   int64
	InvoluntarySwitches int64
}

// serverCost compares two snapshots of the server. The network is every
// interface but loopback, or loopback alone when the race is local (its
// traffic never leaves the machine).
func serverCost(before, after Snapshot, cpus string, local bool) ServerCost {
	cost := ServerCost{
		Seconds:     float64(after.ClockNs-before.ClockNs) / 1e9,
		CPU:         cpuShares(before.Stat, after.Stat, cpus),
		Retransmits: int64(after.Retransmits) - int64(before.Retransmits),
	}
	// A process gone by either snapshot has no counts: 0, not a difference.
	_, statusBefore := before.Status["Threads"]
	_, statusAfter := after.Status["Threads"]
	if statusBefore && statusAfter {
		cost.Threads = after.Status["Threads"]
		cost.VoluntarySwitches = after.Status["voluntary_ctxt_switches"] -
			before.Status["voluntary_ctxt_switches"]
		cost.InvoluntarySwitches = after.Status["nonvoluntary_ctxt_switches"] -
			before.Status["nonvoluntary_ctxt_switches"]
	}
	if cost.Seconds <= 0 {
		return cost
	}
	var rx, tx, packetsRx, packetsTx uint64
	grew := func(after, before uint64) uint64 { return after - min(after, before) }
	for name, bytes := range after.NetRx {
		if (name == "lo") != local {
			continue
		}
		rx += grew(bytes, before.NetRx[name])
		tx += grew(after.NetTx[name], before.NetTx[name])
		packetsRx += grew(after.PacketsRx[name], before.PacketsRx[name])
		packetsTx += grew(after.PacketsTx[name], before.PacketsTx[name])
	}
	cost.NetRxPPS = float64(packetsRx) / cost.Seconds
	cost.NetTxPPS = float64(packetsTx) / cost.Seconds
	cost.NetRxMbps = float64(rx) * 8 / 1e6 / cost.Seconds
	cost.NetTxMbps = float64(tx) * 8 / 1e6 / cost.Seconds
	return cost
}

// over is the cost with every rate taken over the load's own duration
// (oha's) instead of the snapshots' window, which also holds the shell
// calls around the load: the server is idle then, so its busy time and
// bytes all belong to the load. Shares stay at most 100%.
func (cost ServerCost) over(loadSeconds float64) ServerCost {
	if loadSeconds <= 0 || cost.Seconds <= loadSeconds {
		return cost
	}
	factor := cost.Seconds / loadSeconds
	share := func(percent float64) float64 { return math.Min(100, percent*factor) }
	scaled := cost
	scaled.CPU = CPUShares{Busy: share(cost.CPU.Busy), User: share(cost.CPU.User),
		System: share(cost.CPU.System), Irq: share(cost.CPU.Irq),
		Softirq: share(cost.CPU.Softirq), Steal: share(cost.CPU.Steal)}
	scaled.NetRxMbps *= factor
	scaled.NetTxMbps *= factor
	scaled.NetRxPPS *= factor
	scaled.NetTxPPS *= factor
	return scaled
}

// loaderBusy is the loader's CPU busy share over the load's duration.
func loaderBusy(before, after Snapshot, cpus string, loadSeconds float64) float64 {
	window := float64(after.ClockNs-before.ClockNs) / 1e9
	busy := cpuShares(before.Stat, after.Stat, cpus).Busy
	if loadSeconds <= 0 || window <= loadSeconds {
		return busy
	}
	return math.Min(100, busy*window/loadSeconds)
}
