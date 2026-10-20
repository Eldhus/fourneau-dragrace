import pf.Env
import pf.Http
import pf.Path
import pf.Sleep
import pf.Utc
import http.Request
import http.Response
import Checkout
import Config
import Guard
import Machine
import Run
import Text

## One race's droplets: per server class a server and its own loader, in
## one region on its private network, made and deleted through the guard,
## each one's life kept for the race's cost.
Cloud :: [].{
	Life : { id : U64, role : Str, class : Str, size : Str, created_ms : I128, deleted_ms : I128, public : Str, private : Str }

	Fleet : { dir : Str, key : Str, lives : List(Life) }

	## How a race droplet starts: root's login by the run's own key (made
	## where the race is driven, never registered with DigitalOcean), no
	## password, no apt timers, and the network limits a load test needs.
	## `ssh_from`, if set, is the one public address SSH is answered from
	## (the racer's): bots flood a new droplet's sshd from its first second.
	user_data : Str, Str -> Str
	user_data = |public, ssh_from| {
		# A JSON list is a YAML flow sequence.
		keys = Json.to_str([public])
		boot =
			if ssh_from == "" {
				""
			} else {
				filter = Json.to_str([
					"nft add table inet race_ssh",
					"nft add chain inet race_ssh input { type filter hook input priority 0 \\; policy accept \\; }",
					"nft add rule inet race_ssh input iifname eth0 tcp dport 22 ip saddr ${ssh_from} accept",
					"nft add rule inet race_ssh input iifname eth0 tcp dport 22 drop",
				])
				"bootcmd: ${filter}\n"
			}
		"#cloud-config\ndisable_root: false\nssh_pwauth: false\nssh_authorized_keys: ${keys}\n${boot}runcmd:\n  - systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer snapd || true\n  - systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer || true\n  - sysctl -w net.core.somaxconn=65535\n  - sysctl -w net.ipv4.tcp_max_syn_backlog=65535\n  - sysctl -w net.ipv4.ip_local_port_range=\"1024 65535\"\n  - sysctl -w net.ipv4.tcp_tw_reuse=1\n  - sysctl -w fs.file-max=2097152\n"
	}

	## This droplet's public IPv4, from DigitalOcean's metadata service: the
	## racer's, the one address race droplets answer SSH from. None races
	## with SSH open to all, as before the filter.
	public_address! : () => Str
	public_address! = || {
		url = "http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address"
		request = Request.from_method(GET).with_uri(url).with_timeout(TimeoutMilliseconds(5_000))
		match Http.send!(request, {}) {
			Ok(response) => {
				text = Str.from_utf8_lossy(Response.body(response)).trim()
				if Response.status(response) == 200 and is_ipv4(text) {
					text
				} else {
					Run.log!("the racer's address: ${Response.status(response).to_str()} ${Str.inspect(Text.take(text, 64))}; race droplets answer SSH from anywhere")
					""
				}
			}
			Err(_) => {
				Run.log!("the racer's address: no answer; race droplets answer SSH from anywhere")
				""
			}
		}
	}

	## The sizes race.json names, each checked (made, available, in the
	## region; a loader bigger than its server), with their prices.
	check_sizes! : Str, Config.Cloud => Try(List((Str, F64)), [Refused(Str), Failed(Str), Interrupted])
	check_sizes! = |socket, cloud| {
		sizes = Guard.sizes!(socket)?
		problems = Cloud.size_problems(sizes, cloud)
		if problems.is_empty() {
			Ok(sizes.map(|s| (s.slug, s.price_hourly)))
		} else {
			Err(Failed("race.json's cloud sizes: ${Str.join_with(problems, "; ")}"))
		}
	}

	size_problems : List(Guard.Size), Config.Cloud -> List(Str)
	size_problems = |sizes, cloud| {
		of = |slug| sizes.find_first(|s| s.slug == slug)
		vcpus = |slug| (of(slug) ?? { slug, available: Bool.False, regions: [], vcpus: 0, price_hourly: 0 }).vcpus
		var $problems = []
		for class in cloud.servers {
			if vcpus(class.loader_size) <= vcpus(class.size) {
				$problems = $problems.append("${class.name}: loader ${class.loader_size} (${vcpus(class.loader_size).to_str()} vCPUs) is not bigger than server ${class.size} (${vcpus(class.size).to_str()})")
			}
		}
		for slug in cloud.servers.join_map(|c| [c.size, c.loader_size]) {
			match of(slug) {
				Err(_) => {
					$problems = $problems.append("${slug}: no such size")
				}
				Ok(size) if !size.available => {
					$problems = $problems.append("${slug}: not available")
				}
				Ok(size) if !size.regions.contains(cloud.region) => {
					$problems = $problems.append("${slug}: not in ${cloud.region} (offered in ${Str.join_with(size.regions, ", ")})")
				}
				Ok(_) => {}
			}
		}
		$problems
	}

	## What the guard would refuse of a race, before a droplet is made: each
	## size at its price now, the region, image and tag, two droplets a class.
	refusals : Config.Cloud, List((Str, F64)), Guard.Allowed -> List(Str)
	refusals = |cloud, prices, allowed| {
		price = |slug| (prices.find_first(|(s, _)| s == slug) ?? (slug, 0)).1
		sizes = cloud.servers.join_map(|c| [(c.name, c.size), (c.name, c.loader_size)])
		var $problems = sizes.keep_oks(
			|(name, slug)| {
				why = Guard.size_problem(allowed, slug, price(slug))
				if why == "" Err(None) else Ok("${name}: ${why}")
			},
		)
		if cloud.region != allowed.region or cloud.image != allowed.image or cloud.tag != allowed.tag {
			$problems = $problems.append("region, image, tag ${cloud.region}, ${cloud.image}, ${cloud.tag}; the guard allows ${allowed.region}, ${allowed.image}, ${allowed.tag}")
		}
		if 2 * cloud.servers.len() > allowed.droplets_max {
			$problems = $problems.append("${cloud.servers.len().to_str()} classes need ${(2 * cloud.servers.len()).to_str()} droplets; the guard allows ${allowed.droplets_max.to_str()}")
		}
		$problems
	}

	## The fleet made: a key pair for the run, then each class's loader and
	## server; each waited for until active with both addresses and
	## answering SSH. A failure leaves the fleet as far as it got, for
	## `destroy!`.
	launch! : Str, Config.Race => { fleet : Fleet, error : Try({}, [Refused(Str), Failed(Str), Interrupted]) }
	launch! = |socket, race| {
		made =
			match Env.create_temp_dir_with_prefix!("dragrace-cloud-") {
				Ok(dir) => dir.display()
				Err(_) => return { fleet: { dir: "", key: "", lives: [] }, error: Err(Failed("no temporary directory")) }
			}
		key = "${made}/key"
		empty = { dir: made, key, lives: [] }
		keyed = Run.run!(made, [], ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "dragrace-race", "-f", key])
		match keyed {
			Err(Failed(why)) => return { fleet: empty, error: Err(Failed(why)) }
			Err(Interrupted) => return { fleet: empty, error: Err(Interrupted) }
			Ok({}) => {}
		}
		public = (Path.utf8("${key}.pub").read_utf8!() ?? "").trim()
		ssh_from = Cloud.public_address!()
		var $fleet = empty
		for class in race.cloud.servers {
			for (role, size) in [("loader", class.loader_size), ("server", class.size)] {
				request = { name: "dragrace-${role}-${class.name}", region: race.cloud.region, size, image: race.cloud.image, ssh_keys: [], tags: [race.cloud.tag], user_data: Cloud.user_data(public, ssh_from), ipv6: Bool.False }
				requested = (Utc.now!()).to_millis_since_epoch()
				match Guard.create!(socket, request) {
					Ok(droplet) => {
						Run.log!("droplet ${droplet.id.to_str()}: ${role} (${size})")
						$fleet = { ..$fleet, lives: $fleet.lives.append({ id: droplet.id, role, class: class.name, size, created_ms: requested, deleted_ms: 0, public: "", private: "" }) }
					}
					Err(err) => return { fleet: $fleet, error: Err(err) }
				}
			}
		}
		for life in $fleet.lives {
			match ready!(socket, $fleet, life) {
				Ok(addressed) => {
					$fleet = { ..$fleet, lives: $fleet.lives.map(|l| if l.id == life.id addressed else l) }
				}
				Err(err) => return { fleet: $fleet, error: Err(err) }
			}
		}
		{ fleet: $fleet, error: Ok({}) }
	}

	## The machine a droplet of the fleet is, over SSH as root.
	machine : Fleet, Life -> Machine.Where
	machine = |fleet, life| Remote({ user: "root", host: life.public, key: fleet.key, known_hosts: "${fleet.dir}/known_hosts", control: "" })

	## A class's pair: its loader and its server.
	pair : Fleet, Str -> Try({ loader : Life, server : Life }, [NotFound])
	pair = |fleet, class| {
		loader = fleet.lives.find_first(|l| l.class == class and l.role == "loader")?
		server = fleet.lives.find_first(|l| l.class == class and l.role == "server")?
		Ok({ loader, server })
	}

	## Delete one droplet, retrying, unless it is deleted already; when.
	delete! : Str, Fleet, U64 => Fleet
	delete! = |socket, fleet, id| {
		match fleet.lives.find_first(|l| l.id == id) {
			Ok(life) if life.deleted_ms != 0 => return fleet
			_ => {}
		}
		var $tries = 0.U64
		var $done = Bool.False
		while !$done and $tries < 5 {
			match Guard.delete!(socket, id) {
				Ok({}) => {
					Run.log!("droplet ${id.to_str()} deleted")
					$done = Bool.True
				}
				Err(Failed(why)) if why.contains("404") => {
					$done = Bool.True
				}
				Err(err) => {
					Run.log!("deleting droplet ${id.to_str()} (attempt ${($tries + 1).to_str()}): ${describe(err)}")
					_ = Sleep.millis!(10_000)
				}
			}
			$tries = $tries + 1
		}
		now = (Utc.now!()).to_millis_since_epoch()
		{ ..fleet, lives: fleet.lives.map(|l| if l.id == id and l.deleted_ms == 0 { ..l, deleted_ms: now } else l) }
	}

	## Delete a class's pair as soon as its racing is over: classes finish at
	## different times, and a droplet waiting is paid for doing nothing.
	release_class! : Str, Fleet, Str => Fleet
	release_class! = |socket, fleet, class| {
		var $fleet = fleet
		for life in fleet.lives.keep_if(|l| l.class == class) {
			$fleet = Cloud.delete!(socket, $fleet, life.id)
		}
		$fleet
	}

	## Delete every droplet (even after an interrupt: one left running costs
	## money every second), then the run's key.
	destroy! : Str, Fleet => Fleet
	destroy! = |socket, fleet| {
		var $gone = fleet
		for life in fleet.lives {
			$gone = Cloud.delete!(socket, $gone, life.id)
		}
		gone = $gone
		if fleet.dir != "" {
			_ = Path.utf8(fleet.dir).delete_all!()
		}
		gone
	}

	## Every droplet's life and cost, in the order made; one not deleted
	## counts until now. Billed per second, a minute at least.
	costs : Fleet, List((Str, F64)), I128 -> List({ role : Str, class : Str, size : Str, price_hourly : F64, seconds : F64, cost_usd : F64 })
	costs = |fleet, prices, now_ms|
		fleet.lives.map(
			|l| {
				end = if l.deleted_ms == 0 now_ms else l.deleted_ms
				seconds = (end - l.created_ms).to_f64() / 1000
				price = (prices.find_first(|(s, _)| s == l.size) ?? (l.size, 0)).1
				billed = if seconds < 60 60 else seconds
				{ role: l.role, class: l.class, size: l.size, price_hourly: price, seconds, cost_usd: price * billed / 3600 }
			},
		)
}

## Active with both addresses (polled every 5 s, ten minutes at most), and
## answering SSH with cloud-init done (five minutes at most).
ready! : Str, Cloud.Fleet, Cloud.Life => Try(Cloud.Life, [Refused(Str), Failed(Str), Interrupted])
ready! = |socket, fleet, life| {
	var $addressed = life
	var $active = Bool.False
	var $polls = 0
	while !$active and $polls < 120 {
		droplet = Guard.droplet!(socket, life.id)?
		public = Guard.address(droplet, "public")
		private = Guard.address(droplet, "private")
		if droplet.status == "active" and public != "" and private != "" {
			$addressed = { ..life, public, private }
			$active = Bool.True
		} else {
			Sleep.millis!(5_000)?
			$polls = $polls + 1
		}
	}
	if !$active {
		return Err(Failed("droplet ${life.id.to_str()} not active after 10 minutes"))
	}
	machine = Cloud.machine(fleet, $addressed)
	var $tries = 0
	while $tries < 60 {
		match Machine.shell!(machine, "cloud-init status --wait > /dev/null; true") {
			Ok(_) => return Ok($addressed)
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(_)) => {
				Sleep.millis!(5_000)?
				$tries = $tries + 1
			}
		}
	}
	Err(Failed("${$addressed.public}: no SSH after 5 minutes"))
}

describe : [Refused(Str), Failed(Str), Interrupted] -> Str
describe = |err|
	match err {
		Refused(why) => why
		Failed(why) => why
		Interrupted => "interrupted"
	}

is_ipv4 : Str -> Bool
is_ipv4 = |text| {
	parts = text.split_on(".")
	parts.len() == 4 and parts.all(|p| !p.is_empty() and p.to_utf8().len() <= 3 and (U64.from_str(p) ?? 999) <= 255)
}

expect is_ipv4("203.0.113.9")
expect !is_ipv4("<html>")
expect !is_ipv4("1.2.3")

expect {
	data = Cloud.user_data("ssh-ed25519 AAA k", "203.0.113.9")
	data.starts_with("#cloud-config\n") and data.contains("ssh_authorized_keys: [\"ssh-ed25519 AAA k\"]") and data.contains("ip saddr 203.0.113.9 accept") and data.contains("tcp_tw_reuse=1")
}

expect !Cloud.user_data("k", "").contains("bootcmd")

expect {
	fleet = { dir: "", key: "", lives: [{ id: 1, role: "server", class: "c", size: "s", created_ms: 0, deleted_ms: 30_000, public: "", private: "" }, { id: 2, role: "loader", class: "c", size: "l", created_ms: 0, deleted_ms: 0, public: "", private: "" }] }
	costs = Cloud.costs(fleet, [("s", 0.036), ("l", 0.125)], 7_200_000)
	costs.map(|c| c.seconds) == [30, 7200] and costs.map(|c| c.cost_usd) == [0.036 * 60 / 3600, 0.125 * 2]
}

expect {
	cloud = { region: "lon1", image: "i", servers: [{ name: "a", label: "", title: "", size: "s", loader_size: "l" }], tag: "t", max_age_minutes: 240 }
	sizes = [{ slug: "s", available: Bool.True, regions: ["lon1"], vcpus: 1, price_hourly: 0.01 }, { slug: "l", available: Bool.True, regions: ["nyc1"], vcpus: 4, price_hourly: 0.1 }]
	Cloud.size_problems(sizes, cloud) == ["l: not in lon1 (offered in nyc1)"]
}

expect {
	cloud = { region: "lon1", image: "i", servers: [{ name: "a", label: "", title: "", size: "s", loader_size: "l" }], tag: "t", max_age_minutes: 240 }
	allowed = { region: "lon1", image: "i", tag: "t", hourly_max_usd: 0.05, monthly_cap_usd: 25, droplets_max: 6, age_max_minutes: 240 }
	Cloud.refusals(cloud, [("s", 0.01), ("l", 0.1)], allowed) == ["a: l costs $0.1000 an hour, the most allowed is $0.0500"]
}
