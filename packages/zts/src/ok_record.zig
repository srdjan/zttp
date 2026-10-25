//! Leaf helper: which module exports the flow checker and the path generator fork on `x.ok`.

const std = @import("std");
const mb = @import("zts-engine").module_binding;
const type_pool_mod = @import("type_pool.zig");
const type_env_mod = @import("type_env.zig");

/// Whether `x.ok` and `x.status` fork the result of a call to this export: it is
/// failable, does not return a `Result`, and declares an `ok`-record response
/// (`fetch`). The flow checker's witness search asks the same question, so the
/// generated tests and the counterexamples fork the same calls.
pub fn isOkRecordExport(allocator: std.mem.Allocator, func: *const mb.FunctionBinding) error{OutOfMemory}!bool {
    return func.failure_severity != .none and func.returns != .result and
        try declaresOkRecord(allocator, func);
}

/// Whether the export is forked by `x.ok` on its result because it declares an
/// `ok: boolean` response record. The rule reads the parsed return type, not the
/// signature text: `returnsOkRecord` resolves it through the type environment.
/// The caller applies it only to exports with a failure severity.
fn declaresOkRecord(allocator: std.mem.Allocator, func: *const mb.FunctionBinding) error{OutOfMemory}!bool {
    const sig = func.signature orelse return false;
    return returnsOkRecord(allocator, sig.returns);
}

/// True when `return_text` parses to a record that has a top-level, required
/// field `ok` of type `boolean`. A nested `ok`, an optional `ok`, a union that
/// holds such a record, and a function type all give false.
pub fn returnsOkRecord(allocator: std.mem.Allocator, return_text: []const u8) error{OutOfMemory}!bool {
    var pool = type_pool_mod.TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = type_env_mod.TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const parsed = env.resolveType(return_text);
    try env.ensureHealthy();
    if (parsed == type_pool_mod.null_type_idx) return false;
    const resolved = env.resolveRef(parsed);
    if (pool.getTag(resolved) != .t_record) return false;
    for (pool.getRecordFields(resolved)) |field| {
        if (field.optional) continue;
        if (!std.mem.eql(u8, pool.getName(field.name_start, field.name_len), "ok")) continue;
        if (field.type_idx == pool.idx_boolean) return true;
    }
    return false;
}

test "returnsOkRecord reads the parsed return type, not the text" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { text: []const u8, expected: bool }{
        .{ .text = "{ ok: boolean; status: number }", .expected = true },
        .{ .text = "{ status: number; ok: boolean; body: string }", .expected = true },
        .{ .text = "{ ok: boolean; headers: { get: (name: string) => string | undefined } }", .expected = true },
        // A nested `ok` is not the record's own.
        .{ .text = "{ meta: { ok: boolean }; status: number }", .expected = false },
        // Optional, or another type, or a function type.
        .{ .text = "{ ok?: boolean; status: number }", .expected = false },
        .{ .text = "{ ok: string; status: number }", .expected = false },
        .{ .text = "{ check: (ok: boolean) => boolean }", .expected = false },
        // A text scan would match this: the text holds `ok: boolean` and the
        // type is a union, not a record.
        .{ .text = "{ ok: boolean } | undefined", .expected = false },
        .{ .text = "string", .expected = false },
        .{ .text = "", .expected = false },
    };
    for (cases) |case| {
        const actual = try returnsOkRecord(allocator, case.text);
        if (actual != case.expected) {
            std.debug.print("returnsOkRecord(\"{s}\"): expected {}, got {}\n", .{ case.text, case.expected, actual });
            return error.WrongOkRecordVerdict;
        }
    }
}

test "an ok record with no severity, or a Result return, is not forked on ok" {
    const allocator = std.testing.allocator;
    const base = mb.FunctionBinding{
        .name = "probe",
        .arg_count = 0,
        .effect = .write,
        .returns = .object,
        .signature = .{ .params = &.{}, .returns = "{ ok: boolean; status: number }" },
        .failure_severity = .upstream,
    };
    try std.testing.expect(try isOkRecordExport(allocator, &base));

    var no_severity = base;
    no_severity.failure_severity = .none;
    try std.testing.expect(!(try isOkRecordExport(allocator, &no_severity)));

    var result_return = base;
    result_return.returns = .result;
    try std.testing.expect(!(try isOkRecordExport(allocator, &result_return)));
}
