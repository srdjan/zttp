//! Persistent policy for Pi context compaction only.
//!
//! Precedence is built-in defaults, then `$HOME/.zttp/settings.json`, then
//! `<cwd>/.zttp/settings.json`. Unknown keys and malformed values fail closed;
//! this is intentionally not a general application settings subsystem.

const std = @import("std");
const zts = @import("zts");
const compaction = @import("compaction.zig");
const models = @import("providers/models.zig");

pub const Compaction = struct {
    enabled: bool = true,
    max_input_tokens: u64 = compaction.default_max_input_tokens,
    reserve_tokens: u64 = compaction.default_reserve_tokens,
    keep_recent_tokens: u64 = compaction.default_keep_recent_tokens,

    pub fn core(self: Compaction) compaction.Settings {
        return .{
            .max_input_tokens = self.max_input_tokens,
            .reserve_tokens = self.reserve_tokens,
            .keep_recent_tokens = self.keep_recent_tokens,
        };
    }
};

pub const Settings = struct {
    compaction: Compaction = .{},
};

pub const Issue = enum {
    malformed_json,
    root_not_object,
    unknown_key,
    compaction_not_object,
    wrong_type,
    out_of_range,
    file_too_large,
};

pub const Diagnostic = struct {
    path: []u8,
    key: ?[]u8,
    issue: Issue,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.key) |key| allocator.free(key);
        self.* = undefined;
    }
};

pub const LoadResult = union(enum) {
    loaded: Settings,
    invalid: Diagnostic,
};

const max_settings_bytes: usize = 64 * 1024;

pub fn load(
    allocator: std.mem.Allocator,
    model: *const models.Model,
) !LoadResult {
    var value: Settings = .{};
    if (try homeSettingsPath(allocator)) |path| {
        defer allocator.free(path);
        if (try applyFile(allocator, path, model, &value)) |failure| {
            return .{ .invalid = failure };
        }
    }
    const project_path = try projectSettingsPath(allocator);
    defer allocator.free(project_path);
    if (try applyFile(allocator, project_path, model, &value)) |failure| {
        return .{ .invalid = failure };
    }
    return .{ .loaded = value };
}

fn homeSettingsPath(allocator: std.mem.Allocator) !?[]u8 {
    const raw = std.c.getenv("HOME") orelse return null;
    const home = std.mem.sliceTo(raw, 0);
    if (home.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home, ".zttp", "settings.json" });
}

fn projectSettingsPath(allocator: std.mem.Allocator) ![]u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const cwd_z = try std.Io.Dir.realPathFileAlloc(
        std.Io.Dir.cwd(),
        io_backend.io(),
        ".",
        allocator,
    );
    defer allocator.free(cwd_z);
    return std.fs.path.join(allocator, &.{ cwd_z, ".zttp", "settings.json" });
}

fn applyFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    model: *const models.Model,
    value: *Settings,
) !?Diagnostic {
    const bytes = zts.file_io.readFile(allocator, path, max_settings_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.FileTooBig => return try diagnostic(allocator, path, null, .file_too_large),
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return try diagnostic(allocator, path, null, .malformed_json);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try diagnostic(allocator, path, null, .root_not_object);

    var root_iterator = parsed.value.object.iterator();
    while (root_iterator.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "compaction")) {
            return try diagnostic(allocator, path, entry.key_ptr.*, .unknown_key);
        }
    }
    const section = parsed.value.object.get("compaction") orelse return null;
    if (section != .object) return try diagnostic(allocator, path, "compaction", .compaction_not_object);

    var next = value.*;
    var iterator = section.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "enabled")) {
            if (field != .bool) return try diagnostic(allocator, path, key, .wrong_type);
            next.compaction.enabled = field.bool;
        } else if (std.mem.eql(u8, key, "maxInputTokens")) {
            next.compaction.max_input_tokens = switch (integer(field)) {
                .value => |parsed_integer| parsed_integer,
                .wrong_type => return try diagnostic(allocator, path, key, .wrong_type),
                .out_of_range => return try diagnostic(allocator, path, key, .out_of_range),
            };
        } else if (std.mem.eql(u8, key, "reserveTokens")) {
            next.compaction.reserve_tokens = switch (integer(field)) {
                .value => |parsed_integer| parsed_integer,
                .wrong_type => return try diagnostic(allocator, path, key, .wrong_type),
                .out_of_range => return try diagnostic(allocator, path, key, .out_of_range),
            };
        } else if (std.mem.eql(u8, key, "keepRecentTokens")) {
            next.compaction.keep_recent_tokens = switch (integer(field)) {
                .value => |parsed_integer| parsed_integer,
                .wrong_type => return try diagnostic(allocator, path, key, .wrong_type),
                .out_of_range => return try diagnostic(allocator, path, key, .out_of_range),
            };
        } else {
            return try diagnostic(allocator, path, key, .unknown_key);
        }
    }
    if (!inRange(next.compaction, model)) {
        return try diagnostic(allocator, path, rangeKey(next.compaction, model), .out_of_range);
    }
    value.* = next;
    return null;
}

const ParsedInteger = union(enum) {
    value: u64,
    wrong_type,
    out_of_range,
};

fn integer(value: std.json.Value) ParsedInteger {
    if (value != .integer) return .wrong_type;
    if (value.integer <= 0) return .out_of_range;
    return .{ .value = std.math.cast(u64, value.integer) orelse return .out_of_range };
}

fn inRange(value: Compaction, model: *const models.Model) bool {
    const context: u64 = model.capabilities.context_window_tokens;
    return value.max_input_tokens > 0 and value.max_input_tokens <= context and
        value.reserve_tokens >= 4 and value.reserve_tokens < context and
        value.keep_recent_tokens > 0 and value.keep_recent_tokens <= context;
}

pub fn validateCompaction(value: Compaction, model: *const models.Model) !void {
    if (!inRange(value, model)) return error.InvalidCompactionSettings;
}

fn rangeKey(value: Compaction, model: *const models.Model) []const u8 {
    const context: u64 = model.capabilities.context_window_tokens;
    if (value.max_input_tokens == 0 or value.max_input_tokens > context) return "maxInputTokens";
    if (value.reserve_tokens < 4 or value.reserve_tokens >= context) return "reserveTokens";
    return "keepRecentTokens";
}

fn diagnostic(
    allocator: std.mem.Allocator,
    path: []const u8,
    key: ?[]const u8,
    issue: Issue,
) !Diagnostic {
    return .{
        .path = try allocator.dupe(u8, path),
        .key = if (key) |present| try allocator.dupe(u8, present) else null,
        .issue = issue,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "settings file overlays compaction values and rejects exact unknown key" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "settings.json", .data = "{\"compaction\":{\"enabled\":false,\"maxInputTokens\":30000," ++
        "\"reserveTokens\":12000,\"keepRecentTokens\":9000}}" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const root = try allocator.dupe(u8, root_buffer[0..root_len]);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "settings.json" });
    defer allocator.free(path);
    var value: Settings = .{};
    const model = models.defaultForProvider(.anthropic);
    try testing.expect((try applyFile(allocator, path, model, &value)) == null);
    try testing.expect(!value.compaction.enabled);
    try testing.expectEqual(@as(u64, 30_000), value.compaction.max_input_tokens);
    try testing.expectEqual(@as(u64, 12_000), value.compaction.reserve_tokens);
    try testing.expectEqual(@as(u64, 9_000), value.compaction.keep_recent_tokens);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "settings.json", .data = "{\"compaction\":{\"apiKey\":\"must-not-be-accepted\"}}" });
    var invalid_value: Settings = .{};
    var invalid = (try applyFile(allocator, path, model, &invalid_value)) orelse
        return error.TestExpectedDiagnostic;
    defer invalid.deinit(allocator);
    try testing.expectEqual(Issue.unknown_key, invalid.issue);
    try testing.expectEqualStrings("apiKey", invalid.key orelse return error.TestExpectedKey);
    try testing.expectEqualStrings(path, invalid.path);
}

test "settings reject malformed wrong-type and model-out-of-range values" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const root = try allocator.dupe(u8, root_buffer[0..root_len]);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "settings.json" });
    defer allocator.free(path);
    const model = models.resolveForProvider(.local, "mlx-community/Qwen3-8B-4bit") catch unreachable;

    const cases = [_]struct { body: []const u8, issue: Issue, key: ?[]const u8 }{
        .{ .body = "{", .issue = .malformed_json, .key = null },
        .{ .body = "[]", .issue = .root_not_object, .key = null },
        .{ .body = "{\"compaction\":{\"enabled\":1}}", .issue = .wrong_type, .key = "enabled" },
        .{ .body = "{\"compaction\":{\"keepRecentTokens\":-1}}", .issue = .out_of_range, .key = "keepRecentTokens" },
        .{ .body = "{\"compaction\":{\"reserveTokens\":40960}}", .issue = .out_of_range, .key = "reserveTokens" },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "settings.json", .data = case.body });
        var value: Settings = .{};
        var invalid = (try applyFile(allocator, path, model, &value)) orelse
            return error.TestExpectedDiagnostic;
        defer invalid.deinit(allocator);
        try testing.expectEqual(case.issue, invalid.issue);
        if (case.key) |key| {
            try testing.expectEqualStrings(key, invalid.key orelse return error.TestExpectedKey);
        } else try testing.expect(invalid.key == null);
    }
}

test "project compaction values overlay user values without resetting other keys" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "user.json",
        .data = "{\"compaction\":{\"enabled\":false,\"maxInputTokens\":30000}}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "project.json",
        .data = "{\"compaction\":{\"keepRecentTokens\":7000}}",
    });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const user_path = try std.fs.path.join(allocator, &.{ root, "user.json" });
    defer allocator.free(user_path);
    const project_path = try std.fs.path.join(allocator, &.{ root, "project.json" });
    defer allocator.free(project_path);
    const model = models.defaultForProvider(.anthropic);
    var value: Settings = .{};

    try testing.expect((try applyFile(allocator, user_path, model, &value)) == null);
    try testing.expect((try applyFile(allocator, project_path, model, &value)) == null);
    try testing.expect(!value.compaction.enabled);
    try testing.expectEqual(@as(u64, 30_000), value.compaction.max_input_tokens);
    try testing.expectEqual(@as(u64, 7_000), value.compaction.keep_recent_tokens);
    try testing.expectEqual(compaction.default_reserve_tokens, value.compaction.reserve_tokens);
}
