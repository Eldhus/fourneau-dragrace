app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc3/72LPrJNPhao1zzEbawpgzKnkwAPRKy6Xm8jM1rPchQ7o.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

## The dragrace tool: builds the competitors, races them, builds the site,
## and runs the services of self-hosting. Its commands are README.md's and
## the hosts' units', with Go's flag syntax (`-quick`, `-since F`).
import pf.OsStr
import pf.Stderr
import Build
import Checkout
import Flags
import JsonValue
import Run
import Toolchain

main! : List(OsStr) => Try({}, [Exit(I32), Interrupted])
main! = |raw_args| {
	args = raw_args.map(OsStr.display)
	result =
		match args {
			["version", ..] => Ok({})
			[command, .. as rest] => in_checkout!(command, rest)
			[] => Err(Usage)
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
		_ => Err(Usage)
	}
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
