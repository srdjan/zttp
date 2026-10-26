const std = @import("std");

pub const c = @import("sqlite-c");

pub const Error = error{
    SqliteOpenFailed,
    SqliteExecFailed,
    SqlitePrepareFailed,
    SqliteBindFailed,
};

pub const busy_timeout_ms: c_int = 5000;

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn openReadWriteCreate(allocator: std.mem.Allocator, path: []const u8) !Db {
        var db = try openPath(allocator, path, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_URI);
        errdefer db.close();
        // Policy bound, well below the 30 s handler deadline: a pooled runtime waits for a busy writer instead of failing at once.
        if (c.sqlite3_busy_timeout(db.handle, busy_timeout_ms) != c.SQLITE_OK) return error.SqliteOpenFailed;
        return db;
    }

    pub fn openReadOnly(allocator: std.mem.Allocator, path: []const u8) !Db {
        return openPath(allocator, path, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_URI);
    }

    pub fn openInMemory() !Db {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(":memory:", &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_MEMORY, null);
        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |db| _ = c.sqlite3_close(db);
            return error.SqliteOpenFailed;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: *Db, allocator: std.mem.Allocator, sql: []const u8) !void {
        const sql_z = try allocator.dupeSentinel(u8, sql, 0);
        defer allocator.free(sql_z);

        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql_z.ptr, null, null, &err_msg);
        defer if (err_msg != null) c.sqlite3_free(err_msg);
        if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
    }

    pub fn prepare(self: *Db, sql: []const u8) !Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return error.SqlitePrepareFailed;
        return .{
            .db = self.handle,
            .handle = stmt.?,
        };
    }

    pub fn changes(self: Db) i32 {
        return c.sqlite3_changes(self.handle);
    }

    pub fn lastInsertRowId(self: Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn errmsg(self: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }
};

pub const Stmt = struct {
    db: *c.sqlite3,
    handle: *c.sqlite3_stmt,

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn step(self: *Stmt) c_int {
        return c.sqlite3_step(self.handle);
    }

    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    pub fn paramCount(self: Stmt) usize {
        return @intCast(c.sqlite3_bind_parameter_count(self.handle));
    }

    pub fn paramName(self: Stmt, index: usize) ?[]const u8 {
        const raw = c.sqlite3_bind_parameter_name(self.handle, @intCast(index));
        return normalizeParamName(raw);
    }

    pub fn readonly(self: Stmt) bool {
        return c.sqlite3_stmt_readonly(self.handle) != 0;
    }

    pub fn errmsg(self: Stmt) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.db));
    }
};

pub fn normalizeParamName(raw: ?[*:0]const u8) ?[]const u8 {
    const text = if (raw) |ptr| std.mem.span(ptr) else return null;
    if (text.len == 0) return null;
    return switch (text[0]) {
        ':', '@', '$' => if (text.len > 1) text[1..] else null,
        else => text,
    };
}

fn openPath(allocator: std.mem.Allocator, path: []const u8, flags: c_int) !Db {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path_z.ptr, &handle, flags, null);
    if (rc != c.SQLITE_OK or handle == null) {
        if (handle) |db| _ = c.sqlite3_close(db);
        return error.SqliteOpenFailed;
    }
    return .{ .handle = handle.? };
}

const testing = std.testing;

fn writeWhileLockHeld(path: []const u8, result: *?anyerror) void {
    result.* = null;
    var db = Db.openReadWriteCreate(testing.allocator, path) catch |err| {
        result.* = err;
        return;
    };
    defer db.close();
    db.exec(testing.allocator, "INSERT INTO t VALUES (2)") catch |err| {
        result.* = err;
    };
}

test "read-write connection waits for a busy writer instead of failing" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) return error.CwdUnavailable;
    const path = try std.fs.path.join(allocator, &.{ std.mem.sliceTo(&cwd_buf, 0), ".zig-cache", "tmp", &tmp.sub_path, "busy.db" });
    defer allocator.free(path);

    var holder = try Db.openReadWriteCreate(allocator, path);
    defer holder.close();
    try holder.exec(allocator, "CREATE TABLE t (n INTEGER)");
    try holder.exec(allocator, "BEGIN IMMEDIATE");
    try holder.exec(allocator, "INSERT INTO t VALUES (1)");

    var result: ?anyerror = error.NotRun;
    const writer = try std.Thread.spawn(.{}, writeWhileLockHeld, .{ path, &result });
    const delay: std.c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
    try holder.exec(allocator, "COMMIT");
    writer.join();

    try testing.expectEqual(@as(?anyerror, null), result);
    var stmt = try holder.prepare("SELECT COUNT(*) FROM t");
    defer stmt.finalize();
    try testing.expectEqual(@as(c_int, c.SQLITE_ROW), stmt.step());
    try testing.expectEqual(@as(c_int, 2), c.sqlite3_column_int(stmt.handle, 0));
}
