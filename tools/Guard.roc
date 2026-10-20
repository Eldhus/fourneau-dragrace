import pf.Duration
import pf.Path
import pf.UnixSocket
import DigitalOcean
import Run
import Text

## The racer's way to DigitalOcean: the guard, which holds the token and
## the owner's limits (a service of its own on the racer, GuardService).
## It speaks one JSON line each way over a Unix socket: a request
## `{"op", "id", "droplet"}`, an answer `{"status", "why", "value"}`. Go's
## guard spoke HTTP on its socket, reached with curl, a real HTTP client;
## the racer's config says which guard it has (`racer install` puts both in
## place together). A refusal is the guard saying no: the run is recorded
## as refused.
Guard :: [].{
	## The guard's socket, and how to speak to it.
	Way : [Http(Str), Lines(Str)]

	Droplet : DigitalOcean.Droplet

	Size : DigitalOcean.Size

	Request : DigitalOcean.Request

	## What the owner allows (the guard's config).
	Allowed : { region : Str, image : Str, tag : Str, hourly_max_usd : F64, monthly_cap_usd : F64, droplets_max : U64, age_max_minutes : U64 }

	create! : Way, Request => Try(Droplet, [Refused(Str), Failed(Str), Interrupted])
	create! = |way, request| {
		json = exchange!(way, { op: "create", id: 0, method: "POST", path: "/droplets" }, Ok(request))?
		parsed : Try(Droplet, _)
		parsed = Json.parse(json)
		parsed.map_err(|_| not_json("the guard's droplet", json))
	}

	droplet! : Way, U64 => Try(Droplet, [Refused(Str), Failed(Str), Interrupted])
	droplet! = |way, id| {
		json = exchange!(way, { op: "droplet", id, method: "GET", path: "/droplets/${id.to_str()}" }, Err(None))?
		parsed : Try(Droplet, _)
		parsed = Json.parse(json)
		parsed.map_err(|_| not_json("the guard's droplet", json))
	}

	## The race's droplets: the guard knows one tag.
	tagged! : Way => Try(List(Droplet), [Refused(Str), Failed(Str), Interrupted])
	tagged! = |way| {
		json = exchange!(way, { op: "droplets", id: 0, method: "GET", path: "/droplets" }, Err(None))?
		parsed : Try(List(Droplet), _)
		parsed = Json.parse(json)
		parsed.map_err(|_| not_json("the guard's droplets", json))
	}

	delete! : Way, U64 => Try({}, [Refused(Str), Failed(Str), Interrupted])
	delete! = |way, id| {
		_ = exchange!(way, { op: "delete", id, method: "DELETE", path: "/droplets/${id.to_str()}" }, Err(None))?
		Ok({})
	}

	sizes! : Way => Try(List(Size), [Refused(Str), Failed(Str), Interrupted])
	sizes! = |way| {
		json = exchange!(way, { op: "sizes", id: 0, method: "GET", path: "/sizes" }, Err(None))?
		parsed : Try(List(Size), _)
		parsed = Json.parse(json)
		parsed.map_err(|_| not_json("the guard's sizes", json))
	}

	allowed! : Way => Try(Allowed, [Refused(Str), Failed(Str), Interrupted])
	allowed! = |way| {
		json = exchange!(way, { op: "allowed", id: 0, method: "GET", path: "/allowed" }, Err(None))?
		parsed : Try(Allowed, _)
		parsed = Json.parse(json)
		parsed.map_err(|_| not_json("the guard's limits", json))
	}

	## A droplet's address of a kind ("public", "private"), "" for none.
	address : Droplet, Str -> Str
	address = |droplet, kind|
		match droplet.networks.v4.find_first(|n| n.type == kind) {
			Ok(n) => n.ip_address
			Err(_) => ""
		}

	## Why a size at its price now is not allowed, "" when it is.
	size_problem : Allowed, Str, F64 -> Str
	size_problem = |allowed, size, price|
		if price <= 0 or price > allowed.hourly_max_usd {
			"${size} costs $${fixed4(price)} an hour, the most allowed is $${fixed4(allowed.hourly_max_usd)}"
		} else {
			""
		}

	## The answer the guard gives, on its line: a value (its JSON, as a
	## string), or why not.
	answer : [Ok(Str), Refused(Str), Failed(Str), Unknown] -> Str
	answer = |outcome|
		match outcome {
			Ok(json) => Json.to_str({ status: "ok", why: "", value: json })
			Refused(why) => Json.to_str({ status: "refused", why })
			Failed(why) => Json.to_str({ status: "failed", why })
			Unknown => Json.to_str({ status: "unknown", why: "" })
		}
}

## One request, to either guard: the JSON of its answer's value.
exchange! : Guard.Way, { op : Str, id : U64, method : Str, path : Str }, Try(Guard.Request, [None]) => Try(Str, [Refused(Str), Failed(Str), Interrupted])
exchange! = |way, ask, body|
	match (way, body) {
		(Http(socket), Ok(request)) => http!(socket, ask.method, ask.path, Ok(Json.to_str(request)))
		(Http(socket), Err(None)) => http!(socket, ask.method, ask.path, Err(None))
		(Lines(socket), Ok(request)) => line!(socket, Json.to_str({ op: ask.op, id: ask.id, droplet: request }))
		(Lines(socket), Err(None)) => line!(socket, Json.to_str({ op: ask.op, id: ask.id }))
	}

not_json : Str, Str -> [Refused(Str), Failed(Str), Interrupted]
not_json = |what, json| Failed("${what}: not JSON: ${Text.take(json, 120)}")

## One request on its own connection: the answer's value, or why not.
line! : Str, Str => Try(Str, [Refused(Str), Failed(Str), Interrupted])
line! = |socket, request| {
	what = "guard ${socket}"
	io = |result| result.map_err(|err|
		match err {
			Interrupted => Interrupted
			UnixSocketErr(e) => Failed("${what}: ${Str.inspect(e)}")
			EndOfInput => Failed("${what}: closed without an answer")
			ReadLimitExceeded(_) => Failed("${what}: an answer too long")
			BadUtf8(_) => Failed("${what}: an answer not UTF-8")
		})
	conn = io(UnixSocket.connect!(Path.utf8(socket), { connect_timeout: Duration.seconds(10), io_timeout: Duration.seconds(180) }))?
	io(conn.write_utf8!("${request}\n"))?
	text = io(conn.read_line!())?
	status : Try({ status : Str, why : Str }, _)
	status = Json.parse(text)
	match status {
		Ok({ status: "ok", why: _ }) => {
			ok : Try({ value : Str }, _)
			ok = Json.parse(text)
			ok.map_ok(|answer| answer.value).map_err(|_| Failed("${what}: an answer with no value"))
		}
		Ok({ status: "refused", why }) => Err(Refused("refused by the guard: ${why}"))
		Ok({ status: "unknown", why: _ }) => Err(Failed("not known to this guard: ${request}"))
		Ok({ status: _, why }) => Err(Failed("${what}: ${why}"))
		Err(_) => Err(Failed("${what}: not an answer: ${Text.take(text, 120)}"))
	}
}

## One request to Go's guard: curl's body and status line apart. 403 is a
## refusal; 404 a route newer than the guard's install.
http! : Str, Str, Str, Try(Str, [None]) => Try(Str, [Refused(Str), Failed(Str), Interrupted])
http! = |socket, method, path, body| {
	base = ["curl", "-sS", "--max-time", "180", "--unix-socket", socket, "-X", method, "-w", "\n%{http_code}"]
	argv =
		match body {
			Ok(_) => base.concat(["-H", "Content-Type: application/json", "--data-binary", "@-", "http://guard${path}"])
			Err(None) => base.append("http://guard${path}")
		}
	input =
		match body {
			Ok(json) => json.to_utf8()
			Err(None) => []
		}
	printed = Run.with_input_bytes!("", argv, input) ? |err| prefix(err, "guard ${method} ${path}")
	text = Str.from_utf8_lossy(printed)
	{ answer, status } =
		match text.split_last("\n") {
			Ok({ before, after }) => { answer: before, status: after.trim() }
			Err(_) => { answer: "", status: text.trim() }
		}
	if status == "403" {
		Err(Refused("refused by the guard: ${answer.trim()}"))
	} else if status == "404" {
		Err(Failed("not known to this guard: guard ${method} ${path}"))
	} else if status.starts_with("2") {
		Ok(answer)
	} else {
		Err(Failed("guard ${method} ${path}: ${status}: ${answer.trim()}"))
	}
}

prefix : [Failed(Str), Interrupted], Str -> [Refused(Str), Failed(Str), Interrupted]
prefix = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

fixed4 : F64 -> Str
fixed4 = |number| {
	scaled = (number * 10000 + 0.5).floor_to_u64_try() ?? 0
	fraction = (scaled % 10000).to_str()
	"${(scaled // 10000).to_str()}.${Str.repeat("0", 4 - fraction.to_utf8().len())}${fraction}"
}

expect fixed4(0.125) == "0.1250"
expect fixed4(2) == "2.0000"

droplet_json : Str
droplet_json = "{\"id\":42,\"name\":\"dragrace-server-x\",\"status\":\"active\",\"tags\":[\"t\"],\"size_slug\":\"c-2\",\"image\":{\"id\":1,\"slug\":null},\"next_backup_window\":null,\"networks\":{\"v4\":[{\"ip_address\":\"10.0.0.2\",\"netmask\":\"255.255.0.0\",\"gateway\":\"10.0.0.1\",\"type\":\"private\"},{\"ip_address\":\"203.0.113.9\",\"netmask\":\"255.255.255.0\",\"gateway\":\"203.0.113.1\",\"type\":\"public\"}],\"v6\":[]}}"

expect {
	parsed : Try(Guard.Droplet, _)
	parsed = Json.parse(droplet_json)
	match parsed {
		Ok(d) => d.id == 42 and Guard.address(d, "public") == "203.0.113.9" and Guard.address(d, "private") == "10.0.0.2"
		Err(_) => Bool.False
	}
}

# The line guard's answer carries the value's JSON whole.
expect {
	parsed : Try({ status : Str, value : Str }, _)
	parsed = Json.parse(Guard.answer(Ok(droplet_json)))
	parsed == Ok({ status: "ok", value: droplet_json })
}
