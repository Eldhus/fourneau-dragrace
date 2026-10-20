import pf.Duration
import pf.Path
import pf.Signal
import pf.System
import pf.UnixSocket
import pf.Utc
import Checkout
import DigitalOcean
import Flags
import Guard
import Ledger
import Run
import Text

## The guard holds the DigitalOcean token on the racer, and nothing else
## does. The racer asks it over a Unix socket for the few things a race
## needs (Guard), one connection at a time; it refuses a size, region or
## image the owner's config does not allow, any DigitalOcean SSH key (it
## names the owner's admin key itself), more droplets alive than allowed,
## and any droplet that could take the month's spend past the cap
## (Ledger). It deletes its droplets past their age, whatever the racer
## does. Installed by the owner, never updated by a build.
GuardService :: [].{
	## `dragrace guard [-config F]`: serve until stopped.
	command! : List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	command! = |args| {
		flags = Flags.parse(args, [{ name: "config", kind: Value("/etc/dragrace-guard/config.json"), usage: "the owner's config" }])?
		path = Flags.value(flags, "config")
		parsed : Try(Ledger.Config, _)
		parsed = Json.parse(Checkout.read!(path)?)
		config = parsed ? |_| Failed("${path}: not the guard's config")
		problems = Ledger.problems(config)
		if !problems.is_empty() {
			return Err(Failed("guard config: ${Str.join_with(problems, "; ")}"))
		}
		token = DigitalOcean.checked_token(Run.secret!("DIGITALOCEAN_TOKEN", "digitalocean-token")?)?
		lives =
			match Path.utf8(config.ledger).read_utf8!() {
				Ok(text) => Ledger.parse(text) ? |Failed(why)| Failed("${config.ledger}: ${why}")
				Err(PathErr(NotFound, _)) => []
				Err(PathErr(err, _)) => return Err(Failed("${config.ledger}: ${err.to_str()}"))
			}
		match System.target!().os() {
			Linux(os) => Signal.catch!([Interrupt, Terminate(os.unix())]) ? |_| Failed("signals: not caught")
			_ => return Err(Failed("the guard runs on Linux"))
		}
		# The socket's mode is the unit's UMask (the racer's group connects);
		# its directory is the guard's, mode 0750, group racer.
		_ = Path.utf8(config.socket).delete!()
		listener = UnixSocket.listen!(Path.utf8(config.socket)) ? |err| io_failed(err, config.socket)
		Run.log!("guard: on ${config.socket}; month $${Text.fixed(Ledger.spent(lives, now!()), 2)} of $${Text.fixed(config.monthly_cap_usd, 2)}")
		serve!({ config, token, lives, reaped_ms: 0 }, listener)
	}
}

State : { config : Ledger.Config, token : Str, lives : List(Ledger.Life), reaped_ms : I64 }

serve! : State, UnixSocket.Listener => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
serve! = |state, listener| {
	var $state = state
	while Bool.True {
		if now!() - $state.reaped_ms >= 60_000 {
			$state = reap!($state)?
		}
		match listener.accept!({ accept_timeout: After(Duration.minutes(1)), io_timeout: Duration.minutes(1) }) {
			Ok(conn) => {
				$state = connection!($state, conn)?
			}
			Err(UnixSocketErr(TimedOut)) => {}
			Err(Interrupted) => return Ok({})
			Err(Closed) => return Ok({})
			Err(UnixSocketErr(err)) => Run.log!("guard: accept: ${Str.inspect(err)}")
		}
	}
}

## One request and its answer. Only a stop ends the guard; anything else
## wrong is the answer.
connection! : State, UnixSocket.Connection => Try(State, [BadFlag(Str), Failed(Str), Interrupted])
connection! = |state, conn| {
	line =
		match conn.read_line!() {
			Ok(text) => text
			Err(Interrupted) => return Err(Interrupted)
			Err(_) => return Ok(state)
		}
	{ next, outcome } =
		match handle!(state, line) {
			Ok(done) => done
			Err(Interrupted) => return Err(Interrupted)
		}
	match conn.write_utf8!("${Guard.answer(outcome)}\n") {
		Err(Interrupted) => Err(Interrupted)
		_ => Ok(next)
	}
}

handle! : State, Str => Try({ next : State, outcome : [Ok(Str), Refused(Str), Failed(Str), Unknown] }, [Interrupted])
handle! = |state, line| {
	same = |outcome| Ok({ next: state, outcome })
	asked : Try({ op : Str }, _)
	asked = Json.parse(line)
	op = (asked ?? { op: "" }).op
	id_of = || {
		parsed : Try({ id : U64 }, _)
		parsed = Json.parse(line)
		(parsed ?? { id: 0 }).id
	}
	match op {
		"sizes" =>
			match DigitalOcean.sizes!(state.token) {
				Ok(sizes) => same(Ok(Json.to_str_try(sizes) ?? "[]"))
				Err(err) => answer_err(state, err)
			}
		"allowed" => same(Ok(Json.to_str_try(Ledger.allowed(state.config)) ?? "{}"))
		"droplets" =>
			match DigitalOcean.tagged!(state.token, state.config.tag) {
				Ok(droplets) => same(Ok(Json.to_str(droplets)))
				Err(err) => answer_err(state, err)
			}
		"droplet" => {
			id = id_of()
			if !state.lives.any(|life| life.id == id) {
				return same(Refused("droplet ${id.to_str()} is not the guard's"))
			}
			match DigitalOcean.droplet!(state.token, id) {
				Ok(droplet) => same(Ok(Json.to_str(droplet)))
				Err(err) => answer_err(state, err)
			}
		}
		"create" => {
			parsed : Try({ droplet : DigitalOcean.Request }, _)
			parsed = Json.parse(line)
			match parsed {
				Ok({ droplet }) => create!(state, droplet)
				Err(_) => same(Failed("create: not a droplet request"))
			}
		}
		"delete" =>
			match remove!(state, id_of()) {
				Ok(next) => Ok({ next, outcome: Ok("{}") })
				Err(Refused(why)) => same(Refused(why))
				Err(Failed(why)) => same(Failed(why))
				Err(Interrupted) => Err(Interrupted)
			}
		_ => same(Unknown)
	}
}

answer_err : State, [Failed(Str), Interrupted] -> Try({ next : State, outcome : [Ok(Str), Refused(Str), Failed(Str), Unknown] }, [Interrupted])
answer_err = |state, err|
	match err {
		Failed(why) => Ok({ next: state, outcome: Failed(why) })
		Interrupted => Err(Interrupted)
	}

## A droplet, if the owner allows it at its size's price now: made with the
## admin key alone, and written into the ledger.
create! : State, DigitalOcean.Request => Try({ next : State, outcome : [Ok(Str), Refused(Str), Failed(Str), Unknown] }, [Interrupted])
create! = |state, request| {
	sizes =
		match DigitalOcean.sizes!(state.token) {
			Ok(list) => list
			Err(err) => return answer_err(state, err)
		}
	price = (sizes.find_first(|size| size.slug == request.size) ?? { slug: "", available: Bool.False, regions: [], vcpus: 0, price_hourly: 0 }).price_hourly
	match Ledger.allow(state.config, state.lives, request, price, now!()) {
		Err(Refused(why)) => return Ok({ next: state, outcome: Refused(why) })
		Ok({}) => {}
	}
	droplet =
		match DigitalOcean.create!(state.token, { ..request, ssh_keys: [state.config.admin_key_id] }) {
			Ok(made) => made
			Err(err) => return answer_err(state, err)
		}
	next = save!({ ..state, lives: state.lives.append({ id: droplet.id, size: request.size, price_hourly: price, created_ms: now!(), deleted: Alive }) })
	Run.log!("guard: droplet ${droplet.id.to_str()} (${request.size}, $${Text.fixed(price, 4)}/h); month $${Text.fixed(Ledger.spent(next.lives, now!()), 2)} of $${Text.fixed(state.config.monthly_cap_usd, 2)}")
	Ok({ next, outcome: Ok(Json.to_str(droplet)) })
}

## Delete a droplet of the guard's, or one bearing the race tag (a
## leftover of a ledger lost), and record when.
remove! : State, U64 => Try(State, [Refused(Str), Failed(Str), Interrupted])
remove! = |state, id| {
	mine = state.lives.any(|life| life.id == id)
	if !mine {
		droplet = DigitalOcean.droplet!(state.token, id)?
		if !droplet.tags.contains(state.config.tag) {
			return Err(Refused("droplet ${id.to_str()} is not a race droplet"))
		}
	}
	DigitalOcean.delete!(state.token, id)?
	if mine Ok(save!({ ..state, lives: Ledger.deleted(state.lives, id, now!()) })) else Ok(state)
}

## Delete the droplets past their age, and mark deleted the ones
## DigitalOcean no longer has.
reap! : State =>Try(State, [BadFlag(Str), Failed(Str), Interrupted])
reap! = |state| {
	var $state = { ..state, reaped_ms: now!() }
	for id in Ledger.past_age(state.config, state.lives, now!()) {
		Run.log!("guard: droplet ${id.to_str()} is past ${state.config.age_max_minutes.to_str()} minutes: deleting it")
		match remove!($state, id) {
			Ok(next) => {
				$state = next
			}
			Err(Interrupted) => return Err(Interrupted)
			Err(Refused(why)) | Err(Failed(why)) => Run.log!("guard: deleting ${id.to_str()}: ${why}")
		}
	}
	match DigitalOcean.tagged!(state.token, state.config.tag) {
		Ok(tagged) => {
			lives = Ledger.vanished($state.lives, tagged.map(|d| d.id), now!())
			if lives != $state.lives {
				$state = save!({ ..$state, lives })
			}
		}
		Err(Interrupted) => return Err(Interrupted)
		Err(Failed(why)) => Run.log!("guard: listing droplets: ${why}")
	}
	Ok($state)
}

## The ledger written whole, beside and renamed over; a failure is logged
## (the droplets stay counted in memory).
save! : State => State
save! = |state| {
	path = state.config.ledger
	written! = |result|
		match result {
			Ok(_) => Bool.True
			Err(PathErr(err, _)) => {
				Run.log!("guard: the ledger: ${err.to_str()}")
				Bool.False
			}
		}
	if written!(Path.utf8("${path}.new").write_utf8!(Ledger.to_json(state.lives, now!()))) {
		_ = written!(Path.utf8("${path}.new").rename!(Path.utf8(path)))
	}
	state
}

now! : () => I64
now! = || Utc.now!().to_millis_since_epoch().to_i64_wrap()

io_failed : [Interrupted, UnixSocketErr(_)], Str -> [BadFlag(Str), Failed(Str), Interrupted]
io_failed = |err, what|
	match err {
		Interrupted => Interrupted
		UnixSocketErr(e) => Failed("${what}: ${Str.inspect(e)}")
	}
