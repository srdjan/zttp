//! Pool-only lowering for validated direct type-syntax ranges.

const std = @import("std");
const engine = @import("zts-engine");
const type_pool_mod = @import("type_pool.zig");
const type_key = @import("type_key.zig");

const TypeSyntax = engine.parser.type_syntax;
const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const NameRef = type_pool_mod.NameRef;
const RecordField = type_pool_mod.RecordField;
const FuncParam = type_pool_mod.FuncParam;
const PoolTemplatePart = type_pool_mod.TemplatePart;
const null_type_idx = type_pool_mod.null_type_idx;

pub fn lowerOwnedRange(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    lowered: []TypeIndex,
    application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
    node_range: TypeSyntax.Range,
) !void {
    const start: usize = node_range.start;
    const end = std.math.add(usize, start, node_range.count) catch return error.InvalidTypeRange;
    if (end > store.nodes.items.len or end > lowered.len) return error.InvalidTypeRange;
    for (store.nodes.items[start..end], start..) |node, index| {
        if (application_bases.contains(index)) {
            if (node.tag != .named_reference) return error.InvalidGenericApplicationBase;
            lowered[index] = null_type_idx;
            continue;
        }
        lowered[index] = switch (node.data) {
            .primitive => |primitive| primitiveIndex(pool, primitive),
            .named_reference => |span| pool.addRef(allocator, span.text(store.source)),
            .generic_application => |application| blk: {
                const base_index = switch (application.base) {
                    .absent => return error.InvalidGenericApplicationBase,
                    .present => |value| @as(usize, value),
                };
                const base_span = switch (store.nodes.items[base_index].data) {
                    .named_reference => |span| span,
                    else => return error.InvalidGenericApplicationBase,
                };
                const base_name = base_span.text(store.source);
                const children = store.memberSlice(application.arguments) orelse
                    return error.InvalidTypeRange;
                var arguments: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer arguments.deinit(allocator);
                try arguments.ensureTotalCapacity(allocator, children.len);
                for (children) |child| {
                    arguments.appendAssumeCapacity(try loweredChild(lowered, child, index));
                }
                if (std.mem.eql(u8, base_name, "Dict") and arguments.items.len == 2) {
                    break :blk pool.addDict(allocator, arguments.items[0], arguments.items[1]);
                }
                if (std.mem.eql(u8, base_name, "Readonly") and arguments.items.len == 1 and
                    pool.getTag(arguments.items[0]) == .t_record)
                {
                    break :blk pool.makeReadonly(allocator, arguments.items[0]);
                }
                const base = pool.addRef(allocator, base_name);
                break :blk pool.addGenericApp(allocator, base, arguments.items);
            },
            .group => |group| try loweredChild(lowered, group.child, index),
            .readonly_modifier => |child| blk: {
                const inner = try loweredChild(lowered, child, index);
                if (pool.getTag(inner) == .t_array and !pool.isReadonlyArray(inner)) {
                    break :blk pool.addReadonlyArray(allocator, pool.getArrayElement(inner));
                }
                if (pool.getTag(inner) == .t_tuple) {
                    break :blk pool.addReadonlyTuple(allocator, inner);
                }
                if (pool.getTag(inner) == .t_ref or pool.getTag(inner) == .t_generic_app) {
                    const base = pool.addRef(allocator, "Readonly");
                    break :blk pool.addGenericApp(allocator, base, &.{inner});
                }
                break :blk inner;
            },
            .record => |range| blk: {
                const fields = store.fieldSlice(range) orelse return error.InvalidTypeRange;
                var result: std.ArrayListUnmanaged(RecordField) = .empty;
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, fields.len);
                for (fields) |field| {
                    const name = pool.addName(allocator, field.name.text(store.source));
                    try pool.ensureHealthy();
                    result.appendAssumeCapacity(.{
                        .name_start = name.start,
                        .name_len = name.len,
                        .type_idx = try loweredChild(lowered, field.type_child, index),
                        .optional = field.optional,
                        .readonly = field.readonly,
                    });
                }
                break :blk pool.addRecord(allocator, result.items);
            },
            .array => |child| blk: {
                const element = try loweredChild(lowered, child, index);
                if (element == null_type_idx) break :blk null_type_idx;
                break :blk pool.addArray(allocator, element);
            },
            .tuple => |range| blk: {
                const elements = store.memberSlice(range) orelse return error.InvalidTypeRange;
                var result: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, elements.len);
                for (elements) |element| {
                    const child = try loweredChild(lowered, element, index);
                    if (child == null_type_idx) break;
                    result.appendAssumeCapacity(child);
                }
                break :blk pool.addTuple(allocator, result.items);
            },
            .function => |function| blk: {
                const params = store.paramSlice(function.params) orelse return error.InvalidTypeRange;
                var result: std.ArrayListUnmanaged(FuncParam) = .empty;
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, params.len);
                for (params) |parameter| {
                    const name = pool.addName(allocator, parameter.name.text(store.source));
                    try pool.ensureHealthy();
                    result.appendAssumeCapacity(.{
                        .name_start = name.start,
                        .name_len = name.len,
                        .type_idx = try loweredChild(lowered, parameter.type_child, index),
                        .optional = parameter.optional,
                    });
                }
                break :blk pool.addFunctionWithReturn(
                    allocator,
                    result.items,
                    try loweredChild(lowered, function.ret, index),
                );
            },
            .union_type => |range| try lowerJoin(allocator, store, pool, lowered, index, range, true),
            .intersection => |range| try lowerJoin(allocator, store, pool, lowered, index, range, false),
            .literal_string => |span| pool.addLiteralString(allocator, span.text(store.source)),
            .literal_number => |value| pool.addLiteralNumber(allocator, value),
            .literal_bool => |value| pool.addLiteralBool(allocator, value),
            .template => |range| blk: {
                const parts = store.templatePartSlice(range) orelse return error.InvalidTypeRange;
                var result: std.ArrayListUnmanaged(PoolTemplatePart) = .empty;
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, parts.len);
                for (parts) |part| switch (part) {
                    .literal => |span| {
                        const name = pool.addName(allocator, span.text(store.source));
                        try pool.ensureHealthy();
                        result.appendAssumeCapacity(.{
                            .kind = .literal,
                            .name_start = name.start,
                            .name_len = name.len,
                        });
                    },
                    .type_slot => |child| result.appendAssumeCapacity(.{
                        .kind = .type_slot,
                        .type_idx = try loweredChild(lowered, child, index),
                    }),
                };
                break :blk pool.addTemplateLiteral(allocator, result.items);
            },
        };
        try pool.ensureHealthy();
    }
}

pub fn loweredChild(
    lowered: []const TypeIndex,
    child: TypeSyntax.Child,
    parent: usize,
) !TypeIndex {
    return switch (child) {
        .absent => null_type_idx,
        .present => |index| if (@as(usize, index) < parent and @as(usize, index) < lowered.len)
            lowered[index]
        else
            error.InvalidTypeChild,
    };
}

pub fn lowerJoin(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    pool: *TypePool,
    lowered: []const TypeIndex,
    parent: usize,
    range: TypeSyntax.Range,
    is_union: bool,
) !TypeIndex {
    const children = store.memberSlice(range) orelse return error.InvalidTypeRange;
    var members: std.ArrayListUnmanaged(TypeIndex) = .empty;
    defer members.deinit(allocator);
    try members.ensureTotalCapacity(allocator, children.len);
    for (children, 0..) |child, member_index| {
        const member = try loweredChild(lowered, child, parent);
        if (member == null_type_idx) {
            if (member_index == 0) return null_type_idx;
            break;
        }
        members.appendAssumeCapacity(member);
    }
    if (is_union and members.items.len == 2) {
        if (pool.getTag(members.items[1]) == .t_undefined) {
            return pool.addNullable(allocator, members.items[0]);
        }
        if (pool.getTag(members.items[0]) == .t_undefined) {
            return pool.addNullable(allocator, members.items[1]);
        }
    }
    return if (is_union)
        pool.addUnion(allocator, members.items)
    else
        pool.addIntersection(allocator, members.items);
}

pub fn primitiveIndex(pool: *const TypePool, primitive: TypeSyntax.Primitive) TypeIndex {
    return switch (primitive) {
        .unknown => pool.idx_unknown,
        .never => pool.idx_never,
        .undefined => pool.idx_undefined,
        .null => pool.idx_null,
        .boolean => pool.idx_boolean,
        .number => pool.idx_number,
        .string => pool.idx_string,
        .bytes => pool.idx_bytes,
    };
}

/// What the lowering must produce for a parity input:
/// the canonical type key, or that the root is null or has no key, plus the pool name bytes
/// (which fix the order the constructors interned their names in).
const ExpectedType = union(enum) {
    key: []const u8,
    null_root,
    key_error,
};

fn expectLoweredType(pool: *TypePool, root: TypeIndex, expected: ExpectedType, names: []const u8) !void {
    const allocator = std.testing.allocator;
    switch (expected) {
        .null_root => try std.testing.expectEqual(null_type_idx, root),
        .key => |want| {
            // The pool caches and owns the key.
            const key = try type_key.typeKey(pool, allocator, root);
            try std.testing.expectEqualStrings(want, key);
        },
        .key_error => try std.testing.expectError(error.AbsentType, type_key.typeKey(pool, allocator, root)),
    }
    try std.testing.expectEqualStrings(names, pool.names.items);
}

fn expectParsedLowering(
    source: []const u8,
    expected: ExpectedType,
    names: []const u8,
    rejected_prefix: ?[]const u8,
) !void {
    const allocator = std.testing.allocator;
    var standalone = TypePool.init(allocator);
    defer standalone.deinit(allocator);
    const standalone_root = parseTypeText(&standalone, allocator, source);
    try standalone.ensureHealthy();
    if (rejected_prefix == null) {
        try expectLoweredType(&standalone, standalone_root, expected, names);
    } else {
        try std.testing.expectEqual(null_type_idx, standalone_root);
    }

    var store = TypeSyntax.Store.init(allocator, source);
    defer store.deinit();
    const value = try TypeSyntax.parseAdmittedTypeValue(&store, .{
        .start = 0,
        .end = @intCast(source.len),
    });
    const base_uses = try allocator.alloc(u8, store.nodes.items.len);
    @memset(base_uses, 0);
    var application_bases: TypeSyntax.Store.ApplicationBasePlan = .{
        .allocator = allocator,
        .uses = base_uses,
    };
    defer application_bases.deinit();
    for (store.nodes.items) |node| switch (node.data) {
        .generic_application => |application| switch (application.base) {
            .absent => {},
            .present => |index| base_uses[@as(usize, index)] = 1,
        },
        else => {},
    };

    var direct = TypePool.init(allocator);
    defer direct.deinit(allocator);
    const lowered = try allocator.alloc(TypeIndex, store.nodes.items.len);
    defer allocator.free(lowered);
    @memset(lowered, null_type_idx);
    try lowerOwnedRange(
        allocator,
        &store,
        &direct,
        lowered,
        &application_bases,
        value.node_range,
    );
    const direct_root = try loweredChild(lowered, value.root, lowered.len);
    try direct.ensureHealthy();
    if (rejected_prefix) |name| {
        try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, direct.getTag(direct_root).?);
        try std.testing.expectEqualStrings(name, direct.getRefName(direct_root));
        try std.testing.expectEqualStrings(names, direct.names.items);
    } else {
        try expectLoweredType(&direct, direct_root, expected, names);
    }
}

test "parsed lowering preserves constructor name order" {
    // Keys and names are the expected output for each input.
    const cases = [_]struct { source: []const u8, expected: ExpectedType, names: []const u8 }{
        .{
            .source = "(value: T) => Effects<T, \"crypto\">",
            .expected = .{ .key = "F1.Z1:T->X2Z1:TLs6:crypto7:Effects" },
            .names = "TTcryptoEffectsvalue",
        },
        .{
            .source = "(first: Left, second: Right, third: End) => Result",
            .expected = .{ .key = "F3.Z4:Left.Z5:Right.Z3:End->Z6:Result" },
            .names = "LeftRightEndResultfirstsecondthird",
        },
        .{
            .source = "{ first: Left; second: Right; third: End }",
            .expected = .{ .key = "R3.5:firstZ4:Left.6:secondZ5:Right.5:thirdZ3:End" },
            .names = "LeftRightEndfirstsecondthird",
        },
        .{
            .source = "`a${Left}b${Right}c`",
            .expected = .{ .key = "M5l1:atZ4:Leftl1:btZ5:Rightl1:c" },
            .names = "LeftRightabc",
        },
        .{
            .source = "{ callback: (first: Left, second: `x${Right}y`) => { result: End } }",
            .expected = .{ .key = "R1.8:callbackF2.Z4:Left.M3l1:xtZ5:Rightl1:y->R1.6:resultZ3:End" },
            .names = "LeftRightxyEndresultfirstsecondcallback",
        },
        .{ .source = "(first: Left, second:) =>", .expected = .key_error, .names = "Leftfirstsecond" },
        .{ .source = "number", .expected = .{ .key = "n" }, .names = "" },
        .{ .source = "()", .expected = .null_root, .names = "" },
    };
    for (cases) |case| try expectParsedLowering(case.source, case.expected, case.names, null);
}

test "admitted malformed groups retain lowering while binding signatures reject their suffix" {
    // Direct admission retains its prefix; binding signatures require full consumption.
    const cases = [_]struct { source: []const u8, prefix: []const u8, names: []const u8 }{
        .{ .source = "(first: Left, Right)", .prefix = "first", .names = "Leftfirst" },
        .{ .source = "(first: Left, second: Right, Final)", .prefix = "first", .names = "LeftRightfirst" },
        .{ .source = "((inner: Left, Selected), Outer)", .prefix = "inner", .names = "Leftinner" },
        .{ .source = "(first: Outer<Left>, Selected)", .prefix = "first", .names = "LeftOuterfirst" },
    };
    for (cases) |case| try expectParsedLowering(case.source, .null_root, case.names, case.prefix);
}

test "public lowering closes allocation failures and preserves constructor order" {
    const source = "{ callback: (first: Left, second: `x${Right}y`) => { result: End } } = value;";
    const allocator = std.testing.allocator;
    var store = TypeSyntax.Store.init(allocator, source);
    defer store.deinit();
    var cursor = TypeSyntax.Cursor.init(source);
    switch (try TypeSyntax.parseAndStore(&store, .global(300), source, 0, &cursor)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }
    try store.validate();
    var application_bases = try store.planApplicationBases(allocator);
    defer application_bases.deinit();
    const annotation = store.annotations.items[0];

    var observed_scratch_failure = false;
    var observed_pool_failure = false;
    var observed_success = false;
    const Context = struct {
        fn run(
            failing_allocator: std.mem.Allocator,
            syntax_store: *const TypeSyntax.Store,
            bases: *const TypeSyntax.Store.ApplicationBasePlan,
            syntax_range: TypeSyntax.Range,
            root: TypeSyntax.Child,
            saw_scratch_failure: *bool,
            saw_pool_failure: *bool,
            saw_success: *bool,
        ) !void {
            var pool = TypePool.init(failing_allocator);
            defer pool.deinit(failing_allocator);
            try pool.ensureHealthy();
            const lowered = try std.testing.allocator.alloc(TypeIndex, syntax_store.nodes.items.len);
            defer std.testing.allocator.free(lowered);
            @memset(lowered, null_type_idx);

            lowerOwnedRange(
                failing_allocator,
                syntax_store,
                &pool,
                lowered,
                bases,
                syntax_range,
            ) catch |err| {
                switch (err) {
                    error.OutOfMemory => {
                        if (pool.ensureHealthy()) |_| {
                            saw_scratch_failure.* = true;
                        } else |pool_err| switch (pool_err) {
                            error.OutOfMemory => saw_pool_failure.* = true,
                            else => return pool_err,
                        }
                    },
                    else => return err,
                }
                return err;
            };

            try pool.ensureHealthy();
            const direct_root = try loweredChild(lowered, root, lowered.len);
            try expectLoweredType(
                &pool,
                direct_root,
                .{ .key = "R1.8:callbackF2.Z4:Left.M3l1:xtZ5:Rightl1:y->R1.6:resultZ3:End" },
                "LeftRightxyEndresultfirstsecondcallback",
            );
            try std.testing.expect(pool.fields.items.len != 0);
            try std.testing.expect(pool.params.items.len != 0);
            try std.testing.expect(pool.template_parts.items.len != 0);
            saw_success.* = true;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{
        &store,
        &application_bases,
        annotation.node_range,
        annotation.root,
        &observed_scratch_failure,
        &observed_pool_failure,
        &observed_success,
    });
    try std.testing.expect(observed_scratch_failure);
    try std.testing.expect(observed_pool_failure);
    try std.testing.expect(observed_success);
}

/// Parse one standalone type text (a binding signature, an ambient name, a census row) into
/// `pool`. The whole text must be one type: a malformed group that direct admission keeps as a
/// prefix is refused here, as binding signatures always required. Returns `null_type_idx` for
/// text that is not a type. Allocation failure poisons the pool, as the type pool constructors do.
pub fn parseTypeText(pool: *TypePool, allocator: std.mem.Allocator, source: []const u8) TypeIndex {
    if (pool.failure != null) return null_type_idx;
    return parseTypeTextChecked(pool, allocator, source) catch |err| {
        if (err == error.OutOfMemory and pool.failure == null) pool.failure = error.OutOfMemory;
        return null_type_idx;
    };
}

fn parseTypeTextChecked(pool: *TypePool, allocator: std.mem.Allocator, source: []const u8) !TypeIndex {
    if (source.len > std.math.maxInt(u32)) return null_type_idx;
    var store = TypeSyntax.Store.init(allocator, source);
    defer store.deinit();
    const value = TypeSyntax.parseAdmittedTypeValue(&store, .{
        .start = 0,
        .end = @intCast(source.len),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null_type_idx,
    };
    // Direct admission keeps a prefix of a malformed group; a standalone text must be one whole type.
    var tail: usize = value.semantic_prefix_end;
    while (tail < source.len and std.mem.findScalar(u8, " \t\r\n", source[tail]) != null) tail += 1;
    if (tail != source.len) return null_type_idx;
    const base_uses = try allocator.alloc(u8, store.nodes.items.len);
    @memset(base_uses, 0);
    var application_bases: TypeSyntax.Store.ApplicationBasePlan = .{
        .allocator = allocator,
        .uses = base_uses,
    };
    defer application_bases.deinit();
    for (store.nodes.items) |node| switch (node.data) {
        .generic_application => |application| switch (application.base) {
            .absent => {},
            .present => |index| base_uses[@as(usize, index)] = 1,
        },
        else => {},
    };
    const lowered = try allocator.alloc(TypeIndex, store.nodes.items.len);
    defer allocator.free(lowered);
    @memset(lowered, null_type_idx);
    try lowerOwnedRange(allocator, &store, pool, lowered, &application_bases, value.node_range);
    return loweredChild(lowered, value.root, lowered.len);
}
