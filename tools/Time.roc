## RFC 3339 times, as Go's `time.Time` writes them into JSON: the guard's
## ledger. Read strictly: `YYYY-MM-DDTHH:MM:SS`, an optional fraction, then
## `Z` or an offset `±HH:MM`. Kept as milliseconds since the epoch.
Time :: [].{
	## Go's zero time: a droplet's `deleted` while it is alive.
	zero : Str
	zero = "0001-01-01T00:00:00Z"

	## The milliseconds since the epoch of an RFC 3339 time.
	parse_ms : Str -> Try(I64, [BadTime(Str)])
	parse_ms = |text| {
		bytes = text.to_utf8()
		bad = BadTime(text)
		if bytes.len() < 20 or bytes.get(4) != Ok('-') or bytes.get(7) != Ok('-') or bytes.get(10) != Ok('T') or bytes.get(13) != Ok(':') or bytes.get(16) != Ok(':') {
			return Err(bad)
		}
		year = number(bytes, 0, 4) ? |_| bad
		month = number(bytes, 5, 2) ? |_| bad
		day = number(bytes, 8, 2) ? |_| bad
		hour = number(bytes, 11, 2) ? |_| bad
		minute = number(bytes, 14, 2) ? |_| bad
		second = number(bytes, 17, 2) ? |_| bad
		if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60 {
			return Err(bad)
		}
		# The fraction: any number of digits, of which the first three count.
		var $at = 19
		var $millis = 0
		var $scale = 100
		if bytes.get(19) == Ok('.') {
			$at = 20
			while $at < bytes.len() and is_digit(bytes.get($at) ?? 0) {
				digit = bytes.get($at) ?? '0'
				$millis = $millis + (digit - '0').to_i64() * $scale
				$scale = $scale // 10
				$at = $at + 1
			}
			if $at == 20 {
				return Err(bad)
			}
		}
		offset_minutes =
			match bytes.drop_first($at) {
				['Z'] => 0
				[sign, _, _, ':', _, _] if sign == '+' or sign == '-' => {
					hours = number(bytes, $at + 1, 2) ? |_| bad
					minutes = number(bytes, $at + 4, 2) ? |_| bad
					if sign == '+' hours * 60 + minutes else -(hours * 60 + minutes)
				}
				_ => return Err(bad)
			}
		seconds = days_from_civil(year, month, day) * 86_400 + hour * 3_600 + (minute - offset_minutes) * 60 + second
		Ok(seconds * 1_000 + $millis)
	}

	## The start of the month (UTC) a time is in.
	month_start_ms : I64 -> I64
	month_start_ms = |ms| {
		{ year, month, day: _ } = civil_from_days(floor_div(ms, 86_400_000))
		days_from_civil(year, month, 1) * 86_400_000
	}

	## An RFC 3339 time in UTC with milliseconds, which Go reads back.
	format_ms : I64 -> Str
	format_ms = |ms| {
		days = floor_div(ms, 86_400_000)
		of_day = ms - days * 86_400_000
		{ year, month, day } = civil_from_days(days)
		"${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}T${pad(of_day // 3_600_000, 2)}:${pad((of_day // 60_000) % 60, 2)}:${pad((of_day // 1_000) % 60, 2)}.${pad(of_day % 1_000, 3)}Z"
	}
}

number : List(U8), U64, U64 -> Try(I64, [NotDigits])
number = |bytes, at, count| {
	var $value = 0
	var $i = 0
	while $i < count {
		byte = bytes.get(at + $i) ?? 0
		if !is_digit(byte) {
			return Err(NotDigits)
		}
		$value = $value * 10 + (byte - '0').to_i64()
		$i = $i + 1
	}
	Ok($value)
}

is_digit : U8 -> Bool
is_digit = |byte| byte >= '0' and byte <= '9'

pad : I64, U64 -> Str
pad = |value, width| {
	text = value.to_str()
	"${Str.repeat("0", width - (text.to_utf8().len().min(width)))}${text}"
}

floor_div : I64, I64 -> I64
floor_div = |a, b| {
	q = a // b
	if (a % b != 0) and ((a < 0) != (b < 0)) q - 1 else q
}

## Days since 1970-01-01 of a date in the proleptic Gregorian calendar
## (Howard Hinnant's days_from_civil).
days_from_civil : I64, I64, I64 -> I64
days_from_civil = |year, month, day| {
	y = if month <= 2 year - 1 else year
	era = floor_div(y, 400)
	yoe = y - era * 400
	mp = if month > 2 month - 3 else month + 9
	doy = (153 * mp + 2) // 5 + day - 1
	doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	era * 146_097 + doe - 719_468
}

## The date of a day since 1970-01-01 (Hinnant's civil_from_days).
civil_from_days : I64 -> { year : I64, month : I64, day : I64 }
civil_from_days = |days| {
	z = days + 719_468
	era = floor_div(z, 146_097)
	doe = z - era * 146_097
	yoe = (doe - doe // 1_460 + doe // 36_524 - doe // 146_096) // 365
	doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	mp = (5 * doy + 2) // 153
	day = doy - (153 * mp + 2) // 5 + 1
	month = if mp < 10 mp + 3 else mp - 9
	year = yoe + era * 400 + (if month <= 2 1 else 0)
	{ year, month, day }
}

expect Time.parse_ms("1970-01-01T00:00:00Z") == Ok(0)
expect Time.parse_ms("2026-10-20T17:01:16.123456789Z") == Ok(1_792_515_676_123)
expect Time.parse_ms("2026-10-20T13:01:16-04:00") == Ok(1_792_515_676_000)
expect Time.parse_ms("2026-10-20T17:01:16.5Z") == Ok(1_792_515_676_500)
expect Time.parse_ms("2026-10-20 17:01:16Z").is_err()
expect Time.parse_ms("2026-10-20T17:01:16.Z").is_err()
expect Time.parse_ms("2026-13-20T17:01:16Z").is_err()
expect Time.parse_ms(Time.zero) == Ok(-62_135_596_800_000)
expect Time.format_ms(1_792_515_676_123) == "2026-10-20T17:01:16.123Z"
expect Time.format_ms(0) == "1970-01-01T00:00:00.000Z"
expect Time.format_ms(-1) == "1969-12-31T23:59:59.999Z"
expect Time.parse_ms(Time.format_ms(1_792_515_676_123)) == Ok(1_792_515_676_123)
expect Time.month_start_ms(1_792_515_676_123) == (Time.parse_ms("2026-10-01T00:00:00Z") ?? 0)
