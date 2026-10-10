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

## 2026-10-06: outlined bars, the open loop's legend

The owner: the "loader" tags beside the bars squeezed them too. A
result something besides the server's CPU set (loader, network, too few
connections) is now an outlined bar in the competitor's own colour, the
bar chart's equivalent of the open loop's hollow points, with a one-line
key per class; the table says which limit. The open-loop chart hides its
line labels on a phone, so it has a legend (with the hollow point's key),
and its axis says "100ms": at 20px on a phone "100 ms" ran off the left
edge. Checked at 412 px (headless Brave, reduced motion: the bars' launch
animation otherwise leaves them short of their whiskers in a screenshot).

## 2026-10-06: quieter whiskers

The owner: the whiskers looked like blots on the bars' tips. Two 2px
caps a few pixels apart made a solid block where the rounds agreed. Now
1px, at 55% opacity, and none at all when the rounds were within 2% of
the strip's top bar (`whisker_share_min`): the table keeps the spread.

The owner's phone showed the top whisker looking adrift: it was right
(fourneau-zig's rounds 125,005, 126,159, 129,918: from just inside the
bar to past it), but the 4px rounded tip hid where the bar ends. Tips are
2px now, and the longest bar takes 66% of its track, not 72%, so the
fastest round's whisker and a six-digit number fit at 375 px.

The outlined bar's key moved into the competitors' legend as "server not
saturated" (the owner: a line of its own per class, and "set it", read
oddly). The outline now means exactly that, the server's CPU under 90%:
a server at its limit that also met the network (dedicated-2's echo) is
a filled bar, as the label says.

## 2026-10-06: sticky size tabs that keep your place

The owner wanted to flip between sizes without scrolling back up. The
tabs are a sticky band at the top (the page's colour, blurred behind),
and demo.js keeps the workload in view across a switch: on Datastar's
`datastar-fetch` "started" it notes the first chart below the band and
its offset, on "finished" it scrolls that chart back to the same offset.
Tested by driving headless Brave over the DevTools protocol (scratch
script, not committed): scrolled to Templates on small at 390 px, clicked
medium: Templates stayed at 120 px, the address `?class=dedicated-2`;
the same on History, and at 1280 px.

## 2026-10-06: the site keeps the races in SQLite, and takes them by API

WIP 5's first part on this side (docs/self-hosting.md is the design).
The site opens `site.db` (roux, `synchronous` FULL) and reads its two
tokens from `secrets/` at start. `site/db/schema.sql` holds every run as
rows: requests, runs (trigger, status, why), each repository's commit
and whether it was new, race.json's settings, pins, competitors,
workloads and classes per run, machines, droplets, results, every
round's 35 measures, open-loop steps, class status, and the heads the
racer saw. roux-db typed all 38 statements on the first try.

`Api.roc` takes the posts (Bearer tokens compared in constant time; a
worker's token is its run's, good only while the run races). Every post
replaces what it posted before, in one transaction, so a retry through a
deploy changes nothing twice. `Store.roc` rebuilds the pages' `Data.Run`
from the rows, so View.roc and the templates did not change; the raw data
links serve JSON made from the rows.

Two roux needs surfaced and were fixed there: `Sqlite.backup!` (the
racer asks for a copy after each run, `POST /api/backup`) and
`File.read_utf8!` in `init!` (it answered `FileUnreadable` off a shard).

Checked: 109 expects; the site built and run locally; a scratch script
posted the 2026-10-06 run through the API: the refusals (no token, the
racer asking a race, a worker token making a run, a wrong worker token,
a result after the run ended: 409, a CHECK broken: 400 with SQLite's
words, bad JSON: 400), the repeats (a run, a result, a request asked
twice), 32 results, machines, classes, the end, heads, a backup; then
every page and raw data file from the database (200), a missing run 404.

## 2026-10-06: the race page says what the racer will do

Above the newest race, a sentence each (`Store.status`, pure, four
expects): what races now (its classes, results so far), a race asked
for, whether tonight's 03:00 check will race (the heads the racer last
saw against the last finished run's commits: "New commits, roux
def1234: they race tonight") or skip, and the last run that did not
finish, with why. Seen live on the local site.

## 2026-10-06: the guard: the DigitalOcean token and the budget

`dragrace guard` holds the token on the racer and serves a Unix socket
with the few things a race needs (docs/self-hosting.md). It refuses a
size not in the owner's config, a price above the config's for it, any
other region, image, tag or name, more droplets alive than allowed, and
a droplet whose three hours could take the month past the cap (the spend
so far, every alive droplet's remaining hours, the new one's). Its
ledger is each droplet's life by its own clock at the price it allowed,
billed per second with a minute's minimum, written atomically. Every
minute it deletes its droplets past their age and marks the ones
DigitalOcean no longer has. It reads and deletes only its own droplets
(or ones tagged as races), and makes and deletes only race keys. The
fleet now speaks to a `Provider`: DigitalOcean directly (the owner's
`race cloud`) or the guard's client.

Checked: six tests on a fake DigitalOcean, one over a real socket. A
mutation (the budget check off) fails the budget test.

## 2026-10-06: the racer and its workers, end to end on the laptop

`dragrace racer` takes the site's requests (every 30 s), tells the site
the heads (every 10 minutes), and, idle, replaces its own binary with a
newer build's. A request: the heads from GitHub against the last
finished run's commits; a check with nothing new is a `skipped` run;
otherwise the release built from those heads (or `build.yml`
dispatched, waited for up to 45 minutes), unpacked, raced, the run's
results posted again from each worker's file, the run ended with its
timing and droplets, a backup asked for. Through the guard it launches
the fleet as before; on each loader it starts `dragrace worker` with
`systemd-run` (so it outlives the racer's SSH) and waits for it.
`dragrace worker` races its class from the loader and posts each result
after every round and open loop through a queue, so the site being down
never holds the race up; it keeps every result in a file. A racer that
restarts mid-run deletes the race droplets and keys and ends that run
`interrupted`. `SiteClient` retries a post for 20 minutes (1 s doubling
to 30 s), never a 4xx.

Checked: unit tests (the retries, the poster, commits new or not, builds
read from releases). End to end on the laptop with a shrunk race.json
(go and roux, plaintext and templates, a round of 2 s, one open-loop
step; restored after): the site, a race asked with the manual token,
`racer once -local`: the run, 4 results with their rounds and steps,
machines, the end, a backup, the race page showing it. Then again with
the site stopped 20 s mid-race and started again: the race went on, the
posts retried (connection refused, 1 to 16 s), every result arrived,
the run finished. Not checked yet: the cloud path (the guard's socket on
a real racer, a worker on a real loader) and GitHub's side.

## 2026-10-07: builds as releases, the hosts' setup, the old pieces gone

`build.yml` (every push to main, and when the racer dispatches it) builds
everything at the three heads and releases `race.tar.gz` (a checkout as
a race needs it, with this dragrace binary), `site.tar.gz` and
`build.json` (the commits and the files' SHA-256, also the release's
body), keeping the newest 20; `dragrace bundle` packs them (32 MB and
6 MB). `dragrace host-agent`, every minute on the site host, deploys the
newest build's site from `releases/latest/download/` (a CDN download, no
API limit), checks the hash, switches `current`, restarts, and rolls back
a site that does not answer `/api/health` in 30 s, never trying that
build again (a schema change: the migration is the owner's, over SSH).
`site install-server` and `racer install` set the hosts up from the
owner's keyring, secrets on SSH's standard input, the racer's as
systemd credentials encrypted with the machine's key; the guard and the
host agent are pinned copies only the owner replaces. Gone: nightly.yml,
reaper.yml, `publish`, `changed`, `site deploy` and its rrsync user, the
retired class and the relabelling (each run keeps its classes as
raced), committed generated query modules. SECURITY.md is rewritten for
the new pieces: what each secret opens, setup, rotation, migrations,
restoring a copy.

Checked: the host agent's tests (deploy, the same build again does
nothing, a site that does not answer rolled back and marked, the next
build deployed, a tampered tarball refused). Against a local site,
hostile input: traversal in raw data paths (400), results for a run
that does not exist (400, the foreign key), no or a malformed bearer
(401), 2 MB (413), 200,000 nested brackets (400, the site answering
after), bytes not UTF-8 (400); 200 concurrent writes: 187 answered, 13
503 (the writer's queue full: the clients retry), no error. The guard
against real DigitalOcean, from the laptop, with a cap of $2: a size not
allowed and another droplet refused (403); a $4 droplet made, read,
listed, deleted, its life in the ledger (seven seconds). Its clock is
UTC now, as the month's boundary is.

## 2026-10-07: conduit, a RealWorld slice on SQLite, in every competitor

The owner chose RealWorld over a todo list for the read-write workload.
`conduit`: the article list (tags, favorites, authors joined, newest
first, no body as the spec says since 2024-08), one article, a comment
and a favorite (both with `Authorization: Token`: a session row where the
spec has a JWT; no follows). One seed, modelled in `conduit.go`, makes the
database every competitor gets a fresh copy of (sqlite3 shell, WAL, the
WAL folded in) and the answers the race checks each competitor against,
field by field (`validateConduit`); a test holds the database to the
model. Open loop only: a ladder of total rates the same for every server
(250 to 32,000 a second), each step the four parts at once, one oha each
with `--rand-regex-url` (a random article or page per request), stopping
when a server answers under 90% of the rate or errs. A step keeps the
mean over every request (each part's mean weighted by its answers: the
chart) and each part's own rate, mean and percentiles, in the site's
`open_step_parts`. The race page draws it as the open-loop chart is
drawn, the mean on the log axis; the bars and the history leave it out.

The five: Go (modernc's pure-Go SQLite, a reader pool and one writer),
axum (sqlx, the same split), roux (roux-db's statements, `synchronous:
Normal`), basic-webserver (its `Sqlite` pool, BEGIN IMMEDIATE), Zig on
fourneau (roux's vendored amalgamation, a connection per shard). Each
WAL and `synchronous=NORMAL`, as the owner asked.

The contract's checks earned their keep at once:
- roux crashed on two shards: its host shared one row buffer a shard,
  and a statement yielding mid-step let another request's rows into it.
  Fixed in roux (a buffer a connection; roux's DIARY).
- fourneau-zig answered a favorite 500 under load, "database is locked"
  past a 5 s busy timeout: a read statement left on its row kept a
  snapshot, and the connection's BEGIN IMMEDIATE could not write past
  another shard's commit (SQLITE_BUSY_SNAPSHOT, which the busy handler
  does not wait out). Every statement is reset once read now.
- roux's Roc segfaulted the compiler checked through the app; the module
  checked alone named the type error (one-field `{ slug }` is a block):
  the gotcha is in eldhus-skill.

Checked: unit tests (the model against its database, the steps' sums,
the difference finder naming the place, the oha command); each
competitor raced locally on plaintext and conduit; then all five through
the site and the racer (`racer once -local`, a shrunk race.json): every
one valid, the chart on the race page (seen in a headless screenshot);
then CI's `race local -quick` with everything: all valid. On the laptop
(two server CPUs) the ladder topped out around 2,000 to 4,000 a second
(fourneau-zig 4,000, roux, axum and Go 2,000 to 4,000, basic-webserver
1,000, its CPU at 100%): not results, the laptop.

## 2026-10-07: deployed; the first race from the racer; the audit

The owner pushed nothing by hand: with their leave, every repository was
pushed, the old runner's environment, secrets and `results` branch
deleted (the branch kept as a local bundle), the site host set up anew
(`site install-server`: the site from releases, its tokens, the host
agent), DigitalOcean's backups turned on (daily, seven kept: the plan
the API reports, not the weekly one documented), and the racer
provisioned and installed (lon1; the guard's cap $25). Setup found
`putFiles` losing one of two files named `config.json`; fixed.

The first race, asked with `site race-now`, stalled: having dispatched
a build, the racer waited for a release "created" after the dispatch,
and a release's `created_at` is its commit's date (published_at is when
it was made): the build of its own heads was never taken. Fixed: the
build of exactly the heads at every poll, else the newest published
since asking, and no dispatch while a build already runs. The stuck
racer was stopped before it recorded anything, the fixed binary
installed from its release, and the race ran: 52 minutes, $0.29 (the
guard's ledger agrees), 60 results all valid. Five minutes went to
dedicated-2's CPU: six c-2s, 8358s and 8280s, never the 8168 it asks
for. Mid-race a push deployed a new site (serving again in a second)
and the site host rebooted for its kernel (22 s): nothing lost, though
no post fell in either gap, so the retries ran only on the laptop.

The audit read each repository against the running hosts and wrote
the system up for the owner (the doc "The fourneau drag race: how it
works, end to end"). Fixed besides: the status line's promises (a
build's wait; no "tonight" while racing), heads posted when a request is
taken, a stopped racer recording a failed run, the raw-data link's
words, About and RACING, SECURITY on the credential key and on reading
the live database (roux locks it: read a copy), TODO's stale items,
roux's TODO and the skill's map. The hosts: root's login refused,
reboots for updates at 05:30 UTC (site) and 15:30 UTC (racer), a swap
file, update-notifier off; both rebooted onto new kernels and came back
by themselves. The racer's second boot ran DigitalOcean's per-instance
script that its starved first boot had skipped, replacing the machine
id: that boot's journal is in the old id's directory (a one-off). The
builds cache their dependencies now (7.5 of 8 minutes were compiling).
Open, in TODO: the site host on 24.04, the site's unreproducible build,
conduit's history and axis, the CPU pin, docs-only commits racing.

## 2026-10-07: reboots on New York's clock

The owner wants the hosts' reboots before the race, at 02:30, kept there
through daylight saving. unattended-upgrades' Automatic-Reboot-Time is
the host's clock (UTC), so 05:30 UTC was 01:30 New York in winter and
the reboot's hour moved against the race twice a year. Now a timer
(`dragrace-reboot.timer`, `OnCalendar=*-*-* 02:30:00 America/New_York`)
reboots only when `/run/reboot-required` exists, and on the racer only
when no run is racing (its `racing` mark; a restart ends a run). The
updates move to 01:30 New York with no random delay (Ubuntu's default,
06:00 UTC plus up to an hour, could install after the reboot's look).

## 2026-10-07: no CPU pin

The owner would rather a night's machines match than every night's. A
night's comparison already is on one CPU: every competitor of a class
races on the one server droplet, in interleaved rounds. And the classes
cannot match each other: the first race's shared droplets (s-1vcpu,
s-8vcpu) reported 6:79:1, an older generation than any dedicated one
(8280 6:85:7, 8358 6:106:6). So the pin, which cost five minutes and six
c-2s for an 8168 lon1 never gave, is gone: `server_cpu`, the replacing
loop, and the machines' `cpu_wanted`, `cpu_matched` and `attempts`
columns. Every machine still records its model and family:model:stepping.

The schema change is a migration (roux checks the schema's text exactly,
so no `DROP COLUMN`): a new database made from the new schema.sql, every
table copied from the old one attached (`INSERT INTO t SELECT * FROM
old.t`; run_classes and machines by their remaining columns). Tried on
the newest copy: every count the same, integrity and foreign keys ok,
the new site serving every page from it.

The first racer's race also closes "a race took 63 minutes of racing":
with the workers on the loaders, 45 minutes of racing for about 40 of
load.

## 2026-10-07: the site host in lon1, on 26.04

The site host was in nyc3 only because `site provision` said so, from
when GitHub's US runner raced; it now takes race.json's region, beside
the racer and the workers that post to it. A new droplet (606940468,
104.248.175.105, Ubuntu 26.04.1, kernel 7.0) replaced the 24.04 one: a
fresh copy from the old site (`POST /api/backup`), migrated to the
schema without the pin's columns (same counts, integrity ok), put in
place as `site.db` before `install-server`, which deployed the newest
build onto it: every page 200, the certificate for the new address
(Let's Encrypt, six days), the redirect, the reboot timer at 06:30 UTC
(02:30 New York, daylight time). Then `racer install -site` the new
address, and the racer posted its heads there within a minute.

Found on the way: the racer had been down since 12:32 (`Failed to
determine local credential key`, a restart every 10 s). At 12:11 its
reboot had come up fine, decrypting under the old machine id; at 12:11:52
DigitalOcean's per-instance script set a new one (it had been skipped by
the first, starved boot); the self-update's restart at 12:32 then could
not use the key made under the old id. `racer install` made a new key
and re-encrypted; a reboot proved it (guard and racer up, the socket
there). Installs now wait for the first boot's cloud-init. journald had
kept writing under the old id's directory; restarted, it follows the new.

The old host still runs, stale, until the owner agrees to delete it
(its DigitalOcean backups go with it).

The owner agreed: the old site host (606524979, nyc3, 174.138.75.219)
is deleted, its one DigitalOcean backup with it, its key out of
`site-known-hosts`. `site backups` turned on the new host's: daily, seven
kept, the first window 2026-10-08 16:00-20:00 UTC.

A droplet keeps its public IPv4 for its whole life (reboots, power
off, resizes); a new droplet gets a new one, as this move did. With a
domain name, a move is the A record changed; a DigitalOcean reserved IP
(free while assigned) would also survive one, but the name makes it
unneeded.

## 2026-10-07: the site's name

The owner made fourneau.y2kbugger.com at IONOS. Its "create subdomain"
filled in IONOS's web hosting (A and AAAA to their server) and mail; the
AAAA had to go (the site listens on IPv4 only, and Let's Encrypt tries
IPv6 first), as did www. Then `install-server -host` the name: the
redirect went to the name at once, but the certificate stayed the
address's, since fourneau's ACME reused any fresh certificate from the
same CA. Fixed in fourneau (ebdffc5): the state keeps what a
certificate is for. This push builds the site with it.

The build with fourneau ebdffc5 deployed at 17:27:59, ordered a
certificate for the name (four seconds) and passed the host agent's
health check by name. Every page answers at https://fourneau.y2kbugger.com/;
port 80 redirects there; the address alone no longer verifies (the
certificate names only the name). `racer install -site` the name: the
racer posts its heads there.

## 2026-10-07: HSTS and kTLS, fixed in fourneau

The site now sends `Strict-Transport-Security` on every HTTPS response
(fourneau 2b5008c: the server writes it, as it writes `Date`), and a
client that hangs up right after the handshake is `PeerClosed`, no
longer a warning that blames the tls module; whether the kernel has kTLS
is checked once at startup. This push builds the site with both.

## 2026-10-07: tabs by size, smallest first; memory; the front page's bar

The owner: the tabs read "medium small" (the database returns results
sorted by class name, and the tabs followed the results), "small" and
"medium" say nothing, and the machines' lines should say their memory.
The tabs follow race.json's order now and are named by size
(`512MB/1vCPU`, `4GB/2vCPU`). Each machine records MemTotal
(`memory_mib`, from /proc/meminfo: the kernel's figure, a little under
the nominal size), shown as "458 MiB" or "3.8 GiB"; a run from before
shows none. That is a schema change: `docs/migrations/2026-10-07-machine-memory.sql`
(a new database from the new schema, every row copied, older runs'
labels renamed), tested on a database in the old schema seeded with the
two 2026-10-06 cloud runs: every count equal, integrity and foreign keys
ok, every page 200 from the new site. The front page's copper bar closed
the menu, across the top of the fire; it closes the header under the
fire now, as on every other page.

Checked on localhost (a scratch site.db seeded from the 2026-10-06 runs,
memory placeholders): 112 expects; tabs, memory and the bar at 390 and
1280 px.

## 2026-10-07: one masthead on every page

The owner: the front page's bar, pinned under the fire, sat lower than on
every other page; the bar belongs in one place, the fire raised. The
front page's masthead overrides are gone (its taller padding and
min-height, the bar's absolute position, the mobile override and the
body's `home` class that carried them): the masthead is the same
everywhere, the bar right under the menu, and the fire burns up from the
bar behind the menu and the logo (70% of the masthead's height, was 40%
of a taller one). On a phone a page's title sat 64 px under the bar
(main's 24 and the h1's 40); the first h1 keeps 8.

Built and served on localhost: the front page has the fire, History none,
neither a body class. Not looked at in a browser: the owner checks it.

To look at it with real data, the live database was copied down. `sqlite3
.backup` on the host fails ("database is locked": roux holds SQLite's
exclusive lock), so the copy is `site.db` and `site.db-wal` copied
together while the site was idle (`sudo cp` both, then tar over SSH, the
host key from `out/secrets/site-known-hosts`). The copy is fine: integrity ok, 1 run, 60
results. Then `docs/migrations/2026-10-07-machine-memory.sql` ran on it as
its header says: integrity and foreign keys ok, counts the same, and the
new build serves `/`, `/history` and `/competitors` from it. That is the
migration tested on the live data before it runs on the host.

## 2026-10-07: the charts' names beside their own lines

The owner, on the open-loop chart: the names are misaligned. axum's sat
two rows under its line's end, pushed by basic-webserver's name, which
ends far to the left: the spreading looked only at height, right for the
history charts (every line ends on the last race) but not where lines end
at different rates. One `label_ys` now places both charts' names (two
copies before): each beside its end, pushed down only past a name it
overlaps across as well as down (its width from its length, 11 px Space
Mono at 0.6 em). The names are 11 px, from 12.

Checked: 112 expects (the new one: a name pushed under one above, one
beside it not); on the live data's race, axum's name is at its own end.
Not looked at in a browser.

## 2026-10-07: `site dev`, the site rebuilt as it is edited

The owner: the build is far too slow to iterate on the UI. Measured, step
by step (`--timings`): roux's zig steps 0.1 s, roux-db 11 ms,
rocstache-gen 3 ms per template, `roc test` 1 s, and `roc build` 83 to
94 s every time, unchanged or not: LIR passes 31 s, LLVM 49 s, nothing
cached. `--opt=dev` (Roc's x64 backend) builds in 1.8 to 2.9 s, 1.5 to
1.7 s of it Roc's shared lowering of the whole program; `--opt=interpreter`
3 s, its pages 0.2 to 0.9 s each. The dev binary serves `/` and
`/history` byte for byte as the optimized one, in 7 to 14 ms.
`--specialize=no` (boxy lowering) crashes the compiler: SIGSEGV.

`dragrace site dev` (`site_dev.go`; the legacy rocstache's `dev` was a
watcher thread inside the app, regenerating while `roc` ran): one inotify
watcher on site/, site/db and site/static and one serial pass, so a build
never races a generator. A pass hashes every input (sha256, at most 512
files of 4 MiB); a changed template is regenerated, a changed query
regenerates the db modules, and only when the Roc sources' digest then
differs from the last good build does it build (`--opt=dev`, to a new
file moved over the old) and restart the app (SIGTERM, then wait until it
answers). Content, not mtimes or event kinds, decides: a save that
changes nothing, and the generators' own writes, cost nothing; a static
file only reloads. The browser talks to a proxy that injects a script
into HTML pages (event streams pass untouched; pages asked for
uncompressed): `/_dev/events` sends the build's generation on connect, so
a page that missed a reload or loaded under a failed build learns it;
a failure shows its output over the page while the old app keeps serving;
requests wait (up to 30 s) while the app restarts. `roc test` runs after
each build beside it; failures are a banner.

Measured with an event listener: a template save to the reload event
3.0 s (built 2.9 s, up 69 ms); later saves 2.4 s; a CSS save 10 ms. A
broken template: the type error in the browser, the old site still 200.
Go tests for the pure parts (change detection, the digest ignoring
static files and templates, which files count, the injection and what it
leaves alone). Under a second is not reached: TODO says what would.

## 2026-10-07: the open-loop charts switch between latencies

The owner: switch the open-loop lines between p50, p99, p99.9, whatever
there is; p99 first. Every step already keeps p50, p90, p99, p99.9 and the
mean (open_steps); the site read only p99, p99.9 and the mean, and now
reads all five. A chart offers the measures its steps have: the ladder
p50, p90, p99, p99.9; Conduit (no p90; its percentiles are the slowest
part's, its caption says so) p50, p99, p99.9 and the mean, which it drew
alone until now. Each measure is drawn on its own log axis, all on the
page, and radio buttons with CSS `:has()` hide the others: no request, no
script, and it works through the class tabs' fragments. A point's tooltip
gives every measure.

Checked: 113 expects (the new one: which measures each kind offers, p99
shown); on the live data's race the controls read p50 p90 p99 p99.9 and p50
p99 p99.9 mean, p99 checked, 8 charts on the page. Built and reloaded by
`site dev` (3.4 s; the CSS 7 ms). Not looked at in a browser.

The owner looked: every measure showed at once, its caption four times.
The new CSS had never been served: roux reads static files once, at
startup (fourneau's site.zig keeps them in memory, gzipped), so `site
dev`'s "a static file only reloads" served the old style.css; a static
change now restarts the app, without a build (about 60 ms). The caption
is one per chart, the measure only on the axis. The control is
phosphor-green radio buttons (the owner's ask): a ring that lights up
with a glowing dot.

Then the owner, having seen them: the latencies' charts all look alike,
p99 alone is enough. The switch is gone (the radios, their CSS, p50 and
p90 read from the database); every open-loop chart is p99, Conduit's too
(its slowest part's; it drew the mean before the switch). The captions
stay one short line with a link to Workloads, whose Conduit line now says
p99. Against before the switch: the Metric type gone, one open_chart.
112 expects; two charts on the page, no radios.

## 2026-10-07: `site dev` stuck on "connection refused"

The owner: the page sometimes ends on the proxy's "dial tcp
127.0.0.1:8091: connection refused" and stays. Reproduced with a loop of
requests across restarts: 2 of 401 refused, and both *after* the app was
"up". roux listens once per shard (8) on one port with SO_REUSEPORT; the
readiness check took one accepted connection as ready, and the kernel can
hand the next to a shard not yet listening, which refuses it. A reload in
that gap got the error page, which subscribes for events after the reload
event has gone, so nothing moved it on.

Now: ready is 32 connections accepted in a row; a refused request waits
for the gate and is sent again, up to 8 times at 25 ms more each (a body
only if it can be replayed); an app that dies on its own shows its output
over the page. Measured the same way: 779 of 779 answered 200 across four
restarts. Go tests: a refusal retried, a dead app given up on, an
unreplayable body not resent.

## 2026-10-07: the memory migration, live

Pushed (the owner asked: 21 commits, 4affaa2..5daf2d8), then on the site
host as cook, with the racer idle: schema.sql and the migration copied up
(sha256 equal to the checkout's), the agent's timer and the site stopped,
the old database's WAL checkpointed first (the header's steps delete
`site.db-wal` after moving `site.db`, which would have cut its last writes
from the copy kept), then the header's steps, the old database kept as
`site-pre-memory.db` (a `site-old.db` from the earlier migration was
there). The new one: integrity ok, foreign keys ok, every count equal
(runs 1, results 60, rounds 150, machines 4, open_steps 92, requests 1).

The agent then started nothing: `current` was already a build with
`memory_mib` (it had been made current at 18:19), and the agent deploys
only a newer build. The site was down 20:37 to 20:39 UTC, until started
by hand; then `/`, `/history`, `/competitors`, `/workloads` 200 and the
HSTS header there. SECURITY.md now says both (start the site when current
is already the new build; checkpoint before deleting a WAL).

## 2026-10-07: no figure typed into the pages

The audit's findings (figures typed into the pages that race.json or the
racer decide), done as the owner said: from the data where a query gives
it, else worded away; less fragile is better. The Workloads page is now
read from the newest finished run: a card per workload (its title, route,
race.json summary), the line under it from `run_workloads` (connections,
kept alive or not, body size), a mixed workload's parts and rates from the
run's own `race_json` through SQLite's `json_each` (two typed queries,
`workload_specs` and `race_settings`), the warmup, measure and rounds and
the ladder's workload and steps from `run_settings`, the loader's limit
from View's `loader_limit_pct`. Before the first race it says so. The
hand-written card prose (each stack's engine, the reference links, the
seed's size) gave way to the summaries; the check against a reference is
one line in the intro, linking Method. Worded away: "03:00 New York time"
(the banner says "Racing tonight"; the hour is the racer's timer, which
the site does not hold), the front page's list of five workloads and
"three rounds", Method's 5 s, 20 s and three rounds (it links Workloads).
The worked examples (Little's law) stay prose.

Checked: the queries on the live data's copy (Conduit: list 50%, article
30%, comment 15%, favorite 5%; 250 to 32,000; ladder Templates at 50% to
120%); 113 expects (the new one: a card's route without the query, its
line closed and mixed); the page read through `site dev`; a search of
site/ for the old figures finds none.

## 2026-10-07: dedicated-2's loader back to c-4

The owner asked why dedicated-2's fast servers stop short of their CPU.
Read from the race of 2026-10-07 (every round, step and part; the local
copy of the live database):
- dedicated-2's closed loop is under-driven. roux plaintext's rounds 115k,
  88k, 98k with the server at 73, 56, 64% and nothing retransmitted;
  fourneau-zig at 47-60% on every workload. The ladder proves headroom:
  templates at 120% gave fourneau-zig 89k (closed loop 75k, server 70%)
  and roux 90.5k (closed loop 83k). The smallest class, server at 93-100%
  everywhere with a c-4 loader, beat it (fourneau-zig plaintext 110k
  against 84k). The loader was s-8vcpu-16gb, shared: its busy 34-46%
  leaves out steal, which no one records for the loader.
- fourneau-zig's 50% on two vCPUs looked like one shard doing all the
  work; the ladder's 70% at 89k says not.
- Echo is the network on both classes (0.9-1.3 Gbit/s each way, up to
  39k retransmits a round), which the site's rule misses (TODO).
- roux refuses requests under Conduit's load where no other server does
  (TODO).
- Elsewhere clean: success 1.0 and no errors everywhere; Go and
  basic-webserver CPU-bound in every row.

The fix wanted was a dedicated c-8 loader, as on 2026-10-05; `dragrace
sizes` shows this account none above 4 vCPUs in any region, which is
why s-8vcpu was chosen on 2026-10-06 after c-4 hit 98% at 152k. c-4 again
for dedicated-2: honest about its busy time, half busy at ~110k on the
smallest class; past ~150k it is the limit and says so. One change for
tonight's race; TODO says how to read it.

## 2026-10-07: roux's competitor on templates compiled by Zig (branch)

On the branch `templates`, against roux's branch of the same name (its
DIARY): roux's templates are compiled to machine code by Zig, the Roc
side only a contract. The competitor follows: `Menu.rocstache` declares
its contract (`Ctx : { dishes : List({ name : Str, price : U32 }) }`,
the prices being numbers), the context holds it as `menu : Menu.Ctx`,
`/menu` answers `Menu.render!(context.menu)`, and the build is one step,
`roux build --roc={roc} --output={out}/roux main.roc`, in place of
rocstache-gen and `roc build`. `Menu.roc`, now only the contract, is
committed: it changes only when the template's type does.

Checked locally (a workspace of worktrees, `~/devel/eldhus-templates`):
`/menu` is `workloads/menu.html` byte for byte; `/plaintext` answers.
Against roux main's build, five interleaved rounds, two server cores,
64 connections: 109k against 165k requests/s, 39,030 against 14,807
instructions a request, p99 1.03 against 0.62 ms (roux's DIARY has the
table). Not raced on the droplets yet: the branch is not merged.

## 2026-10-07: the site on templates compiled by Zig, and `site dev` on `roux dev` (branch)

The site follows the competitor onto roux's `templates` branch:
- `render` is `render!` everywhere (the host renders), and `not_found`
  became `not_found!`.
- A template's contract is exactly what it reads, and the view's records
  carried more: a class's tab `label`, and the chart lines' `end_x` and
  `end_y` (where a line ends, to spread the labels apart). The lines are
  now `View.DraftLine` and `View.DraftOpenLine` until their labels are
  placed, then `View.Line` and `View.OpenLine` as the templates read
  them; the one class shown is mapped to its contract in main.roc
  (`race_class`, `history_class`).
- Each template's contract (`Page.roc`) is generated and committed now
  (it changes only when the template's type does); `.roux/` and the dev
  binary are ignored.
- `site build` is `roux build --roc=... --output=...` (which also runs
  roux-db and writes the contracts) then `roc test`. `site dev` runs
  `roux dev --port=8090 --static=static` (the Go watcher and proxy, 867
  lines and their test, gone: roux's host now serves the reload stream
  and adds the script itself); stopped, it sends roux dev a TERM, so
  roux dev stops the app first.

Checked: main's site build (`out/dev/dragrace-site`) and the branch's,
each on a copy of site.db: 17 pages and data files byte for byte (every
page, the Datastar fragments for three classes, both JSON files). `roc
test`: 94 pass (113 on main: the 19 others were roux's old
Rocstache.roc's, gone with it; the site's 64 `expect` lines are the
same). `go vet`, `go test` pass.

`roux dev` on a copy of the site, save to new page: a page's markup
266-298 ms, the `Top` partial (in nine pages) 927-948 ms, `main.roc`
1.28-1.33 s, a static file 78-82 ms; `site dev` before: 3.0 s for any
template. Not yet in roux dev, which the Go version had: a failed build
over the page, requests held during a restart, `roc test` after each
build (roux TODO).

## 2026-10-08: the site host's reboot ended in a kernel panic; stock updates

In the morning the site was down: no ping, no port (22, 80, 443) on
104.248.175.105; the racer (144.126.227.9, same region) answered. The
panel's graphs: the update run at ~01:40 New York, the 02:30 reboot timer's
reboot, then 100% user CPU, no disk, no network from ~02:35 on. The
Recovery Console showed why: `Kernel panic - not syncing: No working init
found` on the new kernel (#38-Ubuntu): it mounted the disk and found no
working `/sbin/init`. No race ran. Not known why: the broken disk was
replaced by the restore before anyone read it. Searched: no report of
Ubuntu 26.04 or DigitalOcean doing this now; the error's usual causes
are a broken initramfs or systemd on the disk. The homemade timer did
not hold the reboot for apt, though the disk graph says the update was
done by 01:45.

The owner asked for what DigitalOcean and Canonical advise rather than
the homemade timer: Ubuntu's stock unattended-upgrades (security only,
its daily run 06:00 UTC plus up to an hour) with its own
`Automatic-Reboot "true"`, which reboots at the end of the run, never
mid-install, and monitoring, since apt reports nothing when it breaks.
That reboot window, to 07:30 UTC, held the 03:00 New York race in
summer, so the check moved to 05:00 (owner). `hostFiles` is now sshd's
file and the reboot setting; an install deletes the old timer's files.
The site's reboot mid-race costs nothing (posts retry 20 minutes); the
racer's ends the run, so no manual race between 02:00 and 03:30 New York.

`dragrace site restore` lists the site host's backups (one: 2026-10-07
17:29 UTC, before the memory migration); restoring was refused, 403
`droplet:admin`, which the project's token leaves out on purpose, so the
owner restores in the panel. Left (TODO): the installs on both hosts,
the migration again, an uptime check, Livepatch.

The restored backup did not boot either: twice the same `No working init
found`, and once `System is deadlocked on memory` at 1.1 s. I blamed 512
MB and moved both hosts to 1 GB; the owner refused, and a throwaway 512 MB
droplet of the same image, upgraded to the same kernel (7.0.0-38) and
initramfs (40 MB), booted 4 of 4: not memory alone. Both hosts stay 512
MB (reverted). What differed on the site host is not known: its disk is
gone. It had never booted 7.0.0-38 (installed by cloud-init's first-boot
dist-upgrade, which runs under eatmydata, no fsync; the racer had booted
it once). The kernel has virtio and ext4 built in, so the hosts now boot
without an initramfs (`GRUB_FORCE_PARTUUID`, Ubuntu's cloud images' own
setting, which DigitalOcean's image leaves out; the initramfs is the
fallback): the test droplet 3 of 3, then the site host 2 of 2 and the
racer once. Runtime memory is the same; only the boot's spike goes.

From scratch: the owner rebuilt the droplet from the base image in the
panel (same id, address, user data), I ran `install-server`. A clean
build found what a host kept since 2026-10-06 hid:
- cloud-init's first-boot dist-upgrade outlives `cloud-init status
  --wait`, so the install's apt failed on its lock (exit 100). It waits
  for the lock now.
- that package step failed, cloud-init's final stage stopped, and the
  firewall, which only its runcmd set up, was off; `status` said done.
  The install sets ufw up and checks it now (site 22, 80, 443; racer 22).
- the racer's nightly check fails at once: its unit has only the racer
  token and `racer check` loaded the GitHub token too. The timer path
  had never run (the first race was by hand); `check` loads the racer
  token alone now. The racer gets it from the next release.
The database came back from `site/site.db`, the local copy `site dev`
serves: integrity ok, the counts the migration recorded (runs 1,
results 60, rounds 150, machines 4, open steps 92, requests 1), already
the new schema; installed as `site.db` (the empty one kept beside it),
the same sha256 both ends. Every page 200, HTTP to HTTPS, HSTS, a new
certificate. Then the racer's `racer install`: settings, firewall and
boot the same; its catch-up of today's missed 05:00 check (Persistent)
found the bug above.

What is on each host, and whether it matches the code (the owner asked):
nothing recorded what an install applied, so nothing could say a host
had drifted. Each install now stamps its commit on the box, and `dragrace
hosts check` renders what the checkout says each host should be and
compares it (docs/self-hosting.md, "What is on each host"); `dragrace
version` prints a binary's build commit. Its first run found the racer
on the owner's hand-built binary, the guard's twin: `racer.update`
skipped any binary without a build commit, so the racer had not updated
itself since it was installed and said nothing. It now replaces such a
binary with the newest release, and the install always starts it on the
installer's.

## 2026-10-08: ad-hoc races, two builds compared in 50 s

The owner wanted work in progress (roux's `templates` and `templates-vm`
branches) compared by the clock on real machines, fast enough to ask
often: "compare two implementations in less than a minute". `dragrace
adhoc race` (tools/cmd/dragrace/adhoc.go, docs/adhoc.md). The nightly
path cannot: GitHub builds (up to 40 min), fresh droplets every run. So
the ad-hoc path differs in three places, each measured:

- **Builds on the laptop, at any commits**, each variant in its own
  checkout (`git clone --shared`, then checkout in place). First I
  exported with `git archive` into a fresh directory each build: 121 s
  every time, identical sources included, because Zig's cache knows a
  file by path and inode (`zig build platform` 77 s, `tools` 40 s; the
  same build again in one tree: 33 ms). In place: a rebuild at the same
  content 3.8-4.0 s. Cached by a hash of every file but Markdown (a
  TODO commit on roux had cost a rebuild). Stripped and zstd'd: 17 MB is
  1.6 MB; the builds are reproducible (the same bytes twice).
- **A warm session**: server and loader kept between races (64 s to make;
  a user systemd timer deletes them after 20 minutes unused; their own
  tag, so the racer and guard never see them; `reap` sweeps it).
- **One ssh connection** (ControlMaster): lon1 is 90-140 ms from the
  laptop, a handshake several round trips, a measure about ten calls.

The whole command, roux's two branches on `templates` (dedicated-2:
server c-2, Xeon 8358; loader c-4): from nothing 298 s (builds 123 + 118
s, droplets 64 s alongside, uploads 2 s, race 50 s); a rebuild at the
same content 64 s; warm **50 s**. Output: JSON events on stdout (resolved,
built, session, uploaded, round, result), the table on stderr.

Two rounds of the first eighteen ran with the server at 76% and 83% CPU,
the loader dipping with them, no retransmits: something outside both.
Such a round measures that, not the server: the variant is raced again
(twice at most) and the saturated rounds kept; it fired once in each of
the next two races.

The answer, five races: the VM 3.6-5.2% behind comptime (139k against
144-147k requests a second; rounds of a variant within 2-3% of each
other). On the laptop it had read 5% (157k against 165k); instructions
14% more.

Then made simple (owner: "I'd like simple adhoc story"): two commands,
`adhoc race` and `adhoc down`, two flags, `-workloads` (default all
five closed-loop ones) and `-rounds`; `up`, `status`, the class, region,
idle and timing flags gone, the race printing its machines instead. The
open questions decided (docs/adhoc.md): builds stay on the laptop, no
reuse of release binaries, closed loop only. The idle reaper tested end
to end: with the idle limit at 0 its user unit ran a minute later, read
the token from the keyring, and deleted both droplets and the session.
The final version raced once on new machines (119 s, builds cached, 64 s
of it booting; the VM 5.0% behind, the sixth race to say so), then `adhoc
down`: nothing left running.

## 2026-10-09: the race page a third cheaper (log10)

Found profiling roux's templates (roux, DIARY 2026-10-09): the race page
`/` cost 16.7 M instructions a request (`perf stat -e instructions:u`,
release, a scratch copy of the site on roux templates-vm), a third of
them in Roc's `F64.pow` (`float_math.f64.finitePowerMagnitude`), called
by View.roc's `log10`: Roc's F64 has no logarithm, and the p99 chart
took three by bisection on `F64.pow` per point, 40 calls each. `log10`
now counts the decades and takes ln of the rest by its atanh series
(16 terms, error below 1e-10; a test to 1e-10 at 7 and 123,456). The
race page 11.3 M instructions a request (-33%, two A/B rounds), its
bytes and every other page's the same; all 114 tests pass at the pinned
nightly. What is left on `/`: string concatenation 14%, allocation 14%
(the chart's SVG built by interpolation), SQLite 5%.

## 2026-10-09: adhoc's open-loop ladder (`-open`); roux's page variants raced

The owner: a side by side of roux's current templates, the closure
(pure-render) and the union (page-union) "on the open and closed loop
template tests", and "adding the open-loop ladder to adhoc ... do this
work". adhoc kept race.json's open loop off; now `-open` climbs it after
the rounds (open_loop.go's `climb`, unchanged) for every variant on each
workload, at the same offered rates: shares of the first variant's
closed-loop median, since the nightly's own-share ladder loads each
variant differently. A second table and `open_step` events; a test of
the table's order. Branches here for the race: `pure-render` and
`page-union`, the roux competitor as each roux branch builds it (its
`/menu` checked against menu.html locally).

Closed loop, dedicated-2 (lon1), 5 rounds: templates-vm 128,086,
pure-render 125,205 (-2.2%), page-union 128,737 (+0.5%), every range
overlapping. Again with `-open`, 3 rounds: 125,332, 125,764 (+0.3%),
127,181 (+1.5%), overlapping. The ladder, one climb each (p99 ms at 50,
75, 90, 100, 120% of 125,332/s): templates-vm 15.3, 16.3, 46.1, 38.1,
72.8; pure-render 7.6, 20.6, 60.6, 103.9, 232.6; page-union 5.4, 17.7,
39.5, 28.2, 75.4. Every variant answered at most ~98-100 k good/s at
90% and above, with server CPU ~90%, not the closed loop's 100%: the
open-loop knee is below the closed median here, so from 90% up the
queue grows and p99 measures the queue. One climb each is one sample a
rate: the 50% step's 15 ms against 5-8 ms says how noisy one is.

## 2026-10-09: roux's templates as data, the competitor and the site

roux merged its templates work into main (templates as bytecode, one VM
in the host; then templates as data, the generated `Templates` union:
roux's DIARY, 2026-10-09). This branch takes it, with main merged in
(the log10 fix, adhoc's `-open`):

- The competitor: `Rocstache.html(Menu.template(context.menu))`; no
  `Page` in the app's header, no `Pages.roc`; `Server.Response(_)`.
  `/menu` is workloads/menu.html byte for byte (md5 61f660a7…); the SSE
  and Conduit routes answer.
- The site, from its comptime-Zig port (the templates-vm port was only
  ever a scratch copy): every `X.render!` is `X.template`, sent with
  `Rocstache.html`; `/method`, `/contribute`, `/about` and the 404 are
  top-level constants now (a page that reads nothing is data, made at
  compile time); the Datastar patches take the template's value
  (`Rocstache.patch!`, the site's own framing gone with its expect);
  bodies `Text`/`Bytes`. `site build`: 35.5 s roc, 94 tests pass.
- Checked against the site as `site dev` built it this morning (old
  roux, same database copied): 22 routes, every page, both tab patches,
  the JSON files, a 404, a 400, a 301, the API's health: status,
  headers (but the date) and bodies byte for byte.
- Then roux's `Rocstache.patch!` stopped sending an empty `data:
  elements ` line for a template's final line break (roux DIARY): the
  two tab patches now differ from the old build by that line alone, the
  other 18 routes byte for byte still. `go test ./...` passes; the full
  `dragrace build` (every competitor, as tonight's race) below.

## 2026-10-09: roux links with roc alone; templates in templates/

roux now has roc link the executable and attaches the templates'
program after it (no Zig to build an app), and an app's templates live
in `templates/` beside its `.roc`, imported as `templates/X` (roux
DIARY). The site's twelve templates and the competitor's Menu moved
there (`git mv`, imports `templates/IndexPage`, …). Checked after each
change: the full `dragrace build`, `site build` (96 tests), the site's
22 routes identical (bodies and headers) to the build before, the
competitor's `/menu` workloads/menu.html byte for byte.

## 2026-10-10: HTTP/2, a workload (branch `http2`, not main)

fourneau speaks HTTP/2 now (its DIARY, 2026-10-10). A workload,
`plaintext-h2`: GET /plaintext over h2c, 32 connections of 8 streams,
the 256 requests in flight of Plaintext's 256 connections. The racer
sends it with oha `--http2 -p` (`http2`, `streams` in race.json) and,
when a race has one, checks every competitor answers over h2c first
(RACING.md). Each competitor speaks it as its stack offers: Go's
net/http `Protocols` (SetUnencryptedHTTP2), axum's `http2` feature
(the lock gains h2 0.4.16, fnv, tokio-util; built offline from the
cache), fourneau-zig's and roux's `Config.http2` (roux on its own branch
`http2`), basic-webserver as it was (hyper's server speaks h2c).

On a branch because main may be pushed for tonight's race, which should
run as it is: this changes what each competitor serves.

The local race (`race local -quick`, server CPUs 0-1, the desktop busy:
a smoke test, not a result), requests/s, HTTP/1.1 plaintext then h2c:
fourneau-zig 271k, 303k; roux 235k, 254k; axum 100k, 84k;
basic-webserver 35k, 44k; Go 49k, 27k. Go's h2c is half its HTTP/1.1 in
every shape tried by hand too (32x1, 32x8, 256x1): its own.

The first local race crashed roux (fourneau's stream scratch was not
aligned: fixed there, `111d996`). A smoke test that finds a crash is
worth its minute.

Then the whole race, `race local -quick`, every workload: every
competitor finished every one (no DNF; HTTP/1.1's unchanged by
speaking HTTP/2 too). plaintext-h2, requests/s: fourneau-zig 323k, roux
285k, axum 120k, basic-webserver 43k, Go 35k. `site build`: its 96
tests pass with the new workload in race.json.

## 2026-10-10: the site restarts without refusing anyone (branch `after-race`)

fourneau's graceful restart (M10) is systemd's socket activation
(fourneau DIARY, listen.zig): the site's units now hold its ports,
`dragrace-site-https.socket` (443, named `https`) and
`dragrace-site-http.socket` (80, `http`, which ACME's http-01 responder
uses too: it no longer binds 80 itself, which would fail under the
socket). The service takes them (`Sockets=`); `site install-server`
stops a site that binds its own ports, starts the sockets, starts the
site on them; the host check wants the sockets active. A test checks the
names, the ports and the service's `Sockets=`.

Measured on the laptop with transient units (`systemd-run --user`, the
same socket properties): the roux competitor through three restarts
under load answered every request (twice), the slowest ~315 ms;
fourneau-hello binding its own port refused 4,771 in the same test.
The branch was `http2`, renamed: everything that waits for the race.
Not done here: running `install-server` on the host (the owner's).

## 2026-10-10: `dragrace diff`: second opinions (fourneau's M11)

A command: build the competitors, start each here, send 59 cases as raw
bytes (each on a new connection, read to the close or a second's
silence), parse the answers (interim responses, lengths, chunks, a
HEAD's head alone) and compare status, close and body (an error's body
by status only: each stack words its own). A table, stdout and
`out/diff.md`. Tests: the response parser (lengths, chunks with
extensions and trailers, 100 before 200, HEAD, garbage) and unique case
names.

fourneau-zig against Go and axum: 46 of 59 differed; fourneau fixed three
(its DIARY: HTTP/1.2, garbage refused at once, a small unread body
skipped), and the competitor routed HEAD as GET, a query no longer
breaking a route (`Head.path()`), 405 with `Allow` for a wrong method.
Then 28 differ, each kept in fourneau's docs/differential.md.

## 2026-10-10: the 05:00 run never built; two causes, both fixed

The run failed: "the build: no build after 45m0s". Two causes.

1. roux on GitHub (`333e773`) carried half of fourneau's fiber pool
   (another session's blanket add), the other half unpushed: roux's
   host did not compile (`no field ... 'fibers_max'`). Repaired by
   pushing roux's `race-safe` (`158cfe5`) at 11:22 UTC.
2. Every build since `748fe02` (2026-10-09 20:17 UTC) had already
   failed at the bundle: "a checkout has changes not committed". roux
   build rewrote the committed `Templates.roc` files, since their
   `layouts` key hashes the path roc is installed at, and a runner's
   differs from the laptop's. Found by reproducing CI's steps on the
   laptop (clean there) and reading CI's log ("modules changed" there,
   not here). Fixed by not committing those generated files (`fd2996d`,
   pushed; roux's TODO has the real fix: key them by the layouts). The
   build then passed in CI, the first since 2026-10-09.

A manual race of the old code was asked for (request 6; request 5,
asked before the second cause was found, waits out its 45 minutes for a
build that cannot come). Then this repository's main, roux's and
fourneau's, with the night's work, for the next nightly.

## 2026-10-10: fourneau-zig's template is roux's ceiling

Templates on the smallest class (manual run 6): fourneau-zig 44,219
req/s, roux 43,145, inside roux's 12.8% spread between rounds. The two
templates are separate: fourneau-zig's is about 80 lines of pure Zig,
split at comptime, with no rocstache; roux's is rocstache bytecode run
by its host's VM. So the pure-Zig one is the ceiling, and roux being
even with it means the Roc integration is near the most it can give
(the owner's reading). Written into both competitors' READMEs and the
site's Competitors page. roux's README still said its template was
compiled to machine code (the templates-comptime branch, not chosen);
corrected to the VM. The plaintext-h2 summary no longer says it is how
a browser pays HTTP/2: no browser speaks h2c.

## 2026-10-10: HTTP/2 and TLS, the realistic deployment

The owner asked for a second layer: HTTP/1.1 kept, h2c kept to take
HTTP/2 apart from TLS, and HTTPS as browsers reach a single binary with
no proxy. Four workloads (race.json): plaintext-tls (h2c's shape over
TLS: TLS's cost a request), churn-tls (a full handshake a request,
HTTP/1.1), templates-tls and sse-tls (HTTP/2 + TLS, 128 connections of 2
streams), the last two with ladders, as templates has. Orthogonal: each
differs from a workload already raced in one thing.

- The competitors: an HTTPS mode on the same port, from
  `competitor.json`'s `run.tls` (Go's `ListenAndServeTLS`; axum through
  tokio-rustls and hyper-util, as axum's low-level-rustls example;
  fourneau-zig through `fourneau.https`; roux's `ROUX_TLS_*`).
  basic-webserver's platform serves no TLS: it sits these out.
- The same TLS for all (RACING.md, TLS): a race's own ECDSA P-256
  certificate, TLS 1.3, X25519, AES-128-GCM, no resumption. Found while
  checking it: oha (rustls) asks for AES-256 first and rustls and
  fourneau follow the client, where Go chooses AES-128; so axum and
  fourneau now offer AES-128 and ChaCha20 only (fourneau 9d34a4d). The
  first check in TLS mode asks as oha does and refuses anything else.
- The racer: a round starts each competitor once a mode (`raceMode`),
  checked a mode at a time (`validKey`); ladders per workload
  (`"ladder"`); workloads carry their section (`http1`, `h2c`, `tls`).
- The site: the class tabs and, beside them, a smaller cyan toggle,
  HTTP/1.1 and HTTP/2 + TLS (`?protocol=`), on the race page and the
  history; below either, h2c's strip and a table of plaintext three ways
  with HTTP/2's and TLS's change. The Workloads page in the three
  sections. The schema: run_workloads gains http2, streams, tls,
  section and ladder; run_settings loses open_loop_workload
  (`site/migrations/2026-10-10-sections.sql`, which rebuilds the two
  tables from schema.sql's text: roux compares it).

Checked: a quick local race of plaintext, templates and every new
workload (`race local -quick`), every competitor valid in both modes
but basic-webserver (no TLS results, as meant); its results posted to a
local site (curl, the racer's API), both sections and a phone's width
looked at; the migration run on a database of the old schema, then
opened by the new site (schema accepted, the ladder line right). Go
tests, the site's 101 tests, fourneau's tests pass.

Seen in that quick race (a busy laptop, 1-3 s rounds: not results):
churn-tls fourneau-zig 1,985 and roux 1,969 a second against axum 5,836
and Go 3,339 (fourneau's handshake: its TODO); plaintext over HTTPS
fourneau-zig 254k against its h2c 351k, axum 105k against 121k, Go 29k
against 32k. The TLS ladders showed p99 ~70 ms at half load for every
server: each oha run opens its connections with their handshakes at
once, which a 2 s step cannot dilute (RACING.md, TLS).

## 2026-10-10: the first race with HTTPS

Manual race `2026-10-10T171748Z-cloud` (fourneau 9d34a4d, roux 771769e,
dragrace 24d5198): 82 minutes, $0.36. Every competitor valid in TLS mode
on dedicated-2 (basic-webserver sits out, as meant). Medians a second,
dedicated-2:

| | plaintext | plaintext-h2 | plaintext-tls | churn-tls | templates-tls | sse-tls |
|---|---|---|---|---|---|---|
| fourneau-zig | 168,380 | 250,956 | 202,861 | 1,732 | 69,712 | 64,617 |
| roux | 159,183 | 236,767 | 187,859 | 1,718 | 66,267 | 36,895 |
| axum | 70,463 | 85,210 | 78,674 | 5,103 | 45,406 | 30,573 |
| Go | 41,097 | 23,284 | 22,770 | 2,736 | 11,283 | 5,475 |

- TLS a request (plaintext-h2 to plaintext-tls): fourneau-zig −19%,
  roux −21%, axum −8%, Go −2%. A full handshake (churn-tls) is
  fourneau's weak spot, a third of axum's (fourneau's TODO).
- On smallest, fourneau-zig and roux did not start: the OOM killer took
  them at ~290 MB. fourneau's slabs were written whole at startup in a
  safe build (`alloc` fills with 0xAA): 412 MB on dedicated-2, where the
  race before held 117 MB. Fixed in fourneau 5739295
  (`stdx.alloc_untouched`): 38 MB for one shard. Not pushed.
- The TLS ladders' p99 at half load: fourneau-zig 72 ms and roux 66 ms
  on templates-tls, axum 18 ms, Go 46 ms. About 128 handshakes at each
  server's churn-tls rate (128 / 1,732 a second is 74 ms): each 10 s step
  is a new oha run, which opens all its connections at once, and the
  queue behind them is ~1% of the step. The ladders' tails measure the
  handshake again (TODO).
- The loader is near its limit for fourneau-zig (95% of its CPUs on sse,
  89% on plaintext-h2).
