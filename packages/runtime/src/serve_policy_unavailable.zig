const std = @import("std");
const builtin = @import("builtin");

pub fn validateConfiguredPolicy(
    _: std.mem.Allocator,
    _: []const u8,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
) !void {
    if (!builtin.is_test) {
        std.debug.print(
            "configured source policies require the developer analyzer; use `zttp serve` or build a self-contained artifact\n",
            .{},
        );
    }
    return error.PolicyValidationUnavailable;
}
