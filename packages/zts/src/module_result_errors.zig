//! The error type of each virtual-module export that returns a `Result`.
//!
//! A binding spells `returns = .result` and nothing more, so
//! `module_types.populateModuleTypes` cannot read the type of the `error`
//! field from it. This table gives it, one row for each export that returns
//! `.result` and declares no signature of its own. `sseEvents` declares its own
//! types and has no row.
//!
//! A row names `string` only when every runtime path of the export that stores
//! a value under `error` stores a string (`resultErr` with a message). A path
//! that stores only under `errors` (`resultErrs`) does not count against
//! `string`. A row names `unknown` when any path stores a record, `undefined`,
//! or a value that came from an argument or a callback.
//!
//! A row sets `fills_errors` when any path ends in `resultErrs`, or when the
//! export passes on a Result that holds `errors`. Those rows type `errors` as
//! `unknown` and `error` as `E | undefined`; every other row types `errors`
//! as `never`.
//!
//! The census test at the end fails when an export has no row and when a row
//! names no such export.

const std = @import("std");
const builtin_modules = @import("zts-engine").builtin_modules;

pub const ErrorType = enum { string, unknown };

pub const Row = struct {
    module: []const u8,
    name: []const u8,
    error_type: ErrorType,
    /// Whether any runtime path of the export fails with the payload under
    /// `errors` (`resultErrs`) and leaves `error` absent. The checker then
    /// types `errors` as `unknown` and adds `undefined` to `error`. A row that
    /// never fills `errors` types it as `never`.
    fills_errors: bool,
    /// What the runtime stores under `error`, and the paths that fill `errors`.
    reason: []const u8,
};

pub const rows = [_]Row{
    .{ .module = "zttp:auth", .name = "jwtVerify", .error_type = .string, .fills_errors = false, .reason = "every error path is resultErr with a message" },
    .{ .module = "zttp:validate", .name = "validateJson", .error_type = .string, .fills_errors = true, .reason = "resultErr with a message; a schema failure ends in resultErrs (validateValueAgainstSchema), which fills errors and leaves error absent" },
    .{ .module = "zttp:validate", .name = "validateObject", .error_type = .string, .fills_errors = true, .reason = "resultErr with a message; a schema failure ends in resultErrs (validateValueAgainstSchema), which fills errors and leaves error absent" },
    .{ .module = "zttp:validate", .name = "coerceJson", .error_type = .string, .fills_errors = true, .reason = "resultErr with a message; a schema failure ends in resultErrs (validateValueAgainstSchema), which fills errors and leaves error absent" },
    .{ .module = "zttp:decode", .name = "decodeJson", .error_type = .string, .fills_errors = true, .reason = "resultErr with a message; a schema failure ends in resultErrs (validateValueAgainstSchema), which fills errors and leaves error absent" },
    .{ .module = "zttp:decode", .name = "decodeForm", .error_type = .string, .fills_errors = true, .reason = "resultErr with a message; a schema failure ends in resultErrs (validateValueAgainstSchema), which fills errors and leaves error absent" },
    .{ .module = "zttp:decode", .name = "decodeQuery", .error_type = .string, .fills_errors = true, .reason = "resultErr with a message; a schema failure ends in resultErrs (validateValueAgainstSchema), which fills errors and leaves error absent" },
    .{ .module = "zttp:decode", .name = "decodeFormMultipart", .error_type = .string, .fills_errors = true, .reason = "resultErr with a message; a schema failure ends in resultErrs (validateValueAgainstSchema), which fills errors and leaves error absent" },
    .{ .module = "zttp:ratelimit", .name = "rateCheck", .error_type = .unknown, .fills_errors = false, .reason = "resultErrValue with a { tag } or { tag, retryAfter } record" },
    .{ .module = "zttp:bytes", .name = "bytesFromOctets", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with a { kind, ... } record" },
    .{ .module = "zttp:bytes", .name = "sliceBytes", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with a { kind, start, end } record" },
    .{ .module = "zttp:bytes", .name = "concatBytes", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with a { kind, ... } record" },
    .{ .module = "zttp:bytes", .name = "decodeUtf8", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with a { kind, encoding, offset } record" },
    .{ .module = "zttp:bytes", .name = "decodeBase64", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with a { kind, ... } record" },
    .{ .module = "zttp:collections", .name = "dictFromEntries", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with undefined or a { kind, index } record" },
    .{ .module = "zttp:json", .name = "parseJson", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with a { kind, ... } record" },
    .{ .module = "zttp:json", .name = "parseJsonBytes", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with a { kind, ... } record" },
    .{ .module = "zttp:json", .name = "stringifyJson", .error_type = .unknown, .fills_errors = false, .reason = "createResultErr with a { kind, ... } record" },
    .{ .module = "zttp:result", .name = "ok", .error_type = .unknown, .fills_errors = false, .reason = "stores no error; unknown keeps the claim open" },
    .{ .module = "zttp:result", .name = "err", .error_type = .unknown, .fills_errors = false, .reason = "stores any value the caller passes" },
    .{ .module = "zttp:result", .name = "mapResult", .error_type = .unknown, .fills_errors = true, .reason = "keeps the input's error, or a callback's; an input that holds errors keeps that field" },
    .{ .module = "zttp:result", .name = "mapError", .error_type = .unknown, .fills_errors = true, .reason = "stores the callback's return value; an input that holds errors keeps that field" },
    .{ .module = "zttp:result", .name = "andThen", .error_type = .unknown, .fills_errors = true, .reason = "keeps the input's error, or the callback's Result error; an input that holds errors keeps that field" },
    .{ .module = "zttp:result", .name = "orElse", .error_type = .unknown, .fills_errors = true, .reason = "keeps the callback's Result error; that Result can hold errors" },
    .{ .module = "zttp:result", .name = "collectAll", .error_type = .unknown, .fills_errors = true, .reason = "keeps the first failing element's error, or undefined; an input that holds errors keeps that field" },
};

pub fn find(module: []const u8, name: []const u8) ?Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.module, module) and std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

/// The row for an export known only by name, as the type checker knows a call.
/// `module_types` stores signatures by name, so a name is one export.
pub fn findByName(name: []const u8) ?Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

fn returnsResultWithoutSignature(func: anytype) bool {
    return func.returns == .result and func.signature == null;
}

test "census: every export that returns a Result without a signature has an error row" {
    var missing: usize = 0;
    for (builtin_modules.metadata) |binding| {
        for (binding.exports) |func| {
            if (!returnsResultWithoutSignature(func)) continue;
            if (find(binding.specifier, func.name) == null) {
                std.debug.print("census: {s} export {s} returns a Result and has no error row\n", .{ binding.specifier, func.name });
                missing += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "census: every error row names an export that returns a Result without a signature" {
    var stale: usize = 0;
    for (rows) |row| {
        var found = false;
        for (builtin_modules.metadata) |binding| {
            if (!std.mem.eql(u8, binding.specifier, row.module)) continue;
            for (binding.exports) |func| {
                if (std.mem.eql(u8, func.name, row.name) and returnsResultWithoutSignature(func)) found = true;
            }
        }
        if (!found) {
            std.debug.print("census: row {s} export {s} names no export that returns a Result without a signature\n", .{ row.module, row.name });
            stale += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), stale);
}

test "census: no two error rows share an export name" {
    var duplicates: usize = 0;
    for (rows, 0..) |row, i| {
        for (rows[i + 1 ..]) |other| {
            if (std.mem.eql(u8, row.name, other.name)) {
                std.debug.print("census: {s} and {s} both export {s}\n", .{ row.module, other.module, row.name });
                duplicates += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), duplicates);
}
