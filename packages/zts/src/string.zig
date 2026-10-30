//! SIMD-accelerated string operations with interning
//!
//! UTF-8 strings with ASCII optimization and hash caching.

const std = @import("std");
const heap = @import("heap.zig");
const arena_mod = @import("arena.zig");

fn checkStringLength(len: usize) error{OutOfMemory}!void {
    // Handler-visible lengths use signed i32 values, including for ASCII input.
    if (len > std.math.maxInt(i32)) return error.OutOfMemory;
}

test "string length fits both storage and handler length" {
    try checkStringLength(0);
    try checkStringLength(std.math.maxInt(i32));
    try std.testing.expectError(error.OutOfMemory, checkStringLength(@as(usize, std.math.maxInt(i32)) + 1));
    try std.testing.expectError(error.OutOfMemory, checkStringLength(std.math.maxInt(u32)));
    try std.testing.expectError(error.OutOfMemory, checkStringLength(std.math.maxInt(usize)));
}

test "concatenation rejects signed length overflow before allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const large = JSString{
        .header = heap.MemBlockHeader.init(.string, @sizeOf(JSString)),
        .flags = .{},
        .len = std.math.maxInt(i32),
        .hash = 0,
    };
    const small = JSString{
        .header = heap.MemBlockHeader.init(.string, @sizeOf(JSString)),
        .flags = .{},
        .len = 1,
        .hash = 0,
    };
    try std.testing.expectError(error.OutOfMemory, concatStrings(failing.allocator(), &large, &small));
    try std.testing.expectError(error.OutOfMemory, concatMany(failing.allocator(), &.{ &large, &small, &small }));
    try std.testing.expect(!failing.has_induced_failure);
}

/// JavaScript string representation
/// Uses extern struct for predictable C-compatible memory layout
pub const JSString = extern struct {
    header: heap.MemBlockHeader,
    flags: Flags,
    len: u32,
    hash: u64, // Cached XXHash64
    // Followed by UTF-8 data

    pub const Flags = packed struct(u8) {
        is_unique: bool = false, // Interned string
        is_ascii: bool = false, // All bytes < 128
        is_numeric: bool = false, // Valid array index
        hash_computed: bool = false,
        _reserved: u4 = 0,
    };

    /// Get string data (const version)
    pub fn data(self: *const JSString) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return (base + @sizeOf(JSString))[0..self.len];
    }

    /// Get mutable string data
    pub fn dataMut(self: *JSString) []u8 {
        const base: [*]u8 = @ptrCast(self);
        return (base + @sizeOf(JSString))[0..self.len];
    }

    /// Get string length in bytes
    pub fn length(self: *const JSString) u32 {
        return self.len;
    }

    /// Get cached hash (compute on first use)
    pub fn getHash(self: *JSString) u64 {
        if (!self.flags.hash_computed) {
            self.hash = hashString(self.data());
            self.flags.hash_computed = true;
        }
        return self.hash;
    }

    pub fn getHashConst(self: *const JSString) u64 {
        return @constCast(self).getHash();
    }

    /// Check if string is empty
    pub fn isEmpty(self: *const JSString) bool {
        return self.len == 0;
    }

    /// Compare with another string
    pub fn compare(self: *const JSString, other: *const JSString) std.math.Order {
        // Fast path: same hash means likely equal
        const self_hash = self.getHashConst();
        const other_hash = other.getHashConst();
        if (self_hash == other_hash and self.len == other.len) {
            if (self == other) return .eq; // Same pointer
            if (eqlStrings(self.data(), other.data())) return .eq;
        }
        return compareStrings(self.data(), other.data());
    }

    /// Check equality with another string
    pub fn eql(self: *const JSString, other: *const JSString) bool {
        if (self == other) return true; // Same pointer (interned)
        const self_hash = self.getHashConst();
        const other_hash = other.getHashConst();
        if (self_hash != other_hash) return false;
        if (self.len != other.len) return false;
        return eqlStrings(self.data(), other.data());
    }

    /// Check equality with raw bytes
    pub fn eqlBytes(self: *const JSString, bytes: []const u8) bool {
        if (self.len != bytes.len) return false;
        return eqlStrings(self.data(), bytes);
    }

    /// Get character at byte index (for ASCII strings)
    pub fn charAt(self: *const JSString, index: u32) ?u8 {
        if (index >= self.len) return null;
        return self.data()[index];
    }

    /// Check if string starts with prefix
    pub fn startsWith(self: *const JSString, prefix: []const u8) bool {
        if (prefix.len > self.len) return false;
        return eqlStrings(self.data()[0..prefix.len], prefix);
    }

    /// Check if string ends with suffix
    pub fn endsWith(self: *const JSString, suffix: []const u8) bool {
        if (suffix.len > self.len) return false;
        const start = self.len - @as(u32, @intCast(suffix.len));
        return eqlStrings(self.data()[start..], suffix);
    }

    /// Find first occurrence of substring
    pub fn indexOf(self: *const JSString, needle: []const u8) ?u32 {
        if (needle.len == 0) return 0;
        if (needle.len > self.len) return null;

        const haystack = self.data();
        // Use SIMD for longer searches
        if (needle.len >= 4 and haystack.len >= 32) {
            return simdIndexOf(haystack, needle);
        }

        // Scalar fallback
        return scalarIndexOf(haystack, needle);
    }

    /// Find last occurrence of substring
    pub fn lastIndexOf(self: *const JSString, needle: []const u8) ?u32 {
        if (needle.len == 0) return self.len;
        if (needle.len > self.len) return null;

        const haystack = self.data();
        var i: usize = haystack.len - needle.len + 1;
        while (i > 0) {
            i -= 1;
            if (eqlStrings(haystack[i..][0..needle.len], needle)) {
                return @intCast(i);
            }
        }
        return null;
    }
};

// ============================================================================
// SliceString - Zero-Copy String Slices
// ============================================================================

/// SliceString - a zero-copy view into a parent string
/// Instead of allocating and copying data, this references the parent string
/// with an offset and length. The parent is kept alive via GC tracing.
///
/// Use for substrings >= 16 bytes where the copy overhead exceeds the
/// indirection cost. For smaller slices, direct copy is more efficient.
pub const SliceString = extern struct {
    header: heap.MemBlockHeader, // tag = .string_slice
    flags: JSString.Flags, // Inherited from parent (especially is_ascii)
    len: u32, // Slice length in bytes
    hash: u64, // Computed on demand (0 = not computed)
    parent: *JSString, // Keeps parent alive via GC
    offset: u32, // Byte offset into parent's data
    _pad: u32 = 0, // Padding for alignment

    /// Minimum slice size to use SliceString instead of copying.
    /// SliceString header is ~40 bytes, so for tiny strings copying is cheaper.
    pub const MIN_SLICE_LEN: u32 = 16;

    /// Get the slice data (zero-copy view into parent)
    pub inline fn data(self: *const SliceString) []const u8 {
        return self.parent.data()[self.offset..][0..self.len];
    }

    /// Get string length in bytes
    pub inline fn length(self: *const SliceString) u32 {
        return self.len;
    }

    /// Check if string is empty
    pub inline fn isEmpty(self: *const SliceString) bool {
        return self.len == 0;
    }

    /// Get cached hash (compute on first use)
    pub fn getHash(self: *SliceString) u64 {
        if (!self.flags.hash_computed) {
            self.hash = hashString(self.data());
            self.flags.hash_computed = true;
        }
        return self.hash;
    }

    /// Get hash (const version, may compute)
    pub fn getHashConst(self: *const SliceString) u64 {
        return @constCast(self).getHash();
    }

    /// Flatten slice to a new flat JSString (for operations that need mutable data)
    pub fn flatten(self: *const SliceString, allocator: std.mem.Allocator) !*JSString {
        return try createString(allocator, self.data());
    }

    /// Check equality with a byte slice
    pub fn eqlBytes(self: *const SliceString, bytes: []const u8) bool {
        if (self.len != bytes.len) return false;
        return eqlStrings(self.data(), bytes);
    }

    /// Check if string starts with prefix
    pub fn startsWith(self: *const SliceString, prefix: []const u8) bool {
        if (prefix.len > self.len) return false;
        return eqlStrings(self.data()[0..prefix.len], prefix);
    }

    /// Check if string ends with suffix
    pub fn endsWith(self: *const SliceString, suffix: []const u8) bool {
        if (suffix.len > self.len) return false;
        const start = self.len - @as(u32, @intCast(suffix.len));
        return eqlStrings(self.data()[start..], suffix);
    }
};

/// Create a SliceString referencing a portion of a parent JSString.
/// For slices < MIN_SLICE_LEN bytes, prefer createString() for a direct copy.
pub fn createSlice(allocator: std.mem.Allocator, parent: *JSString, offset: u32, len: u32) !*SliceString {
    const slice = try allocator.create(SliceString);
    slice.* = .{
        .header = heap.MemBlockHeader.init(.string_slice, @sizeOf(SliceString)),
        .flags = .{
            .is_unique = false,
            .is_ascii = parent.flags.is_ascii, // Inherit from parent
            .is_numeric = false, // Slices are rarely valid indices
            .hash_computed = false,
        },
        .len = len,
        .hash = 0,
        .parent = parent,
        .offset = offset,
    };
    return slice;
}

/// Create a SliceString using arena allocation
pub fn createSliceWithArena(arena: *arena_mod.Arena, parent: *JSString, offset: u32, len: u32) ?*SliceString {
    const slice = arena.create(SliceString) orelse return null;
    slice.* = .{
        .header = heap.MemBlockHeader.init(.string_slice, @sizeOf(SliceString)),
        .flags = .{
            .is_unique = false,
            .is_ascii = parent.flags.is_ascii,
            .is_numeric = false,
            .hash_computed = false,
        },
        .len = len,
        .hash = 0,
        .parent = parent,
        .offset = offset,
    };
    return slice;
}

// ============================================================================
// UTF-8 Utilities
// ============================================================================

/// Get byte length of UTF-8 codepoint starting at given byte
pub fn codepointByteLength(first_byte: u8) u3 {
    if (first_byte < 0x80) return 1; // ASCII
    if (first_byte < 0xC0) return 1; // Invalid, treat as 1
    if (first_byte < 0xE0) return 2; // 2-byte
    if (first_byte < 0xF0) return 3; // 3-byte
    return 4; // 4-byte
}

/// Decode a UTF-8 codepoint at the given position
pub fn decodeCodepoint(s: []const u8) ?struct { codepoint: u21, len: u3 } {
    if (s.len == 0) return null;

    const first = s[0];
    if (first < 0x80) {
        return .{ .codepoint = first, .len = 1 };
    }

    const len = codepointByteLength(first);
    if (s.len < len) return null;

    var cp: u21 = switch (len) {
        2 => @as(u21, first & 0x1F) << 6,
        3 => @as(u21, first & 0x0F) << 12,
        4 => @as(u21, first & 0x07) << 18,
        else => return null,
    };

    for (1..len) |i| {
        if ((s[i] & 0xC0) != 0x80) return null;
        const shift: u5 = @intCast((len - 1 - i) * 6);
        cp |= @as(u21, s[i] & 0x3F) << shift;
    }

    return .{ .codepoint = cp, .len = len };
}

// ============================================================================
// UTF-16 Code-Unit Indexing
// ============================================================================
//
// JavaScript string `.length`, indexing, and slicing are defined over UTF-16
// code units, while this engine stores strings as UTF-8. These helpers map
// between the two without materializing UTF-16. They are the single source of
// truth shared by the string builtins (runtime) and the comptime evaluator so
// the two engines agree on non-ASCII lengths and slice boundaries.

/// A position in a UTF-8 buffer paired with its UTF-16 code-unit index.
pub const Utf16Cursor = struct { byte: usize, unit: u32 };

/// Advance from `cursor` to the byte offset of UTF-16 code-unit `target`
/// (`target` must be >= `cursor.unit`), clamped to `data.len`. The returned
/// byte always lands on a UTF-8 codepoint boundary; when `target` falls between
/// the two units of a surrogate pair (an astral codepoint) it rounds down to
/// the boundary before that codepoint, since UTF-8 cannot hold a lone
/// surrogate. Passing a non-zero starting cursor lets callers map several
/// ascending indices in a single forward walk instead of re-scanning the
/// prefix each time.
pub fn utf16AdvanceToUnit(data: []const u8, cursor: Utf16Cursor, target: u32) Utf16Cursor {
    var unit = cursor.unit;
    var i = cursor.byte;
    while (i < data.len) {
        if (unit >= target) return .{ .byte = i, .unit = unit };
        const b = data[i];
        if (b < 0x80) {
            unit += 1;
            i += 1;
            continue;
        }
        const decoded = decodeCodepoint(data[i..]) orelse {
            unit += 1;
            i += 1;
            continue;
        };
        const w: u32 = if (decoded.codepoint > 0xFFFF) 2 else 1;
        if (unit + w > target) return .{ .byte = i, .unit = unit }; // target splits this codepoint: round down
        unit += w;
        i += decoded.len;
    }
    return .{ .byte = data.len, .unit = unit };
}

/// Count UTF-16 code units in UTF-8 `data`. Astral codepoints (> U+FFFF) count
/// as 2 (a surrogate pair); every BMP scalar counts as 1. Invalid bytes count
/// as one unit and advance one byte (lenient). ASCII takes a single-compare
/// fast path.
pub fn utf16Length(data: []const u8) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        if (b < 0x80) {
            units += 1;
            i += 1;
            continue;
        }
        const decoded = decodeCodepoint(data[i..]) orelse {
            units += 1;
            i += 1;
            continue;
        };
        units += if (decoded.codepoint > 0xFFFF) @as(u32, 2) else 1;
        i += decoded.len;
    }
    return units;
}

/// Byte offset of UTF-16 code-unit index `target`, clamped to `data.len`.
pub fn utf16IndexToByteOffset(data: []const u8, target: u32) usize {
    return utf16AdvanceToUnit(data, .{ .byte = 0, .unit = 0 }, target).byte;
}

/// UTF-16 code-unit index of byte offset `byte_off` (i.e. the number of code
/// units in `data[0..byte_off]`). Used to translate a byte position found by a
/// byte-level search (indexOf/lastIndexOf) back into the JS code-unit space.
pub fn byteOffsetToUtf16Index(data: []const u8, byte_off: usize) u32 {
    return utf16Length(data[0..@min(byte_off, data.len)]);
}

/// UTF-8 byte slice of the codepoint whose UTF-16 code-unit range covers
/// `target`, or null when `target` is past the end. An astral codepoint spans
/// two units; both map to the whole codepoint, since a lone surrogate cannot be
/// represented in UTF-8 (documented charAt limitation).
pub fn charCodepointSliceAt(data: []const u8, target: u32) ?[]const u8 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        if (b < 0x80) {
            if (units == target) return data[i .. i + 1];
            units += 1;
            i += 1;
            continue;
        }
        const decoded = decodeCodepoint(data[i..]) orelse {
            if (units == target) return data[i .. i + 1];
            units += 1;
            i += 1;
            continue;
        };
        const w: u32 = if (decoded.codepoint > 0xFFFF) 2 else 1;
        if (target >= units and target < units + w) return data[i .. i + decoded.len];
        units += w;
        i += decoded.len;
    }
    return null;
}

// ============================================================================
// SIMD String Search
// ============================================================================

/// SIMD-accelerated substring search
fn simdIndexOf(haystack: []const u8, needle: []const u8) ?u32 {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    const Vec = @Vector(32, u8);
    const first_char: Vec = @splat(needle[0]);

    var i: usize = 0;
    const search_end = haystack.len - needle.len + 1;

    // SIMD search for first character
    while (i + 32 <= search_end) : (i += 32) {
        const chunk: Vec = haystack[i..][0..32].*;
        const matches = chunk == first_char;
        const match_bytes: @Vector(32, u8) = @intFromBool(matches);
        const match_array: [32]u8 = @bitCast(match_bytes);

        // Check if any matches
        if (@reduce(.Or, matches)) {
            // Found potential match, verify full needle
            var j: usize = 0;
            while (j < 32) : (j += 1) {
                if (match_array[j] != 0) {
                    const pos = i + j;
                    if (pos + needle.len <= haystack.len) {
                        if (eqlStrings(haystack[pos..][0..needle.len], needle)) {
                            return @intCast(pos);
                        }
                    }
                }
            }
        }
    }

    // Scalar fallback for remainder
    if (scalarIndexOf(haystack[i..], needle)) |idx| return @intCast(i + idx);
    return null;
}

/// Scalar substring search
pub fn scalarIndexOf(haystack: []const u8, needle: []const u8) ?u32 {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    const first = needle[0];
    var i: usize = 0;
    const search_end = haystack.len - needle.len + 1;

    while (i < search_end) : (i += 1) {
        if (haystack[i] == first) {
            if (eqlStrings(haystack[i..][0..needle.len], needle)) {
                return @intCast(i);
            }
        }
    }
    return null;
}

// ============================================================================
// SIMD String Comparison
// ============================================================================

/// SIMD string comparison (256-bit AVX2 when available)
pub fn compareStrings(a: []const u8, b: []const u8) std.math.Order {
    if (a.len != b.len) return std.math.order(a.len, b.len);
    if (a.len == 0) return .eq;

    const Vec = @Vector(32, u8);
    var i: usize = 0;

    // SIMD comparison for 32-byte chunks
    while (i + 32 <= a.len) : (i += 32) {
        const va: Vec = a[i..][0..32].*;
        const vb: Vec = b[i..][0..32].*;
        if (@reduce(.Or, va != vb)) {
            return scalarCompare(a[i..], b[i..]);
        }
    }

    // Handle remainder
    return scalarCompare(a[i..], b[i..]);
}

fn scalarCompare(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ca, cb| {
        if (ca != cb) return std.math.order(ca, cb);
    }
    return std.math.order(a.len, b.len);
}

/// Fast string equality check (SIMD-accelerated for long strings)
pub fn eqlStrings(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    if (a.ptr == b.ptr) return true; // Same pointer

    const Vec = @Vector(32, u8);
    var i: usize = 0;

    // SIMD equality for 32-byte chunks
    while (i + 32 <= a.len) : (i += 32) {
        const va: Vec = a[i..][0..32].*;
        const vb: Vec = b[i..][0..32].*;
        if (@reduce(.Or, va != vb)) return false;
    }

    // Scalar fallback for remainder
    return std.mem.eql(u8, a[i..], b[i..]);
}

/// XXHash64 for string hashing
pub fn hashString(s: []const u8) u64 {
    return std.hash.XxHash64.hash(0, s);
}

/// Check if string is a valid array index
pub fn isArrayIndex(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 10) return null;
    if (s[0] == '0' and s.len > 1) return null; // No leading zeros

    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u32 = c - '0';
        // Check for overflow
        const max_before_digit = (std.math.maxInt(u32) - digit) / 10;
        if (result > max_before_digit) return null;
        result = result * 10 + digit;
    }
    return result;
}

/// Check if all bytes are ASCII
pub fn isAscii(s: []const u8) bool {
    const Vec = @Vector(32, u8);
    const high_bit: Vec = @splat(0x80);
    var i: usize = 0;

    while (i + 32 <= s.len) : (i += 32) {
        const chunk: Vec = s[i..][0..32].*;
        if (@reduce(.Or, chunk & high_bit != @as(Vec, @splat(0)))) {
            return false;
        }
    }

    // Check remainder
    for (s[i..]) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

// ============================================================================
// String Interning
// ============================================================================

/// String intern table for unique strings
pub const StringTable = struct {
    /// Hash map from hash -> list of strings with that hash
    buckets: std.AutoHashMap(u64, StringList),
    /// All allocated strings (for cleanup)
    strings: std.ArrayList(*JSString),
    allocator: std.mem.Allocator,
    /// Statistics
    intern_count: usize = 0,
    hit_count: usize = 0,

    const StringList = std.ArrayList(*JSString);

    pub fn init(allocator: std.mem.Allocator) StringTable {
        return .{
            .buckets = std.AutoHashMap(u64, StringList).init(allocator),
            .strings = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StringTable) void {
        self.deinitBuckets();

        // Free all strings
        for (self.strings.items) |str| {
            const total_size = @sizeOf(JSString) + str.len;
            const ptr: [*]align(@alignOf(JSString)) u8 = @ptrCast(@alignCast(str));
            self.allocator.free(ptr[0..total_size]);
        }
        self.strings.deinit(self.allocator);
    }

    fn deinitBuckets(self: *StringTable) void {
        // Free all bucket lists
        var it = self.buckets.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.buckets.deinit();
    }

    /// Intern a string (get or create unique instance)
    pub fn intern(self: *StringTable, s: []const u8) !*JSString {
        try checkStringLength(s.len);
        const hash = hashString(s);

        // Check if already interned
        if (self.buckets.getPtr(hash)) |list| {
            for (list.items) |str| {
                if (str.len == s.len and eqlStrings(str.data(), s)) {
                    self.hit_count += 1;
                    return str;
                }
            }
            // Hash collision - add to existing bucket
            try self.strings.ensureUnusedCapacity(self.allocator, 1);
            try list.ensureUnusedCapacity(self.allocator, 1);
            const new_str = try self.createString(s, hash);
            self.strings.appendAssumeCapacity(new_str);
            list.appendAssumeCapacity(new_str);
            self.intern_count += 1;
            return new_str;
        }

        // Create new bucket
        try self.strings.ensureUnusedCapacity(self.allocator, 1);
        try self.buckets.ensureUnusedCapacity(1);
        var list = StringList.empty;
        errdefer list.deinit(self.allocator);
        try list.ensureUnusedCapacity(self.allocator, 1);
        const new_str = try self.createString(s, hash);

        self.strings.appendAssumeCapacity(new_str);
        list.appendAssumeCapacity(new_str);
        self.buckets.putAssumeCapacityNoClobber(hash, list);
        self.intern_count += 1;
        return new_str;
    }

    /// Create a new JSString
    fn createString(self: *StringTable, s: []const u8, hash: u64) !*JSString {
        try checkStringLength(s.len);
        const total_size = @sizeOf(JSString) + s.len;
        const mem = try self.allocator.alignedAlloc(u8, std.mem.Alignment.of(JSString), total_size);
        errdefer self.allocator.free(mem);

        const str: *JSString = @ptrCast(@alignCast(mem.ptr));
        str.* = .{
            .header = heap.MemBlockHeader.init(.string, total_size),
            .flags = .{
                .is_unique = true,
                .is_ascii = isAscii(s),
                .is_numeric = isArrayIndex(s) != null,
                .hash_computed = true,
            },
            .len = @intCast(s.len),
            .hash = hash,
        };

        // Copy string data after header
        @memcpy(str.dataMut(), s);

        return str;
    }

    /// Get interning statistics
    pub fn getStats(self: *const StringTable) struct { interned: usize, hits: usize } {
        return .{ .interned = self.intern_count, .hits = self.hit_count };
    }
};

/// Create a non-interned string (caller owns memory)
pub fn createString(allocator: std.mem.Allocator, s: []const u8) !*JSString {
    try checkStringLength(s.len);
    const total_size = @sizeOf(JSString) + s.len;
    const mem = try allocator.alignedAlloc(u8, std.mem.Alignment.of(JSString), total_size);

    const str: *JSString = @ptrCast(@alignCast(mem.ptr));
    str.* = .{
        .header = heap.MemBlockHeader.init(.string, total_size),
        .flags = .{
            .is_unique = false,
            .is_ascii = isAscii(s),
            .is_numeric = isArrayIndex(s) != null,
            .hash_computed = false,
        },
        .len = @intCast(s.len),
        .hash = 0,
    };

    @memcpy(str.dataMut(), s);
    return str;
}

/// Free a non-interned string
pub fn freeString(allocator: std.mem.Allocator, str: *JSString) void {
    const total_size = @sizeOf(JSString) + str.len;
    const ptr: [*]align(@alignOf(JSString)) u8 = @ptrCast(@alignCast(str));
    allocator.free(ptr[0..total_size]);
}

/// Create a string using arena allocation (ephemeral, dies at request end)
pub fn createStringWithArena(arena: *arena_mod.Arena, s: []const u8) ?*JSString {
    checkStringLength(s.len) catch return null;
    const total_size = @sizeOf(JSString) + s.len;
    const mem = arena.alloc(total_size) orelse return null;

    const str: *JSString = @ptrCast(@alignCast(mem));
    str.* = .{
        .header = heap.MemBlockHeader.init(.string, total_size),
        .flags = .{
            .is_unique = false,
            .is_ascii = isAscii(s),
            .is_numeric = isArrayIndex(s) != null,
            .hash_computed = false,
        },
        .len = @intCast(s.len),
        .hash = 0,
    };

    @memcpy(str.dataMut(), s);
    return str;
}

/// Concatenate two strings
pub fn concatStrings(allocator: std.mem.Allocator, a: *const JSString, b: *const JSString) !*JSString {
    // Reject overflow before allocating or reading either string's backing bytes.
    const total_len = std.math.add(u32, a.len, b.len) catch return error.OutOfMemory;
    try checkStringLength(total_len);
    const total_size = @sizeOf(JSString) + @as(usize, total_len);
    const mem = try allocator.alignedAlloc(u8, std.mem.Alignment.of(JSString), total_size);

    const str: *JSString = @ptrCast(@alignCast(mem.ptr));
    const data_a = a.data();
    const data_b = b.data();

    str.* = .{
        .header = heap.MemBlockHeader.init(.string, total_size),
        .flags = .{
            .is_unique = false,
            .is_ascii = a.flags.is_ascii and b.flags.is_ascii,
            .is_numeric = false, // Concatenation rarely produces valid index
            .hash_computed = false,
        },
        .len = total_len,
        .hash = 0,
    };

    const data_mut = str.dataMut();
    @memcpy(data_mut[0..a.len], data_a);
    @memcpy(data_mut[a.len..], data_b);

    return str;
}

/// Concatenate multiple strings efficiently (single allocation)
/// More efficient than chained concatStrings for 3+ strings
pub fn concatMany(allocator: std.mem.Allocator, strings: []const *const JSString) !*JSString {
    if (strings.len == 0) {
        return try createString(allocator, "");
    }
    if (strings.len == 1) {
        // Return a copy of the single string
        return try createString(allocator, strings[0].data());
    }
    if (strings.len == 2) {
        return try concatStrings(allocator, strings[0], strings[1]);
    }

    // Calculate total length and check ASCII (checked add: a wraparound would
    // under-allocate and let the per-string memcpy below run past the buffer).
    var total_len: u32 = 0;
    var all_ascii = true;
    for (strings) |s| {
        total_len = std.math.add(u32, total_len, s.len) catch return error.OutOfMemory;
        all_ascii = all_ascii and s.flags.is_ascii;
    }
    try checkStringLength(total_len);

    // Single allocation for result
    const total_size = @sizeOf(JSString) + @as(usize, total_len);
    const mem = try allocator.alignedAlloc(u8, std.mem.Alignment.of(JSString), total_size);

    const str: *JSString = @ptrCast(@alignCast(mem.ptr));
    str.* = .{
        .header = heap.MemBlockHeader.init(.string, total_size),
        .flags = .{
            .is_unique = false,
            .is_ascii = all_ascii,
            .is_numeric = false,
            .hash_computed = false,
        },
        .len = total_len,
        .hash = 0,
    };

    // Copy all strings into result
    const data_mut = str.dataMut();
    var offset: usize = 0;
    for (strings) |s| {
        @memcpy(data_mut[offset .. offset + s.len], s.data());
        offset += s.len;
    }

    return str;
}

/// Format an integer to a buffer without allocation
/// Returns the slice of the buffer that contains the formatted number
pub fn formatIntToBuf(buf: []u8, n: i32) []const u8 {
    if (n == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    var value: u32 = if (n < 0) @intCast(-@as(i64, n)) else @intCast(n);
    var end: usize = buf.len;

    // Write digits from right to left
    while (value > 0) {
        end -= 1;
        buf[end] = '0' + @as(u8, @intCast(value % 10));
        value /= 10;
    }

    // Add negative sign if needed
    if (n < 0) {
        end -= 1;
        buf[end] = '-';
    }

    return buf[end..];
}

/// Format a float to a buffer without allocation
/// Returns the slice of the buffer that contains the formatted number
pub fn formatFloatToBuf(buf: []u8, f: f64) []const u8 {
    // Handle special cases
    if (std.math.isNan(f)) {
        @memcpy(buf[0..3], "NaN");
        return buf[0..3];
    }
    if (std.math.isPositiveInf(f)) {
        @memcpy(buf[0..8], "Infinity");
        return buf[0..8];
    }
    if (std.math.isNegativeInf(f)) {
        @memcpy(buf[0..9], "-Infinity");
        return buf[0..9];
    }

    // Check if it's an integer value
    if (@floor(f) == f and f >= -2147483648 and f <= 2147483647) {
        return formatIntToBuf(buf, @intFromFloat(f));
    }

    // Use std.fmt for general float formatting
    const result = std.fmt.bufPrint(buf, "{d}", .{f}) catch {
        @memcpy(buf[0..3], "NaN");
        return buf[0..3];
    };
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "SIMD string comparison" {
    try std.testing.expectEqual(std.math.Order.eq, compareStrings("hello", "hello"));
    try std.testing.expectEqual(std.math.Order.lt, compareStrings("abc", "abd"));
    try std.testing.expectEqual(std.math.Order.gt, compareStrings("xyz", "abc"));
    try std.testing.expectEqual(std.math.Order.lt, compareStrings("short", "longer string"));
}

test "SIMD string equality" {
    // Short strings
    try std.testing.expect(eqlStrings("hello", "hello"));
    try std.testing.expect(!eqlStrings("hello", "world"));
    try std.testing.expect(!eqlStrings("hello", "hell"));

    // Empty strings
    try std.testing.expect(eqlStrings("", ""));

    // Long strings (>32 bytes, exercises SIMD path)
    const long1 = "This is a relatively long string that exceeds 32 bytes for SIMD testing";
    const long2 = "This is a relatively long string that exceeds 32 bytes for SIMD testing";
    const long3 = "This is a relatively long string that exceeds 32 bytes for SIMD DIFFER";
    try std.testing.expect(eqlStrings(long1, long2));
    try std.testing.expect(!eqlStrings(long1, long3));
}

test "SIMD searches preserve every lane and scalar tail offset" {
    var bytes: [65]u8 = @splat('_');
    try std.testing.expectEqual(@as(?u32, null), simdIndexOf(&bytes, "x"));
    for (0..bytes.len) |offset| {
        bytes[offset] = 'x';
        try std.testing.expectEqual(@as(?u32, @intCast(offset)), simdIndexOf(&bytes, "x"));
        bytes[offset] = '_';
    }
}

test "string hashing" {
    const hash1 = hashString("hello");
    const hash2 = hashString("hello");
    const hash3 = hashString("world");

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
}

test "array index detection" {
    try std.testing.expectEqual(@as(?u32, 0), isArrayIndex("0"));
    try std.testing.expectEqual(@as(?u32, 123), isArrayIndex("123"));
    try std.testing.expectEqual(@as(?u32, null), isArrayIndex("01")); // Leading zero
    try std.testing.expectEqual(@as(?u32, null), isArrayIndex("abc"));
    try std.testing.expectEqual(@as(?u32, null), isArrayIndex("")); // Empty
}

test "ASCII detection" {
    try std.testing.expect(isAscii("Hello, World!"));
    try std.testing.expect(!isAscii("Hello, 世界!"));
    try std.testing.expect(isAscii(""));
}

test "UTF-8 codepoint byte length" {
    try std.testing.expectEqual(@as(u3, 1), codepointByteLength('a'));
    try std.testing.expectEqual(@as(u3, 2), codepointByteLength(0xC2)); // Start of 2-byte
    try std.testing.expectEqual(@as(u3, 3), codepointByteLength(0xE4)); // Start of 3-byte (CJK)
    try std.testing.expectEqual(@as(u3, 4), codepointByteLength(0xF0)); // Start of 4-byte (emoji)
}

test "UTF-8 codepoint decoding" {
    // ASCII
    const ascii = decodeCodepoint("A");
    try std.testing.expect(ascii != null);
    try std.testing.expectEqual(@as(u21, 'A'), ascii.?.codepoint);
    try std.testing.expectEqual(@as(u3, 1), ascii.?.len);

    // 3-byte CJK character (世 = U+4E16)
    const cjk = decodeCodepoint("世界");
    try std.testing.expect(cjk != null);
    try std.testing.expectEqual(@as(u21, 0x4E16), cjk.?.codepoint);
    try std.testing.expectEqual(@as(u3, 3), cjk.?.len);
}

test "string creation and data access" {
    const allocator = std.testing.allocator;

    const str = try createString(allocator, "hello");
    defer freeString(allocator, str);

    try std.testing.expectEqualStrings("hello", str.data());
    try std.testing.expectEqual(@as(u32, 5), str.len);
    try std.testing.expect(str.flags.is_ascii);
    try std.testing.expect(!str.flags.is_unique);
}

test "string interning" {
    const allocator = std.testing.allocator;

    var table = StringTable.init(allocator);
    defer table.deinit();

    const str1 = try table.intern("hello");
    const str2 = try table.intern("hello");
    const str3 = try table.intern("world");

    // Same string returns same pointer
    try std.testing.expectEqual(str1, str2);
    // Different strings return different pointers
    try std.testing.expect(str1 != str3);

    // Check flags
    try std.testing.expect(str1.flags.is_unique);

    // Check stats
    const stats = table.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.interned); // "hello" and "world"
    try std.testing.expectEqual(@as(usize, 1), stats.hits); // Second "hello" was a hit
}

test "string interning releases every partial allocation on OOM" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var table = StringTable.init(allocator);
            defer table.deinit();

            _ = table.intern("hello") catch |err| {
                try std.testing.expectEqual(@as(usize, 0), table.getStats().interned);
                try std.testing.expectEqual(@as(usize, 0), table.strings.items.len);
                try std.testing.expectEqual(@as(u32, 0), table.buckets.count());
                return err;
            };
            _ = table.intern("world") catch |err| {
                try std.testing.expectEqual(@as(usize, 1), table.getStats().interned);
                try std.testing.expectEqual(@as(usize, 1), table.strings.items.len);
                try std.testing.expect(table.buckets.get(hashString("world")) == null);
                return err;
            };
            const stats = table.getStats();
            try std.testing.expectEqual(@as(usize, 2), stats.interned);
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "string concatenation" {
    const allocator = std.testing.allocator;

    const str1 = try createString(allocator, "hello");
    defer freeString(allocator, str1);

    const str2 = try createString(allocator, " world");
    defer freeString(allocator, str2);

    const concat = try concatStrings(allocator, str1, str2);
    defer freeString(allocator, concat);

    try std.testing.expectEqualStrings("hello world", concat.data());
    try std.testing.expectEqual(@as(u32, 11), concat.len);
}

test "concatMany optimization" {
    const allocator = std.testing.allocator;

    const str1 = try createString(allocator, "Hello");
    defer freeString(allocator, str1);

    const str2 = try createString(allocator, ", ");
    defer freeString(allocator, str2);

    const str3 = try createString(allocator, "World");
    defer freeString(allocator, str3);

    const str4 = try createString(allocator, "!");
    defer freeString(allocator, str4);

    // Concatenate 4 strings in one allocation
    const strings = [_]*const JSString{ str1, str2, str3, str4 };
    const result = try concatMany(allocator, &strings);
    defer freeString(allocator, result);

    try std.testing.expectEqualStrings("Hello, World!", result.data());
    try std.testing.expectEqual(@as(u32, 13), result.len);
}

test "JSString methods" {
    const allocator = std.testing.allocator;

    const str = try createString(allocator, "hello world");
    defer freeString(allocator, str);

    // startsWith
    try std.testing.expect(str.startsWith("hello"));
    try std.testing.expect(!str.startsWith("world"));

    // endsWith
    try std.testing.expect(str.endsWith("world"));
    try std.testing.expect(!str.endsWith("hello"));

    // indexOf
    try std.testing.expectEqual(@as(?u32, 0), str.indexOf("hello"));
    try std.testing.expectEqual(@as(?u32, 6), str.indexOf("world"));
    try std.testing.expectEqual(@as(?u32, null), str.indexOf("xyz"));

    // lastIndexOf
    try std.testing.expectEqual(@as(?u32, 6), str.lastIndexOf("world"));

    // charAt
    try std.testing.expectEqual(@as(?u8, 'h'), str.charAt(0));
    try std.testing.expectEqual(@as(?u8, 'd'), str.charAt(10));
    try std.testing.expectEqual(@as(?u8, null), str.charAt(100));

    // isEmpty
    try std.testing.expect(!str.isEmpty());
}

test "JSString equality" {
    const allocator = std.testing.allocator;

    const str1 = try createString(allocator, "test");
    defer freeString(allocator, str1);

    const str2 = try createString(allocator, "test");
    defer freeString(allocator, str2);

    const str3 = try createString(allocator, "other");
    defer freeString(allocator, str3);

    try std.testing.expect(str1.eql(str2));
    try std.testing.expect(!str1.eql(str3));
    try std.testing.expect(str1.eqlBytes("test"));
    try std.testing.expect(!str1.eqlBytes("other"));
}

// ============================================================================
// SliceString Tests
// ============================================================================

test "SliceString creation and data access" {
    const allocator = std.testing.allocator;

    const parent = try createString(allocator, "hello world, this is a test string");
    defer freeString(allocator, parent);

    // Create a slice of "world"
    const slice = try createSlice(allocator, parent, 6, 5);
    defer allocator.destroy(slice);

    try std.testing.expectEqualStrings("world", slice.data());
    try std.testing.expectEqual(@as(u32, 5), slice.length());
    try std.testing.expect(!slice.isEmpty());
}

test "SliceString inherits ASCII flag" {
    const allocator = std.testing.allocator;

    const ascii_parent = try createString(allocator, "hello world, this is ASCII");
    defer freeString(allocator, ascii_parent);

    const slice = try createSlice(allocator, ascii_parent, 0, 5);
    defer allocator.destroy(slice);

    try std.testing.expect(slice.flags.is_ascii);
}

test "SliceString flatten" {
    const allocator = std.testing.allocator;

    const parent = try createString(allocator, "the quick brown fox");
    defer freeString(allocator, parent);

    const slice = try createSlice(allocator, parent, 4, 5); // "quick"
    defer allocator.destroy(slice);

    const flat = try slice.flatten(allocator);
    defer freeString(allocator, flat);

    try std.testing.expectEqualStrings("quick", flat.data());
    try std.testing.expectEqual(@as(u32, 5), flat.len);
}

test "SliceString eqlBytes" {
    const allocator = std.testing.allocator;

    const parent = try createString(allocator, "hello world");
    defer freeString(allocator, parent);

    const slice = try createSlice(allocator, parent, 0, 5); // "hello"
    defer allocator.destroy(slice);

    try std.testing.expect(slice.eqlBytes("hello"));
    try std.testing.expect(!slice.eqlBytes("world"));
    try std.testing.expect(!slice.eqlBytes("hello world"));
}

test "SliceString startsWith and endsWith" {
    const allocator = std.testing.allocator;

    const parent = try createString(allocator, "hello world, hello universe");
    defer freeString(allocator, parent);

    const slice = try createSlice(allocator, parent, 0, 11); // "hello world"
    defer allocator.destroy(slice);

    try std.testing.expect(slice.startsWith("hello"));
    try std.testing.expect(!slice.startsWith("world"));
    try std.testing.expect(slice.endsWith("world"));
    try std.testing.expect(!slice.endsWith("hello"));
}

test "SliceString MIN_SLICE_LEN threshold" {
    // Verify the minimum slice length constant
    try std.testing.expectEqual(@as(u32, 16), SliceString.MIN_SLICE_LEN);
}

test "regression: JSString and SliceString header at offset 0 for type detection" {
    // The value type system reads the header via toPtr(u32) and checks the tag.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(JSString, "header"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SliceString, "header"));
}
