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

HTTPS (`--tls-cert`, `--tls-key`; RACING.md, TLS): `axum::serve` has no
TLS, so as axum's `low-level-rustls` example: tokio-rustls (rustls, its
default aws-lc-rs crypto) accepting, hyper-util's HTTP/1.1-or-HTTP/2
builder serving the router, HTTP/2 by ALPN, TCP_NODELAY as on plain HTTP.
TLS 1.3, X25519, AES-128-GCM and ChaCha20 only (rustls follows the
client, and oha asks for AES-256 first), no session cache or tickets.

`/api/...` (conduit): sqlx's SQLite (bundled), as an axum team runs it:
WAL and `synchronous=NORMAL`, a pool of readers (twice the cores) and a
pool of one writer (SQLite writes one at a time; the pool queues them
rather than retrying on SQLITE_BUSY); serde for JSON, chrono for the
timestamps.
