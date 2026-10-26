-- What the pages read: a run as Data.roc models it, the history, and
-- the racer's state for the race page.

-- The newest finished run.
-- name: latest :one
SELECT id FROM runs WHERE status = 'finished' ORDER BY started_at DESC LIMIT 1;

-- name: run :one
-- @param id : Str
SELECT id, status, trigger, started_at, seconds, cost_usd FROM runs WHERE id = :id;

-- name: commits :many(3)
-- @param run_id : Str
-- @column new : Bool
SELECT repository, commit_sha, new FROM run_commits WHERE run_id = :run_id;

-- name: versions :many(64)
-- @param run_id : Str
SELECT name, version FROM run_versions WHERE run_id = :run_id ORDER BY name;

-- name: competitors :many(64)
-- @param run_id : Str
SELECT name FROM run_competitors WHERE run_id = :run_id ORDER BY position;

-- `saturated`: a mixed workload's share of the offered rate a step must
-- answer to hold, from its race.json (0 for a closed one).
-- name: workloads :many(64)
-- @param run_id : Str
-- @column keepalive : Bool
-- @column http2 : Bool
-- @column tls : Bool
-- @column saturated : F64
SELECT w.name, w.test, w.kind, w.title, w.summary, w.protocol, w.connections, w.streams,
  w.keepalive, w.http2, w.tls,
  coalesce((SELECT json_extract(d.value, '$.mixed.saturated')
    FROM run_settings s, json_each(s.race_json, '$.workloads') AS d
    WHERE s.run_id = w.run_id AND json_extract(d.value, '$.name') = w.test), 0.0) AS saturated
FROM run_workloads w WHERE w.run_id = :run_id
ORDER BY w.position;

-- name: classes :many(32)
-- @param run_id : Str
SELECT name, label, title FROM run_classes WHERE run_id = :run_id ORDER BY position;

-- name: machines :many(64)
-- @param run_id : Str
SELECT role, class, size, cpu, cpus, kernel, memory_mib
FROM machines WHERE run_id = :run_id ORDER BY class, role;

-- name: results :many(2000)
-- @param run_id : Str
-- Its figures are its rounds' (Store.roc summarizes them).
-- @column valid : Bool
SELECT class, workload, competitor, valid, note
FROM results WHERE run_id = :run_id ORDER BY class, workload, competitor;

-- name: rounds :many(10000)
-- @param run_id : Str
-- @column rss_kib : F64
-- @column tcp_retransmits : F64
SELECT class, workload, competitor, rps, p95_ms, p99_ms, p999_ms, cpu_busy_pct, steal_pct,
  CAST(rss_kib AS REAL) AS rss_kib, loader_cpu_busy_pct, net_rx_mbps, net_tx_mbps,
  CAST(tcp_retransmits AS REAL) AS tcp_retransmits, load_seconds
FROM rounds WHERE run_id = :run_id ORDER BY class, workload, competitor, round;

-- name: steps :many(5000)
-- @param run_id : Str
SELECT class, workload, competitor, offered_rps, achieved_rps, p99_ms, p999_ms,
  cpu_busy_pct, loader_cpu_busy_pct, errors, non_2xx
FROM open_steps WHERE run_id = :run_id ORDER BY class, workload, competitor, step;

-- Every finished run's best rounds (as `results`), oldest first: the
-- history's lines (the newest 400 runs).
-- name: history :many(40000)
-- @column valid : Bool
-- @column best_rps : F64
SELECT r.id, r.started_at, s.class, s.workload, s.competitor, s.valid,
  coalesce((SELECT max(x.rps) FROM rounds x WHERE x.run_id = s.run_id AND x.class = s.class
    AND x.workload = s.workload AND x.competitor = s.competitor), 0.0) AS best_rps
FROM (SELECT id, started_at FROM runs WHERE status = 'finished'
      ORDER BY started_at DESC LIMIT 400) AS r
JOIN results s ON s.run_id = r.id
ORDER BY r.started_at, s.class, s.workload, s.competitor;

-- The newest runs of any status, for the race page's line on the racer.
-- name: recent :many(10)
SELECT id, trigger, status, reason, started_at, finished_at FROM runs
ORDER BY started_at DESC LIMIT 10;

-- The Workloads page, from the newest finished run: what each workload
-- asked, so the page never types in what race.json decides. A mixed workload's parts and rates are only in the race's
-- own race.json: `mix` ("list 50%, article 30%, ..."), and `lowest` and
-- `highest` of its rates (0 for a closed one); and `detail`, the test's
-- longer text ("" before 2026-10-11). Each is the test's entry, found by
-- its name: race.json named every workload before tests had variants
-- (conduit's entry held the same mix as conduit-tls's), and names its
-- tests since.
-- name: workload_specs :many(64)
-- @param run_id : Str
-- @column keepalive : Bool
-- @column http2 : Bool
-- @column tls : Bool
-- @column detail : Str
-- @column mix : Str
-- @column lowest : I64
-- @column highest : I64
SELECT w.name, w.test, w.kind, w.title, w.summary, w.method, w.path, w.body_bytes,
  w.connections, w.keepalive, w.http2, w.streams, w.tls, w.protocol,
  coalesce((SELECT json_extract(d.value, '$.detail')
    FROM run_settings s, json_each(s.race_json, '$.workloads') AS d
    WHERE s.run_id = w.run_id AND json_extract(d.value, '$.name') = w.test), '') AS detail,
  coalesce((SELECT group_concat(json_extract(p.value, '$.name') || ' '
      || CAST(round(json_extract(p.value, '$.share') * 100) AS INTEGER) || '%', ', ')
    FROM run_settings s, json_each(s.race_json, '$.workloads') AS d,
      json_each(d.value, '$.mixed.parts') AS p
    WHERE s.run_id = w.run_id AND json_extract(d.value, '$.name') = w.test), '') AS mix,
  coalesce((SELECT min(r.value) FROM run_settings s, json_each(s.race_json, '$.workloads') AS d,
      json_each(d.value, '$.mixed.rates') AS r
    WHERE s.run_id = w.run_id AND json_extract(d.value, '$.name') = w.test), 0) AS lowest,
  coalesce((SELECT max(r.value) FROM run_settings s, json_each(s.race_json, '$.workloads') AS d,
      json_each(d.value, '$.mixed.rates') AS r
    WHERE s.run_id = w.run_id AND json_extract(d.value, '$.name') = w.test), 0) AS highest
FROM run_workloads w WHERE w.run_id = :run_id ORDER BY w.position;

-- The rounds of a run, for the Workloads page.
-- name: race_settings :one
-- @param run_id : Str
SELECT s.rounds, s.warmup_seconds, s.measure_seconds
FROM run_settings s WHERE s.run_id = :run_id;
