-- The dragrace site's database: every run asked for, raced or skipped, as
-- rows (docs/self-hosting.md). STRICT, as roux-db requires. Times are
-- ISO 8601 UTC text ("2026-10-07T07:00:00Z"), which sorts as time; the
-- site's own times come from SQLite's clock (`now`). A flag is INTEGER 0
-- or 1. No migrations yet: a change here is applied over SSH (SECURITY.md).

-- What was asked: a check (race only if a repository has a commit the
-- last finished run did not race) by the racer's timer, or a race by the
-- owner. The racer takes the oldest not taken.
CREATE TABLE requests (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('check', 'race')),
  asked_by TEXT NOT NULL CHECK (asked_by IN ('timer', 'owner')),
  asked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  taken_at TEXT
) STRICT;

-- One run: raced, or skipped (nothing new), or refused (the budget).
CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  request_id INTEGER UNIQUE REFERENCES requests (id),
  trigger TEXT NOT NULL CHECK (trigger IN ('timer', 'manual')),
  status TEXT NOT NULL CHECK (status IN
    ('racing', 'finished', 'failed', 'interrupted', 'skipped', 'refused')),
  -- Why it failed, was skipped or refused; '' when there is nothing to say.
  reason TEXT NOT NULL,
  where_raced TEXT NOT NULL CHECK (where_raced IN ('cloud', 'local')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  started_at TEXT NOT NULL,
  finished_at TEXT,
  -- Results are taken with it while the run races; NULL once it ended.
  worker_token TEXT,
  -- Timing (the racer's clock): the whole run, building, launching the
  -- droplets, racing; and every droplet's cost, in US dollars.
  seconds REAL NOT NULL DEFAULT 0,
  build_seconds REAL NOT NULL DEFAULT 0,
  launch_seconds REAL NOT NULL DEFAULT 0,
  racing_seconds REAL NOT NULL DEFAULT 0,
  cost_usd REAL NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX runs_by_start ON runs (started_at);

-- Each repository's commit, and whether the last finished run before
-- this one raced another.
CREATE TABLE run_commits (
  run_id TEXT NOT NULL REFERENCES runs (id),
  repository TEXT NOT NULL CHECK (repository IN ('fourneau-dragrace', 'fourneau', 'roux')),
  commit_sha TEXT NOT NULL,
  new INTEGER NOT NULL CHECK (new IN (0, 1)),
  PRIMARY KEY (run_id, repository)
) STRICT, WITHOUT ROWID;

-- race.json as raced (a raced run has one): its settings as columns, and
-- the file whole, for what no column holds.
CREATE TABLE run_settings (
  run_id TEXT PRIMARY KEY REFERENCES runs (id),
  seed INTEGER NOT NULL,
  region TEXT NOT NULL,
  image TEXT NOT NULL,
  port INTEGER NOT NULL,
  rounds INTEGER NOT NULL,
  warmup_seconds INTEGER NOT NULL,
  measure_seconds INTEGER NOT NULL,
  open_loop_workload TEXT NOT NULL,
  -- A JSON array of numbers: the shares of the closed-loop median offered.
  open_loop_shares TEXT NOT NULL,
  open_loop_warmup_seconds INTEGER NOT NULL,
  open_loop_measure_seconds INTEGER NOT NULL,
  race_json TEXT NOT NULL,
  versions_json TEXT NOT NULL
) STRICT;

-- versions.json's pins, a row each (zig, roc, oha, go, rust, axum, tokio,
-- droplet_image, ...).
CREATE TABLE run_versions (
  run_id TEXT NOT NULL REFERENCES runs (id),
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  PRIMARY KEY (run_id, name)
) STRICT, WITHOUT ROWID;

CREATE TABLE run_competitors (
  run_id TEXT NOT NULL REFERENCES runs (id),
  name TEXT NOT NULL,
  position INTEGER NOT NULL,
  title TEXT NOT NULL,
  language TEXT NOT NULL,
  framework TEXT NOT NULL,
  PRIMARY KEY (run_id, name)
) STRICT, WITHOUT ROWID;

CREATE TABLE run_workloads (
  run_id TEXT NOT NULL REFERENCES runs (id),
  name TEXT NOT NULL,
  position INTEGER NOT NULL,
  -- closed: rounds at full load, drawn as bars; mixed: an open-loop ladder
  -- of several requests at once (conduit), drawn as a line.
  kind TEXT NOT NULL CHECK (kind IN ('closed', 'mixed')),
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  method TEXT NOT NULL,
  path TEXT NOT NULL,
  body_bytes INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  connections INTEGER NOT NULL,
  keepalive INTEGER NOT NULL CHECK (keepalive IN (0, 1)),
  PRIMARY KEY (run_id, name)
) STRICT, WITHOUT ROWID;

-- The server classes raced: the sizes asked for. What each droplet was is
-- in machines and droplets, so a size changing under its name shows.
CREATE TABLE run_classes (
  run_id TEXT NOT NULL REFERENCES runs (id),
  name TEXT NOT NULL,
  position INTEGER NOT NULL,
  label TEXT NOT NULL,
  title TEXT NOT NULL,
  size TEXT NOT NULL,
  loader_size TEXT NOT NULL,
  PRIMARY KEY (run_id, name)
) STRICT, WITHOUT ROWID;

-- Each class of a raced run, as its worker says.
CREATE TABLE class_status (
  run_id TEXT NOT NULL REFERENCES runs (id),
  class TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('racing', 'done', 'failed')),
  reason TEXT NOT NULL,
  seconds REAL NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  PRIMARY KEY (run_id, class)
) STRICT, WITHOUT ROWID;

-- Every machine raced on, as it reported itself.
CREATE TABLE machines (
  run_id TEXT NOT NULL REFERENCES runs (id),
  class TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('server', 'loader')),
  size TEXT NOT NULL,
  cpu TEXT NOT NULL,
  cpus INTEGER NOT NULL,
  kernel TEXT NOT NULL,
  cpu_id TEXT NOT NULL,
  -- MemTotal from /proc/meminfo: what the kernel has, a little under
  -- the size's nominal memory. 0 before 2026-10-07.
  memory_mib INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (run_id, class, role)
) STRICT, WITHOUT ROWID;

-- Every droplet paid for: its life by the racer's clock, and its price.
CREATE TABLE droplets (
  run_id TEXT NOT NULL REFERENCES runs (id),
  position INTEGER NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('server', 'loader')),
  class TEXT NOT NULL,
  size TEXT NOT NULL,
  price_hourly REAL NOT NULL,
  seconds REAL NOT NULL,
  cost_usd REAL NOT NULL,
  PRIMARY KEY (run_id, position)
) STRICT, WITHOUT ROWID;

-- One competitor on one workload on one server class: the medians of its
-- rounds, and whether it answered as the workload asks.
CREATE TABLE results (
  run_id TEXT NOT NULL REFERENCES runs (id),
  class TEXT NOT NULL,
  workload TEXT NOT NULL,
  competitor TEXT NOT NULL,
  valid INTEGER NOT NULL CHECK (valid IN (0, 1)),
  note TEXT NOT NULL,
  median_rps REAL NOT NULL,
  median_p50_ms REAL NOT NULL,
  median_p95_ms REAL NOT NULL,
  median_p99_ms REAL NOT NULL,
  median_p999_ms REAL NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  PRIMARY KEY (run_id, class, workload, competitor)
) STRICT, WITHOUT ROWID;

-- A measured round, a column per measure (results.go, Round).
CREATE TABLE rounds (
  run_id TEXT NOT NULL,
  class TEXT NOT NULL,
  workload TEXT NOT NULL,
  competitor TEXT NOT NULL,
  round INTEGER NOT NULL,
  rps REAL NOT NULL,
  p50_ms REAL NOT NULL,
  p90_ms REAL NOT NULL,
  p95_ms REAL NOT NULL,
  p99_ms REAL NOT NULL,
  p999_ms REAL NOT NULL,
  p9999_ms REAL NOT NULL,
  mean_ms REAL NOT NULL,
  max_ms REAL NOT NULL,
  first_byte_p50_ms REAL NOT NULL,
  first_byte_p99_ms REAL NOT NULL,
  success_rate REAL NOT NULL,
  errors INTEGER NOT NULL,
  non_2xx INTEGER NOT NULL,
  rps_per_second_stddev REAL NOT NULL,
  connect_mean_ms REAL NOT NULL,
  bytes_per_response REAL NOT NULL,
  cpu_busy_pct REAL NOT NULL,
  cpu_user_pct REAL NOT NULL,
  cpu_system_pct REAL NOT NULL,
  cpu_irq_pct REAL NOT NULL,
  cpu_softirq_pct REAL NOT NULL,
  steal_pct REAL NOT NULL,
  loader_cpu_busy_pct REAL NOT NULL,
  rss_kib INTEGER NOT NULL,
  net_rx_mbps REAL NOT NULL,
  net_tx_mbps REAL NOT NULL,
  net_rx_pps REAL NOT NULL,
  net_tx_pps REAL NOT NULL,
  tcp_retransmits INTEGER NOT NULL,
  threads INTEGER NOT NULL,
  voluntary_switches INTEGER NOT NULL,
  involuntary_switches INTEGER NOT NULL,
  load_seconds REAL NOT NULL,
  seconds REAL NOT NULL,
  PRIMARY KEY (run_id, class, workload, competitor, round),
  FOREIGN KEY (run_id, class, workload, competitor)
    REFERENCES results (run_id, class, workload, competitor)
) STRICT, WITHOUT ROWID;

-- One rate of an open-loop ladder (open_loop.go, OpenStep): of one
-- workload, or of a mixed one, whose parts are in open_step_parts.
CREATE TABLE open_steps (
  run_id TEXT NOT NULL,
  class TEXT NOT NULL,
  workload TEXT NOT NULL,
  competitor TEXT NOT NULL,
  step INTEGER NOT NULL,
  share REAL NOT NULL,
  offered_rps REAL NOT NULL,
  achieved_rps REAL NOT NULL,
  p50_ms REAL NOT NULL,
  p90_ms REAL NOT NULL,
  p99_ms REAL NOT NULL,
  p999_ms REAL NOT NULL,
  errors INTEGER NOT NULL,
  non_2xx INTEGER NOT NULL,
  cpu_busy_pct REAL NOT NULL,
  loader_cpu_busy_pct REAL NOT NULL,
  net_rx_mbps REAL NOT NULL,
  net_tx_mbps REAL NOT NULL,
  -- The mean over every request of the step.
  mean_ms REAL NOT NULL,
  PRIMARY KEY (run_id, class, workload, competitor, step),
  FOREIGN KEY (run_id, class, workload, competitor)
    REFERENCES results (run_id, class, workload, competitor)
) STRICT, WITHOUT ROWID;

-- One part of a mixed step (mixed.go, OpenPart): a kind of request, its
-- own rate and latency.
CREATE TABLE open_step_parts (
  run_id TEXT NOT NULL,
  class TEXT NOT NULL,
  workload TEXT NOT NULL,
  competitor TEXT NOT NULL,
  step INTEGER NOT NULL,
  part TEXT NOT NULL,
  offered_rps REAL NOT NULL,
  achieved_rps REAL NOT NULL,
  mean_ms REAL NOT NULL,
  p50_ms REAL NOT NULL,
  p99_ms REAL NOT NULL,
  p999_ms REAL NOT NULL,
  errors INTEGER NOT NULL,
  non_2xx INTEGER NOT NULL,
  PRIMARY KEY (run_id, class, workload, competitor, step, part),
  FOREIGN KEY (run_id, class, workload, competitor, step)
    REFERENCES open_steps (run_id, class, workload, competitor, step)
) STRICT, WITHOUT ROWID;

-- Each repository's newest commit as the racer last saw it: the race page
-- says whether tonight's check will race.
CREATE TABLE heads (
  repository TEXT PRIMARY KEY CHECK (repository IN ('fourneau-dragrace', 'fourneau', 'roux')),
  commit_sha TEXT NOT NULL,
  seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
) STRICT, WITHOUT ROWID;
