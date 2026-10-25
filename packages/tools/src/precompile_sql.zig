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
