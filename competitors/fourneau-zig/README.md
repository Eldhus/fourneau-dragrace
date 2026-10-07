# fourneau (Zig)

fourneau with a Zig handler: io_uring, a fiber per connection, one shard per
core sharing nothing, built ReleaseSafe (assertions on: how fourneau ships).
Built against the fourneau checkout beside this repository, so the nightly
races fourneau's newest commit.

`GET /menu`: `src/template.zig`, a template split into parts and holes at comptime, rendered into the connection's scratch memory.

`GET /sse`: the signals with `std.json` (`src/datastar.zig`, bounded,
with its tests: `zig build test`), then fourneau's streamed responses,
each event made into the connection's scratch memory and sent as a
chunk; the ten wait in the send buffer and leave in one write. std.json
takes a number in quotes (`"1"`) for a `u32`, where Go and serde refuse
it: the standard library's choice, kept and pinned in a test.
