import Run
import Text

## The racer's way to DigitalOcean: the guard, which holds the token and
## the owner's limits (a service of its own on the racer). Its API is HTTP
## over a Unix socket, reached here with curl, a real HTTP client, so
## nothing reads HTTP by hand. A refusal (403) is the guard saying no: the
## run is recorded as refused.
Guard :: [].{
	## A droplet as DigitalOcean describes it, the few fields a race reads.
	Droplet : { id : U64, name : Str, status : Str, tags : List(Str), size_slug : Str, networks : { v4 : List({ ip_address : Str, type : Str }) } }

	## A droplet size: where it can be made, and its price.
	Size : { slug : Str, available : Bool, regions : List(Str), vcpus : U64, price_hourly : F64 }

	## What the owner allows (the guard's config).
	Allowed : { region : Str, image : Str, tag : Str, hourly_max_usd : F64, monthly_cap_usd : F64, droplets_max : U64, age_max_minutes : U64 }

	## A droplet asked for: no DigitalOcean SSH key (the guard names the
	## owner's admin key itself), the run's key in its user data.
	Request : { name : Str, region : Str, size : Str, image : Str, ssh_keys : List(U64), tags : List(Str), user_data : Str, ipv6 : Bool }

	create! : Str, Request => Try(Droplet, [Refused(Str), Failed(Str), Interrupted])
	create! = |socket, request| {
		body = Json.to_str(request)
		text = call!(socket, "POST", "/droplets", Ok(body))?
		parse_droplet(text)
	}

	droplet! : Str, U64 => Try(Droplet, [Refused(Str), Failed(Str), Interrupted])
	droplet! = |socket, id| {
		text = call!(socket, "GET", "/droplets/${id.to_str()}", Err(None))?
		parse_droplet(text)
	}

	## The race's droplets: the guard knows one tag.
	tagged! : Str => Try(List(Droplet), [Refused(Str), Failed(Str), Interrupted])
	tagged! = |socket| {
		text = call!(socket, "GET", "/droplets", Err(None))?
		parsed : Try(List(Droplet), _)
		parsed = Json.parse(text)
		parsed.map_err(|_| Failed("the guard's droplets: not JSON"))
	}

	delete! : Str, U64 => Try({}, [Refused(Str), Failed(Str), Interrupted])
	delete! = |socket, id| {
		_ = call!(socket, "DELETE", "/droplets/${id.to_str()}", Err(None))?
		Ok({})
	}

	sizes! : Str => Try(List(Size), [Refused(Str), Failed(Str), Interrupted])
	sizes! = |socket| {
		text = call!(socket, "GET", "/sizes", Err(None))?
		parsed : Try(List(Size), _)
		parsed = Json.parse(text)
		parsed.map_err(|_| Failed("the guard's sizes: not JSON"))
	}

	allowed! : Str => Try(Allowed, [Refused(Str), Failed(Str), Interrupted])
	allowed! = |socket| {
		text = call!(socket, "GET", "/allowed", Err(None))?
		parsed : Try(Allowed, _)
		parsed = Json.parse(text)
		parsed.map_err(|_| Failed("the guard's limits: not JSON"))
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
}

## One request: curl's body and status line apart. 403 is a refusal; 404
## a route newer than the guard's install.
call! : Str, Str, Str, Try(Str, [None]) => Try(Str, [Refused(Str), Failed(Str), Interrupted])
call! = |socket, method, path, body| {
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

parse_droplet : Str -> Try(Guard.Droplet, [Refused(Str), Failed(Str), Interrupted])
parse_droplet = |text| {
	parsed : Try(Guard.Droplet, _)
	parsed = Json.parse(text)
	parsed.map_err(|_| Failed("the guard's droplet: not one: ${Text.take(text, 120)}"))
}

prefix : [Failed(Str), Interrupted], Str -> [Refused(Str), Failed(Str), Interrupted]
prefix = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

fixed4 : F64 -> Str
fixed4 = |value| {
	scaled = (value * 10000 + 0.5).floor_to_u64_try() ?? 0
	fraction = (scaled % 10000).to_str()
	"${(scaled // 10000).to_str()}.${Str.repeat("0", 4 - fraction.to_utf8().len())}${fraction}"
}

expect fixed4(0.125) == "0.1250"
expect fixed4(2) == "2.0000"

expect {
	parsed = parse_droplet("{\"id\":42,\"name\":\"dragrace-server-x\",\"status\":\"active\",\"tags\":[\"t\"],\"size_slug\":\"c-2\",\"image\":{\"id\":1,\"slug\":null},\"next_backup_window\":null,\"networks\":{\"v4\":[{\"ip_address\":\"10.0.0.2\",\"netmask\":\"255.255.0.0\",\"gateway\":\"10.0.0.1\",\"type\":\"private\"},{\"ip_address\":\"203.0.113.9\",\"netmask\":\"255.255.255.0\",\"gateway\":\"203.0.113.1\",\"type\":\"public\"}],\"v6\":[]}}")
	match parsed {
		Ok(d) => d.id == 42 and Guard.address(d, "public") == "203.0.113.9" and Guard.address(d, "private") == "10.0.0.2"
		Err(_) => Bool.False
	}
}
