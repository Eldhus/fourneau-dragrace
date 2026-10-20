import pf.Env
import pf.Http
import pf.OsStr
import pf.Path
import pf.Utc
import http.Request
import http.Response
import Checkout
import Fetch
import Flags
import Run
import Text
import Time

## notify pushes the site's failure to the owner's phone, through ntfy.sh.
## The uptime check misses a crash: the site is back within seconds
## (Restart=always), between two of its probes. The site's OnFailure=
## starts dragrace-site-crashed.service, which runs this: systemd gives it
## the failure ($MONITOR_*, systemd 251 and later), the topic as a
## credential (LoadCredential=, from /etc/dragrace-host/ntfy-topic, which
## site install-server writes from the owner's keyring), and a state
## directory. The daily restart is a clean stop and starts nothing.
##
## The topic is the only secret: an unreserved ntfy.sh topic is anyone's
## who knows its name, and an ntfy.sh access token would be the whole
## account (they have no scopes). The message names the failure and the
## restart count, never the site's log; no error shows the topic.
Notify :: [].{
	## A failure as systemd hands it to an OnFailure= unit: MONITOR_UNIT,
	## MONITOR_SERVICE_RESULT (core-dump, signal, oom-kill, exit-code,
	## timeout), MONITOR_EXIT_CODE (dumped, killed, exited),
	## MONITOR_EXIT_STATUS (ABRT, KILL, 1), and NRestarts (since the site was
	## last started by hand or by its timer).
	Failure : { unit : Str, result : Str, code : Str, status : Str, restarts : Str }

	## `dragrace notify [-unit U]`, as dragrace-site-crashed.service.
	command! : List(Str) => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
	command! = |args| {
		flags = Flags.parse(args, [{ name: "unit", kind: Value("dragrace-site.service"), usage: "the unit, when systemd does not say" }])?
		credentials = env!("CREDENTIALS_DIRECTORY")
		state = env!("STATE_DIRECTORY")
		if credentials == "" or state == "" {
			return Err(Failed("notify runs as dragrace-site-crashed.service: no credentials or state directory"))
		}
		topic_path = "${credentials}/ntfy-topic"
		topic = Notify.topic(Checkout.read!(topic_path)?) ? |_| Failed("${topic_path}: not an ntfy topic (letters, digits, - and _, at most 64)")
		# systemd leaves $MONITOR_* out when more than one unit could have
		# started this one ("multiple trigger source candidates"): the unit's
		# last result is then asked for. An alert is never skipped for want
		# of its details.
		named = env!("MONITOR_UNIT")
		unit = if named == "" Flags.value(flags, "unit") else named
		shown = Notify.shown(Run.output!("", ["systemctl", "show", "-p", "Result,ExecMainCode,ExecMainStatus,NRestarts", unit]) ?? "")
		result = env!("MONITOR_SERVICE_RESULT")
		failure =
			if result == "" {
				{ unit, result: shown("Result"), code: exit_code_name(shown("ExecMainCode")), status: shown("ExecMainStatus"), restarts: shown("NRestarts") }
			} else {
				{ unit, result, code: env!("MONITOR_EXIT_CODE"), status: env!("MONITOR_EXIT_STATUS"), restarts: shown("NRestarts") }
			}
		send!(topic, state, failure)
	}

	## The topic, checked against ntfy's grammar: [A-Za-z0-9_-]{1,64}.
	topic : Str -> Try(Str, [NotTopic])
	topic = |text| {
		trimmed = text.trim()
		bytes = trimmed.to_utf8()
		good = |b| (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_' or b == '-'
		if bytes.len() >= 1 and bytes.len() <= 64 and bytes.all(good) Ok(trimmed) else Err(NotTopic)
	}

	## `systemctl show`'s NAME=VALUE lines, as a lookup: "?" for a property
	## it did not say.
	shown : Str -> (Str -> Str)
	shown = |output| {
		pairs = Text.lines(output).keep_oks(|line| line.trim().split_first("=").map_ok(|{ before, after }| (before, after)))
		|name|
			match pairs.find_first(|(key, value)| key == name and value != "") {
				Ok((_, value)) => value
				Err(_) => "?"
			}
	}

	## The alert: the failure in a few words, and where its log is.
	message : Failure -> { title : Str, body : Str }
	message = |failure| {
		verb = if ["core-dump", "signal", "oom-kill", "watchdog"].contains(failure.result) "crashed" else "failed"
		how = if failure.code != "" or failure.status != "" "${failure.result} (${"${failure.code} ${failure.status}".trim()})" else failure.result
		{ title: "dragrace site ${verb}", body: "${failure.unit}: ${how}; restarted ${failure.restarts} times since its last start.\njournalctl -u ${failure.unit}" }
	}
}

## The least time between two alerts: a crash every few seconds is one
## alert, not a storm (the uptime check says it is down).
quiet_ms : I64
quiet_ms = 5 * 60_000

env! : Str => Str
env! = |name| Env.var_str!(OsStr.from_str(name)) ?? ""

## ExecMainCode's numbers (waitid's CLD_*) as $MONITOR_EXIT_CODE names them.
exit_code_name : Str -> Str
exit_code_name = |number|
	match number {
		"1" => "exited"
		"2" => "killed"
		"3" => "dumped"
		_ => ""
	}

## Post the alert, unless one went within five minutes.
send! : Str, Str, Notify.Failure => Try({}, [BadFlag(Str), Failed(Str), Interrupted])
send! = |topic, state, failure| {
	stamp = Path.utf8("${state}/last-sent")
	now = Utc.now!().to_millis_since_epoch().to_i64_wrap()
	match stamp.read_utf8!() {
		Ok(text) =>
			match Time.parse_ms(text.trim()) {
				Ok(sent) if now - sent < quiet_ms => {
					Run.log!("${failure.unit}: ${failure.result}; not sent, one went at ${text.trim()}")
					return Ok({})
				}
				_ => {}
			}
		Err(_) => {}
	}
	{ title, body } = Notify.message(failure)
	request =
		Request.from_method(POST)
			.with_uri("https://ntfy.sh/${topic}")
			.add_header("Title", title)
			.add_header("Priority", "5")
			.add_header("Tags", "rotating_light")
			.add_header("User-Agent", Fetch.user_agent)
			.with_body(body.to_utf8())
			.with_timeout(TimeoutMilliseconds(30_000))
	response =
		match Http.send!(request, {}) {
			Ok(answer) => answer
			Err(Interrupted) => return Err(Interrupted)
			# Never the URL: it holds the topic.
			Err(InvalidUrl(_)) => return Err(Failed("ntfy: not a URL"))
			Err(HttpErr(err)) => return Err(Failed("ntfy: ${Str.inspect(err)}"))
		}
	if Response.status(response) != 200 {
		return Err(Failed("ntfy: ${Response.status(response).to_str()}: ${Text.take(Str.from_utf8_lossy(Response.body(response)).trim(), 512)}"))
	}
	Run.log!("${failure.unit}: ${failure.result}; sent")
	stamp.write_utf8!("${Time.format_ms(now)}\n") ? |PathErr(err, _)| Failed("${state}/last-sent: ${err.to_str()}")
	Ok({})
}

expect Notify.topic(" dragrace-alerts_1\n") == Ok("dragrace-alerts_1")
expect Notify.topic("a b").is_err() and Notify.topic("").is_err() and Notify.topic(Str.repeat("a", 65)).is_err()
expect {
	look = Notify.shown("Result=core-dump\nExecMainCode=3\nExecMainStatus=\nNRestarts=4\n")
	look("Result") == "core-dump" and look("ExecMainCode") == "3" and look("ExecMainStatus") == "?" and look("Other") == "?"
}
expect Notify.message({ unit: "dragrace-site.service", result: "core-dump", code: "dumped", status: "ABRT", restarts: "2" }) == { title: "dragrace site crashed", body: "dragrace-site.service: core-dump (dumped ABRT); restarted 2 times since its last start.\njournalctl -u dragrace-site.service" }
expect Notify.message({ unit: "u", result: "exit-code", code: "", status: "", restarts: "?" }).title == "dragrace site failed"
expect exit_code_name("2") == "killed"
