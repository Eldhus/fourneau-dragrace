## Any JSON value, for the few places that read JSON by its structure
## rather than into a record: conduit's checks compare whole answers with
## the contract and name keys it does not have, and some tools' JSON has
## PascalCase keys (`go mod edit -json`, `tailscale status --json`), which
## no record field can be named. Its parser is built from the format's own
## methods, one kind of value at a time; numbers are F64, as Go's `any`.
JsonValue := [Null, Boolean(Bool), Number(F64), Text(Str), Array(List(JsonValue)), Object(List((Str, JsonValue)))].{
	parser_for = |encoding| |state| parse_value(encoding, state, 0)

	## A value read from JSON text.
	parse : Str -> Try(JsonValue, [InvalidJson(Str)])
	parse = |text|
		match Json.parse(text) {
			Ok(value) => Ok(value)
			Err(InvalidJson(why)) => Err(InvalidJson(why))
		}

	## A member of an object; Null when there is none, or for a value that
	## is not an object.
	get : JsonValue, Str -> JsonValue
	get = |value, key|
		match value {
			Object(members) =>
				match members.find_first(|(name, _)| name == key) {
					Ok((_, member)) => member
					Err(_) => Null
				}
			_ => Null
		}

	## An array's items; none for anything else.
	items : JsonValue -> List(JsonValue)
	items = |value|
		match value {
			Array(list) => list
			_ => []
		}

	## A string's text; "" for anything else.
	text : JsonValue -> Str
	text = |value|
		match value {
			Text(s) => s
			_ => ""
		}

	## The value as JSON text, for a message: objects' keys in their order.
	to_str : JsonValue -> Str
	to_str = |value|
		match value {
			Null => "null"
			Boolean(b) => if b "true" else "false"
			Number(n) => n.to_str()
			Text(s) => Str.inspect(s)
			Array(list) => "[${Str.join_with(list.map(JsonValue.to_str), ",")}]"
			Object(members) => "{${Str.join_with(members.map(|(k, v)| "${Str.inspect(k)}:${v.to_str()}"), ",")}}"
		}

	## Two values equal as Go's reflect.DeepEqual takes two decoded JSON
	## values: objects whatever their keys' order, lists in order.
	same : JsonValue, JsonValue -> Bool
	same = |a, b| JsonValue.difference(a, b, "") == ""

	## The first place two values differ, as a path and what is there: "" when
	## they are the same. A key the first has and the second does not is
	## "not in the contract".
	difference : JsonValue, JsonValue, Str -> Str
	difference = |got, want, path|
		match (got, want) {
			(Object(have), Object(wanted)) => {
				for (key, value) in wanted {
					why =
						match have.find_first(|(name, _)| name == key) {
							Ok((_, found)) => JsonValue.difference(found, value, "${path}.${key}")
							Err(_) => "${path}.${key}: missing, want ${value.to_str()}"
						}
					if why != "" {
						return why
					}
				}
				for (key, _) in have {
					if !wanted.any(|(name, _)| name == key) {
						return "${path}.${key}: not in the contract"
					}
				}
				""
			}
			(_, Object(_)) => "${path}: ${got.to_str()}, not an object"
			(Array(have), Array(wanted)) => {
				if have.len() != wanted.len() {
					return "${path}: ${got.to_str()}, want ${wanted.len().to_str()} items"
				}
				var $index = 0
				for item in wanted {
					why = JsonValue.difference(have.get($index) ?? Null, item, "${path}[${$index.to_str()}]")
					if why != "" {
						return why
					}
					$index = $index + 1
				}
				""
			}
			(_, Array(wanted)) => "${path}: ${got.to_str()}, want ${wanted.len().to_str()} items"
			(Null, Null) => ""
			(Boolean(x), Boolean(y)) if x == y => ""
			(Number(x), Number(y)) if x == y => ""
			(Text(x), Text(y)) if x == y => ""
			_ => "${path}: ${got.to_str()}, want ${want.to_str()}"
		}
}

## How deep a value may nest: every JSON this tool reads is shallow.
depth_max : U64
depth_max = 64

## One value, its kind found by trying each of the format's readers: a
## reader that does not see its kind fails without consuming anything.
parse_value = |encoding, state, depth| {
	if depth > depth_max {
		return Err(InvalidJson("JSON nested deeper than ${depth_max.to_str()}"))
	}
	match encoding.parse_null(state) {
		Ok(rest) => return Ok({ value: JsonValue.Null, rest })
		Err(_) => {}
	}
	match encoding.parse_bool(state) {
		Ok({ value, rest }) => return Ok({ value: JsonValue.Boolean(value), rest })
		Err(_) => {}
	}
	match encoding.parse_f64(state) {
		Ok({ value, rest }) => return Ok({ value: JsonValue.Number(value), rest })
		Err(_) => {}
	}
	match encoding.parse_str(state) {
		Ok({ value, rest }) => return Ok({ value: JsonValue.Text(value), rest })
		Err(_) => {}
	}
	match encoding.parse_list_start(state) {
		Ok(start) => return parse_items(encoding, start, depth)
		Err(_) => {}
	}
	match encoding.parse_dict_start(state) {
		Ok(start) => parse_members(encoding, start, depth)
		Err(err) => Err(err)
	}
}

parse_items = |encoding, start, depth| {
	var $items = []
	match start {
		Counted({ len, rest }) => {
			var $state = rest
			for _ in 0..<len {
				{ value, rest: next } = parse_value(encoding, $state, depth + 1)?
				$items = $items.append(value)
				$state = next
			}
			Ok({ value: JsonValue.Array($items), rest: $state })
		}
		Uncounted(rest) => {
			var $state = rest
			var $open = Bool.True
			while $open {
				match encoding.parse_list_next($state)? {
					Done(after) => {
						$state = after
						$open = Bool.False
					}
					Item(at) => {
						{ value, rest: next } = parse_value(encoding, at, depth + 1)?
						$items = $items.append(value)
						match encoding.parse_list_after_item(next)? {
							Continue(more) => {
								$state = more
							}
							Done(after) => {
								$state = after
								$open = Bool.False
							}
						}
					}
				}
			}
			Ok({ value: JsonValue.Array($items), rest: $state })
		}
	}
}

parse_members = |encoding, start, depth| {
	var $members = []
	var $state =
		match start {
			Counted({ rest, .. }) => rest
			Uncounted(rest) => rest
		}
	var $open = Bool.True
	while $open {
		match encoding.parse_dict_next($state)? {
			Done(after) => {
				$state = after
				$open = Bool.False
			}
			Entry(at) => {
				key = encoding.parse_key_str(at)?
				after_key = encoding.parse_dict_after_key(key.rest)?
				{ value, rest } = parse_value(encoding, after_key, depth + 1)?
				$members = $members.append((key.value, value))
				match encoding.parse_dict_after_entry(rest)? {
					Continue(more) => {
						$state = more
					}
					Done(after) => {
						$state = after
						$open = Bool.False
					}
				}
			}
		}
	}
	Ok({ value: JsonValue.Object($members), rest: $state })
}

expect {
	got = JsonValue.parse("{\"Go\":\"1.27\",\"Toolchain\":\"go1.27.1\",\"Require\":null,\"n\":[1,2.5,true,{}]}")
	match got {
		Ok(v) => v.get("Toolchain").text() == "go1.27.1" and v.get("Require").to_str() == "null" and v.get("n").to_str() == "[1,2.5,true,{}]"
		Err(_) => Bool.False
	}
}

expect JsonValue.parse("{\"a\":}").is_err()
expect JsonValue.parse("[1,").is_err()

expect {
	a = JsonValue.parse("{\"x\":1,\"y\":[\"a\"]}") ?? Null
	b = JsonValue.parse("{\"y\":[\"a\"],\"x\":1}") ?? Null
	JsonValue.same(a, b)
}

expect {
	got = JsonValue.parse("{\"x\":1,\"extra\":2}") ?? Null
	want = JsonValue.parse("{\"x\":1}") ?? Null
	JsonValue.difference(got, want, "") == ".extra: not in the contract"
}

expect {
	got = JsonValue.parse("{\"x\":[1,2]}") ?? Null
	want = JsonValue.parse("{\"x\":[1,3]}") ?? Null
	JsonValue.difference(got, want, "") == ".x[1]: 2, want 3"
}
