import pf.Duration
import pf.Path
import pf.Stdout
import pf.Tcp
import Build
import Checkout
import Conduit
import Config
import Flags
import Hash
import Machine
import Target
import Text
import Toolchain

## `dragrace diff`: the same requests, byte for byte, to several
## competitors, and where their answers differ: second opinions. Each case
## is sent on a new connection; the answer is read until the server closes
## or is idle for a second. What is compared: each response's status,
## whether the connection was closed after, and the body; never the Date or
## Server headers, or the reason phrase. Every divergence is then fixed or
## written down as a decision.
##
## It speaks HTTP/1.1 itself, on purpose: the cases are requests a real
## client would refuse to send, and their answers ones it would tidy away.
## Responses are read by the format's own rules (RFC 9112: the status line,
## the fields, a body by Content-Length, chunked, or to the close).
Diff :: [].{
	## One request (or several, pipelined), as raw bytes.
	Case : { name : Str, about : Str, bytes : List(U8) }

	## One response as compared; 1xx responses before it are its interim.
	Response : { status : U64, close : Bool, body : List(U8), interim : List(U64) }

	## Everything one server sent for one case: its responses, whether it
	## closed the connection (rather than going idle), and what could not be
	## read as responses.
	Answer : { responses : List(Response), closed : Bool, unparsed : Str }

	## `dragrace diff [-competitors a,b] [-cases c,d]`.
	command! : Str, List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	command! = |root, args| {
		flags = Flags.parse(
			args,
			[
				{ name: "competitors", kind: Value("fourneau-zig,go,axum"), usage: "comma-separated" },
				{ name: "cases", kind: Value(""), usage: "comma-separated (default: all)" },
			],
		)?
		race = Checkout.race!(root)?
		names = Flags.value(flags, "competitors").split_on(",")
		cases = Diff.select(Flags.value(flags, "cases"))
		ready = Toolchain.load!(root)?
		competitors = Checkout.competitors!(root, names)?
		_ = Build.all!(root, ready, competitors)?
		out = Checkout.out(root)
		target = {
			class: { name: "local", label: "", title: "", size: "", loader_size: "" },
			server: Local,
			loader: Local,
			server_home: out,
			loader_home: "${out}/loader",
			address: "127.0.0.1",
			server_cpus: "",
			loader_cpus: "",
			loader_threads: 0,
			black_box: "",
		}
		Machine.put!(Local, Conduit.database(root), "${out}/${Conduit.seed_name}")?
		var $rows = []
		for competitor in competitors {
			$rows = $rows.append((competitor.name, competitor!(race, competitor, target, cases)?))
		}
		report = Diff.report(names, cases, $rows)
		_ = Stdout.write!(report)
		path = "${out}/diff.md"
		Path.utf8(path).write_utf8!(report) ? |PathErr(err, _)| Failed("${path}: ${err.to_str()}")
		Ok({})
	}

	## The cases named, comma-separated; all for "".
	select : Str -> List(Case)
	select = |only|
		if only == "" {
			cases
		} else {
			only.split_on(",").join_map(|name| cases.keep_if(|c| c.name == name))
		}

	## Every response in what a server sent, at most 16; what could not be
	## read is said with the bytes left. A HEAD's response has no body, nor a
	## 204's or a 304's.
	parse : List(U8), Bool -> { responses : List(Response), unparsed : Str }
	parse = |raw, head| {
		var $at = 0
		var $responses = []
		var $interim = []
		while $responses.len() < 16 and $at < raw.len() {
			match read_head(raw, $at) {
				Err(Cut(why)) => return { responses: $responses, unparsed: "${why}: ${Str.from_utf8_lossy(raw.drop_first($at))}" }
				Ok({ status, fields, next }) =>
					if status >= 100 and status < 200 {
						$interim = $interim.append(status)
						$at = next
					} else {
						response = { status, interim: $interim, close: has_token(field(fields, "connection"), "close"), body: [] }
						$interim = []
						none = head or status == 204 or status == 304
						match read_body(raw, next, fields, none) {
							Ok({ body, after }) => {
								$responses = $responses.append({ ..response, body })
								$at = after
							}
							Err(Cut(why)) => return { responses: $responses.append(response), unparsed: why }
						}
					}
			}
		}
		{ responses: $responses, unparsed: "" }
	}

	## A table of every case, the divergent ones marked.
	report : List(Str), List(Case), List((Str, List((Str, Str)))) -> Str
	report = |names, chosen, rows| {
		summary = |name, case| {
			of = (rows.find_first(|(n, _)| n == name) ?? (name, [])).1
			(of.find_first(|(c, _)| c == case) ?? (case, "")).1
		}
		var $differ = 0.U64
		var $lines = ["| case | ${Str.join_with(names, " | ")} |", "|---|${Str.repeat("---|", names.len())}"]
		for c in chosen {
			row = names.map(|name| summary(name, c.name))
			same = row.all(|s| s == (row.first() ?? ""))
			if !same {
				$differ = $differ + 1
			}
			mark = if same "" else " **≠**"
			$lines = $lines.append("| `${c.name}`${mark}: ${c.about} | ${Str.join_with(row, " | ")} |")
		}
		"${Str.join_with($lines, "\n")}\n\n${chosen.len().to_str()} cases, ${$differ.to_str()} answered differently.\n"
	}

	## A string as Go's %q writes it, near enough: printable ASCII as is,
	## the usual escapes, any other byte as \xNN.
	quote : List(U8) -> Str
	quote = |bytes| {
		escaped = bytes.map(|b|
			if b == '"' {
				"\\\""
			} else if b == '\\' {
				"\\\\"
			} else if b == '\n' {
				"\\n"
			} else if b == '\r' {
				"\\r"
			} else if b == '\t' {
				"\\t"
			} else if b >= 0x20 and b <= 0x7e {
				Str.from_utf8_lossy([b])
			} else {
				"\\x${Text.hex([b])}"
			})
		"\"${Str.join_with(escaped, "")}\""
	}
}

## The corpus: where HTTP/1.1 parsers are known to differ, and where request
## smuggling lives (RFC 9112 §6.3, §11.2).
cases : List(Diff.Case)
cases = [
	case("plain", "a plain GET", "GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("http10-no-host", "HTTP/1.0, no Host", "GET /plaintext HTTP/1.0\r\n\r\n"),
	case("http11-no-host", "HTTP/1.1 without Host (RFC 9112 §3.2: 400)", "GET /plaintext HTTP/1.1\r\n\r\n"),
	case("two-hosts", "two Host fields", "GET /plaintext HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
	case("host-space", "a Host with a space inside", "GET /plaintext HTTP/1.1\r\nHost: a b\r\n\r\n"),
	case("cl-and-te", "Content-Length and Transfer-Encoding both (smuggling)", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"),
	case("cl-twice-differ", "two Content-Lengths that differ", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd"),
	case("cl-twice-same", "two Content-Lengths alike", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc"),
	case("cl-list", "Content-Length: 3, 3", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3, 3\r\n\r\nabc"),
	case("cl-plus", "Content-Length: +3", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: +3\r\n\r\nabc"),
	case("cl-leading-zero", "Content-Length: 03", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 03\r\n\r\nabc"),
	case("cl-huge", "Content-Length past 2^64", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999999\r\n\r\nabc"),
	case("cl-too-large", "Content-Length past every limit (100 MB)", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100000000\r\n\r\nabc"),
	case("chunked", "a chunked body", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"),
	case("chunked-upper-hex", "chunk sizes in capitals", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nA\r\n0123456789\r\n0\r\n\r\n"),
	case("chunked-extension", "a chunk extension", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3;name=value\r\nabc\r\n0\r\n\r\n"),
	case("chunked-trailer", "a trailer section", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-Sum: 1\r\n\r\n"),
	case("chunked-bad-size", "a chunk size that is not hex", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n"),
	case("chunked-bare-lf", "chunk lines ended by a bare LF", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\nabc\n0\n\n"),
	case("te-gzip-chunked", "Transfer-Encoding: gzip, chunked", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"),
	case("te-chunked-gzip", "Transfer-Encoding: chunked, gzip (chunked not last)", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, gzip\r\n\r\n3\r\nabc\r\n0\r\n\r\n"),
	case("te-identity", "Transfer-Encoding: identity", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity\r\nContent-Length: 3\r\n\r\nabc"),
	case("te-capitals", "Transfer-Encoding: Chunked", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: Chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"),
	case("te-http10", "chunked in HTTP/1.0", "POST /echo HTTP/1.0\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"),
	case("bare-lf", "a head ended by bare LFs", "GET /plaintext HTTP/1.1\nHost: x\n\n"),
	case("space-before-colon", "Host : x (RFC 9112 §5.1: 400)", "GET /plaintext HTTP/1.1\r\nHost : x\r\n\r\n"),
	case("obs-fold", "a folded header line", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX-A: one\r\n two\r\n\r\n"),
	case("bad-name", "a header name with @", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX@A: 1\r\n\r\n"),
	{ name: "nul-in-value", about: "a NUL in a value", bytes: "GET /plaintext HTTP/1.1\r\nHost: x\r\nX-A: a".to_utf8().append(0).concat("b\r\n\r\n".to_utf8()) },
	case("cr-in-value", "a bare CR in a value", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX-A: a\rb\r\n\r\n"),
	case("empty-line-first", "an empty line before the request (RFC 9112 §2.2 may skip it)", "\r\nGET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("absolute-form", "an absolute-form target", "GET http://x/plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("absolute-form-other-host", "an absolute-form target naming another host than Host", "GET http://y/plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("asterisk", "OPTIONS *", "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("asterisk-get", "GET * (only OPTIONS may)", "GET * HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("connect", "CONNECT authority-form", "CONNECT x:443 HTTP/1.1\r\nHost: x:443\r\n\r\n"),
	case("unknown-method", "a method no one knows", "BREW /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("lower-method", "a method in lower case", "get /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("version-12", "HTTP/1.2", "GET /plaintext HTTP/1.2\r\nHost: x\r\n\r\n"),
	case("version-20", "HTTP/2.0 on an HTTP/1 line", "GET /plaintext HTTP/2.0\r\nHost: x\r\n\r\n"),
	case("version-lower", "http/1.1 in lower case", "GET /plaintext http/1.1\r\nHost: x\r\n\r\n"),
	case("two-spaces", "two spaces after the method", "GET  /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("target-space", "a space in the target", "GET /plain text HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("long-target", "a 10,000-byte target", "GET /${Str.repeat("a", 10000)} HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("long-header", "a 20,000-byte header", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX-A: ${Str.repeat("a", 20000)}\r\n\r\n"),
	case("many-headers", "200 headers", "GET /plaintext HTTP/1.1\r\nHost: x\r\n${Str.repeat("X-A: 1\r\n", 200)}\r\n"),
	case("pipelined", "two GETs in one write", "GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\nGET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("head", "HEAD: the head alone", "HEAD /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("get-with-body", "a GET with a body", "GET /plaintext HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("expect-continue", "Expect: 100-continue, the body sent anyway", "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\nabc"),
	case("expect-other", "Expect: something else (RFC 9110 §10.1.1: 417)", "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: other\r\nContent-Length: 3\r\n\r\nabc"),
	case("connection-close", "Connection: close", "GET /plaintext HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
	case("http10-keepalive", "HTTP/1.0 asking to keep alive", "GET /plaintext HTTP/1.0\r\nConnection: keep-alive\r\n\r\nGET /plaintext HTTP/1.0\r\n\r\n"),
	case("not-found", "a path no one serves", "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("query", "a query string", "GET /plaintext?a=1 HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("dot-segments", "/./plaintext", "GET /./plaintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("percent-path", "/%70laintext (a percent-encoded p)", "GET /%70laintext HTTP/1.1\r\nHost: x\r\n\r\n"),
	case("method-on-get-route", "POST to a GET route", "POST /plaintext HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"),
	{ name: "garbage", about: "not HTTP at all", bytes: [0x16, 0x03, 0x01, 0x00, 0x05].concat("hello".to_utf8()) },
]

case : Str, Str, Str -> Diff.Case
case = |name, about, text| { name, about, bytes: text.to_utf8() }

## A competitor's server started, each case sent, the answers in a line
## each, and the server stopped.
competitor! : Config.Race, Config.Competitor, Target.Where, List(Diff.Case) => Try(List((Str, Str)), [BadFlag(Str), Failed(Str), Interrupted])
competitor! = |race, competitor, target, chosen| {
	pid = Target.start!(race, competitor, target, Plain)?
	answered = answers!(race, competitor, target, pid, chosen)
	Target.stop!(target, pid)
	answered
}

answers! : Config.Race, Config.Competitor, Target.Where, Str, List(Diff.Case) => Try(List((Str, Str)), [BadFlag(Str), Failed(Str), Interrupted])
answers! = |race, competitor, target, pid, chosen| {
	match Target.ready!(race, target, Plain) {
		Ok({}) => {}
		Err(Interrupted) => return Err(Interrupted)
		Err(Failed(_)) => return Err(Failed("${competitor.name}: ${Target.why_not_ready!(competitor, target, pid)}"))
	}
	chosen.map_try!(|c| {
		answer = exchange!(target.address, race.port, c.bytes) ? |why| as_failed(why, "${competitor.name}, ${c.name}")
		line = summary!(answer)?
		Ok((c.name, line))
	})
}

## Send a case and read its answer: to the server's close, or a second of
## silence once something came (two before anything); 4 MiB at most.
exchange! : Str, U64, List(U8) => Try(Diff.Answer, [Failed(Str), Interrupted])
exchange! = |address, port, request| {
	conn =
		match Tcp.connect!(address, port.to_u16_wrap(), { connect_timeout: Duration.seconds(2), io_timeout: Duration.seconds(2) }) {
			Ok(c) => c
			Err(Interrupted) => return Err(Interrupted)
			Err(TcpErr(err)) => return Err(Failed(Str.inspect(err)))
		}
	match conn.write_bytes!(request) {
		Ok({}) => {}
		Err(Interrupted) => return Err(Interrupted)
		Err(TcpErr(_)) => return Ok({ responses: [], closed: Bool.True, unparsed: "" })
	}
	var $raw = []
	var $closed = Bool.False
	var $reading = Bool.True
	while $reading and $raw.len() < 4 * 1024 * 1024 {
		wait = if $raw.is_empty() Duration.seconds(2) else Duration.seconds(1)
		match conn.with_timeout(wait).read_up_to!(65_536) {
			Ok(bytes) => {
				$raw = $raw.concat(bytes)
			}
			Err(TcpErr(TimedOut)) => {
				$reading = Bool.False
			}
			Err(Interrupted) => return Err(Interrupted)
			Err(_) => {
				$closed = Bool.True
				$reading = Bool.False
			}
		}
	}
	head = request.starts_with("HEAD ".to_utf8())
	{ responses, unparsed } = Diff.parse($raw, head)
	Ok({ responses, closed: $closed, unparsed })
}

## The answer in a line: what is compared. An error's body is each stack's
## own words: its status is what is compared.
summary! : Diff.Answer => Try(Str, [BadFlag(Str), Failed(Str), Interrupted])
summary! = |answer| {
	var $parts = []
	for response in answer.responses {
		var $part = response.status.to_str()
		for interim in response.interim {
			$part = "${interim.to_str()}+${$part}"
		}
		if !response.body.is_empty() and response.status < 400 {
			$part = "${$part} ${digest!(response.body)?}"
		}
		$parts = $parts.append($part)
	}
	if answer.unparsed != "" {
		$parts = $parts.append("unparsed ${Diff.quote(clip(answer.unparsed.to_utf8(), 24))}")
	}
	parts = if $parts.is_empty() ["nothing"] else $parts
	Ok("${Str.join_with(parts, ", ")} | ${if answer.closed "closed" else "open"}")
}

## A short body as itself, a long one by its length and hash.
digest! : List(U8) => Try(Str, [Failed(Str), Interrupted])
digest! = |body|
	if body.len() <= 16 and body.all(|b| b >= 0x20 and b <= 0x7e) {
		Ok(Diff.quote(body))
	} else {
		sum = Hash.bytes!(body)?
		Ok("${body.len().to_str()}B:${Text.take(sum, 6)}")
	}

clip : List(U8), U64 -> List(U8)
clip = |bytes, n| if bytes.len() <= n bytes else bytes.take_first(n).concat("…".to_utf8())

## The line at `at`, through its LF, without its CR LF; Cut when no LF ends
## it.
line_at : List(U8), U64 -> Try({ line : List(U8), next : U64 }, [Cut(List(U8))])
line_at = |raw, at| {
	rest = raw.drop_first(at)
	match rest.find_first_index(|b| b == '\n') {
		Ok(i) => Ok({ line: trim_crlf(rest.take_first(i)), next: at + i + 1 })
		Err(_) => Err(Cut(rest))
	}
}

trim_crlf : List(U8) -> List(U8)
trim_crlf = |bytes| {
	var $end = bytes.len()
	while $end > 0 and (bytes.get($end - 1) == Ok('\r') or bytes.get($end - 1) == Ok('\n')) {
		$end = $end - 1
	}
	bytes.take_first($end)
}

## A response's head: its status and its fields, by lower-cased name (a
## name given twice joined with a comma).
read_head : List(U8), U64 -> Try({ status : U64, fields : List((Str, Str)), next : U64 }, [Cut(Str)])
read_head = |raw, at| {
	{ line, next } = line_at(raw, at) ? |Cut(rest)| Cut("a cut status line ${Diff.quote(clip(rest, 40))}")
	text = Str.from_utf8_lossy(line)
	words = text.split_on(" ")
	status =
		match words {
			[version, code, ..] if version.starts_with("HTTP/1.") => U64.from_str(code) ? |_| Cut("a status ${Diff.quote(code.to_utf8())}")
			_ => return Err(Cut("not a status line ${Diff.quote(clip(line, 40))}"))
		}
	var $fields = []
	var $at = next
	var $count = 0
	while $count < 1000 {
		{ line: field_line, next: after } = line_at(raw, $at) ? |_| Cut("a cut head")
		$at = after
		if field_line.is_empty() {
			return Ok({ status, fields: $fields, next: $at })
		}
		match Str.from_utf8_lossy(field_line).split_first(":") {
			Ok({ before, after: value }) => {
				key = lower(before)
				joined =
					match $fields.find_first(|(k, _)| k == key) {
						Ok((_, previous)) => "${previous},${value}"
						Err(_) => value
					}
				$fields = $fields.keep_if(|(k, _)| k != key).append((key, joined.trim()))
			}
			Err(_) => return Err(Cut("a header line ${Diff.quote(clip(field_line, 40))}"))
		}
		$count = $count + 1
	}
	Err(Cut("a head of 1,000 lines"))
}

field : List((Str, Str)), Str -> Str
field = |fields, name| (fields.find_first(|(k, _)| k == name) ?? (name, "")).1

lower : Str -> Str
lower = |text| Str.from_utf8_lossy(text.to_utf8().map(|b| if b >= 'A' and b <= 'Z' b + 32 else b))

has_token : Str, Str -> Bool
has_token = |value, token| value.split_on(",").any(|part| lower(part.trim()) == lower(token))

## A body: chunked, by Content-Length, or the rest; none when `none`.
read_body : List(U8), U64, List((Str, Str)), Bool -> Try({ body : List(U8), after : U64 }, [Cut(Str)])
read_body = |raw, at, fields, none| {
	if none {
		return Ok({ body: [], after: at })
	}
	if has_token(field(fields, "transfer-encoding"), "chunked") {
		return read_chunked(raw, at)
	}
	match fields.find_first(|(k, _)| k == "content-length") {
		Ok((_, length)) => {
			n = U64.from_str(length) ? |_| Cut("a content-length ${Diff.quote(length.to_utf8())}")
			if at + n > raw.len() {
				Err(Cut("a body cut short"))
			} else {
				Ok({ body: raw.drop_first(at).take_first(n), after: at + n })
			}
		}
		Err(_) => Ok({ body: raw.drop_first(at), after: raw.len() })
	}
}

read_chunked : List(U8), U64 -> Try({ body : List(U8), after : U64 }, [Cut(Str)])
read_chunked = |raw, at| {
	var $body = []
	var $at = at
	var $chunks = 0
	while $chunks < 100_000 {
		{ line, next } = line_at(raw, $at) ? |_| Cut("a cut chunk size")
		size_text = Str.from_utf8_lossy(line).split_first(";").map_ok(|{ before, .. }| before) ?? Str.from_utf8_lossy(line)
		n = hex(size_text.trim()) ? |_| Cut("a chunk size ${Diff.quote(clip(line, 20))}")
		if n == 0 {
			# The trailer section, to its empty line.
			var $trailer = next
			var $lines = 0
			while $lines < 100 {
				match line_at(raw, $trailer) {
					Ok({ line: t, next: after }) =>
						if t.is_empty() {
							return Ok({ body: $body, after })
						} else {
							$trailer = after
						}
					Err(_) => return Ok({ body: $body, after: raw.len() })
				}
				$lines = $lines + 1
			}
			return Err(Cut("a long trailer"))
		}
		if next + n + 2 > raw.len() {
			return Err(Cut("a chunk cut short"))
		}
		$body = $body.concat(raw.drop_first(next).take_first(n))
		$at = next + n + 2
		$chunks = $chunks + 1
	}
	Err(Cut("100,000 chunks"))
}

## A hexadecimal number, as Go's ParseInt(s, 16, 64) reads one: an optional
## +, then hex digits.
hex : Str -> Try(U64, [NotHex])
hex = |text| {
	digits = text.drop_prefix("+").to_utf8()
	if digits.is_empty() or digits.len() > 15 {
		return Err(NotHex)
	}
	var $n = 0
	for b in digits {
		value =
			if b >= '0' and b <= '9' {
				b - '0'
			} else if b >= 'a' and b <= 'f' {
				b - 'a' + 10
			} else if b >= 'A' and b <= 'F' {
				b - 'A' + 10
			} else {
				return Err(NotHex)
			}
		$n = $n * 16 + value.to_u64()
	}
	Ok($n)
}

as_failed : [Failed(Str), Interrupted], Str -> [BadFlag(Str), Failed(Str), Interrupted]
as_failed = |err, what|
	match err {
		Failed(why) => Failed("${what}: ${why}")
		Interrupted => Interrupted
	}

ok : Str
ok = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nDate: x\r\n\r\nHello, World!"

expect Diff.parse(ok.to_utf8(), Bool.False) == { responses: [{ status: 200, close: Bool.False, body: "Hello, World!".to_utf8(), interim: [] }], unparsed: "" }
expect Diff.parse("${ok}${ok}".to_utf8(), Bool.False).responses.len() == 2
expect {
	chunked = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\nConnection: Close\r\n\r\n3;x=y\r\nabc\r\nA\r\n0123456789\r\n0\r\nX: 1\r\n\r\n"
	Diff.parse(chunked.to_utf8(), Bool.False) == { responses: [{ status: 200, close: Bool.True, body: "abc0123456789".to_utf8(), interim: [100] }], unparsed: "" }
}
expect Diff.parse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n".to_utf8(), Bool.True).responses.map(|r| r.body) == [[]]
expect Diff.parse("HTTP/1.1 400 Bad\r\nConnection: close\r\n\r\nbad request".to_utf8(), Bool.False).responses.map(|r| r.body) == ["bad request".to_utf8()]
expect Diff.parse("garbage\r\n".to_utf8(), Bool.False).unparsed == "not a status line \"garbage\": garbage\r\n"
expect Diff.parse("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nabc".to_utf8(), Bool.False).unparsed == "a body cut short"
expect hex("a") == Ok(10) and hex("+3") == Ok(3) and hex("zz").is_err() and hex("").is_err()
expect Diff.quote([0x16, 'a', '"', '\r']) == "\"\\x16a\\\"\\r\""
expect Diff.select("plain,head").map(|c| c.name) == ["plain", "head"]
expect cases.len() == 59
expect {
	report = Diff.report(["a", "b"], Diff.select("plain,head"), [("a", [("plain", "200 | open"), ("head", "200 | open")]), ("b", [("plain", "200 | open"), ("head", "400 | closed")])])
	report.contains("| `head` **≠**: HEAD: the head alone | 200 | open | 400 | closed |") and report.ends_with("2 cases, 1 answered differently.\n")
}
