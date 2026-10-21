import pf.Http
import http.Method
import http.Request
import http.Response
import Retry

## The site's API (site/Api.roc) with a bearer token. A request the site
## did not answer, or answered 5xx or 429 (a deploy restarting it, a
## database busy), is sent again (Retry.site): the site answers a repeat as
## the first, so a post whose answer was lost does no harm sent twice. A
## 4xx is the site refusing: never sent again.
SiteApi :: [].{
	Client : { base : Str, token : Str }

	client : Str, Str -> Client
	client = |base, token| { base: base.drop_suffix("/"), token }

	## GET a path; the answer's body.
	get! : Client, Str => Try(Str, [Failed(Str), Refused(Str), Interrupted])
	get! = |site, path| SiteApi.call!(site, GET, path, Err(None), Retry.site)

	## POST JSON to a path; the answer's body.
	post! : Client, Str, Str => Try(Str, [Failed(Str), Refused(Str), Interrupted])
	post! = |site, path, json| SiteApi.call!(site, POST, path, Ok(json), Retry.site)

	## POST with a policy of its own: a worker's, which must not hold the race
	## up for twenty minutes.
	post_with! : Client, Str, Str, Retry.Policy => Try(Str, [Failed(Str), Refused(Str), Interrupted])
	post_with! = |site, path, json, policy| SiteApi.call!(site, POST, path, Ok(json), policy)

	call! : Client, Method, Str, Try(Str, [None]), Retry.Policy => Try(Str, [Failed(Str), Refused(Str), Interrupted])
	call! = |site, method, path, body, policy| {
		what = "site ${method.to_str()} ${path}"
		Retry.run!(policy, what, || once!(site, method, path, body))
	}
}

once! : SiteApi.Client, Method, Str, Try(Str, [None]) => Try(Str, [Moment(Str), Refused(Str), Interrupted])
once! = |site, method, path, body| {
	base =
		Request.from_method(method)
			.with_uri("${site.base}${path}")
			.add_header("Authorization", "Bearer ${site.token}")
			.with_timeout(TimeoutMilliseconds(60_000))
	request =
		match body {
			Ok(json) => base.add_header("Content-Type", "application/json").with_body(json.to_utf8())
			Err(None) => base
		}
	response =
		match Http.send!(request, {}) {
			Ok(answer) => answer
			Err(Interrupted) => return Err(Interrupted)
			Err(InvalidUrl(_)) => return Err(Refused("${site.base}${path}: not a URL"))
			Err(HttpErr(err)) => return Err(Moment(Str.inspect(err)))
		}
	status = Response.status(response)
	text = Str.from_utf8_lossy(Response.body(response)).trim()
	if status >= 200 and status < 300 {
		Ok(Str.from_utf8_lossy(Response.body(response)))
	} else if status >= 400 and status < 500 and status != 429 {
		Err(Refused("the site refused: ${path}: ${status.to_str()}: ${text}"))
	} else {
		Err(Moment("${status.to_str()}: ${text}"))
	}
}
