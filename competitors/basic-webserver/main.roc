app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.17.0/AC9goxhsjJJdrQtnc2ga3eTiESyh6ZLraZJsCVdEfeZT.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	roc: "nightly-2026-10-04-130536d",
}

# The basic-webserver competitor: Roc's own platform, as released (a Rust
# host on hyper and tokio; each `respond!` runs on the host's handler
# pool). Written as its examples are; the limits raised to the race's
# load (README.md says which and why).

import pf.Attribute
import pf.Env
import pf.Html
import pf.MultipartFormData
import pf.Server
import pf.Sqlite
import pf.Path
import pf.Sse
import http.Response
import Conduit

Dish : { name : Str, price : U32 }

## The templates workload's dishes, made once by `init!`; the conduit
## workload's database (DRAGRACE_DATABASE: the race's `{db}`), a pool in
## WAL mode with synchronous=NORMAL, as the contract says.
Context : { dishes : List(Dish), db : Sqlite.Db }

program = { init!, respond!, shutdown! }

## The largest body /echo takes, as the other competitors.
echo_bytes_max : U64
echo_bytes_max = 1024 * 1024

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || {
	host = Env.var_str!("DRAGRACE_ADDRESS") ? |_| Exit(2)
	port_text = Env.var_str!("DRAGRACE_PORT") ? |_| Exit(2)
	port = U16.from_str(port_text) ? |_| Exit(2)
	config =
		Server.default_config
			.with_listen({ host, port })
			# The race holds 256 connections, each with a request in flight:
			# the defaults (256 connections, 32 handlers, 64 queued) answer
			# the rest 503. 1,024 connections, as fourneau and Go allow; a
			# queue that holds every connection's request.
			.with_limits({ max_connections: 1024, max_handlers: 32, max_queued_handlers: 1024 })
			.with_request_body_limit(echo_bytes_max)
			# Every connection may hold an SSE stream (default 256).
			.with_sse_limits({ max_streams: 1024, max_event_bytes: 64 * 1024 })
	database = Env.var_str!("DRAGRACE_DATABASE") ? |_| Exit(2)
	db = Sqlite.open!({ ..Sqlite.default_config(Path.utf8(database)), max_connections: 32, busy_timeout_ms: 5_000, synchronous: Normal }) ? |_| Exit(3)
	Ok({ config, context: { dishes: menu_dishes, db } })
}

respond! : Server.Request, Context => Try(Server.Outcome, [ServerErr(Str)])
respond! = |request, context| {
	{ path, query } =
		match request.target() {
			Resource({ raw_path, raw_query: Present(raw_query), .. }) => { path: raw_path, query: raw_query }
			Resource({ raw_path, .. }) => { path: raw_path, query: "" }
			_ => { path: "", query: "" }
		}
	match (request.method(), path) {
		(GET, "/plaintext") => Ok(Server.respond(plain(200, "Hello, World!")))
		(POST, "/echo") =>
			match request.body().with_limit(echo_bytes_max).read_all!() {
				Ok(body) =>
					Ok(
						Server.respond(
							Response.from_status(200)
								.with_headers([{ name: "Content-Type", value: "application/octet-stream" }])
								.with_body(body),
						),
					)
				Err(_) => Ok(Server.respond(plain(413, "body too large")))
			}
		(GET, "/menu") =>
			Ok(
				Server.respond(
					Response.from_status(200)
						.with_headers([{ name: "Content-Type", value: "text/html; charset=utf-8" }])
						.with_body(Str.to_utf8(menu(context.dishes))),
				),
			)
		(GET, "/sse") =>
			match signals(query) {
				Ok({ count }) => Ok(Server.stream(Sse.unfold!({ step: 0, count: count.to_u64() + 1 }, datastar!)))
				Err(_) => Ok(Server.respond(plain(400, "bad signals")))
			}
		_ =>
			if path.starts_with("/api/") {
				conduit!(request, context.db, path, query)
			} else {
				Ok(Server.respond(plain(404, "not found")))
			}
	}
}

## A conduit request: its body read first (a comment's), then Conduit.roc.
conduit! : Server.Request, Sqlite.Db, Str, Str => Try(Server.Outcome, [ServerErr(Str)])
conduit! = |request, db, path, query| {
	{ method, body } =
		match request.method() {
			POST => { method: "POST", body: request.body().with_limit(65_536).read_all!() ?? [] }
			GET => { method: "GET", body: [] }
			_ => { method: "OTHER", body: [] }
		}
	match Conduit.respond!(db, method, path, query, request.headers(), body) {
		Ok(response) => Ok(Server.respond(response))
		Err(NotFound) => Ok(Server.respond(plain(404, "not found")))
		Err(DbErr(why)) => Err(ServerErr(why))
	}
}

shutdown! : Server.ShutdownReason, Context => Try({}, [Exit(I64)])
shutdown! = |_reason, _context| Ok({})

plain : U16, Str -> Response.Response
plain = |status, text|
	Response.from_status(status)
		.with_headers([{ name: "Content-Type", value: "text/plain; charset=utf-8" }])
		.with_body(Str.to_utf8(text))

# --- the templates workload ---------------------------------------------------

## The page, built with the platform's `Html` (which escapes every text
## value). `Html.render` spells the doctype `<!DOCTYPE html>` and puts no
## line breaks between elements; the race's page has both, so the doctype
## is written here and the breaks are text nodes.
menu : List(Dish) -> Str
menu = |dishes| {
	nl = Html.text("\n")
	rows = dishes.map(|dish| [row([Html.text(dish.name), Html.text(dish.price.to_str())], "td"), nl]).join()
	page = Html.element("html", [Attribute.attribute("lang", "en")], [
		nl,
		Html.element("head", [], [
			Html.void_element("meta", [Attribute.attribute("charset", "utf-8")]),
			Html.element("title", [], [Html.text("Menu")]),
		]),
		nl,
		Html.element("body", [], [
			nl,
			Html.element("h1", [], [Html.text("Menu")]),
			nl,
			Html.element("table", [], List.concat([nl, row([Html.text("Dish"), Html.text("Price")], "th"), nl], rows)),
			nl,
		]),
		nl,
	])
	"<!doctype html>\n${Html.render_without_doc_type(page)}\n"
}

row = |cells, tag| Html.element("tr", [], cells.map(|cell| Html.element(tag, [], [cell])))

menu_dishes : List(Dish)
menu_dishes = [
	{ name: "Roux", price: 120 },
	{ name: "Fish & chips", price: 290 },
	{ name: "Crème brûlée", price: 180 },
	{ name: "<b>Bold</b> stew", price: 240 },
	{ name: "Skyr & berries", price: 150 },
	{ name: "Hákarl", price: 990 },
	{ name: "Plokkfiskur", price: 310 },
	{ name: "Kjötsúpa", price: 270 },
	{ name: "Rúgbrauð <warm>", price: 90 },
	{ name: "Pylsa með öllu", price: 120 },
	{ name: "Flatkaka & hangikjöt", price: 210 },
	{ name: "1 < 2 > 0 pie", price: 160 },
]

# --- the SSE workload: a Datastar action --------------------------------------

## Datastar's signals, from the `datastar` query parameter (JSON).
signals : Str -> Try({ count : U32 }, [BadSignals])
signals = |query| {
	params = MultipartFormData.parse_form_url_encoded(Str.to_utf8(query)) ? |_| BadSignals
	json = Dict.get(params, "datastar") ? |_| BadSignals
	match Json.parse(json) {
		Ok(parsed) => Ok(parsed)
		Err(_) => Err(BadSignals)
	}
}

## The events after the signals one: an append per log line.
log_events : U64
log_events = 8

## One event per step, each sent as it is made: the new count as a
## signal, the count's element, then the log lines.
datastar! : { step : U64, count : U64 } => Try(Sse.Step({ step : U64, count : U64 }), [])
datastar! = |{ step, count }| {
	next = { step: step + 1, count }
	n = count.to_str()
	if step == 0 {
		Ok(Emit({ event: Sse.Event.keyed("datastar-patch-signals", "signals", "{\"count\":${n}}"), state: next, wake: Immediately }))
	} else if step == 1 {
		Ok(Emit({ event: Sse.Event.keyed("datastar-patch-elements", "elements", "<span id=\"count\">${n}</span>"), state: next, wake: Immediately }))
	} else if step < 2 + log_events {
		line = "elements <li>Event ${(step - 1).to_str()} of ${log_events.to_str()}</li>"
		Ok(Emit({ event: Sse.Event.named("datastar-patch-elements", ["selector #log", "mode append", line]), state: next, wake: Immediately }))
	} else {
		Ok(End)
	}
}

expect signals("datastar=%7B%22count%22%3A41%7D") == Ok({ count: 41 })
expect signals("") == Err(BadSignals)
expect signals("datastar=%7B%7D") == Err(BadSignals)
expect signals("datastar=nope") == Err(BadSignals)
expect signals("other=%7B%22count%22%3A41%7D") == Err(BadSignals)
expect Str.starts_with(menu(menu_dishes), "<!doctype html>\n<html lang=\"en\">\n<head><meta charset=\"utf-8\"><title>Menu</title></head>\n")
expect signals("datastar=%7B%22count%22%3A4294967295%7D") == Ok({ count: 4294967295 })
expect signals("datastar=%7B%22count%22%3A4294967296%7D") == Err(BadSignals)
expect signals("datastar=%7B%22count%22%3A-1%7D") == Err(BadSignals)
