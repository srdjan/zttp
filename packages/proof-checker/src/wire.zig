//! Shared primitives for the kernel's length-prefixed wire decoders.
//!
//! One bounds-checked reader, one strict-order check, one record iterator,
//! and one domain-separated digest. Each decoder keeps its own error set: a
//! primitive that can fail on content takes the caller's error as a comptime
//! argument, so the error a diagnostic names is still the decoder's own.
//! Zero-copy and allocation-free.

const std = @import("std");

pub const Truncated = error{Truncated};

/// Bounds-checked little-endian reads. It reports truncation and, for a
/// length-prefixed string, the caller's length error; content rules belong to
/// the decoder.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn int(self: *Reader, comptime T: type) Truncated!T {
        @setRuntimeSafety(true);
        const size = @sizeOf(T);
        if (self.bytes.len - self.pos < size) return error.Truncated;
        const value = std.mem.readInt(T, self.bytes[self.pos..][0..size], .little);
        self.pos += size;
        return value;
    }

    pub fn take(self: *Reader, len: usize) Truncated![]const u8 {
        @setRuntimeSafety(true);
        if (self.bytes.len - self.pos < len) return error.Truncated;
        const out = self.bytes[self.pos..][0..len];
        self.pos += len;
        return out;
    }

    /// A string with an `L`-typed length prefix. The length bound is checked
    /// before the body is required, so an out-of-range length names itself
    /// rather than surfacing as truncation.
    pub fn string(
        self: *Reader,
        comptime L: type,
        min: L,
        max: L,
        comptime length_error: anytype,
    ) (Truncated || @TypeOf(length_error))![]const u8 {
        @setRuntimeSafety(true);
        const len = try self.int(L);
        if (len < min or len > max) return length_error;
        return self.take(len);
    }

    pub fn atEnd(self: Reader) bool {
        @setRuntimeSafety(true);
        return self.pos == self.bytes.len;
    }
};

/// Check `magic` and an exact schema, and return a reader positioned after
/// them.
pub fn header(
    bytes: []const u8,
    comptime magic: []const u8,
    schema: u16,
) error{ Truncated, BadMagic, UnsupportedSchema }!Reader {
    @setRuntimeSafety(true);
    if (bytes.len < magic.len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
    var reader = Reader{ .bytes = bytes, .pos = magic.len };
    if (try reader.int(u16) != schema) return error.UnsupportedSchema;
    return reader;
}

pub fn bytesOrder(a: []const u8, b: []const u8) std.math.Order {
    @setRuntimeSafety(true);
    return std.mem.order(u8, a, b);
}

/// A canonical list's order check. `step` returns how the new item compares
/// with the previous one, and `.lt` for the first item.
pub fn Ascending(comptime T: type, comptime order: fn (T, T) std.math.Order) type {
    @setRuntimeSafety(true);
    return struct {
        previous: ?T = null,

        pub fn step(self: *@This(), item: T) std.math.Order {
            @setRuntimeSafety(true);
            defer self.previous = item;
            const prev = self.previous orelse return .lt;
            return order(prev, item);
        }
    };
}

/// `remaining` records, each read by `read` from where the last one ended.
pub fn Iterator(comptime T: type, comptime E: type, comptime read: fn (*Reader) E!T) type {
    @setRuntimeSafety(true);
    return struct {
        bytes: []const u8,
        pos: usize,
        remaining: u16,

        pub fn next(self: *@This()) E!?T {
            @setRuntimeSafety(true);
            if (self.remaining == 0) return null;
            var reader = Reader{ .bytes = self.bytes, .pos = self.pos };
            const item = try read(&reader);
            self.pos = reader.pos;
            self.remaining -= 1;
            return item;
        }

        /// Walk every record once, leaving `reader` after the last.
        pub fn skipAll(self: @This(), reader: *Reader) E!void {
            @setRuntimeSafety(true);
            var walk = self;
            while (try walk.next()) |_| {}
            reader.pos = walk.pos;
        }
    };
}

/// Domain-separated SHA-256 over a whole encoding.
pub fn domainDigest(comptime domain: []const u8, bytes: []const u8) [32]u8 {
    @setRuntimeSafety(true);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(domain);
    hasher.update(bytes);
    return hasher.finalResult();
}

/// A writer over a fixed buffer for building encodings in tests. It writes
/// what it is told, valid or not, so a test can build each refusal directly.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn raw(self: *Writer, data: []const u8) void {
        @setRuntimeSafety(true);
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn int(self: *Writer, comptime T: type, value: T) void {
        @setRuntimeSafety(true);
        std.mem.writeInt(T, self.buf[self.len..][0..@sizeOf(T)], value, .little);
        self.len += @sizeOf(T);
    }

    pub fn string(self: *Writer, data: []const u8) void {
        @setRuntimeSafety(true);
        self.int(u32, @intCast(data.len));
        self.raw(data);
    }

    pub fn bytes(self: *const Writer) []const u8 {
        @setRuntimeSafety(true);
        return self.buf[0..self.len];
    }
};

const testing = std.testing;

test "a string length out of range names itself before the body is required" {
    const bytes = [_]u8{ 9, 0, 0, 0 };
    var reader = Reader{ .bytes = &bytes };
    try testing.expectError(error.TooLong, reader.string(u32, 1, 8, error.TooLong));
    reader = .{ .bytes = &bytes };
    try testing.expectError(error.Truncated, reader.string(u32, 1, 9, error.TooLong));
}

test "a canonical list admits only strictly ascending items" {
    var order = Ascending([]const u8, bytesOrder){};
    try testing.expectEqual(std.math.Order.lt, order.step("a"));
    try testing.expectEqual(std.math.Order.lt, order.step("b"));
    try testing.expectEqual(std.math.Order.eq, order.step("b"));
    try testing.expectEqual(std.math.Order.gt, order.step("a"));
}
