import pf.Cmd
import pf.Duration
import pf.Path
import Run
import Text

## SHA-256, by coreutils' `sha256sum` (basic-cli has no hash): of bytes,
## of a file, and of a stream of parts written to one running sha256sum, so
## a key hashes exactly the bytes keys.go hashed.
Hash :: [].{
	## A running hash: parts written in order, then `finish!`.
	Digest :: { child : Cmd.Child }

	## The SHA-256 of bytes, hex.
	bytes! : List(U8) => Try(Str, [Failed(Str), Interrupted])
	bytes! = |input| {
		printed = Run.with_input!("", ["sha256sum"], input)?
		digest(printed)
	}

	## The SHA-256 of a file, hex.
	file! : Str => Try(Str, [Failed(Str), Interrupted])
	file! = |path| {
		printed = Run.output!("", ["sha256sum", "--", path])?
		digest(printed)
	}

	## A stream to write parts to.
	start! : () => Try(Digest, [Failed(Str), Interrupted])
	start! = || {
		spawned = Cmd.new("sha256sum").stdin(Pipe).stdout(Capture).stderr(Capture).spawn!()
		match spawned {
			Ok(child) => Ok(Digest.{ child })
			Err(Interrupted) => Err(Interrupted)
			Err(CmdErr(err)) => Err(Failed("sha256sum: ${err.to_str()}"))
		}
	}

	## Write bytes to the stream.
	write! : Digest, List(U8) => Try({}, [Failed(Str), Interrupted])
	write! = |stream, part|
		match stream.child.write_bytes!(part, Duration.minutes(1)) {
			Ok({}) => Ok({})
			Err(Interrupted) => Err(Interrupted)
			Err(Closed) => Err(Failed("sha256sum: closed"))
			Err(CmdErr(err)) => Err(Failed("sha256sum: ${err.to_str()}"))
		}

	## Write a string to the stream.
	write_str! : Digest, Str => Try({}, [Failed(Str), Interrupted])
	write_str! = |stream, text| Hash.write!(stream, text.to_utf8())

	## Write a file's bytes to the stream.
	write_file! : Digest, Str => Try({}, [Failed(Str), Interrupted])
	write_file! = |stream, path| {
		contents = Path.utf8(path).read_bytes!() ? |PathErr(err, _)| Failed("${path}: ${err.to_str()}")
		Hash.write!(stream, contents)
	}

	## The stream's SHA-256, hex.
	finish! : Digest =>Try(Str, [Failed(Str), Interrupted])
	finish! = |stream| {
		_ = stream.child.close_stdin!()
		match stream.child.wait!() {
			Ok(output) =>
				match output.status {
					Exited(0) => digest(output.stdout_utf8_lossy())
					other => Err(Failed("sha256sum: ${Run.status(other)}: ${output.stderr_utf8_lossy()}"))
				}
			Err(Interrupted) => Err(Interrupted)
			Err(Closed) => Err(Failed("sha256sum: closed"))
			Err(CmdErr(err)) => Err(Failed("sha256sum: ${err.to_str()}"))
		}
	}
}

## sha256sum's line: the 64 hex digits, then the name.
digest : Str -> Try(Str, [Failed(Str), Interrupted])
digest = |printed| {
	hex = Text.take(printed, 64)
	if hex.to_utf8().len() == 64 and hex.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')) {
		Ok(hex)
	} else {
		Err(Failed("sha256sum printed ${Str.inspect(printed)}"))
	}
}

expect digest("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  -") == Ok("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
expect digest("nope").is_err()
