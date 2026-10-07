# Diary

What was done, measured and learned, in order. Newest last.

## 2026-10-06: into Eldhus

Moved to `~/devel/eldhus/`. fourneau and roux are two repositories now,
checked out beside this one; the tool fingerprints both commits and a
race runs when either moves. Every competitor built and a short local
race ran after the move. Before it (2026-10-05): the tool, the four
competitors, the site, the workflows and the docs were written in one
day, and local races ran end to end.

## 2026-10-06: the docs harmonized

The owner asked for one official stance per kind of document, kept in the
eldhus skill (`eldhus-way/references/docs.md`), and every repository
brought to it. The first pass here: CLAUDE.md and this diary, created; the
README gained the Eldhus line, Status, Build, Read and License (none yet);
the WIP item's "where it stands" and the chore's last-done line in the
standard shape. Every CLAUDE.md got the same `## Always` lines.

## 2026-10-06: no CLAUDE.md

The owner wants nothing Claude-specific in the repositories. This
repository's CLAUDE.md is gone: what it said about this repository is now
the README's "Working on it", and what every repository shares is in the
one `~/devel/eldhus/CLAUDE.md` (eldhus-skill's `workspace/CLAUDE.md`,
symlinked), which Claude Code loads for any session started below it.

## 2026-10-06: a cleanup pass

Across Eldhus, at the owner's request. Here: the 10.7 MB `tools/dragrace`
binary is untracked and ignored (it is built into `out/`; history keeps
it until the owner re-roots); the README explains its own name instead of
fourneau's, says what builds `fourneau-static` and where versions are
pinned; the site's roux card uses competitor.json's title; the token's
due date moved into its chore; SECURITY.md starts with Reporting.

## 2026-10-06: the site on HTTPS

`site install-server` now writes the site's units itself (the boot script
only makes users, firewall and directories), loads the kernel's `tls`
module, opens 443 and enables a daily restart that renews the
certificate. With `-acme staging`, then `-acme production`:
https://174.138.75.219/ serves with a Let's Encrypt certificate for the
host's IP address, and `http://` redirects there.

Bring-up fixes before that: the first provision found no `admin` user
(Ubuntu's image has an admin group; the user is `cook`), and the server
crashed on Ubuntu 24.04's 6.8 kernel (fourneau bound with io_uring's
BIND, from 6.11), then on its first deploy (it read the hidden restart
marker); all fixed in fourneau and here.

## 2026-10-06: the templates workload

`GET /menu`: a 12-row HTML table rendered from a template per request,
the dishes chosen so some values need escaping (`&`, `<b>`, `<warm>`) and
none has a quote (engines spell `"` differently, as `&#34;` or `&quot;`).
`workloads/menu.html` is the reference; each competitor uses what its
users would: Go's `html/template`, askama 0.16 on axum, rocstache on roux
(compiled at build time by roux's rocstache-gen), and a comptime template
on fourneau-zig (`src/template.zig`, parts and holes split by the
compiler).

askama writes `&#38;` and `&#60;` for `&amp;` and `&lt;`: the same HTML,
other bytes. The check canonicalizes the spellings and then compares
byte for byte, so a page that forgets to escape still fails (a test says
so). The first local run marked all four invalid: the shell helper trims
the trailing newline its output ends with, the reference did not.

Quick local race (one short round, a smoke test): fourneau-zig 208,584
requests/s (p99 2.74 ms), roux 118,264 (3.42), axum 94,617 (4.64), Go
19,650 (27.01).

## 2026-10-06: the first cloud race

The size preflight and the owner's size list moved the race to nyc1 (no
CPU-optimized droplets in nyc3). Forced nightly 37474346156: gate, race
(54 min 42 s), publish; the site's latest run is
`2026-10-06T135849Z-cloud`. Medians, requests/s:

| dedicated-2 | fourneau-zig | roux | axum | go |
|---|---|---|---|---|
| plaintext | 167,971 | 167,886 | 89,933 | 45,620 |
| templates | 168,278 | 113,398 | 81,493 | 18,033 |
| churn | 21,670 | 20,524 | 20,091 | 15,354 |
| echo-4k | 35,705 | 35,986 | 35,898 | 18,152 |

| smallest | roux | axum | go |
|---|---|---|---|
| plaintext | 59,137 | 32,720 | 20,012 |
| templates | 38,336 | 30,134 | 7,892 |
| churn | 12,619 | 8,232 | 6,384 |
| echo-4k | 22,838 | 18,810 | 8,266 |

- fourneau-zig did not start on the smallest droplet: one shard of 4,096
  slots at ~100 KiB each is ~400 MiB of 512. Now 1,024 slots for the
  machine, as roux's; it serves under a 400 MiB cap.
- echo-4k on dedicated-2: three servers at ~36,000 requests/s with the
  same p99 (208 ms): 4 KiB each way at that rate is ~1.2 Gbit/s, the
  private network, not the servers. Worth saying on the site, or a
  smaller body.

## 2026-10-06: the site is a roux app

The owner: no second server; the site itself becomes the demo. `site/`
is now a roux app: every page a rocstache template (`Top` and `Bottom`
frame them), `Data.roc` parsing `data/latest.json` and `data/index.json`
on each request into typed records, `View.roc` turning a run into the
drag strips and the history charts (SVG geometry in Roc, 47 expects).
The browser draws nothing; `demo.js` is only the fire on the home page.
Old addresses (`/about.html`) redirect to the new ones (`/about`).

- Roc's `Json.parse` refuses a missing field and a null list. The tool
  wrote `note` only when set and nil rounds as null, so production's
  `latest.json` would not parse. Both are always written now (a test
  pins it), and `writeIndex` rewrites `latest.json` on every publish.
- Deploys send the data only, read per request: no restart, no
  `.deployed` marker, no path unit. The binary, templates and static
  files come only with install-server, so the deploy key can write
  false results but never code.
- The built site is one static binary, 11 MiB; locally ~115 MiB
  resident with 8 shards.
- Live at https://174.138.75.219/ (2026-10-06), every page checked; the
  site uses ~110 MiB of the host's 512. The first start failed: the
  unit's placeholder `ACME_DIRECTORY` also matched inside the variable
  `ROUX_ACME_DIRECTORY`; placeholders are braced now, and a test checks
  the filled-in unit.

## 2026-10-06: the site, plainer

The owner: too long, too branded, too silly for a passerby. The tagline is
"HTTP drag races" alone; the sine scroller, the "say inferno" line, the
thanks list and the TigerStyle talk are gone; the front page has a
two-line intro above the results and three bullets below them; Method,
Contribute and About are a third shorter; templates are no longer "coming
soon". A favicon (a flame). Each class's "raw data" link serves only that
class (`data/classes/RUN/CLASS.json`, written by publish for every run).

fourneau-zig's DNF on the smallest droplet in the first race was the
4,096-slot startup (fixed in b6c16a6), but its note said only "exit
status 1": a server that never answers now gets a note saying whether it
is still running, the end of its output and the kernel's out-of-memory
line.

## 2026-10-06: basic-webserver joins

The owner asked for Roc's own platform as a competitor. roc-lang's
basic-webserver 0.17.0 (released 2026-10-05) targets the very nightly the
race pins, so it races as released: the app names the bundle by URL.
Its defaults would have answered most of the race's 256 in-flight
requests 503 (32 handlers, 64 queued, 256 connections): raised to 1,024
connections, 1,024 queued, 1,024 SSE streams, and nothing else. The menu
is the platform's `Html` module; its doctype spelling and lack of line
breaks needed a hand-written doctype and text nodes. A fifth series color
was searched for with the dataviz validator over the sRGB cube against
the other four: violet `#8010f8`, colorblind dE 9.9 and normal-vision
21.2 from every other, 3:1 on the surface.

Measured (`dragrace race local -quick -competitors basic-webserver`, a
smoke test on the laptop with a browser running, not a result):
plaintext 29.0k req/s, echo-4k 27.5k, templates 6.6k, churn 12.6k. The
templates number stands out: building an `Html` node tree and escaping
byte by byte per request.

## 2026-10-06: an SSE workload, first half

The owner asked for a Datastar response simulator. `GET /sse` carries
Datastar's signals as JSON in the `datastar` query parameter, and the
answer is ten Datastar events (`workloads/sse.txt`): the new count as a
signal, the count's element, eight log lines appended. The contract is
how it is sent as much as what: chunked, no Content-Length, one chunk
per event, checked from curl's raw output (`stream.go`). Without that,
a server could render the whole stream as one body and race the
templates workload under another name; basic-webserver's own Datastar
example does exactly that for actions whose events are all ready.
Requests without good signals are 400, also checked. Go (flush per
event, as Datastar's SDK), axum (`Sse`) and basic-webserver
(`Sse.unfold!`) answer it.

Two bugs found on the way:
- The tool's throughput: oha's rate counts every request that ended,
  errors too, and the 2xx scaling was skipped when no status code came
  back at all, so a dead server raced at 121k requests/s. Now scaled by
  good answers among everything that ended (a test pins it).
- basic-webserver dies of SIGPIPE when a client closes mid-stream (exit
  141, on the third 5-second run): its host runs under Roc's entry
  point, so nothing ignores SIGPIPE as Rust's `main` would. It now starts
  with SIGPIPE ignored, as systemd starts services; a Todo to report it.

Measured (quick local runs, a browser busy, smoke tests only):
sse at 15.9k req/s for Go, 53.2k for axum, 2.4k for basic-webserver
(whose plaintext is 31.9k: its streams cost about thirteen times a plain
answer).

## 2026-10-06: the first race of three classes

Forced run 37518540726, lon1, the three classes at once, each with its
own loader: every competitor started everywhere, fourneau-zig on the
smallest droplet too (1,024 slots fit where 4,096 did not). No errors in
any round. On the smallest droplet fourneau-zig and roux lead every
workload (plaintext ~53k req/s, axum 34k, Go 22k). On dedicated-2
fourneau-zig and roux reach ~150k on plaintext against axum's 72k.
echo-4k is a network number on both larger classes: on dedicated-2
axum, fourneau-zig and roux all stop at ~41.9k, and on premium-4 (Basic
Premium AMD, "up to 10 Gbit/s") at ~28k, lower still. The 10 Gbit/s did
not show; a Todo to measure each link.

## 2026-10-06: the SSE workload, all five

fourneau-zig and roux joined Go, axum and basic-webserver on `/sse`,
once fourneau could stream (its DIARY) and roux had `Sse` (its DIARY).
fourneau-zig's events are made into the connection's scratch memory and
wait in the send buffer, so the ten leave in one write; roux's are
effects from Roc, one a `send!`. The `sse` entry went into `race.json`
with them, so no push ever raced a competitor that could not stream.

Measured (`dragrace race local -quick`, one round, a browser running:
smoke numbers): sse at 169k req/s for fourneau-zig, 58k axum, 55k roux,
17k Go, 3.0k basic-webserver; every competitor passed every check.

## 2026-10-06: more of each run kept, the tail on the site

The owner asked for p95, p99 and p99.9 on the site, and for whatever the
race could keep while it is measuring anyway. Each table now has p95,
p99 and p99.9 (medians of the rounds), and so does each bar's tooltip.
`publish` takes every median again from the rounds (`normalize`), so the
site's strict JSON reading never meets a run without the fields: an old
run gets its p99.9 median from rounds that had p99.9, and shows p95,
which it never recorded, as "–".

Kept per round from now on (RACING.md lists them): oha's whole tail
(p90 to p99.99, mean, max), time to first byte (for SSE, when events
start), the per-second spread, connect time, bytes per response; the
server machine's CPU by kind (user, system, irq, softirq), its network
in and out and TCP retransmits; the server's threads and context
switches; the loader's CPU. One shell call per machine before and after
the run, as `/proc/stat` alone was before.

Two first readings were wrong, and caught by looking at them:
- Context switches read 0 for Go: `/proc/PID/status` is the main
  thread's, which in Go sleeps while the workers serve. Now every
  thread's, summed (`/proc/PID/task/*/status`), a test pins it.
- oha's per-second minimum read 66 requests/s for a server doing 18k:
  the run's last second is partial. Not kept; the spread is.
A process gone between snapshots counts nothing rather than a negative
difference (a test).

Not on the site yet: network, first byte, CPU kinds, loader CPU. They
are what would explain the echo-4k ties (the link) and say whether the
loader was ever the limit.

## 2026-10-06: deployed, and a 500 on the way

`site install-server` (run from here at the owner's word) put the new
site up, and the front page and History answered 500: the live data was
published by the previous tool, so `latest.json` had no `median_p95_ms`,
and the site's strict JSON read refuses a missing field. Republishing
the results branch's two cloud runs with the new tool (which fills every
field) and `site deploy` of that data fixed it; every page answers 200.
The nightly's publish uses the new tool from now on. Code that reads a
new field and data that has it must ship together: a Todo.

## 2026-10-06: the site on a phone; DRAG RACE in two words

The owner's phone showed History shifted sideways. Measured at 390 px in
a headless Chromium (a script listing every element whose right edge
passes the viewport), not guessed: each chart's `figure.strip` was 594
px wide. A grid item's minimum width is its content's, so the 560 px
chart widened its figure and the page instead of scrolling in its own
box; `.strip { min-width: 0 }` fixes it. The front page's tables, 603 px
since the p95 and p99.9 columns, were cut off with no way to reach the
right-hand columns; `.table` now scrolls sideways. Every page now
measures exactly the viewport's width; screenshots at 390 px checked.

The name shows as two words, DRAG RACE (logo, page titles); the tool and
the repository keep theirs. The Method page's checks now name `/sse`.

The logo sat lower on the front page than elsewhere on a phone: its
masthead had 84 px above the logo, for the fire, where the other pages
have 48. On phones it now has 48 too, the fire's room below the copper
bars (min-height 300 px): measured, the logo starts 48 px down on every
page at 390 px. Desktop keeps the front page's taller masthead.

## 2026-10-06: a UI pass, phone and desktop

The owner's screenshots, then every page shot at 390 px and 1280 px in
headless Chromium (reduced motion, so bars are not caught mid-launch),
before and after:
- The server-class tabs repeated the heading under them in full and
  stacked three high on a phone: now the class's short name, one row,
  joined; the row scrolls on a narrow screen rather than stacking.
- The class heading is smaller; its machines are a server and a loader
  line instead of one run-on sentence; "raw data" has its own line.
- The race line breaks between items only (date, each commit), with its
  dots at line ends.
- Prose is left-aligned with the results (centred, it began 140 px to
  their right on a desktop) and lists are less indented.
- History: two lines ending close together printed one name over the
  other; labels are spread at least 14 units apart (`spread_labels`, an
  expect). Two races on one day were both "Oct 6": a repeated day shows
  its time. On a phone the chart fits the screen instead of scrolling
  its labels away; the legend names the lines, and the axis uses short
  ticks ("37.5k").
- Competitor cards at least 280 px wide (two to a row on a desktop, not
  three narrow ones); a link never breaks inside its name.
- Workloads explains the load: a closed loop (oha's 256 connections,
  each waiting for its answer), Little's law, what that hides
  (coordinated omission, latency at a set rate, the knee), and the
  open-loop alternative, planned (Todo).
Measured after: every page exactly the viewport's width at 390 px.

## 2026-10-06: each race's time and cost, recorded

The owner asked whether race durations were tracked: only loosely (the
run's start and finish, GitHub's job times: 55 minutes for the first
race, 36 for the three-class one, of which 30.6 racing). Each run now
keeps `timing`: the whole race, the build, the launch (first droplet
requested to the last answering SSH), the racing and each class's, and
every droplet's life from requested to deleted with its estimated cost
at the size's listed hourly price (billed per second, a minute at least),
summed.

On the way, a waste found: the droplets were deleted only after every
class finished, so a class done early kept its pair running for nothing.
Each class now deletes its own pair the moment it is done, however it
went; the fleet's teardown, kept as the safety net, skips what is gone.
Teardown also ran in a `defer`, after the results were saved, so no run
could have held its droplets' lives; it now runs before saving, and the
`defer` does nothing the second time. Tests with a fake API transport
(no network): each class's pair deleted once, the rest and the key once,
however often called; costs (a minute's minimum, a droplet still up
counted until now). Removing the "already deleted" guard fails them.

Droplets were never thrashed: six per race, created once.

## 2026-10-06: a tune-up, adversarially

The owner shared a ChatGPT thread on the race's method and asked for it
read with a grain of salt, the data checked against it, and the blind
spots found. Forced run 37532162780, the first to record the network,
the loader and response sizes, settled most of it.

What the data said (dedicated-2 and smallest, CPU figures corrected, see
below):
- The smallest droplet is CPU-bound everywhere (98-100%): clean.
- dedicated-2 is CPU-bound almost everywhere. Echo 4 KiB's top two (roux,
  axum) sit at ~1.5 Gbit/s each way with retransmits (roux 38,280 in a
  round): the link, not the servers. roux's plaintext (152k/s) had the
  server at 99% and the c-4 loader at 98%: partly the loader's number.
- premium-4 saturated nothing: roux plaintext at 64% server CPU, 52%
  loader, 190 Mbit/s; its 119k/s is 256 connections over ~2 ms round
  trips. Echo stopped near 1 Gbit/s with retransmits where 10 Gbit/s is
  documented; rounds varied 15%. Dropped until dedicated Premium Intel.
- The thread was right that 256 connections can under-drive a server,
  but only on premium-4; on the classes kept, everything saturates.
  It was wrong that the loader need not be bigger: oha needs about twice
  the server's CPU at these rates, and pacing (open loop) half again
  that. dedicated-2's loader is now c-8.

Found on the way, each fixed:
- oha asks for gzip and brotli on every request; the checks (curl) never
  do. basic-webserver honours it. Now --disable-compression.
- The CPU figures read ~23% low: the snapshot window (26 s) held the
  shell calls around the 20 s load. Now ordered tightly and taken over
  oha's own duration; publish mends the rounds already stored, once.
- fourneau-zig died on every droplet: built for the GitHub runner's
  native CPU (AMD Zen 4 that night), it used AVX-512 vpopcnt, which the
  droplets' Skylake Xeons lack. Built for baseline x86-64 now, as Go,
  Rust and roux already are: the native build was also an unfair edge
  on nights it ran. The note had cut the panic's message off: crash
  notes now lead with it and the kernel's invalid-opcode line.
- Workloads ran in one order in every server process; now seeded per
  round. A local race refuses CPU pinning that shares a physical core.

Added: an open-loop ladder (templates; 50-120% of each server's own
median; latency corrected for coordinated omission; open_loop.go), tried
locally: Go's knee is textbook (p99 26 ms at 90%, 284 ms at 100%, 1.2 s
at 120%); fourneau-zig's 90% step was the loader's (88% busy), which is
why each step records it and the chart draws such a step hollow. Packets
a second recorded. Each result now says what limited it (server CPU,
loader, network, or nothing: under-driven), tagged on the bars when it
was not the server's CPU. Each race's duration and cost on the site.

Tuning, measured (three interleaved local rounds each): Go's echo read
its body with io.ReadAll; a pooled buffer of Content-Length is +28% and
half the p99. axum with mimalloc: no gain (88.9k against 92.0k on
templates), not kept.

Blind spots left (Todo): TLS, idle-connection memory, bodies unchecked
under load, churn under-driven for the fastest, echo at the link, SSE
coalescing, host variance, steal always 0.

## 2026-10-06: the same machine every night; tabs that are sizes

The owner pointed out the class tabs and headings repeated each other and
wrapped, and that the droplets were not the same machines night to
night, which spoils long-term comparison. The runs agree: dedicated-2's
c-2 was a Xeon 8280 one night and an 8168 the next two; the smallest
droplet hides its CPU behind "DO-Regular".

Each machine now records its family:model:stepping beside the model
name. A class may ask for a CPU (`server_cpu`); a server on another is
deleted and replaced, up to six droplets (a minute of a c-2 is a tenth of
a cent), and a run that gave up says so on the site. dedicated-2 asks for
the 8168; the smallest waits for its cpu_id to be known. Not tested
against DigitalOcean yet (the matching is; the replacement loop runs
first in the next race).

The tabs are sizes (small, medium; large for the retired premium-4), the
headings say what each class is for ("What a $4 droplet can do"), both
from race.json and given to every stored run by publish. The front
page's opening paragraph is gone: the legend shows who races, and its
names link to the competitors.

## 2026-10-06: how much the rounds agreed; tabs through Datastar

The owner asked for error bars. Three rounds give no useful confidence
interval (two degrees of freedom: the 95% interval would be about four
times the rounds' own spread), so each bar now carries its range: a
whisker from the slowest round to the fastest, the median the bar. Rounds
more than 10% apart are tagged "rounds N% apart": something besides the
server moved. On the smallest droplet (a shared vCPU) several are,
11-16%; the table has a spread column. The tables are one line a row now,
scrolled sideways on a phone, not tall.

The class tabs switch through Datastar (1.0.2, vendored, sha256 in
VERSIONS.md): a click fetches /race-classes (or /history-classes), whose
answer is one datastar-patch-elements event sent through roux's Sse,
and Datastar swaps #race-classes in place; the address is updated with
history.replaceState, and without JavaScript the tabs are plain links.
Checked in a headless browser: scrolled to 500 px, a click on "medium"
swapped the heading and the current tab and changed the address, and
the page stayed at 500 px. The site uses roux's Sse for its own pages now.

## 2026-10-06: race 37546068955, the first with the tune-up

Two classes, 70 minutes, $0.29, every result valid (`timing` in the run).
Learned:

- The smallest class's c-2 loader was 92-98% busy under fourneau-zig: the
  loader, not the server, set that number. It is c-4 now.
- dedicated-2's echo-4k is the network's: 1,320 Mbit/s with ~45k TCP
  retransmits and p99 205 ms, below the 1,400 Mbit/s rule. The site's
  verdict now also calls a result the network's from 1,000 Mbit/s when
  retransmits reach one per 100 requests (an expect holds that case).
- The open loop shows what the closed loop hid: at half their own maximum
  fourneau-zig and roux have p99 of 20 and 15 ms on dedicated-2, where
  axum has 8.5 and Go 4.5 (TODO, for fourneau and roux).
- The same Xeon 8168 gave roux plaintext 152k one night and 119k the
  next: pinning the CPU does not make nights comparable to a few percent.
- 63 of the 70 minutes were racing for ~40 of load: SSH round trips from
  GitHub's US runner to lon1 (TODO).

## 2026-10-06: Ubuntu 26.04; inferno on About

The owner asked for the newest LTS: DigitalOcean lists `ubuntu-26-04-x64`
in every region and GitHub has `ubuntu-26.04` runners (both checked by
API on 2026-10-06), so race droplets and every workflow job moved
together (axum and basic-webserver link glibc: built on the runner, run
on the droplet). `site provision` no longer carries its own copy of the
image: it reads versions.json, and a test holds race.json and
versions.json to one image. A chore now checks every value kept in two
places. The site host itself stays on 24.04 until it is provisioned
again (it runs a static binary). About says again how fourneau is said.
Every page answered 200 on the live runs once republished by this tool
(the two oldest lacked `tcp_retransmits`, which 500s the front page).

## 2026-10-06: squashed again

The owner wants the public history to stay one commit. The 45 commits
after the first squash (2afa9f6 to 0e8df5d) were replayed onto the
archived history (`~/devel/eldhus-history/fourneau-dragrace.bundle`,
which ended at e8845d0), after a commit holding what the first squash
had changed beyond it (2b43318), every tree identical; the bundle now
holds all of it, signed, 56 commits with this entry. `main` is a single
commit again, force-pushed; the `results` branch, its own history, is
untouched.

## 2026-10-06: the forced race on 26.04 refused; certificate; tags

- The forced race (37555348802) died before any droplet existed:
  DigitalOcean answered 422 "invalid key identifiers" for the SSH key it
  had registered seconds before. A probe with a fresh key created 26.04
  and 24.04 droplets at once (both deleted), so it was the key not yet
  known everywhere, not the image. `createDroplet` retries that refusal
  alone, six times five seconds apart.
- `site install-server` without `-acme` put a Let's Encrypt staging
  certificate on the live site (untrusted); reinstalled with production,
  which reused the stored certificate. Production is the default now.
- The owner: the whiskers are fine, the "rounds N% apart" text is noise:
  gone (the table keeps the spread). The owner's phone also showed the
  whiskers off their bars: the bar, a flex item, shrank when value and
  tag did not fit, while the whisker, placed absolutely, did not. The
  bar no longer shrinks; a tag wraps under its value (checked at 412 px).
