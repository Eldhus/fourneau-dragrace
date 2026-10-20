import Conduit
import Config
import JsonValue
import Machine
import Oha
import Results
import Run
import Snapshot
import Target
import Text

## A mixed workload (conduit): reads and writes at once against a database,
## open loop only. A ladder of fixed total rates, the same for every
## competitor, each offered as its parts at their shares, one oha a part,
## all at once. A competitor climbs until it falls behind (answers under
## `saturated` of the rate offered, or errors). Latency is counted from
## when each request was due (oha -q, --latency-correction): a server that
## stalls is sent no less, so its stall shows. Steps rather than a ramp: a
## ramp never holds a rate long enough for its percentiles to mean it.
Mixed :: [].{
	## Check the competitor against the contract, then climb from the seed
	## again; a competitor that fails the checks has no steps and says why
	## (`why`). A climb cut short keeps its steps and says what stopped it
	## (`stopped`, "" for a climb that ended as it should).
	climb! : Config.Race, Config.Workload, Config.Mixed, Config.Competitor, Target.Where, Conduit.Model => Try({ steps : List(Results.Step), why : Str, stopped : Str }, [Failed(Str), Interrupted])
	climb! = |race, workload, mixed, competitor, target, model| {
		mode = Target.mode_of(workload)
		checked = Target.start!(race, competitor, target, mode)?
		check =
			match Target.ready!(race, target, mode) {
				Ok({}) => Mixed.validate!(race, target, mode, model)
				Err(Interrupted) => {
					Target.stop!(target, checked)
					return Err(Interrupted)
				}
				Err(Failed(_)) => "did not start: ${Target.why_not_ready!(competitor, target, checked)}"
			}
		Target.stop!(target, checked)
		if check != "" {
			return Ok({ steps: [], why: check, stopped: "" })
		}
		# The checks wrote: the climb starts from the seed again.
		pid = Target.start!(race, competitor, target, mode)?
		climbed =
			match Target.ready!(race, target, mode) {
				Ok({}) => climb_rates!(race, workload, mixed, target, pid)
				Err(Interrupted) => Err(Interrupted)
				Err(Failed(_)) => Ok({ steps: [], why: "did not start again: ${Target.why_not_ready!(competitor, target, pid)}", failure: "" })
			}
		Target.stop!(target, pid)
		climbed.map_ok(|{ steps, why, failure }| { steps, why, stopped: failure })
	}

	## The checks of the contract, from the loader, on the seeded database:
	## "" when the competitor answers as the model says.
	validate! : Config.Race, Target.Where, Target.Mode, Conduit.Model => Str
	validate! = |race, target, mode, model| {
		url = Target.base_url(race, target, mode)
		token = (model.users.get(Conduit.load_user) ?? { id: 0, username: "", bio: "", image: "", token: "" }).token
		curl = Target.curl(mode, "10")
		free = Conduit.unfavorited(model)
		free_article = model.articles.get(free) ?? { id: free, slug: "", title: "", description: "", body: "", author: 0, created: "", tags: [], favorites: [] }
		favorite =
			Conduit.article(model, free, Bool.True)
				.with_member("favorited", Boolean(Bool.True))
				.with_member("favoritesCount", Number((free_article.favorites.len() + 1).to_f64()))
		answer = "-w '\\n%{http_code} %{content_type}'"
		checks = [
			{ name: "the list", script: "${curl}${answer} '${url}/api/articles?limit=20&offset=40'", status: "200", want: Same(Conduit.list(model, 20, 40)) },
			{ name: "an article", script: "${curl}${answer} ${url}/api/articles/article-0123", status: "200", want: Same(Object([("article", Conduit.article(model, 123, Bool.True))])) },
			{ name: "a missing article", script: "${curl}-o /dev/null -w '\\n%{http_code} -' ${url}/api/articles/article-9999", status: "404", want: Nothing },
			{ name: "a comment without a token", script: "${curl}-o /dev/null -w '\\n%{http_code} -' -X POST -H 'Content-Type: application/json' -d '{\"comment\":{\"body\":\"x\"}}' ${url}/api/articles/article-0001/comments", status: "401", want: Nothing },
			{ name: "a comment", script: "${curl}${answer} -X POST -H 'Authorization: Token ${token}' -H 'Content-Type: application/json' -d '{\"comment\":{\"body\":\"Lovely roux.\"}}' ${url}/api/articles/article-0001/comments", status: "200", want: Comment },
			{ name: "a favorite", script: "${curl}${answer} -X POST -H 'Authorization: Token ${token}' ${url}/api/articles/${free_article.slug}/favorite", status: "200", want: Same(Object([("article", favorite)])) },
		]
		for check in checks {
			output =
				match Machine.shell!(target.loader, check.script) {
					Ok(text) => text
					Err(Failed(why)) => return "${check.name}: ${why}"
					Err(Interrupted) => return "${check.name}: interrupted"
				}
			{ body, tail } =
				match output.split_last("\n") {
					Ok({ before, after }) => { body: before, tail: after }
					Err(_) => { body: "", tail: output }
				}
			{ status, content_type } =
				match tail.split_first(" ") {
					Ok({ before, after }) => { status: before, content_type: after }
					Err(_) => { status: tail, content_type: "" }
				}
			if status != check.status {
				return "${check.name}: ${status}, not ${check.status}"
			}
			why =
				match check.want {
					Nothing => ""
					_ if !content_type.starts_with("application/json") => "Content-Type ${Str.inspect(content_type)}, not application/json"
					Same(want) =>
						match JsonValue.parse(body) {
							Ok(got) => JsonValue.difference(got, want, "")
							Err(_) => "not JSON: ${Text.take(body, 80)}"
						}
					Comment =>
						match JsonValue.parse(body) {
							Ok(got) => comment_difference(got, model)
							Err(_) => "not JSON: ${Text.take(body, 80)}"
						}
				}
			if why != "" {
				return "${check.name}: ${why}"
			}
		}
		""
	}

	## A step from its parts: the rates add, the mean is over every request
	## (each part's weighted by its answers); a step's percentiles are the
	## worst part's, as a percentile of the whole cannot be had from parts.
	step : U64, List(Results.Part) -> Results.Step
	step = |rate, parts| {
		achieved = parts.map(|p| p.achieved_rps).sum()
		weighted = parts.map(|p| p.mean_ms * p.achieved_rps).sum()
		worst = |field| parts.fold(0.0, |most, p| if field(p) > most field(p) else most)
		{
			offered_rps: rate.to_f64(),
			achieved_rps: achieved,
			p50_ms: worst(|p| p.p50_ms),
			p99_ms: worst(|p| p.p99_ms),
			p999_ms: worst(|p| p.p999_ms),
			errors: parts.map(|p| p.errors).sum(),
			non_2xx: parts.map(|p| p.non_2xx).sum(),
			cpu_busy_pct: 0,
			loader_cpu_busy_pct: 0,
			net_rx_mbps: 0,
			net_tx_mbps: 0,
			mean_ms: if achieved > 0 weighted / achieved else 0,
			parts,
		}
	}

	## One part's oha: open loop at its rate, its connections and threads its
	## share of the workload's.
	part_command : Config.Race, Config.Workload, Target.Where, Config.Part, Str, U64, U64 -> Str
	part_command = |race, workload, target, part, token, rate, seconds| {
		connections = ceiling(part.share * workload.connections.to_f64()).max(8)
		threads =
			if target.loader_threads > 0 {
				" --worker-threads ${ceiling(part.share * target.loader_threads.to_f64()).max(1).to_str()}"
			} else {
				""
			}
		method = if part.method != "GET" " -m ${part.method}" else ""
		auth = if part.auth " -H ${Run.quote("Authorization: Token ${token}")}" else ""
		body = if part.body != "" " -d ${Run.quote(part.body)} -T application/json" else ""
		http2 = if workload.http2 " --http2 -p ${workload.streams.max(1).to_str()}" else ""
		tls = if workload.tls " --insecure" else ""
		# rand_regex: the base URL's dots are written as [.], so only the path varies.
		base = Target.base_url(race, target, Target.mode_of(workload)).replace_each(".", "[.]")
		"ulimit -n $(ulimit -Hn); ${Target.taskset(target.loader_cpus)}${Run.quote(target.loader_home)}/oha -z ${seconds.to_str()}s -c ${connections.to_str()} -q ${rate.to_str()} --latency-correction --no-tui --output-format json --disable-compression --rand-regex-url${threads}${method}${auth}${body}${http2}${tls} ${Run.quote("${base}${part.path}")}"
	}
}

## The ladder climbed, until a step falls behind or errs; an error past the
## first step keeps the steps before it (`failure` says why it ended).
climb_rates! : Config.Race, Config.Workload, Config.Mixed, Target.Where, Str => Try({ steps : List(Results.Step), why : Str, failure : Str }, [Failed(Str), Interrupted])
climb_rates! = |race, workload, mixed, target, pid| {
	local = Machine.is_loopback(target.address)
	token = Conduit.token!(Conduit.load_user)?
	var $steps = []
	for rate in mixed.rates {
		attempt =
			{
				_ = run_parts!(race, workload, mixed, target, token, rate, mixed.warmup_seconds) ? |err| at(err, "warmup at ${rate.to_str()}/s")
				before = Target.snapshots!(target, pid, Before) ? |err| at(err, "snapshot before ${rate.to_str()}/s")
				parts = run_parts!(race, workload, mixed, target, token, rate, mixed.measure_seconds) ? |err| at(err, "at ${rate.to_str()}/s")
				after = Target.snapshots!(target, pid, After) ? |err| at(err, "snapshot after ${rate.to_str()}/s")
				Ok({ parts, before, after })
			}
		match attempt {
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => return Ok({ steps: $steps, why: "", failure: why })
			Ok({ parts, before, after }) => {
				seconds = mixed.measure_seconds.to_f64()
				cost = Snapshot.over(Snapshot.cost(before.server, after.server, target.server_cpus, local), seconds)
				step = {
					..Mixed.step(rate, parts),
					cpu_busy_pct: cost.cpu.busy,
					net_rx_mbps: cost.net_rx_mbps,
					net_tx_mbps: cost.net_tx_mbps,
					loader_cpu_busy_pct: Snapshot.loader_busy(before.loader, after.loader, target.loader_cpus, seconds),
				}
				Run.log!("    ${Text.pad_left(rate.to_str(), 8)}/s offered  ${Text.pad_left(Text.fixed(step.achieved_rps, 0), 8)}/s good  mean ${Text.fixed(step.mean_ms, 2)} ms  worst p99 ${Text.fixed(step.p99_ms, 2)} ms")
				$steps = $steps.append(step)
				# Behind: the next rate would only be further behind.
				if step.achieved_rps < mixed.saturated * rate.to_f64() or step.errors > 0 {
					return Ok({ steps: $steps, why: "", failure: "" })
				}
			}
		}
	}
	Ok({ steps: $steps, why: "", failure: "" })
}

## Every part's oha at once, each at its share of the rate.
run_parts! : Config.Race, Config.Workload, Config.Mixed, Target.Where, Str, U64, U64 => Try(List(Results.Part), [Failed(Str), Interrupted])
run_parts! = |race, workload, mixed, target, token, rate, seconds| {
	var $running = []
	for part in mixed.parts {
		offered = (part.share * rate.to_f64()).round_to_u64_try() ?? 1
		offered_at_least_one = if offered < 1 1 else offered
		running = Machine.start!(target.loader, Mixed.part_command(race, workload, target, part, token, offered_at_least_one, seconds))?
		$running = $running.append((part, offered_at_least_one, running))
	}
	var $measured = []
	var $failure = ""
	for (part, offered, running) in $running {
		match Machine.wait!(running) {
			Ok(report) =>
				match Oha.round(report) {
					Ok(r) => {
						$measured = $measured.append({ name: part.name, offered_rps: offered.to_f64(), achieved_rps: r.rps, mean_ms: r.mean_ms, p50_ms: r.p50_ms, p99_ms: r.p99_ms, p999_ms: r.p999_ms, errors: r.errors, non_2xx: r.non_2xx })
					}
					Err(Failed(why)) => {
						$failure = if $failure == "" "${part.name}: ${why}" else $failure
					}
				}
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => {
				$failure = if $failure == "" "${part.name}: ${why}" else $failure
			}
		}
	}
	if $failure == "" Ok($measured) else Err(Failed($failure))
}

## A comment's answer: a new id, ISO 8601 with milliseconds, the body and
## the load user as its author.
comment_difference : JsonValue, Conduit.Model -> Str
comment_difference = |got, model| {
	comment = got.get("comment")
	created = comment.get("createdAt").text()
	id_ok =
		match comment.get("id") {
			Number(id) => id > model.comments.len().to_f64()
			_ => Bool.False
		}
	if comment.to_str() == "null" {
		return "no comment in the answer"
	}
	if !id_ok or created.to_utf8().len() != 24 {
		return "id ${comment.get("id").to_str()} and createdAt ${comment.get("createdAt").to_str()}: a new id, and ISO 8601 with ms"
	}
	want = Object([
		(
			"comment",
			Object([
				("id", comment.get("id")),
				("createdAt", Text(created)),
				("updatedAt", comment.get("updatedAt")),
				("body", Text("Lovely roux.")),
				("author", Conduit.author(model, Conduit.load_user)),
			]),
		),
	])
	JsonValue.difference(got, want, "")
}

ceiling : F64 -> U64
ceiling = |x| {
	whole = x.floor_to_u64_try() ?? 0
	if whole.to_f64() < x whole + 1 else whole
}

at : [Failed(Str), Interrupted], Str -> [Failed(Str), Interrupted]
at = |err, place|
	match err {
		Failed(why) => Failed("${place}: ${why}")
		Interrupted => Interrupted
	}

expect ceiling(0.5 * 256) == 128
expect ceiling(0.15 * 256) == 39
expect ceiling(0.05 * 4) == 1

expect {
	parts = [
		{ name: "a", offered_rps: 50, achieved_rps: 50, mean_ms: 2, p50_ms: 1, p99_ms: 5, p999_ms: 9, errors: 0, non_2xx: 0 },
		{ name: "b", offered_rps: 50, achieved_rps: 50, mean_ms: 4, p50_ms: 3, p99_ms: 4, p999_ms: 10, errors: 1, non_2xx: 2 },
	]
	s = Mixed.step(100, parts)
	s.achieved_rps == 100 and s.mean_ms == 3 and s.p99_ms == 5 and s.p999_ms == 10 and s.errors == 1 and s.non_2xx == 2
}
