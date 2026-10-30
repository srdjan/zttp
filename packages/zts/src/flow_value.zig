//! The value model of the flow evaluator: sites, defenses, flows, values,
//! cells, states, their joins and their equality for the loop fixpoint.
//! `flow_interp.zig` holds the evaluator that computes over these types.

const std = @import("std");
const engine = @import("zts-engine");
const ir = engine.parser.ir;
const object = engine.object;
const mb = engine.module_binding;
const flow_evidence = @import("flow_evidence.zig");
const counterexample = @import("counterexample.zig");

const NodeIndex = ir.NodeIndex;
const LabelSet = mb.LabelSet;

/// Every allocation is an arena allocation, so the only failures are memory
/// and the step budget. `analyzeFunction` turns the second into a cleared
/// result, so it never reaches a caller of the public entry point.
pub const Error = std.mem.Allocator.Error || error{BudgetExhausted};

// ---------------------------------------------------------------------------
// Domain
// ---------------------------------------------------------------------------

pub const SiteKind = enum(u8) {
    /// An array or object literal.
    literal,
    /// A function object. Functions are mutable at runtime (`object.zig`
    /// 1753), so `g.x = secret` has to land somewhere a later `g.x` can read.
    function,
    /// The synthetic request and headers contents seeded at handler entry.
    /// Their named cells and summary use the same read/write rules as any
    /// other container (R4, R14).
    request,
    headers,
    /// The mutable request query object. Its values are strings or numbers,
    /// but the object itself may receive arbitrary later writes.
    query,
    /// Helper-created responses and their mutable header objects. Their
    /// methods see their own fields, rather than arbitrary runtime state.
    response,
    response_headers,
    router_result,
    router_params,
    /// The cell of a captured binding. `node` holds the packed source key of
    /// the binding, and the cell is the site's `summary`. No value points at
    /// a capture site, so a read through an unnamed object never sees one.
    capture,
    /// A runtime global slot. Its name is shared across modules, and its
    /// scalar value as well as objects reachable from it persist across calls.
    module_binding,
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
pub const any_builtin: u16 = 0;

/// An allocation site. `context` is 0 until a later phase separates the
/// callers of one function.
pub const SiteKey = struct {
    kind: SiteKind,
    node: NodeIndex,
    context: u16,
    /// One syntactic caller separates allocations returned by two calls of
    /// the same helper. Module globals, captures and shared builtins use 0.
    call: NodeIndex = 0,

    fn order(a: SiteKey, b: SiteKey) std.math.Order {
        const by_kind = std.math.order(@backingInt(a.kind), @backingInt(b.kind));
        if (by_kind != .eq) return by_kind;
        const by_node = std.math.order(a.node, b.node);
        if (by_node != .eq) return by_node;
        const by_context = std.math.order(a.context, b.context);
        if (by_context != .eq) return by_context;
        return std.math.order(a.call, b.call);
    }
};

fn nodeOrder(a: NodeIndex, b: NodeIndex) std.math.Order {
    return std.math.order(a, b);
}

pub const watched_top: u8 = 15;
pub const SiteVersion = struct {
    site: SiteKey,
    generation: u8,
    pub fn order(a: SiteVersion, b: SiteVersion) std.math.Order {
        const site = SiteKey.order(a.site, b.site);
        return if (site != .eq) site else std.math.order(a.generation, b.generation);
    }
};
pub const SchemaView = struct {
    sites: []const SiteVersion,
    top_generation: u8,
    guard: ?flow_evidence.Guard = null,
};

fn sameSchema(a: ?SchemaView, b: ?SchemaView) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return left.top_generation == right.top_generation and sameGuard(left.guard, right.guard) and sliceEql(SiteVersion, left.sites, right.sites, SiteVersion.order);
}

fn mergeSchema(a: ?SchemaView, b: ?SchemaView) ?SchemaView {
    var left = a orelse return null;
    const right = b orelse return null;
    if (left.top_generation != right.top_generation or !sliceEql(SiteVersion, left.sites, right.sites, SiteVersion.order)) return null;
    left.guard = flow_evidence.commonGuard(left.guard, right.guard, true, true);
    return left;
}

fn sameGuard(a: ?flow_evidence.Guard, b: ?flow_evidence.Guard) bool {
    const left = a orelse return b == null;
    return left.eql(b orelse return false);
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
    pub fn intersect(a: Defenses, b: Defenses) Defenses {
        const bits: u8 = @as(u8, @bitCast(a)) & @as(u8, @bitCast(b));
        return @bitCast(bits);
    }

    /// The defenses that either set holds.
    pub fn unite(a: Defenses, b: Defenses) Defenses {
        const bits: u8 = @as(u8, @bitCast(a)) | @as(u8, @bitCast(b));
        return @bitCast(bits);
    }

    /// The defenses of `self` that `removed` does not name.
    pub fn without(self: Defenses, removed: Defenses) Defenses {
        const bits: u8 = @as(u8, @bitCast(self)) & ~@as(u8, @bitCast(removed));
        return @bitCast(bits);
    }

    pub fn isEmpty(self: Defenses) bool {
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
    schema_guard: ?flow_evidence.Guard = null,
    html_guard: ?flow_evidence.Guard = null,
    witness_complete: bool = true,

    pub fn exposed(self: Flow) bool {
        return self.labels.user_input or self.labels.unknown;
    }

    /// The same flow with no defenses when it is not exposed.
    pub fn canonical(self: Flow) Flow {
        if (self.exposed()) {
            var out = self;
            if (!out.defenses.schema_checked) out.schema_guard = null;
            if (!out.defenses.html_escaped) out.html_guard = null;
            return out;
        }
        return .{ .labels = self.labels, .witness_complete = self.witness_complete };
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
pub fn combineFlows(a: Flow, b: Flow) Flow {
    const flow: Flow = .{
        .labels = LabelSet.mergeValues(a.labels, b.labels),
        .defenses = combineDefenses(a, b),
        .schema_guard = flow_evidence.commonGuard(a.schema_guard, b.schema_guard, a.exposed(), b.exposed()),
        .html_guard = flow_evidence.commonGuard(a.html_guard, b.html_guard, a.exposed(), b.exposed()),
        .witness_complete = a.witness_complete and b.witness_complete,
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

    pub fn apply(edge: DefenseEdge, flow: Flow) Flow {
        var out = flow;
        switch (edge) {
            .keep => {},
            .drop_html => out.defenses.html_escaped = false,
            .drop_all => out.defenses = .{},
        }
        return out.canonical();
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
    /// The value is a literal HTTP content type: true permits HTML, false is
    /// known not to select HTML, null is unknown. Transformations forget it;
    /// copies preserve it and alternatives retain it only when they agree.
    html_type: ?bool = null,
    /// Canonical: empty unless the labels hold `user_input` or `unknown`.
    defenses: Defenses = .{},
    schema_guard: ?flow_evidence.Guard = null,
    html_guard: ?flow_evidence.Guard = null,
    /// Sorted and deduplicated.
    origins: []const SiteKey = &.{},
    /// The value may point at an object this analysis cannot name.
    origins_top: bool = false,
    /// Function-expression nodes, sorted and deduplicated.
    callables: []const NodeIndex = &.{},
    callables_top: bool = false,
    /// Evidence only: this value's callable selection was not widened by an
    /// absent field, imprecise index, or a different alternative.
    callee_exact: bool = true,
    witness_complete: bool = true,
    native_export: ?ModuleExport = null,
    schema_view: ?SchemaView = null,
    request_field: ?flow_evidence.RequestField = null,
    io_origin: ?flow_evidence.Origin = null,
    io_view: ?SchemaView = null,
    /// Every value this denotes is the unmodified result of a labelled source
    /// (a literal-name `env()` read, the `authorization` header), or carries
    /// none of `declassifiable`. False by default, so a value that an operation
    /// builds anew forgets it. Only a plain copy keeps it; a join keeps it when
    /// both sides hold it (`exactFor`). `mask` declassifies only such text,
    /// because a slice of a secret is not the secret and a chain of slices
    /// would reveal all of it.
    source_exact: bool = false,

    /// A primitive that carries nothing.
    pub const clean: Value = .{ .html_type = false };

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
        return .{ .labels = canonical.labels, .defenses = canonical.defenses, .schema_guard = canonical.schema_guard, .html_guard = canonical.html_guard, .witness_complete = canonical.witness_complete };
    }

    pub fn flow(self: Value) Flow {
        return (Flow{ .labels = self.labels, .defenses = self.defenses, .schema_guard = self.schema_guard, .html_guard = self.html_guard, .witness_complete = self.witness_complete }).canonical();
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

/// The labels `mask`-style declassifiers may discharge. `source_exact` matters
/// only for these: a value that carries none of them has nothing to unmask.
pub const declassifiable: LabelSet = .{ .secret = true, .credential = true };

/// Whether `v` is an unmodified source value, or holds nothing a declassifier
/// could discharge.
pub fn exactFor(v: Value) bool {
    return v.source_exact or !v.labels.hasAny(declassifiable);
}

/// The join of two reachable values. Labels use `mergeConditional`, and the
/// defenses combine as data (`combineDefenses`), so a defense survives a join
/// only when every exposed path holds it. The other parts are set unions with
/// the `top` flags ORed.
pub fn joinValue(arena: std.mem.Allocator, a: Value, b: Value) Error!Value {
    const flow: Flow = (Flow{
        .labels = LabelSet.mergeConditional(a.labels, b.labels),
        .defenses = combineDefenses(a.flow(), b.flow()),
        .schema_guard = flow_evidence.commonGuard(a.schema_guard, b.schema_guard, a.flow().exposed(), b.flow().exposed()),
        .html_guard = flow_evidence.commonGuard(a.html_guard, b.html_guard, a.flow().exposed(), b.flow().exposed()),
        .witness_complete = a.witness_complete and b.witness_complete,
    }).canonical();
    return .{
        .labels = flow.labels,
        .html_type = if (a.html_type == b.html_type) a.html_type else null,
        .native_export = if (sameExport(a.native_export, b.native_export)) a.native_export else null,
        .schema_view = mergeSchema(a.schema_view, b.schema_view),
        .request_field = if (a.request_field == b.request_field) a.request_field else null,
        .io_origin = if (sameOrigin(a.io_origin, b.io_origin)) a.io_origin else null,
        .io_view = if (sameSchema(a.io_view, b.io_view)) a.io_view else null,
        .defenses = flow.defenses,
        .schema_guard = flow.schema_guard,
        .html_guard = flow.html_guard,
        .witness_complete = flow.witness_complete,
        .origins = try mergeSorted(SiteKey, arena, a.origins, b.origins, SiteKey.order),
        .origins_top = a.origins_top or b.origins_top,
        .callables = try mergeSorted(NodeIndex, arena, a.callables, b.callables, nodeOrder),
        .callables_top = a.callables_top or b.callables_top,
        .callee_exact = a.callee_exact and b.callee_exact and std.mem.eql(NodeIndex, a.callables, b.callables) and sameExport(a.native_export, b.native_export),
        .source_exact = exactFor(a) and exactFor(b),
    };
}

/// Join with bottom: the other operand survives unchanged.
pub fn joinOpt(arena: std.mem.Allocator, a: ?Value, b: ?Value) Error!?Value {
    const x = a orelse return b;
    const y = b orelse return a;
    return try joinValue(arena, x, y);
}

/// The flow of `source` joins a value copied out of it as data, and the
/// copied value keeps its own origins and callables because a copy of a
/// reference still names the same object.
pub fn withFlow(v: Value, source: Flow) Value {
    var out = v;
    const flow = combineFlows(v.flow(), source);
    out.labels = flow.labels;
    out.defenses = flow.defenses;
    out.schema_guard = flow.schema_guard;
    out.html_guard = flow.html_guard;
    out.witness_complete = flow.witness_complete and source.witness_complete;
    if (source.labels.hasAny(declassifiable)) out.source_exact = false;
    if (source.exposed() and !source.defenses.schema_checked) out.schema_view = null;
    return out;
}

/// `v` with no defense. An export that may transform or choose among the
/// values it hands back returns them this way.
pub fn withoutDefenses(v: Value) Value {
    var out = v;
    out.defenses = .{};
    out.schema_guard = null;
    out.html_guard = null;
    out.schema_view = null;
    out.request_field = null;
    out.io_origin = null;
    out.io_view = null;
    out.source_exact = false;
    return out;
}

/// The union of two values that an operation reads together: the flows
/// combine as data, the origins and callables are unions, and the `top` flags
/// are ORed.
pub fn unionValue(arena: std.mem.Allocator, a: Value, b: Value) Error!Value {
    var out = try withNative(arena, a, b);
    const flow = combineFlows(a.flow(), b.flow());
    out.labels = flow.labels;
    out.defenses = flow.defenses;
    out.schema_guard = flow.schema_guard;
    out.html_guard = flow.html_guard;
    out.html_type = if (a.html_type == b.html_type) a.html_type else null;
    out.native_export = if (sameExport(a.native_export, b.native_export)) a.native_export else null;
    out.schema_view = mergeSchema(a.schema_view, b.schema_view);
    out.request_field = if (a.request_field == b.request_field) a.request_field else null;
    out.io_origin = if (sameOrigin(a.io_origin, b.io_origin)) a.io_origin else null;
    out.io_view = if (sameSchema(a.io_view, b.io_view)) a.io_view else null;
    out.witness_complete = flow.witness_complete;
    out.source_exact = false;
    return out;
}

/// `v` with the origins, callables, and flags of `native` added. The flow of
/// `v` stays as it is: a native function value carries none, and a join of
/// labels would drop a fact of `v`.
pub fn withNative(arena: std.mem.Allocator, v: Value, native: Value) Error!Value {
    return .{
        .labels = v.labels,
        .html_type = v.html_type,
        .native_export = v.native_export,
        .schema_view = v.schema_view,
        .request_field = v.request_field,
        .io_origin = v.io_origin,
        .io_view = v.io_view,
        .source_exact = v.source_exact,
        .defenses = v.defenses,
        .schema_guard = v.schema_guard,
        .html_guard = v.html_guard,
        .witness_complete = v.witness_complete,
        .origins = try mergeSorted(SiteKey, arena, v.origins, native.origins, SiteKey.order),
        .origins_top = v.origins_top or native.origins_top,
        .callables = try mergeSorted(NodeIndex, arena, v.callables, native.callables, nodeOrder),
        .callables_top = v.callables_top or native.callables_top,
        .callee_exact = v.callee_exact and native.callee_exact and std.mem.eql(NodeIndex, v.callables, native.callables) and sameExport(v.native_export, native.native_export),
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
    /// The response may have an HTML content type. Weak format writes only
    /// establish this fact; an original HTML format never becomes forgotten.
    html_possible: bool = false,
    /// Only locations checked by an object validator need write generations.
    /// Saturation disables that view, so repeated writes remain a finite
    /// abstract domain instead of growing an unbounded validation epoch.
    watched: bool = false,
    generation: u8 = 0,
    request_fields: u3 = 7,
    written: bool = false,
};

/// The union of two cell sets. A name on one side only keeps its value: the
/// other side stands for a reachable `undefined`, not for bottom. The defenses
/// of a value on one side only survive for the same reason: `joinValue`
/// treats the side that holds no value as one that is not exposed.
pub fn joinCells(arena: std.mem.Allocator, a: Cells, b: Cells) Error!Cells {
    var named = try a.named.clone(arena);
    var it = b.named.iterator();
    while (it.next()) |entry| {
        const slot = try named.getOrPut(arena, entry.key_ptr.*);
        slot.value_ptr.* = if (slot.found_existing)
            try joinValue(arena, slot.value_ptr.*, entry.value_ptr.*)
        else
            entry.value_ptr.*;
    }
    return .{ .named = named, .summary = try joinOpt(arena, a.summary, b.summary), .html_possible = a.html_possible or b.html_possible, .watched = a.watched or b.watched, .generation = @max(a.generation, b.generation), .request_fields = a.request_fields & b.request_fields, .written = a.written or b.written };
}

/// A weak update: join `v` into the cell `name`, or into the summary when
/// `name` is null. One site stands for every object it creates, so the old
/// content may still be live and a write never removes a label.
pub fn weakWriteCells(arena: std.mem.Allocator, cells: Cells, name: ?u16, v: Value) Error!Cells {
    const preserved: u3 = if (name) |n|
        if (n == @backingInt(object.Atom.method)) 6 else if (n == @backingInt(object.Atom.url)) 5 else if (n == @backingInt(object.Atom.path)) 3 else 7
    else
        0;
    if (name) |n| {
        var named = try cells.named.clone(arena);
        const slot = try named.getOrPut(arena, n);
        slot.value_ptr.* = if (slot.found_existing)
            try joinValue(arena, slot.value_ptr.*, v)
        else
            v;
        return .{ .named = named, .summary = cells.summary, .html_possible = cells.html_possible, .watched = cells.watched, .generation = if (cells.watched) @min(cells.generation +| 1, watched_top) else cells.generation, .request_fields = cells.request_fields & preserved, .written = true };
    }
    return .{
        .named = cells.named,
        .summary = (try joinOpt(arena, cells.summary, v)),
        .html_possible = cells.html_possible,
        .watched = cells.watched,
        .generation = if (cells.watched) @min(cells.generation +| 1, watched_top) else cells.generation,
        .request_fields = cells.request_fields & preserved,
        .written = true,
    };
}

const EnvMap = std.AutoHashMapUnmanaged(u32, Value);
const HeapMap = std.AutoHashMapUnmanaged(SiteKey, Cells);

pub const PathEvidence = struct {
    complete: bool = true,
    constraints: []const counterexample.WitnessConstraint = &.{},
    io_calls: []const counterexample.TrackedIoCall = &.{},
};

fn sameOrigin(a: ?flow_evidence.Origin, b: ?flow_evidence.Origin) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return left.call_index == right.call_index and left.returns == right.returns and left.ok_record == right.ok_record and std.mem.eql(u8, left.module, right.module) and std.mem.eql(u8, left.func, right.func);
}

pub fn samePath(a: PathEvidence, b: PathEvidence) bool {
    return a.complete and b.complete and a.constraints.len == b.constraints.len and a.io_calls.len == b.io_calls.len and
        (a.constraints.len == 0 or a.constraints.ptr == b.constraints.ptr) and (a.io_calls.len == 0 or a.io_calls.ptr == b.io_calls.ptr);
}

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
    path: PathEvidence = .{},

    pub const bottom: State = .{ .reachable = false };
};

pub fn cloneState(arena: std.mem.Allocator, s: State) Error!State {
    return .{
        .reachable = s.reachable,
        .env = try s.env.clone(arena),
        .heap = try s.heap.clone(arena),
        .top_cell = s.top_cell,
        .path = s.path,
    };
}

/// The join of two states. A binding declared in one branch is out of scope
/// after it, so a key on one side keeps its value. When one side is bottom the
/// other is returned as it is: the caller must not use the operand it passed
/// once the result exists.
pub fn joinStates(arena: std.mem.Allocator, a: State, b: State) Error!State {
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
        .path = if (samePath(a.path, b.path)) a.path else .{ .complete = false },
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
pub fn valueEql(a: Value, b: Value) bool {
    const a_bits: u16 = @bitCast(a.labels);
    const b_bits: u16 = @bitCast(b.labels);
    const a_defenses: u8 = @bitCast(a.defenses);
    const b_defenses: u8 = @bitCast(b.defenses);
    return a_bits == b_bits and
        a.html_type == b.html_type and sameExport(a.native_export, b.native_export) and sameSchema(a.schema_view, b.schema_view) and a.request_field == b.request_field and sameOrigin(a.io_origin, b.io_origin) and sameSchema(a.io_view, b.io_view) and sameGuard(a.flow().schema_guard, b.flow().schema_guard) and sameGuard(a.flow().html_guard, b.flow().html_guard) and
        a_defenses == b_defenses and
        a.origins_top == b.origins_top and
        a.callables_top == b.callables_top and a.callee_exact == b.callee_exact and a.witness_complete == b.witness_complete and a.source_exact == b.source_exact and
        sliceEql(SiteKey, a.origins, b.origins, SiteKey.order) and
        sliceEql(NodeIndex, a.callables, b.callables, nodeOrder);
}

/// Bottom equals only bottom.
pub fn optValueEql(a: ?Value, b: ?Value) bool {
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
    return a.written == b.written and a.html_possible == b.html_possible and a.watched == b.watched and a.generation == b.generation and a.request_fields == b.request_fields and valueMapEql(a.named, b.named) and optValueEql(a.summary, b.summary);
}

/// Whether two states are the same abstract state. Two unreachable states are
/// equal. The summaries take part: a loop can change only a summary on a later
/// pass, and a comparison that skipped it would stop the loop too early.
pub fn stateEql(a: State, b: State) bool {
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
pub fn heapOnly(s: State) State {
    return .{ .reachable = s.reachable, .heap = s.heap, .top_cell = s.top_cell, .path = s.path };
}

pub fn joinSummary(arena: std.mem.Allocator, a: Summary, b: Summary) Error!Summary {
    return .{
        .value = try joinOpt(arena, a.value, b.value),
        .state = try joinStates(arena, a.state, b.state),
    };
}

pub fn summaryEql(a: Summary, b: Summary) bool {
    return optValueEql(a.value, b.value) and stateEql(a.state, b.state);
}

/// Argument lists that are both fitted to one function have the same length.
pub fn joinArgs(arena: std.mem.Allocator, a: []const Value, b: []const Value) Error![]const Value {
    const out = try arena.alloc(Value, @max(a.len, b.len));
    for (out, 0..) |*slot, i| {
        const x = if (i < a.len) a[i] else Value.clean;
        const y = if (i < b.len) b[i] else Value.clean;
        slot.* = try joinValue(arena, x, y);
    }
    return out;
}

pub fn argsEql(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!valueEql(x, y)) return false;
    }
    return true;
}

/// A copy of `v` whose slices live in `arena`, sorted and without duplicates.
/// The caller of `analyzeFunction` may pass slices from its own stack in any
/// order, and equality assumes the canonical form.
pub fn canonicalValue(arena: std.mem.Allocator, v: Value) Error!Value {
    var out = v;
    const canonical = v.flow().canonical();
    out.defenses = canonical.defenses;
    out.schema_guard = canonical.schema_guard;
    out.html_guard = canonical.html_guard;
    out.origins = try canonicalSlice(SiteKey, arena, v.origins, SiteKey.order);
    out.callables = try canonicalSlice(NodeIndex, arena, v.callables, nodeOrder);
    return out;
}

pub fn canonicalSlice(
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

/// An imported virtual-module export: the module, the export, and the atom
/// that the module exports it under.
pub const ModuleId = u16;

pub const ModuleExport = struct {
    binding: *const mb.ModuleBinding,
    func: *const mb.FunctionBinding,
    imported: u16,
};

pub fn sameExport(a: ?ModuleExport, b: ?ModuleExport) bool {
    if (a) |left| {
        const right = b orelse return false;
        return left.binding == right.binding and left.func == right.func;
    }
    return b == null;
}

/// The result of one call, or of one pass over a function body: the join of
/// every normal completion's value (null when none is reachable) and the join
/// of their states. The state carries `heap` and `top_cell` only, because the
/// callee's bindings are out of scope for the caller.
pub const Summary = struct {
    value: ?Value,
    state: State,

    pub const bottom: Summary = .{ .value = null, .state = State.bottom };
};
