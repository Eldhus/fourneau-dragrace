import pf.Env
import pf.OsStr
import pf.Path
import Checkout
import Conduit
import Config
import Keys
import Run
import Text
import Toolchain

## Every competitor into out/bin, each built only when its key is new and
## otherwise taken from the store; the keys to out/competitors.json, which
## the bundle records.
Build :: [].{
	## The seeded database, then each competitor by its key; the keys are
	## taken before any build runs, as the checkout was.
	all! : Str, Toolchain.Ready, List(Config.Competitor) => Try(List((Str, Str)), [Failed(Str), Interrupted])
	all! = |root, ready, competitors| {
		Path.utf8(Checkout.bin(root)).create_all!() ? |PathErr(err, _)| Failed("out/bin: ${err.to_str()}")
		# Every server is given the seeded database (the race's start).
		Conduit.build_database!(root)?
		var $keys = []
		for competitor in competitors {
			key = Keys.competitor!(root, ready.tools, competitor)?
			$keys = $keys.append((competitor.name, key))
			if Keys.from_store!(root, competitor.name, key)? {
				Run.log!("${competitor.name}: from the store, key ${Text.take(key, 12)}")
			} else {
				Build.competitor!(root, ready.tools, competitor)?
				Keys.to_store!(root, competitor.name, key)?
				Run.log!("${competitor.name}: built and stored, key ${Text.take(key, 12)}")
			}
		}
		Build.write_keys!(root, $keys)?
		Ok($keys)
	}

	## One competitor's build command in its directory, with the pinned tools
	## it may run first on its PATH (a command that starts one gets the
	## pinned one), its binary copied to out/bin/NAME.
	competitor! : Str, Keys.Tools, Config.Competitor => Try({}, [Failed(Str), Interrupted])
	competitor! = |root, tools, competitor| {
		dir = "${root}/competitors/${competitor.name}"
		pins = Keys.pinned(competitor, tools).sort_with(|(a, _), (b, _)| Text.order(a, b))
		path = Env.var_str!(OsStr.from_str("PATH")) ?? ""
		search = Str.join_with(pins.map(|(_, tool)| Checkout.parent(tool)).append(path), ":")
		env = competitor.env.keep_if(|(name, _)| name != "PATH").append(("PATH", search))
		argv =
			match competitor.argv {
				[first, .. as rest] =>
					match pins.find_first(|(name, _)| name == first) {
						Ok((_, tool)) => [tool].concat(rest)
						Err(_) => competitor.argv
					}
				[] => []
			}
		Run.run!(dir, env, argv) ? |err| prefix(err, "building ${competitor.name}")
		Keys.copy!("${dir}/${competitor.binary}", "${Checkout.bin(root)}/${competitor.name}").map_err(|Failed(why)| Failed("building ${competitor.name}: ${why}"))
	}

	## out/competitors.json: each competitor's key as built.
	keys_path : Str -> Str
	keys_path = |root| "${Checkout.out(root)}/competitors.json"

	write_keys! : Str, List((Str, Str)) => Try({}, [Failed(Str)])
	write_keys! = |root, keys| {
		object = Dict.from_list(keys)
		Path.utf8(Build.keys_path(root)).write_utf8!(Json.to_str(object)) ? |PathErr(err, _)| Failed("out/competitors.json: ${err.to_str()}")
		Ok({})
	}

	## out/competitors.json read back.
	read_keys! : Str => Try(List((Str, Str)), [Failed(Str)])
	read_keys! = |root| {
		text = Checkout.read!(Build.keys_path(root))?
		parsed : Try(Dict(Str, Str), _)
		parsed = Json.parse(text)
		keys = parsed ? |_| Failed("out/competitors.json: not the keys")
		Ok(keys.to_list())
	}
}

prefix : [Failed(Str), Interrupted], Str -> [Failed(Str), Interrupted]
prefix = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}
