## Numbers as the site shows them: requests per second rounded and grouped
## by thousands (`59,137`), milliseconds to two decimals (`12.31`).
Format :: [].{
	## A non-negative number, rounded, with commas: 59137.48 is "59,137".
	thousands : F64 -> Str
	thousands = |value|
		match value.round_to_u64_try() {
			Ok(whole) => group(whole.to_str())
			Err(_) => "0"
		}

	## Two decimals: 12.311 is "12.31", 4.0 is "4.00".
	two_decimals : F64 -> Str
	two_decimals = |value|
		match (value * 100.0).round_to_u64_try() {
			Ok(hundredths) => {
				whole = hundredths // 100
				rest = hundredths % 100
				pad = if rest < 10 "0" else ""
				"${whole.to_str()}.${pad}${rest.to_str()}"
			}
			Err(_) => "0.00"
		}

	## Milliseconds of latency, two decimals; 0 is a percentile the run did
	## not record (p95 and p99.9 before 2026-10-06), shown as a dash.
	latency : F64 -> Str
	latency = |milliseconds| if milliseconds <= 0.0 "–" else Format.two_decimals(milliseconds)

	## An axis tick, short enough for a phone's chart: 100000 is "100k",
	## 37500 is "37.5k", 500 is "500".
	compact : F64 -> Str
	compact = |value|
		if value < 1000.0 {
			Format.thousands(value)
		} else {
			tenths = (value / 100.0).round_to_u64_try() ?? 0
			whole = tenths // 10
			rest = tenths % 10
			if rest == 0 "${whole.to_str()}k" else "${whole.to_str()}.${rest.to_str()}k"
		}

	## One decimal, for percentages: 81.648 is "81.6".
	one_decimal : F64 -> Str
	one_decimal = |value|
		match (value * 10.0).round_to_u64_try() {
			Ok(tenths) => "${(tenths // 10).to_str()}.${(tenths % 10).to_str()}"
			Err(_) => "0.0"
		}

	## The first seven characters of a commit.
	short : Str -> Str
	short = |commit| Str.from_utf8_lossy(List.take_first(Str.to_utf8(commit), 7))
}

## Digits with a comma every three from the right.
group : Str -> Str
group = |digits| {
	bytes = Str.to_utf8(digits)
	count = List.len(bytes)
	var $out = []
	var $i = 0
	for byte in bytes {
		if $i > 0 and (count - $i) % 3 == 0 {
			$out = $out.append(44)
		}
		$out = $out.append(byte)
		$i = $i + 1
	}
	Str.from_utf8_lossy($out)
}

expect Format.thousands(59137.48) == "59,137"
expect Format.thousands(999.6) == "1,000"
expect Format.thousands(1006030.0) == "1,006,030"
expect Format.thousands(0.0) == "0"
expect Format.two_decimals(12.311489) == "12.31"
expect Format.two_decimals(4.0) == "4.00"
expect Format.two_decimals(0.05) == "0.05"
expect Format.one_decimal(81.648) == "81.6"
expect Format.short("49da1f40d81d946096dc88f6011ac65c3c44c1a5") == "49da1f4"
expect Format.latency(0.0) == "–"
expect Format.latency(1.234) == "1.23"
expect Format.compact(100000.0) == "100k" and Format.compact(37500.0) == "37.5k" and Format.compact(500.0) == "500" and Format.compact(0.0) == "0"
