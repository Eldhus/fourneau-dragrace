//! The conduit workload (RACING.md, "The contract"): a slice of RealWorld's
//! Conduit API over SQLite, as a Zig programmer would add it to a fourneau
//! app: the SQLite amalgamation linked in (roux's vendored copy, beside
//! this repository), a connection per shard (shared nothing, as the
//! shards are), its statements prepared once; WAL, synchronous=NORMAL;
//! writes in BEGIN IMMEDIATE with a busy timeout (another shard's write
//! waits). SQLite's own VFS blocks the shard's thread on a read that
//! misses the page cache: simple, and what a plain fourneau app gets.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("sqlite_c");

pub const Answer = struct {
    status: u16,
    body: []const u8,
};

const article_columns =
    \\SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
    \\  u.username, u.bio, u.image,
    \\  (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
    \\  (SELECT group_concat(name, ',') FROM (SELECT t.name FROM article_tags at
    \\    JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name))
    \\FROM articles a JOIN users u ON u.id = a.author_id
;

/// The statements, by name; prepared on each shard's connection.
const Statement = enum(u8) { list, count, by_slug, user, add_comment, favorite, begin, commit, rollback };
const statement_sql = std.enums.EnumArray(Statement, []const u8).init(.{
    .list = article_columns ++ " ORDER BY a.created_at DESC, a.id DESC LIMIT ?1 OFFSET ?2",
    .count = "SELECT count(*) FROM articles",
    .by_slug = article_columns ++ " WHERE a.slug = ?1",
    .user = "SELECT id, username, bio, image FROM users WHERE token = ?1",
    .add_comment = "INSERT INTO comments (article_id, author_id, body, created_at, updated_at) " ++
        "SELECT id, ?1, ?2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), " ++
        "strftime('%Y-%m-%dT%H:%M:%fZ', 'now') FROM articles WHERE slug = ?3 RETURNING id, created_at",
    .favorite = "INSERT OR IGNORE INTO favorites (user_id, article_id) " ++
        "SELECT ?1, id FROM articles WHERE slug = ?2",
    .begin = "BEGIN IMMEDIATE",
    .commit = "COMMIT",
    .rollback = "ROLLBACK",
});

/// A shard's connection and its statements.
pub const Db = struct {
    db: *c.sqlite3,
    statements: std.enums.EnumArray(Statement, *c.sqlite3_stmt),

    pub fn open(path: [:0]const u8) !Db {
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(path, &db, flags, null) != c.SQLITE_OK) {
            std.debug.print("conduit: open {s}: {s}\n", .{ path, c.sqlite3_errmsg(db) });
            return error.Sqlite;
        }
        // First: shards opening at once wait for each other's settings.
        _ = c.sqlite3_busy_timeout(db, 5000);
        const pragmas = "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; " ++
            "PRAGMA foreign_keys = ON;";
        if (c.sqlite3_exec(db, pragmas, null, null, null) != c.SQLITE_OK) {
            std.debug.print("conduit: {s}\n", .{c.sqlite3_errmsg(db)});
            return error.Sqlite;
        }
        var opened: Db = .{ .db = db.?, .statements = undefined };
        for (std.enums.values(Statement)) |name| {
            var statement: ?*c.sqlite3_stmt = null;
            const sql = statement_sql.get(name);
            if (c.sqlite3_prepare_v3(db, sql.ptr, @intCast(sql.len), c.SQLITE_PREPARE_PERSISTENT, &statement, null) != c.SQLITE_OK) {
                std.debug.print("conduit: {s}: {s}\n", .{ @tagName(name), c.sqlite3_errmsg(db) });
                return error.Sqlite;
            }
            opened.statements.set(name, statement.?);
        }
        return opened;
    }

    /// A statement, ready to bind. Every caller resets it as soon as its
    /// rows are read: a statement left on a row holds its read snapshot,
    /// and a later BEGIN IMMEDIATE on the connection could not write past
    /// another shard's commit (SQLITE_BUSY_SNAPSHOT, which no busy timeout
    /// waits out: found 2026-10-07, under the race's load).
    fn get(db: *Db, name: Statement) *c.sqlite3_stmt {
        const statement = db.statements.get(name);
        _ = c.sqlite3_reset(statement);
        _ = c.sqlite3_clear_bindings(statement);
        return statement;
    }

    fn run(db: *Db, name: Statement) !void {
        const statement = db.get(name);
        defer _ = c.sqlite3_reset(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.Sqlite;
    }
};

fn bind_text(statement: *c.sqlite3_stmt, index: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(statement, index, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
}

fn column_text(statement: *c.sqlite3_stmt, column: c_int) ?[]const u8 {
    const pointer = c.sqlite3_column_text(statement, column) orelse return null;
    return pointer[0..@intCast(c.sqlite3_column_bytes(statement, column))];
}

/// The answer to a /api/ request, its body in `out`; null for another path.
/// `authorization` is the Authorization header's value, if any.
pub fn answer(db: *Db, method: Method, target: []const u8, authorization: ?[]const u8,
    body: []const u8, out: []u8) ?Answer {
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];
    const prefix = "/api/articles";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var writer: std.Io.Writer = .fixed(out);
    const result = route(db, method, path[prefix.len..], target[path_end..], authorization, body,
        &writer);
    const status = result catch |err| return switch (err) {
        error.WriteFailed => .{ .status = 500, .body = "{\"errors\":{\"body\":[\"too large\"]}}" },
        error.Sqlite => {
            std.debug.print("conduit: {s}\n", .{c.sqlite3_errmsg(db.db)});
            return .{ .status = 500, .body = "{\"errors\":{\"body\":[\"database\"]}}" };
        },
    };
    return .{ .status = status, .body = writer.buffered() };
}

pub const Method = enum { get, post, other };

fn route(db: *Db, method: Method, rest: []const u8, query: []const u8,
    authorization: ?[]const u8, body: []const u8, w: *std.Io.Writer) !u16 {
    if (rest.len == 0) {
        if (method != .get) return error_answer(w, 404, "not found");
        return list(db, query, w);
    }
    if (rest[0] != '/') return error_answer(w, 404, "not found");
    var parts = std.mem.splitScalar(u8, rest[1..], '/');
    const slug = parts.next().?;
    const action = parts.next();
    if (parts.next() != null) return error_answer(w, 404, "not found");
    if (action == null and method == .get) return article(db, slug, w);
    if (action != null and method == .post) {
        if (std.mem.eql(u8, action.?, "comments")) return comment(db, slug, authorization, body, w);
        if (std.mem.eql(u8, action.?, "favorite")) return favorite(db, slug, authorization, w);
    }
    return error_answer(w, 404, "not found");
}

fn query_int(query: []const u8, name: []const u8, fallback: i64) i64 {
    if (query.len < 1) return fallback;
    var pairs = std.mem.splitScalar(u8, query[1..], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], name)) continue;
        return std.fmt.parseInt(i64, pair[equals + 1 ..], 10) catch fallback;
    }
    return fallback;
}

fn list(db: *Db, query: []const u8, w: *std.Io.Writer) !u16 {
    const limit = std.math.clamp(query_int(query, "limit", 20), 0, 100);
    const offset = std.math.clamp(query_int(query, "offset", 0), 0, 1 << 30);
    const statement = db.get(.list);
    _ = c.sqlite3_bind_int64(statement, 1, limit);
    _ = c.sqlite3_bind_int64(statement, 2, offset);
    try w.writeAll("{\"articles\":[");
    var first = true;
    for (0..101) |_| {
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => break,
            else => return error.Sqlite,
        }
        if (!first) try w.writeByte(',');
        first = false;
        try write_article(statement, false, false, w);
    }
    _ = c.sqlite3_reset(statement);
    const count = db.get(.count);
    defer _ = c.sqlite3_reset(count);
    if (c.sqlite3_step(count) != c.SQLITE_ROW) return error.Sqlite;
    try w.print("],\"articlesCount\":{d}}}", .{c.sqlite3_column_int64(count, 0)});
    return 200;
}

fn article(db: *Db, slug: []const u8, w: *std.Io.Writer) !u16 {
    const statement = db.get(.by_slug);
    defer _ = c.sqlite3_reset(statement);
    bind_text(statement, 1, slug);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => return error_answer(w, 404, "article not found"),
        else => return error.Sqlite,
    }
    try w.writeAll("{\"article\":");
    try write_article(statement, true, false, w);
    try w.writeAll("}");
    return 200;
}

const User = struct { id: i64, profile: [512]u8 = undefined, profile_len: usize = 0 };

/// The request's user, by its token, with its profile's JSON made.
fn user(db: *Db, authorization: ?[]const u8) !?User {
    const value = authorization orelse return null;
    if (!std.mem.startsWith(u8, value, "Token ")) return null;
    const token = value["Token ".len..];
    const statement = db.get(.user);
    defer _ = c.sqlite3_reset(statement);
    bind_text(statement, 1, token);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => return null,
        else => return error.Sqlite,
    }
    var found: User = .{ .id = c.sqlite3_column_int64(statement, 0) };
    var w: std.Io.Writer = .fixed(&found.profile);
    write_profile(column_text(statement, 1).?, column_text(statement, 2).?, column_text(statement, 3), &w) catch
        return error.Sqlite;
    found.profile_len = w.buffered().len;
    return found;
}

fn comment(db: *Db, slug: []const u8, authorization: ?[]const u8, body: []const u8,
    w: *std.Io.Writer) !u16 {
    const author = try user(db, authorization) orelse return error_answer(w, 401, "a token is needed");
    var buffer: [8192]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const parsed = std.json.parseFromSliceLeaky(struct { comment: struct { body: []const u8 } },
        fixed.allocator(), body, .{ .ignore_unknown_fields = true }) catch
        return error_answer(w, 422, "a comment needs a body");
    const text = parsed.comment.body;
    if (text.len == 0) return error_answer(w, 422, "a comment needs a body");
    try db.run(.begin);
    errdefer db.run(.rollback) catch {};
    const statement = db.get(.add_comment);
    _ = c.sqlite3_bind_int64(statement, 1, author.id);
    bind_text(statement, 2, text);
    bind_text(statement, 3, slug);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => {
            try db.run(.rollback);
            return error_answer(w, 404, "article not found");
        },
        else => return error.Sqlite,
    }
    const id = c.sqlite3_column_int64(statement, 0);
    var created: [32]u8 = undefined;
    const created_text = column_text(statement, 1).?;
    @memcpy(created[0..created_text.len], created_text);
    _ = c.sqlite3_reset(statement);
    try db.run(.commit);
    const time = created[0..created_text.len];
    try w.print("{{\"comment\":{{\"id\":{d},\"createdAt\":\"{s}\",\"updatedAt\":\"{s}\",\"body\":", .{ id, time, time });
    try std.json.Stringify.encodeJsonString(text, .{}, w);
    try w.print(",\"author\":{s}}}}}", .{author.profile[0..author.profile_len]});
    return 200;
}

fn favorite(db: *Db, slug: []const u8, authorization: ?[]const u8, w: *std.Io.Writer) !u16 {
    const found = try user(db, authorization) orelse return error_answer(w, 401, "a token is needed");
    try db.run(.begin);
    errdefer db.run(.rollback) catch {};
    const add = db.get(.favorite);
    _ = c.sqlite3_bind_int64(add, 1, found.id);
    bind_text(add, 2, slug);
    const added = c.sqlite3_step(add);
    _ = c.sqlite3_reset(add);
    if (added != c.SQLITE_DONE) return error.Sqlite;
    const statement = db.get(.by_slug);
    bind_text(statement, 1, slug);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => {
            try db.run(.rollback);
            return error_answer(w, 404, "article not found");
        },
        else => return error.Sqlite,
    }
    try w.writeAll("{\"article\":");
    try write_article(statement, true, true, w);
    try w.writeAll("}");
    _ = c.sqlite3_reset(statement);
    try db.run(.commit);
    return 200;
}

fn write_article(statement: *c.sqlite3_stmt, with_body: bool, favorited: bool,
    w: *std.Io.Writer) !void {
    const json = std.json.Stringify;
    try w.writeAll("{\"slug\":");
    try json.encodeJsonString(column_text(statement, 1).?, .{}, w);
    try w.writeAll(",\"title\":");
    try json.encodeJsonString(column_text(statement, 2).?, .{}, w);
    try w.writeAll(",\"description\":");
    try json.encodeJsonString(column_text(statement, 3).?, .{}, w);
    if (with_body) {
        try w.writeAll(",\"body\":");
        try json.encodeJsonString(column_text(statement, 4).?, .{}, w);
    }
    try w.writeAll(",\"tagList\":[");
    if (column_text(statement, 11)) |tags| {
        var names = std.mem.splitScalar(u8, tags, ',');
        var first = true;
        while (names.next()) |name| {
            if (name.len == 0) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try json.encodeJsonString(name, .{}, w);
        }
    }
    try w.writeAll("],\"createdAt\":");
    try json.encodeJsonString(column_text(statement, 5).?, .{}, w);
    try w.writeAll(",\"updatedAt\":");
    try json.encodeJsonString(column_text(statement, 6).?, .{}, w);
    try w.print(",\"favorited\":{},\"favoritesCount\":{d},\"author\":", .{
        favorited, c.sqlite3_column_int64(statement, 10),
    });
    try write_profile(column_text(statement, 7).?, column_text(statement, 8).?, column_text(statement, 9), w);
    try w.writeAll("}");
}

fn write_profile(username: []const u8, bio: []const u8, image: ?[]const u8, w: *std.Io.Writer) !void {
    const json = std.json.Stringify;
    try w.writeAll("{\"username\":");
    try json.encodeJsonString(username, .{}, w);
    try w.writeAll(",\"bio\":");
    try json.encodeJsonString(bio, .{}, w);
    try w.writeAll(",\"image\":");
    if (image) |url| try json.encodeJsonString(url, .{}, w) else try w.writeAll("null");
    try w.writeAll(",\"following\":false}");
}

/// An error as the spec answers one: {"errors":{"body":[...]}}.
fn error_answer(w: *std.Io.Writer, status: u16, message: []const u8) !u16 {
    try w.print("{{\"errors\":{{\"body\":[\"{s}\"]}}}}", .{message});
    return status;
}

test "query_int reads a parameter, or falls back" {
    try std.testing.expectEqual(@as(i64, 40), query_int("?limit=5&offset=40", "offset", 0));
    try std.testing.expectEqual(@as(i64, 20), query_int("", "limit", 20));
    try std.testing.expectEqual(@as(i64, 7), query_int("?limit=x", "limit", 7));
}
