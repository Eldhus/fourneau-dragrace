import pf.Http
import pf.Path
import pf.Sleep
import pf.Monotonic
import pf.Utc
import http.Request
import http.Response
import Checkout
import Fetch
import Flags
import Hash
import JsonValue
import Run
import Text

## The host agent deploys the site. A timer runs it every minute, as root:
## it reads the newest release's build.json; a site not yet deployed is
## downloaded, checked, unpacked beside the others, made current, and the
## site restarted; if it does not answer /api/health within 30 s, the
## previous one is made current again and that build is never tried again.
## Installed by the owner (dragrace site install-server), never updated by
## a build.
##
## The site migrates its database as it starts (roux: site/db/schema.sql
## and ledger.sql), and the previous site may not open what a newer one
## migrated. So before a new site starts, the database is copied, with the
## site stopped; if the new site then does not answer, the copy is put back
## with the previous site.
HostAgent :: [].{
	## The owner's, on the site host (/etc/dragrace-host/config.json): the
	## repository (owner/name), the site's code (releases/ID, and current, a
	## link to one), its service, its health as the agent asks it (by the
	## site's name, its certificate's), its database and its user.
	Config : { repository : Str, home : Str, service : Str, health : Str, database : Str, user : Str }

	## `dragrace host-agent [-config F]`: one deploy, if one is due.
	command! : List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	command! = |args| {
		flags = Flags.parse(args, [{ name: "config", kind: Value("/etc/dragrace-host/config.json"), usage: "the owner's config" }])?
		path = Flags.value(flags, "config")
		parsed : Try(Config, _)
		parsed = Json.parse(Checkout.read!(path)?)
		config = parsed ? |_| Failed("${path}: not the host agent's config")
		if config.database == "" or config.user == "" {
			return Err(Failed("${path}: database and user are required (site install-server writes them)"))
		}
		deploy!(config)
	}

	## A release's download URL: the newest build's.
	latest : Str, Str -> Str
	latest = |repository, name| "https://github.com/${repository}/releases/latest/download/${name}"

	## The copy of the database made before a build's site first starts,
	## in backups/ (beside the site's own copies, which it names otherwise).
	copy_name : Str -> Str
	copy_name = |id| "pre-deploy-${id}.db"
}

## A deploy under way: written beside the database before
## the site stops, removed when the deploy ends either way. An agent killed
## or a host rebooted mid-way leaves it, and the next run ends that deploy:
## no state but this, the release serving, and the copy.
Journal : { build : Str, release : Str, previous : Str, backup : Str }

## The newest build's site made current, unless it is, or failed. A deploy
## the agent did not finish is ended first.
deploy! : HostAgent.Config => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
deploy! = |config| {
	match finish_interrupted!(config) {
		Ok(Found) => return Ok({})
		Ok(None) => {}
		Err(err) => return Err(err)
	}
	home = config.home
	work = "${home}/download"
	info_path = "${work}/build.json"
	Fetch.quietly!(HostAgent.latest(config.repository, "build.json"), info_path)?
	info = JsonValue.parse(Checkout.read!(info_path)?) ? |_| Failed("build.json: not JSON")
	digest = info.get("files").get("site.tar.gz").text()
	if digest.to_utf8().len() != 64 {
		return Err(Failed("build.json: no site.tar.gz"))
	}
	id = Text.take(digest, 16)
	if Path.utf8("${home}/failed/${id}").exists!() == Ok(Bool.True) {
		# Tried, and it did not answer: the next build will do.
		return Ok({})
	}
	current = current!(home)
	if Checkout.base(current) == id {
		return Ok({})
	}
	tarball = "${work}/site.tar.gz"
	Fetch.quietly!(HostAgent.latest(config.repository, "site.tar.gz"), tarball)?
	got = Hash.file!(tarball)?
	if got != digest {
		# The latest release moved between the two downloads: next minute.
		return Err(Failed("site.tar.gz: SHA-256 ${got}, build.json says ${digest}"))
	}
	release = "${home}/releases/${id}"
	_ = Path.utf8("${release}.new").delete_all!()
	Path.utf8("${release}.new").create_all!() ? |PathErr(err, _)| Failed("${release}.new: ${err.to_str()}")
	_ = Run.output!("", ["tar", "-xzf", tarball, "-C", "${release}.new"])?
	_ = Path.utf8(release).delete_all!()
	Path.utf8("${release}.new").rename!(Path.utf8(release)) ? |PathErr(err, _)| Failed("${release}: ${err.to_str()}")
	commits = info.get("commits")
	Run.log!("deploying site ${id} (dragrace ${Text.take(commits.get("fourneau-dragrace").text(), 7)}, roux ${Text.take(commits.get("roux").text(), 7)})")
	# A first site makes its database from schema.sql: nothing to copy.
	backups = "${Checkout.parent(config.database)}/backups"
	backup = if current == "" "" else "${backups}/${HostAgent.copy_name(id)}"
	if backup != "" {
		write_journal!(config, { build: id, release, previous: current, backup })?
		match copy!(config, backup) {
			Ok({}) => {}
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => {
				# Not the build's doing: the previous site again, and the
				# build tried again next.
				undo!(config, id, current, "")?
				return Err(Failed("site ${id}: ${why}"))
			}
		}
	}
	switch_to!(config, release)?
	if healthy!(config.health) {
		Run.log!("site ${id} is serving")
		remove_journal!(config)?
		prune!("${home}/releases", [id, Checkout.base(current)])
		prune_copies!(backups, id)
		Ok({})
	} else {
		Run.log!("site ${id} did not answer in 30 s: back to ${Checkout.base(current)}")
		roll_back!(config, id, current, backup)
	}
}

## Where current points, "" for none.
current! : Str => Str
current! = |home|
	match Path.utf8("${home}/current").read_link!() {
		Ok(target) => target.display()
		Err(_) => ""
	}

journal_path : HostAgent.Config -> Str
journal_path = |config| "${Checkout.parent(config.database)}/deploying.json"

## The journal, whole or not at all.
write_journal! : HostAgent.Config, Journal => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
write_journal! = |config, journal| {
	path = journal_path(config)
	Path.utf8("${path}.new").write_utf8!(Json.to_str(journal)) ? |PathErr(err, _)| Failed("${path}: ${err.to_str()}")
	_ = Run.output!("", ["chmod", "600", "${path}.new"])?
	Path.utf8("${path}.new").rename!(Path.utf8(path)) ? |PathErr(err, _)| Failed("${path}: ${err.to_str()}")
	Ok({})
}

remove_journal! : HostAgent.Config => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
remove_journal! = |config| {
	path = journal_path(config)
	match Path.utf8(path).delete!() {
		Ok({}) => Ok({})
		Err(PathErr(NotFound, _)) => Ok({})
		Err(PathErr(err, _)) => Err(Failed("${path}: ${err.to_str()}"))
	}
}

## End a deploy the journal says did not finish: the new release, if it is
## linked and answers once started (it migrated as it started); otherwise the
## copy put back, when there is one, and the previous release. Not marked
## failed: the next run tries the build again from the start (a reboot is
## the likely cause, not the build). A failure leaves the journal for the
## next run.
finish_interrupted! : HostAgent.Config => Try([Found, None], [BadFlag(Str), Failed(Str), Interrupted])
finish_interrupted! = |config| {
	text =
		match Path.utf8(journal_path(config)).read_utf8!() {
			Ok(t) => t
			Err(PathErr(NotFound, _)) => return Ok(None)
			Err(PathErr(err, _)) => return Err(Failed("${journal_path(config)}: ${err.to_str()}"))
		}
	parsed : Try(Journal, _)
	parsed = Json.parse(text)
	journal = parsed ? |_| Failed("${journal_path(config)}: not a deploy's journal")
	Run.log!("site ${journal.build}: a deploy that did not finish (the agent stopped mid-way): ending it")
	if current!(config.home) == journal.release {
		if systemctl!("restart", config.service).is_ok() and healthy!(config.health) {
			Run.log!("site ${journal.build} is serving: it migrated as it started")
			remove_journal!(config)?
			return Ok(Found)
		}
	}
	# The copy exists only whole: without it, the new site never started.
	backup = if Path.utf8(journal.backup).exists!() == Ok(Bool.True) journal.backup else ""
	undo!(config, journal.build, journal.previous, backup)?
	Err(Failed("site ${journal.build}: the deploy that did not finish is undone; tried again next"))
}

## Mark a build failed and serve the previous site again, on the database
## as it was before the new site started, when there was one.
roll_back! : HostAgent.Config, Str, Str, Str => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
roll_back! = |config, id, current, backup| {
	failed = "${config.home}/failed"
	_ = Path.utf8(failed).create_all!()
	_ = Path.utf8("${failed}/${id}").write_utf8!(Utc.now!().to_iso_8601())
	undo!(config, id, current, backup)?
	Err(Failed("site ${id} rolled back"))
}

## Serve the previous site again, on the copy when there is one, and end
## the journal. A failure before the previous site is linked leaves the
## journal, so the next run tries again.
undo! : HostAgent.Config, Str, Str, Str => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
undo! = |config, id, current, backup| {
	if backup != "" {
		systemctl!("stop", config.service)?
		sqlite!(config, ".restore '${backup}'\n") ? |err| prefix(err, "site ${id}: putting the database back from ${backup}")
		Run.log!("site ${id}: the database put back from ${backup}")
	}
	if current == "" {
		return Err(Failed("site ${id} failed, and there is no previous one"))
	}
	switch_to!(config, current)?
	remove_journal!(config)?
	if !healthy!(config.health) {
		return Err(Failed("the previous site does not answer either"))
	}
	Ok({})
}

## Stop the site and copy its database to `backup`. current still names
## the previous site: a request on the site's socket while it is stopped
## starts that one, which opens the database as it is (the copy then waits
## for it, or fails and the build is tried again), never the new one, which
## would migrate before the copy.
copy! : HostAgent.Config, Str => Try({}, [Failed(Str), Interrupted])
copy! = |config, backup| {
	systemctl!("stop", config.service).map_err(narrow)?
	# The copy exists only whole: an agent stopped while copying leaves a
	# .partial, and the new site never started.
	partial = "${backup}.partial"
	# VACUUM INTO refuses a file that exists.
	_ = Path.utf8(partial).delete!()
	sqlite!(config, "VACUUM INTO '${partial}';\n") ? |err| narrow(prefix(err, "the copy before the new site"))
	Path.utf8(partial).rename!(Path.utf8(backup)) ? |PathErr(err, _)| Failed("${backup}: ${err.to_str()}")
	Ok({})
}

## Keep the copy made before `id`'s site started, and delete the older
## ones: the agent's only, never the site's own.
prune_copies! : Str, Str => {}
prune_copies! = |dir, id| {
	for entry in Path.utf8(dir).list!() ?? [] {
		name = Checkout.base(entry.display())
		if name.starts_with("pre-deploy-") and name != HostAgent.copy_name(id) {
			_ = entry.delete!()
		}
	}
}

## Point current at a release, atomically, and restart the site.
switch_to! : HostAgent.Config, Str => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
switch_to! = |config, release| {
	link!(config.home, release)?
	systemctl!("restart", config.service)
}

## Point current at a release, atomically.
link! : Str, Str => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
link! = |home, release| {
	link = "${home}/current"
	_ = Path.utf8("${link}.new").delete!()
	Path.utf8(release).symlink!(Path.utf8("${link}.new"), Directory) ? |PathErr(err, _)| Failed("${link}.new: ${err.to_str()}")
	Path.utf8("${link}.new").rename!(Path.utf8(link)) ? |PathErr(err, _)| Failed("${link}: ${err.to_str()}")
	Ok({})
}

## Keep the releases named, and delete the rest.
prune! : Str, List(Str) => {}
prune! = |dir, keep| {
	for entry in Path.utf8(dir).list!() ?? [] {
		if !keep.contains(Checkout.base(entry.display())) {
			_ = entry.delete_all!()
		}
	}
}

## systemctl, its output in the error. A stopped site keeps its sockets
## (systemd's), so a client waits in their queue, and starts it again.
systemctl! : Str, Str => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
systemctl! = |verb, service| {
	_ = Run.output!("", ["systemctl", verb, service]) ? |err| prefix(err, "the site")
	Ok({})
}

## A script run with sqlite3 as the site's user (the files it makes are the
## site's), -bail stopping at the first failed statement, waiting up to 10 s
## for a lock.
sqlite! : HostAgent.Config, Str => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
sqlite! = |config, script| {
	_ = Run.with_input!("", ["runuser", "-u", config.user, "--", "sqlite3", "-bail", config.database], ".timeout 10000\n${script}".to_utf8()) ? |err| prefix(err, "sqlite3")
	Ok({})
}

## The health URL asked until it answers 200 with {"ok":true}, for 30 s.
healthy! : Str => Bool
healthy! = |url| {
	started = Monotonic.now!()
	while started.elapsed!().to_millis() < 30_000 {
		request = Request.from_method(GET).with_uri(url).with_timeout(TimeoutMilliseconds(5_000))
		match Http.send!(request, {}) {
			Ok(response) if Response.status(response) == 200 => {
				answer : Try({ ok : Bool }, _)
				answer = Json.parse(Str.from_utf8_lossy(Response.body(response)))
				if answer == Ok({ ok: Bool.True }) {
					return Bool.True
				}
			}
			Err(Interrupted) => return Bool.False
			_ => {}
		}
		if Sleep.millis!(1_000).is_err() {
			return Bool.False
		}
	}
	Bool.False
}

prefix : [BadFlag(Str), Failed(Str), Interrupted], Str -> [BadFlag(Str), Failed(Str), Interrupted]
prefix = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		BadFlag(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

narrow : [BadFlag(Str), Failed(Str), Interrupted] -> [Failed(Str), Interrupted]
narrow = |err|
	match err {
		Failed(why) | BadFlag(why) => Failed(why)
		Interrupted => Interrupted
	}

expect HostAgent.copy_name("0123456789abcdef") == "pre-deploy-0123456789abcdef.db"
expect HostAgent.latest("Eldhus/fourneau-dragrace", "build.json") == "https://github.com/Eldhus/fourneau-dragrace/releases/latest/download/build.json"
