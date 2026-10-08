app [Context, program] { pf: platform "../../roux/platform/main.roc" }

## The dragrace site, a roux app: every page a rocstache template, the races
## read from its SQLite database (site.db, db/), which the racer and the race
## workers fill through the API (Api.roc, docs/self-hosting.md), so a result
## shows the moment it lands. style.css and demo.js are static files the
## host serves itself (static/). This site is the demo: it runs on what it
## races. Paths are relative to where it runs: site.db, backups/, secrets/
## (racer-token and manual-token, one line each) and static/.

import pf.Server
import pf.File
import pf.Sse
import pf.Sqlite
import db/Database
import Api
import Store
import Data
import View
import IndexPage
import HistoryPage
import RaceClasses
import HistoryClasses
import WorkloadsPage
import CompetitorsPage
import MethodPage
import ContributePage
import AboutPage
import NotFoundPage

Context : { db : Sqlite.Db, tokens : Api.Tokens }

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64), DbErr(Sqlite.Err), FileErr(File.FileErr)])
init! = || {
	# FULL: a result is on the disk when its post is answered (owner, 2026-10-06).
	db = Sqlite.open!(Database.at("site.db"), { synchronous: Full })?
	tokens = { racer: secret!("secrets/racer-token")?, manual: secret!("secrets/manual-token")? }
	Ok({ config: { port: 443, static_dir: "static" }, context: { db, tokens } })
}

## A token from its file, its line break dropped; "" when there is no file
## (that token then opens nothing: Api.same_secret).
secret! : Str => Try(Str, [FileErr(File.FileErr)])
secret! = |path|
	match File.read_utf8!(path, 1024) {
		Ok(text) => Ok(text.trim())
		Err(FileErr(FileNotFound)) => Ok("")
		Err(err) => Err(err)
	}

Err : [BadRequest(Str), DbErr(Sqlite.Err), SseErr(Sse.SseErr), EncodeErr(Str)]

respond! : Server.Request, Context => Try(Server.Response, Err)
respond! = |request, { db, tokens }| {
	path = path_of(request.target)
	wanted = query_value(request.target, "class")
	if path.starts_with("/api/") {
		Api.respond!(request, db, tokens, path)
	} else {
		match path {
			"/" => index!(db, request, wanted)
			"/history" => history!(db, request, wanted)
			"/race-classes" => race_classes!(db, request, wanted)
			"/history-classes" => history_classes!(db, request, wanted)
			"/workloads" => workloads!(db, request)
			"/competitors" => competitors!(db, request)
			"/method" => Ok(page(MethodPage.render!(frame("Method", "/method"))))
			"/contribute" => Ok(page(ContributePage.render!(frame("Contribute", "/contribute"))))
			"/about" => Ok(page(AboutPage.render!(frame("About", "/about"))))
			"/data/latest.json" => latest_file!(db, request)
			"/data/index.json" => index_file!(db, request)
			_ =>
				if path.starts_with("/data/runs/") {
					run_file!(db, request, path)
				} else if path.starts_with("/data/classes/") {
					class_file!(db, request, path)
				} else if path.ends_with(".html") {
					Ok(moved(old_address(path)))
				} else {
					Ok(not_found!())
				}
		}
	}
}

# --- the pages that read the races ------------------------------------------

## The newest race, one server class at a time (`?class=NAME`), with a tab
## per class.
index! : Sqlite.Db, Server.Request, Str => Try(Server.Response, Err)
index! = |db, request, wanted| {
	base = frame("FOURNEAU HTTP DRAG RACE", "/")
	{ ready, latest } =
		match Store.latest!(db, request) {
			Ok(run) => { ready: Bool.True, latest: View.latest(run) }
			Err(NotFound) => { ready: Bool.False, latest: no_race }
			Err(DbErr(err)) => return Err(DbErr(err))
		}
	current = View.chosen(latest.classes.map(|class| class.name), wanted)
	racer = Store.status(Store.racer!(db, request)?)
	Ok(page(IndexPage.render!({
		title: base.title,
		home: Bool.True,
		nav: base.nav,
		racer,
		ready,
		id: latest.id,
		started: latest.started,
		took: latest.took,
		timed: latest.timed,
		commits: latest.commits,
		competitors: latest.competitors,
		tabs: View.tabs(latest.classes.map(|class| { name: class.name, label: class.label }), current, "/"),
		classes: latest.classes.keep_if(|class| class.name == current).map(race_class),
	})))
}

history! : Sqlite.Db, Server.Request, Str => Try(Server.Response, Err)
history! = |db, request, wanted| {
	base = frame("History", "/history")
	view = history_view!(db, request)?
	current = View.chosen(view.classes.map(|class| class.name), wanted)
	Ok(page(HistoryPage.render!({
		title: base.title,
		home: base.home,
		nav: base.nav,
		waiting: view.waiting,
		note: view.note,
		competitors: view.competitors,
		tabs: View.tabs(view.classes.map(|class| { name: class.name, label: class.label }), current, "/history"),
		classes: view.classes.keep_if(|class| class.name == current).map(history_class),
	})))
}

competitors! : Sqlite.Db, Server.Request => Try(Server.Response, Err)
competitors! = |db, request| {
	base = frame("Competitors", "/competitors")
	pins =
		match Store.latest!(db, request) {
			Ok(run) => View.pins(run)
			Err(NotFound) => []
			Err(DbErr(err)) => return Err(DbErr(err))
		}
	Ok(page(CompetitorsPage.render!({ title: base.title, home: base.home, nav: base.nav, pins })))
}

## The workloads as the newest race asked them.
workloads! : Sqlite.Db, Server.Request => Try(Server.Response, Err)
workloads! = |db, request| {
	base = frame("Workloads", "/workloads")
	view =
		match Store.workloads!(db, request) {
			Ok({ specs, settings }) => View.workloads(specs, settings)
			Err(NotFound) => { ready: Bool.False, cards: [], rounds: "", warmup: "", measure: "", shares: "", ladder: "", loader_limit: "" }
			Err(DbErr(err)) => return Err(DbErr(err))
		}
	Ok(page(WorkloadsPage.render!({
		title: base.title,
		home: base.home,
		nav: base.nav,
		ready: view.ready,
		cards: view.cards,
		rounds: view.rounds,
		warmup: view.warmup,
		measure: view.measure,
		shares: view.shares,
		ladder: view.ladder,
		loader_limit: view.loader_limit,
	})))
}

history_view! : Sqlite.Db, Server.Request => Try(View.History, [DbErr(Sqlite.Err)])
history_view! = |db, request|
	match Store.latest!(db, request) {
		Ok(run) => Ok(View.history(run, Store.history!(db, request)?))
		Err(NotFound) => Ok(no_history)
		Err(DbErr(err)) => Err(DbErr(err))
	}

## Before the first race: the pages say so.
no_history : View.History
no_history = { waiting: Bool.True, note: "", competitors: [], classes: [] }

no_race : View.Latest
no_race = { id: "", started: "", took: "", timed: Bool.False, commits: [], competitors: [], classes: [] }

## A server class as the race's templates read it: without its tab's
## label (the tabs have it), since a template's contract is exactly what
## it reads.
race_class = |class| { name: class.name, title: class.title, machines: class.machines, strips: class.strips, open: class.open }

## A server class's history charts as their template reads them.
history_class = |class| { title: class.title, charts: class.charts }

# --- the raw data -------------------------------------------------------------

## The newest run whole, as the race page reads it.
latest_file! : Sqlite.Db, Server.Request => Try(Server.Response, Err)
latest_file! = |db, request|
	match Store.latest!(db, request) {
		Ok(run) => json(Json.to_str_try(run))
		Err(NotFound) => Ok(not_found!())
		Err(DbErr(err)) => Err(DbErr(err))
	}

## Every finished run's medians.
index_file! : Sqlite.Db, Server.Request => Try(Server.Response, Err)
index_file! = |db, request| json(Json.to_str_try(Store.history!(db, request)?))

## /data/runs/ID.json, where ID is letters, digits and dashes only.
run_file! : Sqlite.Db, Server.Request, Str => Try(Server.Response, Err)
run_file! = |db, request, path| {
	name = path.drop_prefix("/data/runs/")
	id = name.drop_suffix(".json")
	if id == name or !is_name(id) {
		Err(BadRequest("not a run: ${path}"))
	} else {
		match Store.run!(Sqlite.read(db, request), id) {
			Ok(run) => json(Json.to_str_try(run))
			Err(NotFound) => Ok(not_found!())
			Err(DbErr(err)) => Err(DbErr(err))
		}
	}
}

## /data/classes/ID/CLASS.json: one server class of one run.
class_file! : Sqlite.Db, Server.Request, Str => Try(Server.Response, Err)
class_file! = |db, request, path| {
	rest = path.drop_prefix("/data/classes/")
	match rest.split_first("/") {
		Ok(parts) => {
			class = parts.after.drop_suffix(".json")
			if is_name(parts.before) and is_name(class) and class != parts.after {
				match Store.run!(Sqlite.read(db, request), parts.before) {
					Ok(run) => json(Json.to_str_try(for_class(run, class)))
					Err(NotFound) => Ok(not_found!())
					Err(DbErr(err)) => Err(DbErr(err))
				}
			} else {
				Err(BadRequest("not a class of a run: ${path}"))
			}
		}
		Err(_) => Err(BadRequest("not a class of a run: ${path}"))
	}
}

## A run with one class's machines and results only.
for_class : Data.Run, Str -> Data.Run
for_class = |run, class| {
	..run,
	machines: run.machines.keep_if(|m| m.class == class),
	results: run.results.keep_if(|r| r.class == class),
}

json : Try(Str, _) -> Try(Server.Response, Err)
json = |encoded|
	match encoded {
		Ok(text) => Ok({ status: 200, headers: [{ name: "Content-Type", value: "application/json" }], body: Str.to_utf8(text) })
		Err(err) => Err(EncodeErr(Str.inspect(err)))
	}

is_name : Str -> Bool
is_name = |name| !name.is_empty() and Str.to_utf8(name).all(is_id_byte)

is_id_byte : U8 -> Bool
is_id_byte = |b| (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45

# --- the frame every page shares ---------------------------------------------

pages = [
	{ href: "/", label: "Race" },
	{ href: "/history", label: "History" },
	{ href: "/workloads", label: "Workloads" },
	{ href: "/competitors", label: "Competitors" },
	{ href: "/method", label: "Method" },
	{ href: "/contribute", label: "Contribute" },
	{ href: "/about", label: "About" },
]

## The page title and the navigation, this page marked current.
frame : Str, Str -> { title : Str, home : Bool, nav : List({ href : Str, label : Str, current : Bool }) }
frame = |name, here| {
	title: if here == "/" name else "${name} · FOURNEAU HTTP DRAG RACE",
	home: Bool.False,
	nav: pages.map(|p| { href: p.href, label: p.label, current: p.href == here }),
}

html_headers = [{ name: "Content-Type", value: "text/html; charset=utf-8" }]

page : Str -> Server.Response
page = |html| Server.html(html)

## Effectful: a page rendered by the host (templates compiled by Zig).
not_found! : () => Server.Response
not_found! = || { status: 404, headers: html_headers, body: Str.to_utf8(NotFoundPage.render!(frame("Not found", ""))) }

moved : Str -> Server.Response
moved = |location| { status: 301, headers: [{ name: "Location", value: location }], body: [] }

## The site's addresses before it was roux: /index.html is /, /about.html is
## /about.
old_address : Str -> Str
old_address = |path| {
	page_name = path.drop_suffix(".html")
	if page_name == "/index" "/" else page_name
}

## A query parameter's value, or "" when the target has none by that name.
query_value : Str, Str -> Str
query_value = |target, key|
	match target.split_first("?") {
		Ok(parts) => {
			found = Str.split_on(parts.after, "&").keep_oks(|pair|
				match pair.split_first("=") {
					Ok(kv) => if kv.before == key Ok(kv.after) else Err(NotIt)
					Err(_) => Err(NotIt)
				})
			match List.first(found) {
				Ok(value) => value
				Err(_) => ""
			}
		}
		Err(_) => ""
	}

path_of : Str -> Str
path_of = |target|
	match target.split_first("?") {
		Ok(parts) => parts.before
		Err(_) => target
	}

expect old_address("/index.html") == "/"
expect old_address("/about.html") == "/about"
expect path_of("/history?x=1") == "/history"
expect is_id_byte(45) and !is_id_byte(47) and !is_id_byte(46)
expect query_value("/history?class=premium-4", "class") == "premium-4"
expect query_value("/?x=1&class=smallest", "class") == "smallest"
expect query_value("/", "class") == ""
expect query_value("/?classes=a", "class") == ""
expect is_name("2026-10-06T135849Z-cloud") and is_name("premium-4")
expect !is_name("..") and !is_name("a/b") and !is_name("")

# --- the tabs, through Datastar ----------------------------------------------

## The race page's tabs and class, alone: what a tab's click swaps in
## (Datastar patches #race-classes in place, so the page does not move).
race_classes! : Sqlite.Db, Server.Request, Str => Try(Server.Response, Err)
race_classes! = |db, request, wanted| {
	latest =
		match Store.latest!(db, request) {
			Ok(run) => View.latest(run)
			Err(NotFound) => no_race
			Err(DbErr(err)) => return Err(DbErr(err))
		}
	current = View.chosen(latest.classes.map(|class| class.name), wanted)
	patch!(request, RaceClasses.render!({
		id: latest.id,
		tabs: View.tabs(latest.classes.map(|class| { name: class.name, label: class.label }), current, "/"),
		classes: latest.classes.keep_if(|class| class.name == current).map(race_class),
	}))
}

history_classes! : Sqlite.Db, Server.Request, Str => Try(Server.Response, Err)
history_classes! = |db, request, wanted| {
	view = history_view!(db, request)?
	current = View.chosen(view.classes.map(|class| class.name), wanted)
	patch!(request, HistoryClasses.render!({
		tabs: View.tabs(view.classes.map(|class| { name: class.name, label: class.label }), current, "/history"),
		classes: view.classes.keep_if(|class| class.name == current).map(history_class),
	}))
}

## A Datastar patch: one event, its HTML a line per `elements` field, the
## element replaced by its id (Datastar's default, outer).
patch! : Server.Request, Str => Try(Server.Response, [SseErr(Sse.SseErr)])
patch! = |request, html| {
	stream = Sse.start!(request, [])?
	Sse.send!(stream, patch_event(html))?
	Sse.end!(stream)
}

patch_event : Str -> Sse.Event
patch_event = |html| {
	data = Str.join_with(html.split_on("\n").map(|line| "elements ${line}"), "\n")
	match Sse.Event.named("datastar-patch-elements", data) {
		Ok(event) => event
		Err(InvalidEventName) => crash "a constant event name has no line break"
	}
}

expect
	Sse.Event.to_bytes(patch_event("<div id=\"a\">\n<b>x</b>\n</div>"))
	== Str.to_utf8("event: datastar-patch-elements\ndata: elements <div id=\"a\">\ndata: elements <b>x</b>\ndata: elements </div>\n\n")
