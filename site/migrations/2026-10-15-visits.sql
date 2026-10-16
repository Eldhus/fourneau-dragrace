-- 2026-10-15: the pages' visits, counted. A new table, empty: nothing is
-- copied. Its text is schema.sql's, which roux compares.

BEGIN;

CREATE TABLE visits (
  day TEXT NOT NULL,
  path TEXT NOT NULL,
  referrer TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('person', 'bot')),
  count INTEGER NOT NULL,
  PRIMARY KEY (day, path, referrer, kind)
) STRICT, WITHOUT ROWID;

COMMIT;
