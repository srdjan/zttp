//! Effect-row inference for user-defined functions.
//!
//! Extends the proof boundary across the call graph. Every named function
//! gets an `EffectRow` recording the union of capabilities required by its
//! direct or transitive calls, plus determinism, purity, and recursion.
//!
//! Algorithm: bottom-up fixed-point over a per-function direct-effect base.
//! Each function's base row captures local facts (Date.now, fetchSync, calls
//! to imported module functions). Propagation iterates user-function calls
//! until rows stabilise. Recursion is detected by a final DFS over the
//! callee map; functions reachable from themselves are flagged.

const std = @import("std");
const ir = @import("parser/ir.zig");
const object = @import("object.zig");
const atom_table = @import("atom_table.zig");
const module_binding = @import("module_binding.zig");
const builtin_modules = @import("builtin_modules.zig");
const manifest_registry_mod = @import("manifest_registry.zig");
const module_facts_mod = @import("module_facts.zig");
const bool_checker = @import("bool_checker.zig");
const known_globals = @import("known_globals.zig");

const NodeIndex = ir.NodeIndex;
const IrView = ir.IrView;
const null_node = ir.null_node;
const Capability = module_binding.ModuleCapability;

pub const CapabilitySet = std.EnumSet(Capability);

/// A `zttp:workflow` call (`call`, `saga`, `fanout`, or `follow`) found
/// while `durable_callback_depth > 0` - i.e. lexically nested inside a
/// `durable.step()` callback. `workflow.call` is only durable-recorded at
/// step depth 0 (see runtime_workflow.zig); nested inside a user `step()`
/// it silently loses durability at runtime with no error. This is an
/// unconditional structural fact, not gated behind a declared `Spec<...>`
/// or `Effects<...>` capsule - ZTS509 fires for every function regardless
/// of what it claims about itself.
pub const NestedWorkflowCall = struct {
    /// Index into `Analyzer.functions` for the function the call sits in.
    owner: usize,
    /// Static name of the offending export: "call", "saga", "fanout", or
    /// "follow". Borrowed from `imported.name`; never allocated.
    workflow_fn: []const u8,
};

pub const EffectRow = struct {
    capabilities: CapabilitySet = CapabilitySet.initEmpty(),
    deterministic: bool = true,
    pure: bool = true,
    recursive: bool = false,
    has_egress: bool = false,
    /// True when a direct or transitive call reaches an imported module export
    /// classified `.write`. Drives the per-function `read_only` capsule
    /// property: `read_only == !writes and !has_egress`.
    writes: bool = false,
    /// True when the function calls through a value this could not resolve to
    /// an import or a user function - a function-typed parameter, a local
    /// holding a function, or an unknown global. The row is then a LOWER
    /// bound: what the callee reaches is unknown and absent from every field
    /// above. Nothing may read this row as an over-approximation, which is
    /// what a ceiling check, a budget check, and every capsule property need.
    lower_bound: bool = false,

    pub const empty: EffectRow = .{};

    pub fn merge(a: EffectRow, b: EffectRow) EffectRow {
        return .{
            .capabilities = a.capabilities.unionWith(b.capabilities),
            .deterministic = a.deterministic and b.deterministic,
            .pure = a.pure and b.pure,
            .recursive = a.recursive or b.recursive,
            .has_egress = a.has_egress or b.has_egress,
            .writes = a.writes or b.writes,
            .lower_bound = a.lower_bound or b.lower_bound,
        };
    }

    pub fn eql(a: EffectRow, b: EffectRow) bool {
        return a.capabilities.eql(b.capabilities) and
            a.deterministic == b.deterministic and
            a.pure == b.pure and
            a.recursive == b.recursive and
            a.has_egress == b.has_egress and
            a.writes == b.writes and
            a.lower_bound == b.lower_bound;
    }

    /// `read_only` capsule property: the function performs no external writes
    /// and opens no egress. Derived, not stored, so it always tracks the
    /// other fields.
    pub fn readOnly(self: EffectRow) bool {
        return !self.writes and !self.has_egress;
    }
};

pub const FunctionEffect = struct {
    name: []const u8,
    binding_key: u32,
    decl_node: NodeIndex,
    body_node: NodeIndex,
    row: EffectRow = .{},
    /// Capabilities reached by this function's own direct module calls,
    /// captured before call-graph propagation. `row.capabilities` is the
    /// transitive union; `direct_caps` is the subset this function reaches
    /// itself, used to attribute a budget violation (ZTS607) to the helper
    /// that actually performs the call rather than every caller above it.
    direct_caps: CapabilitySet = CapabilitySet.initEmpty(),
    /// True when the function declaration sits under an `export`. The
    /// opt-in docs mode asks exported helpers to carry explicit capsules.
    exported: bool = false,
};

const ImportedFunction = struct {
    module: []const u8,
    name: []const u8,
};

const fetch_module_specifier: []const u8 = "zttp:fetch";
const fetch_sync_export: []const u8 = "fetchSync";

/// Maximum fixed-point iterations. A single iteration propagates each user
/// call's current row into its caller. Convergence is bounded by the
/// longest acyclic chain plus one; in practice handlers rarely exceed
/// three or four hops, so 16 is a generous safety net.
const max_iterations: u8 = 16;

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*atom_table.AtomTable,
    manifest_registry: ?*const manifest_registry_mod.Registry,
    functions: std.ArrayListUnmanaged(FunctionEffect),
    /// Imported callee metadata keyed by local binding slot.
    imports: std.AutoHashMapUnmanaged(u16, ImportedFunction),
    /// Shared import index, injected by the orchestrator when one exists for
    /// this compile. Borrowed; it must outlive the analyzer. When null the
    /// analyzer builds `owned_facts` for itself, which is what the in-file
    /// tests and any un-migrated caller do.
    facts: ?*const module_facts_mod.ModuleFacts = null,
    owned_facts: ?module_facts_mod.ModuleFacts = null,
    /// Map binding slot to index into `functions`. Used to resolve identifier
    /// callees back to a user-defined function.
    user_fn_by_slot: std.AutoHashMapUnmanaged(u16, usize),
    /// CSR-encoded direct callees per function: callee_starts[i..i+1] selects
    /// a slice of callee_storage holding the callees of function i. Has
    /// `fn_count + 1` entries with a trailing sentinel.
    callee_starts: std.ArrayListUnmanaged(u32),
    callee_storage: std.ArrayListUnmanaged(usize),
    durable_callback_depth: u32,
    /// The call node whose result the enclosing statement throws away, or
    /// `null_node`. Set only for the outermost call of an `expr_stmt`, so a
    /// nested call inside that statement is not mistaken for a discarded one.
    discarded_call: NodeIndex = null_node,
    /// Every `zttp:workflow` call found nested inside a `step()` callback.
    /// See `NestedWorkflowCall` - this is collected unconditionally during
    /// the same walk that computes effect rows, regardless of any declared
    /// `Spec<...>`/`Effects<...>` capsule.
    nested_workflow_calls: std.ArrayListUnmanaged(NestedWorkflowCall),

    pub fn init(allocator: std.mem.Allocator, ir_view: IrView, atoms: ?*atom_table.AtomTable) Analyzer {
        return initWithManifestRegistry(allocator, ir_view, atoms, null);
    }

    pub fn initWithManifestRegistry(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        atoms: ?*atom_table.AtomTable,
        manifest_registry: ?*const manifest_registry_mod.Registry,
    ) Analyzer {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .manifest_registry = manifest_registry,
            .functions = .empty,
            .imports = .empty,
            .user_fn_by_slot = .empty,
            .callee_starts = .empty,
            .callee_storage = .empty,
            .durable_callback_depth = 0,
            .nested_workflow_calls = .empty,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        if (self.owned_facts) |*owned| owned.deinit();
        self.functions.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.user_fn_by_slot.deinit(self.allocator);
        self.callee_starts.deinit(self.allocator);
        self.callee_storage.deinit(self.allocator);
        self.nested_workflow_calls.deinit(self.allocator);
    }

    pub fn analyze(self: *Analyzer, root: NodeIndex) !void {
        try self.scanImports();
        try self.collectFunctions(root);
        try self.computeBaseEffects();
        try self.propagate();
        try self.detectRecursion();
    }

    pub fn lookup(self: *const Analyzer, name: []const u8) ?EffectRow {
        for (self.functions.items) |fe| {
            if (std.mem.eql(u8, fe.name, name)) return fe.row;
        }
        return null;
    }

    pub fn all(self: *const Analyzer) []const FunctionEffect {
        return self.functions.items;
    }

    /// Whether the function whose body is `body_node` is recursive or can reach
    /// a recursive function through the call graph.
    ///
    /// Keyed on the body rather than the declaration because callers hold
    /// different nodes for the same function: `findHandlerFunction` returns the
    /// `.function_expr`, while `decl_node` here is the enclosing
    /// `.function_decl`. The body is the node both agree on.
    ///
    /// `EffectRow.recursive` answers only the first half: `propagate` resets it
    /// to the function's own value on purpose, because a caller of a recursive
    /// helper is not itself recursive and must not be refused capsule discharge
    /// for one. A cost or termination claim needs the other question, so this
    /// walks the same CSR call graph instead of reading the row.
    ///
    /// Returns false when `body_node` names no analyzed function, so a caller
    /// should treat false as "no evidence of recursion", never as "proven
    /// non-recursive". Allocation failure is returned as an error rather than
    /// as false: the walk that would have found the cycle never ran, and
    /// reporting its silence as a clean result is the fail-open this doc
    /// comment used to claim it avoided.
    pub fn reachesRecursion(self: *const Analyzer, body_node: NodeIndex) !bool {
        const fn_count = self.functions.items.len;
        if (fn_count == 0) return false;

        var start_idx: usize = 0;
        while (start_idx < fn_count) : (start_idx += 1) {
            if (self.functions.items[start_idx].body_node == body_node) break;
        } else return false;

        const visited = try self.allocator.alloc(bool, fn_count);
        defer self.allocator.free(visited);
        @memset(visited, false);

        const stack = try self.allocator.alloc(usize, fn_count);
        defer self.allocator.free(stack);

        var depth: usize = 1;
        stack[0] = start_idx;
        visited[start_idx] = true;

        while (depth > 0) {
            depth -= 1;
            const idx = stack[depth];
            if (self.functions.items[idx].row.recursive) return true;

            const start_off = self.callee_starts.items[idx];
            const count = self.calleeCount(idx);
            for (0..count) |k| {
                const callee_idx = self.callee_storage.items[start_off + k];
                if (visited[callee_idx]) continue;
                visited[callee_idx] = true;
                stack[depth] = callee_idx;
                depth += 1;
            }
        }
        return false;
    }

    // ----- internal -----

    /// Resolve the index to read: the injected one, or a private one built on
    /// first use.
    fn resolveFacts(self: *Analyzer) !*const module_facts_mod.ModuleFacts {
        if (self.facts) |f| return f;
        if (self.owned_facts == null) {
            self.owned_facts = try module_facts_mod.ModuleFacts.build(
                self.allocator,
                self.ir_view,
                self.atoms,
                self.manifest_registry,
            );
        }
        return &self.owned_facts.?;
    }

    /// Record every import, with no filter: this analyzer tracks imports from
    /// modules that are neither builtin nor partner-registered, which is a
    /// deliberate difference from path_generator, flow_checker, bool_checker,
    /// and handler_verifier.
    fn scanImports(self: *Analyzer) !void {
        const facts = try self.resolveFacts();
        for (facts.imports.items) |rec| {
            try self.imports.put(self.allocator, rec.slot, .{
                .module = rec.module_specifier,
                .name = rec.imported_name,
            });
        }
    }

    fn collectFunctions(self: *Analyzer, root: NodeIndex) !void {
        try self.collectFunctionsIn(root, false);
    }

    fn collectFunctionsIn(self: *Analyzer, node: NodeIndex, exported: bool) WalkError!void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    try self.collectFunctionsIn(self.ir_view.getListIndex(block.stmts_start, @intCast(i)), exported);
                }
            },
            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                try self.collectFunctionsIn(export_decl.declaration, true);
            },
            .function_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                try self.recordNamedFunction(decl.binding, node, decl.init, exported);
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                if (decl.init != null_node and self.isFunctionNode(decl.init)) {
                    try self.recordNamedFunction(decl.binding, node, decl.init, exported);
                }
            },
            // exhaustive: this descends only through the statement kinds that
            // can hold a top-level declaration. A function declared inside an
            // `if` or loop body is missed, and that is caught downstream rather
            // than ignored: a call to an uncollected function resolves to no
            // user function, which sets `EffectRow.lower_bound` and refuses the
            // ceiling. Missing it costs precision, never soundness.
            else => {},
        }
    }

    fn recordNamedFunction(
        self: *Analyzer,
        binding: ir.BindingRef,
        decl_node: NodeIndex,
        fn_node: NodeIndex,
        exported: bool,
    ) !void {
        const func = self.ir_view.getFunction(fn_node) orelse return;
        const name = self.resolveAtomName(binding.name_atom) orelse return;
        const key = bool_checker.packBindingKey(binding.scope_id, binding.slot);
        const idx = self.functions.items.len;
        try self.functions.append(self.allocator, .{
            .name = name,
            .binding_key = key,
            .decl_node = decl_node,
            .body_node = func.body,
            .exported = exported,
        });
        try self.user_fn_by_slot.put(self.allocator, binding.slot, idx);
    }

    fn computeBaseEffects(self: *Analyzer) !void {
        const fn_count = self.functions.items.len;
        try self.callee_starts.resize(self.allocator, fn_count + 1);
        for (0..fn_count) |i| {
            self.callee_starts.items[i] = @intCast(self.callee_storage.items.len);
            var seen_users: std.AutoHashMapUnmanaged(usize, void) = .empty;
            defer seen_users.deinit(self.allocator);
            var row: EffectRow = .{};
            try self.walkBaseExpr(self.functions.items[i].body_node, i, &row, &seen_users);
            self.functions.items[i].row = row;
            // Snapshot the direct capability set before propagation unions in
            // the rows of transitively-called user functions.
            self.functions.items[i].direct_caps = row.capabilities;
        }
        self.callee_starts.items[fn_count] = @intCast(self.callee_storage.items.len);
    }

    fn calleeCount(self: *const Analyzer, fn_idx: usize) u32 {
        return self.callee_starts.items[fn_idx + 1] - self.callee_starts.items[fn_idx];
    }

    /// Direct callees of function `fn_idx`, as indices into `functions` -
    /// the public view of the CSR-encoded call graph.
    pub fn calleesOf(self: *const Analyzer, fn_idx: usize) []const usize {
        const start = self.callee_starts.items[fn_idx];
        const end = self.callee_starts.items[fn_idx + 1];
        return self.callee_storage.items[start..end];
    }

    const WalkError = std.mem.Allocator.Error;

    fn walkBaseStmt(
        self: *Analyzer,
        node: NodeIndex,
        owner: usize,
        row: *EffectRow,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    try self.walkBaseStmt(self.ir_view.getListIndex(block.stmts_start, @intCast(i)), owner, row, seen_users);
                }
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node) orelse return;
                try self.walkBaseExpr(if_stmt.condition, owner, row, seen_users);
                try self.walkBaseStmt(if_stmt.then_branch, owner, row, seen_users);
                try self.walkBaseStmt(if_stmt.else_branch, owner, row, seen_users);
            },
            .for_of_stmt => {
                const for_iter = self.ir_view.getForIter(node) orelse return;
                try self.walkBaseExpr(for_iter.iterable, owner, row, seen_users);
                try self.walkBaseStmt(for_iter.body, owner, row, seen_users);
            },
            .return_stmt => {
                if (self.ir_view.getOptValue(node)) |value| {
                    try self.walkBaseExpr(value, owner, row, seen_users);
                }
            },
            .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |value| {
                    // A statement's value is thrown away. Split from
                    // `return_stmt`, whose value is the result, because the
                    // determinism rule below turns on exactly that difference.
                    const saved = self.discarded_call;
                    self.discarded_call = value;
                    defer self.discarded_call = saved;
                    try self.walkBaseExpr(value, owner, row, seen_users);
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                // Nested named functions are their own units; the call graph
                // edge is recorded when this owner calls into them.
                if (decl.init != null_node and !self.isFunctionNode(decl.init)) {
                    try self.walkBaseExpr(decl.init, owner, row, seen_users);
                }
            },
            .function_decl => {
                // Skip nested declarations entirely - they're separate units.
            },
            else => try self.walkBaseExpr(node, owner, row, seen_users),
        }
    }

    fn walkBaseExpr(
        self: *Analyzer,
        node: NodeIndex,
        owner: usize,
        row: *EffectRow,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block, .if_stmt, .for_of_stmt, .return_stmt, .expr_stmt, .var_decl, .function_decl => {
                try self.walkBaseStmt(node, owner, row, seen_users);
            },
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                try self.walkBaseExpr(bin.left, owner, row, seen_users);
                try self.walkBaseExpr(bin.right, owner, row, seen_users);
            },
            .unary_op, .spread => {
                const un = self.ir_view.getUnary(node) orelse return;
                try self.walkBaseExpr(un.operand, owner, row, seen_users);
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node) orelse return;
                try self.walkBaseExpr(ternary.condition, owner, row, seen_users);
                try self.walkBaseExpr(ternary.then_branch, owner, row, seen_users);
                try self.walkBaseExpr(ternary.else_branch, owner, row, seen_users);
            },
            .call, .method_call => {
                try self.handleCall(node, owner, row, seen_users);
                const call = self.ir_view.getCall(node) orelse return;
                const durable_step = self.isDurableStepCall(call);
                try self.walkBaseExpr(call.callee, owner, row, seen_users);
                for (0..call.args_count) |i| {
                    const arg = self.ir_view.getListIndex(call.args_start, @intCast(i));
                    // A named helper handed to a callback slot (`items.map(fmt)`)
                    // is called, but never through a call node this walk can
                    // see: the callee is `items.map`, and `fmt` is only an
                    // argument. Without an edge here the helper's capabilities
                    // stay out of the caller's row entirely.
                    try self.recordFunctionValueArg(arg, owner, seen_users);
                    if (durable_step and i == 1 and self.isFunctionNode(arg)) {
                        self.durable_callback_depth += 1;
                        defer self.durable_callback_depth -= 1;
                        try self.walkBaseExpr(arg, owner, row, seen_users);
                    } else {
                        try self.walkBaseExpr(arg, owner, row, seen_users);
                    }
                }
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                try self.walkBaseExpr(member.object, owner, row, seen_users);
                if (member.computed != null_node) try self.walkBaseExpr(member.computed, owner, row, seen_users);
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(node) orelse return;
                try self.walkBaseExpr(assign.target, owner, row, seen_users);
                try self.walkBaseExpr(assign.value, owner, row, seen_users);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                for (0..arr.elements_count) |i| {
                    try self.walkBaseExpr(self.ir_view.getListIndex(arr.elements_start, @intCast(i)), owner, row, seen_users);
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    try self.walkBaseExpr(prop.value, owner, row, seen_users);
                }
            },
            .template_literal => {
                const tmpl = self.ir_view.getTemplate(node) orelse return;
                for (0..tmpl.parts_count) |i| {
                    const part = self.ir_view.getListIndex(tmpl.parts_start, @intCast(i));
                    if (self.ir_view.getOptValue(part)) |value| try self.walkBaseExpr(value, owner, row, seen_users);
                }
            },
            .match_expr => {
                const match = self.ir_view.getMatchExpr(node) orelse return;
                try self.walkBaseExpr(match.discriminant, owner, row, seen_users);
                for (0..match.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(match.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    try self.walkBaseExpr(arm.body, owner, row, seen_users);
                }
            },
            // Anonymous closures inherit their enclosing function's effect row
            // by-design: callbacks passed to map/filter run inside the caller.
            .function_expr, .arrow_function => {
                if (self.ir_view.getFunction(node)) |func| {
                    try self.walkBaseStmt(func.body, owner, row, seen_users);
                }
            },
            // exhaustive: the remaining tags are leaves - literals and bare
            // identifiers - with no sub-expression that could reach a
            // capability. The one identifier that does carry effect, a named
            // helper passed as a callback, gets its call-graph edge from
            // `recordFunctionValueArg` at the argument site above.
            else => {},
        }
    }

    fn handleCall(
        self: *Analyzer,
        node: NodeIndex,
        owner: usize,
        row: *EffectRow,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        const call = self.ir_view.getCall(node) orelse return;

        if (self.calleeObjectProperty(call.callee)) |op| {
            if (self.durable_callback_depth == 0 and isNonDeterministic(op.object, op.property)) {
                row.deterministic = false;
                row.pure = false;
            }
        }

        if (self.ir_view.getTag(call.callee) != .identifier) return;
        const binding = self.ir_view.getBinding(call.callee) orelse return;

        if (self.imports.get(binding.slot)) |imported| {
            const before = row.capabilities;
            self.insertModuleCapabilities(imported.module, imported.name, row);
            // A call that reads the clock or draws randomness returns something
            // different next time, so the enclosing function is not
            // deterministic. Only `Date.now` and `Math.random` cleared this
            // flag, so `uuid()` reported `deterministic ... PROVEN` - a false
            // proof, and one a handler could then declare in a `Spec<...>` and
            // have discharged.
            //
            // Per-export capability rows make this precise: `parseBearer`
            // declares the empty set and stays deterministic, while `jwtVerify`
            // declares `.clock` for its exp check and does not. Before those
            // rows every `zttp:auth` call carried the module union and this
            // would have demoted all five exports.
            //
            // Inside a `durable.step()` callback the read is recorded and
            // replayed, which is the same reason the member-call rule above is
            // gated on step depth.
            const effect = self.importEffect(imported.module, imported.name);

            // A write-effect call whose result the statement throws away is a
            // sink, not a source: `logInfo(...)` reads the clock for its
            // timestamp, and that value reaches stderr and stops. It cannot
            // reach the response, so the handler's runs produce the same
            // answer and it stays `deterministic` - and therefore
            // `idempotent`, which is `deterministic and retry_safe` and means
            // "safe under at-least-once delivery". A duplicate log line is not
            // a duplicated side effect anyone is protecting against.
            //
            // This is an approximation, in the same family as the
            // `Date.now`-only rule it extends. It still misses a clock value
            // laundered through a store - `cacheSet(k, Date.now())` then
            // `cacheGet(k)` into the response. Closing that needs the value
            // tracked as a flow label to a response sink, the way
            // `no_secret_leakage` already works; see the roadmap item.
            const result_discarded = node == self.discarded_call;
            const sinks_the_read = result_discarded and effect == .write;
            if (self.durable_callback_depth == 0 and !sinks_the_read) {
                const added = row.capabilities.differenceWith(before);
                if (added.contains(.clock) or added.contains(.random)) {
                    row.deterministic = false;
                }
            }
            row.pure = false;
            // A `.write`-classified export modifies external state; that
            // demotes the enclosing function's `read_only` capsule property.
            if (effect == .write) row.writes = true;
            if (std.mem.eql(u8, imported.module, fetch_module_specifier) and
                std.mem.eql(u8, imported.name, fetch_sync_export))
            {
                row.has_egress = true;
            }
            if (self.durable_callback_depth > 0 and
                std.mem.eql(u8, imported.module, "zttp:workflow") and
                isNestedWorkflowExport(imported.name))
            {
                try self.nested_workflow_calls.append(self.allocator, .{
                    .owner = owner,
                    .workflow_fn = imported.name,
                });
            }
            return;
        }

        if (self.user_fn_by_slot.get(binding.slot)) |callee_idx| {
            if (callee_idx == owner) {
                // Self-recursion is captured here; non-self cycles are caught
                // during the dedicated detectRecursion pass.
                row.recursive = true;
            }
            const gop = try seen_users.getOrPut(self.allocator, callee_idx);
            if (!gop.found_existing) try self.callee_storage.append(self.allocator, callee_idx);
            return;
        }

        // Neither an import nor a user function: the call goes through a value.
        // Returning here left the row untouched, which reads downstream as
        // "this callee contributes nothing" - an under-approximation stated
        // with the confidence of a proof.
        if (self.calleeIsUnresolvable(binding)) row.lower_bound = true;
    }

    /// Record a call-graph edge for a bare identifier passed as an argument
    /// that names a user function.
    ///
    /// This over-approximates: an identifier handed to a function is not proof
    /// that it gets called. Over-approximating is the safe direction for a
    /// ceiling - the caller's row gains capabilities it might not reach, which
    /// can only reject, never wrongly certify. Under-approximating is what the
    /// missing edge did.
    fn recordFunctionValueArg(
        self: *Analyzer,
        arg: NodeIndex,
        owner: usize,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        if (self.ir_view.getTag(arg) != .identifier) return;
        const binding = self.ir_view.getBinding(arg) orelse return;
        const callee_idx = self.user_fn_by_slot.get(binding.slot) orelse return;
        if (callee_idx == owner) return;
        const gop = try seen_users.getOrPut(self.allocator, callee_idx);
        if (!gop.found_existing) try self.callee_storage.append(self.allocator, callee_idx);
    }

    /// True when a callee identifier names something whose body this cannot
    /// see. A runtime-provided global (`renderToString`, `range`) is resolvable
    /// by name and contributes nothing; a parameter, a local holding a
    /// function, or an unknown global is not.
    fn calleeIsUnresolvable(self: *const Analyzer, binding: ir.BindingRef) bool {
        switch (binding.kind) {
            .global, .undeclared_global => {
                // `slot` is an atom index only for globals, so the name is
                // readable here and nowhere else.
                if (self.resolveAtomName(binding.name_atom)) |name| {
                    if (known_globals.isKnownGlobalFunction(name)) return false;
                }
                return true;
            },
            .local, .upvalue, .argument => return true,
        }
    }

    fn isDurableStepCall(self: *const Analyzer, call: ir.Node.CallExpr) bool {
        if (self.ir_view.getTag(call.callee) != .identifier) return false;
        const binding = self.ir_view.getBinding(call.callee) orelse return false;
        const imported = self.imports.get(binding.slot) orelse return false;
        return std.mem.eql(u8, imported.module, "zttp:durable") and
            std.mem.eql(u8, imported.name, "step");
    }

    /// ZTS509's export allow-list: the four `zttp:workflow` exports that
    /// only durably record at step depth 0 (runtime_workflow.zig). Nested
    /// inside a `step()` callback, each one silently loses durability.
    fn isNestedWorkflowExport(name: []const u8) bool {
        return std.mem.eql(u8, name, "call") or
            std.mem.eql(u8, name, "saga") or
            std.mem.eql(u8, name, "fanout") or
            std.mem.eql(u8, name, "follow");
    }

    /// Union the capabilities a call into `module` grants into `row`.
    ///
    /// Both registries answer this: built-ins from the comptime table, partner
    /// `zttp-ext:` modules from the session manifest registry. Resolving only
    /// the built-in table left every partner call carrying no capability at
    /// all, so an extension's authority never appeared in any row, ceiling
    /// check, or budget.
    ///
    /// A module neither registry knows fails closed with every capability.
    /// That is spec rev 4 4.5 ("an unknown module makes the certified build
    /// fail closed") applied at the row level: an unresolvable import is a
    /// missing manifest, and guessing zero authority for it is the same
    /// fail-open in a different place.
    fn insertModuleCapabilities(
        self: *const Analyzer,
        module: []const u8,
        name: []const u8,
        row: *EffectRow,
    ) void {
        if (builtin_modules.fromSpecifier(module)) |mb| {
            // An export that declares its own set is the truthful answer: the
            // module union is an over-approximation, and `zttp:websocket`
            // charging `serializeAttachment` for network and filesystem makes
            // every ceiling over it wrong on its face. An export that declares
            // nothing inherits the module set, so an untightened binding
            // behaves exactly as it did before the field existed.
            if (builtin_modules.findExport(module, name)) |exp| {
                if (exp.func.required_capabilities) |export_caps| {
                    for (export_caps) |cap| row.capabilities.insert(cap);
                    return;
                }
            }
            for (mb.required_capabilities) |cap| row.capabilities.insert(cap);
            return;
        }
        if (self.manifest_registry) |registry| {
            if (registry.fromSpecifier(module)) |manifest| {
                for (manifest.required_capabilities.items) |decl| {
                    row.capabilities.insert(decl.effective);
                }
                return;
            }
        }
        row.capabilities = CapabilitySet.initFull();
    }

    fn importEffect(self: *const Analyzer, module: []const u8, name: []const u8) module_binding.EffectClass {
        if (builtin_modules.findExport(module, name)) |exp| return exp.func.effect;
        const registry = self.manifest_registry orelse return .none;
        const exp = registry.findExport(module, name) orelse return .none;
        return exp.effect;
    }

    const ObjectProperty = struct { object: []const u8, property: []const u8 };

    fn calleeObjectProperty(self: *const Analyzer, callee: NodeIndex) ?ObjectProperty {
        if (self.ir_view.getTag(callee) != .member_access) return null;
        const member = self.ir_view.getMember(callee) orelse return null;
        const object_name = self.identifierName(member.object) orelse return null;
        const property_name = self.resolveAtomName(member.property) orelse return null;
        return .{ .object = object_name, .property = property_name };
    }

    fn propagate(self: *Analyzer) !void {
        var iter: u8 = 0;
        while (iter < max_iterations) : (iter += 1) {
            var changed = false;
            for (0..self.functions.items.len) |i| {
                const start = self.callee_starts.items[i];
                const count = self.calleeCount(i);
                var merged = self.functions.items[i].row;
                for (0..count) |k| {
                    const callee_idx = self.callee_storage.items[start + k];
                    merged = merged.merge(self.functions.items[callee_idx].row);
                }
                // Recursion flag on a callee should not necessarily propagate
                // to the caller; reset it back to the caller's own.
                merged.recursive = self.functions.items[i].row.recursive;
                if (!merged.eql(self.functions.items[i].row)) {
                    self.functions.items[i].row = merged;
                    changed = true;
                }
            }
            if (!changed) return;
        }
    }

    fn detectRecursion(self: *Analyzer) !void {
        const fn_count = self.functions.items.len;
        if (fn_count == 0) return;
        // Tarjan-style DFS with explicit on-stack marker. Any back edge to a
        // function currently on the stack proves a cycle; mark every function
        // in the active path that participates.
        const State = enum(u2) { unseen, on_stack, done };
        const states = try self.allocator.alloc(State, fn_count);
        defer self.allocator.free(states);
        @memset(states, .unseen);

        const FrameCursor = struct { fn_idx: usize, next_callee: u32 };
        const cursors = try self.allocator.alloc(FrameCursor, fn_count);
        defer self.allocator.free(cursors);

        for (0..fn_count) |start_idx| {
            if (states[start_idx] != .unseen) continue;
            states[start_idx] = .on_stack;
            cursors[0] = .{ .fn_idx = start_idx, .next_callee = 0 };
            var cursor_depth: usize = 1;

            while (cursor_depth > 0) {
                const top = &cursors[cursor_depth - 1];
                const top_idx = top.fn_idx;
                if (top.next_callee >= self.calleeCount(top_idx)) {
                    states[top_idx] = .done;
                    cursor_depth -= 1;
                    continue;
                }
                const start_off = self.callee_starts.items[top_idx];
                const callee_idx = self.callee_storage.items[start_off + top.next_callee];
                top.next_callee += 1;

                switch (states[callee_idx]) {
                    .unseen => {
                        states[callee_idx] = .on_stack;
                        cursors[cursor_depth] = .{ .fn_idx = callee_idx, .next_callee = 0 };
                        cursor_depth += 1;
                    },
                    .on_stack => {
                        // Back edge: mark every cursor frame from `callee_idx`
                        // up to the current top as part of the cycle.
                        var k: usize = 0;
                        while (k < cursor_depth and cursors[k].fn_idx != callee_idx) : (k += 1) {}
                        while (k < cursor_depth) : (k += 1) {
                            self.functions.items[cursors[k].fn_idx].row.recursive = true;
                        }
                    },
                    .done => {},
                }
            }
        }
    }

    fn isFunctionNode(self: *const Analyzer, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        return tag == .function_decl or tag == .function_expr or tag == .arrow_function;
    }

    fn identifierName(self: *const Analyzer, node: NodeIndex) ?[]const u8 {
        if (self.ir_view.getTag(node) != .identifier) return null;
        const binding = self.ir_view.getBinding(node) orelse return null;
        return self.resolveAtomName(binding.name_atom);
    }

    fn resolveAtomName(self: *const Analyzer, atom_value: u32) ?[]const u8 {
        const atom: object.Atom = @enumFromInt(atom_value);
        if (atom.isPredefined()) return atom.toPredefinedName();
        if (self.atoms) |table| return table.getName(atom);
        return null;
    }
};

fn isNonDeterministic(object_name: []const u8, property_name: []const u8) bool {
    if (std.mem.eql(u8, object_name, "Date") and std.mem.eql(u8, property_name, "now")) return true;
    if (std.mem.eql(u8, object_name, "Math") and std.mem.eql(u8, property_name, "random")) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const JsParser = @import("parser/root.zig").JsParser;
const module_manifest = @import("module_manifest.zig");

test "leaf pure function has empty effect row" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, "function clean(s) { return s; }");
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const row = analyzer.lookup("clean") orelse return error.FunctionNotFound;
    try testing.expect(row.pure);
    try testing.expect(row.deterministic);
    try testing.expect(!row.recursive);
    try testing.expect(!row.has_egress);
}

test "Date.now marks the enclosing function non-deterministic" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, "function nowSeconds() { return Date.now(); }");
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const row = analyzer.lookup("nowSeconds") orelse return error.FunctionNotFound;
    try testing.expect(!row.deterministic);
    try testing.expect(!row.pure);
}

test "Date.now inside durable step callback preserves determinism" {
    const allocator = std.testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator,
        \\import { step } from "zttp:durable";
        \\function handler(req) { return step("ts", () => Date.now()); }
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);
    const row = analyzer.lookup("handler") orelse return error.FunctionNotFound;
    try std.testing.expect(row.deterministic);
    try std.testing.expect(!row.pure);
}

test "Date.now as eager durable step argument is non-deterministic" {
    const allocator = std.testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator,
        \\import { step } from "zttp:durable";
        \\function handler(req) { return step("ts", Date.now()); }
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);
    const row = analyzer.lookup("handler") orelse return error.FunctionNotFound;
    try std.testing.expect(!row.deterministic);
    try std.testing.expect(!row.pure);
}

test "transitive non-determinism flows through callers" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\function inner() { return Date.now(); }
        \\function outer() { return inner(); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const outer = analyzer.lookup("outer") orelse return error.FunctionNotFound;
    try testing.expect(!outer.deterministic);
    try testing.expect(!outer.pure);
}

test "self-recursive function is flagged" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, "function loop(n) { return loop(n); }");
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const row = analyzer.lookup("loop") orelse return error.FunctionNotFound;
    try testing.expect(row.recursive);
}

test "mutual recursion is flagged for both participants" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\function a(n) { return b(n); }
        \\function b(n) { return a(n); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const a_row = analyzer.lookup("a") orelse return error.FunctionNotFound;
    const b_row = analyzer.lookup("b") orelse return error.FunctionNotFound;
    try testing.expect(a_row.recursive);
    try testing.expect(b_row.recursive);
}

test "Math.random marks function non-deterministic" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, "function pick() { return Math.random(); }");
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const row = analyzer.lookup("pick") orelse return error.FunctionNotFound;
    try testing.expect(!row.deterministic);
}

test "pure helper next to non-deterministic helper stays pure" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\function clean(s) { return s; }
        \\function rnd() { return Math.random(); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const clean = analyzer.lookup("clean") orelse return error.FunctionNotFound;
    const rnd = analyzer.lookup("rnd") orelse return error.FunctionNotFound;
    try testing.expect(clean.deterministic);
    try testing.expect(clean.pure);
    try testing.expect(!rnd.deterministic);
}

test "calling a write-classified import marks the function as writing" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\import { cacheSet } from "zttp:cache";
        \\function store(k) { return cacheSet("ns", k, "v"); }
        \\function clean(s) { return s; }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const store = analyzer.lookup("store") orelse return error.FunctionNotFound;
    const clean = analyzer.lookup("clean") orelse return error.FunctionNotFound;
    try testing.expect(store.writes);
    try testing.expect(!store.readOnly());
    try testing.expect(!clean.writes);
    try testing.expect(clean.readOnly());
}

test "write effect propagates transitively to callers" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\import { cacheSet } from "zttp:cache";
        \\function inner(k) { return cacheSet("ns", k, "v"); }
        \\function outer(k) { return inner(k); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const outer = analyzer.lookup("outer") orelse return error.FunctionNotFound;
    try testing.expect(outer.writes);
}

test "partner write-classified import marks function and callers as writing" {
    const allocator = testing.allocator;

    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:stripe",
        \\  "exports": [
        \\    { "name": "chargeCard", "effect": "write", "returns": "result" }
        \\  ]
        \\}
    ;
    var manifest = try module_manifest.parse(allocator, manifest_json);

    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    registry.register(manifest) catch |err| {
        manifest.deinit(allocator);
        return err;
    };

    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\import { chargeCard } from "zttp-ext:stripe";
        \\function charge(tok) { return chargeCard(tok); }
        \\function wrapper(tok) { return charge(tok); }
        \\function clean(tok) { return tok; }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.initWithManifestRegistry(allocator, view, &atoms, &registry);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const charge = analyzer.lookup("charge") orelse return error.FunctionNotFound;
    const wrapper = analyzer.lookup("wrapper") orelse return error.FunctionNotFound;
    const clean = analyzer.lookup("clean") orelse return error.FunctionNotFound;

    try testing.expect(charge.writes);
    try testing.expect(!charge.readOnly());
    try testing.expect(wrapper.writes);
    try testing.expect(!wrapper.readOnly());
    try testing.expect(!clean.writes);
    try testing.expect(clean.readOnly());
}

test "a tightened export carries only what it reaches" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `zttp:auth` declares crypto + clock at module level. `parseBearer` splits
    // a header string and reaches neither, so charging it both made every
    // ceiling over a bearer-parsing helper wrong on its face - the concrete
    // case D2 2 names. `jwtVerify` genuinely reaches both and must keep them.
    const source =
        \\import { parseBearer, jwtVerify } from "zttp:auth";
        \\function readToken(h) { return parseBearer(h); }
        \\function checkToken(t, s) { return jwtVerify(t, s); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const read_token = analyzer.lookup("readToken") orelse return error.FunctionNotFound;
    try testing.expectEqual(@as(usize, 0), read_token.capabilities.count());

    const check_token = analyzer.lookup("checkToken") orelse return error.FunctionNotFound;
    try testing.expect(check_token.capabilities.contains(.crypto));
    try testing.expect(check_token.capabilities.contains(.clock));
}

test "uuid does not reach the clock, ulid does" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `zttp:id` declares clock + random. Only `ulid` reads the clock, for its
    // timestamp prefix; a v4 uuid carries no timestamp. A deterministic handler
    // that mints uuids should not have to declare a clock it never reads.
    const source =
        \\import { uuid, ulid } from "zttp:id";
        \\function mintUuid() { return uuid(); }
        \\function mintUlid() { return ulid(); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const mint_uuid = analyzer.lookup("mintUuid") orelse return error.FunctionNotFound;
    try testing.expect(mint_uuid.capabilities.contains(.random));
    try testing.expect(!mint_uuid.capabilities.contains(.clock));

    const mint_ulid = analyzer.lookup("mintUlid") orelse return error.FunctionNotFound;
    try testing.expect(mint_ulid.capabilities.contains(.random));
    try testing.expect(mint_ulid.capabilities.contains(.clock));
}

test "base64 does not reach crypto, sha256 does" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `zttp:crypto` declares `.crypto` for the whole module, but base64 is a
    // transport encoding: both impls are `std.base64` over the module allocator
    // and reach no gated helper. Charging them `.crypto` made a handler that
    // only encodes a payload declare a cryptographic capability it never uses.
    const source =
        \\import { base64Encode, sha256 } from "zttp:crypto";
        \\function encode(s) { return base64Encode(s); }
        \\function digest(s) { return sha256(s); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const encode_fn = analyzer.lookup("encode") orelse return error.FunctionNotFound;
    try testing.expectEqual(@as(usize, 0), encode_fn.capabilities.count());

    const digest_fn = analyzer.lookup("digest") orelse return error.FunctionNotFound;
    try testing.expect(digest_fn.capabilities.contains(.crypto));
}

test "a websocket room snapshot does not reach the network" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `zttp:websocket` declares six capabilities and charged every export all
    // six. Traced through dispatch -> runtime callback -> pool: `send` writes
    // to the socket fd, `getWebSockets` takes a locked map snapshot and touches
    // nothing else. Charging a room listing for network, filesystem, clock, and
    // policy_check is the largest over-approximation in the module set.
    const source =
        \\import { send, getWebSockets } from "zttp:websocket";
        \\function listRoom(room) { return getWebSockets(room); }
        \\function reply(ws, msg) { return send(ws, msg); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const list_room = analyzer.lookup("listRoom") orelse return error.FunctionNotFound;
    try testing.expect(list_room.capabilities.contains(.runtime_callback));
    try testing.expect(!list_room.capabilities.contains(.network));
    try testing.expect(!list_room.capabilities.contains(.filesystem));

    // The socket write keeps network: narrowing must not drop what a call
    // really reaches.
    const reply_fn = analyzer.lookup("reply") orelse return error.FunctionNotFound;
    try testing.expect(reply_fn.capabilities.contains(.network));
}

test "a discarded write-effect clock read does not demote determinism" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `logInfo` reads the clock for its timestamp, which reaches stderr and
    // stops. The response is identical across runs, so the handler stays
    // deterministic. Demoting it was a false negative on the Spec surface: an
    // author could no longer declare `deterministic` on a handler that merely
    // logs.
    const source =
        \\import { logInfo } from "zttp:log";
        \\function handler(req) {
        \\  logInfo("served", {});
        \\  return Response.json({ ok: true });
        \\}
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const h = analyzer.lookup("handler") orelse return error.FunctionNotFound;
    try testing.expect(h.deterministic);
    // The write still counts: `read_only` and `retry_safe` are unaffected by
    // this rule, which is why `idempotent` does not come back with it.
    try testing.expect(h.writes);
}

test "a bound write-effect result still demotes determinism" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // Same call, but its result is bound and returned, so the clock-derived
    // value can reach the response. The exemption turns on the value being
    // thrown away, not on the callee being a logger.
    const source =
        \\import { logInfo } from "zttp:log";
        \\function handler(req) {
        \\  const r = logInfo("served", {});
        \\  return Response.json({ r: r });
        \\}
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const h = analyzer.lookup("handler") orelse return error.FunctionNotFound;
    try testing.expect(!h.deterministic);
}

test "a read-effect clock or random call still demotes determinism" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `uuid()` is read-effect and its value is the answer, so the exemption
    // must not reach it. This is the false proof the rule exists to stop.
    const source =
        \\import { uuid } from "zttp:id";
        \\function handler(req) { return Response.json({ id: uuid() }); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const h = analyzer.lookup("handler") orelse return error.FunctionNotFound;
    try testing.expect(!h.deterministic);
}

test "an export with no declared set inherits its module's" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `zttp:env` declares env + policy_check at module level and its one export
    // declares nothing, so the export inherits both. This is the migration
    // default: an untightened binding behaves exactly as it did before
    // per-export capabilities existed.
    const source =
        \\import { env } from "zttp:env";
        \\function region() { return env("REGION"); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const region = analyzer.lookup("region") orelse return error.FunctionNotFound;
    try testing.expect(region.capabilities.contains(.env));
    try testing.expect(region.capabilities.contains(.policy_check));
}

test "a partner module's declared capabilities reach the caller's row" {
    const allocator = testing.allocator;

    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:stripe",
        \\  "requiredCapabilities": ["network", "clock"],
        \\  "exports": [
        \\    { "name": "chargeCard", "effect": "write", "returns": "result" }
        \\  ]
        \\}
    ;
    var manifest = try module_manifest.parse(allocator, manifest_json);

    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    registry.register(manifest) catch |err| {
        manifest.deinit(allocator);
        return err;
    };

    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\import { chargeCard } from "zttp-ext:stripe";
        \\function charge(tok) { return chargeCard(tok); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.initWithManifestRegistry(allocator, view, &atoms, &registry);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    // Before this, the union was guarded by the built-in table alone, so a
    // partner call carried no capability at all and no ceiling or budget
    // could ever bound it.
    const charge = analyzer.lookup("charge") orelse return error.FunctionNotFound;
    try testing.expect(charge.capabilities.contains(.network));
    try testing.expect(charge.capabilities.contains(.clock));
    try testing.expect(!charge.capabilities.contains(.random));
}

test "a module neither registry resolves fails closed with every capability" {
    const allocator = testing.allocator;

    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\import { thing } from "zttp-ext:unregistered";
        \\function use(x) { return thing(x); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const use = analyzer.lookup("use") orelse return error.FunctionNotFound;
    try testing.expectEqual(
        CapabilitySet.initFull().count(),
        use.capabilities.count(),
    );
}

test "a named helper passed as a callback reaches the caller's row" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `fmt` is called by `map`, but never through a call node this walk sees:
    // the callee is `items.map` and `fmt` is only an argument. Without the
    // argument-site edge, `fmt`'s capabilities stayed out of `render`'s row
    // entirely and any ceiling on `render` was checked against a set missing
    // them.
    const source =
        \\import { env } from "zttp:env";
        \\function fmt(x) { return env("PREFIX") + x; }
        \\function render(items) { return items.map(fmt); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const fmt = analyzer.lookup("fmt") orelse return error.FunctionNotFound;
    const render = analyzer.lookup("render") orelse return error.FunctionNotFound;
    try testing.expect(fmt.capabilities.contains(.env));
    try testing.expect(render.capabilities.contains(.env));
}

test "a call through a function-typed parameter marks the row a lower bound" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `f` is a parameter, so its body is invisible here. Leaving the row
    // untouched claimed the callee reaches nothing, which is an
    // under-approximation stated as a proof.
    const source =
        \\function apply(f, n) { return f(n); }
        \\function direct(n) { return n + 1; }
        \\function callsDirect(n) { return direct(n); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const apply = analyzer.lookup("apply") orelse return error.FunctionNotFound;
    try testing.expect(apply.lower_bound);

    // A call this can resolve is not a lower bound, in either direction.
    const direct = analyzer.lookup("direct") orelse return error.FunctionNotFound;
    const calls_direct = analyzer.lookup("callsDirect") orelse return error.FunctionNotFound;
    try testing.expect(!direct.lower_bound);
    try testing.expect(!calls_direct.lower_bound);
}

test "a lower bound propagates to callers" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\function apply(f, n) { return f(n); }
        \\function outer(n) { return apply(direct, n); }
        \\function direct(n) { return n + 1; }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const outer = analyzer.lookup("outer") orelse return error.FunctionNotFound;
    try testing.expect(outer.lower_bound);
}

test "a hole does not make the enclosing row a lower bound" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // A hole is a known unknown: the compiler put it there. If it marked the
    // row a lower bound, no ceiling could discharge and the promise that the
    // rest of the program still verifies would be empty.
    const source = "function pending(x) { return hole(); }";
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const pending = analyzer.lookup("pending") orelse return error.FunctionNotFound;
    try testing.expect(!pending.lower_bound);
}

test "a call to a runtime-provided global is not a lower bound" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `range` and `renderToString` are provided by the runtime and reach no
    // capability. Marking them would turn every JSX handler into a lower
    // bound and drown the signal that the flag exists to carry.
    const source = "function rows(n) { return range(n); }";
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const rows = analyzer.lookup("rows") orelse return error.FunctionNotFound;
    try testing.expect(!rows.lower_bound);
}

test "empty program is a no-op" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, "");
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);
    try testing.expectEqual(@as(usize, 0), analyzer.all().len);
}

const import_corpus = @import("tests/import_corpus.zig");

test "the import scan records every specifier across the shared corpus" {
    // Replaces the differential test that proved this scan matches the pre-C1
    // implementation (commit e14b4e77). The expectations below were captured
    // from that proven implementation, which is why they are trustworthy: the
    // legacy scan they were compared against no longer exists.
    const allocator = std.testing.allocator;

    const expected = [_]struct { label: []const u8, count: u32 }{
        .{ .label = "no imports at all", .count = 0 },
        .{ .label = "one builtin import", .count = 1 },
        .{ .label = "several names from one module", .count = 3 },
        .{ .label = "the same module imported twice", .count = 2 },
        // Two import declarations of one name collapse to one slot: the map is
        // keyed by local binding slot, and the second import reuses it.
        .{ .label = "the same name imported twice", .count = 1 },
        .{ .label = "an aliased import", .count = 1 },
        .{ .label = "a builtin function with no extractions and no flags", .count = 1 },
        .{ .label = "a module that is neither builtin nor registered", .count = 1 },
        .{ .label = "a builtin and an unresolved module together", .count = 2 },
        .{ .label = "several modules in first-appearance order", .count = 3 },
    };
    try std.testing.expectEqual(import_corpus.cases.len, expected.len);

    for (import_corpus.cases, expected) |case, want| {
        try std.testing.expectEqualStrings(case.label, want.label);

        var parser = try @import("parser/parse.zig").Parser.init(allocator, case.source);
        defer parser.deinit();
        var atoms = atom_table.AtomTable.init(allocator);
        defer atoms.deinit();
        parser.setAtomTable(&atoms);
        _ = try parser.parse();
        const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

        var analyzer = Analyzer.init(allocator, ir_view, &atoms);
        defer analyzer.deinit();
        try analyzer.scanImports();

        std.testing.expectEqual(want.count, analyzer.imports.count()) catch |err| {
            std.debug.print("\ncorpus case \"{s}\": expected {d} imports, found {d}\n", .{
                case.label, want.count, analyzer.imports.count(),
            });
            return err;
        };
    }
}

test "this analyzer records imports from unresolved modules" {
    // The filter difference that must SURVIVE the migration. strict_checker and
    // effect_inference record every import; the other four record builtins
    // only. A migration that unified the six filters would silently widen
    // analysis, so it is asserted here rather than assumed.
    const allocator = std.testing.allocator;
    const source = "import { thing } from \"zttp-ext:unknown\";\n";

    var parser = try @import("parser/parse.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var analyzer = Analyzer.init(allocator, ir_view, &atoms);
    defer analyzer.deinit();
    try analyzer.scanImports();

    try std.testing.expectEqual(@as(u32, 1), analyzer.imports.count());
    var it = analyzer.imports.iterator();
    const entry = it.next().?;
    try std.testing.expectEqualStrings("zttp-ext:unknown", entry.value_ptr.module);
    try std.testing.expectEqualStrings("thing", entry.value_ptr.name);
}
