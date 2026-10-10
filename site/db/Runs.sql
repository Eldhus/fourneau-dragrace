-- A run as the racer makes it, and ends it. Every write here is safe to
-- repeat: the racer retries a post whose answer it did not see.

-- name: add :exec
-- @param id : Str
-- @param request_id : Nullable(I64)
-- @param trigger : Str
-- @param status : Str
-- @param reason : Str
-- @param where_raced : Str
-- @param started_at : Str
-- @param worker_token : Nullable(Str)
INSERT INTO runs (id, request_id, trigger, status, reason, where_raced, started_at,
  finished_at, worker_token)
VALUES (:id, :request_id, :trigger, :status, :reason, :where_raced, :started_at,
  CASE WHEN :status IN ('skipped', 'refused') THEN :started_at END, :worker_token)
ON CONFLICT (id) DO NOTHING;

-- name: add_commit :exec
-- @param run_id : Str
-- @param repository : Str
-- @param commit_sha : Str
-- @param new : Bool
INSERT INTO run_commits (run_id, repository, commit_sha, new)
VALUES (:run_id, :repository, :commit_sha, :new)
ON CONFLICT DO NOTHING;

-- name: add_settings :exec
-- @param run_id : Str
-- @param seed : I64
-- @param region : Str
-- @param image : Str
-- @param port : I64
-- @param rounds : I64
-- @param warmup_seconds : I64
-- @param measure_seconds : I64
-- @param open_loop_shares : Str
-- @param open_loop_warmup_seconds : I64
-- @param open_loop_measure_seconds : I64
-- @param race_json : Str
-- @param versions_json : Str
INSERT INTO run_settings (run_id, seed, region, image, port, rounds, warmup_seconds,
  measure_seconds, open_loop_shares, open_loop_warmup_seconds,
  open_loop_measure_seconds, race_json, versions_json)
VALUES (:run_id, :seed, :region, :image, :port, :rounds, :warmup_seconds,
  :measure_seconds, :open_loop_shares, :open_loop_warmup_seconds,
  :open_loop_measure_seconds, :race_json, :versions_json)
ON CONFLICT DO NOTHING;

-- name: add_version :exec
-- @param run_id : Str
-- @param name : Str
-- @param version : Str
INSERT INTO run_versions (run_id, name, version) VALUES (:run_id, :name, :version)
ON CONFLICT DO NOTHING;

-- name: add_competitor :exec
-- @param run_id : Str
-- @param name : Str
-- @param position : I64
-- @param title : Str
-- @param language : Str
-- @param framework : Str
INSERT INTO run_competitors (run_id, name, position, title, language, framework)
VALUES (:run_id, :name, :position, :title, :language, :framework)
ON CONFLICT DO NOTHING;

-- name: add_workload :exec
-- @param run_id : Str
-- @param name : Str
-- @param position : I64
-- @param kind : Str
-- @param title : Str
-- @param summary : Str
-- @param method : Str
-- @param path : Str
-- @param body_bytes : I64
-- @param content_type : Str
-- @param connections : I64
-- @param keepalive : Bool
-- @param http2 : Bool
-- @param streams : I64
-- @param tls : Bool
-- @param section : Str
-- @param ladder : Bool
INSERT INTO run_workloads (run_id, name, position, kind, title, summary, method, path,
  body_bytes, content_type, connections, keepalive, http2, streams, tls, section, ladder)
VALUES (:run_id, :name, :position, :kind, :title, :summary, :method, :path,
  :body_bytes, :content_type, :connections, :keepalive, :http2, :streams, :tls, :section,
  :ladder)
ON CONFLICT DO NOTHING;

-- name: add_class :exec
-- @param run_id : Str
-- @param name : Str
-- @param position : I64
-- @param label : Str
-- @param title : Str
-- @param size : Str
-- @param loader_size : Str
INSERT INTO run_classes (run_id, name, position, label, title, size, loader_size)
VALUES (:run_id, :name, :position, :label, :title, :size, :loader_size)
ON CONFLICT DO NOTHING;

-- A run over: its status, its timing, and no more results taken.
-- name: end :exec
-- @param id : Str
-- @param status : Str
-- @param reason : Str
-- @param finished_at : Str
-- @param seconds : F64
-- @param build_seconds : F64
-- @param launch_seconds : F64
-- @param racing_seconds : F64
-- @param cost_usd : F64
UPDATE runs SET status = :status, reason = :reason, finished_at = :finished_at,
  worker_token = NULL, seconds = :seconds, build_seconds = :build_seconds,
  launch_seconds = :launch_seconds, racing_seconds = :racing_seconds, cost_usd = :cost_usd
WHERE id = :id;

-- name: add_droplet :exec
-- @param run_id : Str
-- @param position : I64
-- @param role : Str
-- @param class : Str
-- @param size : Str
-- @param price_hourly : F64
-- @param seconds : F64
-- @param cost_usd : F64
INSERT INTO droplets (run_id, position, role, class, size, price_hourly, seconds, cost_usd)
VALUES (:run_id, :position, :role, :class, :size, :price_hourly, :seconds, :cost_usd)
ON CONFLICT (run_id, position) DO UPDATE SET role = excluded.role, class = excluded.class,
  size = excluded.size, price_hourly = excluded.price_hourly, seconds = excluded.seconds,
  cost_usd = excluded.cost_usd;

-- Who may post results for a run: its worker token while it races.
-- name: access :one
-- @param id : Str
SELECT status, worker_token FROM runs WHERE id = :id;

-- name: set_class :exec
-- @param run_id : Str
-- @param class : Str
-- @param status : Str
-- @param reason : Str
-- @param seconds : F64
INSERT INTO class_status (run_id, class, status, reason, seconds)
VALUES (:run_id, :class, :status, :reason, :seconds)
ON CONFLICT (run_id, class) DO UPDATE SET status = excluded.status,
  reason = excluded.reason, seconds = excluded.seconds,
  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

-- name: set_machine :exec
-- @param run_id : Str
-- @param class : Str
-- @param role : Str
-- @param size : Str
-- @param cpu : Str
-- @param cpus : I64
-- @param kernel : Str
-- @param cpu_id : Str
-- @param memory_mib : I64
INSERT INTO machines (run_id, class, role, size, cpu, cpus, kernel, cpu_id, memory_mib)
VALUES (:run_id, :class, :role, :size, :cpu, :cpus, :kernel, :cpu_id, :memory_mib)
ON CONFLICT (run_id, class, role) DO UPDATE SET size = excluded.size, cpu = excluded.cpu,
  cpus = excluded.cpus, kernel = excluded.kernel, cpu_id = excluded.cpu_id,
  memory_mib = excluded.memory_mib;
