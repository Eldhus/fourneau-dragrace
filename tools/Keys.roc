import pf.Env
import pf.OsStr
import pf.Path
import Checkout
import Config
import Hash
import Run
import Text

## A competitor is built only when its key is new: the key is a hash of
## everything its binary is built from, and the binary is kept in a store
## under it, so equal keys are equal builds and a binary is never taken for
## another's. A wrong key would race a stale binary and publish a wrong
## number, so a key takes more than it strictly needs rather than less.
##
## Every key hashes the bytes the Go tool hashed (keys.go), so builds made
## by either share the store, and the race key says the same.
Keys :: [].{
	## What a key needs of the toolchain: the pinned tools' paths and
	## versions, and the checkouts beside this one.
	Tools : { zig : Str, roc : Str, roux : Str, fourneau : Str, zig_version : Str, roc_version : Str }

	## The newest binaries kept for each competitor in the store.
	store_keep : U64
	store_keep = 3

	## The pinned tools a competitor's build runs with, by name: the one its
	## command starts (zig, roc or roux), and roc with roux, which runs it.
	pinned : Config.Competitor, Tools -> List((Str, Str))
	pinned = |competitor, tools|
		match competitor.argv.first() {
			Ok("zig") => [("zig", tools.zig)]
			Ok("roc") => [("roc", tools.roc)]
			Ok("roux") => [("roc", tools.roc), ("roux", "${tools.roux}/zig-out/bin/roux")]
			_ => []
		}

	## A competitor's key: the recipe; its directory and workloads/ as the
	## checkout has them, uncommitted changes included; each of its inputs;
	## the machine; and the pinned tools its build runs with.
	competitor! : Str, Tools, Config.Competitor => Try(Str, [Failed(Str), Interrupted])
	competitor! = |root, tools, competitor| {
		var $parts = [("recipe", competitor_key_recipe), ("name", competitor.name)]
		for sub in ["competitors/${competitor.name}", "workloads"] {
			tree = Keys.tree!(root, sub)?
			$parts = $parts.append((sub, tree))
		}
		for input in competitor.inputs {
			tree = Keys.tree!("${root}/${input}", ".") ? |err| when_failed(err, |why| "${competitor.name}'s input ${input}: ${why}")
			$parts = $parts.append(("input ${input}", tree))
		}
		$parts = $parts.append(("image", Keys.machine_image!()))
		pins = Keys.pinned(competitor, tools)
		if pins.any(|(name, _)| name == "roux") {
			$parts = $parts.append(("roux", Keys.roux_identity!(tools)?))
		}
		if pins.any(|(name, _)| name == "roc") {
			$parts = $parts.append(("roc", tools.roc_version))
		}
		if pins.any(|(name, _)| name == "zig") {
			$parts = $parts.append(("zig", tools.zig_version))
		}
		Hash.bytes!(Keys.encode_parts($parts))
	}

	## Each part as keys.go wrote it: name, NUL, length, NUL, value, NUL.
	encode_parts : List((Str, Str)) -> List(U8)
	encode_parts = |parts|
		parts.fold(
			[],
			|bytes, (name, value)| bytes.concat("${name}\u(0)${value.to_utf8().len().to_str()}\u(0)${value}\u(0)".to_utf8()),
		)

	## The files under `sub` of `dir` that git tracks or would track: each
	## one's path, whether it is executable and its size, and its bytes (a
	## symbolic link's target; a file listed but deleted is "gone").
	tree! : Str, Str => Try(Str, [Failed(Str), Interrupted])
	tree! = |dir, sub| {
		listing = Run.output_bytes!(dir, ["git", "-C", dir, "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", sub]) ? |err|
			when_failed(err, |why| "git ls-files ${sub} in ${dir}: ${why} (a build is of a git checkout)")
		paths = listing.split_on(0).keep_if(|p| !p.is_empty()).map(Str.from_utf8_lossy)
		hash = Hash.start!()?
		var $previous = ""
		for path in Text.sorted(paths) {
			if path != $previous {
				Keys.tree_entry!(hash, dir, path)?
			}
			$previous = path
		}
		Hash.finish!(hash)
	}

	## One file of a tree, written to the hash.
	tree_entry! : Hash.Digest, Str, Str => Try({}, [Failed(Str), Interrupted])
	tree_entry! = |hash, dir, path| {
		full = Path.utf8("${dir}/${path}")
		match full.type!() {
			Err(PathErr(NotFound, _)) => Hash.write_str!(hash, "${path}\u(0)gone\u(0)")
			Err(PathErr(err, _)) => Err(Failed("${dir}/${path}: ${err.to_str()}"))
			Ok(IsSymLink) => {
				target = full.read_link!() ? |PathErr(err, _)| Failed("${dir}/${path}: ${err.to_str()}")
				Hash.write_str!(hash, "${path}\u(0)link\u(0)${target.display()}\u(0)")
			}
			Ok(IsFile) => {
				executable = full.is_executable!() ? |PathErr(err, _)| Failed("${dir}/${path}: ${err.to_str()}")
				size = full.size_in_bytes!() ? |PathErr(err, _)| Failed("${dir}/${path}: ${err.to_str()}")
				Hash.write_str!(hash, "${path}\u(0)${if executable "true" else "false"}\u(0)${size.to_str()}\u(0)")?
				Hash.write_file!(hash, "${dir}/${path}")
			}
			Ok(_) => Ok({})
		}
	}

	## What roux's platform and tools are built from: roux's and fourneau's
	## trees (roux's holds its toolchain.json, so Zig's and roc's versions).
	roux_identity! : Tools => Try(Str, [Failed(Str), Interrupted])
	roux_identity! = |tools| {
		roux = Keys.tree!(tools.roux, ".")?
		fourneau = Keys.tree!(tools.fourneau, ".")?
		Ok("${roux} ${fourneau}")
	}

	## roux's key: the recipe, its identity, the machine.
	roux! : Tools => Try(Str, [Failed(Str), Interrupted])
	roux! = |tools| {
		identity = Keys.roux_identity!(tools)?
		Hash.bytes!("${roux_key_recipe}\u(0)${identity}\u(0)${Keys.machine_image!()}".to_utf8())
	}

	## The race key: each competitor's key, race.json and workloads/. A
	## check races only when it is not the last race's.
	race! : Str, List((Str, Str)) => Try(Str, [Failed(Str), Interrupted])
	race! = |root, competitors| {
		var $text = "${race_key_recipe}\u(0)"
		for (name, key) in competitors.sort_with(|(a, _), (b, _)| Text.order(a, b)) {
			$text = "${$text}${name}\u(0)${key}\u(0)"
		}
		for sub in ["race.json", "workloads"] {
			tree = Keys.tree!(root, sub)?
			$text = "${$text}${sub}\u(0)${tree}\u(0)"
		}
		Hash.bytes!($text.to_utf8())
	}

	## The harness key: what races a competitor besides its own build, the
	## tool's code (tools/) and race.json.
	harness! : Str => Try(Str, [Failed(Str), Interrupted])
	harness! = |root| {
		var $text = "${harness_key_recipe}\u(0)"
		for sub in ["tools", "race.json"] {
			tree = Keys.tree!(root, sub)?
			$text = "${$text}${sub}\u(0)${tree}\u(0)"
		}
		Hash.bytes!($text.to_utf8())
	}

	## What a build's smoke race races, in race.json's order: every
	## competitor when the harness is not the last release's (or there is
	## none), else each whose key moved; none for the site alone.
	smoke_set : List(Str), List((Str, Str)), Str, Try({ harness_key : Str, competitors : List((Str, Str)) }, [None]) -> List(Str)
	smoke_set = |names, keys, harness, last|
		match last {
			Ok(release) if release.harness_key != "" and release.harness_key == harness =>
				names.keep_if(|name| lookup(keys, name) != lookup(release.competitors, name))
			_ => names
		}

	## What a build links against besides its pins: GitHub's runner image by
	## its version, or this machine's name and C compiler.
	machine_image! : () => Str
	machine_image! = || {
		image = Env.var_str!(OsStr.from_str("ImageOS")) ?? ""
		if image != "" {
			version = Env.var_str!(OsStr.from_str("ImageVersion")) ?? ""
			"runner ${image} ${version}"
		} else {
			host = (Path.utf8("/proc/sys/kernel/hostname").read_utf8!() ?? "").trim()
			compiler = (Run.output!("", ["cc", "--version"]) ?? "").trim()
			"machine ${host} ${compiler}"
		}
	}

	## The store of built competitors: STORE/NAME-KEY.
	store! : () => Try(Str, [Failed(Str)])
	store! = || {
		cache = Keys.cache!()?
		Ok("${cache}/competitors")
	}

	## Downloads and the store: $DRAGRACE_CACHE, else ~/.cache/fourneau-dragrace.
	cache! : () => Try(Str, [Failed(Str)])
	cache! = || {
		explicit = Env.var_str!(OsStr.from_str("DRAGRACE_CACHE")) ?? ""
		xdg = Env.var_str!(OsStr.from_str("XDG_CACHE_HOME")) ?? ""
		home = Env.var_str!(OsStr.from_str("HOME")) ?? ""
		if explicit != "" {
			Ok(explicit)
		} else if xdg != "" {
			Ok("${xdg}/fourneau-dragrace")
		} else if home != "" {
			Ok("${home}/.cache/fourneau-dragrace")
		} else {
			Err(Failed("neither $XDG_CACHE_HOME nor $HOME is defined"))
		}
	}

	## The competitor's binary for key from the store into out/bin, if the
	## store has it, marked used.
	from_store! : Str, Str, Str => Try(Bool, [Failed(Str), Interrupted])
	from_store! = |root, name, key| {
		store = Keys.store!()?
		stored = "${store}/${name}-${key}"
		if Path.utf8(stored).exists!() != Ok(Bool.True) {
			return Ok(Bool.False)
		}
		Keys.copy!(stored, "${root}/out/bin/${name}")?
		_ = Run.output!("", ["touch", "--", stored])?
		Ok(Bool.True)
	}

	## The competitor's binary just built kept under key; all but the newest
	## few of its kind dropped.
	to_store! : Str, Str, Str => Try({}, [Failed(Str), Interrupted])
	to_store! = |root, name, key| {
		store = Keys.store!()?
		Keys.copy!("${root}/out/bin/${name}", "${store}/${name}-${key}")?
		Keys.prune!(store, name)
	}

	## A file copied with its mode, written beside and renamed over: a
	## program running from `to` keeps its file, and no reader sees half.
	copy! : Str, Str => Try({}, [Failed(Str)])
	copy! = |from, to| {
		Path.utf8(Checkout.parent(to)).create_all!() ? |PathErr(err, _)| Failed("${to}: ${err.to_str()}")
		Path.utf8(from).copy!(Path.utf8("${to}.partial")) ? |CopyErr(failure)| Failed("copying ${from}: ${failure.operation}: ${failure.error.to_str()}")
		Path.utf8("${to}.partial").rename!(Path.utf8(to)) ? |PathErr(err, _)| Failed("${to}: ${err.to_str()}")
		Ok({})
	}

	## Keep the newest used `store_keep` of name's entries (NAME-KEY, the key
	## 64 hex digits), and remove the rest.
	prune! : Str, Str => Try({}, [Failed(Str), Interrupted])
	prune! = |store, name| {
		entries = Path.utf8(store).list!() ? |PathErr(err, _)| Failed("${store}: ${err.to_str()}")
		var $kept = []
		for entry in entries {
			base = Checkout.base(entry.display())
			if base.starts_with("${name}-") and base.to_utf8().len() == name.to_utf8().len() + 65 {
				used = entry.time_modified!() ? |PathErr(err, _)| Failed("${entry.display()}: ${err.to_str()}")
				$kept = $kept.append((used, entry))
			}
		}
		newest_first = $kept.sort_with(|(a, _), (b, _)| b.order_relative_to(a))
		for (_, old) in newest_first.drop_first(Keys.store_keep) {
			Run.log!("store: dropping ${Checkout.base(old.display())}")
			match old.type!() {
				Ok(IsDir) => old.delete_all!() ? |PathErr(err, _)| Failed("${old.display()}: ${err.to_str()}")
				_ => old.delete!() ? |PathErr(err, _)| Failed("${old.display()}: ${err.to_str()}")
			}
		}
		Ok({})
	}
}

competitor_key_recipe = "competitor-key 4"
roux_key_recipe = "roux-key 1"
race_key_recipe = "race-key 1"
harness_key_recipe = "harness-key 1"

lookup : List((Str, Str)), Str -> Str
lookup = |pairs, name|
	match pairs.find_first(|(key, _)| key == name) {
		Ok((_, value)) => value
		Err(_) => ""
	}

when_failed : [Failed(Str), Interrupted], (Str -> Str) -> [Failed(Str), Interrupted]
when_failed = |err, describe|
	match err {
		Failed(why) => Failed(describe(why))
		Interrupted => Interrupted
	}

expect Keys.encode_parts([("a", "xyz")]) == "a\u(0)3\u(0)xyz\u(0)".to_utf8()
expect Keys.smoke_set(["a", "b"], [("a", "1"), ("b", "2")], "h", Err(None)) == ["a", "b"]
expect Keys.smoke_set(["a", "b"], [("a", "1"), ("b", "2")], "h", Ok({ harness_key: "h", competitors: [("a", "1"), ("b", "3")] })) == ["b"]
expect Keys.smoke_set(["a", "b"], [("a", "1"), ("b", "2")], "h", Ok({ harness_key: "other", competitors: [("a", "1"), ("b", "2")] })) == ["a", "b"]
expect Keys.smoke_set(["a"], [("a", "1")], "h", Ok({ harness_key: "", competitors: [("a", "1")] })) == ["a"]
