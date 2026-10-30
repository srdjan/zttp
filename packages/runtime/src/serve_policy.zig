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

/// The capability policy that governs `handler_path`, from the manifest nearest
/// to that path. `project` is the manifest that the start already loaded. It
/// is reused only when it is that nearest manifest; a nearer manifest between
/// the handler and the project root is loaded instead, because it may declare
/// a different policy and a missed policy is less restrictive.
pub fn configuredPolicy(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
    project: ?*const project_config_mod.ProjectConfig,
) !?ConfiguredPolicy {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    const manifest_path = try project_config_mod.nearestManifestPath(allocator, io, handler_path) orelse return null;
    defer allocator.free(manifest_path);

    if (project) |loaded| {
        if (std.mem.eql(u8, loaded.manifest_path, manifest_path)) return try policyOf(allocator, loaded);
    }
    var nearest = try project_config_mod.loadAbsolute(allocator, io, manifest_path);
    defer nearest.deinit(allocator);
    return try policyOf(allocator, &nearest);
}

fn policyOf(
    allocator: std.mem.Allocator,
    config: *const project_config_mod.ProjectConfig,
) !?ConfiguredPolicy {
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
    var policy = (try configuredPolicy(testing.allocator, handler_path, null)) orelse
        return error.TestExpectedPolicy;
    defer policy.deinit(testing.allocator);
    try testing.expectStringEndsWith(policy.path, "policy.json");
    try testing.expectEqualStrings("{\"env\":{\"allow\":[\"APP_NAME\"]}}", policy.source);
}

test "configured serve policy reuses the project that is the nearest manifest" {
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
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "other.json",
        .data = "{\"env\":{\"allow\":[\"OTHER_NAME\"]}}",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/handler.ts", .data = "" });

    const handler_path = try tmp.dir.realPathFileAlloc(testing.io, "src/handler.ts", testing.allocator);
    defer testing.allocator.free(handler_path);
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    var project = (try project_config_mod.discover(testing.allocator, io_backend.io(), handler_path)).?;
    defer project.deinit(testing.allocator);
    // The project value decides the policy: the manifest file is not read again.
    testing.allocator.free(project.policy.?);
    project.policy = try testing.allocator.dupe(u8, "other.json");

    var policy = (try configuredPolicy(testing.allocator, handler_path, &project)) orelse
        return error.TestExpectedPolicy;
    defer policy.deinit(testing.allocator);
    try testing.expectStringEndsWith(policy.path, "other.json");
    try testing.expectEqualStrings("{\"env\":{\"allow\":[\"OTHER_NAME\"]}}", policy.source);
}

test "configured serve policy comes from a nearer manifest than the project" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"sub/handler.ts\",\"policy\":\"policy.json\"}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "policy.json",
        .data = "{\"env\":{\"allow\":[\"APP_NAME\"]}}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sub/zttp.json",
        .data = "{\"entry\":\"handler.ts\",\"policy\":\"sub-policy.json\"}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sub/sub-policy.json",
        .data = "{\"env\":{\"allow\":[\"SUB_NAME\"]}}",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/handler.ts", .data = "" });

    const root_manifest = try tmp.dir.realPathFileAlloc(testing.io, "zttp.json", testing.allocator);
    defer testing.allocator.free(root_manifest);
    const handler_path = try tmp.dir.realPathFileAlloc(testing.io, "sub/handler.ts", testing.allocator);
    defer testing.allocator.free(handler_path);
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    var project = (try project_config_mod.discover(testing.allocator, io_backend.io(), root_manifest)).?;
    defer project.deinit(testing.allocator);

    var policy = (try configuredPolicy(testing.allocator, handler_path, &project)) orelse
        return error.TestExpectedPolicy;
    defer policy.deinit(testing.allocator);
    try testing.expectStringEndsWith(policy.path, "sub-policy.json");
    try testing.expectEqualStrings("{\"env\":{\"allow\":[\"SUB_NAME\"]}}", policy.source);
}
