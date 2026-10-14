-- The race page's live banner while a run races: the
-- run, its newest results, and each class's progress and time left,
-- estimated from the newest finished run before it. Read every 1.618 s by
-- each open race page's stream (main.roc, race_live!).

-- The run racing now, if one is.
-- name: racing :one
SELECT id, started_at FROM runs WHERE status = 'racing' ORDER BY started_at DESC LIMIT 1;

-- Each class's newest result: what landed, and its best rate (the best
-- round's, or the ladder's highest rate achieved). One a class, under its
-- bar (three were cut off on a phone; each
-- scrolls instead).
-- name: newest :many(32)
-- @param run_id : Str
-- @column workload : Str
-- @column valid : Bool
-- @column best_rps : F64
SELECT r.class, coalesce(w.title, r.workload) AS workload, r.competitor, r.valid,
  coalesce((SELECT max(o.rps) FROM rounds o WHERE o.run_id = r.run_id AND o.class = r.class
      AND o.workload = r.workload AND o.competitor = r.competitor),
    (SELECT max(s.achieved_rps) FROM open_steps s WHERE s.run_id = r.run_id AND s.class = r.class
      AND s.workload = r.workload AND s.competitor = r.competitor), 0.0) AS best_rps
FROM (SELECT x.*, row_number() OVER (PARTITION BY x.class
        ORDER BY x.updated_at DESC, x.workload, x.competitor DESC) AS n
      FROM results x WHERE x.run_id = :run_id) AS r
LEFT JOIN run_workloads w ON w.run_id = r.run_id AND w.name = r.workload
WHERE r.n = 1
ORDER BY r.class;

-- Each class of a racing run: results in, results the previous run had
-- (0 for a class it did not race), and the seconds left. Each result of
-- the previous run weighs what it measured (its rounds' seconds and
-- warmups, a mixed workload's steps at their length); the class's time then,
-- shared by weight, is what each test takes. Left: the tests not in yet,
-- less the time since the class's last result (the test in progress).
-- Elapsed: a class over, its own time; else the run's (classes start
-- together).
-- During a race a result's `updated_at` is when it landed (the racer posts
-- them all again at the end).
-- name: progress :many(32)
-- @param run_id : Str
-- @column done : I64
-- @column expected : I64
-- @column left_seconds : F64
-- @column over : Bool
-- @column elapsed_seconds : F64
WITH previous AS (
  SELECT id FROM runs WHERE status = 'finished'
    AND started_at < (SELECT started_at FROM runs WHERE id = :run_id)
  ORDER BY started_at DESC LIMIT 1
),
settings AS (
  SELECT s.* FROM run_settings s WHERE s.run_id = (SELECT id FROM previous)
),
weights AS (
  SELECT r.class, r.workload, r.competitor,
    coalesce((SELECT sum(o.seconds) FROM rounds o WHERE o.run_id = r.run_id AND o.class = r.class
        AND o.workload = r.workload AND o.competitor = r.competitor), 0.0)
    + (SELECT count(*) FROM rounds o WHERE o.run_id = r.run_id AND o.class = r.class
        AND o.workload = r.workload AND o.competitor = r.competitor)
      * (SELECT warmup_seconds FROM settings)
    + (SELECT count(*) FROM open_steps s WHERE s.run_id = r.run_id AND s.class = r.class
        AND s.workload = r.workload AND s.competitor = r.competitor)
      * coalesce((SELECT json_extract(d.value, '$.mixed.warmup_seconds')
            + json_extract(d.value, '$.mixed.measure_seconds')
          FROM settings, json_each(settings.race_json, '$.workloads') AS d, run_workloads w
          WHERE w.run_id = r.run_id AND w.name = r.workload
            AND json_extract(d.value, '$.name') = w.test), 0) AS weight
  FROM results r WHERE r.run_id = (SELECT id FROM previous)
)
SELECT c.name AS class, c.label,
  (SELECT count(*) FROM results x WHERE x.run_id = :run_id AND x.class = c.name) AS done,
  (SELECT count(*) FROM weights w WHERE w.class = c.name) AS expected,
  coalesce((SELECT status IN ('done', 'failed') FROM class_status s
    WHERE s.run_id = :run_id AND s.class = c.name), 0) AS over,
  coalesce((SELECT s.seconds FROM class_status s WHERE s.run_id = :run_id AND s.class = c.name
      AND s.status IN ('done', 'failed')),
    (julianday('now') - julianday((SELECT started_at FROM runs WHERE id = :run_id))) * 86400.0) AS elapsed_seconds,
  coalesce(max(0.0,
    (SELECT s.seconds FROM class_status s WHERE s.run_id = (SELECT id FROM previous) AND s.class = c.name)
    * (SELECT sum(w.weight) FROM weights w WHERE w.class = c.name AND NOT EXISTS (
        SELECT 1 FROM results x WHERE x.run_id = :run_id AND x.class = w.class
          AND x.workload = w.workload AND x.competitor = w.competitor))
    / (SELECT sum(w.weight) FROM weights w WHERE w.class = c.name)
    - (julianday('now') - julianday(coalesce(
        (SELECT max(x.updated_at) FROM results x WHERE x.run_id = :run_id AND x.class = c.name),
        (SELECT started_at FROM runs WHERE id = :run_id)))) * 86400.0), 0.0) AS left_seconds
FROM run_classes c WHERE c.run_id = :run_id ORDER BY c.position;
