import Conduit
import Config
import Machine
import Run
import Snapshot
import Text

## One server class to race on: where the server runs and where the loader
## runs, and the CPUs each may use; and the server's life there, every
## competitor started the same way (CONTRIBUTING.md, "The contract").
Target :: [].{
	Where : {
		class : Config.ServerClass,
		server : Machine.Where,
		loader : Machine.Where,
		## Holds bin/, the seed, the certificate.
		server_home : Str,
		## Holds oha and the request bodies.
		loader_home : Str,
		## Where servers listen, as the loader reaches them.
		address : Str,
		server_cpus : Str,
		loader_cpus : Str,
		## oha's threads: the loader's CPUs (0: oha's default).
		loader_threads : U64,
		## The file on this machine following the server's black box ("": none).
		black_box : Str,
	}

	## How a competitor is started: plain HTTP (HTTP/1.1 and h2c), or its
	## HTTPS mode, on the same port.
	Mode : [Plain, Tls]

	certificate_name : Str
	certificate_name = "tls-cert.pem"

	key_name : Str
	key_name = "tls-key.pem"

	mode_of : Config.Workload -> Mode
	mode_of = |workload| if workload.tls Tls else Plain

	## A competitor's entry in the checks: each mode on its own, so one that
	## fails TLS still races plain HTTP.
	valid_key : Str, Mode -> Str
	valid_key = |competitor, mode|
		match mode {
			Tls => "${competitor} (TLS)"
			Plain => competitor
		}

	## Whether a competitor races a workload: one with no HTTPS mode sits the
	## TLS workloads out, with no result.
	offers : Config.Competitor, Config.Workload -> Bool
	offers = |competitor, workload| !workload.tls or competitor.tls

	## `taskset -c CPUS ` for a set of CPUs, "" for all.
	taskset : Str -> Str
	taskset = |cpus| if cpus == "" "" else "taskset -c ${cpus} "

	base_url : Config.Race, Where, Mode -> Str
	base_url = |race, target, mode| {
		scheme =
			match mode {
				Tls => "https"
				Plain => "http"
			}
		"${scheme}://${target.address}:${race.port.to_str()}"
	}

	## curl as the checks run it: over TLS it takes the race's own
	## certificate (-k) and offers oha's ciphers in oha's order (rustls's,
	## AES-256-GCM first), so the cipher a check sees is the race's.
	curl : Mode, Str -> Str
	curl = |mode, max_seconds|
		match mode {
			Tls => "curl -s -m ${max_seconds} -k --tls13-ciphers TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256 "
			Plain => "curl -s -m ${max_seconds} "
		}

	## Start a competitor in a mode: its binary, told where to serve by the
	## variables roux's host reads, on a fresh copy of the seeded database,
	## SIGPIPE ignored as systemd starts a service. Its pid.
	start! : Config.Race, Config.Competitor, Where, Mode => Try(Str, [Failed(Str), Interrupted])
	start! = |race, competitor, target, mode| {
		home = Run.quote(target.server_home)
		fresh = "cd ${home} && rm -f ${Conduit.database_name} ${Conduit.database_name}-wal ${Conduit.database_name}-shm && cp ${Conduit.seed_name} ${Conduit.database_name}"
		_ = Machine.shell!(target.server, fresh) ? |err| prefix(err, "the database for ${competitor.name}")
		base_env = ["ROUX_ADDRESS=${target.address}", "ROUX_PORT=${race.port.to_str()}", "ROUX_DATABASE=${target.server_home}/${Conduit.database_name}"]
		env =
			match mode {
				Tls =>
					if competitor.tls {
						base_env.concat(["ROUX_TLS_CERT=${target.server_home}/${Target.certificate_name}", "ROUX_TLS_KEY=${target.server_home}/${Target.key_name}"])
					} else {
						return Err(Failed("${competitor.name} serves no TLS"))
					}
				Plain => base_env
			}
		# Ignored last, by a shell that execs the server: Ubuntu 26.04's nohup
		# puts SIGPIPE back to the default for what it starts. Every step
		# execs, so $! is the server's pid.
		command = Str.join_with(
			[
				"cd ${home} && ulimit -n $(ulimit -Hn); env",
				Str.join_with(env.map(Run.quote), " "),
				"nohup ${Target.taskset(target.server_cpus)}sh -c ${Run.quote("trap '' PIPE; exec \"$0\"")}",
				Run.quote("${target.server_home}/bin/${competitor.name}"),
				"> ${Run.quote("${competitor.name}.log")} 2>&1 < /dev/null & echo $!",
			],
			" ",
		)
		pid = Machine.shell!(target.server, command) ? |err| prefix(err, "starting ${competitor.name}")
		Ok(pid.trim())
	}

	## Stop a server: TERM, five seconds, then KILL.
	stop! : Where, Str => {}
	stop! = |target, pid| {
		script = "kill ${pid} 2>/dev/null; for i in $(seq 50); do kill -0 ${pid} 2>/dev/null || exit 0; sleep 0.1; done; kill -9 ${pid}"
		match Machine.shell!(target.server, script) {
			Ok(_) => {}
			Err(Failed(why)) => Run.log!("stopping ${pid}: ${why}")
			Err(Interrupted) => Run.log!("stopping ${pid}: interrupted")
		}
	}

	## Wait up to ten seconds for /plaintext's 200, from the loader.
	ready! : Config.Race, Where, Mode => Try({}, [Failed(Str), Interrupted])
	ready! = |race, target, mode| {
		script = "for i in $(seq 100); do [ \"$(${Target.curl(mode, "1")}-o /dev/null -w '%{http_code}' ${Target.base_url(race, target, mode)}/plaintext)\" = 200 ] && exit 0; sleep 0.1; done; exit 1"
		_ = Machine.shell!(target.loader, script)?
		Ok({})
	}

	## Snapshots of the server and the loader, the server's nearest the load:
	## before it, the loader's first; after it, the server's first.
	snapshots! : Where, Str, [Before, After] => Try({ server : Snapshot.Taken, loader : Snapshot.Taken }, [Failed(Str), Interrupted])
	snapshots! = |target, pid, when| {
		take! = |machine, of| {
			text = Machine.shell!(machine, Snapshot.command(of))?
			Snapshot.parse(text)
		}
		match when {
			Before => {
				loader = take!(target.loader, "")?
				server = take!(target.server, pid)?
				Ok({ server, loader })
			}
			After => {
				server = take!(target.server, pid)?
				loader = take!(target.loader, "")?
				Ok({ server, loader })
			}
		}
	}

	## What the server machine knows about a server that never answered:
	## whether it still runs, its output's lines that name a failure, the end
	## of its output, and the kernel's line for a kill or a fault.
	why_not_ready! : Config.Competitor, Where, Str => Str
	why_not_ready! = |competitor, target, pid| {
		log = Run.quote("${competitor.name}.log")
		script = "cd ${Run.quote(target.server_home)}; if kill -0 ${pid} 2>/dev/null; then echo 'running, not answering;'; else echo 'exited;'; fi; { grep -m 3 -iE 'panic|illegal|segmentation|fault|error' ${log}; echo '...'; tail -c 600 ${log}; } | tr '\\n' ' '; dmesg 2>/dev/null | grep -iE 'out of memory|invalid opcode|segfault' | tail -n 2"
		match Machine.shell!(target.server, script) {
			Ok(why) => "no answer in 10 s: ${Str.join_with(Text.fields(why.replace_each("\n", " ")), " ")}"
			Err(Failed(why)) => "no answer in 10 s (${why})"
			Err(Interrupted) => "no answer in 10 s (interrupted)"
		}
	}
}

prefix : [Failed(Str), Interrupted], Str -> [Failed(Str), Interrupted]
prefix = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

expect Target.taskset("0-1") == "taskset -c 0-1 "
expect Target.taskset("") == ""
expect Target.valid_key("roux", Tls) == "roux (TLS)"
