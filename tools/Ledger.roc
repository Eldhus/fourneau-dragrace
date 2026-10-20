import DigitalOcean
import Guard
import Text
import Time

## The guard's rules and its ledger: what the owner allows (the guard's
## config), and every droplet the guard made, by its own clock, at the
## price it allowed. Pure: the guard (GuardService) asks DigitalOcean and
## keeps the file.
Ledger :: [].{
	## The owner's, on the racer's disk (/etc/dragrace-guard/config.json).
	## `hourly_max_usd` is the most any droplet may cost an hour: whatever
	## size a race asks for under it is allowed, so a class added to race.json
	## needs no install; the month's cap still bounds the spend. The admin
	## key is the one DigitalOcean key a race droplet names (racer install
	## looks it up), so no root password is emailed.
	Config : { region : Str, image : Str, tag : Str, hourly_max_usd : F64, monthly_cap_usd : F64, droplets_max : U64, age_max_minutes : U64, socket : Str, ledger : Str, admin_key_id : U64 }

	## One droplet the guard made.
	Life : { id : U64, size : Str, price_hourly : F64, created_ms : I64, deleted : [Alive, At(I64)] }

	## What is wrong with a config, each problem; none when it is good.
	problems : Config -> List(Str)
	problems = |config| {
		checks = [
			(config.region == "" or config.image == "" or config.tag == "", "region, image and tag are required"),
			(config.admin_key_id == 0, "admin_key_id is required"),
			(config.hourly_max_usd <= 0 or config.hourly_max_usd > hourly_usd_max, "hourly_max_usd: above 0, at most ${hourly_usd_max.to_str()}"),
			(config.monthly_cap_usd <= 0 or config.monthly_cap_usd > cap_usd_max, "monthly_cap_usd: above 0, at most ${cap_usd_max.to_str()}"),
			(config.droplets_max < 1 or config.droplets_max > 16, "droplets_max: 1 to 16"),
			(config.age_max_minutes < 10 or config.age_max_minutes > 24 * 60, "age_max_minutes: 10 to 1440"),
			(config.socket == "" or config.ledger == "", "socket and ledger are required"),
		]
		checks.keep_if(|(bad, _)| bad).map(|(_, why)| why)
	}

	## The limits the racer compares a race with before it makes a droplet.
	allowed : Config -> Guard.Allowed
	allowed = |c| { region: c.region, image: c.image, tag: c.tag, hourly_max_usd: c.hourly_max_usd, monthly_cap_usd: c.monthly_cap_usd, droplets_max: c.droplets_max, age_max_minutes: c.age_max_minutes }

	## Why a droplet asked for, at its size's price now, is refused; Ok when
	## it is allowed.
	allow : Config, List(Life), DigitalOcean.Request, F64, I64 -> Try({}, [Refused(Str)])
	allow = |config, lives, request, price, now_ms| {
		size = Guard.size_problem(Ledger.allowed(config), request.size, price)
		alive = lives.count_if(|life| life.deleted == Alive)
		age_hours = config.age_max_minutes.to_f64() / 60
		spent = Ledger.spent(lives, now_ms)
		committed = Ledger.committed(config, lives, now_ms)
		next = price * age_hours
		why =
			if size != "" {
				size
			} else if request.region != config.region {
				"region ${request.region}, not ${config.region}"
			} else if request.image != config.image {
				"image ${request.image}, not ${config.image}"
			} else if request.tags != [config.tag] {
				"tags [${Str.join_with(request.tags, " ")}], not [${config.tag}]"
			} else if !request.name.starts_with("dragrace-") {
				"name \"${request.name}\""
			} else if !request.ssh_keys.is_empty() {
				"ssh_keys [${Str.join_with(request.ssh_keys.map(|k| k.to_str()), " ")}] (the guard names the admin key alone)"
			} else if alive >= config.droplets_max {
				"${alive.to_str()} droplets alive, the most allowed"
			} else if spent + committed + next > config.monthly_cap_usd {
				"the month's budget: $${Text.fixed(spent, 2)} spent, $${Text.fixed(committed, 2)} committed, $${Text.fixed(next, 2)} more would pass the cap of $${Text.fixed(config.monthly_cap_usd, 2)}"
			} else {
				""
			}
		if why == "" Ok({}) else Err(Refused(why))
	}

	## What a life cost within [from, to): billed per second, at least a
	## minute, its minute counted in the month it began.
	cost : Life, I64, I64 -> F64
	cost = |life, from_ms, to_ms| {
		end =
			match life.deleted {
				At(ms) if ms < to_ms => ms
				_ => to_ms
			}
		start = if life.created_ms < from_ms from_ms else life.created_ms
		if end <= start {
			0
		} else {
			seconds = (end - start).to_f64() / 1000
			billed = if life.created_ms >= from_ms and seconds < billed_seconds_min billed_seconds_min else seconds
			life.price_hourly * billed / 3600
		}
	}

	## The month's spend so far.
	spent : List(Life), I64 -> F64
	spent = |lives, now_ms| {
		from = Time.month_start_ms(now_ms)
		lives.map(|life| Ledger.cost(life, from, now_ms)).sum()
	}

	## What the alive droplets may still cost: each until its age runs out
	## (the guard deletes it then).
	committed : Config, List(Life), I64 -> F64
	committed = |config, lives, now_ms| {
		age_ms = config.age_max_minutes.to_i64_wrap() * 60_000
		lives
			.keep_if(|life| life.deleted == Alive)
			.map(|life| {
				left_ms = life.created_ms + age_ms - now_ms
				if left_ms > 0 life.price_hourly * left_ms.to_f64() / 3_600_000 else 0
			})
			.sum()
	}

	## The droplets alive past their age.
	past_age : Config, List(Life), I64 -> List(U64)
	past_age = |config, lives, now_ms| {
		age_ms = config.age_max_minutes.to_i64_wrap() * 60_000
		lives.keep_if(|life| life.deleted == Alive and now_ms - life.created_ms > age_ms).map(|life| life.id)
	}

	## The lives with one deleted now, if it was alive.
	deleted : List(Life), U64, I64 -> List(Life)
	deleted = |lives, id, now_ms|
		lives.map(|life| if life.id == id and life.deleted == Alive { ..life, deleted: At(now_ms) } else life)

	## The lives with every one DigitalOcean no longer lists marked deleted:
	## made a minute ago at least, since one just made may not be listed yet.
	vanished : List(Life), List(U64), I64 -> List(Life)
	vanished = |lives, listed, now_ms|
		lives.map(|life| if life.deleted == Alive and !listed.contains(life.id) and now_ms - life.created_ms > 60_000 { ..life, deleted: At(now_ms) } else life)

	## The ledger file: Go's JSON (RFC 3339 times, the zero time for a
	## droplet alive), so either guard reads the other's.
	parse : Str -> Try(List(Life), [Failed(Str)])
	parse = |text| {
		parsed : Try(List({ id : U64, size : Str, price_hourly : F64, created : Str, deleted : Str }), _)
		parsed = Json.parse(text)
		rows = parsed ? |_| Failed("the ledger: not a list of lives")
		rows.map_try(|row| {
			created_ms = Time.parse_ms(row.created) ? |BadTime(t)| Failed("the ledger: created ${t}")
			gone =
				if row.deleted == Time.zero {
					Alive
				} else {
					At(Time.parse_ms(row.deleted) ? |BadTime(t)| Failed("the ledger: deleted ${t}"))
				}
			Ok({ id: row.id, size: row.size, price_hourly: row.price_hourly, created_ms, deleted: gone })
		})
	}

	## The file, without the lives deleted over 100 days ago (no month's
	## spend needs them).
	to_json : List(Life), I64 -> Str
	to_json = |lives, now_ms| {
		cutoff = now_ms - 100 * 86_400_000
		kept = lives.keep_if(|life|
			match life.deleted {
				Alive => Bool.True
				At(ms) => ms > cutoff
			})
		rows = kept.map(|life| {
			id: life.id,
			size: life.size,
			price_hourly: life.price_hourly,
			created: Time.format_ms(life.created_ms),
			deleted: match life.deleted {
				Alive => Time.zero
				At(ms) => Time.format_ms(ms)
			},
		})
		Json.to_str_try(rows) ?? "[]"
	}
}

## A cap typed with a zero too many is refused; so is an hourly ceiling past
## $2 (the race's dearest size, c-4, is $0.125).
cap_usd_max : F64
cap_usd_max = 200

hourly_usd_max : F64
hourly_usd_max = 2

billed_seconds_min : F64
billed_seconds_min = 60

test_config : Ledger.Config
test_config = { region: "lon1", image: "ubuntu-26-04-x64", tag: "fourneau-dragrace-race", hourly_max_usd: 0.13, monthly_cap_usd: 25, droplets_max: 4, age_max_minutes: 180, socket: "/run/g", ledger: "/var/l", admin_key_id: 42 }

race_droplet : Str -> DigitalOcean.Request
race_droplet = |size| { name: "dragrace-server-x", region: "lon1", size, image: "ubuntu-26-04-x64", ssh_keys: [], tags: ["fourneau-dragrace-race"], user_data: "#cloud-config\n", ipv6: Bool.False }

## 2026-10-07T07:00:00Z.
seven : I64
seven = 1_791_356_400_000

hour : I64
hour = 3_600_000

life : U64, F64, I64 -> Ledger.Life
life = |id, price, created_ms| { id, size: "c-4", price_hourly: price, created_ms, deleted: Alive }

expect Ledger.problems(test_config) == []
expect Ledger.problems({ ..test_config, hourly_max_usd: 20 }) == ["hourly_max_usd: above 0, at most 2"]
expect Ledger.problems({ ..test_config, hourly_max_usd: 0 }).len() == 1
expect Ledger.problems({ ..test_config, admin_key_id: 0 }) == ["admin_key_id is required"]

# What the owner did not allow is refused.
expect {
	refused = |request, price| Ledger.allow(test_config, [], request, price, seven).is_err()
	refused(race_droplet("c-32"), 1.0)
	and refused(race_droplet("c-2"), 0.15)
	and refused({ ..race_droplet("c-4"), region: "nyc3" }, 0.125)
	and refused({ ..race_droplet("c-4"), image: "debian" }, 0.125)
	and refused({ ..race_droplet("c-4"), tags: [] }, 0.125)
	and refused({ ..race_droplet("c-4"), name: "miner" }, 0.125)
	and refused({ ..race_droplet("c-4"), ssh_keys: [7] }, 0.125)
	and refused(race_droplet("c-4"), 0)
	and !refused(race_droplet("c-4"), 0.125)
	and !refused(race_droplet("s-2vcpu-2gb-amd"), 0.0312)
}

# The month under its cap: c-4 at $0.125 for at most 3 hours commits
# $0.375 each.
expect {
	cap = { ..test_config, monthly_cap_usd: 1.0 }
	two = [life(1, 0.125, seven), life(2, 0.125, seven)]
	third = Ledger.allow(cap, two, race_droplet("c-4"), 0.125, seven)
	# An hour later both are deleted: $0.25 spent, nothing committed.
	later = seven + hour
	gone = Ledger.deleted(Ledger.deleted(two, 1, later), 2, later)
	spent = Ledger.spent(gone, later)
	match third {
		Err(Refused(why)) => why.contains("budget") and spent > 0.2499 and spent < 0.2501 and Ledger.allow(cap, gone, race_droplet("c-4"), 0.125, later).is_ok()
		Ok({}) => Bool.False
	}
}

# A new month starts from what is still alive only.
expect {
	november = 1_793_493_000_000 # 2026-11-01T00:30:00Z
	alive = [life(1, 0.125, november - 2 * hour)]
	Ledger.spent(alive, november) < 0.0626
}

# No more alive than allowed.
expect {
	four = [life(1, 0.006, seven), life(2, 0.006, seven), life(3, 0.006, seven), life(4, 0.006, seven)]
	Ledger.allow(test_config, four, race_droplet("s-1vcpu-512mb-10gb"), 0.006, seven).is_err()
}

# Billed per second, at least a minute, split at the month.
expect {
	start = 1_793_487_600_000 # 2026-10-31T23:00:00Z
	october = 1_790_812_800_000
	november = 1_793_491_200_000
	december = 1_796_083_200_000
	two_hours = { ..life(1, 1, start), deleted: At(start + 2 * hour) }
	short = { ..life(2, 3600, start), deleted: At(start + 1_000) }
	Ledger.cost(two_hours, october, november) == 1 and Ledger.cost(two_hours, november, december) == 1 and Ledger.cost(short, october, november) == 60
}

# Reaping: past their age, and vanished behind the guard's back.
expect {
	lives = [life(1, 0.0625, seven), life(2, 0.0625, seven + 2 * hour), life(3, 0.0625, seven + 2 * hour)]
	now = seven + 2 * hour + 90 * 60_000
	old = Ledger.past_age(test_config, lives, now)
	after = Ledger.vanished(Ledger.deleted(lives, 1, now), [2], now)
	old == [1] and after.keep_if(|l| l.deleted == Alive).map(|l| l.id) == [2]
}

# The file reads Go's, and writes what reads back.
expect {
	go = "[{\"id\":610925728,\"size\":\"c-4\",\"price_hourly\":0.125,\"created\":\"2026-10-20T17:01:16.123456789Z\",\"deleted\":\"0001-01-01T00:00:00Z\"},{\"id\":7,\"size\":\"c-2\",\"price_hourly\":0.0625,\"created\":\"2026-10-20T17:01:16Z\",\"deleted\":\"2026-10-20T18:01:16Z\"}]"
	match Ledger.parse(go) {
		Ok(lives) =>
			lives.len() == 2
			and lives.first() == Ok({ id: 610925728, size: "c-4", price_hourly: 0.125, created_ms: 1_792_515_676_123, deleted: Alive })
			and Ledger.parse(Ledger.to_json(lives, 1_792_515_676_123)) == Ok(lives)
		Err(_) => Bool.False
	}
}

# Lives deleted over 100 days ago are dropped from the file.
expect {
	old = { ..life(1, 1, 0), deleted: At(1_000) }
	Ledger.to_json([old, life(2, 1, 0)], 200 * 86_400_000).contains("\"id\":1,") == Bool.False
}
