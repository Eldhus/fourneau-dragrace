# basic-webserver (Roc)

Roc's own web platform, [roc-lang/basic-webserver](https://github.com/roc-lang/basic-webserver),
as released: the app names the 0.17.0 bundle by its URL (the name is the
bundle's hash, so it is pinned), and 0.17.0 targets the Roc nightly this
race pins. Its host is Rust, on hyper and tokio; each `respond!` runs on
the host's handler pool. One static binary.

Changed from the defaults, only to fit the race's load (256 connections,
each with a request in flight):

- `max_connections` 1,024 (default 256), as fourneau and roux allow;
- `max_queued_handlers` 1,024 (default 64): with 32 handlers running and
  64 queued, the rest of the 256 requests were answered 503;
- `sse.max_streams` 1,024 (default 256), so every connection may stream.

`GET /menu`: the platform's `Html` module (it escapes every text value).
`Html.render` spells the doctype `<!DOCTYPE html>` and puts no line breaks
between elements, so the doctype is written by hand and the race page's
line breaks are text nodes.

`GET /sse`: `Sse.unfold!`, one event per step, each `wake: Immediately`.
basic-webserver's own Datastar example answers a finite action whose
events are all ready as one ordinary response; the race's SSE workload is
a stream, so this uses the stream.

Address and port come from `DRAGRACE_ADDRESS` and `DRAGRACE_PORT`.

Started with SIGPIPE ignored (`trap '' PIPE; exec`), as systemd starts
every service (`IgnoreSIGPIPE=yes`, its default). The host leaves SIGPIPE
at its default: its Rust code runs under Roc's entry point, not Rust's
`main`, which is what ignores it in a Rust program. So a client that
closes a connection while an SSE stream is being written kills the
server (exit 141): oha does that to every stream in flight at the end of
each run, and the third 5-second run killed it (2026-10-06). To report
upstream; then this wrapper goes.
