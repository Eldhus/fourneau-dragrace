import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Utc

## Running other programs, and saying so: every command the tool runs is
## logged first (`$ git ls-files ...`), its output goes to standard error so
## standard output stays the command's own (a table, a JSON line), and a
## failure says which program and how it ended.
Run :: [].{
	## A line on standard error, after the time: `dragrace: 09:30:00 ...`.
	## The time is UTC, as on the hosts.
	log! : Str => {}
	log! = |text| {
		clock =
			match Utc.now!().to_iso_8601().split_first("T") {
				Ok({ after, .. }) => after.drop_suffix("Z")
				Err(_) => "?"
			}
		_ = Stderr.line!("dragrace: ${clock} ${text}")
		{}
	}

	## Run `argv` in `dir` with `env` added, its output shown, and require it
	## to succeed.
	run! : Str, List((Str, Str)), List(Str) => Try({}, [Failed(Str), Interrupted])
	run! = |dir, env, argv| {
		Run.log!("$ ${Str.join_with(argv, " ")}")
		match command(dir, env, argv) {
			Ok(cmd) =>
				match cmd.stdout(InheritStderr).call!() {
					Ok({}) => Ok({})
					Err(Interrupted) => Err(Interrupted)
					Err(BadExitStatus(output)) => Err(Failed("${program(argv)}: ${status(output.status)}"))
					Err(CmdErr(err)) => Err(Failed("${program(argv)}: ${err.to_str()}"))
				}
			Err(Empty) => Err(Failed("run: no program"))
		}
	}

	## Run `argv` in `dir` and return its standard output, trimmed; its
	## standard error is shown.
	output! : Str, List(Str) => Try(Str, [Failed(Str), Interrupted])
	output! = |dir, argv|
		Run.output_bytes!(dir, argv).map_ok(|bytes| Str.from_utf8_lossy(bytes).trim())

	## Run `argv` in `dir` and return its standard output as it is.
	output_bytes! : Str, List(Str) => Try(List(U8), [Failed(Str), Interrupted])
	output_bytes! = |dir, argv|
		match command(dir, [], argv) {
			Ok(cmd) =>
				match cmd.stdout(Capture).stderr(Inherit).output_limit(NoLimit).run!() {
					Ok(output) =>
						match output.status {
							Exited(0) => Ok(output.stdout_bytes)
							other => Err(Failed("${Str.join_with(argv, " ")}: ${status(other)}"))
						}
					Err(Interrupted) => Err(Interrupted)
					Err(CmdErr(err)) => Err(Failed("${Str.join_with(argv, " ")}: ${err.to_str()}"))
				}
			Err(Empty) => Err(Failed("output: no program"))
		}

	## Run `argv` with `input` on its standard input and return its standard
	## output, trimmed. How a secret reaches a program, never on a command
	## line.
	with_input! : Str, List(Str), List(U8) => Try(Str, [Failed(Str), Interrupted])
	with_input! = |dir, argv, input|
		Run.with_input_bytes!(dir, argv, input).map_ok(|bytes| Str.from_utf8_lossy(bytes).trim())

	## Run `argv` with `input` on its standard input and return its standard
	## output as it is, byte for byte.
	with_input_bytes! : Str, List(Str), List(U8) => Try(List(U8), [Failed(Str), Interrupted])
	with_input_bytes! = |dir, argv, input|
		match command(dir, [], argv) {
			Ok(cmd) =>
				match cmd.stdin(Bytes(input)).stdout(Capture).stderr(Inherit).output_limit(NoLimit).run!() {
					Ok(output) =>
						match output.status {
							Exited(0) => Ok(output.stdout_bytes)
							other => Err(Failed("${program(argv)}: ${status(other)}"))
						}
					Err(Interrupted) => Err(Interrupted)
					Err(CmdErr(err)) => Err(Failed("${program(argv)}: ${err.to_str()}"))
				}
			Err(Empty) => Err(Failed("with_input: no program"))
		}

	## A secret from the environment, or a systemd credential of that name
	## (LoadCredentialEncrypted=): never in a unit file or on a command line.
	## "" when there is neither.
	secret! : Str, Str => Try(Str, [Failed(Str)])
	secret! = |variable, credential| {
		from_env = (Env.var_str!(OsStr.from_str(variable)) ?? "").trim()
		if from_env != "" {
			return Ok(from_env)
		}
		dir = Env.var_str!(OsStr.from_str("CREDENTIALS_DIRECTORY")) ?? ""
		if dir == "" {
			return Ok("")
		}
		text = Path.utf8("${dir}/${credential}").read_utf8!() ? |PathErr(err, _)| Failed("credential ${credential}: ${err.to_str()}")
		Ok(text.trim())
	}

	## A string as one shell word: `it's` is `'it'\''s'`.
	quote : Str -> Str
	quote = |text| "'${text.replace_each("'", "'\\''")}'"

	## How a command ended, as Go's os/exec says it.
	status : Cmd.ExitStatus -> Str
	status = |ended|
		match ended {
			Exited(code) => "exit status ${code.to_str()}"
			Signaled(signal) => "signal ${signal.to_str()}"
		}
}

command : Str, List((Str, Str)), List(Str) -> Try(Cmd.Command, [Empty])
command = |dir, env, argv|
	match argv {
		[first, .. as args] => {
			base = Cmd.new(OsStr.from_str(first)).args(args.map(OsStr.from_str))
			with_env = base.envs(env.map(|(name, value)| (OsStr.from_str(name), OsStr.from_str(value))))
			Ok(if dir == "" with_env else with_env.cwd(Path.utf8(dir)))
		}
		[] => Err(Empty)
	}

program : List(Str) -> Str
program = |argv| argv.first() ?? "?"

expect Run.quote("it's") == "'it'\\''s'"
expect Run.quote("") == "''"
expect Run.quote("a b") == "'a b'"
expect Run.status(Exited(3)) == "exit status 3"
