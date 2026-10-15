# roux

Roc on fourneau: a Roc app on [roux](https://github.com/Eldhus/roux), the Roc platform whose host
is fourneau. The handler is Roc, compiled with the server into one static binary. The gap to
fourneau-zig is what Roc and roux cost.


## At a glance

| | |
|---|---|
| Language | Roc (roux's pinned nightly) |
| Server | roux, from the checkout beside this repository, on fourneau |
| I/O | fourneau: io_uring, a fiber per connection, one shard per core |
| Templates | rocstache: Roc-typed, compiled to bytecode |
| Database | roux's SQLite: statements typed by roux-db, prepared at start |
| HTTPS | roux's own (fourneau's TLS, then kTLS); HTTP/2 by ALPN |
| Build | `roux build --roc=roc main.roc`: Roc `--opt=speed`, host ReleaseSafe, x86-64-v3 |
| Binary | static (musl) |


## The workloads

- **`GET /plaintext`** (also churn): `Server.text`.
- **`POST /echo`**: `Server.read_body!`, up to 1 MiB.
- **`GET /menu`**: `templates/Menu.rocstache`, compiled to bytecode by `roux build`.
    - Run by the host's template VM as the response is sent; the Roc handler only returns the record.
    - `templates/Menu.roc` is its contract, generated and committed: the record the template reads.
    - fourneau-zig's template is pure Zig, so it is the floor this one is measured against.
- **`GET /sse`**: roux's `Url.query_value` and Roc's `Json.parse` for the signals.
    - Then roux's `Sse` effects, an event a `send!`, on the request's fiber.
- **Conduit (`/api/...`)**: roux's SQLite.
    - The statements are in `db/Conduit.sql`, typed by roux-db (which `roux build` runs).
    - Against the workload's schema: `db/schema.sql`, a link to `workloads/conduit/schema.sql`.
    - Reads on the request's shard, writes on the one writer, `synchronous: Normal`.
    - The JSON is written by hand (`Conduit.roc`): the spec's names are camelCase and an image may be null.
        - Roc's derived encoder writes neither; every string goes through `Json.to_str`.
    - Comments are stamped by SQLite's clock (`strftime`), as roux has no clock of its own.
- **HTTPS**: as a roux app serves browsers, with no proxy.


## Changed from the defaults

- None.


## Tuning

Ideas welcome; roux's own changes go to [roux](https://github.com/Eldhus/roux). Say why
([CONTRIBUTING](../../CONTRIBUTING.md)).


## Links

- [roux](https://github.com/Eldhus/roux), [fourneau](https://github.com/Eldhus/fourneau), [Roc](https://www.roc-lang.org)
