import pf.Path
import Checkout
import Config
import Fetch
import Hash
import JsonValue
import Keys
import Run
import Text

## The pinned tools, fetched and checked: Zig and roc at roux's pins
## (roux's toolchain.json, one pin per tool in the repository that owns
## it), musl's two files for `roc build`, roux's platform and tools readied
## (from the store, or built), and the record of what a build was built
## with, out/toolchain.json, which race.tar.gz carries and a race posts.
Toolchain :: [].{
	## What a build was built with: Zig and roc at roux's pins, the Go, Rust,
	## axum, tokio and basic-webserver the competitors pin.
	Used : { zig : Str, roc : Str, go : Str, rust : Str, axum : Str, tokio : Str, basic_webserver : Str }

	## The tools ready, and what they are.
	Ready : { tools : Keys.Tools, used : Used }

	## Fetch, check and ready everything; record it in out/toolchain.json.
	load! : Str => Try(Ready, [Failed(Str), Interrupted])
	load! = |root| {
		cache = Keys.cache!()?
		fourneau = Checkout.beside(root, "fourneau")
		roux = Checkout.beside(root, "roux")
		for checkout in [fourneau, roux] {
			if Path.utf8("${checkout}/build.zig").is_file!() != Ok(Bool.True) {
				return Err(Failed("no checkout at ${checkout} (fourneau and roux go beside this repository)"))
			}
		}
		pins = Toolchain.pins!(roux)?
		zig_dir = Toolchain.archive!(cache, "zig-${pins.zig.version}", pins.zig)?
		roc_dir = Toolchain.archive!(cache, "roc-${pins.roc.version}", pins.roc)?
		Toolchain.musl!(cache, pins.roc_musl, roux)?
		tools = { zig: "${zig_dir}/zig", roc: "${roc_dir}/roc", roux, fourneau, zig_version: pins.zig.version, roc_version: pins.roc.version }
		versions = Toolchain.competitor_versions!(root)?
		used = { zig: pins.zig.version, roc: pins.roc.version, go: versions.go, rust: versions.rust, axum: versions.axum, tokio: versions.tokio, basic_webserver: versions.basic_webserver }
		Toolchain.ready_roux!(tools)?
		record = Json.to_str(used)
		Path.utf8(Checkout.out(root)).create_all!() ? |PathErr(err, _)| Failed("out: ${err.to_str()}")
		Path.utf8(Toolchain.record(root)).write_utf8!(record) ? |PathErr(err, _)| Failed("out/toolchain.json: ${err.to_str()}")
		Run.log!("toolchain: zig ${used.zig}, roc ${used.roc}, go ${used.go}, rust ${used.rust}")
		Ok({ tools, used })
	}

	## out/toolchain.json.
	record : Str -> Str
	record = |root| "${Checkout.out(root)}/toolchain.json"

	## A race's versions, a row each as the site keeps them: the build's
	## record, and oha's and the droplet image from race.json. A record from
	## before basic-webserver's version was in it races too, without it.
	versions! : Str, Config.Race => Try(List({ name : Str, version : Str }), [Failed(Str)])
	versions! = |root, race| {
		used = Toolchain.recorded(Checkout.read!(Toolchain.record(root))?)?
		Ok([
			{ name: "zig", version: used.zig },
			{ name: "roc", version: used.roc },
			{ name: "oha", version: race.oha.version },
			{ name: "go", version: used.go },
			{ name: "rust", version: used.rust },
			{ name: "axum", version: used.axum },
			{ name: "tokio", version: used.tokio },
			{ name: "basic_webserver", version: used.basic_webserver },
			{ name: "droplet_image", version: race.cloud.image },
		])
	}

	## out/toolchain.json's text read back; basic-webserver's version ""
	## in a record from before it was kept.
	recorded : Str -> Try(Used, [Failed(Str)])
	recorded = |text| {
		parsed : Try({ zig : Str, roc : Str, go : Str, rust : Str, axum : Str, tokio : Str, basic_webserver ?: Str }, _)
		parsed = Json.parse(text)
		used = parsed ? |_| Failed("out/toolchain.json: not the toolchain's record")
		Ok({ zig: used.zig, roc: used.roc, go: used.go, rust: used.rust, axum: used.axum, tokio: used.tokio, basic_webserver: used.?basic_webserver ?? "" })
	}

	## roux's toolchain.json.
	pins! : Str => Try({ zig : Config.Download, roc : Config.Download, roc_musl : Musl }, [Failed(Str)])
	pins! = |roux| {
		path = "${roux}/toolchain.json"
		text = Checkout.read!(path) ? |Failed(why)| Failed("roux's pins (roux checked out beside this repository): ${why}")
		parsed : Try({ zig : Config.Download, roc : Config.Download, roc_musl : { commit : Str, url : Str, files : Dict(Str, Str) } }, _)
		parsed = Json.parse(text)
		pins = parsed ? |_| Failed("${path}: not roux's pins")
		if pins.zig.sha256 == "" or pins.roc.sha256 == "" {
			return Err(Failed("${path}: no zig or roc pin"))
		}
		files = pins.roc_musl.files.to_list().sort_with(|(a, _), (b, _)| Text.order(a, b))
		Ok({ zig: pins.zig, roc: pins.roc, roc_musl: { commit: pins.roc_musl.commit, url: pins.roc_musl.url, files } })
	}

	## musl's files from Roc's source at the nightly's commit, each pinned.
	Musl : { commit : Str, url : Str, files : List((Str, Str)) }

	## An archive downloaded, checked and unpacked once; the directory with
	## its one top-level directory's contents.
	archive! : Str, Str, Config.Download => Try(Str, [Failed(Str), Interrupted])
	archive! = |cache, name, pin| {
		dir = "${cache}/${name}"
		if Path.utf8("${dir}/.verified").exists!() == Ok(Bool.True) {
			return Ok(dir)
		}
		archive_path = "${cache}/${Checkout.base(pin.url)}"
		Fetch.pinned!(pin.url, pin.sha256, archive_path)?
		_ = Path.utf8(dir).delete_all!()
		Path.utf8(dir).create_all!() ? |PathErr(err, _)| Failed("${dir}: ${err.to_str()}")
		Run.run!(dir, [], ["tar", "-xf", archive_path, "--strip-components=1"])?
		Path.utf8("${dir}/.verified").write_utf8!("${pin.sha256}\n") ? |PathErr(err, _)| Failed("${dir}: ${err.to_str()}")
		Ok(dir)
	}

	## musl's crt1.o and libc.a where `roc build` looks for them in roux's
	## checkout, from Roc's source at the pinned commit, each file checked
	## (GitHub's archives are not byte-stable, so the archive is not pinned).
	musl! : Str, Musl, Str => Try({}, [Failed(Str), Interrupted])
	musl! = |cache, musl, roux| {
		musl_dir = "${roux}/platform/targets/x64musl"
		var $missing = Bool.False
		for (path, want) in musl.files {
			if Hash.file!("${musl_dir}/${Checkout.base(path)}") != Ok(want) {
				$missing = Bool.True
			}
		}
		if !$missing {
			return Ok({})
		}
		source = "${cache}/roc-source-${musl.commit}"
		Path.utf8(source).create_all!() ? |PathErr(err, _)| Failed("${source}: ${err.to_str()}")
		archive_path = "${cache}/roc-${musl.commit}.tar.gz"
		Fetch.unpinned!(musl.url, archive_path)?
		Run.run!(source, [], ["tar", "-xzf", archive_path, "--strip-components=1", "--wildcards"].concat(musl.files.map(|(path, _)| "*/${path}")))?
		Path.utf8(musl_dir).create_all!() ? |PathErr(err, _)| Failed("${musl_dir}: ${err.to_str()}")
		for (path, want) in musl.files {
			got = Hash.file!("${source}/${path}") ?? ""
			if got != want {
				return Err(Failed("roc source ${musl.commit}: ${path} sha256 ${got}, pinned ${want}"))
			}
			Keys.copy!("${source}/${path}", "${musl_dir}/${Checkout.base(path)}")?
		}
		Ok({})
	}

	## The Go and Rust pins, asked of their tools in the competitors'
	## directories: Go from competitors/go's go.mod (its toolchain line),
	## Rust as rustup picks it there, axum and tokio as Cargo.lock resolves
	## them, basic-webserver's platform as its competitor.json says. Asked on
	## every build, a competitor from the store included.
	competitor_versions! : Str => Try({ go : Str, rust : Str, axum : Str, tokio : Str, basic_webserver : Str }, [Failed(Str), Interrupted])
	competitor_versions! = |root| {
		go_mod = Run.output!("${root}/competitors/go", ["go", "mod", "edit", "-json"])?
		go_module = JsonValue.parse(go_mod) ? |_| Failed("go mod edit: not JSON")
		toolchain = go_module.get("Toolchain").text()
		go = if toolchain == "" go_module.get("Go").text() else toolchain.drop_prefix("go")
		axum_dir = "${root}/competitors/axum"
		# rustc -vV is `key: value` lines, release among them (rustc's own
		# documented format, which cargo reads too).
		rustc = Run.output!(axum_dir, ["rustc", "-vV"])?
		rust =
			match rustc.split_on("\n").keep_oks(|line| if line.starts_with("release: ") Ok(line.drop_prefix("release: ")) else Err(NotIt)).first() {
				Ok(release) => release
				Err(_) => ""
			}
		metadata = Run.output!(axum_dir, ["cargo", "metadata", "--format-version", "1", "--locked"])?
		# Its "packages" key is a Roc keyword, which no record field can be.
		cargo = JsonValue.parse(metadata) ? |_| Failed("cargo metadata: not JSON")
		resolve = cargo.get("resolve")
		root_id = resolve.get("root").text()
		direct =
			match resolve.get("nodes").items().find_first(|node| node.get("id").text() == root_id) {
				Ok(node) => node.get("deps").items().map(|dep| dep.get("pkg").text())
				Err(_) => []
			}
		version_of = |name|
			match cargo.get("packages").items().find_first(|pkg| pkg.get("name").text() == name and direct.contains(pkg.get("id").text())) {
				Ok(pkg) => pkg.get("version").text()
				Err(_) => ""
			}
		axum = version_of("axum")
		tokio = version_of("tokio")
		basic_webserver = Toolchain.platform_version!(root, "basic-webserver")?
		if go == "" or rust == "" or axum == "" or tokio == "" {
			return Err(Failed("competitors' versions: go ${Str.inspect(go)}, rust ${Str.inspect(rust)}, axum ${Str.inspect(axum)}, tokio ${Str.inspect(tokio)}"))
		}
		Ok({ go, rust, axum, tokio, basic_webserver })
	}

	## A Roc competitor's platform version, from its competitor.json. Its
	## main.roc pins the platform by a release URL; a version that URL does
	## not carry is two pins that disagree, refused rather than raced.
	platform_version! : Str, Str => Try(Str, [Failed(Str)])
	platform_version! = |root, name| {
		dir = "${root}/competitors/${name}"
		competitor = Config.competitor(name, Checkout.read!("${dir}/competitor.json")?)?
		main = Checkout.read!("${dir}/main.roc")?
		if !Toolchain.pins_release(main, competitor.version) {
			return Err(Failed("competitors/${name}: competitor.json's version ${Str.inspect(competitor.version)} is not the release main.roc's platform URL pins"))
		}
		Ok(competitor.version)
	}

	## main.roc pins a GitHub release of that version: its URL holds
	## `/releases/download/VERSION/`, the slashes keeping 0.1 from matching
	## 0.19.0.
	pins_release : Str, Str -> Bool
	pins_release = |main, version| {
		if version == "" or Str.contains(version, "/") {
			return Bool.False
		}
		Str.contains(main, "/releases/download/${version}/")
	}

	## roux's platform and tools in its checkout: from the store under their
	## key, else built there and stored.
	ready_roux! : Keys.Tools => Try({}, [Failed(Str), Interrupted])
	ready_roux! = |tools| {
		key = Keys.roux!(tools)?
		store = Keys.store!()?
		stored = "${store}/${roux_store_name}-${key}"
		if Path.utf8("${stored}/done").exists!() == Ok(Bool.True) {
			for path in roux_built {
				Keys.copy!("${stored}/${path}", "${tools.roux}/${path}")?
			}
			_ = Run.output!("", ["touch", "--", stored])?
			Run.log!("roux: from the store, key ${Text.take(key, 12)}")
			return Ok({})
		}
		for step in ["platform", "tools"] {
			Run.run!(tools.roux, [], [tools.zig, "build", step])?
		}
		_ = Path.utf8(stored).delete_all!()
		for path in roux_built {
			Keys.copy!("${tools.roux}/${path}", "${stored}/${path}")?
		}
		# Written last: an entry cut short has no `done` and is built again.
		Path.utf8("${stored}/done").write_utf8!("") ? |PathErr(err, _)| Failed("${stored}: ${err.to_str()}")
		Run.log!("roux: built and stored, key ${Text.take(key, 12)}")
		Keys.prune!(store, roux_store_name)
	}
}

## roux's entries in the store, apart from the roux competitor's.
roux_store_name = "roux-platform"

## What `zig build platform` and `zig build tools` make in roux's checkout.
roux_built = ["platform/targets/x64musl/libhost.a", "zig-out/bin/roux", "zig-out/bin/roux-db", "zig-out/bin/roux-load"]

# basic-webserver's header pins its release by URL; another version, a
# prefix of it, or none is not that pin.
pinned_header = "app [main!] { pf: platform \"https://github.com/roc-lang/basic-webserver/releases/download/0.19.0/4KBAoi.tar.zst\" }"

expect Toolchain.pins_release(pinned_header, "0.19.0")
expect !Toolchain.pins_release(pinned_header, "0.18.0")
expect !Toolchain.pins_release(pinned_header, "0.1")
expect !Toolchain.pins_release(pinned_header, "")
expect !Toolchain.pins_release(pinned_header, "0.19.0/4KBAoi.tar.zst\" }")

# A record from before basic-webserver's version still reads (the racer may
# race a build made before it); one missing another field does not.
old_record = "{\"axum\":\"0.8.9\",\"go\":\"1.27.3\",\"roc\":\"r\",\"rust\":\"1.99.1\",\"tokio\":\"1.54.1\",\"zig\":\"0.17.0\"}"

expect Toolchain.recorded(old_record).map_ok(|u| u.basic_webserver) == Ok("")
expect Toolchain.recorded(old_record.replace_first("{", "{\"basic_webserver\":\"0.19.0\",")).map_ok(|u| u.basic_webserver) == Ok("0.19.0")
expect Toolchain.recorded(old_record.replace_first("\"go\":\"1.27.3\",", "")).is_err()
