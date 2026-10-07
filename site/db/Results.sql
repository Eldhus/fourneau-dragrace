-- One result, as a worker posts it: replaced whole (the result, then its
-- rounds and open-loop steps), so a post repeated changes nothing.

-- name: set :exec
-- @param run_id : Str
-- @param class : Str
-- @param workload : Str
-- @param competitor : Str
-- @param valid : Bool
-- @param note : Str
-- @param median_rps : F64
-- @param median_p50_ms : F64
-- @param median_p95_ms : F64
-- @param median_p99_ms : F64
-- @param median_p999_ms : F64
INSERT INTO results (run_id, class, workload, competitor, valid, note, median_rps,
  median_p50_ms, median_p95_ms, median_p99_ms, median_p999_ms)
VALUES (:run_id, :class, :workload, :competitor, :valid, :note, :median_rps,
  :median_p50_ms, :median_p95_ms, :median_p99_ms, :median_p999_ms)
ON CONFLICT (run_id, class, workload, competitor) DO UPDATE SET valid = excluded.valid,
  note = excluded.note, median_rps = excluded.median_rps,
  median_p50_ms = excluded.median_p50_ms, median_p95_ms = excluded.median_p95_ms,
  median_p99_ms = excluded.median_p99_ms, median_p999_ms = excluded.median_p999_ms,
  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

-- name: clear_rounds :exec
-- @param run_id : Str
-- @param class : Str
-- @param workload : Str
-- @param competitor : Str
DELETE FROM rounds WHERE run_id = :run_id AND class = :class AND workload = :workload
  AND competitor = :competitor;

-- name: clear_steps :exec
-- @param run_id : Str
-- @param class : Str
-- @param workload : Str
-- @param competitor : Str
DELETE FROM open_steps WHERE run_id = :run_id AND class = :class AND workload = :workload
  AND competitor = :competitor;

-- name: add_round :exec
-- @param run_id : Str
-- @param class : Str
-- @param workload : Str
-- @param competitor : Str
-- @param round : I64
-- @param rps : F64
-- @param p50_ms : F64
-- @param p90_ms : F64
-- @param p95_ms : F64
-- @param p99_ms : F64
-- @param p999_ms : F64
-- @param p9999_ms : F64
-- @param mean_ms : F64
-- @param max_ms : F64
-- @param first_byte_p50_ms : F64
-- @param first_byte_p99_ms : F64
-- @param success_rate : F64
-- @param errors : I64
-- @param non_2xx : I64
-- @param rps_per_second_stddev : F64
-- @param connect_mean_ms : F64
-- @param bytes_per_response : F64
-- @param cpu_busy_pct : F64
-- @param cpu_user_pct : F64
-- @param cpu_system_pct : F64
-- @param cpu_irq_pct : F64
-- @param cpu_softirq_pct : F64
-- @param steal_pct : F64
-- @param loader_cpu_busy_pct : F64
-- @param rss_kib : I64
-- @param net_rx_mbps : F64
-- @param net_tx_mbps : F64
-- @param net_rx_pps : F64
-- @param net_tx_pps : F64
-- @param tcp_retransmits : I64
-- @param threads : I64
-- @param voluntary_switches : I64
-- @param involuntary_switches : I64
-- @param load_seconds : F64
-- @param seconds : F64
INSERT INTO rounds (run_id, class, workload, competitor, round, rps, p50_ms, p90_ms,
  p95_ms, p99_ms, p999_ms, p9999_ms, mean_ms, max_ms, first_byte_p50_ms,
  first_byte_p99_ms, success_rate, errors, non_2xx, rps_per_second_stddev,
  connect_mean_ms, bytes_per_response, cpu_busy_pct, cpu_user_pct, cpu_system_pct,
  cpu_irq_pct, cpu_softirq_pct, steal_pct, loader_cpu_busy_pct, rss_kib, net_rx_mbps,
  net_tx_mbps, net_rx_pps, net_tx_pps, tcp_retransmits, threads, voluntary_switches,
  involuntary_switches, load_seconds, seconds)
VALUES (:run_id, :class, :workload, :competitor, :round, :rps, :p50_ms, :p90_ms,
  :p95_ms, :p99_ms, :p999_ms, :p9999_ms, :mean_ms, :max_ms, :first_byte_p50_ms,
  :first_byte_p99_ms, :success_rate, :errors, :non_2xx, :rps_per_second_stddev,
  :connect_mean_ms, :bytes_per_response, :cpu_busy_pct, :cpu_user_pct, :cpu_system_pct,
  :cpu_irq_pct, :cpu_softirq_pct, :steal_pct, :loader_cpu_busy_pct, :rss_kib, :net_rx_mbps,
  :net_tx_mbps, :net_rx_pps, :net_tx_pps, :tcp_retransmits, :threads, :voluntary_switches,
  :involuntary_switches, :load_seconds, :seconds);

-- name: add_step :exec
-- @param run_id : Str
-- @param class : Str
-- @param workload : Str
-- @param competitor : Str
-- @param step : I64
-- @param share : F64
-- @param offered_rps : F64
-- @param achieved_rps : F64
-- @param p50_ms : F64
-- @param p90_ms : F64
-- @param p99_ms : F64
-- @param p999_ms : F64
-- @param errors : I64
-- @param non_2xx : I64
-- @param cpu_busy_pct : F64
-- @param loader_cpu_busy_pct : F64
-- @param net_rx_mbps : F64
-- @param net_tx_mbps : F64
INSERT INTO open_steps (run_id, class, workload, competitor, step, share, offered_rps,
  achieved_rps, p50_ms, p90_ms, p99_ms, p999_ms, errors, non_2xx, cpu_busy_pct,
  loader_cpu_busy_pct, net_rx_mbps, net_tx_mbps)
VALUES (:run_id, :class, :workload, :competitor, :step, :share, :offered_rps,
  :achieved_rps, :p50_ms, :p90_ms, :p99_ms, :p999_ms, :errors, :non_2xx, :cpu_busy_pct,
  :loader_cpu_busy_pct, :net_rx_mbps, :net_tx_mbps);
