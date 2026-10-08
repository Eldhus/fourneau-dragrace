# Ad-hoc races: two builds, one answer, in under a minute

`dragrace adhoc race` races builds of a competitor at chosen commits
against each other, on a few workloads, on a cloud server with dedicated
cores: the question "is this branch faster than that one?" answered by
the clock, not by the laptop's instruction counts. Asked for by the owner
on 2026-10-08, to compare roux's template branches; built for an agent to
call as often as a human would run a test.

```sh
out/dragrace adhoc race -workloads templates \
    roux:roux=templates,dragrace=templates \
    roux:roux=templates-vm,dragrace=templates-vm
out/dragrace adhoc status          # the warm machines, if any
out/dragrace adhoc down            # delete them now
```

## A variant

`COMPETITOR[:REPO=REF,...]`, REPO one of `dragrace` (this repository: the
competitor's source and how to build and run it), `fourneau`, `roux`; a
repository not named is at its local checkout's `HEAD`. A REF is anything
git knows in the local checkout (a branch, a tag, a hash, `origin/main`);
one it does not know is fetched from origin once. Committed work only:
uncommitted changes are not raced.

Two variants may differ in any of the three: roux's template branches
need this repository's matching branch too (the competitor's Roc differs).

## What happens, and what it costs

Measured 2026-10-08 (roux's two template branches, the `templates`
workload, dedicated-2 in lon1, from the laptop):

| step | first time | after |
|---|---|---|
| resolve the refs, key each variant | < 1 s | < 1 s |
| build each variant | 118-123 s (roux: Zig compiles the host and the tools) | 0 (cached by content); 4 s rebuilt in its checkout when only the competitor changed |
| the machines | 64 s (two droplets, cloud-init, oha) | 0 (the session) |
| upload each variant | 1.6-2.1 s (1.6 MB) | 0 (the server has it) |
| race | ~50 s (2 variants, 1 workload, 3 rounds of 1 + 4 s; a rerun adds 8 s) | the same |
| **the whole command** | 298 s | **50 s** warm; 64 s with two rebuilds |

So a question about builds already made takes the race's time; a new
roux commit adds its build (Zig recompiles the host: about 2 minutes
when its sources changed).

- **Builds** are local, at the variant's commits: each variant has its
  own directory under `out/adhoc/tree/` holding the three repositories
  side by side (as RACING.md's layout), clones sharing the local
  repositories' objects, checked out in place. git rewrites only the
  files a commit changed, so Zig's cache (`out/adhoc/zig-cache`, shared)
  recompiles only what changed; a fresh export every build missed it
  every time (117 s for identical sources). The competitor is built with
  its own `competitor.json` and pins at its commit.
- **The cache** keys a build by the competitor and every file of the
  three trees but Markdown (`git ls-tree`), so a commit of documentation
  only keeps its build. The binary is kept stripped (symbols only; the
  code is the same) and compressed with zstd: roux's 17 MB is 1.6 MB.
- **The machines** are a session: a server and a loader of a class of
  race.json (`-class`, default `dedicated-2`: dedicated cores, so no
  neighbour moves a number), kept between races. A user systemd timer,
  re-armed by every command, deletes them after `-idle` minutes unused
  (default 20); `dragrace reap` sweeps them after race.json's
  `max_age_minutes` too. They carry their own tag
  (`fourneau-dragrace-adhoc`): the racer and its guard never see them. A
  session costs the two droplets' hourly price while it lives (c-2 and
  c-4), from the owner's token (the environment, or the keyring:
  `secret-tool lookup service digitalocean name fourneau-dragrace`), not
  the racer's budget.
- **The connection**: every ssh call to the session shares one kept
  connection (ControlMaster): a round trip a call, not a handshake's
  several, from a laptop 90-140 ms from lon1.
- **The race** is RACING.md's, short: `-rounds` (3), each variant once a
  round in a new order, `-warmup` (1 s) and `-measure` (4 s) a
  workload, checked first as a nightly race checks. A round whose
  server was under 95% CPU measured something else (the network, a
  neighbour: two of six rounds on 2026-10-08, the loader dipping with
  them); the variant is raced again, twice at most, and the saturated
  rounds kept.

## The answer

Standard output is a stream of events, one JSON object a line, each with
`t`, the seconds since the command started:

| event | when | fields |
|---|---|---|
| `resolved` | each variant's refs found | `variant`, `commits`, `key` |
| `built` | each variant built, or found | `cached`, `seconds` |
| `session` | the machines ready | `reused`, `seconds`, `machines` (CPU model and generation) |
| `uploaded` | a binary sent | `bytes`, `seconds` |
| `round` | each measured round | `variant`, `workload`, `round`, `rps`, `p50_ms`, `p99_ms`, `cpu_busy_pct`, `errors`, `non_2xx` |
| `invalid` | a variant failed the checks | `why` |
| `rerun`, `dropped` | a round not server-bound, raced again, dropped | |
| `result` | the end | `comparison`: per workload and variant the median req/s, every round's, the median p99, and against the first variant the difference and whether the rounds' ranges are apart; `results_file` |

Standard error has the progress for people, and the table:

```
workload   variant                                          req/s   vs 1st    p99 ms  rounds
templates  roux:roux=templates,dragrace=templates          144223               4.31  144223 143226 144688
templates  roux:roux=templates-vm,dragrace=templates-vm    140950    -2.3%      4.01  141129 140950 132159
```

`~` after a difference: the rounds' ranges overlap, so this race cannot
tell the two apart; race again or longer (`-rounds 5 -measure 8`).

Why a stream and not a server with SSE: nothing has to stay up between
races (the session is two droplets and a timer, not a process), and a
stream of lines is read the same by a terminal, a pipe, a script and an
agent waiting on it; it is SSE's shape without its server.

## Not yet

- Reusing a binary the release already has (`build.yml` builds main's
  heads): the server could download it from GitHub's CDN, faster than
  a build and an upload, and the very binary the nightly races.
- The open-loop workloads (conduit): refused for now.
- Building on the racer instead of the laptop: only worth it if a build
  must not depend on the laptop; the laptop is the fast machine here.
