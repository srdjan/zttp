//! Shared loader for `ExecutionSpec.handler` sources.
//!
//! Replay and handler-test runners share this loader so
//! the embedded_bytecode and appended_payload branches are declared once.
//! Callers own their diagnostics on the error path.

const std = @import("std");
const zq = @import("zts");
const execution_spec = @import("execution_spec.zig");

pub const LoadedHandler = struct {
    /// Borrows the owned code buffer when evaluation received source admission.
    prepared_eval: ?execution_spec.PreparedEvalSource = null,
    /// Owned buffer holding the handler source code. Free with `allocator.free`.
    code: []const u8,
    /// Filename for error messages. Points into the config for `file_path`,
    /// or the static virtual-source identity "<eval>" for inline code.
    filename: []const u8,
    pub fn loadInto(self: LoadedHandler, runtime: *@import("handler_instance.zig").HandlerInstance) !void {
        if (self.prepared_eval) |prepared| {
            try runtime.loadPreparedEval(prepared, self.filename);
        } else {
            try runtime.loadCode(self.code, self.filename);
        }
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    handler: execution_spec.HandlerSource,
) !LoadedHandler {
    return switch (handler) {
        .file_path => |path| .{
            .code = try zq.file_io.readFile(allocator, path, 100 * 1024 * 1024),
            .filename = path,
        },
        .inline_code => |code| .{
            .code = try allocator.dupe(u8, code),
            .filename = "<eval>",
        },
        .prepared_eval => |prepared| blk: {
            const code = try allocator.dupe(u8, prepared.code);
            break :blk .{ .code = code, .filename = "<eval>", .prepared_eval = .{ .code = code } };
        },
        .embedded_bytecode, .appended_payload => error.UnsupportedHandlerSource,
    };
}

test "load inline_code returns duped buffer and eval filename" {
    const allocator = std.testing.allocator;
    const source = "function handler(r) { return Response.json({ok:true}); }";

    const loaded = try load(allocator, .{ .inline_code = source });
    defer allocator.free(loaded.code);

    try std.testing.expectEqualStrings(source, loaded.code);
    try std.testing.expectEqualStrings("<eval>", loaded.filename);
    // Returned buffer is a separate allocation; callers free unconditionally.
    try std.testing.expect(loaded.code.ptr != source.ptr);
}

test "load embedded_bytecode returns UnsupportedHandlerSource" {
    const stub = [_]u8{ 0x00, 0x01, 0x02 };
    const result = load(std.testing.allocator, .{ .embedded_bytecode = &stub });
    try std.testing.expectError(error.UnsupportedHandlerSource, result);
}

test "load appended_payload returns UnsupportedHandlerSource" {
    const payload: execution_spec.AppendedPayload = .{
        .bytecode = &.{},
        .dep_bytecodes = &.{},
        .contract_json = null,
    };
    const result = load(std.testing.allocator, .{ .appended_payload = payload });
    try std.testing.expectError(error.UnsupportedHandlerSource, result);
}

test "load prepared evaluation preserves its case and owns the original bytes" {
    const source = "function handler(req: Request): Response { return Response.text(\"ok\"); }";
    const loaded = try load(std.testing.allocator, .{ .prepared_eval = .{ .code = source } });
    defer std.testing.allocator.free(loaded.code);
    try std.testing.expectEqualStrings("<eval>", loaded.filename);
    try std.testing.expectEqualStrings(source, loaded.code);
    try std.testing.expect(loaded.code.ptr != source.ptr);
    try std.testing.expectEqual(loaded.code.ptr, loaded.prepared_eval.?.code.ptr);
}
