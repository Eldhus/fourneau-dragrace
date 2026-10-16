import Data
import Format
import db/Pages
import db/Live

## What the pages show, made from the races: every number formatted, every
## bar's share and every chart's path computed here, so the templates only
## place text.
View :: [].{
	Commit : { name : Str, short : Str, url : Str }
	## `hollow`: something besides the server's CPU limited the result (the
	## tip and the table say what), drawn as an outline, as the open loop's
	## hollow points are.
	## `share`: the best round's; `low`, `high`: the slowest and fastest
	## rounds as shares, the whisker's ends (the fastest is the bar's end:
	## the whisker shows how far noise took the other rounds below it).
	## `p99`: the rounds' median p99 in milliseconds, two figures, small
	## after the rate for comparing tails at a glance; `p99_tip`, its hover.
	## `raced`: else the row is "n/a", muted (a DNF is the news, in gold).
	Row : { competitor : Str, valid : Bool, raced : Bool, share : Str, low : Str, high : Str, value : Str, p99 : Str, p99_tip : Str, ranged : Bool, hollow : Bool, tip : Str }
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
	## `key`: which chart this is in every class and section (chart_key).
	## `variant`: the line under the summary (variant_line). `run`: the
	## run's id, faint in the corner, so a picture of one chart says which
	## race it is.
	Strip : { key : Str, title : Str, summary : Str, variant : List(Str), run : Str, rows : List(Row), table : List(TableRow) }
	## A machine's line, item by item: a line breaks between them only.
	Machine : { role : Str, items : List(Str) }
	## A class as one section shows it (its tabs say which, no sentence
	## repeating them), and below, outside the
	## section's toggle, the h2c comparison (one, or none in a race without
	## it). `history`: the address of its history panel's charts, this
	## class's in this section, fetched when the panel is first opened.
	Class : { name : Str, label : Str, title : Str, machines : List(Machine), strips : List(Strip), open : List(OpenChart), h2c : List(H2c), history : Str }
	## Plaintext three ways: HTTP/1.1, HTTP/2 without TLS (h2c), HTTP/2 and
	## TLS; each step's change is what HTTP/2, then TLS, cost or gave.
	## `strips`: the h2c workload's bars, one strip (a template's section
	## over a record is a list).
	H2c : { strips : List(Strip), rows : List(H2cRow) }
	## On a phone the table is four columns: each
	## rate in three figures (`*_short`), and each change small under the
	## rate it led to (`*_note`, "" where either rate is missing; muted, its
	## sign the news: a colour would read as a competitor's).
	H2cRow : { competitor : Str, plain : Str, h2c : Str, tls : Str, plain_short : Str, h2c_short : Str, tls_short : Str, http2_change : Str, tls_change : Str, http2_note : Str, tls_note : Str }
	## A section of the race page, toggled beside the class tabs.
	Section : { name : Str, label : Str }
	## The open-loop ladder: p99 against the offered rate, a line per
	## competitor; a hollow point is a step where the loader was the limit.
	OpenDot : { cx : Str, cy : Str, hollow : Bool, title : Str }
	OpenLine : { competitor : Str, path : Str, dots : List(OpenDot), label_x : Str, label_y : Str }
	## An open line before its label is placed: `end_x`, `end_y` are where
	## it ends, for spreading the labels apart (`spread_open`).
	DraftOpenLine : { competitor : Str, path : Str, dots : List(OpenDot), label_x : Str, label_y : Str, end_x : F64, end_y : F64 }
	## `caption`: one sentence on the load; `measure`: the y axis's note;
	## `loader_bound`: a point is hollow, so the legend explains it.
	## `legend`: every competitor of the race, in its order, "n/a" where it
	## has no line, so both sections' legends are alike.
	OpenChart : { key : Str, title : Str, caption : Str, variant : List(Str), run : Str, measure : Str, lines : List(OpenLine), legend : List(Legend), ticks_x : List(Mark), ticks_y : List(Tick), loader_bound : Bool }
	## A chart's legend entry; `drawn`, else "n/a": not raced, or no result.
	Legend : { competitor : Str, drawn : Bool }
	Latest : { id : Str, started : Str, took : Str, timed : Bool, commits : List(Commit), competitors : List(Str), sections : List(Section), section : Str, classes : List(Class) }

	Dot : { cx : Str, cy : Str, r : Str, title : Str }
	## A history line; the chart's own legend names it, not a label at its
	## end (on a phone the end labels are hidden, and a legend for the page
	## scrolls away, so no chart would say which line is which).
	Line : { competitor : Str, drawn : Bool, path : Str, dots : List(Dot) }
	Tick : { line_y : Str, text_y : Str, label : Str }
	Mark : { x : Str, label : Str }
	## A race on the history's x axis: its day, and under it its time when
	## another race shares the day (one line, "Oct 10 12:26", overlapped
	## its neighbours on a phone).
	DateMark : { x : Str, day : Str, time : Str }
	Chart : { key : Str, title : Str, variant : List(Str), empty : Bool, lines : List(Line), ticks : List(Tick), dates : List(DateMark) }
	## A class's history in one section; `h2c`, HTTP/2 without TLS, below it.
	Charts : { name : Str, label : Str, title : Str, charts : List(Chart), h2c : List(Chart) }
	History : { waiting : Bool, sections : List(Section), section : Str, classes : List(Charts) }

	Pin : { name : Str, version : Str }

	## The Workloads page, every figure from the newest race (nothing typed
	## in that race.json decides): a card per test, then its variants said
	## once, by protocol (not repeated under every test). A card's `paragraphs`:
	## after the summary, the detail and a mixed one's open loop, those it
	## has; `protocols`: the variants it is raced in.
	WorkloadCard : { title : Str, route : Str, summary : Str, paragraphs : List(Str), protocols : List(Str) }
	## A protocol's variants: a row per way the loader sends them (the
	## variant line, less the protocol where the heading says it), and the
	## tests sent that way.
	VariantGroup : { label : Str, intro : Str, rows : List(VariantRow) }
	VariantRow : { line : List(Str), tests : Str }
	Workloads : { ready : Bool, cards : List(WorkloadCard), variants : List(VariantGroup), rounds : Str, warmup : Str, measure : Str, loader_limit : Str }

	workloads : List(Pages.WorkloadSpecs), Pages.RaceSettings -> Workloads
	workloads = |specs, settings| {
		ready: Bool.True,
		# A test's HTTP/1.1 variant is named as the test (race.json).
		cards: specs.keep_if(|w| w.name == w.test).map(|test| workload_card(test, specs.keep_if(|w| w.test == test.test))),
		variants: variant_groups(specs),
		rounds: settings.rounds.to_str(),
		warmup: settings.warmup_seconds.to_str(),
		measure: settings.measure_seconds.to_str(),
		loader_limit: Format.thousands(loader_limit_pct),
	}

	## A server class's tab: a link to the same page showing that class.
	## `label` is the class's short name; its title heads the class below.
	## `action`: Datastar's, on a click: the address updated and only the
	## class's fragment fetched and swapped in place, so the page does not
	## move; without JavaScript the link loads the page.
	Tab : { href : Str, label : Str, current : Bool, action : Str }

	## The tab a page shows: the one asked for when the race has it, else
	## the default when it has that, else the first. The tabs keep their
	## order either way.
	chosen : List(Str), Str, Str -> Str
	chosen = |names, wanted, default|
		if names.contains(wanted) {
			wanted
		} else if names.contains(default) {
			default
		} else {
			match List.first(names) {
				Ok(first) => first
				Err(_) => ""
			}
		}

	## The class shown when none is asked for: the
	## dedicated cores, whose numbers are the engines'.
	default_class : Str
	default_class = "dedicated-2"

	## A tab per class, linking to `page` with `?class=NAME` and the section
	## shown (`protocol`), kept across a switch. Only names the race itself
	## has are ever put in a link.
	tabs : List({ name : Str, label : Str }), Str, Str, Str -> List(Tab)
	tabs = |classes, current, section, page|
		classes.map(|class| tab(page, class.name, section, class.label, class.name == current))

	## A tab per section, beside the class tabs: the same class, the other
	## section. None when the race has one section only.
	section_tabs : List(Section), Str, Str, Str -> List(Tab)
	section_tabs = |sections, current, class, page|
		if List.len(sections) < 2 {
			[]
		} else {
			sections.map(|s| tab(page, class, s.name, s.label, s.name == current))
		}

	## The section a page shows: the one asked for when the race has it,
	## else HTTP/2 + TLS, the realistic deployment.
	chosen_section : List(Section), Str -> Str
	chosen_section = |sections, wanted| chosen(sections.map(|s| s.name), wanted, "tls")

	## The sections a race has, in the page's order: HTTP/1.1, then HTTP/2
	## and TLS. h2c is not one: it is shown below either.
	sections_of : Data.Run -> List(Section)
	sections_of = |run|
		[{ name: "http1", label: "HTTP/1.1" }, { name: "tls", label: "HTTP/2 + TLS" }]
			.keep_if(|s| run.race.workloads.any(|w| w.protocol == s.name))

	## The newest race, as the front page shows it: one section.
	latest : Data.Run, Str -> Latest
	latest = |run, wanted| {
		sections = sections_of(run)
		section = chosen_section(sections, wanted)
		{
			id: run.id,
			started: started(run.started_at),
			took: took(run.timing),
			timed: run.timing.seconds > 0.0,
			commits: commits(run),
			competitors: run.race.competitors,
			sections,
			section,
			classes: classes_of(run).map(|class| class_view(run, class, section)),
		}
	}

	## Every race's best rounds, a chart per server class and workload of
	## one section, and h2c's below; two races at least.
	history : Data.Run, List(Data.Entry), Str -> History
	history = |run, entries, wanted| {
		sections = sections_of(run)
		section = chosen_section(sections, wanted)
		charted = |name, class| in_section(closed(run.race.workloads), name).map(|workload| chart(entries, class.name, as_test(run.race.workloads, workload), run.race.competitors))
		classes = classes_of(run).map(|class| {
			name: class.name,
			label: class.label,
			title: class.title,
			charts: charted(section, class),
			h2c: charted("h2c", class),
		})
		{ waiting: List.len(entries) < 2, sections, section, classes }
	}

	## The race page's live banner while a run races (LiveRace.rocstache):
	## "Racing now", then a lane per server class. `flare`: a result has
	## just landed; `done` (the steps raced of all the classes') names the
	## flare's canvas, so each result's is a new element and its animation
	## runs.
	LiveBanner : { lanes : List(Lane), flare : Bool, done : Str }
	## A server class: its name, its step count and time left beside
	## its bars; the step racing (`now`, and when its result lands, `soon`)
	## over the step's bar; under it the class's track, a mark a step.
	## `stepping`: a step is racing: its bar fills from `from` (0 to 1) to
	## the end in `seconds`, the estimate's rest; `late`, past it.
	## `fill` names the bar's fill by the class, the step and its seconds,
	## so each patch draws a new one: a CSS animation already running keeps
	## its start and runs on (full, a step later) whatever the patch says.
	## `track`: each step "done", "now", "next" or, failed, "bad".
	Lane : {
		label : Str,
		count : Str,
		left : Str,
		now : Str,
		soon : Str,
		stepping : Bool,
		late : Bool,
		failed : Bool,
		from : Str,
		seconds : Str,
		fill : Str,
		track : List(Str),
	}

	live_banner : List(Live.Classes), Bool -> LiveBanner
	live_banner = |classes, flare| {
		done = classes.fold(0.I64, |sum, c| sum + raced(c))
		{ lanes: classes.map(lane), flare, done: done.to_str() }
	}

	## Every word the banner says, and its marks: the stream patches the
	## page only when this changed (the step bars move by themselves, in
	## CSS).
	said : LiveBanner -> Str
	said = |banner|
		Str.join_with(banner.lanes.map(|l| "${l.label} ${l.count} ${l.left} ${l.now} ${l.soon} ${Str.join_with(l.track, ",")}"), "|")

	## A class's steps raced: before the step racing, or all begun once
	## it is done (a failed class's last begun did not finish).
	raced : Live.Classes -> I64
	raced = |c|
		if c.status == "done" c.step
		else if c.step > 0 c.step - 1
		else 0

	## A class's lane. A class whose worker tells no steps (one older than
	## the plan, race.go's Step) says only its time.
	lane : Live.Classes -> Lane
	lane = |c| {
		over = c.status != "racing"
		failed = c.status == "failed"
		stepping = !over and c.step > 0
		rest = c.step_estimate - c.step_seconds
		finished = raced(c)
		var $track = []
		var $i = 1
		while $i <= c.steps {
			mark =
				if $i <= finished "done"
				else if $i == c.step and failed "bad"
				else if $i == c.step and !over "now"
				else "next"
			$track = $track.append(mark)
			$i = $i + 1
		}
		count =
			if c.steps == 0 ""
			else if over or c.step == 0 "${finished.to_str()} of ${c.steps.to_str()} steps"
			else "step ${c.step.to_str()} of ${c.steps.to_str()}"
		left =
			if c.status == "done" "done in ${View.clock(c.elapsed_seconds)}"
			else if failed "failed at ${View.clock(c.elapsed_seconds)}"
			else if c.steps == 0 "${View.clock(c.elapsed_seconds)} elapsed"
			else if c.left_seconds <= 0.0 "running long"
			else "about ${View.clock(c.left_seconds)} left"
		now =
			if failed (if c.reason == "" "failed" else "failed: ${c.reason}")
			else if over "every step raced"
			else if c.steps == 0 "racing"
			else if c.step == 0 "readying the server and the loader"
			else step_name(c.competitor, c.round, c.rounds, c.workload)
		soon =
			if !stepping ""
			else if rest > 0.0 "result ${View.in_minutes(rest)}"
			else if rest > -60.0 "running a little long"
			else "running ${View.whole_minutes(0.0 - rest)} long"
		from =
			if !stepping or c.step_estimate <= 0.0 0.0
			else if c.step_seconds >= c.step_estimate 1.0
			else c.step_seconds / c.step_estimate
		seconds = if stepping and rest > 0.0 (rest.round_to_u64_try() ?? 0) else 0
		{
			label: c.label,
			count,
			left,
			now,
			soon,
			stepping,
			late: stepping and rest <= 0.0,
			failed,
			from: Format.two_decimals(from),
			seconds: seconds.to_str(),
			fill: "${c.class}-${c.step.to_str()}-${(c.step_seconds.round_to_u64_try() ?? 0).to_str()}",
			track: $track,
		}
	}

	## "roux · round 2 of 3", or a ladder's "roux · RealWorld (Conduit) ladder".
	step_name : Str, I64, I64, Str -> Str
	step_name = |competitor, round, rounds, workload|
		if round > 0 "${competitor} · round ${round.to_str()} of ${rounds.to_str()}"
		else "${competitor} · ${workload} ladder"

	## Seconds to come, said in minutes: "in under a minute", "in about 3 min".
	in_minutes : F64 -> Str
	in_minutes = |seconds| if seconds < 60.0 "in under a minute" else "in about ${View.whole_minutes(seconds)}"

	## Seconds in whole minutes, rounded up: "3 min".
	whole_minutes : F64 -> Str
	whole_minutes = |seconds| {
		whole = seconds.round_to_u64_try() ?? 0
		"${((whole + 59) // 60).to_str()} min"
	}

	## Seconds as hours and minutes, HH:MM, rounded up to the minute: a
	## race says 00:01 until it is done, never 00:00.
	clock : F64 -> Str
	clock = |seconds| {
		whole_seconds = seconds.round_to_u64_try() ?? 0
		minutes = (whole_seconds + 59) // 60
		hours = minutes // 60
		rest = minutes % 60
		pad = |n| if n < 10 "0${n.to_str()}" else n.to_str()
		"${pad(hours)}:${pad(rest)}"
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
			{ name: "fourneau", version: Format.short(run.fingerprint.fourneau) },
		].concat(if run.fingerprint.roux.is_empty() [] else [{ name: "roux", version: Format.short(run.fingerprint.roux) }])
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
## then, by its name alone, any its results name that race.json does not
## (none so far: kept so a stored run still shows whole). Not the
## results' order: the database sorts those by name, which puts
## dedicated-2 before smallest.
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
			Err(_) => { name, label: name, title: name }
		})
}

## A tab: a link to `page` showing `class` in `section`. `action`:
## Datastar's, on a click: the address updated and only the classes'
## fragment fetched and swapped in place, so the page does not move;
## without JavaScript the link loads the page.
tab : Str, Str, Str, Str, Bool -> View.Tab
tab = |page, class, section, label, current| {
	query = "?class=${class}&protocol=${section}"
	fragment = if page == "/" "/race-classes" else "${page}-classes"
	{
		href: "${page}${query}",
		label,
		current,
		action: "window.history.replaceState(null, '', '${page}${query}'); @get('${fragment}${query}')",
	}
}

class_view : Data.Run, Data.ServerClass, Str -> View.Class
class_view = |run, class, section| {
	# A loader is its class's.
	described = run.machines.keep_if(|machine| machine.class == class.name)
	# The server first: it is what the class is about.
	ordered = described.sort_with(|a, b| if a.role == b.role Same else if a.role == "server" Before else After)
	machines = ordered.map(|m| { role: m.role, items: [m.size, vcpus(m.cpus)].concat(memory(m.memory_mib)).concat([cpu_name(m.cpu), "Linux ${m.kernel}"]) })
	strips = in_section(closed(run.race.workloads), section).map(|workload| strip(run, class.name, workload))
	open = open_charts(run, class.name).keep_if(|o| o.section == section).map(|o| o.chart)
	history = "/history-panel?class=${class.name}&protocol=${section}"
	{ name: class.name, label: class.label, title: class.title, machines, strips, open, h2c: h2c_view(run, class.name), history }
}

## A CPU's model name without its makers' marks and filler words, so a
## machine's line stays short: "Intel(R) Xeon(R) Platinum 8280 CPU @
## 2.70GHz" is "Intel Xeon Platinum 8280 @ 2.70GHz".
cpu_name : Str -> Str
cpu_name = |name| name.replace_each("(R)", "").replace_each("(TM)", "").replace_each(" CPU", "").replace_each(" Processor", "")

expect cpu_name("Intel(R) Xeon(R) Platinum 8280 CPU @ 2.70GHz") == "Intel Xeon Platinum 8280 @ 2.70GHz"
expect cpu_name("AMD EPYC 7543 32-Core Processor") == "AMD EPYC 7543 32-Core" and cpu_name("DO-Regular") == "DO-Regular"

## The workloads one section shows: its protocol's.
in_section : List(Data.Workload), Str -> List(Data.Workload)
in_section = |workloads, section| workloads.keep_if(|w| w.protocol == section)

## What a protocol is, one sentence: on Workloads, over its variants.
intro : Str -> Str
intro = |section|
	if section == "tls" {
		"The realistic deployment: HTTPS as browsers reach a server with no proxy in front. TLS 1.3, AES-128-GCM, X25519, an ECDSA P-256 certificate, no session resumption; HTTP/2 by ALPN (churn: HTTP/1.1). basic-webserver serves no TLS."
	} else if section == "h2c" {
		"HTTP/2 without TLS, by prior knowledge: HTTP/2's own cost, apart from TLS's. No browser speaks it."
	} else {
		"Plain HTTP/1.1, as a server behind a proxy sees it."
	}

## Plaintext three ways, when the race has h2c: its bars, and each
## competitor's HTTP/1.1, h2c and HTTP/2 + TLS plaintext side by side, the
## test's other variants.
h2c_view : Data.Run, Str -> List(View.H2c)
h2c_view = |run, class|
	match run.race.workloads.find_first(|w| w.protocol == "h2c") {
		Err(_) => []
		Ok(h2c) => {
			variant = |protocol|
				match run.race.workloads.find_first(|w| w.test == h2c.test and w.protocol == protocol) {
					Ok(w) => w.name
					Err(_) => ""
				}
			found = |workload, competitor|
				match run.results.find_first(|r| r.class == class and r.workload == workload and r.competitor == competitor and r.valid) {
					Ok(r) => r.best_rps
					Err(_) => 0.0
				}
			bars = strip(run, class, h2c)
			rows = bars.rows.map(|bar| {
				plain = found(variant("http1"), bar.competitor)
				h2 = found(h2c.name, bar.competitor)
				secure = found(variant("tls"), bar.competitor)
				{
					competitor: bar.competitor,
					plain: rate_or_dash(plain),
					h2c: rate_or_dash(h2),
					tls: rate_or_dash(secure),
					plain_short: short_rate(plain),
					h2c_short: short_rate(h2),
					tls_short: short_rate(secure),
					http2_change: change(plain, h2),
					tls_change: change(h2, secure),
					http2_note: if h2 > 0.0 and plain > 0.0 change(plain, h2) else "",
					tls_note: if secure > 0.0 and h2 > 0.0 change(h2, secure) else "",
				}
			})
			[{ strips: [bars], rows }]
		}
	}

## A rate, or a dash where there is none (not raced, or did not finish).
rate_or_dash : F64 -> Str
rate_or_dash = |rps| if rps > 0.0 Format.thousands(rps) else "—"

## A rate in three figures, for a phone's table: 136k, 51.5k, 5.2k, 640;
## five characters at most.
short_rate : F64 -> Str
short_rate = |rps|
	if rps <= 0.0 {
		"—"
	} else if rps < 1000.0 {
		Format.thousands(rps)
	} else if rps < 100000.0 {
		Format.compact(rps)
	} else {
		"${((rps / 1000.0).round_to_u64_try() ?? 0).to_str()}k"
	}

expect short_rate(136468.0) == "136k" and short_rate(51457.0) == "51.5k" and short_rate(5247.0) == "5.2k"
expect short_rate(640.0) == "640" and short_rate(0.0) == "—" and short_rate(17688.0) == "17.7k"

## From `before` to `after` as a signed percentage ("+21%", "−12%").
change : F64, F64 -> Str
change = |before, after|
	if before <= 0.0 or after <= 0.0 {
		"—"
	} else {
		pct = (after / before - 1.0) * 100.0
		if pct >= 0.0 "+${Format.thousands(pct)}%" else "−${Format.thousands(0.0 - pct)}%"
	}

expect change(100.0, 121.0) == "+21%"
expect change(100.0, 88.0) == "−12%"
expect change(0.0, 88.0) == "—" and rate_or_dash(0.0) == "—"

## The workloads raced in rounds, drawn as bars and in the history; a
## mixed one (conduit) is a ladder only, drawn as a line (open_charts).
closed : List(Data.Workload) -> List(Data.Workload)
closed = |workloads| workloads.keep_if(|w| w.kind != "mixed")

## One workload on one server class: a bar per competitor, fastest first,
## then a row "n/a" for each the race has that did not race it
## (basic-webserver serves no TLS), so both sections show every
## competitor and their charts are the same height.
strip : Data.Run, Str, Data.Workload -> View.Strip
strip = |run, class, workload| {
	results = run.results
		.keep_if(|r| r.class == class and r.workload == workload.name)
		.sort_with(|a, b| if a.best_rps > b.best_rps Before else if a.best_rps < b.best_rps After else Same)
	# The scale ends at the fastest round, so every whisker fits.
	most = results.fold(0.0, |best, r| if r.valid and round_range(r).fastest > best round_range(r).fastest else best)
	absent = run.race.competitors.keep_if(|c| !results.any(|r| r.competitor == c))
	not_raced = |c| "${c} is not raced over ${protocol_label(workload.protocol, workload.http2)}"
	rows = results.map(|r| row(r, most)).concat(absent.map(|c| { ..row_not_raced(c), tip: not_raced(c) }))
	table = results.map(|r| table_row(r)).concat(absent.map(|c| { ..table_row_not_raced(c), note: not_raced(c) }))
	shown = as_test(run.race.workloads, workload)
	{ key: chart_key(workload), title: shown.title, summary: shown.summary, variant: workload_variant(workload), run: run.id, rows, table }
}

## A variant as the race page and History title it: its test's title and
## summary (the HTTP/1.1 variant's), the same in both sections, the tab and
## the variant line saying the protocol; so a switch changes no caption's
## length. h2c's keeps its own: it shows below
## either section.
as_test : List(Data.Workload), Data.Workload -> Data.Workload
as_test = |workloads, workload|
	if workload.protocol == "h2c" {
		workload
	} else {
		match workloads.find_first(|w| w.name == workload.test) {
			Ok(test) => { ..workload, title: test.title, summary: test.summary }
			Err(_) => workload
		}
	}

expect {
	w = |name, test, protocol, title| { name, test, kind: "closed", title, summary: title, protocol, connections: 256, streams: 0, keepalive: Bool.True, http2: Bool.False, tls: Bool.False }
	all = [w("echo-4k", "echo-4k", "http1", "Echo 4 KiB"), w("echo-4k-tls", "echo-4k", "tls", "Echo 4 KiB, HTTP/2 + TLS"), w("plaintext-h2", "plaintext", "h2c", "Plaintext, HTTP/2 (h2c)")]
	shown = |name| all.find_first(|x| x.name == name).map_ok(|x| as_test(all, x).title) ?? ""
	shown("echo-4k-tls") == "Echo 4 KiB" and shown("echo-4k") == "Echo 4 KiB" and shown("plaintext-h2") == "Plaintext, HTTP/2 (h2c)"
}

## Which chart a workload's is, the same in every class and section: its
## test's, over HTTP/1.1 or TLS. A tab keeps that chart where it was on the
## screen (static/demo.js), so switching section compares the two
## protocols. h2c's is its own: it shows below either.
chart_key : Data.Workload -> Str
chart_key = |workload| if workload.protocol == "h2c" workload.name else workload.test

expect {
	w = |name, test, protocol| { name, test, kind: "closed", title: "", summary: "", protocol, connections: 256, streams: 0, keepalive: Bool.True, http2: Bool.False, tls: Bool.False }
	chart_key(w("echo-4k-tls", "echo-4k", "tls")) == "echo-4k" and chart_key(w("echo-4k", "echo-4k", "http1")) == "echo-4k"
	and chart_key(w("plaintext-h2", "plaintext", "h2c")) == "plaintext-h2"
}

## How a variant is sent, the protocol first: what the line under a chart,
## and on Workloads under a test, says (thin text in the protocol tabs'
## colour, bullets between). Short enough for one line on a phone: kept
## alive goes unsaid, the usual case (the bars first, the words quieter).
## Churn's no longer than
## HTTP/2's: "connections, one request each" wrapped at 350 px wide over
## TLS and not over HTTP/1.1, so a section switch moved every chart
## below it.
variant_line : Str, Bool, I64, I64, Bool -> List(Str)
variant_line = |protocol, http2, connections, streams, keepalive| {
	carried =
		if http2 "${connections.to_str()} connections × ${streams.to_str()} streams"
		else if keepalive "${connections.to_str()} connections"
		else "${connections.to_str()} one-shot connections"
	[protocol_label(protocol, http2), carried]
}

workload_variant : Data.Workload -> List(Str)
workload_variant = |w| variant_line(w.protocol, w.http2, w.connections, w.streams, w.keepalive)

## A variant's protocol by name, in a variant line: over TLS without
## HTTP/2 is churn's. "HTTP/2+TLS", no spaces, is one item between the
## bullets (spaced, it read as three); the tabs
## and titles keep "HTTP/2 + TLS".
protocol_label : Str, Bool -> Str
protocol_label = |protocol, http2|
	if protocol == "h2c" "HTTP/2 (h2c)"
	else if protocol == "tls" and http2 "HTTP/2+TLS"
	else if protocol == "tls" "HTTP/1.1+TLS"
	else "HTTP/1.1"

expect variant_line("tls", Bool.True, 128, 2, Bool.True) == ["HTTP/2+TLS", "128 connections × 2 streams"]
expect variant_line("tls", Bool.False, 64, 0, Bool.False) == ["HTTP/1.1+TLS", "64 one-shot connections"]
expect variant_line("http1", Bool.False, 256, 0, Bool.True) == ["HTTP/1.1", "256 connections"]

row : Data.Result, F64 -> View.Row
row = |result, most|
	if !result.valid or most <= 0.0 {
		{ ..row_not_raced(result.competitor), raced: Bool.True, value: "DNF", tip: "${result.competitor} did not finish: ${result.note}" }
	} else {
		value = Format.thousands(result.best_rps)
		rounds = List.len(result.rounds).to_str()
		{ slowest, fastest } = round_range(result)
		spread = spread_pct(result)
		{
			competitor: result.competitor,
			valid: Bool.True,
			raced: Bool.True,
			share: Format.two_decimals(result.best_rps / most),
			low: Format.two_decimals(slowest / most),
			high: Format.two_decimals(fastest / most),
			value,
			p99: Format.two_figures(result.median_p99_ms),
			p99_tip: "p99 ${Format.latency(result.median_p99_ms)} ms, the rounds' median",
			ranged: (fastest - slowest) / most >= whisker_share_min,
			hollow: !saturated(result),
			tip: "${result.competitor}: ${value} req/s, the best of ${rounds} rounds (the slowest ${Format.thousands(slowest)}, ${Format.thousands(spread)}% below), limited by ${limited_by(result)}; the rounds' median p95 ${Format.latency(result.median_p95_ms)}, p99 ${Format.latency(result.median_p99_ms)}, p99.9 ${Format.latency(result.median_p999_ms)} ms",
		}
	}

## A competitor that did not race the workload: "n/a" where its bar would
## be (the tip says why).
row_not_raced : Str -> View.Row
row_not_raced = |competitor| { competitor, valid: Bool.False, raced: Bool.False, share: "0", low: "0", high: "0", value: "n/a", p99: "", p99_tip: "", ranged: Bool.False, hollow: Bool.False, tip: "" }

table_row_not_raced : Str -> View.TableRow
table_row_not_raced = |competitor| { competitor, valid: Bool.False, note: "", rps: "", p95: "", p99: "", p999: "", rounds: "", cpu: "", loader: "", net: "", limit: "", spread: "", steal: "", rss: "" }

## The table: the rate the bar's (the best round), the percentiles the
## rounds' medians (Data.Result says why); what the machines did is the
## fastest round's, the one the bar shows.
table_row : Data.Result -> View.TableRow
table_row = |result| {
	rounds = result.rounds
	rss = rounds.fold(0.0, |top, r| if r.rss_kib > top r.rss_kib else top)
	best = best_round(result)
	{
		competitor: result.competitor,
		valid: result.valid,
		note: "not valid: ${result.note}",
		rps: Format.thousands(result.best_rps),
		p95: Format.latency(result.median_p95_ms),
		p99: Format.latency(result.median_p99_ms),
		p999: Format.latency(result.median_p999_ms),
		rounds: Str.join_with(rounds.map(|r| Format.thousands(r.rps)), " · "),
		cpu: Format.one_decimal(best.cpu_busy_pct),
		loader: Format.one_decimal(best.loader_cpu_busy_pct),
		net: "${Format.thousands(best.net_rx_mbps)} / ${Format.thousands(best.net_tx_mbps)}",
		limit: limited_by(result),
		spread: Format.one_decimal(spread_pct(result)),
		steal: Format.one_decimal(best.steal_pct),
		rss: "${Format.one_decimal(rss / 1024.0)} MiB",
	}
}

## The round with the most requests a second (the first of equals), or
## one of zeros where there is none.
best_round : Data.Result -> Data.Round
best_round = |result| {
	none = { rps: 0.0, p99_ms: 0.0, cpu_busy_pct: 0.0, steal_pct: 0.0, rss_kib: 0.0, loader_cpu_busy_pct: 0.0, net_rx_mbps: 0.0, net_tx_mbps: 0.0, tcp_retransmits: 0.0, load_seconds: 0.0 }
	result.rounds.fold(none, |best, r| if r.rps > best.rps r else best)
}

# The history chart's geometry, in HistoryChart.rocstache's viewBox. No
# room on the right for line names (the legend names them), only for the
# last date's half; the bottom holds two lines of date.
width = 720.0
height = 280.0
left = 72.0
right = 40.0
top = 14.0
bottom = 56.0

chart : List(Data.Entry), Str, Data.Workload, List(Str) -> View.Chart
chart = |all_entries, class, workload, competitors| {
	value = |entry, competitor|
		match entry.results.find_first(|r| r.class == class and r.workload == workload.name and r.competitor == competitor and r.valid) {
			Ok(found) => Ok(found.best_rps)
			Err(_) => Err(Missing)
		}
	# From the first race that ran this workload: a workload added later
	# drew its lines in the right third of an axis of empty dates.
	ran = |entry| competitors.any(|c|
		match value(entry, c) {
			Ok(_) => Bool.True
			Err(_) => Bool.False
		})
	entries = all_entries.drop_first(all_entries.find_first_index(ran) ?? 0)
	most = entries.fold(0.0, |top_value, entry|
		competitors.fold(top_value, |t, c|
			match value(entry, c) {
				Ok(v) => if v > t v else t
				Err(_) => t
			}))
	if most <= 0.0 {
		{ key: chart_key(workload), title: workload.title, variant: workload_variant(workload), empty: Bool.True, lines: [], ticks: [], dates: [] }
	} else {
		ceiling = nice_ceiling(most)
		count = List.len(entries)
		x = |i| left + (if count == 1 0.5 else i.to_f64() / (count - 1).to_f64()) * (width - left - right)
		y = |v| top + (1.0 - v / ceiling) * (height - top - bottom)
		lines = competitors.map(|competitor| line(entries, competitor, value, x, y))
		ticks = [0.0, 1.0, 2.0, 3.0, 4.0].map(|t| {
			v = ceiling * t / 4.0
			{ line_y: Format.one_decimal(y(v)), text_y: Format.one_decimal(y(v) + 4.0), label: Format.compact(v) }
		})
		every = if count <= 6 1 else (count + 5) // 6
		dates = entries
			.map_with_index(|entry, i| { i, entry })
			.keep_if(|e| e.i % every == 0 or e.i == count - 1)
			.map(|e| {
				x: Format.one_decimal(x(e.i)),
				day: day(e.entry.started_at),
				time: axis_time(entries, e.entry.started_at),
			})
		{ key: chart_key(workload), title: workload.title, variant: workload_variant(workload), empty: Bool.False, lines, ticks, dates }
	}
}

## A competitor's best rounds as an SVG path, lifting the pen over races it
## did not finish.
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
	{ competitor, drawn: !$path.is_empty(), path: $path, dots: $dots }
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

import "test/latest.json" as latest_sample : Str
import "test/index.json" as index_sample : Str

expect
	match Data.run(latest_sample) {
		Ok(run) => {
			page = View.latest(run, "")
			first_strip_ok =
				match List.first(page.classes) {
					Ok(class) =>
						match List.first(class.strips) {
							Ok(first) => List.len(first.rows) == 4 and first.title == "Plaintext"
							Err(_) => Bool.False
						}
					Err(_) => Bool.False
				}
			# A race before HTTP/2 and TLS: one section, no toggle, no h2c.
			one_section = page.section == "http1" and List.len(page.sections) == 1 and page.classes.all(|c| c.h2c.is_empty())
			List.len(page.classes) == 2 and List.len(page.commits) == 3 and first_strip_ok and one_section
		}
		Err(_) => Bool.False
	}

expect
	match (Data.run(latest_sample), Data.index(index_sample)) {
		(Ok(run), Ok(entries)) => {
			page = View.history(run, entries, "tls")
			List.len(page.classes) == 2 and page.waiting
		}
		_ => Bool.False
	}

expect View.chosen(["smallest", "premium-4"], "premium-4", "smallest") == "premium-4"
expect View.chosen(["smallest", "dedicated-2"], "", View.default_class) == "dedicated-2"
expect View.chosen(["smallest", "premium-4"], "nope", View.default_class) == "smallest"
expect View.chosen([], "nope", View.default_class) == ""
expect View.chosen_section([{ name: "http1", label: "" }, { name: "tls", label: "" }], "") == "tls"
expect View.chosen_section([{ name: "http1", label: "" }, { name: "tls", label: "" }], "http1") == "http1"
expect {
	tabs = View.tabs([{ name: "a", label: "A" }, { name: "b", label: "B" }], "b", "tls", "/history")
	tabs.map(|t| t.href) == ["/history?class=a&protocol=tls", "/history?class=b&protocol=tls"] and tabs.map(|t| t.current) == [Bool.False, Bool.True]
}
expect {
	both = [{ name: "http1", label: "HTTP/1.1" }, { name: "tls", label: "HTTP/2 + TLS" }]
	tabs = View.section_tabs(both, "tls", "smallest", "/")
	actions_ok = tabs.map(|t| t.action) == ["window.history.replaceState(null, '', '/?class=smallest&protocol=http1'); @get('/race-classes?class=smallest&protocol=http1')", "window.history.replaceState(null, '', '/?class=smallest&protocol=tls'); @get('/race-classes?class=smallest&protocol=tls')"]
	actions_ok and tabs.map(|t| t.current) == [Bool.False, Bool.True] and View.section_tabs(List.take_first(both, 1), "http1", "a", "/").is_empty()
}
expect View.chosen_section([{ name: "http1", label: "" }], "tls") == "http1"

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
## other, and a name is never pushed by one far to its side (on the
## open-loop chart lines end at different rates). Placed from the highest
## end down;
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

expect vcpus(1) == "1 vCPU" and vcpus(4) == "4 vCPUs"
expect {
	at = |name, x, y| { competitor: name, x, y, drawn: Bool.True }
	# b is pushed under a; c is clear below; d, beside a, is not pushed.
	label_ys([at("b", 0.0, 100.0), at("a", 0.0, 95.0), at("c", 0.0, 200.0), at("d", 100.0, 96.0)])
		== [112.0, 99.0, 204.0, 100.0]
}

## A race's time on a chart's axis, under its day, only when another race
## shares the day (two "Oct 6" side by side said nothing).
axis_time : List(Data.Entry), Str -> Str
axis_time = |entries, stamp| {
	shared = entries.keep_if(|entry| day(entry.started_at) == day(stamp))
	if List.len(shared) > 1 clock(stamp) else ""
}

## "2026-10-06T13:58:49Z" is "13:58": the tool writes that one format.
clock : Str -> Str
clock = |stamp| Str.from_utf8_lossy(List.sublist(Str.to_utf8(stamp), { start: 11, len: 5 }))

expect clock("2026-10-06T13:58:49Z") == "13:58"

## "53 min · $0.45": how long the race took and what its droplets cost
## (the cost only when droplets ran).
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
## closed loop does (measured).
loader_limit_pct : F64
loader_limit_pct = 85.0

## A test's card: its route without the query (SSE's carries the signals)
## and its words, a mixed one's open loop, and the protocols of its
## variants.
workload_card : Pages.WorkloadSpecs, List(Pages.WorkloadSpecs) -> View.WorkloadCard
workload_card = |test, variants| {
	path =
		match test.path.split_first("?") {
			Ok({ before, after: _ }) => before
			Err(_) => test.path
		}
	mixed = test.kind == "mixed"
	rates = "${Format.thousands(test.lowest.to_f64())} to ${Format.thousands(test.highest.to_f64())} requests a second"
	open = if mixed "Open loop only: ${test.mix}; ${rates}, the same for every server, each climbing until it falls behind." else ""
	{
		title: test.title,
		route: if mixed path else "${test.method} ${path}",
		summary: test.summary,
		paragraphs: [test.detail, open].keep_if(|p| !p.is_empty()),
		protocols: variants.map(|w| protocol_label(w.protocol, w.http2)),
	}
}

## The variants by protocol, in the race page's order: each a row per way
## the loader sends them, with the tests sent that way (their HTTP/1.1
## variants' titles, the tests' own).
variant_groups : List(Pages.WorkloadSpecs) -> List(View.VariantGroup)
variant_groups = |specs| {
	test_title = |w|
		match specs.find_first(|t| t.name == w.test) {
			Ok(t) => t.title
			Err(_) => w.title
		}
	# `usual`: the protocol's label in a line, left out under its heading.
	group = |protocol, label, usual| {
		rows = specs
			.keep_if(|w| w.protocol == protocol)
			.fold([], |kept, w| {
				full = variant_line(w.protocol, w.http2, w.connections, w.streams, w.keepalive)
				shown = if List.first(full) == Ok(usual) full.drop_first(1) else full
				title = test_title(w)
				if kept.any(|r| r.line == shown) {
					kept.map(|r| if r.line == shown { line: r.line, titles: r.titles.append(title) } else r)
				} else {
					kept.append({ line: shown, titles: [title] })
				}
			})
			.map(|r| { line: r.line, tests: Str.join_with(r.titles, ", ") })
		{ label, intro: intro(protocol), rows }
	}
	[group("http1", "HTTP/1.1", "HTTP/1.1"), group("h2c", "HTTP/2 (h2c)", "HTTP/2 (h2c)"), group("tls", "HTTP/2 + TLS", "HTTP/2+TLS")].keep_if(|g| !g.rows.is_empty())
}

expect {
	spec = |name, test, kind, connections, keepalive| { name, test, kind, title: name, summary: "", method: "GET", path: "/sse?datastar=x", body_bytes: 0, connections, keepalive, http2: Bool.False, streams: 0, tls: Bool.False, protocol: "http1", detail: "", mix: "list 50%, article 50%", lowest: 250, highest: 32000 }
	h2 = |w, protocol, connections, streams| { ..w, protocol, connections, streams, http2: Bool.True, tls: protocol == "tls" }
	sse = spec("sse", "sse", "closed", 256, Bool.True)
	sse_tls = h2(spec("sse-tls", "sse", "closed", 256, Bool.True), "tls", 128, 2)
	churn = spec("churn", "churn", "closed", 64, Bool.False)
	churn_tls = { ..spec("churn-tls", "churn", "closed", 64, Bool.False), protocol: "tls", tls: Bool.True }
	conduit = spec("conduit", "conduit", "mixed", 256, Bool.True)
	conduit_tls = h2(spec("conduit-tls", "conduit", "mixed", 256, Bool.True), "tls", 128, 2)
	specs = [sse, churn, sse_tls, churn_tls, conduit, conduit_tls]
	card = workload_card(sse, [sse, sse_tls])
	open = workload_card(conduit, [conduit, conduit_tls])
	card.route == "GET /sse" and card.paragraphs == [] and card.protocols == ["HTTP/1.1", "HTTP/2+TLS"]
	and open.route == "/sse"
	and open.paragraphs == ["Open loop only: list 50%, article 50%; 250 to 32,000 requests a second, the same for every server, each climbing until it falls behind."]
	and variant_groups(specs).map(|g| g.rows) == [
		[{ line: ["256 connections"], tests: "sse, conduit" }, { line: ["64 one-shot connections"], tests: "churn" }],
		[{ line: ["128 connections × 2 streams"], tests: "sse, conduit" }, { line: ["HTTP/1.1+TLS", "64 one-shot connections"], tests: "churn" }],
	]
}

## The class's open-loop charts, a climb each: each mixed workload's, at
## rates the same for every server. (Runs before 2026-10-10 also hold
## templates' share ladder in their steps: the pages show only the newest
## run, so only those runs' data files show it.)
open_charts : Data.Run, Str -> List({ section : Str, chart : View.OpenChart })
open_charts = |run, class|
	run.race.workloads.keep_oks(|workload| {
		results = run.results.keep_if(|r| r.class == class and r.workload == workload.name and r.valid and !r.open_loop.is_empty())
		if workload.kind != "mixed" or results.is_empty() {
			Err(NoClimb)
		} else {
			shown = as_test(run.race.workloads, workload)
			Ok({ section: workload.protocol, chart: open_chart({ key: "open-${chart_key(workload)}", title: shown.title, summary: shown.summary, variant: workload_variant(workload), run: run.id, results, competitors: run.race.competitors }) })
		}
	})

## p99 against the offered rate, on a log axis: the slowest part's. (A
## switch to p50, p90, p99.9 and the mean was built and taken out; the
## charts all looked alike.)
open_chart : { key : Str, title : Str, summary : Str, variant : List(Str), run : Str, results : List(Data.Result), competitors : List(Str) } -> View.OpenChart
open_chart = |{ key, title, summary, variant, run, results, competitors }| {
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
	lines = spread_open(results.map(|r| open_line(r, x, y)))
	ticks_y = decades.map(|ms| { line_y: Format.one_decimal(y(ms)), text_y: Format.one_decimal(y(ms) + 4.0), label: ms_label(ms) })
	# The caption is one sentence on the load, as every strip's is: the
	# workload's own summary (it races only open loop); what is plotted is
	# the axis's note.
	measure = "p99 latency, the slowest request type's"
	loader_bound = lines.any(|l| l.dots.any(|dot| dot.hollow))
	legend = competitors.map(|c| { competitor: c, drawn: lines.any(|l| l.competitor == c) })
	{ key, title, caption: summary, variant, run, measure, lines, legend, ticks_x, ticks_y, loader_bound }
}

open_line : Data.Result, (F64 -> F64), (F64 -> F64) -> View.DraftOpenLine
open_line = |result, x, y| {
	points = result.open_loop.map(|s| { s, px: x(s.offered_rps), py: y(s.p99_ms) })
	path = Str.join_with(points.map_with_index(|p, i| "${if i == 0 "M" else "L"}${Format.one_decimal(p.px)} ${Format.one_decimal(p.py)}"), " ")
	dots = points.map(|p| {
		cx: Format.one_decimal(p.px),
		cy: Format.one_decimal(p.py),
		hollow: p.s.loader_cpu_busy_pct >= loader_limit_pct,
		title: step_title(result.competitor, p.s),
	})
	{ last_x, last_y } =
		match List.last(points) {
			Ok(p) => { last_x: p.px, last_y: p.py }
			Err(_) => { last_x: 0.0, last_y: 0.0 }
		}
	{ competitor: result.competitor, path, dots, label_x: Format.one_decimal(last_x + 10.0), label_y: Format.one_decimal(last_y + 4.0), end_x: last_x, end_y: last_y }
}

step_title : Str, Data.OpenStep -> Str
step_title = |competitor, s| {
	limit = if s.loader_cpu_busy_pct >= loader_limit_pct " (the loader was the limit)" else ""
	rates = "${Format.thousands(s.offered_rps)}/s offered, ${Format.thousands(s.achieved_rps)}/s answered"
	cpu = "server CPU ${Format.thousands(s.cpu_busy_pct)}%, loader ${Format.thousands(s.loader_cpu_busy_pct)}%${limit}"
	"${competitor}: ${rates}; the slowest part's p99 ${Format.latency(s.p99_ms)} ms, p99.9 ${Format.latency(s.p999_ms)} ms; ${cpu}"
}

## The open chart's labels, spread as the history charts' are.
spread_open : List(View.DraftOpenLine) -> List(View.OpenLine)
spread_open = |lines| {
	ys = label_ys(lines.map(|l| { competitor: l.competitor, x: l.end_x, y: l.end_y, drawn: Bool.True }))
	List.map2(lines, ys, |l, y| { competitor: l.competitor, path: l.path, dots: l.dots, label_x: l.label_x, label_y: Format.one_decimal(y) })
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

## Roc's F64 has no logarithm, so it is computed: the decades counted,
## then ln of what is left by its atanh series (a few dozen flops, error
## below 1e-10). Bisection on F64.pow did it before, 40 calls a value:
## 33% of the race page's instructions. For positive values
## between 10^-40 and 10^40.
log10 : F64 -> F64
log10 = |value| {
	# value = m * 10^k, m in [1, 10).
	var $m = value
	var $k = 0.0
	for _ in 0..<40.U64 {
		$k = if $m >= 10.0 $k + 1.0 else if $m < 1.0 $k - 1.0 else $k
		$m = if $m >= 10.0 $m / 10.0 else if $m < 1.0 $m * 10.0 else $m
	}
	# Half a decade out (r in [1, sqrt 10)), then ln r = 2 atanh((r-1)/(r+1)),
	# whose series in s^2 <= 0.27 is below 1e-10 after 16 terms.
	root10 = 3.1622776601683795
	half = if $m > root10 0.5 else 0.0
	r = if $m > root10 $m / root10 else $m
	s = (r - 1.0) / (r + 1.0)
	var $term = s
	var $odd = 1.0
	var $sum = 0.0
	for _ in 0..<16.U64 {
		$sum = $sum + $term / $odd
		$term = $term * s * s
		$odd = $odd + 2.0
	}
	$k + half + 2.0 * $sum / 2.302585092994046
}

ms_label : F64 -> Str
## No space before the unit: on a phone the axis text is 20px and "100 ms"
## runs past the chart's left edge; five characters fit.
ms_label = |ms| if ms < 1.0 "0.1ms" else if ms >= 1000.0 "${Format.thousands(ms / 1000.0)}s" else "${Format.thousands(ms)}ms"

expect decades_between(2.2, 1903.0) == [1.0, 10.0, 100.0, 1000.0, 10000.0]
expect decades_between(1.5, 1.6) == [1.0, 10.0]
expect ms_label(0.1) == "0.1ms" and ms_label(100.0) == "100ms" and ms_label(1000.0) == "1s" and ms_label(10000.0) == "10s"
expect took({ seconds: 3180.0, cost_usd: 0.4512 }) == "took 53 min · $0.45"
expect took({ seconds: 600.0, cost_usd: 0.0 }) == "took 10 min"
expect F64.abs(log10(1000.0) - 3.0) < 0.000001 and F64.abs(log10(0.1) + 1.0) < 0.000001 and F64.abs(log10(2.0) - 0.30103) < 0.00001
expect F64.abs(log10(7.0) - 0.8450980400142568) < 0.0000000001 and F64.abs(log10(123456.0) - 5.091512201627772) < 0.0000000001

## What limited a result, from its fastest round (the bar's): the server's
## CPU, the loader's, the network. At least 90% busy is a CPU at its limit; at
## least 1,400 Mbit/s either way is the network's, 70% of the 2 Gbit/s
## DigitalOcean documents for these droplets (where retransmits began).
## None of them: the closed loop's connections and their
## round trips were the limit (the server was under-driven).
limits : Data.Result -> List(Str)
limits = |result| {
	r = best_round(result)
	cpu = r.cpu_busy_pct
	loader = r.loader_cpu_busy_pct
	net = if r.net_rx_mbps > r.net_tx_mbps r.net_rx_mbps else r.net_tx_mbps
	drops = if r.rps > 0.0 and r.load_seconds > 0.0 r.tcp_retransmits / (r.rps * r.load_seconds) else 0.0
	# A link enforcing its limit drops packets: a gigabit and more with a
	# retransmit every hundred requests is the link (1.3 Gbit/s and 45,000
	# retransmits a round gave a p99 of 205 ms), as is 1.4 Gbit/s alone.
	at_link = net >= network_limit_mbps or (net >= 1000.0 and drops >= 0.01)
	List.concat(
		List.concat(if cpu >= cpu_limit_pct ["server CPU"] else [], if loader >= cpu_limit_pct ["loader"] else []),
		if at_link ["network"] else [],
	)
}

limited_by : Data.Result -> Str
limited_by = |result| {
	found = limits(result)
	if found.is_empty() "connections (nothing saturated)" else Str.join_with(found, ", ")
}

cpu_limit_pct : F64
cpu_limit_pct = 90.0

network_limit_mbps : F64
network_limit_mbps = 1400.0

expect {
	round = |cpu, loader, net| { rps: 1.0, p99_ms: 1.0, cpu_busy_pct: cpu, steal_pct: 0.0, rss_kib: 0.0, loader_cpu_busy_pct: loader, net_rx_mbps: net, net_tx_mbps: 0.0, tcp_retransmits: 0.0, load_seconds: 20.0 }
	result = |rounds| { class: "c", workload: "w", competitor: "x", valid: Bool.True, note: "", rounds, best_rps: 1.0, median_p95_ms: 0.0, median_p99_ms: 0.0, median_p999_ms: 0.0, open_loop: [] }
	limited_by(result([round(99.0, 98.0, 240.0)])) == "server CPU, loader"
	and limited_by(result([round(88.0, 64.0, 1510.0)])) == "network"
	and limited_by(result([round(64.0, 52.0, 190.0)])) == "connections (nothing saturated)"
	and !saturated(result([round(64.0, 52.0, 190.0)]))
}

## A whisker narrower than this share of the strip's top bar is a few
## pixels: it reads as a blot on the bar's tip, not a range, so it is
## not drawn; the rounds agreed.
whisker_share_min : F64
whisker_share_min = 0.02

## Whether the server ran out of CPU, the case the race is for. A bar that
## did not is drawn as an outline ("server not saturated"): the loader, the
## network or too few connections set it, and the table says which. A
## server at its CPU's limit that also met the network is saturated.
saturated : Data.Result -> Bool
saturated = |result| limits(result).any(|limit| limit == "server CPU")

## The slowest and the fastest round.
round_range : Data.Result -> { slowest : F64, fastest : F64 }
round_range = |result| {
	rates = result.rounds.map(|r| r.rps)
	fastest = rates.fold(result.best_rps, |best, rate| if rate > best rate else best)
	slowest = rates.fold(fastest, |low, rate| if rate < low rate else low)
	{ slowest, fastest }
}

## How far the slowest round fell below the best, as a share of the best:
## the noise the best of the rounds leaves out.
spread_pct : Data.Result -> F64
spread_pct = |result| {
	{ slowest, fastest } = round_range(result)
	if fastest <= 0.0 0.0 else 100.0 * (fastest - slowest) / fastest
}

expect {
	at = |net, retransmits| { rps: 35000.0, p99_ms: 200.0, cpu_busy_pct: 93.0, steal_pct: 0.0, rss_kib: 0.0, loader_cpu_busy_pct: 26.0, net_rx_mbps: net, net_tx_mbps: 0.0, tcp_retransmits: retransmits, load_seconds: 20.0 }
	result = |rounds| { class: "c", workload: "w", competitor: "x", valid: Bool.True, note: "", rounds, best_rps: 35000.0, median_p95_ms: 0.0, median_p99_ms: 0.0, median_p999_ms: 0.0, open_loop: [] }
	limited_by(result([at(1322.0, 47363.0)])) == "server CPU, network"
	and saturated(result([at(1322.0, 47363.0)]))
	and limited_by(result([at(1322.0, 100.0)])) == "server CPU"
}

## A machine's memory as the kernel has it, "457 MiB" or "3.8 GiB";
## nothing for a run from before it was recorded (0).
memory : U32 -> List(Str)
memory = |mib|
	if mib == 0 {
		[]
	} else if mib < 1024 {
		["${mib.to_str()} MiB"]
	} else {
		["${Format.one_decimal(mib.to_f64() / 1024.0)} GiB"]
	}

expect memory(0) == [] and memory(457) == ["457 MiB"] and memory(3916) == ["3.8 GiB"]

expect View.clock(0.0) == "00:00" and View.clock(1.0) == "00:01" and View.clock(60.0) == "00:01"
expect View.clock(61.0) == "00:02" and View.clock(4320.0) == "01:12" and View.clock(36000.0) == "10:00"

## A class of a racing run as Live.classes reads it: racing step `step` of
## `steps`, a round of roux's, 30 s into its 120 s estimate.
live_class : Str, I64, I64 -> Live.Classes
live_class = |class, steps, step| {
	class,
	label: class,
	status: "racing",
	reason: "",
	elapsed_seconds: 2520.0,
	steps,
	step,
	competitor: "roux",
	round: 1,
	rounds: 3,
	workload: "",
	step_seconds: 30.0,
	step_estimate: 120.0,
	left_seconds: 400.0,
}

expect {
	b = { ..live_class("b", 3, 3), competitor: "go", round: 0, workload: "RealWorld (Conduit)", step_seconds: 700.0, step_estimate: 600.0, left_seconds: 0.0 }
	banner = View.live_banner([live_class("a", 4, 2), b, { ..live_class("c", 4, 0), left_seconds: 600.0 }], Bool.True)
	when = |l| { now: l.now, soon: l.soon, count: l.count, left: l.left, from: l.from, seconds: l.seconds, late: l.late }
	banner.done == "3"
	and banner.lanes.map(when) == [
		{ now: "roux · round 1 of 3", soon: "result in about 2 min", count: "step 2 of 4", left: "about 00:07 left", from: "0.25", seconds: "90", late: Bool.False },
		{ now: "go · RealWorld (Conduit) ladder", soon: "running 2 min long", count: "step 3 of 3", left: "running long", from: "1.00", seconds: "0", late: Bool.True },
		{ now: "readying the server and the loader", soon: "", count: "0 of 4 steps", left: "about 00:10 left", from: "0.00", seconds: "0", late: Bool.False },
	]
	and banner.lanes.map(|l| l.track) == [["done", "now", "next", "next"], ["done", "done", "now"], ["next", "next", "next", "next"]]
	and banner.lanes.map(|l| l.stepping) == [Bool.True, Bool.True, Bool.False]
	and banner.lanes.map(|l| l.fill) == ["a-2-30", "b-3-700", "c-0-30"]
}

expect {
	no_plan = live_class("a", 0, 0)
	done = { ..live_class("b", 4, 4), status: "done", elapsed_seconds: 6720.0 }
	failed = { ..live_class("c", 4, 2), status: "failed", reason: "the server went away" }
	banner = View.live_banner([no_plan, done, failed], Bool.False)
	when = |l| { now: l.now, count: l.count, left: l.left, stepping: l.stepping, failed: l.failed, track: l.track }
	banner.done == "5"
	and banner.lanes.map(when) == [
		{ now: "racing", count: "", left: "00:42 elapsed", stepping: Bool.False, failed: Bool.False, track: [] },
		{ now: "every step raced", count: "4 of 4 steps", left: "done in 01:52", stepping: Bool.False, failed: Bool.False, track: ["done", "done", "done", "done"] },
		{ now: "failed: the server went away", count: "1 of 4 steps", left: "failed at 00:42", stepping: Bool.False, failed: Bool.True, track: ["done", "bad", "next", "next"] },
	]
}

expect View.in_minutes(59.0) == "in under a minute" and View.in_minutes(61.0) == "in about 2 min" and View.whole_minutes(120.0) == "2 min"
