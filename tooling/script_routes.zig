//! Compare the tracked script inventory with executable graph/driver routes.
const std = @import("std");

pub const Report = struct {
    checked: usize = 0,
    manual: usize = 0,
    violations: usize = 0,
    details: std.ArrayList(u8) = .empty,
    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.details.deinit(allocator);
    }
};

pub fn audit(allocator: std.mem.Allocator, inventory: []const u8, executed: []const u8, allow: []const u8) !Report {
    var report: Report = .{};
    errdefer report.deinit(allocator);
    var scripts: std.StringHashMap(void) = .init(allocator);
    defer scripts.deinit();
    var names = std.mem.tokenizeScalar(u8, inventory, 0);
    while (names.next()) |path| {
        if (!std.mem.startsWith(u8, path, "scripts/") or !std.mem.endsWith(u8, path, ".sh")) return error.InvalidScriptInventory;
        if (scripts.contains(path)) return error.DuplicateScript;
        try scripts.put(path, {});
    }
    report.checked = scripts.count();
    var routes: std.StringHashMap(void) = .init(allocator);
    defer routes.deinit();
    var paths = std.mem.tokenizeScalar(u8, executed, 0);
    while (paths.next()) |path| {
        if (!std.mem.startsWith(u8, path, "scripts/") or !std.mem.endsWith(u8, path, ".sh")) return error.InvalidScriptRoute;
        try routes.put(path, {});
    }
    var allowed: std.StringHashMap(void) = .init(allocator);
    defer allowed.deinit();
    var lines = std.mem.splitScalar(u8, allow, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next().?;
        if (fields.next() == null) return error.MissingManualReason;
        if (allowed.contains(name)) return error.DuplicateManualRow;
        try allowed.put(name, {});
        report.manual += 1;
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "scripts/{s}", .{name});
        if (!scripts.contains(path) or routes.contains(path)) {
            report.violations += 1;
            try report.details.print(allocator, "  {s}: manual row is stale (missing script or executable route exists)\n", .{name});
        }
    }
    var it = scripts.keyIterator();
    while (it.next()) |path| {
        if (routes.contains(path.*) or allowed.contains(path.*["scripts/".len..])) continue;
        report.violations += 1;
        try report.details.print(allocator, "  {s}: no executable route or stated manual reason\n", .{path.*});
    }
    return report;
}

test "removed script execution cannot be replaced by a comment or display label" {
    const allocator = std.testing.allocator;
    // Labels and comments live outside executable census data. Removing the
    // route leaves the script uncovered regardless of their retained text.
    const retained_label = "bash scripts/removed.sh";
    _ = retained_label;
    var removed = try audit(allocator, "scripts/removed.sh\x00", "", "");
    defer removed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), removed.checked);
    try std.testing.expectEqual(@as(usize, 1), removed.violations);
    var routed = try audit(allocator, "scripts/removed.sh\x00", "scripts/removed.sh\x00", "");
    defer routed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), routed.violations);
}

test "manual declarations ratchet both missing and now executed scripts" {
    const allocator = std.testing.allocator;
    var report = try audit(allocator, "scripts/manual.sh\x00", "scripts/manual.sh\x00", "manual.sh operator-command\nmissing.sh absent\n");
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), report.violations);
    try std.testing.expectError(error.MissingManualReason, audit(allocator, "scripts/manual.sh\x00", "", "manual.sh\n"));
}

test "automatic routes preserve spaces and embedded newlines in script paths" {
    const path = "scripts/odd \r\nname.sh\x00";
    var report = try audit(std.testing.allocator, path, path, "");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.checked);
    try std.testing.expectEqual(@as(usize, 0), report.violations);
}
