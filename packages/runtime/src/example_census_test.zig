//! Census of the example handlers through the lifetime-arena guard.
//!
//! `runtime_pool.zig` holds the guard: a pooled runtime serves identical
//! requests and `RuntimeStats.lifetime_allocs` must stay fixed once the runtime
//! has warmed up. This file runs every `.ts` file under `examples/` through that
//! guard, so a request-time allocation in any example handler a user can run
//! fails here. The census iterates a directory, which the testing rules permit
//! for a census.
//!
//! Each example file must have a row in `runnable` or in `not_run`. A file with
//! neither fails, a file with both fails, and a row whose file is gone fails.
//! A `not_run` row also carries a probe of its own reason, so a file that the
//! census can now run fails too (see `probeNotRun`). The two tables live in this
//! file and not under `scripts/`: no shell gate reads them, and the Zig test
//! that enforces them sits beside them.

const std = @import("std");
const zq = @import("zts");
const pool_mod = @import("runtime_pool.zig");
const runtime_config_mod = @import("runtime_config.zig");

const HandlerPool = pool_mod.HandlerPool;
const LifetimeGuardCase = pool_mod.LifetimeGuardCase;

/// The census asserts this many `.ts` files before it reports any count. It
/// equals the current number, so a moved or emptied `examples/` directory
/// cannot pass with nothing to run. Raise it by hand when an example is added.
const min_example_files: usize = 33;

/// Adds the state that a row's handler needs before it can serve a request.
const Setup = enum {
    /// The handler needs nothing beyond its source.
    none,
    /// The handler reads and writes `zttp:sql`. The census creates a SQLite
    /// file from `examples/sql/schema.sql` and allows the handler's two queries.
    sql_todos,
};

/// One request that the census runs against one example handler.
const Row = struct {
    file: []const u8,
    method: []const u8 = "GET",
    url: []const u8 = "/",
    headers: []const [2][]const u8 = &.{},
    body: ?[]const u8 = null,
    status: u16 = 200,
    /// The response body, or a part of it when `contains` is set.
    expect: []const u8,
    contains: bool = false,
    setup: Setup = .none,
};

/// Every example handler that the guard runs, with a representative request.
/// Where a handler has several routes, the row names the route with the most
/// work in it, taken from the example's `.test.jsonl` file.
const runnable = [_]Row{
    .{ .file = "examples/autoloop/handler.ts", .expect = "{}" },
    .{ .file = "examples/fetch/weather-app.ts", .expect = "<!doctype html>", .contains = true },
    .{ .file = "examples/handler/effects-capsule.ts", .expect = "zttp" },
    .{ .file = "examples/handler/feature-probes.ts", .url = "/spread", .expect = "{\"obj\":{\"a\":1,\"b\":2,\"c\":3},\"arr\":[0,1,2,3],\"empty\":[],\"emptyThenValue\":[1],\"valueThenEmpty\":[0]}" },
    .{ .file = "examples/handler/handler-with-imports.ts", .expect = "{\"message\":\"Hello, world!\"}" },
    .{ .file = "examples/handler/handler.ts", .expect = "Hello, World", .contains = true },
    .{ .file = "examples/handler/secret-leak.ts", .expect = "{\"ok\":true}" },
    .{ .file = "examples/handler/spec-fails-idempotent.ts", .expect = "{\"now\":", .contains = true },
    .{ .file = "examples/handler/spec-guardrails.ts", .expect = "{\"ok\":true}" },
    .{ .file = "examples/handler/sugar.ts", .expect = "{\"score\":150,\"evens\":[2,4],\"doubled\":[4,8],\"total\":12,\"piped\":300,\"keys\":[\"a\",\"b\"]}" },
    .{ .file = "examples/modules-all/modules_all.ts", .expect = "schema_compiled", .contains = true },
    .{ .file = "examples/modules/modules.ts", .method = "POST", .body = "hello world", .expect = "\"bodyHash\":\"b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9\"", .contains = true },
    .{ .file = "examples/patterns/annotate-not-assert.ts", .expect = "{\"port\":8080,\"host\":\"0.0.0.0\",\"version\":\"1.0\"}" },
    .{ .file = "examples/patterns/boundary-types.ts", .expect = "{\"id\":\"u-1\",\"enabled\":true,\"count\":1,\"method\":\"GET\"}" },
    .{ .file = "examples/patterns/bytes-boundary.ts", .method = "POST", .body = "{\"a\":1}", .expect = "\"documentKind\":\"dict\"", .contains = true },
    .{ .file = "examples/patterns/derive-types.ts", .expect = "\"summary\":{\"id\":1,\"name\":\"Ada\"}", .contains = true },
    .{ .file = "examples/patterns/discriminated-union-match.ts", .expect = "{\"result\":\"hi\"}" },
    .{ .file = "examples/patterns/infer-and-generics.ts", .expect = "{\"first\":\"alice\",\"count\":3}" },
    .{ .file = "examples/patterns/json-and-dict.ts", .expect = "\"entries\":[[\"name\",\"ada\"],[\"tags\",[1,null,true]],[\"ok\",true]]", .contains = true },
    .{ .file = "examples/patterns/literal-types-no-enum.ts", .expect = "{\"method\":\"GET\",\"route\":\"/api/health\"}" },
    .{ .file = "examples/patterns/nominal-brand.ts", .expect = "{\"user\":\"user:u-1\",\"order\":\"order:o-9\",\"port\":\"port:8080\",\"erased\":true}" },
    .{ .file = "examples/patterns/recursive-json-value.ts", .expect = "{\"outer\":\"array\",\"kinds\":[\"number\",\"string\",\"boolean\",\"null\",\"array\"]}" },
    .{ .file = "examples/patterns/result-combinators.ts", .expect = "\"value\":43", .contains = true },
    .{ .file = "examples/patterns/unknown-and-guards.ts", .method = "POST", .body = "hello", .expect = "{\"length\":5}" },
    .{ .file = "examples/patterns/validate-external.ts", .method = "POST", .body = "{\"title\":\"buy milk\"}", .status = 201, .expect = "buy milk", .contains = true },
    .{ .file = "examples/routing/api-surface.ts", .method = "POST", .url = "/profiles/42", .body = "{\"displayName\":\"Ada\"}", .expect = "\"displayName\":\"Ada\"", .contains = true },
    .{ .file = "examples/routing/guard-flow.ts", .method = "OPTIONS", .url = "/health", .status = 204, .expect = "" },
    .{ .file = "examples/routing/match-handler.ts", .url = "/health", .expect = "ok", .contains = true },
    .{ .file = "examples/routing/router.ts", .url = "/health", .expect = "healthy", .contains = true },
    .{ .file = "examples/sql/sql-crud.ts", .setup = .sql_todos, .expect = "{\"items\":[]}" },
    .{ .file = "examples/sql/sql-crud.ts", .setup = .sql_todos, .method = "POST", .body = "{\"title\":\"buy milk\"}", .status = 201, .expect = "\"rowsAffected\":1", .contains = true },
};

/// Why the guard does not run a file. Each reason has a probe in `probeNotRun`.
const Reason = enum {
    /// The file is an imported module. `HandlerPool.init` refuses it with
    /// `error.NoHandler`.
    imported_module,
    /// The handler's success path calls a hard-coded upstream host. Without
    /// outbound access the same request returns the handler's own failure
    /// response, so the guard would measure only that branch. `fetchSync`
    /// itself runs under the guard in `runtime_pool.zig` against a loopback
    /// server.
    hard_coded_upstream,
};

const NotRun = struct {
    file: []const u8,
    reason: Reason,
    /// The request whose offline answer the probe checks, for
    /// `hard_coded_upstream`.
    method: []const u8 = "GET",
    url: []const u8 = "/",
    headers: []const [2][]const u8 = &.{},
    body: ?[]const u8 = null,
    offline_status: u16 = 0,
};

const not_run = [_]NotRun{
    .{ .file = "examples/handler/utils.ts", .reason = .imported_module },
    .{ .file = "examples/fetch/weather-forecasts.ts", .reason = .hard_coded_upstream, .url = "/weather", .offline_status = 502 },
    .{ .file = "examples/fetch/webhook.ts", .reason = .hard_coded_upstream, .method = "POST", .url = "/charge", .headers = &.{.{ "idempotency-key", "charge-abc-123" }}, .body = "{\"amount\":100}", .offline_status = 503 },
};

const guard_arena_size: usize = 4 * 1024 * 1024;

fn readExample(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return zq.file_io.readFile(allocator, path, 1024 * 1024);
}

/// Every `.ts` path under `examples/`, sorted. The caller frees each path.
fn listExamples(allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var found: std.ArrayList([]u8) = .empty;
    errdefer {
        for (found.items) |path| allocator.free(path);
        found.deinit(allocator);
    }
    var dir = std.Io.Dir.cwd().openDir(io, "examples", .{ .iterate = true }) catch |err| {
        std.debug.print("example census: cannot open ./examples from the test working directory: {s}\n", .{@errorName(err)});
        return err;
    };
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ts")) continue;
        const path = try std.fs.path.join(allocator, &.{ "examples", entry.path });
        errdefer allocator.free(path);
        try found.append(allocator, path);
    }
    std.mem.sort([]u8, found.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return found;
}

fn guardCase(row: Row, source: []const u8) LifetimeGuardCase {
    return .{
        .name = row.file,
        .handler = source,
        .arena_size = guard_arena_size,
        .method = row.method,
        .url = row.url,
        .headers = row.headers,
        .body = row.body,
        .filename = row.file,
        .expected_status = row.status,
        .expected_body = row.expect,
        .body_contains = row.contains,
    };
}

/// Create the SQLite file for a `sql_todos` row and return the runtime config
/// that points at it. The caller frees `db_path`.
fn sqlConfig(allocator: std.mem.Allocator, sub_path: []const u8, db_path_out: *[]u8) !runtime_config_mod.RuntimeConfig {
    const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/todos.db", .{sub_path});
    errdefer allocator.free(db_path);
    const schema = try readExample(allocator, "examples/sql/schema.sql");
    defer allocator.free(schema);
    var db = try zq.sqlite.Db.openReadWriteCreate(allocator, db_path);
    defer db.close();
    try db.exec(allocator, schema);
    db_path_out.* = db_path;
    return .{
        .arena_size = guard_arena_size,
        .sqlite_path = db_path,
        .dev_capability_policy = .{
            .sql = .{
                .enabled = true,
                .queries = &.{
                    zq.handler_policy.normalizedSqlQuery("listTodos", true),
                    zq.handler_policy.normalizedSqlQuery("createTodo", false),
                },
            },
        },
    };
}

fn runRow(allocator: std.mem.Allocator, row: Row) !void {
    const source = try readExample(allocator, row.file);
    defer allocator.free(source);
    const case = guardCase(row, source);
    switch (row.setup) {
        .none => try pool_mod.runLifetimeGuardCaseWith(case, .{ .arena_size = guard_arena_size }),
        .sql_todos => {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db_path: []u8 = &.{};
            const config = try sqlConfig(allocator, &tmp.sub_path, &db_path);
            defer allocator.free(db_path);
            try pool_mod.runLifetimeGuardCaseWith(case, config);
        },
    }
}

/// Check the reason in a `not_run` row. Returns false when the reason no longer
/// holds, which means the census can run the file and the row must go.
fn probeNotRun(allocator: std.mem.Allocator, entry: NotRun) !bool {
    const source = try readExample(allocator, entry.file);
    defer allocator.free(source);
    switch (entry.reason) {
        .imported_module => {
            if (HandlerPool.init(allocator, .{ .arena_size = guard_arena_size }, source, entry.file, 1, 0)) |loaded| {
                var pool = loaded;
                pool.deinit();
                return false;
            } else |err| return err == error.NoHandler;
        },
        .hard_coded_upstream => {
            var pool = try HandlerPool.init(allocator, .{ .arena_size = guard_arena_size }, source, entry.file, 1, 0);
            defer pool.deinit();
            var request = try pool_mod.guardRequest(allocator, .{
                .name = entry.file,
                .handler = source,
                .arena_size = guard_arena_size,
                .method = entry.method,
                .url = entry.url,
                .headers = entry.headers,
                .body = entry.body,
                .expected_body = "",
            });
            defer request.deinit(allocator);
            var handle = try pool.executeHandlerBorrowed(request.asView());
            defer handle.deinit();
            return handle.response.status == entry.offline_status;
        },
    }
}

fn listHas(paths: []const []u8, file: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, file)) return true;
    }
    return false;
}

test "example census: every example handler keeps lifetime_allocs flat or carries a reason" {
    const allocator = std.testing.allocator;
    var examples = try listExamples(allocator);
    defer {
        for (examples.items) |path| allocator.free(path);
        examples.deinit(allocator);
    }

    // Floor on the census's own input, before any count below means anything.
    if (examples.items.len < min_example_files) {
        std.debug.print(
            "example census: found {d} .ts files under ./examples, fewer than the floor of {d}; the directory moved or emptied\n",
            .{ examples.items.len, min_example_files },
        );
        return error.ExampleCensusBelowFloor;
    }

    var problems: usize = 0;

    for (examples.items) |file| {
        var run_rows: usize = 0;
        for (runnable) |row| {
            if (std.mem.eql(u8, row.file, file)) run_rows += 1;
        }
        var skip_rows: usize = 0;
        for (not_run) |entry| {
            if (std.mem.eql(u8, entry.file, file)) skip_rows += 1;
        }
        if (run_rows == 0 and skip_rows == 0) {
            std.debug.print("example census: {s} has no row in `runnable` and none in `not_run`\n", .{file});
            problems += 1;
        }
        if (run_rows > 0 and skip_rows > 0) {
            std.debug.print("example census: {s} has rows in both `runnable` and `not_run`\n", .{file});
            problems += 1;
        }
    }

    for (runnable) |row| {
        if (!listHas(examples.items, row.file)) {
            std.debug.print("example census: `runnable` row names {s}, which is not under ./examples\n", .{row.file});
            problems += 1;
        }
    }
    for (not_run) |entry| {
        if (!listHas(examples.items, entry.file)) {
            std.debug.print("example census: `not_run` row names {s}, which is not under ./examples\n", .{entry.file});
            problems += 1;
            continue;
        }
        const holds = probeNotRun(allocator, entry) catch |err| {
            std.debug.print("example census: probe of `not_run` row {s} failed: {s}\n", .{ entry.file, @errorName(err) });
            problems += 1;
            continue;
        };
        if (!holds) {
            std.debug.print("example census: `not_run` row {s} ({s}) no longer holds; move the file to `runnable`\n", .{ entry.file, @tagName(entry.reason) });
            problems += 1;
        }
    }

    for (runnable) |row| {
        if (!listHas(examples.items, row.file)) continue;
        runRow(allocator, row) catch |err| {
            std.debug.print("example census: {s} {s} {s}: {s}\n", .{ row.file, row.method, row.url, @errorName(err) });
            problems += 1;
        };
    }

    try std.testing.expectEqual(@as(usize, 0), problems);
}
