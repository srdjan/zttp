//! `zttp:sql` query validation against a schema database.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const handler_contract = zts.handler_contract;
const HandlerContract = zts.HandlerContract;
const sqlite = zts.sqlite;
const readFilePosix = zts.file_io.readFile;
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;

/// Validate `zttp:sql` queries against a schema database. SQLite is a C
/// dependency unavailable on freestanding/wasm, and the analyzer build has no
/// `--sql-schema` input, so the native implementation is referenced only
/// inside the comptime-gated branch and stays out of the wasm module graph.
pub fn validateSqlContract(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    sql_schema_path: ?[]const u8,
) !void {
    if (comptime builtin.target.os.tag != .freestanding) {
        return validateSqlContractNative(allocator, contract, sql_schema_path);
    }
}

fn validateSqlContractNative(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    sql_schema_path: ?[]const u8,
) !void {
    if (contract.sql.queries.items.len == 0) return;

    const schema_path = sql_schema_path orelse {
        if (!builtin.is_test) {
            debugPrint("zttp:sql queries require --sql-schema <schema.sql|schema.sqlite>\n", .{});
        }
        return error.MissingSqlSchema;
    };

    var db = try openSqlSchemaDatabase(allocator, schema_path);
    defer db.close();

    for (contract.sql.queries.items) |*query| {
        var analysis = zts.analyzeSqlStatement(allocator, query.statement) catch |err| {
            if (!builtin.is_test) {
                debugPrint("Unsupported SQL statement for query '{s}': {s}\n", .{ query.name, query.statement });
            }
            return err;
        };
        defer analysis.deinit(allocator);

        var stmt = db.prepare(query.statement) catch {
            if (!builtin.is_test) {
                debugPrint("SQL validation failed for query '{s}': {s}\n", .{ query.name, db.errmsg() });
            }
            return error.InvalidSqlQuery;
        };
        defer stmt.finalize();

        try ensureNamedParameters(&stmt, query.name);

        query.operation = analysis.operation.toString();
        for (query.tables.items) |table| allocator.free(table);
        query.tables.clearAndFree(allocator);
        for (analysis.tables.items) |table| {
            try handler_contract.appendUniqueString(allocator, &query.tables, table, false);
        }
    }
}

fn openSqlSchemaDatabase(allocator: std.mem.Allocator, schema_path: []const u8) !sqlite.Db {
    if (std.mem.endsWith(u8, schema_path, ".sql")) {
        const schema_source = try readFilePosix(allocator, schema_path, 10 * 1024 * 1024);
        defer allocator.free(schema_source);

        var db = try sqlite.Db.openInMemory();
        errdefer db.close();
        try db.exec(allocator, schema_source);
        return db;
    }

    return sqlite.Db.openReadOnly(allocator, schema_path);
}

const schema_query =
    "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' " ++
    "ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 WHEN 'view' THEN 2 ELSE 3 END, rowid";

/// The schema of a SQLite database file as SQL text: each statement followed by
/// `;\n`. A statement prepare depends on the schema and never on rows, so the
/// proof hashes this text and not the file. The text runs back through
/// `execSqlite` to a database that prepares the same statements.
pub fn readDatabaseSchema(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var db = try sqlite.Db.openReadOnly(allocator, path);
    defer db.close();
    // A running server may hold a write lock while the proof reads.
    if (sqlite.c.sqlite3_busy_timeout(db.handle, sqlite.busy_timeout_ms) != sqlite.c.SQLITE_OK) {
        return error.SqlSchemaReadFailed;
    }
    var stmt = db.prepare(schema_query) catch return error.SqlSchemaReadFailed;
    defer stmt.finalize();

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    while (true) {
        const rc = stmt.step();
        if (rc == sqlite.c.SQLITE_DONE) break;
        if (rc != sqlite.c.SQLITE_ROW) return error.SqlSchemaReadFailed;
        const column = sqlite.c.sqlite3_column_text(stmt.handle, 0) orelse return error.SqlSchemaReadFailed;
        const length: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt.handle, 0));
        try text.appendSlice(allocator, column[0..length]);
        try text.appendSlice(allocator, ";\n");
    }
    return text.toOwnedSlice(allocator);
}

/// Run `sql_text` against the database at `path`, creating the file when absent.
pub fn execSqlite(allocator: std.mem.Allocator, path: []const u8, sql_text: []const u8) !void {
    var db = try sqlite.Db.openReadWriteCreate(allocator, path);
    defer db.close();
    try db.exec(allocator, sql_text);
}

fn ensureNamedParameters(stmt: *sqlite.Stmt, query_name: []const u8) !void {
    const count = stmt.paramCount();
    for (1..count + 1) |idx| {
        if (stmt.paramName(idx) == null) {
            if (!builtin.is_test) {
                debugPrint("SQL query '{s}' uses positional parameters; only named parameters are supported\n", .{query_name});
            }
            return error.PositionalSqlParameter;
        }
    }
}

test "readDatabaseSchema leaves out sqlite_sequence and orders an index after its table" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const path = try std.fs.path.join(testing.allocator, &.{ root_z, "data.db" });
    defer testing.allocator.free(path);
    try execSqlite(
        testing.allocator,
        path,
        "CREATE TABLE a(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);" ++
            "CREATE INDEX a_name ON a(name);" ++
            "CREATE TABLE b(x INTEGER);" ++
            "INSERT INTO a(name) VALUES ('row');",
    );

    const schema = try readDatabaseSchema(testing.allocator, path);
    defer testing.allocator.free(schema);
    try testing.expectEqualStrings(
        "CREATE TABLE a(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);\n" ++
            "CREATE TABLE b(x INTEGER);\n" ++
            "CREATE INDEX a_name ON a(name);\n",
        schema,
    );
}
