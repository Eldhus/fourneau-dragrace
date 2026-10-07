# axum on tokio

axum 0.8 on tokio's multi-threaded runtime (a worker per core), release
profile with LTO and one codegen unit. TCP_NODELAY is set on accepted
sockets the way axum's own docs show; without it, pipelined responses wait
on delayed ACKs. Pinned by `rust-toolchain.toml` and `Cargo.lock`.

Tuning ideas welcome: allocators (mimalloc, jemalloc), runtime settings,
hyper options. Say why.

`GET /menu`: askama 0.16, `templates/menu.html` compiled into the binary.

`GET /sse`: `Query` and `serde_json` for the signals, then axum's `Sse`
over a stream of the ten events; hyper writes ready events together.

`/api/...` (conduit): sqlx's SQLite (bundled), as an axum team runs it:
WAL and `synchronous=NORMAL`, a pool of readers (twice the cores) and a
pool of one writer (SQLite writes one at a time; the pool queues them
rather than retrying on SQLITE_BUSY); serde for JSON, chrono for the
timestamps.
