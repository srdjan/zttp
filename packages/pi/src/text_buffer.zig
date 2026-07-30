//! Leak-safe collection of writer output into an owned slice.
//!
//! Kept dependency-free (std only) so every layer of the agent - tools,
//! transcript, loop, providers, RPC - can use it without an import cycle.

const std = @import("std");

/// Collect writer output into an owned slice.
///
/// The shape this replaces was spelled out at each call site: an empty
/// ArrayList, a `defer buf.deinit(allocator)`, an Allocating writer built with
/// `fromArrayList`, then `toArrayList` to read the bytes back. That shape leaks
/// when a write fails: `fromArrayList` takes ownership and replaces the source
/// list with empty, so the deferred `buf.deinit` frees an empty list while the
/// Allocating writer still holds the grown buffer.
///
/// `deinit` here is the whole cleanup, so `defer out.deinit()` covers both the
/// success and the failure path.
pub const TextBuffer = struct {
    aw: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) TextBuffer {
        return .{ .aw = .init(allocator) };
    }

    pub fn writer(self: *TextBuffer) *std.Io.Writer {
        return &self.aw.writer;
    }

    pub fn deinit(self: *TextBuffer) void {
        self.aw.deinit();
    }

    /// Borrow the bytes written so far. The buffer keeps ownership.
    pub fn written(self: *TextBuffer) []u8 {
        return self.aw.written();
    }

    /// Drop the bytes written so far, keeping the allocation for reuse.
    pub fn clearRetainingCapacity(self: *TextBuffer) void {
        self.aw.clearRetainingCapacity();
    }

    /// Cut the buffer back to `new_len` bytes, keeping the allocation.
    pub fn shrinkRetainingCapacity(self: *TextBuffer, new_len: usize) void {
        self.aw.shrinkRetainingCapacity(new_len);
    }

    /// Transfer the bytes to the caller. The buffer is empty afterwards, so a
    /// trailing `defer deinit()` stays correct.
    pub fn toOwnedSlice(self: *TextBuffer) std.mem.Allocator.Error![]u8 {
        return self.aw.toOwnedSlice();
    }
};

/// One-call form of `TextBuffer`: render through `write`, return the bytes.
/// `args` is a tuple of the arguments after the writer, so
/// `renderAlloc(a, writeFeaturesJson, .{})` and
/// `renderAlloc(a, writeRuleJson, .{entry})` both work.
pub fn renderAlloc(
    allocator: std.mem.Allocator,
    comptime write: anytype,
    args: anytype,
) anyerror![]u8 {
    var out = TextBuffer.init(allocator);
    errdefer out.deinit();
    try @call(.auto, write, .{out.writer()} ++ args);
    return out.toOwnedSlice();
}

const testing = std.testing;

test "TextBuffer frees the buffer when a write fails" {
    // The shape this replaced leaked here: `fromArrayList` takes ownership and
    // replaces the source list with empty, so the caller's
    // `defer buf.deinit(allocator)` freed an empty list while the Allocating
    // writer still held the grown buffer. Fail every allocation index in turn;
    // the testing allocator asserts at teardown that nothing survived.
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var buf = TextBuffer.init(failing.allocator());
        defer buf.deinit();
        buf.writer().writeAll("some output that needs a heap buffer") catch continue;
        const owned = buf.toOwnedSlice() catch continue;
        failing.allocator().free(owned);
    }
}

test "TextBuffer borrows written bytes without transferring ownership" {
    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    try buf.writer().writeAll("hello");
    try testing.expectEqualStrings("hello", buf.written());
    try buf.writer().writeAll(" world");
    try testing.expectEqualStrings("hello world", buf.written());
    buf.shrinkRetainingCapacity(5);
    try testing.expectEqualStrings("hello", buf.written());
    buf.clearRetainingCapacity();
    try testing.expectEqualStrings("", buf.written());
}

test "renderAlloc passes trailing arguments through to the writer" {
    const render = struct {
        fn write(w: *std.Io.Writer, prefix: []const u8, n: u32) !void {
            try w.print("{s}{d}", .{ prefix, n });
        }
    }.write;

    const text = try renderAlloc(testing.allocator, render, .{ "count=", @as(u32, 7) });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("count=7", text);
}
