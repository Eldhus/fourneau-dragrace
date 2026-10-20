## Command-line flags as Go's `flag` package reads them, so every command
## line the workflow, the units and the docs hold keeps working: `-name
## value`, `-name=value` (one dash or two), a boolean alone (`-quick`) or
## `-quick=false`; the first word that is not a flag, or `--`, ends them.
Flags :: [].{
	## A flag a command takes: a boolean, or a value with its default.
	Spec : { name : Str, kind : [Switch, Value(Str)], usage : Str }

	## What a command line said: each flag's value ("true" or "false" for a
	## switch), and the words after the flags.
	Parsed : { values : Dict(Str, Str), rest : List(Str) }

	## Read the flags; a flag the command does not take, or one without its
	## value, is an error that names it.
	parse : List(Str), List(Spec) -> Try(Parsed, [BadFlag(Str)])
	parse = |words, specs| {
		var $values = Dict.empty()
		for spec in specs {
			default =
				match spec.kind {
					Switch => "false"
					Value(text) => text
				}
			$values = $values.insert(spec.name, default)
		}
		var $index = 0
		var $rest = []
		var $done = Bool.False
		while !$done and $index < words.len() {
			word = words.get($index) ?? ""
			if word == "--" {
				$rest = words.drop_first($index + 1)
				$done = Bool.True
			} else if word.starts_with("-") and word != "-" {
				name_and_value = word.drop_prefix("--").drop_prefix("-")
				{ name, given } =
					match name_and_value.split_first("=") {
						Ok({ before, after }) => { name: before, given: Ok(after) }
						Err(_) => { name: name_and_value, given: Err(Missing) }
					}
				spec = specs.find_first(|s| s.name == name) ? |_| BadFlag("-${name}: no such flag")
				match (spec.kind, given) {
					(Switch, Ok(text)) =>
						if text == "true" or text == "false" {
							$values = $values.insert(name, text)
						} else {
							return Err(BadFlag("-${name}: true or false, not ${text}"))
						}
					(Switch, Err(Missing)) => {
						$values = $values.insert(name, "true")
					}
					(Value(_), Ok(text)) => {
						$values = $values.insert(name, text)
					}
					(Value(_), Err(Missing)) => {
						value = words.get($index + 1) ? |_| BadFlag("-${name}: needs a value")
						$values = $values.insert(name, value)
						$index = $index + 1
					}
				}
				$index = $index + 1
			} else {
				$rest = words.drop_first($index)
				$done = Bool.True
			}
		}
		Ok({ values: $values, rest: $rest })
	}

	## A flag's value, "" for one never declared (a bug: the command reads
	## what it declared).
	value : Parsed, Str -> Str
	value = |parsed, name| parsed.values.get(name) ?? ""

	## Whether a switch was set.
	switch : Parsed, Str -> Bool
	switch = |parsed, name| parsed.values.get(name) == Ok("true")

	## The command's usage: each flag, its default, what it does.
	usage : Str, List(Spec) -> Str
	usage = |command, specs| {
		lines = specs.map(
			|spec|
				match spec.kind {
					Switch => "  -${spec.name}\n    \t${spec.usage}"
					Value("") => "  -${spec.name} string\n    \t${spec.usage}"
					Value(default) => "  -${spec.name} string\n    \t${spec.usage} (default \"${default}\")"
				},
		)
		Str.join_with(["Usage of ${command}:"].concat(lines), "\n")
	}
}

specs : List(Flags.Spec)
specs = [
	{ name: "quick", kind: Switch, usage: "a smoke test" },
	{ name: "since", kind: Value(""), usage: "a release's build.json" },
	{ name: "server-cpus", kind: Value("0-1"), usage: "the server's CPUs" },
]

expect {
	parsed = Flags.parse(["-quick", "-since", "out/last/build.json", "--server-cpus=2-3", "a", "-b"], specs)
	match parsed {
		Ok(p) => Flags.switch(p, "quick") and Flags.value(p, "since") == "out/last/build.json" and Flags.value(p, "server-cpus") == "2-3" and p.rest == ["a", "-b"]
		Err(_) => Bool.False
	}
}

expect {
	parsed = Flags.parse([], specs)
	match parsed {
		Ok(p) => !Flags.switch(p, "quick") and Flags.value(p, "server-cpus") == "0-1" and p.rest == []
		Err(_) => Bool.False
	}
}

expect Flags.parse(["-nope"], specs) == Err(BadFlag("-nope: no such flag"))
expect Flags.parse(["-since"], specs) == Err(BadFlag("-since: needs a value"))
expect Flags.parse(["-quick=maybe"], specs) == Err(BadFlag("-quick: true or false, not maybe"))

expect {
	parsed = Flags.parse(["-quick=false", "--", "-x"], specs)
	match parsed {
		Ok(p) => !Flags.switch(p, "quick") and p.rest == ["-x"]
		Err(_) => Bool.False
	}
}
