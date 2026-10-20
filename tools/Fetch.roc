import pf.File
import pf.Http
import pf.Path
import http.Request
import Checkout
import Hash
import Run

## Downloads: written to disk a chunk at a time, checked against their
## SHA-256 before they take their name. A file already there with the
## pinned hash is not fetched again; one with another hash is an error,
## never a silent download over it.
Fetch :: [].{
	## `url` to `path`, unless a file with the hash `want` is there.
	pinned! : Str, Str, Str => Try({}, [Failed(Str), Interrupted])
	pinned! = |url, want, path| {
		if Hash.file!(path) == Ok(want) {
			return Ok({})
		}
		partial = "${path}.partial"
		Fetch.download!(url, partial)?
		got = Hash.file!(partial)?
		if got != want {
			_ = Path.utf8(partial).delete!()
			return Err(Failed("${url}: sha256 ${got}, pinned ${want}"))
		}
		rename!(partial, path)
	}

	## `url` to `path`, whose contents the caller checks, unless it exists.
	unpinned! : Str, Str => Try({}, [Failed(Str), Interrupted])
	unpinned! = |url, path| {
		if Path.utf8(path).exists!() == Ok(Bool.True) {
			return Ok({})
		}
		Fetch.download!(url, "${path}.partial")?
		rename!("${path}.partial", path)
	}

	## `url` to `path`, following GitHub's redirects to its storage.
	download! : Str, Str => Try({}, [Failed(Str), Interrupted])
	download! = |url, path| {
		Path.utf8(Checkout.parent(path)).create_all!() ? |PathErr(err, _)| Failed("${path}: ${err.to_str()}")
		Run.log!("fetch ${url}")
		request = Request.from_method(GET).with_uri(url)
		response =
			match Http.send_streaming!(request, { max_redirects: 5 }) {
				Ok(answer) => answer
				Err(Interrupted) => return Err(Interrupted)
				Err(InvalidUrl(_)) => return Err(Failed("${url}: not a URL"))
				Err(HttpErr(err)) => return Err(Failed("${url}: ${transport(err)}"))
			}
		if response.status() != 200 {
			return Err(Failed("${url}: ${response.status().to_str()}"))
		}
		written = File.with_writer!(Path.utf8(path), Truncate, {}, |writer| writer.write_stream!(response.chunks()))
		match written {
			Ok({}) => Ok({})
			Err(SourceErr(Interrupted)) => Err(Interrupted)
			Err(SourceErr(HttpErr(err))) => Err(Failed("${url}: ${transport(err)}"))
			Err(FileErr(err)) => Err(Failed("${path}: ${err.to_str()}"))
			Err(PathErr(err, _)) => Err(Failed("${path}: ${err.to_str()}"))
		}
	}
}

rename! : Str, Str => Try({}, [Failed(Str), Interrupted])
rename! = |from, to|
	Path.utf8(from).rename!(Path.utf8(to)).map_err(|PathErr(err, _)| Failed("${to}: ${err.to_str()}"))

## What failed on the way, in words.
transport : Http.TransportErr -> Str
transport = |err|
	match err {
		Timeout => "timed out"
		NetworkError => "network error"
		BadBody => "the body could not be read"
		Other(bytes) => Str.from_utf8_lossy(bytes)
		RedirectLimitExceeded(n) => "more than ${n.to_str()} redirects"
		InvalidRedirectUrl(_) => "a redirect to no URL"
		AmbiguousRedirectLocation => "a redirect to two places"
		InsecureRedirect => "a redirect from HTTPS to HTTP"
	}
