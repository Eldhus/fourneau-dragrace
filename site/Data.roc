## The races as the pages model them: a run whole, and every run's best
## rounds. A result (Store.roc makes it from its rounds):
## `best_rps`, the most requests a second of any round, as a benchmark
## takes the fastest of its repeats: a server can do no more than it did,
## and a round short of it met noise. The latency percentiles are each the
## median of the rounds: a tail is the server's rare stalls, real
## behaviour, so the least would report the round that missed them and
## the most the round a neighbour hit.
## Store.roc reads them from the database; the JSON parsers here read the
## tests' fixtures (test/: a run, and an index, as the site served them).
Data :: [].{
	Round : { rps : F64, p99_ms : F64, cpu_busy_pct : F64, steal_pct : F64, rss_kib : F64, loader_cpu_busy_pct : F64, net_rx_mbps : F64, net_tx_mbps : F64, tcp_retransmits : F64, load_seconds : F64 }

	Result : {
		class : Str,
		workload : Str,
		competitor : Str,
		valid : Bool,
		note : Str,
		rounds : List(Round),
		best_rps : F64,
		median_p95_ms : F64,
		median_p99_ms : F64,
		median_p999_ms : F64,
		open_loop : List(OpenStep),
	}

	## One rate of an open-loop climb: the offered rate, what was answered
	## (2xx), latency from when each request was due, and both machines' CPU.
	OpenStep : {
		offered_rps : F64,
		achieved_rps : F64,
		## A mixed workload's percentiles are its slowest part's.
		p99_ms : F64,
		p999_ms : F64,
		cpu_busy_pct : F64,
		loader_cpu_busy_pct : F64,
	}

	## A test in one variant. `kind`: "closed" (rounds, bars) or "mixed" (an
	## open-loop ladder of several requests at once, a line). `protocol`:
	## the variant's, "http1", "h2c" (HTTP/2 without TLS) or "tls" (the
	## realistic deployment), each a section of the race page; and how the
	## loader sent it: connections, HTTP/2's streams on each (0 for
	## HTTP/1.1), kept alive or not.
	Workload : { name : Str, test : Str, kind : Str, title : Str, summary : Str, protocol : Str, connections : I64, streams : I64, keepalive : Bool, http2 : Bool, tls : Bool }
	ServerClass : { name : Str, label : Str, title : Str }
	Machine : { role : Str, class : Str, size : Str, cpu : Str, cpus : U32, kernel : Str, memory_mib : U32 }
	Fingerprint : { dragrace : Str, fourneau : Str, roux : Str }
	Pinned : { version : Str }

	Versions : {
		fourneau : { repository : Str },
		roux : { repository : Str },
		zig : Pinned,
		roc : Pinned,
		oha : Pinned,
		go : Pinned,
		rust : Pinned,
		axum : Pinned,
		tokio : Pinned,
		## "" before 2026-10-26, when no race recorded it.
		basic_webserver : Pinned,
		droplet_image : Str,
	}

	Race : {
		competitors : List(Str),
		workloads : List(Workload),
		cloud : { servers : List(ServerClass) },
	}

	Run : {
		id : Str,
		started_at : Str,
		fingerprint : Fingerprint,
		versions : Versions,
		race : Race,
		machines : List(Machine),
		results : List(Result),
		timing : { seconds : F64, cost_usd : F64 },
	}

	Summary : { class : Str, workload : Str, competitor : Str, valid : Bool, best_rps : F64 }
	Entry : { id : Str, started_at : Str, results : List(Summary) }

	run : Str -> Try(Run, [BadData(Str)])
	run = |text|
		match Json.parse(text) {
			Ok(parsed) => Ok(parsed)
			Err(err) => Err(BadData(Str.inspect(err)))
		}

	index : Str -> Try(List(Entry), [BadData(Str)])
	index = |text|
		match Json.parse(text) {
			Ok(parsed) => Ok(parsed)
			Err(err) => Err(BadData(Str.inspect(err)))
		}
}

import "test/latest.json" as latest_sample : Str
import "test/index.json" as index_sample : Str

expect
	match Data.run(latest_sample) {
		Ok(parsed) => parsed.id == "2026-10-06T135849Z-cloud" and List.len(parsed.results) == 32
		Err(_) => Bool.False
	}

expect
	match Data.index(index_sample) {
		Ok(entries) => List.len(entries) == 1
		Err(_) => Bool.False
	}

expect
	match Data.run("{\"id\": 3}") {
		Ok(_) => Bool.False
		Err(BadData(_)) => Bool.True
	}
