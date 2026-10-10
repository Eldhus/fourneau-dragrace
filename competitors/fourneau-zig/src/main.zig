//! The fourneau-zig competitor: fourneau's server with a Zig handler, one
//! shard per CPU (shared nothing), on fourneau's io_uring port.
//!
//!   fourneau-zig [--address A] [--port P]

const std = @import("std");
const assert = std.debug.assert;
const fourneau = @import("fourneau");
const Evented = @import("zig_io_evented");
const Template = @import("template.zig").Template;
const datastar = @import("datastar.zig");
const conduit = @import("conduit.zig");

/// The shard's connection to the conduit workload's database (`--database`).
threadlocal var shard_db: ?conduit.Db = null;

/// The templates workload's page: a head, a row per dish, a tail.
const MenuHead = Template(
    \\<!doctype html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><title>Menu</title></head>
    \\<body>
    \\<h1>Menu</h1>
    \\<table>
    \\<tr><th>Dish</th><th>Price</th></tr>
    \\
);
const MenuRow = Template("<tr><td>{{ name }}</td><td>{{ price }}</td></tr>\n");
const MenuTail = Template("</table>\n</body>\n</html>\n");

const Dish = struct { name: []const u8, price: u32 };
const dishes = [_]Dish{
    .{ .name = "Roux", .price = 120 },
    .{ .name = "Fish & chips", .price = 290 },
    .{ .name = "Crème brûlée", .price = 180 },
    .{ .name = "<b>Bold</b> stew", .price = 240 },
    .{ .name = "Skyr & berries", .price = 150 },
    .{ .name = "Hákarl", .price = 990 },
    .{ .name = "Plokkfiskur", .price = 310 },
    .{ .name = "Kjötsúpa", .price = 270 },
    .{ .name = "Rúgbrauð <warm>", .price = 90 },
    .{ .name = "Pylsa með öllu", .price = 120 },
    .{ .name = "Flatkaka & hangikjöt", .price = 210 },
    .{ .name = "1 < 2 > 0 pie", .price = 160 },
};

const Header = fourneau.http1_response.Header;
const shards_max = 256;

const App = struct {
    pub const Response = struct {
        status: u16,
        headers: []const Header,
        body: []const u8,
    };

    const text_plain: []const Header = &.{
        .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
    };
    const octet_stream: []const Header = &.{
        .{ .name = "Content-Type", .value = "application/octet-stream" },
    };
    const text_html: []const Header = &.{
        .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
    };

    pub fn handle(app: *App, request: *Server.Request) Response {
        _ = app;
        const head = request.head;
        if (head.method == .get and std.mem.eql(u8, head.path_and_query, "/plaintext")) {
            return .{ .status = 200, .headers = text_plain, .body = "Hello, World!" };
        }
        if (head.method == .post and std.mem.eql(u8, head.path_and_query, "/echo")) {
            return echo(request);
        }
        if (head.method == .get and std.mem.eql(u8, head.path_and_query, "/menu")) {
            return menu(request);
        }
        if (head.method == .get and std.mem.eql(u8, path_of(head.path_and_query), "/sse")) {
            return sse(request);
        }
        if (shard_db) |*db| {
            if (std.mem.startsWith(u8, head.path_and_query, "/api/")) return api(request, db);
        }
        return .{ .status = 404, .headers = text_plain, .body = "not found" };
    }

    fn path_of(target: []const u8) []const u8 {
        const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return target;
        return target[0..query_start];
    }

    const event_stream: []const Header = &.{
        .{ .name = "Content-Type", .value = "text/event-stream" },
        .{ .name = "Cache-Control", .value = "no-cache" },
    };
    const streamed: Response = .{
        .status = fourneau.server.streamed_status,
        .headers = &.{},
        .body = "",
    };

    /// The SSE workload: Datastar's events, made one at a time into this
    /// connection's scratch memory and streamed, a chunk each.
    fn sse(request: *Server.Request) Response {
        var buffer: [datastar.signals_bytes_max]u8 = undefined;
        const signals = datastar.signals(request.head.path_and_query, &buffer) orelse {
            return .{ .status = 400, .headers = text_plain, .body = "bad signals" };
        };
        const count = @as(u64, signals.count) + 1;
        request.stream_start(200, event_stream) catch |err| switch (err) {
            // Nothing was started: an ordinary answer, for a peer that is gone.
            error.Disconnected => return .{ .status = 500, .headers = text_plain, .body = "" },
            error.HeadRefused => unreachable, // a 200 with two plain headers
        };
        comptime assert(datastar.event_bytes_max <= 64 * 1024); // fourneau's default scratch
        for (0..datastar.events_count) |index| {
            var writer: std.Io.Writer = .fixed(request.scratch[0..datastar.event_bytes_max]);
            datastar.write_event(&writer, @intCast(index), count) catch unreachable; // bounded
            request.stream_send(writer.buffered()) catch return streamed;
        }
        request.stream_end() catch return streamed;
        return streamed;
    }

    const application_json: []const Header = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    /// The conduit workload: a comment's body read first, the answer
    /// written into this connection's scratch memory.
    fn api(request: *Server.Request, db: *conduit.Db) Response {
        const head = request.head;
        var body_buffer: [16 * 1024]u8 = undefined;
        var used: usize = 0;
        const method: conduit.Method = switch (head.method) {
            .get => .get,
            .post => .post,
            else => .other,
        };
        if (method == .post) {
            for (0..body_buffer.len + 1) |_| {
                if (used == body_buffer.len) {
                    return .{ .status = 413, .headers = text_plain, .body = "body too large" };
                }
                const got = request.read_body(body_buffer[used..]) catch {
                    return .{ .status = 400, .headers = text_plain, .body = "bad body" };
                };
                if (got == 0) break;
                used += got;
            } else unreachable; // each pass reads a byte or ends
        }
        var authorization: ?[]const u8 = null;
        for (head.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) authorization = header.value;
        }
        const answer = conduit.answer(db, method, head.path_and_query, authorization,
            body_buffer[0..used], request.scratch) orelse
            return .{ .status = 404, .headers = text_plain, .body = "not found" };
        return .{ .status = answer.status, .headers = application_json, .body = answer.body };
    }

    /// The body, into this connection's scratch memory, and back.
    fn echo(request: *Server.Request) Response {
        var used: usize = 0;
        for (0..request.scratch.len + 1) |_| {
            if (used == request.scratch.len) {
                return .{ .status = 413, .headers = text_plain, .body = "body too large" };
            }
            const got = request.read_body(request.scratch[used..]) catch {
                return .{ .status = 400, .headers = text_plain, .body = "bad body" };
            };
            if (got == 0) break;
            used += got;
        } else unreachable; // each pass reads a byte or ends
        return .{ .status = 200, .headers = octet_stream, .body = request.scratch[0..used] };
    }

    /// The page, rendered into this connection's scratch memory.
    fn menu(request: *Server.Request) Response {
        var writer: std.Io.Writer = .fixed(request.scratch);
        render_menu(&writer) catch {
            return .{ .status = 500, .headers = text_plain, .body = "page too large" };
        };
        return .{ .status = 200, .headers = text_html, .body = writer.buffered() };
    }

    fn render_menu(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try MenuHead.render(writer, .{});
        for (dishes) |dish| try MenuRow.render(writer, dish);
        try MenuTail.render(writer, .{});
    }

    pub fn release(app: *App, response: *Response) void {
        _ = app;
        response.* = undefined;
    }
};

const Server = fourneau.server.ServerType(App, .{
    .send_then_receive = Evented.sendThenReceive,
});

const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    /// The conduit workload's database; "" for none.
    database: [:0]const u8 = "",
};

pub fn main(init: std.process.Init.Minimal) !void {
    var options: Options = .{};
    var args = init.args.iterate();
    _ = args.skip();
    for (0..8) |_| {
        const arg = args.next() orelse break;
        const value = args.next() orelse return error.Usage;
        if (std.mem.eql(u8, arg, "--address")) {
            options.address = value;
        } else if (std.mem.eql(u8, arg, "--port")) {
            options.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, arg, "--database")) {
            options.database = value;
        } else return error.Usage;
    }
    const shards = cpu_count();
    var threads: [shards_max]std.Thread = undefined;
    for (threads[1..shards]) |*thread| {
        thread.* = try std.Thread.spawn(.{}, run_shard, .{ options, shards });
    }
    std.debug.print("fourneau-zig on http://{s}:{d} ({d} shards)\n", .{
        options.address,
        options.port,
        shards,
    });
    run_shard(options, shards);
}

fn cpu_count() u32 {
    const linux = std.os.linux;
    var set: linux.cpu_set_t = @splat(0);
    const result = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(result) != .SUCCESS) return 1;
    var count: u32 = 0;
    for (set) |word| count += @popCount(word);
    assert(count >= 1);
    return @min(count, shards_max);
}

fn run_shard(options: Options, shards: u32) void {
    run_shard_or_fail(options, shards) catch |err| std.debug.panic("shard: {t}", .{err});
}

fn run_shard_or_fail(options: Options, shards: u32) !void {
    const gpa = std.heap.page_allocator;
    const config: fourneau.server.Config = .{
        // 1,024 for the machine, as roux and fourneau-static: each slot
        // takes ~100 KiB at startup, and 4,096 of them (one shard) did not
        // fit the smallest droplet's 512 MiB (first cloud race, 2026-10-06).
        .connections_max = @max(64, 1024 / shards),
    };
    var runtime: Evented = undefined;
    try runtime.init(gpa, .{
        .thread_limit = 0,
        .log2_ring_entries = 12,
        .fibers_max = config.fibers_max(), // reserved now, its server's own
    });
    defer runtime.deinit();
    const io = runtime.io();
    if (options.database.len > 0) shard_db = try conduit.Db.open(options.database);
    const address = try std.Io.net.IpAddress.parse(options.address, options.port);
    const listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 4096 });
    var app: App = .{};
    var server = try Server.init(gpa, io, &app, listener, config);
    try server.run();
}
