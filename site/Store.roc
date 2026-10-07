import pf.Server
import pf.Sqlite
import db/Pages
import db/Heads
import db/Requests
import Data

## The races as the pages model them (Data.roc), read from the database:
## a run whole for the race page, every run's medians for the history,
## and what the racer is doing for the line above them.
Store :: [].{
	## The newest finished run, or `NotFound` before the first.
	latest! : Sqlite.Db, Server.Request => Try(Data.Run, [NotFound, DbErr(Sqlite.Err)])
	latest! = |db, request| {
		reads = Sqlite.read(db, request)
		{ id } = Pages.latest!(reads)?
		run!(reads, id)
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
				workloads: workloads.map(|w| { name: w.name, title: w.title, summary: w.summary }),
				cloud: { servers: classes.map(|c| { name: c.name, label: c.label, title: c.title }) },
			},
			machines: machines.map(|m| {
				role: m.role,
				class: m.class,
				size: m.size,
				cpu: m.cpu,
				cpus: m.cpus.to_u32_try() ?? 0,
				kernel: m.kernel,
				cpu_wanted: m.cpu_wanted,
				cpu_matched: m.cpu_matched,
				attempts: m.attempts.to_u32_try() ?? 0,
			}),
			results: results.map(|r| {
				same = |x| x.class == r.class and x.workload == r.workload and x.competitor == r.competitor
				{
					class: r.class,
					workload: r.workload,
					competitor: r.competitor,
					valid: r.valid,
					note: r.note,
					rounds: rounds.keep_if(same).map(|x| {
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
					median_rps: r.median_rps,
					median_p95_ms: r.median_p95_ms,
					median_p99_ms: r.median_p99_ms,
					median_p999_ms: r.median_p999_ms,
					open_loop: steps.keep_if(same).map(|x| {
						share: x.share,
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

	## Every finished run's medians, oldest first (Data.Entry), from rows
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
			$results = $results.append({ class: row.class, workload: row.workload, competitor: row.competitor, valid: row.valid, median_rps: row.median_rps })
		}
		if $id.is_empty() $entries else $entries.append({ id: $id, started_at: $started_at, results: $results })
	}

	## What the racer is doing, for the race page.
	Racer : {
		## The newest run of any status, if any.
		recent : List(Pages.Recent),
		## The classes of the newest run, while it races.
		classes : List(Pages.ClassStatus),
		## Results the newest run holds so far.
		results : I64,
		waiting : List(Requests.Waiting),
		heads : List(Heads.All),
		## The commits of the newest finished run.
		raced : List(Pages.Commits),
	}

	racer! : Sqlite.Db, Server.Request => Try(Racer, [DbErr(Sqlite.Err)])
	racer! = |db, request| {
		reads = Sqlite.read(db, request)
		recent = Pages.recent!(reads)?
		{ classes, results } =
			match recent.first() {
				Ok(newest) => {
					count =
						match Pages.result_count!(reads, { run_id: newest.id }) {
							Ok(row) => row.results
							Err(NotFound) => 0
							Err(DbErr(err)) => return Err(DbErr(err))
						}
					{ classes: Pages.class_status!(reads, { run_id: newest.id })?, results: count }
				}
				Err(_) => { classes: [], results: 0 }
			}
		raced =
			match Pages.latest!(reads) {
				Ok({ id }) => Pages.commits!(reads, { run_id: id })?
				Err(NotFound) => []
				Err(DbErr(err)) => return Err(DbErr(err))
			}
		Ok({
			recent,
			classes,
			results,
			waiting: Requests.waiting!(reads)?,
			heads: Heads.all!(reads)?,
			raced,
		})
	}
}

expect {
	row = |id, competitor| { id, started_at: "t-${id}", class: "c", workload: "w", competitor, valid: Bool.True, median_rps: 1.0 }
	entries = Store.entries_of([row("a", "go"), row("a", "roux"), row("b", "go")])
	entries.len() == 2 and entries.map(|e| e.results.len()) == [2, 1] and entries.map(|e| e.id) == ["a", "b"]
}

expect Store.entries_of([]).is_empty()
