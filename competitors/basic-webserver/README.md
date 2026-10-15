# basic-webserver

Roc's reference web platform, as released: Roc on Rust.
[roc-lang/basic-webserver](https://github.com/roc-lang/basic-webserver) 0.17.0, written as its own
examples are, its limits raised only to fit the race's load.


## At a glance

| | |
|---|---|
| Language | Roc (the nightly 0.17.0 targets, which this race pins) |
| Server | basic-webserver 0.17.0, named by its bundle's URL (the name is its hash, so it is pinned) |
| I/O | a Rust host on hyper and tokio (epoll); each `respond!` runs on the host's handler pool |
| Templates | the platform's `Html` module |
| Database | the platform's `Sqlite`, its pool raised to 32 |
| HTTPS | none: the platform's server is plain HTTP |
| Build | `roc build main.roc` (Roc's default, `--opt=speed`) |
| Binary | static |


## The workloads

- **`GET /plaintext`** (also churn): a constant body.
- **`POST /echo`**: up to 1 MiB (`with_request_body_limit`).
- **`GET /menu`**: `Html`, which escapes every text value.
    - `Html.render` spells the doctype `<!DOCTYPE html>` and puts no line breaks between elements.
    - So the doctype is written by hand, and the race page's line breaks are text nodes.
- **`GET /sse`**: `Sse.unfold!`, one event per step, each `wake: Immediately`.
    - basic-webserver's Datastar example answers a finite action's ready events as one ordinary response.
    - The race's SSE workload is a stream, so this uses the stream.
- **Conduit (`/api/...`)**: the platform's `Sqlite`.
    - 32 connections (the handler pool's size), a 5 s busy timeout.
    - WAL, `synchronous=NORMAL`; writes in `BEGIN IMMEDIATE` transactions.
    - Its rows have no nullable fields yet, so the SQL turns a missing image or tag list into '' and says which (`has_image`).
    - The JSON is written by hand (`Conduit.roc`), each string through `Json.to_str`.
    - Comments are stamped by SQLite's clock.
- **HTTPS**: none. Its rustls is for its HTTP client, so it sits the TLS workloads out.


## Changed from the defaults

Only to fit the race's load, 256 connections each with a request in flight:

- `max_connections` 1,024 (default 256), as fourneau and roux allow.
- `max_queued_handlers` 1,024 (default 64): with 32 handlers running and 64 queued, the rest were answered 503.
- `sse.max_streams` 1,024 (default 256), so every connection may stream.
- The `Sqlite` pool 32 connections, the handler pool's size.


## Worth knowing

- It needs SIGPIPE ignored, as the race starts every server (systemd's `IgnoreSIGPIPE=yes`, its default).
    - The host leaves SIGPIPE at its default: its Rust runs under Roc's entry point, not Rust's `main`.
    - Started by hand from a shell, a client closing a connection mid-stream kills it (exit 141).
    - oha does that to every stream in flight at the end of each run.


## Tuning

Ideas welcome; the platform's own changes go to
[basic-webserver](https://github.com/roc-lang/basic-webserver). Say why
([CONTRIBUTING](../../CONTRIBUTING.md)).


## Links

- [basic-webserver](https://github.com/roc-lang/basic-webserver), [Roc](https://www.roc-lang.org)
