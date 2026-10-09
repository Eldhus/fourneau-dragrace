# Ad-hoc races: two builds, one answer, in under a minute

Is this branch faster than that one? Name the two builds; the laptop
builds each and keeps it; a server and a loader in the cloud race them,
three rounds each; you get a table: requests a second for each, the
difference, and whether it is real or within noise. The machines stay up
20 minutes in case you ask again, then delete themselves. Warm, 50
seconds.

```sh
out/dragrace adhoc race -workloads templates \
    roux:roux=templates,dragrace=templates \
    roux:roux=templates-vm,dragrace=templates-vm
out/dragrace adhoc down            # delete the machines now
```

Asked for by the owner on 2026-10-08, to compare roux's template branches
by the clock rather than by the laptop's instruction counts; built for an
agent to call as often as a human runs a test. Kept simple on purpose
(owner, 2026-10-08): two commands, two flags; a third, `-open`, asked
for on 2026-10-09.

## A variant

`COMPETITOR[:REPO=REF,...]`, REPO one of `dragrace` (this repository: the
competitor's source and how to build and run it), `fourneau`, `roux`; a
repository not named is at its local checkout's `HEAD`. A REF is anything
git knows in the local checkout (a branch, a tag, a hash, `origin/main`);
one it does not know is fetched from origin once. Committed work only.

Two variants may differ in any of the three: roux's template branches
need this repository's matching branch too (the competitor's Roc differs).

## The flags

- `-workloads` (default: all five closed-loop ones, `plaintext,echo-4k,templates,sse,churn`; about two minutes of racing for two variants).
- `-rounds` (default 3). Each round races every variant once, in a new
  order; a workload is 1 s of warmup and 4 s measured.
- `-open` (owner, 2026-10-09): after the rounds, race.json's open-loop
  ladder on each workload, every variant at the **same** offered rates,
  shares of the first variant's closed-loop median (the nightly's ladder
  is each server's own share, right for a league table, wrong for an
  A/B). Latency from when each request was due. A second table, a line
  per rate and variant; `open_step` events. About 65 s a variant
  (five steps, 3 s warm, 10 s measured); one climb each, so one sample
  a rate.

Everything else is fixed: the class `dedicated-2` (dedicated cores, so a
difference is the builds'), race.json's region, 20 minutes idle.

## What it costs

Measured 2026-10-08 (roux's two template branches, `templates`, from the
laptop to lon1):

| step | first time | after |
|---|---|---|
| build each variant | 118-123 s (Zig compiles roux's host and tools) | 0 (cached by content); 4 s when only the competitor changed |
| the machines | 64 s (alongside the builds) | 0 (warm) |
| upload each variant | 1.6-2.1 s (1.6 MB) | 0 (the server has it) |
| race | ~50 s (2 variants, 1 workload, 3 rounds; a rerun adds 8 s) | the same |
| **the whole command** | 298 s | **50 s** |

## How

- **Builds** on the laptop, at the variant's commits, each variant in its
  own directory under `out/adhoc/tree/` holding the three repositories
  side by side (RACING.md's layout): clones sharing the local
  repositories' objects, checked out in place, so git rewrites only the
  files a commit changed and Zig's cache (`out/adhoc/zig-cache`) keeps
  the rest (a fresh export each build missed it every time: 117 s for
  identical sources). The competitor is built with its own
  `competitor.json` and pins at its commit.
- **The cache** keys a build by the competitor and every file of the
  three trees but Markdown, so a documentation commit keeps its build.
  Kept stripped and compressed: roux's 17 MB is 1.6 MB.
- **The machines**: a server and a loader kept between races, their own
  tag (`fourneau-dragrace-adhoc`: the racer and its guard never see
  them). A user systemd timer, re-armed by every race, deletes them after
  20 minutes unused; `dragrace reap` sweeps them past race.json's
  `max_age_minutes` too. Paid by the owner's token (the environment, or
  the keyring: `secret-tool lookup service digitalocean name
  fourneau-dragrace`), not the racer's budget.
- **One ssh connection** (ControlMaster) for every call: a round trip a
  call, not a handshake's several, 90-140 ms to lon1.
- **The race** is RACING.md's, checked first as a nightly checks. A round
  whose server was under 95% CPU measured something else (the network, a
  neighbour: two of eighteen on 2026-10-08); that variant is raced again,
  twice at most, and the saturated rounds kept.

## The answer

Standard error: the progress, the machines (CPU model and generation),
and the table:

```
workload   variant                                          req/s   vs 1st    p99 ms  rounds
templates  roux:roux=templates,dragrace=templates          144223               4.31  144223 143226 144688
templates  roux:roux=templates-vm,dragrace=templates-vm    140950    -2.3%      4.01  141129 140950 132159
```

A difference counts when every round of one variant is above every round
of the other; `~` after it: the ranges overlap, this race cannot tell
the two apart (more `-rounds` can).

Standard output: the same as events, one JSON object a line, each with
`t`, the seconds since the start, for a script or an agent:

| event | when | fields |
|---|---|---|
| `resolved` | each variant's refs found | `variant`, `commits`, `key` |
| `built` | each variant built, or found | `cached`, `seconds` |
| `session` | the machines ready | `reused`, `seconds`, `machines` |
| `uploaded` | a binary sent | `bytes`, `seconds` |
| `round` | each measured round | `variant`, `workload`, `round`, `rps`, `p50_ms`, `p99_ms`, `cpu_busy_pct`, `errors`, `non_2xx` |
| `invalid` | a variant failed the checks | `why` |
| `rerun`, `dropped` | a round not server-bound, raced again, dropped | |
| `result` | the end | `comparison` (per workload and variant: median req/s, every round's, median p99, the difference to the first, `apart`), `results_file` |

## Decided, and why (2026-10-08)

- **Builds on the laptop**, not the racer and not GitHub's: the laptop
  has the toolchains, warm caches and every local branch; the racer is
  one shared vCPU, GitHub's build up to 40 minutes. The upload costs 2 s
  once per session; the builds are reproducible (the same bytes twice).
- **No reuse of the releases' binaries**: they exist only for main's
  heads, which the nightly races anyway.
- **Closed-loop workloads only, and their ladder with `-open`**: conduit is
  open loop only (a seeded
  database a start, a ladder of rates, minutes a competitor); refused,
  with a pointer to a nightly or `race cloud -workloads conduit`.
- **A stream of lines, no server with SSE**: nothing stays up between
  races but the machines, and lines read the same in a terminal, a pipe
  and an agent.
- **No `up` or `status`, no class, region, idle or timing flags**: one
  setup, the race makes the machines and prints them (owner: "simple").
- **The owner's money, bounded**: the idle timer was tested end to end
  (its user unit read the token from the keyring and deleted the pair,
  the key and the session); `reap` is the backstop.
