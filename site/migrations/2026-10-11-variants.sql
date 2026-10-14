-- 2026-10-11: a workload is a test in one variant (race.json: a test lists
-- its variants). run_workloads records the test each row is a
-- variant of (`test`), and its `section` is named for what it is, the
-- variant's `protocol` (the same values). Run once, before the site built
-- from this commit starts; with
-- `sqlite3 -bail`, so a failed statement stops before the old table goes.
--
-- roux opens only a database whose sqlite_schema rows are exactly what
-- schema.sql makes, so the table is made anew from schema.sql's text and
-- its rows copied (2026-10-10-sections.sql says why). Nothing references
-- it.
--
-- The tests of the races so far, by name: every name a race has posted
-- (13, checked on the live data). A name not among them would
-- be its own test, never a lost row.

BEGIN;

ALTER TABLE run_workloads RENAME TO old_run_workloads;

CREATE TABLE run_workloads (
  run_id TEXT NOT NULL REFERENCES runs (id),
  name TEXT NOT NULL,
  -- The test it is a variant of (race.json's workload): plaintext for
  -- plaintext, plaintext-h2 and plaintext-tls.
  test TEXT NOT NULL,
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
  -- HTTP/2 (its streams a connection; 0 for HTTP/1.1), over TLS or not.
  http2 INTEGER NOT NULL CHECK (http2 IN (0, 1)),
  streams INTEGER NOT NULL,
  tls INTEGER NOT NULL CHECK (tls IN (0, 1)),
  -- The variant's protocol: HTTP/1.1, h2c (HTTP/2 without TLS), or tls
  -- (the realistic deployment). The race page's sections are these.
  protocol TEXT NOT NULL CHECK (protocol IN ('http1', 'h2c', 'tls')),
  -- It climbed the open-loop ladder after the rounds.
  ladder INTEGER NOT NULL CHECK (ladder IN (0, 1)),
  PRIMARY KEY (run_id, name)
) STRICT, WITHOUT ROWID;

INSERT INTO run_workloads (run_id, name, test, position, kind, title, summary, method, path,
  body_bytes, content_type, connections, keepalive, http2, streams, tls, protocol, ladder)
SELECT w.run_id, w.name,
  coalesce((SELECT t.column2 FROM (VALUES
      ('plaintext', 'plaintext'), ('plaintext-h2', 'plaintext'), ('plaintext-tls', 'plaintext'),
      ('echo-4k', 'echo-4k'), ('echo-4k-tls', 'echo-4k'),
      ('templates', 'templates'), ('templates-tls', 'templates'),
      ('sse', 'sse'), ('sse-tls', 'sse'),
      ('churn', 'churn'), ('churn-tls', 'churn'),
      ('conduit', 'conduit'), ('conduit-tls', 'conduit')) AS t
    WHERE t.column1 = w.name), w.name),
  w.position, w.kind, w.title, w.summary, w.method, w.path,
  w.body_bytes, w.content_type, w.connections, w.keepalive, w.http2, w.streams, w.tls,
  w.section, w.ladder
FROM old_run_workloads w;

DROP TABLE old_run_workloads;

COMMIT;
