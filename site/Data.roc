## The races, as the dragrace tool publishes them (data/latest.json, the
## newest run whole; data/index.json, every run's medians). Only the
## fields the pages show; the rest of the JSON is ignored.
Data :: [].{
	Round : { rps : F64, p99_ms : F64, cpu_busy_pct : F64, steal_pct : F64, rss_kib : F64, loader_cpu_busy_pct : F64, net_rx_mbps : F64, net_tx_mbps : F64, tcp_retransmits : F64, load_seconds : F64 }

	Result : {
		class : Str,
		workload : Str,
		competitor : Str,
		valid : Bool,
		note : Str,
		rounds : List(Round),
		median_rps : F64,
		median_p95_ms : F64,
		median_p99_ms : F64,
		median_p999_ms : F64,
		open_loop : List(OpenStep),
	}

	## One rate of the open-loop ladder: the offered rate, what was answered
	## (2xx), latency from when each request was due, and both machines' CPU.
	OpenStep : {
		share : F64,
		offered_rps : F64,
		achieved_rps : F64,
		p99_ms : F64,
		p999_ms : F64,
		cpu_busy_pct : F64,
		loader_cpu_busy_pct : F64,
	}

	Workload : { name : Str, title : Str, summary : Str }
	ServerClass : { name : Str, label : Str, title : Str }
	Machine : { role : Str, class : Str, size : Str, cpu : Str, cpus : U32, kernel : Str, cpu_wanted : Str, cpu_matched : Bool, attempts : U32 }
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

	Summary : { class : Str, workload : Str, competitor : Str, valid : Bool, median_rps : F64 }
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
		Ok(entries) => List.len(entries) == 2
		Err(_) => Bool.False
	}

expect
	match Data.run("{\"id\": 3}") {
		Ok(_) => Bool.False
		Err(BadData(_)) => Bool.True
	}
