import pf.Env
import pf.Path
import Config
import Run

## This repository's checkout as the commands find it: its root (the
## directory with race.json, found from anywhere inside), its race and its
## competitors, and where fourneau and roux are (beside it, by the fixed
## layout: README, Use it).
Checkout :: [].{
	## The root: the working directory or the nearest one above it that
	## holds race.json.
	root! : () => Try(Str, [Failed(Str)])
	root! = || {
		cwd = Env.cwd!() ? |_| Failed("the working directory cannot be read")
		var $dir = cwd.display()
		var $tries = 0
		while $tries < 64 {
			if Path.utf8("${$dir}/race.json").is_file!() == Ok(Bool.True) {
				return Ok($dir)
			}
			parent = Checkout.parent($dir)
			if parent == $dir {
				$tries = 64
			} else {
				$dir = parent
				$tries = $tries + 1
			}
		}
		Err(Failed("not inside fourneau-dragrace (no race.json above here)"))
	}

	## The directory a path is in: "/a/b" is "/a", "/a" is "/".
	parent : Str -> Str
	parent = |path|
		match path.drop_suffix("/").split_last("/") {
			Ok({ before: "", .. }) => "/"
			Ok({ before, .. }) => before
			Err(_) => path
		}

	## A path's last part: "/a/b.json" is "b.json".
	base : Str -> Str
	base = |path|
		match path.drop_suffix("/").split_last("/") {
			Ok({ after, .. }) => after
			Err(_) => path
		}

	## Where a raced repository is, fourneau or roux: beside this one.
	beside : Str, Str -> Str
	beside = |root, repository| "${Checkout.parent(root)}/${repository}"

	## out/: builds, results, secrets (ignored by git).
	out : Str -> Str
	out = |root| "${root}/out"

	## out/bin: the competitors, the site, oha.
	bin : Str -> Str
	bin = |root| "${root}/out/bin"

	## race.json and its reference answers.
	race! : Str => Try(Config.Race, [Failed(Str)])
	race! = |root| {
		text = Checkout.read!("${root}/race.json")?
		menu = Checkout.read!("${root}/workloads/menu.html")?
		stream = Checkout.read!("${root}/workloads/sse.txt")?
		Config.race(text, menu, stream)
	}

	## The competitors named, each from its competitor.json.
	competitors! : Str, List(Str) => Try(List(Config.Competitor), [Failed(Str)])
	competitors! = |root, names|
		names.map_try!(|name| Config.competitor(name, Checkout.read!("${root}/competitors/${name}/competitor.json")?))

	## A file's text; a missing or unreadable file names itself.
	read! : Str => Try(Str, [Failed(Str)])
	read! = |path| Path.utf8(path).read_utf8!().map_err(|PathErr(err, _)| Failed("${path}: ${err.to_str()}"))

	## The three checkouts' commits, and whether each has changes.
	Fingerprint : { dragrace : Str, dragrace_dirty : Bool, fourneau : Str, fourneau_dirty : Bool, roux : Str, roux_dirty : Bool }

	fingerprint! : Str => Try(Fingerprint, [Failed(Str), Interrupted])
	fingerprint! = |root| {
		commit! = |dir| {
			head = Run.output!(dir, ["git", "rev-parse", "HEAD"])?
			status = Run.output!(dir, ["git", "status", "--porcelain"])?
			Ok({ head, dirty: status != "" })
		}
		dragrace = commit!(root)?
		fourneau = commit!(Checkout.beside(root, "fourneau"))?
		roux = commit!(Checkout.beside(root, "roux"))?
		Ok({ dragrace: dragrace.head, dragrace_dirty: dragrace.dirty, fourneau: fourneau.head, fourneau_dirty: fourneau.dirty, roux: roux.head, roux_dirty: roux.dirty })
	}
}

expect Checkout.parent("/a/b") == "/a"
expect Checkout.parent("/a") == "/"
expect Checkout.parent("/a/b/") == "/a"
expect Checkout.base("/a/b.json") == "b.json"
expect Checkout.beside("/src/fourneau-dragrace", "roux") == "/src/roux"
