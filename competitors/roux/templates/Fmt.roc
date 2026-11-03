## The catalog's own Roc for its holes: plain functions, tested like any other.
Fmt :: [].{
	## A price in hundredths: `12.05`.
	kr : U32 -> Str
	kr = |hundredths| "${(hundredths // 100).to_str()}.${Fmt.two((hundredths % 100).to_u64())}"

	## A count and the noun that fits it: `1 group`, `6 groups`.
	plural : U64, Str, Str -> Str
	plural = |count, one, many| {
		noun = if count == 1 one else many
		"${count.to_str()} ${noun}"
	}

	## A percentage: `10%`.
	pct : U8 -> Str
	pct = |percent| "${percent.to_str()}%"

	## A stock's level, the row's class: `out`, `low` (under ten), `ok`.
	level : I32 -> Str
	level = |stock| if stock <= 0 "out" else if stock < 10 "low" else "ok"

	## A stock as written: `out`, `3 left`, `16`.
	stock : I32 -> Str
	stock = |count| if count <= 0 "out" else if count < 10 "${count.to_str()} left" else count.to_str()

	## A price after a discount in percent, in hundredths, rounded down.
	sale : U32, U8 -> U32
	sale = |price, off| price - price * off.to_u32() // 100

	## A day of 2026 (0 is January 1) as `MM-DD`.
	date : U16 -> Str
	date = |day| {
		var $left = day.to_u64()
		var $month = 1
		for days in [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] {
			if $left < days {
				break
			} else {
				$left = $left - days
				$month = $month + 1
			}
		}
		"${Fmt.two($month)}-${Fmt.two($left + 1)}"
	}

	## A weight in grams: `350 g`, or `1.25 kg` from a kilogram up.
	weight : U32 -> Str
	weight = |grams|
		if grams < 1000 {
			"${grams.to_str()} g"
		} else {
			"${(grams // 1000).to_str()}.${Fmt.two(((grams % 1000) // 10).to_u64())} kg"
		}

	## A number under 100 in two digits: `05`.
	two : U64 -> Str
	two = |n| if n < 10 "0${n.to_str()}" else n.to_str()
}

expect Fmt.kr(1205) == "12.05"
expect Fmt.kr(500) == "5.00"
expect Fmt.kr(7) == "0.07"
expect Fmt.plural(1, "group", "groups") == "1 group"
expect Fmt.plural(6, "group", "groups") == "6 groups"
expect Fmt.pct(10) == "10%"
expect Fmt.level(-1) == "out"
expect Fmt.level(3) == "low"
expect Fmt.level(10) == "ok"
expect Fmt.stock(0) == "out"
expect Fmt.stock(3) == "3 left"
expect Fmt.stock(16) == "16"
expect Fmt.sale(8419, 37) == 5304
expect Fmt.sale(500, 0) == 500
expect Fmt.date(0) == "01-01"
expect Fmt.date(53) == "02-23"
expect Fmt.date(364) == "12-31"
expect Fmt.weight(50) == "50 g"
expect Fmt.weight(1045) == "1.04 kg"
expect Fmt.weight(1000) == "1.00 kg"
