//! What it takes to execute a handler, as data.
//!
//! Replay and the handler-test runner execute a handler without serving HTTP.
//! They use the handler source and runtime configuration from this file.
//!
//! `HandlerSource` and `AppendedPayload` live here rather than in `server.zig`
//! for the same reason: they are pure data, and `handler_loader.zig` imported
//! `server.zig` only to name them.

const std = @import("std");
const runtime_config_mod = @import("runtime_config.zig");

pub const RuntimeConfig = runtime_config_mod.RuntimeConfig;

/// Original inline bytes admitted for the fixed prepared-evaluation path.
pub const PreparedEvalSource = struct { code: []const u8 };

pub const HandlerSource = union(enum) {
    prepared_eval: PreparedEvalSource,

    /// Inline JavaScript code
    inline_code: []const u8,

    /// Path to JavaScript file
    file_path: []const u8,

    /// Pre-compiled bytecode embedded at build time (via -Dhandler)
    embedded_bytecode: []const u8,

    /// Pre-compiled bytecode extracted from self-extracting binary at runtime
    appended_payload: AppendedPayload,
};

pub const AppendedPayload = struct {
    bytecode: []const u8,
    dep_bytecodes: []const []const u8,
    contract_json: ?[]const u8 = null,
};

/// The handler and the runtime configuration to execute it under. Borrows every
/// string it carries, exactly as `ServerConfig` does, so it is safe to copy and
/// carries no ownership.
pub const ExecutionSpec = struct {
    handler: HandlerSource,
    runtime_config: RuntimeConfig = .{},
};

test "ExecutionSpec copies as data" {
    const spec: ExecutionSpec = .{ .handler = .{ .file_path = "handler.ts" } };
    const copy = spec;
    try std.testing.expectEqualStrings("handler.ts", copy.handler.file_path);
}
