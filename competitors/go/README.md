# go

The baseline, as most teams would ship it: Go on its standard library. `net/http` with a
`ServeMux`, no framework, nothing tuned past what a Go team would set on day one.


## At a glance

| | |
|---|---|
| Language | Go 1.27.3 (`toolchain` in `go.mod`) |
| Server | `net/http`, the standard library |
| I/O | a goroutine per connection on the runtime's epoll netpoller; `GOMAXPROCS` left at all cores |
| Templates | `html/template`, parsed once at startup |
| Database | `database/sql` with `modernc.org/sqlite` (SQLite in pure Go) |
| HTTPS | crypto/tls; HTTP/2 by ALPN |
| Build | `go build -trimpath -o dragrace-go`, `CGO_ENABLED=0`, `GOAMD64=v3` (`competitor.json`) |
| Binary | static |


## The workloads

- **`GET /plaintext`** (also churn): `io.WriteString` of the body.
- **`POST /echo`**: up to 1 MiB (`http.MaxBytesReader`).
    - A body of known length is read straight into a pooled buffer (`sync.Pool`); `io.ReadAll` grew a fresh one each request.
    - +28% requests/s and half the p99, measured locally in three interleaved rounds (30-33k against 39-41k).
- **`GET /menu`**: `html/template`, executed per request; it escapes every value for its context.
- **`GET /sse`**: the signals with `encoding/json`, then each event written and flushed (`http.ResponseController`).
    - As Datastar's Go SDK does.
- **Conduit (`/api/...`)**: `database/sql`, as a Go team runs SQLite.
    - WAL, `synchronous=NORMAL`, a 5 s busy timeout.
    - A pool of readers (twice `GOMAXPROCS`) and one writer connection, writes in `BEGIN IMMEDIATE`.
    - SQLite writes one at a time; the pool queues them in Go rather than retrying on SQLITE_BUSY.
    - JSON with `encoding/json`.
- **HTTPS**: `ListenAndServeTLS`; TLS 1.3, X25519 (`CurvePreferences`), session tickets off.
    - Go picks AES-128-GCM itself.
    - On plain HTTP, HTTP/2 by prior knowledge (h2c) beside HTTP/1.1.


## Changed from the defaults

- `ReadHeaderTimeout` 10 s and `IdleTimeout` 30 s, as a server facing clients sets them.
- The echo buffer pool, above.


## Worth knowing

- `modernc.org/sqlite` keeps the binary static; `mattn/go-sqlite3` would need cgo.


## Tuning

Ideas welcome: GOGC/GOMEMLIMIT, PGO, a different mux. Say why ([CONTRIBUTING](../../CONTRIBUTING.md)).


## Links

- [net/http](https://pkg.go.dev/net/http)
- [modernc.org/sqlite](https://pkg.go.dev/modernc.org/sqlite)
