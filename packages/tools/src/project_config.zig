const std = @import("std");

const zts = @import("zts");
pub const retired_authority = @import("retired_authority.zig");

/// The suite that `zttp test` runs when it receives no path, relative to the
/// project root.
pub const default_test_suite = "tests/handler.test.jsonl";

pub const ProjectConfig = struct {
    root_dir: []const u8,
    manifest_path: []const u8,
    entry: []const u8,
    port: u16 = 3000,
    host: []const u8 = "127.0.0.1",
    static_dir: ?[]const u8 = null,
    sqlite: ?[]const u8 = null,
    /// Path to the capability-policy JSON this project's handlers are checked
    /// against. Resolved like `sqlite`: relative to the manifest directory.
    policy: ?[]const u8 = null,
    outbound_http: bool = false,
    outbound_hosts: []const []const u8 = &.{},
    /// Proof properties the expert holds every change set to (`requiredProperties`). The loader
    /// checks no name; the expert proof reports an unknown one.
    required_properties: []const []const u8 = &.{},

    pub fn deinit(self: *ProjectConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.root_dir);
        allocator.free(self.manifest_path);
        allocator.free(self.entry);
        allocator.free(self.host);
        if (self.static_dir) |path| allocator.free(path);
        if (self.sqlite) |path| allocator.free(path);
        if (self.policy) |path| allocator.free(path);
        for (self.outbound_hosts) |host| allocator.free(host);
        allocator.free(self.outbound_hosts);
        for (self.required_properties) |name| allocator.free(name);
        allocator.free(self.required_properties);
    }

    pub fn resolvePath(self: *const ProjectConfig, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) {
            return try allocator.dupe(u8, path);
        }
        return try std.fs.path.resolve(allocator, &.{ self.root_dir, path });
    }

    pub fn resolvedEntry(self: *const ProjectConfig, allocator: std.mem.Allocator) ![]u8 {
        return try self.resolvePath(allocator, self.entry);
    }

    pub fn resolvedStaticDir(self: *const ProjectConfig, allocator: std.mem.Allocator) !?[]u8 {
        const path = self.static_dir orelse return null;
        return try self.resolvePath(allocator, path);
    }

    pub fn resolvedSqlitePath(self: *const ProjectConfig, allocator: std.mem.Allocator) !?[]u8 {
        const path = self.sqlite orelse return null;
        return try self.resolvePath(allocator, path);
    }

    pub fn resolvedPolicyPath(self: *const ProjectConfig, allocator: std.mem.Allocator) !?[]u8 {
        const path = self.policy orelse return null;
        return try self.resolvePath(allocator, path);
    }

    /// Load the configured capability policy. Null means the manifest declares
    /// no policy; a configured path that cannot be read is an error so callers
    /// cannot publish a policy-free verdict by accident. Caller frees.
    pub fn readPolicySource(self: *const ProjectConfig, allocator: std.mem.Allocator) !?[]u8 {
        const path = try self.resolvedPolicyPath(allocator) orelse return null;
        defer allocator.free(path);
        return try zts.file_io.readFile(allocator, path, 1024 * 1024);
    }
};

/// The subset of `zttp.json` entries consumed by static analysis (`zts`).
/// Caller frees via `deinit`.
pub const AnalysisContext = struct {
    found: bool = false,
    sqlite: ?[]u8 = null,
    policy: ?[]u8 = null,
    required_properties: []const []const u8 = &.{},

    pub fn deinit(self: *AnalysisContext, allocator: std.mem.Allocator) void {
        if (self.sqlite) |p| allocator.free(p);
        if (self.policy) |p| allocator.free(p);
        for (self.required_properties) |name| allocator.free(name);
        allocator.free(self.required_properties);
        self.* = .{};
    }

    pub fn readPolicySource(self: *const AnalysisContext, allocator: std.mem.Allocator) !?[]u8 {
        const path = self.policy orelse return null;
        return try zts.file_io.readFile(allocator, path, 1024 * 1024);
    }
};

/// The path of the nearest `zttp.json` at or above `start_path`, or null when
/// no manifest exists. A null `start_path` starts at the current directory.
/// Caller frees the returned path. `discover` loads this manifest.
pub fn nearestManifestPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: ?[]const u8,
) !?[]u8 {
    return nearestManifestPathBounded(allocator, io, start_path, null);
}

/// Like `nearestManifestPath`, but stops upward traversal at `stop_at_dir`
/// when provided and never inspects or escapes above it.
pub fn nearestManifestPathBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: ?[]const u8,
    stop_at_dir: ?[]const u8,
) !?[]u8 {
    const stop_norm = if (stop_at_dir) |stop| try canonicalizeStopDir(allocator, io, stop) else null;
    defer if (stop_norm) |s| allocator.free(s);

    const start_dir = try findStartDirBounded(allocator, io, start_path, stop_norm != null);
    defer allocator.free(start_dir);

    var current = try allocator.dupe(u8, start_dir);
    defer allocator.free(current);

    while (true) {
        if (stop_norm) |stop| {
            if (!isSameOrDescendant(current, stop)) break;
        }
        const manifest_path = try std.fs.path.resolve(allocator, &.{ current, "zttp.json" });

        if (std.Io.Dir.accessAbsolute(io, manifest_path, .{})) |_| {
            return manifest_path;
        } else |err| {
            allocator.free(manifest_path);
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }

        if (stop_norm) |stop| {
            if (std.mem.eql(u8, current, stop)) break;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return null;
}

pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: ?[]const u8,
) !?ProjectConfig {
    return discoverBounded(allocator, io, start_path, null);
}

pub fn discoverBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: ?[]const u8,
    stop_at_dir: ?[]const u8,
) !?ProjectConfig {
    const manifest_path = try nearestManifestPathBounded(allocator, io, start_path, stop_at_dir) orelse return null;
    defer allocator.free(manifest_path);
    return try loadAbsolute(allocator, io, manifest_path);
}

/// Discover resolved SQL schema, capability policy, and required properties
/// from the nearest `zttp.json` walking upward from `start_path` (or cwd),
/// bounded to `stop_at_dir` when provided.
pub fn discoverAnalysisContext(
    allocator: std.mem.Allocator,
    start_path: ?[]const u8,
    stop_at_dir: ?[]const u8,
) !AnalysisContext {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var project = try discoverBounded(allocator, io, start_path, stop_at_dir);
    defer if (project) |*p| p.deinit(allocator);
    const cfg = if (project) |*p| p else return .{};

    var ctx = AnalysisContext{
        .found = true,
        .sqlite = try cfg.resolvedSqlitePath(allocator),
    };
    errdefer ctx.deinit(allocator);
    ctx.policy = try cfg.resolvedPolicyPath(allocator);
    ctx.required_properties = try dupeStringSlice(allocator, cfg.required_properties);
    return ctx;
}

fn dupeStringSlice(allocator: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, names.len);
    var done: usize = 0;
    errdefer {
        for (copy[0..done]) |name| allocator.free(name);
        allocator.free(copy);
    }
    for (names, 0..) |name, index| {
        copy[index] = try allocator.dupe(u8, name);
        done = index + 1;
    }
    return copy;
}

pub fn loadAbsolute(
    allocator: std.mem.Allocator,
    io: std.Io,
    manifest_path: []const u8,
) !ProjectConfig {
    const bytes = try zts.file_io.readFile(allocator, manifest_path, 1024 * 1024);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProjectConfig;
    const obj = parsed.value.object;

    if (retired_authority.first(retired_authority.projectFacts(obj))) |feature| {
        if (!@import("builtin").is_test) {
            std.debug.print("zttp.json uses retired runtime authority: {s}\n", .{feature.sentence()});
        }
        return error.UnsupportedRuntimeAuthority;
    }

    const root_dir_src = std.fs.path.dirname(manifest_path) orelse return error.InvalidProjectConfig;
    const automatic_system_path = try std.fs.path.resolve(allocator, &.{ root_dir_src, "system.json" });
    defer allocator.free(automatic_system_path);
    if (std.Io.Dir.accessAbsolute(io, automatic_system_path, .{})) |_| {
        if (!@import("builtin").is_test) {
            std.debug.print("Project uses retired runtime authority: {s}\n", .{retired_authority.Feature.system_config.sentence()});
        }
        return error.UnsupportedRuntimeAuthority;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var config = blk: {
        const entry = try dupStringField(allocator, obj, "entry", "src/handler.ts");
        errdefer allocator.free(entry);
        const host = try dupStringField(allocator, obj, "host", "127.0.0.1");
        errdefer allocator.free(host);
        const root_dir = try allocator.dupe(u8, root_dir_src);
        errdefer allocator.free(root_dir);
        const manifest_path_copy = try allocator.dupe(u8, manifest_path);
        errdefer allocator.free(manifest_path_copy);
        const port = try parseU16Field(obj, "port", 3000);
        const static_dir = try dupOptionalStringField(allocator, obj, "staticDir");
        errdefer if (static_dir) |p| allocator.free(p);
        const sqlite = try dupOptionalStringField(allocator, obj, "sqlite");
        errdefer if (sqlite) |p| allocator.free(p);
        const policy = try dupOptionalStringField(allocator, obj, "policy");
        errdefer if (policy) |p| allocator.free(p);
        const outbound_http = try parseBoolField(obj, "outboundHttp", false);
        const outbound_hosts = try dupStringArrayField(allocator, obj, "outboundHosts");
        break :blk ProjectConfig{
            .root_dir = root_dir,
            .manifest_path = manifest_path_copy,
            .entry = entry,
            .port = port,
            .host = host,
            .static_dir = static_dir,
            .sqlite = sqlite,
            .policy = policy,
            .outbound_http = outbound_http,
            .outbound_hosts = outbound_hosts,
        };
    };
    errdefer config.deinit(allocator);
    config.required_properties = dupStringArrayField(allocator, obj, "requiredProperties") catch |err| switch (err) {
        error.InvalidProjectConfig => return error.InvalidRequiredProperties,
        else => return err,
    };
    if (config.static_dir == null) {
        const public_path = try std.fs.path.resolve(allocator, &.{ config.root_dir, "public" });
        defer allocator.free(public_path);
        if (std.Io.Dir.accessAbsolute(io, public_path, .{})) |_| {
            config.static_dir = try allocator.dupe(u8, "public");
        } else |_| {}
    }

    return config;
}

fn findStartDirBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: ?[]const u8,
    stop_bounded: bool,
) ![]u8 {
    const input = start_path orelse return try dupCurrentDir(allocator, io);
    const normalized = try normalizeAbsolutePath(allocator, io, input);
    // Freed on every path except the one that hands `normalized` back to the
    // caller, which clears `owned` to transfer ownership. Covers the error
    // paths too.
    var owned = true;
    defer if (owned) allocator.free(normalized);

    if (std.mem.eql(u8, std.fs.path.basename(input), "zttp.json")) {
        const dir_name = std.fs.path.dirname(normalized) orelse return error.InvalidProjectConfig;
        if (stop_bounded) return try canonicalizePathOrDupe(allocator, io, dir_name);
        return try allocator.dupe(u8, dir_name);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, normalized, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (stop_bounded) {
                const dir_name = std.fs.path.dirname(normalized) orelse return try dupCurrentDir(allocator, io);
                return try canonicalizePathOrDupe(allocator, io, dir_name);
            }
            return try dupCurrentDir(allocator, io);
        },
        error.NotDir => {
            const dir_name = std.fs.path.dirname(normalized) orelse return error.InvalidProjectConfig;
            if (stop_bounded) return try canonicalizePathOrDupe(allocator, io, dir_name);
            return try allocator.dupe(u8, dir_name);
        },
        else => return err,
    };
    dir.close(io);
    if (stop_bounded) return try canonicalizePathOrDupe(allocator, io, normalized);
    owned = false;
    return normalized;
}

fn canonicalizePathOrDupe(allocator: std.mem.Allocator, io: std.Io, abs_path: []const u8) ![]u8 {
    if (std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, abs_path, allocator)) |resolved| {
        defer allocator.free(resolved);
        return try allocator.dupe(u8, resolved);
    } else |_| {}
    return try allocator.dupe(u8, abs_path);
}

fn canonicalizeStopDir(allocator: std.mem.Allocator, io: std.Io, stop_at_dir: []const u8) ![]u8 {
    const normalized = try normalizeAbsolutePath(allocator, io, stop_at_dir);
    defer allocator.free(normalized);
    return try canonicalizePathOrDupe(allocator, io, normalized);
}

fn isSameOrDescendant(path: []const u8, root: []const u8) bool {
    if (root.len == 1 and root[0] == '/') return path.len > 0 and path[0] == '/';
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == std.fs.path.sep;
}

fn dupCurrentDir(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const path_z = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, ".", allocator);
    defer allocator.free(path_z);
    return try allocator.dupe(u8, path_z);
}

fn normalizeAbsolutePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    }

    const cwd = try dupCurrentDir(allocator, io);
    defer allocator.free(cwd);
    return try std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn dupStringField(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    const value = obj.get(key) orelse return try allocator.dupe(u8, default_value);
    if (value != .string) return error.InvalidProjectConfig;
    return try allocator.dupe(u8, value.string);
}

fn dupOptionalStringField(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = obj.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidProjectConfig;
    return try allocator.dupe(u8, value.string);
}

fn dupStringArrayField(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ![]const []const u8 {
    const value = obj.get(key) orelse return try allocator.alloc([]const u8, 0);
    if (value != .array) return error.InvalidProjectConfig;

    const items = try allocator.alloc([]const u8, value.array.items.len);
    // Free the populated prefix on failure; the outer `free(items)` only
    // releases the backing array, not the duped strings.
    var items_initialized: usize = 0;
    errdefer {
        for (items[0..items_initialized]) |s| allocator.free(s);
        allocator.free(items);
    }

    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidProjectConfig;
        items[i] = try allocator.dupe(u8, item.string);
        items_initialized = i + 1;
    }
    return items;
}

fn parseBoolField(obj: std.json.ObjectMap, key: []const u8, default_value: bool) !bool {
    const value = obj.get(key) orelse return default_value;
    return switch (value) {
        .bool => value.bool,
        else => error.InvalidProjectConfig,
    };
}

fn parseU16Field(obj: std.json.ObjectMap, key: []const u8, default_value: u16) !u16 {
    const value = obj.get(key) orelse return default_value;
    if (value != .integer) return error.InvalidProjectConfig;
    if (value.integer < 0 or value.integer > std.math.maxInt(u16)) return error.InvalidProjectConfig;
    return @intCast(value.integer);
}

test "project config parses and defaults public directory" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.Io.Dir.createDirPath(tmp.dir, io, "public");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zttp.json",
        .data =
        \\{
        \\  "entry": "src/app.ts",
        \\  "port": 4000,
        \\  "host": "0.0.0.0",
        \\  "outboundHttp": true,
        \\  "outboundHosts": ["api.internal"],
        \\  "requiredProperties": ["state_isolated", "cost_bounded"]
        \\}
        ,
    });

    // `tmp.sub_path` names a directory under `.zig-cache/tmp`, not one relative
    // to the current directory, so resolving against it pointed at a path that
    // does not exist. Ask the handle where it actually is.
    const tmp_root = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);

    const manifest_path = try std.fs.path.resolve(std.testing.allocator, &.{ tmp_root, "zttp.json" });
    defer std.testing.allocator.free(manifest_path);

    var config = try loadAbsolute(std.testing.allocator, io, manifest_path);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("src/app.ts", config.entry);
    try std.testing.expectEqual(@as(u16, 4000), config.port);
    try std.testing.expectEqualStrings("0.0.0.0", config.host);
    try std.testing.expect(config.outbound_http);
    try std.testing.expectEqual(@as(usize, 1), config.outbound_hosts.len);
    try std.testing.expectEqualStrings("api.internal", config.outbound_hosts[0]);
    try std.testing.expectEqual(@as(usize, 2), config.required_properties.len);
    try std.testing.expectEqualStrings("state_isolated", config.required_properties[0]);
    try std.testing.expectEqualStrings("cost_bounded", config.required_properties[1]);
    try std.testing.expect(config.static_dir != null);
    try std.testing.expectEqualStrings("public", config.static_dir.?);
}

test "discover finds manifest from relative handler path" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.Io.Dir.createDirPath(tmp.dir, io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zttp.json",
        .data =
        \\{
        \\  "entry": "src/handler.ts"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/handler.ts",
        .data = "function handler(req) { return Response.text('ok') }\n",
    });

    const cwd = try dupCurrentDir(std.testing.allocator, io);
    defer std.testing.allocator.free(cwd);

    const tmp_root = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);

    const handler_abs = try std.fs.path.resolve(std.testing.allocator, &.{ tmp_root, "src", "handler.ts" });
    defer std.testing.allocator.free(handler_abs);

    const relative_handler = try std.fs.path.relative(std.testing.allocator, cwd, null, cwd, handler_abs);
    defer std.testing.allocator.free(relative_handler);

    var config = (try discover(std.testing.allocator, io, relative_handler)).?;
    defer config.deinit(std.testing.allocator);

    const expected_root = try std.fs.path.resolve(std.testing.allocator, &.{tmp_root});
    defer std.testing.allocator.free(expected_root);

    try std.testing.expectEqualStrings(expected_root, config.root_dir);
    try std.testing.expectEqualStrings("src/handler.ts", config.entry);
}

test "project discovery rejects every retired authority configuration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manifests = [_][]const u8{
        "{\"durableDir\":\".zttp/durable\"}",
        "{\"durableDir\":null}",
        "{\"system\":\"system.json\"}",
        "{\"system\":null}",
        "{\"declaration\":\"declaration.json\"}",
        "{\"declaration\":null}",
        "{\"invariants\":\"invariant.json\",\"ledger\":\"ledger.db\"}",
        "{\"invariants\":null}",
        "{\"ledger\":null}",
        "{\"auth\":{\"keyEnv\":\"TOOL_KEY\",\"tenantClaim\":\"org\"}}",
        "{\"auth\":null}",
        "{\"credentials\":{\"weather\":{\"env\":\"WEATHER_KEY\",\"endpoint\":\"https://api.weather.example\",\"header\":\"authorization\",\"methods\":[\"GET\"],\"paths\":[\"/v1/forecast\"]}}}",
        "{\"credentials\":null}",
    };
    for (manifests) |body| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "zttp.json", .data = body });
        try tmp.dir.writeFile(io, .{ .sub_path = "invariant.json", .data =
            \\{"version":1,"kind":"balance_conservation_v1","ledger":"main","currencies":[{"code":"USD","scale":2}]}
        });
        const manifest = try tmp.dir.realPathFileAlloc(io, "zttp.json", allocator);
        defer allocator.free(manifest);
        if (discover(allocator, io, manifest)) |config_optional| {
            var config = config_optional orelse return error.TestExpectedError;
            config.deinit(allocator);
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.UnsupportedRuntimeAuthority, err);
        }
    }
}

test "project discovery refuses automatic system configuration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zttp.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "system.json",
        .data = "{\"version\":1,\"handlers\":[]}",
    });
    const manifest = try tmp.dir.realPathFileAlloc(io, "zttp.json", allocator);
    defer allocator.free(manifest);
    try std.testing.expectError(
        error.UnsupportedRuntimeAuthority,
        discover(allocator, io, manifest),
    );
}

test "nearestManifestPath names the manifest nearest to the start path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "app/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/zttp.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/sub/zttp.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/sub/handler.ts", .data = "" });

    const handler = try tmp.dir.realPathFileAlloc(io, "app/sub/handler.ts", allocator);
    defer allocator.free(handler);
    const expected = try tmp.dir.realPathFileAlloc(io, "app/sub/zttp.json", allocator);
    defer allocator.free(expected);
    const nearest = (try nearestManifestPath(allocator, io, handler)).?;
    defer allocator.free(nearest);
    try std.testing.expectEqualStrings(expected, nearest);
}

test "loadAbsolute frees earlier fields when a later field is invalid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const invalid_manifests = [_][]const u8{
        "{\"entry\":\"src/app.ts\",\"host\":\"0.0.0.0\",\"port\":\"bad\"}",
        "{\"entry\":\"src/app.ts\",\"host\":\"0.0.0.0\",\"staticDir\":\"pub\",\"sqlite\":\"db.sql\",\"policy\":\"pol.json\",\"outboundHttp\":\"yes\"}",
        "{\"entry\":\"src/app.ts\",\"host\":\"0.0.0.0\",\"staticDir\":\"pub\",\"sqlite\":\"db.sql\",\"policy\":\"pol.json\",\"outboundHosts\":[\"ok\",123]}",
    };
    for (invalid_manifests) |body| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "zttp.json", .data = body });
        const manifest = try tmp.dir.realPathFileAlloc(io, "zttp.json", allocator);
        defer allocator.free(manifest);
        try std.testing.expectError(error.InvalidProjectConfig, loadAbsolute(allocator, io, manifest));
    }
}

test "discoverAnalysisContext respects stop_at_dir and resolves sqlite and policy" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.Io.Dir.createDirPath(tmp.dir, io, "workspace/sub");
    try tmp.dir.writeFile(io, .{
        .sub_path = "zttp.json",
        .data = "{\"sqlite\":\"parent.sql\",\"policy\":\"parent_policy.json\"}",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "workspace/sub/handler.ts", .data = "" });

    const root_dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, "workspace", allocator);
    defer allocator.free(root_dir);
    const handler = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, "workspace/sub/handler.ts", allocator);
    defer allocator.free(handler);

    // Bounded to workspace: ignores ancestor zttp.json outside workspace.
    var bounded = try discoverAnalysisContext(allocator, handler, root_dir);
    defer bounded.deinit(allocator);
    try std.testing.expect(!bounded.found);
    try std.testing.expect(bounded.sqlite == null);
    try std.testing.expect(bounded.policy == null);

    // Once workspace itself has zttp.json, bounded discovery resolves its paths.
    try tmp.dir.writeFile(io, .{
        .sub_path = "workspace/zttp.json",
        .data = "{\"sqlite\":\"db.sql\",\"policy\":\"pol.json\"}",
    });
    var inside = try discoverAnalysisContext(allocator, handler, root_dir);
    defer inside.deinit(allocator);
    try std.testing.expect(inside.found);
    try std.testing.expect(std.mem.endsWith(u8, inside.sqlite.?, "workspace/db.sql"));
    try std.testing.expect(std.mem.endsWith(u8, inside.policy.?, "workspace/pol.json"));
}
