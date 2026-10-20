import pf.Env
import pf.OsStr
import pf.Path
import pf.Sleep
import Checkout
import Hash
import JsonValue
import Machine
import Run
import Text

## The owner's two hosts, the site host and the racer, as the installs set
## them up and `hosts check` reads them. Each host's files are in hosts/
## (common/ on both, then site/ or racer/), each at its install path; an
## install puts them in place and lists them, with the binaries it
## installs, in SHA256SUMS on the host.
##
## The owner reaches the hosts' SSH over the owner's tailnet (Tailscale)
## alone. Each host joins it tagged with its own name (tag:dragrace-site,
## tag:dragrace-racer), a device of no user's; the tailnet's policy grants
## the tags nothing, so a host taken over reaches no other device. Its
## firewall takes port 22 on tailscale0 only. A host's first install
## reaches it by its public address (-host): the install joins it with a
## one-off auth key (TAILSCALE_AUTH_KEY), reaches it again by its tailnet
## name, and only then closes the public port 22. Every install after
## reaches it by the name.
##
## Locked out (Tailscale down on a host, its public 22 closed):
## DigitalOcean's Droplet Console is SSH over the network, so closed too;
## the way in is the recovery ISO (power off, boot it from the panel's
## Recovery tab, mount the disk, `ufw allow 22/tcp` in a chroot or the rule
## in /etc/ufw/user.rules).
Hosts :: [].{
	site_tailnet : Str
	site_tailnet = "dragrace-site"

	racer_tailnet : Str
	racer_tailnet = "dragrace-racer"

	## The site's name (an A record): the one hosts/ names.
	site_name : Str
	site_name = "fourneau.y2kbugger.com"

	## Where an install lists what it put there, with each SHA-256.
	sums_path : Str
	sums_path = "/etc/dragrace-host/SHA256SUMS"

	## out/secrets: what a setup made here, never committed (the hosts'
	## pinned keys).
	secrets : Str -> Str
	secrets = |root| "${Checkout.out(root)}/secrets"

	## A host of the owner's, as cook, with the owner's key. Its host key is
	## trusted at the first install and kept in out/secrets.
	owner : Str, Str, Str, Str -> Machine.Ssh
	owner = |root, host, key, known_hosts| { user: "cook", host, key, known_hosts: "${Hosts.secrets(root)}/${known_hosts}", control: "" }

	## The owner's private key: ~/.ssh/id_rsa.
	default_key! : () => Str
	default_key! = || "${Env.var_str!(OsStr.from_str("HOME")) ?? ""}/.ssh/id_rsa"

	## A host's files in hosts/ (common/, then its own): each install path
	## without its leading slash, and the file here, in order.
	tree! : Str, Str => Try(List((Str, Str)), [Failed(Str), Interrupted])
	tree! = |root, host| {
		var $files = []
		for dir in ["common", host] {
			base = "${root}/hosts/${dir}"
			for relative in Checkout.files_under!(base)? {
				$files = $files.append((relative, "${base}/${relative}"))
			}
		}
		sorted = $files.sort_with(|(a, _), (b, _)| Text.order(a, b))
		var $previous = ""
		for (name, _) in sorted {
			if name == $previous {
				return Err(Failed("hosts/: /${name} twice"))
			}
			$previous = name
		}
		Ok(sorted)
	}

	## The SHA256SUMS an install writes, as sha256sum prints it: each of the
	## host's files and each binary it installs (path, local file). The
	## racer's own binary is not one: it replaces itself.
	sums! : List((Str, Str)), List((Str, Str)) => Try(Str, [Failed(Str), Interrupted])
	sums! = |files, binaries| {
		all = binaries.concat(files.map(|(name, path)| ("/${name}", path))).sort_with(|(a, _), (b, _)| Text.order(a, b))
		lines = all.map_try!(|(path, local)| Hash.file!(local).map_ok(|sum| "${sum}  ${path}\n"))?
		Ok(Str.join_with(lines, ""))
	}

	## Put the host's files in place as root, with SHA256SUMS and the
	## generated files (path, content; not listed: this checkout does not
	## hold what they say), from one tarball on SSH's standard input: each
	## file root's, mode 644, its directory made if missing.
	install! : Machine.Ssh, Str, Str, List((Str, Str)), List((Str, Str)) => Try({}, [Failed(Str), Interrupted])
	install! = |ssh, root, host, binaries, generated| {
		files = Hosts.tree!(root, host)?
		sums = Hosts.sums!(files, binaries)?
		dir = (Env.create_temp_dir_with_prefix!("dragrace-host-") ? |_| Failed("no temporary directory")).display()
		installed = install_from!(ssh, dir, files, [(Hosts.sums_path, sums)].concat(generated))
		_ = Path.utf8(dir).delete_all!()
		installed
	}

	## The script that goes with the host's files: the first boot's
	## cloud-init waited for (DigitalOcean's per-instance script can replace
	## the machine id late, and the racer's credentials, encrypted before it,
	## would stop decrypting at the next restart), Tailscale at its pinned
	## version, the firewall (incoming refused but for the `public` ports and
	## SSH from the tailnet; it was cloud-init's alone, whose final stage
	## stops at a failed package step, leaving ufw inactive while `status`
	## says done), a boot without an initramfs (GRUB_FORCE_PARTUUID, Ubuntu's
	## own cloud images' setting: a failed boot falls back to the initramfs,
	## which can panic on a 512 MB droplet), sshd reloaded, a 512 MiB swap
	## file (a 512 MB droplet thrashed in its first boot's package checks),
	## and Ubuntu's update-notifier and motd timers off (nobody logs in to
	## read them; on the racer they took a CPU for minutes).
	setup : List(Str) -> List(Str)
	setup = |public| {
		apt = "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=1800"
		firewall = ["sudo ufw default deny incoming >/dev/null"].concat(Hosts.firewall_rules(public).map(|rule| "sudo ufw ${rule} >/dev/null"))
		[
			"(cloud-init status --wait >/dev/null; true)",
			"${apt} install -y -q ufw >/dev/null 2>&1",
			"${apt} update -q >/dev/null 2>&1",
			"${apt} install -y -q --allow-downgrades tailscale >/dev/null 2>&1",
			Str.join_with(firewall, " && "),
			"sudo ufw --force enable >/dev/null",
			"sudo ufw status | grep -q '^Status: active'",
			"echo \"GRUB_FORCE_PARTUUID=$(findmnt -no PARTUUID /)\" | sudo tee /etc/default/grub.d/40-force-partuuid.cfg >/dev/null",
			"grep -q '^GRUB_FORCE_PARTUUID=[0-9a-f-]\\{36\\}$' /etc/default/grub.d/40-force-partuuid.cfg",
			"sudo update-grub 2>/dev/null",
			"sudo sshd -t && sudo systemctl reload ssh",
			"sudo systemctl daemon-reload",
			"(test -e /swapfile || (sudo fallocate -l 512M /swapfile && sudo chmod 600 /swapfile && sudo mkswap -q /swapfile))",
			"(swapon --show=NAME --noheadings | grep -q /swapfile || sudo swapon /swapfile)",
			"(grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null)",
			"sudo systemctl disable --now update-notifier-download.timer update-notifier-motd.timer motd-news.timer 2>/dev/null; true",
		]
	}

	## A host's firewall rules, as `ufw show added` lists them: its public
	## ports, and SSH from the tailnet.
	firewall_rules : List(Str) -> List(Str)
	firewall_rules = |public| public.map(|port| "allow ${port}/tcp").append(tailnet_ssh_rule)

	## The Tailscale version hosts/common/etc/apt/preferences.d/tailscale
	## pins (an apt preferences file: `Pin: version V`).
	tailscale_version! : Str => Try(Str, [Failed(Str)])
	tailscale_version! = |root| {
		text = Checkout.read!("${root}/${tailscale_pin}")?
		match Text.lines(text).find_first(|line| line.starts_with("Pin: version ")) {
			Ok(line) => Ok(line.drop_prefix("Pin: version ").trim())
			Err(_) => Err(Failed("${tailscale_pin} pins no version"))
		}
	}

	## Tailscale's state on the host, from `tailscale status --json` (its keys
	## are PascalCase: read as a JSON value). Logged out, the command fails
	## but still prints its state; only ssh's own failure (255) is one here.
	tailscale! : Machine.Ssh => Try({ state : Str, dns_name : Str, tags : List(Str) }, [Failed(Str), Interrupted])
	tailscale! = |ssh| {
		ended = Machine.attempt!(Remote(ssh), "sudo tailscale status --json")?
		if ended.status == Exited(255) {
			return Err(Failed("ssh ${ssh.host}: exit status 255"))
		}
		value = JsonValue.parse(ended.out) ? |_| Failed("tailscale status: not JSON")
		me = value.get("Self")
		Ok({ state: value.get("BackendState").text(), dns_name: me.get("DNSName").text(), tags: me.get("Tags").items().map(JsonValue.text) })
	}

	## Whether the host is on the tailnet as `name`, with its tag alone.
	joined : { state : Str, dns_name : Str, tags : List(Str) }, Str -> Try({}, [NotJoined(Str)])
	joined = |status, name|
		if status.state != "Running" {
			Err(NotJoined("tailscale is \"${status.state}\", not Running"))
		} else if !status.dns_name.starts_with("${name}.") {
			Err(NotJoined("on the tailnet as \"${status.dns_name}\", not ${name} (another device has the name?)"))
		} else if status.tags != ["tag:${name}"] {
			Err(NotJoined("tagged [${Str.join_with(status.tags, " ")}], not tag:${name} alone"))
		} else {
			Ok({})
		}

	## Put the host on the tailnet as `name` if it is not, pin its host keys
	## under the name, reach it by the name, and close its public SSH; the
	## host by the name. The keys pinned are the ones already trusted for its
	## address: nothing is trusted anew.
	join! : Machine.Ssh, Str => Try(Machine.Ssh, [Failed(Str), Interrupted])
	join! = |ssh, name| {
		status = Hosts.tailscale!(ssh)?
		match Hosts.joined(status, name) {
			Ok({}) => {}
			Err(NotJoined(why)) => {
				key = (Env.var_str!(OsStr.from_str("TAILSCALE_AUTH_KEY")) ?? "").trim()
				if key == "" {
					return Err(Failed("${ssh.host} is not on the tailnet as ${name} (${why}): set TAILSCALE_AUTH_KEY to a one-off auth key tagged tag:${name}"))
				}
				Run.log!("joining the tailnet as ${name}")
				up = "sudo tailscale up --auth-key=file:/dev/stdin --hostname=${name} --advertise-tags=tag:${name} --accept-dns=false --accept-routes=false --ssh=false"
				Machine.shell_input!(Remote(ssh), up, "${key}\n") ? |err| prefix(err, "tailscale up")
				again = Hosts.tailscale!(ssh)?
				Hosts.joined(again, name) ? |NotJoined(still)| Failed(still)
			}
		}
		_ = Machine.shell!(Remote(ssh), "sudo tailscale set --auto-update=false --webclient=false")?
		by_name = { ..ssh, host: name }
		if ssh.host != name {
			pin_under!(ssh.known_hosts, ssh.host, name)?
		}
		var $reached = Bool.False
		var $tries = 0
		while !$reached and $tries < 12 {
			if $tries > 0 {
				Sleep.millis!(5_000)?
			}
			$reached = Machine.shell!(Remote(by_name), "true").is_ok()
			$tries = $tries + 1
		}
		if !$reached {
			return Err(Failed("${ssh.host} is on the tailnet but not reached as ${name} from here in a minute: its public SSH stays open"))
		}
		close = "if sudo ufw show added | grep -qxF ${Run.quote("ufw ${public_ssh_rule}")}; then sudo ufw delete ${public_ssh_rule} >/dev/null; fi"
		_ = Machine.shell!(Remote(by_name), close)?
		Ok(by_name)
	}
}

## The file that pins Tailscale's version on every host.
tailscale_pin : Str
tailscale_pin = "hosts/common/etc/apt/preferences.d/tailscale"

## The firewall's one way to SSH: from the tailnet.
tailnet_ssh_rule : Str
tailnet_ssh_rule = "allow in on tailscale0 to any port 22 proto tcp"

## The rule a droplet is made with (hosts/*.cloud-init.yaml) and the first
## install removes.
public_ssh_rule : Str
public_ssh_rule = "allow 22/tcp"

## The files and the written ones (path, content), each written to `dir`,
## in one tarball of files alone (no directory entries: tar never resets an
## existing directory's mode), extracted as root at /. -m: the files' times
## are the install's.
install_from! : Machine.Ssh, Str, List((Str, Str)), List((Str, Str)) => Try({}, [Failed(Str), Interrupted])
install_from! = |ssh, dir, files, written| {
	var $all = files
	var $index = 0.U64
	for (path, content) in written.sort_with(|(a, _), (b, _)| Text.order(a, b)) {
		local = "${dir}/${$index.to_str()}"
		Path.utf8(local).write_utf8!(content) ? |PathErr(err, _)| Failed("${local}: ${err.to_str()}")
		$all = $all.append((path.drop_prefix("/"), local))
		$index = $index + 1
	}
	staging = "${dir}/staging"
	for (name, source) in $all {
		link = "${staging}/${name}"
		Path.utf8(Checkout.parent(link)).create_all!() ? |PathErr(err, _)| Failed("${link}: ${err.to_str()}")
		Path.utf8(source).symlink!(Path.utf8(link), File) ? |PathErr(err, _)| Failed("${link}: ${err.to_str()}")
	}
	tar = "${dir}/host.tar"
	names = Text.sorted($all.map(|(name, _)| name))
	Run.run!(staging, [], ["tar", "--create", "--dereference", "--format=gnu", "--owner=0", "--group=0", "--numeric-owner", "--mode=u=rw,go=r", "--file", tar].concat(names))?
	Run.run!("", [], ["gzip", "-n", "-f", tar])?
	bytes = Path.utf8("${tar}.gz").read_bytes!() ? |PathErr(err, _)| Failed("${tar}.gz: ${err.to_str()}")
	Machine.shell_bytes!(Remote(ssh), "sudo tar -xzm -C /", bytes)
}

## Give `name`, in a known_hosts file, the keys the file holds for `host`,
## in place of any it had. Each line of the file is ssh's: names
## (comma-separated), key type, key.
pin_under! : Str, Str, Str => Try({}, [Failed(Str), Interrupted])
pin_under! = |known_hosts, host, name| {
	text = Checkout.read!(known_hosts)?
	var $kept = []
	var $keys = []
	for line in Text.lines(text.trim()) {
		fields = Text.fields(line)
		match fields {
			[names, .. as rest] if rest.len() >= 2 => {
				listed = names.split_on(",")
				if listed.contains(host) {
					$keys = $keys.append("${name} ${Str.join_with(rest, " ")}")
				}
				if !listed.contains(name) {
					$kept = $kept.append(line)
				}
			}
			_ => {
				$kept = $kept.append(line)
			}
		}
	}
	if $keys.is_empty() {
		return Err(Failed("${known_hosts} holds no key for ${host}"))
	}
	Path.utf8(known_hosts).write_utf8!("${Str.join_with($kept.concat($keys), "\n")}\n") ? |PathErr(err, _)| Failed("${known_hosts}: ${err.to_str()}")
	Ok({})
}

prefix : [Failed(Str), Interrupted], Str -> [Failed(Str), Interrupted]
prefix = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

expect Hosts.firewall_rules(["80", "443"]) == ["allow 80/tcp", "allow 443/tcp", "allow in on tailscale0 to any port 22 proto tcp"]
expect Hosts.firewall_rules([]) == ["allow in on tailscale0 to any port 22 proto tcp"]
expect Hosts.joined({ state: "Running", dns_name: "dragrace-racer.tail1.ts.net.", tags: ["tag:dragrace-racer"] }, "dragrace-racer") == Ok({})
expect Hosts.joined({ state: "Running", dns_name: "dragrace-racer-1.tail1.ts.net.", tags: ["tag:dragrace-racer"] }, "dragrace-racer").is_err()
expect Hosts.joined({ state: "Running", dns_name: "dragrace-racer.tail1.ts.net.", tags: ["tag:dragrace-racer", "tag:x"] }, "dragrace-racer").is_err()
expect Hosts.joined({ state: "NeedsLogin", dns_name: "", tags: [] }, "dragrace-racer").is_err()
