import pf.Monotonic
import pf.Sleep
import Run

## Trying again what fails for a moment: a site restarting for a deploy, a
## 5xx from GitHub. The wait doubles from `first_ms` up to `most_ms`, for
## at most `window_ms` in all; an attempt that fails for good (a refusal)
## is never tried again.
Retry :: [].{
	Policy : { first_ms : U64, most_ms : U64, window_ms : U64 }

	## The site's: 1 s doubling to 30 s, for 20 minutes, ten times a deploy.
	site : Policy
	site = { first_ms: 1_000, most_ms: 30_000, window_ms: 20 * 60_000 }

	## GitHub's: 2 s doubling to a minute, for half an hour.
	github : Policy
	github = { first_ms: 2_000, most_ms: 60_000, window_ms: 30 * 60_000 }

	## The wait before attempt `n` (1 for the second attempt).
	wait_before : Policy, U64 -> U64
	wait_before = |policy, n| {
		var $wait = policy.first_ms
		var $i = 1
		while $i < n and $wait < policy.most_ms {
			$wait = $wait * 2
			$i = $i + 1
		}
		if $wait > policy.most_ms policy.most_ms else $wait
	}

	## Run `attempt!` until it succeeds, fails for good (`Refused`), or the
	## window passes; each failure for a moment is logged with its wait.
	run! : Policy, Str, (() => Try(a, [Moment(Str), Refused(Str), Interrupted])) => Try(a, [Failed(Str), Refused(Str), Interrupted])
	run! = |policy, what, attempt!| {
		start = Monotonic.now!()
		var $n = 1
		var $last = ""
		while Bool.True {
			match attempt!() {
				Ok(value) => return Ok(value)
				Err(Refused(why)) => return Err(Refused(why))
				Err(Interrupted) => return Err(Interrupted)
				Err(Moment(why)) => {
					$last = why
					wait = Retry.wait_before(policy, $n)
					if start.elapsed!().to_millis() + wait > policy.window_ms {
						return Err(Failed("${what}: ${$n.to_str()} attempts over ${(policy.window_ms // 60_000).to_str()} minutes: ${$last}"))
					}
					Run.log!("${what} (attempt ${$n.to_str()}): ${why}; again in ${(wait // 1000).to_str()} s")
					Sleep.millis!(wait)?
					$n = $n + 1
				}
			}
		}
	}
}

expect Retry.wait_before(Retry.site, 1) == 1_000
expect Retry.wait_before(Retry.site, 2) == 2_000
expect Retry.wait_before(Retry.site, 5) == 16_000
expect Retry.wait_before(Retry.site, 6) == 30_000
expect Retry.wait_before(Retry.site, 60) == 30_000
expect Retry.wait_before(Retry.github, 1) == 2_000
