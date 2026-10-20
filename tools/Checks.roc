import Text

## The parts of a competitor's checks that read what it answered: the SSE
## stream as sent (chunked, each event its own chunk), the TLS a client
## like oha's agreed, and the menu with its entities spelled one way.
Checks :: [].{
	## The most events a checked stream may have.
	stream_events_max : U64
	stream_events_max = 64

	## A raw HTTP/1.1 response (curl --include --raw) against the reference
	## stream: "" when it is right. Requiring a chunk per event means each
	## competitor's streaming path is what races, not a page sent whole.
	stream : Str, Str -> Str
	stream = |raw, reference| {
		{ head, body } =
			match raw.split_first("\r\n\r\n") {
				Ok({ before, after }) => { head: before, body: after }
				Err(_) => return "no end of the response head"
			}
		lines = head.split_on("\r\n")
		status_line = lines.first() ?? ""
		if !status_line.starts_with("HTTP/1.1 200 ") {
			return "status line ${Str.inspect(status_line)}, not 200"
		}
		var $content_type = ""
		var $chunked = Bool.False
		var $length = Bool.False
		for line in lines.drop_first(1) {
			{ name, value } =
				match line.split_first(":") {
					Ok({ before, after }) => { name: before.with_ascii_lowercased(), value: after.trim() }
					Err(_) => { name: line.with_ascii_lowercased(), value: "" }
				}
			if name == "content-type" {
				$content_type = value
			} else if name == "transfer-encoding" {
				$chunked = value.caseless_ascii_equals("chunked")
			} else if name == "content-length" {
				$length = Bool.True
			}
		}
		if !$content_type.starts_with("text/event-stream") {
			return "Content-Type ${Str.inspect($content_type)}, not text/event-stream"
		}
		if !$chunked or $length {
			return "not streamed: the contract is chunked, with no Content-Length"
		}
		chunks =
			match read_chunks(body.to_utf8()) {
				Ok(list) => list
				Err(Bad(why)) => return "chunked body: ${why}"
			}
		events = split_events(reference)
		if chunks.len() != events.len() {
			return "${chunks.len().to_str()} chunks for ${events.len().to_str()} events: the contract is one chunk per event"
		}
		var $i = 0
		for event in events {
			chunk = chunks.get($i) ?? ""
			if chunk != event {
				return "event ${($i + 1).to_str()} is ${Str.inspect(chunk)}, not ${Str.inspect(event)}"
			}
			$i = $i + 1
		}
		""
	}

	## curl's lines about a TLS handshake (`SSL connection using ...` and
	## `version N`): "" when it was TLS 1.3, AES-128-GCM, X25519 and HTTP/2
	## by ALPN; the agreement, to log, either way.
	tls : Str -> { why : Str, agreed : Str }
	tls = |text| {
		var $agreed = ""
		var $version = ""
		for line in Text.lines(text) {
			match line.split_first("SSL connection using ") {
				Ok({ after, .. }) => {
					$agreed = after.trim()
				}
				Err(_) => {}
			}
			if line.starts_with("version ") {
				$version = line.drop_prefix("version ").trim()
			}
		}
		lower = $agreed.with_ascii_lowercased()
		why =
			if $version != "2" {
				"TLS: HTTP/${$version} by ALPN, not HTTP/2"
			} else if $agreed == "" {
				# A curl that does not say: HTTP/2 was checked, the rest is logged.
				""
			} else if !lower.contains("tlsv1.3") {
				"TLS: not TLS 1.3: ${$agreed}"
			} else if !lower.contains("aes_128_gcm") {
				"TLS: not AES-128-GCM: ${$agreed}"
			} else if !lower.contains("/ x25519 /") {
				"TLS: not X25519: ${$agreed}"
			} else {
				""
			}
		{ why, agreed: $agreed }
	}

	## Every way the competitors' engines write the five characters HTML
	## escaping is about, written one way: html/template writes &#34;,
	## askama &#38;, rocstache &amp;. A character left raw stays raw.
	canonical_entities : Str -> Str
	canonical_entities = |page|
		spellings.fold(page, |text, (from, to)| text.replace_each(from, to))
}

spellings : List((Str, Str))
spellings = [
	("&#38;", "&amp;"),
	("&#x26;", "&amp;"),
	("&#60;", "&lt;"),
	("&#x3c;", "&lt;"),
	("&#x3C;", "&lt;"),
	("&#62;", "&gt;"),
	("&#x3e;", "&gt;"),
	("&#x3E;", "&gt;"),
	("&#34;", "&quot;"),
	("&#x22;", "&quot;"),
	("&#x27;", "&#39;"),
	("&apos;", "&#39;"),
]

## A chunked body's chunks, the last (empty) one left out; a trailer or
## anything after the end is refused, as the contract has none.
read_chunks : List(U8) -> Try(List(Str), [Bad(Str)])
read_chunks = |body| {
	var $at = 0
	var $chunks = []
	while $chunks.len() <= Checks.stream_events_max {
		line_end = find_crlf(body, $at) ? |_| Bad("chunk size: no line end")
		size_text = Str.from_utf8_lossy(body.sublist({ start: $at, len: line_end - $at }))
		size = parse_hex(size_text) ? |_| Bad("chunk size line ${Str.inspect(size_text)}")
		$at = line_end + 2
		if size == 0 {
			rest = body.drop_first($at)
			if rest == ['\r', '\n'] {
				return Ok($chunks)
			}
			return Err(Bad("trailer or junk after the last chunk: ${Str.inspect(Str.from_utf8_lossy(rest))}"))
		}
		if $at + size + 2 > body.len() {
			return Err(Bad("chunk data cut short"))
		}
		if body.sublist({ start: $at + size, len: 2 }) != ['\r', '\n'] {
			return Err(Bad("chunk of ${size.to_str()} bytes not followed by CRLF"))
		}
		$chunks = $chunks.append(Str.from_utf8_lossy(body.sublist({ start: $at, len: size })))
		$at = $at + size + 2
	}
	Err(Bad("more than ${Checks.stream_events_max.to_str()} chunks"))
}

find_crlf : List(U8), U64 -> Try(U64, [NotFound])
find_crlf = |bytes, from| {
	var $i = from
	while $i + 1 < bytes.len() {
		if bytes.get($i) == Ok('\r') and bytes.get($i + 1) == Ok('\n') {
			return Ok($i)
		}
		$i = $i + 1
	}
	Err(NotFound)
}

parse_hex : Str -> Try(U64, [NotHex])
parse_hex = |text| {
	digits = text.to_utf8()
	if digits.is_empty() or digits.len() > 8 {
		return Err(NotHex)
	}
	var $value = 0.U64
	for d in digits {
		v =
			if d >= '0' and d <= '9' {
				(d - '0').to_u64()
			} else if d >= 'a' and d <= 'f' {
				(d - 'a').to_u64() + 10
			} else if d >= 'A' and d <= 'F' {
				(d - 'A').to_u64() + 10
			} else {
				return Err(NotHex)
			}
		$value = $value * 16 + v
	}
	Ok($value)
}

## A stream's events, each with its blank line.
split_events : Str -> List(Str)
split_events = |stream| {
	var $events = []
	var $rest = stream
	var $open = Bool.True
	while $open and $rest != "" {
		match $rest.split_first("\n\n") {
			Ok({ before, after }) => {
				$events = $events.append("${before}\n\n")
				$rest = after
			}
			Err(_) => {
				$events = $events.append($rest)
				$open = Bool.False
			}
		}
	}
	$events
}

reference = "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n"

# Each event is 18 bytes: hex 12.
good = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n12\r\nevent: a\ndata: 1\n\n\r\n12\r\nevent: b\ndata: 2\n\n\r\n0\r\n\r\n"

expect Checks.stream(good, reference) == ""
expect Checks.stream(good.replace_first("Transfer-Encoding: chunked", "Content-Length: 34"), reference) == "not streamed: the contract is chunked, with no Content-Length"
expect Checks.stream("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n24\r\nevent: a\ndata: 1\n\nevent: b\ndata: 2\n\n\r\n0\r\n\r\n", reference) == "1 chunks for 2 events: the contract is one chunk per event"
expect Checks.stream(good.replace_first("0\r\n\r\n", "0\r\nX: 1\r\n\r\n"), reference).starts_with("chunked body: trailer")
expect Checks.stream("HTTP/1.1 404 Not Found\r\n\r\n", reference) == "status line \"HTTP/1.1 404 Not Found\", not 200"
expect split_events(reference) == ["event: a\ndata: 1\n\n", "event: b\ndata: 2\n\n"]

expect Checks.tls("* SSL connection using TLSv1.3 / TLS_AES_128_GCM_SHA256 / x25519 / id-ecPublicKey\nversion 2").why == ""
expect Checks.tls("* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / x25519 / id-ecPublicKey\nversion 2").why == "TLS: not AES-128-GCM: TLSv1.3 / TLS_AES_256_GCM_SHA384 / x25519 / id-ecPublicKey"
expect Checks.tls("version 1.1").why == "TLS: HTTP/1.1 by ALPN, not HTTP/2"

expect Checks.canonical_entities("a &#38; b &#x3C;c&#62; &#34;&apos;") == "a &amp; b &lt;c&gt; &quot;&#39;"
