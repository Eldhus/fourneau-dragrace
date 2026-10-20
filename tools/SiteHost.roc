import pf.Env
import pf.Path
import pf.Stdout
import Flags
import Hosts
import Keyring
import Machine
import Retry
import Run
import SiteApi

## The site host: one small droplet, up all the time, running the site (a
## roux app) and keeping the races in its database. In short:
##   - cook: the owner's key, sudo. Root login and passwords are off. (Not
##     "admin": Ubuntu's image has an admin group, so useradd refuses it and
##     cloud-init carries on without the user.)
##   - site: no login; runs the site from /opt/dragrace-site/current (a
##     release the host agent unpacked), in /var/lib/dragrace-site: its
##     database, its copies, its two tokens, its certificate. Sandboxed by
##     systemd, allowed to bind ports 80 and 443 and nothing more; it
##     obtains its own certificate (fourneau's ACME, through roux's host).
##   - the host agent (root, a timer, every minute): deploys the newest
##     build's site, rolling back one that does not answer (HostAgent).
##   - the crash alert: the site's failure pushed to the owner's phone
##     (Notify).
##
## Its users are hosts/site.cloud-init.yaml's, the user data it is made
## with in DigitalOcean's panel. Its units and configs are files in
## hosts/site/ (and hosts/common/).
SiteHost :: [].{
	## The host agent: this binary, as installed.
	agent_binary : Str
	agent_binary = "/usr/local/bin/dragrace-host-agent"

	## The crash alert's topic on the site host.
	topic_path : Str
	topic_path = "/etc/dragrace-host/ntfy-topic"

	## `dragrace site install-server`: the site host set up, as cook: its
	## files (hosts/site/, hosts/common/), the host agent (this binary,
	## pinned), the tailnet, the site's two tokens from the owner's keyring
	## (made there if missing), and a first deploy. Run again after a change
	## to hosts/ or the agent; never needed for a new site: a push deploys
	## that. It reaches the host by its tailnet name; -host, by its public
	## address, a host not yet on the tailnet (its first install).
	install! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	install! = |root, args| {
		flags = Flags.parse(
			args,
			[
				{ name: "key", kind: Value(Hosts.default_key!()), usage: "the owner's private key (the cook user)" },
				{ name: "host", kind: Value(Hosts.site_tailnet), usage: "the site host's public address, for its first install" },
			],
		)?
		agent = (Env.exe_path!() ? |_| Failed("this binary's path is not known")).display()
		Path.utf8(Hosts.secrets(root)).create_all!() ? |PathErr(err, _)| Failed("${Hosts.secrets(root)}: ${err.to_str()}")
		_ = Run.run!("", [], ["chmod", "700", Hosts.secrets(root)])?
		first = Hosts.owner(root, Flags.value(flags, "host"), Flags.value(flags, "key"), "site-known-hosts")
		Machine.put!(Remote(first), agent, "/tmp/dragrace-host-agent")?
		Hosts.install!(first, root, "site", [(SiteHost.agent_binary, agent)], [])?
		home = "/opt/dragrace-site"
		state = "/var/lib/dragrace-site"
		setup = Hosts.setup(["80", "443"]).concat(
			[
				"sudo install -m 755 /tmp/dragrace-host-agent ${SiteHost.agent_binary}",
				"rm /tmp/dragrace-host-agent",
				"sudo install -d -m 755 ${home}",
				"sudo install -d -m 700 -o site -g site ${state} ${state}/secrets ${state}/backups",
				"sudo ln -sfn ${home}/current/static ${state}/static",
				# The first boot's dist-upgrade can outlive `cloud-init status
				# --wait`: wait for its lock.
				"sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=1800 install -y -q sqlite3 >/dev/null 2>&1",
				# kTLS: the kernel loads tls only for a CAP_NET_ADMIN process;
				# the site has none, so it is loaded at boot (modules-load.d)
				# and now.
				"sudo modprobe tls",
				"sudo systemctl daemon-reload",
				"sudo systemctl enable --now dragrace-site-renew.timer dragrace-host-agent.timer",
				# The sockets take ports 80 and 443: a site still binding them
				# itself (installed before them) stops first, then starts on
				# them (a host with no site yet skips the start:
				# ConditionPathExists).
				"sudo systemctl stop dragrace-site.service",
				"sudo systemctl enable --now dragrace-site-https.socket dragrace-site-http.socket",
				"sudo systemctl enable dragrace-site.service",
				"sudo systemctl start dragrace-site.service",
			],
		)
		_ = Machine.shell!(Remote(first), Str.join_with(setup, " && "))?
		site = Hosts.join!(first, Hosts.site_tailnet)?
		# The crash alert's topic, root's: systemd hands it to
		# dragrace-site-crashed.service. Not made here: the owner subscribes
		# their phone to it first.
		topic = Keyring.lookup!("ntfy-topic")?
		Machine.shell_input!(Remote(site), "sudo sh -c 'umask 077; cat > ${SiteHost.topic_path}'", "${topic}\n")?
		for name in ["racer-token", "manual-token"] {
			token = Keyring.token!(name)?
			path = "${state}/secrets/${name}"
			Machine.shell_input!(Remote(site), "sudo sh -c 'umask 077; cat > ${path} && chown site:site ${path}'", "${token}\n")?
		}
		Run.log!("deploying the newest build's site (the host agent)")
		deployed = Machine.shell!(Remote(site), "sudo systemctl start dragrace-host-agent.service; sudo systemctl restart dragrace-site.service; sleep 3; systemctl is-active dragrace-site.service")
		match deployed {
			Ok(_) => {}
			Err(Interrupted) => return Err(Interrupted)
			Err(Failed(why)) => return Err(Failed("the site is not up (${why}); its log: ssh cook@${Hosts.site_tailnet} journalctl -u dragrace-site; the agent's: journalctl -u dragrace-host-agent"))
		}
		_ = Stdout.line!("the site is serving https://${Hosts.site_name}/")
		Ok({})
	}

	## `dragrace site race-now [-host H]`: a race asked of the site, with the
	## owner's manual token.
	race_now! : List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	race_now! = |args| {
		flags = Flags.parse(args, [{ name: "host", kind: Value(Hosts.site_name), usage: "the site's address" }])?
		token = Keyring.lookup!("manual-token")?
		site = SiteApi.client("https://${Flags.value(flags, "host")}", token)
		text =
			match SiteApi.call!(site, POST, "/api/requests?kind=race", Err(None), Retry.site) {
				Ok(t) => t
				Err(Refused(why)) | Err(Failed(why)) => return Err(Failed(why))
				Err(Interrupted) => return Err(Interrupted)
			}
		parsed : Try({ id : I64, already : Bool }, _)
		parsed = Json.parse(text)
		answer = parsed ? |_| Failed("the site's answer: ${text}")
		line =
			if answer.already {
				"a race was asked for already (request ${answer.id.to_str()}); the racer takes it soon"
			} else {
				"race asked for (request ${answer.id.to_str()}); the racer takes it within a minute"
			}
		_ = Stdout.line!(line)
		Ok({})
	}
}
