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

/// HTML escaping: `& < > " '`, runs of other bytes written whole.
fn write_escaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        const entity: []const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try writer.writeAll(text[start..index]);
        try writer.writeAll(entity);
        start = index + 1;
    }
    try writer.writeAll(text[start..]);
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
