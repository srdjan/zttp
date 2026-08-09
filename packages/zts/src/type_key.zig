//! Canonical type serialization: the identity function for types.
//!
//! The pool does not intern, so `TypeIndex` equality is not structural
//! identity: two separately built `{ id: string }` records hold different
//! indices. D1 section 1 resolves that with one canonical string per type, and
//! derives structural equality and the wire digest from it.
//!
//! The grammar is D1 section 1, with three extensions the design document did
//! not cover because the ground-truth table did not record the tags:
//!
//! - `gen := "G" name_len ":" name` for `t_generic_param`. A bound type
//!   variable is not an unresolved reference, so it is encoded rather than
//!   rejected.
//! - `app := "X" arg_count type* name_len ":" name` for `t_generic_app`. Its
//!   base is always a `t_ref` (`type_pool.parseGenericApp`), so the base is
//!   identified by name, which is the same identity `isAssignableTo` already
//!   uses for two unresolved applications.
//! - Function parameters carry an optionality flag. D1's `fn` production
//!   dropped it, which would give `(a: T) => T` and `(a?: T) => T` one key.
//!
//! A `t_nullable` node is desugared to the union of its inner type with
//! `undefined`, because that is what it means: `T | undefined` and `T?` are one
//! type and must not hold two identities.
//!
//! An unresolved `t_ref` is a hard error and is never encoded. Callers resolve
//! through `TypeEnv` first. `structurallyEqual` falls back to index equality
//! when a key cannot be computed, which is the conservative direction: it can
//! only fail to notice that two types are the same, never claim that two
//! different types are one.

const std = @import("std");
const type_pool = @import("type_pool.zig");

const TypePool = type_pool.TypePool;
const TypeIndex = type_pool.TypeIndex;
const null_type_idx = type_pool.null_type_idx;
const TemplatePart = type_pool.TemplatePart;

pub const KeyError = error{
    /// A `t_ref` reached the encoder. The caller must resolve names through
    /// `TypeEnv` before asking for an identity.
    UnresolvedTypeReference,
    /// The absence sentinel has no type and therefore no identity.
    AbsentType,
    /// A malformed node, or a type graph deeper than `max_depth`.
    TypeKeyTooDeep,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Bounds the walk independently of the cycle guard: a node reachable by two
/// paths is not a cycle and is encoded twice, so a wide DAG can still cost more
/// than the pool's node count.
const max_depth: usize = 64;

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

const Encoder = struct {
    pool: *const TypePool,
    allocator: std.mem.Allocator,
    /// Nodes currently being encoded, innermost last. Re-entering a node on
    /// this stack emits a de Bruijn back-reference instead of recursing.
    stack: std.ArrayListUnmanaged(TypeIndex) = .empty,

    fn deinit(self: *Encoder) void {
        self.stack.deinit(self.allocator);
    }

    fn write(self: *Encoder, idx: TypeIndex, w: *std.Io.Writer) KeyError!void {
        if (idx == null_type_idx) return error.AbsentType;
        if (self.stack.items.len >= max_depth) return error.TypeKeyTooDeep;

        // Cycle: emit the distance from the top of the stack. A recursive alias
        // encodes finitely and keeps its structure.
        var i = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.stack.items[i] == idx) {
                try w.print("^{d}", .{self.stack.items.len - 1 - i});
                return;
            }
        }

        try self.stack.append(self.allocator, idx);
        defer _ = self.stack.pop();

        if (self.pool.isNominal(idx)) {
            const name = self.pool.nominalName(idx);
            try w.print("N{d}:{s}", .{ name.len, name });
        }
        try self.writeBody(idx, w);
    }

    fn writeBody(self: *Encoder, idx: TypeIndex, w: *std.Io.Writer) KeyError!void {
        const tag = self.pool.getTag(idx) orelse return error.TypeKeyTooDeep;
        switch (tag) {
            .t_boolean => try w.writeAll("b"),
            .t_number => try w.writeAll("n"),
            .t_string => try w.writeAll("s"),
            .t_undefined => try w.writeAll("u"),
            .t_null => try w.writeAll("d"),
            .t_void => try w.writeAll("v"),
            .t_never => try w.writeAll("!"),
            .t_unknown_type => try w.writeAll("?"),

            .t_literal_string => {
                const value = self.pool.getLiteralStringValue(idx) orelse "";
                try w.print("Ls{d}:{s}", .{ value.len, value });
            },
            .t_literal_number => {
                const data = self.pool.getData(idx) orelse return error.TypeKeyTooDeep;
                const value: i16 = @bitCast(data.a);
                try w.print("Ln{d}", .{value});
            },
            .t_literal_bool => {
                const data = self.pool.getData(idx) orelse return error.TypeKeyTooDeep;
                try w.print("Lb{d}", .{@intFromBool(data.a != 0)});
            },

            .t_record => try self.writeRecord(idx, w),
            .t_array => {
                const data = self.pool.getData(idx) orelse return error.TypeKeyTooDeep;
                try w.writeAll(if (data.b == 1) "Ar" else "Am");
                try self.write(self.pool.getArrayElement(idx), w);
            },
            .t_dict => {
                try w.writeAll("D");
                try self.write(self.pool.getDictKey(idx), w);
                try self.write(self.pool.getDictValue(idx), w);
            },
            .t_tuple => {
                const elements = self.pool.getTupleElements(idx);
                try w.print("Tm{d}", .{elements.len});
                for (elements) |element| try self.write(element, w);
            },
            .t_function => {
                const info = self.pool.getFunctionInfo(idx);
                try w.print("F{d}", .{info.params.len});
                for (info.params) |param| {
                    try w.writeAll(if (param.optional) "o" else ".");
                    try self.write(param.type_idx, w);
                }
                try w.writeAll("->");
                try self.write(info.ret, w);
            },
            .t_union => try self.writeSorted("U", self.pool.getUnionMembers(idx), w),
            .t_intersection => try self.writeSorted("I", self.pool.getIntersectionMembers(idx), w),

            // `T?` is `T | undefined`, so the two spellings share one identity.
            .t_nullable => {
                const inner = self.pool.getNullableInner(idx);
                try self.writeSorted("U", &.{ inner, self.pool.idx_undefined }, w);
            },

            .t_generic_param => {
                const name = self.pool.getRefName(idx);
                try w.print("G{d}:{s}", .{ name.len, name });
            },
            .t_generic_app => {
                const info = self.pool.getGenericAppInfo(idx);
                try w.print("X{d}", .{info.args.len});
                for (info.args) |arg| try self.write(arg, w);
                const base_name = self.pool.getRefName(info.base);
                if (base_name.len == 0) return error.UnresolvedTypeReference;
                try w.print("{d}:{s}", .{ base_name.len, base_name });
            },
            .t_template_literal => {
                const parts = self.pool.getTemplateParts(idx);
                try w.print("M{d}", .{parts.len});
                for (parts) |part| switch (part.kind) {
                    .literal => {
                        const text = self.pool.getName(part.name_start, part.name_len);
                        try w.print("l{d}:{s}", .{ text.len, text });
                    },
                    .type_slot => {
                        try w.writeAll("t");
                        try self.write(part.type_idx, w);
                    },
                };
            },

            .t_ref => return error.UnresolvedTypeReference,
        }
    }

    /// Fields sort by name so declaration order never affects identity.
    /// Declaration order stays on the record node, which is what the JSON
    /// encoder reads for wire order.
    fn writeRecord(self: *Encoder, idx: TypeIndex, w: *std.Io.Writer) KeyError!void {
        const fields = self.pool.getRecordFields(idx);
        try w.print("R{d}", .{fields.len});

        const order = try self.allocator.alloc(usize, fields.len);
        defer self.allocator.free(order);
        for (order, 0..) |*slot, i| slot.* = i;

        const Ctx = struct {
            pool: *const TypePool,
            fields: []const type_pool.RecordField,

            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const an = ctx.pool.getName(ctx.fields[a].name_start, ctx.fields[a].name_len);
                const bn = ctx.pool.getName(ctx.fields[b].name_start, ctx.fields[b].name_len);
                return switch (std.mem.order(u8, an, bn)) {
                    .lt => true,
                    .gt => false,
                    // Two fields with one name is malformed input, not an
                    // ordering question. Index keeps the sort total.
                    .eq => a < b,
                };
            }
        };
        std.mem.sort(usize, order, Ctx{ .pool = self.pool, .fields = fields }, Ctx.lessThan);

        for (order) |i| {
            const field = fields[i];
            if (field.optional) try w.writeAll("o");
            if (field.readonly) try w.writeAll("r");
            if (!field.optional and !field.readonly) try w.writeAll(".");
            const name = self.pool.getName(field.name_start, field.name_len);
            try w.print("{d}:{s}", .{ name.len, name });
            try self.write(field.type_idx, w);
        }
    }

    /// Union and intersection members sort by their own canonical strings, so
    /// `string | number` and `number | string` produce one key. Source order
    /// stays on the node for display and for the join's first-appearance rule.
    fn writeSorted(self: *Encoder, prefix: []const u8, members: []const TypeIndex, w: *std.Io.Writer) KeyError!void {
        try w.print("{s}{d}", .{ prefix, members.len });
        if (members.len == 0) return;

        const encoded = try self.allocator.alloc([]u8, members.len);
        var built: usize = 0;
        defer {
            for (encoded[0..built]) |slice| self.allocator.free(slice);
            self.allocator.free(encoded);
        }

        for (members) |member| {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer aw.deinit();
            try self.write(member, &aw.writer);
            encoded[built] = try aw.toOwnedSlice();
            built += 1;
        }

        std.mem.sort([]u8, encoded[0..built], {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (encoded[0..built]) |slice| try w.writeAll(slice);
    }
};

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

/// Write the canonical encoding of `idx`. Allocates only for the temporary
/// buffers that sorting needs.
pub fn writeCanonical(
    pool: *const TypePool,
    allocator: std.mem.Allocator,
    idx: TypeIndex,
    w: *std.Io.Writer,
) KeyError!void {
    var encoder = Encoder{ .pool = pool, .allocator = allocator };
    defer encoder.deinit();
    try encoder.write(idx, w);
}

/// The canonical string for `idx`, memoized on the pool. The returned slice is
/// owned by the pool and lives until `TypePool.deinit`.
///
/// Only the requested index is memoized, never the nodes below it: a subtree
/// containing a back-reference to an ancestor encodes differently under a
/// different root, and storing that under the subtree's own index would hand a
/// later caller a key for a type it did not ask about. The entry index is
/// always safe, because every back-reference inside it targets a node at or
/// below it.
pub fn typeKey(pool: *TypePool, allocator: std.mem.Allocator, idx: TypeIndex) KeyError![]const u8 {
    if (pool.lookupTypeKey(idx)) |cached| return cached;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeCanonical(pool, allocator, idx, &aw.writer);

    return pool.storeTypeKey(allocator, idx, aw.written());
}

/// Structural identity. Index equality is the fallback whenever a key cannot be
/// computed, which can only under-report equality and never over-report it.
pub fn structurallyEqual(pool: *TypePool, allocator: std.mem.Allocator, a: TypeIndex, b: TypeIndex) bool {
    if (a == b) return true;
    if (a == null_type_idx or b == null_type_idx) return false;
    const ka = typeKey(pool, allocator, a) catch return false;
    const kb = typeKey(pool, allocator, b) catch return false;
    return std.mem.eql(u8, ka, kb);
}

/// SHA-256 over the canonical string. D3 consumes this at wire boundaries,
/// where it is rendered as lowercase hex like every other digest in the repo.
pub fn typeDigest(pool: *TypePool, allocator: std.mem.Allocator, idx: TypeIndex) KeyError![32]u8 {
    const key = try typeKey(pool, allocator, idx);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &out, .{});
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn stringField(pool: *TypePool, allocator: std.mem.Allocator, name: []const u8, ty: TypeIndex) type_pool.RecordField {
    const n = pool.addName(allocator, name);
    return .{ .name_start = n.start, .name_len = n.len, .type_idx = ty, .optional = false };
}

test "two independently built identical records share a key" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const a = pool.addRecord(allocator, &.{
        stringField(&pool, allocator, "id", pool.idx_string),
        stringField(&pool, allocator, "count", pool.idx_number),
    });
    const b = pool.addRecord(allocator, &.{
        stringField(&pool, allocator, "id", pool.idx_string),
        stringField(&pool, allocator, "count", pool.idx_number),
    });

    try testing.expect(a != b);
    try testing.expect(structurallyEqual(&pool, allocator, a, b));
}

test "field declaration order does not affect identity" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const a = pool.addRecord(allocator, &.{
        stringField(&pool, allocator, "id", pool.idx_string),
        stringField(&pool, allocator, "count", pool.idx_number),
    });
    const b = pool.addRecord(allocator, &.{
        stringField(&pool, allocator, "count", pool.idx_number),
        stringField(&pool, allocator, "id", pool.idx_string),
    });

    try testing.expect(structurallyEqual(&pool, allocator, a, b));
}

test "a field's optionality is part of its identity" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const required = stringField(&pool, allocator, "id", pool.idx_string);
    var optional = required;
    optional.optional = true;

    const a = pool.addRecord(allocator, &.{required});
    const b = pool.addRecord(allocator, &.{optional});
    try testing.expect(!structurallyEqual(&pool, allocator, a, b));
}

test "union member order does not affect identity" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const a = pool.addUnion(allocator, &.{ pool.idx_string, pool.idx_number });
    const b = pool.addUnion(allocator, &.{ pool.idx_number, pool.idx_string });
    try testing.expect(a != b);
    try testing.expect(structurallyEqual(&pool, allocator, a, b));
}

test "two distinct types over the same base do not share a key" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const user_id = pool.addNominalAlias(allocator, pool.idx_string, "UserId");
    const order_id = pool.addNominalAlias(allocator, pool.idx_string, "OrderId");

    try testing.expect(!structurallyEqual(&pool, allocator, user_id, order_id));
    // And neither is the same type as its own base, which is what stops
    // `normalizeUnion` from collapsing `UserId | string` to `string`.
    try testing.expect(!structurallyEqual(&pool, allocator, user_id, pool.idx_string));
}

test "two capability interfaces with the same shape do not share a key" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const method = pool.addFunction(allocator, &.{}, pool.idx_void);
    const clock = pool.addRecord(allocator, &.{stringField(&pool, allocator, "now", method)});
    const random = pool.addRecord(allocator, &.{stringField(&pool, allocator, "now", method)});
    try testing.expect(structurallyEqual(&pool, allocator, clock, random));

    pool.markNominal(allocator, clock, "Clock");
    pool.markNominal(allocator, random, "Random");
    // The keys were computed above, so branding has to invalidate them or the
    // memo would answer with the pre-brand identity forever.
    try testing.expect(!structurallyEqual(&pool, allocator, clock, random));
}

test "an optional type and its explicit union share one identity" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const nullable = pool.addNullable(allocator, pool.idx_string);
    const explicit = pool.addUnion(allocator, &.{ pool.idx_string, pool.idx_undefined });
    try testing.expect(structurallyEqual(&pool, allocator, nullable, explicit));
}

test "a self-referential type terminates and keeps its shape" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    // The pool's constructors take already-built indices, so a cycle cannot be
    // built through them. Phase 3's recursive aliases will produce one, and the
    // back-reference rule is what keeps the encoding finite when they do.
    const placeholder = pool.addRecord(allocator, &.{
        stringField(&pool, allocator, "next", pool.idx_undefined),
    });
    const fields = pool.fields.items;
    for (fields) |*field| {
        if (std.mem.eql(u8, pool.getName(field.name_start, field.name_len), "next")) {
            field.type_idx = placeholder;
        }
    }

    const key = try typeKey(&pool, allocator, placeholder);
    try testing.expectEqualStrings("R1.4:next^0", key);
}

test "an unresolved reference has no identity" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const ref = pool.addRef(allocator, "Missing");
    try testing.expectError(error.UnresolvedTypeReference, typeKey(&pool, allocator, ref));
    // The fallback is index equality, so two different unresolved refs are not
    // reported as one type.
    const other = pool.addRef(allocator, "Missing");
    try testing.expect(!structurallyEqual(&pool, allocator, ref, other));
}

test "the key is computed once per index" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const record = pool.addRecord(allocator, &.{
        stringField(&pool, allocator, "id", pool.idx_string),
    });
    const first = try typeKey(&pool, allocator, record);
    const second = try typeKey(&pool, allocator, record);
    try testing.expectEqual(first.ptr, second.ptr);
}

test "a digest is stable and separates two different types" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const a = pool.addRecord(allocator, &.{stringField(&pool, allocator, "id", pool.idx_string)});
    const b = pool.addRecord(allocator, &.{stringField(&pool, allocator, "id", pool.idx_number)});

    try testing.expectEqual(try typeDigest(&pool, allocator, a), try typeDigest(&pool, allocator, a));
    try testing.expect(!std.mem.eql(
        u8,
        &(try typeDigest(&pool, allocator, a)),
        &(try typeDigest(&pool, allocator, b)),
    ));
}

test "a function's parameter optionality is part of its identity" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const n = pool.addName(allocator, "x");
    const required = pool.addFunction(allocator, &.{
        .{ .name_start = n.start, .name_len = n.len, .type_idx = pool.idx_string, .optional = false },
    }, pool.idx_number);
    const optional = pool.addFunction(allocator, &.{
        .{ .name_start = n.start, .name_len = n.len, .type_idx = pool.idx_string, .optional = true },
    }, pool.idx_number);

    try testing.expect(!structurallyEqual(&pool, allocator, required, optional));
}
