app [Context, program] { pf: platform "../../../roux/platform/main.roc" }

# The roux competitor: a Roc app on roux, the Roc platform
# built on fourneau. Each request runs `respond!` on its connection's
# fiber; the host listens on ROUX_ADDRESS and ROUX_PORT (the race's), over
# the app's port.

import pf.Server
import pf.Rocstache
import pf.Sqlite
import pf.Sse
import pf.Url
import db/Database
import Conduit
import templates/Catalog
import templates/Holes

## The templates workload's page, made once by `init!` (`catalog`);
## `Catalog.rocstache` (compiled to bytecode linked into the app by roux
## build, which the host's renderer runs as the response is sent;
## `Catalog.roc` is its contract and `Catalog.template`) renders it per
## request, its holes of Roc through `Holes.hole`.
## The conduit workload's database: ROUX_DATABASE says where, as the race
## starts every server, in WAL mode with synchronous=NORMAL (the contract).
## A request waits for it up to 5 s, as the contract asks of every server,
## where roux's defaults answer 503 sooner; 256 may wait for the writer,
## every request Conduit's 256 connections hold.
Context : { catalog : Catalog.Ctx, db : Sqlite.Db }

program = { init!, respond!, hole: Holes.hole }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64), DbErr(Sqlite.Err)])
init! = || {
	db = Sqlite.open!(Database.at("conduit.db"), { synchronous: Normal, read_wait_ms: 5_000, write_wait_ms: 5_000, writers_waiting: 256 })?
	Ok({ config: { port: 8080, static_dir: "" }, context: { db, catalog: catalog() } })
}

respond! : Server.Request, Context => Try(Server.Response(_), [NotFound, BadRequest(Str), SseErr(Sse.SseErr), DbErr(Sqlite.Err)])
respond! = |request, context| {
	path =
		match request.target.split_first("?") {
			Ok({ before, .. }) => before
			Err(_) => request.target
		}
	match (request.method, path) {
		("GET", "/plaintext") => Ok(Server.text("Hello, World!"))
		("POST", "/echo") =>
			match Server.read_body!(request, 1_048_576) {
				Ok(body) =>
					Ok(
						{
							status: 200,
							headers: [{ name: "Content-Type", value: "application/octet-stream" }],
							body: Bytes(body),
						},
					)
				Err(BodyErr(err)) => Err(BadRequest(Str.inspect(err)))
			}
		("GET", "/catalog") => Ok(Rocstache.html(Catalog.template(context.catalog)))
		("GET", "/sse") =>
			match signals(request.target) {
				Ok({ count }) => datastar!(request, count.to_u64() + 1)
				Err(BadSignals) => Err(BadRequest("bad signals"))
			}
		_ =>
			if path.starts_with("/api/") {
				Conduit.respond!(request, context.db, path)
			} else {
				Err(NotFound)
			}
	}
}

# --- the templates workload: the catalog page's data -----------------------------

## The catalog's names: markup, quotes and accents, each escaped as printed.
names : List(Str)
names = ["Roux", "Skyr & ber", "Crème", "<b>Stew</b>", "Hákarl", "Kjöt \"s\"", "O'Brien", "Pylsa"]

## The catalog's data, as race.json's `catalog` defines it: row i (from 0)
## is id i + 1, names[i % 8], price 500 + (i * 7919) % 20000 hundredths,
## discount (i * 37) % 40 percent (on sale when above 0), stock (i * 13) %
## 50 - 10, hot when i % 7 is 0, tags by i % 3: none, veg, veg and gf;
## added on day (i * 53) % 365 of the year, grams 50 + (i * 997) % 5000.
## Group k (from 0) is "Group k + 1", names k to k + 2. The total is the
## prices' sum.
catalog : () -> Catalog.Ctx
catalog = || {
	var $rows = []
	var $total = 0
	for i in 0..<96.U64 {
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

name_at : U64 -> Str
name_at = |i| names.get(i % 8) ?? ""

# --- the SSE workload: a Datastar action ----------------------------------------

## Datastar's signals: JSON in the `datastar` query parameter.
signals : Str -> Try({ count : U32 }, [BadSignals])
signals = |target|
	match Url.query_value(target, "datastar") {
		Ok(json) =>
			match Json.parse(json) {
				Ok(parsed) => Ok(parsed)
				Err(_) => Err(BadSignals)
			}
		Err(_) => Err(BadSignals)
	}

log_lines : U64
log_lines = 8

## The new count as a signal, the count's element, then the log lines,
## each event made and sent in turn, a chunk each.
datastar! : Server.Request, U64 => Try(Server.Response(_), [SseErr(Sse.SseErr), BadRequest(Str)])
datastar! = |request, count| {
	stream = Sse.start!(request, [])?
	n = count.to_str()
	Sse.send!(stream, patch("datastar-patch-signals", "signals {\"count\":${n}}"))?
	Sse.send!(stream, patch("datastar-patch-elements", "elements <span id=\"count\">${n}</span>"))?
	for line in 1..=log_lines {
		data = "selector #log\nmode append\nelements <li>Event ${line.to_str()} of ${log_lines.to_str()}</li>"
		Sse.send!(stream, patch("datastar-patch-elements", data))?
	}
	Sse.end!(stream)
}

## A Datastar event; its two names have no line breaks.
patch : Str, Str -> Sse.Event
patch = |name, data|
	match Sse.Event.named(name, data) {
		Ok(event) => event
		Err(InvalidEventName) => crash "a Datastar event name has no line break"
	}

expect signals("/sse?datastar=%7B%22count%22%3A41%7D") == Ok({ count: 41 })
expect signals("/sse?datastar=%7B%22count%22%3A4294967295%7D") == Ok({ count: 4294967295 })
expect signals("/sse") == Err(BadSignals)
expect signals("/sse?datastar=%7B%7D") == Err(BadSignals)
expect signals("/sse?datastar=%7B%22count%22%3A-1%7D") == Err(BadSignals)
expect signals("/sse?datastar=%7B%22count%22%3A4294967296%7D") == Err(BadSignals)
expect signals("/sse?datastar=%") == Err(BadSignals)
