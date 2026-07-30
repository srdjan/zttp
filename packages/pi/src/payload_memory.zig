//! Reflective deep clone and free for the owned UI payload types.
//!
//! `ui_payload.zig` declared 17 struct types, each with a hand-written `clone`
//! and `deinit` that listed every field twice: 633 lines that a change to any
//! payload had to keep in sync three ways (the field list, the clone, the free).
//!
//! Ownership is encoded in the field type, and that is what makes the walk
//! decidable:
//!
//!   []u8        an owned string          dupe / free
//!   [][]u8      owned slice of strings   alloc + per-element / per-element + free
//!   []Struct    owned slice of payloads  alloc + recurse / recurse + free
//!   ?T          optional of the above    null or recurse
//!   [N]u8       inline array             copied by value
//!   ints, bools, floats, enums           copied by value
//!   []const u8  compile error: a borrowed field must not be freed by a
//!               generic walk, so it has to be an explicit decision
//!
//! `cloneOwned` also fixes a defect the hand-written versions shared: they
//! duped fields inside a struct literal with no unwind, so an allocation
//! failure partway through leaked every field already duped. This clones into
//! a scratch value and frees the completed prefix on failure.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Deep-copy `value` into `allocator`. On failure nothing is leaked: every
/// field cloned before the failing one is freed.
pub fn cloneOwned(comptime T: type, value: T, allocator: Allocator) Allocator.Error!T {
    return cloneValue(T, value, allocator);
}

/// Free every owned allocation reachable from `value`, then blank its pointer
/// fields so a second free is a no-op rather than a double free. Scalars keep
/// their values: the pointers are what make reuse unsafe.
pub fn freeOwned(comptime T: type, value: *T, allocator: Allocator) void {
    freeValue(T, value, allocator);
}

fn cloneValue(comptime T: type, value: T, allocator: Allocator) Allocator.Error!T {
    return switch (@typeInfo(T)) {
        .int, .bool, .float, .@"enum", .void => value,
        .array => value,
        .optional => |info| if (value) |inner|
            @as(T, try cloneValue(info.child, inner, allocator))
        else
            null,
        .pointer => |info| blk: {
            if (info.size != .slice) {
                @compileError("payload field of pointer type " ++ @typeName(T) ++ " is not clonable");
            }
            if (info.is_const) {
                @compileError("payload field " ++ @typeName(T) ++
                    " is borrowed (const slice); a generic walk must not own it - " ++
                    "make it a mutable slice if the payload owns it, or clone it by hand");
            }
            if (info.child == u8) break :blk try allocator.dupe(u8, value);
            const out = try allocator.alloc(info.child, value.len);
            var done: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < done) : (i += 1) freeValue(info.child, &out[i], allocator);
                allocator.free(out);
            }
            for (value, 0..) |element, i| {
                out[i] = try cloneValue(info.child, element, allocator);
                done = i + 1;
            }
            break :blk out;
        },
        .@"struct" => try cloneStruct(T, value, allocator),
        else => @compileError("payload field of type " ++ @typeName(T) ++ " is not clonable"),
    };
}

fn cloneStruct(comptime T: type, value: T, allocator: Allocator) Allocator.Error!T {
    const fields = @typeInfo(T).@"struct".fields;
    var out: T = undefined;
    var done: usize = 0;
    errdefer freeStructPrefix(T, &out, allocator, done);
    inline for (fields, 0..) |field, index| {
        @field(out, field.name) = try cloneValue(field.type, @field(value, field.name), allocator);
        done = index + 1;
    }
    return out;
}

fn freeStructPrefix(comptime T: type, value: *T, allocator: Allocator, count: usize) void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, index| {
        if (index < count) freeValue(field.type, &@field(value, field.name), allocator);
    }
}

fn freeValue(comptime T: type, value: *T, allocator: Allocator) void {
    switch (@typeInfo(T)) {
        .int, .bool, .float, .@"enum", .void, .array => {},
        .optional => |info| {
            if (value.* != null) {
                freeValue(info.child, &value.*.?, allocator);
                value.* = null;
            }
        },
        .pointer => |info| {
            if (info.size != .slice or info.is_const) return;
            if (info.child != u8) {
                for (value.*) |*element| freeValue(info.child, element, allocator);
            }
            allocator.free(value.*);
            value.* = &.{};
        },
        .@"struct" => freeStructPrefix(T, value, allocator, @typeInfo(T).@"struct".fields.len),
        else => {},
    }
}
