import pf.Server
import pf.Sqlite
import db/Pages
import db/Heads
import db/Requests
import db/Live
import Data

## The races as the pages model them (Data.roc), read from the database:
## a run whole for the race page, every run's best rounds for the history,
## and what the racer is doing for the line above them.
Store :: [].{
	## The newest finished run, or `NotFound` before the first.
	latest! : Sqlite.Db, Server.Request => Try(Data.Run, [NotFound, DbErr(Sqlite.Err)])
	latest! = |db, request| {
		reads = Sqlite.read(db, request)
		{ id } = Pages.latest!(reads)?
		run!(reads, id)
	}

	## What the newest finished run asked of each workload, and its rounds:
	## the Workloads page. `NotFound` before the first race.
	workloads! : Sqlite.Db, Server.Request => Try({ specs : List(Pages.WorkloadSpecs), settings : Pages.RaceSettings }, [NotFound, DbErr(Sqlite.Err)])
	workloads! = |db, request| {
		reads = Sqlite.read(db, request)
		{ id } = Pages.latest!(reads)?
		key = { run_id: id }
		Ok({ specs: Pages.workload_specs!(reads, key)?, settings: Pages.race_settings!(reads, key)? })
	}

	## One run, as Data.Run.
	run! : Sqlite.Read, Str => Try(Data.Run, [NotFound, DbErr(Sqlite.Err)])
	run! = |reads, id| {
		row = Pages.run!(reads, { id: id })?
		key = { run_id: id }
		commits = Pages.commits!(reads, key)?
		versions = Pages.versions!(reads, key)?
		competitors = Pages.competitors!(reads, key)?
		workloads = Pages.workloads!(reads, key)?
		classes = Pages.classes!(reads, key)?
		machines = Pages.machines!(reads, key)?
		results = Pages.results!(reads, key)?
		rounds = Pages.rounds!(reads, key)?
		steps = Pages.steps!(reads, key)?
		commit_of = |repository| commits.find_first(|c| c.repository == repository).map_ok(|c| c.commit_sha) ?? ""
		version_of = |name| versions.find_first(|v| v.name == name).map_ok(|v| v.version) ?? ""
		pinned = |name| { version: version_of(name) }
		Ok({
			id: row.id,
			started_at: row.started_at,
			fingerprint: { dragrace: commit_of("fourneau-dragrace"), fourneau: commit_of("fourneau"), roux: commit_of("roux") },
			versions: {
				fourneau: { repository: "https://github.com/Eldhus/fourneau" },
				roux: { repository: "https://github.com/Eldhus/roux" },
				zig: pinned("zig"),
				roc: pinned("roc"),
				oha: pinned("oha"),
				go: pinned("go"),
				rust: pinned("rust"),
				axum: pinned("axum"),
				tokio: pinned("tokio"),
				droplet_image: version_of("droplet_image"),
			},
			race: {
				competitors: competitors.map(|c| c.name),
				workloads: workloads.map(|w| { name: w.name, test: w.test, kind: w.kind, title: w.title, summary: w.summary, protocol: w.protocol, connections: w.connections, streams: w.streams, keepalive: w.keepalive, http2: w.http2, tls: w.tls }),
				cloud: { servers: classes.map(|c| { name: c.name, label: c.label, title: c.title }) },
			},
			machines: machines.map(|m| {
				role: m.role,
				class: m.class,
				size: m.size,
				cpu: m.cpu,
				cpus: m.cpus.to_u32_try() ?? 0,
				kernel: m.kernel,
				memory_mib: m.memory_mib.to_u32_try() ?? 0,
			}),
			results: results.map(|r| {
				same = |x| x.class == r.class and x.workload == r.workload and x.competitor == r.competitor
				own = rounds.keep_if(same)
				# A round that answered nothing has no latency.
				answered = own.keep_if(|x| x.rps > 0.0)
				{
					class: r.class,
					workload: r.workload,
					competitor: r.competitor,
					valid: r.valid,
					note: r.note,
					rounds: own.map(|x| {
						rps: x.rps,
						p99_ms: x.p99_ms,
						cpu_busy_pct: x.cpu_busy_pct,
						steal_pct: x.steal_pct,
						rss_kib: x.rss_kib,
						loader_cpu_busy_pct: x.loader_cpu_busy_pct,
						net_rx_mbps: x.net_rx_mbps,
						net_tx_mbps: x.net_tx_mbps,
						tcp_retransmits: x.tcp_retransmits,
						load_seconds: x.load_seconds,
					}),
					best_rps: own.fold(0.0, |most, x| if x.rps > most x.rps else most),
					median_p95_ms: median(answered.map(|x| x.p95_ms)),
					median_p99_ms: median(answered.map(|x| x.p99_ms)),
					median_p999_ms: median(answered.map(|x| x.p999_ms)),
					open_loop: steps.keep_if(same).map(|x| {
						offered_rps: x.offered_rps,
						achieved_rps: x.achieved_rps,
						p99_ms: x.p99_ms,
						p999_ms: x.p999_ms,
						cpu_busy_pct: x.cpu_busy_pct,
						loader_cpu_busy_pct: x.loader_cpu_busy_pct,
					}),
				}
			}),
			timing: { seconds: row.seconds, cost_usd: row.cost_usd },
		})
	}

	## The middle of the values (the mean of the two middle ones for an even
	## count), 0 for none: a latency percentile across rounds, one round's
	## luck or one round's neighbour left out either way (Data.Result).
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

	## Every finished run's best rounds, oldest first (Data.Entry), from rows
	## ordered by run.
	history! : Sqlite.Db, Server.Request => Try(List(Data.Entry), [DbErr(Sqlite.Err)])
	history! = |db, request| {
		rows = Pages.history!(Sqlite.read(db, request))?
		Ok(entries_of(rows))
	}

	entries_of : List(Pages.History) -> List(Data.Entry)
	entries_of = |rows| {
		var $entries = []
		var $id = ""
		var $started_at = ""
		var $results = []
		for row in rows {
			if row.id != $id {
				if !$id.is_empty() {
					$entries = $entries.append({ id: $id, started_at: $started_at, results: $results })
				}
				$id = row.id
				$started_at = row.started_at
				$results = []
			}
			$results = $results.append({ class: row.class, workload: row.workload, competitor: row.competitor, valid: row.valid, best_rps: row.best_rps })
		}
		if $id.is_empty() $entries else $entries.append({ id: $id, started_at: $started_at, results: $results })
	}

	## What the racer is doing, for the race page.
	Racer : {
		## The newest run of any status, if any.
		recent : List(Pages.Recent),
		waiting : List(Requests.Waiting),
		heads : List(Heads.All),
		## The commits of the newest finished run.
		raced : List(Pages.Commits),
	}

	## What the race page says of the racer, a banner each: what tonight's
	## check will do, what was asked, what the last run that did not finish
	## said (a run racing is the live banner's, live!). `items` are the
	## banner's parts that must not break inside (a repository and its
	## commit), apart from the sentence. `countdown`
	## ends the banner with the time left to push (demo.js counts it).
	Banner : { text : Str, items : List(Str), countdown : Bool }

	status : Racer -> List(Banner)
	status = |racer| {
		newest = racer.recent.first()
		said = |text| { text, items: [], countdown: Bool.False }
		racing =
			match newest {
				Ok(run) => run.status == "racing"
				Err(_) => Bool.False
			}
		new = racer.heads.keep_if(|head| !racer.raced.any(|c| c.repository == head.repository and c.commit_sha == head.commit_sha))
		# While a run races, the heads it races are the news; tonight's
		# check is said again once it is over.
		tonight =
			if racer.heads.is_empty() or racing {
				[]
			} else if new.is_empty() {
				[{ ..said(nothing_new), countdown: Bool.True }]
			} else {
				# Not the hour: the racer's timer holds it, and the site has no
				# copy to go stale.
				[{ ..said("Racing tonight"), items: new.map(|head| "${head.repository} ${short(head.commit_sha)}") }]
			}
		asked = if racer.waiting.any(|w| w.kind == "race") [said("A race is asked for: the racer takes it once idle, within a minute; a race takes about two and a half hours.")] else []
		last =
			match newest {
				Ok(run) if run.status != "racing" and run.status != "finished" => {
					why = if run.reason.is_empty() "" else ": ${run.reason}"
					[said("The last run, ${run.id}, was ${run.status}${why}.")]
				}
				_ => []
			}
		asked.concat(tonight).concat(last)
	}

	## The racer judges from its newest build, and fourneau's and roux's
	## new commits reach a build at the latest with the daily one
	## (build.yml, 07:47 UTC). The countdown ends at 07:30 UTC: a scheduled
	## run starts late, never early, so a push by then is in it.
	nothing_new : Str
	nothing_new = "Quiet night on the track: nothing new to race. Got something faster? Push it to fourneau or roux"

	## The run racing now, as the race page's live banner shows it: its newest results, and each class's progress
	## and seconds left (db/Live.sql says how they are estimated).
	LiveRun : { id : Str, newest : List(Live.Newest), classes : List(Live.Progress) }

	live! : Sqlite.Db, Server.Request => Try([Racing(LiveRun), Idle], [DbErr(Sqlite.Err)])
	live! = |db, request| {
		reads = Sqlite.read(db, request)
		match Live.racing!(reads) {
			Ok({ id, .. }) => {
				key = { run_id: id }
				Ok(Racing({ id, newest: Live.newest!(reads, key)?, classes: Live.progress!(reads, key)? }))
			}
			Err(NotFound) => Ok(Idle)
			Err(DbErr(err)) => Err(DbErr(err))
		}
	}

	short : Str -> Str
	short = |sha| Str.from_utf8(Str.to_utf8(sha).take_first(7)) ?? sha

	racer! : Sqlite.Db, Server.Request => Try(Racer, [DbErr(Sqlite.Err)])
	racer! = |db, request| {
		reads = Sqlite.read(db, request)
		recent = Pages.recent!(reads)?
		raced =
			match Pages.latest!(reads) {
				Ok({ id }) => Pages.commits!(reads, { run_id: id })?
				Err(NotFound) => []
				Err(DbErr(err)) => return Err(DbErr(err))
			}
		Ok({
			recent,
			waiting: Requests.waiting!(reads)?,
			heads: Heads.all!(reads)?,
			raced,
		})
	}
}

expect {
	row = |id, competitor| { id, started_at: "t-${id}", class: "c", workload: "w", competitor, valid: Bool.True, best_rps: 1.0 }
	entries = Store.entries_of([row("a", "go"), row("a", "roux"), row("b", "go")])
	entries.len() == 2 and entries.map(|e| e.results.len()) == [2, 1] and entries.map(|e| e.id) == ["a", "b"]
}

expect Store.entries_of([]).is_empty()

expect Store.median([3.0, 1.0, 2.0]) == 2.0
expect Store.median([4.0, 1.0, 3.0, 2.0]) == 2.5
expect Store.median([]) == 0.0
# Three real rounds: the odd round out is left out.
expect Store.median([20.73, 20.40, 13.45]) == 20.40

expect {
	head = |repository, commit_sha| { repository, commit_sha, seen_at: "" }
	raced = |repository, commit_sha| { repository, commit_sha, new: Bool.False }
	quiet = { recent: [], waiting: [], heads: [head("roux", "abc1234567")], raced: [raced("roux", "abc1234567")] }
	busy = { ..quiet, heads: [head("roux", "def1234567"), head("fourneau", "aaa")], raced: [raced("roux", "abc1234567"), raced("fourneau", "aaa")] }
	Store.status(quiet) == [{ text: Store.nothing_new, items: [], countdown: Bool.True }]
	and Store.status(busy) == [{ text: "Racing tonight", items: ["roux def1234"], countdown: Bool.False }]
}

expect {
	run = |status, reason| { id: "r1", trigger: "timer", status, reason, started_at: "", finished_at: Null }
	racing = { recent: [run("racing", "")], waiting: [], heads: [], raced: [] }
	skipped = { ..racing, recent: [run("skipped", "nothing new")] }
	# A run racing is the live banner's; tonight's news waits for its end.
	Store.status(racing) == []
	and Store.status({ ..racing, heads: [{ repository: "roux", commit_sha: "abc", seen_at: "" }] }) == []
	and Store.status(skipped) == [{ text: "The last run, r1, was skipped: nothing new.", items: [], countdown: Bool.False }]
}
