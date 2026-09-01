//! Capability-policy context for file-backed serve commands.
//!
//! Project discovery is always available. The developer CLI supplies the full
//! analyzer; the minimal deployed runtime rejects a configured source policy
//! because it cannot prove the source against it.

const std = @import("std");
const feature_options = @import("runtime_feature_options");
const project_config_mod = @import("project_config");

const analyzer = if (feature_options.enable_live_reload)
    @import("serve_policy_analyzer.zig")
else
    @import("serve_policy_unavailable.zig");

pub const CheckedPolicy = @import("serve_policy_types.zig").CheckedPolicy;

pub const ConfiguredPolicy = struct {
    path: []u8,
    source: []u8,

    pub fn deinit(self: *ConfiguredPolicy, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        self.* = undefined;
    }
};

pub fn discoverConfiguredPolicy(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
) !?ConfiguredPolicy {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    var project = try project_config_mod.discover(allocator, io_backend.io(), handler_path);
    defer if (project) |*config| config.deinit(allocator);
    const config = if (project) |*value| value else return null;
    const path = try config.resolvedPolicyPath(allocator) orelse return null;
    errdefer allocator.free(path);
    const source = try config.readPolicySource(allocator) orelse return error.PolicyContextFailed;
    return .{ .path = path, .source = source };
}

pub const validateConfiguredPolicy = analyzer.validateConfiguredPolicy;

test "configured serve policy is discovered beside the project manifest" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\",\"policy\":\"policy.json\"}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "policy.json",
        .data = "{\"env\":{\"allow\":[\"APP_NAME\"]}}",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/handler.ts", .data = "" });

    const handler_path = try tmp.dir.realPathFileAlloc(testing.io, "src/handler.ts", testing.allocator);
    defer testing.allocator.free(handler_path);
    var policy = (try discoverConfiguredPolicy(testing.allocator, handler_path)) orelse
        return error.TestExpectedPolicy;
    defer policy.deinit(testing.allocator);
    try testing.expectStringEndsWith(policy.path, "policy.json");
    try testing.expectEqualStrings("{\"env\":{\"allow\":[\"APP_NAME\"]}}", policy.source);
}
