import pf.Cmd
import pf.Monotonic
import pf.OsStr
import pf.Path
import pf.Signal
import pf.Sleep
import pf.System
import Checkout
import Conduit
import Config
import Flags
import Machine
import Race
import Results
import Retry
import Run
import SiteApi
import Target

## A worker races one server class from its loader: the racer starts it on
## the loader droplet, the run's build unpacked as a checkout (race.json,
## competitors/, out/bin), with a config. It drives the server over the
## private network and posts each result to the site as it grows. Every
## result is also kept in a file, which the racer posts again when the
## worker is done, so a post the site missed costs nothing.
Worker :: [].{
	Config : {
		run_id : Str,
		class : Config.ServerClass,
		seed : I64,
		site : Str,
		token : Str,
		## The server's private address.
		server_host : Str,
		key : Str,
		known_hosts : Str,
		## Where every result is kept as raced, for the racer.
		results : Str,
	}

	## A worker's posts wait at most two minutes: they come between steps,
	## so a slow site costs idle time, not a measurement.
	post_policy : Retry.Policy
	post_policy = { first_ms: 1_000, most_ms: 15_000, window_ms: 2 * 60_000 }

	command! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	command! = |root, args| {
		flags = Flags.parse(args, [{ name: "config", kind: Value("worker.json"), usage: "the racer's config for this worker" }])?
		path = Flags.value(flags, "config")
		text = Checkout.read!(path)?
		parsed : Try(Config, _)
		parsed = Json.parse(text)
		config = parsed ? |_| Failed("${path}: not a worker's config")
		if config.run_id == "" or config.site == "" or config.token == "" or config.server_host == "" or config.results == "" {
			return Err(Failed("${path}: run_id, site, token, server_host and results are required"))
		}
		# The racer stops a worker past its time (systemctl stop): what is
		# waiting returns Interrupted, and the worker says how its class ended.
		match System.target!().os() {
			Linux(os) => Signal.catch!([Interrupt, Terminate(os.unix())]) ? |_| Failed("signals: not caught")
			_ => return Err(Failed("a worker runs on Linux"))
		}
		Worker.run!(root, config)
	}

	run! : Str, Config => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	run! = |root, config| {
		site = SiteApi.client(config.site, config.token)
		class_path = "/api/runs/${config.run_id}/classes/${config.class.name}"
		_ = SiteApi.post!(site, class_path, "{\"status\":\"racing\",\"reason\":\"\",\"seconds\":0}") ? |err| refused_as_failed(err)
		started = Monotonic.now!()
		raced = race!(root, config, site)
		{ status, reason } =
			match raced {
				Ok({}) => { status: "done", reason: "" }
				Err(Failed(why)) => { status: "failed", reason: why }
				Err(Interrupted) => { status: "failed", reason: "the worker was stopped" }
			}
		# Acknowledged, so the posts below are not interrupted too.
		_ = Signal.poll!()
		if status == "failed" {
			# The racer's reason when no results came.
			_ = Path.utf8(Worker.failed_path(config.results)).write_utf8!(reason)
		}
		# Past an interrupt too: the site should hear how the class ended.
		seconds = started.elapsed!().to_nanos().to_f64() / 1e9
		match SiteApi.post!(site, class_path, Json.to_str_try({ status, reason, seconds }) ?? "{}") {
			Ok(_) => {}
			Err(err) => Run.log!("the class's end: ${describe(err)}")
		}
		match raced {
			Ok({}) => Ok({})
			Err(Failed(why)) => Err(Failed(why))
			Err(Interrupted) => Err(Interrupted)
		}
	}

	## Where a failed worker leaves its reason, beside its results.
	failed_path : Str -> Str
	failed_path = |results| "${Checkout.parent(results)}/failed.txt"
}

race! : Str, Worker.Config, SiteApi.Client => Try({}, [Failed(Str), Interrupted])
race! = |root, config, site| {
	race = Checkout.race!(root)?
	competitors = Checkout.competitors!(root, race.competitors)?
	seed = config.seed.to_u64_wrap()
	steps_path = "/api/runs/${config.run_id}/classes/${config.class.name}/steps"
	results_path = "/api/runs/${config.run_id}/results"
	# Annotated: a bare 0 given it would be a Dec, posted as 0.0, which the
	# site refuses for a step.
	post_steps! : List(Race.Step), U64 => {}
	post_steps! = |plan, index| {
		# Only the banner's: a failed post fails nothing.
		# Planned seconds are whole numbers: never NaN, so `{}` never goes.
		match SiteApi.post_with!(site, steps_path, Json.to_str_try({ step: index, steps: plan }) ?? "{}", Worker.post_policy) {
			Ok(_) => {}
			Err(err) => Run.log!("posting step ${index.to_str()}: ${describe(err)}")
		}
	}
	# The plan before the machines are readied, no step begun: the site
	# says the class is readying.
	post_steps!(Race.plan(race, competitors, seed), 0)
	home = "/root/dragrace"
	server = Remote({ user: "root", host: config.server_host, key: config.key, known_hosts: config.known_hosts, control: "${home}/ssh-server" })
	# The racer reached the server, but its sshd can still reset a new
	# connection: wait, as the racer does. The connection that gets through
	# is kept for every call after (control).
	wait_ssh!(server)?
	raced = race_on!(root, config, site, race, competitors, server, results_path, post_steps!)
	Machine.close!(server)
	raced
}

race_on! : Str, Worker.Config, SiteApi.Client, Config.Race, List(Config.Competitor), Machine.Where, Str, (List(Race.Step), U64 => {}) => Try({}, [Failed(Str), Interrupted])
race_on! = |root, config, site, race, competitors, server, results_path, post_steps!| {
	home = "/root/dragrace"
	for competitor in competitors {
		Machine.put!(server, "${Checkout.bin(root)}/${competitor.name}", "${home}/bin/${competitor.name}")?
	}
	_ = Machine.shell!(server, "chmod +x ${home}/bin/*")?
	Machine.put!(Local, "${Checkout.bin(root)}/oha", "${home}/loader/oha")?
	Machine.put!(server, Conduit.database(root), "${home}/${Conduit.seed_name}")?
	loader_info = Race.machine_info!(Local, "loader", config.class.name, config.class.loader_size)
	server_info = Race.machine_info!(server, "server", config.class.name, config.class.size)
	_ = SiteApi.post!(site, "/api/runs/${config.run_id}/machines", Json.to_str([loader_info, server_info])) ? |err| refused_as_failed(err)
	black_box = "${Checkout.parent(config.results)}/server.log"
	follower : Try(Cmd.Child, [None])
	follower =
		match follow!(server, black_box) {
			Ok(child) => Ok(child)
			Err(why) => {
				# The black box only explains a failure: without it, the class races.
				Run.log!("the black box: ${why}; racing without it")
				Err(None)
			}
		}
	target = {
		class: config.class,
		server,
		loader: Local,
		server_home: home,
		loader_home: "${home}/loader",
		address: config.server_host,
		server_cpus: "",
		loader_cpus: "",
		loader_threads: if loader_info.cpus > 0 loader_info.cpus.to_u64_wrap() else 0,
		black_box: if follower.is_ok() black_box else "",
	}
	report! = |result| {
		match keep!(config.results, result) {
			Ok({}) => {}
			Err(why) => Run.log!("keeping results: ${why}")
		}
		match Results.to_json(result) {
			Ok(json) =>
				match SiteApi.post_with!(site, results_path, json, Worker.post_policy) {
					Ok(_) => {}
					Err(err) => Run.log!("posting ${result.workload}/${result.competitor}: ${describe(err)} (the racer posts it again from the file)")
				}
			Err(Failed(why)) => Run.log!("posting ${result.workload}/${result.competitor}: ${why}")
		}
	}
	raced = Race.target!(race, competitors, target, config.seed.to_u64_wrap(), { report!, begin!: |plan, index| post_steps!(plan, index + 1) })
	match follower {
		Ok(child) => {
			_ = child.kill!()
			_ = child.wait!()
			_ = Path.utf8(black_box).append_utf8!("black box ended\n")
			{}
		}
		Err(None) => {}
	}
	raced.map_ok(|_| {})
}

## The black box: the server's kernel messages and, every 10 s, its memory,
## load and largest process, over one SSH session into a file here. A server
## that dies takes its own logs with it; this is what led up to it. Ends
## with its session (SIGPIPE ignored, the sampler's write fails once the
## session is gone). A child's output goes to a file only through a shell.
follow! : Machine.Where, Str => Try(Cmd.Child, Str)
follow! = |server, path| {
	script = "trap '' PIPE; journalctl -k -f -n 0 -o short-iso & trap 'kill $! 2>/dev/null' EXIT; while echo \"$(date -u +%FT%TZ) sample: $(awk '/^MemAvailable|^SwapFree/ {printf \" %s %d MiB\", $1, $2 / 1024}' /proc/meminfo) load $(cut -d' ' -f1 /proc/loadavg) largest $(ps -eo rss=,comm= --sort=-rss | awk 'NR == 1 {printf \"%s %d MiB\", $2, $1 / 1024}')\"; do sleep 10; done"
	argv = Machine.argv(server, script)
	command = "${Str.join_with(argv.map(Run.quote), " ")} > ${Run.quote(path)} 2>&1"
	match Cmd.new("bash").args(["-c", command].map(OsStr.from_str)).stdin(Null).spawn!() {
		Ok(child) => Ok(child)
		Err(CmdErr(err)) => Err(err.to_str())
		Err(Interrupted) => Err("interrupted")
	}
}

## The server's SSH, waited for: up to 5 minutes.
wait_ssh! : Machine.Where => Try({}, [Failed(Str), Interrupted])
wait_ssh! = |server| {
	var $tries = 0.U64
	var $last = ""
	while $tries < 60 {
		match Machine.shell!(server, "cloud-init status --wait > /dev/null; true") {
			Ok(_) => return Ok({})
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => {
				$last = why
				Sleep.millis!(5_000)?
				$tries = $tries + 1
			}
		}
	}
	Err(Failed("the server: no SSH after 5 minutes: ${$last}"))
}

## The results file with this result in it, replacing the one of its key:
## written whole, beside and renamed over.
keep! : Str, Results.Result => Try({}, Str)
keep! = |path, result| {
	kept =
		match Path.utf8(path).read_utf8!() {
			Ok(text) => Results.parse_list(text) ?? []
			Err(_) => []
		}
	same = |r| r.class == result.class and r.workload == result.workload and r.competitor == result.competitor
	all = if kept.any(same) kept.map(|r| if same(r) result else r) else kept.append(result)
	jsons = all.map_try(Results.to_json) ? |Failed(why)| why
	Path.utf8("${path}.new").write_utf8!("[${Str.join_with(jsons, ",")}]") ? |PathErr(err, _)| err.to_str()
	Path.utf8("${path}.new").rename!(Path.utf8(path)) ? |PathErr(err, _)| err.to_str()
	Ok({})
}

describe : [Failed(Str), Refused(Str), Interrupted] -> Str
describe = |err|
	match err {
		Failed(why) => why
		Refused(why) => why
		Interrupted => "interrupted"
	}

refused_as_failed : [Failed(Str), Refused(Str), Interrupted] -> [Failed(Str), Interrupted]
refused_as_failed = |err|
	match err {
		Failed(why) => Failed(why)
		Refused(why) => Failed(why)
		Interrupted => Interrupted
	}
