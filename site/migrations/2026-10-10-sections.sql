-- 2026-10-10: workloads carry how they were sent (HTTP/2, its streams,
-- TLS), the race page's section and whether they climbed the ladder;
-- run_settings loses open_loop_workload (a race now has a ladder per
-- workload). Run once, as SECURITY.md (Migrations) says, before the site
-- built from this commit starts.
--
-- roux opens only a database whose sqlite_schema rows are exactly what
-- schema.sql makes, so each table is made anew from schema.sql's text
-- (ALTER TABLE ADD COLUMN would rewrite the CREATE differently) and its
-- rows copied. Nothing references either table.

BEGIN;

ALTER TABLE run_workloads RENAME TO old_run_workloads;

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
  -- HTTP/2 (its streams a connection; 0 for HTTP/1.1), over TLS or not.
  http2 INTEGER NOT NULL CHECK (http2 IN (0, 1)),
  streams INTEGER NOT NULL,
  tls INTEGER NOT NULL CHECK (tls IN (0, 1)),
  -- Where the race page shows it: HTTP/1.1, h2c (HTTP/2 without TLS,
  -- beside plaintext), or tls (the realistic deployment).
  section TEXT NOT NULL CHECK (section IN ('http1', 'h2c', 'tls')),
  -- It climbed the open-loop ladder after the rounds.
  ladder INTEGER NOT NULL CHECK (ladder IN (0, 1)),
  PRIMARY KEY (run_id, name)
) STRICT, WITHOUT ROWID;

-- Every race so far was HTTP/1.1 but plaintext-h2 (h2c, 8 streams), and
-- climbed one ladder, run_settings' open_loop_workload.
INSERT INTO run_workloads (run_id, name, position, kind, title, summary, method, path,
  body_bytes, content_type, connections, keepalive, http2, streams, tls, section, ladder)
SELECT w.run_id, w.name, w.position, w.kind, w.title, w.summary, w.method, w.path,
  w.body_bytes, w.content_type, w.connections, w.keepalive,
  w.name = 'plaintext-h2', CASE WHEN w.name = 'plaintext-h2' THEN 8 ELSE 0 END, 0,
  CASE WHEN w.name = 'plaintext-h2' THEN 'h2c' ELSE 'http1' END,
  coalesce((SELECT s.open_loop_workload = w.name FROM run_settings s
    WHERE s.run_id = w.run_id), 0)
FROM old_run_workloads w;

DROP TABLE old_run_workloads;

ALTER TABLE run_settings RENAME TO old_run_settings;

CREATE TABLE run_settings (
  run_id TEXT PRIMARY KEY REFERENCES runs (id),
  seed INTEGER NOT NULL,
  region TEXT NOT NULL,
  image TEXT NOT NULL,
  port INTEGER NOT NULL,
  rounds INTEGER NOT NULL,
  warmup_seconds INTEGER NOT NULL,
  measure_seconds INTEGER NOT NULL,
  -- A JSON array of numbers: the shares of the closed-loop median offered
  -- by each ladder (run_workloads.ladder).
  open_loop_shares TEXT NOT NULL,
  open_loop_warmup_seconds INTEGER NOT NULL,
  open_loop_measure_seconds INTEGER NOT NULL,
  race_json TEXT NOT NULL,
  versions_json TEXT NOT NULL
) STRICT;

INSERT INTO run_settings (run_id, seed, region, image, port, rounds, warmup_seconds,
  measure_seconds, open_loop_shares, open_loop_warmup_seconds, open_loop_measure_seconds,
  race_json, versions_json)
SELECT run_id, seed, region, image, port, rounds, warmup_seconds, measure_seconds,
  open_loop_shares, open_loop_warmup_seconds, open_loop_measure_seconds, race_json,
  versions_json
FROM old_run_settings;

DROP TABLE old_run_settings;

COMMIT;
