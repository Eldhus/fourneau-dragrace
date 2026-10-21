import pf.Http
import pf.Path
import http.Request
import http.Response
import Fetch
import Hash
import JsonValue
import Retry
import Text

## What the racer asks of GitHub: the builds build.yml released and their
## files, and fourneau's and roux's masters. The repositories are public,
## so it holds no token. A call or download that fails for a moment is
## tried again (Retry.github): a 504 on a release's download must not
## spend the night's check.
GitHub :: [].{
	## build.json: a release's commits, its files' SHA-256, each
	## competitor's key, the race key over them and the harness key.
	Info : { commits : List((Str, Str)), files : List((Str, Str)), competitors : List((Str, Str)), race_key : Str, harness_key : Str }

	## A release of build.yml: its build.json, and its files' URLs.
	Build : { info : Info, assets : List((Str, Str)) }

	## The repositories a race races, by their names in the site's database.
	raced : List(Str)
	raced = ["fourneau-dragrace", "fourneau", "roux"]

	## The raced repositories build.yml takes at their masters.
	upstream : List(Str)
	upstream = ["fourneau", "roux"]

	## The newest builds, newest first by when each was published (GitHub
	## lists releases by their commit's date); a release whose body is not
	## a build.json is not one.
	builds! : Str => Try(List(Build), [Failed(Str), Interrupted])
	builds! = |repository| {
		text = GitHub.get!("/repos/${repository}/releases?per_page=30")?
		releases = JsonValue.parse(text) ? |_| Failed("GitHub's releases: not JSON")
		Ok(GitHub.builds_of(releases))
	}

	builds_of : JsonValue -> List(Build)
	builds_of = |releases|
		releases.items()
			.sort_with(|a, b| Text.order(b.get("published_at").text(), a.get("published_at").text()))
			.keep_oks(
				|release| {
					if !release.get("tag_name").text().starts_with("build-") {
						return Err(NotABuild)
					}
					info = GitHub.info(release.get("body").text())?
					assets = release.get("assets").items().map(|a| (a.get("name").text(), a.get("browser_download_url").text()))
					Ok({ info, assets })
				},
			)

	## A build.json read; one with no commits is not one.
	info : Str -> Try(Info, [NotABuild])
	info = |text| {
		parsed : Try({ commits : Dict(Str, Str), files : Dict(Str, Str), competitors ?: Dict(Str, Str), race_key ?: Str, harness_key ?: Str }, _)
		parsed = Json.parse(text)
		match parsed {
			Ok(b) if b.commits.len() > 0 =>
				Ok({
					commits: b.commits.to_list(),
					files: b.files.to_list(),
					competitors: (b.?competitors ?? Dict.empty()).to_list(),
					race_key: b.?race_key ?? "",
					harness_key: b.?harness_key ?? "",
				})
			_ => Err(NotABuild)
		}
	}

	## The upstream repositories' newest commits on master, by name.
	masters! : Str => Try(List((Str, Str)), [Failed(Str), Interrupted])
	masters! = |owner|
		GitHub.upstream.map_try!(
			|name| {
				text = GitHub.get!("/repos/${owner}/${name}/branches/master")?
				branch = JsonValue.parse(text) ? |_| Failed("${name}'s master: not JSON")
				sha = branch.get("commit").get("sha").text()
				if sha == "" Err(Failed("${name}'s master: no commit in GitHub's answer")) else Ok((name, sha))
			},
		)

	## A release's file to `path`, checked against its SHA-256.
	download! : Str, Str, Str => Try({}, [Failed(Str), Interrupted])
	download! = |url, sha256, path| {
		fetched = Retry.run!(
			Retry.github,
			"GitHub download",
			|| {
				Fetch.download_once!(url, path)?
				got = Hash.file!(path) ? |err| when_failed(err)
				if got != sha256 {
					_ = Path.utf8(path).delete!()
					Err(Refused("${url}: SHA-256 ${got}, build.json says ${sha256}"))
				} else {
					Ok({})
				}
			},
		)
		match fetched {
			Ok({}) => Ok({})
			Err(Refused(why)) => Err(Failed(why))
			Err(Failed(why)) => Err(Failed(why))
			Err(Interrupted) => Err(Interrupted)
		}
	}

	## A path of GitHub's API, its answer's body.
	get! : Str => Try(Str, [Failed(Str), Interrupted])
	get! = |path| {
		got = Retry.run!(Retry.github, "GitHub GET ${path}", || get_once!(path))
		match got {
			Ok(text) => Ok(text)
			Err(Refused(why)) => Err(Failed(why))
			Err(Failed(why)) => Err(Failed(why))
			Err(Interrupted) => Err(Interrupted)
		}
	}

	## The newest build of this repository at a commit.
	newest_of_commit : List(Build), Str -> Try(Build, [NotFound])
	newest_of_commit = |builds, commit|
		if commit == "" Err(NotFound) else builds.find_first(|b| lookup(b.info.commits, "fourneau-dragrace") == commit)

	## The newest build of exactly these commits.
	with_commits : List(Build), List((Str, Str)) -> Try(Build, [NotFound])
	with_commits = |builds, commits|
		builds.find_first(|b| GitHub.raced.all(|name| lookup(b.info.commits, name) != "" and lookup(b.info.commits, name) == lookup(commits, name)))

	## A value by its name, "" for none.
	value_of : List((Str, Str)), Str -> Str
	value_of = |pairs, name| lookup(pairs, name)
}

get_once! : Str => Try(Str, [Moment(Str), Refused(Str), Interrupted])
get_once! = |path| {
	request =
		Request.from_method(GET)
			.with_uri("https://api.github.com${path}")
			.add_header("Accept", "application/vnd.github+json")
			.add_header("X-GitHub-Api-Version", "2022-11-28")
			.with_timeout(TimeoutMilliseconds(120_000))
	response =
		match Http.send!(request, {}) {
			Ok(answer) => answer
			Err(Interrupted) => return Err(Interrupted)
			Err(InvalidUrl(_)) => return Err(Refused("${path}: not a URL"))
			Err(HttpErr(err)) => return Err(Moment("GitHub GET ${path}: ${Str.inspect(err)}"))
		}
	status = Response.status(response)
	text = Str.from_utf8_lossy(Response.body(response))
	if status >= 200 and status < 300 {
		Ok(text)
	} else if status >= 500 or status == 429 {
		Err(Moment("GitHub GET ${path}: ${status.to_str()}: ${text.trim()}"))
	} else {
		Err(Refused("GitHub GET ${path}: ${status.to_str()}: ${text.trim()}"))
	}
}

lookup : List((Str, Str)), Str -> Str
lookup = |pairs, name|
	match pairs.find_first(|(key, _)| key == name) {
		Ok((_, value)) => value
		Err(_) => ""
	}

when_failed : [Failed(Str), Interrupted] -> [Moment(Str), Refused(Str), Interrupted]
when_failed = |err|
	match err {
		Failed(why) => Refused(why)
		Interrupted => Interrupted
	}

release = |tag, published, commit| "{\"tag_name\":\"${tag}\",\"published_at\":${published},\"draft\":false,\"body\":\"{\\\"commits\\\":{\\\"fourneau-dragrace\\\":\\\"${commit}\\\",\\\"fourneau\\\":\\\"f\\\",\\\"roux\\\":\\\"r\\\"},\\\"files\\\":{\\\"race.tar.gz\\\":\\\"aa\\\"},\\\"race_key\\\":\\\"k-${commit}\\\"}\",\"assets\":[{\"name\":\"race.tar.gz\",\"browser_download_url\":\"https://x/${tag}/race.tar.gz\",\"size\":1}]}"

expect {
	text = "[${release("build-old", "\"2026-10-01T00:00:00Z\"", "a")},${release("build-new", "\"2026-10-02T00:00:00Z\"", "b")},${release("v1.0", "\"2026-10-03T00:00:00Z\"", "c")},{\"tag_name\":\"build-draft\",\"published_at\":null,\"body\":null,\"assets\":[]}]"
	builds = GitHub.builds_of(JsonValue.parse(text) ?? Null)
	builds.map(|b| b.info.race_key) == ["k-b", "k-a"] and (builds.first() ?? crash "none").assets == [("race.tar.gz", "https://x/build-new/race.tar.gz")]
}

expect {
	text = "[${release("build-1", "\"2026-10-01T00:00:00Z\"", "a")}]"
	builds = GitHub.builds_of(JsonValue.parse(text) ?? Null)
	GitHub.newest_of_commit(builds, "a").is_ok() and GitHub.newest_of_commit(builds, "").is_err() and GitHub.with_commits(builds, [("fourneau-dragrace", "a"), ("fourneau", "f"), ("roux", "r")]).is_ok() and GitHub.with_commits(builds, [("fourneau-dragrace", "a"), ("fourneau", "f"), ("roux", "x")]).is_err()
}

expect GitHub.info("{\"commits\":{}}").is_err()
