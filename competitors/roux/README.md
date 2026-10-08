# roux (Roc on fourneau)

A Roc app on roux, the Roc platform built on fourneau: the handler is
Roc, compiled with the server into one static binary (musl). The host
listens on `ROUX_ADDRESS`; the app names port 8080. Built with the pinned Roc
nightly against the roux and fourneau checkouts beside this repository.

`GET /menu`: `Menu.rocstache`, compiled to machine code by Zig and linked
into the app by `roux build`; `Menu.roc` is its contract (the record it
reads, declared in the template since the prices are numbers),
generated and committed. The templates object is ReleaseSafe, as roux's
host.

`GET /sse`: roux's `Url.query_value` and Roc's `Json.parse` for the
signals, then roux's `Sse` effects, an event a `send!`, on the request's
fiber.

`/api/...` (conduit): roux's SQLite. The statements are in
`db/Conduit.sql`, typed by roux-db against the workload's schema (the
build copies `workloads/conduit/schema.sql` to `db/schema.sql`), and
prepared at start: reads on the request's shard, writes on the one writer,
`synchronous: Normal`. The JSON is written by hand (`Conduit.roc`): the
spec's names are camelCase and an image may be null, which Roc's derived
encoder does not write; every string goes through `Json.to_str`. Comments
are stamped by SQLite's clock (`strftime`), as roux has no clock of its
own.
