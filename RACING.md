# Racing

How a race runs, where everything is, and every command of the tool.

## Layout

This repository, fourneau and roux sit side by side, as they do in CI and
in the owner's `~/devel/eldhus/`:

```
some-dir/
  fourneau-dragrace/     this repository
  fourneau/              the server (versions.json: fourneau.checkout)
  roux/                  the Roc platform on it (versions.json: roux.checkout)
```

fourneau-zig builds against fourneau (`competitors/fourneau-zig/build.zig.zon`);
roux's app names its platform in roux (`competitors/roux/main.roc`), and
roux builds against fourneau (its own `build.zig.zon`).

## What is where

| path | what |
|---|---|
| `race.json` | the race: workloads, rounds, durations, droplet sizes, local CPUs |
| `versions.json` | every pin (VERSIONS.md) |
| `competitors/NAME/` | a competitor: its source, `competitor.json` (build and run), README |
| `tools/cmd/dragrace/` | the tool: Go, standard library only |
| `site/` | the site, a roux app: rocstache templates, the races in its SQLite (`site/db/`), the API the racer and workers post to |
| `docs/self-hosting.md` | the machines, a run, the database, the API, the budget |
| `.github/workflows/` | ci (every push), build (every push to main, and when the racer asks: the releases) |
| `out/` | builds, results, secrets (ignored) |

## The contract

Every competitor listens where it is told (`{address}`, `{port}` in its
`competitor.json`; port 8080) and answers:

- `GET /plaintext`: 200, `Content-Type: text/plain; charset=utf-8`, body `Hello, World!`
- `POST /echo`: 200, `Content-Type: application/octet-stream`, the request body (up to 64 KiB)
- `GET /menu`: 200, `Content-Type: text/html; charset=utf-8`, the page in
  `workloads/menu.html`, rendered from a template per request with the
  competitor's usual engine, every value HTML-escaped (entities may be
  spelled `&amp;` or `&#38;`: the check treats them alike)
- `GET /sse?datastar=JSON`: a Datastar action. The signals are JSON in the
  `datastar` query parameter (`{"count":41}`); the answer is 200,
  `Content-Type: text/event-stream`, the events in `workloads/sse.txt`
  for count + 1, streamed: chunked, no `Content-Length`, each event a
  chunk of its own, made and sent in turn with the competitor's own SSE
  support (whether ready chunks share a write is the stack's business).
  Without good signals: 400.
- anything else: 404

The race checks all of them before a competitor runs (`/sse` when the
race has the SSE workload); one that fails is DNF.

### Conduit: reads and writes on SQLite

A slice of [RealWorld](https://realworld-docs.netlify.app/)'s Conduit API.
The server is started with `{db}`: a fresh copy of a database seeded the
same for everyone (`workloads/conduit/schema.sql`, seeded by
`tools/cmd/dragrace/conduit.go`: 100 users, 1,000 articles, tags,
favorites, comments). It opens it in WAL mode with `synchronous=NORMAL`,
and answers JSON (`Content-Type: application/json`) as the spec's
response format says:

- `GET /api/articles?limit=L&offset=O`: `{"articles": [...], "articlesCount": N}`,
  newest first (`created_at`, then `id`, descending); each article without
  its body (the spec since 2024-08), `tagList` sorted, `favorited` false,
  `favoritesCount` counted, `author` with `following` false and `image`
  null when the user has none
- `GET /api/articles/SLUG`: `{"article": {...}}`, with the body; 404 for no such article
- `POST /api/articles/SLUG/comments` with `{"comment":{"body":"..."}}`:
  200, `{"comment": {"id", "createdAt", "updatedAt", "body", "author"}}`,
  the time ISO 8601 with milliseconds (`2026-01-01T00:00:00.000Z`)
- `POST /api/articles/SLUG/favorite`: 200, the article with `favorited`
  true and its count with the new favorite (a second favorite adds none)

Both writes need `Authorization: Token TOKEN` (the `users.token` column:
a session, where the spec has a JWT; 401 without one). No follows: every
`following` is false. The race checks the answers against the seed's
model (`validateConduit`): a competitor that differs is DNF on conduit.

Under load it is open loop only: at each total rate of `mixed.rates`, the
list (50%), an article (30%), a comment (15%) and a favorite (5%) at once,
a random article or page each request (oha `--rand-regex-url`), one oha
a part. A server climbs until it answers under 90% of the rate offered,
or errs. Each step records the mean over every request (the chart) and
each part's rate, mean, p50, p99 and p99.9.

## A race

A cloud race runs on its own droplets, started by the racer (docs/self-hosting.md):
a `dragrace worker` on each class's loader drives that class's server over
the private network and posts each result to the site as it lands.
`dragrace race local` runs the same race on one machine.

For each server class, for each round (a new random order every round, from
a seed recorded in the results), for each competitor: start it, wait until
it answers, check it (first round), then for each workload a warmup
(discarded) and a measured oha run, with a snapshot of both machines
before and after (`snapshot.go`). The result is the median of the rounds,
for throughput and for p50, p95, p99 and p99.9; throughput counts 2xx
answers only (errors and other statuses are no work done).

Each round keeps (the raw data, `results.go`'s `Round`):

| from | what |
|---|---|
| oha | requests/s; latency p50, p90, p95, p99, p99.9, p99.99, mean and max; time to first byte, p50 and p99 (for a stream, when events start); the per-second spread of throughput; the mean connect time; bytes per response; errors and non-2xx |
| the server machine | CPU busy, user, system, irq, softirq and steal on the server's CPUs (softirq is the network stack's work for it); network in and out, Mbit/s (a result at the droplet's link shows here); TCP retransmits |
| the server process | peak RSS; threads; voluntary and involuntary context switches, every thread's |
| the server machine (also) | packets a second in and out: DigitalOcean also limits packets, which small responses reach before bytes |
| the loader machine | CPU busy: a busy loader means the server was not the limit |

Rates and shares are taken over oha's own duration (`load_seconds`), not
the snapshots' window, which also holds the shell calls around the load
(about six seconds of 26 from GitHub's runner: every CPU figure read 23%
low until 2026-10-06).

oha runs with `--disable-compression` (it asks for gzip and brotli
otherwise, which a server that compresses honours and the checks never
see) and `--worker-threads` at the loader's CPUs.

What limited each result, as the site says it: the server's CPU (at least
90% busy: the case the race is for), the loader's (at least 90%), the
network (at least 1,400 Mbit/s either way, 70% of the 2 Gbit/s
DigitalOcean documents, where retransmits began; or at least 1,000 with
a TCP retransmit per 100 requests or more: dedicated-2's link dropped
packets from 1,320 Mbit/s on 2026-10-06, p99 205 ms), or none of them: then
the closed loop's 256 connections and their round trips were the limit,
and the server was under-driven.

## The same machine within a night, not across nights

DigitalOcean gives a size whatever host has room, and hosts of one size
differ by a CPU generation: lon1's c-2s were Xeon 8280s and 8358s on
2026-10-07, an 8168 in nyc3 the day before. Within a night that changes
nothing: every competitor of a class races on the one server droplet, in
interleaved rounds, so a night's comparison is always on one CPU. Across
nights it moves the numbers, so every machine records its CPU model and
its `family:model:stepping` (the generation, even where the name is
hidden: the shared droplets say only "DO-Regular", 6:79:1 so far), and
the history is read with them. Pinning a CPU (asking again until one
came up) was tried and dropped (owner, 2026-10-07): six c-2s in a row
missed the 8168, five minutes for nothing, and a night's fairness never
needed it. The two classes cannot share one: the shared droplets are an
older generation than the dedicated ones.

Each class has a `label` (its tab: small, medium) and a `title` (its
heading: what it is for); each run keeps its classes as raced.

## Under load: the open loop

After the rounds, each server climbs a ladder on one workload
(`race.json`'s `open_loop`: templates): fixed offered rates at 50, 75, 90,
100 and 120% of its own closed-loop median, 3 s of warmup and 10 s
measured each, latency from when each request was due (oha `-q`,
`--latency-correction`; `open_loop.go` says why steps and not a ramp).
oha pacing costs about half again the loader CPU of its closed loop
(measured): a step with the loader 85% busy or more is the loader's, and
the site draws it hollow.

## Commands

| command | does |
|---|---|
| `dragrace toolchain` | fetch Zig, Roc, oha and musl's crt files, each checked against its sha256 |
| `dragrace build` | build every competitor into `out/bin` |
| `dragrace race local [-quick] [-server-cpus 0-1 -loader-cpus 2-7]` | race here; loopback, so it compares competitors, not deployments |
| `dragrace race cloud [-quick]` | race on fresh droplets; deletes them however it ends |
| `dragrace adhoc race -workloads W VARIANT...` | builds at any commits against each other on a warm pair, in under a minute once warm (docs/adhoc.md); `adhoc status`, `adhoc down` |
| `dragrace sizes [-prefix c]` | droplet sizes with prices and the regions offering them |
| `dragrace reap [-all]` | delete race droplets and keys older than `race.json` allows |
| `dragrace fingerprint` | the commits a race would race |
| `dragrace site build` | build the site into `out/bin/dragrace-site` |
| `dragrace site dev [-port 8090 -app-port 8091]` | the site rebuilt (Roc's dev backend) and the browser reloaded on each save, for UI work |
| `dragrace bundle` | pack a build for a release (`build.yml`) |
| `dragrace site provision \| install-server \| backups` | the 24/7 site host (SECURITY.md) |
| `dragrace site race-now -host H` | ask the site for a race now (the manual token) |
| `dragrace racer provision \| install` | the racer (SECURITY.md) |
| `dragrace racer serve \| check` | on the racer: take the site's requests; ask for the nightly check |
| `dragrace racer once -local DIR` | take one request and race it here, this checkout as the build (a test) |
| `dragrace guard`, `host-agent`, `worker` | on the racer, the site host and a loader (docs/self-hosting.md) |

`-competitors a,b` and `-workloads x,y` narrow any race.

## Cost

Per nightly, two pairs at once in lon1, each a server and a loader with
more vCPUs (`dragrace sizes` has the prices): s-1vcpu-512mb with
c-4 (c-2 was 92-98% busy under fourneau-zig, 2026-10-06), and c-2 with
c-4 too. c-4 was the limit for the fastest server once (98% busy at 152k
plaintext requests/s, 2026-10-06), and this account can make no
dedicated size above 4 vCPUs (`dragrace sizes`; DigitalOcean raises such
limits on request), so dedicated-2 ran an s-8vcpu-16gb loader from then.
Its shared vCPUs hid their steal: on 2026-10-07 the closed loop
under-drove every fast server (roux's plaintext rounds 88k to 115k with
the server at 56-73%, while the open-loop ladder took fourneau-zig to 89k
against its closed loop's 75k), and the smallest class, with a c-4
loader, beat it. So c-4 again: a dedicated loader's busy figure is
honest, and at ~110k it is half busy; past ~150k it is the limit, and
the site says so. About $0.27 an hour together,
billed per second (a minute at least). With five competitors, six
workloads and the two ladders a class races for about 43 minutes: the
first cloud race from the racer (2026-10-07) took 52 minutes from
request to result, five of them finding dedicated-2's CPU, and cost
$0.29. `premium-4` (Basic Premium AMD) is out until
dedicated Premium Intel is offered: its shared vCPUs varied by 15% round
to round, its "up to 10 Gbit/s" stopped near 1 Gbit/s with retransmits,
and its slower network left 256 connections unable to saturate anything,
so its numbers measured round trips, not servers. The site host and the
racer are $4 a month each; the guard holds the races under a monthly
cap. The nightly check records a skipped run when nothing changed.

Each droplet is created once per race and deleted as soon as its class
is done (the classes finish at different times; the slowest no longer
keeps the others up). Every run records its `timing`: the whole race,
the build, the launch, the racing and each class's; and each droplet's
life, from requested to deleted, with its estimated cost at the size's
listed hourly price, and their sum (`cost_usd`).
