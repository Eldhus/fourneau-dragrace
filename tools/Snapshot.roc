import Text

## What a machine's kernel says at one moment, taken in one shell call
## before and after each measured run: the difference is what the run cost.
## /proc/stat, the network (bytes and packets per interface, so a result
## that is the droplet's link says so), TCP's retransmits, and the server
## process's threads and context switches. Each is a kernel text format of
## named fields, read by its fields.
Snapshot :: [].{
	Taken : {
		clock_ns : I64,
		stat : Str,
		## Per interface: bytes and packets received and sent.
		net : List({ name : Str, rx : U64, tx : U64, packets_rx : U64, packets_tx : U64 }),
		retransmits : U64,
		## From /proc/PID/task/*/status; Err when the process is gone.
		status : Try({ threads : I64, voluntary : I64, involuntary : I64 }, [Gone]),
	}

	## How a set of CPUs spent a run, percent of their time.
	Shares : { busy : F64, user : F64, system : F64, irq : F64, softirq : F64, steal : F64 }

	## What a measured run cost the server machine.
	Cost : {
		seconds : F64,
		cpu : Shares,
		net_rx_mbps : F64,
		net_tx_mbps : F64,
		net_rx_pps : F64,
		net_tx_pps : F64,
		retransmits : I64,
		threads : I64,
		voluntary_switches : I64,
		involuntary_switches : I64,
	}

	## The shell script that prints a snapshot, its sections marked `@@ name`;
	## pid is the server's, "" for a machine with no process of interest.
	command : Str -> Str
	command = |pid| {
		base = "echo '@@ clock'; date +%s%N; echo '@@ stat'; cat /proc/stat; echo '@@ net'; cat /proc/net/dev; echo '@@ snmp'; cat /proc/net/snmp"
		# Every thread's: a thread's switches are its own, and a server's main
		# thread may sleep while its workers serve (Go's does).
		if pid == "" base else "${base}; echo '@@ status'; cat /proc/${pid}/task/*/status 2>/dev/null"
	}

	parse : Str -> Try(Taken, [Failed(Str)])
	parse = |text| {
		sections = split_sections(text)
		clock_text = Str.join_with(section(sections, "clock"), "").trim()
		clock_ns = I64.from_str(clock_text) ? |_| Failed("snapshot clock ${Str.inspect(clock_text)}")
		net = section(sections, "net").keep_oks(net_line)
		status_lines = section(sections, "status")
		status =
			if status_lines.any(|line| line.starts_with("Threads:")) {
				var $threads = 0.I64
				var $voluntary = 0.I64
				var $involuntary = 0.I64
				for line in status_lines {
					match line.split_first(":") {
						Ok({ before, after }) => {
							count = I64.from_str(after.trim()) ?? 0
							if before == "Threads" {
								# The process's, repeated in every thread's status.
								$threads = count
							} else if before == "voluntary_ctxt_switches" {
								# Summed over the threads alive now.
								$voluntary = $voluntary + count
							} else if before == "nonvoluntary_ctxt_switches" {
								$involuntary = $involuntary + count
							}
						}
						Err(_) => {}
					}
				}
				Ok({ threads: $threads, voluntary: $voluntary, involuntary: $involuntary })
			} else {
				Err(Gone)
			}
		Ok({ clock_ns, stat: Str.join_with(section(sections, "stat"), "\n"), net, retransmits: retransmits(section(sections, "snmp")), status })
	}

	## The difference of two /proc/stat texts on the CPUs given ("0-1,4"; ""
	## for the whole machine). Busy is user, nice, system, irq and softirq:
	## softirq is the network stack's work for the server.
	shares : Str, Str, Str -> Shares
	shares = |before, after, cpus| {
		wanted = Snapshot.cpu_set(cpus)
		first = sum_stat(before, wanted)
		last = sum_stat(after, wanted)
		delta = List.map2(last, first, |a, b| a - b)
		total = delta.sum()
		if total <= 0 {
			return { busy: 0, user: 0, system: 0, irq: 0, softirq: 0, steal: 0 }
		}
		at = |i| delta.get(i) ?? 0
		share = |value| 100 * value / total
		{
			busy: share(at(0) + at(1) + at(2) + at(5) + at(6)),
			user: share(at(0) + at(1)),
			system: share(at(2)),
			irq: share(at(5)),
			softirq: share(at(6)),
			steal: share(at(7)),
		}
	}

	## "0-1,4" as the CPUs' ids; Err for "", the whole machine.
	cpu_set : Str -> Try(List(Str), [All])
	cpu_set = |cpus| {
		if cpus == "" {
			return Err(All)
		}
		ids = cpus.split_on(",").join_map(
			|part| {
				{ low, high } =
					match part.split_first("-") {
						Ok({ before, after }) => { low: U64.from_str(before) ?? 0, high: U64.from_str(after) ?? 0 }
						Err(_) => { low: U64.from_str(part) ?? 0, high: U64.from_str(part) ?? 0 }
					}
				List.from_iter((low..=high).iter()).map(|id| id.to_str())
			},
		)
		Ok(ids)
	}

	## How many CPUs a set names; 0 for the whole machine.
	cpu_count : Str -> U64
	cpu_count = |cpus|
		match Snapshot.cpu_set(cpus) {
			Ok(ids) => ids.len()
			Err(All) => 0
		}

	## Two snapshots of the server compared. The network is every interface
	## but loopback, or loopback alone when the race is local.
	cost : Taken, Taken, Str, Bool -> Cost
	cost = |before, after, cpus, local| {
		seconds = (after.clock_ns - before.clock_ns).to_f64() / 1e9
		{ threads, voluntary_switches, involuntary_switches } =
			match (before.status, after.status) {
				(Ok(b), Ok(a)) => { threads: a.threads, voluntary_switches: a.voluntary - b.voluntary, involuntary_switches: a.involuntary - b.involuntary }
				_ => { threads: 0, voluntary_switches: 0, involuntary_switches: 0 }
			}
		base = {
			seconds,
			cpu: Snapshot.shares(before.stat, after.stat, cpus),
			net_rx_mbps: 0,
			net_tx_mbps: 0,
			net_rx_pps: 0,
			net_tx_pps: 0,
			retransmits: after.retransmits.to_i64_wrap() - before.retransmits.to_i64_wrap(),
			threads,
			voluntary_switches,
			involuntary_switches,
		}
		if seconds <= 0 {
			return base
		}
		grew = |a, b| if a >= b a - b else 0
		var $rx = 0.U64
		var $tx = 0.U64
		var $prx = 0.U64
		var $ptx = 0.U64
		for iface in after.net {
			if (iface.name == "lo") == local {
				was = before.net.find_first(|n| n.name == iface.name) ?? { name: iface.name, rx: 0, tx: 0, packets_rx: 0, packets_tx: 0 }
				$rx = $rx + grew(iface.rx, was.rx)
				$tx = $tx + grew(iface.tx, was.tx)
				$prx = $prx + grew(iface.packets_rx, was.packets_rx)
				$ptx = $ptx + grew(iface.packets_tx, was.packets_tx)
			}
		}
		{
			..base,
			net_rx_pps: $prx.to_f64() / seconds,
			net_tx_pps: $ptx.to_f64() / seconds,
			net_rx_mbps: $rx.to_f64() * 8 / 1e6 / seconds,
			net_tx_mbps: $tx.to_f64() * 8 / 1e6 / seconds,
		}
	}

	## The cost with every rate over the load's own duration (oha's) instead
	## of the snapshots' window, which also holds the shell calls around the
	## load: the server is idle then. Shares stay at most 100%.
	over : Cost, F64 -> Cost
	over = |c, load_seconds| {
		if load_seconds <= 0 or c.seconds <= load_seconds {
			return c
		}
		factor = c.seconds / load_seconds
		share = |percent| at_most_100(percent * factor)
		{
			..c,
			cpu: { busy: share(c.cpu.busy), user: share(c.cpu.user), system: share(c.cpu.system), irq: share(c.cpu.irq), softirq: share(c.cpu.softirq), steal: share(c.cpu.steal) },
			net_rx_mbps: c.net_rx_mbps * factor,
			net_tx_mbps: c.net_tx_mbps * factor,
			net_rx_pps: c.net_rx_pps * factor,
			net_tx_pps: c.net_tx_pps * factor,
		}
	}

	## The loader's busy share over the load's duration.
	loader_busy : Taken, Taken, Str, F64 -> F64
	loader_busy = |before, after, cpus, load_seconds| {
		window = (after.clock_ns - before.clock_ns).to_f64() / 1e9
		busy = Snapshot.shares(before.stat, after.stat, cpus).busy
		if load_seconds <= 0 or window <= load_seconds busy else at_most_100(busy * window / load_seconds)
	}
}

at_most_100 : F64 -> F64
at_most_100 = |percent| if percent > 100 100 else percent

split_sections : Str -> List((Str, List(Str)))
split_sections = |text| {
	var $sections = []
	var $name = ""
	var $lines = []
	for line in Text.lines(text) {
		if line.starts_with("@@ ") {
			$sections = $sections.append(($name, $lines))
			$name = line.drop_prefix("@@ ")
			$lines = []
		} else {
			$lines = $lines.append(line)
		}
	}
	$sections.append(($name, $lines))
}

section : List((Str, List(Str))), Str -> List(Str)
section = |sections, name| sections.keep_if(|(n, _)| n == name).join_map(|(_, lines)| lines)

## A /proc/net/dev line: `  eth0: rx_bytes rx_packets ... tx_bytes tx_packets ...`.
net_line : Str -> Try({ name : Str, rx : U64, tx : U64, packets_rx : U64, packets_tx : U64 }, [NotAnInterface])
net_line = |line|
	match line.split_first(":") {
		Ok({ before, after }) => {
			fields = Text.fields(after)
			if fields.len() < 10 {
				return Err(NotAnInterface)
			}
			at = |i| U64.from_str(fields.get(i) ?? "") ?? 0
			Ok({ name: before.trim(), rx: at(0), packets_rx: at(1), tx: at(8), packets_tx: at(9) })
		}
		Err(_) => Err(NotAnInterface)
	}

## Tcp's RetransSegs: /proc/net/snmp gives each protocol two lines, the
## names and then the values.
retransmits : List(Str) -> U64
retransmits = |lines| {
	var $found = 0.U64
	var $i = 0
	while $i + 1 < lines.len() {
		names = Text.fields(lines.get($i) ?? "")
		values = Text.fields(lines.get($i + 1) ?? "")
		if names.first() == Ok("Tcp:") and values.first() == Ok("Tcp:") and names.len() == values.len() {
			var $j = 0
			for name in names {
				if name == "RetransSegs" {
					$found = U64.from_str(values.get($j) ?? "") ?? 0
				}
				$j = $j + 1
			}
		}
		$i = $i + 1
	}
	$found
}

## The eight counters (user nice system idle iowait irq softirq steal)
## summed over the CPUs wanted: the total line alone for the whole machine.
sum_stat : Str, Try(List(Str), [All]) -> List(F64)
sum_stat = |stat, wanted|
	Text.lines(stat).fold(
		List.repeat(0.0, 8),
		|sums, line| {
			words = Text.fields(line)
			first = words.first() ?? ""
			if words.len() < 9 or !first.starts_with("cpu") {
				return sums
			}
			id = first.drop_prefix("cpu")
			counted =
				match wanted {
					Err(All) => id == ""
					Ok(ids) => id != "" and ids.contains(id)
				}
			if !counted {
				return sums
			}
			List.map2(sums, words.drop_first(1).take_first(8), |sum, word| sum + (F64.from_str(word) ?? 0))
		},
	)

stat_before = "cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 50 0 50 400 0 0 0 0 0 0\ncpu1 50 0 50 400 0 0 0 0 0 0"
stat_after = "cpu  200 0 200 1000 0 0 0 0 0 0\ncpu0 150 0 100 450 0 0 0 0 0 0\ncpu1 50 0 100 450 0 0 0 0 0 0"

expect Snapshot.cpu_set("0-1,4") == Ok(["0", "1", "4"])
expect Snapshot.cpu_set("") == Err(All)
expect Snapshot.cpu_count("2-3") == 2
expect Snapshot.shares(stat_before, stat_after, "").busy == 50
expect Snapshot.shares(stat_before, stat_after, "0").busy == 75
expect Snapshot.shares(stat_before, stat_after, "1").busy == 50

expect {
	text = "@@ clock\n1000000000\n@@ stat\n${stat_before}\n@@ net\nInter-|   Receive\n face |bytes    packets\n    lo: 100 10 0 0 0 0 0 0 200 20 0 0 0 0 0 0\n  eth0: 1000 5 0 0 0 0 0 0 2000 7 0 0 0 0 0 0\n@@ snmp\nTcp: RtoAlgorithm RetransSegs\nTcp: 1 42\n@@ status\nThreads:\t4\nvoluntary_ctxt_switches:\t10\nnonvoluntary_ctxt_switches:\t2\nThreads:\t4\nvoluntary_ctxt_switches:\t5\nnonvoluntary_ctxt_switches:\t1"
	match Snapshot.parse(text) {
		Ok(s) => s.clock_ns == 1_000_000_000 and s.retransmits == 42 and s.net.len() == 2 and s.status == Ok({ threads: 4, voluntary: 15, involuntary: 3 })
		Err(_) => Bool.False
	}
}

expect {
	empty = { clock_ns: 0, stat: stat_before, net: [{ name: "eth0", rx: 0, tx: 0, packets_rx: 0, packets_tx: 0 }], retransmits: 1, status: Err(Gone) }
	later = { clock_ns: 2_000_000_000, stat: stat_after, net: [{ name: "eth0", rx: 1_000_000, tx: 0, packets_rx: 100, packets_tx: 0 }], retransmits: 4, status: Err(Gone) }
	c = Snapshot.cost(empty, later, "", Bool.False)
	c.seconds == 2 and c.net_rx_mbps == 4 and c.net_rx_pps == 50 and c.retransmits == 3 and c.threads == 0 and Snapshot.over(c, 1).net_rx_mbps == 8 and Snapshot.over(c, 1).cpu.busy == 100
}
