## What the tool needs of text that the builtins lack: an order (Go's
## sort.Strings, byte by byte: `Str` has none), and numbers printed as Go's
## `%.2f` and `%x` print them.
Text :: [].{
	## Byte-wise order of two strings, as Go compares them.
	order : Str, Str -> [Before, Same, After]
	order = |a, b| order_bytes(a.to_utf8(), b.to_utf8())

	## A list of strings sorted byte-wise.
	sorted : List(Str) -> List(Str)
	sorted = |items| items.sort_with(Text.order)

	## A number with `digits` decimals, rounded half away from zero, as
	## Go's `%.Nf`: 12.345 at 2 is "12.35", -0.5 at 0 is "-1".
	fixed : F64, U64 -> Str
	fixed = |value, digits| {
		scale = 10.U64.pow(digits).to_f64()
		negative = value < 0.0
		magnitude = if negative -value else value
		scaled = (magnitude * scale + 0.5).floor_to_u64_try() ?? 0
		whole = (scaled // 10.U64.pow(digits)).to_str()
		fraction = (scaled % 10.U64.pow(digits)).to_str()
		length = fraction.to_utf8().len()
		padded = if length >= digits fraction else "${Str.repeat("0", digits - length)}${fraction}"
		sign = if negative and scaled > 0 "-" else ""
		if digits == 0 "${sign}${whole}" else "${sign}${whole}.${padded}"
	}

	## Bytes as lower-case hexadecimal, two digits each.
	hex : List(U8) -> Str
	hex = |bytes| {
		digits = "0123456789abcdef".to_utf8()
		out = bytes.fold(
			List.with_capacity(bytes.len() * 2),
			|acc, byte| acc.append(digits.get((byte // 16).to_u64()) ?? 48).append(digits.get((byte % 16).to_u64()) ?? 48),
		)
		Str.from_utf8_lossy(out)
	}

	## Padded on the right to `width` bytes, as Go's `%-Ns`.
	pad_right : Str, U64 -> Str
	pad_right = |text, width| {
		length = text.to_utf8().len()
		if length >= width text else "${text}${Str.repeat(" ", width - length)}"
	}

	## Padded on the left to `width` bytes, as Go's `%Ns`.
	pad_left : Str, U64 -> Str
	pad_left = |text, width| {
		length = text.to_utf8().len()
		if length >= width text else "${Str.repeat(" ", width - length)}${text}"
	}

	## The first `count` bytes of a string, which must end on a character.
	take : Str, U64 -> Str
	take = |text, count| {
		bytes = text.to_utf8()
		if bytes.len() <= count text else Str.from_utf8_lossy(bytes.take_first(count))
	}

	## The words of a line, split on runs of spaces and tabs (Go's
	## strings.Fields for the kernel's text).
	fields : Str -> List(Str)
	fields = |line|
		line.replace_each("\t", " ").split_on(" ").keep_if(|word| !word.is_empty())

	## The lines of a text, without their terminators.
	lines : Str -> List(Str)
	lines = |text| text.split_on("\n").map(|line| line.drop_suffix("\r"))
}

order_bytes : List(U8), List(U8) -> [Before, Same, After]
order_bytes = |a, b| {
	var $index = 0
	var $result = Same
	var $done = Bool.False
	while !$done {
		match (a.get($index), b.get($index)) {
			(Ok(x), Ok(y)) =>
				if x < y {
					$result = Before
					$done = Bool.True
				} else if x > y {
					$result = After
					$done = Bool.True
				} else {
					$index = $index + 1
				}
			(Err(_), Ok(_)) => {
				$result = Before
				$done = Bool.True
			}
			(Ok(_), Err(_)) => {
				$result = After
				$done = Bool.True
			}
			(Err(_), Err(_)) => {
				$done = Bool.True
			}
		}
	}
	$result
}

expect Text.sorted(["b", "a", "ab", "B", ""]) == ["", "B", "a", "ab", "b"]
expect Text.order("x", "x") == Same
expect Text.fixed(12.345, 2) == "12.35"
expect Text.fixed(4.0, 2) == "4.00"
expect Text.fixed(0.004, 2) == "0.00"
expect Text.fixed(1234.5, 0) == "1235"
expect Text.fixed(-1.25, 1) == "-1.3"
expect Text.fixed(0.05, 3) == "0.050"
expect Text.hex([0, 15, 16, 255]) == "000f10ff"
expect Text.pad_right("ab", 4) == "ab  "
expect Text.pad_left("ab", 4) == "  ab"
expect Text.fields(" cpu0  1\t2 ") == ["cpu0", "1", "2"]
expect Text.take("abcdef", 3) == "abc"
