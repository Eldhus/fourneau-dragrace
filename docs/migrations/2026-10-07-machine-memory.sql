-- 2026-10-07: machines gain memory_mib (MemTotal, MiB; 0 for older runs),
-- and the classes are named by their size on the tabs.
--
-- roux opens only a database holding exactly the schema it was built with,
-- and ALTER TABLE would not write the schema's text the way schema.sql
-- does, so this makes a new database from the new schema and copies every
-- row into it (as the CPU pin's removal did, DIARY 2026-10-07). As cook on
-- the site host, with the site stopped (SECURITY.md, "Migrations and
-- copies"), in /var/lib/dragrace-site, schema.sql being site/db/schema.sql
-- of the build that adds memory_mib:
--
--   sudo -u site sqlite3 site-new.db < schema.sql
--   sudo -u site sqlite3 site-new.db < 2026-10-07-machine-memory.sql
--   sudo -u site mv site.db site-old.db   # kept until the new one serves
--   sudo -u site rm -f site.db-wal site.db-shm
--   sudo -u site mv site-new.db site.db
--
-- Tested on a copy in the old schema (DIARY 2026-10-07): every count the
-- same, integrity and foreign keys ok, the new site serving every page.

ATTACH DATABASE 'site.db' AS old;

BEGIN;
INSERT INTO requests SELECT * FROM old.requests;
INSERT INTO runs SELECT * FROM old.runs;
INSERT INTO run_commits SELECT * FROM old.run_commits;
INSERT INTO run_settings SELECT * FROM old.run_settings;
INSERT INTO run_versions SELECT * FROM old.run_versions;
INSERT INTO run_competitors SELECT * FROM old.run_competitors;
INSERT INTO run_workloads SELECT * FROM old.run_workloads;
INSERT INTO run_classes SELECT * FROM old.run_classes;
INSERT INTO class_status SELECT * FROM old.class_status;
INSERT INTO machines (run_id, class, role, size, cpu, cpus, kernel, cpu_id, memory_mib)
  SELECT run_id, class, role, size, cpu, cpus, kernel, cpu_id, 0 FROM old.machines;
INSERT INTO droplets SELECT * FROM old.droplets;
INSERT INTO results SELECT * FROM old.results;
INSERT INTO rounds SELECT * FROM old.rounds;
INSERT INTO open_steps SELECT * FROM old.open_steps;
INSERT INTO open_step_parts SELECT * FROM old.open_step_parts;
INSERT INTO heads SELECT * FROM old.heads;

-- The tabs name a class by its size now (race.json); the page's tabs come
-- from the newest run, so its older runs are named the same way.
UPDATE run_classes SET label = '512MB/1vCPU' WHERE name = 'smallest';
UPDATE run_classes SET label = '4GB/2vCPU' WHERE name = 'dedicated-2';
COMMIT;

DETACH DATABASE old;
