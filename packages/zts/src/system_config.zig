//! The `system.json` manifest: which handlers a linked bundle contains, where
//! each one lives, and which of them is the external entry point.
//!
//! This is the manifest's shape and its parser, not the proof that reads it.
//! `system_linker.zig` proves the handlers in a system communicate correctly,
//! and it holds a `SystemConfig` while doing so - but `zttp:service` also needs
//! to read the manifest at runtime, to learn each service's base URL. Keeping
//! the type and the parser inside the linker meant that runtime read pulled the
//! whole cross-handler proof, and through it the contract types and the route
//! matcher, into the engine's import closure. See
//! docs/plans/2026-08-07-021-zts-three-module-split-plan.md.

const std = @import("std");
const json_wire = @import("zts-base").json_wire;

pub const SystemConfig = struct {
    version: u32,
    /// The bundle's single external HTTP entry point, naming one of
    /// `handlers[].name`. Optional for backward compatibility with manifests
    /// predating this field. When set, `zttp link` validates it names an
    /// existing handler and the signed `kind=workflow` receipt attests to it.
    entry: ?[]const u8 = null, // owned
    handlers: []HandlerEntry,

    pub const HandlerEntry = struct {
        name: []const u8, // owned
        path: []const u8, // owned
        /// Real-HTTP base URL, consumed only by `zttp:service`'s
        /// `serviceCall` and raw `fetchSync` egress resolution. Optional: a
        /// handler reached only via `zttp:workflow`'s in-process
        /// `call`/`saga`/`fanout`/`follow` (resolved by name, never by URL)
        /// genuinely never needs one.
        base_url: ?[]const u8 = null, // owned
    };

    pub fn deinit(self: *SystemConfig, allocator: std.mem.Allocator) void {
        if (self.entry) |e| allocator.free(e);
        for (self.handlers) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
            if (entry.base_url) |base_url| allocator.free(base_url);
        }
        allocator.free(self.handlers);
    }
};

const SystemHandlerWire = struct {
    name: ?json_wire.String = null,
    path: ?json_wire.String = null,
    baseUrl: ?json_wire.String = null,
};

const SystemConfigWire = struct {
    version: json_wire.Unsigned(u32) = .{ .value = null },
    entry: ?json_wire.String = null,
    handlers: []const SystemHandlerWire = &.{},
};

/// `handler_contract.dupeOptionalString` under a local name. Reaching that file
/// for a two-line duplication would put the contract types back into every
/// runtime read of the manifest, which is the reach this file exists to break.
fn dupeOptional(allocator: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try allocator.dupe(u8, v) else null;
}

pub fn parseSystemConfig(allocator: std.mem.Allocator, json_bytes: []const u8) !SystemConfig {
    var parsed = try json_wire.parse(SystemConfigWire, allocator, json_bytes);
    defer parsed.deinit();

    var entries: std.ArrayList(SystemConfig.HandlerEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
            if (entry.base_url) |base_url| allocator.free(base_url);
        }
        entries.deinit(allocator);
    }

    try entries.ensureTotalCapacity(allocator, parsed.value.handlers.len);
    for (parsed.value.handlers) |wire| {
        const name_wire = wire.name orelse return error.InvalidJson;
        const path_wire = wire.path orelse return error.InvalidJson;
        const name = try allocator.dupe(u8, name_wire.bytes);
        errdefer allocator.free(name);
        const path = try allocator.dupe(u8, path_wire.bytes);
        errdefer allocator.free(path);
        const base_url = try dupeOptional(
            allocator,
            if (wire.baseUrl) |value| value.bytes else null,
        );
        errdefer if (base_url) |value| allocator.free(value);
        entries.appendAssumeCapacity(.{
            .name = name,
            .path = path,
            .base_url = base_url,
        });
    }

    const entry = try dupeOptional(
        allocator,
        if (parsed.value.entry) |value| value.bytes else null,
    );
    errdefer if (entry) |value| allocator.free(value);
    const handlers = try entries.toOwnedSlice(allocator);
    return .{
        .version = parsed.value.version.value orelse 1,
        .entry = entry,
        .handlers = handlers,
    };
}

test "parseSystemConfig" {
    const json =
        \\{
        \\  "version": 1,
        \\  "handlers": [
        \\    { "name": "gateway", "path": "gateway.ts", "baseUrl": "https://gateway.internal" },
        \\    { "name": "users", "path": "users.ts", "baseUrl": "https://users.internal" }
        \\  ]
        \\}
    ;
    var config = try parseSystemConfig(std.testing.allocator, json);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), config.version);
    try std.testing.expectEqual(@as(usize, 2), config.handlers.len);
    try std.testing.expectEqualStrings("gateway", config.handlers[0].name);
    try std.testing.expectEqualStrings("gateway.ts", config.handlers[0].path);
    try std.testing.expectEqualStrings("https://gateway.internal", config.handlers[0].base_url.?);
    try std.testing.expectEqualStrings("users.ts", config.handlers[1].path);
}

test "parseSystemConfig: baseUrl and entry are optional" {
    const json =
        \\{
        \\  "version": 1,
        \\  "entry": "orchestrator",
        \\  "handlers": [
        \\    { "name": "orchestrator", "path": "orchestrator.ts" },
        \\    { "name": "inventory", "path": "inventory.ts" }
        \\  ]
        \\}
    ;
    var config = try parseSystemConfig(std.testing.allocator, json);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("orchestrator", config.entry.?);
    try std.testing.expectEqual(@as(usize, 2), config.handlers.len);
    try std.testing.expectEqual(@as(?[]const u8, null), config.handlers[0].base_url);
    try std.testing.expectEqual(@as(?[]const u8, null), config.handlers[1].base_url);
}

test "parseSystemConfig preserves duplicate unknown trailing and raw-key behavior" {
    const json =
        \\{
        \\  "future": {"nested": [true]},
        \\  "version": 99999999999999999999,
        \\  "entr\u0079": "ignored",
        \\  "entry": "first",
        \\  "entry": "second",
        \\  "handlers": [{"name":"gateway","path":"gateway.ts"}],
        \\  "handlers": [{"name":"users","path":"users.ts"}]
        \\} trailing
    ;
    var config = try parseSystemConfig(std.testing.allocator, json);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), config.version);
    try std.testing.expectEqualStrings("second", config.entry orelse unreachable);
    try std.testing.expectEqual(@as(usize, 2), config.handlers.len);
    try std.testing.expectEqualStrings("gateway", config.handlers[0].name);
    try std.testing.expectEqualStrings("users", config.handlers[1].name);
}

test "parseSystemConfig rejects escaped required handler keys" {
    try std.testing.expectError(
        error.InvalidJson,
        parseSystemConfig(
            std.testing.allocator,
            "{\"handlers\":[{\"na\\u006de\":\"gateway\",\"path\":\"gateway.ts\"}]}",
        ),
    );
}

fn parseSystemConfigAllocationFixture(
    allocator: std.mem.Allocator,
    json: []const u8,
) !void {
    var config = try parseSystemConfig(allocator, json);
    defer config.deinit(allocator);
}

test "parseSystemConfig cleans every allocation failure" {
    const json =
        \\{
        \\  "entry": "gateway",
        \\  "handlers": [
        \\    {"name":"gateway","path":"gateway.ts","baseUrl":"https://gateway.internal"},
        \\    {"name":"users","path":"users.ts"}
        \\  ]
        \\}
    ;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseSystemConfigAllocationFixture,
        .{json},
    );
}
