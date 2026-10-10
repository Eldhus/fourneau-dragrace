# Go net/http

The standard library's server, as a Go team would ship it: `http.Server`
with a `ServeMux`, timeouts set, `CGO_ENABLED=0` (a static binary),
`GOMAXPROCS` left to the runtime (all cores). Pinned by the `toolchain` line
in `go.mod`.

Tuning ideas welcome: GOGC/GOMEMLIMIT, PGO, a different mux. Say why.

`GET /menu`: `html/template`, parsed once at startup, executed per request.

`GET /sse`: the signals with `encoding/json`, then each event written and
flushed (`http.ResponseController`), as Datastar's Go SDK does.

`POST /echo` reads a body of known length (Content-Length) straight into
a pooled buffer (`sync.Pool`), where `io.ReadAll` grew a fresh one every
request: +28% requests/s and half the p99, measured locally in three
interleaved rounds (2026-10-06: 30-33k against 39-41k).

HTTPS (`--tls-cert`, `--tls-key`; RACING.md, TLS): `ListenAndServeTLS`
with crypto/tls, HTTP/2 by ALPN; TLS 1.3, X25519 (`CurvePreferences`),
session tickets off. Go picks AES-128-GCM itself.

`/api/...` (conduit): `database/sql` with `modernc.org/sqlite` (SQLite in
pure Go, so the binary stays static; mattn/go-sqlite3 would need cgo), as
a Go team runs SQLite: WAL and `synchronous=NORMAL`, a pool of readers
(twice GOMAXPROCS), one writer connection (SQLite writes one at a time;
the pool queues them in Go rather than retrying on SQLITE_BUSY) with
`BEGIN IMMEDIATE`. JSON with `encoding/json`.
