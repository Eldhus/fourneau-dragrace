-- 2026-10-14: each class's plan, a row a step, for the live banner's bar
-- of the step racing. A new table, empty: nothing is copied.
-- Its text is schema.sql's, which roux compares.

BEGIN;

CREATE TABLE class_steps (
  run_id TEXT NOT NULL REFERENCES runs (id),
  class TEXT NOT NULL,
  step INTEGER NOT NULL,
  competitor TEXT NOT NULL,
  round INTEGER NOT NULL,
  workload TEXT NOT NULL,
  planned_seconds REAL NOT NULL,
  started_at TEXT,
  PRIMARY KEY (run_id, class, step)
) STRICT, WITHOUT ROWID;

COMMIT;
