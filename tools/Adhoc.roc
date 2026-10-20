import pf.Cmd
import pf.Env
import pf.Monotonic
import pf.OsStr
import pf.Path
import pf.Sleep
import pf.Stderr
import pf.Stdout
import pf.Utc
import Build
import Checkout
import Cloud
import Conduit
import Config
import DigitalOcean
import Flags
import Guard
import Hash
import Keyring
import Local
import Machine
import Race
import Results
import Run
import Target
import Text
import Time
import Toolchain

## Ad-hoc races: two (or more) builds of a competitor, each at its own
## commits of this repository, fourneau and roux, raced against each other
## on one server droplet, in under a minute once the machines are up.
##
##     dragrace adhoc race -workloads templates \
##         roux:roux=templates,dragrace=templates \
##         roux:roux=templates-vm,dragrace=templates-vm
##     dragrace adhoc down
##
## What makes it fast: the machines are a session, kept warm between races
## and deleted after 20 minutes unused (a user systemd timer, re-armed by
## every race; `adhoc down -all` the backstop); a variant is built once per
## content, locally, in its own checkout updated in place, and uploaded once
## per session, stripped and compressed; every ssh call to the session
## shares one kept connection; and the race is short and interleaved (rounds
## of every variant in a new order each). A new session is made before the
## builds, not beside them: a cold one waits a minute longer.
##
## One command at a time holds the session (the idle reaper never deletes
## it mid-race): the command runs again under flock(1) on out/adhoc/lock.
##
## Standard output is a stream of events, one JSON object a line, for an
## agent or a script: resolved, built, session, uploaded, round, result.
## Standard error has the same for people, and the final table.
Adhoc :: [].{
	## A build to race: a competitor at chosen commits (REPOSITORY=REF each,
	## HEAD for the rest).
	Variant : { label : Str, competitor : Str, refs : List((Str, Str)) }

	## `dragrace adhoc race|down`.
	command! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted, Exited(I32)])
	command! = |root, args| {
		locked = (Env.var_str!(OsStr.from_str(lock_variable)) ?? "") == "held"
		match args {
			["race", .. as rest] => if locked race!(root, rest) else with_lock!(root, args, Bool.True)
			["down", .. as rest] =>
				if locked {
					down!(root, rest)
				} else {
					flags = Flags.parse(rest, down_flags)?
					with_lock!(root, args, !Flags.switch(flags, "if-idle"))
				}
			_ => Err(Failed("usage: dragrace adhoc race [-workloads W] [-rounds N] VARIANT... | adhoc down [-all]"))
		}
	}

	## A variant as given: `roux:roux=templates-vm,dragrace=templates-vm`.
	parse_variant : Str -> Try(Variant, [BadFlag(Str)])
	parse_variant = |text| {
		{ name, given } =
			match text.split_first(":") {
				Ok({ before, after }) => { name: before, given: after }
				Err(_) => { name: text, given: "" }
			}
		var $refs = repositories.map(|r| (r, "HEAD"))
		if given != "" {
			for pair in given.split_on(",") {
				match pair.split_first("=") {
					Ok({ before, after }) if repositories.contains(before) and after != "" => {
						$refs = $refs.map(|(r, ref)| if r == before (r, after) else (r, ref))
					}
					_ => return Err(BadFlag("variant \"${text}\": \"${pair}\" is not REPOSITORY=REF (dragrace, fourneau, roux)"))
				}
			}
		}
		Ok({ label: text, competitor: name, refs: $refs })
	}

	## One variant on one workload, against the first variant: the best
	## rounds' difference, and whether the rounds' ranges are apart (every
	## round of one above every round of the other) or overlap (within this
	## race's noise).
	Row : { workload : Str, variant : Str, valid : Bool, best_rps : F64, rps : List(F64), median_p99_ms : F64, delta_pct : F64, apart : Bool }

	compare : List(Str), List(Results.Result), List((Str, Str)) -> List(Row)
	compare = |workloads, results, labels| {
		var $rows = []
		for workload in workloads {
			var $base = Err(None)
			for (name, label) in labels {
				result = results.find_first(|r| r.workload == workload and r.competitor == name) ?? Results.empty("", workload, name)
				summary = Results.summarize(result.rounds)
				row = { workload, variant: label, valid: result.valid, best_rps: round2(summary.best_rps), rps: result.rounds.map(|r| round2(r.rps)), median_p99_ms: summary.median_p99_ms, delta_pct: 0, apart: Bool.False }
				match $base {
					Err(None) => {
						$base = Ok(row)
						$rows = $rows.append(row)
					}
					Ok(base) => {
						delta = if base.best_rps > 0 round2(100 * (row.best_rps - base.best_rps) / base.best_rps) else 0
						apart =
							match (lowest(row.rps), highest(row.rps), lowest(base.rps), highest(base.rps)) {
								(Ok(low), Ok(high), Ok(base_low), Ok(base_high)) => low > base_high or high < base_low
								_ => Bool.False
							}
						$rows = $rows.append({ ..row, delta_pct: delta, apart })
					}
				}
			}
		}
		$rows
	}

	table : List(Row) -> Str
	table = |rows| {
		head = "\n${Text.pad_right("workload", 10)} ${Text.pad_right("variant", 48)} ${Text.pad_left("req/s", 10)} ${Text.pad_left("vs 1st", 8)} ${Text.pad_left("p99 ms", 9)}  rounds\n"
		lines = rows.map(|row| {
			delta =
				if !row.valid {
					"INVALID"
				} else if row.delta_pct != 0 or row.apart {
					sign = if row.delta_pct >= 0 "+" else "-"
					"${sign}${Text.fixed(row.delta_pct.abs(), 1)}%${if row.apart "" else "~"}"
				} else {
					""
				}
			rounds = Str.join_with(row.rps.map(|r| Text.fixed(r, 0)), " ")
			"${Text.pad_right(row.workload, 10)} ${Text.pad_right(row.variant, 48)} ${Text.pad_left(Text.fixed(row.best_rps, 0), 10)} ${Text.pad_left(delta, 8)} ${Text.pad_left(Text.fixed(row.median_p99_ms, 2), 9)}  ${rounds}\n"
		})
		overlap = rows.any(|row| !row.apart and row.delta_pct != 0)
		"${head}${Str.join_with(lines, "")}${if overlap "(~: the rounds' ranges overlap, within this race's noise)\n" else ""}"
	}

	## The rounds kept: the saturated ones, as many as asked for when there
	## are, then the first others to make up the number; and how many were
	## dropped.
	kept : List(Results.Round), U64 -> { kept : List(Results.Round), dropped : U64 }
	kept = |rounds, wanted| {
		var $kept = []
		var $dropped = []
		for r in rounds {
			if r.cpu_busy_pct >= saturated and $kept.len() < wanted {
				$kept = $kept.append(r)
			} else {
				$dropped = $dropped.append(r)
			}
		}
		while $kept.len() < wanted and !$dropped.is_empty() {
			$kept = $kept.append($dropped.first() ?? Results.zero_round)
			$dropped = $dropped.drop_first(1)
		}
		{ kept: $kept, dropped: $dropped.len() }
	}
}

lock_variable : Str
lock_variable = "DRAGRACE_ADHOC_LOCK"

## The repositories a variant names commits of.
repositories : List(Str)
repositories = ["dragrace", "fourneau", "roux"]

home : Str
home = "/root/dragrace"

reap_unit : Str
reap_unit = "dragrace-adhoc-reap"

## Its own tag: the nightly race's guard and racer never see a session, and
## `adhoc down -all` sweeps it.
tag : Str
tag = "fourneau-dragrace-adhoc"

## Dedicated cores, so a difference is the builds'; deleted after 20
## minutes unused.
session_class : Str
session_class = "dedicated-2"

idle_minutes : U64
idle_minutes = 20

## A workload's warmup and measure, seconds: short, since rounds interleave.
warmup_seconds : U64
warmup_seconds = 1

measure_seconds : U64
measure_seconds = 4

## The server CPU a round needs to measure the server: below it something
## else held the load back (the loader dipping with it, no retransmits: the
## network or a neighbour), and the round measured that.
saturated : F64
saturated = 95.0

down_flags : List(Flags.Spec)
down_flags = [
	{ name: "if-idle", kind: Switch, usage: "only when unused for the session's idle minutes (the timer)" },
	{ name: "all", kind: Switch, usage: "and every ad-hoc droplet on the account (a lost session's)" },
]

dir : Str -> Str
dir = |root| "${Checkout.out(root)}/adhoc"

## The command again, under flock(1) on out/adhoc/lock: waiting for it, or
## (`wait` false, the idle reaper) not, looking again in five minutes when a
## race holds it. Zig's local cache is shared by every variant's tree.
with_lock! : Str, List(Str), Bool => Try({}, [BadFlag(Str), Failed(Str), Interrupted, Exited(I32)])
with_lock! = |root, args, wait| {
	Path.utf8(dir(root)).create_all!() ? |PathErr(err, _)| Failed("${dir(root)}: ${err.to_str()}")
	self = (Env.exe_path!() ? |_| Failed("this binary's path is not known")).display()
	how = if wait [] else ["-n", "-E", "75"]
	argv = how.concat(["${dir(root)}/lock", self, "adhoc"]).concat(args)
	env = [(lock_variable, "held"), ("ZIG_LOCAL_CACHE_DIR", "${dir(root)}/zig-cache")]
	ran = Cmd.new(OsStr.from_str("flock")).args(argv.map(OsStr.from_str)).envs(env.map(|(k, v)| (OsStr.from_str(k), OsStr.from_str(v)))).inherit_stdio().run!()
	match ran {
		Ok(output) =>
			match output.status {
				Exited(0) => Ok({})
				Exited(75) if !wait => {
					arm_reaper!(root, 5)
					Ok({})
				}
				# The command said why: its status is this one's.
				Exited(code) => Err(Exited(code))
				other => Err(Failed("adhoc: ${Run.status(other)}"))
			}
		Err(Interrupted) => Err(Interrupted)
		Err(CmdErr(err)) => Err(Failed("flock: ${err.to_str()}"))
	}
}

## The event stream: a JSON object a line on standard output, its keys in
## order, the seconds since the command started in "t".
emit! : Monotonic, Str, List((Str, Str)) => {}
emit! = |started, kind, fields| {
	t = num(round2(started.elapsed!().to_nanos().to_f64() / 1e9))
	all = fields.concat([("event", Json.to_str(kind)), ("t", t)]).sort_with(|(a, _), (b, _)| Text.order(a, b))
	_ = Stdout.line!("{${Str.join_with(all.map(|(k, v)| "${Json.to_str(k)}:${v}"), ",")}}")
	{}
}

## A number as JSON (never NaN here: times, rates and percentages).
num : F64 -> Str
num = |value| Json.to_str_try(value) ?? "0"

round2 : F64 -> F64
round2 = |value| ((value * 100 + 0.5).floor_to_i64_try() ?? 0).to_f64() / 100

lowest : List(F64) -> Try(F64, [Empty])
lowest = |list| list.first().map_ok(|first| list.fold(first, |a, b| if b < a b else a)).map_err(|_| Empty)

highest : List(F64) -> Try(F64, [Empty])
highest = |list| list.first().map_ok(|first| list.fold(first, |a, b| if b > a b else a)).map_err(|_| Empty)

log! : Str => {}
log! = |text| Run.log!("adhoc: ${text}")

## --- variants -----------------------------------------------------------------

## A variant resolved: its commits, its key (a hash of what the build reads),
## its name on the server, and its cached binary.
Resolved : { variant : Adhoc.Variant, commits : List((Str, Str)), key : Str, name : Str, binary : Str }

checkout_dir : Str, Str -> Str
checkout_dir = |root, repository| if repository == "dragrace" root else Checkout.beside(root, repository)

## A ref's commit in the local repository, fetching origin once when it is
## not there (a branch pushed from elsewhere). Anything git knows works: a
## branch, a tag, a hash, origin/master.
commit_of! : Str, Str => Try(Str, [Failed(Str), Interrupted])
commit_of! = |repository, ref| {
	verify! = |name| Run.output!(repository, ["git", "rev-parse", "--verify", "--quiet", "${name}^{commit}"])
	match verify!(ref) {
		Ok(commit) => return Ok(commit)
		Err(Interrupted) => return Err(Interrupted)
		Err(Failed(_)) => {}
	}
	Run.run!(repository, [], ["git", "fetch", "--quiet", "origin"])?
	match verify!(ref) {
		Ok(commit) => Ok(commit)
		Err(Interrupted) => Err(Interrupted)
		Err(Failed(_)) => verify!("origin/${ref}").map_err(|_| Failed("${repository}: no commit \"${ref}\", here or on origin"))
	}
}

## The variant's commits and its key: a hash of every file of the three
## trees but Markdown (git ls-tree's lines), so a commit of documentation
## only keeps its build.
resolve! : Str, Adhoc.Variant => Try(Resolved, [BadFlag(Str), Failed(Str), Interrupted])
resolve! = |root, variant| {
	stream = Hash.start!()?
	Hash.write_str!(stream, variant.competitor)?
	var $commits = []
	for (repository, ref) in variant.refs {
		at = checkout_dir(root, repository)
		commit = commit_of!(at, ref) ? |err| prefix(err, "variant ${variant.label}")
		$commits = $commits.append((repository, commit))
		files = Run.output!(at, ["git", "ls-tree", "-r", commit])?
		Hash.write_str!(stream, repository)?
		for line in files.split_on("\n") {
			if !line.ends_with(".md") {
				Hash.write_str!(stream, "${line}\n")?
			}
		}
	}
	key = Text.take(Hash.finish!(stream)?, 12)
	name = "${variant.competitor}-${Text.take(key, 8)}"
	Ok({ variant, commits: $commits, key, name, binary: "${dir(root)}/bin/${name}.zst" })
}

commit_in : Resolved, Str -> Str
commit_in = |resolved, repository| (resolved.commits.find_first(|(r, _)| r == repository) ?? (repository, "HEAD")).1

## The variant's binary, unless the cache has it: the three repositories
## checked out at their commits side by side (as the README's layout), the
## competitor built there with its own competitor.json and pins, then
## stripped (symbols only: the code is the same) and compressed (17 MB of
## roux is 1.6 MB to send). One directory per label, updated in place: Zig's
## cache knows a file by its path, so a new directory each time compiled
## everything again (roux's host and tools, 117 s).
build! : Str, Resolved, Monotonic => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
build! = |root, resolved, started| {
	label = resolved.variant.label
	if Path.utf8(resolved.binary).exists!() == Ok(Bool.True) {
		emit!(started, "built", [("variant", Json.to_str(label)), ("cached", "true"), ("seconds", "0")])
		return Ok({})
	}
	clock = Monotonic.now!()
	tree = "${dir(root)}/tree/${Text.take(Hash.bytes!(label.to_utf8())?, 12)}"
	tree_root = "${tree}/fourneau-dragrace"
	checkout_at!(root, "dragrace", commit_in(resolved, "dragrace"), tree_root)?
	# Its siblings beside it, as in every checkout.
	for repository in ["fourneau", "roux"] {
		checkout_at!(root, repository, commit_in(resolved, repository), Checkout.beside(tree_root, repository))?
	}
	ready = Toolchain.load!(tree_root)?
	competitors = Checkout.competitors!(tree_root, [resolved.variant.competitor])?
	_ = Build.all!(tree_root, ready, competitors) ? |err| prefix(err, "variant ${label}")
	stripped = "${tree}/${resolved.name}"
	Run.run!(tree, [], ["strip", "-o", stripped, "${Checkout.bin(tree_root)}/${resolved.variant.competitor}"])?
	Path.utf8(Checkout.parent(resolved.binary)).create_all!() ? |PathErr(err, _)| Failed("${resolved.binary}: ${err.to_str()}")
	Run.run!(tree, [], ["zstd", "-q", "-f", "-3", stripped, "-o", "${resolved.binary}.tmp"])?
	Path.utf8("${resolved.binary}.tmp").rename!(Path.utf8(resolved.binary)) ? |PathErr(err, _)| Failed("${resolved.binary}: ${err.to_str()}")
	emit!(started, "built", [("variant", Json.to_str(label)), ("cached", "false"), ("seconds", num(round2(clock.elapsed!().to_nanos().to_f64() / 1e9)))])
	Ok({})
}

## `at` a checkout of the repository at a commit, updated in place: a clone
## sharing the repository's objects (no copy), then a forced checkout and a
## clean of untracked files, ignored ones kept (zig-out, .roux). git
## rewrites only the files that differ, so a file unchanged keeps its inode
## and Zig's cache still knows it.
checkout_at! : Str, Str, Str, Str => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
checkout_at! = |root, repository, commit, at| {
	if Path.utf8("${at}/.git").exists!() != Ok(Bool.True) {
		_ = Path.utf8(at).delete_all!()
		Path.utf8(Checkout.parent(at)).create_all!() ? |PathErr(err, _)| Failed("${at}: ${err.to_str()}")
		Run.run!(Checkout.parent(at), [], ["git", "clone", "--quiet", "--shared", "--no-checkout", checkout_dir(root, repository), at])?
	}
	Run.run!(at, [], ["git", "checkout", "--quiet", "--force", "--detach", commit])?
	Run.run!(at, [], ["git", "clean", "-fdq"])?
	Ok({})
}

## --- the session --------------------------------------------------------------

Node : { id : U64, size : Str, public : Str, private : Str }

MachineInfo : { role : Str, class : Str, size : Str, cpu : Str, cpus : I64, kernel : Str, cpu_id : Str, memory_mib : I64 }

## The warm pair, kept in out/adhoc/session.json (times as Go's RFC 3339).
Session : { class : Str, region : Str, server : Node, loader : Node, created : Str, used : Str, idle_minutes : U64, machines : List(MachineInfo) }

session_path : Str -> Str
session_path = |root| "${dir(root)}/session.json"

load_session! : Str => Try([Some(Session), None], [Failed(Str)])
load_session! = |root|
	match Path.utf8(session_path(root)).read_utf8!() {
		Ok(text) => {
			parsed : Try(Session, _)
			parsed = Json.parse(text)
			parsed.map_ok(|s| Some(s)).map_err(|_| Failed("${session_path(root)}: not a session"))
		}
		Err(PathErr(NotFound, _)) => Ok(None)
		Err(PathErr(err, _)) => Err(Failed("${session_path(root)}: ${err.to_str()}"))
	}

save_session! : Str, Session => Try({}, [Failed(Str)])
save_session! = |root, session| {
	path = session_path(root)
	Path.utf8(path).write_utf8!("${Json.to_str(session)}\n") ? |PathErr(err, _)| Failed("${path}: ${err.to_str()}")
	Ok({})
}

now! : () => Str
now! = || Time.format_ms(Utc.now!().to_millis_since_epoch().to_i64_wrap())

## A session droplet, as root: the session's key, its own known_hosts, and a
## kept connection (its socket path short: not under out/).
ssh_of : Str, Node -> Machine.Ssh
ssh_of = |root, node| { user: "root", host: node.public, key: "${dir(root)}/key", known_hosts: "${dir(root)}/known_hosts", control: "/tmp/dragrace-adhoc-${node.id.to_str()}" }

## The warm session, made if there is none (or the one there is is for
## another class or region, or gone).
ensure_session! : Str, Config.Race, Str, Monotonic => Try(Session, [BadFlag(Str), Failed(Str), Interrupted])
ensure_session! = |root, race, token, started| {
	region = race.cloud.region
	class = race.cloud.servers.find_first(|c| c.name == session_class) ? |_| Failed("no server class \"${session_class}\" in race.json")
	found =
		match load_session!(root)? {
			Some(s) if s.class != session_class or s.region != region => {
				log!("the session is ${s.class} in ${s.region}; replacing it")
				delete_session!(root, token, s)
				None
			}
			other => other
		}
	match found {
		Some(session) => {
			# Still there, and answering?
			alive = DigitalOcean.droplet!(token, session.server.id).is_ok() and Machine.shell!(Remote(ssh_of(root, session.server)), "true").is_ok()
			if alive {
				warm = { ..session, used: now!(), idle_minutes }
				save_session!(root, warm)?
				arm_reaper!(root, idle_minutes)
				log_machines!(warm, "warm")
				emit!(started, "session", [("reused", "true"), ("class", Json.to_str(warm.class)), ("machines", Json.to_str(warm.machines))])
				return Ok(warm)
			}
			log!("the session's droplets do not answer; making new ones")
			delete_session!(root, token, session)
		}
		None => {}
	}
	clock = Monotonic.now!()
	session = make_session!(root, race, class, token)?
	arm_reaper!(root, idle_minutes)
	log_machines!(session, "new")
	emit!(started, "session", [("reused", "false"), ("class", Json.to_str(session.class)), ("seconds", num(round2(clock.elapsed!().to_nanos().to_f64() / 1e9))), ("machines", Json.to_str(session.machines))])
	Ok(session)
}

## Which machines race (there is no status command).
log_machines! : Session, Str => {}
log_machines! = |session, how| {
	for m in session.machines {
		log!("${how} ${m.role}, ${m.size}: ${m.cpu}, ${m.cpus.to_str()} CPUs (${m.cpu_id}); deleted after ${session.idle_minutes.to_str()} min unused")
	}
}

## The pair made: as a race's, root's key (a new one) in their user data,
## and the admin key in ssh_keys. Saved as soon as a droplet exists, so
## `adhoc down` finds it whatever happens next.
make_session! : Str, Config.Race, Config.ServerClass, Str => Try(Session, [BadFlag(Str), Failed(Str), Interrupted])
make_session! = |root, race, class, token| {
	key = "${dir(root)}/key"
	for stale in [key, "${key}.pub", "${dir(root)}/known_hosts"] {
		_ = Path.utf8(stale).delete!()
	}
	Run.run!(dir(root), [], ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "dragrace-adhoc", "-f", key])?
	public = Checkout.read!("${key}.pub")?.trim()
	admin_key_id = DigitalOcean.admin_key_id!(token)?
	create! = |role, size| {
		droplet = DigitalOcean.create!(token, { name: "dragrace-adhoc-${role}", region: race.cloud.region, size, image: race.cloud.image, ssh_keys: [admin_key_id], tags: [tag], user_data: Cloud.user_data(public, ""), ipv6: Bool.False })?
		Ok({ id: droplet.id, size, public: "", private: "" })
	}
	none = { id: 0, size: "", public: "", private: "" }
	server = create!("server", class.size)?
	var $session = { class: class.name, region: race.cloud.region, server, loader: none, created: now!(), used: now!(), idle_minutes, machines: [] }
	save_session!(root, $session)?
	match create!("loader", class.loader_size) {
		Ok(loader) => {
			$session = { ..$session, loader }
		}
		Err(err) => {
			delete_session!(root, token, $session)
			return Err(widen(err))
		}
	}
	save_session!(root, $session)?
	match addressed!(token, $session) {
		Ok(both) => {
			$session = both
		}
		Err(err) => {
			delete_session!(root, token, $session)
			return Err(err)
		}
	}
	save_session!(root, $session)?
	server_ssh = Remote(ssh_of(root, $session.server))
	loader_ssh = Remote(ssh_of(root, $session.loader))
	for machine in [server_ssh, loader_ssh] {
		match Machine.wait_ssh!(machine) {
			Ok({}) => {}
			Err(err) => {
				delete_session!(root, token, $session)
				return Err(widen(err))
			}
		}
	}
	oha = Local.oha!(race.oha)?
	Machine.put!(loader_ssh, oha, "${home}/oha")?
	_ = Machine.shell!(server_ssh, "mkdir -p ${home}/bin && command -v zstd >/dev/null || (apt-get update -q && apt-get install -yq zstd) >/dev/null")?
	machines = [
		Race.machine_info!(server_ssh, "server", class.name, class.size),
		Race.machine_info!(loader_ssh, "loader", class.name, class.loader_size),
	]
	done = { ..$session, machines }
	save_session!(root, done)?
	Ok(done)
}

## Both droplets active with both addresses: polled every 5 s, ten minutes
## at most.
addressed! : Str, Session => Try(Session, [BadFlag(Str), Failed(Str), Interrupted])
addressed! = |token, session| {
	address! = |node| {
		var $polls = 0.U64
		while $polls < 120 {
			droplet = DigitalOcean.droplet!(token, node.id)?
			public = Guard.address(droplet, "public")
			private = Guard.address(droplet, "private")
			if droplet.status == "active" and public != "" and private != "" {
				return Ok({ ..node, public, private })
			}
			Sleep.millis!(5_000)?
			$polls = $polls + 1
		}
		Err(Failed("droplet ${node.id.to_str()}: not active with both addresses after ten minutes"))
	}
	server = address!(session.server).map_err(widen)?
	loader = address!(session.loader).map_err(widen)?
	Ok({ ..session, server, loader })
}

## The droplets deleted, retrying, and the session forgotten.
delete_session! : Str, Str, Session => {}
delete_session! = |root, token, session| {
	for node in [session.server, session.loader] {
		if node.id != 0 {
			var $attempt = 0.U64
			var $done = Bool.False
			while !$done and $attempt < 5 {
				match DigitalOcean.delete!(token, node.id) {
					Ok({}) => {
						log!("droplet ${node.id.to_str()} deleted")
						$done = Bool.True
					}
					Err(Failed(why)) => {
						log!("deleting droplet ${node.id.to_str()} (attempt ${($attempt + 1).to_str()}): ${why}")
						_ = Sleep.millis!(5_000)
					}
					Err(Interrupted) => {
						_ = Sleep.millis!(5_000)
					}
				}
				$attempt = $attempt + 1
			}
			Machine.close!(Remote(ssh_of(root, node)))
		}
	}
	_ = Path.utf8(session_path(root)).delete!()
	{}
}

## A user timer (re)armed to run `adhoc down -if-idle` once the session has
## been idle long enough. A machine asleep runs it on waking; `adhoc down
## -all` is the backstop.
arm_reaper! : Str, U64 => {}
arm_reaper! = |root, idle| {
	_ = Run.output!("", ["systemctl", "--user", "stop", "${reap_unit}.timer"])
	_ = Run.output!("", ["systemctl", "--user", "reset-failed", "${reap_unit}.service"])
	match Env.exe_path!() {
		Err(_) => log!("no idle reaper (this binary's path is not known): `dragrace adhoc down` when done")
		Ok(self) =>
			match Run.output!("", ["systemd-run", "--user", "--quiet", "--collect", "--unit=${reap_unit}", "--on-active=${(idle + 1).to_str()}m", "--working-directory=${root}", self.display(), "adhoc", "down", "-if-idle"]) {
				Ok(_) => {}
				Err(Failed(why)) => log!("no idle reaper (${why}): `dragrace adhoc down` when done")
				Err(Interrupted) => {}
			}
	}
}

## `dragrace adhoc down [-if-idle] [-all]`, the lock held.
down! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
down! = |root, args| {
	flags = Flags.parse(args, down_flags)?
	all = Flags.switch(flags, "all")
	found = load_session!(root)?
	if found == None and !all {
		return Ok({})
	}
	if Flags.switch(flags, "if-idle") {
		match found {
			Some(session) => {
				now = Utc.now!().to_millis_since_epoch().to_i64_wrap()
				used = Time.parse_ms(session.used) ?? now
				idle_ms = session.idle_minutes.to_i64_wrap() * 60_000
				if now - used < idle_ms {
					arm_reaper!(root, (idle_ms - (now - used)).to_u64_wrap() // 60_000)
					return Ok({})
				}
			}
			None => {}
		}
	}
	token = DigitalOcean.checked_token(Keyring.digitalocean!()?)?
	var $deleted = []
	match found {
		Some(session) => {
			delete_session!(root, token, session)
			_ = Run.output!("", ["systemctl", "--user", "stop", "${reap_unit}.timer"])
			log!("session deleted (made ${session.created})")
			$deleted = [session.server.id, session.loader.id]
		}
		None => {}
	}
	if all {
		# Every droplet with the ad-hoc tag but the ones just deleted (one may
		# still be listed just after its delete): what a session lost from
		# out/adhoc left behind.
		for droplet in DigitalOcean.tagged!(token, tag)? {
			if !$deleted.contains(droplet.id) {
				log!("deleting droplet ${droplet.id.to_str()} ${droplet.name}")
				DigitalOcean.delete!(token, droplet.id)?
			}
		}
	}
	Ok({})
}

## --- the race -----------------------------------------------------------------

## `dragrace adhoc race [-workloads W] [-rounds N] VARIANT...`, the lock held.
race! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
race! = |root, args| {
	started = Monotonic.now!()
	whole = Checkout.race!(root)?
	closed = whole.workloads.keep_if(|w| w.mixed.is_err()).map(|w| w.name)
	flags = Flags.parse(
		args,
		[
			{ name: "workloads", kind: Value(Str.join_with(closed, ",")), usage: "comma-separated" },
			{ name: "rounds", kind: Value("3"), usage: "rounds, each variant once a round in a new order" },
		],
	)?
	if flags.rest.is_empty() {
		return Err(BadFlag("adhoc race: at least one VARIANT (competitor[:dragrace=REF,fourneau=REF,roux=REF])"))
	}
	rounds = U64.from_str(Flags.value(flags, "rounds")) ? |_| BadFlag("-rounds: a number")
	picked = Flags.value(flags, "workloads").split_on(",").map(Str.trim).map_try(|name| closed_workload(whole, name))?
	race = { ..whole, rounds, warmup_seconds, measure_seconds, workloads: picked }
	variants = flags.rest.map_try(Adhoc.parse_variant)?
	resolved = variants.map_try!(|v| {
		r = resolve!(root, v)?
		emit!(started, "resolved", [("variant", Json.to_str(v.label)), ("commits", "{${Str.join_with(r.commits.map(|(k, c)| "${Json.to_str(k)}:${Json.to_str(c)}"), ",")}}"), ("key", Json.to_str(r.key))])
		Ok(r)
	})?
	token = DigitalOcean.checked_token(Keyring.digitalocean!()?)?
	session = ensure_session!(root, race, token, started)?
	# One at a time: two Zig builds at once only fight for the CPUs.
	for r in resolved {
		build!(root, r, started)?
	}
	server = Remote(ssh_of(root, session.server))
	loader = Remote(ssh_of(root, session.loader))
	upload!(server, resolved, started)?
	# Each competitor as its competitor.json says at the variant's own
	# dragrace commit (whether it serves TLS), named for the variant.
	competitors = resolved.map_try!(|r| {
		path = "competitors/${r.variant.competitor}/competitor.json"
		text = Run.output!(root, ["git", "show", "${commit_in(r, "dragrace")}:${path}"])?
		spec = Config.competitor(r.variant.competitor, text)?
		Ok({ ..spec, name: r.name })
	})?
	labels = resolved.map(|r| (r.name, r.variant.label))
	label_of = |name| (labels.find_first(|(n, _)| n == name) ?? (name, name)).1
	class = race.cloud.servers.find_first(|c| c.name == session.class) ?? { name: session.class, label: "", title: "", size: "", loader_size: "" }
	threads = (session.machines.find_first(|m| m.role == "loader") ?? { role: "", class: "", size: "", cpu: "", cpus: 0, kernel: "", cpu_id: "", memory_mib: 0 }).cpus
	target = { class, server, loader, server_home: home, loader_home: home, address: session.server.private, server_cpus: "", loader_cpus: "", loader_threads: threads.to_u64_wrap(), black_box: "" }
	report! = |result| {
		# Its newest round: the race reports each competitor's results after
		# each of its rounds.
		match result.rounds.last() {
			Ok(r) if result.valid => emit!(started, "round", [("variant", Json.to_str(label_of(result.competitor))), ("workload", Json.to_str(result.workload)), ("round", result.rounds.len().to_str()), ("rps", num(round2(r.rps))), ("p50_ms", num(r.p50_ms)), ("p99_ms", num(r.p99_ms)), ("cpu_busy_pct", num(round2(r.cpu_busy_pct))), ("errors", r.errors.to_str()), ("non_2xx", r.non_2xx.to_str())])
			_ => {}
		}
		if !result.valid {
			emit!(started, "invalid", [("variant", Json.to_str(label_of(result.competitor))), ("workload", Json.to_str(result.workload)), ("why", Json.to_str(result.note))])
		}
	}
	seed = Utc.now!().to_nanos_since_epoch().to_u64_wrap()
	run_started = Utc.now!()
	# Every start is on a fresh copy of the seeded database, conduit raced or
	# not.
	Machine.put!(server, Conduit.database(root), "${home}/${Conduit.seed_name}")?
	racing = Monotonic.now!()
	raced = Race.target!(race, competitors, target, seed, { report!, begin!: |_, _| {} })?
	results = rerun_unsaturated!(race, competitors, target, seed, raced, label_of, started)?
	save_session!(root, { ..session, used: now!() })?
	arm_reaper!(root, session.idle_minutes)
	rows = Adhoc.compare(race.workloads.map(|w| w.name), results, labels)
	race_seconds = round2(racing.elapsed!().to_nanos().to_f64() / 1e9)
	path = Local.save!(
		"${dir(root)}/results",
		{
			id: "${run_started.to_iso_8601().replace_each(":", "")}-adhoc",
			where_raced: "adhoc",
			started_at: run_started.to_iso_8601(),
			finished_at: Utc.now!().to_iso_8601(),
			seed: seed.to_i64_wrap(),
			fingerprint: Checkout.fingerprint!(root)?,
			versions: Local.versions!(root, race)?,
			race_json: Checkout.read!("${root}/race.json")?,
			machines: session.machines,
			results,
			timing: { seconds: race_seconds, build_seconds: 0, launch_seconds: 0, racing_seconds: race_seconds, classes: [{ class: class.name, seconds: race_seconds }], droplets: [], cost_usd: 0 },
		},
	)?
	comparison = Json.to_str_try(rows) ?? "[]"
	emit!(started, "result", [("race_seconds", num(race_seconds)), ("comparison", comparison), ("results_file", Json.to_str(path)), ("machines", Json.to_str(session.machines))])
	_ = Stderr.write!(Adhoc.table(rows))
	Ok({})
}

## A workload raced ad hoc: a closed-loop one, by name.
closed_workload : Config.Race, Str -> Try(Config.Workload, [BadFlag(Str)])
closed_workload = |race, name| {
	closed = race.workloads.keep_if(|w| w.mixed.is_err()).map(|w| w.name)
	match race.workloads.find_first(|w| w.name == name) {
		Ok(w) if w.mixed.is_ok() => Err(BadFlag("${name} is open loop only, not raced ad hoc: a nightly races it"))
		Ok(w) => Ok(w)
		Err(_) => Err(BadFlag("no workload \"${name}\" (${Str.join_with(closed, ",")})"))
	}
}

## Each variant's binary the server does not have yet, sent.
upload! : Machine.Where, List(Resolved), Monotonic => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
upload! = |server, resolved, started| {
	have = Text.fields(Machine.shell!(server, "ls ${home}/bin")?)
	var $present = have
	for r in resolved {
		if !$present.contains(r.name) {
			clock = Monotonic.now!()
			remote = "${home}/bin/${r.name}"
			Machine.put!(server, r.binary, "${remote}.zst")?
			_ = Machine.shell!(server, "zstd -q -d -f ${Run.quote("${remote}.zst")} -o ${Run.quote(remote)} && rm ${Run.quote("${remote}.zst")} && chmod +x ${Run.quote(remote)}")?
			bytes = Path.utf8(r.binary).size_in_bytes!() ?? 0
			emit!(started, "uploaded", [("variant", Json.to_str(r.variant.label)), ("bytes", bytes.to_str()), ("seconds", num(round2(clock.elapsed!().to_nanos().to_f64() / 1e9)))])
			$present = $present.append(r.name)
		}
	}
	Ok({})
}

## Race again, up to twice, every competitor with a round in which its
## server was not the limit, then keep the saturated rounds.
rerun_unsaturated! : Config.Race, List(Config.Competitor), Target.Where, U64, List(Results.Result), (Str -> Str), Monotonic => Try(List(Results.Result), [BadFlag(Str), Failed(Str), Interrupted])
rerun_unsaturated! = |race, competitors, target, seed, results, label_of, started| {
	# The saturated rounds a competitor still lacks, on its worst workload.
	missing = |all, name|
		all
			.keep_if(|r| r.competitor == name and r.valid)
			.map(|r| race.rounds - r.rounds.count_if(|round| round.cpu_busy_pct >= saturated).min(race.rounds))
			.fold(0, |a, b| if b > a b else a)
	var $results = results
	for competitor in competitors {
		var $attempt = 0.U64
		while $attempt < 2 and missing($results, competitor.name) > 0 {
			emit!(started, "rerun", [("variant", Json.to_str(label_of(competitor.name))), ("why", Json.to_str("a round's server under ${Text.fixed(saturated, 0)}% CPU"))])
			$results = Race.rerun!(race, competitor, target, race.rounds + 1 + $attempt, seed, $results).map_err(widen)?
			$attempt = $attempt + 1
		}
	}
	var $kept = []
	for result in $results {
		{ kept, dropped } = Adhoc.kept(result.rounds, race.rounds)
		if dropped > 0 {
			emit!(started, "dropped", [("variant", Json.to_str(label_of(result.competitor))), ("workload", Json.to_str(result.workload)), ("rounds", dropped.to_str())])
		}
		$kept = $kept.append({ ..result, rounds: kept })
	}
	Ok($kept)
}

prefix : [Failed(Str), Interrupted], Str -> [BadFlag(Str), Failed(Str), Interrupted]
prefix = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

widen : [Failed(Str), Interrupted] -> [BadFlag(Str), Failed(Str), Interrupted]
widen = |err|
	match err {
		Failed(why) => Failed(why)
		Interrupted => Interrupted
	}

expect Adhoc.parse_variant("roux") == Ok({ label: "roux", competitor: "roux", refs: [("dragrace", "HEAD"), ("fourneau", "HEAD"), ("roux", "HEAD")] })
expect Adhoc.parse_variant("roux:roux=vm,dragrace=vm").map_ok(|v| v.refs) == Ok([("dragrace", "vm"), ("fourneau", "HEAD"), ("roux", "vm")])
expect Adhoc.parse_variant("roux:zig=x").is_err() and Adhoc.parse_variant("roux:roux=").is_err()
expect round2(1.234) == 1.23 and round2(1.235) == 1.24
expect {
	round = |rps, cpu| { ..Results.zero_round, rps, cpu_busy_pct: cpu }
	out = Adhoc.kept([round(1, 50), round(2, 99), round(3, 99), round(4, 40)], 3)
	out.kept.map(|r| r.rps) == [2, 3, 1] and out.dropped == 1
}
expect {
	round = |rps| { ..Results.zero_round, rps, p99_ms: 1 }
	result = |name, rpss| { ..Results.empty("c", "plaintext", name), valid: Bool.True, rounds: rpss.map(round) }
	rows = Adhoc.compare(["plaintext"], [result("a", [100, 110]), result("b", [120, 130])], [("a", "A"), ("b", "B")])
	rows.map(|r| (r.variant, r.delta_pct, r.apart)) == [("A", 0, Bool.False), ("B", 18.18, Bool.True)]
}
