# go

The baseline, as most teams would ship it: Go on its standard library. `net/http` with a
`ServeMux`, no framework, nothing tuned past what a Go team would set on day one.


## At a glance

| | |
|---|---|
| Language | Go 1.27.3 (`toolchain` in `go.mod`) |
| Server | `net/http`, the standard library |
| I/O | a goroutine per connection on the runtime's epoll netpoller; `GOMAXPROCS` left at all cores |
| Templates | [templ](https://templ.guide) 0.3.1100, `catalog.templ` compiled to Go (`catalog_templ.go`, committed) |
| Database | `database/sql` with `modernc.org/sqlite` (SQLite in pure Go) |
| HTTPS | crypto/tls; HTTP/2 by ALPN |
| Build | `go build -trimpath -o dragrace-go`, `CGO_ENABLED=0`, `GOAMD64=v3` (`competitor.json`) |
| Binary | static |


## The workloads

- **`GET /plaintext`** (also churn): `io.WriteString` of the body.
- **`POST /echo`**: up to 1 MiB (`http.MaxBytesReader`).
    - A body of known length is read straight into a pooled buffer (`sync.Pool`); `io.ReadAll` grew a fresh one each request.
    - +28% requests/s and half the p99, measured locally in three interleaved rounds (30-33k against 39-41k).
- **`GET /catalog`**: templ, rendered per request (`catalog.templ`, its data and formatters in `catalog.go`, plain Go functions called from the template); it escapes every value.
    - Until 2026-11-03 it was `html/template`, which calls its escaper by reflection on every action, thousands on this page: 1.5 ms a render, 500 requests a second where the others do ten thousand.
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
- A 5 s deadline on each Conduit request's database work, as the contract asks.
    - `database/sql` alone waits for a pooled connection as long as the client stays.


## Worth knowing

- `modernc.org/sqlite` keeps the binary static; `mattn/go-sqlite3` would need cgo.
- templ is a generator: `go tool templ generate` turns each `.templ` into a `_templ.go`, which is
  committed, so the race's `go build` needs no generator. Its version is pinned twice in `go.mod`,
  the library (`require`) and the generator (`tool`), kept equal; to move them,
  `go get github.com/a-h/templ@vX && go get -tool github.com/a-h/templ/cmd/templ@vX`, then
  regenerate and `go mod tidy`. `go tool templ fmt .` formats the templates.
- The reference page sets one thing templ does not do by itself: templ writes no line break
  between elements, so each of the reference's is a `{ "\n" }` in the template. Everything else
  is templ as its guide shows it: elements, `if`, `for`, `{ value }` escaped, a `class` from an
  expression and a `templ.KV`.
    - Until 2026-11-04 the page left its `<tr>` and `<td>` open, which templ cannot write (it
      closes every element), so each cell was a small component; those components were most of
      the cost then (12,400 allocations a page against 3,700 with the tags closed). The page
      closes its tags now.
    - What it costs now (2026-11-03, locally, `perf stat` on the server): 3.07M instructions a
      request, against axum's 0.70M and fourneau-zig's 0.51M on the same page; html/template did
      14.4M on the old one. The profile is spread thin: the allocator and the GC, `fmt.Sprintf`
      in the formatters, templ's per-value writes and its buffer pool, the escaper.


## Tuning

Ideas welcome: GOGC/GOMEMLIMIT, PGO, a different mux. Say why ([CONTRIBUTING](../../CONTRIBUTING.md)).


## Links

- [net/http](https://pkg.go.dev/net/http)
- [templ](https://templ.guide), [a-h/templ](https://github.com/a-h/templ)
- [modernc.org/sqlite](https://pkg.go.dev/modernc.org/sqlite)
