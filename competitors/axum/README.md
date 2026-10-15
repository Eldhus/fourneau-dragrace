# axum

Rust's most used web framework, by the book: axum 0.8 on tokio's multi-threaded runtime, written as
axum's own docs and examples write it.


## At a glance

| | |
|---|---|
| Language | Rust 1.94.1 (`rust-toolchain.toml`) |
| Server | axum 0.8 on hyper; `axum::serve` |
| I/O | tokio's multi-threaded runtime: a worker per core, work stealing, epoll |
| Templates | askama 0.16, `templates/menu.html` compiled into the binary |
| Database | sqlx 0.8's SQLite (SQLite bundled) |
| HTTPS | tokio-rustls (rustls on aws-lc-rs); HTTP/2 by ALPN |
| Build | `cargo build --release --locked`: LTO, one codegen unit, x86-64-v3 (`.cargo/config.toml`) |
| Binary | dynamically linked against glibc |


## The workloads

- **`GET /plaintext`** (also churn): a `&'static str`.
- **`POST /echo`**: up to 1 MiB (`DefaultBodyLimit`), as `Bytes`.
- **`GET /menu`**: askama, rendered per request; it escapes every value.
- **`GET /sse`**: `Query` and `serde_json` for the signals, then axum's `Sse` over a stream of the ten events.
    - hyper writes ready events together.
- **Conduit (`/api/...`)**: sqlx, as an axum team runs SQLite.
    - WAL, `synchronous=NORMAL`, a 5 s busy timeout.
    - A pool of readers (twice the cores) and a pool of one writer.
    - SQLite writes one at a time; the pool queues them rather than retrying on SQLITE_BUSY.
    - serde for JSON, chrono for the timestamps.
- **HTTPS**: `axum::serve` has no TLS, so as axum's `low-level-rustls` example.
    - tokio-rustls accepts; hyper-util's HTTP/1.1-or-HTTP/2 builder serves the router.
    - TLS 1.3, X25519, AES-128-GCM and ChaCha20 only; no session cache or tickets.
    - rustls follows the client's order, and oha asks for AES-256 first, so AES-256 is left out.
    - On plain HTTP, HTTP/2 by prior knowledge beside HTTP/1.1 (axum's `http2` feature).


## Changed from the defaults

- TCP_NODELAY on accepted sockets, plain and TLS, the way axum's docs show.
    - Without it, pipelined responses wait on delayed ACKs.
- The release profile: LTO and one codegen unit.
- x86-64-v3 with AES and PCLMUL, for Rust and for the C in SQLite and aws-lc (`.cargo/config.toml`).


## Tuning

Ideas welcome: allocators (mimalloc, jemalloc), runtime settings, hyper options. Say why
([CONTRIBUTING](../../CONTRIBUTING.md)).


## Links

- [axum](https://github.com/tokio-rs/axum), [tokio](https://tokio.rs), [sqlx](https://github.com/launchbadge/sqlx), [askama](https://github.com/askama-rs/askama)
