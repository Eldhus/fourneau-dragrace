# fourneau (Zig)

fourneau with a Zig handler: io_uring, a fiber per connection, one shard per
core sharing nothing, built ReleaseSafe (assertions on: how fourneau ships).
Built against the fourneau checkout beside this repository, so the nightly
races fourneau's newest commit.

`GET /menu`: `src/template.zig`, a template split into parts and holes at comptime, rendered into the connection's scratch memory.
Pure Zig, about 80 lines; it shares no code with rocstache. That makes
it roux's ceiling: once roux's rocstache matches it, there is little
left to gain in the Roc integration. On 2026-10-10 they were even
(templates, smallest class: 44,219 against roux's 43,145 req/s, inside
roux's 12.8% spread between rounds).

`GET /sse`: the signals with `std.json` (`src/datastar.zig`, bounded,
with its tests: `zig build test`), then fourneau's streamed responses,
each event made into the connection's scratch memory and sent as a
chunk; the ten wait in the send buffer and leave in one write. std.json
takes a number in quotes (`"1"`) for a `u32`, where Go and serde refuse
it: the standard library's choice, kept and pinned in a test.

`/api/...` (conduit): SQLite as a Zig programmer would add it to a
fourneau app: the amalgamation (roux's vendored copy, beside this
repository) compiled in, a connection per shard with its statements
prepared once, WAL and `synchronous=NORMAL`, writes in `BEGIN IMMEDIATE`
with a 5 s busy timeout, the JSON written with std's string escaping into
the connection's scratch memory. SQLite's own VFS blocks the shard's
thread on a read that misses the page cache (roux's VFS yields instead).
Every statement is reset as soon as its rows are read: one left on a row
holds its snapshot, and the connection's next write failed with
SQLITE_BUSY_SNAPSHOT, which no busy timeout waits out (found under the
race's load, 2026-10-07).
