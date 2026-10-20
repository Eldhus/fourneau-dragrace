## A JSON number that may be null, read as no value: oha writes null for
## the percentiles of a run that had no answers, which Go read as 0. Roc's
## Json reads no null into any type of its own, so this one reads it.
Number := [Some(F64), Null].{
	parser_for = |encoding|
		|state|
			match encoding.parse_null(state) {
				Ok(rest) => Ok({ value: Number.Null, rest })
				Err(_) => {
					parsed = encoding.parse_f64(state)?
					Ok({ value: Number.Some(parsed.value), rest: parsed.rest })
				}
			}

	## The number, 0 for null: what Go's float64 held for it.
	or_zero : Number -> F64
	or_zero = |number|
		match number {
			Some(value) => value
			Null => 0
		}
}

expect {
	parsed : Try(List(Number), _)
	parsed = Json.parse("[null, 1.5, 2]")
	match parsed {
		Ok(list) => list.map(Number.or_zero) == [0, 1.5, 2]
		Err(_) => Bool.False
	}
}
