//! The catalog workload's page: the templates workload's engine (holes,
//! compiled at comptime) and Zig's own loops and conditions around it, as
//! main.zig's menu: a record's fields, lists nested in lists, a table of
//! 256 rows, empty lists, raw HTML and formatted prices. The reference is
//! workloads/catalog.html.

const std = @import("std");
const assert = std.debug.assert;
const Template = @import("template.zig").Template;

const Head = Template(
    \\<!doctype html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><title>{{ title }}</title></head>
    \\<body>
    \\<h1>{{ title }}</h1>
    \\<p>
);
const ShopLine = Template("</p>\n<p>{{ name }}, {{ city }}");
const GroupHead = Template("<h2>{{ name }}</h2><p>");
const Member = Template("{{ member }};");
const RowCells = Template("><td>{{ id }}<td>{{ name }}<td>{{ stock }}<td>");
const Tag = Template("<i>{{ tag }}</i>");
const Currency = Template(" {{ currency }}\n");

const Shop = struct { name: []const u8, city: []const u8, open: bool };
const Group = struct { name: []const u8, members: [3][]const u8 };
const Row = struct {
    id: u32,
    name: []const u8,
    price: u32,
    stock: i32,
    hot: bool,
    tags: []const []const u8,
};

const rows_count = 256;
const groups_count = 6;

/// The catalog's names: markup, quotes and accents, each escaped as printed.
const names = [8][]const u8{ "Roux", "Skyr & ber", "Crème", "<b>Stew</b>", "Hákarl", "Kjöt \"s\"", "O'Brien", "Pylsa" };
const tags_by_row = [3][]const []const u8{ &.{}, &.{"veg"}, &.{ "veg", "gf" } };

const title = "Catalog <&> \"one\" 'two'";
const note = "<em>Fresh</em> &amp; local";
const currency = "kr";
const shop: Shop = .{ .name = "Eldhús", .city = "Reykjavík", .open = true };
const closed = false;
const specials: []const []const u8 = &.{};

/// The catalog's data, as race.json's catalog test defines it.
const rows = blk: {
    @setEvalBranchQuota(10_000);
    var list: [rows_count]Row = undefined;
    for (&list, 0..) |*row, i| row.* = .{
        .id = i + 1,
        .name = names[i % 8],
        .price = 500 + (i * 7919) % 20000,
        .stock = @as(i32, (i * 13) % 50) - 10,
        .hot = i % 7 == 0,
        .tags = tags_by_row[i % 3],
    };
    break :blk list;
};

const groups = blk: {
    var list: [groups_count]Group = undefined;
    for (&list, 0..) |*group, k| group.* = .{
        .name = std.fmt.comptimePrint("Group {d}", .{k + 1}),
        .members = .{ names[k % 8], names[(k + 1) % 8], names[(k + 2) % 8] },
    };
    break :blk list;
};

pub fn render(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try Head.render(writer, .{ .title = title });
    try writer.writeAll(note); // raw HTML, as the page's own
    try ShopLine.render(writer, shop);
    if (shop.open) try writer.writeAll(" (open)");
    try writer.writeAll("</p>\n");
    if (!closed) try writer.writeAll("<p>Open today.</p>\n");
    if (specials.len == 0) try writer.writeAll("<p>No specials.</p>\n");
    const noun = if (groups.len == 1) "group" else "groups";
    try writer.print("<p>{d} {s}, {d} rows</p>\n", .{ groups.len, noun, rows.len });
    for (&groups) |*group| {
        try GroupHead.render(writer, group.*);
        for (group.members) |member| try Member.render(writer, .{ .member = member });
        try writer.writeAll("</p>\n");
    }
    try writer.writeAll("<table>\n");
    for (&rows) |*row| {
        try writer.writeAll(if (row.hot) "<tr class=\"hot\"" else "<tr");
        try RowCells.render(writer, row.*);
        if (row.tags.len == 0) try writer.writeAll("-");
        for (row.tags) |tag| try Tag.render(writer, .{ .tag = tag });
        try writer.print("<td>{d}.{d:0>2}", .{ row.price / 100, row.price % 100 });
        try Currency.render(writer, .{ .currency = currency });
    }
    try writer.writeAll("</table>\n</body>\n</html>\n");
}

test "catalog: the page starts and ends as the reference does" {
    var buffer: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer);
    const page = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, page, "<!doctype html>\n"));
    try std.testing.expect(std.mem.endsWith(u8, page, "</table>\n</body>\n</html>\n"));
    assert(page.len < buffer.len);
}
