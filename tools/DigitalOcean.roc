import pf.Http
import http.Method
import http.Request
import http.Response

## The few calls of DigitalOcean's API a race makes, with a token that needs
## only droplet (create, read, delete), ssh_key (read) and tag (create,
## read). The guard makes them on the racer; the owner's install looks up
## sizes and the admin key.
DigitalOcean :: [].{
	## A droplet as DigitalOcean describes it, the few fields a race reads.
	Droplet : { id : U64, name : Str, status : Str, tags : List(Str), size_slug : Str, networks : { v4 : List({ ip_address : Str, type : Str }) } }

	## A droplet size: where it can be made, and its price.
	Size : { slug : Str, available : Bool, regions : List(Str), vcpus : U64, price_hourly : F64 }

	## A droplet asked for.
	Request : { name : Str, region : Str, size : Str, image : Str, ssh_keys : List(U64), tags : List(Str), user_data : Str, ipv6 : Bool }

	## A token pasted into a keyring often brings a space or a carriage
	## return with it, which HTTP refuses in a header: the ends are trimmed,
	## the middle refused, and the token never printed.
	checked_token : Str -> Try(Str, [Failed(Str)])
	checked_token = |text| {
		trimmed = text.trim()
		if trimmed == "" {
			Err(Failed("DIGITALOCEAN_TOKEN is not set"))
		} else if trimmed.to_utf8().any(|byte| byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
			Err(Failed("DIGITALOCEAN_TOKEN has whitespace inside it: store the token alone"))
		} else {
			Ok(trimmed)
		}
	}

	create! : Str, Request => Try(Droplet, [Failed(Str), Interrupted])
	create! = |token, request| {
		text = call!(token, POST, "/v2/droplets", Ok(Json.to_str(request)))?
		parsed : Try({ droplet : Droplet }, _)
		parsed = Json.parse(text)
		parsed.map_ok(|answer| answer.droplet).map_err(|_| Failed("DigitalOcean's droplet: not one"))
	}

	droplet! : Str, U64 => Try(Droplet, [Failed(Str), Interrupted])
	droplet! = |token, id| {
		text = call!(token, GET, "/v2/droplets/${id.to_str()}", Err(None))?
		parsed : Try({ droplet : Droplet }, _)
		parsed = Json.parse(text)
		parsed.map_ok(|answer| answer.droplet).map_err(|_| Failed("DigitalOcean's droplet ${id.to_str()}: not one"))
	}

	tagged! : Str, Str => Try(List(Droplet), [Failed(Str), Interrupted])
	tagged! = |token, tag| {
		text = call!(token, GET, "/v2/droplets?per_page=200&tag_name=${tag}", Err(None))?
		parsed : Try({ droplets : List(Droplet) }, _)
		parsed = Json.parse(text)
		parsed.map_ok(|answer| answer.droplets).map_err(|_| Failed("DigitalOcean's droplets: not a list"))
	}

	## Deleting one already gone (404) is done.
	delete! : Str, U64 => Try({}, [Failed(Str), Interrupted])
	delete! = |token, id|
		match call!(token, DELETE, "/v2/droplets/${id.to_str()}", Err(None)) {
			Ok(_) => Ok({})
			Err(Failed(why)) if why.contains(": 404:") => Ok({})
			Err(err) => Err(err)
		}

	sizes! : Str => Try(List(Size), [Failed(Str), Interrupted])
	sizes! = |token| {
		text = call!(token, GET, "/v2/sizes?per_page=200", Err(None))?
		parsed : Try({ sizes : List(Size) }, _)
		parsed = Json.parse(text)
		parsed.map_ok(|answer| answer.sizes).map_err(|_| Failed("DigitalOcean's sizes: not a list"))
	}

	## The owner's admin key on the account, as added in the panel. Every
	## droplet names it, so DigitalOcean emails no root password; a race
	## droplet's own key is in its user data, never registered.
	admin_key_id! : Str => Try(U64, [Failed(Str), Interrupted])
	admin_key_id! = |token| {
		text = call!(token, GET, "/v2/account/keys?per_page=200", Err(None))?
		parsed : Try({ ssh_keys : List({ id : U64, name : Str }) }, _)
		parsed = Json.parse(text)
		keys = parsed.map_err(|_| Failed("DigitalOcean's SSH keys: not a list"))?
		match keys.ssh_keys.find_first(|key| key.name == admin_key_name) {
			Ok(key) => Ok(key.id)
			Err(_) => Err(Failed("DigitalOcean has no SSH key named ${admin_key_name} (add yours in the panel)"))
		}
	}
}

admin_key_name : Str
admin_key_name = "fourneau-dragrace-admin"

call! : Str, Method, Str, Try(Str, [None]) => Try(Str, [Failed(Str), Interrupted])
call! = |token, method, path, body| {
	what = "DigitalOcean ${method.to_str()} ${path}"
	base =
		Request.from_method(method)
			.with_uri("https://api.digitalocean.com${path}")
			.add_header("Authorization", "Bearer ${token}")
			.with_timeout(TimeoutMilliseconds(60_000))
	request =
		match body {
			Ok(json) => base.add_header("Content-Type", "application/json").with_body(json.to_utf8())
			Err(None) => base
		}
	response =
		match Http.send!(request, {}) {
			Ok(answer) => answer
			Err(Interrupted) => return Err(Interrupted)
			Err(InvalidUrl(_)) => return Err(Failed("${what}: not a URL"))
			Err(HttpErr(err)) => return Err(Failed("${what}: ${Str.inspect(err)}"))
		}
	status = Response.status(response)
	text = Str.from_utf8_lossy(Response.body(response))
	if status >= 300 {
		Err(Failed("${what}: ${status.to_str()}: ${text.trim()}"))
	} else {
		Ok(text)
	}
}

expect DigitalOcean.checked_token(" abc\r\n") == Ok("abc")
expect DigitalOcean.checked_token("a b").is_err()
expect DigitalOcean.checked_token("").is_err()
