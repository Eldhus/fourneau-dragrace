app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc3/72LPrJNPhao1zzEbawpgzKnkwAPRKy6Xm8jM1rPchQ7o.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

## The dragrace tool: builds the competitors, races them, builds the site,
## and runs the services of self-hosting. Its commands are README.md's and
## the hosts' units', with Go's flag syntax (`-quick`, `-since F`).
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.System
import pf.Stdout
import Build
import Bundle
import Checkout
import Checks
import Cloud
import Flags
import GitHub
import Guard
import GuardService
import Hosts
import JsonValue
import Keyring
import Ledger
import Local
import Machine
import Mixed
import Race
import Target
import Number
import Oha
import Racer
import RacerHost
import Results
import Retry
import Run
import SiteApi
import Seeded
import Site
import Snapshot
import Time
import Toolchain
import Worker

main! : List(OsStr) => Try({}, [Exit(I32), Interrupted])
main! = |raw_args| {
	args = raw_args.map(OsStr.display)
	result =
		match args {
			["version", ..] => {
				# The commit beside the binary (a bundle's, or a racer's
				# update's); "" for one built by hand.
				_ = Stdout.line!(Racer.own_commit!())
				Ok({})
			}
			["toolchain", ..] | ["build", ..] | ["site", "build", ..] | ["site", "dev", ..] | ["race", "local", ..] | ["worker", ..] | ["bundle", ..] | ["racer", "install", ..] =>
				match args {
					[command, .. as rest] => in_checkout!(command, rest)
					[] => Err(Usage)
				}
			["guard", .. as rest] => GuardService.command!(rest)
			["racer", "serve", ..] | ["racer", "check", ..] =>
				match Racer.command!(args.drop_first(1)) {
					Ok({}) => Ok({})
					# A new binary in place: systemd starts it (Restart=always).
					Err(Restart) => Ok({})
					Err(BadFlag(why)) => Err(BadFlag(why))
					Err(Failed(why)) => Err(Failed(why))
					Err(Interrupted) => Ok({})
				}
			[command, ..] if go_commands.contains(command) => go_tool!(args)
			_ => Err(Usage)
		}
	match result {
		Ok({}) => Ok({})
		Err(Usage) => {
			_ = Stderr.line!(usage)
			Err(Exit(2))
		}
		Err(BadFlag(why)) => {
			_ = Stderr.line!(why)
			Err(Exit(2))
		}
		Err(Failed(why)) => {
			Run.log!(why)
			Err(Exit(1))
		}
		Err(Interrupted) => Err(Interrupted)
	}
}

## The commands the Go tool still has (the tool moves to Roc a stage at a
## time): run by `dragrace-go`, built beside this binary, in this
## process's place.
go_commands : List(Str)
go_commands = ["adhoc", "diff", "site", "host-agent", "notify", "hosts"]

go_tool! : List(Str) => Try({}, [Usage, BadFlag(Str), Failed(Str), Interrupted])
go_tool! = |args| {
	exe = Env.exe_path!() ? |_| Failed("this binary's path is not known")
	go = Path.utf8("${Checkout.parent(exe.display())}/dragrace-go")
	if go.is_executable!() != Ok(Bool.True) {
		return Err(Failed("dragrace ${Str.join_with(args.take_first(2), " ")} is still the Go tool's: build it beside this one (go build -C tools -o ../out/dragrace-go ./cmd/dragrace)"))
	}
	replaced =
		match System.target!().os() {
			Linux(os) => Cmd.exec!(os.unix(), go, args.map(OsStr.from_str))
			MacOS(os) => Cmd.exec!(os.unix(), go, args.map(OsStr.from_str))
			Windows(_) => return Err(Failed("Linux or macOS"))
		}
	match replaced {
		Ok(never) => never
		Err(Interrupted) => Err(Interrupted)
		Err(CmdErr(err)) => Err(Failed("dragrace-go: ${err.to_str()}"))
	}
}

## The commands that run from anywhere inside the repository.
in_checkout! : Str, List(Str) => Try({}, [Usage, BadFlag(Str), Failed(Str), Interrupted])
in_checkout! = |command, args| {
	root = Checkout.root!()?
	match command {
		"toolchain" => {
			_ = Toolchain.load!(root)?
			Ok({})
		}
		"build" => build!(root, args)
		"worker" => Worker.command!(root, args)
		"bundle" => Bundle.command!(root, args)
		"racer" =>
			match args {
				["install", .. as rest] => RacerHost.install!(root, rest)
				_ => Err(Usage)
			}
		"site" => site!(root, args)
		"race" =>
			match args {
				["local", .. as rest] => Local.race!(root, rest)
				_ => Err(Usage)
			}
		_ => Err(Usage)
	}
}

## `dragrace site build|dev`.
site! : Str, List(Str) => Try({}, [Usage, BadFlag(Str), Failed(Str), Interrupted])
site! = |root, args|
	match args {
		["build", .. as rest] => {
			_ = Flags.parse(rest, [])?
			ready = Toolchain.load!(root)?
			Site.build!(root, ready)?
			_ = Stdout.line!("built ${Site.binary(root)}; run it from site/ (ROUX_PORT=8090 for a local look; it makes site.db there)")
			Ok({})
		}
		["dev", .. as rest] => {
			flags = Flags.parse(rest, [{ name: "port", kind: Value("8090"), usage: "the site's port: open http://127.0.0.1:PORT/" }])?
			port = U64.from_str(Flags.value(flags, "port")) ? |_| BadFlag("-port: a number")
			ready = Toolchain.load!(root)?
			Site.dev!(root, ready, port)
		}
		_ => Err(Usage)
	}

## `dragrace build [-competitors a,b]`: every competitor into out/bin.
build! : Str, List(Str) => Try({}, [Usage, BadFlag(Str), Failed(Str), Interrupted])
build! = |root, args| {
	flags = Flags.parse(args, [{ name: "competitors", kind: Value(""), usage: "comma-separated names (default: race.json's)" }])?
	race = Checkout.race!(root)?
	only = Flags.value(flags, "competitors")
	names = if only == "" race.competitors else only.split_on(",")
	ready = Toolchain.load!(root)?
	competitors = Checkout.competitors!(root, names)?
	_ = Build.all!(root, ready, competitors)?
	Ok({})
}

usage =
	\\usage: dragrace COMMAND
	\\  toolchain | build | race local | adhoc race|down | diff |
	\\  bundle | worker | site build|dev|install-server|race-now |
	\\  guard | racer serve|check|install | host-agent | notify |
	\\  hosts check | version
	\\See README.md.

expect JsonValue.parse("[]").is_ok()
