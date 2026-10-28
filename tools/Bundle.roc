import pf.Env
import pf.Path
import pf.Stdout
import pf.Utc
import Build
import Checkout
import Conduit
import Flags
import Hash
import Keys
import Local
import Run
import Site
import Toolchain

## A build packed for a release (build.yml), into -out:
##
## - race.tar.gz: a checkout as a race needs it, for the racer and its
##   workers: race.json, workloads/, each competitor's competitor.json,
##   out/toolchain.json, and out/bin with the competitors, oha, and this
##   dragrace binary with the commit it was built from beside it
##   (dragrace.commit);
## - site.tar.gz: the site, for the site host: dragrace-site (which
##   migrates its database as it starts) and static/ with site.json (the
##   commit, which the racer reads);
## - build.json: the commits built, each competitor's key and the race key,
##   and each file's SHA-256 (the release's body too).
##
## Everything must be built first (dragrace build, dragrace site build).
Bundle :: [].{
	command! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	command! = |root, args| {
		flags = Flags.parse(args, [{ name: "out", kind: Value("${Checkout.out(root)}/bundle"), usage: "where the files go" }])?
		asked = Flags.value(flags, "out")
		Path.utf8(asked).create_all!() ? |PathErr(err, _)| Failed("${asked}: ${err.to_str()}")
		# Absolute: tar runs where the links are.
		out = (Path.utf8(asked).absolute!() ? |PathErr(err, _)| Failed("${asked}: ${err.to_str()}")).display()
		# The toolchain's record, out/toolchain.json, made afresh: what the
		# race posts as its versions.
		_ = Toolchain.load!(root)?
		race = Checkout.race!(root)?
		fingerprint = Checkout.fingerprint!(root)?
		if fingerprint.dragrace_dirty or fingerprint.fourneau_dirty or fingerprint.roux_dirty {
			return Err(Failed("a checkout has changes not committed: a build is of commits"))
		}
		exe = Env.exe_path!() ? |_| Failed("this binary's path is not known")
		oha = Local.oha!(race.oha)?
		# Each competitor's key as `dragrace build` took it, and the race key.
		built = Build.read_keys!(root)?
		competitors = race.competitors.map_try(
			|name|
				match built.find_first(|(n, _)| n == name) {
					Ok(pair) => Ok(pair)
					Err(_) => Err(Failed("${name}: no key in ${Build.keys_path(root)} (dragrace build first)"))
				},
		)?
		race_key = Keys.race!(root, competitors)?
		harness_key = Keys.harness!(root)?
		commit_file = "${out}/dragrace.commit"
		Path.utf8(commit_file).write_utf8!("${fingerprint.dragrace}\n") ? |PathErr(err, _)| Failed("${commit_file}: ${err.to_str()}")
		race_files =
			[
				("race.json", "${root}/race.json"),
				("workloads", "${root}/workloads"),
				("out/toolchain.json", Toolchain.record(root)),
				("out/bin/oha", oha),
				("out/bin/dragrace", exe.display()),
				("out/bin/dragrace.commit", commit_file),
				# The seeded database every server is started on.
				("out/conduit/conduit.db", Conduit.database(root)),
			].concat(race.competitors.join_map(|name| [("competitors/${name}/competitor.json", "${root}/competitors/${name}/competitor.json"), ("out/bin/${name}", "${Checkout.bin(root)}/${name}")]))
		race_sha = Bundle.tarball!("${out}/race.tar.gz", race_files)?
		# The commit the site serves, at /site.json: the racer updates only to
		# it.
		site_json = "${out}/site.json"
		Path.utf8(site_json).write_utf8!(Json.to_str(Dict.from_list([("fourneau-dragrace", fingerprint.dragrace)]))) ? |PathErr(err, _)| Failed("${site_json}: ${err.to_str()}")
		site_sha = Bundle.tarball!(
			"${out}/site.tar.gz",
			[
				("dragrace-site", Site.binary(root)),
				("static", "${root}/site/static"),
				("static/site.json", site_json),
			],
		)?
		info = {
			commits: Dict.from_list([("fourneau-dragrace", fingerprint.dragrace), ("fourneau", fingerprint.fourneau), ("roux", fingerprint.roux)]),
			built_at: Utc.now!().to_iso_8601(),
			files: Dict.from_list([("race.tar.gz", race_sha), ("site.tar.gz", site_sha)]),
			competitors: Dict.from_list(competitors),
			race_key,
			harness_key,
		}
		encoded = Json.to_str(info)
		build_json = "${out}/build.json"
		Path.utf8(build_json).write_utf8!(encoded) ? |PathErr(err, _)| Failed("${build_json}: ${err.to_str()}")
		_ = Stdout.line!("bundled into ${out}:\n${encoded}")
		Ok({})
	}

	## A gzipped tarball of files and directories, each at its name, and its
	## SHA-256. GNU tar makes it from a directory of links to them: sorted,
	## no owners, no times, each file 644 or, executable, 755, so the same
	## files make the same tarball. A name inside a directory also given is
	## added beside that directory's files (static/site.json).
	tarball! : Str, List((Str, Str)) => Try(Str, [Failed(Str), Interrupted])
	tarball! = |path, entries| {
		staging = "${path}.staging"
		_ = Path.utf8(staging).delete_all!()
		var $tops = []
		for (name, source) in entries {
			kind = if Path.utf8(source).is_dir!() == Ok(Bool.True) Directory else File
			link = "${staging}/${name}"
			match kind {
				Directory => {
					# A directory's files each linked, so a name given inside
					# it lands beside them.
					for relative in Checkout.files_under!(source)? {
						made = "${link}/${relative}"
						Path.utf8(Checkout.parent(made)).create_all!() ? |PathErr(err, _)| Failed("${made}: ${err.to_str()}")
						Path.utf8("${source}/${relative}").symlink!(Path.utf8(made), File) ? |PathErr(err, _)| Failed("${made}: ${err.to_str()}")
					}
				}
				File => {
					Path.utf8(Checkout.parent(link)).create_all!() ? |PathErr(err, _)| Failed("${link}: ${err.to_str()}")
					Path.utf8(source).symlink!(Path.utf8(link), File) ? |PathErr(err, _)| Failed("${link}: ${err.to_str()} (${source})")
				}
			}
			top =
				match name.split_first("/") {
					Ok({ before, .. }) => before
					Err(_) => name
				}
			if !$tops.contains(top) {
				$tops = $tops.append(top)
			}
		}
		tar = path.drop_suffix(".gz")
		_ = Path.utf8(tar).delete!()
		Run.run!(staging, [], ["tar", "--create", "--dereference", "--sort=name", "--format=gnu", "--owner=0", "--group=0", "--numeric-owner", "--mtime=@0", "--mode=u=rwX,go=rX", "--file", tar].concat($tops))?
		Run.run!("", [], ["gzip", "-n", "-f", tar])?
		_ = Path.utf8(staging).delete_all!()
		Hash.file!(path)
	}
}
