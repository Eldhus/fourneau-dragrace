//! The SSE workload: a Datastar action. Its signals come as JSON in the
//! `datastar` query parameter, percent-encoded; the answer is a stream of
//! Datastar events, a chunk each (RACING.md, the contract): the new count
//! as a signal, the count's element, then the log lines.

const std = @import("std");
const assert = std.debug.assert;

/// The longest `datastar` parameter read: Datastar sends every signal, so
/// a real app bounds it; ours has one.
pub const signals_bytes_max = 1024;
/// Parameters looked at in a query before giving up.
const parameters_max = 32;

pub const Signals = struct { count: u32 };

/// The signals in a request target's query, or null when it has none or
/// they are not what the action takes: a 400.
pub fn signals(target: []const u8, buffer: *[signals_bytes_max]u8) ?Signals {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var parameters = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    for (0..parameters_max) |_| {
        const parameter = parameters.next() orelse return null;
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        if (!std.mem.eql(u8, parameter[0..equals], "datastar")) continue;
        return parse(parameter[equals + 1 ..], buffer);
    }
    return null;
}

fn parse(encoded: []const u8, buffer: *[signals_bytes_max]u8) ?Signals {
    if (encoded.len > buffer.len) return null;
    const copy = buffer[0..encoded.len];
    @memcpy(copy, encoded);
    // In a query, `+` is a space (form encoding), as browsers send it.
    for (copy) |*byte| {
        if (byte.* == '+') byte.* = ' ';
    }
    const json = std.Uri.percentDecodeInPlace(copy);
    assert(json.len <= encoded.len);
    // Parsing a struct of numbers allocates only the scanner's nesting
    // stack: a few bytes, never more than this.
    var memory: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    return std.json.parseFromSliceLeaky(Signals, fixed.allocator(), json, .{
        // Datastar sends every signal the page has; the action reads one.
        .ignore_unknown_fields = true,
    }) catch null;
}

/// The events of one answer: the signal, the element, the log lines.
pub const log_lines = 8;
pub const events_count = 2 + log_lines;
/// The largest event, for the count's widest value (a u32 plus one).
pub const event_bytes_max = 128;

/// Event `index` of the answer for `count`.
pub fn write_event(writer: *std.Io.Writer, index: u32, count: u64) std.Io.Writer.Error!void {
    assert(index < events_count);
    assert(count <= @as(u64, std.math.maxInt(u32)) + 1);
    if (index == 0) {
        try writer.print("event: datastar-patch-signals\ndata: signals {{\"count\":{d}}}\n\n", .{
            count,
        });
    } else if (index == 1) {
        try writer.print(
            "event: datastar-patch-elements\ndata: elements <span id=\"count\">{d}</span>\n\n",
            .{count},
        );
    } else {
        try writer.print(
            "event: datastar-patch-elements\ndata: selector #log\ndata: mode append\n" ++
                "data: elements <li>Event {d} of {d}</li>\n\n",
            .{ index - 1, log_lines },
        );
    }
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "datastar: signals from the query" {
    var buffer: [signals_bytes_max]u8 = undefined;
    const good = "/sse?datastar=%7B%22count%22%3A41%7D";
    try testing.expectEqual(@as(u32, 41), signals(good, &buffer).?.count);
    const plus = "/sse?x=1&datastar=%7B+%22count%22%3A+7%2C+%22other%22%3Atrue%7D";
    try testing.expectEqual(@as(u32, 7), signals(plus, &buffer).?.count);
    const largest = "/sse?datastar=%7B%22count%22%3A4294967295%7D";
    try testing.expectEqual(@as(u32, 4294967295), signals(largest, &buffer).?.count);
}

test "datastar: signals refused" {
    var buffer: [signals_bytes_max]u8 = undefined;
    const refused = [_][]const u8{
        "/sse",
        "/sse?",
        "/sse?other=%7B%22count%22%3A41%7D",
        "/sse?datastar=",
        "/sse?datastar=%7B%7D", // no count
        "/sse?datastar=nope",
        "/sse?datastar=%7B%22count%22%3A-1%7D",
        "/sse?datastar=%7B%22count%22%3A4294967296%7D",
        "/sse?datastar=%7B%22count%22%3A1.5%7D",
    };
    for (refused) |target| {
        if (signals(target, &buffer) != null) {
            std.debug.print("accepted: {s}\n", .{target});
            return error.TestUnexpectedResult;
        }
    }
    // A number in quotes is a number to std.json (Go and serde refuse it):
    // the standard library's choice, kept, and pinned here.
    const quoted = "/sse?datastar=%7B%22count%22%3A%221%22%7D";
    try testing.expectEqual(@as(u32, 1), signals(quoted, &buffer).?.count);
    // Longer than the bound: refused before it is decoded.
    const prefix = "/sse?datastar=";
    var long: [prefix.len + signals_bytes_max + 3]u8 = undefined;
    @memcpy(long[0..prefix.len], prefix);
    for (long[prefix.len..], 0..) |*byte, index| byte.* = "%20"[index % 3];
    try testing.expect(signals(&long, &buffer) == null);
}

test "datastar: the events, and their bound" {
    var buffer: [event_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_event(&writer, 0, 42);
    try testing.expectEqualStrings(
        "event: datastar-patch-signals\ndata: signals {\"count\":42}\n\n",
        writer.buffered(),
    );
    writer = .fixed(&buffer);
    try write_event(&writer, events_count - 1, 42);
    try testing.expectEqualStrings(
        "event: datastar-patch-elements\ndata: selector #log\ndata: mode append\n" ++
            "data: elements <li>Event 8 of 8</li>\n\n",
        writer.buffered(),
    );
    // Every event fits the bound at the widest count.
    for (0..events_count) |index| {
        writer = .fixed(&buffer);
        try write_event(&writer, @intCast(index), @as(u64, std.math.maxInt(u32)) + 1);
    }
}
