# Self-hosting: the site keeps the races, and runs them

The design of TODO's WIP 5 (owner, 2026-10-06): which machine does what,
what crosses between them, and what each one can do if it is taken. Not
how to race (RACING.md) or the secrets' setup steps (SECURITY.md, once
built). Everything here is planned until TODO says otherwise.

## Machines

| machine | runs | holds | inbound |
|---|---|---|---|
| site host (exists, nyc3, $4) | the site (roux, SQLite FULL); `dragrace host-agent` (a timer) | the races' database and its copies; the racer and manual tokens | 22 (owner), 80, 443 |
| racer (new, lon1, $4) | `dragrace racer` (a service); `dragrace guard` (a service) | the DigitalOcean token (the guard's only); a GitHub token (Actions only); the racer token | 22 (owner) |
| race droplets (per race) | a server; a loader running `dragrace worker` | the run's SSH key; the run's worker token | 22 (the run's key) |
| GitHub | `build.yml`: builds and releases; `ci.yml` as today | nothing secret | |

No GitHub runner is held for a race, and GitHub holds no secret.

## Builds and deploys

- `build.yml` runs on a push to main and when the racer dispatches it. It
  builds at the heads of this repository, fourneau and roux: every
  competitor, oha's pin, the site and the `dragrace` tool, all for the
  droplets (linux x86_64). It publishes them as a release `build-<UTC>`
  with `build.json`: the three commits, the versions, each file's
  SHA-256. Older releases past the newest 20 are deleted.
- **The site deploys itself.** `dragrace host-agent` (a timer, every
  minute) reads `releases/latest/download/build.json` (a CDN download,
  not the rate-limited API). A new site commit: download, check the
  hashes, unpack beside the current one, point `current` at it, restart,
  ask `/api/health` for 30 s; no answer: point back, restart, log why. A
  schema change makes the new site refuse to open the database (roux has
  no migrations yet), so it rolls back until the owner migrates over SSH.
- A restart drops the requests in flight; workers retry (below), so a
  deploy during a race loses nothing. Commits are FULL: on the disk when
  answered.
- The host agent and the guard are installed by the owner and never
  update themselves (a broken one would stop the updates, or the budget);
  the racer updates itself from the newest release between races.

## A run

1. **Asked.** A request row in the site: `check` (race only if a
   repository has a commit the last finished run did not race) or `race`
   (always). The racer's timer asks for a check at 03:00 New York time;
   the owner asks for a race with the manual token (`dragrace site
   race-now`).
2. **Taken.** The racer polls the site every 30 s. It reads the heads
   (GitHub's API) and the last finished run's commits from the site. A
   check with nothing new is recorded as a run with status `skipped`;
   otherwise a run is made: its ID (`2026-10-07T070000Z-cloud`), how it
   started (`timer` or `manual`), each repository's commit and whether it
   was new, the seed, race.json whole and its parts as rows.
3. **Built.** The newest release built at exactly those commits, or the
   racer dispatches `build.yml` and waits (40 min at most).
4. **Budget.** The guard refuses a droplet that would let the month's
   spend pass the cap (below): the run ends `refused`.
5. **Raced.** Per class a server and a loader, as today. The racer makes
   a worker token for the run (the site keeps it with the run), copies
   the build, the run's SSH key and a config to each loader, and starts
   `dragrace worker` there (`systemd-run`, so it outlives the racer's
   SSH). The worker races its class as `raceClass` does today and posts
   each result (rounds, open-loop steps) and its machines to the site as
   it finishes them.
6. **Ended.** The racer waits for each worker to exit, copies its results
   file and posts every result again (idempotent: a result is keyed by
   run, class, workload and competitor, and replaces itself), deletes the
   class's droplets, then posts the timing and every droplet's life and
   cost, and the run's status (`finished`, or `failed` with why). Then
   it asks the site for a backup.

The racer restarting mid-race (its own update waits for idle, but a crash
or reboot happens) marks the run `interrupted` and deletes its droplets.

## Retries

A worker or the racer retries a post with backoff (1 s doubling to 30 s)
for 20 minutes: a deploy takes about a minute and a rollback two, so
that is ten times what a deploy needs. The site answers a repeated post
the same way as the first.

## The site's database

STRICT tables, one row per thing, first class; JSON only for race.json
whole (an archive) and the open loop's shares. Times are ISO 8601 UTC
text. `db/schema.sql` is the truth; in short:

- `requests`: what was asked, by whom (`timer`, `owner`), when, the run
  that took it.
- `runs`: ID, trigger, status (`racing`, `finished`, `failed`,
  `interrupted`, `skipped`, `refused`), why, times, seed, race settings,
  the worker token, timing and cost.
- `run_commits`: per run and repository, the commit and whether it was
  new.
- `run_versions`, `run_competitors`, `run_workloads`, `run_classes`: the
  pins and race.json, per run, as they were.
- `machines`, `droplets`: every machine raced on and every droplet paid
  for (size, CPU, kernel, price an hour, life, cost), so a size changing
  under its name shows.
- `results`, `rounds`, `open_steps`: as Run's JSON today, a column a
  field.
- `class_status`: per run and class, racing, done or failed, and its
  time.
- `heads`: each repository's newest commit the racer saw, and when; the
  race page compares them with the last finished run to say whether
  tonight races.

Legacy runs are not imported (owner, 2026-10-06).

## The site's API

All `POST` but `GET /api/racer/next` and `/api/health`; JSON bodies;
`Authorization: Bearer <token>`, compared in constant time.

| route | token | does |
|---|---|---|
| `POST /api/requests?kind=race` | manual | asks for a race |
| `POST /api/requests?kind=check` | racer | asks for a check (the timer) |
| `GET /api/racer/next` | racer | the oldest request not taken, the last finished run's commits |
| `POST /api/heads` | racer | the heads seen |
| `POST /api/runs` | racer | a run made (or skipped), taking its request |
| `POST /api/runs/ID/status` | racer | status, timing, droplets |
| `POST /api/runs/ID/machines` | worker or racer | a class's machines |
| `POST /api/runs/ID/results` | worker or racer | one result, replacing |
| `POST /api/runs/ID/classes/CLASS` | worker or racer | a class's status |
| `POST /api/backup` | racer | `Sqlite.backup!`, 30 kept |
| `GET /api/health` | none | 200 when the database answers |

A worker token is good for its run's results only, and only while the
run is `racing`.

## The budget and the token

The DigitalOcean token can make and delete droplets and keys in the whole
account; DigitalOcean has alerts but no hard cap. So the token lives on
the racer only, readable by the guard only (its own user; a systemd
credential, encrypted with the machine's key; sent there over SSH from
the owner's keyring, never on a command line). The racer reaches
DigitalOcean only through the guard, on a Unix socket, which allows:

- create a droplet: only a size in its own config (the owner's, on the
  racer's disk, not from a build), at no more than that size's price an
  hour, in the race region, from the pinned image, tagged as a race;
  at most 6 alive;
- delete a droplet it made; make and delete SSH keys named
  `fourneau-dragrace-*`; list sizes;
- and it refuses a create when the month's spend so far, plus every
  alive droplet's cost if it lived to the cap of 3 hours, plus the new
  one's, would pass the monthly cap (its own ledger: each droplet's life
  by its own clock, at the price it allowed). It deletes any droplet it
  made that passes 3 hours.

So a racer or build taken over can spend at most the cap, on the sizes
the owner chose; it cannot read the token. The guard taken over (root on
the racer) has the token: the owner rotates it.

## What each secret opens

| secret | where | taken, it can |
|---|---|---|
| DigitalOcean token | racer, the guard's credential; owner's keyring | the account (rotate) |
| GitHub token (fine-grained: this repository, Actions read and write) | racer | dispatch and cancel builds |
| racer token | racer; site | ask checks, post runs and results, back up |
| manual token | owner's keyring; site | ask for races (the budget still holds) |
| a worker token | a race's loader; site | post that run's results while it races |
| a run's SSH key | racer; that run's loaders | that run's droplets, while they live |
