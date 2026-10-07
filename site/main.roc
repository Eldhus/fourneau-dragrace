app [Context, program] { pf: platform "../../roux/platform/main.roc" }

## The dragrace site, a roux app: every page a rocstache template, the races
## read from disk (data/) on each request, so a nightly's results show the
## moment they land. style.css and demo.js are static files the host serves
## itself (static/). This site is the demo: it runs on what it races.

import pf.Server
import pf.File
import pf.Sse
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

Context : {}

program = { init!, respond! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({ config: { port: 443, static_dir: "static" }, context: {} })

respond! : Server.Request, Context => Try(Server.Response, [BadRequest(Str), BadData(Str), FileErr(File.FileErr), SseErr(Sse.SseErr)])
respond! = |request, _context| {
	path = path_of(request.target)
	wanted = query_value(request.target, "class")
	match path {
		"/" => index!(wanted)
		"/history" => history!(wanted)
		"/race-classes" => race_classes!(request, wanted)
		"/history-classes" => history_classes!(request, wanted)
		"/workloads" => Ok(page(WorkloadsPage.render(frame("Workloads", "/workloads"))))
		"/competitors" => competitors!()
		"/method" => Ok(page(MethodPage.render(frame("Method", "/method"))))
		"/contribute" => Ok(page(ContributePage.render(frame("Contribute", "/contribute"))))
		"/about" => Ok(page(AboutPage.render(frame("About", "/about"))))
		"/data/latest.json" => json!("data/latest.json")
		"/data/index.json" => json!("data/index.json")
		_ =>
			if path.starts_with("/data/runs/") {
				run_file!(path)
			} else if path.starts_with("/data/classes/") {
				class_file!(path)
			} else if path.ends_with(".html") {
				Ok(moved(old_address(path)))
			} else {
				Ok(not_found())
			}
	}
}

# --- the pages that read the races ------------------------------------------

## The newest race, one server class at a time (`?class=NAME`), with a tab
## per class.
index! : Str => Try(Server.Response, [BadData(Str), FileErr(File.FileErr)])
index! = |wanted| {
	base = frame("FOURNEAU HTTP DRAG RACE", "/")
	{ ready, latest } =
		match latest!() {
			Ok(run) => { ready: Bool.True, latest: View.latest(run) }
			Err(FileErr(FileNotFound)) => { ready: Bool.False, latest: no_race }
			Err(err) => return Err(err)
		}
	current = View.chosen(latest.classes.map(|class| class.name), wanted)
	Ok(page(IndexPage.render({
		title: base.title,
		home: Bool.True,
		nav: base.nav,
		ready,
		id: latest.id,
		started: latest.started,
		took: latest.took,
		timed: latest.timed,
		commits: latest.commits,
		competitors: latest.competitors,
		tabs: View.tabs(latest.classes.map(|class| { name: class.name, label: class.label }), current, "/"),
		classes: latest.classes.keep_if(|class| class.name == current),
	})))
}

history! : Str => Try(Server.Response, [BadData(Str), FileErr(File.FileErr)])
history! = |wanted| {
	base = frame("History", "/history")
	view = history_view!()?
	current = View.chosen(view.classes.map(|class| class.name), wanted)
	Ok(page(HistoryPage.render({
		title: base.title,
		home: base.home,
		nav: base.nav,
		waiting: view.waiting,
		note: view.note,
		competitors: view.competitors,
		tabs: View.tabs(view.classes.map(|class| { name: class.name, label: class.label }), current, "/history"),
		classes: view.classes.keep_if(|class| class.name == current),
	})))
}

competitors! : () => Try(Server.Response, [BadData(Str), FileErr(File.FileErr)])
competitors! = || {
	base = frame("Competitors", "/competitors")
	pins =
		match latest!() {
			Ok(run) => View.pins(run)
			Err(_) => []
		}
	Ok(page(CompetitorsPage.render({ title: base.title, home: base.home, nav: base.nav, pins })))
}

history_view! : () => Try(View.History, [BadData(Str), FileErr(File.FileErr)])
history_view! = ||
	match latest!() {
		Ok(run) => Ok(View.history(run, Data.index(File.read_utf8!("data/index.json", data_bytes_max)?)?))
		Err(FileErr(FileNotFound)) => Ok(no_history)
		Err(err) => Err(err)
	}

## Before the first race: the pages say so.
no_history : View.History
no_history = { waiting: Bool.True, note: "", competitors: [], classes: [] }

no_race : View.Latest
no_race = { id: "", started: "", took: "", timed: Bool.False, commits: [], competitors: [], classes: [] }

latest! : () => Try(Data.Run, [BadData(Str), FileErr(File.FileErr)])
latest! = || Data.run(File.read_utf8!("data/latest.json", data_bytes_max)?)

# --- the raw data -------------------------------------------------------------

json! : Str => Try(Server.Response, [FileErr(File.FileErr)])
json! = |file|
	match File.read_utf8!(file, data_bytes_max) {
		Ok(text) => Ok({ status: 200, headers: [{ name: "Content-Type", value: "application/json" }], body: Str.to_utf8(text) })
		Err(FileErr(FileNotFound)) => Ok(not_found())
		Err(err) => Err(err)
	}

## /data/runs/ID.json, where ID is letters, digits and dashes only: a
## request names a run, never a path.
run_file! : Str => Try(Server.Response, [BadRequest(Str), FileErr(File.FileErr)])
run_file! = |path| {
	name = path.drop_prefix("/data/runs/")
	id = name.drop_suffix(".json")
	if id == name or id.is_empty() or !Str.to_utf8(id).all(is_id_byte) {
		Err(BadRequest("not a run: ${path}"))
	} else {
		json!("data/runs/${id}.json")
	}
}

## /data/classes/ID/CLASS.json: one server class of one run, its raw data
## (the dragrace tool writes them). Both parts letters, digits and dashes.
class_file! : Str => Try(Server.Response, [BadRequest(Str), FileErr(File.FileErr)])
class_file! = |path| {
	rest = path.drop_prefix("/data/classes/")
	match rest.split_first("/") {
		Ok(parts) => {
			class = parts.after.drop_suffix(".json")
			if is_name(parts.before) and is_name(class) and class != parts.after {
				json!("data/classes/${parts.before}/${class}.json")
			} else {
				Err(BadRequest("not a class of a run: ${path}"))
			}
		}
		Err(_) => Err(BadRequest("not a class of a run: ${path}"))
	}
}

is_name : Str -> Bool
is_name = |name| !name.is_empty() and Str.to_utf8(name).all(is_id_byte)

is_id_byte : U8 -> Bool
is_id_byte = |b| (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45

# --- the frame every page shares ---------------------------------------------

## The largest data file read: the index grows a few KiB a race.
data_bytes_max = 16 * 1024 * 1024

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

not_found : () -> Server.Response
not_found = || { status: 404, headers: html_headers, body: Str.to_utf8(NotFoundPage.render(frame("Not found", ""))) }

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
race_classes! : Server.Request, Str => Try(Server.Response, [BadData(Str), FileErr(File.FileErr), SseErr(Sse.SseErr)])
race_classes! = |request, wanted| {
	latest = View.latest(latest!()?)
	current = View.chosen(latest.classes.map(|class| class.name), wanted)
	patch!(request, RaceClasses.render({
		id: latest.id,
		tabs: View.tabs(latest.classes.map(|class| { name: class.name, label: class.label }), current, "/"),
		classes: latest.classes.keep_if(|class| class.name == current),
	}))
}

history_classes! : Server.Request, Str => Try(Server.Response, [BadData(Str), FileErr(File.FileErr), SseErr(Sse.SseErr)])
history_classes! = |request, wanted| {
	view = history_view!()?
	current = View.chosen(view.classes.map(|class| class.name), wanted)
	patch!(request, HistoryClasses.render({
		tabs: View.tabs(view.classes.map(|class| { name: class.name, label: class.label }), current, "/history"),
		classes: view.classes.keep_if(|class| class.name == current),
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
