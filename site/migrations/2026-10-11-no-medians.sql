-- 2026-10-11: results keeps no summary of its rounds. The pages summarize
-- the rounds themselves (Data.Result: the best round's rate, the rounds'
-- median percentiles), so the medians the racer posted
-- go; every round stays. Run once, before
-- the site built from this commit starts.
--
-- roux opens only a database whose sqlite_schema rows are exactly what
-- schema.sql makes, so the table is made anew from schema.sql's text and
-- its rows copied (2026-10-10-sections.sql says why). rounds and
-- open_steps reference it: since SQLite 3.26 a rename rewrites their
-- REFERENCES to the new name (old_results, then dropped), changing their
-- text too. legacy_alter_table leaves them naming `results`, which the new
-- table is; foreign keys are off in the sqlite3 shell, so the drop checks
-- nothing (the rows they reference are all copied).

PRAGMA legacy_alter_table = ON;

BEGIN;

ALTER TABLE results RENAME TO old_results;

CREATE TABLE results (
  run_id TEXT NOT NULL REFERENCES runs (id),
  class TEXT NOT NULL,
  workload TEXT NOT NULL,
  competitor TEXT NOT NULL,
  valid INTEGER NOT NULL CHECK (valid IN (0, 1)),
  note TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  PRIMARY KEY (run_id, class, workload, competitor)
) STRICT, WITHOUT ROWID;

INSERT INTO results (run_id, class, workload, competitor, valid, note, updated_at)
SELECT run_id, class, workload, competitor, valid, note, updated_at FROM old_results;

DROP TABLE old_results;

COMMIT;
