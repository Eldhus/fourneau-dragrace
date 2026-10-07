# todo

## WIP
0. **A benchmarking tune-up, adversarially; an open-loop test.** (owner,
   2026-10-06) Read a ChatGPT thread on the race's method (with a grain
   of salt), find what the data does not fit and where the blind spots
   are, everywhere; an open-loop test for tail latency and saturation
   (research: ramp or fixed rates); timing on the site; keep only what
   is useful (drop `premium-4` if it adds nothing until dedicated Intel
   exists). Commit, do not push.
   - Where it stands (2026-10-06): done and committed, not pushed (the
     owner pushes after reviewing): open-loop ladder on templates; oha
     without compression and with explicit threads; packets recorded;
     rates over oha's own duration (the window bias found in run
     37532162780, mended on publish); a "limited by" verdict per result
     on the site; timing on the site; fourneau-zig built for baseline
     x86-64 (its native build died of an illegal instruction on every
     droplet); `premium-4` dropped, dedicated-2's loader s-8vcpu-16gb (lon1 has no c-8); Go's echo
     tuned (+28%). Next: the owner pushes, then a forced race (the first
     with all of it); the blind spots not fixed are Todo items.

1. **A Premium 10 Gbit/s class, a loader per class, tabs.** (owner,
   2026-10-06) A third server class on Premium CPU-optimized droplets
   (10 Gbit/s, which echo-4k needs: 2 Gbit/s capped it), each class with
   its own loader one size bigger, the three pairs racing at once; the
   site shows one class at a time, a tab each (`?class=`). Then a forced
   run at once.
   - Where it stands (2026-10-06): loaders per class and tabs stay;
     `premium-4` is dropped (WIP 0: shared vCPUs varying 15% a round,
     ~1 Gbit/s with retransmits where 10 was documented, and a network
     slow enough that 256 connections saturated nothing). Dedicated
     Premium Intel when offered (Todo); then this item goes.

2. **basic-webserver as a competitor.** (owner, 2026-10-06) Roc's own
   platform, roc-lang/basic-webserver (Rust host on hyper and tokio), as
   released: 0.17.0 targets the nightly the race pins.
   - Where it stands (2026-10-06): done locally
     (`competitors/basic-webserver/`): every check passes, every workload
     races (quick local race). Started with SIGPIPE ignored (Todo: report
     upstream). Waits on the owner: push; then its first cloud race.

3. **An SSE workload: Datastar responses.** (owner, 2026-10-06) A
   request with Datastar's signals in the query, answered with a short
   stream of Datastar events (`text/event-stream`, chunked, no
   Content-Length), as a Datastar action is. Go, axum and basic-webserver
   stream today; fourneau and roux do not, so fourneau gets streamed
   responses and roux an `Sse` module, TigerStyle.
   - Where it stands (2026-10-06): done locally in all five competitors:
     fourneau's streamed responses (fourneau 45a028c, c2d9236: simulator
     streams and cut-short streams, six injected bugs caught), roux's
     `Sse` and `Url` (roux 9787890, `examples/sse`), the check (a chunk
     per event, 400 without signals), `race.json`, RACING.md's contract,
     the Workloads page; a quick local race runs every competitor on it.
     Waits on the owner: push fourneau, roux and this repository (in that
     order: the nightly builds main of each); then the first cloud race.

4. **Ubuntu 26.04, the pronunciation, a resquash, push and install.**
   (owner, 2026-10-06) Droplets and runners on Ubuntu 26.04 LTS (kernel
   7.0), checked working; "say inferno, drop the in" back on About only;
   then fold the commits since the squash into the archived history
   (`~/devel/eldhus-history/fourneau-dragrace.bundle`), squash main again,
   push, and install the site.
   - Where it stands (2026-10-06): image bumped and pronunciation added,
     tested locally (tool tests, every page 200 on the republished live
     data); archived and squashed, force-pushed, site installed (production
     certificate). The first forced race died on a new key DigitalOcean
     did not know yet (now retried); next: its rerun on 26.04.

5. **Self-hosting: the site keeps the races, and runs them.** (owner,
   2026-10-06) Results in the site's SQLite (roux, `synchronous=FULL`),
   every run's metadata first class (a JSON field only where it pays); a
   unique run ID unifying a run; each run says how it started (manual or
   timer, and which repositories had new commits), and a check with no
   new commits is recorded as skipped. Race workers push their results
   straight to the site, retrying for well past a deploy, so a deploy
   during a race loses nothing. Push to GitHub is the whole deploy
   (GitHub builds, owner's choice; the host pulls); no GitHub runner held
   for a race. A private authenticated endpoint to start a run, and one a
   cron may hit to check for new commits; the race page says when new
   commits will race tonight. Backups automatic (nightly copies on the
   host, DigitalOcean's droplet backups); migrations over SSH for now.
   A budget cap. Legacy data dropped. Clean up the runner workflows, the
   deploy key and the results branch. A new mixed read-write workload in
   every competitor: a todo list, SQLite in the loop, `synchronous=NORMAL`
   everywhere, open loop, the same line chart, mean latency.
   - Decided (2026-10-06): the DigitalOcean token lives on a second small
     droplet, the racer, with no service and no inbound port but the
     owner's SSH; the site never holds it. The racer enforces the budget
     (fixed sizes, a monthly cap on its own disk). Builds are GitHub's;
     the site host and the racer pull them.
   - Where it stands (2026-10-06): planned. Next: roux, a synchronous
     setting per database and `Sqlite.backup!`.

## Chores

- **Check that every value kept in two places agrees.** Each row of
  VERSIONS.md names where its pin lives: open each place and confirm they
  match (the droplet image in race.json and versions.json is tested; the
  workflows' `runs-on` against versions.json's runner_image is not, nor
  any prose that names a version: README, RACING.md, the site's
  templates). The site's own pages show versions from each run's data,
  never typed in. Also when any pin changes.
  - Last done: 2026-10-06 (Ubuntu 24.04 to 26.04: race.json, versions.json,
    the four workflow jobs, VERSIONS.md; `site provision` now reads the
    pin; no page or doc typed the version).

- **Rotate the DigitalOcean race token** before it expires (90 days):
  make a new one with the same scopes, update the keyring and the
  `dragrace` environment, delete the old one.
  - Last done: never (made 2026-10-05 or after; due by 2026-12-28).

## Todo

- [ ] Templates and database workloads, on roux (the Roc platform), with
  live demos (2026-10-05)
- [ ] `dragrace diff`: differential tests of fourneau against Go and axum,
  moved here from fourneau (owner, 2026-10-06; fourneau's `reference/`
  apps duplicated `competitors/`). (2026-10-06)
  - The competitors grow the endpoints a comparison needs: echo the
    request (method, target, headers, body length and hash), fixed bodies
    of given sizes, a chunked response, a slow response, a static file,
    an SSE stream; written as each language's programmers would, defaults
    changed only to match limits.
  - The tool sends the same seeded request stream to each (TCP, later TLS
    and HTTP/2) and compares status, the headers that matter, and body.
    Malformed and adversarial input is where it pays: a disagreement is
    our bug or a decision, and a decision is written down with its
    reason (`DIVERGENCES.md`).
  - Later: `fourneau-static` against Go's `FileServer`, tower-http's
    `ServeDir` and Caddy (fourneau M6 and M11).
- security review. if comprimised what secrets are on the server??
    - also if i was to move to a completely self hosted dragrace
      runner/coordinator on digocean instead of github, could that be done
      without too many keys? how to limit impact of my api key lost.  i didnt
      see a hard budget cap on digocean just alerts.
- [ ] A site check in CI: load each page in a headless browser and fail on
  console errors (2026-10-05)
- add more bleeding edge kernel option to ubuntu. lets us stay closer to
  io_uring regression and improves. maybe even helping upstream.
  (2026-10-06: the droplets are on 26.04 LTS now, kernel 7.0; newer would
  mean a mainline or HWE kernel on top.)
- [ ] Dedicated Premium Intel (c-4-intel, loader c-8-intel) for
  `premium-4` once DigitalOcean offers it again: on 2026-10-06 every
  Premium Intel size listed no region (`dragrace sizes`). (2026-10-06)
- [ ] Self-hosting (owner, 2026-10-06): once roux has its database, the
  site receives each race's results at an endpoint and keeps them, with
  the commit of every repository, the server classes and configurations;
  the nightly posts there instead of pushing to the `results` branch.
  (2026-10-06)
- [ ] The site's Versions table lacks basic-webserver: the pins come from
  each run's `versions`, and Roc's `Json.parse` rejects a run without the
  field, so adding it breaks every published run. Give `versions.json` a
  `basic_webserver` entry once the site reads optional fields (or the
  published runs are rewritten). (2026-10-06)
- [ ] Report to basic-webserver (the owner reports): its host leaves SIGPIPE
  at the default, so a client closing during an SSE stream kills the
  server (exit 141; `competitors/basic-webserver/README.md`). Then drop
  the `trap '' PIPE` wrapper in its competitor.json. (2026-10-06)
- [ ] Measure each class's network (iperf3 from its loader) and say the
  cap on the site: echo-4k ties at ~42k requests/s on dedicated-2 and
  ~28k on premium-4 for every fast competitor, so it measures the
  droplet's link there, not the server (forced run 37518540726). A
  smaller body, or the link's number beside the result. (2026-10-06)
- [ ] `site install-server` should deploy freshly published data with the
  code: a site that reads a new field 500s on data an older tool wrote
  (2026-10-06: the p95 columns, until the runs were republished and
  deployed). Either install-server republishes the results branch and
  deploys it, or the site reads new fields as optional. (2026-10-06)
- [ ] An open-loop round per workload (the Workloads page promises it):
  oha at a fixed rate, a share of each server's closed-loop maximum (half
  and 90%), `--latency-correction`, so coordinated omission no longer
  hides stalls from p99 and p99.9. (2026-10-06)
- [ ] Show each race's duration and cost on the site (the run's `timing`,
  2026-10-06). Only once the live data has `timing` (a race published by
  a tool that records it, or the runs republished): the site reads fields
  strictly, and reading it earlier 500s, as the p95 columns did. (2026-10-06)
- [ ] Blind spots the 2026-10-06 review found and did not fix (WIP 0):
  - No TLS workload: production servers terminate TLS, and fourneau's
    kTLS against rustls (axum) and crypto/tls (Go) is a real difference
    the race cannot see.
  - No idle-connection capacity: memory per held connection (10k idle
    keep-alives, SSE subscribers) is a property of a server the race
    never asks about; fourneau's ~100 KiB a slot may lose there.
  - Bodies are checked once, by curl, before the race; under load only
    the status is counted. A server returning wrong bytes fast under
    load would win. Sample bodies during a round.
  - Churn is under-driven for the fastest (roux at 77% CPU on
    dedicated-2 with 64 connections): try 128 (the loader's ports and
    TIME_WAIT allow it with tcp_tw_reuse).
  - Echo 4 KiB reaches dedicated-2's link (~1.5 Gbit/s, retransmits)
    for the top two: labelled "network" now; or a 1 KiB body.
  - SSE: fourneau-zig sends ready events in one write, Go flushes each
    (its SDK does): the contract allows both, and the gap is partly that.
    A variant with a wait between events would test streaming itself.
  - One droplet per class a night samples no host variance; three
    rounds do not separate results within a few percent. Show the round
    spread and the night-to-night history beside the bars.
  - Steal read 0 on every shared droplet: check DigitalOcean reports it
    at all before trusting a 0.
  (2026-10-06)
- [ ] Pin the smallest droplet's CPU (`server_cpu` in race.json) once a few
  races have recorded its `cpu_id` (it reports only "DO-Regular" by name):
  the most frequent family:model:stepping. Also check whether pinning
  dedicated-2 to the 8168 needs more than six droplets some nights (the
  log says each try). (2026-10-06)
- [ ] For the owner (fourneau, roux; not this repository): under the open
  loop, fourneau-zig and roux have the worst tails at moderate load. At
  50% of their own maximum on dedicated-2: p99 20 ms (fourneau-zig) and
  15 ms (roux) against axum 8.5, Go 4.5, basic-webserver 2; on the
  smallest droplet roux 170 ms at 73% CPU where axum had 2 ms. And
  fourneau-zig stops keeping up earlier: 52k of 58k offered at 90%, p99
  1 s. The closed loop hid it (coordinated omission). Race 37546068955.
  (2026-10-06)
- [ ] Night-to-night variance on one CPU model: roux plaintext on
  dedicated-2's Xeon 8168 did 152k one race and 119k the next, the server
  at 95-99% both times; the loader type changed between them (c-4 to
  s-8vcpu-16gb). Pinning the CPU is not enough: compare a few races
  before trusting a trend under ~20%; consider pinning the loader too.
  (2026-10-06)
- [ ] A race takes 63 minutes of racing for ~40 of load: every
  measurement is several SSH round trips from GitHub's US runner to
  lon1 (snapshots, warmups, RSS). Fewer calls (one script per
  measurement on the loader), or the race in a region near the runner.
  (2026-10-06)
- [ ] A domain name for the site (owner, 2026-10-06: wants one). Then
  ACME for the name, HSTS takes effect. (2026-10-05)

## Tickler
