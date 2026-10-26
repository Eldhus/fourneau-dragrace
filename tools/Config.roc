import Text

## What a race is (race.json) and how each competitor is built
## (competitors/NAME/competitor.json), read and checked. A test of race.json
## is one request sent each of its variants' ways; what is raced is a
## workload, a test in one variant, named as the races before variants
## named them: `plaintext`, `plaintext-h2`, `plaintext-tls`.
Config :: [].{
	## A pinned download: oha (race.json), Zig and roc (roux's toolchain.json).
	Download : { version : Str, url : Str, sha256 : Str }

	## A mixed workload's load (conduit): open loop only, a ladder of total
	## rates, its parts at their shares at once.
	Mixed : {
		rates : List(U64),
		warmup_seconds : U64,
		measure_seconds : U64,
		saturated : F64,
		parts : List(Part),
	}

	## One kind of request in a mix: its path a rand_regex (oha
	## --rand-regex-url); `auth` sends the load user's token.
	Part : { name : Str, method : Str, path : Str, share : F64, auth : Bool, body : Str }

	## One way a test is sent: "http1", "h2c" (HTTP/2 by prior knowledge) or
	## "tls" (the competitor's HTTPS mode, HTTP/2 by ALPN with streams); its
	## connections, and HTTP/2's requests at once on each (0: HTTP/1.1).
	Variant : { protocol : Str, connections : U64, streams : U64 }

	## One of race.json's workloads, as written there.
	Test : {
		name : Str,
		title : Str,
		summary : Str,
		detail : Str,
		method : Str,
		path : Str,
		body_bytes : U64,
		content_type : Str,
		keepalive : Bool,
		variants : List(Variant),
		mixed : Try(Mixed, [None]),
	}

	## What is raced: a test in one variant.
	Workload : {
		name : Str,
		test : Str,
		title : Str,
		summary : Str,
		method : Str,
		path : Str,
		body_bytes : U64,
		content_type : Str,
		connections : U64,
		keepalive : Bool,
		http2 : Bool,
		streams : U64,
		tls : Bool,
		protocol : Str,
		mixed : Try(Mixed, [None]),
	}

	## One kind of server droplet and the bigger loader that races it.
	ServerClass : { name : Str, label : Str, title : Str, size : Str, loader_size : Str }

	Cloud : { region : Str, image : Str, servers : List(ServerClass), tag : Str, max_age_minutes : U64 }

	## race.json, its tests expanded into workloads, and the two reference
	## answers (workloads/menu.html, workloads/sse.txt).
	Race : {
		port : U64,
		rounds : U64,
		warmup_seconds : U64,
		measure_seconds : U64,
		competitors : List(Str),
		oha : Download,
		tests : List(Test),
		workloads : List(Workload),
		cloud : Cloud,
		local : { server_cpus : Str, loader_cpus : Str },
		menu : Str,
		stream : Str,
		## The workloads measured, when not all (a smoke race's); the checks
		## still ask every workload's path.
		loaded : Try(List(Str), [All]),
	}

	## competitors/NAME/competitor.json: one command, run in the
	## competitor's directory, that writes `binary`; `inputs` are what it
	## reads by path outside its directory (its key takes them). `version`:
	## what it races where no tool reports it (basic-webserver's platform,
	## which its main.roc pins by URL); "" when a tool does.
	Competitor : {
		name : Str,
		title : Str,
		language : Str,
		framework : Str,
		version : Str,
		inputs : List(Str),
		argv : List(Str),
		env : List((Str, Str)),
		binary : Str,
		tls : Bool,
		kernel_tls : Bool,
	}

	## race.json read from its text and the two reference answers.
	race : Str, Str, Str -> Try(Race, [Failed(Str)])
	race = |text, menu, stream| {
		file = parse_race(text) ? |err| Failed("race.json: ${describe_json(err)}")
		if file.rounds < 1 or file.measure_seconds < 1 or file.workloads.is_empty() or file.oha.sha256 == "" {
			return Err(Failed("race.json: rounds, measure_seconds, workloads and oha must be set"))
		}
		tests = file.workloads.map(to_test)
		workloads = tests.map_try(Config.expand)?.join()
		Ok({
			port: file.port,
			rounds: file.rounds,
			warmup_seconds: file.warmup_seconds,
			measure_seconds: file.measure_seconds,
			competitors: file.competitors,
			oha: file.oha,
			tests,
			workloads,
			cloud: file.cloud,
			local: file.local,
			menu,
			stream,
			loaded: Err(All),
		})
	}

	## A test's workloads, a variant each in protocols' order. A test has a
	## summary and a detail, and an HTTP/1.1 variant, whose name is the
	## test's.
	expand : Test -> Try(List(Workload), [Failed(Str)])
	expand = |test| {
		if test.name == "" or test.summary == "" or test.detail == "" {
			return Err(Failed("race.json: \"${test.name}\": a name, a summary and a detail"))
		}
		var $workloads = []
		for (protocol, suffix) in protocols {
			match test.variants.find_first(|v| v.protocol == protocol) {
				Ok(variant) => {
					name = "${test.name}${suffix}"
					if variant.connections < 1 {
						return Err(Failed("race.json: ${name}: no connections"))
					}
					if (protocol == "http1" and variant.streams != 0) or (protocol == "h2c" and variant.streams < 1) {
						return Err(Failed("race.json: ${name}: HTTP/1.1 has no streams, h2c has"))
					}
					if variant.streams > 0 and !test.keepalive {
						return Err(Failed("race.json: ${name}: oha's HTTP/2 always keeps connections"))
					}
					title = if protocol == "http1" test.title else "${test.title}, ${Config.protocol_label(protocol, variant.streams > 0)}"
					$workloads = $workloads.append(
						{
							name,
							test: test.name,
							title,
							summary: test.summary,
							method: test.method,
							path: test.path,
							body_bytes: test.body_bytes,
							content_type: test.content_type,
							connections: variant.connections,
							keepalive: test.keepalive,
							http2: variant.streams > 0,
							streams: variant.streams,
							tls: protocol == "tls",
							protocol,
							mixed: test.mixed,
						},
					)
				}
				Err(_) => {}
			}
		}
		first_http1 =
			match $workloads.first() {
				Ok(first) => first.protocol == "http1"
				Err(_) => Bool.False
			}
		if $workloads.len() != test.variants.len() or !first_http1 {
			return Err(Failed("race.json: ${test.name}: an HTTP/1.1 variant, and each protocol once of http1, h2c, tls"))
		}
		Ok($workloads)
	}

	## How the site names a variant's protocol: "HTTP/2 + TLS", or
	## "HTTP/1.1 + TLS" over TLS without HTTP/2 (churn).
	protocol_label : Str, Bool -> Str
	protocol_label = |protocol, http2|
		if protocol == "h2c" {
			"HTTP/2 (h2c)"
		} else if protocol == "tls" and http2 {
			"HTTP/2 + TLS"
		} else if protocol == "tls" {
			"HTTP/1.1 + TLS"
		} else {
			"HTTP/1.1"
		}

	## A competitor.json, for the competitor of that name.
	competitor : Str, Str -> Try(Competitor, [Failed(Str)])
	competitor = |name, text| {
		file = parse_competitor(text) ? |err| Failed("competitors/${name}/competitor.json: ${describe_json(err)}")
		binary_local = file.build.binary != "" and !file.build.binary.starts_with("/") and !file.build.binary.split_on("/").contains("..")
		if file.build.argv.is_empty() or !binary_local {
			return Err(Failed("competitors/${name}/competitor.json: build.argv and build.binary, a path in its directory, must be set"))
		}
		env = (file.build.?env ?? Dict.empty()).to_list().sort_with(|(a, _), (b, _)| Text.order(a, b))
		Ok({
			name,
			title: file.title,
			language: file.language,
			framework: file.framework,
			version: file.?version ?? "",
			inputs: file.?inputs ?? [],
			argv: file.build.argv,
			env,
			binary: file.build.binary,
			tls: file.tls,
			kernel_tls: file.?kernel_tls ?? Bool.False,
		})
	}

	## Whether a race measures a workload.
	loads : Race, Workload -> Bool
	loads = |r, workload|
		match r.loaded {
			Ok(names) => names.contains(workload.name)
			Err(All) => Bool.True
		}

	## Whether a race checks that competitors speak h2c.
	has_h2c : Race -> Bool
	has_h2c = |r| r.workloads.any(|w| w.http2 and !w.tls)

	## Whether a race has a TLS workload.
	has_tls : Race -> Bool
	has_tls = |r| r.workloads.any(|w| w.tls)

	## How the site draws a workload: "closed" bars, or "mixed" lines.
	kind : Workload -> Str
	kind = |workload|
		match workload.mixed {
			Ok(_) => "mixed"
			Err(None) => "closed"
		}
}

## The protocols in the site's order, each with what it adds to its test's
## name.
protocols : List((Str, Str))
protocols = [("http1", ""), ("h2c", "-h2"), ("tls", "-tls")]

RaceFile : {
	port : U64,
	rounds : U64,
	warmup_seconds : U64,
	measure_seconds : U64,
	competitors : List(Str),
	oha : Config.Download,
	workloads : List(TestFile),
	cloud : Config.Cloud,
	local : { server_cpus : Str, loader_cpus : Str },
}

TestFile : {
	name : Str,
	title : Str,
	summary : Str,
	detail : Str,
	method : Str,
	path : Str,
	body_bytes ?: U64,
	content_type ?: Str,
	keepalive : Bool,
	variants : List({ protocol : Str, connections : U64, streams ?: U64 }),
	mixed ?: { rates : List(U64), warmup_seconds : U64, measure_seconds : U64, saturated : F64, parts : List(PartFile) },
}

PartFile : { name : Str, method : Str, path : Str, share : F64, auth ?: Bool, body ?: Str }

CompetitorFile : {
	title : Str,
	language : Str,
	framework : Str,
	version ?: Str,
	inputs ?: List(Str),
	build : { argv : List(Str), env ?: Dict(Str, Str), binary : Str },
	tls : Bool,
	kernel_tls ?: Bool,
}

parse_race : Str -> Try(RaceFile, [InvalidJson(Str), MissingRequiredField(Str)])
parse_race = |text| Json.parse(text)

parse_competitor : Str -> Try(CompetitorFile, [InvalidJson(Str), MissingRequiredField(Str)])
parse_competitor = |text| Json.parse(text)

to_test : TestFile -> Config.Test
to_test = |file| {
	name: file.name,
	title: file.title,
	summary: file.summary,
	detail: file.detail,
	method: file.method,
	path: file.path,
	body_bytes: file.?body_bytes ?? 0,
	content_type: file.?content_type ?? "",
	keepalive: file.keepalive,
	variants: file.variants.map(|v| { protocol: v.protocol, connections: v.connections, streams: v.?streams ?? 0 }),
	mixed: match file.?mixed {
		Ok(m) =>
			Ok(
				{
					rates: m.rates,
					warmup_seconds: m.warmup_seconds,
					measure_seconds: m.measure_seconds,
					saturated: m.saturated,
					parts: m.parts.map(|p| { name: p.name, method: p.method, path: p.path, share: p.share, auth: p.?auth ?? Bool.False, body: p.?body ?? "" }),
				},
			)
		Err(MissingField) => Err(None)
	},
}

describe_json : [InvalidJson(Str), MissingRequiredField(Str)] -> Str
describe_json = |err|
	match err {
		InvalidJson(why) => why
		MissingRequiredField(field) => "no ${field}"
	}

test_of : Str, List(Config.Variant), Bool -> Config.Test
test_of = |name, variants, keepalive| {
	name,
	title: "T",
	summary: "s",
	detail: "d",
	method: "GET",
	path: "/p",
	body_bytes: 0,
	content_type: "",
	keepalive,
	variants,
	mixed: Err(None),
}

expect {
	got = Config.expand(test_of("plaintext", [{ protocol: "tls", connections: 32, streams: 8 }, { protocol: "http1", connections: 256, streams: 0 }, { protocol: "h2c", connections: 32, streams: 8 }], Bool.True))
	match got {
		Ok(ws) => ws.map(|w| w.name) == ["plaintext", "plaintext-h2", "plaintext-tls"] and ws.map(|w| w.title) == ["T", "T, HTTP/2 (h2c)", "T, HTTP/2 + TLS"]
		Err(_) => Bool.False
	}
}

expect {
	got = Config.expand(test_of("churn", [{ protocol: "http1", connections: 64, streams: 0 }, { protocol: "tls", connections: 64, streams: 0 }], Bool.False))
	match got {
		Ok(ws) => ws.map(|w| (w.name, w.http2, w.tls)) == [("churn", Bool.False, Bool.False), ("churn-tls", Bool.False, Bool.True)] and (ws.last() ?? { ..(ws.first() ?? crash "none"), title: "" }).title == "T, HTTP/1.1 + TLS"
		Err(_) => Bool.False
	}
}

# The refusals: no HTTP/1.1 variant, streams on HTTP/1.1, none on h2c,
# HTTP/2 without keepalive, a protocol twice, no connections.
expect Config.expand(test_of("x", [{ protocol: "tls", connections: 1, streams: 0 }], Bool.True)).is_err()
expect Config.expand(test_of("x", [{ protocol: "http1", connections: 1, streams: 2 }], Bool.True)).is_err()
expect Config.expand(test_of("x", [{ protocol: "http1", connections: 1, streams: 0 }, { protocol: "h2c", connections: 1, streams: 0 }], Bool.True)).is_err()
expect Config.expand(test_of("x", [{ protocol: "http1", connections: 1, streams: 0 }, { protocol: "tls", connections: 1, streams: 2 }], Bool.False)).is_err()
expect Config.expand(test_of("x", [{ protocol: "http1", connections: 1, streams: 0 }, { protocol: "http1", connections: 1, streams: 0 }], Bool.True)).is_err()
expect Config.expand(test_of("x", [{ protocol: "http1", connections: 0, streams: 0 }], Bool.True)).is_err()

expect {
	got = Config.competitor("go", "{\"title\":\"go\",\"language\":\"Go\",\"framework\":\"f\",\"build\":{\"argv\":[\"go\",\"build\"],\"env\":{\"GOAMD64\":\"v3\",\"CGO_ENABLED\":\"0\"},\"binary\":\"dragrace-go\"},\"tls\":true}")
	match got {
		Ok(c) => c.env == [("CGO_ENABLED", "0"), ("GOAMD64", "v3")] and c.inputs == [] and !c.kernel_tls
		Err(_) => Bool.False
	}
}

expect Config.competitor("x", "{\"title\":\"x\",\"language\":\"\",\"framework\":\"\",\"build\":{\"argv\":[\"x\"],\"binary\":\"../x\"},\"tls\":true}").is_err()
expect Config.competitor("x", "{\"title\":\"x\",\"language\":\"\",\"framework\":\"\",\"build\":{\"argv\":[],\"binary\":\"x\"},\"tls\":true}").is_err()
