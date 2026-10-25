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

const NameTarget = union(enum) {
    field: u32,
    parameter: u32,
    template_part: u32,
};

const NameEvent = struct {
    target: NameTarget,
    next: usize,
};

const PlanAction = union(enum) {
    visit: usize,
    emit: struct {
        boundary: usize,
        target: NameTarget,
    },
};

const NamePlan = struct {
    allocator: std.mem.Allocator,
    range_start: usize,
    events: []NameEvent,
    event_count: usize,
    heads: []usize,
    tails: []usize,
    field_names: []?NameRef,
    parameter_names: []?NameRef,
    template_names: []?NameRef,

    fn init(allocator: std.mem.Allocator, options: struct {
        range_start: usize,
        event_capacity: usize,
        boundary_count: usize,
        field_count: usize,
        parameter_count: usize,
        template_count: usize,
    }) !NamePlan {
        const events = try allocator.alloc(NameEvent, options.event_capacity);
        errdefer allocator.free(events);
        const heads = try allocator.alloc(usize, options.boundary_count);
        errdefer allocator.free(heads);
        @memset(heads, std.math.maxInt(usize));
        const tails = try allocator.alloc(usize, options.boundary_count);
        errdefer allocator.free(tails);
        @memset(tails, std.math.maxInt(usize));
        const field_names = try allocator.alloc(?NameRef, options.field_count);
        errdefer allocator.free(field_names);
        @memset(field_names, null);
        const parameter_names = try allocator.alloc(?NameRef, options.parameter_count);
        errdefer allocator.free(parameter_names);
        @memset(parameter_names, null);
        const template_names = try allocator.alloc(?NameRef, options.template_count);
        errdefer allocator.free(template_names);
        @memset(template_names, null);
        return .{
            .allocator = allocator,
            .range_start = options.range_start,
            .events = events,
            .event_count = 0,
            .heads = heads,
            .tails = tails,
            .field_names = field_names,
            .parameter_names = parameter_names,
            .template_names = template_names,
        };
    }

    fn deinit(self: *NamePlan) void {
        self.allocator.free(self.template_names);
        self.allocator.free(self.parameter_names);
        self.allocator.free(self.field_names);
        self.allocator.free(self.tails);
        self.allocator.free(self.heads);
        self.allocator.free(self.events);
        self.* = undefined;
    }

    fn appendEvent(self: *NamePlan, boundary: usize, target: NameTarget) !void {
        if (boundary < self.range_start) return error.InvalidTypeRange;
        const local_boundary = boundary - self.range_start;
        if (local_boundary >= self.heads.len or self.event_count >= self.events.len) {
            return error.InvalidTypeRange;
        }
        const event_index = self.event_count;
        self.event_count += 1;
        self.events[event_index] = .{ .target = target, .next = std.math.maxInt(usize) };
        if (self.tails[local_boundary] == std.math.maxInt(usize)) {
            self.heads[local_boundary] = event_index;
        } else {
            self.events[self.tails[local_boundary]].next = event_index;
        }
        self.tails[local_boundary] = event_index;
    }

    fn emitBoundary(
        self: *NamePlan,
        store: *const TypeSyntax.Store,
        pool: *TypePool,
        boundary: usize,
    ) !void {
        if (boundary < self.range_start) return error.InvalidTypeRange;
        const local_boundary = boundary - self.range_start;
        if (local_boundary >= self.heads.len) return error.InvalidTypeRange;
        var event_index = self.heads[local_boundary];
        while (event_index != std.math.maxInt(usize)) {
            const event = self.events[event_index];
            switch (event.target) {
                .field => |index| {
                    const slot: usize = index;
                    if (slot >= self.field_names.len) return error.InvalidTypeRange;
                    self.field_names[slot] = pool.addName(
                        self.allocator,
                        store.fields.items[slot].name.text(store.source),
                    );
                },
                .parameter => |index| {
                    const slot: usize = index;
                    if (slot >= self.parameter_names.len) return error.InvalidTypeRange;
                    self.parameter_names[slot] = pool.addName(
                        self.allocator,
                        store.params.items[slot].name.text(store.source),
                    );
                },
                .template_part => |index| {
                    const slot: usize = index;
                    if (slot >= self.template_names.len) return error.InvalidTypeRange;
                    const span = switch (store.template_parts.items[slot]) {
                        .literal => |value| value,
                        .type_slot => return error.InvalidTypeRange,
                    };
                    self.template_names[slot] = pool.addName(
                        self.allocator,
                        span.text(store.source),
                    );
                },
            }
            try pool.ensureHealthy();
            event_index = event.next;
        }
    }
};

fn checkedAdd(total: *usize, value: usize) !void {
    total.* = std.math.add(usize, total.*, value) catch return error.InvalidTypeRange;
}

fn localChildIndex(
    child: TypeSyntax.Child,
    range_start: usize,
    range_end: usize,
) ?usize {
    return switch (child) {
        .absent => null,
        .present => |index| blk: {
            const value: usize = index;
            break :blk if (value >= range_start and value < range_end) value else null;
        },
    };
}

fn childStart(
    child: TypeSyntax.Child,
    range_start: usize,
    range_end: usize,
    subtree_starts: []const usize,
    fallback: usize,
) usize {
    const index = localChildIndex(child, range_start, range_end) orelse return fallback;
    return subtree_starts[index - range_start];
}

fn afterChild(
    child: TypeSyntax.Child,
    range_start: usize,
    range_end: usize,
    fallback: usize,
) usize {
    const index = localChildIndex(child, range_start, range_end) orelse return fallback;
    return index + 1;
}

fn pushAction(actions: []PlanAction, count: *usize, action: PlanAction) !void {
    if (count.* >= actions.len) return error.InvalidTypeRange;
    actions[count.*] = action;
    count.* += 1;
}

fn noteChild(
    child: TypeSyntax.Child,
    node_index: usize,
    range_start: usize,
    range_end: usize,
    subtree_starts: []usize,
    parented: []bool,
) void {
    const child_index = localChildIndex(child, range_start, range_end) orelse return;
    if (child_index >= node_index) return;
    const local = child_index - range_start;
    subtree_starts[node_index - range_start] = @min(
        subtree_starts[node_index - range_start],
        subtree_starts[local],
    );
    parented[local] = true;
}

fn buildNamePlan(
    allocator: std.mem.Allocator,
    store: *const TypeSyntax.Store,
    application_bases: *const TypeSyntax.Store.ApplicationBasePlan,
    node_range: TypeSyntax.Range,
) !NamePlan {
    const start: usize = node_range.start;
    const end = std.math.add(usize, start, node_range.count) catch return error.InvalidTypeRange;
    if (end > store.nodes.items.len) return error.InvalidTypeRange;

    var event_capacity: usize = 0;
    var child_capacity: usize = 0;
    for (store.nodes.items[start..end]) |node| switch (node.data) {
        .primitive, .named_reference, .literal_string, .literal_number, .literal_bool => {},
        .generic_application => |application| {
            const arguments = store.memberSlice(application.arguments) orelse return error.InvalidTypeRange;
            try checkedAdd(&child_capacity, arguments.len);
        },
        .group => |group| {
            const parameters = store.paramSlice(group.attempted_params) orelse
                return error.InvalidTypeRange;
            try checkedAdd(&event_capacity, parameters.len);
            try checkedAdd(&child_capacity, parameters.len);
            try checkedAdd(&child_capacity, 1);
        },
        .readonly_modifier, .array => try checkedAdd(&child_capacity, 1),
        .record => |range| {
            const fields = store.fieldSlice(range) orelse return error.InvalidTypeRange;
            try checkedAdd(&event_capacity, fields.len);
            try checkedAdd(&child_capacity, fields.len);
        },
        .tuple, .union_type, .intersection => |range| {
            const members = store.memberSlice(range) orelse return error.InvalidTypeRange;
            try checkedAdd(&child_capacity, members.len);
        },
        .function => |function| {
            const parameters = store.paramSlice(function.params) orelse return error.InvalidTypeRange;
            try checkedAdd(&event_capacity, parameters.len);
            try checkedAdd(&child_capacity, parameters.len);
            try checkedAdd(&child_capacity, 1);
        },
        .template => |range| {
            const parts = store.templatePartSlice(range) orelse return error.InvalidTypeRange;
            for (parts) |part| switch (part) {
                .literal => try checkedAdd(&event_capacity, 1),
                .type_slot => try checkedAdd(&child_capacity, 1),
            };
        },
    };

    const boundary_count = std.math.add(usize, node_range.count, 1) catch
        return error.InvalidTypeRange;
    var plan = try NamePlan.init(allocator, .{
        .range_start = start,
        .event_capacity = event_capacity,
        .boundary_count = boundary_count,
        .field_count = store.fields.items.len,
        .parameter_count = store.params.items.len,
        .template_count = store.template_parts.items.len,
    });
    errdefer plan.deinit();
    if (node_range.count == 0) return plan;

    const subtree_starts = try allocator.alloc(usize, node_range.count);
    defer allocator.free(subtree_starts);
    const parented = try allocator.alloc(bool, node_range.count);
    defer allocator.free(parented);
    @memset(parented, false);
    for (subtree_starts, 0..) |*subtree_start, index| subtree_start.* = start + index;

    for (store.nodes.items[start..end], start..) |node, node_index| switch (node.data) {
        .primitive, .named_reference, .literal_string, .literal_number, .literal_bool => {},
        .generic_application => |application| {
            noteChild(application.base, node_index, start, end, subtree_starts, parented);
            const arguments = store.memberSlice(application.arguments) orelse return error.InvalidTypeRange;
            for (arguments) |child| noteChild(
                child,
                node_index,
                start,
                end,
                subtree_starts,
                parented,
            );
        },
        .group => |group| {
            const parameters = store.paramSlice(group.attempted_params) orelse
                return error.InvalidTypeRange;
            for (parameters) |parameter| noteChild(
                parameter.type_child,
                node_index,
                start,
                end,
                subtree_starts,
                parented,
            );
            noteChild(group.child, node_index, start, end, subtree_starts, parented);
        },
        .readonly_modifier => |child| noteChild(child, node_index, start, end, subtree_starts, parented),
        .record => |range| {
            const fields = store.fieldSlice(range) orelse return error.InvalidTypeRange;
            for (fields) |field| noteChild(
                field.type_child,
                node_index,
                start,
                end,
                subtree_starts,
                parented,
            );
        },
        .array => |child| noteChild(child, node_index, start, end, subtree_starts, parented),
        .tuple, .union_type, .intersection => |range| {
            const members = store.memberSlice(range) orelse return error.InvalidTypeRange;
            for (members) |child| noteChild(
                child,
                node_index,
                start,
                end,
                subtree_starts,
                parented,
            );
        },
        .function => |function| {
            const parameters = store.paramSlice(function.params) orelse return error.InvalidTypeRange;
            for (parameters) |parameter| noteChild(
                parameter.type_child,
                node_index,
                start,
                end,
                subtree_starts,
                parented,
            );
            noteChild(function.ret, node_index, start, end, subtree_starts, parented);
        },
        .template => |range| {
            const parts = store.templatePartSlice(range) orelse return error.InvalidTypeRange;
            for (parts) |part| switch (part) {
                .literal => {},
                .type_slot => |child| noteChild(
                    child,
                    node_index,
                    start,
                    end,
                    subtree_starts,
                    parented,
                ),
            };
        },
    };

    const visited = try allocator.alloc(bool, node_range.count);
    defer allocator.free(visited);
    @memset(visited, false);
    const action_capacity = std.math.add(usize, child_capacity, event_capacity) catch
        return error.InvalidTypeRange;
    const actions = try allocator.alloc(PlanAction, std.math.add(usize, action_capacity, 1) catch
        return error.InvalidTypeRange);
    defer allocator.free(actions);

    for (store.nodes.items[start..end], start..) |_, root_index| {
        const local_root = root_index - start;
        if (parented[local_root] or application_bases.contains(root_index)) continue;
        var action_count: usize = 0;
        try pushAction(actions, &action_count, .{ .visit = root_index });
        while (action_count != 0) {
            action_count -= 1;
            switch (actions[action_count]) {
                .emit => |event| try plan.appendEvent(event.boundary, event.target),
                .visit => |node_index| {
                    if (node_index < start or node_index >= end) continue;
                    const local_index = node_index - start;
                    if (visited[local_index] or application_bases.contains(node_index)) continue;
                    visited[local_index] = true;
                    const node = store.nodes.items[node_index];
                    switch (node.data) {
                        .primitive, .named_reference, .literal_string, .literal_number, .literal_bool => {},
                        .generic_application => |application| {
                            const arguments = store.memberSlice(application.arguments) orelse
                                return error.InvalidTypeRange;
                            var index = arguments.len;
                            while (index != 0) {
                                index -= 1;
                                if (localChildIndex(arguments[index], start, end)) |child| {
                                    try pushAction(actions, &action_count, .{ .visit = child });
                                }
                            }
                        },
                        .group => |group| {
                            if (localChildIndex(group.child, start, end)) |child| {
                                try pushAction(actions, &action_count, .{ .visit = child });
                            }
                            var next_boundary = childStart(
                                group.child,
                                start,
                                end,
                                subtree_starts,
                                node_index,
                            );
                            const parameters = store.paramSlice(group.attempted_params) orelse
                                return error.InvalidTypeRange;
                            var index = parameters.len;
                            while (index != 0) {
                                index -= 1;
                                const parameter = parameters[index];
                                const parameter_index = std.math.add(
                                    usize,
                                    group.attempted_params.start,
                                    index,
                                ) catch return error.InvalidTypeRange;
                                const parameter_target = std.math.cast(u32, parameter_index) orelse
                                    return error.InvalidTypeRange;
                                const boundary = afterChild(
                                    parameter.type_child,
                                    start,
                                    end,
                                    next_boundary,
                                );
                                try pushAction(actions, &action_count, .{ .emit = .{
                                    .boundary = boundary,
                                    .target = .{ .parameter = parameter_target },
                                } });
                                if (localChildIndex(parameter.type_child, start, end)) |child| {
                                    try pushAction(actions, &action_count, .{ .visit = child });
                                    next_boundary = childStart(
                                        parameter.type_child,
                                        start,
                                        end,
                                        subtree_starts,
                                        next_boundary,
                                    );
                                }
                            }
                        },
                        .readonly_modifier => |child| if (localChildIndex(child, start, end)) |value| {
                            try pushAction(actions, &action_count, .{ .visit = value });
                        },
                        .record => |range| {
                            const fields = store.fieldSlice(range) orelse return error.InvalidTypeRange;
                            var next_boundary = node_index;
                            var index = fields.len;
                            while (index != 0) {
                                index -= 1;
                                const field = fields[index];
                                const field_index = std.math.add(usize, range.start, index) catch
                                    return error.InvalidTypeRange;
                                const field_target = std.math.cast(u32, field_index) orelse
                                    return error.InvalidTypeRange;
                                const boundary = afterChild(
                                    field.type_child,
                                    start,
                                    end,
                                    next_boundary,
                                );
                                try pushAction(actions, &action_count, .{ .emit = .{
                                    .boundary = boundary,
                                    .target = .{ .field = field_target },
                                } });
                                if (localChildIndex(field.type_child, start, end)) |child| {
                                    try pushAction(actions, &action_count, .{ .visit = child });
                                    next_boundary = childStart(
                                        field.type_child,
                                        start,
                                        end,
                                        subtree_starts,
                                        next_boundary,
                                    );
                                }
                            }
                        },
                        .array => |child| if (localChildIndex(child, start, end)) |value| {
                            try pushAction(actions, &action_count, .{ .visit = value });
                        },
                        .tuple, .union_type, .intersection => |range| {
                            const members = store.memberSlice(range) orelse return error.InvalidTypeRange;
                            var index = members.len;
                            while (index != 0) {
                                index -= 1;
                                if (localChildIndex(members[index], start, end)) |child| {
                                    try pushAction(actions, &action_count, .{ .visit = child });
                                }
                            }
                        },
                        .function => |function| {
                            if (localChildIndex(function.ret, start, end)) |ret| {
                                try pushAction(actions, &action_count, .{ .visit = ret });
                            }
                            var next_boundary = childStart(
                                function.ret,
                                start,
                                end,
                                subtree_starts,
                                node_index,
                            );
                            const parameters = store.paramSlice(function.params) orelse
                                return error.InvalidTypeRange;
                            var index = parameters.len;
                            while (index != 0) {
                                index -= 1;
                                const parameter = parameters[index];
                                const parameter_index = std.math.add(
                                    usize,
                                    function.params.start,
                                    index,
                                ) catch return error.InvalidTypeRange;
                                const parameter_target = std.math.cast(u32, parameter_index) orelse
                                    return error.InvalidTypeRange;
                                const boundary = afterChild(
                                    parameter.type_child,
                                    start,
                                    end,
                                    next_boundary,
                                );
                                try pushAction(actions, &action_count, .{ .emit = .{
                                    .boundary = boundary,
                                    .target = .{ .parameter = parameter_target },
                                } });
                                if (localChildIndex(parameter.type_child, start, end)) |child| {
                                    try pushAction(actions, &action_count, .{ .visit = child });
                                    next_boundary = childStart(
                                        parameter.type_child,
                                        start,
                                        end,
                                        subtree_starts,
                                        next_boundary,
                                    );
                                }
                            }
                        },
                        .template => |range| {
                            const parts = store.templatePartSlice(range) orelse
                                return error.InvalidTypeRange;
                            var next_boundary = node_index;
                            var index = parts.len;
                            while (index != 0) {
                                index -= 1;
                                const part_index = std.math.add(usize, range.start, index) catch
                                    return error.InvalidTypeRange;
                                const part_target = std.math.cast(u32, part_index) orelse
                                    return error.InvalidTypeRange;
                                switch (parts[index]) {
                                    .literal => try pushAction(actions, &action_count, .{ .emit = .{
                                        .boundary = next_boundary,
                                        .target = .{ .template_part = part_target },
                                    } }),
                                    .type_slot => |child| if (localChildIndex(child, start, end)) |value| {
                                        try pushAction(actions, &action_count, .{ .visit = value });
                                        next_boundary = childStart(
                                            child,
                                            start,
                                            end,
                                            subtree_starts,
                                            next_boundary,
                                        );
                                    },
                                }
                            }
                        },
                    }
                },
            }
        }
    }

    if (plan.event_count != event_capacity) return error.InvalidTypeRange;
    return plan;
}

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
    var name_plan = try buildNamePlan(allocator, store, application_bases, node_range);
    defer name_plan.deinit();
    for (store.nodes.items[start..end], start..) |node, index| {
        try name_plan.emitBoundary(store, pool, index);
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
                for (fields, 0..) |field, field_offset| {
                    const field_index = std.math.add(usize, range.start, field_offset) catch
                        return error.InvalidTypeRange;
                    const name = name_plan.field_names[field_index] orelse
                        return error.InvalidTypeRange;
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
                for (params, 0..) |parameter, parameter_offset| {
                    const parameter_index = std.math.add(
                        usize,
                        function.params.start,
                        parameter_offset,
                    ) catch return error.InvalidTypeRange;
                    const name = name_plan.parameter_names[parameter_index] orelse
                        return error.InvalidTypeRange;
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
                for (parts, 0..) |part, part_offset| switch (part) {
                    .literal => {
                        const part_index = std.math.add(usize, range.start, part_offset) catch
                            return error.InvalidTypeRange;
                        const name = name_plan.template_names[part_index] orelse
                            return error.InvalidTypeRange;
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
    try name_plan.emitBoundary(store, pool, end);
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

/// What the old standalone parser produced for a parity input, recorded before it was removed:
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
    // Keys and names are what the removed standalone parser produced for each input.
    const cases = [_]struct { source: []const u8, expected: ExpectedType, names: []const u8 }{
        .{
            .source = "(value: T) => Effects<T, \"crypto\">",
            .expected = .{ .key = "F1.Z1:T->X2Z1:TLs6:crypto7:Effects" },
            .names = "TvalueTcryptoEffects",
        },
        .{
            .source = "(first: Left, second: Right, third: End) => Result",
            .expected = .{ .key = "F3.Z4:Left.Z5:Right.Z3:End->Z6:Result" },
            .names = "LeftfirstRightsecondEndthirdResult",
        },
        .{
            .source = "{ first: Left; second: Right; third: End }",
            .expected = .{ .key = "R3.5:firstZ4:Left.6:secondZ5:Right.5:thirdZ3:End" },
            .names = "LeftfirstRightsecondEndthird",
        },
        .{
            .source = "`a${Left}b${Right}c`",
            .expected = .{ .key = "M5l1:atZ4:Leftl1:btZ5:Rightl1:c" },
            .names = "aLeftbRightc",
        },
        .{
            .source = "{ callback: (first: Left, second: `x${Right}y`) => { result: End } }",
            .expected = .{ .key = "R1.8:callbackF2.Z4:Left.M3l1:xtZ5:Rightl1:y->R1.6:resultZ3:End" },
            .names = "LeftfirstxRightysecondEndresultcallback",
        },
        .{ .source = "(first: Left, second:) =>", .expected = .key_error, .names = "Leftfirstsecond" },
        .{ .source = "number", .expected = .{ .key = "n" }, .names = "" },
        .{ .source = "()", .expected = .null_root, .names = "" },
    };
    for (cases) |case| try expectParsedLowering(case.source, case.expected, case.names, null);
}

test "admitted malformed groups retain lowering while binding signatures reject their suffix" {
    // Direct admission retains its historical prefix; binding signatures require full consumption.
    const cases = [_]struct { source: []const u8, prefix: []const u8, names: []const u8 }{
        .{ .source = "(first: Left, Right)", .prefix = "first", .names = "Leftfirstfirst" },
        .{ .source = "(first: Left, second: Right, Final)", .prefix = "first", .names = "LeftfirstRightsecondfirst" },
        .{ .source = "((inner: Left, Selected), Outer)", .prefix = "inner", .names = "Leftinnerinner" },
        .{ .source = "(first: Outer<Left>, Selected)", .prefix = "first", .names = "LeftOuterfirstfirst" },
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

    const PoolLengths = struct {
        nodes: usize,
        fields: usize,
        params: usize,
        members: usize,
        names: usize,
        template_parts: usize,

        fn read(pool: *const TypePool) @This() {
            return .{
                .nodes = pool.nodes.items.len,
                .fields = pool.fields.items.len,
                .params = pool.params.items.len,
                .members = pool.members.items.len,
                .names = pool.names.items.len,
                .template_parts = pool.template_parts.items.len,
            };
        }
    };
    var observed_early_failure = false;
    var observed_pool_failure = false;
    var observed_success = false;
    const Context = struct {
        fn run(
            failing_allocator: std.mem.Allocator,
            syntax_store: *const TypeSyntax.Store,
            bases: *const TypeSyntax.Store.ApplicationBasePlan,
            syntax_range: TypeSyntax.Range,
            root: TypeSyntax.Child,
            saw_early_failure: *bool,
            saw_pool_failure: *bool,
            saw_success: *bool,
        ) !void {
            var pool = TypePool.init(failing_allocator);
            defer pool.deinit(failing_allocator);
            try pool.ensureHealthy();
            const original = PoolLengths.read(&pool);
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
                            if (std.meta.eql(original, PoolLengths.read(&pool))) {
                                saw_early_failure.* = true;
                            }
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
                "LeftfirstxRightysecondEndresultcallback",
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
        &observed_early_failure,
        &observed_pool_failure,
        &observed_success,
    });
    try std.testing.expect(observed_early_failure);
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
    while (tail < source.len and std.mem.indexOfScalar(u8, " \t\r\n", source[tail]) != null) tail += 1;
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
