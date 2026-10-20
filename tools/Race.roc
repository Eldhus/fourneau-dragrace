import pf.Env
import pf.Path
import Checks
import Conduit
import Config
import Machine
import Mixed
import Oha
import Results
import Run
import Seeded
import Snapshot
import Target
import Text

## A race on one server class: round after round, every competitor in a new
## seeded order each round, started in each mode its workloads need,
## checked in its first round, then each closed-loop workload warmed up and
## measured with a snapshot of both machines around it; after the rounds,
## each mixed workload's climb.
Race :: [].{
	## A class's race between two reports: a competitor's round of the closed
	## workloads, or its climb of one mixed workload. The whole plan is told
	## to the site as each step starts, for the live banner.
	Step : { competitor : Str, round : U64, workload : Str, planned_seconds : F64 }

	## What a race tells as it goes: each result as it grows, each step as it
	## begins (a worker posts both to the site).
	Hooks : { report! : Results.Result => {}, begin! : List(Step), U64 => {} }

	## No one to tell: a local race.
	quiet : Hooks
	quiet = { report!: |_| {}, begin!: |_, _| {} }

	## The order a class races in.
	plan : Config.Race, List(Config.Competitor), U64 -> List(Step)
	plan = |race, competitors, seed| {
		var $steps = []
		for round in 1..=race.rounds {
			for competitor in Seeded.shuffled(competitors, Seeded.mix(seed, round)) {
				seconds = race.workloads.keep_if(|w| w.mixed.is_err() and Target.offers(competitor, w) and Config.loads(race, w)).len() * (race.warmup_seconds + race.measure_seconds)
				$steps = $steps.append({ competitor: competitor.name, round, workload: "", planned_seconds: seconds.to_f64() })
			}
		}
		for workload in race.workloads {
			match workload.mixed {
				Ok(mixed) if Config.loads(race, workload) => {
					seconds = mixed.rates.len() * (mixed.warmup_seconds + mixed.measure_seconds)
					for competitor in Seeded.shuffled(competitors, Seeded.mix(seed, race.rounds + 2)) {
						if Target.offers(competitor, workload) {
							$steps = $steps.append({ competitor: competitor.name, round: 0, workload: workload.name, planned_seconds: seconds.to_f64() })
						}
					}
				}
				_ => {}
			}
		}
		$steps
	}

	## Race the class's plan and return its results. A step's error is that
	## step's: its result's note says why, and the class races on while the
	## server answers. The class fails only when it ends early.
	target! : Config.Race, List(Config.Competitor), Target.Where, U64, Hooks => Try(List(Results.Result), [Failed(Str), Interrupted])
	target! = |race, competitors, target, seed, hooks| {
		bodies = put_bodies!(race, target, seed)?
		if Config.has_tls(race) {
			put_certificate!(target)?
		}
		model = Conduit.model!()?
		steps = Race.plan(race, competitors, seed)
		var $state = { results: [], valid: Dict.empty() }
		var $failed = 0.U64
		var $index = 0.U64
		for step in steps {
			(hooks.begin!)(steps, $index)
			competitor = competitors.find_first(|c| c.name == step.competitor) ? |_| Failed("the plan names ${step.competitor}")
			raced =
				if step.workload != "" {
					climb_step!(race, step, competitor, target, model, $state, hooks)
				} else {
					Run.log!("[${target.class.name}] round ${step.round.to_str()}/${race.rounds.to_str()}: ${competitor.name}")
					done = race_competitor!(race, competitor, target, bodies, step.round, seed, $state)
					for result in done.state.results {
						if result.class == target.class.name and result.competitor == competitor.name {
							(hooks.report!)(result)
						}
					}
					done
				}
			$state = raced.state
			if raced.error != "" {
				Run.log!("[${target.class.name}] step ${($index + 1).to_str()} of ${steps.len().to_str()}: ${raced.error}")
				if raced.interrupted {
					return Err(Interrupted)
				}
				match server_answers!(target) {
					Ok({}) => {}
					Err(Interrupted) => return Err(Interrupted)
					Err(Failed(lost)) => {
						left = steps.drop_first($index + 1).map(|s| "${s.competitor} ${if s.workload == "" "round ${s.round.to_str()}" else s.workload}")
						return Err(Failed("the server stopped answering at step ${($index + 1).to_str()} of ${steps.len().to_str()} (${lost}), after: ${raced.error}; its black box ends: ${black_box_tail!(target.black_box, 6)}; ${if left.is_empty() "no step" else Str.join_with(left, ", ")} not raced"))
					}
				}
				$failed = $failed + 1
				Run.log!("[${target.class.name}] the server after step ${($index + 1).to_str()}: ${server_state!(target)}")
			}
			$index = $index + 1
		}
		if $failed > 0 {
			Run.log!("[${target.class.name}] ${$failed.to_str()} of ${steps.len().to_str()} steps failed; each result's note says why")
		}
		Ok($state.results)
	}

	## One more round of a competitor, after the race (an ad-hoc race's
	## rerun): its results with that round's measures added. What the race
	## found invalid stays so, unmeasured.
	rerun! : Config.Race, Config.Competitor, Target.Where, U64, U64, List(Results.Result) => Try(List(Results.Result), [Failed(Str), Interrupted])
	rerun! = |race, competitor, target, round, seed, results| {
		bodies = put_bodies!(race, target, seed)?
		valid = results.keep_if(|r| !r.valid).fold(
			Dict.empty(),
			|found, r|
				match race.workloads.find_first(|w| w.name == r.workload) {
					Ok(w) => found.insert(Target.valid_key(r.competitor, Target.mode_of(w)), r.note)
					Err(_) => found
				},
		)
		done = race_competitor!(race, competitor, target, bodies, round, seed, { results, valid })
		if done.interrupted Err(Interrupted) else Ok(done.state.results)
	}

	## What a machine is: its CPU and its generation, its CPUs, kernel and
	## memory.
	machine_info! : Machine.Where, Str, Str, Str => { role : Str, class : Str, size : Str, cpu : Str, cpus : I64, kernel : Str, cpu_id : Str, memory_mib : I64 }
	machine_info! = |machine, role, class, size| {
		ask! = |script| Machine.shell!(machine, script) ?? ""
		{
			role,
			class,
			size,
			cpu: ask!("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'"),
			cpus: I64.from_str(ask!("nproc").trim()) ?? 0,
			kernel: ask!("uname -r"),
			cpu_id: ask!("awk -F': *' '/^cpu family/ && !f {f=$2} /^model[ \\t]*:/ && !m {m=$2} /^stepping/ && !s {s=$2} END {print f\":\"m\":\"s}' /proc/cpuinfo").trim(),
			memory_mib: I64.from_str(ask!("awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo").trim()) ?? 0,
		}
	}

	## One oha run on the loader, closed loop: each connection's next request
	## when its answer arrives. Compression off (oha would ask for gzip and
	## brotli, which a server that compresses honours and the checks never
	## see); its threads at the loader's CPUs.
	oha_command : Config.Race, Config.Workload, Target.Where, List((U64, Str)), U64 -> Str
	oha_command = |race, workload, target, bodies, seconds| {
		threads = if target.loader_threads > 0 " --worker-threads ${target.loader_threads.to_str()}" else ""
		keepalive = if workload.keepalive "" else " --disable-keepalive"
		http2 = if workload.http2 " --http2 -p ${workload.streams.max(1).to_str()}" else ""
		# The race's own certificate. oha offers HTTP/2 by ALPN only with
		# --http2; churn-tls, without it, is HTTP/1.1 over TLS.
		tls = if workload.tls " --insecure" else ""
		method = if workload.method != "GET" " -m ${workload.method}" else ""
		body =
			if workload.body_bytes > 0 {
				path = (bodies.find_first(|(size, _)| size == workload.body_bytes) ?? (0, "")).1
				" -D ${Run.quote(path)} -T ${Run.quote(workload.content_type)}"
			} else {
				""
			}
		"ulimit -n $(ulimit -Hn); ${Target.taskset(target.loader_cpus)}${Run.quote(target.loader_home)}/oha -z ${seconds.to_str()}s -c ${workload.connections.to_str()} --no-tui --output-format json --disable-compression${threads}${keepalive}${http2}${tls}${method}${body} ${Target.base_url(race, target, Target.mode_of(workload))}${workload.path}"
	}
}

State : { results : List(Results.Result), valid : Dict(Str, Str) }

## A step's outcome: the state after it, and its error ("" for none).
Raced : { state : State, error : Str, interrupted : Bool }

## The result for a class, workload and competitor, new if there is none.
result_of : State, Str, Str, Str -> Results.Result
result_of = |state, class, workload, competitor|
	state.results.find_first(|r| r.class == class and r.workload == workload and r.competitor == competitor) ?? Results.empty(class, workload, competitor)

## The state with a result in it, replacing the one of its key.
with_result : State, Results.Result -> State
with_result = |state, result| {
	same = |r| r.class == result.class and r.workload == result.workload and r.competitor == result.competitor
	results =
		if state.results.any(same) {
			state.results.map(|r| if same(r) result else r)
		} else {
			state.results.append(result)
		}
	{ ..state, results }
}

## A competitor's round: each mode its workloads need, in a seeded order,
## and the workloads of each in their own order (in one order always, a
## server's drift would land on the same workloads every time).
race_competitor! : Config.Race, Config.Competitor, Target.Where, List((U64, Str)), U64, U64, State => Raced
race_competitor! = |race, competitor, target, bodies, round, seed, state| {
	order_seed = Seeded.mix(Seeded.mix(seed, round), Seeded.fnv(competitor.name))
	var $state = state
	var $errors = []
	var $interrupted = Bool.False
	for mode in Seeded.shuffled([Plain, Tls], Seeded.mix(order_seed, 1)) {
		workloads = Seeded.shuffled(race.workloads, order_seed).keep_if(|w| w.mixed.is_err() and Target.mode_of(w) == mode and Target.offers(competitor, w) and Config.loads(race, w))
		if !workloads.is_empty() and !$interrupted {
			raced = race_mode!(race, competitor, target, bodies, round, $state, mode, workloads)
			$state = raced.state
			if raced.error != "" {
				$errors = $errors.append(raced.error)
			}
			$interrupted = $interrupted or raced.interrupted
		}
	}
	{ state: $state, error: Str.join_with($errors, "; "), interrupted: $interrupted }
}

## Start the competitor in one mode and race its workloads.
race_mode! : Config.Race, Config.Competitor, Target.Where, List((U64, Str)), U64, State, Target.Mode, List(Config.Workload) => Raced
race_mode! = |race, competitor, target, bodies, round, state, mode, workloads| {
	key = Target.valid_key(competitor.name, mode)
	class = target.class.name
	pid =
		match Target.start!(race, competitor, target, mode) {
			Ok(p) => p
			Err(err) => {
				why = "${competitor.name} round ${round.to_str()}: starting it: ${describe(err)}"
				stopped = workloads.fold(
					state,
					|s, w| {
						r = result_of(s, class, w.name, competitor.name)
						with_result(s, { ..r, valid: !r.rounds.is_empty(), note: "stopped: ${why}" })
					},
				)
				return { state: stopped, error: why, interrupted: err == Interrupted }
			}
		}
	ready = Target.ready!(race, target, mode)
	var $state = state
	match ready {
		Err(Interrupted) => {
			Target.stop!(target, pid)
			return { state, error: "interrupted", interrupted: Bool.True }
		}
		Err(Failed(_)) => {
			$state = { ..$state, valid: $state.valid.insert(key, "did not start: ${Target.why_not_ready!(competitor, target, pid)}") }
		}
		Ok({}) => {
			if round == 1 and ($state.valid.get(key) ?? "") == "" {
				$state = { ..$state, valid: $state.valid.insert(key, validate!(race, target, bodies, mode)) }
			}
		}
	}
	why_invalid = $state.valid.get(key) ?? ""
	for workload in workloads {
		r = result_of($state, class, workload.name, competitor.name)
		if why_invalid != "" {
			$state = with_result($state, { ..r, valid: Bool.False, note: why_invalid })
		} else {
			match measure!(race, workload, target, bodies, pid) {
				Ok(measured) => {
					$state = with_result($state, { ..r, valid: Bool.True, rounds: r.rounds.append(measured) })
				}
				Err(err) => {
					# The rounds measured stand, and the note says why one is
					# missing; none, no result.
					why = "${competitor.name} ${workload.name} round ${round.to_str()}: ${describe(err)}"
					Target.stop!(target, pid)
					return { state: with_result($state, { ..r, valid: !r.rounds.is_empty(), note: "stopped: ${why}" }), error: why, interrupted: err == Interrupted }
				}
			}
		}
	}
	Target.stop!(target, pid)
	{ state: $state, error: "", interrupted: Bool.False }
}

## A mixed workload's climb for its competitor, if the rounds found it valid.
climb_step! : Config.Race, Race.Step, Config.Competitor, Target.Where, Conduit.Model, State, Race.Hooks => Raced
climb_step! = |race, step, competitor, target, model, state, hooks| {
	workload = race.workloads.find_first(|w| w.name == step.workload) ?? (race.workloads.first() ?? crash "a race with no workloads")
	class = target.class.name
	r = result_of(state, class, workload.name, competitor.name)
	why = state.valid.get(Target.valid_key(competitor.name, Target.mode_of(workload))) ?? ""
	if why != "" {
		result = { ..r, valid: Bool.False, note: why }
		(hooks.report!)(result)
		return { state: with_result(state, result), error: "", interrupted: Bool.False }
	}
	mixed =
		match workload.mixed {
			Ok(m) => m
			Err(None) => return { state, error: "${workload.name} is not mixed", interrupted: Bool.False }
		}
	Run.log!("[${class}] ${workload.name}: ${competitor.name}")
	match Mixed.climb!(race, workload, mixed, competitor, target, model) {
		Ok({ steps, why: refused, stopped }) => {
			if stopped == "" {
				result = { ..r, valid: refused == "", note: refused, open_loop: steps }
				(hooks.report!)(result)
				{ state: with_result(state, result), error: "", interrupted: Bool.False }
			} else {
				# The steps climbed stand, with why the climb ended.
				failure = "${competitor.name} ${workload.name}: ${stopped}"
				result = { ..r, valid: !steps.is_empty(), note: "stopped: ${failure}", open_loop: steps }
				(hooks.report!)(result)
				{ state: with_result(state, result), error: failure, interrupted: Bool.False }
			}
		}
		Err(err) => {
			failure = "${competitor.name} ${workload.name}: ${describe(err)}"
			result = { ..r, valid: Bool.False, note: "stopped: ${failure}" }
			(hooks.report!)(result)
			{ state: with_result(state, result), error: failure, interrupted: err == Interrupted }
		}
	}
}

## A warmup (discarded), then the measured run with snapshots around it.
measure! : Config.Race, Config.Workload, Target.Where, List((U64, Str)), Str => Try(Results.Round, [Failed(Str), Interrupted])
measure! = |race, workload, target, bodies, pid| {
	_ = Machine.shell!(target.loader, Race.oha_command(race, workload, target, bodies, race.warmup_seconds)) ? |err| at(err, "warmup")
	before = Target.snapshots!(target, pid, Before)?
	report = Machine.shell!(target.loader, Race.oha_command(race, workload, target, bodies, race.measure_seconds)) ? |err| at(err, "oha")
	after = Target.snapshots!(target, pid, After)?
	round = Oha.round(report)?
	local = Machine.is_loopback(target.address)
	cost = Snapshot.over(Snapshot.cost(before.server, after.server, target.server_cpus, local), round.load_seconds)
	hwm = Machine.shell!(target.server, "awk '/VmHWM/ {print $2}' /proc/${pid}/status") ?? ""
	measured = {
		..round,
		cpu_busy_pct: cost.cpu.busy,
		steal_pct: cost.cpu.steal,
		cpu_user_pct: cost.cpu.user,
		cpu_system_pct: cost.cpu.system,
		cpu_irq_pct: cost.cpu.irq,
		cpu_softirq_pct: cost.cpu.softirq,
		net_rx_mbps: cost.net_rx_mbps,
		net_tx_mbps: cost.net_tx_mbps,
		net_rx_pps: cost.net_rx_pps,
		net_tx_pps: cost.net_tx_pps,
		tcp_retransmits: cost.retransmits,
		threads: cost.threads,
		voluntary_switches: cost.voluntary_switches,
		involuntary_switches: cost.involuntary_switches,
		seconds: cost.seconds,
		loader_cpu_busy_pct: Snapshot.loader_busy(before.loader, after.loader, target.loader_cpus, round.load_seconds),
		rss_kib: I64.from_str(hwm.trim()) ?? 0,
	}
	Run.log!("    ${Text.pad_right(workload.name, 10)} ${Text.pad_left(Text.fixed(measured.rps, 0), 10)} req/s  p99 ${Text.fixed(measured.p99_ms, 2)} ms  cpu ${Text.fixed(measured.cpu_busy_pct, 0)}%")
	Ok(measured)
}

## That the competitor does the work, "" when it does: the exact
## plaintext, each echoed body byte for byte, the menu, the stream, h2c,
## the 404; over TLS, what TLS was agreed.
validate! : Config.Race, Target.Where, List((U64, Str)), Target.Mode => Str
validate! = |race, target, bodies, mode| {
	url = Target.base_url(race, target, mode)
	curl = Target.curl(mode, "5")
	ask! = |script| Machine.shell!(target.loader, script)
	plain = ask!("${curl}${url}/plaintext") ?? ""
	if plain != "Hello, World!" {
		return "/plaintext answered ${Str.inspect(plain)}"
	}
	if mode == Tls {
		lines = ask!("${curl}-v -o /dev/null -w 'version %{http_version}\\n' ${url}/plaintext 2>&1 | grep -E 'SSL connection using|^version '")
		match lines {
			Ok(text) => {
				{ why, agreed } = Checks.tls(text)
				Run.log!("    TLS agreed: ${agreed}")
				if why != "" {
					return why
				}
			}
			Err(Failed(why)) => return "TLS: ${why}"
			Err(Interrupted) => return "TLS: interrupted"
		}
	}
	for (_, body) in bodies {
		want = ask!("sha256sum < ${Run.quote(body)} | cut -c1-64") ?? "want"
		got = ask!("${curl}-X POST --data-binary @${Run.quote(body)} -H 'Content-Type: application/octet-stream' ${url}/echo | sha256sum | cut -c1-64") ?? "got"
		if got != want {
			return "/echo did not answer the body it was sent"
		}
	}
	# The machine trims trailing line breaks from what it returns; so is the
	# reference.
	menu = ask!("${curl}${url}/menu") ?? ""
	if Checks.canonical_entities(menu) != trim_breaks(Checks.canonical_entities(race.menu)) {
		return "/menu did not render the menu (workloads/menu.html)"
	}
	stream = validate_stream!(race, target, mode)
	if stream != "" {
		return stream
	}
	if mode == Plain and Config.has_h2c(race) {
		h2c = ask!("${curl}--http2-prior-knowledge ${url}/plaintext") ?? ""
		if h2c != "Hello, World!" {
			return "/plaintext over HTTP/2 (h2c) answered ${Str.inspect(h2c)}"
		}
	}
	missing = ask!("${curl}-o /dev/null -w '%{http_code}' ${url}/nope") ?? ""
	if missing != "404" {
		return "/nope answered ${missing}, not 404"
	}
	""
}

## The SSE workload's route, when the race runs it: the stream, a chunk an
## event, and 400 without signals. Raw bytes cross the shell as base64
## (the machine trims line breaks).
validate_stream! : Config.Race, Target.Where, Target.Mode => Str
validate_stream! = |race, target, mode|
	match race.workloads.find_first(|w| w.name == "sse") {
		Err(_) => ""
		Ok(workload) => {
			url = Target.base_url(race, target, mode)
			curl = Target.curl(mode, "5")
			encoded =
				match Machine.shell!(target.loader, "${curl}--http1.1 --include --raw ${Run.quote("${url}${workload.path}")} | base64 -w0") {
					Ok(text) => text
					Err(Failed(why)) => return "/sse: ${why}"
					Err(Interrupted) => return "/sse: interrupted"
				}
			raw =
				match Run.with_input_bytes!("", ["base64", "-d"], encoded.to_utf8()) {
					Ok(bytes) => Str.from_utf8_lossy(bytes)
					Err(_) => return "/sse: not base64"
				}
			why = Checks.stream(raw, race.stream)
			if why != "" {
				return "/sse: ${why}"
			}
			path =
				match workload.path.split_first("?") {
					Ok({ before, .. }) => before
					Err(_) => workload.path
				}
			got = Machine.shell!(target.loader, "${curl}-o /dev/null -w '%{http_code}' ${url}${path}") ?? ""
			if got != "400" "${path} without signals answered ${got}, not 400" else ""
		}
	}

## Each request body size the workloads need, written to the loader: bytes
## from the seed, so a run can be repeated exactly.
put_bodies! : Config.Race, Target.Where, U64 => Try(List((U64, Str)), [Failed(Str), Interrupted])
put_bodies! = |race, target, seed| {
	dir = temp_dir!()?
	var $bodies = []
	for workload in race.workloads {
		size = workload.body_bytes
		if size > 0 and !$bodies.any(|(s, _)| s == size) {
			local = "${dir}/body-${size.to_str()}"
			Path.utf8(local).write_bytes!(Seeded.bytes(Seeded.mix(seed, size), size)) ? |PathErr(err, _)| Failed("${local}: ${err.to_str()}")
			remote = "${target.loader_home}/body-${size.to_str()}"
			Machine.put!(target.loader, local, remote)?
			$bodies = $bodies.append((size, remote))
		}
	}
	_ = Path.utf8(dir).delete_all!()
	Ok($bodies)
}

## A new private directory for files made here and then put elsewhere.
temp_dir! : () => Try(Str, [Failed(Str), Interrupted])
temp_dir! = || {
	made = Env.create_temp_dir_with_prefix!("dragrace-") ? |_| Failed("no temporary directory")
	Ok(made.display())
}

## The race's certificate and key, made here and put in the server's home:
## ECDSA P-256 as Let's Encrypt issues by default, self-signed (oha takes it
## with --insecure: verifying a chain is the client's cost), for the
## server's address, a day long.
put_certificate! : Target.Where => Try({}, [Failed(Str), Interrupted])
put_certificate! = |target| {
	dir = temp_dir!()?
	cert = "${dir}/${Target.certificate_name}"
	key = "${dir}/${Target.key_name}"
	address = target.address
	san = if is_ip(address) "DNS:fourneau-dragrace,IP:${address}" else "DNS:fourneau-dragrace,DNS:${address}"
	Run.run!("", [], ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=fourneau-dragrace", "-addext", "subjectAltName=${san}", "-addext", "keyUsage=critical,digitalSignature", "-addext", "extendedKeyUsage=serverAuth"]) ? |err| at(err, "the certificate")
	Machine.put!(target.server, cert, "${target.server_home}/${Target.certificate_name}") ? |err| at(err, "the certificate")
	Machine.put!(target.server, key, "${target.server_home}/${Target.key_name}") ? |err| at(err, "the certificate")
	_ = Path.utf8(dir).delete_all!()
	Ok({})
}

## Whether the server machine answers SSH, for about a minute and a half: a
## step may fail with the machine itself fine.
server_answers! : Target.Where => Try({}, [Failed(Str), Interrupted])
server_answers! = |target| {
	var $last = ""
	for attempt in 0..<4 {
		if attempt > 0 {
			Run.run!("", [], ["sleep", "15"])?
		}
		match Machine.shell!(target.server, "true") {
			Ok(_) => return Ok({})
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => {
				$last = why
			}
		}
	}
	Err(Failed($last))
}

## What the server machine says of itself after a step failed: when it
## booted, its memory, the kernel's last kill or fault.
server_state! : Target.Where => Str
server_state! = |target| {
	script = "echo \"up since $(uptime -s);\" $(awk '/^MemAvailable/ {printf \"MemAvailable %d MiB;\", $2 / 1024}' /proc/meminfo); dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|invalid opcode|segfault' | tail -n 2"
	match Machine.shell!(target.server, script) {
		Ok(state) => Str.join_with(Text.fields(state.replace_each("\n", " ")), " ")
		Err(err) => "the server's state: ${describe(err)}"
	}
}

## The black box's last lines, one line of text.
black_box_tail! : Str, U64 => Str
black_box_tail! = |path, count| {
	if path == "" {
		return ""
	}
	text = Path.utf8(path).read_utf8!() ?? ""
	lines = Text.lines(text.trim())
	Str.join_with(lines.drop_first(lines.len() - count.min(lines.len())), " | ")
}

describe : [Failed(Str), Interrupted] -> Str
describe = |err|
	match err {
		Failed(why) => why
		Interrupted => "interrupted"
	}

at : [Failed(Str), Interrupted], Str -> [Failed(Str), Interrupted]
at = |err, place|
	match err {
		Failed(why) => Failed("${place}: ${why}")
		Interrupted => Interrupted
	}

trim_breaks : Str -> Str
trim_breaks = |text| {
	var $out = text
	while $out.ends_with("\n") {
		$out = $out.drop_suffix("\n")
	}
	$out
}

is_ip : Str -> Bool
is_ip = |address| address.contains(":") or address.to_utf8().all(|b| (b >= '0' and b <= '9') or b == '.')
