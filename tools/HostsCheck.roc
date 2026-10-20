import pf.Env
import pf.Path
import pf.Stdout
import Checkout
import Fetch
import Flags
import Hosts
import JsonValue
import Machine
import RacerHost
import Run
import SiteHost
import Text

## `dragrace hosts check`: the two hosts against this checkout, read only.
## The installs set the boxes up; this says when one has drifted from them.
## It compares the host's SHA256SUMS with the one this checkout and this
## binary make now, has the host check its files against it (sha256sum
## -c), and looks at the rest: the generated configs and credentials there,
## the firewall's rules, the boot without an initramfs, the services up, no
## unit failed, a reboot pending, each binary that updates itself (the
## site, the racer) against the newest release, Tailscale's version and the
## host's place on the tailnet, and who logged in. It reaches each host by
## its tailnet name, prints each finding and fails on any difference.
HostsCheck :: [].{
	## What one host should be, by this checkout: its directory in hosts/,
	## its address, its tailnet name (and tag's), the binaries installed
	## (path, local file), the generated files there, its firewall's rules,
	## its units active, and which of the racer's binary and the site's code
	## it updates from releases.
	Want : { name : Str, ssh : Machine.Ssh, tailnet : Str, binaries : List((Str, Str)), present : List(Str), rules : List(Str), units : List(Str), racer_bin : Bool, site_deploy : Bool }

	Finding : [Good(Str), Diff(Str), Note(Str)]

	command! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	command! = |root, args| {
		flags = Flags.parse(
			args,
			[
				{ name: "site", kind: Value(Hosts.site_tailnet), usage: "the site host's address" },
				{ name: "racer", kind: Value(Hosts.racer_tailnet), usage: "the racer's address (empty: the site host alone)" },
				{ name: "key", kind: Value(Hosts.default_key!()), usage: "the owner's private key (the cook user)" },
			],
		)?
		self = (Env.exe_path!() ? |_| Failed("this binary's path is not known")).display()
		release = newest_release!()?
		owner = fingerprint!("${Flags.value(flags, "key")}.pub")?
		var $differences = 0
		for want in HostsCheck.wants(root, Flags.value(flags, "site"), Flags.value(flags, "racer"), Flags.value(flags, "key"), self) {
			_ = Stdout.line!("== ${want.name} ${want.ssh.host}")
			findings = check_host!(root, want, release, owner) ? |err| as_failed(err, "${want.name} ${want.ssh.host}")
			for finding in findings {
				_ = Stdout.line!(HostsCheck.line(finding))
			}
			$differences = $differences + findings.count_if(is_diff)
		}
		if $differences > 0 {
			_ = Stdout.line!("${$differences.to_str()} differences")
			return Err(Failed("the hosts differ from this checkout"))
		}
		_ = Stdout.line!("in sync")
		Ok({})
	}

	wants : Str, Str, Str, Str, Str -> List(Want)
	wants = |root, site, racer, key, self| {
		site_want = {
			name: "site",
			ssh: Hosts.owner(root, site, key, "site-known-hosts"),
			tailnet: Hosts.site_tailnet,
			binaries: [(SiteHost.agent_binary, self)],
			present: [SiteHost.topic_path],
			rules: Hosts.firewall_rules(["80", "443"]),
			units: ["dragrace-site.service", "dragrace-site-https.socket", "dragrace-site-http.socket", "dragrace-host-agent.timer", "dragrace-site-renew.timer", "apt-daily-upgrade.timer"],
			racer_bin: Bool.False,
			site_deploy: Bool.True,
		}
		if racer == "" {
			return [site_want]
		}
		racer_want = {
			name: "racer",
			ssh: Hosts.owner(root, racer, key, "racer-known-hosts"),
			tailnet: Hosts.racer_tailnet,
			binaries: [(RacerHost.guard_binary, self)],
			present: ["/etc/dragrace-guard/config.json", "/etc/credstore.encrypted/digitalocean-token", "/etc/credstore.encrypted/racer-token"],
			rules: Hosts.firewall_rules([]),
			units: ["dragrace-guard.service", "dragrace-racer.service", "dragrace-racer-check.timer", "apt-daily-upgrade.timer"],
			racer_bin: Bool.True,
			site_deploy: Bool.False,
		}
		[site_want, racer_want]
	}

	## What the check compares but the files, a line each, each line's first
	## word saying what it is.
	probe : Want -> Str
	probe = |want| {
		lines = [
			"for f in ${Str.join_with(want.present, " ")}; do sudo test -e $f || echo missing $f; done",
			"sudo ufw status | sed -n 1p | sed 's/^/ufw /'",
			"sudo ufw show added | grep '^ufw ' | sed 's/^/rule /'",
			"echo tailscale-version $(dpkg-query -W -f='\${Version}' tailscale 2>/dev/null)",
			"echo partuuid $(findmnt -no PARTUUID /) $(sed -n 's/^GRUB_FORCE_PARTUUID=//p' /etc/default/grub.d/40-force-partuuid.cfg 2>/dev/null)",
			"echo booted $(grep -c 'root=PARTUUID.*panic=-1' /proc/cmdline)",
			"for u in ${Str.join_with(want.units, " ")}; do echo active $u $(systemctl is-active $u); done",
			"systemctl --failed --plain --no-legend | awk '{print \"failed\", $1}'",
			"test -e /run/reboot-required && echo reboot-required",
			# -m: every machine's journal, so one written under a machine ID
			# changed after boot (the site host's, 2026-10-16) is read too.
			"sudo journalctl -m -t sshd-session -t sshd --since -${login_days}d -o cat --no-pager | grep '^Accepted ' | sed 's/^/login /'",
		]
		racer = if want.racer_bin ["echo racerbin $(sudo -u racer /var/lib/dragrace-racer/bin/dragrace version 2>/dev/null)"] else []
		site = if want.site_deploy ["echo current $(basename $(readlink /opt/dragrace-site/current))", "ls /opt/dragrace-site/failed 2>/dev/null | sed 's/^/failed-deploy /'"] else []
		"${Str.join_with(lines.concat(racer).concat(site), "; ")}; true"
	}

	## The probe's state: files missing, the firewall, the boot, the units.
	state : Want, List(List(Str)) -> List(Finding)
	state = |want, lines| {
		seen = |key| Str.join_with((lines.find_first(|fields| fields.first() == Ok(key)) ?? []).drop_first(1), " ")
		var $found = lines.keep_oks(|fields|
			match fields {
				["missing", file] => Ok(Diff("${file} is missing"))
				_ => Err(None)
			})
		ufw = seen("ufw")
		if ufw != "Status: active" {
			$found = $found.append(Diff("firewall: \"${ufw}\""))
		}
		rules = Text.sorted(lines.keep_oks(|fields|
			match fields {
				["rule", _, .. as rule] if !rule.is_empty() => Ok(Str.join_with(rule, " "))
				_ => Err(None)
			}))
		expected = Text.sorted(want.rules)
		if rules != expected {
			$found = $found.append(Diff("firewall rules ${quoted(rules)}, want ${quoted(expected)}"))
		} else if ufw == "Status: active" {
			$found = $found.append(Good("firewall on, rules ${quoted(rules)}"))
		}
		parts = Text.fields(seen("partuuid"))
		$found = $found.append(
			match parts {
				[a, b] if a == b => if seen("booted") == "1" Good("booted without an initramfs") else Diff("set up, but this boot came through the initramfs (the fallback: a failed boot?)")
				_ => Diff("boot without an initramfs not set up: \"${seen("partuuid")}\"")
			},
		)
		for fields in lines {
			match fields {
				["active", unit, status] if status != "active" => {
					$found = $found.append(Diff("${unit} is ${status}"))
				}
				["failed", unit] => {
					$found = $found.append(Diff("${unit} failed"))
				}
				_ => {}
			}
		}
		$found = $found.append(Good("${want.units.len().to_str()} units checked"))
		if lines.any(|fields| fields == ["reboot-required"]) {
			$found = $found.append(Note("a reboot is pending (Ubuntu's next update run does it)"))
		}
		$found
	}

	## The racer's binary and the site's code against the newest release.
	versions : Want, List(List(Str)), { newest : Str, site_id : Str } -> List(Finding)
	versions = |want, lines, release| {
		seen = |key| Str.join_with((lines.find_first(|fields| fields.first() == Ok(key)) ?? []).drop_first(1), " ")
		racer =
			if !want.racer_bin {
				[]
			} else if seen("racerbin") == release.newest {
				[Good("racer binary at the newest release, ${Text.take(release.newest, 7)}")]
			} else {
				[Diff("racer binary at \"${Text.take(seen("racerbin"), 7)}\", the newest release ${Text.take(release.newest, 7)} (it updates within 10 minutes, idle)")]
			}
		id = release.site_id
		site =
			if !want.site_deploy {
				[]
			} else if seen("current") == id {
				[Good("site at the newest release's site, ${id}")]
			} else if lines.any(|fields| fields == ["failed-deploy", id]) {
				[Diff("the newest site (${id}) failed to deploy: rolled back to ${seen("current")}")]
			} else {
				[Diff("site at ${seen("current")}, the newest release's is ${id} (the agent deploys within a minute)")]
			}
		racer.concat(site)
	}

	## sshd's "Accepted" lines: any user but cook, any way in but the owner's
	## key, or a line not in sshd's form, differs; the addresses are listed,
	## each with its count, for the owner to know.
	logins : List(List(Str)), Str -> List(Finding)
	logins = |lines, owner| {
		var $found = []
		var $addresses = []
		var $strange = 0
		for fields in lines {
			match fields {
				["login", .. as login] =>
					# Accepted publickey for USER from ADDRESS port N ssh2: TYPE SHA256:...
					match login {
						["Accepted", how, "for", user, "from", address, "port", _, _, _, print] =>
							if how != "publickey" or user != "cook" or print != owner {
								$found = $found.append(Diff("a login not cook's with the owner's key: ${Str.join_with(login, " ")}"))
								$strange = $strange + 1
							} else {
								$addresses = $addresses.append(address)
							}
						_ => {
							$found = $found.append(Diff("a login sshd logged in an unknown form: ${Str.join_with(login, " ")}"))
							$strange = $strange + 1
						}
					}
				_ => {}
			}
		}
		if $strange == 0 {
			$found = $found.append(Good("${$addresses.len().to_str()} logins in ${login_days} days, each cook's with the owner's key"))
		}
		var $counted = []
		for address in Text.sorted($addresses) {
			if !$counted.contains(address) {
				$counted = $counted.append(address)
				$found = $found.append(Note("logged in from ${address}, ${$addresses.count_if(|a| a == address).to_str()} times"))
			}
		}
		$found
	}

	line : Finding -> Str
	line = |finding|
		match finding {
			Good(what) => "  ok    ${what}"
			Diff(what) => "  DIFF  ${what}"
			Note(what) => "  note  ${what}"
		}
}

## How far back the check reads the logins.
login_days : Str
login_days = "14"

is_diff : HostsCheck.Finding -> Bool
is_diff = |finding|
	match finding {
		Diff(_) => Bool.True
		_ => Bool.False
	}

quoted : List(Str) -> Str
quoted = |list| "[${Str.join_with(list.map(Str.inspect), " ")}]"

## The newest build's commit and its site's id, from its build.json.
newest_release! : () => Try({ newest : Str, site_id : Str }, [Failed(Str), Interrupted])
newest_release! = || {
	dir = (Env.create_temp_dir_with_prefix!("dragrace-check-") ? |_| Failed("no temporary directory")).display()
	path = "${dir}/build.json"
	fetched = Fetch.quietly!("https://github.com/Eldhus/fourneau-dragrace/releases/latest/download/build.json", path)
	text = Checkout.read!(path)
	_ = Path.utf8(dir).delete_all!()
	fetched?
	info = JsonValue.parse(text?) ? |_| Failed("build.json: not JSON")
	Ok({ newest: info.get("commits").get("fourneau-dragrace").text(), site_id: Text.take(info.get("files").get("site.tar.gz").text(), 16) })
}

## A public key file's SHA256 fingerprint, as sshd logs it.
fingerprint! : Str => Try(Str, [Failed(Str), Interrupted])
fingerprint! = |path| {
	out = Run.output!("", ["ssh-keygen", "-lf", path]) ? |err| prefix(err, "the owner's key ${path}")
	match Text.fields(out) {
		[_, print, ..] if print.starts_with("SHA256:") => Ok(print)
		_ => Err(Failed("the owner's key ${path}: no fingerprint in \"${out}\""))
	}
}

check_host! : Str, HostsCheck.Want, { newest : Str, site_id : Str }, Str => Try(List(HostsCheck.Finding), [Failed(Str), Interrupted])
check_host! = |root, want, release, owner| {
	out = Machine.shell!(Remote(want.ssh), HostsCheck.probe(want))?
	lines = Text.lines(out).map(Text.fields).keep_if(|fields| !fields.is_empty())
	sums = compare_sums!(root, want)?
	tailnet = compare_tailnet!(root, want, lines)?
	Ok(sums.concat(HostsCheck.state(want, lines)).concat(HostsCheck.versions(want, lines, release)).concat(tailnet).concat(HostsCheck.logins(lines, owner)))
}

## The host's SHA256SUMS against the one this checkout and binary make now,
## then the host's files against it. Only ssh's own failure (255) fails.
compare_sums! : Str, HostsCheck.Want => Try(List(HostsCheck.Finding), [Failed(Str), Interrupted])
compare_sums! = |root, want| {
	files = Hosts.tree!(root, want.name)?
	sums = Hosts.sums!(files, want.binaries)?
	installed = Machine.attempt!(Remote(want.ssh), "sudo cat ${Hosts.sums_path} 2>/dev/null")?
	if installed.status == Exited(255) {
		return Err(Failed("ssh: exit status 255"))
	}
	var $found = []
	if installed.status != Exited(0) {
		$found = $found.append(Diff("no ${Hosts.sums_path} (installed before it): install again"))
	} else if "${installed.out}\n" == sums {
		$found = $found.append(Good("${Hosts.sums_path} as this checkout and binary make it"))
	} else {
		wanted = Text.lines(sums.drop_suffix("\n"))
		have = Text.lines(installed.out)
		extra = have.keep_if(|l| !wanted.contains(l)).map(|l| "        installed  ${l}")
		missing = wanted.keep_if(|l| !have.contains(l)).map(|l| "        wanted     ${l}")
		$found = $found.append(Diff("${Hosts.sums_path} is not as this checkout and binary make it: install again\n${Str.join_with(extra.concat(missing), "\n")}"))
	}
	changed = Machine.attempt!(Remote(want.ssh), "sudo sha256sum -c --quiet ${Hosts.sums_path}")?
	if changed.status == Exited(255) {
		return Err(Failed("ssh: exit status 255"))
	}
	if changed.status == Exited(0) {
		$found = $found.append(Good("each file as ${Hosts.sums_path} lists it"))
	} else {
		$found = $found.append(Diff("files changed since the install (sha256sum -c):\n${Str.join_with(Text.lines(changed.out).map(|l| "        ${l}"), "\n")}"))
	}
	Ok($found)
}

## Tailscale at the pinned version, the host on the tailnet as its name,
## with its tag alone.
compare_tailnet! : Str, HostsCheck.Want, List(List(Str)) => Try(List(HostsCheck.Finding), [Failed(Str), Interrupted])
compare_tailnet! = |root, want, lines| {
	pinned = Hosts.tailscale_version!(root)?
	got = Str.join_with((lines.find_first(|fields| fields.first() == Ok("tailscale-version")) ?? []).drop_first(1), " ")
	version = if got == pinned Good("tailscale at the pinned ${pinned}") else Diff("tailscale at \"${got}\", pinned ${pinned}: install again")
	joined =
		match Hosts.tailscale!(want.ssh) {
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => Diff("tailscale status: ${why}")
			Ok(status) =>
				match Hosts.joined(status, want.tailnet) {
					Ok({}) => Good("on the tailnet as ${want.tailnet}, tag:${want.tailnet} alone")
					Err(NotJoined(why)) => Diff("tailnet: ${why}")
				}
		}
	Ok([version, joined])
}

prefix : [Failed(Str), Interrupted], Str -> [Failed(Str), Interrupted]
prefix = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

as_failed : [Failed(Str), Interrupted], Str -> [BadFlag(Str), Failed(Str), Interrupted]
as_failed = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

test_want : HostsCheck.Want
test_want = {
	name: "racer",
	ssh: { user: "cook", host: "dragrace-racer", key: "k", known_hosts: "kh", control: "" },
	tailnet: "dragrace-racer",
	binaries: [],
	present: ["/etc/x"],
	rules: ["allow in on tailscale0 to any port 22 proto tcp"],
	units: ["a.service"],
	racer_bin: Bool.True,
	site_deploy: Bool.False,
}

expect {
	lines = [["ufw", "Status:", "active"], ["rule", "ufw", "allow", "in", "on", "tailscale0", "to", "any", "port", "22", "proto", "tcp"], ["partuuid", "x", "x"], ["booted", "1"], ["active", "a.service", "active"]]
	HostsCheck.state(test_want, lines).keep_if(is_diff) == []
}
expect {
	lines = [["missing", "/etc/x"], ["ufw", "Status:", "inactive"], ["partuuid", "x", "y"], ["active", "a.service", "failed"], ["failed", "b.service"], ["reboot-required"]]
	# Missing, inactive, no rules, the boot, a unit inactive, a unit failed.
	HostsCheck.state(test_want, lines).keep_if(is_diff).len() == 6
}
expect HostsCheck.versions(test_want, [["racerbin", "abc"]], { newest: "abc", site_id: "" }) == [Good("racer binary at the newest release, abc")]
expect {
	print = "SHA256:owner"
	good = ["login", "Accepted", "publickey", "for", "cook", "from", "100.1.2.3", "port", "5", "ssh2:", "RSA", print]
	bad = ["login", "Accepted", "password", "for", "root", "from", "1.2.3.4", "port", "5", "ssh2:", "RSA", print]
	odd = ["login", "Accepted", "something"]
	HostsCheck.logins([good, good], print) == [Good("2 logins in 14 days, each cook's with the owner's key"), Note("logged in from 100.1.2.3, 2 times")]
	and HostsCheck.logins([bad, odd], print).keep_if(is_diff).len() == 2
}
expect HostsCheck.probe(test_want).contains("echo racerbin")
expect HostsCheck.probe(test_want).contains(Str.concat("dpkg-query -W -f='$", "{Version}' tailscale"))
