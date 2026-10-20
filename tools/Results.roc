import Text

## A race's results: each competitor on each workload on each server class,
## its rounds as measured and, on a mixed workload, its open-loop climb.
## The fields are the site's (site/Api.roc, ResultPost), which the workers
## post and the racer posts again; a race's results file holds them too.
Results :: [].{
	## One measured run.
	Round : {
		rps : F64,
		p50_ms : F64,
		p90_ms : F64,
		p95_ms : F64,
		p99_ms : F64,
		p999_ms : F64,
		p9999_ms : F64,
		mean_ms : F64,
		max_ms : F64,
		first_byte_p50_ms : F64,
		first_byte_p99_ms : F64,
		success_rate : F64,
		errors : I64,
		non_2xx : I64,
		rps_per_second_stddev : F64,
		connect_mean_ms : F64,
		bytes_per_response : F64,
		cpu_busy_pct : F64,
		cpu_user_pct : F64,
		cpu_system_pct : F64,
		cpu_irq_pct : F64,
		cpu_softirq_pct : F64,
		steal_pct : F64,
		loader_cpu_busy_pct : F64,
		rss_kib : I64,
		net_rx_mbps : F64,
		net_tx_mbps : F64,
		net_rx_pps : F64,
		net_tx_pps : F64,
		tcp_retransmits : I64,
		threads : I64,
		voluntary_switches : I64,
		involuntary_switches : I64,
		load_seconds : F64,
		seconds : F64,
	}

	## One rate of a mixed workload's climb.
	Step : {
		offered_rps : F64,
		achieved_rps : F64,
		p50_ms : F64,
		p99_ms : F64,
		p999_ms : F64,
		errors : I64,
		non_2xx : I64,
		cpu_busy_pct : F64,
		loader_cpu_busy_pct : F64,
		net_rx_mbps : F64,
		net_tx_mbps : F64,
		mean_ms : F64,
		parts : List(Part),
	}

	## One part of a mixed step.
	Part : { name : Str, offered_rps : F64, achieved_rps : F64, mean_ms : F64, p50_ms : F64, p99_ms : F64, p999_ms : F64, errors : I64, non_2xx : I64 }

	## One competitor on one workload on one class.
	Result : {
		class : Str,
		workload : Str,
		competitor : Str,
		valid : Bool,
		note : Str,
		rounds : List(Round),
		open_loop : List(Step),
	}

	## A result with nothing measured yet.
	empty : Str, Str, Str -> Result
	empty = |class, workload, competitor| { class, workload, competitor, valid: Bool.False, note: "", rounds: [], open_loop: [] }

	## A round with nothing in it, for building one from parts.
	zero_round : Round
	zero_round = {
		rps: 0, p50_ms: 0, p90_ms: 0, p95_ms: 0, p99_ms: 0, p999_ms: 0, p9999_ms: 0, mean_ms: 0, max_ms: 0,
		first_byte_p50_ms: 0, first_byte_p99_ms: 0, success_rate: 0, errors: 0, non_2xx: 0,
		rps_per_second_stddev: 0, connect_mean_ms: 0, bytes_per_response: 0, cpu_busy_pct: 0,
		cpu_user_pct: 0, cpu_system_pct: 0, cpu_irq_pct: 0, cpu_softirq_pct: 0, steal_pct: 0,
		loader_cpu_busy_pct: 0, rss_kib: 0, net_rx_mbps: 0, net_tx_mbps: 0, net_rx_pps: 0, net_tx_pps: 0,
		tcp_retransmits: 0, threads: 0, voluntary_switches: 0, involuntary_switches: 0, load_seconds: 0, seconds: 0,
	}

	## The rounds summarized as the site does (Data.Result): the best
	## round's rate, as a benchmark takes the fastest of its repeats, and
	## each latency percentile the median of the rounds that answered.
	Summary : { best_rps : F64, median_p50_ms : F64, median_p95_ms : F64, median_p99_ms : F64, median_p999_ms : F64 }

	summarize : List(Round) -> Summary
	summarize = |rounds| {
		best_rps = rounds.fold(0.0, |best, r| if r.rps > best r.rps else best)
		answered = rounds.keep_if(|r| r.rps > 0)
		if answered.is_empty() {
			return { best_rps, median_p50_ms: 0, median_p95_ms: 0, median_p99_ms: 0, median_p999_ms: 0 }
		}
		of = |field| Results.median(answered.map(field))
		{
			best_rps,
			median_p50_ms: of(|r| r.p50_ms),
			median_p95_ms: of(|r| r.p95_ms),
			median_p99_ms: of(|r| r.p99_ms),
			median_p999_ms: of(|r| r.p999_ms),
		}
	}

	median : List(F64) -> F64
	median = |values| {
		sorted = values.sort_with(|a, b| if a < b Before else if a > b After else Same)
		middle = sorted.len() // 2
		if sorted.len() % 2 == 1 {
			sorted.get(middle) ?? 0
		} else {
			((sorted.get(middle - 1) ?? 0) + (sorted.get(middle) ?? 0)) / 2
		}
	}

	## A result as JSON, its summary with it, as the results file and the
	## racer's file keep it (the site takes the same, its summary ignored).
	to_json : Result -> Try(Str, [Failed(Str)])
	to_json = |result| {
		summary = Results.summarize(result.rounds)
		whole = {
			class: result.class,
			workload: result.workload,
			competitor: result.competitor,
			valid: result.valid,
			note: result.note,
			rounds: result.rounds,
			open_loop: result.open_loop,
			best_rps: summary.best_rps,
			median_p50_ms: summary.median_p50_ms,
			median_p95_ms: summary.median_p95_ms,
			median_p99_ms: summary.median_p99_ms,
			median_p999_ms: summary.median_p999_ms,
		}
		Json.to_str_try(whole).map_err(|_| Failed("a result of ${result.competitor} ${result.workload}: a number JSON cannot hold (NaN or infinite)"))
	}

	## Results read back from their JSON: the racer's, from a worker's file.
	parse_list : Str -> Try(List(Result), [Failed(Str)])
	parse_list = |text| {
		parsed : Try(List(Result), _)
		parsed = Json.parse(text)
		parsed.map_err(|_| Failed("results: not a list of results"))
	}

	## The results as a table: the best round's rate and the median p99, or,
	## for a mixed workload, its top step.
	table : List(Result) -> Str
	table = |results|
		Str.join_with(
			results.map(
				|r| {
					mark = if r.valid "" else "  INVALID: ${r.note}"
					head = "${Text.pad_right(r.class, 12)} ${Text.pad_right(r.workload, 10)} ${Text.pad_right(r.competitor, 14)}"
					match (r.rounds, r.open_loop.last()) {
						([], Ok(top)) => "${head} ${Text.pad_left(Text.fixed(top.achieved_rps, 0), 12)} req/s  mean ${Text.pad_left(Text.fixed(top.mean_ms, 2), 6)} ms at ${Text.fixed(top.offered_rps, 0)}/s offered${mark}\n"
						_ => {
							s = Results.summarize(r.rounds)
							"${head} ${Text.pad_left(Text.fixed(s.best_rps, 0), 12)} req/s  p99 ${Text.pad_left(Text.fixed(s.median_p99_ms, 2), 7)} ms${mark}\n"
						}
					}
				},
			),
			"",
		)

	## A smoke race's verdict: every result that is not valid, named.
	invalid : List(Result) -> Try({}, [Failed(Str)])
	invalid = |results| {
		bad = results.keep_if(|r| !r.valid).map(|r| "${r.competitor} ${r.workload}: ${r.note}")
		if bad.is_empty() Ok({}) else Err(Failed("${bad.len().to_str()} results not valid:\n  ${Str.join_with(bad, "\n  ")}"))
	}
}

round_of : F64, F64 -> Results.Round
round_of = |rps, p99| { ..Results.zero_round, rps, p99_ms: p99 }

expect Results.median([3, 1, 2]) == 2
expect Results.median([4, 1, 2, 3]) == 2.5

expect {
	s = Results.summarize([round_of(100, 5), round_of(0, 0), round_of(300, 7), round_of(200, 9)])
	s.best_rps == 300 and s.median_p99_ms == 7
}

expect Results.summarize([]).best_rps == 0

expect {
	r = { ..Results.empty("local", "plaintext", "go"), valid: Bool.True, rounds: [round_of(1234.4, 1.234)] }
	match Results.to_json(r) {
		Ok(text) =>
			match Results.parse_list("[${text}]") {
				Ok([back]) => back.rounds == r.rounds and back.competitor == "go"
				_ => Bool.False
			}
		Err(_) => Bool.False
	}
}

expect Results.invalid([{ ..Results.empty("c", "w", "x"), note: "why" }]) == Err(Failed("1 results not valid:\n  x w: why"))
