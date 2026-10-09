# Self-hosting: the site keeps the races, and runs them

Which machine does what, what crosses between them, and what each one
can do if it is taken (designed with the owner 2026-10-06, live since
2026-10-07). Not how to race (RACING.md) or the secrets' setup steps
(SECURITY.md).

## Machines

| machine | runs | holds | inbound |
|---|---|---|---|
| site host (lon1, $4) | the site (roux, SQLite FULL); `dragrace host-agent` (a timer) | the races' database and its copies; the racer and manual tokens | 22 (owner), 80, 443 |
| racer (lon1, $4) | `dragrace racer` (a service); `dragrace guard` (a service) | the DigitalOcean token (the guard's only); a GitHub token (Actions only); the racer token | 22 (owner) |
| race droplets (per race) | a server; a loader running `dragrace worker` | the run's SSH key; the run's worker token | 22 (the run's key) |
| GitHub | `build.yml`: builds and releases; `ci.yml` as today | nothing secret | |

No GitHub runner is held for a race, and GitHub holds no secret.

Both hosts keep Ubuntu's update cycle stock, as DigitalOcean and
Canonical advise: unattended-upgrades' daily run (security only, 06:00
UTC plus up to an hour of random delay), and its own reboot at the end
of that run when an update needs one (`Automatic-Reboot "true"`, the one
setting changed; `hostFiles`). The reboot never comes mid-install, and is
over by 07:30 UTC: 03:30 New York time in summer, 02:30 in winter. The
nightly check is at 05:00 New York time, after it all year (owner,
2026-10-08). The site's reboot is a half minute's outage, which posts
retry through; the racer's mid-race would end the run (`interrupted`,
its droplets deleted), so a manual race is not started between 02:00 and
03:30 New York time.

Both boot without an initramfs (`GRUB_FORCE_PARTUUID`, as Ubuntu's own
cloud images; the kernel has virtio and ext4 built in, and the
initramfs is GRUB's fallback): the site host's first boot of a new
kernel, 2026-10-08, panicked in its initramfs, twice. Both run ufw,
set up by the install (cloud-init's setup of it can silently not run).

Until 2026-10-08 a homemade timer rebooted both at 02:30 New York time;
after that night's panic the site host was rebuilt from the base image
in DigitalOcean's panel (Destroy, Rebuild; same address) and installed
from scratch (DIARY.md). `dragrace site restore` lists the backups;
restoring one needs a token with `droplet:admin`, which the project's
lacks, so it is done in the panel.

## Builds and deploys

- `build.yml` runs on a push to main and when the racer dispatches it. It
  builds at the heads of this repository, fourneau and roux: every
  competitor, oha's pin, the site and the `dragrace` tool, all for the
  droplets (linux x86_64). It publishes them as a release `build-<UTC>`
  with `build.json`: the three commits, the versions, each file's
  SHA-256. Older releases past the newest 20 are deleted.
- The racer, not a schedule, asks for a build of fourneau's or roux's new
  commits: a build exactly when a race needs one (owner, 2026-10-07, over
  a scheduled check, which needed no token but built on a timer and
  stops after 60 days without commits). Its GitHub token can only
  dispatch and cancel this repository's builds.
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
  the racer updates itself from the newest release between races, from
  any binary that is not that release's (`racer install` starts it on
  the installer's own).

## Knowing it is down

A DigitalOcean uptime check, `fourneau-dragrace-site`, asks
`https://fourneau.y2kbugger.com/api/health` (200 only when the site and
its database answer) from every region, and emails the owner: down for
2 minutes, the certificate expiring within 5 days, latency over 2000 ms
for 10 minutes. Made by hand in the panel (owner, 2026-10-09): under the
legacy Monitoring, Uptime; Insights' new alert rules know only the
probe's duration, which cannot say down, and the project's token has no
uptime scope (it would widen the racer's too).

## What is on each host, and whether it matches

| on the host | defined in | put there by | changes when |
|---|---|---|---|
| droplet: size, region, image, user data | `site provision`, `racer provision` | the provision, once | a rebuild |
| systemd units, host files, configs, firewall, boot setting, swap | `siteUnits`, `racerUnits`, `hostFiles`, `hostSetup` | `site install-server`, `racer install` | the owner installs again |
| the host agent, the guard | this checkout's `out/dragrace` | the installs | the owner installs again |
| the site's code | the newest release | the host agent | a push (within a minute) |
| the racer's binary | the newest release | the racer itself | a push (within 10 minutes, idle) |
| Ubuntu | Ubuntu | unattended-upgrades | nightly |

Each install stamps the commit it was run from in
`/etc/dragrace-host/installed` ("-dirty" with changes not committed).
`out/dragrace hosts check -racer RACER` (read only, any time; after
every install) renders what this checkout says each host should be and
compares: every unit and host file by SHA-256, the configs and
credentials there, the retired files gone, the firewall on with exactly
its ports, booted without an initramfs, the services up and no unit
failed, the stamp against HEAD, the site's code and the racer's binary
against the newest release. It prints each difference and exits 1 on
any; "in sync" is the goal. A reboot pending is a note, not a difference.

## A run

1. **Asked.** A request row in the site: `check` (race only if a
   repository has a commit the last finished run did not race) or `race`
   (always). The racer's timer asks for a check at 05:00 New York time;
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
