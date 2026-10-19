//! Flow evaluator, phase P2: the abstract domain, the location scheme, the
//! field-sensitive heap, and an evaluator for expressions without calls.
//!
//! This is the shadow of the checker that will replace the label walk in
//! `flow_checker.zig`. Nothing in the pipeline, the CLI, or any verdict reads
//! it, so `flow_analyzer_version` and the policy hash stay where they are. The
//! design is in `docs/plans/2026-10-18-flow-checker-sound-redesign-plan.md`
//! (rounds 2 and 3 override its earlier text) and the contract for this phase
//! is `docs/plans/2026-10-19-flow-interp-p2-r16-spec.md`.
//!
//! The old checker keeps one label set per binding and loses what a value
//! points at, so a write through an alias reaches nothing the reader can see.
//! This evaluator keeps three facts per value instead: the labels it carries,
//! the allocation sites it may point at (`origins`), and the function bodies it
//! may call (`callables`). A heap cell is named by an allocation site and a
//! property name, and one site stands for every object it creates, so every
//! write is a weak update: it joins with the cell and never removes a label.
//!
//! Anything this phase does not model sets `cleared` on the result, which means
//! every flow property is cleared. The wrong answer for a construct owned by a
//! later phase is a proof, so the rule for each of them is to say "I could not
//! follow this" and not to guess. `tagPlan` records which phase owns each tag,
//! and its test keeps that table and the two evaluators from drifting apart.

const std = @import("std");
const engine = @import("zts-engine");
const ir = engine.parser.ir;
const object = engine.object;
const atom_table = engine.atom_table;
const mb = engine.module_binding;
const bool_checker_mod = @import("bool_checker.zig");

const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;
const LabelSet = mb.LabelSet;

const packBindingKey = bool_checker_mod.packBindingKey;

const tag_count = @typeInfo(NodeTag).@"enum".fields.len;

/// Every allocation is an arena allocation, so the only failure is memory.
pub const Error = std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Domain
// ---------------------------------------------------------------------------

pub const SiteKind = enum(u8) {
    /// An array or object literal.
    literal,
    /// A function object. Functions are mutable at runtime (`object.zig`
    /// 1753), so `g.x = secret` has to land somewhere a later `g.x` can read.
    function,
    /// The request and its headers. P2 never creates these. P7 models R4 as
    /// synthetic containers, and the kinds exist now so that a seed can name
    /// them and the key type does not change shape later.
    request,
    headers,
};

/// An allocation site. `context` is 0 until a later phase separates the
/// callers of one function.
pub const SiteKey = struct {
    kind: SiteKind,
    node: NodeIndex,
    context: u16,

    fn order(a: SiteKey, b: SiteKey) std.math.Order {
        const by_kind = std.math.order(@intFromEnum(a.kind), @intFromEnum(b.kind));
        if (by_kind != .eq) return by_kind;
        const by_node = std.math.order(a.node, b.node);
        if (by_node != .eq) return by_node;
        return std.math.order(a.context, b.context);
    }
};

fn nodeOrder(a: NodeIndex, b: NodeIndex) std.math.Order {
    return std.math.order(a, b);
}

/// What an expression can be. Bottom is the absence of a value (`?Value` is
/// null), never an empty value: an empty `Value` is a reachable primitive that
/// carries nothing, and conflating the two is how a join drops a branch.
///
/// A value is immutable once built. A join builds new storage, so a state copy
/// can share values safely.
pub const Value = struct {
    labels: LabelSet = .empty,
    /// Sorted and deduplicated.
    origins: []const SiteKey = &.{},
    /// The value may point at an object this analysis cannot name.
    origins_top: bool = false,
    /// Function-expression nodes, sorted and deduplicated.
    callables: []const NodeIndex = &.{},
    callables_top: bool = false,

    /// A primitive that carries nothing.
    pub const clean: Value = .{};

    /// What the analysis could not follow: carries `unknown`, may point at
    /// anything, and may be any function.
    pub const top: Value = .{
        .labels = .{ .unknown = true },
        .origins_top = true,
        .callables_top = true,
    };

    pub fn labelled(labels: LabelSet) Value {
        return .{ .labels = labels };
    }
};

fn mergeSorted(
    comptime T: type,
    arena: std.mem.Allocator,
    a: []const T,
    b: []const T,
    comptime order: fn (T, T) std.math.Order,
) Error![]const T {
    if (b.len == 0) return a;
    if (a.len == 0) return b;
    // A join of a value with itself is common (both arms read one variable),
    // so share the larger slice instead of copying when it already holds the
    // smaller one.
    if (isSubset(T, b, a, order)) return a;
    if (isSubset(T, a, b, order)) return b;
    const out = try arena.alloc(T, a.len + b.len);
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (i < a.len and j < b.len) : (n += 1) {
        switch (order(a[i], b[j])) {
            .lt => {
                out[n] = a[i];
                i += 1;
            },
            .gt => {
                out[n] = b[j];
                j += 1;
            },
            .eq => {
                out[n] = a[i];
                i += 1;
                j += 1;
            },
        }
    }
    while (i < a.len) : (i += 1) {
        out[n] = a[i];
        n += 1;
    }
    while (j < b.len) : (j += 1) {
        out[n] = b[j];
        n += 1;
    }
    return out[0..n];
}

fn isSubset(
    comptime T: type,
    small: []const T,
    big: []const T,
    comptime order: fn (T, T) std.math.Order,
) bool {
    var j: usize = 0;
    for (small) |item| {
        while (j < big.len and order(big[j], item) == .lt) j += 1;
        if (j == big.len or order(big[j], item) != .eq) return false;
    }
    return true;
}

/// The join of two reachable values. Labels use `mergeConditional`, so a
/// value counts as validated only when every path that produces it validated
/// it. The other parts are set unions with the `top` flags ORed.
fn joinValue(arena: std.mem.Allocator, a: Value, b: Value) Error!Value {
    return .{
        .labels = LabelSet.mergeConditional(a.labels, b.labels),
        .origins = try mergeSorted(SiteKey, arena, a.origins, b.origins, SiteKey.order),
        .origins_top = a.origins_top or b.origins_top,
        .callables = try mergeSorted(NodeIndex, arena, a.callables, b.callables, nodeOrder),
        .callables_top = a.callables_top or b.callables_top,
    };
}

/// Join with bottom: the other operand survives unchanged.
fn joinOpt(arena: std.mem.Allocator, a: ?Value, b: ?Value) Error!?Value {
    const x = a orelse return b;
    const y = b orelse return a;
    return try joinValue(arena, x, y);
}

/// The labels of `source` flow into a value copied out of it, and the
/// copied value keeps its own origins and callables because a copy of a
/// reference still names the same object.
fn withLabels(v: Value, labels: LabelSet) Value {
    var out = v;
    out.labels = LabelSet.mergeValues(v.labels, labels);
    return out;
}

const NamedMap = std.AutoHashMapUnmanaged(u16, Value);

/// The cells of one allocation site: a map from property-name atom to value,
/// and a `summary` for names the analysis cannot tell apart and for every array
/// element. A missing name stands for a reachable `undefined`, which is why a
/// read of an absent name yields `clean` and not bottom.
///
/// A `Cells` is never changed in place. A write builds a new one, so two state
/// copies may share the same `named` map.
pub const Cells = struct {
    named: NamedMap = .empty,
    summary: ?Value = null,
};

/// The union of two cell sets. A name on one side only keeps its value: the
/// other side stands for a reachable `undefined`, not for bottom. P6 must keep
/// that distinction when it joins defense facts.
fn joinCells(arena: std.mem.Allocator, a: Cells, b: Cells) Error!Cells {
    var named = try a.named.clone(arena);
    var it = b.named.iterator();
    while (it.next()) |entry| {
        const slot = try named.getOrPut(arena, entry.key_ptr.*);
        slot.value_ptr.* = if (slot.found_existing)
            try joinValue(arena, slot.value_ptr.*, entry.value_ptr.*)
        else
            entry.value_ptr.*;
    }
    return .{ .named = named, .summary = try joinOpt(arena, a.summary, b.summary) };
}

/// A weak update: join `v` into the cell `name`, or into the summary when
/// `name` is null. One site stands for every object it creates, so the old
/// content may still be live and a write never removes a label.
fn weakWriteCells(arena: std.mem.Allocator, cells: Cells, name: ?u16, v: Value) Error!Cells {
    if (name) |n| {
        var named = try cells.named.clone(arena);
        const slot = try named.getOrPut(arena, n);
        slot.value_ptr.* = if (slot.found_existing)
            try joinValue(arena, slot.value_ptr.*, v)
        else
            v;
        return .{ .named = named, .summary = cells.summary };
    }
    return .{
        .named = cells.named,
        .summary = (try joinOpt(arena, cells.summary, v)),
    };
}

const EnvMap = std.AutoHashMapUnmanaged(u32, Value);
const HeapMap = std.AutoHashMapUnmanaged(SiteKey, Cells);

/// The abstract machine state: the bindings of the function, the heap, and the
/// cells that writes through an unnamed target land in. A state is reachable
/// or bottom, and the join of bottom with `s` is `s`.
///
/// The maps are mutated in place by the one flow that owns the state. Every
/// copy that outlives a branch goes through `cloneState`, and the `Value` and
/// `Cells` held inside are immutable, so the clone is shallow past the maps.
pub const State = struct {
    reachable: bool = true,
    /// `packBindingKey(scope_id, slot)` to value.
    env: EnvMap = .empty,
    heap: HeapMap = .empty,
    /// Writes whose target origin is `top`. A read through any receiver sees
    /// them, because the unnamed object might be that receiver.
    top_cell: Cells = .{},

    pub const bottom: State = .{ .reachable = false };
};

fn cloneState(arena: std.mem.Allocator, s: State) Error!State {
    return .{
        .reachable = s.reachable,
        .env = try s.env.clone(arena),
        .heap = try s.heap.clone(arena),
        .top_cell = s.top_cell,
    };
}

/// The join of two states. A binding declared in one branch is out of scope
/// after it, so a key on one side keeps its value. When one side is bottom the
/// other is returned as it is: the caller must not use the operand it passed
/// once the result exists.
fn joinStates(arena: std.mem.Allocator, a: State, b: State) Error!State {
    if (!a.reachable) return b;
    if (!b.reachable) return a;

    var env = try a.env.clone(arena);
    var env_it = b.env.iterator();
    while (env_it.next()) |entry| {
        const slot = try env.getOrPut(arena, entry.key_ptr.*);
        slot.value_ptr.* = if (slot.found_existing)
            try joinValue(arena, slot.value_ptr.*, entry.value_ptr.*)
        else
            entry.value_ptr.*;
    }

    var heap = try a.heap.clone(arena);
    var heap_it = b.heap.iterator();
    while (heap_it.next()) |entry| {
        const slot = try heap.getOrPut(arena, entry.key_ptr.*);
        slot.value_ptr.* = if (slot.found_existing)
            try joinCells(arena, slot.value_ptr.*, entry.value_ptr.*)
        else
            entry.value_ptr.*;
    }

    return .{
        .reachable = true,
        .env = env,
        .heap = heap,
        .top_cell = try joinCells(arena, a.top_cell, b.top_cell),
    };
}

// --- equality, for the loop fixpoint ---

fn sliceEql(
    comptime T: type,
    a: []const T,
    b: []const T,
    comptime order: fn (T, T) std.math.Order,
) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (order(x, y) != .eq) return false;
    }
    return true;
}

/// Two values are equal when every part is: all label bits, both `top` flags,
/// and the sorted, duplicate-free slices element by element. The slices are
/// canonical because every constructor and every join keeps them sorted, and
/// `analyzeFunction` canonicalizes the parameters it is given.
fn valueEql(a: Value, b: Value) bool {
    const a_bits: u16 = @bitCast(a.labels);
    const b_bits: u16 = @bitCast(b.labels);
    return a_bits == b_bits and
        a.origins_top == b.origins_top and
        a.callables_top == b.callables_top and
        sliceEql(SiteKey, a.origins, b.origins, SiteKey.order) and
        sliceEql(NodeIndex, a.callables, b.callables, nodeOrder);
}

/// Bottom equals only bottom.
fn optValueEql(a: ?Value, b: ?Value) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return valueEql(x, y);
}

/// Equality of two maps from a key to a value by the count and keyed lookup,
/// never by insertion order.
fn valueMapEql(a: anytype, b: @TypeOf(a)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |entry| {
        const other = b.get(entry.key_ptr.*) orelse return false;
        if (!valueEql(entry.value_ptr.*, other)) return false;
    }
    return true;
}

fn cellsEql(a: Cells, b: Cells) bool {
    return valueMapEql(a.named, b.named) and optValueEql(a.summary, b.summary);
}

/// Whether two states are the same abstract state. Two unreachable states are
/// equal. The summaries take part: a loop can change only a summary on a later
/// pass, and a comparison that skipped it would stop the loop too early.
fn stateEql(a: State, b: State) bool {
    if (a.reachable != b.reachable) return false;
    if (!a.reachable) return true;
    if (!valueMapEql(a.env, b.env)) return false;
    if (a.heap.count() != b.heap.count()) return false;
    var it = a.heap.iterator();
    while (it.next()) |entry| {
        const other = b.heap.get(entry.key_ptr.*) orelse return false;
        if (!cellsEql(entry.value_ptr.*, other)) return false;
    }
    return cellsEql(a.top_cell, b.top_cell);
}

/// A copy of `v` whose slices live in `arena`, sorted and without duplicates.
/// The caller of `analyzeFunction` may pass slices from its own stack in any
/// order, and equality assumes the canonical form.
fn canonicalValue(arena: std.mem.Allocator, v: Value) Error!Value {
    var out = v;
    out.origins = try canonicalSlice(SiteKey, arena, v.origins, SiteKey.order);
    out.callables = try canonicalSlice(NodeIndex, arena, v.callables, nodeOrder);
    return out;
}

fn canonicalSlice(
    comptime T: type,
    arena: std.mem.Allocator,
    items: []const T,
    comptime order: fn (T, T) std.math.Order,
) Error![]const T {
    const copy = try arena.dupe(T, items);
    const Less = struct {
        fn lessThan(_: void, x: T, y: T) bool {
            return order(x, y) == .lt;
        }
    };
    std.mem.sort(T, copy, {}, Less.lessThan);
    var n: usize = 0;
    for (copy) |item| {
        if (n > 0 and order(copy[n - 1], item) == .eq) continue;
        copy[n] = item;
        n += 1;
    }
    return copy[0..n];
}

// ---------------------------------------------------------------------------
// Results and the tag census
// ---------------------------------------------------------------------------

/// The phase that will resolve a construct this phase leaves unresolved.
pub const Phase = enum { p4, p5, p6, p7, p8 };

/// How the evaluators treat one `NodeTag`. P9 requires that no tag is `later`.
pub const TagPlan = union(enum) {
    /// A rule exists and resolves the tag in every context the census uses.
    handled,
    /// The phase that adds the rule. Until then the tag is unresolved.
    later: Phase,
    /// The restricted profile refuses the construct, so no accepted program
    /// holds it.
    refused_by_parser,
    /// The parser produces no such node, or produces it only where a parent
    /// rule reads it through an accessor, so it is never an evaluation target.
    not_produced,
};

/// Why a construct is unresolved: the phase that owns it, or the reason that
/// no phase does. `fixpoint_limit` marks a loop that reached `max_loop_passes`
/// before its head stopped changing.
pub const Owner = enum { p4, p5, p6, p7, p8, fixpoint_limit, refused_by_parser, not_produced };

pub const Unresolved = struct {
    node: NodeIndex,
    tag: NodeTag,
    owner: Owner,
};

pub const CompletionKind = enum {
    returned,
    /// A failed `assert cond, message;`: the message becomes the response.
    assert_message,
    /// A failed `assert cond;`: the runtime halts and answers with `undefined`
    /// (the prerequisite code generation fix).
    halt,
};

pub const Completion = struct {
    kind: CompletionKind,
    value: ?Value,
    state: State,
};

pub const FunctionResult = struct {
    /// Join of every returned value, every assert message, every halt value,
    /// and `clean` when the end of the body is reachable (an implicit
    /// `return undefined`).
    returned: ?Value,
    /// Join of the states of every completion and of the fallthrough.
    exit: State,
    completions: []const Completion,
    /// True when any construct was unresolved: every flow property is then
    /// cleared, and `returned` and `exit` carry no guarantee.
    cleared: bool,
    unresolved: []const Unresolved,
};

fn ownerOfPhase(phase: Phase) Owner {
    return switch (phase) {
        .p4 => .p4,
        .p5 => .p5,
        .p6 => .p6,
        .p7 => .p7,
        .p8 => .p8,
    };
}

/// A handled tag that reaches an evaluator in a position its parent rule does
/// not read (an `object_property` evaluated as an expression) is the parser
/// putting a tag where it never does, so it reports `not_produced`.
fn ownerOf(tag: NodeTag) Owner {
    return switch (tagPlan(tag)) {
        .later => |phase| ownerOfPhase(phase),
        .refused_by_parser => .refused_by_parser,
        .handled, .not_produced => .not_produced,
    };
}

/// The disposition of every node tag. The switch has no `else` arm, so a new
/// tag fails to compile until it has a row here and in `eval` and `exec`.
pub fn tagPlan(tag: NodeTag) TagPlan {
    return switch (tag) {
        .lit_int,
        .lit_float,
        .lit_string,
        .lit_bool,
        .lit_null,
        .lit_undefined,
        .identifier,
        .binary_op,
        .unary_op,
        .ternary,
        .member_access,
        .computed_access,
        .optional_chain,
        .assignment,
        .array_literal,
        .object_literal,
        .object_property,
        .object_spread,
        .function_expr,
        .arrow_function,
        .match_expr,
        .match_arm,
        .match_pattern,
        .match_type_test,
        .expr_stmt,
        .var_decl,
        .if_stmt,
        .return_stmt,
        .assert_stmt,
        .block,
        .function_decl,
        .pattern_element,
        .for_of_stmt,
        .break_stmt,
        .continue_stmt,
        => .handled,

        // A call and a call-site spread need callee summaries.
        .call, .spread => .{ .later = .p4 },
        .array_pattern => .{ .later = .p6 },

        .await_expr,
        .yield_expr,
        .for_stmt,
        .for_in_stmt,
        .while_stmt,
        .do_while_stmt,
        .switch_stmt,
        .case_clause,
        .throw_stmt,
        .try_stmt,
        .labeled_stmt,
        => .refused_by_parser,

        .method_call,
        .object_method,
        .object_getter,
        .object_setter,
        .sequence_expr,
        .comma_expr,
        .pattern_rest,
        .pattern_default,
        .import_decl,
        .import_specifier,
        .import_default,
        .import_namespace,
        .export_decl,
        .export_specifier,
        .export_default,
        .export_all,
        .program,
        .param_list,
        .arg_list,
        .stmt_list,
        => .not_produced,
    };
}

// ---------------------------------------------------------------------------
// The evaluator
// ---------------------------------------------------------------------------

/// A property key after evaluation: a name the analysis knows, or a value it
/// does not (the key's labels then travel with the access).
const Key = union(enum) {
    name: u16,
    dynamic: Value,
};

/// The states that leave the body of one `for...of` through `break` and
/// `continue`. Each is a clone, so no map is shared with a state that
/// execution mutates later.
const LoopFrame = struct {
    breaks: std.ArrayList(State) = .empty,
    continues: std.ArrayList(State) = .empty,
};

pub const FlowInterp = struct {
    arena: std.heap.ArenaAllocator,
    ir_view: IrView,
    atoms: ?*atom_table.AtomTable,
    completions: std.ArrayList(Completion) = .empty,
    unresolved_list: std.ArrayList(Unresolved) = .empty,
    /// The enclosing loops, innermost last. A `break` or `continue` acts on the
    /// last one. The parser clears the loop flag at each function boundary, so
    /// neither crosses into a nested function.
    loop_frames: std.ArrayList(LoopFrame) = .empty,
    /// The pass cap of one loop. It is a fail-closed exit and not the
    /// termination argument: the loop head only grows over finite components.
    /// A value below 1 is treated as 1.
    max_loop_passes: u32 = 256,
    /// How often each tag reached `eval`, `exec`, or a parent rule that reads
    /// it through an accessor. The census test reads this to prove that its
    /// corpus reached every handled tag. It counts across calls.
    visits: [tag_count]u32 = @splat(0),

    pub fn init(allocator: std.mem.Allocator, ir_view: IrView, atoms: ?*atom_table.AtomTable) FlowInterp {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ir_view = ir_view,
            .atoms = atoms,
        };
    }

    pub fn deinit(self: *FlowInterp) void {
        self.arena.deinit();
    }

    fn mem(self: *FlowInterp) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn tagVisits(self: *const FlowInterp, tag: NodeTag) u32 {
        return self.visits[@intFromEnum(tag)];
    }

    fn noteVisited(self: *FlowInterp, tag: NodeTag) void {
        self.visits[@intFromEnum(tag)] +|= 1;
    }

    /// Analyze one function body with its parameters bound to `params`
    /// (missing entries are `clean`). The result lives in the arena. `func`
    /// is a function expression, an arrow function, or a function declaration.
    pub fn analyzeFunction(self: *FlowInterp, func: NodeIndex, params: []const Value) Error!FunctionResult {
        self.completions = .empty;
        self.unresolved_list = .empty;
        self.loop_frames = .empty;
        var st: State = .{};

        // The accessors read payload words, so the tag is checked first: a
        // node of any other tag would be decoded as a function.
        const func_tag = self.ir_view.getTag(func) orelse .stmt_list;
        const function = (if (func_tag == .function_expr or func_tag == .arrow_function)
            self.ir_view.getFunction(func)
        else if (func_tag == .function_decl)
            self.ir_view.getFunctionOfDecl(func)
        else
            null) orelse {
            _ = try self.missing(func);
            return self.finish(State.bottom);
        };

        var i: usize = 0;
        while (i < function.params_count) : (i += 1) {
            const param_idx = self.ir_view.getListIndex(function.params_start, @intCast(i));
            const param_tag = self.ir_view.getTag(param_idx) orelse .stmt_list;
            const binding = self.ir_view.paramBinding(param_idx) orelse {
                try self.record(param_idx, param_tag, .refused_by_parser);
                continue;
            };
            self.noteVisited(param_tag);
            // The slices of a parameter belong to the caller and may be
            // unsorted, so the analysis keeps its own canonical copy.
            var value = if (i < params.len) try canonicalValue(self.mem(), params[i]) else Value.clean;
            // A default value joins the passed one: the caller may omit it.
            if (param_tag == .pattern_element) {
                if (self.ir_view.getPatternElem(param_idx)) |elem| {
                    if (elem.default_value != null_node) {
                        const fallback = try self.eval(elem.default_value, &st);
                        value = try joinValue(self.mem(), value, fallback);
                    }
                }
            }
            try st.env.put(self.mem(), packBindingKey(binding.scope_id, binding.slot), value);
        }

        try self.exec(function.body, &st);
        return self.finish(st);
    }

    fn finish(self: *FlowInterp, fallthrough: State) Error!FunctionResult {
        const arena = self.mem();
        var returned: ?Value = null;
        var exit = State.bottom;
        for (self.completions.items) |completion| {
            returned = try joinOpt(arena, returned, completion.value);
            exit = try joinStates(arena, exit, completion.state);
        }
        if (fallthrough.reachable) {
            returned = try joinOpt(arena, returned, Value.clean);
            exit = try joinStates(arena, exit, fallthrough);
        }
        const completions = try self.completions.toOwnedSlice(arena);
        const unresolved = try self.unresolved_list.toOwnedSlice(arena);
        return .{
            .returned = returned,
            .exit = exit,
            .completions = completions,
            .cleared = unresolved.len > 0,
            .unresolved = unresolved,
        };
    }

    // --- unresolved records ---

    fn record(self: *FlowInterp, node: NodeIndex, tag: NodeTag, owner: Owner) Error!void {
        try self.unresolved_list.append(self.mem(), .{ .node = node, .tag = tag, .owner = owner });
    }

    /// An unresolved expression: the analysis could not follow it, so the
    /// value is `top` and the function result is cleared.
    fn unresolvedNode(self: *FlowInterp, node: NodeIndex, tag: NodeTag) Error!Value {
        try self.record(node, tag, ownerOf(tag));
        return Value.top;
    }

    /// A node the rule needs and the accessor cannot read. The parser does not
    /// produce this, so it is recorded as an unproduced list tag.
    fn missing(self: *FlowInterp, node: NodeIndex) Error!Value {
        try self.record(node, .stmt_list, .not_produced);
        return Value.top;
    }

    // --- names ---

    /// The atom of a property name. This is the resolution that code generation
    /// uses (`resolveKeyAtom`), so a literal key and a `.name` access meet in
    /// the same cell.
    fn atomOf(self: *FlowInterp, name: []const u8, string_idx: u16) Error!u16 {
        if (object.lookupPredefinedAtom(name)) |atom| return @truncate(@intFromEnum(atom));
        if (self.atoms) |table| return @truncate(@intFromEnum(try table.intern(name)));
        return @truncate(object.Atom.FIRST_DYNAMIC + @as(u32, string_idx));
    }

    /// The name of a string-literal key node, or null for any other node.
    fn literalKey(self: *FlowInterp, key_node: NodeIndex) Error!?u16 {
        if ((self.ir_view.getTag(key_node) orelse return null) != .lit_string) return null;
        const string_idx = self.ir_view.getStringIdx(key_node) orelse return null;
        const text = self.ir_view.getString(string_idx) orelse "";
        return try self.atomOf(text, string_idx);
    }

    // --- reads and writes (R14) ---

    fn siteValue(self: *FlowInterp, site: SiteKey, callable: ?NodeIndex) Error!Value {
        const arena = self.mem();
        return .{
            .origins = try arena.dupe(SiteKey, &.{site}),
            .callables = if (callable) |node| try arena.dupe(NodeIndex, &.{node}) else &.{},
        };
    }

    /// Join `cells` into `acc`: the named cell and the summary, or every cell
    /// when `name` is null.
    fn absorb(self: *FlowInterp, acc: ?Value, cells: Cells, name: ?u16) Error!?Value {
        const arena = self.mem();
        var out = acc;
        if (name) |n| {
            if (cells.named.get(n)) |v| out = try joinOpt(arena, out, v);
        } else {
            var it = cells.named.valueIterator();
            while (it.next()) |v| out = try joinOpt(arena, out, v.*);
        }
        if (cells.summary) |summary| out = try joinOpt(arena, out, summary);
        return out;
    }

    /// The join of every cell a read of `name` through `o` can see, or null
    /// when it sees none. A static read (`name` set) sees the named cell and
    /// the summary of each origin. A dynamic read sees every cell. Both always
    /// see `top_cell`, because the unnamed object a write went to might be `o`,
    /// and both see every site's cells when `o` may point anywhere.
    fn visible(self: *FlowInterp, st: *const State, o: Value, name: ?u16) Error!?Value {
        var acc: ?Value = null;
        for (o.origins) |site| {
            if (st.heap.get(site)) |cells| acc = try self.absorb(acc, cells, name);
        }
        acc = try self.absorb(acc, st.top_cell, name);
        if (o.origins_top) {
            var it = st.heap.valueIterator();
            while (it.next()) |cells| acc = try self.absorb(acc, cells.*, null);
        }
        return acc;
    }

    /// An absent cell is a reachable `undefined`, so a read that sees nothing
    /// yields `clean`. The receiver and key labels join the result: a property
    /// of a labelled value, and a selection by a labelled key, carry the label
    /// (R1).
    fn readValue(self: *FlowInterp, st: *const State, o: Value, key: Key) Error!Value {
        return switch (key) {
            .name => |n| blk: {
                const seen = try self.visible(st, o, n);
                break :blk withLabels(seen orelse Value.clean, o.labels);
            },
            .dynamic => |k| blk: {
                const seen = try self.visible(st, o, null);
                const labels = LabelSet.mergeValues(o.labels, k.labels);
                break :blk withLabels(seen orelse Value.clean, labels);
            },
        };
    }

    /// Every cell a dynamic read of `o` can see, with `o`'s labels on the
    /// result. This is what a spread copies and what the tests inspect.
    pub fn readAll(self: *FlowInterp, state: State, o: Value) Error!Value {
        return self.readValue(&state, o, .{ .dynamic = Value.clean });
    }

    /// The cells a spread of `o` copies, as one cell set.
    fn snapshotCells(self: *FlowInterp, st: *const State, o: Value) Error!Cells {
        const arena = self.mem();
        var out: Cells = .{};
        for (o.origins) |site| {
            if (st.heap.get(site)) |cells| out = try joinCells(arena, out, cells);
        }
        out = try joinCells(arena, out, st.top_cell);
        if (o.origins_top) {
            var it = st.heap.valueIterator();
            while (it.next()) |cells| out = try joinCells(arena, out, cells.*);
        }
        return out;
    }

    fn weakWriteSite(self: *FlowInterp, st: *State, site: SiteKey, name: ?u16, v: Value) Error!void {
        const arena = self.mem();
        const current = st.heap.get(site) orelse Cells{};
        try st.heap.put(arena, site, try weakWriteCells(arena, current, name, v));
    }

    /// A write of `v` to `o.name` or `o[k]`. The stored value carries the
    /// labels of the receiver and the key, because a target chosen by a
    /// labelled value is itself a flow. Every origin takes a weak update, and
    /// a write through an unnamed target lands in `top_cell`. The expression
    /// value of the assignment is `v`, not the stored value.
    fn writeValue(self: *FlowInterp, st: *State, o: Value, key: Key, v: Value) Error!void {
        var labels = LabelSet.mergeValues(v.labels, o.labels);
        var name: ?u16 = null;
        switch (key) {
            .name => |n| name = n,
            .dynamic => |k| labels = LabelSet.mergeValues(labels, k.labels),
        }
        // The combined set replaces `v`'s labels. `withLabels` would merge it
        // with `v.labels` a second time, which can restore a `validated` flag
        // that the combination dropped.
        var stored = v;
        stored.labels = labels;
        for (o.origins) |site| try self.weakWriteSite(st, site, name, stored);
        if (o.origins_top) st.top_cell = try weakWriteCells(self.mem(), st.top_cell, name, stored);
    }

    /// Copy the cells `src` shows to a dynamic read into `site`. Each copied
    /// value takes the source's labels. A source that carries labels but shows
    /// no cell (a labelled string) still taints the result, in the summary,
    /// because every element or field of it is derived from it.
    fn spreadInto(self: *FlowInterp, st: *State, site: SiteKey, src: Value, keep_names: bool) Error!void {
        const view = try self.snapshotCells(st, src);
        var it = view.named.iterator();
        while (it.next()) |entry| {
            const name: ?u16 = if (keep_names) entry.key_ptr.* else null;
            try self.weakWriteSite(st, site, name, withLabels(entry.value_ptr.*, src.labels));
        }
        if (view.summary) |summary| {
            try self.weakWriteSite(st, site, null, withLabels(summary, src.labels));
        }
        if (!src.labels.isEmpty()) {
            try self.weakWriteSite(st, site, null, Value.labelled(src.labels));
        }
    }

    // --- expressions ---

    pub fn eval(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const tag = self.ir_view.getTag(node) orelse return self.missing(node);
        self.noteVisited(tag);
        switch (tag) {
            .lit_int, .lit_float, .lit_string, .lit_bool, .lit_null, .lit_undefined => return Value.clean,
            .identifier => return self.evalIdentifier(node, st),
            .binary_op => return self.evalBinary(node, st),
            .unary_op => {
                const unary = self.ir_view.getUnary(node) orelse return self.missing(node);
                const operand = try self.eval(unary.operand, st);
                return Value.labelled(operand.labels);
            },
            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return self.missing(node);
                _ = try self.eval(t.condition, st);
                var then_state = try cloneState(self.mem(), st.*);
                const then_value = try self.eval(t.then_branch, &then_state);
                const else_value = try self.eval(t.else_branch, st);
                st.* = try joinStates(self.mem(), then_state, st.*);
                return joinValue(self.mem(), then_value, else_value);
            },
            .member_access => {
                const m = self.ir_view.getMember(node) orelse return self.missing(node);
                const o = try self.eval(m.object, st);
                return self.readValue(st, o, .{ .name = m.property });
            },
            .optional_chain => {
                // The receiver is evaluated on both paths and a read changes
                // no state, so the join of the states before and after the
                // read is the state after the receiver.
                const m = self.ir_view.getMember(node) orelse return self.missing(node);
                const o = try self.eval(m.object, st);
                const read = try self.readValue(st, o, .{ .name = m.property });
                return joinValue(self.mem(), read, Value.clean);
            },
            .computed_access => {
                const m = self.ir_view.getMember(node) orelse return self.missing(node);
                const o = try self.eval(m.object, st);
                const key = try self.evalKey(m.computed, st);
                return self.readValue(st, o, key);
            },
            .assignment => return self.evalAssignment(node, st),
            .array_literal => return self.evalArray(node, st),
            .object_literal => return self.evalObject(node, st),
            .function_expr, .arrow_function => {
                // The body is not executed. P4 owns calls, so a function value
                // is only a name for its body and a mutable object.
                const site: SiteKey = .{ .kind = .function, .node = node, .context = 0 };
                return self.siteValue(site, node);
            },
            .call => {
                const c = self.ir_view.getCall(node) orelse return self.missing(node);
                _ = try self.eval(c.callee, st);
                var i: u16 = 0;
                while (i < c.args_count) : (i += 1) {
                    _ = try self.eval(self.ir_view.getListIndex(c.args_start, i), st);
                }
                try self.record(node, .call, .p4);
                return Value.top;
            },
            .match_expr => return self.evalMatch(node, st),

            // The parser produces none of these, or produces them only inside
            // a parent whose rule reads them through an accessor, or refuses
            // them. Reached here they are unresolved.
            .method_call,
            .object_property,
            .object_method,
            .object_getter,
            .object_setter,
            .object_spread,
            .spread,
            .await_expr,
            .yield_expr,
            .sequence_expr,
            .comma_expr,
            .match_arm,
            .match_pattern,
            .match_type_test,
            .expr_stmt,
            .var_decl,
            .if_stmt,
            .for_stmt,
            .for_of_stmt,
            .for_in_stmt,
            .while_stmt,
            .do_while_stmt,
            .switch_stmt,
            .case_clause,
            .return_stmt,
            .assert_stmt,
            .throw_stmt,
            .break_stmt,
            .continue_stmt,
            .try_stmt,
            .block,
            .labeled_stmt,
            .function_decl,
            .array_pattern,
            .pattern_element,
            .pattern_rest,
            .pattern_default,
            .import_decl,
            .import_specifier,
            .import_default,
            .import_namespace,
            .export_decl,
            .export_specifier,
            .export_default,
            .export_all,
            .program,
            .param_list,
            .arg_list,
            .stmt_list,
            => return self.unresolvedNode(node, tag),
        }
    }

    fn evalIdentifier(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const binding = self.ir_view.getBinding(node) orelse return self.missing(node);
        switch (binding.kind) {
            .local, .argument => {
                if (st.env.get(packBindingKey(binding.scope_id, binding.slot))) |v| return v;
                // Read before its declaration ran. The runtime does not hoist
                // a function declaration, so the slot holds something this
                // evaluator never saw.
                try self.record(node, .identifier, .p4);
                return Value.top;
            },
            // P4 owns captures and P8 owns module state.
            .upvalue => {
                try self.record(node, .identifier, .p4);
                return Value.top;
            },
            .global, .undeclared_global => {
                try self.record(node, .identifier, .p8);
                return Value.top;
            },
        }
    }

    fn evalBinary(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const bin = self.ir_view.getBinary(node) orelse return self.missing(node);
        switch (bin.op) {
            .and_op, .or_op, .nullish => {
                // The right operand runs only on some paths, so it runs in a
                // copy and its writes join with the paths that skip it.
                const left = try self.eval(bin.left, st);
                var right_state = try cloneState(self.mem(), st.*);
                const right = try self.eval(bin.right, &right_state);
                st.* = try joinStates(self.mem(), st.*, right_state);
                return joinValue(self.mem(), left, right);
            },
            else => {
                // Left, then right, as code generation does. The result of an
                // arithmetic or comparison operator is a fresh primitive.
                const left = try self.eval(bin.left, st);
                const right = try self.eval(bin.right, st);
                return Value.labelled(LabelSet.mergeValues(left.labels, right.labels));
            },
        }
    }

    /// Evaluate a computed key once. A string literal is a static name.
    fn evalKey(self: *FlowInterp, key_node: NodeIndex, st: *State) Error!Key {
        const value = try self.eval(key_node, st);
        if (try self.literalKey(key_node)) |name| return .{ .name = name };
        return .{ .dynamic = value };
    }

    /// The combined value of `old op rhs` for a compound assignment. A logical
    /// operator runs its right side on some paths only.
    fn compoundValue(self: *FlowInterp, op: ir.BinaryOp, old: Value, rhs_node: NodeIndex, st: *State) Error!Value {
        switch (op) {
            .and_op, .or_op, .nullish => {
                var right_state = try cloneState(self.mem(), st.*);
                const rhs = try self.eval(rhs_node, &right_state);
                st.* = try joinStates(self.mem(), st.*, right_state);
                return joinValue(self.mem(), old, rhs);
            },
            else => {
                const rhs = try self.eval(rhs_node, st);
                return Value.labelled(LabelSet.mergeValues(old.labels, rhs.labels));
            },
        }
    }

    fn evalAssignment(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const asg = self.ir_view.getAssignment(node) orelse return self.missing(node);
        const target_tag = self.ir_view.getTag(asg.target) orelse return self.missing(node);
        switch (target_tag) {
            .identifier => {
                const binding = self.ir_view.getBinding(asg.target) orelse return self.missing(node);
                switch (binding.kind) {
                    .local, .argument => {
                        const key = packBindingKey(binding.scope_id, binding.slot);
                        const assigned = if (asg.op) |op| blk: {
                            const old = st.env.get(key) orelse old_blk: {
                                try self.record(asg.target, .identifier, .p4);
                                break :old_blk Value.top;
                            };
                            break :blk try self.compoundValue(op, old, asg.value, st);
                        } else try self.eval(asg.value, st);
                        try st.env.put(self.mem(), key, assigned);
                        return assigned;
                    },
                    // P4 owns captured bindings and P8 owns module state.
                    .upvalue, .global, .undeclared_global => {
                        const assigned = try self.eval(asg.value, st);
                        try self.record(node, .assignment, if (binding.kind == .upvalue) .p4 else .p8);
                        return assigned;
                    },
                }
            },
            .member_access => {
                // Receiver first, then the right side. The receiver value is
                // kept for the write, so a right side that reassigns the
                // receiver's binding does not move the write.
                const m = self.ir_view.getMember(asg.target) orelse return self.missing(node);
                const o = try self.eval(m.object, st);
                const key: Key = .{ .name = m.property };
                return self.assignThrough(st, o, key, asg);
            },
            .computed_access => {
                const m = self.ir_view.getMember(asg.target) orelse return self.missing(node);
                const o = try self.eval(m.object, st);
                const key = try self.evalKey(m.computed, st);
                return self.assignThrough(st, o, key, asg);
            },
            // The restricted profile has no other assignment target.
            else => {
                _ = try self.eval(asg.value, st);
                try self.record(node, .assignment, .refused_by_parser);
                return Value.top;
            },
        }
    }

    fn assignThrough(self: *FlowInterp, st: *State, o: Value, key: Key, asg: ir.Node.AssignExpr) Error!Value {
        const assigned = if (asg.op) |op| blk: {
            const old = try self.readValue(st, o, key);
            break :blk try self.compoundValue(op, old, asg.value, st);
        } else try self.eval(asg.value, st);
        try self.writeValue(st, o, key, assigned);
        return assigned;
    }

    fn evalArray(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const arr = self.ir_view.getArray(node) orelse return self.missing(node);
        const site: SiteKey = .{ .kind = .literal, .node = node, .context = 0 };
        var i: u16 = 0;
        while (i < arr.elements_count) : (i += 1) {
            const element = self.ir_view.getListIndex(arr.elements_start, i);
            if ((self.ir_view.getTag(element) orelse .stmt_list) == .spread) {
                self.noteVisited(.spread);
                const operand = self.ir_view.getOptValue(element) orelse return self.missing(node);
                const src = try self.eval(operand, st);
                try self.spreadInto(st, site, src, false);
            } else {
                const v = try self.eval(element, st);
                try self.weakWriteSite(st, site, null, v);
            }
        }
        return self.siteValue(site, null);
    }

    fn evalObject(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const obj = self.ir_view.getObject(node) orelse return self.missing(node);
        const site: SiteKey = .{ .kind = .literal, .node = node, .context = 0 };
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop_tag = self.ir_view.getTag(prop_idx) orelse .stmt_list;
            switch (prop_tag) {
                .object_property => {
                    self.noteVisited(.object_property);
                    const prop = self.ir_view.getProperty(prop_idx) orelse return self.missing(node);
                    const v = try self.eval(prop.value, st);
                    if (try self.literalKey(prop.key)) |name| {
                        try self.weakWriteSite(st, site, name, v);
                    } else {
                        // A computed record key is refused. If one arrives the
                        // value may sit under any name.
                        try self.record(prop_idx, .object_property, .refused_by_parser);
                        try self.weakWriteSite(st, site, null, v);
                    }
                },
                .object_spread => {
                    self.noteVisited(.object_spread);
                    const operand = self.ir_view.getOptValue(prop_idx) orelse return self.missing(node);
                    const src = try self.eval(operand, st);
                    try self.spreadInto(st, site, src, true);
                },
                // A method, getter, or setter: the parser refuses all three.
                else => _ = try self.unresolvedNode(prop_idx, prop_tag),
            }
        }
        return self.siteValue(site, null);
    }

    fn evalMatch(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const m = self.ir_view.getMatchExpr(node) orelse return self.missing(node);
        const disc = try self.eval(m.discriminant, st);
        const arena = self.mem();

        var result: ?Value = null;
        var joined = State.bottom;
        var has_default = false;
        var i: u8 = 0;
        while (i < m.arms_count) : (i += 1) {
            const arm_idx = self.ir_view.getListIndex(m.arms_start, i);
            const arm = self.ir_view.getMatchArm(arm_idx) orelse return self.missing(node);
            self.noteVisited(.match_arm);
            if (arm.pattern == null_node) has_default = true;

            var arm_state = try cloneState(arena, st.*);
            try self.bindPattern(arm.pattern, disc, &arm_state);
            const v = try self.eval(arm.body, &arm_state);
            result = try joinOpt(arena, result, v);
            joined = try joinStates(arena, joined, arm_state);
        }
        // Code generation pushes `undefined` when no arm matches and there is
        // no default, so that path exists and keeps the state after the
        // discriminant.
        if (!has_default) {
            result = try joinOpt(arena, result, Value.clean);
            joined = try joinStates(arena, joined, st.*);
        }
        st.* = joined;
        return result orelse Value.clean;
    }

    /// Bind the fields a record pattern names. A binding gets the static read
    /// of its field from the discriminant, so it carries that field's cell and
    /// the discriminant's labels and not a neighbouring field's.
    fn bindPattern(self: *FlowInterp, pattern: NodeIndex, disc: Value, st: *State) Error!void {
        if (pattern == null_node) return;
        const tag = self.ir_view.getTag(pattern) orelse return;
        switch (tag) {
            .match_pattern => {
                self.noteVisited(.match_pattern);
                const pat = self.ir_view.getMatchPattern(pattern) orelse return;
                var i: u16 = 0;
                while (i < pat.props_count) : (i += 1) {
                    const prop_idx = self.ir_view.getListIndex(pat.props_start, i);
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    self.noteVisited(.object_property);
                    if (prop.value == null_node) continue;
                    const value_tag = self.ir_view.getTag(prop.value) orelse continue;
                    switch (value_tag) {
                        .identifier => {
                            const binding = self.ir_view.getBinding(prop.value) orelse continue;
                            const name = (try self.literalKey(prop.key)) orelse {
                                try self.record(prop_idx, .object_property, .refused_by_parser);
                                continue;
                            };
                            const field = try self.readValue(st, disc, .{ .name = name });
                            try st.env.put(self.mem(), packBindingKey(binding.scope_id, binding.slot), field);
                        },
                        // A nested record or array pattern binds below the
                        // first level, which P2 does not follow.
                        .match_pattern, .array_pattern => try self.record(prop.value, value_tag, .p6),
                        // exhaustive: a record pattern field holds a binding, a
                        // nested pattern, or a literal. A literal is a
                        // discriminant test and binds nothing, and the tags the
                        // parser never puts in a pattern bind nothing either.
                        else => {},
                    }
                }
            },
            .match_type_test => self.noteVisited(.match_type_test),
            .array_pattern => try self.record(pattern, .array_pattern, .p6),
            // exhaustive: an arm pattern is a record, an array, a type test, a
            // literal, or the default. Only the first two bind a name, and a
            // literal is a discriminant test that binds nothing.
            else => {},
        }
    }

    // --- statements ---

    pub fn exec(self: *FlowInterp, node: NodeIndex, st: *State) Error!void {
        // A statement after `return` never runs.
        if (!st.reachable) return;
        const tag = self.ir_view.getTag(node) orelse {
            _ = try self.missing(node);
            return;
        };
        self.noteVisited(tag);
        switch (tag) {
            .block => {
                const b = self.ir_view.getBlock(node) orelse {
                    _ = try self.missing(node);
                    return;
                };
                var i: u16 = 0;
                while (i < b.stmts_count and st.reachable) : (i += 1) {
                    try self.exec(self.ir_view.getListIndex(b.stmts_start, i), st);
                }
            },
            .var_decl => {
                const vd = self.ir_view.getVarDecl(node) orelse {
                    _ = try self.missing(node);
                    return;
                };
                // Code generation stores `undefined` for a declaration without
                // an initializer, so the binding is `clean` and not whatever an
                // earlier block left in the reused slot.
                const v = if (vd.init == null_node) Value.clean else try self.eval(vd.init, st);
                try self.bindDeclared(st, vd.binding, v, node, tag);
            },
            .function_decl => {
                // In statement order, like the runtime: there is no hoisting.
                const vd = self.ir_view.getVarDecl(node) orelse {
                    _ = try self.missing(node);
                    return;
                };
                if (self.ir_view.getFunctionOfDecl(node) == null) {
                    _ = try self.missing(node);
                    return;
                }
                const v = try self.eval(vd.init, st);
                try self.bindDeclared(st, vd.binding, v, node, tag);
            },
            .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |expr| _ = try self.eval(expr, st);
            },
            .if_stmt => {
                const s = self.ir_view.getIfStmt(node) orelse {
                    _ = try self.missing(node);
                    return;
                };
                _ = try self.eval(s.condition, st);
                var then_state = try cloneState(self.mem(), st.*);
                try self.exec(s.then_branch, &then_state);
                if (s.else_branch != null_node) try self.exec(s.else_branch, st);
                st.* = try joinStates(self.mem(), then_state, st.*);
            },
            .return_stmt => {
                const v = if (self.ir_view.getOptValue(node)) |expr|
                    try self.eval(expr, st)
                else
                    Value.clean;
                try self.completions.append(self.mem(), .{ .kind = .returned, .value = v, .state = st.* });
                st.* = State.bottom;
            },
            .assert_stmt => {
                const s = self.ir_view.getAssertStmt(node) orelse {
                    _ = try self.missing(node);
                    return;
                };
                _ = try self.eval(s.condition, st);
                // The assert held on the path that continues, so the original
                // state goes on. The failure is a completion of its own.
                var failed = try cloneState(self.mem(), st.*);
                if (s.error_expr == null_node) {
                    try self.completions.append(self.mem(), .{ .kind = .halt, .value = Value.clean, .state = failed });
                } else {
                    const message = try self.eval(s.error_expr, &failed);
                    try self.completions.append(self.mem(), .{ .kind = .assert_message, .value = message, .state = failed });
                }
            },

            // An expression used as a statement runs for its effects.
            .lit_int,
            .lit_float,
            .lit_string,
            .lit_bool,
            .lit_null,
            .lit_undefined,
            .identifier,
            .binary_op,
            .unary_op,
            .ternary,
            .call,
            .method_call,
            .member_access,
            .computed_access,
            .optional_chain,
            .assignment,
            .array_literal,
            .object_literal,
            .object_property,
            .object_method,
            .object_getter,
            .object_setter,
            .object_spread,
            .function_expr,
            .arrow_function,
            .spread,
            .await_expr,
            .yield_expr,
            .sequence_expr,
            .comma_expr,
            .match_expr,
            .match_arm,
            .match_pattern,
            .match_type_test,
            => _ = try self.eval(node, st),

            .for_of_stmt => try self.execForOf(node, st),
            .break_stmt, .continue_stmt => try self.leaveLoop(node, tag, st),

            // The forms the parser refuses, and the structural tags that a
            // parent reads through its accessor.
            .for_stmt,
            .for_in_stmt,
            .while_stmt,
            .do_while_stmt,
            .switch_stmt,
            .case_clause,
            .throw_stmt,
            .try_stmt,
            .labeled_stmt,
            .array_pattern,
            .pattern_element,
            .pattern_rest,
            .pattern_default,
            .import_decl,
            .import_specifier,
            .import_default,
            .import_namespace,
            .export_decl,
            .export_specifier,
            .export_default,
            .export_all,
            .program,
            .param_list,
            .arg_list,
            .stmt_list,
            => try self.record(node, tag, ownerOf(tag)),
        }
    }

    /// `break` or `continue`: park a clone of the current state in the
    /// innermost loop frame and make the current state bottom. With no frame
    /// the parser would have refused the statement, so a synthetic node is
    /// unresolved.
    fn leaveLoop(self: *FlowInterp, node: NodeIndex, tag: NodeTag, st: *State) Error!void {
        if (self.loop_frames.items.len == 0) {
            try self.record(node, tag, .refused_by_parser);
            st.* = State.bottom;
            return;
        }
        const arena = self.mem();
        const parked = try cloneState(arena, st.*);
        const frame = &self.loop_frames.items[self.loop_frames.items.len - 1];
        switch (tag) {
            .break_stmt => try frame.breaks.append(arena, parked),
            .continue_stmt => try frame.continues.append(arena, parked),
            else => try self.record(node, tag, .not_produced),
        }
        st.* = State.bottom;
    }

    /// A `for...of` loop as a fixpoint over the loop head.
    ///
    /// The iterable is evaluated once, as code generation does. Pass `k` binds
    /// the loop variable to every cell the iterable shows in `head_k` (an
    /// earlier iteration can write an element a later one reads), runs the body
    /// on a clone, and joins the result into `head_{k+1}` together with every
    /// `continue` state of the pass. The join keeps `head_k`, so the heads
    /// ascend, and every component is finite for a program, so they stop. The
    /// equality check runs before the cap check, so a loop that converges on
    /// the last permitted pass has converged.
    ///
    /// The state after the loop is the final head, which stands for leaving
    /// when the index reaches the length after zero or more iterations, joined
    /// with every `break` state. Completions and unresolved entries from every
    /// pass are kept.
    fn execForOf(self: *FlowInterp, node: NodeIndex, st: *State) Error!void {
        const arena = self.mem();
        const loop = self.ir_view.getForIter(node) orelse {
            _ = try self.missing(node);
            return;
        };
        // The parser builds every `for_of_stmt` with `is_for_in` false and
        // refuses `for-in`, whose iteration yields keys and not elements.
        if (loop.is_for_in) {
            try self.record(node, .for_in_stmt, .refused_by_parser);
            return;
        }
        const iterable = try self.eval(loop.iterable, st);
        const cap = @max(self.max_loop_passes, 1);

        var head = st.*;
        var breaks: std.ArrayList(State) = .empty;
        var pass: u32 = 0;
        while (true) : (pass +|= 1) {
            var body = try cloneState(arena, head);
            const element = try self.readAll(head, iterable);
            try self.bindDeclared(&body, loop.binding, element, node, .for_of_stmt);

            const depth = self.loop_frames.items.len;
            try self.loop_frames.append(arena, .{});
            try self.exec(loop.body, &body);
            const frame = self.loop_frames.items[depth];
            self.loop_frames.shrinkRetainingCapacity(depth);

            try breaks.appendSlice(arena, frame.breaks.items);
            var next = try joinStates(arena, head, body);
            for (frame.continues.items) |parked| next = try joinStates(arena, next, parked);

            if (stateEql(next, head)) break;
            head = next;
            if (pass +| 1 >= cap) {
                try self.record(node, .for_of_stmt, .fixpoint_limit);
                break;
            }
        }

        var exit = head;
        for (breaks.items) |parked| exit = try joinStates(arena, exit, parked);
        st.* = exit;
    }

    /// A strong update of a declared binding. Only function-local bindings
    /// live in `env`; a declaration of any other kind belongs to module state.
    fn bindDeclared(
        self: *FlowInterp,
        st: *State,
        binding: ir.BindingRef,
        v: Value,
        node: NodeIndex,
        tag: NodeTag,
    ) Error!void {
        switch (binding.kind) {
            .local, .argument => try st.env.put(self.mem(), packBindingKey(binding.scope_id, binding.slot), v),
            .upvalue, .global, .undeclared_global => try self.record(node, tag, .p8),
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const JsParser = engine.parser.JsParser;

const secret: LabelSet = .{ .secret = true };

/// A parsed source and the evaluator over it. The parser keeps a pointer to
/// the atom table, so the harness is heap allocated and never moves.
const Harness = struct {
    allocator: std.mem.Allocator,
    parser: JsParser,
    atoms: atom_table.AtomTable,
    interp: FlowInterp,

    fn create(allocator: std.mem.Allocator, source: []const u8) !*Harness {
        const h = try allocator.create(Harness);
        errdefer allocator.destroy(h);
        h.allocator = allocator;
        h.atoms = atom_table.AtomTable.init(allocator);
        errdefer h.atoms.deinit();
        h.parser = try JsParser.init(allocator, source);
        errdefer h.parser.deinit();
        h.parser.setAtomTable(&h.atoms);
        _ = try h.parser.parse();
        const view = IrView.fromIRStore(&h.parser.nodes, &h.parser.constants);
        h.interp = FlowInterp.init(allocator, view, &h.atoms);
        return h;
    }

    fn destroy(h: *Harness) void {
        const allocator = h.allocator;
        h.interp.deinit();
        h.parser.deinit();
        h.atoms.deinit();
        allocator.destroy(h);
    }

    fn nameOf(h: *Harness, atom_idx: u16) ?[]const u8 {
        const atom: object.Atom = @enumFromInt(atom_idx);
        if (atom.toPredefinedName()) |name| return name;
        return h.atoms.getName(atom);
    }

    /// The first function declaration called `name`, at any depth.
    fn find(h: *Harness, name: []const u8) !NodeIndex {
        const view = h.interp.ir_view;
        var i: usize = 0;
        while (i < view.nodeCount()) : (i += 1) {
            const idx: NodeIndex = @intCast(i);
            if ((view.getTag(idx) orelse continue) != .function_decl) continue;
            const decl = view.getVarDecl(idx) orelse continue;
            const found = h.nameOf(decl.binding.name_atom) orelse continue;
            if (std.mem.eql(u8, found, name)) return idx;
        }
        return error.FunctionNotFound;
    }

    fn analyze(h: *Harness, name: []const u8, params: []const Value) !FunctionResult {
        return h.interp.analyzeFunction(try h.find(name), params);
    }
};

const secret_value = Value.labelled(secret);

/// Analyze `f` in `source` and return its result. The harness is returned for
/// the caller to destroy, because the result lives in its arena.
const Run = struct {
    harness: *Harness,
    result: FunctionResult,

    fn deinit(run: Run) void {
        run.harness.destroy();
    }

    fn returnedLabels(run: Run) LabelSet {
        return (run.result.returned orelse return .empty).labels;
    }
};

fn analyzeSource(source: []const u8, name: []const u8, params: []const Value) !Run {
    const h = try Harness.create(testing.allocator, source);
    errdefer h.destroy();
    return .{ .harness = h, .result = try h.analyze(name, params) };
}

/// Run `f` and require a fully resolved result whose returned labels have the
/// secret flag set or clear.
fn expectSecret(source: []const u8, params: []const Value, expected: bool) !void {
    const r = try analyzeSource(source, "f", params);
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expectEqual(expected, r.returnedLabels().secret);
    if (!expected) try testing.expect(r.returnedLabels().isEmpty());
}

test "a literal returns clean and a parameter seeded secret returns secret" {
    try expectSecret("function f(s) { return \"lit\"; }", &.{secret_value}, false);
    try expectSecret("function f(s) { return s; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return s; }", &.{Value.clean}, false);
}

test "each operand position of a binary operator carries its label" {
    const secret_then_clean = [_]Value{ secret_value, Value.clean };
    const clean_then_secret = [_]Value{ Value.clean, secret_value };
    const clean_both = [_]Value{ Value.clean, Value.clean };
    try expectSecret("function f(s) { return s + 1; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return 1 + s; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return s > 3; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return 3 > s; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return -s; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return !s; }", &.{secret_value}, true);
    try expectSecret("function f(a, b) { return a + b; }", &secret_then_clean, true);
    try expectSecret("function f(a, b) { return a + b; }", &clean_then_secret, true);
    try expectSecret("function f(a, b) { return a + b; }", &clean_both, false);
    try expectSecret("function f(s) { return 1 + 2; }", &.{secret_value}, false);
    try expectSecret("function f(s) { return -1; }", &.{secret_value}, false);
}

test "logical operators join both operands and keep the right operand's write" {
    const secret_then_clean = [_]Value{ secret_value, Value.clean };
    const clean_then_secret = [_]Value{ Value.clean, secret_value };
    const clean_both = [_]Value{ Value.clean, Value.clean };
    inline for (.{ "&&", "||", "??" }) |op| {
        const source = "function f(a, b) { return a " ++ op ++ " b; }";
        try expectSecret(source, &secret_then_clean, true);
        try expectSecret(source, &clean_then_secret, true);
        try expectSecret(source, &clean_both, false);
    }

    // The write sits in the right operand and the left operand may skip it,
    // so the exit state holds it on the joined path.
    const write = "function f(a, s) { const h = {}; a && (h.x = s); return h; }";
    const r = try analyzeSource(write, "f", &.{ Value.clean, secret_value });
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    const seen = try r.harness.interp.readAll(r.result.exit, r.result.returned.?);
    try testing.expect(seen.labels.secret);

    const clean_write = "function f(a, s) { const h = {}; a && (h.x = \"c\"); return h; }";
    const c = try analyzeSource(clean_write, "f", &.{ Value.clean, secret_value });
    defer c.deinit();
    const unseen = try c.harness.interp.readAll(c.result.exit, c.result.returned.?);
    try testing.expect(unseen.labels.isEmpty());
}

test "a ternary carries a secret from either arm and from either arm's write" {
    const arm_a = [_]Value{ Value.clean, secret_value, Value.clean };
    const arm_b = [_]Value{ Value.clean, Value.clean, secret_value };
    const source = "function f(c, a, b) { return c ? a : b; }";
    try expectSecret(source, &arm_a, true);
    try expectSecret(source, &arm_b, true);
    try expectSecret(source, &.{ Value.clean, Value.clean, Value.clean }, false);

    const then_write = "function f(c, s) { const h = {}; c ? (h.x = s) : (h.y = \"k\"); return h; }";
    const else_write = "function f(c, s) { const h = {}; c ? (h.x = \"k\") : (h.y = s); return h; }";
    const both_clean = "function f(c, s) { const h = {}; c ? (h.x = \"k\") : (h.y = \"j\"); return h; }";
    inline for (.{ then_write, else_write, both_clean }, .{ true, true, false }) |src, leaks| {
        const r = try analyzeSource(src, "f", &.{ Value.clean, secret_value });
        defer r.deinit();
        try testing.expect(!r.result.cleared);
        const seen = try r.harness.interp.readAll(r.result.exit, r.result.returned.?);
        try testing.expectEqual(leaks, seen.labels.secret);
    }
}

test "an if joins its branches and keeps the raw value of either path" {
    const raw = [_]Value{ Value.clean, secret_value };
    // The P0 shape: the raw value arrives in one branch.
    try expectSecret(
        "function f(c, raw) { let x = \"clean\"; if (c) { x = raw; } else { x = \"clean2\"; } return x; }",
        &raw,
        true,
    );
    try expectSecret(
        "function f(c, raw) { let x = \"clean\"; if (c) { x = \"clean2\"; } else { x = raw; } return x; }",
        &raw,
        true,
    );
    // The raw value is in the initializer and one branch overwrites it.
    try expectSecret(
        "function f(c, raw) { let x = raw; if (c) { x = \"clean\"; } return x; }",
        &raw,
        true,
    );
    try expectSecret(
        "function f(c, raw) { let x = raw; if (c) { x = \"a\"; } else { x = \"b\"; } return x; }",
        &raw,
        false,
    );
    try expectSecret(
        "function f(c, raw) { let x = \"clean\"; if (c) { x = \"a\"; } else { x = \"b\"; } return x; }",
        &raw,
        false,
    );
}

test "an array literal carries its element and the key that selects it" {
    try expectSecret("function f(s) { return [s][0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [s][0]; }", &.{Value.clean}, false);
    try expectSecret("function f(i) { return [\"a\", \"b\"][i]; }", &.{secret_value}, true);
    try expectSecret("function f(i) { return [\"a\", \"b\"][i]; }", &.{Value.clean}, false);
    try expectSecret("function f(s) { return [\"a\", \"b\"][0]; }", &.{secret_value}, false);
}

test "a write through an alias is visible through the other name" {
    const through_variable =
        "function f(s) { const a = [\"x\"]; const b = a; b[0] = s; return a[0]; }";
    const through_field =
        "function f(s) { const a = [\"x\"]; const h = { items: a }; h.items[0] = s; return a[0]; }";
    const other_array =
        "function f(s) { const a = [\"x\"]; const c = [\"y\"]; c[0] = s; return a[0]; }";
    const overwritten =
        "function f(s) { const a = [\"x\"]; a[0] = s; a[0] = \"c\"; return a[0]; }";
    const clean_only =
        "function f(s) { const a = [\"x\"]; a[0] = \"c\"; a[0] = \"d\"; return a[0]; }";
    try expectSecret(through_variable, &.{secret_value}, true);
    try expectSecret(through_variable, &.{Value.clean}, false);
    try expectSecret(through_field, &.{secret_value}, true);
    try expectSecret(through_field, &.{Value.clean}, false);
    // Separate allocation sites stay separate.
    try expectSecret(other_array, &.{secret_value}, false);
    // A weak update never removes a label from a cell.
    try expectSecret(overwritten, &.{secret_value}, true);
    try expectSecret(clean_only, &.{secret_value}, false);
}

test "a static read sees one field and a dynamic read sees every field" {
    try expectSecret("function f(s) { return { a: s, b: \"x\" }.b; }", &.{secret_value}, false);
    try expectSecret("function f(s) { return { a: s, b: \"x\" }.a; }", &.{secret_value}, true);
    try expectSecret("function f(s, k) { const o = { a: s, b: \"x\" }; return o[k]; }", &.{ secret_value, Value.clean }, true);
    try expectSecret("function f(s, k) { const o = { a: s, b: \"x\" }; return o[\"b\"]; }", &.{ secret_value, Value.clean }, false);
    try expectSecret("function f(s, k) { const o = { a: \"y\", b: \"x\" }; return o[k]; }", &.{ secret_value, Value.clean }, false);
}

test "receiver and key labels travel with a read and a write" {
    const read_labelled_key = "function f(s) { const a = []; const table = [a]; return table[s][0]; }";
    try expectSecret(read_labelled_key, &.{secret_value}, true);
    try expectSecret(read_labelled_key, &.{Value.clean}, false);

    const write_through_key = "function f(s) { const a = {}; const table = [a]; table[s].x = \"X\"; return a.x; }";
    try expectSecret(write_through_key, &.{secret_value}, true);
    try expectSecret(write_through_key, &.{Value.clean}, false);

    // A write at a labelled key stores the key's label in the cell it picks.
    const write_at_key = "function f(s) { const t = [\"a\"]; t[s] = \"X\"; return t[0]; }";
    try expectSecret(write_at_key, &.{secret_value}, true);
    try expectSecret(write_at_key, &.{Value.clean}, false);

    // A property of a labelled value carries the label.
    try expectSecret("function f(s) { return s.length; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return s.length; }", &.{Value.clean}, false);
}

test "a spread copies its source's cells and labels" {
    try expectSecret("function f(s) { return [...[s]][0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [...[s]][0]; }", &.{Value.clean}, false);
    try expectSecret("function f(s) { return { ...{ a: s } }.a; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return { ...{ a: \"c\" } }.a; }", &.{secret_value}, false);
    const labelled_source = "function f(s) { const table = [{ x: \"c\" }]; return { ...table[s] }.x; }";
    try expectSecret(labelled_source, &.{secret_value}, true);
    try expectSecret(labelled_source, &.{Value.clean}, false);
    // A labelled value with no cells still taints what it spreads into.
    try expectSecret("function f(s) { return { ...s }.x; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [...s][0]; }", &.{secret_value}, true);
}

test "a function value is a mutable object" {
    const source = "function f(s) { const g = () => 0; g.x = s; return g.x; }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(source, &.{Value.clean}, false);

    // The value of a function expression names its body.
    const r = try analyzeSource("function f() { const g = () => 0; return g; }", "f", &.{});
    defer r.deinit();
    const returned = r.result.returned.?;
    try testing.expectEqual(@as(usize, 1), returned.callables.len);
    try testing.expectEqual(@as(usize, 1), returned.origins.len);
    try testing.expectEqual(SiteKind.function, returned.origins[0].kind);
}

test "an unnamed origin and a named origin see each other's writes" {
    const known = [_]SiteKey{.{ .kind = .request, .node = 1, .context = 0 }};
    const unnamed: Value = .{ .origins_top = true };
    const named: Value = .{ .origins = &known };
    const params = [_]Value{ unnamed, named, secret_value };

    // A write through the unnamed target reaches a static read of a named one.
    try expectSecret("function f(p, q, s) { p.x = s; return q.x; }", &params, true);
    // The static read of another name does not see it.
    try expectSecret("function f(p, q, s) { p.x = s; return q.y; }", &params, false);
    // And the reverse: a read through the unnamed target sees every site.
    try expectSecret("function f(p, q, s) { q.x = s; return p.x; }", &params, true);
    try expectSecret("function f(p, q, s) { q.y = \"c\"; return p.x; }", &params, false);
    // A dynamic read through the named origin sees every top cell.
    try expectSecret("function f(p, q, s, k) { p.x = s; return q[k]; }", &.{ unnamed, named, secret_value, Value.clean }, true);
}

test "the receiver is evaluated before a right side that reassigns it" {
    const site_a = [_]SiteKey{.{ .kind = .request, .node = 1, .context = 0 }};
    const site_b = [_]SiteKey{.{ .kind = .request, .node = 2, .context = 0 }};
    const a: Value = .{ .origins = &site_a };
    const b: Value = .{ .origins = &site_b };
    const params = [_]Value{ a, b, secret_value };
    const body = "let o = a; o.x = ((o = b) === b ? s : 0); ";
    // The write lands on the receiver the left side named.
    try expectSecret("function f(a, b, s) { " ++ body ++ "return a.x; }", &params, true);
    try expectSecret("function f(a, b, s) { " ++ body ++ "return b.x; }", &params, false);
}

test "an assert message is a completion and a bare assert halts with clean" {
    const with_message = try analyzeSource("function f(c, s) { assert c, s; return \"ok\"; }", "f", &.{ Value.clean, secret_value });
    defer with_message.deinit();
    try testing.expect(!with_message.result.cleared);
    try testing.expect(with_message.returnedLabels().secret);
    try testing.expectEqual(@as(usize, 2), with_message.result.completions.len);
    try testing.expectEqual(CompletionKind.assert_message, with_message.result.completions[0].kind);

    const clean_message = try analyzeSource("function f(c, s) { assert c, \"no\"; return \"ok\"; }", "f", &.{ Value.clean, secret_value });
    defer clean_message.deinit();
    try testing.expect(clean_message.returnedLabels().isEmpty());

    const bare = try analyzeSource("function f(c, s) { assert c; return \"ok\"; }", "f", &.{ Value.clean, secret_value });
    defer bare.deinit();
    try testing.expect(!bare.result.cleared);
    try testing.expectEqual(@as(usize, 2), bare.result.completions.len);
    try testing.expectEqual(CompletionKind.halt, bare.result.completions[0].kind);
    try testing.expect(bare.result.completions[0].value.?.labels.isEmpty());
    try testing.expect(bare.returnedLabels().isEmpty());
}

test "the exit state joins a returning branch's writes with the fallthrough" {
    const source = "function f(c, s) { const h = {}; if (c) { h.x = s; return 1; } return h; }";
    const r = try analyzeSource(source, "f", &.{ Value.clean, secret_value });
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expectEqual(@as(usize, 2), r.result.completions.len);
    // The returned `h` is only the fallthrough value, but the write sits in
    // the state of the branch that returned.
    const seen = try r.harness.interp.readAll(r.result.exit, r.result.returned.?);
    try testing.expect(seen.labels.secret);

    const clean = "function f(c, s) { const h = {}; if (c) { h.x = \"k\"; return 1; } return h; }";
    const c = try analyzeSource(clean, "f", &.{ Value.clean, secret_value });
    defer c.deinit();
    const unseen = try c.harness.interp.readAll(c.result.exit, c.result.returned.?);
    try testing.expect(unseen.labels.isEmpty());
}

test "a function declaration binds in statement order" {
    const after = try analyzeSource("function f() { function g() { return 1; } const r = g; return r; }", "f", &.{});
    defer after.deinit();
    try testing.expect(!after.result.cleared);
    try testing.expectEqual(@as(usize, 1), after.result.returned.?.callables.len);

    const before = try analyzeSource("function f() { const r = g; function g() { return 1; } return r; }", "f", &.{});
    defer before.deinit();
    try testing.expect(before.result.cleared);
    try testing.expect(before.result.returned.?.labels.unknown);
    try testing.expectEqual(NodeTag.identifier, before.result.unresolved[0].tag);
}

fn expectUnresolved(result: FunctionResult, tag: NodeTag, owner: Owner) !void {
    try testing.expect(result.cleared);
    for (result.unresolved) |entry| {
        if (entry.tag == tag and entry.owner == owner) return;
    }
    return error.UnresolvedEntryNotFound;
}

test "a call, an upvalue read, and a nested pattern clear the result with their owner" {
    const call = try analyzeSource("function f(g) { return g(1); }", "f", &.{Value.clean});
    defer call.deinit();
    try expectUnresolved(call.result, .call, .p4);
    try testing.expect(call.result.returned.?.labels.unknown);

    const upvalue = try analyzeSource(
        "function outer() { const k = 1; function inner() { return k; } return inner; }",
        "inner",
        &.{},
    );
    defer upvalue.deinit();
    try expectUnresolved(upvalue.result, .identifier, .p4);

    const nested = try analyzeSource(
        "function f(x) { return match (x) { when { a: { b: v } }: v default: 0 }; }",
        "f",
        &.{Value.clean},
    );
    defer nested.deinit();
    try expectUnresolved(nested.result, .match_pattern, .p6);

    // The contrast: the same shapes without the construct stay resolved.
    const plain = try analyzeSource("function f(x) { return x; }", "f", &.{Value.clean});
    defer plain.deinit();
    try testing.expect(!plain.result.cleared);
}

test "match arms join and a record pattern binding reads its own field" {
    const bound = "function f(s) { const o = { kind: \"a\", text: s }; return match (o) { when { kind: \"a\", text }: text default: \"k\" }; }";
    try expectSecret(bound, &.{secret_value}, true);
    try expectSecret(bound, &.{Value.clean}, false);

    // The binding reads `text`, not the neighbouring field.
    const other_field = "function f(s) { const o = { kind: \"a\", text: \"c\", other: s }; return match (o) { when { kind: \"a\", text }: text default: \"k\" }; }";
    try expectSecret(other_field, &.{secret_value}, false);

    // The default arm contributes to the join.
    const default_arm = "function f(s, x) { return match (x) { when \"a\": \"c\" default: s }; }";
    try expectSecret(default_arm, &.{ secret_value, Value.clean }, true);
    const first_arm = "function f(s, x) { return match (x) { when \"a\": s default: \"c\" }; }";
    try expectSecret(first_arm, &.{ secret_value, Value.clean }, true);
    try expectSecret(first_arm, &.{ Value.clean, Value.clean }, false);

    // Without a default the runtime answers `undefined` on no match, so the
    // join includes a clean path and keeps the labels of the arms.
    const no_default = "function f(s, x) { return match (x) { when \"a\": s when \"b\": \"c\" }; }";
    try expectSecret(no_default, &.{ secret_value, Value.clean }, true);
}

test "a binding declared without an initializer is clean" {
    const source = "function f(s, c) { if (c) { const a = s; } if (c) { let b; return b; } return \"end\"; }";
    const r = try analyzeSource(source, "f", &.{ secret_value, Value.clean });
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expect(r.returnedLabels().isEmpty());
}

// --- loops (P3) ---
//
// These sources are internal evaluator fixtures, not checked modules: several
// mutate the array they iterate, which the strict checker refuses.

const xs_secret = [_]Value{ Value.clean, secret_value };

test "a loop-carried value needs a second pass" {
    const body = "{ out[0] = r; r = s; }";
    const carried = "function f(xs, s) { let r = \"c\"; const out = [\"x\"]; for (const v of xs) " ++ body ++ " return out[0]; }";
    const clean = "function f(xs, s) { let r = \"c\"; const out = [\"x\"]; for (const v of xs) { out[0] = r; r = \"d\"; } return out[0]; }";
    try expectSecret(carried, &xs_secret, true);
    try expectSecret(clean, &xs_secret, false);
}

test "a write to a later element of the iterated array reaches the next iteration" {
    try expectSecret(
        "function f(s) { const a = [\"x\", \"y\"]; let r = \"c\"; for (const v of a) { r = v; a[1] = s; } return r; }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { const a = [\"x\", \"y\"]; let r = \"c\"; for (const v of a) { r = v; a[1] = \"z\"; } return r; }",
        &.{secret_value},
        false,
    );
}

test "a loop may run zero times" {
    try expectSecret("function f(xs, s) { let r = s; for (const v of xs) { r = \"c\"; } return r; }", &xs_secret, true);
    try expectSecret("function f(xs, s) { let r = \"d\"; for (const v of xs) { r = \"c\"; } return r; }", &xs_secret, false);
}

test "break reaches the exit and code after it is dead" {
    try expectSecret(
        "function f(xs, s) { let r = \"c\"; for (const v of xs) { if (v) { r = s; break; } r = \"d\"; } return r; }",
        &xs_secret,
        true,
    );
    try expectSecret(
        "function f(xs, s) { let r = \"c\"; for (const v of xs) { if (v) { r = \"d\"; break; } r = \"d\"; } return r; }",
        &xs_secret,
        false,
    );
    try expectSecret("function f(xs, s) { let r = \"c\"; for (const v of xs) { break; r = s; } return r; }", &xs_secret, false);
}

test "continue reaches the head and skips the rest of the body" {
    try expectSecret(
        "function f(xs, s) { let r = \"c\"; const o = {}; for (const v of xs) { o.x = r; if (v) { r = s; continue; } } return o.x; }",
        &xs_secret,
        true,
    );
    try expectSecret(
        "function f(xs, s) { let r = \"c\"; const o = {}; for (const v of xs) { o.x = r; if (v) { r = \"d\"; continue; } } return o.x; }",
        &xs_secret,
        false,
    );
    try expectSecret("function f(xs, s) { let r = \"c\"; for (const v of xs) { continue; r = s; } return r; }", &xs_secret, false);
}

test "a return in the first pass carries the element" {
    try expectSecret("function f(s) { const a = [s]; for (const v of a) { return v; } return \"c\"; }", &.{secret_value}, true);
    try expectSecret("function f(s) { const a = [\"x\"]; for (const v of a) { return v; } return \"c\"; }", &.{secret_value}, false);
}

test "a return in a later pass is kept with the first pass's completion" {
    const returns = "function f(s) { let r = \"c\"; for (const stop of [false, true]) { if (stop) { return r; } r = s; } return \"c\"; }";
    const r = try analyzeSource(returns, "f", &.{secret_value});
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expect(r.returnedLabels().secret);
    // The first pass returns the clean `r` and the second the joined one:
    // both stay, ahead of the final return.
    try testing.expectEqual(@as(usize, 3), r.result.completions.len);
    try testing.expect(r.result.completions[0].value.?.labels.isEmpty());
    try testing.expect(r.result.completions[1].value.?.labels.secret);

    try expectSecret(
        "function f(s) { let r = \"c\"; for (const stop of [false, true]) { if (stop) { return r; } r = \"d\"; } return \"c\"; }",
        &.{secret_value},
        false,
    );

    // The same through an assert message.
    const asserts = "function f(s) { let r = \"c\"; for (const stop of [false, true]) { assert !stop, r; r = s; } return \"c\"; }";
    const a = try analyzeSource(asserts, "f", &.{secret_value});
    defer a.deinit();
    try testing.expect(!a.result.cleared);
    try testing.expectEqual(@as(usize, 3), a.result.completions.len);
    try testing.expectEqual(CompletionKind.assert_message, a.result.completions[0].kind);
    try testing.expect(a.result.completions[0].value.?.labels.isEmpty());
    try testing.expect(a.result.completions[1].value.?.labels.secret);
    try testing.expect(a.returnedLabels().secret);

    const clean_asserts = "function f(s) { let r = \"c\"; for (const stop of [false, true]) { assert !stop, r; r = \"d\"; } return \"c\"; }";
    const c = try analyzeSource(clean_asserts, "f", &.{secret_value});
    defer c.deinit();
    try testing.expect(!c.result.cleared);
    try testing.expect(c.returnedLabels().isEmpty());
}

test "a labelled primitive iterable labels the loop variable" {
    const source = "function f(s) { let r = \"c\"; for (const ch of s) { r = ch; } return r; }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(source, &.{Value.clean}, false);
}

test "break and continue act on the innermost loop only" {
    // The inner break leaves the inner loop, and the outer loop runs again.
    try expectSecret(
        "function f(xs, s) { let r = \"c\"; let t = \"c\"; for (const a of xs) { r = t; for (const b of xs) { t = s; break; } } return r; }",
        &xs_secret,
        true,
    );
    try expectSecret(
        "function f(xs, s) { let r = \"c\"; let t = \"c\"; for (const a of xs) { r = t; for (const b of xs) { t = \"d\"; break; } } return r; }",
        &xs_secret,
        false,
    );
    // The inner continue stays in the inner loop.
    try expectSecret(
        "function f(xs, s) { let r = \"c\"; for (const a of xs) { let u = \"c\"; for (const b of xs) { r = u; u = s; continue; } } return r; }",
        &xs_secret,
        true,
    );
    try expectSecret(
        "function f(xs, s) { let r = \"c\"; for (const a of xs) { let u = \"c\"; for (const b of xs) { r = u; u = \"d\"; continue; } } return r; }",
        &xs_secret,
        false,
    );
    // An inner break or continue does not feed the outer loop's own exit or
    // head: `x` is overwritten after the inner loop on every path.
    try expectSecret(
        "function f(xs, s) { let x = \"c\"; for (const a of xs) { x = s; for (const b of xs) { break; } x = \"d\"; } return x; }",
        &xs_secret,
        false,
    );
    try expectSecret(
        "function f(xs, s) { let x = \"c\"; for (const a of xs) { x = s; for (const b of xs) { continue; } x = \"d\"; } return x; }",
        &xs_secret,
        false,
    );
}

test "the loop variable keeps the origins of the element" {
    const source = "function f(s) { const item = { x: \"c\" }; for (const v of [item]) { v.x = s; return item.x; } return \"c\"; }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(
        "function f(s) { const item = { x: \"c\" }; for (const v of [item]) { v.x = \"d\"; return item.x; } return \"c\"; }",
        &.{secret_value},
        false,
    );
}

test "a change that reaches only a heap summary keeps the loop running" {
    const source = "function f(s) { const a = [\"c\"]; const b = [\"c\"]; const c = [\"c\"]; for (const v of [\"c\", \"c\", \"c\"]) { a[0] = b[0]; b[0] = c[0]; c[0] = s; } return a[0]; }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(
        "function f(s) { const a = [\"c\"]; const b = [\"c\"]; const c = [\"c\"]; for (const v of [\"c\", \"c\", \"c\"]) { a[0] = b[0]; b[0] = c[0]; c[0] = \"d\"; } return a[0]; }",
        &.{secret_value},
        false,
    );
}

test "a change that reaches only the origins keeps the loop running" {
    const source = "function f(s) { const p = { x: \"c\" }; const q = { x: s }; let m = p; let n = p; for (const v of [\"c\", \"c\"]) { m = n; n = q; } return m.x; }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(
        "function f(s) { const p = { x: \"c\" }; const q = { x: \"d\" }; let m = p; let n = p; for (const v of [\"c\", \"c\"]) { m = n; n = q; } return m.x; }",
        &.{secret_value},
        false,
    );
}

test "the iterable is evaluated once" {
    try expectSecret(
        "function f(s) { let a = [\"c\"]; let r = \"c\"; for (const v of a) { r = v; a = [s]; } return r; }",
        &.{secret_value},
        false,
    );
    try expectSecret(
        "function f(s) { let a = [\"c\"]; let r = \"c\"; for (const v of a) { r = v; a[0] = s; } return r; }",
        &.{secret_value},
        true,
    );
}

test "a loop that reaches the pass cap clears the result" {
    const source = "function f(xs, s) { let r = \"c\"; const out = [\"x\"]; for (const v of xs) { out[0] = r; r = s; } return out[0]; }";

    const capped = try Harness.create(testing.allocator, source);
    defer capped.destroy();
    capped.interp.max_loop_passes = 1;
    const one = try capped.analyze("f", &xs_secret);
    try expectUnresolved(one, .for_of_stmt, .fixpoint_limit);
    try testing.expect(one.cleared);

    // A cap below 1 is treated as 1.
    const zero = try Harness.create(testing.allocator, source);
    defer zero.destroy();
    zero.interp.max_loop_passes = 0;
    try expectUnresolved(try zero.analyze("f", &xs_secret), .for_of_stmt, .fixpoint_limit);

    // The loop needs three passes: two change the head, the third confirms it.
    // Convergence on the last permitted pass is convergence.
    const short = try Harness.create(testing.allocator, source);
    defer short.destroy();
    short.interp.max_loop_passes = 2;
    try expectUnresolved(try short.analyze("f", &xs_secret), .for_of_stmt, .fixpoint_limit);

    const exact = try Harness.create(testing.allocator, source);
    defer exact.destroy();
    exact.interp.max_loop_passes = 3;
    const three = try exact.analyze("f", &xs_secret);
    try testing.expect(!three.cleared);
    try testing.expectEqual(@as(usize, 0), three.unresolved.len);

    const roomy = try analyzeSource(source, "f", &xs_secret);
    defer roomy.deinit();
    try testing.expect(!roomy.result.cleared);
    try testing.expectEqual(@as(usize, 0), roomy.result.unresolved.len);
    try testing.expect(roomy.returnedLabels().secret);
}

test "a break or continue with no loop frame is unresolved" {
    inline for (.{ NodeTag.break_stmt, NodeTag.continue_stmt }) |tag| {
        var store = ir.IRStore.init(testing.allocator);
        defer store.deinit();
        var constants = ir.ConstantPool.init(testing.allocator);
        defer constants.deinit();
        _ = try store.addNode(tag, .{ .line = 1, .column = 1, .offset = 0 }, .{ .a = 0, .b = 0 });
        var interp = FlowInterp.init(testing.allocator, IrView.fromIRStore(&store, &constants), null);
        defer interp.deinit();
        var st: State = .{};
        try interp.exec(0, &st);
        try testing.expect(!st.reachable);
        const result = try interp.finish(st);
        try expectUnresolved(result, tag, .refused_by_parser);
    }
}

test "a change that reaches only the top cell keeps the loop running" {
    // `p` stands for an object of unknown origin, so its writes land in the
    // top cell. Every read also sees the top cell, so the loop variable would
    // change one pass after it. Iterating the labelled `s` makes it secret from
    // the first pass without a heap site that `p` could alias, so the second
    // pass changes only `top_cell.a`.
    const p: Value = .{ .origins_top = true };
    try expectSecret(
        "function f(p, s) { for (const v of s) { p.a = p.b; p.b = s; } return p.a; }",
        &.{ p, secret_value },
        true,
    );
    try expectSecret(
        "function f(p, s) { for (const v of s) { p.a = p.b; p.b = \"d\"; } return p.a; }",
        &.{ p, secret_value },
        false,
    );
}

test "a for_of_stmt marked for-in is refused" {
    var store = ir.IRStore.init(testing.allocator);
    defer store.deinit();
    var constants = ir.ConstantPool.init(testing.allocator);
    defer constants.deinit();
    // [binding, iterable, flags, body] with flag bit 0 set: a for-in. The
    // guard runs before the iterable and the body are read.
    const extra = try store.addExtra(&.{ 0, 0, 1, 0 });
    const node = try store.addNode(.for_of_stmt, .{ .line = 1, .column = 1, .offset = 0 }, .{ .a = extra, .b = 0 });
    var interp = FlowInterp.init(testing.allocator, IrView.fromIRStore(&store, &constants), null);
    defer interp.deinit();
    var st: State = .{};
    try interp.exec(node, &st);
    const result = try interp.finish(st);
    try expectUnresolved(result, .for_in_stmt, .refused_by_parser);
}

test "parameter values are canonicalized and copied" {
    const a: SiteKey = .{ .kind = .request, .node = 1, .context = 0 };
    const b: SiteKey = .{ .kind = .request, .node = 2, .context = 0 };
    const source = "function f(p) { return p; }";

    const ordered = [_]SiteKey{ a, b };
    const first = try analyzeSource(source, "f", &.{.{ .origins = &ordered, .callables = &.{ 3, 7 } }});
    defer first.deinit();

    // The same set, reversed and with duplicates.
    const shuffled = [_]SiteKey{ b, a, b, a };
    const second = try analyzeSource(source, "f", &.{.{ .origins = &shuffled, .callables = &.{ 7, 3, 7 } }});
    defer second.deinit();
    try testing.expect(valueEql(first.result.returned.?, second.result.returned.?));
    try testing.expectEqual(@as(usize, 2), second.result.returned.?.origins.len);
    try testing.expectEqual(@as(usize, 2), second.result.returned.?.callables.len);

    // A different set is a different value.
    const only_a = [_]SiteKey{a};
    const third = try analyzeSource(source, "f", &.{.{ .origins = &only_a, .callables = &.{ 3, 7 } }});
    defer third.deinit();
    try testing.expect(!valueEql(first.result.returned.?, third.result.returned.?));

    // The result survives the caller's slice.
    const owned = try testing.allocator.dupe(SiteKey, &shuffled);
    const owned_callables = try testing.allocator.dupe(NodeIndex, &.{ 7, 3 });
    const kept = try analyzeSource(source, "f", &.{.{ .origins = owned, .callables = owned_callables }});
    defer kept.deinit();
    @memset(owned, .{ .kind = .headers, .node = 99, .context = 9 });
    @memset(owned_callables, 99);
    testing.allocator.free(owned);
    testing.allocator.free(owned_callables);
    try testing.expect(valueEql(first.result.returned.?, kept.result.returned.?));
}

test "state equality ignores insertion order and tells bottom from a reachable state" {
    var arena_owner = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_owner.deinit();
    const arena = arena_owner.allocator();

    var x: State = .{};
    try x.env.put(arena, 1, Value.clean);
    try x.env.put(arena, 2, secret_value);
    var y: State = .{};
    try y.env.put(arena, 2, secret_value);
    try y.env.put(arena, 1, Value.clean);
    try testing.expect(stateEql(x, y));

    try y.env.put(arena, 2, Value.clean);
    try testing.expect(!stateEql(x, y));

    const site: SiteKey = .{ .kind = .literal, .node = 5, .context = 0 };
    var with_summary: State = .{};
    try with_summary.heap.put(arena, site, .{ .summary = Value.clean });
    var without_summary: State = .{};
    try without_summary.heap.put(arena, site, .{});
    try testing.expect(!stateEql(with_summary, without_summary));
    try testing.expect(stateEql(with_summary, with_summary));

    try testing.expect(stateEql(State.bottom, State.bottom));
    try testing.expect(!stateEql(State.bottom, State{}));
}

// --- the tag census ---

/// What a corpus run saw: which tags reached an evaluator, and which tags
/// were recorded as unresolved.
const Census = struct {
    visits: [tag_count]u32 = @splat(0),
    unresolved: [tag_count]u32 = @splat(0),

    fn absorb(census: *Census, interp: *const FlowInterp, result: ?FunctionResult) void {
        for (interp.visits, 0..) |count, i| census.visits[i] +|= count;
        const res = result orelse return;
        for (res.unresolved) |entry| census.unresolved[@intFromEnum(entry.tag)] += 1;
    }
};

/// Sources whose every construct is resolved. Each declares `f(p, q)` and
/// reads only its parameters and its own locals, so a handled tag that records
/// an unresolved entry here is a rule that does not do what `tagPlan` says.
const resolved_corpus = [_][]const u8{
    "function f(p, q) { const a = 1; const b = 1.5; const c = \"s\"; const d = true; const e = null; const u = undefined; let g; return a; }",
    "function f(p, q) { return -p + (p && q) + (p || q) + (p ?? q); }",
    "function f(p, q) { return p ? p.x : q[\"y\"]; }",
    "function f(p, q) { let x = p?.x; x = q; p.k = x; p[q] = x; p.k += 1; return p; }",
    "function f(p, q) { const a = [p, ...q]; const o = { k: p, ...q }; return o.k; }",
    "function f(p, q) { const g = () => p; const h = (z) => q; function inner() { return 1; } return inner; }",
    "function f(p, q) { if (p) { return 1; } else { return 2; } }",
    "function f(p, q) { assert p, \"no\"; assert q; return 1; }",
    "function f(p, q) { return match (p) { when { kind: \"a\", text }: text when \"x\": q when string: q default: 0 }; }",
    "function f(p, q) { p; return; }",
    "function f(p, q) { let r = p; for (const v of q) { if (v) { r = v; break; } if (r) { continue; } r = q; } return r; }",
};

/// Sources that hold a construct a later phase owns.
const unresolved_corpus = [_][]const u8{
    "function f(g) { return g(1); }",
    "function f(g, xs) { return g(...xs); }",
    "function f(x) { return match (x) { when [_, _]: 1 default: 0 }; }",
};

test "tagPlan agrees with eval and exec for every tag" {
    var census: Census = .{};

    for (resolved_corpus) |source| {
        const h = Harness.create(testing.allocator, source) catch |err| {
            std.debug.print("corpus source does not parse: {s}\n", .{source});
            return err;
        };
        defer h.destroy();
        const result = try h.analyze("f", &.{ Value.clean, Value.clean });
        census.absorb(&h.interp, result);
        // A handled tag records nothing here, so the whole result is resolved.
        if (result.cleared) {
            std.debug.print("unresolved in a resolved corpus source: {s}\n", .{source});
            for (result.unresolved) |entry| std.debug.print("  {s} {s}\n", .{ @tagName(entry.tag), @tagName(entry.owner) });
            return error.ResolvedCorpusWasCleared;
        }
    }
    for (unresolved_corpus) |source| {
        const h = Harness.create(testing.allocator, source) catch |err| {
            std.debug.print("corpus source does not parse: {s}\n", .{source});
            return err;
        };
        defer h.destroy();
        const result = try h.analyze("f", &.{ Value.clean, Value.clean });
        census.absorb(&h.interp, result);
    }

    // A tag the corpora did not record as unresolved is probed with a node
    // that holds no payload. The rule for such a tag must not read one.
    inline for (@typeInfo(NodeTag).@"enum".fields) |field| {
        const tag: NodeTag = @enumFromInt(field.value);
        const plan = tagPlan(tag);
        const index = @intFromEnum(tag);
        if (plan != .handled and census.unresolved[index] == 0) {
            if (tag == .call) return error.CallNeedsACorpusSource;
            var store = ir.IRStore.init(testing.allocator);
            defer store.deinit();
            var constants = ir.ConstantPool.init(testing.allocator);
            defer constants.deinit();
            _ = try store.addNode(tag, .{ .line = 1, .column = 1, .offset = 0 }, .{ .a = 0, .b = 0 });
            var interp = FlowInterp.init(testing.allocator, IrView.fromIRStore(&store, &constants), null);
            defer interp.deinit();
            var st: State = .{};
            _ = try interp.eval(0, &st);
            const after_eval = interp.unresolved_list.items.len;
            try interp.exec(0, &st);
            const after_exec = interp.unresolved_list.items.len;
            try testing.expect(after_eval >= 1);
            try testing.expect(after_exec > after_eval);
            census.unresolved[index] += 1;
        }
    }

    var handled: usize = 0;
    var later: usize = 0;
    var refused: usize = 0;
    var not_produced: usize = 0;
    var by_phase = [_]usize{0} ** @typeInfo(Phase).@"enum".fields.len;
    inline for (@typeInfo(NodeTag).@"enum".fields) |field| {
        const tag: NodeTag = @enumFromInt(field.value);
        const index = @intFromEnum(tag);
        switch (tagPlan(tag)) {
            .handled => {
                handled += 1;
                // The corpus reached the tag and no corpus source left it
                // unresolved.
                if (census.visits[index] == 0) {
                    std.debug.print("handled tag never reached by the corpus: {s}\n", .{field.name});
                    return error.HandledTagNotReached;
                }
            },
            .later => |phase| {
                later += 1;
                by_phase[@intFromEnum(phase)] += 1;
                try testing.expect(census.unresolved[index] > 0);
            },
            .refused_by_parser => {
                refused += 1;
                try testing.expect(census.unresolved[index] > 0);
            },
            .not_produced => {
                not_produced += 1;
                try testing.expect(census.unresolved[index] > 0);
            },
        }
    }
    try testing.expectEqual(tag_count, handled + later + refused + not_produced);
    try testing.expect(handled > 0 and later > 0 and refused > 0 and not_produced > 0);
    // After P3 only the call-shaped tags and the array pattern are left.
    try testing.expectEqual(@as(usize, 3), later);
    inline for (.{ NodeTag.call, NodeTag.spread, NodeTag.array_pattern }) |tag| {
        try testing.expect(tagPlan(tag) == .later);
    }
    inline for (.{ NodeTag.for_of_stmt, NodeTag.break_stmt, NodeTag.continue_stmt }) |tag| {
        try testing.expect(tagPlan(tag) == .handled);
    }
    std.debug.print(
        "flow_interp tagPlan: {d} tags, handled={d} later={d} (p4={d} p5={d} p6={d} p7={d} p8={d}) refused_by_parser={d} not_produced={d}\n",
        .{ tag_count, handled, later, by_phase[0], by_phase[1], by_phase[2], by_phase[3], by_phase[4], refused, not_produced },
    );
}
