app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc3/72LPrJNPhao1zzEbawpgzKnkwAPRKy6Xm8jM1rPchQ7o.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

## The dragrace tool: builds the competitors, races them, builds the site,
## and runs the services of self-hosting. Its commands are README.md's and
## the hosts' units', with Go's flag syntax (`-quick`, `-since F`).
import pf.OsStr
import pf.Stderr
import Flags
import Run
import Checkout
import Config
import Hash
import JsonValue
import Keys
import Text

main! : List(OsStr) => Try({}, [Exit(I32), Interrupted])
main! = |raw_args| {
	args = raw_args.map(OsStr.display)
	match args {
		["version", ..] => {
			Run.log!("version: not built by build.yml")
			Ok({})
		}
		_ => {
			_ = Stderr.line!(usage)
			Err(Exit(2))
		}
	}
}

usage =
	\\usage: dragrace COMMAND
	\\  toolchain | build | race local | adhoc race|down | diff |
	\\  bundle | worker | site build|dev|install-server|race-now |
	\\  guard | racer serve|check|install | host-agent | notify |
	\\  hosts check | version
	\\See README.md.
