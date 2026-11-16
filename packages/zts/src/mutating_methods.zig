//! Leaf helper: the array methods that write through their receiver.

const std = @import("std");

/// The array methods that write through their receiver.
///
/// Closed against what the engine implements rather than against the
/// JavaScript surface: `pop`, `shift`, `unshift`, `splice`, `sort`, `reverse`,
/// `fill`, and `copyWithin` mutate too and are not admitted, so listing them
/// here would describe a call that cannot be written. `slice` returns a new
/// array and is deliberately absent.
pub const mutating_array_methods = [_][]const u8{"push"};

/// True when `method` names an array method that writes through its receiver.
pub fn isMutatingArrayMethod(method: []const u8) bool {
    for (mutating_array_methods) |name| {
        if (std.mem.eql(u8, method, name)) return true;
    }
    return false;
}

test "the mutating list names push and no reader" {
    try std.testing.expect(isMutatingArrayMethod("push"));
    try std.testing.expect(!isMutatingArrayMethod("slice"));
    try std.testing.expect(!isMutatingArrayMethod("pop"));
}
