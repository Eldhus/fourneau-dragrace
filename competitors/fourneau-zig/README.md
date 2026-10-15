# fourneau-zig

The server this race exists to measure, bare: Zig handlers on
[fourneau](https://github.com/Eldhus/fourneau), with nothing between them. Built against the
fourneau checkout beside this repository, so each nightly races fourneau's newest commit.


## At a glance

| | |
|---|---|
| Language | Zig 0.17.0 (the race's pin) |
| Server | fourneau, from the checkout beside this repository |
| I/O | io_uring (`std.Io.Evented`): a fiber per connection, one shard per core, sharing nothing |
| Templates | pure Zig, no engine (`src/template.zig`): the floor |
| Database | the SQLite amalgamation (roux's vendored copy), a connection per shard |
| HTTPS | fourneau's own: tls.zig's handshake, then kTLS; HTTP/2 by ALPN |
| Build | `zig build`: ReleaseSafe, x86-64-v3 with AES and PCLMUL (build.zig's defaults) |
| Binary | dynamically linked against glibc (SQLite's C) |


## The workloads

- **`GET /plaintext`** (also churn): a constant body.
- **`POST /echo`**: the body read into the connection's scratch memory, 64 KiB; past that, 413.
- **`GET /menu`**: a template split into parts and holes at comptime, rendered into the connection's scratch memory.
    - About 80 lines of Zig, no code shared with rocstache.
    - So it is the floor roux's rocstache is measured against: the least a page can cost on fourneau.
- **`GET /sse`**: the signals with `std.json` (`src/datastar.zig`, bounded, tested by `zig build test`).
    - Then fourneau's streamed responses: each event made in scratch memory and sent as a chunk.
    - The ten wait in the send buffer and leave in one write.
- **Conduit (`/api/...`)**: SQLite as a Zig programmer would add it to a fourneau app.
    - A connection per shard, its statements prepared once.
    - WAL, `synchronous=NORMAL`; writes in `BEGIN IMMEDIATE` with a 5 s busy timeout.
    - The JSON written with std's string escaping into scratch memory.
- **HTTPS**: `fourneau.https.context`, as roux and fourneau-static use it.
    - TLS 1.3 on the connection's fiber, then the keys to the kernel (kTLS).
    - No session resumption: fourneau has none.


## Changed from the defaults

- None: build.zig's defaults are the race's.


## Worth knowing

- SQLite's own VFS blocks the shard's thread on a read that misses the page cache; roux's VFS yields instead.
- Every statement is reset as soon as its rows are read.
    - One left on a row holds its snapshot, and the next write fails with SQLITE_BUSY_SNAPSHOT.
    - No busy timeout waits that out.
- std.json takes a number in quotes (`"1"`) for a `u32`, where Go and serde refuse it.
    - The standard library's choice, kept and pinned in a test.


## Tuning

Ideas welcome; fourneau's own changes go to [fourneau](https://github.com/Eldhus/fourneau). Say why
([CONTRIBUTING](../../CONTRIBUTING.md)).


## Links

- [fourneau](https://github.com/Eldhus/fourneau), [SQLite](https://sqlite.org)
