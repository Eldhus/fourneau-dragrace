//! The catalog workload's page: the templates workload's engine (holes,
//! compiled at comptime) and Zig's own loops, conditions and formatting
//! around it, as main.zig's menu: a record's fields, lists nested in lists,
//! a table of 128 rows, empty lists, raw HTML, prices, sale prices, dates
//! and weights. The reference is workloads/catalog.html.

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
const OfferLine = Template("<li>{{ what }}: {{ off }}% off</li>\n");
const InStock = Template(" {{ currency }} in stock</p>\n");
const GroupHead = Template("<h2>{{ name }}</h2><p>");
const Member = Template("{{ member }};");
const RowCells = Template("<td>{{ id }} {{ name }}</td><td>");
const Tag = Template("<i>{{ tag }}</i>");
const Currency = Template(" {{ currency }}</td><td>");

const Shop = struct { name: []const u8, city: []const u8, open: bool };
const Offer = struct { what: []const u8, off: u8 };
const Group = struct { name: []const u8, members: [3][]const u8 };
const Row = struct {
    id: u32,
    name: []const u8,
    price: u32,
    discount: u8,
    on_sale: bool,
    stock: i32,
    hot: bool,
    tags: []const []const u8,
    added: u16,
    grams: u32,
};

const rows_count = 128;
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
const offers = [3]Offer{ .{ .what = "Soup of the day", .off = 10 }, .{ .what = "Bread & butter", .off = 25 }, .{ .what = "Coffee <hot>", .off = 5 } };

/// The catalog's data, as race.json's catalog test defines it.
const rows = blk: {
    @setEvalBranchQuota(10_000);
    var list: [rows_count]Row = undefined;
    for (&list, 0..) |*row, i| {
        const discount: u8 = (i * 37) % 40;
        row.* = .{
            .id = i + 1,
            .name = names[i % 8],
            .price = 500 + (i * 7919) % 20000,
            .discount = discount,
            .on_sale = discount > 0,
            .stock = @as(i32, (i * 13) % 50) - 10,
            .hot = i % 7 == 0,
            .tags = tags_by_row[i % 3],
            .added = (i * 53) % 365,
            .grams = 50 + (i * 997) % 5000,
        };
    }
    break :blk list;
};

/// The prices' sum.
const total = blk: {
    var sum: u32 = 0;
    for (&rows) |*row| sum += row.price;
    break :blk sum;
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
    try writer.writeAll(if (shop.open) " (open)" else " (closed)");
    try writer.writeAll("</p>\n");
    if (!closed) try writer.writeAll("<p>Open today.</p>\n");
    if (specials.len == 0) try writer.writeAll("<p>No specials.</p>\n");
    try writer.writeAll("<ul>\n");
    for (&offers) |*offer| try OfferLine.render(writer, offer.*);
    try writer.writeAll("</ul>\n");
    if (offers.len == 0) try writer.writeAll("<p>No offers.</p>\n");
    try writer.print("<p>{d} {s}, {d} {s}, ", .{ groups.len, plural(groups.len, "group", "groups"), rows.len, plural(rows.len, "row", "rows") });
    try writeKr(writer, total);
    try InStock.render(writer, .{ .currency = currency });
    for (&groups) |*group| {
        try GroupHead.render(writer, group.*);
        for (group.members) |member| try Member.render(writer, .{ .member = member });
        try writer.writeAll("</p>\n");
    }
    try writer.writeAll("<table>\n");
    for (&rows) |*row| {
        try writer.print("<tr class=\"{s}{s}\">", .{ level(row.stock), if (row.hot) " hot" else "" });
        try RowCells.render(writer, .{ .id = row.id, .name = row.name });
        try writeStock(writer, row.stock);
        try writer.writeAll(" ");
        if (row.tags.len == 0) try writer.writeAll("-");
        for (row.tags) |tag| try Tag.render(writer, .{ .tag = tag });
        try writer.writeAll("</td><td>");
        if (row.on_sale) {
            try writer.writeAll("<s>");
            try writeKr(writer, row.price);
            try writer.writeAll("</s> ");
            try writeKr(writer, sale(row.price, row.discount));
        } else {
            try writeKr(writer, row.price);
        }
        try Currency.render(writer, .{ .currency = currency });
        try writeDate(writer, row.added);
        try writer.writeAll(" ");
        try writeWeight(writer, row.grams);
        try writer.writeAll("</td></tr>\n");
    }
    try writer.writeAll("</table>\n</body>\n</html>\n");
}

/// The noun that fits a count: group, groups.
fn plural(count: usize, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

/// A price in hundredths: 12.05.
fn writeKr(writer: *std.Io.Writer, hundredths: u32) std.Io.Writer.Error!void {
    try writer.print("{d}.{d:0>2}", .{ hundredths / 100, hundredths % 100 });
}

/// A stock's level, the row's class: out, low (under ten), ok.
fn level(stock: i32) []const u8 {
    return if (stock <= 0) "out" else if (stock < 10) "low" else "ok";
}

/// A stock as written: out, 3 left, 16.
fn writeStock(writer: *std.Io.Writer, count: i32) std.Io.Writer.Error!void {
    if (count <= 0) {
        try writer.writeAll("out");
    } else if (count < 10) {
        try writer.print("{d} left", .{count});
    } else {
        try writer.print("{d}", .{count});
    }
}

/// A price after a discount in percent, in hundredths, rounded down.
fn sale(price: u32, off: u8) u32 {
    return price - price * off / 100;
}

/// A day of 2026 (0 is January 1) as MM-DD.
fn writeDate(writer: *std.Io.Writer, day: u16) std.Io.Writer.Error!void {
    const months = [12]u16{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var left = day;
    var month: u8 = 1;
    for (months) |days| {
        if (left < days) break;
        left -= days;
        month += 1;
    }
    try writer.print("{d:0>2}-{d:0>2}", .{ month, left + 1 });
}

/// A weight in grams: 350 g, or 1.25 kg from a kilogram up.
fn writeWeight(writer: *std.Io.Writer, grams: u32) std.Io.Writer.Error!void {
    if (grams < 1000) {
        try writer.print("{d} g", .{grams});
    } else {
        try writer.print("{d}.{d:0>2} kg", .{ grams / 1000, (grams % 1000) / 10 });
    }
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

test "catalog: the formatters" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeDate(&writer, 53);
    try writer.writeAll(" ");
    try writeWeight(&writer, 1045);
    try writer.writeAll(" ");
    try writeKr(&writer, sale(8419, 37));
    try writer.writeAll(" ");
    try writeStock(&writer, 3);
    try std.testing.expectEqualStrings("02-23 1.04 kg 53.04 3 left", writer.buffered());
    try std.testing.expectEqualStrings("out", level(0));
}
