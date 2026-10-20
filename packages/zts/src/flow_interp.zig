//! Flow evaluator, phases P2 to P6: the abstract domain, the location scheme,
//! the field-sensitive heap, an evaluator for expressions and statements,
//! `for...of` loops (P3), calls with captured bindings and recursion (P4), the
//! builtin globals with the operations that take no callback (P5a), the calls
//! of imported virtual-module exports (P5b), the callbacks of array methods,
//! `Array.from`, and seven exports (P5c), nested patterns in `match` (P6a),
//! and the defense facts with their sources and sink requirements (P6b).
//!
//! This is the shadow of the checker that will replace the label walk in
//! `flow_checker.zig`. Nothing in the pipeline, the CLI, or any verdict reads
//! it, so `flow_analyzer_version` and the policy hash stay where they are. The
//! design is in `docs/plans/2026-10-18-flow-checker-sound-redesign-plan.md`
//! (rounds 2 and 3 override its earlier text). The contracts are
//! `docs/plans/2026-10-19-flow-interp-p2-r16-spec.md`,
//! `docs/plans/2026-10-19-flow-interp-p3-spec.md`,
//! `docs/plans/2026-10-19-flow-interp-p4-spec.md`,
//! `docs/plans/2026-10-19-flow-interp-p5-spec.md`, and
//! `docs/plans/2026-10-20-flow-interp-p6-spec.md`.
//!
//! The old checker keeps one label set per binding and loses what a value
//! points at, so a write through an alias reaches nothing the reader can see.
//! This evaluator keeps three facts per value instead: the labels it carries,
//! the allocation sites it may point at (`origins`), and the function bodies it
//! may call (`callables`). A heap cell is named by an allocation site and a
//! property name, and one site stands for every object it creates, so every
//! write is a weak update: it joins with the cell and never removes a label.
//! Beside the labels, a value carries the defenses that request data passed
//! (`Defenses`), and an operation keeps or removes them at its own edge.
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
const known_globals = @import("zts-base").known_globals;

const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;
const LabelSet = mb.LabelSet;

const packBindingKey = bool_checker_mod.packBindingKey;

const tag_count = @typeInfo(NodeTag).@"enum".fields.len;

/// The default for `FlowInterp.max_steps`.
const default_max_steps: u32 = 100_000;

/// Every allocation is an arena allocation, so the only failures are memory
/// and the step budget. `analyzeFunction` turns the second into a cleared
/// result, so it never reaches a caller of the public entry point.
pub const Error = std.mem.Allocator.Error || error{BudgetExhausted};

const ScopeAnalyzer = engine.parser.ScopeAnalyzer;

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
    /// The cell of a captured binding. `node` holds the packed source key of
    /// the binding, and the cell is the site's `summary`. No value points at
    /// a capture site, so a read through an unnamed object never sees one.
    capture,
    /// An array that a builtin returns. `node` is the call node, and the site
    /// stands for every container the call makes, nested ones included.
    allocated_array,
    /// A container that may be an array, a record, a Dict, Bytes, or a native
    /// Result (`JSON.parse`, the request readers, `range`, `h`, and the result
    /// of an export). `node` is the call node.
    allocated_any,
    /// A container that holds native methods (the result of a `Response`
    /// static, of a fetch). `node` is the call node.
    native,
    /// The shared runtime objects reached under one name: a namespace, a
    /// global function, a namespace member, a prototype method read as a
    /// value. `node` holds the atom of that name, and `any_builtin` stands for
    /// all of them. Every request in one runtime shares these objects.
    builtin,
};

/// The atom of the `builtin` site that stands for every shared runtime object.
/// Atom 0 is `null`, which no property read reaches by name.
const any_builtin: u16 = 0;

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

/// A fact about request data that a sink may accept in place of a clean
/// value (R2). It sits beside the provenance labels and never replaces one.
pub const Defense = enum {
    /// Every character of the value that came from request data passed
    /// `escapeHtml`, and no later operation turned an escaped character back
    /// into markup. The claim is about request characters only: it says
    /// nothing about which author characters appear, where, or in what order
    /// (D25).
    html_escaped,
    /// The request-controlled part of the value passed a schema validator and
    /// was not reinterpreted afterwards. It does not claim that the value
    /// still satisfies the schema.
    schema_checked,
};

/// The set of defenses that a value holds. Both are false by default, so a
/// construct that forgets to compute defenses removes them. That costs
/// precision and never soundness.
pub const Defenses = packed struct(u8) {
    html_escaped: bool = false,
    schema_checked: bool = false,
    _reserved: u6 = 0,

    pub fn has(self: Defenses, defense: Defense) bool {
        return switch (defense) {
            .html_escaped => self.html_escaped,
            .schema_checked => self.schema_checked,
        };
    }

    /// The defenses that both sets hold.
    fn intersect(a: Defenses, b: Defenses) Defenses {
        const bits: u8 = @as(u8, @bitCast(a)) & @as(u8, @bitCast(b));
        return @bitCast(bits);
    }

    /// The defenses that either set holds.
    fn unite(a: Defenses, b: Defenses) Defenses {
        const bits: u8 = @as(u8, @bitCast(a)) | @as(u8, @bitCast(b));
        return @bitCast(bits);
    }

    /// The defenses of `self` that `removed` does not name.
    fn without(self: Defenses, removed: Defenses) Defenses {
        const bits: u8 = @as(u8, @bitCast(self)) & ~@as(u8, @bitCast(removed));
        return @bitCast(bits);
    }

    fn isEmpty(self: Defenses) bool {
        return @as(u8, @bitCast(self)) == 0;
    }
};

/// What a value carries, without its origins and callables: the provenance
/// labels and the defenses.
///
/// A flow is *exposed* when its labels hold `user_input` or `unknown`. A
/// defense on a flow that is not exposed means nothing, so the canonical form
/// has no defenses there. Every constructor and every join keeps flows
/// canonical.
pub const Flow = struct {
    labels: LabelSet = .empty,
    defenses: Defenses = .{},

    pub fn exposed(self: Flow) bool {
        return self.labels.user_input or self.labels.unknown;
    }

    /// The same flow with no defenses when it is not exposed.
    pub fn canonical(self: Flow) Flow {
        if (self.exposed()) return self;
        return .{ .labels = self.labels };
    }
};

/// The defenses of a value built from `a` and `b` as data, at a join or in a
/// combination (R13). A side that is not exposed holds every defense, because
/// no sink in the D24 table refuses a literal, so it is neutral. Among exposed
/// sides, fewer defenses is higher in the order, which is the AND.
fn combineDefenses(a: Flow, b: Flow) Defenses {
    if (!a.exposed()) return b.defenses;
    if (!b.exposed()) return a.defenses;
    return a.defenses.intersect(b.defenses);
}

/// The flow of a value that an operation builds from `a` and `b` together.
fn combineFlows(a: Flow, b: Flow) Flow {
    const flow: Flow = .{
        .labels = LabelSet.mergeValues(a.labels, b.labels),
        .defenses = combineDefenses(a, b),
    };
    return flow.canonical();
}

/// What an operation does to the defenses of the flow that it builds its
/// result from (`OperationRow.defense`).
pub const DefenseEdge = enum {
    /// The result keeps the defenses of the flow.
    keep,
    /// The result loses `html_escaped` and keeps `schema_checked`.
    drop_html,
    /// The result loses both defenses.
    drop_all,

    fn apply(edge: DefenseEdge, flow: Flow) Flow {
        var out = flow;
        switch (edge) {
            .keep => {},
            .drop_html => out.defenses.html_escaped = false,
            .drop_all => out.defenses = .{},
        }
        return out;
    }
};

/// What an expression can be. Bottom is the absence of a value (`?Value` is
/// null), never an empty value: an empty `Value` is a reachable primitive that
/// carries nothing, and conflating the two is how a join drops a branch.
///
/// A value is immutable once built. A join builds new storage, so a state copy
/// can share values safely.
pub const Value = struct {
    labels: LabelSet = .empty,
    /// Canonical: empty unless the labels hold `user_input` or `unknown`.
    defenses: Defenses = .{},
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

    /// A primitive with this flow, made canonical.
    pub fn flowing(of: Flow) Value {
        const canonical = of.canonical();
        return .{ .labels = canonical.labels, .defenses = canonical.defenses };
    }

    pub fn flow(self: Value) Flow {
        return .{ .labels = self.labels, .defenses = self.defenses };
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

/// The join of two reachable values. Labels use `mergeConditional`, and the
/// defenses combine as data (`combineDefenses`), so a defense survives a join
/// only when every exposed path holds it. The other parts are set unions with
/// the `top` flags ORed.
fn joinValue(arena: std.mem.Allocator, a: Value, b: Value) Error!Value {
    const flow: Flow = (Flow{
        .labels = LabelSet.mergeConditional(a.labels, b.labels),
        .defenses = combineDefenses(a.flow(), b.flow()),
    }).canonical();
    return .{
        .labels = flow.labels,
        .defenses = flow.defenses,
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

/// The flow of `source` joins a value copied out of it as data, and the
/// copied value keeps its own origins and callables because a copy of a
/// reference still names the same object.
fn withFlow(v: Value, source: Flow) Value {
    var out = v;
    const flow = combineFlows(v.flow(), source);
    out.labels = flow.labels;
    out.defenses = flow.defenses;
    return out;
}

/// `v` with no defense. An export that may transform or choose among the
/// values it hands back returns them this way.
fn withoutDefenses(v: Value) Value {
    var out = v;
    out.defenses = .{};
    return out;
}

/// The union of two values that an operation reads together: the flows
/// combine as data, the origins and callables are unions, and the `top` flags
/// are ORed.
fn unionValue(arena: std.mem.Allocator, a: Value, b: Value) Error!Value {
    var out = try withNative(arena, a, b);
    const flow = combineFlows(a.flow(), b.flow());
    out.labels = flow.labels;
    out.defenses = flow.defenses;
    return out;
}

/// `v` with the origins, callables, and flags of `native` added. The flow of
/// `v` stays as it is: a native function value carries none, and a join of
/// labels would drop a fact of `v`.
fn withNative(arena: std.mem.Allocator, v: Value, native: Value) Error!Value {
    return .{
        .labels = v.labels,
        .defenses = v.defenses,
        .origins = try mergeSorted(SiteKey, arena, v.origins, native.origins, SiteKey.order),
        .origins_top = v.origins_top or native.origins_top,
        .callables = try mergeSorted(NodeIndex, arena, v.callables, native.callables, nodeOrder),
        .callables_top = v.callables_top or native.callables_top,
    };
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
/// other side stands for a reachable `undefined`, not for bottom. The defenses
/// of a value on one side only survive for the same reason: `joinValue`
/// treats the side that holds no value as one that is not exposed.
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

/// Two values are equal when every part is: all label bits, all defense bits,
/// both `top` flags, and the sorted, duplicate-free slices element by element.
/// The slices are canonical because every constructor and every join keeps
/// them sorted, and `analyzeFunction` canonicalizes the parameters it is given.
fn valueEql(a: Value, b: Value) bool {
    const a_bits: u16 = @bitCast(a.labels);
    const b_bits: u16 = @bitCast(b.labels);
    const a_defenses: u8 = @bitCast(a.defenses);
    const b_defenses: u8 = @bitCast(b.defenses);
    return a_bits == b_bits and
        a_defenses == b_defenses and
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

/// The state of a callee as its caller sees it: the heap and the cells of
/// unnamed writes. The maps are shared with `s`, so the result is read-only.
fn heapOnly(s: State) State {
    return .{ .reachable = s.reachable, .heap = s.heap, .top_cell = s.top_cell };
}

fn joinSummary(arena: std.mem.Allocator, a: Summary, b: Summary) Error!Summary {
    return .{
        .value = try joinOpt(arena, a.value, b.value),
        .state = try joinStates(arena, a.state, b.state),
    };
}

fn summaryEql(a: Summary, b: Summary) bool {
    return optValueEql(a.value, b.value) and stateEql(a.state, b.state);
}

/// Argument lists that are both fitted to one function have the same length.
fn joinArgs(arena: std.mem.Allocator, a: []const Value, b: []const Value) Error![]const Value {
    const out = try arena.alloc(Value, @max(a.len, b.len));
    for (out, 0..) |*slot, i| {
        const x = if (i < a.len) a[i] else Value.clean;
        const y = if (i < b.len) b[i] else Value.clean;
        slot.* = try joinValue(arena, x, y);
    }
    return out;
}

fn argsEql(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!valueEql(x, y)) return false;
    }
    return true;
}

/// A copy of `v` whose slices live in `arena`, sorted and without duplicates.
/// The caller of `analyzeFunction` may pass slices from its own stack in any
/// order, and equality assumes the canonical form.
fn canonicalValue(arena: std.mem.Allocator, v: Value) Error!Value {
    var out = v;
    out.defenses = v.flow().canonical().defenses;
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
pub const Phase = enum { p7, p8 };

/// How the evaluators treat one `NodeTag`. P9 requires that no tag is `later`.
pub const TagPlan = union(enum) {
    /// A rule exists and resolves the tag in every context the census uses.
    handled,
    /// The phase that adds the rule. Until then the tag is unresolved.
    later: Phase,
    /// The restricted profile refuses the construct, so no accepted program
    /// holds it.
    refused_by_parser,
    /// The parser accepts the construct and the strict checker refuses it, so
    /// no checked module holds it. The runtime does not evaluate it as the
    /// source reads, so the evaluator does not follow it either.
    refused_by_strict,
    /// The parser produces no such node, or produces it only where a parent
    /// rule reads it through an accessor, so it is never an evaluation target.
    not_produced,
};

/// Why a construct is unresolved: the phase that owns it, or the reason that
/// no phase does.
///
/// - `fixpoint_limit`: a loop reached `max_loop_passes`, or a recursive
///   function reached `max_recursion_passes`, before its summary stopped
///   changing.
/// - `read_before_declaration`: a local read ran before its declaration, so
///   the slot holds something this evaluator never saw.
/// - `unknown_callee`: a call whose callee may be a function this analysis
///   cannot name (a value read from a property, or a join with `top`).
/// - `capture_unplaced`: a closure read a captured binding and no capture
///   table was given, so the binding's cell is unknown.
/// - `capture_unseeded`: the analyzed function itself captures bindings that
///   no activation in this analysis created.
/// - `budget_limit`: the root analysis reached `max_steps`.
/// - `refused_by_strict`: the strict checker refuses the construct (call-site
///   spread, ZTS616, or a global the strict checker does not know).
/// - `no_operation_rule`: an operation that has no transfer rule: a method of
///   a native Result, a callback argument that holds no function, a call that
///   the runtime fails with `NotCallable`, or a native method of an object the
///   analysis does not model (R3).
pub const Owner = enum {
    p7,
    p8,
    fixpoint_limit,
    read_before_declaration,
    unknown_callee,
    capture_unplaced,
    capture_unseeded,
    budget_limit,
    refused_by_strict,
    no_operation_rule,
    refused_by_parser,
    not_produced,
};

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
        .refused_by_strict => .refused_by_strict,
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
        .array_pattern,
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
        .call,
        => .handled,

        // A spread inside an array or object literal is read by the literal's
        // rule. A call-site spread is the case this plan names.
        .spread => .refused_by_strict,

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
// Builtin operations (P5a)
// ---------------------------------------------------------------------------

/// How the evaluator transfers labels, origins, and writes through one builtin
/// operation. The names state what the operation does to the heap and to its
/// result; `applyRule` holds the transfer for each.
const Rule = enum {
    /// A string method that returns a primitive.
    string_scalar,
    /// `split`: a fresh array of pieces.
    string_split,
    /// `push` and `unshift`: write each argument into the receiver.
    array_push,
    /// `pop` and `shift`: an element of the receiver.
    array_pop,
    array_splice,
    /// `indexOf`, `includes`, and `join`: a primitive that reads the elements.
    array_scalar,
    /// `slice` and `toReversed`: a fresh array of the elements.
    array_copy,
    /// `toSorted`: a copy, and a comparator is a callback.
    array_to_sorted,
    /// `map`: a fresh array of the callback results.
    array_map,
    /// `filter`: a fresh array of the elements, labelled by the predicate.
    array_filter,
    /// `find`: an element, labelled by the predicate.
    array_find,
    /// `forEach`: the callback runs for its writes.
    array_for_each,
    /// `every`, `some`, and `findIndex`: a primitive that the predicate decides.
    array_test,
    /// `reduce`: the accumulator.
    array_reduce,
    /// `Array.from`: a fresh array of the elements, or of the mapped elements.
    array_from,
    /// `h`: a vnode that holds what it was given, components included.
    vnode,
    /// `renderToString`: runs no component, so it has a rule only for a vnode
    /// that holds none.
    render,
    array_concat,
    /// A primitive computed from the arguments alone.
    deep_scalar,
    /// A primitive that differs between runs (a clock or random read).
    nondeterministic,
    /// `JSON.parse` and the request readers: a container built from the
    /// arguments.
    parsed,
    object_keys,
    object_values,
    object_entries,
    array_of,
    /// A `Response` static: a container that holds native methods.
    response_static,
    range,
    /// `hole()`: the call never returns.
    hole,
    /// The operation has no rule, and the row says why.
    no_rule,
};

/// One builtin operation. `scope` is `global` for a global function, the
/// namespace name for a namespace member, and `String.prototype`,
/// `Array.prototype`, or `Result.prototype` for a method of a prototype.
const OperationRow = struct {
    scope: []const u8,
    name: []const u8,
    rule: Rule,
    /// What the operation does to the defenses of the flow that its rule
    /// builds the result from. There is no default: every row states it.
    defense: DefenseEdge,
    /// Why the operation has no rule. Set for `no_rule` rows only.
    reason: []const u8 = "",
};

const callback_reason = "takes a callback, and a Result method is not modeled";
const result_reason = "a Result method is not modeled";

fn rowsOf(
    comptime scope: []const u8,
    comptime rule: Rule,
    comptime defense: DefenseEdge,
    comptime reason: []const u8,
    comptime names: []const []const u8,
) [names.len]OperationRow {
    var rows: [names.len]OperationRow = undefined;
    for (names, 0..) |name, i| {
        rows[i] = .{ .scope = scope, .name = name, .rule = rule, .defense = defense, .reason = reason };
    }
    return rows;
}

/// The operation table. The census (C1) checks it against the registered
/// builtins in both directions, and checks that exactly twelve rows have an
/// edge other than `keep`. The edges that remove a defense, and why:
///
/// - `replace` and `replaceAll` can bring back markup or decode escaped text,
///   so they remove both defenses.
/// - `String.fromCharCode` makes a character from a number, so it removes
///   both.
/// - `JSON.stringify` adds a `"` next to the text, so it removes
///   `html_escaped`.
/// - `JSON.parse` and `JSON.tryParse` turn the text `\u003c` into `<` and
///   build a structure that no schema checked, so they remove both.
/// - `Object.keys` and `Object.entries` return property names, and no export
///   escapes one, so they remove `html_escaped`.
/// - `renderToString` writes tag names, attribute names, and the children of
///   `script` unescaped, so it removes `html_escaped`.
/// - The request readers return fresh request data, so they remove both.
const operation_rows =
    rowsOf("String.prototype", .string_scalar, .keep, "", &.{
        "charAt",      "charCodeAt", "indexOf",   "lastIndexOf", "startsWith",
        "endsWith",    "includes",   "slice",     "substring",   "toLowerCase",
        "toUpperCase", "trim",       "trimStart", "trimEnd",     "repeat",
        "padStart",    "padEnd",     "concat",
    }) ++
    rowsOf("String.prototype", .string_scalar, .drop_all, "", &.{ "replace", "replaceAll" }) ++
    rowsOf("String.prototype", .string_split, .keep, "", &.{"split"}) ++
    rowsOf("Array.prototype", .array_push, .keep, "", &.{ "push", "unshift" }) ++
    rowsOf("Array.prototype", .array_pop, .keep, "", &.{ "pop", "shift" }) ++
    rowsOf("Array.prototype", .array_splice, .keep, "", &.{"splice"}) ++
    rowsOf("Array.prototype", .array_scalar, .keep, "", &.{ "indexOf", "includes", "join" }) ++
    rowsOf("Array.prototype", .array_copy, .keep, "", &.{ "slice", "toReversed" }) ++
    rowsOf("Array.prototype", .array_to_sorted, .keep, "", &.{"toSorted"}) ++
    rowsOf("Array.prototype", .array_concat, .keep, "", &.{"concat"}) ++
    rowsOf("Array.prototype", .array_map, .keep, "", &.{"map"}) ++
    rowsOf("Array.prototype", .array_filter, .keep, "", &.{"filter"}) ++
    rowsOf("Array.prototype", .array_find, .keep, "", &.{"find"}) ++
    rowsOf("Array.prototype", .array_for_each, .keep, "", &.{"forEach"}) ++
    rowsOf("Array.prototype", .array_test, .keep, "", &.{ "every", "some", "findIndex" }) ++
    rowsOf("Array.prototype", .array_reduce, .keep, "", &.{"reduce"}) ++
    rowsOf("Result.prototype", .no_rule, .keep, result_reason, &.{
        "isOk", "isErr", "unwrap", "unwrapOr", "unwrapErr",
    }) ++
    rowsOf("Result.prototype", .no_rule, .keep, callback_reason, &.{ "map", "mapErr", "andThen", "match" }) ++
    rowsOf("Math", .deep_scalar, .keep, "", &.{
        "abs", "floor", "ceil", "round", "min", "max", "pow", "trunc", "sqrt", "sin", "cos", "tan", "log", "exp",
    }) ++
    rowsOf("Math", .nondeterministic, .keep, "", &.{"random"}) ++
    rowsOf("JSON", .parsed, .drop_all, "", &.{ "parse", "tryParse" }) ++
    rowsOf("JSON", .deep_scalar, .drop_html, "", &.{"stringify"}) ++
    rowsOf("Object", .object_keys, .drop_html, "", &.{"keys"}) ++
    rowsOf("Object", .object_values, .keep, "", &.{"values"}) ++
    rowsOf("Object", .object_entries, .drop_html, "", &.{"entries"}) ++
    rowsOf("Object", .deep_scalar, .keep, "", &.{"hasOwn"}) ++
    rowsOf("Number", .deep_scalar, .keep, "", &.{ "isInteger", "isNaN", "isFinite", "parseFloat", "parseInt" }) ++
    rowsOf("Response", .response_static, .keep, "", &.{ "json", "text", "html", "redirect", "rawJson" }) ++
    rowsOf("Date", .nondeterministic, .keep, "", &.{"now"}) ++
    rowsOf("Array", .deep_scalar, .keep, "", &.{"isArray"}) ++
    rowsOf("Array", .array_of, .keep, "", &.{"of"}) ++
    rowsOf("Array", .array_from, .keep, "", &.{"from"}) ++
    rowsOf("String", .deep_scalar, .drop_all, "", &.{"fromCharCode"}) ++
    rowsOf("global", .deep_scalar, .keep, "", &.{ "String", "Number", "parseFloat", "parseInt", "isDict", "isBytes" }) ++
    rowsOf("global", .range, .keep, "", &.{"range"}) ++
    rowsOf("global", .parsed, .drop_all, "", &.{ "requestBody", "requestText", "requestJson" }) ++
    rowsOf("global", .hole, .keep, "", &.{"hole"}) ++
    rowsOf("global", .vnode, .keep, "", &.{"h"}) ++
    rowsOf("global", .render, .drop_html, "", &.{"renderToString"});

/// The builtin objects whose members are the `Math`-style namespace rows.
const namespace_names = [_][]const u8{ "Array", "Date", "JSON", "Math", "Number", "Object", "Response", "String" };

/// The namespaces that are also functions, so a read of the name may be called.
const callable_namespaces = [_][]const u8{ "Number", "Response", "String" };

fn nameIn(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn findRow(rows: []const OperationRow, scope: []const u8, name: []const u8) ?OperationRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.scope, scope) and std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

/// What a virtual-module export that calls a function passes to it. The
/// callback is argument 1 of every one of them.
const CallbackShape = enum {
    /// `(value, key)` for each entry of the dictionary in argument 0.
    dict_entries,
    /// `(acc, value, key)`, with the initial value in argument 2.
    dict_fold,
    /// The payload of the Result in argument 0.
    payload,
};

const CallbackExport = struct {
    specifier: []const u8,
    name: []const u8,
    shape: CallbackShape,
};

/// The exports with a precise callback rule. The binding cannot say that a
/// parameter is a callback, so any other export keeps the presumed call.
/// Census C2 checks each row against `findExport` and against a test.
const callback_exports = [_]CallbackExport{
    .{ .specifier = "zttp:collections", .name = "dictMapValues", .shape = .dict_entries },
    .{ .specifier = "zttp:collections", .name = "dictFilter", .shape = .dict_entries },
    .{ .specifier = "zttp:collections", .name = "dictFold", .shape = .dict_fold },
    .{ .specifier = "zttp:result", .name = "mapResult", .shape = .payload },
    .{ .specifier = "zttp:result", .name = "mapError", .shape = .payload },
    .{ .specifier = "zttp:result", .name = "andThen", .shape = .payload },
    .{ .specifier = "zttp:result", .name = "orElse", .shape = .payload },
};

fn findCallbackExport(rows: []const CallbackExport, specifier: []const u8, name: []const u8) ?CallbackExport {
    for (rows) |row| {
        if (std.mem.eql(u8, row.specifier, specifier) and std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Defense sources and sink requirements (P6b)
// ---------------------------------------------------------------------------

/// What an export that declares `validated` does to the defenses of its
/// result. The result of every other export has none, because the binding
/// cannot say that an export leaves the characters of its input alone.
///
/// The result has the defenses of everything the call reads, minus `removes`,
/// plus `establishes`. `keeps` states what the row passes through from its
/// input, and the census checks that it never overlaps `removes`. No source
/// removes a label: a validated request value keeps `user_input` (D23).
const DefenseSource = struct {
    specifier: []const u8,
    name: []const u8,
    establishes: Defenses = .{},
    keeps: Defenses = .{},
    removes: Defenses = .{},
    /// Why the row establishes nothing. Set for such rows only.
    reason: []const u8 = "",

    fn outcome(self: DefenseSource, input: Defenses) Defenses {
        return input.without(self.removes).unite(self.establishes);
    }
};

const html_only: Defenses = .{ .html_escaped = true };
const schema_only: Defenses = .{ .schema_checked = true };

/// One row for each export whose binding declares `validated`. A row that
/// establishes a defense needs a binding that declares only string
/// parameters: each of these exports answers an `err` Result or `undefined`
/// when an argument is not a string, so the origins of what the call reads
/// need no check. Census C3 checks the table against the bindings and against
/// an expected mapping.
const defense_sources = [_]DefenseSource{
    .{ .specifier = "zttp:text", .name = "escapeHtml", .establishes = html_only, .keeps = schema_only },
    .{ .specifier = "zttp:validate", .name = "validateJson", .establishes = schema_only, .removes = html_only },
    .{ .specifier = "zttp:validate", .name = "coerceJson", .establishes = schema_only, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeJson", .establishes = schema_only, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeForm", .establishes = schema_only, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeFormMultipart", .establishes = schema_only, .removes = html_only },
    .{
        .specifier = "zttp:validate",
        .name = "validateObject",
        .reason = "returns the object it was given, and defense evidence for an object is deferred (R13)",
    },
    .{
        .specifier = "zttp:decode",
        .name = "decodeQuery",
        .reason = "takes an object, and defense evidence for an object is deferred (R13)",
    },
    .{
        .specifier = "zttp:auth",
        .name = "jwtVerify",
        .reason = "authenticates the token and validates no claim",
    },
};

comptime {
    for (defense_sources) |row| {
        if (!row.keeps.intersect(row.removes).isEmpty()) {
            @compileError(row.name ++ " keeps and removes the same defense");
        }
    }
}

fn findDefenseSource(rows: []const DefenseSource, specifier: []const u8, name: []const u8) ?DefenseSource {
    for (rows) |row| {
        if (std.mem.eql(u8, row.specifier, specifier) and std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

/// A place where request data can arrive in a response, a log, or a call to
/// the network. P7 maps each call it finds to one of these.
pub const InputSink = enum {
    /// The body of `Response.html`.
    response_html,
    /// The body of another `Response` helper.
    response_other,
    /// The second argument of a helper (the status and headers).
    response_init,
    log,
    egress_url,
    egress_body,
    egress_headers,
    /// The options object that a call passes by name. It takes the strictest
    /// row of the three egress fields.
    egress_opaque,
};

/// A property that request data decides.
pub const InputProperty = enum { input_validated, injection_safe, pii_contained };

/// What a sink accepts for a property of request data (R12, D24).
pub const Requirement = union(enum) {
    /// The sink does not govern the property, so request data may arrive.
    not_governed,
    /// The sink accepts request data that holds this defense.
    defense: Defense,
    /// No defense is enough, so request data may not arrive.
    no_defense,
};

/// The requirement of each sink and property. The switch has no `else` arm, so
/// a new sink or property fails to compile until it has a row.
///
/// Two limits hold for every row. `html_escaped` covers HTML text and quoted
/// attribute values: a URL attribute such as `href="javascript:..."` and a
/// script context are outside it (D24). And it covers request characters, not
/// the author characters that request data selects through a slice bound, an
/// order, or a count (D25).
pub fn requirement(sink: InputSink, property: InputProperty) Requirement {
    return switch (sink) {
        .response_html => switch (property) {
            .input_validated => .not_governed,
            .injection_safe => .{ .defense = .html_escaped },
            .pii_contained => .not_governed,
        },
        .response_other, .response_init, .log => switch (property) {
            .input_validated => .not_governed,
            .injection_safe => .not_governed,
            .pii_contained => .not_governed,
        },
        .egress_url, .egress_headers, .egress_opaque => switch (property) {
            .input_validated => .{ .defense = .schema_checked },
            .injection_safe => .no_defense,
            .pii_contained => .no_defense,
        },
        .egress_body => switch (property) {
            .input_validated => .{ .defense = .schema_checked },
            .injection_safe => .{ .defense = .schema_checked },
            .pii_contained => .no_defense,
        },
    };
}

/// Whether request data that reaches `sink` is acceptable for `property`.
///
/// `reached` must be the `deepFlow` of the value that reaches the sink, in
/// the state at the sink. The value alone is not enough: a container with
/// clean surface labels can hold request data in its cells, and a validated
/// value keeps its own defense after an alias writes raw data into a cell.
///
/// A flow that is not exposed is always accepted. Request data is accepted
/// where the sink does not govern the property, or where the flow holds the
/// defense that the sink requires. It is never accepted where no defense is
/// enough.
///
/// The limits of `requirement` apply: HTML context (D24) and request
/// characters only (D25).
pub fn inputAccepted(reached: Flow, sink: InputSink, property: InputProperty) bool {
    if (!reached.exposed()) return true;
    return switch (requirement(sink, property)) {
        .not_governed => true,
        .defense => |defense| reached.defenses.has(defense),
        .no_defense => false,
    };
}

// ---------------------------------------------------------------------------
// The evaluator
// ---------------------------------------------------------------------------

/// A property key after evaluation: a name the analysis knows, a numeric
/// literal, or a value it does not know (the key's labels then travel with the
/// access). A numeric literal reads like a dynamic key but cannot name a
/// method, because no method name is numeric.
const Key = union(enum) {
    name: u16,
    index,
    dynamic: Value,
};

/// The states that leave the body of one `for...of` through `break` and
/// `continue`. Each is a clone, so no map is shared with a state that
/// execution mutates later.
const LoopFrame = struct {
    breaks: std.ArrayList(State) = .empty,
    continues: std.ArrayList(State) = .empty,
};

/// Where each upvalue of each function scope comes from, read from the
/// parser's scope analysis. The analyzer records for every upvalue the exact
/// declaring binding (`source_scope_id`, `source_slot`), so the table agrees
/// with the parser for a duplicate declaration in one scope and for an
/// unbraced conditional declaration, which a scan by name does not.
pub const CaptureTable = struct {
    allocator: std.mem.Allocator,
    /// `by_scope[function_scope][upvalue_slot]` is the packed key of the
    /// binding that upvalue names.
    by_scope: []const []const u32,
    /// Every source key. A binding in this set lives in a capture cell.
    captured: std.AutoHashMapUnmanaged(u32, void),

    pub fn init(allocator: std.mem.Allocator, scopes: *const ScopeAnalyzer) std.mem.Allocator.Error!CaptureTable {
        const by_scope = try allocator.alloc([]const u32, scopes.scopes.items.len);
        var built: usize = 0;
        errdefer {
            for (by_scope[0..built]) |keys| allocator.free(keys);
            allocator.free(by_scope);
        }
        var captured: std.AutoHashMapUnmanaged(u32, void) = .empty;
        errdefer captured.deinit(allocator);
        for (scopes.scopes.items, 0..) |scope, i| {
            const keys = try allocator.alloc(u32, scope.upvalues.items.len);
            by_scope[i] = keys;
            built += 1;
            for (scope.upvalues.items, keys) |upvalue, *key| {
                key.* = packBindingKey(upvalue.source_scope_id, upvalue.source_slot);
                try captured.put(allocator, key.*, {});
            }
        }
        return .{ .allocator = allocator, .by_scope = by_scope, .captured = captured };
    }

    pub fn deinit(self: *CaptureTable) void {
        for (self.by_scope) |keys| self.allocator.free(keys);
        self.allocator.free(self.by_scope);
        self.captured.deinit(self.allocator);
    }

    /// The source key of upvalue `slot` of `function_scope`, or null when the
    /// table does not know that upvalue.
    fn source(self: *const CaptureTable, function_scope: u16, slot: u16) ?u32 {
        if (function_scope >= self.by_scope.len) return null;
        const keys = self.by_scope[function_scope];
        if (slot >= keys.len) return null;
        return keys[slot];
    }

    /// The source keys of every upvalue of `function_scope`.
    fn upvalues(self: *const CaptureTable, function_scope: u16) []const u32 {
        if (function_scope >= self.by_scope.len) return &.{};
        return self.by_scope[function_scope];
    }
};

/// An imported virtual-module export: the module, the export, and the atom
/// that the module exports it under.
const ModuleExport = struct {
    binding: *const mb.ModuleBinding,
    func: *const mb.FunctionBinding,
    imported: u16,
};

/// What the module level binds. A global read may resolve to a function in
/// `functions`, or to an imported export in `exports`. A name in `bound` is
/// declared, imported, or assigned at the module level, so it replaces a
/// builtin global of the same name.
const ModuleNames = struct {
    functions: std.AutoHashMapUnmanaged(u16, NodeIndex),
    exports: std.AutoHashMapUnmanaged(u16, ModuleExport),
    bound: std.AutoHashMapUnmanaged(u16, void),
};

/// The result of one call, or of one pass over a function body: the join of
/// every normal completion's value (null when none is reachable) and the join
/// of their states. The state carries `heap` and `top_cell` only, because the
/// callee's bindings are out of scope for the caller.
const Summary = struct {
    value: ?Value,
    state: State,

    const bottom: Summary = .{ .value = null, .state = State.bottom };
};

/// One function body that is being analyzed for a call. `entry_*` is the
/// input of the current pass. `pending_*` joins that input with the input of
/// every recursive call made during the pass. `summary` is the result of the
/// last finished pass.
const Activation = struct {
    func: NodeIndex,
    entry_args: []const Value,
    entry: State,
    pending_args: []const Value,
    pending: State,
    summary: Summary,
    /// A recursive call read or fed this record during the current pass.
    used: bool,
};

pub const FlowInterp = struct {
    arena: std.heap.ArenaAllocator,
    ir_view: IrView,
    atoms: ?*atom_table.AtomTable,
    /// Where each upvalue comes from. Without it every upvalue read is
    /// unresolved (`capture_unplaced`) and no binding is placed in a cell.
    captures: ?*const CaptureTable = null,
    completions: std.ArrayList(Completion) = .empty,
    unresolved_list: std.ArrayList(Unresolved) = .empty,
    /// The enclosing loops, innermost last. A `break` or `continue` acts on the
    /// last one. The parser clears the loop flag at each function boundary, so
    /// neither crosses into a nested function. A call gives the callee an empty
    /// stack and restores this one afterwards.
    loop_frames: std.ArrayList(LoopFrame) = .empty,
    /// The function bodies being analyzed for a call, innermost last.
    activations: std.ArrayList(Activation) = .empty,
    /// The module-level names, by atom. Built on first use.
    module_names: ?ModuleNames = null,
    /// The pass cap of one loop. It is a fail-closed exit and not the
    /// termination argument: the loop head only grows over finite components.
    /// A value below 1 is treated as 1.
    max_loop_passes: u32 = 256,
    /// The pass cap of one recursive function, with the same meaning. A value
    /// below 1 is treated as 1.
    max_recursion_passes: u32 = 64,
    /// The cap on `eval` and `exec` visits for one root analysis, across every
    /// call and pass. It is fail-closed: reaching it clears the result.
    max_steps: u32 = default_max_steps,
    /// The visits counted so far in the current root analysis.
    steps: u32 = 0,
    /// The most passes any recursive function needed in the last analysis.
    recursion_passes_peak: u32 = 0,
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
    ///
    /// The step budget, the activation stack, and the loop stack belong to one
    /// root, so each call starts them afresh. A root that reaches `max_steps`
    /// returns a cleared result with no completion kept as normal.
    pub fn analyzeFunction(self: *FlowInterp, func: NodeIndex, params: []const Value) std.mem.Allocator.Error!FunctionResult {
        if (self.analyzeRoot(func, params)) |result| {
            return result;
        } else |err| switch (err) {
            error.BudgetExhausted => return self.budgetResult(),
            error.OutOfMemory => return error.OutOfMemory,
        }
    }

    /// The result of a root that reached `max_steps`: cleared, with the
    /// unresolved entries recorded so far, and no value or state to trust.
    fn budgetResult(self: *FlowInterp) std.mem.Allocator.Error!FunctionResult {
        const unresolved = try self.unresolved_list.toOwnedSlice(self.mem());
        self.completions = .empty;
        self.loop_frames = .empty;
        self.activations = .empty;
        return .{
            .returned = Value.top,
            .exit = .{},
            .completions = &.{},
            .cleared = true,
            .unresolved = unresolved,
        };
    }

    fn analyzeRoot(self: *FlowInterp, func: NodeIndex, params: []const Value) Error!FunctionResult {
        self.completions = .empty;
        self.unresolved_list = .empty;
        self.loop_frames = .empty;
        self.activations = .empty;
        self.steps = 0;
        self.recursion_passes_peak = 0;
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

        // The analyzed function is a root, not a closure created by an
        // activation in this analysis, so nothing placed the cells of the
        // bindings it captures. Each one may hold anything.
        if (self.captures) |table| {
            const sources = table.upvalues(function.scope_id);
            if (sources.len > 0) {
                try self.record(func, func_tag, .capture_unseeded);
                for (sources) |key| try self.weakWriteCapture(&st, key, Value.top);
            }
        }

        try self.bindParams(function, params, &st);
        try self.exec(function.body, &st);
        return self.finish(st);
    }

    /// Bind parameter `i` to `params[i]`, canonicalized, joined with the
    /// default value when the IR has one. A missing argument is `clean`.
    fn bindParams(self: *FlowInterp, function: ir.Node.FunctionExpr, params: []const Value, st: *State) Error!void {
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
                        const fallback = try self.eval(elem.default_value, st);
                        value = try joinValue(self.mem(), value, fallback);
                    }
                }
            }
            try self.storeLocal(st, packBindingKey(binding.scope_id, binding.slot), value);
        }
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

    /// Count one `eval` or `exec` visit against the budget. Exhaustion is
    /// recorded here and unwinds to `analyzeFunction`.
    fn tick(self: *FlowInterp, node: NodeIndex, tag: NodeTag) Error!void {
        self.steps +|= 1;
        if (self.steps > self.max_steps) {
            try self.record(node, tag, .budget_limit);
            return error.BudgetExhausted;
        }
    }

    // --- bindings and capture cells (P4) ---

    fn isCaptured(self: *const FlowInterp, key: u32) bool {
        const table = self.captures orelse return false;
        return table.captured.contains(key);
    }

    fn captureSite(key: u32) SiteKey {
        return .{ .kind = .capture, .node = key, .context = 0 };
    }

    /// The content of a capture cell. A cell nothing wrote stands for the
    /// runtime's `undefined`, which is `clean`: a closure is created after the
    /// declaration it reads, in the activation that declared it.
    fn captureValue(st: *const State, key: u32) Value {
        const cells = st.heap.get(captureSite(key)) orelse return Value.clean;
        return cells.summary orelse Value.clean;
    }

    /// Every write to a captured binding is weak. One cell stands for every
    /// activation of the declaring function and every loop iteration, so a
    /// strong write by one of them would hide what another stored.
    fn weakWriteCapture(self: *FlowInterp, st: *State, key: u32, v: Value) Error!void {
        try self.weakWriteSite(st, captureSite(key), null, v);
    }

    /// Store `v` in the binding `key` of the running function: a weak write to
    /// its capture cell when a closure captures it, else a strong update of
    /// `env`.
    fn storeLocal(self: *FlowInterp, st: *State, key: u32, v: Value) Error!void {
        if (self.isCaptured(key)) {
            try self.weakWriteCapture(st, key, v);
        } else {
            try st.env.put(self.mem(), key, v);
        }
    }

    /// The value of the binding `key`, or null when it is a function-local
    /// binding that no declaration has run for.
    fn loadLocal(self: *const FlowInterp, st: *const State, key: u32) ?Value {
        if (self.isCaptured(key)) return captureValue(st, key);
        return st.env.get(key);
    }

    /// The source key of an upvalue reference, or null when no capture table
    /// places it.
    fn upvalueKey(self: *const FlowInterp, binding: ir.BindingRef) ?u32 {
        const table = self.captures orelse return null;
        return table.source(binding.scope_id, binding.slot);
    }

    // --- module-level functions (P4) ---

    /// The function a module-level name resolves to, or null. A name resolves
    /// when exactly one declaration in the program binds it, that declaration
    /// is a function declaration or a `const` arrow function at the top level
    /// (so module initialization runs it before any request), and no
    /// assignment targets the name. Anything else stays module state (P8).
    fn moduleFunction(self: *FlowInterp, atom: u16) Error!?NodeIndex {
        const names = try self.moduleNames();
        return names.functions.get(atom);
    }

    /// Whether the module level declares, imports, or assigns `atom`. Such a
    /// name replaces a builtin global of the same name at runtime.
    fn moduleBinds(self: *FlowInterp, atom: u16) Error!bool {
        const names = try self.moduleNames();
        return names.bound.contains(atom);
    }

    /// The virtual-module export that a module-level name resolves to, or
    /// null. A name resolves when exactly one declaration binds it, that
    /// declaration is an import specifier from a `zttp:` path whose module
    /// exports the imported name, and no assignment targets the name. An
    /// import from a user module, or of a name with no export, stays module
    /// state (P8).
    fn moduleExport(self: *FlowInterp, atom: u16) Error!?ModuleExport {
        const names = try self.moduleNames();
        return names.exports.get(atom);
    }

    fn moduleNames(self: *FlowInterp) Error!ModuleNames {
        if (self.module_names) |names| return names;
        const built = try self.buildModuleNames();
        self.module_names = built;
        return built;
    }

    const Declared = struct { count: u32, decl: NodeIndex };

    fn countDeclaration(
        self: *FlowInterp,
        declared: *std.AutoHashMapUnmanaged(u16, Declared),
        atom: u16,
        decl: NodeIndex,
    ) Error!void {
        const slot = try declared.getOrPut(self.mem(), atom);
        if (slot.found_existing) {
            slot.value_ptr.count += 1;
        } else {
            slot.value_ptr.* = .{ .count = 1, .decl = decl };
        }
    }

    fn buildModuleNames(self: *FlowInterp) Error!ModuleNames {
        const arena = self.mem();
        const view = self.ir_view;
        var declared: std.AutoHashMapUnmanaged(u16, Declared) = .empty;
        var assigned: std.AutoHashMapUnmanaged(u16, void) = .empty;
        var direct: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        const Imported = struct { module: []const u8, atom: u16 };
        var imported: std.AutoHashMapUnmanaged(u16, Imported) = .empty;

        var i: usize = 0;
        while (i < view.nodeCount()) : (i += 1) {
            const idx: NodeIndex = @intCast(i);
            const tag = view.getTag(idx) orelse continue;
            switch (tag) {
                .var_decl, .function_decl => {
                    const vd = view.getVarDecl(idx) orelse continue;
                    if (vd.binding.kind == .global) try self.countDeclaration(&declared, vd.binding.name_atom, idx);
                },
                // A named specifier maps its local name to the module path and
                // the exported name. The declaration count below decides
                // whether the local name still resolves to that export.
                .import_decl => {
                    const decl = view.getImportDecl(idx) orelse continue;
                    const module = view.getString(decl.module_idx) orelse continue;
                    var k: u8 = 0;
                    while (k < decl.specifiers_count) : (k += 1) {
                        const spec_idx = view.getListIndex(decl.specifiers_start, k);
                        const spec = view.getImportSpec(spec_idx) orelse continue;
                        if (spec.kind != .named or spec.local_binding.kind != .global) continue;
                        try imported.put(arena, spec.local_binding.name_atom, .{ .module = module, .atom = spec.imported_atom });
                    }
                },
                // An import or a pattern binding that binds a module name
                // counts as a declaration and is never a function.
                .import_specifier, .import_default, .import_namespace => {
                    const spec = view.getImportSpec(idx) orelse continue;
                    if (spec.local_binding.kind == .global) {
                        try self.countDeclaration(&declared, spec.local_binding.name_atom, null_node);
                    }
                },
                .pattern_element => {
                    const elem = view.getPatternElem(idx) orelse continue;
                    if (elem.binding.kind == .global) {
                        try self.countDeclaration(&declared, elem.binding.name_atom, null_node);
                    }
                },
                .assignment => {
                    const asg = view.getAssignment(idx) orelse continue;
                    if ((view.getTag(asg.target) orelse continue) != .identifier) continue;
                    const binding = view.getBinding(asg.target) orelse continue;
                    if (binding.kind == .global or binding.kind == .undeclared_global) {
                        try assigned.put(arena, binding.name_atom, {});
                    }
                },
                .program => {
                    const block = view.getBlock(idx) orelse continue;
                    var k: u16 = 0;
                    while (k < block.stmts_count) : (k += 1) {
                        const stmt = view.getListIndex(block.stmts_start, k);
                        try direct.put(arena, stmt, {});
                        if ((view.getTag(stmt) orelse continue) != .export_decl) continue;
                        const export_decl = view.getExportDecl(stmt) orelse continue;
                        if (export_decl.declaration != null_node) try direct.put(arena, export_decl.declaration, {});
                    }
                },
                // exhaustive: every other tag neither declares a module name
                // nor assigns one, and holds no program body.
                else => {},
            }
        }

        var resolved: std.AutoHashMapUnmanaged(u16, NodeIndex) = .empty;
        var it = declared.iterator();
        while (it.next()) |entry| {
            const atom = entry.key_ptr.*;
            const found = entry.value_ptr.*;
            if (found.count != 1 or found.decl == null_node) continue;
            if (assigned.contains(atom) or !direct.contains(found.decl)) continue;
            const vd = view.getVarDecl(found.decl) orelse continue;
            const init_tag = view.getTag(vd.init) orelse continue;
            const is_function = switch ((view.getTag(found.decl) orelse continue)) {
                .function_decl => init_tag == .function_expr or init_tag == .arrow_function,
                .var_decl => vd.kind == .@"const" and init_tag == .arrow_function,
                // exhaustive: only a function declaration and a `const` arrow
                // are counted as declarations above, so no other tag arrives.
                else => false,
            };
            if (is_function) try resolved.put(arena, atom, vd.init);
        }

        var exports: std.AutoHashMapUnmanaged(u16, ModuleExport) = .empty;
        var import_it = imported.iterator();
        while (import_it.next()) |entry| {
            const atom = entry.key_ptr.*;
            const found = declared.get(atom) orelse continue;
            if (found.count != 1 or assigned.contains(atom)) continue;
            const name = self.nameOfAtom(entry.value_ptr.atom) orelse continue;
            const resolved_export = engine.builtin_modules.findExport(entry.value_ptr.module, name) orelse continue;
            try exports.put(arena, atom, .{
                .binding = resolved_export.binding,
                .func = resolved_export.func,
                .imported = entry.value_ptr.atom,
            });
        }

        var bound: std.AutoHashMapUnmanaged(u16, void) = .empty;
        var declared_it = declared.keyIterator();
        while (declared_it.next()) |atom| try bound.put(arena, atom.*, {});
        var assigned_it = assigned.keyIterator();
        while (assigned_it.next()) |atom| try bound.put(arena, atom.*, {});
        return .{ .functions = resolved, .exports = exports, .bound = bound };
    }

    // --- calls (P4) ---

    /// `args` as the exact list of a callee's parameters: surplus arguments are
    /// dropped (the callee cannot read them) and missing ones are `clean`.
    fn fitArgs(self: *FlowInterp, function: ir.Node.FunctionExpr, args: []const Value) Error![]const Value {
        const fitted = try self.mem().alloc(Value, function.params_count);
        for (fitted, 0..) |*slot, i| slot.* = if (i < args.len) args[i] else Value.clean;
        return fitted;
    }

    /// The state a callee starts from and a summary carries: the heap and the
    /// cells of unnamed writes, and no bindings. The heap is copied, because
    /// the caller goes on mutating its own maps.
    fn heapState(self: *FlowInterp, st: *const State) Error!State {
        return .{ .heap = try st.heap.clone(self.mem()), .top_cell = st.top_cell };
    }

    /// The argument values of a call, in source order, and whether one of them
    /// is a call-site spread.
    const CallArgs = struct { values: []const Value, has_spread: bool };

    fn evalArgs(self: *FlowInterp, c: ir.Node.CallExpr, st: *State) Error!CallArgs {
        const arena = self.mem();
        var args: std.ArrayList(Value) = .empty;
        var has_spread = false;
        var i: u16 = 0;
        while (i < c.args_count) : (i += 1) {
            const arg = self.ir_view.getListIndex(c.args_start, i);
            if ((self.ir_view.getTag(arg) orelse .stmt_list) == .spread) {
                // The runtime does not evaluate the operand (it pushes
                // `undefined`) and the strict checker refuses the call.
                self.noteVisited(.spread);
                try self.record(arg, .spread, .refused_by_strict);
                has_spread = true;
                continue;
            }
            try args.append(arena, try self.eval(arg, st));
        }
        return .{ .values = args.items, .has_spread = has_spread };
    }

    fn evalCall(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const c = self.ir_view.getCall(node) orelse return self.missing(node);
        const callee_tag = self.ir_view.getTag(c.callee) orelse .stmt_list;

        // The runtime dispatches a call through a property to a builtin method
        // of a string, an array, or another builtin value, and a value cannot
        // exclude a primitive alternative after a join.
        if (callee_tag == .member_access or callee_tag == .optional_chain or callee_tag == .computed_access) {
            return self.evalPropertyCall(node, c, callee_tag, st);
        }

        // A call of an imported export is evaluated before its callee, which
        // is a native function that no body stands behind.
        if (try self.exportCallee(c.callee)) |resolved| return self.evalExportCall(node, c, resolved, st);

        // A call of a builtin global function uses its row and never reads
        // the callee.
        if (try self.globalFunction(c.callee)) |global| {
            const args = try self.evalArgs(c, st);
            if (args.has_spread) return Value.top;
            return self.applyRule(st, node, global.row, try self.nativeFunction(global.atom), args.values);
        }

        const callee = try self.eval(c.callee, st);
        const args = try self.evalArgs(c, st);
        if (args.has_spread) return Value.top;

        if (callee.callables_top) {
            try self.record(node, .call, .unknown_callee);
            return Value.top;
        }
        // The runtime fails with `NotCallable`.
        if (callee.callables.len == 0) {
            try self.record(node, .call, .no_operation_rule);
            return Value.top;
        }

        // Which callee runs is control flow, so every one of them does and the
        // results join. A result chosen through a labelled callee carries its
        // labels, as a read through a labelled key does.
        const joined = try self.runCallables(callee.callables, args.values, st);
        return self.takeSummary(st, joined, callee.flow());
    }

    /// Run every function of `callables` from `st` and join the summaries.
    fn runCallables(self: *FlowInterp, callables: []const NodeIndex, args: []const Value, st: *const State) Error!Summary {
        var joined = Summary.bottom;
        for (callables) |func_node| {
            joined = try joinSummary(self.mem(), joined, try self.invoke(func_node, args, st));
        }
        return joined;
    }

    /// Continue the caller from the joined summary of a call: its heap, and its
    /// value with `flow` added as data. A summary with no reachable completion
    /// leaves the caller unreachable.
    fn takeSummary(self: *FlowInterp, st: *State, joined: Summary, flow: Flow) Error!Value {
        if (!joined.state.reachable) {
            // No completion is reachable. The bindings stay readable for the
            // dead code that follows in the same expression.
            st.reachable = false;
            return Value.clean;
        }
        st.heap = try joined.state.heap.clone(self.mem());
        st.top_cell = joined.state.top_cell;
        return withFlow(joined.value orelse Value.clean, flow);
    }

    // --- builtin globals and operations (P5a) ---

    /// The name behind an atom: a predefined one, or one the table interned.
    fn nameOfAtom(self: *const FlowInterp, atom: u16) ?[]const u8 {
        const named: object.Atom = @enumFromInt(atom);
        if (named.toPredefinedName()) |name| return name;
        const table = self.atoms orelse return null;
        return table.getName(named);
    }

    fn builtinSite(atom: u16) SiteKey {
        return .{ .kind = .builtin, .node = atom, .context = 0 };
    }

    /// The native function value of a static name: it has a location, and it
    /// may be called.
    fn nativeFunction(self: *FlowInterp, atom: u16) Error!Value {
        return .{
            .origins = try self.mem().dupe(SiteKey, &.{builtinSite(atom)}),
            .callables_top = true,
        };
    }

    /// The native value of an access whose name is not known: any shared
    /// runtime object, and any function.
    fn anyNative(self: *FlowInterp) Error!Value {
        return .{
            .origins = try self.mem().dupe(SiteKey, &.{builtinSite(any_builtin)}),
            .origins_top = true,
            .callables_top = true,
        };
    }

    /// A value may be an array when it points at an array literal or at an
    /// array that a builtin made, or at anything.
    fn mayBeArray(self: *const FlowInterp, v: Value) bool {
        if (v.origins_top) return true;
        for (v.origins) |site| {
            switch (site.kind) {
                .allocated_array, .allocated_any => return true,
                .literal => {
                    if ((self.ir_view.getTag(site.node) orelse continue) == .array_literal) return true;
                },
                .function, .request, .headers, .capture, .native, .builtin => {},
            }
        }
        return false;
    }

    /// A native Result comes from a builtin that returns an `allocated_any`
    /// container. An array that a builtin returns is not one.
    fn mayBeResult(v: Value) bool {
        if (v.origins_top) return true;
        for (v.origins) |site| {
            if (site.kind == .allocated_any) return true;
        }
        return false;
    }

    /// A value may hold native methods when it points at a shared runtime
    /// object, a native container, or the request or its headers.
    fn mayHoldNative(v: Value) bool {
        if (v.origins_top) return true;
        for (v.origins) |site| {
            switch (site.kind) {
                .builtin, .native, .request, .headers => return true,
                .literal, .function, .capture, .allocated_array, .allocated_any => {},
            }
        }
        return false;
    }

    /// Whether the value points at a `builtin` or `native` site, whose
    /// properties are the methods of a native object.
    fn hasNativeSite(v: Value) bool {
        for (v.origins) |site| {
            if (site.kind == .builtin or site.kind == .native) return true;
        }
        return false;
    }

    fn hasBuiltinSite(v: Value) bool {
        for (v.origins) |site| {
            if (site.kind == .builtin) return true;
        }
        return false;
    }

    /// The native value that a read of `key` through `o` adds to the cells it
    /// sees, or null. A name adds its own native function when it names a
    /// method the receiver may have. A key that is not a literal may name any
    /// method. A numeric literal names none, but still reads the properties of
    /// a native site.
    fn implicitNative(self: *FlowInterp, o: Value, key: Key) Error!?Value {
        switch (key) {
            .name => |atom| {
                // A name this table cannot spell may be any method.
                const text = self.nameOfAtom(atom) orelse return try self.anyNative();
                const method = findRow(&operation_rows, "String.prototype", text) != null or
                    (findRow(&operation_rows, "Array.prototype", text) != null and self.mayBeArray(o)) or
                    (findRow(&operation_rows, "Result.prototype", text) != null and mayBeResult(o)) or
                    mayHoldNative(o);
                if (!method) return null;
                return try self.nativeFunction(atom);
            },
            .dynamic => return try self.anyNative(),
            .index => {
                if (hasNativeSite(o)) return try self.anyNative();
                return null;
            },
        }
    }

    /// A scan reads elements, and the properties of a native site as well.
    fn scanNative(self: *FlowInterp, v: Value, o: Value) Error!Value {
        if (!hasNativeSite(o)) return v;
        return withNative(self.mem(), v, try self.anyNative());
    }

    /// The row of a builtin global function that an identifier names, or null.
    /// A name that the module level declares or assigns is the user's.
    fn globalFunction(self: *FlowInterp, callee: NodeIndex) Error!?struct { row: OperationRow, atom: u16 } {
        if ((self.ir_view.getTag(callee) orelse return null) != .identifier) return null;
        const binding = self.ir_view.getBinding(callee) orelse return null;
        if (binding.kind != .undeclared_global) return null;
        if (try self.moduleBinds(binding.name_atom)) return null;
        const name = self.nameOfAtom(binding.name_atom) orelse return null;
        const row = findRow(&operation_rows, "global", name) orelse return null;
        return .{ .row = row, .atom = binding.name_atom };
    }

    /// The value of an undeclared global that no module declaration replaces.
    fn builtinGlobal(self: *FlowInterp, node: NodeIndex, atom: u16) Error!Value {
        const name = self.nameOfAtom(atom) orelse {
            try self.record(node, .identifier, .refused_by_strict);
            return Value.top;
        };
        if (nameIn(&namespace_names, name)) {
            var namespace = Value{ .origins = try self.mem().dupe(SiteKey, &.{builtinSite(atom)}) };
            namespace.callables_top = nameIn(&callable_namespaces, name);
            return namespace;
        }
        if (findRow(&operation_rows, "global", name) != null) return self.nativeFunction(atom);
        // The strict checker accepts the other known globals, and no rule
        // models them. Any other name it refuses.
        const known = nameIn(&known_globals.names, name);
        try self.record(node, .identifier, if (known) .no_operation_rule else .refused_by_strict);
        return Value.top;
    }

    /// The condition of `tryEmitMathBuiltin` in `parser/codegen.zig`: these
    /// calls compile to an opcode, and the code generator does not read the
    /// receiver, so a user `Math` never runs.
    fn isMathOpcode(self: *const FlowInterp, callee_tag: NodeTag, m: ir.Node.MemberExpr, args_count: u8) bool {
        if (callee_tag != .member_access and callee_tag != .optional_chain) return false;
        if ((self.ir_view.getTag(m.object) orelse return false) != .identifier) return false;
        const binding = self.ir_view.getBinding(m.object) orelse return false;
        if (binding.kind != .global and binding.kind != .undeclared_global) return false;
        if (binding.name_atom != @intFromEnum(object.Atom.Math)) return false;
        if (args_count == 1) {
            return m.property == @intFromEnum(object.Atom.floor) or
                m.property == @intFromEnum(object.Atom.ceil) or
                m.property == @intFromEnum(object.Atom.round) or
                m.property == @intFromEnum(object.Atom.abs);
        }
        if (args_count == 2) {
            return m.property == @intFromEnum(object.Atom.min) or m.property == @intFromEnum(object.Atom.max);
        }
        return false;
    }

    /// A call through a property: `r.name(args)`, `r?.name(args)`, or
    /// `r["name"](args)`. An optional call skips the read, the arguments, and
    /// the call when the receiver is nullish, so the state after the receiver
    /// joins the state after the call.
    fn evalPropertyCall(self: *FlowInterp, node: NodeIndex, c: ir.Node.CallExpr, callee_tag: NodeTag, st: *State) Error!Value {
        const arena = self.mem();
        const m = self.ir_view.getMember(c.callee) orelse return self.missing(node);
        self.noteVisited(callee_tag);

        if (self.isMathOpcode(callee_tag, m, c.args_count)) {
            const args = try self.evalArgs(c, st);
            if (args.has_spread) return Value.top;
            return Value.flowing(try self.deepFlow(st, args.values));
        }

        const receiver = try self.eval(m.object, st);
        const key: Key = if (callee_tag == .computed_access)
            try self.evalKey(m.computed, st)
        else
            .{ .name = m.property };
        const skipped: ?State = if (callee_tag == .optional_chain) try cloneState(arena, st.*) else null;

        const value = try self.dispatchPropertyCall(node, c, receiver, key, st);
        if (skipped) |skip| {
            st.* = try joinStates(arena, skip, st.*);
            return joinValue(arena, value, Value.clean);
        }
        return value;
    }

    /// The candidates of a call `r.name(args)`: the user functions stored
    /// under the name, then each builtin operation the receiver may reach
    /// under it. Every candidate runs from the state after the arguments, and
    /// the results and states join.
    fn dispatchPropertyCall(self: *FlowInterp, node: NodeIndex, c: ir.Node.CallExpr, r: Value, key: Key, st: *State) Error!Value {
        const arena = self.mem();
        const args = try self.evalArgs(c, st);
        if (args.has_spread) return Value.top;

        // A computed key that is a string literal is a static name, and the
        // runtime reads the same property. Any other key may name a method.
        const atom = switch (key) {
            .name => |name| name,
            .index, .dynamic => {
                try self.record(node, .call, .unknown_callee);
                return Value.top;
            },
        };
        const text = self.nameOfAtom(atom) orelse {
            try self.record(node, .call, .unknown_callee);
            return Value.top;
        };
        if (r.origins_top) {
            try self.record(node, .call, .unknown_callee);
            return Value.top;
        }

        const user = try self.storedRead(st, r, key);
        if (user.callables_top) {
            try self.record(node, .call, .unknown_callee);
            return Value.top;
        }

        var joined = Summary.bottom;
        var candidates: usize = 0;
        if (user.callables.len > 0) {
            joined = try self.runCallables(user.callables, args.values, st);
            candidates += 1;
        }
        if (findRow(&operation_rows, "String.prototype", text)) |row| {
            joined = try joinSummary(arena, joined, try self.candidate(node, st, row, r, args.values));
            candidates += 1;
        }
        if (self.mayBeArray(r)) {
            if (findRow(&operation_rows, "Array.prototype", text)) |row| {
                joined = try joinSummary(arena, joined, try self.candidate(node, st, row, r, args.values));
                candidates += 1;
            }
        }
        if (mayBeResult(r)) {
            if (findRow(&operation_rows, "Result.prototype", text)) |row| {
                joined = try joinSummary(arena, joined, try self.candidate(node, st, row, r, args.values));
                candidates += 1;
            }
        }
        for (r.origins) |site| {
            switch (site.kind) {
                .builtin => {
                    // Only a namespace has member rows. Any other shared
                    // object has no rule.
                    const scope = self.nameOfAtom(@truncate(site.node)) orelse "";
                    const found = if (nameIn(&namespace_names, scope)) findRow(&operation_rows, scope, text) else null;
                    const row = found orelse OperationRow{ .scope = scope, .name = text, .rule = .no_rule, .defense = .keep, .reason = "no member row" };
                    joined = try joinSummary(arena, joined, try self.candidate(node, st, row, r, args.values));
                    candidates += 1;
                },
                .native => {
                    const row: OperationRow = .{ .scope = "native", .name = text, .rule = .no_rule, .defense = .keep, .reason = "a native method" };
                    joined = try joinSummary(arena, joined, try self.candidate(node, st, row, r, args.values));
                    candidates += 1;
                },
                // The contents of the request and its headers belong to P7.
                .request, .headers => {
                    try self.record(node, .call, .p7);
                    joined = try joinSummary(arena, joined, .{ .value = Value.top, .state = try self.heapState(st) });
                    candidates += 1;
                },
                .literal, .function, .capture, .allocated_array, .allocated_any => {},
            }
        }

        // The runtime fails with `NotCallable`.
        if (candidates == 0) {
            try self.record(node, .call, .no_operation_rule);
            return Value.top;
        }
        // The user candidate selects what runs only when it holds a function.
        // A value that holds none cannot be called: the runtime fails with
        // `NotCallable` and returns nothing, so its flow reaches no result.
        // A candidate that may be any function returned above.
        const selected: Flow = if (user.callables.len > 0 or user.callables_top) user.flow() else .{};
        return self.takeSummary(st, joined, selected);
    }

    /// Apply one builtin row to a copy of the heap and return its summary.
    fn candidate(self: *FlowInterp, node: NodeIndex, st: *const State, row: OperationRow, r: Value, args: []const Value) Error!Summary {
        var copy = try self.heapState(st);
        const value = try self.applyRule(&copy, node, row, r, args);
        return .{ .value = value, .state = heapOnly(copy) };
    }

    /// The flow of everything `vs` can reach.
    fn deepFlow(self: *FlowInterp, st: *const State, vs: []const Value) Error!Flow {
        return (try self.reach(st, vs)).flow();
    }

    /// The argument at `index`, or `clean` when the call passes none.
    fn argAt(args: []const Value, index: usize) Value {
        return if (index < args.len) args[index] else Value.clean;
    }

    /// A container that a builtin makes at the call `node`. The site holds
    /// `contents` and its own self value, so a nested container has a
    /// location and a write to it lands in the site. The result is the self
    /// value with `flow`.
    fn allocate(self: *FlowInterp, st: *State, kind: SiteKind, node: NodeIndex, contents: []const Value, flow: Flow) Error!Value {
        const site: SiteKey = .{ .kind = kind, .node = node, .context = 0 };
        const self_value = try self.siteValue(site, null);
        for (contents) |content| try self.weakWriteSite(st, site, null, content);
        try self.weakWriteSite(st, site, null, self_value);
        var out = self_value;
        const canonical = flow.canonical();
        out.labels = canonical.labels;
        out.defenses = canonical.defenses;
        return out;
    }

    /// The transfer of one builtin operation. `r` is the receiver, `args` the
    /// argument values, and `st` the state the operation runs in. `L` is the
    /// flow of the receiver and of everything the arguments reach, combined
    /// as data, with the defense edge of the row applied. `A` is the same flow
    /// of the arguments alone. A value that a rule moves as it is keeps its
    /// own flow.
    fn applyRule(self: *FlowInterp, st: *State, node: NodeIndex, row: OperationRow, r: Value, args: []const Value) Error!Value {
        const reached = try self.deepFlow(st, args);
        const arg_flow = row.defense.apply(reached);
        const flow = row.defense.apply(combineFlows(r.flow(), reached));
        switch (row.rule) {
            .string_scalar => return Value.flowing(flow),
            .string_split => return self.allocate(st, .allocated_array, node, &.{Value.flowing(flow)}, flow),
            .array_push => {
                try self.recordSharedWrite(node, r);
                for (args) |arg| try self.writeValue(st, r, .{ .dynamic = Value.clean }, arg);
                return Value.flowing(combineFlows(flow, try self.deepFlow(st, &.{r})));
            },
            .array_pop => return self.readAll(st.*, r),
            .array_splice => {
                const removed = try self.readAll(st.*, r);
                try self.recordSharedWrite(node, r);
                // The selectors decide which elements go, so their flow
                // reaches what stays, and the items from argument 2 are pushed.
                const selectors = combineFlows(argAt(args, 0).flow(), argAt(args, 1).flow());
                try self.writeValue(st, r, .{ .dynamic = Value.clean }, Value.flowing(selectors));
                if (args.len > 2) {
                    for (args[2..]) |item| try self.writeValue(st, r, .{ .dynamic = Value.clean }, item);
                }
                return self.allocate(st, .allocated_array, node, &.{removed}, flow);
            },
            .array_scalar => return Value.flowing(combineFlows(flow, try self.deepFlow(st, &.{r}))),
            .array_copy => return self.allocate(st, .allocated_array, node, &.{try self.readAll(st.*, r)}, flow),
            .array_to_sorted => {
                if (args.len == 0) return self.allocate(st, .allocated_array, node, &.{try self.readAll(st.*, r)}, flow);
                // The comparator may run many times per element, and it sees
                // two of them.
                const results = try self.runCallback(node, args[0], &.{ .{ .elements = r }, .{ .elements = r } }, st);
                const sorted = withFlow(try self.readAll(st.*, r), resultFlow(results));
                return self.allocate(st, .allocated_array, node, &.{sorted}, flow);
            },
            .array_map => {
                const results = try self.runCallback(node, argAt(args, 0), &.{ .{ .elements = r }, .{ .structure = r }, .{ .itself = r } }, st);
                return self.allocate(st, .allocated_array, node, &.{results orelse Value.clean}, flow);
            },
            .array_filter => {
                const results = try self.runCallback(node, argAt(args, 0), &.{ .{ .elements = r }, .{ .structure = r }, .{ .itself = r } }, st);
                // The predicate decides which elements stay, so its flow
                // reaches each one. The receiver is read after the loop, which
                // sees what the callback wrote.
                const kept = withFlow(try self.readAll(st.*, r), resultFlow(results));
                return self.allocate(st, .allocated_array, node, &.{kept}, flow);
            },
            .array_find => {
                const results = try self.runCallback(node, argAt(args, 0), &.{ .{ .elements = r }, .{ .structure = r }, .{ .itself = r } }, st);
                const kept = withFlow(try self.readAll(st.*, r), resultFlow(results));
                return withFlow(kept, flow);
            },
            .array_for_each => {
                _ = try self.runCallback(node, argAt(args, 0), &.{ .{ .elements = r }, .{ .structure = r }, .{ .itself = r } }, st);
                return Value.flowing(flow);
            },
            .array_test => {
                const results = try self.runCallback(node, argAt(args, 0), &.{ .{ .elements = r }, .{ .structure = r }, .{ .itself = r } }, st);
                const decided = combineFlows(try self.deepFlow(st, &.{r}), resultFlow(results));
                return Value.flowing(combineFlows(flow, decided));
            },
            .array_reduce => {
                const initial = if (args.len > 1) args[1] else try self.readAll(st.*, r);
                const results = try self.runCallback(
                    node,
                    argAt(args, 0),
                    &.{ .{ .acc = initial }, .{ .elements = r }, .{ .structure = r }, .{ .itself = r } },
                    st,
                );
                return withFlow((try joinOpt(self.mem(), initial, results)) orelse initial, flow);
            },
            .array_from => {
                const source: Param = .{ .elements_labelled = argAt(args, 0) };
                if (args.len < 2) return self.allocate(st, .allocated_array, node, &.{try self.paramValue(st, source, null)}, flow);
                const results = try self.runCallback(node, args[1], &.{ source, .{ .structure = argAt(args, 0) } }, st);
                return self.allocate(st, .allocated_array, node, &.{results orelse Value.clean}, flow);
            },
            .array_concat => {
                var contents: std.ArrayList(Value) = .empty;
                try contents.append(self.mem(), try self.readAll(st.*, r));
                for (args) |arg| {
                    try contents.append(self.mem(), arg);
                    try contents.append(self.mem(), try self.readAll(st.*, arg));
                }
                return self.allocate(st, .allocated_array, node, contents.items, flow);
            },
            .deep_scalar => return Value.flowing(arg_flow),
            .nondeterministic => return Value.labelled(.{ .nondeterministic = true }),
            .parsed, .range => return self.allocate(st, .allocated_any, node, &.{Value.flowing(arg_flow)}, arg_flow),
            .object_keys => return self.allocate(st, .allocated_array, node, &.{Value.flowing(arg_flow)}, flow),
            .object_values => return self.allocate(st, .allocated_array, node, &.{try self.readAll(st.*, argAt(args, 0))}, flow),
            .object_entries => return self.allocate(
                st,
                .allocated_array,
                node,
                &.{ try self.readAll(st.*, argAt(args, 0)), Value.flowing(arg_flow) },
                flow,
            ),
            .array_of => return self.allocate(st, .allocated_array, node, args, flow),
            .response_static => return self.allocate(st, .native, node, &.{try self.reach(st, args)}, arg_flow),
            .vnode => return self.allocate(st, .allocated_any, node, &.{try self.reach(st, args)}, arg_flow),
            .render => {
                // A component runs later and writes `props`, which this
                // analysis does not follow.
                const read = try self.reach(st, &.{argAt(args, 0)});
                if (read.callables_top or read.callables.len > 0) return self.noRule(node);
                return Value.flowing(row.defense.apply(read.flow()));
            },
            .hole => {
                // The call never returns, as a P4 call whose callee has no
                // completion. The bindings stay readable for the rest of the
                // expression.
                st.reachable = false;
                return Value.clean;
            },
            .no_rule => return self.noRule(node),
        }
    }

    /// An operation with no rule: unresolved, and anything.
    fn noRule(self: *FlowInterp, node: NodeIndex) Error!Value {
        try self.record(node, .call, .no_operation_rule);
        return Value.top;
    }

    /// A write into the receiver of an array method. A shared runtime object
    /// is shared by every request, so a write into one belongs to P8.
    fn recordSharedWrite(self: *FlowInterp, node: NodeIndex, r: Value) Error!void {
        if (hasBuiltinSite(r)) try self.record(node, .call, .p8);
    }

    // --- virtual-module exports (P5b) ---

    /// The export that a callee identifier names, or null. A local binding of
    /// the same name has its own binding kind and never reaches the lookup.
    fn exportCallee(self: *FlowInterp, callee: NodeIndex) Error!?ModuleExport {
        if ((self.ir_view.getTag(callee) orelse return null) != .identifier) return null;
        const binding = self.ir_view.getBinding(callee) orelse return null;
        if (binding.kind != .global) return null;
        return self.moduleExport(binding.name_atom);
    }

    /// Whether an export's result differs between runs of the same request:
    /// the module is stateful and the export reads, or its capabilities
    /// include a clock or a random source. `flow_checker.zig` applies the same
    /// test. An explicit empty capability list does not inherit the module's.
    fn readsVaryingSource(resolved: ModuleExport) bool {
        if (resolved.binding.stateful and resolved.func.effect == .read) return true;
        const caps = resolved.func.required_capabilities orelse resolved.binding.required_capabilities;
        for (caps) |cap| {
            if (cap == .clock or cap == .random) return true;
        }
        return false;
    }

    /// Whether `haystack` holds `needle`, ignoring ASCII case.
    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        var start: usize = 0;
        while (start + needle.len <= haystack.len) : (start += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
        }
        return false;
    }

    /// The labels an export declares for its result. `env` with a literal
    /// name keeps `secret` when the name looks like a credential and gives
    /// `config` otherwise, as `flow_checker.zig` refines it. A name that is
    /// not a literal keeps the declared labels. The `validated` bit is never
    /// kept: no value carries it, and the defense of the result comes from
    /// `defense_sources`.
    fn declaredLabels(self: *const FlowInterp, resolved: ModuleExport, c: ir.Node.CallExpr) LabelSet {
        const declared = resolved.func.return_labels.without(.{ .validated = true });
        if (!std.mem.eql(u8, resolved.func.name, "env") or c.args_count == 0) return declared;
        const arg = self.ir_view.getListIndex(c.args_start, 0);
        if ((self.ir_view.getTag(arg) orelse return declared) != .lit_string) return declared;
        const string_idx = self.ir_view.getStringIdx(arg) orelse return declared;
        const name = self.ir_view.getString(string_idx) orelse return declared;
        const sensitive = [_][]const u8{ "SECRET", "PASSWORD", "PASSWD", "KEY", "TOKEN", "PRIVATE", "CREDENTIAL", "AUTH" };
        for (sensitive) |pattern| {
            if (containsIgnoreCase(name, pattern)) return declared;
        }
        return .{ .config = true };
    }

    /// Whether an export's declassification holds at this call (D14): the
    /// bounding argument is a numeric literal, or is omitted so that the
    /// export's own default bounds it, and what the call reads holds no
    /// object and no function, which a declassified summary could not keep.
    fn declassifies(self: *const FlowInterp, resolved: ModuleExport, c: ir.Node.CallExpr, read: Value) bool {
        const bound = resolved.func.declassify_bound_arg orelse return false;
        if (read.origins.len > 0 or read.callables.len > 0 or read.origins_top or read.callables_top) return false;
        if (bound >= c.args_count) return true;
        const arg = self.ir_view.getListIndex(c.args_start, bound);
        const tag = self.ir_view.getTag(arg) orelse return false;
        return tag == .lit_int or tag == .lit_float;
    }

    /// A call of an imported export. The binding says what the result is
    /// labelled, and nothing more: it cannot say which argument is a callback
    /// or which one the result aliases. So the call reads everything the
    /// arguments reach (`R`), runs every function in `R` as a callback of
    /// unknown shape, and returns a container that may be, or hold, any of it.
    /// The seven exports in `callback_exports` run only their callback.
    ///
    /// The result has no defense, because the binding cannot say that an
    /// export leaves the characters of its input alone. The exports in
    /// `defense_sources` are the exception: a row that establishes a defense
    /// builds the result from the labels of the call and the defenses of `R`
    /// minus what the row removes, plus what it establishes. The result of
    /// such a row holds no origin, callable, or flag of `R`. The callback
    /// results lose their defenses in every case, because an export may
    /// transform them or choose among them. Nothing here removes a label.
    fn evalExportCall(self: *FlowInterp, node: NodeIndex, c: ir.Node.CallExpr, resolved: ModuleExport, st: *State) Error!Value {
        const arena = self.mem();
        const args = try self.evalArgs(c, st);
        if (args.has_spread) return Value.top;

        const read = try self.reach(st, args.values);
        // The labels an export declassifies leave what it read, not what it
        // declares, and they leave the summary too, so no later read of the
        // result restores them.
        const declassified = self.declassifies(resolved, c, read);
        const input = if (declassified) read.labels.without(resolved.func.declassifies) else read.labels;
        var labels = LabelSet.mergeValues(input, self.declaredLabels(resolved, c));
        if (readsVaryingSource(resolved)) labels.nondeterministic = true;
        // The defenses of the result come from the source table and nowhere
        // else. A source row builds the result from the labels of the call,
        // with no origin, callable, or flag.
        var held = if (declassified) Value.labelled(labels) else read;
        held.defenses = .{};
        if (findDefenseSource(&defense_sources, resolved.binding.specifier, resolved.func.name)) |source| {
            if (!source.establishes.isEmpty()) {
                held = Value.flowing(.{ .labels = labels, .defenses = source.outcome(read.defenses) });
            }
        }

        // An export with a precise row calls the function in its argument 1.
        // Any other export may call each function the arguments reach, and a
        // function that the analysis cannot name may be anything.
        var results: ?Value = null;
        if (findCallbackExport(&callback_exports, resolved.binding.specifier, resolved.func.name)) |row| {
            results = try self.exportCallback(node, row.shape, args.values, st);
        } else {
            if (read.callables_top) try self.record(node, .call, .unknown_callee);
            if (read.callables.len > 0) {
                results = try self.runCallbackLoop(node, read, .{ .presumed = args.values }, st);
            }
        }
        if (results) |passed| results = withoutDefenses(passed);

        var contents: std.ArrayList(Value) = .empty;
        try contents.append(arena, held);
        if (results) |passed| try contents.append(arena, passed);
        const is_fetch = std.mem.eql(u8, resolved.binding.specifier, "zttp:fetch") and
            (std.mem.eql(u8, resolved.func.name, "fetch") or std.mem.eql(u8, resolved.func.name, "fetchWithRetry"));
        const site_kind: SiteKind = if (is_fetch) .native else .allocated_any;
        const container = try self.allocate(st, site_kind, node, contents.items, .{ .labels = labels, .defenses = held.defenses });

        // The result keeps every origin, callable, and flag of what the call
        // read and of what the callbacks returned: an export can hand back an
        // argument, a value stored in one, or a callback result.
        var shown = held;
        shown.labels = labels;
        var out = try joinValue(arena, shown, container);
        if (results) |passed| out = try joinValue(arena, out, passed);

        // No native export writes into an argument today. The write keeps a
        // future one sound, at the cost of mixing the containers of one call.
        try self.writeValue(st, read, .{ .dynamic = Value.clean }, out);
        return out;
    }

    /// One parameter of a callback, computed from the loop head on each pass.
    const Param = union(enum) {
        /// The accumulator: its initial value joined with every result so far.
        acc: Value,
        /// Every element of the value, read at the head.
        elements: Value,
        /// Every element of the value, read at the head, and the flow of the
        /// value itself.
        elements_labelled: Value,
        /// The labels of everything the value reaches at the head, and no
        /// defense. The key of a dictionary entry takes this form.
        deep: Value,
        /// The position of an element in the value: the labels of everything
        /// the value reaches at the head, and no defense. A receiver built
        /// from request data has a length that the data decides, so the index
        /// carries what the cells carry (R1).
        structure: Value,
        /// The value itself.
        itself: Value,
    };

    /// What a callback loop passes on each pass.
    const LoopParams = union(enum) {
        /// A presumed call: every parameter of the callee is everything that
        /// these arguments reach in the loop head, joined with the results so
        /// far.
        presumed: []const Value,
        /// A precise call: the parameters, in order.
        precise: []const Param,
    };

    /// The number of parameters of the function at `func_node`, or 0 when the
    /// node is no function (`invoke` records that case).
    fn paramCount(self: *const FlowInterp, func_node: NodeIndex) usize {
        const tag = self.ir_view.getTag(func_node) orelse return 0;
        if (tag != .function_expr and tag != .arrow_function) return 0;
        const function = self.ir_view.getFunction(func_node) orelse return 0;
        return function.params_count;
    }

    /// The arguments of one pass for the callback at `func_node`.
    fn loopArgs(self: *FlowInterp, params: LoopParams, func_node: NodeIndex, head: *const State, results: ?Value) Error![]const Value {
        const arena = self.mem();
        switch (params) {
            .presumed => |args| {
                const every = try joinOpt(arena, try self.reach(head, args), results) orelse Value.clean;
                const vector = try arena.alloc(Value, self.paramCount(func_node));
                @memset(vector, every);
                return vector;
            },
            .precise => |list| {
                const vector = try arena.alloc(Value, list.len);
                for (list, vector) |param, *slot| slot.* = try self.paramValue(head, param, results);
                return vector;
            },
        }
    }

    /// The value of `param` in the loop head, with the results of the passes
    /// so far (null before the first).
    fn paramValue(self: *FlowInterp, head: *const State, param: Param, results: ?Value) Error!Value {
        switch (param) {
            .acc => |initial| return (try joinOpt(self.mem(), initial, results)) orelse initial,
            .elements => |source| return self.readAll(head.*, source),
            .elements_labelled => |source| {
                return joinValue(self.mem(), try self.readAll(head.*, source), Value.flowing(source.flow()));
            },
            .deep, .structure => |source| return Value.labelled((try self.deepFlow(head, &.{source})).labels),
            .itself => |v| return v,
        }
    }

    /// The flow of the callback results so far, or no flow before the first.
    fn resultFlow(results: ?Value) Flow {
        return (results orelse return .{}).flow();
    }

    /// Run the callback `f` of the operation at `node` as a precise loop. A
    /// callback that holds no function, or that may be any function, is
    /// recorded, and the result is `top`. A null result means that no callback
    /// completes.
    fn runCallback(self: *FlowInterp, node: NodeIndex, f: Value, params: []const Param, st: *State) Error!?Value {
        if (f.callables_top) {
            try self.record(node, .call, .unknown_callee);
            return Value.top;
        }
        if (f.callables.len == 0) {
            try self.record(node, .call, .no_operation_rule);
            return Value.top;
        }
        return self.runCallbackLoop(node, f, .{ .precise = params }, st);
    }

    /// The precise callback of an export (argument 1). The results join the
    /// call's summary and value, and `dictFold` returns its accumulator, which
    /// is the initial value joined with every result.
    fn exportCallback(self: *FlowInterp, node: NodeIndex, shape: CallbackShape, args: []const Value, st: *State) Error!?Value {
        const source = argAt(args, 0);
        const f = argAt(args, 1);
        switch (shape) {
            .dict_entries => return self.runCallback(node, f, &.{ .{ .elements = source }, .{ .deep = source } }, st),
            .dict_fold => {
                const initial = argAt(args, 2);
                const results = try self.runCallback(
                    node,
                    f,
                    &.{ .{ .acc = initial }, .{ .elements = source }, .{ .deep = source } },
                    st,
                );
                return try joinOpt(self.mem(), initial, results);
            },
            .payload => return self.runCallback(node, f, &.{.{ .elements = source }}, st),
        }
    }

    /// A callback loop: run every function of `f` as a callback until the loop
    /// head and the result set stop changing, and return the result set (null
    /// when no callback completes).
    ///
    /// The head starts as the state before the loop and includes it at the end,
    /// because a callback can run zero times. Each pass computes the arguments
    /// from the head, so a callback that writes what a later pass reads is seen.
    /// A callback runs as a P4 callee from the head, and the join of every
    /// callee state is the next head (`heap` and `top_cell` only, because the
    /// caller's bindings are out of scope for a callback). Each callee value
    /// joins the result set with the labels of `f`: a callback chosen through
    /// a labelled value is selected by that value. Convergence is checked
    /// before the cap, so a loop that converges on the last permitted pass has
    /// converged, and the cap records `fixpoint_limit`.
    fn runCallbackLoop(self: *FlowInterp, node: NodeIndex, f: Value, params: LoopParams, st: *State) Error!?Value {
        const arena = self.mem();
        const cap = @max(self.max_loop_passes, 1);
        var head = try self.heapState(st);
        var results: ?Value = null;
        var pass: u32 = 0;
        while (true) : (pass +|= 1) {
            var next = head;
            var next_results = results;
            for (f.callables) |func_node| {
                const args = try self.loopArgs(params, func_node, &head, results);
                const summary = try self.invoke(func_node, args, &head);
                next = try joinStates(arena, next, summary.state);
                if (summary.value) |returned| {
                    next_results = try joinOpt(arena, next_results, withFlow(returned, f.flow()));
                }
            }
            if (stateEql(next, head) and optValueEql(next_results, results)) break;
            head = next;
            results = next_results;
            if (pass +| 1 >= cap) {
                try self.record(node, .call, .fixpoint_limit);
                break;
            }
        }
        // The caller goes on mutating its own maps, so it gets a copy.
        st.heap = try head.heap.clone(arena);
        st.top_cell = head.top_cell;
        return results;
    }

    // --- reach (P5) ---

    /// The state of one `reach` walk: the join so far, the sites already
    /// queued, and whether the walk has swept the whole heap.
    const Reach = struct {
        joined: Value = .{},
        seen: std.AutoHashMapUnmanaged(SiteKey, void) = .empty,
        queue: std.ArrayList(SiteKey) = .empty,
        swept: bool = false,
    };

    fn reachValue(self: *FlowInterp, walk: *Reach, v: Value) Error!void {
        walk.joined = try unionValue(self.mem(), walk.joined, v);
        for (v.origins) |site| try self.reachSite(walk, site);
    }

    /// A capture cell is not an object, so no walk follows one.
    fn reachSite(self: *FlowInterp, walk: *Reach, site: SiteKey) Error!void {
        if (site.kind == .capture) return;
        const slot = try walk.seen.getOrPut(self.mem(), site);
        if (slot.found_existing) return;
        try walk.queue.append(self.mem(), site);
    }

    fn reachCells(self: *FlowInterp, walk: *Reach, cells: Cells) Error!void {
        var it = cells.named.valueIterator();
        while (it.next()) |v| try self.reachValue(walk, v.*);
        if (cells.summary) |summary| try self.reachValue(walk, summary);
    }

    /// The join of every value reachable from `vs`: the values, every cell of
    /// every origin they name, transitively, the cells of unnamed writes, and
    /// the native value of each `builtin` and `native` origin. A value that
    /// may point anywhere reaches every cell of the heap.
    fn reach(self: *FlowInterp, st: *const State, vs: []const Value) Error!Value {
        var walk: Reach = .{};
        for (vs) |v| try self.reachValue(&walk, v);
        try self.reachCells(&walk, st.top_cell);
        var next: usize = 0;
        while (true) {
            while (next < walk.queue.items.len) : (next += 1) {
                const site = walk.queue.items[next];
                if (st.heap.get(site)) |cells| try self.reachCells(&walk, cells);
                if (site.kind == .builtin or site.kind == .native) try self.reachValue(&walk, try self.anyNative());
            }
            if (!walk.joined.origins_top or walk.swept) break;
            walk.swept = true;
            var it = st.heap.keyIterator();
            while (it.next()) |site| try self.reachSite(&walk, site.*);
        }
        return walk.joined;
    }

    /// Run `func_node` with `args` from the caller's state `st`. A function that
    /// is already being analyzed is a recursive call and uses that
    /// activation's summary.
    fn invoke(self: *FlowInterp, func_node: NodeIndex, args: []const Value, st: *const State) Error!Summary {
        const tag = self.ir_view.getTag(func_node) orelse .stmt_list;
        const function = (if (tag == .function_expr or tag == .arrow_function)
            self.ir_view.getFunction(func_node)
        else
            null) orelse {
            _ = try self.missing(func_node);
            return .{ .value = Value.top, .state = try self.heapState(st) };
        };
        const fitted = try self.fitArgs(function, args);
        var i = self.activations.items.len;
        while (i > 0) {
            i -= 1;
            if (self.activations.items[i].func == func_node) return self.recurse(i, fitted, st);
        }
        return self.runActivation(func_node, tag, function, fitted, st);
    }

    /// A call of a function that is being analyzed. The call feeds its
    /// arguments and heap into the activation's pending input and returns the
    /// summary of the finished passes, with the caller's heap joined in. While
    /// no pass has finished, the summary is bottom and so is the state after
    /// the call: the activation is rerun when its summary grows.
    fn recurse(self: *FlowInterp, index: usize, args: []const Value, st: *const State) Error!Summary {
        const arena = self.mem();
        // Shares the caller's maps by reference. `joinStates` copies them.
        const caller: State = .{ .heap = st.heap, .top_cell = st.top_cell };
        const record_ptr = &self.activations.items[index];
        record_ptr.used = true;
        record_ptr.pending_args = try joinArgs(arena, record_ptr.pending_args, args);
        record_ptr.pending = try joinStates(arena, record_ptr.pending, caller);
        const summary = record_ptr.summary;
        if (!summary.state.reachable) return Summary.bottom;
        return .{ .value = summary.value, .state = try joinStates(arena, caller, summary.state) };
    }

    /// Analyze the body of `func_node` for a call, once or as a fixpoint when
    /// a call inside it reaches the function again. Pass `k` runs the body from
    /// `entry`. When a recursive call fed the record, the pass ends by
    /// comparing the pending input with `entry` and the joined summary with the
    /// previous one: if either grew, the body runs again from the pending
    /// input. Convergence is checked before the cap, as for a loop.
    fn runActivation(
        self: *FlowInterp,
        func_node: NodeIndex,
        tag: NodeTag,
        function: ir.Node.FunctionExpr,
        args: []const Value,
        st: *const State,
    ) Error!Summary {
        const arena = self.mem();
        const entry = try self.heapState(st);
        const depth = self.activations.items.len;
        try self.activations.append(arena, .{
            .func = func_node,
            .entry_args = args,
            .entry = entry,
            .pending_args = args,
            .pending = entry,
            .summary = Summary.bottom,
            .used = false,
        });
        defer self.activations.shrinkRetainingCapacity(depth);

        const cap = @max(self.max_recursion_passes, 1);
        var pass: u32 = 0;
        while (true) {
            pass +|= 1;
            self.activations.items[depth].used = false;
            const input = self.activations.items[depth];
            const result = try self.runBody(function, input.entry_args, input.entry);

            // The body can grow the stack, so the record is read again.
            const record_ptr = &self.activations.items[depth];
            if (!record_ptr.used) {
                record_ptr.summary = result;
                return result;
            }
            self.recursion_passes_peak = @max(self.recursion_passes_peak, pass);
            const changed = !argsEql(record_ptr.pending_args, record_ptr.entry_args) or
                !stateEql(record_ptr.pending, record_ptr.entry) or
                !summaryEql(result, record_ptr.summary);
            record_ptr.summary = result;
            if (!changed) return result;
            record_ptr.entry_args = record_ptr.pending_args;
            record_ptr.entry = record_ptr.pending;
            if (pass >= cap) {
                try self.record(func_node, tag, .fixpoint_limit);
                return result;
            }
        }
    }

    /// One pass over a callee body: a fresh environment holding the
    /// parameters, the heap and unnamed cells of `entry`, and no loop frames.
    /// The callee's completions are its own: a return, a failed assert, and the
    /// fallthrough are normal completions that return to the caller.
    fn runBody(self: *FlowInterp, function: ir.Node.FunctionExpr, args: []const Value, entry: State) Error!Summary {
        var st: State = .{ .heap = try entry.heap.clone(self.mem()), .top_cell = entry.top_cell };
        const saved_completions = self.completions;
        const saved_loops = self.loop_frames;
        self.completions = .empty;
        self.loop_frames = .empty;
        defer {
            self.completions = saved_completions;
            self.loop_frames = saved_loops;
        }
        try self.bindParams(function, args, &st);
        try self.exec(function.body, &st);
        return self.summarize(st);
    }

    /// The join of the running callee's completions and its fallthrough.
    fn summarize(self: *FlowInterp, fallthrough: State) Error!Summary {
        const arena = self.mem();
        var out = Summary.bottom;
        for (self.completions.items) |completion| {
            out = try joinSummary(arena, out, .{ .value = completion.value, .state = heapOnly(completion.state) });
        }
        if (fallthrough.reachable) {
            out = try joinSummary(arena, out, .{ .value = Value.clean, .state = heapOnly(fallthrough) });
        }
        return out;
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
            // A capture cell is not an object, so no value points at it.
            var it = st.heap.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.kind == .capture) continue;
                acc = try self.absorb(acc, entry.value_ptr.*, null);
            }
        }
        return acc;
    }

    /// An absent cell is a reachable `undefined`, so a read that sees nothing
    /// yields `clean`. The receiver and key flows join the result as data: a
    /// property of a labelled value, and a selection by a labelled key, carry
    /// the label (R1), and a raw receiver or key removes a defense. This is
    /// the stored content only: a method that the runtime finds on a prototype
    /// is not in any cell.
    fn storedRead(self: *FlowInterp, st: *const State, o: Value, key: Key) Error!Value {
        return switch (key) {
            .name => |n| blk: {
                const seen = try self.visible(st, o, n);
                break :blk withFlow(seen orelse Value.clean, o.flow());
            },
            .index => blk: {
                const seen = try self.visible(st, o, null);
                break :blk withFlow(seen orelse Value.clean, o.flow());
            },
            .dynamic => |k| blk: {
                const seen = try self.visible(st, o, null);
                break :blk withFlow(seen orelse Value.clean, combineFlows(o.flow(), k.flow()));
            },
        };
    }

    /// The stored content of a read, with the native function that the runtime
    /// may find under the key (`implicitNative`).
    fn readValue(self: *FlowInterp, st: *const State, o: Value, key: Key) Error!Value {
        const stored = try self.storedRead(st, o, key);
        const native = (try self.implicitNative(o, key)) orelse return stored;
        return withNative(self.mem(), stored, native);
    }

    /// Every cell a scan of `o` can see, with `o`'s labels on the result. This
    /// is what a spread copies and what the tests inspect. A scan reads
    /// elements and does not go through the computed-read rule, but it also
    /// sees the properties of a native site.
    pub fn readAll(self: *FlowInterp, state: State, o: Value) Error!Value {
        const stored = try self.storedRead(&state, o, .index);
        return self.scanNative(stored, o);
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
            var it = st.heap.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.kind == .capture) continue;
                out = try joinCells(arena, out, entry.value_ptr.*);
            }
        }
        if (hasNativeSite(o)) {
            out = try joinCells(arena, out, .{ .summary = try self.anyNative() });
        }
        return out;
    }

    fn weakWriteSite(self: *FlowInterp, st: *State, site: SiteKey, name: ?u16, v: Value) Error!void {
        const arena = self.mem();
        const current = st.heap.get(site) orelse Cells{};
        try st.heap.put(arena, site, try weakWriteCells(arena, current, name, v));
    }

    /// A write of `v` to `o.name` or `o[k]`. The stored value carries the
    /// flow of the receiver and the key, because a target chosen by a
    /// labelled value is itself a flow, and a raw receiver or key removes a
    /// defense from every later read of the cell. Every origin takes a weak
    /// update, and a write through an unnamed target lands in `top_cell`. The
    /// expression value of the assignment is `v`, not the stored value.
    fn writeValue(self: *FlowInterp, st: *State, o: Value, key: Key, v: Value) Error!void {
        var flow = combineFlows(v.flow(), o.flow());
        var name: ?u16 = null;
        switch (key) {
            .name => |n| name = n,
            .index => {},
            .dynamic => |k| flow = combineFlows(flow, k.flow()),
        }
        // The combined flow already holds `v`, so it replaces the flow of `v`
        // and is not merged with it a second time.
        var stored = v;
        stored.labels = flow.labels;
        stored.defenses = flow.defenses;
        for (o.origins) |site| try self.weakWriteSite(st, site, name, stored);
        if (o.origins_top) st.top_cell = try weakWriteCells(self.mem(), st.top_cell, name, stored);
    }

    /// Copy the cells `src` shows to a dynamic read into `site`. Each copied
    /// value takes the source's flow as data. A source that carries labels but
    /// shows no cell (a labelled string) still taints the result, in the
    /// summary, because every element or field of it is derived from it.
    fn spreadInto(self: *FlowInterp, st: *State, site: SiteKey, src: Value, keep_names: bool) Error!void {
        const view = try self.snapshotCells(st, src);
        var it = view.named.iterator();
        while (it.next()) |entry| {
            const name: ?u16 = if (keep_names) entry.key_ptr.* else null;
            try self.weakWriteSite(st, site, name, withFlow(entry.value_ptr.*, src.flow()));
        }
        if (view.summary) |summary| {
            try self.weakWriteSite(st, site, null, withFlow(summary, src.flow()));
        }
        if (!src.labels.isEmpty()) {
            try self.weakWriteSite(st, site, null, Value.flowing(src.flow()));
        }
    }

    // --- expressions ---

    pub fn eval(self: *FlowInterp, node: NodeIndex, st: *State) Error!Value {
        const tag = self.ir_view.getTag(node) orelse return self.missing(node);
        self.noteVisited(tag);
        try self.tick(node, tag);
        switch (tag) {
            .lit_int, .lit_float, .lit_string, .lit_bool, .lit_null, .lit_undefined => return Value.clean,
            .identifier => return self.evalIdentifier(node, st),
            .binary_op => return self.evalBinary(node, st),
            .unary_op => {
                const unary = self.ir_view.getUnary(node) orelse return self.missing(node);
                const operand = try self.eval(unary.operand, st);
                return Value.flowing(operand.flow());
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
                // The body is not executed here. A call runs it, so a function
                // value is a name for its body and a mutable object.
                const site: SiteKey = .{ .kind = .function, .node = node, .context = 0 };
                return self.siteValue(site, node);
            },
            .call => return self.evalCall(node, st),
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
                if (self.loadLocal(st, packBindingKey(binding.scope_id, binding.slot))) |v| return v;
                // Read before its declaration ran. The runtime does not hoist
                // a function declaration, so the slot holds something this
                // evaluator never saw.
                try self.record(node, .identifier, .read_before_declaration);
                return Value.top;
            },
            // A closure reads the cell of the binding the parser's scope
            // analysis names. Without a table there is no cell to read.
            .upvalue => {
                const key = self.upvalueKey(binding) orelse {
                    try self.record(node, .identifier, .capture_unplaced);
                    return Value.top;
                };
                return captureValue(st, key);
            },
            // A module function is a fixed value; any other module name is
            // state that P8 owns. An undeclared global that the module level
            // never binds is a builtin.
            .global, .undeclared_global => {
                // An export that is not a callee is its native function value.
                if (binding.kind == .global) {
                    if (try self.moduleExport(binding.name_atom)) |resolved| return self.nativeFunction(resolved.imported);
                }
                if (try self.moduleFunction(binding.name_atom)) |func_node| {
                    const site: SiteKey = .{ .kind = .function, .node = func_node, .context = 0 };
                    return self.siteValue(site, func_node);
                }
                if (binding.kind == .undeclared_global and !try self.moduleBinds(binding.name_atom)) {
                    return self.builtinGlobal(node, binding.name_atom);
                }
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
                return Value.flowing(combineFlows(left.flow(), right.flow()));
            },
        }
    }

    /// Evaluate a computed key once. A string literal is a static name, and a
    /// numeric literal names an element.
    fn evalKey(self: *FlowInterp, key_node: NodeIndex, st: *State) Error!Key {
        const value = try self.eval(key_node, st);
        if (try self.literalKey(key_node)) |name| return .{ .name = name };
        const tag = self.ir_view.getTag(key_node) orelse return .{ .dynamic = value };
        if (tag == .lit_int or tag == .lit_float) return .index;
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
                return Value.flowing(combineFlows(old.flow(), rhs.flow()));
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
                            const old = self.loadLocal(st, key) orelse old_blk: {
                                try self.record(asg.target, .identifier, .read_before_declaration);
                                break :old_blk Value.top;
                            };
                            break :blk try self.compoundValue(op, old, asg.value, st);
                        } else try self.eval(asg.value, st);
                        try self.storeLocal(st, key, assigned);
                        return assigned;
                    },
                    // A closure writes the cell of the captured binding, weakly.
                    .upvalue => {
                        const key = self.upvalueKey(binding) orelse {
                            const assigned = try self.eval(asg.value, st);
                            try self.record(node, .assignment, .capture_unplaced);
                            return assigned;
                        };
                        const assigned = if (asg.op) |op|
                            try self.compoundValue(op, captureValue(st, key), asg.value, st)
                        else
                            try self.eval(asg.value, st);
                        try self.weakWriteCapture(st, key, assigned);
                        return assigned;
                    },
                    // Module state belongs to P8.
                    .global, .undeclared_global => {
                        const assigned = try self.eval(asg.value, st);
                        try self.record(node, .assignment, .p8);
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
                return self.assignThrough(node, st, o, key, asg);
            },
            .computed_access => {
                const m = self.ir_view.getMember(asg.target) orelse return self.missing(node);
                const o = try self.eval(m.object, st);
                const key = try self.evalKey(m.computed, st);
                return self.assignThrough(node, st, o, key, asg);
            },
            // The restricted profile has no other assignment target.
            else => {
                _ = try self.eval(asg.value, st);
                try self.record(node, .assignment, .refused_by_parser);
                return Value.top;
            },
        }
    }

    fn assignThrough(self: *FlowInterp, node: NodeIndex, st: *State, o: Value, key: Key, asg: ir.Node.AssignExpr) Error!Value {
        const assigned = if (asg.op) |op| blk: {
            const old = try self.readValue(st, o, key);
            break :blk try self.compoundValue(op, old, asg.value, st);
        } else try self.eval(asg.value, st);
        try self.writeValue(st, o, key, assigned);
        // A shared runtime object is shared by every request.
        if (hasBuiltinSite(o)) try self.record(node, .assignment, .p8);
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

    /// Bind the names a pattern holds. A binding gets the static read of its
    /// field or element from the discriminant, so it carries that cell and the
    /// discriminant's labels and not a neighbouring field's. A nested record or
    /// array pattern reads the same way and binds below that read.
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
                            try self.storeLocal(st, packBindingKey(binding.scope_id, binding.slot), field);
                        },
                        .match_pattern, .array_pattern => {
                            const name = (try self.literalKey(prop.key)) orelse {
                                try self.record(prop_idx, .object_property, .refused_by_parser);
                                continue;
                            };
                            const field = try self.readValue(st, disc, .{ .name = name });
                            try self.bindPattern(prop.value, field, st);
                        },
                        // exhaustive: a record pattern field holds a binding, a
                        // nested pattern, or a literal. A literal is a
                        // discriminant test and binds nothing, and the tags the
                        // parser never puts in a pattern bind nothing either.
                        else => {},
                    }
                }
            },
            .array_pattern => {
                self.noteVisited(.array_pattern);
                const arr = self.ir_view.getArray(pattern) orelse return;
                var i: u16 = 0;
                while (i < arr.elements_count) : (i += 1) {
                    const element = self.ir_view.getListIndex(arr.elements_start, i);
                    // A hole reads nothing.
                    if (element == null_node) continue;
                    const element_tag = self.ir_view.getTag(element) orelse continue;
                    // Only a record or array element can hold a binding.
                    if (element_tag != .match_pattern and element_tag != .array_pattern) continue;
                    const elem = try self.readValue(st, disc, .index);
                    try self.bindPattern(element, elem, st);
                }
            },
            .match_type_test => self.noteVisited(.match_type_test),
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
        try self.tick(node, tag);
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
                // A call in the expression that never returns leaves nothing
                // to return.
                if (!st.reachable) return;
                try self.completions.append(self.mem(), .{ .kind = .returned, .value = v, .state = st.* });
                st.* = State.bottom;
            },
            .assert_stmt => {
                const s = self.ir_view.getAssertStmt(node) orelse {
                    _ = try self.missing(node);
                    return;
                };
                _ = try self.eval(s.condition, st);
                if (!st.reachable) return;
                // The assert held on the path that continues, so the original
                // state goes on. The failure is a completion of its own.
                var failed = try cloneState(self.mem(), st.*);
                if (s.error_expr == null_node) {
                    try self.completions.append(self.mem(), .{ .kind = .halt, .value = Value.clean, .state = failed });
                } else {
                    const message = try self.eval(s.error_expr, &failed);
                    if (!failed.reachable) return;
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

    /// A strong update of a declared binding, or a weak write to its capture
    /// cell when a closure captures it. Only function-local bindings are
    /// stored; a declaration of any other kind belongs to module state.
    fn bindDeclared(
        self: *FlowInterp,
        st: *State,
        binding: ir.BindingRef,
        v: Value,
        node: NodeIndex,
        tag: NodeTag,
    ) Error!void {
        switch (binding.kind) {
            .local, .argument => try self.storeLocal(st, packBindingKey(binding.scope_id, binding.slot), v),
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
    captures: ?CaptureTable,
    interp: FlowInterp,

    fn create(allocator: std.mem.Allocator, source: []const u8) !*Harness {
        return createWith(allocator, source, true);
    }

    /// With `place_captures` false the evaluator gets no capture table, as a
    /// caller that has not wired the parser's scope analysis would.
    fn createWith(allocator: std.mem.Allocator, source: []const u8, place_captures: bool) !*Harness {
        const h = try allocator.create(Harness);
        errdefer allocator.destroy(h);
        h.allocator = allocator;
        h.atoms = atom_table.AtomTable.init(allocator);
        errdefer h.atoms.deinit();
        h.parser = try JsParser.init(allocator, source);
        errdefer h.parser.deinit();
        h.parser.setAtomTable(&h.atoms);
        _ = try h.parser.parse();
        h.captures = if (place_captures) try CaptureTable.init(allocator, &h.parser.scopes) else null;
        errdefer if (h.captures) |*table| table.deinit();
        const view = IrView.fromIRStore(&h.parser.nodes, &h.parser.constants);
        h.interp = FlowInterp.init(allocator, view, &h.atoms);
        if (h.captures) |*table| h.interp.captures = table;
        return h;
    }

    fn destroy(h: *Harness) void {
        const allocator = h.allocator;
        h.interp.deinit();
        if (h.captures) |*table| table.deinit();
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

    // The read at a labelled key may return a method of `table` (the key may
    // name one), a function object that every request shares. So the write
    // through it is a P8 write, and the label still reaches `a.x`.
    const write_through_key = "function f(s) { const a = {}; const table = [a]; table[s].x = \"X\"; return a.x; }";
    inline for (.{ secret_value, Value.clean }, .{ true, false }) |seed, leaks| {
        const r = try analyzeSource(write_through_key, "f", &.{seed});
        defer r.deinit();
        try expectUnresolved(r.result, .assignment, .p8);
        try testing.expectEqual(leaks, r.returnedLabels().secret);
    }

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
    // The parser resolves a name only to an earlier declaration, so the read of
    // `g` is an undeclared global when it is parsed. The module level never
    // binds `g`, and `g` is no builtin, so the strict checker refuses it.
    try testing.expectEqual(Owner.refused_by_strict, before.result.unresolved[0].owner);
}

test "a local read with no declaration behind it is unresolved" {
    var store = ir.IRStore.init(testing.allocator);
    defer store.deinit();
    var constants = ir.ConstantPool.init(testing.allocator);
    defer constants.deinit();
    const binding: ir.BindingRef = .{ .scope_id = 3, .slot = 1, .name_atom = 0, .kind = .local };
    const node = try store.addIdentifier(.{ .line = 1, .column = 1, .offset = 0 }, binding);
    var interp = FlowInterp.init(testing.allocator, IrView.fromIRStore(&store, &constants), null);
    defer interp.deinit();

    var st: State = .{};
    const unseen = try interp.eval(node, &st);
    try testing.expect(unseen.labels.unknown);
    try expectUnresolved(try interp.finish(st), .identifier, .read_before_declaration);

    // The contrast: a binding that a declaration stored reads as stored.
    var declared: State = .{};
    try declared.env.put(interp.mem(), packBindingKey(3, 1), Value.clean);
    const seen = try interp.eval(node, &declared);
    try testing.expect(seen.labels.isEmpty());
    try testing.expectEqual(@as(usize, 0), interp.unresolved_list.items.len);
}

fn expectUnresolved(result: FunctionResult, tag: NodeTag, owner: Owner) !void {
    try testing.expect(result.cleared);
    for (result.unresolved) |entry| {
        if (entry.tag == tag and entry.owner == owner) return;
    }
    return error.UnresolvedEntryNotFound;
}

test "a call and an upvalue read clear the result with their owner, and a nested pattern does not" {
    // A callee with no function in it is the runtime's `NotCallable`, which
    // has no operation rule.
    const call = try analyzeSource("function f(g) { return g(1); }", "f", &.{Value.clean});
    defer call.deinit();
    try expectUnresolved(call.result, .call, .no_operation_rule);
    try testing.expect(call.result.returned.?.labels.unknown);

    // Without a capture table no closure read has a cell to read.
    const closure = "function outer() { const k = 1; function inner() { return k; } return inner; }";
    const unplaced = try Harness.createWith(testing.allocator, closure, false);
    defer unplaced.destroy();
    try expectUnresolved(try unplaced.analyze("inner", &.{}), .identifier, .capture_unplaced);

    // With one, the analyzed function is a root whose captures nothing seeded.
    const upvalue = try analyzeSource(closure, "inner", &.{});
    defer upvalue.deinit();
    try expectUnresolved(upvalue.result, .function_decl, .capture_unseeded);

    // A nested pattern binds below the first level, so it resolves.
    const nested = "function f(s) { const o = { a: { b: s } }; return match (o) { when { a: { b: v } }: v default: 0 }; }";
    try expectSecret(nested, &.{secret_value}, true);
    try expectSecret(nested, &.{Value.clean}, false);

    // The contrast: the same shapes without the construct stay resolved, and
    // the whole of `outer` creates the capture it reads.
    const plain = try analyzeSource("function f(x) { return x; }", "f", &.{Value.clean});
    defer plain.deinit();
    try testing.expect(!plain.result.cleared);
    const whole = try analyzeSource(closure, "outer", &.{});
    defer whole.deinit();
    try testing.expect(!whole.result.cleared);
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

// --- nested match patterns (P6a) ---

test "a nested record pattern binds its field and not a neighbour" {
    const source = "function f(s) { const x = { a: { b: s } }; return match (x) { when { a: { b: v } }: v default: \"c\" }; }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(source, &.{Value.clean}, false);

    const neighbour = "function f(s) { const x = { a: { b: \"c\", z: s } }; return match (x) { when { a: { b: v } }: v default: \"c\" }; }";
    try expectSecret(neighbour, &.{secret_value}, false);
}

test "an array pattern binds through an element record pattern" {
    const source = "function f(s) { const x = [{ k: s }]; return match (x) { when [{ k: v }]: v default: \"c\" }; }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(source, &.{Value.clean}, false);
}

test "a pattern nested in a record field or an array element binds" {
    const in_field = "function f(s) { const x = { a: [{ b: s }] }; return match (x) { when { a: [{ b: v }] }: v default: \"c\" }; }";
    try expectSecret(in_field, &.{secret_value}, true);
    try expectSecret(in_field, &.{Value.clean}, false);

    const in_element = "function f(s) { const x = [[{ b: s }]]; return match (x) { when [[{ b: v }]]: v default: \"c\" }; }";
    try expectSecret(in_element, &.{secret_value}, true);
    try expectSecret(in_element, &.{Value.clean}, false);
}

test "a hole and a literal element bind nothing and the arm still evaluates" {
    const holes = [_][]const u8{
        // The arm body reads a parameter, so the arm runs.
        "function f(s, x) { return match (x) { when [, \"a\"]: s default: \"c\" }; }",
        "function f(s, x) { return match (x) { when [\"a\", , { k: v }]: s default: \"c\" }; }",
    };
    for (holes) |source| {
        const r = try analyzeSource(source, "f", &.{ secret_value, Value.clean });
        defer r.deinit();
        try testing.expect(!r.result.cleared);
        try testing.expectEqual(@as(usize, 0), r.result.unresolved.len);
        try testing.expect(r.returnedLabels().secret);
    }

    // A secret in the discriminant reaches no binding, because the hole and
    // the literal bind none.
    const unbound = "function f(s) { const x = [s, \"a\"]; return match (x) { when [, \"a\"]: \"d\" default: \"c\" }; }";
    const r = try analyzeSource(unbound, "f", &.{secret_value});
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expectEqual(@as(usize, 0), r.result.unresolved.len);
    try testing.expect(r.returnedLabels().isEmpty());
}

test "no tag is left to the nested-pattern phase" {
    try testing.expect(!@hasField(Phase, "p6"));
    try testing.expect(!@hasField(Owner, "p6"));
    try testing.expect(tagPlan(.array_pattern) == .handled);
    inline for (@typeInfo(NodeTag).@"enum".fields) |field| {
        const tag: NodeTag = @enumFromInt(field.value);
        switch (tagPlan(tag)) {
            .later => |phase| try testing.expect(!std.mem.eql(u8, @tagName(phase), "p6")),
            else => {},
        }
    }
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

// --- calls and captures (P4) ---
//
// These sources are internal evaluator fixtures. `s` is seeded secret and any
// other parameter clean, unless a test says otherwise. Each test has a clean
// contrast in which a literal replaces the secret.

const c_secret = [_]Value{ Value.clean, secret_value };

test "a local call returns the callee's value" {
    try expectSecret("function f(s) { function id(x) { return x; } return id(s); }", &.{secret_value}, true);
    try expectSecret("function f(s) { function id(x) { return x; } return id(\"c\"); }", &.{secret_value}, false);
}

test "a call joins every return of the callee" {
    try expectSecret(
        "function f(c, s) { function g(c) { if (c) { return \"c\"; } return s; } return g(c); }",
        &c_secret,
        true,
    );
    try expectSecret(
        "function f(c, s) { function g(c) { if (c) { return \"c\"; } return \"d\"; } return g(c); }",
        &c_secret,
        false,
    );
    // The first return alone would be clean, and so would the last alone.
    try expectSecret(
        "function f(c, s) { function g(c) { if (c) { return s; } return \"c\"; } return g(c); }",
        &c_secret,
        true,
    );
}

test "a callee's write through its argument reaches the caller's object" {
    try expectSecret(
        "function f(s) { const o = { x: \"c\" }; function w(t) { t.x = s; return 0; } w(o); return o.x; }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { const o = { x: \"c\" }; function w(t) { t.x = \"d\"; return 0; } w(o); return o.x; }",
        &.{secret_value},
        false,
    );
}

test "a callee that never returns leaves no returned value and an unreachable exit" {
    const r = try analyzeSource(
        "function f(s) { function spin() { return spin(); } spin(); return s; }",
        "f",
        &.{secret_value},
    );
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expect(r.result.returned == null);
    try testing.expect(!r.result.exit.reachable);
    try testing.expectEqual(@as(usize, 0), r.result.completions.len);

    // The contrast: a callee that returns lets the caller go on.
    try expectSecret("function f(s) { function spin() { return 1; } spin(); return s; }", &.{secret_value}, true);

    // A `return` whose own expression holds the call returns nothing either.
    const inline_call = try analyzeSource(
        "function f(s) { function spin() { return spin(); } return spin() + s; }",
        "f",
        &.{secret_value},
    );
    defer inline_call.deinit();
    try testing.expect(!inline_call.result.cleared);
    try testing.expect(inline_call.result.returned == null);
    try testing.expectEqual(@as(usize, 0), inline_call.result.completions.len);
}

test "a callee that falls off its end returns to the caller" {
    try expectSecret(
        "function f(s) { const o = { x: \"c\" }; function w(t) { t.x = s; } w(o); return o.x; }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { const o = { x: \"c\" }; function w(t) { t.x = \"d\"; } w(o); return o.x; }",
        &.{secret_value},
        false,
    );
}

test "a helper assert returns its message to the caller and not to the root" {
    try expectSecret("function f(c, s) { function g() { assert c, s; return \"c\"; } return g(); }", &c_secret, true);
    try expectSecret("function f(c, s) { function g() { assert c, \"m\"; return \"c\"; } return g(); }", &c_secret, false);

    // The root's own completions do not include the helper's failed assert.
    const helper_only = try analyzeSource(
        "function f(c, s) { function g() { assert c, s; return \"c\"; } g(); return \"ok\"; }",
        "f",
        &c_secret,
    );
    defer helper_only.deinit();
    try testing.expect(!helper_only.result.cleared);
    try testing.expect(helper_only.returnedLabels().isEmpty());
    try testing.expectEqual(@as(usize, 1), helper_only.result.completions.len);

    // A bare assert in a helper returns `undefined`, which is clean.
    try expectSecret("function f(c, s) { function g() { assert c; return s; } return g(); }", &c_secret, true);
    try expectSecret("function f(c, s) { function g() { assert c; return \"c\"; } return g(); }", &c_secret, false);
}

test "a callable set runs every function in both node orders" {
    try expectSecret(
        "function f(c, s) { const a = () => \"c\"; const b = () => s; return (c ? a : b)(); }",
        &c_secret,
        true,
    );
    try expectSecret(
        "function f(c, s) { const b = () => s; const a = () => \"c\"; return (c ? a : b)(); }",
        &c_secret,
        true,
    );
    try expectSecret(
        "function f(c, s) { const a = () => \"c\"; const b = () => \"d\"; return (c ? a : b)(); }",
        &c_secret,
        false,
    );
}

test "a capture written after the closure is read through the cell" {
    try expectSecret("function f(s) { let r = \"c\"; const g = () => r; r = s; return g(); }", &.{secret_value}, true);
    try expectSecret("function f(s) { let r = \"c\"; const g = () => r; r = \"d\"; return g(); }", &.{secret_value}, false);
}

test "a closure writes the owner's binding" {
    try expectSecret(
        "function f(s) { let r = \"c\"; const w = () => { r = s; return 1; }; w(); return r; }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { let r = \"c\"; const w = () => { r = \"d\"; return 1; }; w(); return r; }",
        &.{secret_value},
        false,
    );
}

test "two activations of a captured const share one weak cell" {
    try expectSecret(
        "function f(s) { function mk(v) { const x = v; return () => x; } const a = mk(s); const b = mk(\"c\"); return a(); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { function mk(v) { const x = v; return () => x; } const a = mk(\"d\"); const b = mk(\"c\"); return a(); }",
        &.{secret_value},
        false,
    );
}

test "two activations of a captured parameter share one weak cell" {
    try expectSecret(
        "function f(s) { function mk(v) { return () => v; } const a = mk(s); mk(\"c\"); return a(); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { function mk(v) { return () => v; } const a = mk(\"d\"); mk(\"c\"); return a(); }",
        &.{secret_value},
        false,
    );
}

test "a captured match binding lives in its cell" {
    try expectSecret(
        "function f(s) { return match ({ text: s }) { when { text }: (() => text)() default: \"c\" }; }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { return match ({ text: \"d\" }) { when { text }: (() => text)() default: \"c\" }; }",
        &.{secret_value},
        false,
    );
}

test "a captured loop variable is read by a later activation's loop" {
    const carried = "function f(s) { let first = () => \"c\"; let seen = \"c\"; function mk(xs) { let last = () => \"c\"; for (const v of xs) { seen = first(); last = () => v; } return last; } first = mk([s]); mk([\"c\"]); return seen; }";
    const clean = "function f(s) { let first = () => \"c\"; let seen = \"c\"; function mk(xs) { let last = () => \"c\"; for (const v of xs) { seen = first(); last = () => v; } return last; } first = mk([\"d\"]); mk([\"c\"]); return seen; }";
    try expectSecret(carried, &.{secret_value}, true);
    try expectSecret(clean, &.{secret_value}, false);
}

test "a capture follows the parser's binding, not the name" {
    // The parser binds a read to the first declaration of a name.
    try expectSecret("function f(s) { let x = s; let x = \"c\"; return (() => x)(); }", &.{secret_value}, true);
    try expectSecret("function f(s) { let x = \"c\"; let x = s; return (() => x)(); }", &.{secret_value}, false);

    // An unbraced conditional declaration is a second binding of `x` in the
    // function scope. The closure reads the first, which holds "c", so the
    // secret written to the second never reaches it. A scan by name would join
    // the two.
    try expectSecret(
        "function f(c, s) { let x = \"c\"; if (c) let x = s; return (() => x)(); }",
        &c_secret,
        false,
    );
    try expectSecret(
        "function f(c, s) { let x = s; if (c) let x = \"c\"; return (() => x)(); }",
        &c_secret,
        true,
    );
}

test "a module-level function resolves only when it is the single fixed declaration" {
    const definition = "function help(x) { return x; } ";
    try expectSecret(definition ++ "function f(s) { return help(s); }", &.{secret_value}, true);
    try expectSecret(definition ++ "function f(s) { return help(\"c\"); }", &.{secret_value}, false);
    // A forward read is an undeclared global when it is parsed.
    try expectSecret("function f(s) { return help(s); } " ++ definition, &.{secret_value}, true);
    try expectSecret("const help = (x) => x; function f(s) { return help(s); }", &.{secret_value}, true);
    try expectSecret("export function help(x) { return x; } function f(s) { return help(s); }", &.{secret_value}, true);

    // A second declaration of the name replaces the first at runtime.
    const second = try analyzeSource(
        definition ++ "let help = (x) => \"c\"; function f(s) { return help(s); }",
        "f",
        &.{secret_value},
    );
    defer second.deinit();
    try expectUnresolved(second.result, .identifier, .p8);

    // An assignment in another function may replace it.
    const assigned = try analyzeSource(
        definition ++ "function g() { help = (x) => \"c\"; return 0; } function f(s) { return help(s); }",
        "f",
        &.{secret_value},
    );
    defer assigned.deinit();
    try expectUnresolved(assigned.result, .identifier, .p8);

    // An unbraced declaration under an `if` runs only when the condition holds.
    const conditional = try analyzeSource(
        "if (false) function help(x) { return \"c\"; } function f(s) { return help(s); }",
        "f",
        &.{secret_value},
    );
    defer conditional.deinit();
    try expectUnresolved(conditional.result, .identifier, .p8);

    // A `let` arrow is not a fixed function.
    const mutable = try analyzeSource("let help = (x) => x; function f(s) { return help(s); }", "f", &.{secret_value});
    defer mutable.deinit();
    try expectUnresolved(mutable.result, .identifier, .p8);
}

test "a recursive call feeds its arguments into the entry" {
    const source = "function f(s) { function r(n, acc) { if (n) { return acc; } return r(true, s); } return r(false, \"c\"); }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(
        "function f(s) { function r(n, acc) { if (n) { return acc; } return r(true, \"d\"); } return r(false, \"c\"); }",
        &.{secret_value},
        false,
    );
    // The entry keeps the first call's input: a recursive call that passes a
    // clean value does not replace the secret the first call passed.
    try expectSecret(
        "function f(s) { function r(n, acc) { if (n) { return acc; } return r(true, \"c\"); } return r(false, s); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { function r(n, acc) { if (n) { return acc; } return r(true, \"c\"); } return r(false, \"d\"); }",
        &.{secret_value},
        false,
    );
    // The same when the result of the recursive call is not returned, so the
    // earlier summary cannot carry the first call's input to the last pass.
    try expectSecret(
        "function f(s) { function r(n, acc) { if (n) { return acc; } r(true, \"c\"); return acc; } return r(false, s); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { function r(n, acc) { if (n) { return acc; } r(true, \"c\"); return acc; } return r(false, \"d\"); }",
        &.{secret_value},
        false,
    );
}

// The write sits in the branch that the recursive call does not take, so only
// the summary's heap shows it after the call. Three places hold the written
// value: a seeded unnamed origin, a local object, and a captured binding.
test "a recursive call returns the summary's write through a seeded parameter" {
    const origins_top: Value = .{ .origins_top = true };
    try expectSecret(
        "function f(p, s) { function r(p, n, x, y) { if (n) { p.out = x; return 0; } r(p, true, y, y); return p.out; } return r(p, false, \"c\", s); }",
        &.{ origins_top, secret_value },
        true,
    );
    try expectSecret(
        "function f(p, s) { function r(p, n, x, y) { if (n) { p.out = x; return 0; } r(p, true, y, y); return p.out; } return r(p, false, \"c\", \"d\"); }",
        &.{ origins_top, secret_value },
        false,
    );
}

test "a recursive call returns the summary's write through a local object" {
    try expectSecret(
        "function f(s) { const o = { out: \"c\" }; function r(p, n, x, y) { if (n) { p.out = x; return 0; } r(p, true, y, y); return p.out; } return r(o, false, \"c\", s); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { const o = { out: \"c\" }; function r(p, n, x, y) { if (n) { p.out = x; return 0; } r(p, true, y, y); return p.out; } return r(o, false, \"c\", \"d\"); }",
        &.{secret_value},
        false,
    );
}

test "a recursive call returns the summary's write through a captured binding" {
    try expectSecret(
        "function f(s) { let out = \"c\"; function r(n, x, y) { if (n) { out = x; return 0; } r(true, y, y); return out; } return r(false, \"c\", s); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { let out = \"c\"; function r(n, x, y) { if (n) { out = x; return 0; } r(true, y, y); return out; } return r(false, \"c\", \"d\"); }",
        &.{secret_value},
        false,
    );
}

test "a capture written in one recursive pass is read in a later one" {
    try expectSecret(
        "function f(s) { let r = \"c\"; function rec(n) { const out = r; if (n) { return out; } r = s; return rec(true); } return rec(false); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { let r = \"c\"; function rec(n) { const out = r; if (n) { return out; } r = \"d\"; return rec(true); } return rec(false); }",
        &.{secret_value},
        false,
    );
}

test "mutual recursion through a captured binding converges" {
    try expectSecret(
        "function f(s) { let b; function a(n, x) { if (n) { return x; } return b(true, s); } b = (n, x) => a(n, x); return a(false, \"c\"); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { let b; function a(n, x) { if (n) { return x; } return b(true, \"d\"); } b = (n, x) => a(n, x); return a(false, \"c\"); }",
        &.{secret_value},
        false,
    );
}

test "recursion through a callable set converges" {
    try expectSecret(
        "function f(c, s) { let g = (n, x) => \"c\"; function a(n, x) { if (n) { return x; } return g(true, s); } g = c ? a : g; return g(false, \"c\"); }",
        &c_secret,
        true,
    );
    try expectSecret(
        "function f(c, s) { let g = (n, x) => \"c\"; function a(n, x) { if (n) { return x; } return g(true, \"d\"); } g = c ? a : g; return g(false, \"c\"); }",
        &c_secret,
        false,
    );
}

test "recursion inside a loop with break and continue after it" {
    try expectSecret(
        "function f(s) { function r(n, x) { if (n) { return x; } return r(true, s); } let out = \"c\"; for (const v of [false, true]) { out = r(false, \"c\"); if (v) { break; } continue; } return out; }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { function r(n, x) { if (n) { return x; } return r(true, \"d\"); } let out = \"c\"; for (const v of [false, true]) { out = r(false, \"c\"); if (v) { break; } continue; } return out; }",
        &.{secret_value},
        false,
    );
}

test "a labelled callee labels the call's value" {
    try expectSecret("function f(s) { const a = () => \"c\"; const g = s || a; return g(); }", &.{secret_value}, true);
    try expectSecret("function f(s) { const a = () => \"c\"; const g = \"d\" || a; return g(); }", &.{secret_value}, false);
}

test "a known callable joined with an unknown one is an unknown callee" {
    const source = "function f(c, g) { const h = c ? (() => \"c\") : g; return h(); }";
    const unknown = try analyzeSource(source, "f", &.{ Value.clean, Value.top });
    defer unknown.deinit();
    try expectUnresolved(unknown.result, .call, .unknown_callee);

    // The contrast: the same join with a known function resolves.
    try expectSecret(
        "function f(c, g) { const k = () => \"d\"; const h = c ? (() => \"c\") : k; return h(); }",
        &.{ Value.clean, Value.clean },
        false,
    );
}

test "a call through a property dispatches to the stored function or the builtin" {
    // A callback method of an array resolves.
    try expectSecret("function f(s) { const a = [() => \"c\"]; return a.map(() => s)[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { const a = [() => \"c\"]; return a.map(() => \"c\")[0]; }", &.{secret_value}, false);

    // The method of a native Result with the same name has no rule.
    const result_method = try analyzeSource(
        "function f(s) { return JSON.parse(s).map(() => \"c\")[0]; }",
        "f",
        &.{secret_value},
    );
    defer result_method.deinit();
    try expectUnresolved(result_method.result, .call, .no_operation_rule);

    // A function stored in a property runs, by name and by literal key.
    try expectSecret("function f(s) { const o = { m: () => \"c\" }; return o.m(); }", &.{secret_value}, false);
    try expectSecret("function f(s) { const o = { m: () => \"c\" }; return o[\"m\"](); }", &.{secret_value}, false);

    // The contrast: the same function called through a name resolves.
    try expectSecret("function f(s) { const m = () => \"c\"; return m(); }", &.{secret_value}, false);
}

test "a method read into a variable is an unknown callee" {
    const extracted = try analyzeSource(
        "function f(c, s) { const x = c ? { slice: () => \"c\" } : s; const g = x.slice; return g(); }",
        "f",
        &c_secret,
    );
    defer extracted.deinit();
    try expectUnresolved(extracted.result, .call, .unknown_callee);

    // The contrast: a function held in a variable resolves.
    try expectSecret(
        "function f(c, s) { const x = c ? () => \"c\" : () => \"d\"; const g = x; return g(); }",
        &c_secret,
        false,
    );
}

test "a call with no callable has no operation rule" {
    const empty = try analyzeSource("function f(x) { return x(1); }", "f", &.{Value.clean});
    defer empty.deinit();
    try expectUnresolved(empty.result, .call, .no_operation_rule);

    try expectSecret("function f(x) { function id(y) { return y; } return id(1); }", &.{Value.clean}, false);
}

test "call-site spread is refused by the strict checker" {
    const spread = try analyzeSource("function f(g, xs) { return g(...xs); }", "f", &.{ Value.clean, Value.clean });
    defer spread.deinit();
    try expectUnresolved(spread.result, .spread, .refused_by_strict);

    // The same call with a local callee is refused too, and a plain argument
    // to that callee is not.
    const local = try analyzeSource(
        "function f(xs) { function id(y) { return y; } return id(...xs); }",
        "f",
        &.{Value.clean},
    );
    defer local.deinit();
    try expectUnresolved(local.result, .spread, .refused_by_strict);
    try expectSecret("function f(xs) { function id(y) { return y; } return id(xs); }", &.{Value.clean}, false);
}

test "a nested root seeds the cells of the bindings it captures with top" {
    const source = "function outer(s) { function inner(c) { if (c) { s = \"c\"; } return s; } return inner; }";
    const h = try Harness.create(testing.allocator, source);
    defer h.destroy();
    const result = try h.analyze("inner", &.{Value.clean});
    try expectUnresolved(result, .function_decl, .capture_unseeded);
    try testing.expect(result.returned.?.labels.unknown);

    // The record is made once, however many captures the root has.
    var seeded: usize = 0;
    for (result.unresolved) |entry| {
        if (entry.owner == .capture_unseeded) seeded += 1;
    }
    try testing.expectEqual(@as(usize, 1), seeded);

    // The contrast: the function that declares the capture seeds it itself.
    const whole = try h.analyze("outer", &.{secret_value});
    try testing.expect(!whole.cleared);
}

test "the step budget is per root and fails closed" {
    const source = "function id(x) { return x; } function f(s) { let r = \"c\"; for (const v of [s, s]) { r = id(v); r = id(r); } return r; } function g(s) { return id(s); }";
    const h = try Harness.create(testing.allocator, source);
    defer h.destroy();

    const whole = try h.analyze("f", &.{secret_value});
    try testing.expect(!whole.cleared);
    try testing.expect(whole.returned.?.labels.secret);
    const needed = h.interp.steps;
    try testing.expect(needed > 0);

    h.interp.max_steps = needed - 1;
    const starved = try h.analyze("f", &.{secret_value});
    try testing.expect(starved.cleared);
    var budget_entries: usize = 0;
    for (starved.unresolved) |entry| {
        if (entry.owner == .budget_limit) budget_entries += 1;
    }
    try testing.expectEqual(@as(usize, 1), budget_entries);
    try testing.expect(starved.returned.?.labels.unknown);
    try testing.expectEqual(@as(usize, 0), starved.completions.len);

    // The counter restarts with the next root, and the smaller root fits.
    const small = try h.analyze("g", &.{secret_value});
    try testing.expect(!small.cleared);
    try testing.expect(valueEql(small.returned.?, secret_value));
    try testing.expect(h.interp.steps < needed - 1);

    // The limit itself is enough.
    h.interp.max_steps = needed;
    const exact = try h.analyze("f", &.{secret_value});
    try testing.expect(!exact.cleared);
}

test "calls that double at every level exhaust the default budget and fail closed" {
    const levels = 24;
    const source = comptime blk: {
        var text: []const u8 = "function f(s) { function g0(x) { return x; } ";
        for (1..levels) |i| {
            text = text ++ std.fmt.comptimePrint("function g{d}(x) {{ return g{d}(x) + g{d}(x); }} ", .{ i, i - 1, i - 1 });
        }
        break :blk text ++ std.fmt.comptimePrint("return g{d}(s); }}", .{levels - 1});
    };
    const r = try analyzeSource(source, "f", &.{secret_value});
    defer r.deinit();
    try testing.expect(r.result.cleared);
    try testing.expect(r.harness.interp.steps > default_max_steps);
    var budget_entries: usize = 0;
    for (r.result.unresolved) |entry| {
        if (entry.owner == .budget_limit) budget_entries += 1;
    }
    try testing.expectEqual(@as(usize, 1), budget_entries);
}

test "the recursion cap clears the result and convergence beats the cap" {
    const source = "function f(s) { function r(n, acc) { if (n) { return acc; } return r(true, s); } return r(false, \"c\"); }";
    const h = try Harness.create(testing.allocator, source);
    defer h.destroy();
    const roomy = try h.analyze("f", &.{secret_value});
    try testing.expect(!roomy.cleared);
    try testing.expect(roomy.returned.?.labels.secret);
    const passes = h.interp.recursion_passes_peak;
    try testing.expect(passes >= 2);

    const capped = try Harness.create(testing.allocator, source);
    defer capped.destroy();
    capped.interp.max_recursion_passes = 1;
    try expectUnresolved(try capped.analyze("f", &.{secret_value}), .function_expr, .fixpoint_limit);

    // A cap below 1 is treated as 1.
    const zero = try Harness.create(testing.allocator, source);
    defer zero.destroy();
    zero.interp.max_recursion_passes = 0;
    try expectUnresolved(try zero.analyze("f", &.{secret_value}), .function_expr, .fixpoint_limit);

    const short = try Harness.create(testing.allocator, source);
    defer short.destroy();
    short.interp.max_recursion_passes = passes - 1;
    try expectUnresolved(try short.analyze("f", &.{secret_value}), .function_expr, .fixpoint_limit);

    // Convergence on the last permitted pass is convergence.
    const exact = try Harness.create(testing.allocator, source);
    defer exact.destroy();
    exact.interp.max_recursion_passes = passes;
    const converged = try exact.analyze("f", &.{secret_value});
    try testing.expect(!converged.cleared);
    try testing.expect(converged.returned.?.labels.secret);
}

test "a capture cell is not an object and a read through an unnamed origin skips it" {
    // `p` stands for any object. The captured `r` holds the secret, and a
    // read of `p.x` must not see it: no value points at a capture cell.
    const origins_top: Value = .{ .origins_top = true };
    try expectSecret(
        "function f(p, s) { let r = s; const g = () => r; return p.x; }",
        &.{ origins_top, secret_value },
        false,
    );
    try expectSecret(
        "function f(p, s) { let r = s; const g = () => r; return g(); }",
        &.{ origins_top, secret_value },
        true,
    );
}

// --- builtin globals and operations (P5a) ---
//
// These sources are internal evaluator fixtures. `s` is seeded secret. Each
// secret test has a contrast in which a literal replaces the secret, so the
// result is clean. Test 25 of the P5 specification is test 51, in the P5c
// section: `map` is the only name that `Array.prototype` and
// `Result.prototype` share.

/// Run `f` and require a result whose `returned` carries exactly the labels in
/// `expected`, with the result resolved.
fn expectLabels(source: []const u8, params: []const Value, expected: LabelSet) !void {
    const r = try analyzeSource(source, "f", params);
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expectEqual(@as(u16, @bitCast(expected)), @as(u16, @bitCast(r.returnedLabels())));
}

// P5 specification test 1.
test "a user method runs through a property call" {
    try expectSecret("function f(s) { const o = { m: () => s }; return o.m(); }", &.{secret_value}, true);
    try expectSecret("function f(s) { const o = { m: () => \"c\" }; return o.m(); }", &.{secret_value}, false);
}

// P5 specification test 2.
test "the string candidate runs beside a user method" {
    try expectSecret("function f(s) { const o = { slice: () => \"c\" }; return o.slice(s); }", &.{secret_value}, true);
    try expectSecret("function f(s) { const o = { slice: () => \"c\" }; return o.slice(\"d\"); }", &.{secret_value}, false);
}

// P5 specification test 3.
test "a string method carries its receiver and its arguments" {
    try expectSecret("function f(s) { return \"a\".concat(s); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return \"a\".concat(\"b\"); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return s.slice(1); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return s.slice(1); }", &.{Value.clean}, false);
}

// P5 specification test 4.
test "split makes an array of labelled pieces" {
    try expectSecret("function f(s) { const p = s.split(\",\"); return p[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { const p = \"a,b\".split(\",\"); return p[0]; }", &.{secret_value}, false);
}

// P5 specification test 5.
test "push writes its argument into the receiver" {
    try expectSecret("function f(s) { const xs = []; xs.push(s); return xs[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { const xs = []; xs.push(\"c\"); return xs[0]; }", &.{secret_value}, false);
    try expectSecret("function f(s) { const xs = []; xs.unshift(s); return xs[0]; }", &.{secret_value}, true);
}

// P5 specification test 6.
test "pop returns an element of the receiver" {
    try expectSecret("function f(s) { return [s].pop(); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [\"c\"].pop(); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return [s].shift(); }", &.{secret_value}, true);
    // An element in a named cell is not in the summary that a read of `pop`
    // itself sees, so only the rule can return it.
    try expectSecret("function f(s) { const a = []; a[\"0\"] = s; return a.pop(); }", &.{secret_value}, true);
    try expectSecret("function f(s) { const a = []; a[\"0\"] = \"c\"; return a.pop(); }", &.{secret_value}, false);
}

// P5 specification test 7.
test "splice writes its selectors and its items and returns the removed elements" {
    // The labelled selector decides which element stays at index 0.
    try expectSecret("function f(s) { const a = [\"A\", \"B\"]; a.splice(s, 1); return a[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { const a = [\"A\", \"B\"]; a.splice(0, 1); return a[0]; }", &.{secret_value}, false);
    // An item from argument 2 on is written.
    try expectSecret("function f(s) { const a = [\"A\", \"B\"]; a.splice(0, 1, s); return a[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { const a = [\"A\", \"B\"]; a.splice(0, 1, \"C\"); return a[0]; }", &.{secret_value}, false);
    // The removed elements come back in a fresh array.
    try expectSecret("function f(s) { return [s].splice(0, 1)[0]; }", &.{secret_value}, true);
}

// P5 specification test 8.
test "join, indexOf, and includes read the elements of the receiver" {
    try expectSecret("function f(s) { return [s].join(\",\"); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [s].indexOf(\"x\"); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [s].includes(\"x\"); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [\"c\"].join(\",\"); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return [\"c\"].indexOf(\"x\"); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return [\"c\"].includes(\"x\"); }", &.{secret_value}, false);
    // The same with the element in a named cell.
    try expectSecret("function f(s) { const a = []; a[\"0\"] = s; return a.join(\",\"); }", &.{secret_value}, true);
    try expectSecret("function f(s) { const a = []; a[\"0\"] = s; return a.indexOf(\"x\"); }", &.{secret_value}, true);
    try expectSecret("function f(s) { const a = []; a[\"0\"] = \"c\"; return a.join(\",\"); }", &.{secret_value}, false);
}

// P5 specification test 9.
test "concat copies the elements of an array argument" {
    const source = "function f(s) { const g = () => s; const a = [].concat([g]); const h = a[\"0\"]; return h(); }";
    try expectSecret(source, &.{secret_value}, true);
    const clean = "function f(s) { const g = () => \"c\"; const a = [].concat([g]); const h = a[\"0\"]; return h(); }";
    try expectSecret(clean, &.{secret_value}, false);
}

// P5 specification test 10.
test "JSON and a nested container carry their labels and keep a location" {
    try expectSecret("function f(s) { return JSON.stringify({ x: s }); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return JSON.stringify({ x: 1 }); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return JSON.parse(s).x; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return JSON.parse(\"{}\").x; }", &.{secret_value}, false);

    // The nested container has a location, so a write to it lands in the site.
    const nested = "function f(s) { const p = JSON.parse(\"[[1]]\"); const q = p[\"0\"]; q[\"0\"] = s; return p[\"0\"][\"0\"]; }";
    try expectSecret(nested, &.{secret_value}, true);
    const clean_nested = "function f(s) { const p = JSON.parse(\"[[1]]\"); const q = p[\"0\"]; q[\"0\"] = \"c\"; return p[\"0\"][\"0\"]; }";
    try expectSecret(clean_nested, &.{secret_value}, false);

    const inner = try analyzeSource("function f(s) { const p = JSON.parse(\"[[1]]\"); const q = p[\"0\"]; return q; }", "f", &.{secret_value});
    defer inner.deinit();
    const q = inner.result.returned.?;
    try testing.expect(q.origins.len > 0);
    try testing.expect(!q.origins_top);
}

// P5 specification test 11.
test "Object.keys, values, and entries carry what the object holds" {
    try expectSecret("function f(s) { const o = {}; o[s] = \"x\"; return Object.keys(o)[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { const o = {}; o[\"k\"] = \"x\"; return Object.keys(o)[0]; }", &.{secret_value}, false);
    try expectSecret("function f(s) { return Object.values({ x: s })[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return Object.values({ x: \"c\" })[0]; }", &.{secret_value}, false);
    try expectSecret("function f(s) { return Object.entries({ x: s })[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return Object.entries({ x: \"c\" })[0]; }", &.{secret_value}, false);
}

// P5 specification test 12.
test "a spread of a native function keeps the implicit native value" {
    const r = try analyzeSource("function f(s) { const o = { ...Response }; const g = o.json; return g(); }", "f", &.{secret_value});
    defer r.deinit();
    try expectUnresolved(r.result, .call, .unknown_callee);

    // The contrast: a spread of a plain object has no native method.
    try expectSecret("function f(s) { const o = { ...{ a: \"c\" } }; return o.a; }", &.{secret_value}, false);
}

// P5 specification test 13.
test "a call on a receiver of unknown origin is an unknown callee" {
    const unnamed: Value = .{ .origins_top = true };
    const r = try analyzeSource("function f(p) { return p.foo(); }", "f", &.{unnamed});
    defer r.deinit();
    try expectUnresolved(r.result, .call, .unknown_callee);
}

// P5 specification test 14.
test "a call through a dynamic method key is an unknown callee" {
    const r = try analyzeSource("function f(o, k) { return o[k](); }", "f", &.{ Value.clean, Value.clean });
    defer r.deinit();
    try expectUnresolved(r.result, .call, .unknown_callee);

    // A numeric literal names no method either.
    const index = try analyzeSource("function f(o) { return o[0](); }", "f", &.{Value.clean});
    defer index.deinit();
    try expectUnresolved(index.result, .call, .unknown_callee);
}

// P5 specification test 15.
test "an optional call keeps the state of the skip path" {
    try expectSecret(
        "function f(s) { let x = s; const o = { slice: () => \"c\" }; o?.slice((x = \"c\")); return x; }",
        &.{secret_value},
        true,
    );
    // The contrast: the same call without the optional chain always assigns.
    try expectSecret(
        "function f(s) { let x = s; const o = { slice: () => \"c\" }; o.slice((x = \"c\")); return x; }",
        &.{secret_value},
        false,
    );
}

// P5 specification test 16.
test "a write to a shared runtime object is a P8 write" {
    const math = try analyzeSource("function f(s) { Math.x = s; return 1; }", "f", &.{secret_value});
    defer math.deinit();
    try expectUnresolved(math.result, .assignment, .p8);

    const alias = try analyzeSource("function f(s) { const g = parseInt; g.x = s; return 1; }", "f", &.{secret_value});
    defer alias.deinit();
    try expectUnresolved(alias.result, .assignment, .p8);

    // The contrast: a write to a local object is resolved.
    try expectSecret("function f(s) { const o = {}; o.x = s; return 1; }", &.{secret_value}, false);
}

// P5 specification test 17.
test "an unknown global is refused by the strict checker" {
    const r = try analyzeSource("function f(s) { return foo; }", "f", &.{secret_value});
    defer r.deinit();
    try expectUnresolved(r.result, .identifier, .refused_by_strict);

    // A known global that no rule models has no operation rule.
    const boolean = try analyzeSource("function f(s) { return Boolean; }", "f", &.{secret_value});
    defer boolean.deinit();
    try expectUnresolved(boolean.result, .identifier, .no_operation_rule);
}

// P5 specification test 18.
test "hole never returns" {
    const r = try analyzeSource("function f(s) { return hole() + s; }", "f", &.{secret_value});
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expect(r.result.returned == null);
    try testing.expectEqual(@as(usize, 0), r.result.completions.len);
    try testing.expect(!r.result.exit.reachable);

    // The contrast: an ordinary call lets the caller go on.
    try expectSecret("function f(s) { return parseInt(\"1\") + s; }", &.{secret_value}, true);
}

// P5 specification test 19.
test "clock and random reads carry nondeterministic" {
    const nondeterministic: LabelSet = .{ .nondeterministic = true };
    try expectLabels("function f(s) { return Math.random(); }", &.{secret_value}, nondeterministic);
    try expectLabels("function f(s) { return Date.now(); }", &.{secret_value}, nondeterministic);
    try expectLabels("function f(s) { return Math.pow(2, 3); }", &.{secret_value}, .empty);
}

// P5 specification test 20.
test "a Result method with a callback has no operation rule" {
    const sources = [_][]const u8{
        "function f(s) { return JSON.parse(s).map((x) => x); }",
        "function f(s) { return JSON.parse(s).mapErr((x) => x); }",
        "function f(s) { return JSON.parse(s).andThen((x) => x); }",
        "function f(s) { return JSON.parse(s).match((x) => x); }",
    };
    inline for (sources) |source| {
        const r = try analyzeSource(source, "f", &.{secret_value});
        defer r.deinit();
        try expectUnresolved(r.result, .call, .no_operation_rule);
    }

    // The contrast: a sort with no comparator has a rule.
    try expectSecret("function f(s) { return [s].toSorted()[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [\"c\"].toSorted()[0]; }", &.{secret_value}, false);
}

// P5 specification test 21.
test "a property read adds a native function only where the runtime may find one" {
    // An object literal's own field is not a method.
    const own = try analyzeSource("function f() { const o = { handler: () => 1 }; return o.handler; }", "f", &.{});
    defer own.deinit();
    try testing.expect(!own.result.returned.?.callables_top);
    try testing.expectEqual(@as(usize, 1), own.result.returned.?.callables.len);

    // A name that String.prototype holds may be a method of a joined value.
    const method = try analyzeSource("function f() { const o = { handler: () => 1 }; return o.slice; }", "f", &.{});
    defer method.deinit();
    try testing.expect(method.result.returned.?.callables_top);

    // A stored callables_top survives a read of any name.
    const unknown_function: Value = .{ .callables_top = true };
    const stored = try analyzeSource("function f(g) { const o = { handler: g }; return o.handler; }", "f", &.{unknown_function});
    defer stored.deinit();
    try testing.expect(stored.result.returned.?.callables_top);

    // A name that no builtin holds, on a receiver that holds no native
    // method, reads nothing but the stored content.
    const other = try analyzeSource("function f() { const o = { handler: () => 1 }; return o.other; }", "f", &.{});
    defer other.deinit();
    try testing.expect(!other.result.returned.?.callables_top);
    try testing.expectEqual(@as(usize, 0), other.result.returned.?.callables.len);

    // A key that is not a literal may name a method.
    const dynamic = try analyzeSource("function f(k) { const o = { handler: () => 1 }; return o[k]; }", "f", &.{Value.clean});
    defer dynamic.deinit();
    try testing.expect(dynamic.result.returned.?.callables_top);

    // A numeric literal names no method.
    const indexed = try analyzeSource("function f() { const o = [() => 1]; return o[0]; }", "f", &.{});
    defer indexed.deinit();
    try testing.expect(!indexed.result.returned.?.callables_top);
}

// P5 specification test 22.
test "a user Math does not replace a call that compiles to an opcode" {
    const user_math = "const Math = { floor: (x) => \"c\" }; ";
    try expectSecret(user_math ++ "function f(s) { return Math.floor(s); }", &.{secret_value}, true);
    try expectSecret(user_math ++ "function f(s) { return Math.floor(\"d\"); }", &.{secret_value}, false);
    try expectSecret(user_math ++ "function f(s) { return Math.max(s, 1); }", &.{secret_value}, true);
}

// P5 specification test 23.
test "a method call on a Response result has no operation rule" {
    const r = try analyzeSource("function f(s) { return Response.json(s).text(); }", "f", &.{secret_value});
    defer r.deinit();
    try expectUnresolved(r.result, .call, .no_operation_rule);

    // The static call itself has a rule, and its result carries the argument.
    try expectSecret("function f(s) { return Response.json(s); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return Response.json(\"c\"); }", &.{secret_value}, false);
}

test "reach sees the cells of a write through an unnamed target" {
    // `p` may be any object, so the write lands in `top_cell`. `o.inner` is
    // `p`, and serializing `o` reaches what was written through it.
    const unnamed: Value = .{ .origins_top = true };
    try expectSecret(
        "function f(p, s) { p.x = s; const o = { inner: p }; return JSON.stringify(o); }",
        &.{ unnamed, secret_value },
        true,
    );
    try expectSecret(
        "function f(p, s) { p.x = \"c\"; const o = { inner: p }; return JSON.stringify(o); }",
        &.{ unnamed, secret_value },
        false,
    );
}

// P5 specification test 24.
test "a call of a builtin namespace member stays resolved and clean" {
    try expectSecret("function f(s) { return JSON.stringify({ x: 1 }); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return Number.isInteger(1); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return String.fromCharCode(65); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return Array.isArray([s]); }", &.{secret_value}, true);
}

test "a builtin global function uses its row" {
    try expectSecret("function f(s) { return parseInt(s); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return parseInt(\"1\"); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return String(s); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return Number(\"1\"); }", &.{secret_value}, false);
    try expectSecret("function f(s) { return isDict(s); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return range(s)[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return range(3)[0]; }", &.{secret_value}, false);
    try expectSecret("function f(s) { return requestJson(s)[\"x\"]; }", &.{secret_value}, true);

    // A module declaration of the same name replaces the builtin.
    const own = try analyzeSource("function parseInt(x) { return \"c\"; } function f(s) { return parseInt(s); }", "f", &.{secret_value});
    defer own.deinit();
    try testing.expect(!own.result.cleared);
    try testing.expect(own.returnedLabels().isEmpty());

    // Response is a function too: a direct call may reach any function.
    const response = try analyzeSource("function f(s) { return Response(s); }", "f", &.{secret_value});
    defer response.deinit();
    try expectUnresolved(response.result, .call, .unknown_callee);

    // A namespace that is not a function has no operation rule when called.
    const json = try analyzeSource("function f(s) { return JSON(s); }", "f", &.{secret_value});
    defer json.deinit();
    try expectUnresolved(json.result, .call, .no_operation_rule);
}

/// What `censusBuiltins` found: the known globals that exist, the callable
/// properties it enumerated, and the rows it matched.
const BuiltinCensus = struct { globals: usize, properties: usize, rows: usize };

const BuiltinCensusError = error{
    /// A callable global has neither a row nor a callable-namespace entry.
    GlobalWithoutRow,
    /// A global row names a global that is missing or not callable.
    RowWithoutGlobal,
    /// A callable property has no row.
    PropertyWithoutRow,
    /// A row names no callable property.
    RowWithoutProperty,
    /// A callable property has no name.
    UnnamedProperty,
    /// A `no_rule` row states no reason.
    RowWithoutReason,
};

/// Check `rows` against the builtins registered in `ctx`, in both directions.
fn censusBuiltins(ctx: *engine.context.Context, rows: []const OperationRow) (BuiltinCensusError || std.mem.Allocator.Error)!BuiltinCensus {
    const used = try testing.allocator.alloc(bool, rows.len);
    defer testing.allocator.free(used);
    @memset(used, false);
    var globals: usize = 0;
    var properties: usize = 0;

    // Globals: every callable known global is a global-function row or a
    // callable namespace, and every global row names a callable global.
    for (known_globals.names) |name| {
        const atom = try ctx.atoms.intern(name);
        const value = ctx.getGlobal(atom) orelse continue;
        globals += 1;
        if (!value.isCallable()) continue;
        const row_index = rowIndex(rows, "global", name);
        if (row_index == null and !nameIn(&callable_namespaces, name)) return error.GlobalWithoutRow;
        if (row_index) |i| used[i] = true;
    }
    for (rows, used) |row, was_used| {
        if (std.mem.eql(u8, row.scope, "global") and !was_used) return error.RowWithoutGlobal;
    }

    // Properties: every callable own property of a namespace and of the three
    // prototypes has a row, and every row names one.
    const pool = ctx.hidden_class_pool orelse return error.PropertyWithoutRow;
    const prototypes = [_]struct { scope: []const u8, object: ?*object.JSObject }{
        .{ .scope = "Array.prototype", .object = ctx.array_prototype },
        .{ .scope = "String.prototype", .object = ctx.string_prototype },
        .{ .scope = "Result.prototype", .object = ctx.result_prototype },
    };
    for (prototypes) |prototype| {
        const holder = prototype.object orelse continue;
        properties += try censusProperties(ctx, pool, rows, used, prototype.scope, holder);
    }
    for (namespace_names) |name| {
        const value = ctx.getGlobal(try ctx.atoms.intern(name)) orelse continue;
        if (!value.isObject()) continue;
        properties += try censusProperties(ctx, pool, rows, used, name, value.toPtr(object.JSObject));
    }

    var matched: usize = 0;
    for (rows, used) |row, was_used| {
        if (!was_used) return error.RowWithoutProperty;
        if (row.rule == .no_rule and row.reason.len == 0) return error.RowWithoutReason;
        matched += 1;
    }
    return .{ .globals = globals, .properties = properties, .rows = matched };
}

fn rowIndex(rows: []const OperationRow, scope: []const u8, name: []const u8) ?usize {
    for (rows, 0..) |row, i| {
        if (std.mem.eql(u8, row.scope, scope) and std.mem.eql(u8, row.name, name)) return i;
    }
    return null;
}

/// The callable own properties of `holder`, each marked in `used`.
fn censusProperties(
    ctx: *engine.context.Context,
    pool: *const object.HiddenClassPool,
    rows: []const OperationRow,
    used: []bool,
    scope: []const u8,
    holder: *object.JSObject,
) (BuiltinCensusError || std.mem.Allocator.Error)!usize {
    var count: usize = 0;
    var it = holder.propertyIterator(pool);
    while (it.next()) |entry| {
        if (!entry.value.isCallable()) continue;
        count += 1;
        const name = ctx.atoms.getName(entry.atom) orelse return error.UnnamedProperty;
        const i = rowIndex(rows, scope, name) orelse return error.PropertyWithoutRow;
        used[i] = true;
    }
    return count;
}

// P5 specification test 26.
test "census C1: every registered builtin has a row and every row names a builtin" {
    var arena_owner = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_owner.deinit();
    const allocator = arena_owner.allocator();
    var gc_state = try engine.gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try engine.context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();
    try engine.builtins.initBuiltins(ctx);

    const counts = try censusBuiltins(ctx, &operation_rows);
    std.debug.print(
        "flow_interp builtin census: {d} known globals found, {d} callable properties, {d} rows\n",
        .{ counts.globals, counts.properties, counts.rows },
    );
    // A floor on the input: a census that enumerated nothing would pass.
    try testing.expect(counts.globals >= 19);
    try testing.expect(counts.properties >= 87);
    try testing.expectEqual(operation_rows.len, counts.rows);
    // Every property belongs to one row, and a global function has a row of
    // its own, so the rows cover the properties and the global functions.
    try testing.expect(counts.rows >= counts.properties);

    // A probe that removes one row must fail. `String` and `Number` are also
    // callable namespaces, so removing their global row leaves a census that
    // still holds; every other row is tested.
    for (operation_rows, 0..) |row, skipped| {
        const global_namespace = std.mem.eql(u8, row.scope, "global") and nameIn(&callable_namespaces, row.name);
        if (global_namespace) continue;
        const without = try allocator.alloc(OperationRow, operation_rows.len - 1);
        @memcpy(without[0..skipped], operation_rows[0..skipped]);
        @memcpy(without[skipped..], operation_rows[skipped + 1 ..]);
        // A global function without a row is a callable global with no row.
        const expected = if (std.mem.eql(u8, row.scope, "global")) error.GlobalWithoutRow else error.PropertyWithoutRow;
        try testing.expectError(expected, censusBuiltins(ctx, without));
    }

    // A row that names nothing registered fails the other direction.
    const extra = try allocator.alloc(OperationRow, operation_rows.len + 1);
    @memcpy(extra[0..operation_rows.len], &operation_rows);
    extra[operation_rows.len] = .{ .scope = "Math", .name = "noSuchMember", .rule = .deep_scalar, .defense = .keep };
    try testing.expectError(error.RowWithoutProperty, censusBuiltins(ctx, extra));

    // A global row for a name that is not a global fails too.
    extra[operation_rows.len] = .{ .scope = "global", .name = "noSuchGlobal", .rule = .deep_scalar, .defense = .keep };
    try testing.expectError(error.RowWithoutGlobal, censusBuiltins(ctx, extra));

    // A row with no rule states its reason.
    const silent = try allocator.dupe(OperationRow, &operation_rows);
    for (silent) |*row| {
        if (row.rule == .no_rule) row.reason = "";
    }
    try testing.expectError(error.RowWithoutReason, censusBuiltins(ctx, silent));

    // After P5c the only rows with no rule are the methods of a native Result,
    // and the only rows with a callback reason are its four callback methods.
    var without_rule: usize = 0;
    var callback_rows: usize = 0;
    for (operation_rows) |row| {
        if (row.rule == .no_rule) {
            without_rule += 1;
            try testing.expectEqualStrings("Result.prototype", row.scope);
        }
        if (std.mem.eql(u8, row.reason, callback_reason)) {
            callback_rows += 1;
            try testing.expectEqualStrings("Result.prototype", row.scope);
            try testing.expect(nameIn(&.{ "map", "mapErr", "andThen", "match" }, row.name));
        }
    }
    try testing.expectEqual(@as(usize, 9), without_rule);
    try testing.expectEqual(@as(usize, 4), callback_rows);
}

// --- P5b: the calls of virtual-module exports ---

const user_input_value = Value.labelled(.{ .user_input = true });

/// Run `f` and require a resolved result whose returned `secret` flag is
/// `expected`. Other labels may be present.
fn expectSecretBit(source: []const u8, params: []const Value, expected: bool) !void {
    const r = try analyzeSource(source, "f", params);
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expectEqual(expected, r.returnedLabels().secret);
}

// P5 specification test 27.
test "an identity export carries the secret of its argument" {
    const text = "import { unescapeHtml } from \"zttp:text\"; ";
    try expectSecret(text ++ "function f(s) { return unescapeHtml(s); }", &.{secret_value}, true);
    try expectSecret(text ++ "function f(s) { return unescapeHtml(\"c\"); }", &.{secret_value}, false);

    // The local name may differ from the exported one.
    const alias = "import { unescapeHtml as plain } from \"zttp:text\"; ";
    try expectSecret(alias ++ "function f(s) { return plain(s); }", &.{secret_value}, true);

    // A local binding of the same name is the local function, not the export.
    try expectSecret(
        text ++ "function f(s) { const unescapeHtml = (x) => \"c\"; return unescapeHtml(s); }",
        &.{secret_value},
        false,
    );
}

// P5 specification test 28.
test "an export that answers a fact about its argument carries a nested secret" {
    const collections = "import { dictHas } from \"zttp:collections\"; ";
    try expectSecret(collections ++ "function f(s) { return dictHas({ x: s }, \"x\"); }", &.{secret_value}, true);
    try expectSecret(collections ++ "function f(s) { return dictHas({ x: \"c\" }, \"x\"); }", &.{secret_value}, false);
}

// P5 specification test 29.
test "mask declassifies under a literal bound and an argument that holds no object" {
    const text = "import { mask } from \"zttp:text\"; ";
    inline for (.{
        "function f(s) { return mask(s, 4); }",
        "function f(s) { return String(mask(s, 4)); }",
        "function f(s) { return mask(s); }",
    }) |body| {
        const r = try analyzeSource(text ++ body, "f", &.{secret_value});
        defer r.deinit();
        try testing.expect(!r.result.cleared);
        try testing.expect(!r.returnedLabels().secret);
        try testing.expect(r.returnedLabels().internal);
    }

    // A bound that is not a literal keeps the secret, and so does an
    // argument that holds an object, whose cells a declassified summary
    // would drop.
    try expectSecretBit(text ++ "function f(s, n) { return mask(s, n); }", &.{ secret_value, Value.clean }, true);
    try expectSecretBit(text ++ "function f(s, n) { return String(mask(s, n)); }", &.{ secret_value, Value.clean }, true);
    try expectSecretBit(text ++ "function f(s) { return mask({ x: s }, 4); }", &.{secret_value}, true);
}

// P5 specification test 30.
test "env keeps secret for a credential name and gives config for any other" {
    const env = "import { env } from \"zttp:env\"; ";
    try expectLabels(env ++ "function f() { return env(\"API_KEY\"); }", &.{}, secret);
    try expectLabels(env ++ "function f() { return env(\"db_password\"); }", &.{}, secret);
    try expectLabels(env ++ "function f() { return env(\"PORT\"); }", &.{}, .{ .config = true });
    // A name that is not a literal may be any variable.
    try expectLabels(env ++ "function f(n) { return env(n); }", &.{Value.clean}, secret);
}

// P5 specification test 31.
test "an export result aliases the container passed to it" {
    const validate = "import { validateObject } from \"zttp:validate\"; ";
    const write = validate ++ "function f(s) { const o = { x: \"c\" }; const r = validateObject(\"n\", o); r.x = s; return o.x; }";
    try expectSecret(write, &.{secret_value}, true);
    const clean = validate ++ "function f(s) { const o = { x: \"c\" }; const r = validateObject(\"n\", o); r.x = \"c\"; return o.x; }";
    try expectSecret(clean, &.{secret_value}, false);
}

// P5 specification test 32.
test "an export hands back a function stored in its argument" {
    const collections = "import { dictEmpty, dictSet, dictGet } from \"zttp:collections\"; ";
    const stored = collections ++
        "function f(s) { const g = () => s; const h = dictGet(dictSet(dictEmpty(), \"k\", g), \"k\"); return h(); }";
    try expectSecret(stored, &.{secret_value}, true);
    const clean = collections ++
        "function f(s) { const g = () => \"c\"; const h = dictGet(dictSet(dictEmpty(), \"k\", g), \"k\"); return h(); }";
    try expectSecret(clean, &.{secret_value}, false);
}

// P5 specification test 33.
test "routerMatch returns a route handler that runs" {
    const router = "import { routerMatch } from \"zttp:router\"; ";
    const routed = router ++
        "function f(s, req) { const routes = { \"GET /x\": () => s }; const m = routerMatch(routes, req); const h = m.handler; return h(); }";
    try expectSecretBit(routed, &.{ secret_value, Value.clean }, true);
    const clean = router ++
        "function f(s, req) { const routes = { \"GET /x\": () => \"c\" }; const m = routerMatch(routes, req); const h = m.handler; return h(); }";
    try expectSecretBit(clean, &.{ secret_value, Value.clean }, false);
}

// P5 specification test 34.
test "a state reader carries unknown and a clock or random export is nondeterministic" {
    const cache = "import { cacheGet } from \"zttp:cache\"; ";
    const read = try analyzeSource(cache ++ "function f() { return cacheGet(\"ns\", \"k\"); }", "f", &.{});
    defer read.deinit();
    try testing.expect(!read.result.cleared);
    try testing.expect(read.returnedLabels().unknown);

    // The capability half: `uuid` declares a random source.
    const id = "import { uuid } from \"zttp:id\"; ";
    try expectLabels(id ++ "function f() { return uuid(); }", &.{}, .{ .internal = true, .nondeterministic = true });

    // The stateful half: `sqlOne` reads a stateful module and declares no
    // clock or random source.
    const sql = try analyzeSource("import { sqlOne } from \"zttp:sql\"; function f() { return sqlOne(\"q\"); }", "f", &.{});
    defer sql.deinit();
    try testing.expect(sql.returnedLabels().nondeterministic);
}

// P5 specification test 35.
test "a validating export keeps the user input it was given" {
    const validate = "import { validateObject } from \"zttp:validate\"; ";
    const checked = try analyzeSource(validate ++ "function f(u) { return validateObject(\"n\", u); }", "f", &.{user_input_value});
    defer checked.deinit();
    try testing.expect(!checked.result.cleared);
    try testing.expect(checked.returnedLabels().user_input);
    try testing.expect(!checked.returnedLabels().validated);

    // The contrast: with nothing tainted the result carries nothing, because
    // no value carries `validated` (P6).
    try expectLabels(validate ++ "function f(u) { return validateObject(\"n\", {}); }", &.{user_input_value}, .empty);
}

// P5 specification test 36.
test "an export with no precise row runs the closures it was given" {
    // `dictSet` never calls its value, and it has no precise row.
    const collections = "import { dictEmpty, dictSet } from \"zttp:collections\"; ";
    try expectSecret(collections ++ "function f(s) { return dictSet(dictEmpty(), \"k\", () => s); }", &.{secret_value}, true);
    try expectSecret(collections ++ "function f(s) { return dictSet(dictEmpty(), \"k\", () => \"c\"); }", &.{secret_value}, false);

    // A function that the analysis cannot name may be anything.
    const unknown: Value = .{ .callables_top = true };
    const open = try analyzeSource(collections ++ "function f(g) { return dictSet(dictEmpty(), \"k\", g); }", "f", &.{unknown});
    defer open.deinit();
    try expectUnresolved(open.result, .call, .unknown_callee);
}

// P5 specification test 37.
test "a presumed call keeps the flags of what its callbacks returned" {
    const collections = "import { dictEmpty, dictSet } from \"zttp:collections\"; ";
    const source = collections ++ "function f(s) { return dictSet(dictEmpty(), \"k\", () => Number)(s); }";
    const r = try analyzeSource(source, "f", &.{secret_value});
    defer r.deinit();
    try expectUnresolved(r.result, .call, .unknown_callee);
}

// P5 specification test 38.
test "a container nested in an export result has a location" {
    const collections = "import { dictEmpty, dictSet } from \"zttp:collections\"; ";
    const nested = collections ++
        "function f(s) { const r = dictSet(dictEmpty(), \"k\", \"c\"); const q = r[\"k\"]; q[\"x\"] = s; return r[\"k\"][\"x\"]; }";
    try expectSecret(nested, &.{secret_value}, true);
    const clean = collections ++
        "function f(s) { const r = dictSet(dictEmpty(), \"k\", \"c\"); const q = r[\"k\"]; q[\"x\"] = \"c\"; return r[\"k\"][\"x\"]; }";
    try expectSecret(clean, &.{secret_value}, false);

    // The argument is a parameter that holds no object, so only the call's own
    // site can give `q` a location.
    const own_site = collections ++
        "function f(s, d) { const r = dictSet(d, \"k\", \"c\"); const q = r[\"k\"]; q[\"x\"] = s; return r[\"k\"][\"x\"]; }";
    try expectSecret(own_site, &.{ secret_value, Value.clean }, true);
    const own_clean = collections ++
        "function f(s, d) { const r = dictSet(d, \"k\", \"c\"); const q = r[\"k\"]; q[\"x\"] = \"c\"; return r[\"k\"][\"x\"]; }";
    try expectSecret(own_clean, &.{ secret_value, Value.clean }, false);

    const inner = try analyzeSource(
        collections ++ "function f(s, d) { const r = dictSet(d, \"k\", \"c\"); return r[\"k\"]; }",
        "f",
        &.{ secret_value, Value.clean },
    );
    defer inner.deinit();
    const q = inner.result.returned.?;
    try testing.expect(q.origins.len > 0);
    try testing.expect(!q.origins_top);
}

// P5 specification test 39.
test "an import from a user module is module state" {
    const r = try analyzeSource("import { helper } from \"./other.ts\"; function f(s) { return helper(s); }", "f", &.{secret_value});
    defer r.deinit();
    try expectUnresolved(r.result, .identifier, .p8);

    // An import of a name that the module does not export is module state too.
    const missing = try analyzeSource("import { noSuchExport } from \"zttp:text\"; function f(s) { return noSuchExport(s); }", "f", &.{secret_value});
    defer missing.deinit();
    try expectUnresolved(missing.result, .identifier, .p8);
}

test "an export read as a value is a native function value" {
    const collections = "import { dictHas } from \"zttp:collections\"; ";
    const value = try analyzeSource(collections ++ "function f() { return dictHas; }", "f", &.{});
    defer value.deinit();
    try testing.expect(!value.result.cleared);
    const held = value.result.returned.?;
    try testing.expect(held.callables_top);
    try testing.expectEqual(@as(usize, 1), held.origins.len);
    try testing.expectEqual(SiteKind.builtin, held.origins[0].kind);

    // A call through the alias may reach any function.
    const alias = try analyzeSource(collections ++ "function f(s) { const g = dictHas; return g({ x: s }, \"x\"); }", "f", &.{secret_value});
    defer alias.deinit();
    try expectUnresolved(alias.result, .call, .unknown_callee);
}

test "a fetch result is a native container" {
    const fetch = "import { fetch } from \"zttp:fetch\"; ";
    const r = try analyzeSource(fetch ++ "function f(s) { return fetch(s); }", "f", &.{secret_value});
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    const held = r.result.returned.?;
    try testing.expect(held.labels.secret);
    try testing.expect(held.labels.external);
    var native = false;
    for (held.origins) |site| native = native or site.kind == .native;
    try testing.expect(native);

    // A method call on it has no rule, as on a `Response` result.
    const call = try analyzeSource(fetch ++ "function f(s) { return fetch(s).text(); }", "f", &.{secret_value});
    defer call.deinit();
    try expectUnresolved(call.result, .call, .no_operation_rule);
}

test "a presumed callback loop runs again until its parameters stop growing" {
    // The first pass passes clean parameters and returns the secret. The
    // second passes that secret to the callback, which stores it.
    const collections = "import { dictEmpty, dictSet } from \"zttp:collections\"; ";
    const source = collections ++
        "function f(s) { const o = { v: \"c\" }; const g = (x) => { o.v = x; return s; }; dictSet(dictEmpty(), \"k\", g); return o.v; }";
    try expectSecret(source, &.{secret_value}, true);
    const clean = collections ++
        "function f(s) { const o = { v: \"c\" }; const g = (x) => { o.v = x; return \"c\"; }; dictSet(dictEmpty(), \"k\", g); return o.v; }";
    try expectSecret(clean, &.{secret_value}, false);

    // A cap below the need records the limit, and a cap equal to it converges.
    const h = try Harness.create(testing.allocator, source);
    defer h.destroy();
    var needed: u32 = 0;
    var cap: u32 = 1;
    while (cap <= 16) : (cap += 1) {
        h.interp.max_loop_passes = cap;
        const result = try h.analyze("f", &.{secret_value});
        var limited = false;
        for (result.unresolved) |entry| limited = limited or entry.owner == .fixpoint_limit;
        if (!limited) {
            needed = cap;
            break;
        }
    }
    try testing.expect(needed >= 2);
    h.interp.max_loop_passes = needed - 1;
    try expectUnresolved(try h.analyze("f", &.{secret_value}), .call, .fixpoint_limit);
    h.interp.max_loop_passes = needed;
    try testing.expect(!(try h.analyze("f", &.{secret_value})).cleared);
}

// --- P5c: callbacks ---

// An element in a named cell is not in the summary that a read of the method
// name sees, so only the rule can carry it into the result. Each secret test
// that needs the elements uses these two receivers.
const held_secret = "function f(s) { const a = []; a[\"0\"] = s; ";
const held_clean = "function f(s) { const a = []; a[\"0\"] = \"c\"; ";

// P5 specification test 40.
test "map passes each element to its callback and returns the results" {
    try expectSecret("function f(s) { return [s].map((x) => x)[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [\"c\"].map((x) => x)[0]; }", &.{secret_value}, false);
    try expectSecret(held_secret ++ "return a.map((x) => x)[0]; }", &.{secret_value}, true);
    try expectSecret(held_clean ++ "return a.map((x) => x)[0]; }", &.{secret_value}, false);
    // The callback also receives the index and the array.
    try expectSecret(held_secret ++ "return a.map((x, i, y) => y[\"0\"])[0]; }", &.{secret_value}, true);
    try expectSecret(held_clean ++ "return a.map((x, i, y) => y[\"0\"])[0]; }", &.{secret_value}, false);
}

// P5 specification test 41.
test "filter labels its elements with the predicate" {
    try expectSecret("function f(s) { return [\"c\"].filter(() => s)[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [\"c\"].filter(() => \"c\")[0]; }", &.{secret_value}, false);
    try expectSecret(held_secret ++ "return a.filter((x) => true)[0]; }", &.{secret_value}, true);
    try expectSecret(held_clean ++ "return a.filter((x) => true)[0]; }", &.{secret_value}, false);
}

test "find, forEach, every, some, and findIndex carry what their callback sees" {
    try expectSecret("function f(s) { return [\"c\"].find(() => s); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [\"c\"].find(() => \"c\"); }", &.{secret_value}, false);
    try expectSecret(held_secret ++ "return a.find((x) => true); }", &.{secret_value}, true);
    try expectSecret(held_clean ++ "return a.find((x) => true); }", &.{secret_value}, false);

    // `forEach` runs for its writes.
    const each = "function f(s) { const o = { x: \"c\" }; ";
    try expectSecret(each ++ "[s].forEach((x) => { o.x = x; }); return o.x; }", &.{secret_value}, true);
    try expectSecret(each ++ "[\"c\"].forEach((x) => { o.x = x; }); return o.x; }", &.{secret_value}, false);

    inline for (.{ "every", "some", "findIndex" }) |method| {
        try expectSecret("function f(s) { return [\"c\"]." ++ method ++ "(() => s); }", &.{secret_value}, true);
        try expectSecret(held_secret ++ "return a." ++ method ++ "((x) => true); }", &.{secret_value}, true);
        try expectSecret("function f(s) { return [\"c\"]." ++ method ++ "(() => \"c\"); }", &.{secret_value}, false);
        try expectSecret(held_clean ++ "return a." ++ method ++ "((x) => true); }", &.{secret_value}, false);
    }
}

// P5 specification test 42.
test "a later pass of a callback loop sees the writes of an earlier one" {
    try expectSecret(
        "function f(s) { const a = [\"c\"]; const out = a.map((x) => { a.push(s); return x; }); return out[\"0\"]; }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { const a = [\"c\"]; const out = a.map((x) => { a.push(\"c\"); return x; }); return out[\"0\"]; }",
        &.{secret_value},
        false,
    );
}

// P5 specification test 43.
test "reduce joins every result into its accumulator" {
    try expectSecret("function f(s) { return [s].reduce((acc, value) => value, \"c\"); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [\"c\"].reduce((acc, value) => value, \"c\"); }", &.{secret_value}, false);
    try expectSecret(held_secret ++ "return a.reduce((acc, value) => value, \"c\"); }", &.{secret_value}, true);
    try expectSecret(held_clean ++ "return a.reduce((acc, value) => value, \"c\"); }", &.{secret_value}, false);
    // Without an initial value the accumulator starts as the elements.
    try expectSecret(held_secret ++ "return a.reduce((acc, value) => \"c\"); }", &.{secret_value}, true);
    try expectSecret(held_clean ++ "return a.reduce((acc, value) => \"c\"); }", &.{secret_value}, false);
}

// P5 specification test 44.
test "a comparator sees two elements and labels the sorted copy" {
    const sort = "function f(s) { const o = { x: \"c\" }; ";
    try expectSecret(sort ++ "[s].toSorted((a, b) => { o.x = a; return 0; }); return o.x; }", &.{secret_value}, true);
    try expectSecret(sort ++ "[s].toSorted((a, b) => { o.x = b; return 0; }); return o.x; }", &.{secret_value}, true);
    try expectSecret(sort ++ "[\"c\"].toSorted((a, b) => { o.x = b; return 0; }); return o.x; }", &.{secret_value}, false);
    try expectSecret("function f(s) { return [\"c\"].toSorted(() => s)[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return [\"c\"].toSorted(() => 0)[0]; }", &.{secret_value}, false);
}

// P5 specification test 45.
test "Array.from passes the source and its labels to the callback" {
    const from = "function f(s) { const o = { x: \"c\" }; ";
    try expectSecret(from ++ "Array.from(s, (x) => { o.x = x; return \"c\"; }); return o.x; }", &.{secret_value}, true);
    try expectSecret(from ++ "Array.from(\"c\", (x) => { o.x = x; return \"c\"; }); return o.x; }", &.{secret_value}, false);
    try expectSecret("function f(s) { return Array.from([\"c\"], () => s)[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return Array.from([s], (x) => x)[0]; }", &.{secret_value}, true);
    // Without a callback the result holds the elements.
    try expectSecret("function f(s) { return Array.from([s])[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return Array.from([\"c\"])[0]; }", &.{secret_value}, false);
}

const ExportFixture = struct {
    specifier: []const u8,
    name: []const u8,
    /// The result is secret, and the secret reaches it only through the
    /// capture of the callback.
    secret: []const u8,
    clean: []const u8,
    /// Another argument holds a function that returns the secret, and the
    /// export never calls it, so the result is clean.
    elsewhere: []const u8,
};

const collections_import = "import { dictEmpty, dictMapValues, dictFilter, dictFold } from \"zttp:collections\"; ";
const result_import = "import { ok, err, mapResult, mapError, andThen, orElse } from \"zttp:result\"; ";

const export_fixtures = [_]ExportFixture{
    .{
        .specifier = "zttp:collections",
        .name = "dictMapValues",
        .secret = collections_import ++ "function f(s) { return dictMapValues(dictEmpty(), () => s); }",
        .clean = collections_import ++ "function f(s) { return dictMapValues(dictEmpty(), () => \"c\"); }",
        .elsewhere = collections_import ++ "function f(s) { return dictMapValues({ k: () => s }, () => \"c\"); }",
    },
    .{
        .specifier = "zttp:collections",
        .name = "dictFilter",
        .secret = collections_import ++ "function f(s) { return dictFilter(dictEmpty(), () => s); }",
        .clean = collections_import ++ "function f(s) { return dictFilter(dictEmpty(), () => \"c\"); }",
        .elsewhere = collections_import ++ "function f(s) { return dictFilter({ k: () => s }, () => \"c\"); }",
    },
    .{
        .specifier = "zttp:collections",
        .name = "dictFold",
        .secret = collections_import ++ "function f(s) { return dictFold(dictEmpty(), () => s, 0); }",
        .clean = collections_import ++ "function f(s) { return dictFold(dictEmpty(), () => \"c\", 0); }",
        .elsewhere = collections_import ++ "function f(s) { return dictFold({ k: () => s }, () => \"c\", 0); }",
    },
    .{
        .specifier = "zttp:result",
        .name = "mapResult",
        .secret = result_import ++ "function f(s) { return mapResult(ok(\"c\"), () => s); }",
        .clean = result_import ++ "function f(s) { return mapResult(ok(\"c\"), () => \"c\"); }",
        .elsewhere = result_import ++ "function f(s) { return mapResult({ v: () => s }, () => \"c\"); }",
    },
    .{
        .specifier = "zttp:result",
        .name = "mapError",
        .secret = result_import ++ "function f(s) { return mapError(err(\"c\"), () => s); }",
        .clean = result_import ++ "function f(s) { return mapError(err(\"c\"), () => \"c\"); }",
        .elsewhere = result_import ++ "function f(s) { return mapError({ v: () => s }, () => \"c\"); }",
    },
    .{
        .specifier = "zttp:result",
        .name = "andThen",
        .secret = result_import ++ "function f(s) { return andThen(ok(\"c\"), () => s); }",
        .clean = result_import ++ "function f(s) { return andThen(ok(\"c\"), () => \"c\"); }",
        .elsewhere = result_import ++ "function f(s) { return andThen({ v: () => s }, () => \"c\"); }",
    },
    .{
        .specifier = "zttp:result",
        .name = "orElse",
        .secret = result_import ++ "function f(s) { return orElse(err(\"c\"), () => s); }",
        .clean = result_import ++ "function f(s) { return orElse(err(\"c\"), () => \"c\"); }",
        .elsewhere = result_import ++ "function f(s) { return orElse({ v: () => s }, () => \"c\"); }",
    },
};

const ExportCensusError = error{
    /// A row names no export that `findExport` finds.
    RowWithoutExport,
    /// A row's export has no function parameter at argument 1.
    RowWithoutCallbackParam,
    /// A row has no fixture.
    RowWithoutTest,
    /// A fixture names no row.
    TestWithoutRow,
};

/// Check the precise export rows against `findExport` and against the
/// fixtures, in both directions, and return the number of rows.
fn censusExports(rows: []const CallbackExport, fixtures: []const ExportFixture) ExportCensusError!usize {
    for (rows) |row| {
        const found = engine.builtin_modules.findExport(row.specifier, row.name) orelse return error.RowWithoutExport;
        if (found.func.param_types.len < 2 or found.func.param_types[1] != .object) return error.RowWithoutCallbackParam;
        var tested = false;
        for (fixtures) |fixture| {
            tested = tested or (std.mem.eql(u8, fixture.specifier, row.specifier) and std.mem.eql(u8, fixture.name, row.name));
        }
        if (!tested) return error.RowWithoutTest;
    }
    for (fixtures) |fixture| {
        if (findCallbackExport(rows, fixture.specifier, fixture.name) == null) return error.TestWithoutRow;
    }
    return rows.len;
}

// P5 specification test 46.
test "census C2: each callback export runs its callback and only its callback" {
    const rows = try censusExports(&callback_exports, &export_fixtures);
    std.debug.print("flow_interp export census: {d} precise callback rows, {d} fixtures\n", .{ rows, export_fixtures.len });
    // A floor on the input: a census over no rows would pass.
    try testing.expect(rows >= 7);
    try testing.expectEqual(callback_exports.len, rows);

    for (export_fixtures) |fixture| {
        try expectSecret(fixture.secret, &.{secret_value}, true);
        try expectSecret(fixture.clean, &.{secret_value}, false);
        try expectSecret(fixture.elsewhere, &.{secret_value}, false);
    }

    // A probe that drops a fixture, a row, or the export itself must fail.
    for (0..export_fixtures.len) |skipped| {
        var kept: [export_fixtures.len - 1]ExportFixture = undefined;
        @memcpy(kept[0..skipped], export_fixtures[0..skipped]);
        @memcpy(kept[skipped..], export_fixtures[skipped + 1 ..]);
        try testing.expectError(error.RowWithoutTest, censusExports(&callback_exports, &kept));
    }
    for (0..callback_exports.len) |skipped| {
        var kept: [callback_exports.len - 1]CallbackExport = undefined;
        @memcpy(kept[0..skipped], callback_exports[0..skipped]);
        @memcpy(kept[skipped..], callback_exports[skipped + 1 ..]);
        try testing.expectError(error.TestWithoutRow, censusExports(&kept, &export_fixtures));
    }
    const missing = [_]CallbackExport{.{ .specifier = "zttp:collections", .name = "noSuchExport", .shape = .payload }};
    try testing.expectError(error.RowWithoutExport, censusExports(&missing, &export_fixtures));
    // `dictEmpty` takes no argument, so it has no callback parameter.
    const no_callback = [_]CallbackExport{.{ .specifier = "zttp:collections", .name = "dictEmpty", .shape = .payload }};
    try testing.expectError(error.RowWithoutCallbackParam, censusExports(&no_callback, &export_fixtures));
}

test "an export callback receives what its shape says" {
    const imports = "import { ok, mapResult } from \"zttp:result\"; " ++
        "import { dictEmpty, dictMapValues, dictFold } from \"zttp:collections\"; ";
    const setup = imports ++ "function f(s) { const o = { x: \"c\" }; ";

    // The value and the key of each entry.
    try expectSecret(setup ++ "dictMapValues({ k: s }, (v, k) => { o.x = v; return 1; }); return o.x; }", &.{secret_value}, true);
    try expectSecret(setup ++ "dictMapValues({ k: \"c\" }, (v, k) => { o.x = v; return 1; }); return o.x; }", &.{secret_value}, false);
    try expectSecret(setup ++ "dictMapValues({ k: s }, (v, k) => { o.x = k; return 1; }); return o.x; }", &.{secret_value}, true);

    // The accumulator starts as argument 2, and each entry follows it.
    try expectSecret(setup ++ "dictFold(dictEmpty(), (acc) => { o.x = acc; return 1; }, s); return o.x; }", &.{secret_value}, true);
    try expectSecret(setup ++ "dictFold(dictEmpty(), (acc) => { o.x = acc; return 1; }, \"c\"); return o.x; }", &.{secret_value}, false);
    try expectSecret(setup ++ "dictFold({ k: s }, (acc, v) => { o.x = v; return 1; }, 0); return o.x; }", &.{secret_value}, true);

    // The payload of a Result.
    try expectSecret(setup ++ "mapResult(ok(s), (v) => { o.x = v; return 1; }); return o.x; }", &.{secret_value}, true);
    try expectSecret(setup ++ "mapResult(ok(\"c\"), (v) => { o.x = v; return 1; }); return o.x; }", &.{secret_value}, false);

    // A fold returns its accumulator, which holds every result.
    try expectSecret(imports ++ "function f(s) { return dictFold(dictEmpty(), () => s, 0); }", &.{secret_value}, true);
}

// P5 specification test 47.
test "a callback that may be any function is an unknown callee" {
    const unknown: Value = .{ .callables_top = true };
    const sources = [_][]const u8{
        "function f(g) { return [1].map(g); }",
        "function f(g) { return [1].reduce(g, 0); }",
        "function f(g) { return [1].toSorted(g); }",
        "function f(g) { return Array.from([1], g); }",
        "import { dictMapValues, dictEmpty } from \"zttp:collections\"; function f(g) { return dictMapValues(dictEmpty(), g); }",
    };
    inline for (sources) |source| {
        const r = try analyzeSource(source, "f", &.{unknown});
        defer r.deinit();
        try expectUnresolved(r.result, .call, .unknown_callee);
    }

    // A callback argument that holds no function has no rule.
    const missing = [_][]const u8{
        "function f(g) { return [1].map(); }",
        "function f(g) { return [1].filter(3); }",
        "function f(g) { return [1].toSorted(3); }",
        "function f(g) { return Array.from([1], 3); }",
        "import { dictFold, dictEmpty } from \"zttp:collections\"; function f(g) { return dictFold(dictEmpty()); }",
    };
    inline for (missing) |source| {
        const r = try analyzeSource(source, "f", &.{Value.clean});
        defer r.deinit();
        try expectUnresolved(r.result, .call, .no_operation_rule);
    }
}

// P5 specification test 48.
test "a callback loop records its passes and the cap" {
    const source =
        "function f(s) { const o = { v: \"c\" }; [\"c\"].reduce((acc, x) => { o.v = acc; return s; }, \"c\"); return o.v; }";
    try expectSecret(source, &.{secret_value}, true);
    try expectSecret(
        "function f(s) { const o = { v: \"c\" }; [\"c\"].reduce((acc, x) => { o.v = acc; return \"c\"; }, \"c\"); return o.v; }",
        &.{secret_value},
        false,
    );

    // The accumulator takes the result of the first pass into the second, and
    // the third finds nothing new.
    const h = try Harness.create(testing.allocator, source);
    defer h.destroy();
    var needed: u32 = 0;
    var cap: u32 = 1;
    while (cap <= 16) : (cap += 1) {
        h.interp.max_loop_passes = cap;
        const result = try h.analyze("f", &.{secret_value});
        var limited = false;
        for (result.unresolved) |entry| limited = limited or entry.owner == .fixpoint_limit;
        if (!limited) {
            needed = cap;
            break;
        }
    }
    try testing.expectEqual(@as(u32, 3), needed);
    h.interp.max_loop_passes = needed - 1;
    try expectUnresolved(try h.analyze("f", &.{secret_value}), .call, .fixpoint_limit);
    h.interp.max_loop_passes = needed;
    try testing.expect(!(try h.analyze("f", &.{secret_value})).cleared);
}

test "a callback chosen through a labelled value labels what it returns" {
    // `o[s]` stores the function under a key that is the secret, so the value
    // read back carries it. The second pass passes that label to the
    // accumulator, and the callback stores it where the caller reads it.
    const labelled =
        "function f(s) { const o = {}; const sink = { w: \"c\" }; o[s] = (acc, x) => { sink.w = acc; return \"c\"; }; [1].reduce(o.k, \"c\"); return sink.w; }";
    try expectSecret(labelled, &.{secret_value}, true);
    const plain =
        "function f(s) { const o = {}; const sink = { w: \"c\" }; o[\"k\"] = (acc, x) => { sink.w = acc; return \"c\"; }; [1].reduce(o.k, \"c\"); return sink.w; }";
    try expectSecret(plain, &.{secret_value}, false);
}

// P5 specification test 49.
test "renderToString refuses a vnode that holds a component" {
    // A component runs later and writes its props.
    const component = try analyzeSource(
        "function f(s) { const c = (props) => s; return renderToString(h(c, {})); }",
        "f",
        &.{secret_value},
    );
    defer component.deinit();
    try expectUnresolved(component.result, .call, .no_operation_rule);

    // A vnode of strings carries their labels.
    try expectSecret("function f(s) { return renderToString(h(\"div\", {}, s)); }", &.{secret_value}, true);
    try expectSecret("function f(s) { return renderToString(h(\"div\", {}, \"c\")); }", &.{secret_value}, false);

    // A write into the children is rendered.
    try expectSecret(
        "function f(s) { const v = h(\"div\", {}); v.children = s; return renderToString(v); }",
        &.{secret_value},
        true,
    );
    try expectSecret(
        "function f(s) { const v = h(\"div\", {}); v.children = \"c\"; return renderToString(v); }",
        &.{secret_value},
        false,
    );
}

// P5 specification test 50.
test "a recursive call through a callback converges" {
    const go = "function go(n) { if (n) { return n; } return [n].map((x) => go(x)); } ";
    try expectSecret(go ++ "function f(s) { return go(s); }", &.{secret_value}, true);
    try expectSecret(go ++ "function f(s) { return go(\"c\"); }", &.{secret_value}, false);
}

// P5 specification test 51.
test "an array that a builtin returns is not a Result" {
    try expectSecret("function f(s) { return s.split(\",\").map((x) => x)[0]; }", &.{secret_value}, true);
    try expectSecret("function f(s) { return \"a,b\".split(\",\").map((x) => x)[0]; }", &.{secret_value}, false);
}

// --- P6b: defenses ---
//
// These sources are internal evaluator fixtures. `u` is seeded `user_input`
// and holds no defense. A seed may also be a hand-built primitive with labels
// and defenses and no origin. Each test that expects a defense has a contrast
// without it, and each check compares the exact defense set.

const both_defenses: Defenses = .{ .html_escaped = true, .schema_checked = true };
const no_defenses: Defenses = .{};

/// A primitive that request data decided and that holds `defenses`.
fn exposedSeed(defenses: Defenses) Value {
    return .{ .labels = .{ .user_input = true }, .defenses = defenses };
}

const text_import = "import { escapeHtml, unescapeHtml, truncate } from \"zttp:text\"; ";
const validate_import = "import { validateJson, validateObject, coerceJson } from \"zttp:validate\"; ";
const decode_import = "import { decodeJson, decodeForm, decodeQuery, decodeFormMultipart } from \"zttp:decode\"; ";

/// What a run returned: the flow of the value, the flow of everything the
/// value reaches in the exit state, and whether the value points anywhere.
const Probe = struct { cleared: bool, surface: Flow, deep: Flow, origins: usize };

fn probe(source: []const u8, params: []const Value) !Probe {
    const r = try analyzeSource(source, "f", params);
    defer r.deinit();
    const returned = r.result.returned orelse return error.NoReturnedValue;
    return .{
        .cleared = r.result.cleared,
        .surface = returned.flow(),
        .deep = try r.harness.interp.deepFlow(&r.result.exit, &.{returned}),
        .origins = returned.origins.len,
    };
}

fn expectSameDefenses(expected: Defenses, actual: Defenses) !void {
    try testing.expectEqual(@as(u8, @bitCast(expected)), @as(u8, @bitCast(actual)));
}

/// Require a resolved run whose value is exposed to request data and holds
/// exactly `expected`.
fn expectDefenses(source: []const u8, params: []const Value, expected: Defenses) !void {
    const p = try probe(source, params);
    try testing.expect(!p.cleared);
    try testing.expect(p.surface.labels.user_input);
    try expectSameDefenses(expected, p.surface.defenses);
}

/// The same, for the flow of everything the value reaches.
fn expectDeepDefenses(source: []const u8, params: []const Value, expected: Defenses) !void {
    const p = try probe(source, params);
    try testing.expect(!p.cleared);
    try testing.expect(p.deep.labels.user_input);
    try expectSameDefenses(expected, p.deep.defenses);
}

fn expectUserInput(source: []const u8, params: []const Value, expected: bool) !void {
    const r = try analyzeSource(source, "f", params);
    defer r.deinit();
    try testing.expect(!r.result.cleared);
    try testing.expectEqual(expected, r.returnedLabels().user_input);
}

// P6 specification test 6.
test "escapeHtml establishes html_escaped, keeps user_input, and ignores the origins of its argument" {
    const plain = text_import ++ "function f(u) { return escapeHtml(u); }";
    try expectDefenses(plain, &.{user_input_value}, html_only);
    // `u` holds no defense.
    try expectDefenses("function f(u) { return u; }", &.{user_input_value}, no_defenses);

    // `t` is an exposed value with an origin, and the result is the same.
    const split = "function f(u) { return u.split(\",\")[0]; }";
    const origin = try probe(split, &.{user_input_value});
    try testing.expect(origin.origins > 0);
    try expectDefenses(text_import ++ "function f(u) { const t = u.split(\",\")[0]; return escapeHtml(t); }", &.{user_input_value}, html_only);

    // The sink predicate takes the `deepFlow` of the result.
    const escaped = try probe(plain, &.{user_input_value});
    try testing.expect(inputAccepted(escaped.deep, .response_html, .injection_safe));
    const raw = try probe(split, &.{user_input_value});
    try testing.expect(!inputAccepted(raw.deep, .response_html, .injection_safe));

    // The row keeps `schema_checked` from its argument.
    const checked = text_import ++ "function f(v) { return escapeHtml(v); }";
    try expectDefenses(checked, &.{exposedSeed(schema_only)}, both_defenses);
    try expectDefenses(checked, &.{exposedSeed(html_only)}, html_only);

    // A clean argument gives a clean result.
    const literal = try probe(text_import ++ "function f(u) { return escapeHtml(\"c\"); }", &.{user_input_value});
    try testing.expect(!literal.surface.labels.user_input);
}

// P6 specification test 7.
test "a combination keeps a defense only when every exposed contributor holds it" {
    const params = [_]Value{user_input_value};
    try expectDefenses(text_import ++ "function f(u) { return \"<p>\" + escapeHtml(u) + \"</p>\"; }", &params, html_only);
    try expectDefenses(text_import ++ "function f(u) { return escapeHtml(u) + u; }", &params, no_defenses);
    try expectDefenses(text_import ++ "function f(u) { return u + escapeHtml(u); }", &params, no_defenses);
    // Two escaped contributors keep it.
    try expectDefenses(text_import ++ "function f(u) { return escapeHtml(u) + escapeHtml(u); }", &params, html_only);
}

// P6 specification test 8.
test "a join keeps a defense when the other side is not exposed" {
    const params = [_]Value{ Value.clean, user_input_value };
    try expectDefenses(text_import ++ "function f(c, u) { return c ? escapeHtml(u) : \"x\"; }", &params, html_only);
    try expectDefenses(text_import ++ "function f(c, u) { return c ? \"x\" : escapeHtml(u); }", &params, html_only);
    try expectDefenses(text_import ++ "function f(c, u) { return c ? escapeHtml(u) : u; }", &params, no_defenses);
    try expectDefenses(text_import ++ "function f(c, u) { return c ? u : escapeHtml(u); }", &params, no_defenses);
}

// P6 specification test 9.
test "operations with the edge keep carry the defenses of their flow" {
    const params = [_]Value{user_input_value};
    const escaped_forms = [_][]const u8{
        "e.toUpperCase()",
        "e.trim()",
        "\"<b>\".concat(e)",
        "e.slice(0, 3)",
        "e.split(\",\")[0]",
        "(e + \"<\").charAt(1)",
        "e.padStart(9, \"<\")",
        "e.charCodeAt(0)",
        "[e, \"<b>\"].join(\"\")",
        "[e, \"<b>\"][0]",
        "[e, \"<img>\"].toSorted()[0]",
        "[e, \"<img>\"].pop()",
        "[e, \"<b>\"].filter((x) => true).join(\"\")",
        "[e, \"<b>\"].splice(0, 1).join(\"\")",
    };
    inline for (escaped_forms) |form| {
        try expectDefenses(text_import ++ "function f(u) { const e = escapeHtml(u); return " ++ form ++ "; }", &params, html_only);
    }

    // A raw argument removes the defense.
    try expectDefenses(text_import ++ "function f(u) { const e = escapeHtml(u); return e.slice(u.length); }", &params, no_defenses);
    try expectDefenses(text_import ++ "function f(u) { const e = escapeHtml(u); return \"<b>\".concat(u, e); }", &params, no_defenses);

    // The same holds for the other defense.
    const seeds = [_]Value{ exposedSeed(schema_only), user_input_value };
    try expectDefenses("function f(v, u) { return v.slice(1); }", &seeds, schema_only);
    try expectDefenses("function f(v, u) { return v.slice(u.length); }", &seeds, no_defenses);

    // `replace` and `replaceAll` remove both defenses.
    const both = [_]Value{ exposedSeed(both_defenses), user_input_value };
    inline for (.{ "replace", "replaceAll" }) |method| {
        try expectDefenses(text_import ++ "function f(u) { const e = escapeHtml(u); return e." ++ method ++ "(\"a\", \"b\"); }", &params, no_defenses);
        try expectDefenses("function f(v, u) { return v." ++ method ++ "(\"a\", \"b\"); }", &seeds, no_defenses);
        try expectDefenses("function f(v, u) { return v." ++ method ++ "(\"a\", \"b\"); }", &both, no_defenses);
    }
    // Contrast: a row with the edge keep leaves both defenses where they are.
    try expectDefenses("function f(v, u) { return v.trim(); }", &both, both_defenses);

    // A container keeps the flow of its rule: it takes the raw flow of `u`
    // while its elements are escaped.
    const from = text_import ++ "function f(u) { return Array.from(u, (c) => escapeHtml(c)); }";
    try expectDeepDefenses(from, &params, no_defenses);
    const first = text_import ++ "function f(u) { return Array.from(u, (c) => escapeHtml(c))[0]; }";
    try expectDefenses(first, &params, no_defenses);
    try expectDeepDefenses(first, &params, no_defenses);
}

// P6 specification test 10.
test "request data that selects author characters keeps html_escaped, as D25 states" {
    const tag = "\"<img src=x onerror=alert(1)>\"";
    const escaped_bound = text_import ++ "function f(u) { const n = escapeHtml(u).length; return " ++ tag ++ ".slice(n); }";
    try expectDefenses(escaped_bound, &.{user_input_value}, html_only);
    const raw_bound = "function f(u) { const n = u.length; return " ++ tag ++ ".slice(n); }";
    try expectDefenses(raw_bound, &.{user_input_value}, no_defenses);
    const literal_bound = try probe("function f(u) { const n = 1; return " ++ tag ++ ".slice(n); }", &.{user_input_value});
    try testing.expect(!literal_bound.surface.exposed());
    try expectSameDefenses(no_defenses, literal_bound.surface.defenses);
}

// P6 specification test 11.
test "a computed read and a computed write combine the key as data" {
    const params = [_]Value{user_input_value};
    const record = text_import ++ "function f(u) { const o = { k: escapeHtml(u) }; ";
    try expectDefenses(record ++ "return o[u]; }", &params, no_defenses);
    try expectDefenses(record ++ "return o[escapeHtml(u)]; }", &params, html_only);
    try expectDefenses(record ++ "return o[\"k\"]; }", &params, html_only);

    // A write at a raw key removes the defense from every later read, and a
    // write at a literal key does not.
    try expectDefenses(record ++ "o[u] = escapeHtml(u); return o.k; }", &params, no_defenses);
    try expectDefenses(record ++ "o[\"z\"] = escapeHtml(u); return o.k; }", &params, html_only);
    // The value written at an escaped key keeps its own defense.
    try expectDefenses(record ++ "o[escapeHtml(u)] = escapeHtml(u); return o.k; }", &params, html_only);
}

// P6 specification test 12.
test "the callback index carries the structure of the receiver" {
    const write = "o.w = \"c\".charAt(i);";
    const calls = [_][]const u8{
        "a.map((x, i) => { " ++ write ++ " return x; })",
        "a.filter((x, i) => { " ++ write ++ " return true; })",
        "a.find((x, i) => { " ++ write ++ " return true; })",
        "a.forEach((x, i) => { " ++ write ++ " })",
        "a.every((x, i) => { " ++ write ++ " return true; })",
        "a.some((x, i) => { " ++ write ++ " return true; })",
        "a.findIndex((x, i) => { " ++ write ++ " return true; })",
        "a.reduce((acc, x, i) => { " ++ write ++ " return acc; }, \"c\")",
        "Array.from(a, (x, i) => { " ++ write ++ " return x; })",
    };
    inline for (calls) |call| {
        const head = "function f(u) { const o = { w: \"c\" }; const a = ";
        const tail = "; " ++ call ++ "; return o.w; }";
        // A spread copies request-derived elements into a receiver whose own
        // labels are clean.
        try expectUserInput(head ++ "[...u.split(\",\")]" ++ tail, &.{user_input_value}, true);
        try expectUserInput(head ++ "[\"c\", \"c\"]" ++ tail, &.{user_input_value}, false);
    }

    const index = text_import ++ "function f(u) { return Array.from(escapeHtml(u), (c, i) => \"c\".charAt(i)).join(\"\"); }";
    try expectUserInput(index, &.{user_input_value}, true);
    const element = text_import ++ "function f(u) { return Array.from(escapeHtml(u), (c) => c).join(\"\"); }";
    try expectDefenses(element, &.{user_input_value}, html_only);
}

// P6 specification test 13.
test "method dispatch adds the user candidate only when it can be called" {
    const params = [_]Value{user_input_value};
    const list = text_import ++
        "function f(u) { const a = [u]; return a.map((x) => \"<li>\" + escapeHtml(x) + \"</li>\").join(\"\"); }";
    try expectDefenses(list, &params, html_only);

    // A stored function runs, and its result reaches the call.
    try expectUserInput("function f(u) { const a = [() => u]; return a.map(() => \"c\"); }", &params, true);
    try expectUserInput("function f(u) { const a = [() => \"c\"]; return a.map(() => \"c\"); }", &params, false);

    // The flow of a callable candidate joins the result even when the body
    // returns a clean value.
    const selected = "function f(s) { const a = []; a[s] = () => \"c\"; return a.map(() => \"c\"); }";
    const p = try probe(selected, &.{secret_value});
    try testing.expect(!p.cleared);
    try testing.expect(p.surface.labels.secret);
    try expectSameDefenses(no_defenses, p.surface.defenses);
    try expectSecret("function f(s) { const a = []; a[\"k\"] = () => \"c\"; return a.map(() => \"c\"); }", &.{secret_value}, false);

    // A raw key that selects the function removes a defense from the result.
    const keyed = text_import ++
        "function f(u) { const a = []; a[u] = () => \"c\"; return a.map(() => escapeHtml(u)).join(\"\"); }";
    try expectDefenses(keyed, &params, no_defenses);
}

/// The call of one export with a precise callback row, split around the
/// callback: the text before it and the text after it.
const CallbackCall = struct { before: []const u8, after: []const u8 };

const callback_calls = [_]CallbackCall{
    .{ .before = "dictMapValues(dictEmpty(), ", .after = ")" },
    .{ .before = "dictFilter(dictEmpty(), ", .after = ")" },
    .{ .before = "dictFold(dictSet(dictEmpty(), \"k\", \"c\"), ", .after = ", \"\")" },
    .{ .before = "mapResult(ok(\"c\"), ", .after = ")" },
    .{ .before = "mapError(err(\"c\"), ", .after = ")" },
    .{ .before = "andThen(ok(\"c\"), ", .after = ")" },
    .{ .before = "orElse(err(\"c\"), ", .after = ")" },
};

const callback_imports = text_import ++
    "import { dictEmpty, dictSet, dictMapValues, dictFilter, dictFold } from \"zttp:collections\"; " ++
    "import { ok, err, mapResult, mapError, andThen, orElse } from \"zttp:result\"; ";

// P6 specification test 14.
test "a non-source export clears the defenses of its callback results" {
    // The callback returns an escaped value, or a seed that holds a defense.
    const callbacks = [_][]const u8{ "() => escapeHtml(u)", "() => v" };
    const schema_seeds = [_]Value{ user_input_value, exposedSeed(schema_only) };
    const html_seeds = [_]Value{ user_input_value, exposedSeed(html_only) };
    inline for (callback_calls) |call| {
        inline for (callbacks) |callback| {
            const source = callback_imports ++ "function f(u, v) { return " ++ call.before ++ callback ++ call.after ++ "; }";
            try expectDefenses(source, &schema_seeds, no_defenses);
            try expectDeepDefenses(source, &schema_seeds, no_defenses);
            try expectDeepDefenses(source, &html_seeds, no_defenses);
        }
    }

    // The named example.
    const fold = callback_imports ++
        "function f(u) { return dictFold(dictSet(dictEmpty(), \"k\", \"c\"), () => escapeHtml(u), \"\"); }";
    try expectDeepDefenses(fold, &.{user_input_value}, no_defenses);
}

// P6 specification test 15.
test "an export that is not a source removes the defenses of what it read" {
    const params = [_]Value{user_input_value};
    try expectDefenses(text_import ++ "function f(u) { return unescapeHtml(escapeHtml(u)); }", &params, no_defenses);
    try expectDefenses(text_import ++ "function f(u) { return truncate(escapeHtml(u), 3); }", &params, no_defenses);
    try expectDeepDefenses(text_import ++ "function f(u) { return unescapeHtml(escapeHtml(u)); }", &params, no_defenses);
    // Contrast: the escaped value itself keeps it.
    try expectDefenses(text_import ++ "function f(u) { return escapeHtml(u); }", &params, html_only);
}

// P6 specification test 16.
test "fromCharCode removes both defenses and charCodeAt keeps them" {
    try expectDefenses("function f(n) { return String.fromCharCode(n); }", &.{exposedSeed(both_defenses)}, no_defenses);
    try expectDefenses("function f(n) { return String.fromCharCode(n); }", &.{exposedSeed(html_only)}, no_defenses);
    try expectDefenses(text_import ++ "function f(u) { return escapeHtml(u).charCodeAt(0); }", &.{user_input_value}, html_only);
}

// P6 specification test 17.
test "JSON.stringify keeps schema_checked and JSON.parse removes both" {
    const seeds = [_]Value{exposedSeed(both_defenses)};
    try expectDefenses("function f(v) { return JSON.stringify(v); }", &seeds, schema_only);
    try expectDefenses("function f(v) { return JSON.parse(v); }", &seeds, no_defenses);
    try expectDefenses("function f(v) { return JSON.tryParse(v); }", &seeds, no_defenses);
    try expectDeepDefenses("function f(v) { return JSON.parse(v); }", &seeds, no_defenses);
    // Contrast: a seed with html_escaped alone loses it at stringify.
    try expectDefenses("function f(v) { return JSON.stringify(v); }", &.{exposedSeed(html_only)}, no_defenses);
}

// P6 specification test 18.
test "Object.keys and Object.entries remove html_escaped and Object.values keeps it" {
    const params = [_]Value{user_input_value};
    const record = text_import ++ "function f(u) { const o = { k: escapeHtml(u) }; ";
    try expectDefenses(record ++ "return Object.keys(o).join(\"\"); }", &params, no_defenses);
    try expectDefenses(record ++ "return Object.entries(o).join(\"\"); }", &params, no_defenses);
    try expectDefenses(record ++ "return Object.values(o).join(\"\"); }", &params, html_only);
}

// P6 specification test 19.
test "renderToString removes html_escaped" {
    const params = [_]Value{user_input_value};
    try expectDefenses(text_import ++ "function f(u) { return renderToString(h(\"p\", {}, escapeHtml(u))); }", &params, no_defenses);
    // Contrast: building the vnode keeps it.
    try expectDefenses(text_import ++ "function f(u) { return h(\"p\", {}, escapeHtml(u)); }", &params, html_only);
}

/// A call of one source with the argument `u`, and the extra argument that
/// `decodeFormMultipart` takes.
const SchemaSource = struct { imports: []const u8, call: []const u8 };

const schema_sources = [_]SchemaSource{
    .{ .imports = validate_import, .call = "validateJson(\"n\", u)" },
    .{ .imports = validate_import, .call = "coerceJson(\"n\", u)" },
    .{ .imports = decode_import, .call = "decodeJson(\"n\", u)" },
    .{ .imports = decode_import, .call = "decodeForm(\"n\", u)" },
    .{ .imports = decode_import, .call = "decodeFormMultipart(\"n\", u, \"multipart/form-data\")" },
};

// P6 specification test 20.
test "a schema source establishes schema_checked and removes html_escaped" {
    const raw = [_]Value{user_input_value};
    const escaped = [_]Value{exposedSeed(html_only)};
    inline for (schema_sources) |source| {
        const result = source.imports ++ "function f(u) { return " ++ source.call ++ "; }";
        const member = source.imports ++ "function f(u) { return " ++ source.call ++ ".value; }";
        inline for (.{ result, member }) |text| {
            try expectDefenses(text, &raw, schema_only);
            try expectDefenses(text, &escaped, schema_only);
            try expectDeepDefenses(text, &raw, schema_only);
        }
    }
    // Contrast: the same call on a clean argument is not exposed.
    const clean = try probe(validate_import ++ "function f(u) { return validateJson(\"n\", \"{}\"); }", &raw);
    try testing.expect(!clean.surface.exposed());
}

// P6 specification test 21.
test "a row without a defense establishes nothing" {
    const params = [_]Value{user_input_value};
    const auth = "import { jwtVerify } from \"zttp:auth\"; ";
    const sources = [_][]const u8{
        validate_import ++ "function f(u) { return validateObject(\"n\", u); }",
        validate_import ++ "function f(u) { return validateObject(\"n\", { k: u }); }",
        decode_import ++ "function f(u) { return decodeQuery(\"n\", { k: u }); }",
        auth ++ "function f(u) { return jwtVerify(u, \"k\"); }",
    };
    for (sources) |source| {
        try expectDefenses(source, &params, no_defenses);
        try expectDeepDefenses(source, &params, no_defenses);
        // An escaped argument does not survive either.
        try expectDefenses(source, &.{exposedSeed(both_defenses)}, no_defenses);
    }
    const r = try analyzeSource(auth ++ "function f(u) { return jwtVerify(u, \"k\"); }", "f", &params);
    defer r.deinit();
    try testing.expect(r.returnedLabels().credential);
    try testing.expect(r.returnedLabels().user_input);
}

// P6 specification test 22.
test "a write into a validated result removes the defense for later reads" {
    const params = [_]Value{user_input_value};
    const head = validate_import ++ "function f(u) { const r = validateJson(\"n\", u); ";
    try expectDefenses(head ++ "r.value.x = u; return r.value.x; }", &params, no_defenses);
    try expectDefenses(head ++ "return r.value.x; }", &params, schema_only);
    // A write of a validated value keeps the defense.
    try expectDefenses(head ++ "r.value.x = r.value; return r.value.x; }", &params, schema_only);
}

// P6 specification test 23.
test "a defense survives a call, a loop, and a callback" {
    const params = [_]Value{user_input_value};
    try expectDefenses(
        text_import ++ "function esc(x) { return escapeHtml(x); } function f(u) { return esc(u); }",
        &params,
        html_only,
    );
    try expectDefenses(
        text_import ++ "function f(u) { let r = \"x\"; for (const y of [escapeHtml(u)]) { r = y; } return r; }",
        &params,
        html_only,
    );
    try expectDefenses(text_import ++ "function f(u) { return [u].map((x) => escapeHtml(x)).join(\"\"); }", &params, html_only);
    try expectDefenses(text_import ++ "function f(u) { return [u].map((x) => x).join(\"\"); }", &params, no_defenses);
}

// P6 specification test 24.
test "canonical form: only an exposed value holds a defense" {
    const literal = try probe(text_import ++ "function f(u) { return escapeHtml(\"c\"); }", &.{user_input_value});
    try testing.expect(!literal.cleared);
    try testing.expect(!literal.surface.exposed());
    try expectSameDefenses(no_defenses, literal.surface.defenses);

    try testing.expect(Value.top.flow().exposed());
    try testing.expect(Value.labelled(.{ .unknown = true }).flow().exposed());
    try testing.expect(!Value.labelled(.{ .secret = true }).flow().exposed());

    // A join with `Value.top` and a combination with a value that holds only
    // `unknown` both remove the defense.
    const joined = text_import ++ "function f(c, t, u) { return c ? t : escapeHtml(u); }";
    const p = try probe(joined, &.{ Value.clean, Value.top, user_input_value });
    try testing.expect(p.surface.exposed());
    try expectSameDefenses(no_defenses, p.surface.defenses);
    const unknown_only = Value.labelled(.{ .unknown = true });
    const combined = try probe(text_import ++ "function f(x, u) { return x + escapeHtml(u); }", &.{ unknown_only, user_input_value });
    try testing.expect(combined.surface.exposed());
    try expectSameDefenses(no_defenses, combined.surface.defenses);

    // The join of the values themselves.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const escaped = exposedSeed(html_only);
    const top_join = try joinValue(arena.allocator(), Value.top, escaped);
    try expectSameDefenses(no_defenses, top_join.defenses);
    const clean_join = try joinValue(arena.allocator(), Value.clean, escaped);
    try expectSameDefenses(html_only, clean_join.defenses);
    // A flow that is not exposed cannot hold a defense.
    const quiet = Value.flowing(.{ .labels = .{ .secret = true }, .defenses = html_only });
    try expectSameDefenses(no_defenses, quiet.defenses);
}

// P6 specification test 25.
test "no value carries the validated label" {
    const params = [_]Value{user_input_value};
    const sources = [_][]const u8{
        validate_import ++ "function f(u) { return validateJson(\"n\", u); }",
        validate_import ++ "function f(u) { return validateJson(\"n\", u).value; }",
        text_import ++ "function f(u) { return escapeHtml(u); }",
        validate_import ++ "function f(u) { return validateJson(\"n\", \"{}\"); }",
        validate_import ++ "function f(u) { return validateObject(\"n\", {}); }",
        text_import ++ "function f(u) { return escapeHtml(\"c\"); }",
    };
    for (sources) |source| {
        const r = try analyzeSource(source, "f", &params);
        defer r.deinit();
        try testing.expect(!r.result.cleared);
        try testing.expect(!r.returnedLabels().validated);
    }
    // Nothing else is declared either: the labels of a call that reads
    // nothing are empty.
    try expectLabels(validate_import ++ "function f(u) { return validateObject(\"n\", {}); }", &params, .empty);
    try expectLabels(text_import ++ "function f(u) { return escapeHtml(\"c\"); }", &params, .empty);
}

// P6 specification test 26.
test "a loop that makes a value exposed converges" {
    const params = [_]Value{user_input_value};
    const head = text_import ++ "function f(u) { let x = escapeHtml(\"c\"); for (const y of [u]) { ";
    try expectDefenses(head ++ "x = x + escapeHtml(y); } return x; }", &params, html_only);
    try expectDefenses(head ++ "x = x + y; } return x; }", &params, no_defenses);
    // The same through a callback loop.
    try expectDefenses(
        text_import ++ "function f(u) { let x = escapeHtml(\"c\"); [u].forEach((y) => { x = x + escapeHtml(y); }); return x; }",
        &params,
        html_only,
    );
}

// P6 specification test 27.
test "requirement matches the table and inputAccepted reads the defenses of the reached flow" {
    const open: Requirement = .not_governed;
    const html: Requirement = .{ .defense = .html_escaped };
    const schema: Requirement = .{ .defense = .schema_checked };
    const closed: Requirement = .no_defense;
    // Rows follow the order of `InputSink`, columns the order of
    // `InputProperty`.
    const expected = [_][3]Requirement{
        .{ open, html, open },
        .{ open, open, open },
        .{ open, open, open },
        .{ open, open, open },
        .{ schema, closed, closed },
        .{ schema, schema, closed },
        .{ schema, closed, closed },
        .{ schema, closed, closed },
    };
    const sinks = std.enums.values(InputSink);
    const properties = std.enums.values(InputProperty);
    try testing.expectEqual(expected.len, sinks.len);
    try testing.expectEqual(expected[0].len, properties.len);
    for (sinks, expected) |sink, row| {
        for (properties, row) |property, want| {
            try testing.expectEqual(want, requirement(sink, property));
        }
    }

    const raw: Flow = .{ .labels = .{ .user_input = true } };
    const html_flow: Flow = .{ .labels = .{ .user_input = true }, .defenses = html_only };
    const schema_flow: Flow = .{ .labels = .{ .user_input = true }, .defenses = schema_only };
    const both_flow: Flow = .{ .labels = .{ .user_input = true }, .defenses = both_defenses };

    // The escaped value at the HTML body.
    const escaped = try probe(text_import ++ "function f(u) { return escapeHtml(u); }", &.{user_input_value});
    try testing.expect(inputAccepted(escaped.deep, .response_html, .injection_safe));
    try testing.expect(!inputAccepted(schema_flow, .response_html, .injection_safe));
    try testing.expect(!inputAccepted(raw, .response_html, .injection_safe));

    // The validated value at the network.
    try testing.expect(inputAccepted(schema_flow, .egress_url, .input_validated));
    try testing.expect(!inputAccepted(schema_flow, .egress_url, .injection_safe));
    try testing.expect(!inputAccepted(html_flow, .egress_body, .input_validated));
    try testing.expect(!inputAccepted(html_flow, .egress_body, .injection_safe));
    try testing.expect(inputAccepted(schema_flow, .egress_body, .input_validated));
    try testing.expect(inputAccepted(schema_flow, .egress_body, .injection_safe));

    // Personal data is never contained by a defense.
    for ([_]InputSink{ .egress_url, .egress_body, .egress_headers, .egress_opaque }) |sink| {
        for ([_]Flow{ raw, html_flow, schema_flow, both_flow }) |flow| {
            try testing.expect(!inputAccepted(flow, sink, .pii_contained));
        }
    }

    // A flow that is not exposed is accepted everywhere. A flow that holds
    // only `unknown` needs the defense, and raw request data passes only where
    // the sink does not govern the property.
    const quiet: Flow = .{ .labels = .{ .secret = true } };
    const unknown_only: Flow = .{ .labels = .{ .unknown = true } };
    var governed: usize = 0;
    for (sinks) |sink| {
        for (properties) |property| {
            try testing.expect(inputAccepted(quiet, sink, property));
            try testing.expect(inputAccepted(.{}, sink, property));
            switch (requirement(sink, property)) {
                .not_governed => {
                    try testing.expect(inputAccepted(raw, sink, property));
                    try testing.expect(inputAccepted(unknown_only, sink, property));
                },
                .defense => {
                    governed += 1;
                    try testing.expect(!inputAccepted(raw, sink, property));
                    try testing.expect(!inputAccepted(unknown_only, sink, property));
                },
                .no_defense => {
                    try testing.expect(!inputAccepted(raw, sink, property));
                    try testing.expect(!inputAccepted(both_flow, sink, property));
                },
            }
        }
    }
    try testing.expectEqual(@as(usize, 6), governed);

    // The sink reads the flow of everything the value reaches.
    const body = try probe("function f(u) { return { body: u }; }", &.{user_input_value});
    try testing.expect(!inputAccepted(body.deep, .egress_body, .input_validated));

    const checked = validate_import ++ "function f(u) { const r = validateJson(\"n\", u); ";
    const intact = try probe(checked ++ "return r.value; }", &.{user_input_value});
    try testing.expect(inputAccepted(intact.deep, .egress_url, .input_validated));
    const aliased = try probe(checked ++ "const alias = r.value; alias.x = u; return r.value; }", &.{user_input_value});
    // The surface of the value keeps its own defense, and the cells do not.
    try testing.expect(inputAccepted(aliased.surface, .egress_url, .input_validated));
    try testing.expect(!inputAccepted(aliased.deep, .egress_url, .input_validated));
}

/// An operation row the census expects to carry an edge other than `keep`.
const ExpectedEdge = struct { scope: []const u8, name: []const u8, edge: DefenseEdge };

const expected_edges = [_]ExpectedEdge{
    .{ .scope = "String.prototype", .name = "replace", .edge = .drop_all },
    .{ .scope = "String.prototype", .name = "replaceAll", .edge = .drop_all },
    .{ .scope = "String", .name = "fromCharCode", .edge = .drop_all },
    .{ .scope = "JSON", .name = "stringify", .edge = .drop_html },
    .{ .scope = "JSON", .name = "parse", .edge = .drop_all },
    .{ .scope = "JSON", .name = "tryParse", .edge = .drop_all },
    .{ .scope = "Object", .name = "keys", .edge = .drop_html },
    .{ .scope = "Object", .name = "entries", .edge = .drop_html },
    .{ .scope = "global", .name = "renderToString", .edge = .drop_html },
    .{ .scope = "global", .name = "requestBody", .edge = .drop_all },
    .{ .scope = "global", .name = "requestText", .edge = .drop_all },
    .{ .scope = "global", .name = "requestJson", .edge = .drop_all },
};

const EdgeCensusError = error{
    /// An expected row is missing or has another edge.
    EdgeMismatch,
    /// A row that is not expected has an edge other than `keep`.
    UnexpectedEdge,
};

/// Check that the rows with an edge other than `keep` are exactly `expected`,
/// and return their number.
fn censusEdges(rows: []const OperationRow, expected: []const ExpectedEdge) EdgeCensusError!usize {
    for (expected) |want| {
        const row = findRow(rows, want.scope, want.name) orelse return error.EdgeMismatch;
        if (row.defense != want.edge) return error.EdgeMismatch;
    }
    var removing: usize = 0;
    for (rows) |row| {
        if (row.defense != .keep) removing += 1;
    }
    if (removing != expected.len) return error.UnexpectedEdge;
    return removing;
}

// P6 specification test 28, the C1 half.
test "census C1: the rows that remove a defense are exactly the twelve" {
    const removing = try censusEdges(&operation_rows, &expected_edges);
    std.debug.print("flow_interp edge census: {d} rows remove a defense of {d}\n", .{ removing, operation_rows.len });
    // A floor on the input: a census over no rows would pass.
    try testing.expectEqual(@as(usize, 12), removing);
    try testing.expectEqual(@as(usize, 12), expected_edges.len);

    var arena_owner = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_owner.deinit();
    const allocator = arena_owner.allocator();

    // A probe that gives any of the twelve another edge must fail, and so
    // must a probe that gives another row an edge.
    for (expected_edges) |want| {
        const copy = try allocator.dupe(OperationRow, &operation_rows);
        const at = rowIndex(copy, want.scope, want.name) orelse return error.RowNotFound;
        copy[at].defense = .keep;
        try testing.expectError(error.EdgeMismatch, censusEdges(copy, &expected_edges));
        copy[at].defense = if (want.edge == .drop_all) .drop_html else .drop_all;
        try testing.expectError(error.EdgeMismatch, censusEdges(copy, &expected_edges));
    }
    const slice = try allocator.dupe(OperationRow, &operation_rows);
    slice[rowIndex(slice, "String.prototype", "slice") orelse return error.RowNotFound].defense = .drop_html;
    try testing.expectError(error.UnexpectedEdge, censusEdges(slice, &expected_edges));

    // The field has no default, so every `rowsOf` call and every literal row
    // names its edge.
    inline for (@typeInfo(OperationRow).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "defense")) try testing.expect(field.defaultValue() == null);
    }
}

/// What the census expects of one defense source.
const ExpectedSource = struct {
    specifier: []const u8,
    name: []const u8,
    establishes: Defenses,
    keeps: Defenses,
    removes: Defenses,
};

const expected_sources = [_]ExpectedSource{
    .{ .specifier = "zttp:text", .name = "escapeHtml", .establishes = html_only, .keeps = schema_only, .removes = no_defenses },
    .{ .specifier = "zttp:validate", .name = "validateJson", .establishes = schema_only, .keeps = no_defenses, .removes = html_only },
    .{ .specifier = "zttp:validate", .name = "coerceJson", .establishes = schema_only, .keeps = no_defenses, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeJson", .establishes = schema_only, .keeps = no_defenses, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeForm", .establishes = schema_only, .keeps = no_defenses, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeFormMultipart", .establishes = schema_only, .keeps = no_defenses, .removes = html_only },
    .{ .specifier = "zttp:validate", .name = "validateObject", .establishes = no_defenses, .keeps = no_defenses, .removes = no_defenses },
    .{ .specifier = "zttp:decode", .name = "decodeQuery", .establishes = no_defenses, .keeps = no_defenses, .removes = no_defenses },
    .{ .specifier = "zttp:auth", .name = "jwtVerify", .establishes = no_defenses, .keeps = no_defenses, .removes = no_defenses },
};

const SourceCensusError = error{
    /// An export declares `validated` and no row names it.
    ExportWithoutRow,
    /// A row names no export that `findExport` finds.
    RowWithoutExport,
    /// A row names an export that does not declare `validated`.
    RowWithoutValidated,
    /// A row establishes a defense and its export takes a parameter that is
    /// not a string, or takes none.
    NonStringParameter,
    /// A row that establishes nothing states no reason.
    RowWithoutReason,
    /// The table differs from the expected mapping.
    TableDiffers,
};

const SourceCensus = struct { rows: usize, validated_exports: usize };

/// Check `rows` against the bindings in both directions and against the
/// expected mapping.
fn censusSources(rows: []const DefenseSource, expected: []const ExpectedSource) SourceCensusError!SourceCensus {
    var validated_exports: usize = 0;
    for (&engine.builtin_modules.all) |*binding| {
        for (binding.exports) |*func| {
            if (!func.return_labels.validated) continue;
            validated_exports += 1;
            if (findDefenseSource(rows, binding.specifier, func.name) == null) return error.ExportWithoutRow;
        }
    }
    for (rows) |row| {
        const found = engine.builtin_modules.findExport(row.specifier, row.name) orelse return error.RowWithoutExport;
        if (!found.func.return_labels.validated) return error.RowWithoutValidated;
        if (row.establishes.isEmpty()) {
            if (row.reason.len == 0) return error.RowWithoutReason;
        } else {
            if (found.func.param_types.len == 0) return error.NonStringParameter;
            for (found.func.param_types) |kind| {
                if (kind != .string) return error.NonStringParameter;
            }
        }
    }
    if (rows.len != expected.len) return error.TableDiffers;
    for (rows) |row| {
        var matched = false;
        for (expected) |want| {
            if (!std.mem.eql(u8, want.specifier, row.specifier) or !std.mem.eql(u8, want.name, row.name)) continue;
            matched = true;
            const same = @as(u8, @bitCast(row.establishes)) == @as(u8, @bitCast(want.establishes)) and
                @as(u8, @bitCast(row.keeps)) == @as(u8, @bitCast(want.keeps)) and
                @as(u8, @bitCast(row.removes)) == @as(u8, @bitCast(want.removes));
            if (!same) return error.TableDiffers;
        }
        if (!matched) return error.TableDiffers;
    }
    return .{ .rows = rows.len, .validated_exports = validated_exports };
}

// P6 specification test 28, the C3 half.
test "census C3: each export that declares validated has a source row with the expected defenses" {
    const counts = try censusSources(&defense_sources, &expected_sources);
    std.debug.print(
        "flow_interp defense census: {d} source rows, {d} exports declare validated\n",
        .{ counts.rows, counts.validated_exports },
    );
    // A floor on the input: a census over no rows would pass.
    try testing.expect(counts.rows >= 9);
    try testing.expectEqual(counts.validated_exports, counts.rows);
    try testing.expectEqual(defense_sources.len, counts.rows);

    var arena_owner = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_owner.deinit();
    const allocator = arena_owner.allocator();

    // A probe that removes one row must fail.
    for (0..defense_sources.len) |skipped| {
        const without = try allocator.alloc(DefenseSource, defense_sources.len - 1);
        @memcpy(without[0..skipped], defense_sources[0..skipped]);
        @memcpy(without[skipped..], defense_sources[skipped + 1 ..]);
        try testing.expectError(error.ExportWithoutRow, censusSources(without, &expected_sources));
    }

    // A row for an export without `validated` fails, and so does a row that
    // names no export.
    const extra = try allocator.alloc(DefenseSource, defense_sources.len + 1);
    @memcpy(extra[0..defense_sources.len], &defense_sources);
    extra[defense_sources.len] = .{ .specifier = "zttp:text", .name = "unescapeHtml", .reason = "derives from its argument" };
    try testing.expectError(error.RowWithoutValidated, censusSources(extra, &expected_sources));
    extra[defense_sources.len] = .{ .specifier = "zttp:text", .name = "noSuchExport", .reason = "none" };
    try testing.expectError(error.RowWithoutExport, censusSources(extra, &expected_sources));

    // `validateObject` takes an object, so it cannot establish a defense.
    const takes_object = try allocator.dupe(DefenseSource, &defense_sources);
    takes_object[sourceIndex(takes_object, "validateObject")].establishes = schema_only;
    try testing.expectError(error.NonStringParameter, censusSources(takes_object, &expected_sources));
    const query = try allocator.dupe(DefenseSource, &defense_sources);
    query[sourceIndex(query, "decodeQuery")].establishes = schema_only;
    try testing.expectError(error.NonStringParameter, censusSources(query, &expected_sources));

    // `jwtVerify` takes only strings, so only the expected mapping rejects a
    // defense there.
    const jwt = try allocator.dupe(DefenseSource, &defense_sources);
    jwt[sourceIndex(jwt, "jwtVerify")].establishes = schema_only;
    try testing.expectError(error.TableDiffers, censusSources(jwt, &expected_sources));

    // A row with a wrong defense fails even when its parameters are strings.
    const wrong = try allocator.dupe(DefenseSource, &defense_sources);
    wrong[sourceIndex(wrong, "escapeHtml")].establishes = schema_only;
    try testing.expectError(error.TableDiffers, censusSources(wrong, &expected_sources));
    wrong[sourceIndex(wrong, "escapeHtml")] = defense_sources[sourceIndex(&defense_sources, "escapeHtml")];
    wrong[sourceIndex(wrong, "escapeHtml")].removes = html_only;
    try testing.expectError(error.TableDiffers, censusSources(wrong, &expected_sources));
    wrong[sourceIndex(wrong, "escapeHtml")] = defense_sources[sourceIndex(&defense_sources, "escapeHtml")];
    wrong[sourceIndex(wrong, "validateJson")].removes = no_defenses;
    try testing.expectError(error.TableDiffers, censusSources(wrong, &expected_sources));
    wrong[sourceIndex(wrong, "validateJson")] = defense_sources[sourceIndex(&defense_sources, "validateJson")];
    wrong[sourceIndex(wrong, "decodeForm")].keeps = html_only;
    try testing.expectError(error.TableDiffers, censusSources(wrong, &expected_sources));

    // A row that establishes nothing states why.
    const silent = try allocator.dupe(DefenseSource, &defense_sources);
    silent[sourceIndex(silent, "jwtVerify")].reason = "";
    try testing.expectError(error.RowWithoutReason, censusSources(silent, &expected_sources));

    // The expected mapping is part of the check: a shorter one differs.
    try testing.expectError(error.TableDiffers, censusSources(&defense_sources, expected_sources[1..]));
}

fn sourceIndex(rows: []const DefenseSource, name: []const u8) usize {
    for (rows, 0..) |row, i| {
        if (std.mem.eql(u8, row.name, name)) return i;
    }
    return rows.len;
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
    "function f(p, q) { return match (p) { when [{ k: v }, , \"a\"]: v when { a: [{ b: w }] }: w when { c: { d: z } }: z default: 0 }; }",
    "function f(p, q) { p; return; }",
    "function f(p, q) { let r = p; for (const v of q) { if (v) { r = v; break; } if (r) { continue; } r = q; } return r; }",
    // Calls: a local callee, a captured binding read and written through a
    // closure, recursion, a callable set, and a module-level function.
    "function f(p, q) { function id(x) { return x; } const g = (a) => id(a); let r = p; const w = () => { r = q; return r; }; return g(w()); }",
    "function f(p, q) { function rec(n) { if (n) { return 1; } return rec(true); } return rec(p); }",
    "function f(p, q) { const a = () => p; const b = () => q; return (p ? a : b)(); }",
    "function help(x) { return x; } function f(p, q) { return help(p); }",
};

/// Sources that hold a construct a later phase owns.
const unresolved_corpus = [_][]const u8{
    "function f(g) { return g(1); }",
    "function f(g, xs) { return g(...xs); }",
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
    var refused_strict: usize = 0;
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
            .refused_by_strict => {
                refused_strict += 1;
                try testing.expect(census.unresolved[index] > 0);
            },
            .not_produced => {
                not_produced += 1;
                try testing.expect(census.unresolved[index] > 0);
            },
        }
    }
    try testing.expectEqual(tag_count, handled + later + refused + refused_strict + not_produced);
    try testing.expect(handled > 0 and refused > 0 and refused_strict > 0 and not_produced > 0);
    // After P6a no tag is left to a later phase.
    try testing.expectEqual(@as(usize, 0), later);
    try testing.expect(tagPlan(.array_pattern) == .handled);
    try testing.expect(tagPlan(.spread) == .refused_by_strict);
    inline for (.{ NodeTag.for_of_stmt, NodeTag.break_stmt, NodeTag.continue_stmt, NodeTag.call }) |tag| {
        try testing.expect(tagPlan(tag) == .handled);
    }
    std.debug.print(
        "flow_interp tagPlan: {d} tags, handled={d} later={d} (p7={d} p8={d}) refused_by_parser={d} refused_by_strict={d} not_produced={d}\n",
        .{ tag_count, handled, later, by_phase[0], by_phase[1], refused, refused_strict, not_produced },
    );
}
