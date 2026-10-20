app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc3/72LPrJNPhao1zzEbawpgzKnkwAPRKy6Xm8jM1rPchQ7o.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

## The dragrace tool: builds the competitors, races them, builds the site,
## and runs the services of self-hosting. Its commands are README.md's and
## the hosts' units', with Go's flag syntax (`-quick`, `-since F`).
import pf.OsStr
import pf.Stderr
import pf.Stdout
import Adhoc
import Build
import Bundle
import Checkout
import Checks
import Cloud
import Diff
import Flags
import GitHub
import Guard
import GuardService
import HostAgent
import Hosts
import HostsCheck
import JsonValue
import Keyring
import Ledger
import Local
import Machine
import Mixed
import Race
import Target
import Notify
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
import SiteHost
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
			["toolchain", ..] | ["build", ..] | ["site", "build", ..] | ["site", "dev", ..] | ["site", "install-server", ..] | ["race", "local", ..] | ["worker", ..] | ["bundle", ..] | ["racer", "install", ..] | ["hosts", ..] | ["diff", ..] | ["adhoc", ..] =>
				match args {
					[command, .. as rest] => in_checkout!(command, rest)
					[] => Err(Usage)
				}
			# The hosts' services, and the owner's request: anywhere.
			["guard", .. as rest] => GuardService.command!(rest)
			["host-agent", .. as rest] => HostAgent.command!(rest)
			["notify", .. as rest] => Notify.command!(rest)
			["site", "race-now", .. as rest] => SiteHost.race_now!(rest)
			["racer", "serve", ..] | ["racer", "check", ..] =>
				match Racer.command!(args.drop_first(1)) {
					Ok({}) => Ok({})
					# A new binary in place: systemd starts it (Restart=always).
					Err(Restart) => Ok({})
					Err(BadFlag(why)) => Err(BadFlag(why))
					Err(Failed(why)) => Err(Failed(why))
					Err(Interrupted) => Ok({})
				}
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
		# A command run again under a lock, which said why itself.
		Err(Exited(code)) => Err(Exit(code))
	}
}

## The commands that run from anywhere inside the repository.
in_checkout! : Str, List(Str) => Try({}, [Usage, BadFlag(Str), Failed(Str), Interrupted, Exited(I32)])
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
		"diff" => Diff.command!(root, args)
		"adhoc" => Adhoc.command!(root, args)
		"racer" =>
			match args {
				["install", .. as rest] => RacerHost.install!(root, rest)
				_ => Err(Usage)
			}
		"hosts" =>
			match args {
				["check", .. as rest] => HostsCheck.command!(root, rest)
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
		["install-server", .. as rest] => SiteHost.install!(root, rest)
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
