import pf.Env
import pf.OsStr
import pf.Path
import pf.Signal
import pf.Sleep
import pf.System
import pf.Utc
import Checkout
import Cloud
import Config
import Flags
import GitHub
import Guard
import JsonValue
import Machine
import Results
import Retry
import Run
import SiteApi
import Text
import Worker

## The racer takes what the site was asked (a check or a race), races the
## build it runs from (the one the site serves) through the guard with a
## worker on each loader, and tells the site how it went. A check races
## only when that build's race key is not the last race's. It holds no
## DigitalOcean token (the guard does) and no GitHub token (the builds are
## public).
Racer :: [].{
	Config : { site : Str, guard : Guard.Way, repository : Str, state : Str }

	## The config file: `guard_lines` names the socket of a guard that speaks
	## lines; `guard`, Go's, which speaks HTTP. `racer install` writes the
	## file with the guard it installs.
	parse_config : Str -> Try(Config, [NotConfig])
	parse_config = |text| {
		lines : Try({ site : Str, guard_lines : Str, repository : Str, state : Str }, _)
		lines = Json.parse(text)
		match lines {
			Ok(c) => Ok({ site: c.site, guard: Lines(c.guard_lines), repository: c.repository, state: c.state })
			Err(_) => {
				http : Try({ site : Str, guard : Str, repository : Str, state : Str }, _)
				http = Json.parse(text)
				match http {
					Ok(c) => Ok({ site: c.site, guard: Http(c.guard), repository: c.repository, state: c.state })
					Err(_) => Err(NotConfig)
				}
			}
		}
	}

	Self : { config : Config, site : SiteApi.Client, commit : Str }

	## `dragrace racer serve|check [-config F]`.
	command! : List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted, Restart])
	command! = |args| {
		{ verb, rest } =
			match args {
				[first, .. as others] => { verb: first, rest: others }
				[] => return Err(Failed("usage: dragrace racer serve|check [-config F]"))
			}
		flags = Flags.parse(rest, [{ name: "config", kind: Value("/etc/dragrace-racer/config.json"), usage: "the owner's config" }])?
		path = Flags.value(flags, "config")
		config = Racer.parse_config(Checkout.read!(path)?) ? |_| Failed("${path}: not the racer's config")
		token = Run.secret!("RACER_TOKEN", "racer-token")?
		if config.site == "" or token == "" {
			return Err(Failed("the site and its racer token (RACER_TOKEN) are required"))
		}
		racer = { config, site: SiteApi.client(config.site, token), commit: Racer.own_commit!() }
		match verb {
			"check" => {
				_ = SiteApi.call!(racer.site, POST, "/api/requests?kind=check", Err(None), Retry.site) ? |err| as_failed(err)
				Ok({})
			}
			"serve" => {
				# systemctl stop: what is waiting returns Interrupted, and a run
				# racing deletes its droplets and ends before the racer does.
				match System.target!().os() {
					Linux(os) => Signal.catch!([Interrupt, Terminate(os.unix())]) ? |_| Failed("signals: not caught")
					_ => return Err(Failed("the racer runs on Linux"))
				}
				serve!(racer)
			}
			_ => Err(Failed("unknown: dragrace racer ${verb}"))
		}
	}

	## The commit this binary was built from: the `dragrace.commit` beside it,
	## which the bundle writes and the update keeps; "" for one built by hand,
	## which updates itself to the newest build.
	own_commit! : () => Str
	own_commit! = || {
		match Env.exe_path!() {
			Ok(exe) => (Path.utf8("${exe.display()}.commit").read_utf8!() ?? "").trim()
			Err(_) => ""
		}
	}

	## How long to wait before asking the site again after `refused` runs in
	## a row it did not record: 30 s, then a minute doubling to half an hour,
	## so a site that refuses every run is asked fewer than fifty times a day.
	request_wait_ms : U64 -> U64
	request_wait_ms = |refused|
		if refused == 0 {
			30_000
		} else {
			doubled = 60_000 * 2.U64.pow(if refused - 1 > 5 5 else refused - 1)
			if doubled > 30 * 60_000 30 * 60_000 else doubled
		}

	## How long a class's worker may run: a quarter hour before the guard
	## deletes its droplets, the time to fetch the results and tear down.
	worker_minutes : U64 -> U64
	worker_minutes = |age| if age > 25 age - 15 else 10

	## What a check would race tonight, from the builds and the masters: the
	## newest build of the racer's own commit; new when its race key is not
	## the last race's; a master past it is tonight's too, before its build.
	Tonight : { commits : List((Str, Str)), build : GitHub.Build, new : Bool, raced : List((Str, Str)), unbuilt : List(Str) }

	tonight : List(GitHub.Build), Str, List((Str, Str)), List((Str, Str)) -> Try(Tonight, [Failed(Str)])
	tonight = |builds, commit, masters, raced| {
		own = GitHub.newest_of_commit(builds, commit) ? |_| Failed("no build of this racer's commit ${Str.inspect(Text.take(commit, 7))} among the newest (one just installed updates itself within 10 minutes)")
		last = GitHub.with_commits(builds, raced)
		var $new =
			match last {
				Ok(b) => b.info.race_key == "" or b.info.race_key != own.info.race_key
				Err(_) => Bool.True
			}
		var $commits = own.info.commits
		var $unbuilt = []
		for name in GitHub.upstream {
			master = GitHub.value_of(masters, name)
			if master != GitHub.value_of($commits, name) {
				$unbuilt = $unbuilt.append(name)
				$commits = $commits.keep_if(|(n, _)| n != name).append((name, master))
				$new = $new or master != GitHub.value_of(raced, name)
			}
		}
		Ok({ commits: $commits, build: own, new: $new, raced, unbuilt: $unbuilt })
	}

	## What the race page's line on tonight is told: tonight's commits, or,
	## with nothing new, the last race's, which the site reads as nothing new.
	posted : Tonight -> List((Str, Str))
	posted = |t| if t.new t.commits else t.raced

	## Each raced repository's commit, and whether it is not the last race's.
	commits_post : List((Str, Str)), List((Str, Str)) -> List({ repository : Str, commit_sha : Str, new : Bool })
	commits_post = |heads, raced|
		GitHub.raced.map(|name| { repository: name, commit_sha: GitHub.value_of(heads, name), new: GitHub.value_of(heads, name) != GitHub.value_of(raced, name) })
}

serve! : Racer.Self => Try({}, [BadFlag(Str), Failed(Str), Interrupted, Restart])
serve! = |racer| {
	recover!(racer)
	var $heads_at = 0.I128
	var $update_at = 0.I128
	var $refused = 0.U64
	while Bool.True {
		now = Utc.now!().to_millis_since_epoch()
		if now - $heads_at > 10 * 60_000 {
			$heads_at = now
			match post_heads!(racer) {
				Ok({}) => {}
				Err(err) => Run.log!("heads: ${describe(err)}")
			}
		}
		# A racer that does not know its build (one installed by hand, or
		# updated by a racer that kept no commit) races nothing: it would
		# fail every request. It updates first.
		handled = if racer.commit == "" Ok(Idle) else handle_next!(racer)
		match handled {
			Ok(Handled) => {
				$refused = 0
			}
			Ok(Idle) => {
				$refused = 0
				if now - $update_at > 10 * 60_000 {
					$update_at = now
					match update!(racer) {
						Ok({}) => {}
						Err(Restart) => return Err(Restart)
						Err(err) => Run.log!("update: ${describe(err)}")
					}
				}
			}
			Err(NotRecorded(why)) => {
				$refused = $refused + 1
				Run.log!("request: ${why}; asking again in ${(Racer.request_wait_ms($refused) // 1000).to_str()} s")
			}
			Err(Interrupted) => return Ok({})
			Err(err) => Run.log!("request: ${describe(err)}")
		}
		match Sleep.millis!(Racer.request_wait_ms($refused)) {
			Ok({}) => {}
			# systemctl stop: a racer stopped records nothing; the request
			# stays, and the racer started again takes it.
			Err(Interrupted) => return Ok({})
		}
	}
}

handle_next! : Racer.Self => Try([Handled, Idle], [Failed(Str), Refused(Str), NotRecorded(Str), Interrupted, Restart])
handle_next! = |racer| {
	next = next!(racer)?
	match next.waiting.first() {
		Err(_) => Ok(Idle)
		Ok(request) => {
			handled = handle!(racer, request, next.raced)
			match handled {
				Err(NotRecorded(why)) => {
					# Nothing new to copy: a backup each time would push the
					# nights' copies out of the thirty kept.
					return Err(NotRecorded(why))
				}
				Err(Interrupted) => return Err(Interrupted)
				_ => {}
			}
			match SiteApi.call!(racer.site, POST, "/api/backup", Err(None), Retry.site) {
				Ok(_) => {}
				Err(err) => Run.log!("backup: ${describe(err)}")
			}
			handled.map_ok(|_| Handled)
		}
	}
}

## /api/racer/next: the requests waiting, and the newest finished run's
## commits.
next! : Racer.Self => Try({ waiting : List({ id : I64, kind : Str, asked_by : Str }), raced : List((Str, Str)) }, [Failed(Str), Refused(Str), Interrupted])
next! = |racer| {
	text = SiteApi.get!(racer.site, "/api/racer/next")?
	parsed : Try({ waiting : List({ id : I64, kind : Str, asked_by : Str }), raced : List({ repository : Str, commit_sha : Str }) }, _)
	parsed = Json.parse(text)
	next = parsed ? |_| Failed("/api/racer/next: not its answer")
	Ok({ waiting: next.waiting, raced: next.raced.map(|r| (r.repository, r.commit_sha)) })
}

tonight! : Racer.Self, List((Str, Str)) => Try(Racer.Tonight, [Failed(Str), Interrupted])
tonight! = |racer, raced| {
	builds = GitHub.builds!(racer.config.repository)?
	org =
		match racer.config.repository.split_first("/") {
			Ok({ before, .. }) => before
			Err(_) => racer.config.repository
		}
	masters = GitHub.masters!(org)?
	Racer.tonight(builds, racer.commit, masters, raced)
}

post_heads! : Racer.Self => Try({}, [Failed(Str), Refused(Str), Interrupted])
post_heads! = |racer| {
	next = next!(racer)?
	t = tonight!(racer, next.raced) ? |err| as_refusable(err)
	post_heads_of!(racer, Racer.posted(t))
}

post_heads_of! : Racer.Self, List((Str, Str)) => Try({}, [Failed(Str), Refused(Str), Interrupted])
post_heads_of! = |racer, heads| {
	body = Json.to_str(GitHub.raced.map(|name| { repository: name, commit_sha: GitHub.value_of(heads, name) }))
	_ = SiteApi.post!(racer.site, "/api/heads", body)?
	Ok({})
}

## A run as the racer posts it (site/Api.roc, RunPost).
RunPost : { id : Str, request_id : I64, trigger : Str, status : Str, reason : Str, where_raced : Str, started_at : Str, worker_token : Str, commits : List({ repository : Str, commit_sha : Str, new : Bool }) }

## One request: a check with nothing new is a skipped run; anything else
## races tonight's build.
handle! : Racer.Self, { id : I64, kind : Str, asked_by : Str }, List((Str, Str)) => Try({}, [Failed(Str), Refused(Str), NotRecorded(Str), Interrupted])
handle! = |racer, request, raced| {
	clock = Utc.now!()
	started = clock.to_iso_8601()
	run = {
		id: "${started.replace_each(":", "")}-cloud",
		request_id: request.id,
		trigger: if request.asked_by == "owner" "manual" else "timer",
		status: "",
		reason: "",
		where_raced: "cloud",
		started_at: started,
		worker_token: "",
		commits: [],
	}
	t =
		match tonight!(racer, raced) {
			Ok(found) => found
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => return not_raced!(racer, run, "failed", "tonight's build: ${why}")
		}
	# The race page's line on tonight says it at once.
	match post_heads_of!(racer, Racer.posted(t)) {
		Ok({}) => {}
		Err(err) => Run.log!("heads: ${describe(err)}")
	}
	with_commits = { ..run, commits: Racer.commits_post(t.commits, raced) }
	if request.kind == "check" and !t.new {
		Run.log!("check: nothing raced changed since the last finished run: skipped")
		return not_raced!(racer, with_commits, "skipped", "nothing new since the last finished race")
	}
	built =
		match await_build!(racer, t) {
			Ok(found) => found
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => return not_raced!(racer, with_commits, "failed", "tonight's build: ${why}")
		}
	awaited = { ..with_commits, commits: Racer.commits_post(built.commits, raced) }
	root =
		match fetch_build!(racer, awaited.id, built) {
			Ok(dir) => dir
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => return not_raced!(racer, awaited, "failed", "the build: ${why}")
		}
	race_run!(racer, root, awaited, clock)
}

## A run that did not race: skipped, refused, or failed before its
## droplets. One the site did not take stays a request, taken again.
not_raced! : Racer.Self, RunPost, Str, Str => Try({}, [Failed(Str), Refused(Str), NotRecorded(Str), Interrupted])
not_raced! = |racer, run, status, reason| {
	posted = SiteApi.post!(racer.site, "/api/runs", Json.to_str({ ..run, status, reason }))
	match posted {
		Ok(_) => if status == "failed" Err(Failed(reason)) else Ok({})
		Err(Interrupted) => Err(Interrupted)
		Err(err) => Err(NotRecorded("the site did not record the run: ${describe(err)}"))
	}
}

## Waits for the build of tonight's unbuilt masters, asking every ten
## minutes and telling the site, for at most six hours.
await_build! : Racer.Self, Racer.Tonight => Try(Racer.Tonight, [Failed(Str), Interrupted])
await_build! = |racer, first| {
	var $t = first
	var $waited = 0.U64
	while !$t.unbuilt.is_empty() {
		unbuilt = Str.join_with($t.unbuilt.map(|name| "${name} ${Text.take(GitHub.value_of($t.commits, name), 7)}"), ", ")
		if $waited + 10 > 6 * 60 {
			return Err(Failed("no build of ${unbuilt} within 6h0m0s"))
		}
		Run.log!("waiting for the build of ${unbuilt}")
		Sleep.millis!(10 * 60_000)?
		$waited = $waited + 10
		$t = tonight!(racer, $t.raced)?
		match post_heads_of!(racer, Racer.posted($t)) {
			Ok({}) => {}
			Err(err) => Run.log!("heads: ${describe(err)}")
		}
	}
	Ok($t)
}

## Tonight's build's race.tar.gz downloaded and unpacked: the checkout to
## race. The newest five runs' directories are kept.
fetch_build! : Racer.Self, Str, Racer.Tonight => Try(Str, [Failed(Str), Interrupted])
fetch_build! = |racer, id, t| {
	runs = "${racer.config.state}/runs"
	dir = "${runs}/${id}"
	Path.utf8(dir).create_all!() ? |PathErr(err, _)| Failed("${dir}: ${err.to_str()}")
	prune_runs!(runs, 5)
	tarball = "${dir}/race.tar.gz"
	url = GitHub.value_of(t.build.assets, "race.tar.gz")
	sha = GitHub.value_of(t.build.info.files, "race.tar.gz")
	GitHub.download!(url, sha, tarball)?
	root = "${dir}/bundle"
	Path.utf8(root).create_all!() ? |PathErr(err, _)| Failed("${root}: ${err.to_str()}")
	Run.run!(root, [], ["tar", "-xzf", tarball])?
	Ok(root)
}

## Keep the newest `keep` run directories (their names sort as their times).
prune_runs! : Str, U64 => {}
prune_runs! = |dir, keep| {
	entries = (Path.utf8(dir).list!() ?? []).map(|p| p.display())
	names = Text.sorted(entries)
	if names.len() > keep {
		for old in names.take_first(names.len() - keep) {
			_ = Path.utf8(old).delete_all!()
		}
	}
}

## Make the run at the site, race it, post every result again, end it.
race_run! : Racer.Self, Str, RunPost, Utc => Try({}, [Failed(Str), Refused(Str), NotRecorded(Str), Interrupted])
race_run! = |racer, root, run, clock| {
	race =
		match Checkout.race!(root) {
			Ok(r) => r
			Err(Failed(why)) => return not_raced!(racer, run, "failed", why)
		}
	competitors =
		match Checkout.competitors!(root, race.competitors) {
			Ok(cs) => cs
			Err(Failed(why)) => return not_raced!(racer, run, "failed", why)
		}
	build_seconds = seconds_since!(clock)
	seed = Utc.now!().to_nanos_since_epoch().to_i64_wrap()
	post =
		match race_post!(root, race, competitors, seed) {
			Ok(p) => p
			Err(Failed(why)) => return not_raced!(racer, run, "failed", why)
		}
	token = Run.random_token!() ? |_| Failed("no randomness for the worker token")
	racing = { ..run, status: "racing", worker_token: token }
	body = Json.to_str({ id: racing.id, request_id: racing.request_id, trigger: racing.trigger, status: racing.status, reason: racing.reason, where_raced: racing.where_raced, started_at: racing.started_at, worker_token: racing.worker_token, commits: racing.commits, race: post })
	match SiteApi.post!(racer.site, "/api/runs", body) {
		Ok(_) => {}
		Err(Interrupted) => return Err(Interrupted)
		Err(err) => return Err(NotRecorded("the site did not record the run: ${describe(err)}"))
	}
	remember!(racer, run.id)
	raced = race_cloud!(racer, root, racing, race, seed)
	# Stopped mid-run: the droplets are gone, the rest is told before the
	# racer exits.
	_ = Signal.poll!()
	# Every result again, as the workers kept them: whatever a worker could
	# not post is posted now, the rest replaces itself.
	for result in raced.results {
		match Results.to_json(result) {
			Ok(json) =>
				match SiteApi.post!(racer.site, "/api/runs/${run.id}/results", json) {
					Ok(_) => {}
					Err(err) => Run.log!("result ${result.class}/${result.workload}/${result.competitor}: ${describe(err)}")
				}
			Err(Failed(why)) => Run.log!(why)
		}
	}
	timing = { ..raced.timing, build_seconds, seconds: seconds_since!(clock), cost_usd: raced.timing.droplets.map(|d| d.cost_usd).sum() }
	{ status, reason } =
		match raced.outcome {
			Ok({}) => { status: "finished", reason: "" }
			Err(Refused(why)) => { status: "refused", reason: why }
			Err(Failed(why)) => { status: "failed", reason: why }
			Err(Interrupted) => { status: "interrupted", reason: "the racer stopped during the run" }
		}
	end = Json.to_str_try({ status, reason, finished_at: Utc.now!().to_iso_8601(), timing }) ?? "{}"
	ended = SiteApi.post!(racer.site, "/api/runs/${run.id}/end", end)
	forget!(racer)
	_ = ended ? |err| as_recorded(err)
	Run.log!("run ${run.id}: ${status} ${reason}")
	raced.outcome.map_err(|err| as_recorded(err))
}

Timing : { seconds : F64, build_seconds : F64, launch_seconds : F64, racing_seconds : F64, classes : List({ class : Str, seconds : F64 }), droplets : List({ role : Str, class : Str, size : Str, price_hourly : F64, seconds : F64, cost_usd : F64 }), cost_usd : F64 }

no_timing : Timing
no_timing = { seconds: 0, build_seconds: 0, launch_seconds: 0, racing_seconds: 0, classes: [], droplets: [], cost_usd: 0 }

## One class racing: its worker on its loader, polled until it ends.
Class : { class : Config.ServerClass, started_ms : I128, seconds : F64, ended : Bool, results : List(Results.Result), why : Str }

## Every class on its own pair of droplets at once, a worker on each
## loader. The racer only starts the workers and polls them, every 30 s:
## the racing is theirs, on the loaders.
race_cloud! : Racer.Self, Str, RunPost, Config.Race, I64 => { results : List(Results.Result), timing : Timing, outcome : Try({}, [Refused(Str), Failed(Str), Interrupted]) }
race_cloud! = |racer, root, run, race, seed| {
	failed = |err| { results: [], timing: no_timing, outcome: Err(err) }
	guard = racer.config.guard
	prices =
		match Cloud.check_sizes!(guard, race.cloud) {
			Ok(p) => p
			Err(err) => return failed(err)
		}
	allowed =
		match Guard.allowed!(guard) {
			Ok(a) => a
			Err(err) => return failed(err)
		}
	refusals = Cloud.refusals(race.cloud, prices, allowed)
	if !refusals.is_empty() {
		return failed(Refused("${Str.join_with(refusals, "; ")} (race.json changed since the guard's install: dragrace racer install again)"))
	}
	# The droplets live as long as race.json says, or less when the guard,
	# installed earlier, deletes them sooner.
	age = race.cloud.max_age_minutes.min(allowed.age_max_minutes)
	worker_ms = Racer.worker_minutes(age).to_i128() * 60_000
	tarball = "${Checkout.parent(root)}/race.tar.gz"
	launched = Utc.now!()
	{ fleet, error } = Cloud.launch!(guard, race)
	match error {
		Ok({}) => {}
		Err(err) => {
			_ = Signal.poll!()
			gone = Cloud.destroy!(guard, fleet)
			return { results: [], timing: { ..no_timing, droplets: Cloud.costs(gone, prices, Utc.now!().to_millis_since_epoch()) }, outcome: Err(err) }
		}
	}
	launch_seconds = seconds_since!(launched)
	racing = Utc.now!()
	var $fleet = fleet
	var $classes = []
	for class in race.cloud.servers {
		started = Utc.now!().to_millis_since_epoch()
		begun = start_worker!(racer, $fleet, class, run, seed, tarball)
		$classes = $classes.append({ class, started_ms: started, seconds: 0, ended: Bool.False, results: [], why: "" })
		match begun {
			Ok({}) => Run.log!("[${class.name}] worker started on its loader")
			Err(why) => {
				$classes = end_class(Utc.now!(), $classes, class.name, Err(why))
				$fleet = settle!(guard, $fleet, class.name, tarball)
			}
		}
	}
	var $stopped = Bool.False
	while !$stopped and $classes.any(|c| !c.ended) {
		match Sleep.millis!(30_000) {
			Ok({}) => {}
			Err(Interrupted) => {
				_ = Signal.poll!()
				$stopped = Bool.True
			}
		}
		for c in $classes.keep_if(|c| !c.ended) {
			if $stopped {
				$classes = end_class(Utc.now!(), $classes, c.class.name, Err("the racer stopped"))
				$fleet = settle!(guard, $fleet, c.class.name, tarball)
			} else {
				match poll_worker!($fleet, c, worker_ms) {
					Running => {}
					Ended(how) => {
						$classes = end_class(Utc.now!(), $classes, c.class.name, how)
						$fleet = settle!(guard, $fleet, c.class.name, tarball)
					}
				}
			}
		}
	}
	racing_seconds = seconds_since!(racing)
	gone = Cloud.destroy!(guard, $fleet)
	timing = {
		..no_timing,
		launch_seconds,
		racing_seconds,
		classes: $classes.map(|c| { class: c.class.name, seconds: c.seconds }),
		droplets: Cloud.costs(gone, prices, Utc.now!().to_millis_since_epoch()),
	}
	whys = $classes.keep_if(|c| c.why != "").map(|c| "${c.class.name}: ${c.why}")
	outcome =
		if $stopped {
			Err(Interrupted)
		} else if whys.is_empty() {
			Ok({})
		} else {
			Err(Failed(Str.join_with(whys, "; ")))
		}
	{ results: $classes.join_map(|c| c.results), timing, outcome }
}

end_class : Utc, List(Class), Str, Try(List(Results.Result), Str) -> List(Class)
end_class = |now, classes, name, how|
	classes.map(
		|c|
			if c.class.name != name {
				c
			} else {
				seconds = (now.to_millis_since_epoch() - c.started_ms).to_f64() / 1000
				match how {
					Ok(results) => { ..c, ended: Bool.True, seconds, results }
					Err(why) => { ..c, ended: Bool.True, seconds, why }
				}
			},
	)

## A class ended: its logs home, its droplets deleted.
settle! : Guard.Way, Cloud.Fleet, Str, Str => Cloud.Fleet
settle! = |guard, fleet, class, tarball| {
	keep_logs!(fleet, class, Checkout.parent(tarball))
	Cloud.release_class!(guard, fleet, class)
}

worker_home : Str
worker_home = "/root/dragrace"

## The race's build, the run's key and the worker's config on the class's
## loader, and its worker started there as a unit of its own.
start_worker! : Racer.Self, Cloud.Fleet, Config.ServerClass, RunPost, I64, Str => Try({}, Str)
start_worker! = |racer, fleet, class, run, seed, tarball| {
	home = worker_home
	{ loader, server } = Cloud.pair(fleet, class.name) ? |_| "no droplets"
	on = Cloud.machine(fleet, loader)
	Machine.put!(on, tarball, "${home}/race.tar.gz") ? |err| shell_why(err)
	Machine.put!(on, fleet.key, "${home}/key") ? |err| shell_why(err)
	config : Worker.Config
	config = { run_id: run.id, class, seed, site: racer.site.base, token: run.worker_token, server_host: server.private, key: "${home}/key", known_hosts: "${home}/known_hosts", results: "${home}/results.json" }
	local = "${fleet.dir}/worker-${class.name}.json"
	Path.utf8(local).write_utf8!(Json.to_str(config)) ? |PathErr(err, _)| "${local}: ${err.to_str()}"
	Machine.put!(on, local, "${home}/worker.json") ? |err| shell_why(err)
	start = Str.join_with(
		[
			"chmod 600 ${home}/key ${home}/worker.json",
			"mkdir -p ${home}/bundle",
			"tar -xzf ${home}/race.tar.gz -C ${home}/bundle",
			"systemd-run --unit=dragrace-worker --working-directory=${home}/bundle ${home}/bundle/out/bin/dragrace worker -config ${home}/worker.json",
		],
		" && ",
	)
	_ = Machine.shell!(on, start) ? |err| shell_why(err)
	Ok({})
}

## A class's worker, asked whether it is still running: once it is not,
## its results; past its time, stopped.
poll_worker! : Cloud.Fleet, Class, I128 => [Running, Ended(Try(List(Results.Result), Str))]
poll_worker! = |fleet, c, worker_ms| {
	on =
		match Cloud.pair(fleet, c.class.name) {
			Ok({ loader, .. }) => Cloud.machine(fleet, loader)
			Err(_) => return Ended(Err("no droplets"))
		}
	state = Machine.shell!(on, "systemctl is-active dragrace-worker; true") ?? ""
	if state == "active" or state == "activating" {
		if Utc.now!().to_millis_since_epoch() - c.started_ms > worker_ms {
			_ = Machine.shell!(on, "systemctl stop dragrace-worker")
			Ended(Err("the worker ran past ${(worker_ms // 60_000).to_str()} minutes"))
		} else {
			Running
		}
	} else {
		results = "${worker_home}/results.json"
		match Machine.shell!(on, "cat ${results}") {
			Ok(text) =>
				match Results.parse_list(text) {
					Ok(list) => {
						logs = Machine.shell!(on, "journalctl -u dragrace-worker --no-pager -n 5 -o cat; true") ?? ""
						Run.log!("[${c.class.name}] worker done: ${list.len().to_str()} results; its last lines:\n${logs}")
						Ended(Ok(list))
					}
					Err(Failed(why)) => Ended(Err("the worker's results: ${why}"))
				}
			Err(err) => {
				reason = Machine.shell!(on, "cat ${Worker.failed_path(results)}") ?? ""
				if reason != "" {
					Ended(Err("the worker failed: ${reason}"))
				} else {
					Ended(Err("the worker's results: ${shell_why(err)}"))
				}
			}
		}
	}
}

## A class's worker log and black box from its loader, and its server's
## sshd log (a reset at a worker's first connection left no trace of why),
## into the run's directory on the racer.
keep_logs! : Cloud.Fleet, Str, Str => {}
keep_logs! = |fleet, class, dir| {
	match Cloud.pair(fleet, class) {
		Err(_) => {}
		Ok({ loader, server }) => {
			files = [
				(Cloud.machine(fleet, loader), "worker-${class}.log", "journalctl -u dragrace-worker --no-pager -o short-iso"),
				(Cloud.machine(fleet, loader), "server-${class}.log", "cat ${worker_home}/server.log"),
				(Cloud.machine(fleet, server), "sshd-${class}.log", "journalctl -u ssh -u ssh.socket --no-pager -o short-iso"),
			]
			for (on, name, script) in files {
				match Machine.shell!(on, script) {
					Ok(text) if text != "" =>
						match Path.utf8("${dir}/${name}").write_utf8!("${text}\n") {
							Ok({}) => {}
							Err(PathErr(err, _)) => Run.log!("[${class}] keeping ${name}: ${err.to_str()}")
						}
					Ok(_) => {}
					Err(err) => Run.log!("[${class}] keeping ${name}: ${shell_why(err)}")
				}
			}
		}
	}
}

shell_why : [Failed(Str), Interrupted] -> Str
shell_why = |err|
	match err {
		Failed(why) => why
		Interrupted => "interrupted"
	}

seconds_since! : Utc => F64
seconds_since! = |from| Utc.now!().since(from).to_nanos().to_f64() / 1e9

## race.json and the versions raced, as the site keeps them (RacePost).
race_post! = |root, race, competitors, seed| {
	race_json = Checkout.read!("${root}/race.json")?
	text = Checkout.read!("${Checkout.out(root)}/toolchain.json")?
	used = JsonValue.parse(text) ? |_| Failed("out/toolchain.json: not JSON")
	versions = [
		("zig", used.get("zig").text()),
		("roc", used.get("roc").text()),
		("oha", race.oha.version),
		("go", used.get("go").text()),
		("rust", used.get("rust").text()),
		("axum", used.get("axum").text()),
		("tokio", used.get("tokio").text()),
		("droplet_image", race.cloud.image),
	].map(|(name, version)| { name, version })
	post = {
		seed,
		region: race.cloud.region,
		image: race.cloud.image,
		port: race.port,
		rounds: race.rounds,
		warmup_seconds: race.warmup_seconds,
		measure_seconds: race.measure_seconds,
		race_json,
		versions,
		competitors: competitors.map(|c| { name: c.name, title: c.title, language: c.language, framework: c.framework }),
		workloads: race.workloads.map(|w| { name: w.name, test: w.test, kind: Config.kind(w), title: w.title, summary: w.summary, method: w.method, path: w.path, body_bytes: w.body_bytes, content_type: w.content_type, connections: w.connections, keepalive: w.keepalive, http2: w.http2, streams: if w.http2 w.streams.max(1) else 0, tls: w.tls, protocol: w.protocol }),
		classes: race.cloud.servers,
	}
	Ok(post)
}

## The run racing, on the racer's disk: a racer restarted mid-run finds it.
remember! : Racer.Self, Str => {}
remember! = |racer, id| {
	_ = Path.utf8("${racer.config.state}/racing").write_utf8!(id)
	{}
}

forget! : Racer.Self => {}
forget! = |racer| {
	_ = Path.utf8("${racer.config.state}/racing").delete!()
	{}
}

## End a run a previous racer did not finish, and delete every race droplet
## it may have left.
recover! : Racer.Self => {}
recover! = |racer| {
	match Path.utf8("${racer.config.state}/racing").read_utf8!() {
		Err(_) => {}
		Ok(text) => {
			id = text.trim()
			Run.log!("run ${id} was racing when the racer stopped: ending it")
			for droplet in Guard.tagged!(racer.config.guard) ?? [] {
				_ = Guard.delete!(racer.config.guard, droplet.id)
			}
			end = Json.to_str_try({ status: "interrupted", reason: "the racer stopped during the run", finished_at: Utc.now!().to_iso_8601(), timing: no_timing }) ?? "{}"
			match SiteApi.post!(racer.site, "/api/runs/${id}/end", end) {
				Ok(_) => {}
				Err(err) => Run.log!("ending ${id}: ${describe(err)}")
			}
			forget!(racer)
		}
	}
}

## Replace this racer's binary with the newest build of the commit the site
## serves, when that is not the racer's own, and exit for systemd to start
## it again: the racer and the site speak one API, so a site that did not
## deploy keeps the racer that works with it.
update! : Racer.Self => Try({}, [Failed(Str), Interrupted, Restart])
update! = |racer| {
	served = site_commit!(racer)
	if served == "" {
		return Err(Failed("held at ${Text.take(racer.commit, 7)}: the site says no commit"))
	}
	if served == racer.commit {
		return Ok({})
	}
	builds = GitHub.builds!(racer.config.repository)?
	build = GitHub.newest_of_commit(builds, served) ? |_| Failed("held at ${Text.take(racer.commit, 7)}: no build of ${Text.take(served, 7)}, the commit the site serves")
	dir = "${racer.config.state}/update"
	_ = Path.utf8(dir).delete_all!()
	Path.utf8(dir).create_all!() ? |PathErr(err, _)| Failed("${dir}: ${err.to_str()}")
	tarball = "${dir}/race.tar.gz"
	GitHub.download!(GitHub.value_of(build.assets, "race.tar.gz"), GitHub.value_of(build.info.files, "race.tar.gz"), tarball)?
	Run.run!(dir, [], ["tar", "-xzf", tarball, "out/bin/dragrace"])?
	bin = "${racer.config.state}/bin"
	Path.utf8(bin).create_all!() ? |PathErr(err, _)| Failed("${bin}: ${err.to_str()}")
	moved! = |from, to| Path.utf8(from).rename!(Path.utf8(to)).map_err(|PathErr(err, _)| Failed("${to}: ${err.to_str()}"))
	Path.utf8("${dir}/dragrace.commit").write_utf8!("${served}\n") ? |PathErr(err, _)| Failed("${dir}: ${err.to_str()}")
	# The binary first, then its commit: stopped between, the racer is new
	# and says it is old, and only updates once more.
	moved!("${dir}/out/bin/dragrace", "${bin}/dragrace.new")?
	moved!("${bin}/dragrace.new", "${bin}/dragrace")?
	moved!("${dir}/dragrace.commit", "${bin}/dragrace.commit")?
	Run.log!("updated to ${served}: restarting")
	Err(Restart)
}

## The commit of this repository the site serves, from the /site.json its
## release carries; "" when it does not say.
site_commit! : Racer.Self => Str
site_commit! = |racer|
	match SiteApi.get!(racer.site, "/site.json") {
		# Its key has a hyphen, which no record field can.
		Ok(text) => (JsonValue.parse(text) ?? Null).get("fourneau-dragrace").text()
		Err(_) => ""
	}

describe : [Failed(Str), Refused(Str), NotRecorded(Str), Interrupted, Restart] -> Str
describe = |err|
	match err {
		Failed(why) => why
		Refused(why) => why
		NotRecorded(why) => why
		Interrupted => "interrupted"
		Restart => "restarting"
	}

as_failed : [Failed(Str), Refused(Str), Interrupted] -> [BadFlag(Str), Failed(Str), Interrupted, Restart]
as_failed = |err|
	match err {
		Failed(why) => Failed(why)
		Refused(why) => Failed(why)
		Interrupted => Interrupted
	}

as_refusable : [Failed(Str), Interrupted] -> [Failed(Str), Refused(Str), Interrupted]
as_refusable = |err|
	match err {
		Failed(why) => Failed(why)
		Interrupted => Interrupted
	}

as_recorded : [Failed(Str), Refused(Str), Interrupted] -> [Failed(Str), Refused(Str), NotRecorded(Str), Interrupted]
as_recorded = |err|
	match err {
		Failed(why) => Failed(why)
		Refused(why) => Refused(why)
		Interrupted => Interrupted
	}

build_of = |commit, race_key| {
	info: { commits: [("fourneau-dragrace", commit), ("fourneau", "f1"), ("roux", "r1")], files: [], competitors: [], race_key, harness_key: "" },
	assets: [],
}

# Go's guard's config, on a racer not installed again since: the HTTP guard.
expect {
	old = "{\n  \"site\": \"https://fourneau.y2kbugger.com\",\n  \"guard\": \"/run/dragrace-guard/guard.sock\",\n  \"repository\": \"Eldhus/fourneau-dragrace\",\n  \"state\": \"/var/lib/dragrace-racer\"\n}"
	Racer.parse_config(old).map_ok(|c| c.guard) == Ok(Http("/run/dragrace-guard/guard.sock"))
}

expect Racer.parse_config("{\"site\":\"s\"}") == Err(NotConfig)

expect {
	# The last race raced this build's own commits and key: nothing new.
	t = Racer.tonight([build_of("d1", "k")], "d1", [("fourneau", "f1"), ("roux", "r1")], [("fourneau-dragrace", "d1"), ("fourneau", "f1"), ("roux", "r1")])
	match t {
		Ok(found) => !found.new and found.unbuilt == []
		Err(_) => Bool.False
	}
}

expect {
	# A roux master past the build: tonight's, before its build.
	t = Racer.tonight([build_of("d1", "k")], "d1", [("fourneau", "f1"), ("roux", "r2")], [("fourneau-dragrace", "d1"), ("fourneau", "f1"), ("roux", "r1")])
	match t {
		Ok(found) => found.new and found.unbuilt == ["roux"] and GitHub.value_of(found.commits, "roux") == "r2"
		Err(_) => Bool.False
	}
}

expect {
	# Another build of the racer's commit with a new race key: new.
	t = Racer.tonight([build_of("d1", "k2"), build_of("d0", "k")], "d1", [("fourneau", "f1"), ("roux", "r1")], [("fourneau-dragrace", "d0"), ("fourneau", "f1"), ("roux", "r1")])
	match t {
		Ok(found) => found.new
		Err(_) => Bool.False
	}
}

expect Racer.tonight([], "d1", [], []).is_err()
expect Racer.request_wait_ms(0) == 30_000
expect Racer.request_wait_ms(1) == 60_000
expect Racer.request_wait_ms(3) == 240_000
expect Racer.request_wait_ms(10) == 30 * 60_000
expect Racer.worker_minutes(240) == 225
expect Racer.commits_post([("fourneau-dragrace", "a"), ("fourneau", "b"), ("roux", "c")], [("fourneau-dragrace", "a"), ("fourneau", "x"), ("roux", "c")]).map(|c| c.new) == [Bool.False, Bool.True, Bool.False]
