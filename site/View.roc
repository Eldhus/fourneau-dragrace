import Data
import Format
import db/Pages

## What the pages show, made from the races: every number formatted, every
## bar's share and every chart's path computed here, so the templates only
## place text. (This was race.js, drawing in the browser.)
View :: [].{
	Commit : { name : Str, short : Str, url : Str }
	## `hollow`: something besides the server's CPU limited the result (the
	## tip and the table say what), drawn as an outline, as the open loop's
	## hollow points are.
	## `low`, `high`: the slowest and fastest rounds as shares, the whisker's
	## ends; `reach`, how far the whisker runs past the bar (median).
	Row : { competitor : Str, valid : Bool, share : Str, low : Str, high : Str, reach : Str, value : Str, ranged : Bool, hollow : Bool, tip : Str }
	TableRow : {
		competitor : Str,
		valid : Bool,
		note : Str,
		rps : Str,
		p95 : Str,
		p99 : Str,
		p999 : Str,
		rounds : Str,
		cpu : Str,
		loader : Str,
		net : Str,
		limit : Str,
		spread : Str,
		steal : Str,
		rss : Str,
	}
	Strip : { title : Str, summary : Str, rows : List(Row), table : List(TableRow) }
	Machine : { role : Str, text : Str }
	Class : { name : Str, label : Str, title : Str, machines : List(Machine), strips : List(Strip), open : List(OpenChart) }
	## The open-loop ladder: p99 against the offered rate, a line per
	## competitor; a hollow point is a step where the loader was the limit.
	OpenDot : { cx : Str, cy : Str, hollow : Bool, title : Str }
	OpenLine : { competitor : Str, path : Str, dots : List(OpenDot), label_x : Str, label_y : Str, end_x : F64, end_y : F64 }
	## `caption`: one sentence on the load; `measure`: the y axis's note.
	OpenChart : { title : Str, caption : Str, measure : Str, lines : List(OpenLine), ticks_x : List(Mark), ticks_y : List(Tick) }
	Latest : { id : Str, started : Str, took : Str, timed : Bool, commits : List(Commit), competitors : List(Str), classes : List(Class) }

	Dot : { cx : Str, cy : Str, r : Str, title : Str }
	## `end_x`, `end_y`: where the line ends, for spreading the labels apart.
	Line : { competitor : Str, drawn : Bool, path : Str, dots : List(Dot), label_x : Str, label_y : Str, end_x : F64, end_y : F64 }
	Tick : { line_y : Str, text_y : Str, label : Str }
	Mark : { x : Str, label : Str }
	Chart : { title : Str, empty : Bool, lines : List(Line), ticks : List(Tick), dates : List(Mark) }
	Charts : { name : Str, label : Str, title : Str, charts : List(Chart) }
	History : { waiting : Bool, note : Str, competitors : List(Str), classes : List(Charts) }

	Pin : { name : Str, version : Str }

	## The Workloads page, every figure from the newest race (the owner,
	## 2026-10-07: nothing typed in that race.json decides). `spec`: what
	## the loader asked, small under the card.
	WorkloadCard : { title : Str, route : Str, summary : Str, spec : Str }
	Workloads : { ready : Bool, cards : List(WorkloadCard), rounds : Str, warmup : Str, measure : Str, shares : Str, ladder : Str, loader_limit : Str }

	workloads : List(Pages.WorkloadSpecs), Pages.RaceSettings -> Workloads
	workloads = |specs, settings| {
		ready: Bool.True,
		cards: specs.map(workload_card),
		rounds: settings.rounds.to_str(),
		warmup: settings.warmup_seconds.to_str(),
		measure: settings.measure_seconds.to_str(),
		shares: settings.shares,
		ladder: settings.ladder,
		loader_limit: Format.thousands(loader_limit_pct),
	}

	## A server class's tab: a link to the same page showing that class.
	## `label` is the class's short name; its title heads the class below.
	## `action`: Datastar's, on a click: the address updated and only the
	## class's fragment fetched and swapped in place, so the page does not
	## move; without JavaScript the link loads the page.
	Tab : { href : Str, label : Str, current : Bool, action : Str }

	## The class a page shows: the one asked for when the race has it,
	## else the first.
	chosen : List(Str), Str -> Str
	chosen = |names, wanted|
		if names.contains(wanted) {
			wanted
		} else {
			match List.first(names) {
				Ok(first) => first
				Err(_) => ""
			}
		}

	## A tab per class, linking to `page` with `?class=NAME`. Only names the
	## race itself has are ever put in a link.
	tabs : List({ name : Str, label : Str }), Str, Str -> List(Tab)
	tabs = |classes, current, page|
		classes.map(|class| {
			href = "${page}?class=${class.name}"
			fragment = if page == "/" "/race-classes" else "${page}-classes"
			{
				href,
				label: class.label,
				current: class.name == current,
				action: "window.history.replaceState(null, '', '${href}'); @get('${fragment}?class=${class.name}')",
			}
		})

	## The newest race, as the front page shows it.
	latest : Data.Run -> Latest
	latest = |run| {
		id: run.id,
		started: started(run.started_at),
		took: took(run.timing),
		timed: run.timing.seconds > 0.0,
		commits: commits(run),
		competitors: run.race.competitors,
		classes: classes_of(run).map(|class| class_view(run, class)),
	}

	## Every cloud race's medians (local ones only while no cloud race
	## exists), a chart per server class and workload; two races at least.
	history : Data.Run, List(Data.Entry) -> History
	history = |run, entries| {
		cloud = entries.keep_if(|entry| entry.id.ends_with("-cloud"))
		shown = if cloud.is_empty() entries else cloud
		note = if cloud.is_empty() "No cloud race yet: these are local races." else ""
		classes = classes_of(run).map(|class| {
			name: class.name,
			label: class.label,
			title: class.title,
			charts: closed(run.race.workloads).map(|workload| chart(shown, class.name, workload, run.race.competitors)),
		})
		{ waiting: List.len(shown) < 2, note, competitors: run.race.competitors, classes }
	}

	## The pinned versions of the newest race.
	pins : Data.Run -> List(Pin)
	pins = |run| {
		v = run.versions
		[
			{ name: "Zig", version: v.zig.version },
			{ name: "Roc", version: v.roc.version },
			{ name: "Go", version: v.go.version },
			{ name: "Rust", version: v.rust.version },
			{ name: "axum", version: v.axum.version },
			{ name: "tokio", version: v.tokio.version },
			{ name: "oha (load)", version: v.oha.version },
			{ name: "droplet image", version: v.droplet_image },
			{ name: "fourneau", version: "main at ${Format.short(run.fingerprint.fourneau)}" },
		].concat(if run.fingerprint.roux.is_empty() [] else [{ name: "roux", version: "main at ${Format.short(run.fingerprint.roux)}" }])
	}
}

## "2026-10-06T13:58:49.000800103Z" is "2026-10-06 13:58 UTC".
started : Str -> Str
started = |stamp| {
	minute = Str.from_utf8_lossy(List.take_first(Str.to_utf8(stamp), 16))
	"${minute.replace_first("T", " ")} UTC"
}

commits : Data.Run -> List(View.Commit)
commits = |run| {
	fingerprint = run.fingerprint
	fourneau = commit("fourneau", run.versions.fourneau.repository, fingerprint.fourneau)
	dragrace = commit("dragrace", "https://github.com/Eldhus/fourneau-dragrace", fingerprint.dragrace)
	if fingerprint.roux.is_empty() {
		[fourneau, dragrace]
	} else {
		[fourneau, commit("roux", run.versions.roux.repository, fingerprint.roux), dragrace]
	}
}

commit : Str, Str, Str -> View.Commit
commit = |name, repository, sha| { name, short: Format.short(sha), url: "${repository}/commit/${sha}" }

## The server classes a race ran, in race.json's order (smallest first),
## then any its results name that race.json does not (a local race). Not
## the results' order: the database sorts those by name, which put
## dedicated-2 before smallest (2026-10-07).
classes_of : Data.Run -> List(Data.ServerClass)
classes_of = |run| {
	var $named = []
	for result in run.results {
		if !$named.contains(result.class) {
			$named = $named.append(result.class)
		}
	}
	listed = run.race.cloud.servers.map(|server| server.name).keep_if(|name| $named.contains(name))
	others = $named.keep_if(|name| !listed.contains(name))
	listed.concat(others).map(|name|
		match run.race.cloud.servers.find_first(|server| server.name == name) {
			Ok(server) => server
			Err(_) => { name, label: "local", title: "This computer (a local race)" }
		})
}

class_view : Data.Run, Data.ServerClass -> View.Class
class_view = |run, class| {
	# A loader is its class's now; before 2026-10-06 one loader, of class
	# "loader", raced every class.
	described = run.machines.keep_if(|machine| machine.class == class.name or machine.class == "loader")
	# The server first: it is what the class is about.
	ordered = described.sort_with(|a, b| if a.role == b.role Same else if a.role == "server" Before else After)
	machines = ordered.map(|m| { role: m.role, text: "${m.size} · ${vcpus(m.cpus)}${memory(m.memory_mib)} · ${m.cpu} · Linux ${m.kernel}" })
	strips = closed(run.race.workloads).map(|workload| strip(run, class.name, workload))
	{ name: class.name, label: class.label, title: class.title, machines, strips, open: open_charts(run, class.name) }
}

## The workloads raced in rounds, drawn as bars and in the history; a
## mixed one (conduit) is a ladder only, drawn as a line (open_charts).
closed : List(Data.Workload) -> List(Data.Workload)
closed = |workloads| workloads.keep_if(|w| w.kind != "mixed")

## One workload on one server class: a bar per competitor, fastest first.
strip : Data.Run, Str, Data.Workload -> View.Strip
strip = |run, class, workload| {
	results = run.results
		.keep_if(|r| r.class == class and r.workload == workload.name)
		.sort_with(|a, b| if a.median_rps > b.median_rps Before else if a.median_rps < b.median_rps After else Same)
	# The scale ends at the fastest round, so every whisker fits.
	most = results.fold(0.0, |best, r| if r.valid and round_range(r).fastest > best round_range(r).fastest else best)
	# A local race's traffic is loopback: no network limit applies.
	local = class == "local"
	rows = results.map(|r| row(r, most, local))
	{ title: workload.title, summary: workload.summary, rows, table: results.map(|r| table_row(r, local)) }
}

row : Data.Result, F64, Bool -> View.Row
row = |result, most, local|
	if !result.valid or most <= 0.0 {
		{ competitor: result.competitor, valid: Bool.False, share: "0", low: "0", high: "0", reach: "0", value: "DNF", ranged: Bool.False, hollow: Bool.False, tip: "${result.competitor} did not finish: ${result.note}" }
	} else {
		value = Format.thousands(result.median_rps)
		rounds = List.len(result.rounds).to_str()
		{ slowest, fastest } = round_range(result)
		spread = spread_pct(result)
		{
			competitor: result.competitor,
			valid: Bool.True,
			share: Format.two_decimals(result.median_rps / most),
			low: Format.two_decimals(slowest / most),
			high: Format.two_decimals(fastest / most),
			reach: Format.two_decimals((fastest - result.median_rps) / most),
			value,
			ranged: (fastest - slowest) / most >= whisker_share_min,
			hollow: !saturated(result, local),
			tip: "${result.competitor}: ${value} req/s, median of ${rounds} rounds (${Format.thousands(slowest)} to ${Format.thousands(fastest)}, ${Format.thousands(spread)}% apart), limited by ${limited_by(result, local)}; p95 ${Format.latency(result.median_p95_ms)}, p99 ${Format.latency(result.median_p99_ms)}, p99.9 ${Format.latency(result.median_p999_ms)} ms",
		}
	}

table_row : Data.Result, Bool -> View.TableRow
table_row = |result, local| {
	rounds = result.rounds
	rss = rounds.fold(0.0, |top, r| if r.rss_kib > top r.rss_kib else top)
	{
		competitor: result.competitor,
		valid: result.valid,
		note: result.note,
		rps: Format.thousands(result.median_rps),
		p95: Format.latency(result.median_p95_ms),
		p99: Format.latency(result.median_p99_ms),
		p999: Format.latency(result.median_p999_ms),
		rounds: Str.join_with(rounds.map(|r| Format.thousands(r.rps)), " · "),
		cpu: Format.one_decimal(median(rounds.map(|r| r.cpu_busy_pct))),
		loader: Format.one_decimal(median(rounds.map(|r| r.loader_cpu_busy_pct))),
		net: "${Format.thousands(median(rounds.map(|r| r.net_rx_mbps)))} / ${Format.thousands(median(rounds.map(|r| r.net_tx_mbps)))}",
		limit: limited_by(result, local),
		spread: Format.one_decimal(spread_pct(result)),
		steal: Format.one_decimal(median(rounds.map(|r| r.steal_pct))),
		rss: "${Format.one_decimal(rss / 1024.0)} MiB",
	}
}

median : List(F64) -> F64
median = |values| {
	sorted = values.sort_with(|a, b| if a < b Before else if a > b After else Same)
	count = List.len(sorted)
	if count == 0 {
		0.0
	} else {
		middle = count // 2
		upper = List.get(sorted, middle) ?? 0.0
		if count % 2 == 1 upper else (upper + (List.get(sorted, middle - 1) ?? 0.0)) / 2.0
	}
}

# The history chart's geometry: race.js's, so the CSS still fits.
width = 720.0
height = 260.0
left = 72.0
right = 120.0
top = 14.0
bottom = 34.0

chart : List(Data.Entry), Str, Data.Workload, List(Str) -> View.Chart
chart = |entries, class, workload, competitors| {
	value = |entry, competitor|
		match entry.results.find_first(|r| r.class == class and r.workload == workload.name and r.competitor == competitor and r.valid) {
			Ok(found) => Ok(found.median_rps)
			Err(_) => Err(Missing)
		}
	most = entries.fold(0.0, |top_value, entry|
		competitors.fold(top_value, |t, c|
			match value(entry, c) {
				Ok(v) => if v > t v else t
				Err(_) => t
			}))
	if most <= 0.0 {
		{ title: workload.title, empty: Bool.True, lines: [], ticks: [], dates: [] }
	} else {
		ceiling = nice_ceiling(most)
		count = List.len(entries)
		x = |i| left + (if count == 1 0.5 else i.to_f64() / (count - 1).to_f64()) * (width - left - right)
		y = |v| top + (1.0 - v / ceiling) * (height - top - bottom)
		lines = spread_labels(competitors.map(|competitor| line(entries, competitor, value, x, y)))
		ticks = [0.0, 1.0, 2.0, 3.0, 4.0].map(|t| {
			v = ceiling * t / 4.0
			{ line_y: Format.one_decimal(y(v)), text_y: Format.one_decimal(y(v) + 4.0), label: Format.compact(v) }
		})
		every = if count <= 6 1 else (count + 5) // 6
		dates = entries
			.map_with_index(|entry, i| { i, entry })
			.keep_if(|e| e.i % every == 0 or e.i == count - 1)
			.map(|e| { x: Format.one_decimal(x(e.i)), label: axis_date(entries, e.entry.started_at) })
		{ title: workload.title, empty: Bool.False, lines, ticks, dates }
	}
}

## A competitor's medians as an SVG path, lifting the pen over races it
## did not finish; its name at its last point.
line : List(Data.Entry), Str, (Data.Entry, Str -> Try(F64, [Missing])), (U64 -> F64), (F64 -> F64) -> View.Line
line = |entries, competitor, value, x, y| {
	var $path = ""
	var $pen = "M"
	var $last_x = 0.0
	var $last_y = 0.0
	var $dots = []
	var $i = 0
	for entry in entries {
		match value(entry, competitor) {
			Ok(v) => {
				$last_x = x($i)
				$last_y = y(v)
				$path = "${$path}${$pen}${Format.one_decimal($last_x)} ${Format.one_decimal($last_y)} "
				$pen = "L"
				$dots = $dots.append({
					cx: Format.one_decimal($last_x),
					cy: Format.one_decimal($last_y),
					r: if $i + 1 == List.len(entries) "4" else "3",
					title: "${competitor}, ${entry.id}: ${Format.thousands(v)} req/s",
				})
			}
			Err(_) => {
				$pen = "M"
			}
		}
		$i = $i + 1
	}
	{
		competitor,
		drawn: !$path.is_empty(),
		path: $path,
		dots: $dots,
		label_x: Format.one_decimal($last_x + 10.0),
		label_y: Format.one_decimal($last_y + 4.0),
		end_x: $last_x,
		end_y: $last_y,
	}
}

## The smallest of 1, 2, 5, 10 times a power of ten that is at least `most`.
nice_ceiling : F64 -> F64
nice_ceiling = |most| {
	powers = [1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0, 10000000.0, 100000000.0, 1000000000.0]
	power = powers.fold(1.0, |kept, p| if p <= most p else kept)
	match [1.0, 2.0, 5.0, 10.0].find_first(|step| step * power >= most) {
		Ok(step) => step * power
		Err(_) => 10.0 * power
	}
}

## "2026-10-06T13:58:49Z" is "Oct 6".
day : Str -> Str
day = |stamp| {
	months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	bytes = Str.to_utf8(stamp)
	month_text = Str.from_utf8_lossy(List.sublist(bytes, { start: 5, len: 2 }))
	day_text = Str.from_utf8_lossy(List.sublist(bytes, { start: 8, len: 2 }))
	month = U64.from_str(month_text) ?? 1
	day_number = U64.from_str(day_text) ?? 1
	"${List.get(months, month - 1) ?? "?"} ${day_number.to_str()}"
}

expect started("2026-10-06T13:58:49.000800103Z") == "2026-10-06 13:58 UTC"
expect day("2026-10-06T13:58:49Z") == "Oct 6"
expect nice_ceiling(167971.0) == 200000.0
expect nice_ceiling(45620.0) == 50000.0
expect median([3.0, 1.0, 2.0]) == 2.0
expect median([4.0, 1.0, 3.0, 2.0]) == 2.5

import "test/latest.json" as latest_sample : Str
import "test/index.json" as index_sample : Str

expect
	match Data.run(latest_sample) {
		Ok(run) => {
			page = View.latest(run)
			first_strip_ok =
				match List.first(page.classes) {
					Ok(class) =>
						match List.first(class.strips) {
							Ok(first) => List.len(first.rows) == 4 and first.title == "Plaintext"
							Err(_) => Bool.False
						}
					Err(_) => Bool.False
				}
			List.len(page.classes) == 2 and List.len(page.commits) == 3 and first_strip_ok
		}
		Err(_) => Bool.False
	}

expect
	match (Data.run(latest_sample), Data.index(index_sample)) {
		(Ok(run), Ok(entries)) => {
			page = View.history(run, entries)
			List.len(page.classes) == 2 and page.waiting
		}
		_ => Bool.False
	}

expect View.chosen(["smallest", "premium-4"], "premium-4") == "premium-4"
expect View.chosen(["smallest", "premium-4"], "nope") == "smallest"
expect View.chosen([], "nope") == ""
expect {
	tabs = View.tabs([{ name: "a", label: "A" }, { name: "b", label: "B" }], "b", "/history")
	tabs.map(|tab| tab.href) == ["/history?class=a", "/history?class=b"] and tabs.map(|tab| tab.current) == [Bool.False, Bool.True]
}

vcpus : U32 -> Str
vcpus = |count| if count == 1 "1 vCPU" else "${count.to_str()} vCPUs"

## A label's height and a character's width, in the charts' units (the
## `.end` text: 11 px Space Mono, 0.6 em to a character).
label_gap : F64
label_gap = 13.0

label_char_width : F64
label_char_width = 6.6

## Where each line's name goes, in the order given: beside its line's end,
## pushed down below any name already placed that it would overlap, across
## and down, so lines ending close together do not print one name over the
## other, and a name is never pushed by one far to its side (2026-10-07:
## on the open-loop chart, where lines end at different rates, axum's name
## was pushed under basic-webserver's). Placed from the highest end down;
## an undrawn line's name neither moves nor pushes.
label_ys : List({ competitor : Str, x : F64, y : F64, drawn : Bool }) -> List(F64)
label_ys = |ends| {
	by_y = |a, b| if a.y < b.y Before else if a.y > b.y After else Same
	sorted = ends
		.map_with_index(|e, i| { i, x: e.x, y: e.y, drawn: e.drawn, width: Str.to_utf8(e.competitor).len().to_f64() * label_char_width })
		.sort_with(by_y)
	var $placed = []
	var $ys = []
	for e in sorted {
		var $y = e.y + 4.0
		if e.drawn {
			for p in $placed.sort_with(by_y) {
				across = e.x < p.x + p.width and p.x < e.x + e.width
				if across and $y > p.y - label_gap and $y < p.y + label_gap {
					$y = p.y + label_gap
				}
			}
			$placed = $placed.append({ ..e, y: $y })
		}
		$ys = $ys.append({ i: e.i, y: $y })
	}
	$ys.sort_with(|a, b| if a.i < b.i Before else if a.i > b.i After else Same).map(|p| p.y)
}

spread_labels : List(View.Line) -> List(View.Line)
spread_labels = |lines| {
	ys = label_ys(lines.map(|l| { competitor: l.competitor, x: l.end_x, y: l.end_y, drawn: l.drawn }))
	List.map2(lines, ys, |l, y| { ..l, label_y: Format.one_decimal(y) })
}

expect vcpus(1) == "1 vCPU" and vcpus(4) == "4 vCPUs"
expect {
	at = |name, x, y| { competitor: name, x, y, drawn: Bool.True }
	# b is pushed under a; c is clear below; d, beside a, is not pushed.
	label_ys([at("b", 0.0, 100.0), at("a", 0.0, 95.0), at("c", 0.0, 200.0), at("d", 100.0, 96.0)])
		== [112.0, 99.0, 204.0, 100.0]
}

## A race's date on a chart's axis: the day, and the time when another
## race shares the day (two "Oct 6" side by side said nothing).
axis_date : List(Data.Entry), Str -> Str
axis_date = |entries, stamp| {
	shared = entries.keep_if(|entry| day(entry.started_at) == day(stamp))
	if List.len(shared) > 1 "${day(stamp)} ${clock(stamp)}" else day(stamp)
}

## "2026-10-06T13:58:49Z" is "13:58": the tool writes that one format.
clock : Str -> Str
clock = |stamp| Str.from_utf8_lossy(List.sublist(Str.to_utf8(stamp), { start: 11, len: 5 }))

expect clock("2026-10-06T13:58:49Z") == "13:58"

## "53 min · $0.45": how long the race took and what its droplets cost
## (the cost only for a cloud race).
took : { seconds : F64, cost_usd : F64 } -> Str
took = |timing| {
	minutes = (timing.seconds / 60.0).round_to_u64_try() ?? 0
	if timing.cost_usd > 0.0 {
		"took ${minutes.to_str()} min · $${Format.two_decimals(timing.cost_usd)}"
	} else {
		"took ${minutes.to_str()} min"
	}
}

## The loader's CPU at or above this, a step says more about the loader
## than the server: oha pacing requests costs about half again what its
## closed loop does (measured 2026-10-06).
loader_limit_pct : F64
loader_limit_pct = 85.0

## A workload's card: its route without the query (SSE's carries the
## signals), and what the loader asked of it.
workload_card : Pages.WorkloadSpecs -> View.WorkloadCard
workload_card = |w| {
	path =
		match w.path.split_first("?") {
			Ok({ before, after: _ }) => before
			Err(_) => w.path
		}
	if w.kind == "mixed" {
		rates = "${Format.thousands(w.lowest.to_f64())} to ${Format.thousands(w.highest.to_f64())} requests a second"
		{ title: w.title, route: path, summary: w.summary, spec: "Open loop only: ${w.mix}; ${rates}, the same for every server, each climbing until it falls behind." }
	} else {
		reuse = if w.keepalive "kept alive" else "a new one per request"
		body = if w.body_bytes > 0 ", ${Format.thousands(w.body_bytes.to_f64())}-byte body" else ""
		{ title: w.title, route: "${w.method} ${path}", summary: w.summary, spec: "${w.connections.to_str()} connections, ${reuse}${body}." }
	}
}

expect {
	spec = |kind, method, path, body_bytes, connections, keepalive| { name: "w", kind, title: "W", summary: "", method, path, body_bytes, connections, keepalive, mix: "list 50%, article 50%", lowest: 250, highest: 32000 }
	echo = workload_card(spec("closed", "POST", "/echo", 4096, 256, Bool.True))
	sse = workload_card(spec("closed", "GET", "/sse?datastar=x", 0, 64, Bool.False))
	conduit = workload_card(spec("mixed", "MIXED", "/api/articles", 0, 256, Bool.True))
	echo.spec == "256 connections, kept alive, 4,096-byte body."
	and sse.route == "GET /sse" and sse.spec == "64 connections, a new one per request."
	and conduit.route == "/api/articles"
	and conduit.spec == "Open loop only: list 50%, article 50%; 250 to 32,000 requests a second, the same for every server, each climbing until it falls behind."
}

## The class's open-loop charts, a ladder each: the closed workload's
## (each server at shares of its own maximum), and each mixed workload's
## (at rates the same for every server).
open_charts : Data.Run, Str -> List(View.OpenChart)
open_charts = |run, class|
	run.race.workloads.keep_oks(|workload| {
		results = run.results.keep_if(|r| r.class == class and r.workload == workload.name and r.valid and !r.open_loop.is_empty())
		if results.is_empty() {
			Err(NoLadder)
		} else {
			Ok(open_chart({ title: workload.title, summary: workload.summary, results, mixed: workload.kind == "mixed" }))
		}
	})

## p99 against the offered rate, on a log axis: a mixed workload's is its
## slowest part's. (The owner, 2026-10-07: a switch to p50, p90, p99.9 and
## the mean was built and taken out; the charts all looked alike.)
open_chart : { title : Str, summary : Str, results : List(Data.Result), mixed : Bool } -> View.OpenChart
open_chart = |{ title, summary, results, mixed }| {
	steps = results.map(|r| r.open_loop).join()
	most_rate = steps.fold(0.0, |top_rate, s| if s.offered_rps > top_rate s.offered_rps else top_rate)
	x_ceiling = nice_ceiling(most_rate)
	x = |rate| left + rate / x_ceiling * (width - left - right)
	ticks_x = [0.0, 0.25, 0.5, 0.75, 1.0].map(|t| { x: Format.one_decimal(x(t * x_ceiling)), label: Format.compact(t * x_ceiling) })
	slowest = steps.fold(0.0, |worst, s| if s.p99_ms > worst s.p99_ms else worst)
	fastest = steps.fold(slowest, |best, s| if s.p99_ms > 0.0 and s.p99_ms < best s.p99_ms else best)
	decades = decades_between(fastest, slowest)
	low = List.first(decades) ?? 0.1
	high = List.last(decades) ?? 1000.0
	y = |ms| {
		clamped = if ms < low low else ms
		top + (1.0 - (log10(clamped) - log10(low)) / (log10(high) - log10(low))) * (height - top - bottom)
	}
	lines = spread_open(results.map(|r| open_line(r, x, y, mixed)))
	ticks_y = decades.map(|ms| { line_y: Format.one_decimal(y(ms)), text_y: Format.one_decimal(y(ms) + 4.0), label: ms_label(ms) })
	# The caption is one sentence on the load, as every strip's is: a mixed
	# workload's own summary (it races only open loop), else the ladder, its
	# shares from the run's own steps, never typed in (the owner,
	# 2026-10-07); what is plotted is the axis's note.
	least_share = steps.fold(1000.0, |least, s| if s.share < least s.share else least)
	most_share = steps.fold(0.0, |most, s| if s.share > most s.share else most)
	ladder = "The same requests at fixed rates, ${Format.thousands(least_share * 100.0)}% to ${Format.thousands(most_share * 100.0)}% of each server's own max."
	{ caption, measure } =
		if mixed {
			{ caption: summary, measure: "p99 latency, the slowest request type's" }
		} else {
			{ caption: ladder, measure: "p99 latency" }
		}
	{ title, caption, measure, lines, ticks_x, ticks_y }
}

open_line : Data.Result, (F64 -> F64), (F64 -> F64), Bool -> View.OpenLine
open_line = |result, x, y, mixed| {
	points = result.open_loop.map(|s| { s, px: x(s.offered_rps), py: y(s.p99_ms) })
	path = Str.join_with(points.map_with_index(|p, i| "${if i == 0 "M" else "L"}${Format.one_decimal(p.px)} ${Format.one_decimal(p.py)}"), " ")
	dots = points.map(|p| {
		cx: Format.one_decimal(p.px),
		cy: Format.one_decimal(p.py),
		hollow: p.s.loader_cpu_busy_pct >= loader_limit_pct,
		title: step_title(result.competitor, p.s, mixed),
	})
	{ last_x, last_y } =
		match List.last(points) {
			Ok(p) => { last_x: p.px, last_y: p.py }
			Err(_) => { last_x: 0.0, last_y: 0.0 }
		}
	{ competitor: result.competitor, path, dots, label_x: Format.one_decimal(last_x + 10.0), label_y: Format.one_decimal(last_y + 4.0), end_x: last_x, end_y: last_y }
}

step_title : Str, Data.OpenStep, Bool -> Str
step_title = |competitor, s, mixed| {
	limit = if s.loader_cpu_busy_pct >= loader_limit_pct " (the loader was the limit)" else ""
	rates = "${Format.thousands(s.offered_rps)}/s offered, ${Format.thousands(s.achieved_rps)}/s answered"
	cpu = "server CPU ${Format.thousands(s.cpu_busy_pct)}%, loader ${Format.thousands(s.loader_cpu_busy_pct)}%${limit}"
	if mixed {
		"${competitor}: ${rates}; the slowest part's p99 ${Format.latency(s.p99_ms)} ms, mean ${Format.latency(s.mean_ms)} ms; ${cpu}"
	} else {
		share = Format.thousands(s.share * 100.0)
		"${competitor} at ${share}% of its max: ${rates}; p99 ${Format.latency(s.p99_ms)} ms, p99.9 ${Format.latency(s.p999_ms)} ms; ${cpu}"
	}
}

## The open chart's labels, spread as the history charts' are.
spread_open : List(View.OpenLine) -> List(View.OpenLine)
spread_open = |lines| {
	ys = label_ys(lines.map(|l| { competitor: l.competitor, x: l.end_x, y: l.end_y, drawn: Bool.True }))
	List.map2(lines, ys, |l, y| { ..l, label_y: Format.one_decimal(y) })
}

## Powers of ten from at or below `low` to at or above `high`, at least
## two: the log axis's gridlines. 0.1 ms is the floor.
decades_between : F64, F64 -> List(F64)
decades_between = |low, high| {
	powers = [0.1, 1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0]
	from = powers.fold(0.1, |kept, p| if p <= low p else kept)
	to = powers.fold(100000.0, |kept, p| if p >= high and p < kept p else kept)
	chosen = powers.keep_if(|p| p >= from and p <= to)
	if List.len(chosen) < 2 [from, from * 10.0] else chosen
}

## Roc's F64 has no logarithm: the exponent t with 10^t = value, by
## bisection on F64.pow, 40 halvings (2^-40 of a decade: far below a
## pixel). For positive values between 10^-6 and 10^6.
log10 : F64 -> F64
log10 = |value| {
	var $low = -6.0
	var $high = 6.0
	for _ in 0..<40.U64 {
		middle = ($low + $high) / 2.0
		above = F64.pow(10.0, middle) > value
		$high = if above middle else $high
		$low = if above $low else middle
	}
	($low + $high) / 2.0
}

ms_label : F64 -> Str
## No space before the unit: on a phone the axis text is 20px and "100 ms"
## ran past the chart's left edge (2026-10-06); five characters fit.
ms_label = |ms| if ms < 1.0 "0.1ms" else if ms >= 1000.0 "${Format.thousands(ms / 1000.0)}s" else "${Format.thousands(ms)}ms"

expect decades_between(2.2, 1903.0) == [1.0, 10.0, 100.0, 1000.0, 10000.0]
expect decades_between(1.5, 1.6) == [1.0, 10.0]
expect ms_label(0.1) == "0.1ms" and ms_label(100.0) == "100ms" and ms_label(1000.0) == "1s" and ms_label(10000.0) == "10s"
expect took({ seconds: 3180.0, cost_usd: 0.4512 }) == "took 53 min · $0.45"
expect took({ seconds: 600.0, cost_usd: 0.0 }) == "took 10 min"
expect F64.abs(log10(1000.0) - 3.0) < 0.000001 and F64.abs(log10(0.1) + 1.0) < 0.000001 and F64.abs(log10(2.0) - 0.30103) < 0.00001

## What limited a result, from its rounds' medians: the server's CPU, the
## loader's, the network. At least 90% busy is a CPU at its limit; at
## least 1,400 Mbit/s either way is the network's, 70% of the 2 Gbit/s
## DigitalOcean documents for these droplets (where retransmits began,
## 2026-10-06). None of them: the closed loop's connections and their
## round trips were the limit (the server was under-driven).
limits : Data.Result, Bool -> List(Str)
limits = |result, local| {
	rounds = result.rounds
	cpu = median(rounds.map(|r| r.cpu_busy_pct))
	loader = median(rounds.map(|r| r.loader_cpu_busy_pct))
	net = median(rounds.map(|r| if r.net_rx_mbps > r.net_tx_mbps r.net_rx_mbps else r.net_tx_mbps))
	drops = median(rounds.map(|r| if r.rps > 0.0 and r.load_seconds > 0.0 r.tcp_retransmits / (r.rps * r.load_seconds) else 0.0))
	# A link enforcing its limit drops packets: a gigabit and more with a
	# retransmit every hundred requests is the link (2026-10-06: 1.3 Gbit/s
	# and 45,000 retransmits a round, p99 205 ms), as is 1.4 Gbit/s alone.
	at_link = net >= network_limit_mbps or (net >= 1000.0 and drops >= 0.01)
	List.concat(
		List.concat(if cpu >= cpu_limit_pct ["server CPU"] else [], if loader >= cpu_limit_pct ["loader"] else []),
		if !local and at_link ["network"] else [],
	)
}

limited_by : Data.Result, Bool -> Str
limited_by = |result, local| {
	found = limits(result, local)
	if found.is_empty() "connections (nothing saturated)" else Str.join_with(found, ", ")
}

cpu_limit_pct : F64
cpu_limit_pct = 90.0

network_limit_mbps : F64
network_limit_mbps = 1400.0

expect {
	round = |cpu, loader, net| { rps: 1.0, p99_ms: 1.0, cpu_busy_pct: cpu, steal_pct: 0.0, rss_kib: 0.0, loader_cpu_busy_pct: loader, net_rx_mbps: net, net_tx_mbps: 0.0, tcp_retransmits: 0.0, load_seconds: 20.0 }
	result = |rounds| { class: "c", workload: "w", competitor: "x", valid: Bool.True, note: "", rounds, median_rps: 1.0, median_p95_ms: 0.0, median_p99_ms: 0.0, median_p999_ms: 0.0, open_loop: [] }
	limited_by(result([round(99.0, 98.0, 240.0)]), Bool.False) == "server CPU, loader"
	and limited_by(result([round(88.0, 64.0, 1510.0)]), Bool.False) == "network"
	and limited_by(result([round(88.0, 64.0, 1510.0)]), Bool.True) == "connections (nothing saturated)"
	and limited_by(result([round(64.0, 52.0, 190.0)]), Bool.False) == "connections (nothing saturated)"
	and !saturated(result([round(64.0, 52.0, 190.0)]), Bool.False)
}

## A whisker narrower than this share of the strip's top bar is a few
## pixels: it reads as a blot on the bar's tip, not a range (the owner,
## 2026-10-06), so it is not drawn; the rounds agreed.
whisker_share_min : F64
whisker_share_min = 0.02

## Whether the server ran out of CPU, the case the race is for. A bar that
## did not is drawn as an outline ("server not saturated"): the loader, the
## network or too few connections set it, and the table says which. A
## server at its CPU's limit that also met the network is saturated.
saturated : Data.Result, Bool -> Bool
saturated = |result, local| limits(result, local).any(|limit| limit == "server CPU")

## The slowest and the fastest round.
round_range : Data.Result -> { slowest : F64, fastest : F64 }
round_range = |result| {
	rates = result.rounds.map(|r| r.rps)
	fastest = rates.fold(result.median_rps, |best, rate| if rate > best rate else best)
	slowest = rates.fold(fastest, |low, rate| if rate < low rate else low)
	{ slowest, fastest }
}

## How far apart the rounds were, as a share of the median: with three
## rounds the range, not a confidence interval, which two degrees of
## freedom would make four times as wide as the rounds themselves.
spread_pct : Data.Result -> F64
spread_pct = |result| {
	{ slowest, fastest } = round_range(result)
	if result.median_rps <= 0.0 0.0 else 100.0 * (fastest - slowest) / result.median_rps
}

expect {
	at = |net, retransmits| { rps: 35000.0, p99_ms: 200.0, cpu_busy_pct: 93.0, steal_pct: 0.0, rss_kib: 0.0, loader_cpu_busy_pct: 26.0, net_rx_mbps: net, net_tx_mbps: 0.0, tcp_retransmits: retransmits, load_seconds: 20.0 }
	result = |rounds| { class: "c", workload: "w", competitor: "x", valid: Bool.True, note: "", rounds, median_rps: 35000.0, median_p95_ms: 0.0, median_p99_ms: 0.0, median_p999_ms: 0.0, open_loop: [] }
	limited_by(result([at(1322.0, 47363.0)]), Bool.False) == "server CPU, network"
	and saturated(result([at(1322.0, 47363.0)]), Bool.False)
	and limited_by(result([at(1322.0, 100.0)]), Bool.False) == "server CPU"
}

## A machine's memory as the kernel has it, " · 457 MiB" or " · 3.8 GiB";
## nothing for a run from before it was recorded (0).
memory : U32 -> Str
memory = |mib|
	if mib == 0 {
		""
	} else if mib < 1024 {
		" · ${mib.to_str()} MiB"
	} else {
		" · ${Format.one_decimal(mib.to_f64() / 1024.0)} GiB"
	}

expect memory(0) == "" and memory(457) == " · 457 MiB" and memory(3916) == " · 3.8 GiB"
