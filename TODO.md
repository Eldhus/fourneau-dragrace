# todo

## WIP
0. **Self-hosting: the site keeps the races, and runs them.** (owner,
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
   - Decided (owner, 2026-10-07): the read-write workload is a slice of
     RealWorld's Conduit API (`conduit`), not a todo list.
   - Where it stands (2026-10-07): deployed and racing. The site host runs
     the new site and deploys itself; the racer (lon1) with its guard
     ($25 a month) raced the first cloud race from a request: 52 min,
     $0.29, 60 results, a deploy and a reboot of the site mid-race lost
     nothing. The racer's build matching was wrong (GitHub's
     `created_at`) and is fixed. The audit, the system written up end to
     end, its findings (the owner's doc, "The fourneau drag race: how it
     works, end to end"): open ones below in Todo.
   - 2026-10-07, after: the site host moved to lon1 on Ubuntu 26.04
     (104.248.175.105), its data migrated (no CPU pin, so three columns
     fewer); both hosts reboot for updates at 02:30 New York time.
   - Next: the 03:00 check tonight (it races: new commits) proves the
     timer path and the new site; then this item goes.
1. **Tabs by size, smallest first; machines' memory; the bar under the
   fire.** (owner, 2026-10-07)
   - Where it stands (2026-10-07): done and tested on localhost; pushed in
     08ce01c (another session's commit took the uncommitted files with
     it). The bar under the fire was redone (owner): one masthead on
     every page, the fire raised behind the menu; the owner checks it on
     localhost. The build adds `machines.memory_mib`, so it fails the live
     schema check and the host agent keeps the old site (live at 18:03
     UTC: no HSTS header, the old style.css), which holds back 08ce01c's
     HSTS too. Tonight's race is safe meanwhile: the new workers post
     `memory_mib` and the old site ignores it (Roc's `Json.parse` skips
     unknown fields, tested; a missing field is still refused); that
     run's memory is lost.
   - Next (owner): push 360e5cb (the migration and DIARY), then on the
     site host run `docs/migrations/2026-10-07-machine-memory.sql` as its
     header says, `sudo rm /opt/dragrace-site/failed/*`, and start the
     host agent's timer. Check the HSTS header and the tabs.
2. **`dragrace site dev`: edit a template, see it in under a second.**
   (owner, 2026-10-07) A watcher over the templates, queries, Roc and
   static files; regeneration and a dev-backend build (`--opt=dev`); the
   app restarted behind a proxy that reloads the browser. The testing
   ground for a build server in roux; races and deploys keep the
   optimized build.
   - Measured (2026-10-07): `roc build` (LLVM, optimized) 83 to 94 s every
     time, unchanged or not (LIR passes 31 s, LLVM 49 s); `--opt=dev` 1.8
     to 2.7 s, 1.5 s of it Roc's shared lowering; the interpreter 3 s and
     0.2 to 0.9 s a page. rocstache-gen 3 ms, roux-db 11 ms, `roc test`
     1 s. The dev binary serves every page byte for byte as the optimized
     one.
   - Where it stands (2026-10-07): built and in use
     (`tools/cmd/dragrace/site_dev.go`). Save to reloaded page measured
     at 3.0 s for a template (the dev build 2.4 to 2.9 s, the restart 40 to
     70 ms), 10 ms for a static file. Under a second is not reached: Roc
     lowers the whole program on every build (1.5 to 1.7 s, none of it
     cached), and `--specialize=no` crashes the compiler (SIGSEGV,
     nightly-2026-10-04).
   - Next, the owner's call: report the SIGSEGV and ask upstream for
     incremental lowering (the one path to under a second while
     templates are Roc); or, a big experiment, a dev mode in which
     rocstache templates are interpreted, not compiled, which needs the
     contexts as data (Roc has no reflection). Then port the devserver
     into roux (Zig) once it has settled.
3. **The site's pages type in what race.json and the racer decide.**
   (owner, 2026-10-07: "don't do nasty things like that; audit for
   more") An audit of site/ for figures typed into views and templates
   that a run's data, race.json or the racer's timer already hold; they go
   stale when those change. Fixed: the ladder's caption ("50% to 120%",
   now from the run's steps).
   - Found, for the owner's call (render each from the run's data, keep
     as prose and add to the two-places chore, or cut):
     - "03:00 New York time": `site/Store.roc` (the race page's status
       line) and `IndexPage.rocstache`; the racer's timer holds it.
     - `IndexPage.rocstache`: "Five workloads raced flat out" and their
       list; "Three rounds".
     - `MethodPage.rocstache`: 5 s warmup, 20 s measured, three rounds.
     - `WorkloadsPage.rocstache`: each workload's connections (256, 64),
       the 4,096-byte body, 13 bytes, Conduit's shares (50/30/15/5%) and
       rates (250 to 32,000), the seed (100 users, 1,000 articles), the
       warmup and rounds, the ladder's steps (50% to 120%), the loader's
       85% (also `loader_limit_pct` in View.roc).
     - Worked examples (256 connections at 50,000/s is about 5 ms;
       "20,000 requests a second") are prose, not settings: keep.

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

- **Rotate the GitHub token `fourneau-dragrace-racer`** before it
  expires (a year): a new one with the same settings (SECURITY.md), into
  the keyring, `dragrace racer install` again, delete the old one.
  - Last done: 2026-10-07 (made; GitHub says it expires 2027-10-08:
    checked to reach this repository's Actions only, every other write
    refused).

- **Rotate the DigitalOcean race token** before it expires (90 days):
  make a new one with the same scopes (SECURITY.md; scopes cannot be
  changed later), into the keyring, `dragrace racer install` again (it
  re-encrypts the guard's credential), delete the old one.
  - Last done: 2026-10-07 (made anew with `droplet:update`, scopes
    cannot be changed; the old one deleted by the owner; checked: droplet,
    ssh_key and tag allowed, domains, databases, billing, volumes,
    firewalls and projects refused; due by 2027-01-05).

## Todo

- [ ] Live demos on the site: roux's examples, running (the templates and
  database workloads are done: templates, conduit). (2026-10-05)
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
- [ ] A site check in CI: load each page in a headless browser and fail on
  console errors (2026-10-05)
- add more bleeding edge kernel option to ubuntu. lets us stay closer to
  io_uring regression and improves. maybe even helping upstream.
  (2026-10-06: the droplets are on 26.04 LTS now, kernel 7.0; newer would
  mean a mainline or HWE kernel on top.)
- [ ] Dedicated Premium Intel (c-4-intel, loader c-8-intel) for
  `premium-4` once DigitalOcean offers it again: on 2026-10-06 every
  Premium Intel size listed no region (`dragrace sizes`). (2026-10-06)
- [ ] The Competitors page's pins lack basic-webserver (0.17.0) and the
  conduit drivers (modernc.org/sqlite, sqlx, SQLite 3.53.4): versions.json
  holds none of them, so no run records them. Add them to versions.json
  (the racer posts every pin it has) and to `View.pins`. (2026-10-07)
- [ ] Report to basic-webserver (the owner reports): its host leaves SIGPIPE
  at the default, so a client closing during an SSE stream kills the
  server (exit 141; `competitors/basic-webserver/README.md`). Then drop
  the `trap '' PIPE` wrapper in its competitor.json. (2026-10-06)
- [ ] Measure each class's network (iperf3 from its loader) and say the
  cap on the site: echo-4k ties at ~42k requests/s on dedicated-2 and
  ~28k on premium-4 for every fast competitor, so it measures the
  droplet's link there, not the server (forced run 37518540726). A
  smaller body, or the link's number beside the result. (2026-10-06)
- [ ] An open-loop ladder on more workloads than templates (and
  conduit's own): plaintext and SSE would show stalls the closed loop
  hides. (2026-10-06)
- [ ] Blind spots the 2026-10-06 review found and did not fix:
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
  s-8vcpu-16gb). The CPU is not pinned now (RACING.md, "The same
  machine within a night"): read the history with each night's CPU, and
  compare a few races before trusting a trend under ~20%. (2026-10-06)
- [ ] Long term (owner, 2026-10-07): reproducible builds, the answer to
  both of these, rather than skipping docs-only commits by path (a rule
  that guesses what is raced, and goes wrong the day a doc file is
  built in):
  - The site's build is not reproducible: two builds of the same source
    differ only in symbol names (`__anon_<n>`), so every push restarts
    the site for nothing (a second; clients retry). Find where the
    numbering comes from (Roc or Zig); stripping the symbols in `dragrace
    bundle` would hide it, not fix it.
  - Every commit is new to the nightly check, docs and TODO too: a night
    races again ($0.29) for commits that change nothing raced. With
    reproducible competitor builds, the check could compare what was
    built (the binaries' hashes) instead of the commits. (2026-10-07)
- [ ] Conduit has no history line: its runs keep steps, not a median.
  Plot, say, the highest rate a server held under 90%, night by night.
  (2026-10-07)
- [ ] The class's data link (`/data/classes/ID/CLASS.json`) is the page's
  model: a subset of each round's measures. Every measure is in the
  database: an export of it whole. (2026-10-07)
- [ ] Conduit's chart: rates double each step, and the linear axis kept
  for likeness bunches the low ones; a log axis would read them.
  (2026-10-07)

## Tickler
