//! A template compiled at comptime, for the templates workload: the source
//! is split once, by the compiler, into literal parts and `{{ field }}`
//! holes, so rendering is writing the parts and the values, nothing parsed
//! per request. Strings are HTML-escaped; integers are written in decimal.
//! A list is the caller's loop over a row template (main.zig): the engine
//! stays small enough to read in one sitting.

const std = @import("std");
const assert = std.debug.assert;

pub fn Template(comptime source: []const u8) type {
    const split = comptime parse(source);
    return struct {
        /// Writes the template with `value`'s fields in its holes.
        pub fn render(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
            inline for (split.parts, 0..) |part, index| {
                try writer.writeAll(part);
                if (index < split.fields.len) {
                    try write_value(writer, @field(value, split.fields[index]));
                }
            }
        }
    };
}

const Split = struct {
    parts: []const []const u8,
    fields: []const []const u8,
};

/// Literal, hole, literal, ..., literal: one more part than fields.
fn parse(comptime source: []const u8) Split {
    @setEvalBranchQuota(100_000);
    var parts: []const []const u8 = &.{};
    var fields: []const []const u8 = &.{};
    var rest = source;
    for (0..source.len + 1) |_| {
        const open = std.mem.indexOf(u8, rest, "{{") orelse break;
        const close = std.mem.indexOfPos(u8, rest, open, "}}") orelse
            @compileError("template: {{ without }}");
        parts = parts ++ .{rest[0..open]};
        fields = fields ++ .{std.mem.trim(u8, rest[open + 2 .. close], " ")};
        rest = rest[close + 2 ..];
    } else unreachable;
    parts = parts ++ .{rest};
    assert(parts.len == fields.len + 1);
    return .{ .parts = parts, .fields = fields };
}

fn write_value(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => try writer.print("{d}", .{value}),
        else => try write_escaped(writer, value),
    }
}

const V = @Vector(16, u8);

/// HTML escaping: `& < > " '`, sixteen bytes looked at a time (the last
/// chunk too, short or not), runs of other bytes written whole. A value
/// with nothing to escape is one look and one write.
fn write_escaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (at += 16) {
        const len = @min(16, text.len - at);
        var mask = specials(load16(text[at..][0..len])) & live(len);
        while (mask != 0) : (mask &= mask - 1) {
            const index = at + @ctz(mask);
            try writer.writeAll(text[start..index]);
            try writer.writeAll(entity(text[index]));
            start = index + 1;
        }
    }
    try writer.writeAll(text[start..]);
}

/// Up to 16 bytes as one vector: a single load when it cannot cross a page
/// (the bytes past the end are never used), else a copy.
inline fn load16(value: []const u8) [16]u8 {
    assert(value.len <= 16);
    if ((@intFromPtr(value.ptr) & 4095) <= 4096 - 16) return value.ptr[0..16].*;
    var copy: [16]u8 = @splat(0);
    @memcpy(copy[0..value.len], value);
    return copy;
}

/// A bit for each byte of the chunk that HTML escaping replaces.
inline fn specials(chunk: [16]u8) u16 {
    const v: V = chunk;
    const hits = (v == @as(V, @splat('&'))) | (v == @as(V, @splat('<'))) |
        (v == @as(V, @splat('>'))) | (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\'')));
    return @bitCast(hits);
}

/// A bit for each of the chunk's first `len` bytes.
inline fn live(len: usize) u16 {
    assert(len <= 16);
    return if (len == 16) 0xffff else (@as(u16, 1) << @intCast(len)) - 1;
}

fn entity(byte: u8) []const u8 {
    return switch (byte) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&#39;",
        else => unreachable,
    };
}

test "template: escaping, every byte at every position, short and long" {
    var buffer: [64 * 6]u8 = undefined;
    for (0..256) |byte| {
        for ([_]usize{ 1, 5, 15, 16, 17, 40 }) |len| {
            for (0..len) |at| {
                var value: [40]u8 = @splat('x');
                value[at] = @intCast(byte);
                var writer: std.Io.Writer = .fixed(&buffer);
                try write_escaped(&writer, value[0..len]);
                // The plain loop it replaces, as the oracle.
                var expected: [64 * 6]u8 = undefined;
                var expected_len: usize = 0;
                for (value[0..len]) |c| {
                    const out: []const u8 = switch (c) {
                        '&', '<', '>', '"', '\'' => entity(c),
                        else => &.{c},
                    };
                    @memcpy(expected[expected_len..][0..out.len], out);
                    expected_len += out.len;
                }
                try std.testing.expectEqualStrings(expected[0..expected_len], writer.buffered());
            }
        }
    }
}

test "template: holes filled and escaped" {
    const Row = Template("<td>{{ name }}</td><td>{{ price }}</td>");
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try Row.render(&writer, .{ .name = "Fish & <chips>", .price = @as(u32, 290) });
    try std.testing.expectEqualStrings(
        "<td>Fish &amp; &lt;chips&gt;</td><td>290</td>",
        writer.buffered(),
    );
}
