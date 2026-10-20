import pf.Monotonic
import pf.Path
import pf.Stdout
import pf.Utc
import Build
import Checkout
import Conduit
import Config
import Fetch
import Flags
import Keys
import Machine
import Race
import Results
import Run
import Snapshot
import Target
import Text
import Toolchain

## `dragrace race local`: the race on this machine, the servers on
## race.json's local.server_cpus and oha on local.loader_cpus, over
## loopback. Loopback is not a network: the numbers compare competitors,
## not deployments. `-quick` is the smoke race every build runs.
Local :: [].{
	## What -quick races unless -workloads says: a cell of each protocol,
	## connections made and closed, and the database. The checks before
	## each server's cells ask every workload's path in each mode.
	smoke_workloads : List(Str)
	smoke_workloads = ["plaintext", "plaintext-h2", "plaintext-tls", "churn", "conduit"]

	flag_specs : Str -> List(Flags.Spec)
	flag_specs = |root| [
		{ name: "quick", kind: Switch, usage: "a smoke test, not a result: one 2 s round of a few workloads; any invalid result fails it" },
		{ name: "since", kind: Value(""), usage: "a release's build.json: race only the competitors that moved since (smoke_set); a missing file races all" },
		{ name: "server-cpus", kind: Value(""), usage: "local race: the server's CPUs (default race.json's)" },
		{ name: "loader-cpus", kind: Value(""), usage: "local race: oha's CPUs (default race.json's)" },
		{ name: "competitors", kind: Value(""), usage: "comma-separated (default: all)" },
		{ name: "workloads", kind: Value(""), usage: "comma-separated (default: all)" },
		{ name: "results", kind: Value("${Checkout.out(root)}/results"), usage: "directory for the results file" },
	]

	## race.json narrowed by the flags.
	narrow : Config.Race, Flags.Parsed -> Config.Race
	narrow = |race, flags| {
		server_cpus = Flags.value(flags, "server-cpus")
		loader_cpus = Flags.value(flags, "loader-cpus")
		local = {
			server_cpus: if server_cpus == "" race.local.server_cpus else server_cpus,
			loader_cpus: if loader_cpus == "" race.local.loader_cpus else loader_cpus,
		}
		only = Flags.value(flags, "workloads")
		quickened =
			if Flags.switch(flags, "quick") {
				workloads = race.workloads.map(
					|w|
						match w.mixed {
							Ok(m) => { ..w, mixed: Ok({ ..m, rates: m.rates.take_first(1), warmup_seconds: 1, measure_seconds: 1 }) }
							Err(None) => w
						},
				)
				{ ..race, rounds: 1, warmup_seconds: 1, measure_seconds: 1, workloads, loaded: if only == "" Ok(Local.smoke_workloads) else race.loaded }
			} else {
				race
			}
		names = Flags.value(flags, "competitors")
		with_competitors = if names == "" quickened else { ..quickened, competitors: names.split_on(",") }
		narrowed = if only == "" with_competitors else { ..with_competitors, workloads: with_competitors.workloads.keep_if(|w| only.split_on(",").contains(w.name)) }
		{ ..narrowed, local }
	}

	race! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	race! = |root, args| {
		clock = Monotonic.now!()
		flags = Flags.parse(args, Local.flag_specs(root))?
		race = Local.narrow(Checkout.race!(root)?, flags)
		if race.local.server_cpus != "" and race.local.loader_cpus != "" {
			cores_apart!(race.local.server_cpus, race.local.loader_cpus)?
		}
		ready = Toolchain.load!(root)?
		all = Checkout.competitors!(root, race.competitors)?
		since = Flags.value(flags, "since")
		# Before the build, which can take minutes; with -since, once the
		# competitors raced are known.
		if since == "" {
			kernel_tls!(race, all)?
		}
		keys = Build.all!(root, ready, all)?
		competitors =
			if since == "" {
				all
			} else {
				moved = moved_since!(root, since, all, keys)?
				if moved.is_empty() {
					Run.log!("nothing to race: no competitor and not the harness moved since ${since}")
					return Ok({})
				}
				Run.log!("racing what moved since ${since}: ${Str.join_with(moved.map(|c| c.name), ", ")}")
				kernel_tls!(race, moved)?
				moved
			}
		raced_race = { ..race, competitors: competitors.map(|c| c.name) }
		started = Utc.now!()
		seed = started.to_nanos_since_epoch().to_u64_wrap()
		oha = Local.oha!(race.oha)?
		build_seconds = seconds_since!(clock)
		out = Checkout.out(root)
		loader_home = "${out}/loader"
		Machine.put!(Local, oha, "${loader_home}/oha")?
		cpu = Machine.shell!(Local, "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'") ?? ""
		target = {
			class: { name: "local", label: "", title: "${cpu}: server on CPUs ${race.local.server_cpus}, loader on ${race.local.loader_cpus}", size: "", loader_size: "" },
			server: Local,
			loader: Local,
			server_home: out,
			loader_home,
			address: "127.0.0.1",
			server_cpus: race.local.server_cpus,
			loader_cpus: race.local.loader_cpus,
			loader_threads: Snapshot.cpu_count(race.local.loader_cpus),
			black_box: "",
		}
		Machine.put!(Local, Conduit.database(root), "${out}/${Conduit.seed_name}")?
		machines = [Race.machine_info!(Local, "server", "local", "this computer")]
		racing = Monotonic.now!()
		results = Race.target!(raced_race, competitors, target, seed, Race.quiet)?
		racing_seconds = seconds_since!(racing)
		timing = {
			seconds: seconds_since!(clock),
			build_seconds,
			launch_seconds: 0.0,
			racing_seconds,
			classes: [{ class: "local", seconds: racing_seconds }],
			droplets: [],
			cost_usd: 0.0,
		}
		id = run_id("local", started)
		race_json = Checkout.read!("${root}/race.json")?
		versions = Local.versions!(root, race)?
		fingerprint = fingerprint!(root)?
		run = {
			id,
			where_raced: "local",
			started_at: started.to_iso_8601(),
			finished_at: Utc.now!().to_iso_8601(),
			seed: seed.to_i64_wrap(),
			fingerprint,
			versions,
			race_json,
			machines,
			results,
			timing,
		}
		dir = Flags.value(flags, "results")
		path = Local.save!(dir, run)?
		Run.log!("results: ${path}")
		_ = Stdout.write!(Results.table(results))
		if Flags.switch(flags, "quick") {
			Results.invalid(results)
		} else {
			Ok({})
		}
	}

	## oha at race.json's pin, fetched and checked once, executable.
	oha! : Config.Download => Try(Str, [Failed(Str), Interrupted])
	oha! = |pin| {
		cache = Keys.cache!()?
		path = "${cache}/oha-${pin.version}"
		Fetch.pinned!(pin.url, pin.sha256, path)?
		Run.run!("", [], ["chmod", "755", path])?
		Ok(path)
	}

	## A race's versions, a row each as the site keeps them: the build's
	## record, and oha's and the droplet image from race.json.
	versions! : Str, Config.Race => Try(List({ name : Str, version : Str }), [Failed(Str)])
	versions! = |root, race| {
		text = Checkout.read!(Toolchain.record(root))?
		parsed : Try(Toolchain.Used, _)
		parsed = Json.parse(text)
		used = parsed ? |_| Failed("out/toolchain.json: not the toolchain's record")
		Ok([
			{ name: "zig", version: used.zig },
			{ name: "roc", version: used.roc },
			{ name: "oha", version: race.oha.version },
			{ name: "go", version: used.go },
			{ name: "rust", version: used.rust },
			{ name: "axum", version: used.axum },
			{ name: "tokio", version: used.tokio },
			{ name: "droplet_image", version: race.cloud.image },
		])
	}

	## The results file: everything needed to read a race later without this
	## repository at that commit (race.json as it was, its versions, its
	## machines). Its fields are the Go tool's; race.json is kept whole.
	save! : Str, RunFile => Try(Str, [Failed(Str)])
	save! = |dir, run| {
		Path.utf8(dir).create_all!() ? |PathErr(err, _)| Failed("${dir}: ${err.to_str()}")
		results = run.results.map_try(Results.to_json)?
		head =
			# Go's file said "where"; a Roc field cannot be a keyword, and the
			# site's API names it where_raced.
			Json.to_str_try({ id: run.id, where_raced: run.where_raced, started_at: run.started_at, finished_at: run.finished_at, seed: run.seed, fingerprint: run.fingerprint, versions: run.versions, machines: run.machines, timing: run.timing })
			? |_| Failed("the results file: a number JSON cannot hold")
		# race.json is JSON already: it goes in as it is, a value of the object.
		text = "${head.drop_suffix("}")},\"race\":${run.race_json.trim()},\"results\":[${Str.join_with(results, ",")}]}\n"
		path = "${dir}/${run.id}.json"
		Path.utf8(path).write_utf8!(text) ? |PathErr(err, _)| Failed("${path}: ${err.to_str()}")
		Ok(path)
	}

	RunFile : {
		id : Str,
		where_raced : Str,
		started_at : Str,
		finished_at : Str,
		seed : I64,
		fingerprint : Fingerprint,
		versions : List({ name : Str, version : Str }),
		race_json : Str,
		machines : List({ role : Str, class : Str, size : Str, cpu : Str, cpus : I64, kernel : Str, cpu_id : Str, memory_mib : I64 }),
		results : List(Results.Result),
		timing : { seconds : F64, build_seconds : F64, launch_seconds : F64, racing_seconds : F64, classes : List({ class : Str, seconds : F64 }), droplets : List({ role : Str, class : Str, size : Str, price_hourly : F64, seconds : F64, cost_usd : F64 }), cost_usd : F64 },
	}

	## The three checkouts' commits, and whether each has changes.
	Fingerprint : { dragrace : Str, dragrace_dirty : Bool, fourneau : Str, fourneau_dirty : Bool, roux : Str, roux_dirty : Bool }
}

fingerprint! : Str => Try(Local.Fingerprint, [Failed(Str), Interrupted])
fingerprint! = |root| {
	commit! = |dir| {
		head = Run.output!(dir, ["git", "rev-parse", "HEAD"])?
		status = Run.output!(dir, ["git", "status", "--porcelain"])?
		Ok({ head, dirty: status != "" })
	}
	dragrace = commit!(root)?
	fourneau = commit!(Checkout.beside(root, "fourneau"))?
	roux = commit!(Checkout.beside(root, "roux"))?
	Ok({ dragrace: dragrace.head, dragrace_dirty: dragrace.dirty, fourneau: fourneau.head, fourneau_dirty: fourneau.dirty, roux: roux.head, roux_dirty: roux.dirty })
}

## `2026-10-20T041332Z-local`.
run_id : Str, Utc -> Str
run_id = |where_raced, at| "${at.to_iso_8601().replace_each(":", "")}-${where_raced}"

seconds_since! : Monotonic => F64
seconds_since! = |clock| clock.elapsed!().to_nanos().to_f64() / 1e9

## A race refused when its kernel-TLS competitors would race a TLS workload
## on a kernel without `tls`: each would not start, and say so only in its
## results, after the race.
kernel_tls! : Config.Race, List(Config.Competitor) => Try({}, [Failed(Str)])
kernel_tls! = |race, competitors| {
	path = "/proc/sys/net/ipv4/tcp_available_ulp"
	ulps = (Path.utf8(path).read_utf8!() ?? "").trim()
	if Text.fields(ulps).contains("tls") or !race.workloads.any(|w| w.tls and Config.loads(race, w)) {
		return Ok({})
	}
	need = competitors.keep_if(|c| c.tls and c.kernel_tls).map(|c| c.name)
	rest = competitors.keep_if(|c| !(c.tls and c.kernel_tls)).map(|c| c.name)
	if need.is_empty() {
		return Ok({})
	}
	escape = if rest.is_empty() "" else "\nor race without them: -competitors ${Str.join_with(rest, ",")}"
	Err(Failed("${Str.join_with(need, " and ")} serve HTTPS through the kernel's TLS, which this kernel has not loaded (${path} lists ${Str.inspect(ulps)}). Load it:\n  sudo modprobe tls                                 # now\n  echo tls | sudo tee /etc/modules-load.d/tls.conf  # and at every boot${escape}"))
}

## The competitors the smoke set picks against a release's build.json; a
## missing file is no release yet, and races them all.
moved_since! : Str, Str, List(Config.Competitor), List((Str, Str)) => Try(List(Config.Competitor), [Failed(Str), Interrupted])
moved_since! = |root, since, competitors, keys| {
	last =
		if Path.utf8(since).exists!() == Ok(Bool.True) {
			text = Checkout.read!(since)?
			parsed : Try({ competitors : Dict(Str, Str), harness_key ?: Str }, _)
			parsed = Json.parse(text)
			info = parsed ? |_| Failed("${since}: not a build.json")
			Ok({ harness_key: info.?harness_key ?? "", competitors: info.competitors.to_list() })
		} else {
			Run.log!("${since}: none, so every competitor races")
			Err(None)
		}
	harness = Keys.harness!(root)?
	picked = Keys.smoke_set(competitors.map(|c| c.name), keys, harness, last)
	Ok(competitors.keep_if(|c| picked.contains(c.name)))
}

## A local race refused when a physical core has CPUs in both sets: two
## hyperthreads of one core share its execution units.
cores_apart! : Str, Str => Try({}, [Failed(Str)])
cores_apart! = |server_cpus, loader_cpus| {
	cores! = |cpus| {
		ids = Snapshot.cpu_set(cpus) ?? []
		ids.map_try!(
			|cpu| {
				read! = |name| Path.utf8("/sys/devices/system/cpu/cpu${cpu}/topology/${name}").read_utf8!().map_ok(Str.trim)
				pkg = read!("physical_package_id") ? |_| Failed("CPU ${cpu}: no topology")
				core = read!("core_id") ? |_| Failed("CPU ${cpu}: no topology")
				Ok(("${pkg}:${core}", cpu))
			},
		)
	}
	server = cores!(server_cpus)?
	loader = cores!(loader_cpus)?
	shared = Text.sorted(
		server
			.keep_if(|(core, _)| loader.any(|(other, _)| other == core))
			.map(|(core, _)| core),
	)
	if shared.is_empty() {
		Ok({})
	} else {
		Err(Failed("server CPUs ${server_cpus} and loader CPUs ${loader_cpus} share physical cores (${Str.join_with(shared, "; ")}): pick whole cores for each (lscpu -e=CPU,CORE)"))
	}
}

expect run_id("local", Utc.from_millis_since_epoch(1_760_933_612_000)) == "2025-10-20T041332Z-local"
