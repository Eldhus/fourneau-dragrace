import pf.Env
import pf.Path
import pf.Sleep
import pf.Stdout
import "../hosts/racer/etc/dragrace-racer/config.json" as racer_config : Str
import "../hosts/racer/etc/systemd/system/dragrace-guard.service" as guard_unit : Str
import "../hosts/racer/etc/systemd/system/dragrace-racer.service" as racer_unit : Str
import "../hosts/racer/etc/systemd/system/dragrace-racer-check.service" as check_unit : Str
import Checkout
import Cloud
import Config
import DigitalOcean
import Flags
import Hosts
import Keyring
import Ledger
import Machine
import Racer
import Run
import Text

## The racer host: a small droplet in the race region, with no inbound
## port but the owner's SSH, over the tailnet (Hosts). Users:
##   - cook: the owner's key, sudo;
##   - guard: runs `dragrace-guard guard` (a copy of this binary the owner
##     installs, never updated by a build), the only reader of the
##     DigitalOcean token (an encrypted systemd credential);
##   - racer: runs `dragrace racer serve` from its state directory, a binary
##     it updates itself from the newest build; reaches DigitalOcean only
##     through the guard's socket (group racer).
##
## Its users are hosts/racer.cloud-init.yaml's, the user data it is made
## with in DigitalOcean's panel. Its units and the racer's config are files
## in hosts/racer/ (and hosts/common/); the guard's config is made at the
## install.
RacerHost :: [].{
	## The guard: this binary, as installed.
	guard_binary : Str
	guard_binary = "/usr/local/bin/dragrace-guard"

	## The guard's config for a race: any size up to `hourly_max` an hour,
	## in race.json's region and image, under the month's cap, so a class
	## added to race.json needs no install; each droplet names the admin key.
	## Its socket is the one hosts/racer's racer config names.
	guard_config : Config.Cloud, F64, F64, U64 -> Ledger.Config
	guard_config = |cloud, hourly_max, cap, admin_key_id| {
		region: cloud.region,
		image: cloud.image,
		tag: cloud.tag,
		hourly_max_usd: hourly_max,
		monthly_cap_usd: cap,
		droplets_max: 6,
		age_max_minutes: cloud.max_age_minutes,
		socket: "/run/dragrace-guard/lines.sock",
		ledger: "/var/lib/dragrace-guard/ledger.json",
		admin_key_id,
	}

	## `dragrace racer install`: the racer set up, as cook: its files
	## (hosts/racer/, hosts/common/), the guard (this binary, pinned) and its
	## config (with the admin key's id, looked up on the account), the
	## racer's first binary, and the two secrets as encrypted credentials,
	## each sent on SSH's standard input: the DigitalOcean token
	## (DIGITALOCEAN_TOKEN, or else the keyring's) and the racer token from
	## the keyring. And the tailnet: it reaches the racer by its tailnet
	## name; -host, by its public address, a racer not yet on the tailnet
	## (its first install).
	install! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	install! = |root, args| {
		flags = Flags.parse(
			args,
			[
				{ name: "host", kind: Value(Hosts.racer_tailnet), usage: "the racer's public address, for its first install" },
				{ name: "key", kind: Value(Hosts.default_key!()), usage: "the owner's private key (the cook user)" },
				{ name: "cap", kind: Value("25"), usage: "the most the races may cost in a month, US dollars" },
				{ name: "hourly-max", kind: Value("0.25"), usage: "the most any droplet may cost an hour, US dollars" },
			],
		)?
		cap = F64.from_str(Flags.value(flags, "cap")) ? |_| BadFlag("-cap: a number")
		hourly_max = F64.from_str(Flags.value(flags, "hourly-max")) ? |_| BadFlag("-hourly-max: a number")
		race = Checkout.race!(root)?
		token = DigitalOcean.checked_token(Keyring.digitalocean!()?)?
		sizes = DigitalOcean.sizes!(token)?
		problems = Cloud.size_problems(sizes, race.cloud)
		if !problems.is_empty() {
			return Err(Failed("race.json's cloud sizes: ${Str.join_with(problems, "; ")}"))
		}
		admin_key_id = DigitalOcean.admin_key_id!(token)?
		config = RacerHost.guard_config(race.cloud, hourly_max, cap, admin_key_id)
		wrong = Ledger.problems(config)
		if !wrong.is_empty() {
			return Err(Failed("guard config: ${Str.join_with(wrong, "; ")}"))
		}
		refusals = Cloud.refusals(race.cloud, sizes.map(|s| (s.slug, s.price_hourly)), Ledger.allowed(config))
		if !refusals.is_empty() {
			return Err(Failed("this guard would refuse race.json: ${Str.join_with(refusals, "; ")}"))
		}
		guard_json = Json.to_str_try(config) ? |_| Failed("the guard's config: not JSON")
		racer_token = Keyring.token!("racer-token")?
		self = (Env.exe_path!() ? |_| Failed("this binary's path is not known")).display()
		Path.utf8(Hosts.secrets(root)).create_all!() ? |PathErr(err, _)| Failed("${Hosts.secrets(root)}: ${err.to_str()}")
		_ = Run.run!("", [], ["chmod", "700", Hosts.secrets(root)])?
		first = Hosts.owner(root, Flags.value(flags, "host"), Flags.value(flags, "key"), "racer-known-hosts")
		Machine.put!(Remote(first), self, "/tmp/dragrace")?
		Hosts.install!(first, root, "racer", [(RacerHost.guard_binary, self)], [("/etc/dragrace-guard/config.json", guard_json)])?
		setup = Hosts.setup([]).concat(
			[
				"sudo install -m 755 /tmp/dragrace ${RacerHost.guard_binary}",
				"sudo install -d -m 700 -o racer -g racer /var/lib/dragrace-racer /var/lib/dragrace-racer/bin",
				# The installer's binary to start from: with no commit beside it,
				# it updates itself to the build the site serves before it
				# races (racer serve).
				"sudo install -m 755 -o racer -g racer /tmp/dragrace /var/lib/dragrace-racer/bin/dragrace",
				"sudo rm -f /var/lib/dragrace-racer/bin/dragrace.commit",
				"rm /tmp/dragrace",
				"sudo install -d -m 700 /etc/credstore.encrypted",
			],
		)
		_ = Machine.shell!(Remote(first), Str.join_with(setup, " && "))?
		racer = Hosts.join!(first, Hosts.racer_tailnet)?
		for (name, secret) in [("digitalocean-token", token), ("racer-token", racer_token)] {
			encrypt = "sudo systemd-creds encrypt --name=${name} - /etc/credstore.encrypted/${name}"
			Machine.shell_input!(Remote(racer), encrypt, secret) ? |err| as_failed(err, "the ${name} credential")
		}
		# Everything above is safe while a race runs (the running guard and
		# racer keep their binaries and configs until restarted); the restart
		# is not, so it waits for the racer to be idle. The guard and the
		# racer restart together: the racer's new config names the new
		# guard's socket.
		start = Str.join_with(
			[
				idle_test,
				"sudo systemctl daemon-reload",
				"sudo systemctl enable --now dragrace-guard.service",
				"sudo systemctl enable dragrace-racer.service",
				"sudo systemctl restart dragrace-guard.service dragrace-racer.service",
				"sudo systemctl enable --now dragrace-racer-check.timer",
				"sleep 3",
				"systemctl is-active dragrace-guard.service dragrace-racer.service",
			],
			" && ",
		)
		when_idle!(racer, start) ? |err| as_failed(err, "not running; the logs: ssh cook@${Hosts.racer_tailnet} journalctl -u dragrace-guard -u dragrace-racer")
		_ = Stdout.line!("the racer is serving: guard cap $${Text.fixed(cap, 2)} a month, any size up to $${Text.fixed(hourly_max, 4)} an hour")
		Ok({})
	}
}

## Fails with `busy_status` while the racer races a run (its `racing`
## file). In the same command as the restart, so a run can start only in
## the instant between. A racer restarted before it has recorded its run
## records nothing: the request stays and is taken again.
busy_status : I32
busy_status = 75

idle_test : Str
idle_test = "if sudo test -e /var/lib/dragrace-racer/racing; then exit ${busy_status.to_str()}; fi"

## Run `start` (which begins with the idle test) until the racer is idle
## and it runs: a minute apart, five hours at most, past the longest race
## (its droplets' age of 240 minutes, and the download, launch and
## teardown around it).
when_idle! : Machine.Ssh, Str => Try({}, [Failed(Str), Interrupted])
when_idle! = |racer, start| {
	var $wait = 1
	while $wait <= 300 {
		ended = Machine.attempt!(Remote(racer), start)?
		match ended.status {
			Exited(0) => return Ok({})
			Exited(code) if code == busy_status => {
				if $wait == 1 {
					Run.log!("a race is running: the racer restarts when it ends (asking each minute)")
				}
				Sleep.millis!(60_000)?
			}
			other => return Err(Failed(Run.status(other)))
		}
		$wait = $wait + 1
	}
	Err(Failed("the racer was still racing after 300 minutes: install again later"))
}

as_failed : [Failed(Str), Interrupted], Str -> [BadFlag(Str), Failed(Str), Interrupted]
as_failed = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

# The racer's config (hosts/racer/) names the line guard's socket and the
# owner's site; only the guard's unit loads the DigitalOcean token, and its
# socket lets the racer's group in.
expect {
	config = Racer.parse_config(racer_config)
	config == Ok({ site: "https://${Hosts.site_name}", guard: Lines(RacerHost.guard_config(test_cloud, 0.25, 25, 42).socket), repository: "Eldhus/fourneau-dragrace", state: "/var/lib/dragrace-racer" })
}
expect guard_unit.contains("LoadCredentialEncrypted=digitalocean-token") and guard_unit.contains("User=guard") and guard_unit.contains("UMask=0007")
expect !racer_unit.contains("digitalocean-token") and !check_unit.contains("digitalocean-token")

test_cloud : Config.Cloud
test_cloud = { region: "lon1", image: "ubuntu-26-04-x64", tag: "t", max_age_minutes: 180, servers: [] }

expect {
	config = RacerHost.guard_config(test_cloud, 0.25, 25, 42)
	Ledger.problems(config) == [] and config.socket == "/run/dragrace-guard/lines.sock"
}
expect Ledger.problems(RacerHost.guard_config(test_cloud, 20, 25, 42)) != []
expect Ledger.problems(RacerHost.guard_config(test_cloud, 0.25, 25, 0)) != []
expect idle_test == "if sudo test -e /var/lib/dragrace-racer/racing; then exit 75; fi"
