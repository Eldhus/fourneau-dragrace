-- The race page's live banner while a run races: the
-- run, and each class's step racing, its progress and name, the last
-- step's results, and the time left. A step is a competitor's round, or its climb of a
-- ladder (race.go, Step): each worker posts its class's plan as each step
-- begins (class_steps). Read every 1.618 s by each open race page's stream
-- (main.roc, race_live!).

-- The run racing now, if one is.
-- name: racing :one
SELECT id, started_at FROM runs WHERE status = 'racing' ORDER BY started_at DESC LIMIT 1;

-- Each class of a racing run: how it stands (racing, done or failed, and
-- why), its time, its steps, and the step racing (0 before the first; a
-- class whose worker posts no plan has none). A step's estimate is what
-- the same step took in the newest finished run before (to its next
-- step's start, the last to its class's end), else its plan's seconds.
-- Left: the step racing's estimate less its time so far (never below 0),
-- and every later step's. Elapsed: a class over, its own time; else the
-- run's (classes start together).
-- name: classes :many(32)
-- @param run_id : Str
-- @column status : Str
-- @column reason : Str
-- @column elapsed_seconds : F64
-- @column steps : I64
-- @column step : I64
-- @column competitor : Str
-- @column round : I64
-- @column rounds : I64
-- @column workload : Str
-- @column step_seconds : F64
-- @column step_estimate : F64
-- @column left_seconds : F64
WITH previous AS (
  SELECT id FROM runs WHERE status = 'finished'
    AND started_at < (SELECT started_at FROM runs WHERE id = :run_id)
  ORDER BY started_at DESC LIMIT 1
),
took AS (
  SELECT p.class, p.competitor, p.round, p.workload,
    (julianday(coalesce(
        (SELECT n.started_at FROM class_steps n
          WHERE n.run_id = p.run_id AND n.class = p.class AND n.step = p.step + 1),
        (SELECT s.updated_at FROM class_status s
          WHERE s.run_id = p.run_id AND s.class = p.class AND s.status = 'done')))
      - julianday(p.started_at)) * 86400.0 AS seconds
  FROM class_steps p WHERE p.run_id = (SELECT id FROM previous) AND p.started_at IS NOT NULL
),
steps AS (
  SELECT t.class, t.step, t.competitor, t.round, t.workload, t.started_at,
    coalesce((SELECT k.seconds FROM took k WHERE k.class = t.class AND k.competitor = t.competitor
        AND k.round = t.round AND k.workload = t.workload AND k.seconds > 0),
      t.planned_seconds) AS estimate
  FROM class_steps t WHERE t.run_id = :run_id
),
racing AS (
  SELECT s.*, (julianday('now') - julianday(s.started_at)) * 86400.0 AS age
  FROM steps s WHERE s.started_at IS NOT NULL AND s.step = (
    SELECT max(m.step) FROM steps m WHERE m.class = s.class AND m.started_at IS NOT NULL)
)
SELECT c.name AS class, c.label,
  coalesce(st.status, 'racing') AS status, coalesce(st.reason, '') AS reason,
  coalesce(CASE WHEN st.status IN ('done', 'failed') THEN st.seconds END,
    (julianday('now') - julianday((SELECT started_at FROM runs WHERE id = :run_id))) * 86400.0)
    AS elapsed_seconds,
  (SELECT count(*) FROM steps s WHERE s.class = c.name) AS steps,
  coalesce(r.step, 0) AS step,
  coalesce(r.competitor, '') AS competitor,
  coalesce(r.round, 0) AS round,
  coalesce((SELECT g.rounds FROM run_settings g WHERE g.run_id = c.run_id), 0) AS rounds,
  coalesce(w.title, r.workload, '') AS workload,
  coalesce(r.age, 0.0) AS step_seconds,
  coalesce(r.estimate, 0.0) AS step_estimate,
  coalesce(max(0.0, r.estimate - r.age), 0.0)
    + coalesce((SELECT sum(s.estimate) FROM steps s
        WHERE s.class = c.name AND s.step > coalesce(r.step, 0)), 0.0) AS left_seconds
FROM run_classes c
LEFT JOIN class_status st ON st.run_id = c.run_id AND st.class = c.name
LEFT JOIN racing r ON r.class = c.name
LEFT JOIN run_workloads w ON w.run_id = c.run_id AND w.name = r.workload
WHERE c.run_id = :run_id
ORDER BY c.position;

-- Each class's last step ended: the step before the one racing, or the
-- class over, its last begun. A row each result it measured, in the race's
-- order of workloads: a round's rate, or a ladder's highest achieved; 0
-- and not valid for a competitor that did not start or failed its checks
-- (its note says why).
-- name: ended :many(64)
-- @param run_id : Str
-- @column rounds : I64
-- @column valid : Bool
-- @column rps : F64
WITH begun AS (
  SELECT t.class, max(t.step) AS step FROM class_steps t
  WHERE t.run_id = :run_id AND t.started_at IS NOT NULL GROUP BY t.class
),
ended AS (
  SELECT t.class, t.competitor, t.round, t.workload FROM class_steps t
  JOIN begun b ON b.class = t.class
  WHERE t.run_id = :run_id AND t.step = b.step - (
    CASE WHEN EXISTS (SELECT 1 FROM class_status s WHERE s.run_id = :run_id
      AND s.class = t.class AND s.status IN ('done', 'failed')) THEN 0 ELSE 1 END)
)
SELECT e.class, e.competitor, e.round,
  (SELECT g.rounds FROM run_settings g WHERE g.run_id = :run_id) AS rounds, w.title AS workload, r.valid, r.note,
  coalesce(o.rps, (SELECT max(s.achieved_rps) FROM open_steps s WHERE s.run_id = r.run_id
      AND s.class = r.class AND s.workload = r.workload AND s.competitor = r.competitor), 0.0) AS rps
FROM ended e
JOIN results r ON r.run_id = :run_id AND r.class = e.class AND r.competitor = e.competitor
JOIN run_workloads w ON w.run_id = r.run_id AND w.name = r.workload
  AND ((e.workload = '' AND w.kind = 'closed') OR w.name = e.workload)
LEFT JOIN rounds o ON o.run_id = r.run_id AND o.class = r.class AND o.workload = r.workload
  AND o.competitor = r.competitor AND o.round = e.round
ORDER BY e.class, w.position;
