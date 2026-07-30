//! What it takes to execute a handler, as data.
//!
//! Durable recovery, the durable scheduler, replay, and the handler-test runner
//! all execute a handler without serving HTTP. They used to take a whole
//! `ServerConfig` to do it, which put `server.zig` in their import graph and
//! made the request-serving configuration look like a dependency of durable
//! scheduling. Measured, they read two of its 27 fields: the handler source and
//! the runtime configuration. Those two are this file.
//!
//! `HandlerSource` and `AppendedPayload` live here rather than in `server.zig`
//! for the same reason: they are pure data, and `handler_loader.zig` imported
//! `server.zig` only to name them.

const std = @import("std");
const runtime_config_mod = @import("runtime_config.zig");

pub const RuntimeConfig = runtime_config_mod.RuntimeConfig;

pub const HandlerSource = union(enum) {
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
