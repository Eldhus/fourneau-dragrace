import pf.Server
import pf.Sqlite
import db/Requests
import db/Runs
import db/Results
import db/Heads
import db/Pages
import db/Health
import db/Visits

## The site's API: what the racer
## and the race workers post, and what the owner asks. Every post is safe
## to repeat: a run, a result, a class or a machine posted again replaces
## itself, so a worker retrying through a deploy changes nothing twice.
## An answer is JSON; a refusal says why in its text.
Api :: [].{
	## The site's secrets, read at start (`init!`): "" for one not set, which
	## then opens nothing.
	Tokens : { racer : Str, manual : Str }

	## Who a request is, by its token.
	Caller : [Racer, Owner, Worker, Nobody]

	## A run as the racer posts it: made (racing), skipped or refused.
	RunPost : {
		id : Str,
		## 0: no request (a run made by hand).
		request_id : I64,
		trigger : Str,
		status : Str,
		reason : Str,
		where_raced : Str,
		started_at : Str,
		## "": none (a run that does not race).
		worker_token : Str,
		commits : List({ repository : Str, commit_sha : Str, new : Bool }),
		## race.json and the versions as raced; a run that does not race has
		## none.
		race : Try(RacePost, [Missing]),
	}

	RacePost : {
		seed : I64,
		region : Str,
		image : Str,
		port : I64,
		rounds : I64,
		warmup_seconds : I64,
		measure_seconds : I64,
		race_json : Str,
		versions : List({ name : Str, version : Str }),
		competitors : List({ name : Str, title : Str, language : Str, framework : Str }),
		workloads : List(WorkloadPost),
		classes : List({ name : Str, label : Str, title : Str, size : Str, loader_size : Str }),
	}

	WorkloadPost : {
		name : Str,
		## The test it is a variant of (race.json's workload).
		test : Str,
		kind : Str,
		title : Str,
		summary : Str,
		method : Str,
		path : Str,
		body_bytes : I64,
		content_type : Str,
		connections : I64,
		keepalive : Bool,
		## HTTP/2 (`streams` a connection; 0 for HTTP/1.1), over TLS or not;
		## the variant's protocol ("http1", "h2c", "tls").
		http2 : Bool,
		streams : I64,
		tls : Bool,
		protocol : Str,
	}

	## A run's end: its status, and its timing and droplets (timing.go).
	EndPost : {
		status : Str,
		reason : Str,
		finished_at : Str,
		timing : {
			seconds : F64,
			build_seconds : F64,
			launch_seconds : F64,
			racing_seconds : F64,
			cost_usd : F64,
			droplets : List({ role : Str, class : Str, size : Str, price_hourly : F64, seconds : F64, cost_usd : F64 }),
		},
	}

	## A machine, as results.go's MachineInfo.
	MachinePost : {
		role : Str,
		class : Str,
		size : Str,
		cpu : Str,
		cpus : I64,
		kernel : Str,
		cpu_id : Str,
		memory_mib : I64,
	}

	## A result, as results.go's Result: the rounds and open-loop steps whole.
	## The racer's own summary of the rounds (`best_rps`, `median_*_ms`) is
	## not read: the pages take theirs from the rounds.
	ResultPost : {
		class : Str,
		workload : Str,
		competitor : Str,
		valid : Bool,
		note : Str,
		rounds : List(RoundPost),
		open_loop : List(StepPost),
	}

	RoundPost : {
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

	## A step of a mixed workload's climb (mixed.go, OpenStep).
	StepPost : {
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
		parts : List(PartPost),
	}

	## One part of a mixed step (mixed.go, OpenPart).
	PartPost : {
		name : Str,
		offered_rps : F64,
		achieved_rps : F64,
		mean_ms : F64,
		p50_ms : F64,
		p99_ms : F64,
		p999_ms : F64,
		errors : I64,
		non_2xx : I64,
	}

	ClassPost : { status : Str, reason : Str, seconds : F64 }

	## A class's plan and the step begun, 1 for the first, 0 for none yet
	## (the worker's StepsPost, race.go's Step).
	StepsPost : {
		step : I64,
		steps : List({ competitor : Str, round : I64, workload : Str, planned_seconds : F64 }),
	}

	HeadPost : { repository : Str, commit_sha : Str }

	## The largest body taken: a run with race.json is some 20 KiB, a result
	## with its rounds a few.
	body_bytes_max : U64
	body_bytes_max = 1024 * 1024

	## Lists in a body, at most (competitors, workloads, rounds, steps, ...).
	items_max : U64
	items_max = 256

	## Copies of the database kept (`Sqlite.backup!`): a month of nights.
	backups_kept : U32
	backups_kept = 30

	## Answers a request under /api/.
	respond! : Server.Request, Sqlite.Db, Tokens, Str => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	respond! = |request, db, tokens, path| {
		caller = caller_of(request, tokens)
		parts = path.split_on("/")
		match (request.method, parts) {
			("GET", ["", "api", "health"]) => health!(db, request)
			("POST", ["", "api", "requests"]) => ask!(db, request, caller)
			("GET", ["", "api", "racer", "next"]) =>
				if caller == Racer next!(db, request) else Ok(refused(401, "the racer's token"))
			("POST", ["", "api", "heads"]) =>
				if caller == Racer heads!(db, request) else Ok(refused(401, "the racer's token"))
			("POST", ["", "api", "runs"]) =>
				if caller == Racer add_run!(db, request) else Ok(refused(401, "the racer's token"))
			("POST", ["", "api", "runs", id, "end"]) =>
				if caller == Racer end_run!(db, request, id) else Ok(refused(401, "the racer's token"))
			("POST", ["", "api", "runs", id, "results"]) => for_run!(db, request, tokens, id, add_result!)
			("POST", ["", "api", "runs", id, "machines"]) => for_run!(db, request, tokens, id, add_machines!)
			("POST", ["", "api", "runs", id, "classes", class]) =>
				for_run!(db, request, tokens, id, |d, r, run_id| set_class!(d, r, run_id, class))
			("POST", ["", "api", "runs", id, "classes", class, "steps"]) =>
				for_run!(db, request, tokens, id, |d, r, run_id| begin_step!(d, r, run_id, class))
			("POST", ["", "api", "backup"]) =>
				if caller == Racer backup!(db, request) else Ok(refused(401, "the racer's token"))
			("GET", ["", "api", "visits"]) =>
				if caller == Owner visits!(db, request) else Ok(refused(401, "the manual token"))
			_ => Ok(refused(404, "no such API route"))
		}
	}

	## The last two weeks' visits, a line a row, tab-separated: day, page,
	## referring site ("-" for none), kind, count.
	visits! : Sqlite.Db, Server.Request => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	visits! = |db, request| {
		rows = Visits.recent!(Sqlite.read(db, request))?
		lines = rows.map(|row| {
			from = if row.referrer == "" "-" else row.referrer
			"${row.day}\t${row.path}\t${from}\t${row.kind}\t${row.count.to_str()}\n"
		})
		Ok({ status: 200, headers: [{ name: "Content-Type", value: "text/plain; charset=utf-8" }], body: Text(Str.join_with(lines, "")) })
	}

	## The racer or the owner, by the bearer token; a run's worker is told
	## apart per run (`for_run!`).
	caller_of : Server.Request, Tokens -> Caller
	caller_of = |request, tokens|
		match bearer(request) {
			Ok(given) =>
				if same_secret(given, tokens.racer) {
					Racer
				} else if same_secret(given, tokens.manual) {
					Owner
				} else {
					Nobody
				}
			Err(_) => Nobody
		}

	bearer : Server.Request -> Try(Str, [NotFound])
	bearer = |request|
		match Server.header(request, "authorization") {
			Ok(value) =>
				match value.split_first("Bearer ") {
					Ok({ before: "", after }) => Ok(after)
					_ => Err(NotFound)
				}
			Err(_) => Err(NotFound)
		}

	## Whether `given` is the secret, in time that does not depend on where
	## they differ. A secret under 32 bytes (or none, "") matches nothing.
	same_secret : Str, Str -> Bool
	same_secret = |given, secret| {
		a = Str.to_utf8(given)
		b = Str.to_utf8(secret)
		if b.len() < 32 or a.len() != b.len() {
			Bool.False
		} else {
			difference = List.map2(a, b, |x, y| U8.bitwise_xor(x, y)).fold(0.U8, |acc, d| U8.bitwise_or(acc, d))
			difference == 0
		}
	}

	# --- the racer and the owner ---------------------------------------------

	health! : Sqlite.Db, Server.Request => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	health! = |db, request|
		match Health.ping!(Sqlite.read(db, request)) {
			Ok(_) => Ok(answer("{\"ok\":true}"))
			Err(NotFound) => Ok(refused(500, "the database answered nothing"))
			Err(DbErr(err)) => Err(DbErr(err))
		}

	## A check (race only if something is new) or a race. The owner may ask
	## either; the racer's timer asks checks. One of a kind waiting is
	## enough: asking again changes nothing.
	ask! : Sqlite.Db, Server.Request, Caller => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	ask! = |db, request, caller| {
		kind = query_value(request.target, "kind")
		asked_by =
			match (caller, kind) {
				(Owner, "race") | (Owner, "check") => Ok("owner")
				(Racer, "check") => Ok("timer")
				(Owner, _) | (Racer, _) => Err(BadKind)
				_ => Err(Unknown)
			}
		match asked_by {
			Err(Unknown) => Ok(refused(401, "the manual or the racer's token"))
			Err(BadKind) => Ok(refused(400, "kind: race or check (the racer: check)"))
			Ok(by) => {
				waiting = Requests.waiting!(Sqlite.read(db, request))?
				match waiting.find_first(|w| w.kind == kind) {
					Ok(already) => Ok(answer("{\"id\":${already.id.to_str()},\"already\":true}"))
					Err(_) => {
						tx = Sqlite.write!(db, request)?
						added =
							match Requests.add!(tx, { kind, asked_by: by }) {
								Ok(row) => row
								Err(NotFound) => crash "INSERT ... RETURNING gave no row"
								Err(DbErr(err)) => return Err(DbErr(err))
							}
						Sqlite.commit!(tx)?
						Ok({ status: 201, headers: json_headers, body: Text("{\"id\":${added.id.to_str()},\"already\":false}") })
					}
				}
			}
		}
	}

	## What the racer should do: the requests waiting, oldest first, and the
	## commits of the last finished run (a check races what differs).
	next! : Sqlite.Db, Server.Request => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	next! = |db, request| {
		reads = Sqlite.read(db, request)
		waiting = Requests.waiting!(reads)?
		raced =
			match Pages.latest!(reads) {
				Ok({ id }) => Pages.commits!(reads, { run_id: id })?.map(|c| { repository: c.repository, commit_sha: c.commit_sha })
				Err(NotFound) => []
				Err(DbErr(err)) => return Err(DbErr(err))
			}
		Ok(answer(Json.to_str({ waiting, raced })))
	}

	heads! : Sqlite.Db, Server.Request => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	heads! = |db, request| {
		parsed : Try(List(HeadPost), _)
		parsed = body!(request) |> and_parse
		match parsed {
			Err(Refused(response)) => Ok(response)
			Ok(heads) => {
				tx = Sqlite.write!(db, request)?
				for head in heads.take_first(8) {
					match Heads.set!(tx, head) {
						Ok({}) => {}
						Err(DbErr(Constraint(why))) => return Ok(refused(400, why))
						Err(DbErr(err)) => return Err(DbErr(err))
					}
				}
				Sqlite.commit!(tx)?
				Ok(answer("{\"ok\":true}"))
			}
		}
	}

	## A run made: the run, its commits and, if it races, its settings, in
	## one transaction, taking its request.
	add_run! : Sqlite.Db, Server.Request => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	add_run! = |db, request| {
		parsed : Try(RunPost, _)
		parsed = body!(request) |> and_parse
		match parsed {
			Err(Refused(response)) => Ok(response)
			Ok(run) =>
				if !is_name(run.id) {
					Ok(refused(400, "a run's id is letters, digits and dashes"))
				} else {
					tx = Sqlite.write!(db, request)?
					match write_run!(tx, run) {
						Ok({}) => {
							Sqlite.commit!(tx)?
							Ok(answer("{\"ok\":true}"))
						}
						Err(DbErr(Constraint(why))) => Ok(refused(400, why))
						Err(DbErr(err)) => Err(DbErr(err))
					}
				}
		}
	}

	write_run! : Sqlite.Write, RunPost => Try({}, [DbErr(Sqlite.Err)])
	write_run! = |tx, run| {
		Runs.add!(tx, {
			id: run.id,
			request_id: if run.request_id > 0 NotNull(run.request_id) else Null,
			trigger: run.trigger,
			status: run.status,
			reason: run.reason,
			where_raced: run.where_raced,
			started_at: run.started_at,
			worker_token: if run.worker_token.is_empty() Null else NotNull(run.worker_token),
		})?
		if run.request_id > 0 {
			Requests.take!(tx, { id: run.request_id })?
		}
		for commit in run.commits.take_first(8) {
			Runs.add_commit!(tx, { run_id: run.id, repository: commit.repository, commit_sha: commit.commit_sha, new: commit.new })?
		}
		match run.race {
			Ok(race) => write_race!(tx, run.id, race)
			Err(Missing) => Ok({})
		}
	}

	write_race! : Sqlite.Write, Str, RacePost => Try({}, [DbErr(Sqlite.Err)])
	write_race! = |tx, run_id, race| {
		Runs.add_settings!(tx, {
			run_id,
			seed: race.seed,
			region: race.region,
			image: race.image,
			port: race.port,
			rounds: race.rounds,
			warmup_seconds: race.warmup_seconds,
			measure_seconds: race.measure_seconds,
			race_json: race.race_json,
		})?
		for version in race.versions.take_first(items_max) {
			Runs.add_version!(tx, { run_id, name: version.name, version: version.version })?
		}
		var $position = 0.I64
		for c in race.competitors.take_first(items_max) {
			Runs.add_competitor!(tx, { run_id, name: c.name, position: $position, title: c.title, language: c.language, framework: c.framework })?
			$position = $position + 1
		}
		$position = 0
		for w in race.workloads.take_first(items_max) {
			Runs.add_workload!(tx, {
				run_id,
				name: w.name,
				test: w.test,
				position: $position,
				kind: w.kind,
				title: w.title,
				summary: w.summary,
				method: w.method,
				path: w.path,
				body_bytes: w.body_bytes,
				content_type: w.content_type,
				connections: w.connections,
				keepalive: w.keepalive,
				http2: w.http2,
				streams: w.streams,
				tls: w.tls,
				protocol: w.protocol,
			})?
			$position = $position + 1
		}
		$position = 0
		for c in race.classes.take_first(items_max) {
			Runs.add_class!(tx, { run_id, name: c.name, position: $position, label: c.label, title: c.title, size: c.size, loader_size: c.loader_size })?
			$position = $position + 1
		}
		Ok({})
	}

	## A run over: its status, timing and droplets; its worker token goes.
	end_run! : Sqlite.Db, Server.Request, Str => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	end_run! = |db, request, run_id| {
		parsed : Try(EndPost, _)
		parsed = body!(request) |> and_parse
		match parsed {
			Err(Refused(response)) => Ok(response)
			Ok(end) => {
				tx = Sqlite.write!(db, request)?
				match write_end!(tx, run_id, end) {
					Ok({}) => {
						Sqlite.commit!(tx)?
						Ok(answer("{\"ok\":true}"))
					}
					Err(DbErr(Constraint(why))) => Ok(refused(400, why))
					Err(DbErr(err)) => Err(DbErr(err))
				}
			}
		}
	}

	write_end! : Sqlite.Write, Str, EndPost => Try({}, [DbErr(Sqlite.Err)])
	write_end! = |tx, run_id, end| {
		timing = end.timing
		Runs.end!(tx, {
			id: run_id,
			status: end.status,
			reason: end.reason,
			finished_at: end.finished_at,
			seconds: timing.seconds,
			build_seconds: timing.build_seconds,
			launch_seconds: timing.launch_seconds,
			racing_seconds: timing.racing_seconds,
			cost_usd: timing.cost_usd,
		})?
		var $position = 0.I64
		for d in timing.droplets.take_first(items_max) {
			Runs.add_droplet!(tx, { run_id, position: $position, role: d.role, class: d.class, size: d.size, price_hourly: d.price_hourly, seconds: d.seconds, cost_usd: d.cost_usd })?
			$position = $position + 1
		}
		Ok({})
	}

	## A copy of the database in backups/ (the racer asks after each run).
	backup! : Sqlite.Db, Server.Request => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	backup! = |db, request| {
		name = Sqlite.backup!(db, request, { directory: "backups", keep: backups_kept })?
		Ok(answer(Json.to_str({ backup: name })))
	}

	# --- a run's workers --------------------------------------------------------

	## A post for one run: from the racer, or from the run's worker while it
	## races (its token is the run's).
	for_run! : Sqlite.Db, Server.Request, Tokens, Str, (Sqlite.Db, Server.Request, Str => Try(Server.Response(t), [DbErr(Sqlite.Err)])) => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	for_run! = |db, request, tokens, run_id, post!| {
		given = bearer(request) ?? ""
		if same_secret(given, tokens.racer) {
			post!(db, request, run_id)
		} else {
			match Runs.access!(Sqlite.read(db, request), { id: run_id }) {
				Ok({ status: "racing", worker_token: NotNull(token) }) =>
					if same_secret(given, token) post!(db, request, run_id) else Ok(refused(401, "the run's worker token"))
				Ok(_) => Ok(refused(409, "the run is not racing"))
				Err(NotFound) => Ok(refused(404, "no run ${run_id}"))
				Err(DbErr(err)) => Err(DbErr(err))
			}
		}
	}

	## One result, replacing what the run held for it.
	add_result! : Sqlite.Db, Server.Request, Str => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	add_result! = |db, request, run_id| {
		parsed : Try(ResultPost, _)
		parsed = body!(request) |> and_parse
		match parsed {
			Err(Refused(response)) => Ok(response)
			Ok(result) => {
				tx = Sqlite.write!(db, request)?
				match write_result!(tx, run_id, result) {
					Ok({}) => {
						Sqlite.commit!(tx)?
						Ok(answer("{\"ok\":true}"))
					}
					Err(DbErr(Constraint(why))) => Ok(refused(400, why))
					Err(DbErr(err)) => Err(DbErr(err))
				}
			}
		}
	}

	write_result! : Sqlite.Write, Str, ResultPost => Try({}, [DbErr(Sqlite.Err)])
	write_result! = |tx, run_id, r| {
		key = { run_id, class: r.class, workload: r.workload, competitor: r.competitor }
		Results.set!(tx, {
			run_id,
			class: r.class,
			workload: r.workload,
			competitor: r.competitor,
			valid: r.valid,
			note: r.note,
		})?
		Results.clear_rounds!(tx, key)?
		Results.clear_parts!(tx, key)?
		Results.clear_steps!(tx, key)?
		var $index = 0.I64
		for round in r.rounds.take_first(items_max) {
			Results.add_round!(tx, round_row(key, $index, round))?
			$index = $index + 1
		}
		$index = 0
		for step in r.open_loop.take_first(items_max) {
			Results.add_step!(tx, {
				run_id,
				class: r.class,
				workload: r.workload,
				competitor: r.competitor,
				step: $index,
				offered_rps: step.offered_rps,
				achieved_rps: step.achieved_rps,
				p50_ms: step.p50_ms,
				p99_ms: step.p99_ms,
				p999_ms: step.p999_ms,
				errors: step.errors,
				non_2xx: step.non_2xx,
				cpu_busy_pct: step.cpu_busy_pct,
				loader_cpu_busy_pct: step.loader_cpu_busy_pct,
				net_rx_mbps: step.net_rx_mbps,
				net_tx_mbps: step.net_tx_mbps,
				mean_ms: step.mean_ms,
			})?
			for part in step.parts.take_first(16) {
				Results.add_part!(tx, {
					run_id,
					class: r.class,
					workload: r.workload,
					competitor: r.competitor,
					step: $index,
					part: part.name,
					offered_rps: part.offered_rps,
					achieved_rps: part.achieved_rps,
					mean_ms: part.mean_ms,
					p50_ms: part.p50_ms,
					p99_ms: part.p99_ms,
					p999_ms: part.p999_ms,
					errors: part.errors,
					non_2xx: part.non_2xx,
				})?
			}
			$index = $index + 1
		}
		Ok({})
	}

	round_row = |key, index, round| {
		run_id: key.run_id,
		class: key.class,
		workload: key.workload,
		competitor: key.competitor,
		round: index,
		rps: round.rps,
		p50_ms: round.p50_ms,
		p90_ms: round.p90_ms,
		p95_ms: round.p95_ms,
		p99_ms: round.p99_ms,
		p999_ms: round.p999_ms,
		p9999_ms: round.p9999_ms,
		mean_ms: round.mean_ms,
		max_ms: round.max_ms,
		first_byte_p50_ms: round.first_byte_p50_ms,
		first_byte_p99_ms: round.first_byte_p99_ms,
		success_rate: round.success_rate,
		errors: round.errors,
		non_2xx: round.non_2xx,
		rps_per_second_stddev: round.rps_per_second_stddev,
		connect_mean_ms: round.connect_mean_ms,
		bytes_per_response: round.bytes_per_response,
		cpu_busy_pct: round.cpu_busy_pct,
		cpu_user_pct: round.cpu_user_pct,
		cpu_system_pct: round.cpu_system_pct,
		cpu_irq_pct: round.cpu_irq_pct,
		cpu_softirq_pct: round.cpu_softirq_pct,
		steal_pct: round.steal_pct,
		loader_cpu_busy_pct: round.loader_cpu_busy_pct,
		rss_kib: round.rss_kib,
		net_rx_mbps: round.net_rx_mbps,
		net_tx_mbps: round.net_tx_mbps,
		net_rx_pps: round.net_rx_pps,
		net_tx_pps: round.net_tx_pps,
		tcp_retransmits: round.tcp_retransmits,
		threads: round.threads,
		voluntary_switches: round.voluntary_switches,
		involuntary_switches: round.involuntary_switches,
		load_seconds: round.load_seconds,
		seconds: round.seconds,
	}

	## A class's machines (its server and its loader).
	add_machines! : Sqlite.Db, Server.Request, Str => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	add_machines! = |db, request, run_id| {
		parsed : Try(List(MachinePost), _)
		parsed = body!(request) |> and_parse
		match parsed {
			Err(Refused(response)) => Ok(response)
			Ok(machines) => {
				tx = Sqlite.write!(db, request)?
				for m in machines.take_first(8) {
					written = Runs.set_machine!(tx, {
						run_id,
						class: m.class,
						role: m.role,
						size: m.size,
						cpu: m.cpu,
						cpus: m.cpus,
						kernel: m.kernel,
						cpu_id: m.cpu_id,
						memory_mib: m.memory_mib,
					})
					match written {
						Ok({}) => {}
						Err(DbErr(Constraint(why))) => return Ok(refused(400, why))
						Err(DbErr(err)) => return Err(DbErr(err))
					}
				}
				Sqlite.commit!(tx)?
				Ok(answer("{\"ok\":true}"))
			}
		}
	}

	set_class! : Sqlite.Db, Server.Request, Str, Str => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	set_class! = |db, request, run_id, class| {
		parsed : Try(ClassPost, _)
		parsed = body!(request) |> and_parse
		match parsed {
			Err(Refused(response)) => Ok(response)
			Ok(post) => {
				tx = Sqlite.write!(db, request)?
				match Runs.set_class!(tx, { run_id, class, status: post.status, reason: post.reason, seconds: post.seconds }) {
					Ok({}) => {
						Sqlite.commit!(tx)?
						Ok(answer("{\"ok\":true}"))
					}
					Err(DbErr(Constraint(why))) => Ok(refused(400, why))
					Err(DbErr(err)) => Err(DbErr(err))
				}
			}
		}
	}

	## A class's plan, and the step begun now (the live banner's).
	begin_step! : Sqlite.Db, Server.Request, Str, Str => Try(Server.Response(t), [DbErr(Sqlite.Err)])
	begin_step! = |db, request, run_id, class| {
		parsed : Try(StepsPost, _)
		parsed = body!(request) |> and_parse
		match parsed {
			Err(Refused(response)) => Ok(response)
			Ok(post) =>
				if post.steps.len() > items_max {
					Ok(refused(400, "more than ${items_max.to_str()} steps"))
				} else if post.step < 0 or post.step > post.steps.len().to_i64_wrap() {
					Ok(refused(400, "step ${post.step.to_str()} is not in the plan"))
				} else {
					tx = Sqlite.write!(db, request)?
					var $number = 0
					for s in post.steps {
						$number = $number + 1
						written = Runs.set_step!(tx, {
							run_id,
							class,
							step: $number,
							competitor: s.competitor,
							round: s.round,
							workload: s.workload,
							planned_seconds: s.planned_seconds,
						})
						match written {
							Ok({}) => {}
							Err(DbErr(Constraint(why))) => return Ok(refused(400, why))
							Err(DbErr(err)) => return Err(DbErr(err))
						}
					}
					if post.step > 0 {
						Runs.begin_step!(tx, { run_id, class, step: post.step })?
					}
					Sqlite.commit!(tx)?
					Ok(answer("{\"ok\":true}"))
				}
		}
	}

	# --- bodies and answers -----------------------------------------------------

	## The body as text, or the answer refusing it.
	body! : Server.Request => Try(Str, [Refused(Server.Response(t))])
	body! = |request|
		match Server.read_body!(request, body_bytes_max) {
			Ok(bytes) =>
				match Str.from_utf8(bytes) {
					Ok(text) => Ok(text)
					Err(_) => Err(Refused(refused(400, "the body is not UTF-8")))
				}
			Err(BodyErr(err)) => Err(Refused(refused(400, "the body: ${Str.inspect(err)}")))
		}

	and_parse = |text_or|
		match text_or {
			Ok(text) =>
				match Json.parse(text) {
					Ok(parsed) => Ok(parsed)
					Err(err) => Err(Refused(refused(400, "the body: ${Str.inspect(err)}")))
				}
			Err(Refused(response)) => Err(Refused(response))
		}

	json_headers : List({ name : Str, value : Str })
	json_headers = [{ name: "Content-Type", value: "application/json" }]

	answer : Str -> Server.Response(t)
	answer = |json| { status: 200, headers: json_headers, body: Text(json) }

	refused : U16, Str -> Server.Response(t)
	refused = |status, why| {
		status,
		headers: [{ name: "Content-Type", value: "text/plain; charset=utf-8" }],
		body: Text("${why}\n"),
	}

	is_name : Str -> Bool
	is_name = |name| {
		bytes = Str.to_utf8(name)
		!bytes.is_empty() and bytes.len() <= 64 and bytes.all(|b| (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45)
	}

	## A query parameter's value, or "".
	query_value : Str, Str -> Str
	query_value = |target, key|
		match target.split_first("?") {
			Ok(parts) => {
				found = Str.split_on(parts.after, "&").keep_oks(|pair|
					match pair.split_first("=") {
						Ok(kv) => if kv.before == key Ok(kv.after) else Err(NotIt)
						Err(_) => Err(NotIt)
					})
				List.first(found) ?? ""
			}
			Err(_) => ""
		}
}

secret = "0123456789abcdef0123456789abcdef"

expect Api.same_secret(secret, secret)
expect !Api.same_secret("0123456789abcdef0123456789abcdeX", secret)
expect !Api.same_secret("0123456789abcdef", secret)
expect !Api.same_secret("", "")
expect !Api.same_secret("short", "short")
expect Api.is_name("2026-10-07T070000Z-cloud") and !Api.is_name("a/b") and !Api.is_name("")
expect Api.query_value("/api/requests?kind=race", "kind") == "race"

expect {
	parsed : Try(Api.RunPost, _)
	parsed = Json.parse("{\"id\":\"r\",\"request_id\":0,\"trigger\":\"timer\",\"status\":\"skipped\",\"reason\":\"nothing new\",\"where_raced\":\"cloud\",\"started_at\":\"2026-10-07T07:00:00Z\",\"worker_token\":\"\",\"commits\":[{\"repository\":\"roux\",\"commit_sha\":\"abc\",\"new\":false}]}")
	match parsed {
		Ok(run) =>
			match run.race {
				Err(Missing) => run.commits.len() == 1
				Ok(_) => Bool.False
			}
		Err(_) => Bool.False
	}
}

# The racer's own summary (best_rps, median_*_ms) is not read: the pages
# take theirs from the rounds.
expect {
	parsed : Try(Api.ResultPost, _)
	parsed = Json.parse("{\"class\":\"smallest\",\"workload\":\"plaintext\",\"competitor\":\"go\",\"valid\":true,\"note\":\"\",\"rounds\":[],\"best_rps\":41863.2,\"median_p50_ms\":1.0,\"median_p95_ms\":2.0,\"median_p99_ms\":3.0,\"median_p999_ms\":4.0,\"open_loop\":[]}")
	match parsed {
		Ok(result) => result.competitor == "go" and result.valid
		Err(_) => Bool.False
	}
}

# A step with fields the site no longer reads (`share`, `p90_ms`) still
# parses: the site deploys before the racer updates itself.
expect {
	parsed : Try(Api.StepPost, _)
	parsed = Json.parse("{\"share\":0.0,\"offered_rps\":250.0,\"achieved_rps\":250.0,\"p50_ms\":1.0,\"p90_ms\":0.0,\"p99_ms\":2.0,\"p999_ms\":3.0,\"errors\":0,\"non_2xx\":0,\"cpu_busy_pct\":5.0,\"loader_cpu_busy_pct\":4.0,\"net_rx_mbps\":1.0,\"net_tx_mbps\":2.0,\"mean_ms\":1.0,\"parts\":[]}")
	match parsed {
		Ok(step) => step.offered_rps == 250.0 and step.p99_ms == 2.0
		Err(_) => Bool.False
	}
}

# A race with a field the site no longer reads (`versions_json`) still
# parses.
expect {
	parsed : Try(Api.RacePost, _)
	parsed = Json.parse("{\"seed\":1,\"region\":\"lon1\",\"image\":\"ubuntu-26-04-x64\",\"port\":8080,\"rounds\":3,\"warmup_seconds\":5,\"measure_seconds\":20,\"race_json\":\"{}\",\"versions_json\":\"{}\",\"versions\":[{\"name\":\"oha\",\"version\":\"1.16.0\"}],\"competitors\":[],\"workloads\":[],\"classes\":[]}")
	match parsed {
		Ok(race) => race.versions.len() == 1 and race.port == 8080
		Err(_) => Bool.False
	}
}
