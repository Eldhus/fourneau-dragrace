app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.19.0/4KBAoiBazDfi9UF6e3BYKwon6rA8mnx3dbLMLKFzdEMw.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	roc: "nightly-2026-10-24-f6c6cfb",
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

## The catalog workload's page data, as race.json's `catalog` defines it.
Catalog : {
	title : Str,
	note : Str,
	currency : Str,
	shop : { name : Str, city : Str, open : Bool },
	closed : Bool,
	specials : List(Str),
	offers : List({ what : Str, off : U8 }),
	total : U32,
	groups : List({ name : Str, members : List(Str) }),
	rows : List({ id : U32, name : Str, price : U32, discount : U8, on_sale : Bool, stock : I32, hot : Bool, tags : List(Str), added : U16, grams : U32 }),
}

## The templates workload's dishes and the catalog's data, made once by
## `init!`; the conduit workload's database (ROUX_DATABASE, as the race
## starts every server), a pool in WAL mode with synchronous=NORMAL, as the
## contract says.
Context : { dishes : List(Dish), catalog : Catalog, db : Sqlite.Db }

program = { init!, respond!, shutdown! }

## The largest body /echo takes, as the other competitors.
echo_bytes_max : U64
echo_bytes_max = 1024 * 1024

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || {
	host = Env.var_str!("ROUX_ADDRESS") ? |_| Exit(2)
	port_text = Env.var_str!("ROUX_PORT") ? |_| Exit(2)
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
	database = Env.var_str!("ROUX_DATABASE") ? |_| Exit(2)
	db = Sqlite.open!({ ..Sqlite.default_config(Path.utf8(database)), max_connections: 32, busy_timeout_ms: 5_000, synchronous: Normal }) ? |_| Exit(3)
	Ok({ config, context: { dishes: menu_dishes, catalog: catalog(), db } })
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
		(GET, "/catalog") =>
			Ok(
				Server.respond(
					Response.from_status(200)
						.with_headers([{ name: "Content-Type", value: "text/html; charset=utf-8" }])
						.with_body(Str.to_utf8(catalog_page(context.catalog))),
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

# --- the catalog workload -----------------------------------------------------

## The page, written out as text, each value escaped by the platform's
## `Html`: its elements put no line breaks between elements, and the race's
## page has one after each.
catalog_page : Catalog -> Str
catalog_page = |page| {
	title = escape(page.title)
	var $out = Str.with_capacity(20_000)
	$out = $out.concat("<!doctype html>\n<html lang=\"en\">\n<head><meta charset=\"utf-8\"><title>${title}</title></head>\n<body>\n<h1>${title}</h1>\n<p>${page.note}</p>\n")
	open = if page.shop.open " (open)" else " (closed)"
	$out = $out.concat("<p>${escape(page.shop.name)}, ${escape(page.shop.city)}${open}</p>\n")
	$out = $out.concat(if page.closed "" else "<p>Open today.</p>\n")
	$out = $out.concat(if page.specials.is_empty() "<p>No specials.</p>\n" else "")
	$out = $out.concat("<ul>\n")
	for offer in page.offers {
		$out = $out.concat("<li>${escape(offer.what)}: ${pct(offer.off)} off</li>\n")
	}
	$out = $out.concat("</ul>\n")
	$out = $out.concat(if page.offers.is_empty() "<p>No offers.</p>\n" else "")
	currency = escape(page.currency)
	$out = $out.concat("<p>${plural(page.groups.len(), "group", "groups")}, ${plural(page.rows.len(), "row", "rows")}, ${kr(page.total)} ${currency} in stock</p>\n")
	for group in page.groups {
		$out = $out.concat("<h2>${escape(group.name)}</h2><p>")
		for member in group.members {
			$out = $out.concat("${escape(member)};")
		}
		$out = $out.concat("</p>\n")
	}
	$out = $out.concat("<table>\n")
	for item in page.rows {
		hot = if item.hot " hot" else ""
		$out = $out.concat("<tr class=\"${level(item.stock)}${hot}\"><td>${item.id.to_str()} ${escape(item.name)}</td><td>${stock(item.stock)} ")
		if item.tags.is_empty() {
			$out = $out.concat("-")
		} else {
			for tag in item.tags {
				$out = $out.concat("<i>${escape(tag)}</i>")
			}
		}
		price = if item.on_sale "<s>${kr(item.price)}</s> ${kr(sale(item.price, item.discount))}" else kr(item.price)
		$out = $out.concat("</td><td>${price} ${currency}</td><td>${date(item.added)} ${weight(item.grams)}</td></tr>\n")
	}
	$out.concat("</table>\n</body>\n</html>\n")
}

## A text value as HTML: the platform's escaping (`&`, `<`, `>`, what a
## text node needs), then the quotes, as every other engine in the race
## escapes them (so a value is safe in an attribute too).
escape : Str -> Str
escape = |text|
	Html.render_without_doc_type(Html.text(text))
		.replace_each("\"", "&quot;")
		.replace_each("'", "&#39;")

## The catalog's names: markup, quotes and accents, each escaped as printed.
catalog_names : List(Str)
catalog_names = ["Roux", "Skyr & ber", "Crème", "<b>Stew</b>", "Hákarl", "Kjöt \"s\"", "O'Brien", "Pylsa"]

name_at : U64 -> Str
name_at = |i| catalog_names.get(i % 8) ?? ""

## The catalog's data: row i (from 0) is id i + 1, catalog_names[i % 8],
## price 500 + (i * 7919) % 20000 hundredths, discount (i * 37) % 40 percent
## (on sale when above 0), stock (i * 13) % 50 - 10, hot when i % 7 is 0,
## tags by i % 3: none, veg, veg and gf; added on day (i * 53) % 365 of the
## year, grams 50 + (i * 997) % 5000. Group k (from 0) is "Group k + 1",
## names k to k + 2. The total is the prices' sum.
catalog : () -> Catalog
catalog = || {
	var $rows = []
	var $total = 0
	for i in 0..<128.U64 {
		tags = if i % 3 == 0 [] else if i % 3 == 1 ["veg"] else ["veg", "gf"]
		price = (500 + (i * 7919) % 20000).to_u32_wrap()
		discount = ((i * 37) % 40).to_u8_wrap()
		$total = $total + price
		$rows = $rows.append(
			{
				id: (i + 1).to_u32_wrap(),
				name: name_at(i),
				price,
				discount,
				on_sale: discount > 0,
				stock: ((i * 13) % 50).to_i32_wrap() - 10,
				hot: i % 7 == 0,
				tags,
				added: ((i * 53) % 365).to_u16_wrap(),
				grams: (50 + (i * 997) % 5000).to_u32_wrap(),
			},
		)
	}
	var $groups = []
	for k in 0..<6.U64 {
		$groups = $groups.append({ name: "Group ${(k + 1).to_str()}", members: [name_at(k), name_at(k + 1), name_at(k + 2)] })
	}
	{
		title: "Catalog <&> \"one\" 'two'",
		note: "<em>Fresh</em> &amp; local",
		currency: "kr",
		shop: { name: "Eldhús", city: "Reykjavík", open: Bool.True },
		closed: Bool.False,
		specials: [],
		offers: [{ what: "Soup of the day", off: 10 }, { what: "Bread & butter", off: 25 }, { what: "Coffee <hot>", off: 5 }],
		total: $total,
		groups: $groups,
		rows: $rows,
	}
}

## A price in hundredths: `12.05`.
kr : U32 -> Str
kr = |hundredths| "${(hundredths // 100).to_str()}.${two((hundredths % 100).to_u64())}"

## A count and the noun that fits it: `1 group`, `6 groups`.
plural : U64, Str, Str -> Str
plural = |count, one, many| {
	noun = if count == 1 one else many
	"${count.to_str()} ${noun}"
}

## A percentage: `10%`.
pct : U8 -> Str
pct = |percent| "${percent.to_str()}%"

## A stock's level, the row's class: `out`, `low` (under ten), `ok`.
level : I32 -> Str
level = |count| if count <= 0 "out" else if count < 10 "low" else "ok"

## A stock as written: `out`, `3 left`, `16`.
stock : I32 -> Str
stock = |count| if count <= 0 "out" else if count < 10 "${count.to_str()} left" else count.to_str()

## A price after a discount in percent, in hundredths, rounded down.
sale : U32, U8 -> U32
sale = |price, off| price - price * off.to_u32() // 100

## A day of 2026 (0 is January 1) as `MM-DD`.
date : U16 -> Str
date = |day| {
	var $left = day.to_u64()
	var $month = 1
	for days in [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] {
		if $left < days {
			break
		} else {
			$left = $left - days
			$month = $month + 1
		}
	}
	"${two($month)}-${two($left + 1)}"
}

## A weight in grams: `350 g`, or `1.25 kg` from a kilogram up.
weight : U32 -> Str
weight = |grams|
	if grams < 1000 {
		"${grams.to_str()} g"
	} else {
		"${(grams // 1000).to_str()}.${two(((grams % 1000) // 10).to_u64())} kg"
	}

## A number under 100 in two digits: `05`.
two : U64 -> Str
two = |n| if n < 10 "0${n.to_str()}" else n.to_str()

expect kr(1205) == "12.05"
expect sale(8419, 37) == 5304
expect date(53) == "02-23"
expect weight(1045) == "1.04 kg"
expect stock(3) == "3 left"

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
