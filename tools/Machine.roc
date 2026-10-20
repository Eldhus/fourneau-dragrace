import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Sleep
import pf.Stderr
import Checkout
import Keys
import Run
import Text

## Where a script runs: this computer, or a droplet reached with the
## system's ssh and scp. The race is the same on either.
Machine :: [].{
	## A droplet: its user and address, the run's key, this run's own
	## known_hosts, and an ssh ControlPath ("" for none) so every call shares
	## one kept connection.
	Ssh : { user : Str, host : Str, key : Str, known_hosts : Str, control : Str }

	Where : [Local, Remote(Ssh)]

	## A running script, waited for later.
	Running :: { child : Cmd.Child, what : Str }

	## Run a script with bash and return its standard output, its final
	## line breaks trimmed. A failure says how the script ended and the end
	## of what it said on standard error.
	shell! : Where, Str => Try(Str, [Failed(Str), Interrupted])
	shell! = |machine, script| {
		running = Machine.start!(machine, script)?
		Machine.wait!(running)
	}

	## Run a script with `input` on its standard input: how a secret reaches
	## a host, never on a command line.
	shell_input! : Where, Str, Str => Try({}, [Failed(Str), Interrupted])
	shell_input! = |machine, script, input| Machine.shell_bytes!(machine, script, input.to_utf8())

	## Run a script with bytes on its standard input: a tarball.
	shell_bytes! : Where, Str, List(U8) => Try({}, [Failed(Str), Interrupted])
	shell_bytes! = |machine, script, input| {
		argv = Machine.argv(machine, script)
		_ = Run.with_input_bytes!("", argv, input)?
		Ok({})
	}

	## Start a script without waiting for it: scripts on several machines,
	## or several on one, at once.
	start! : Where, Str => Try(Running, [Failed(Str), Interrupted])
	start! = |machine, script| {
		argv = Machine.argv(machine, script)
		match argv {
			[first, .. as rest] =>
				match Cmd.new(OsStr.from_str(first)).args(rest.map(OsStr.from_str)).stdin(Null).stdout(Capture).stderr(Capture).output_limit(NoLimit).spawn!() {
					Ok(child) => Ok(Running.{ child, what: first })
					Err(Interrupted) => Err(Interrupted)
					Err(CmdErr(err)) => Err(Failed("${first}: ${err.to_str()}"))
				}
			[] => Err(Failed("no command"))
		}
	}

	## Wait for a started script: its standard output, as `shell!`.
	wait! : Running => Try(Str, [Failed(Str), Interrupted])
	wait! = |running| {
		ended = finish!(running)?
		match ended.status {
			Exited(0) => Ok(ended.out)
			other => {
				tail = Str.join_with(Text.fields(last_bytes(ended.said, 300).replace_each("\n", " ")), " ")
				Err(Failed(if tail == "" Run.status(other) else "${Run.status(other)}: ${tail}"))
			}
		}
	}

	## Run a script and say how it ended, its output as `shell!`'s: for a
	## script whose exit status is an answer. ssh's own failure is 255.
	attempt! : Where, Str => Try({ status : Cmd.ExitStatus, out : Str }, [Failed(Str), Interrupted])
	attempt! = |machine, script| {
		ended = finish!(Machine.start!(machine, script)?)?
		Ok({ status: ended.status, out: ended.out })
	}

	## Put a local file at `remote` on the machine, executable.
	put! : Where, Str, Str => Try({}, [Failed(Str), Interrupted])
	put! = |machine, local, remote|
		match machine {
			Local =>
				if local == remote {
					Ok({})
				} else {
					Keys.copy!(local, remote)?
					Run.run!("", [], ["chmod", "755", remote])
				}
			Remote(ssh) => {
				_ = Machine.shell!(machine, "mkdir -p ${Run.quote(Checkout.parent(remote))}")?
				_ = Run.output!("", ["scp"].concat(options(ssh)).concat([local, "${ssh.user}@${ssh.host}:${remote}"]))?
				Ok({})
			}
		}

	## The command line that runs a script on the machine.
	argv : Where, Str -> List(Str)
	argv = |machine, script|
		match machine {
			Local => ["bash", "-c", script]
			Remote(ssh) => ["ssh"].concat(options(ssh)).concat(["${ssh.user}@${ssh.host}", "bash -c ${Run.quote(script)}"])
		}

	## End the kept connection, if any.
	close! : Where => {}
	close! = |machine|
		match machine {
			Remote(ssh) if ssh.control != "" => {
				_ = Run.output!("", ["ssh", "-o", "ControlPath=${ssh.control}", "-O", "exit", "x"])
				{}
			}
			_ => {}
		}

	## A new droplet's SSH, waited for (with its first boot's cloud-init): up
	## to 5 minutes. Its sshd can reset connections a while after it answers.
	wait_ssh! : Where => Try({}, [Failed(Str), Interrupted])
	wait_ssh! = |machine| {
		var $tries = 0.U64
		var $last = ""
		while $tries < 60 {
			match Machine.shell!(machine, "cloud-init status --wait > /dev/null; true") {
				Ok(_) => return Ok({})
				Err(Interrupted) => return Err(Interrupted)
				Err(Failed(why)) => {
					$last = why
					Sleep.millis!(5_000)?
					$tries = $tries + 1
				}
			}
		}
		Err(Failed("no SSH after 5 minutes: ${$last}"))
	}

	## Whether the address is this machine's loopback (a local race's).
	is_loopback : Str -> Bool
	is_loopback = |address| address.starts_with("127.") or address == "::1" or address == "localhost"
}

## ssh's options: batch mode, the run's key alone, a new droplet's host key
## trusted on first use into this run's own known_hosts, and a kept
## connection when there is a ControlPath.
options : Machine.Ssh -> List(Str)
options = |ssh| {
	base = [
		"-i",
		ssh.key,
		"-o",
		"BatchMode=yes",
		"-o",
		"IdentitiesOnly=yes",
		"-o",
		"StrictHostKeyChecking=accept-new",
		"-o",
		"UserKnownHostsFile=${ssh.known_hosts}",
		"-o",
		"ConnectTimeout=10",
		"-o",
		"ServerAliveInterval=15",
		"-o",
		"LogLevel=ERROR",
	]
	if ssh.control == "" base else base.concat(["-o", "ControlMaster=auto", "-o", "ControlPath=${ssh.control}", "-o", "ControlPersist=600"])
}

## A started script's end: its status, its output (line breaks trimmed),
## and what it said on standard error, shown here as well.
finish! : Machine.Running => Try({ status : Cmd.ExitStatus, out : Str, said : Str }, [Failed(Str), Interrupted])
finish! = |running|
	match running.child.wait!() {
		Ok(output) => {
			said = output.stderr_utf8_lossy()
			if said != "" {
				_ = Stderr.write!(said)
			}
			Ok({ status: output.status, out: trim_line_breaks(output.stdout_utf8_lossy()), said })
		}
		Err(Interrupted) => Err(Interrupted)
		Err(Closed) => Err(Failed("${running.what}: closed"))
		Err(CmdErr(err)) => Err(Failed("${running.what}: ${err.to_str()}"))
	}

trim_line_breaks : Str -> Str
trim_line_breaks = |text| {
	var $out = text
	while $out.ends_with("\n") {
		$out = $out.drop_suffix("\n")
	}
	$out
}

last_bytes : Str, U64 -> Str
last_bytes = |text, count| {
	bytes = text.to_utf8()
	if bytes.len() <= count text else Str.from_utf8_lossy(bytes.drop_first(bytes.len() - count))
}

expect trim_line_breaks("a\nb\n\n") == "a\nb"
expect Machine.argv(Local, "true") == ["bash", "-c", "true"]
expect {
	ssh = { user: "root", host: "10.0.0.2", key: "k", known_hosts: "kh", control: "" }
	got = Machine.argv(Remote(ssh), "echo 'x'")
	got.last() == Ok("bash -c 'echo '\\''x'\\'''") and got.contains("UserKnownHostsFile=kh") and !got.contains("ControlMaster=auto")
}
expect Machine.is_loopback("127.0.0.1") and !Machine.is_loopback("10.1.2.3")
