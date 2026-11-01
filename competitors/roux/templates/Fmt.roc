## The catalog's own Roc for its holes: plain functions, tested like any other.
Fmt :: [].{
	## A price in hundredths: `12.05`.
	kr : U32 -> Str
	kr = |hundredths| {
		cents = hundredths % 100
		pad = if cents < 10 "0" else ""
		"${(hundredths // 100).to_str()}.${pad}${cents.to_str()}"
	}

	## A count and the noun that fits it: `1 group`, `6 groups`.
	plural : U64, Str, Str -> Str
	plural = |count, one, many| {
		noun = if count == 1 one else many
		"${count.to_str()} ${noun}"
	}
}

expect Fmt.kr(1205) == "12.05"
expect Fmt.kr(500) == "5.00"
expect Fmt.kr(7) == "0.07"
expect Fmt.plural(1, "group", "groups") == "1 group"
expect Fmt.plural(6, "group", "groups") == "6 groups"
