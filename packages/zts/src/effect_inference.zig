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
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const atom_table = @import("zts-engine").atom_table;
const module_binding = @import("zts-engine").module_binding;
const builtin_modules = @import("zts-engine").builtin_modules;
const manifest_registry_mod = @import("manifest_registry.zig");
const module_facts_mod = @import("module_facts.zig");
const route_resolution = @import("route_resolution.zig");
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");
const bool_checker = @import("bool_checker.zig");
const known_globals = @import("zts-base").known_globals;

const NodeIndex = ir.NodeIndex;
const IrView = ir.IrView;
const null_node = ir.null_node;
const Capability = module_binding.ModuleCapability;

pub const CapabilitySet = std.EnumSet(Capability);

/// A callee that reads the clock or draws randomness can return a different
/// value on the next run, so its caller is not deterministic.
fn reachesClockOrRandom(caps: CapabilitySet) bool {
    return caps.contains(.clock) or caps.contains(.random);
}

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

/// The `owner` passed to the walk while a module-level initializer is being
/// walked. It equals no function index, so no edge is mistaken for
/// self-recursion and no parameter type is looked up.
const module_scope_owner: usize = std.math.maxInt(usize);

/// A module-level binding that may hold function values. Its `row` and
/// `users` are what a reference to it charges: the row is the effects of the
/// imports and closures in its initializer, and `users` is every user
/// function that initializer calls or holds. `refs` names the other module
/// bindings it mentions, resolved to a fixed point so an alias of an alias
/// carries the whole set.
const ModuleBinding = struct {
    key: u32,
    init_node: NodeIndex,
    row: EffectRow = .{},
    users: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,
    refs: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,
    /// Module bindings this initializer makes a member call through
    /// (`other.f()`). Whether that is a lower bound depends on whether
    /// `other` holds a function, which is only known after the closure.
    rooted_calls: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,
    /// True when the initializer, or a binding it mentions, holds a function
    /// value. A plain data object stays false and charges nothing.
    holds: bool = false,

    fn deinit(self: *ModuleBinding, allocator: std.mem.Allocator) void {
        self.users.deinit(allocator);
        self.refs.deinit(allocator);
        self.rooted_calls.deinit(allocator);
    }
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
    /// Type environment for reading a function-typed parameter's declared
    /// ceiling. Borrowed and optional: without it a call through a parameter
    /// stays a lower bound, which is the conservative answer this had before
    /// the type env was available at all.
    type_env: ?*const type_env_mod.TypeEnv = null,
    /// Map binding slot to index into `functions`. Used to resolve identifier
    /// callees back to a user-defined function.
    user_fn_by_slot: std.AutoHashMapUnmanaged(u16, usize),
    /// CSR-encoded direct callees per function: callee_starts[i..i+1] selects
    /// a slice of callee_storage holding the callees of function i. Has
    /// `fn_count + 1` entries with a trailing sentinel.
    callee_starts: std.ArrayListUnmanaged(u32),
    callee_storage: std.ArrayListUnmanaged(usize),
    /// CSR-encoded function-value references per function, beside the call
    /// edges. A reference to a function is not a call: `const t = [b]` makes
    /// `b` reachable and charges its row to the owner, but it must not make the
    /// owner recursive when `b` refers back. `propagate` and the reachability
    /// walks read both stores; `detectRecursion` and `reachesRecursion` read
    /// `callee_*` only.
    value_starts: std.ArrayListUnmanaged(u32),
    value_storage: std.ArrayListUnmanaged(usize),
    /// Functions already recorded as value references of the function being
    /// walked. Cleared per function.
    seen_values: std.AutoHashMapUnmanaged(usize, void),
    /// Module-level bindings whose initializer is not itself a function: an
    /// object or array of functions, an alias of an import, an alias of
    /// another such binding. One row and one function set per binding, built
    /// by `computeModuleBindings` before any function body is walked.
    module_bindings: std.ArrayListUnmanaged(ModuleBinding),
    /// `bool_checker.packBindingKey` of a declaration -> index in
    /// `module_bindings`.
    module_by_key: std.AutoHashMapUnmanaged(u32, usize),
    /// Set while the module-scope pass walks one initializer. Edges and
    /// module references found then belong to that binding, not to a
    /// function's CSR rows.
    module_acc: ?*ModuleBinding = null,
    /// Counts function values the walk has met: an import, a user function,
    /// a function-holding module binding, or a closure created in place. A
    /// caller reads the difference across a subtree to learn whether that
    /// subtree created or referenced one.
    fn_value_count: u32 = 0,
    /// Name atoms of body-local bindings whose initializer created or
    /// referenced a function value (`const o = { f: w }`). A member call on
    /// such a binding is a lower bound. Keyed by name, not slot, because a
    /// closure sees the binding as an upvalue with a different slot; a name
    /// reused for an unrelated local only makes the answer more conservative.
    /// Cleared per function and per module initializer.
    holding_names: std.AutoHashMapUnmanaged(u16, void),
    /// The call node whose result the enclosing statement throws away, or
    /// `null_node`. Set only for the outermost call of an `expr_stmt`, so a
    /// nested call inside that statement is not mistaken for a discarded one.
    discarded_call: NodeIndex = null_node,
    /// Inline route functions currently being folded into an owner's row.
    /// Named routes use the ordinary call graph recursion machinery.
    inline_route_stack: std.AutoHashMapUnmanaged(NodeIndex, void),

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
            .value_starts = .empty,
            .value_storage = .empty,
            .seen_values = .empty,
            .module_bindings = .empty,
            .module_by_key = .empty,
            .holding_names = .empty,
            .inline_route_stack = .empty,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        if (self.owned_facts) |*owned| owned.deinit();
        self.functions.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.user_fn_by_slot.deinit(self.allocator);
        self.callee_starts.deinit(self.allocator);
        self.callee_storage.deinit(self.allocator);
        self.value_starts.deinit(self.allocator);
        self.value_storage.deinit(self.allocator);
        self.seen_values.deinit(self.allocator);
        for (self.module_bindings.items) |*mb| mb.deinit(self.allocator);
        self.module_bindings.deinit(self.allocator);
        self.module_by_key.deinit(self.allocator);
        self.holding_names.deinit(self.allocator);
        self.inline_route_stack.deinit(self.allocator);
    }

    pub fn analyze(self: *Analyzer, root: NodeIndex) !void {
        try self.scanImports();
        try self.collectFunctions(root);
        try self.computeModuleBindings(root);
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

    /// Build the row and function set of every module-level binding whose
    /// initializer is not a function. A function body that mentions such a
    /// binding is charged what it holds (`chargeModuleBinding`).
    ///
    /// Charging at the reference matters because a module-level object or
    /// alias reaches a handler through names the handler never spells out as
    /// the function: `ops.save()`, `helper(ops)`, `save()` for
    /// `const save = cacheSet`. The initializer is walked as a function body
    /// is, closures included, so a write that sits in callee position inside
    /// a closure is charged too.
    ///
    /// Every binding is registered before any initializer is walked, so a
    /// closure may mention a binding declared further down. The sets are then
    /// closed over module-to-module references until nothing grows.
    fn computeModuleBindings(self: *Analyzer, root: NodeIndex) !void {
        try self.registerModuleBindings(root);
        const count = self.module_bindings.items.len;
        if (count == 0) return;

        for (0..count) |i| {
            const mb = &self.module_bindings.items[i];
            var scratch: std.AutoHashMapUnmanaged(usize, void) = .empty;
            defer scratch.deinit(self.allocator);
            self.module_acc = mb;
            defer self.module_acc = null;
            self.holding_names.clearRetainingCapacity();
            const before = self.fn_value_count;
            try self.walkBaseExpr(mb.init_node, module_scope_owner, &mb.row, &scratch);
            mb.holds = self.fn_value_count != before;
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (self.module_bindings.items, 0..) |*mb, i| {
                for (self.module_bindings.items, 0..) |*other, j| {
                    if (!mb.refs.contains(j)) continue;
                    // R4 for a closure in this initializer: a member call
                    // through a binding that holds a function is a lower
                    // bound, including a binding reached through itself.
                    if (mb.rooted_calls.contains(j) and other.holds and !mb.row.lower_bound) {
                        mb.row.lower_bound = true;
                        changed = true;
                    }
                    if (i == j) continue;
                    var merged = mb.row.merge(other.row);
                    // Whether a binding is recursive is no property of the
                    // functions it holds.
                    merged.recursive = mb.row.recursive;
                    if (!merged.eql(mb.row)) {
                        mb.row = merged;
                        changed = true;
                    }
                    if (other.holds and !mb.holds) {
                        mb.holds = true;
                        changed = true;
                    }
                    for (other.users.keys()) |user| {
                        const gop = try mb.users.getOrPut(self.allocator, user);
                        if (!gop.found_existing) changed = true;
                    }
                }
            }
        }
    }

    fn registerModuleBindings(self: *Analyzer, node: NodeIndex) WalkError!void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    try self.registerModuleBindings(self.ir_view.getListIndex(block.stmts_start, @intCast(i)));
                }
            },
            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                try self.registerModuleBindings(export_decl.declaration);
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                // A function-valued initializer is a unit with its own row;
                // `userFnOf` already resolves a reference to it.
                if (decl.init == null_node or self.isFunctionNode(decl.init)) return;
                const key = bool_checker.packBindingKey(decl.binding.scope_id, decl.binding.slot);
                const idx = self.module_bindings.items.len;
                try self.module_bindings.append(self.allocator, .{ .key = key, .init_node = decl.init });
                try self.module_by_key.put(self.allocator, key, idx);
            },
            // exhaustive: only a top-level `var_decl` binds a module value.
            // Statements at module scope run at load, not per request.
            else => {},
        }
    }

    /// The module-level binding a reference names, or null.
    fn moduleBindingOf(self: *const Analyzer, binding: ir.BindingRef) ?usize {
        if (!slotIsAtom(binding)) return null;
        return self.module_by_key.get(bool_checker.packBindingKey(binding.scope_id, binding.slot));
    }

    /// Charge a reference to a function-holding module binding: its row joins
    /// the owner's and every user function it holds gets a value edge. While
    /// the module pass itself is walking, the reference is only recorded for
    /// the closure over module-to-module references.
    fn chargeModuleBinding(
        self: *Analyzer,
        binding: ir.BindingRef,
        owner: usize,
        row: *EffectRow,
        seen_users: *const std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        const idx = self.moduleBindingOf(binding) orelse return;
        if (self.module_acc) |acc| {
            try acc.refs.put(self.allocator, idx, {});
            return;
        }
        const mb = &self.module_bindings.items[idx];
        if (!mb.holds) return;
        self.fn_value_count += 1;
        var merged = row.merge(mb.row);
        merged.recursive = row.recursive;
        row.* = merged;
        for (mb.users.keys()) |user| try self.addValueEdge(user, owner, seen_users);
    }

    fn computeBaseEffects(self: *Analyzer) !void {
        const fn_count = self.functions.items.len;
        try self.callee_starts.resize(self.allocator, fn_count + 1);
        try self.value_starts.resize(self.allocator, fn_count + 1);
        for (0..fn_count) |i| {
            self.callee_starts.items[i] = @intCast(self.callee_storage.items.len);
            self.value_starts.items[i] = @intCast(self.value_storage.items.len);
            self.seen_values.clearRetainingCapacity();
            self.holding_names.clearRetainingCapacity();
            var seen_users: std.AutoHashMapUnmanaged(usize, void) = .empty;
            defer seen_users.deinit(self.allocator);
            var row: EffectRow = .{};
            try self.walkBaseExpr(self.functions.items[i].body_node, i, &row, &seen_users);
            if (std.mem.eql(u8, self.functions.items[i].name, "handler")) {
                try self.contributeRouteRoots(i, &row, &seen_users);
            }
            self.functions.items[i].row = row;
            // Snapshot the direct capability set before propagation unions in
            // the rows of transitively-called user functions.
            self.functions.items[i].direct_caps = row.capabilities;
        }
        self.callee_starts.items[fn_count] = @intCast(self.callee_storage.items.len);
        self.value_starts.items[fn_count] = @intCast(self.value_storage.items.len);
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

    /// Functions that function `fn_idx` references as values without calling
    /// them. A reachability walk must follow these as well as `calleesOf`: a
    /// referenced helper can be called, so counting it reachable is the
    /// conservative direction.
    pub fn valueRefsOf(self: *const Analyzer, fn_idx: usize) []const usize {
        const start = self.value_starts.items[fn_idx];
        const end = self.value_starts.items[fn_idx + 1];
        return self.value_storage.items[start..end];
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
                // A function value created in a body is charged to that body,
                // initializer or not. `collectFunctionsIn` reads top-level
                // statements only, so a closure declared here is no unit's
                // row; skipping it here too left its effects in nobody's.
                // Passed on as a value (`items.forEach(w)`) it then charged
                // nothing, and the owner proved `read_only` for a write.
                if (decl.init != null_node) {
                    const before = self.fn_value_count;
                    try self.walkBaseExpr(decl.init, owner, row, seen_users);
                    // The binding now holds a function value, so a member call
                    // through it reaches code this walk cannot name.
                    if (self.fn_value_count != before) {
                        try self.holding_names.put(self.allocator, decl.binding.name_atom, {});
                    }
                }
            },
            .function_decl => {
                // Same rule for a nested declaration: it is not a unit, so
                // its body is walked into the owner where it is declared.
                const decl = self.ir_view.getVarDecl(node) orelse return;
                if (decl.init != null_node) {
                    try self.walkBaseExpr(decl.init, owner, row, seen_users);
                }
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
                // A bare identifier callee was resolved and charged by
                // `handleCall`. Walking it as a value reference as well would
                // charge an import twice, and a discarded `logInfo(...)` would
                // lose the sink exemption that call carries: the leaf charge
                // has no discarded-call context. Every other callee shape
                // (`items.filter(a).map(b)`, `f().g()`, `o.f`) is walked.
                if (self.ir_view.getTag(call.callee) != .identifier) {
                    try self.walkBaseExpr(call.callee, owner, row, seen_users);
                }
                for (0..call.args_count) |i| {
                    const arg = self.ir_view.getListIndex(call.args_start, @intCast(i));
                    // A named helper handed to a callback slot (`items.map(fmt)`)
                    // is called, but never through a call node this walk can
                    // see: the callee is `items.map`, and `fmt` is only an
                    // argument. Without an edge here the helper's capabilities
                    // stay out of the caller's row entirely. This stays a call
                    // edge, not a value reference: recursion through a callback
                    // (`a` maps `b`, `b` calls `a`) is real recursion.
                    try self.recordFunctionValueArg(arg, owner, seen_users);
                    try self.walkBaseExpr(arg, owner, row, seen_users);
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
                self.fn_value_count += 1;
                if (self.ir_view.getFunction(node)) |func| {
                    try self.walkBaseStmt(func.body, owner, row, seen_users);
                }
            },
            // A function value is charged where it is referenced, wherever it
            // goes next: a callback slot, a local alias, an object member, an
            // array element. Charging only at argument position left every
            // other route (`const f = cacheSet; items.forEach(f)`,
            // `{ f: w }.f()`) proving `read_only` for a write.
            .identifier => try self.chargeValueReference(node, owner, row, seen_users),
            // exhaustive: the remaining tags are literals and other leaves
            // with no sub-expression that could reach a capability.
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
            if (isNonDeterministic(op.object, op.property)) {
                row.deterministic = false;
                row.pure = false;
            }
        }

        // `found.handler(...)` is an indirect call, but a stable literal
        // `routerMatch` table makes its target set finite. Add every resolved
        // route to the owner's call graph. An unstable table, route value, or
        // selected result leaves the row as a lower bound, so no property can
        // treat missing route effects as proof that they are absent.
        if (try self.contributeRouteDispatch(call.callee, owner, row, seen_users)) return;

        try self.markCallThroughHolder(call.callee, row);

        if (self.ir_view.getTag(call.callee) != .identifier) return;
        const binding = self.ir_view.getBinding(call.callee) orelse return;

        if (self.importOf(binding)) |imported| {
            var reached: EffectRow = .{};
            self.insertModuleCapabilities(imported.module, imported.name, &reached);
            row.capabilities.setUnion(reached.capabilities);
            // A call that reads the clock or draws randomness returns something
            // different next time, so the enclosing function is not
            // deterministic. Only `Date.now` and `Math.random` cleared this
            // flag, so `uuid()` reported `deterministic ... PROVEN` - a false
            // proof, and one a handler could then declare in a `Proof<T, P>` and
            // have discharged.
            //
            // Per-export capability rows make this precise: `parseBearer`
            // declares the empty set and stays deterministic, while `jwtVerify`
            // declares `.clock` for its exp check and does not. Before those
            // rows every `zttp:auth` call carried the module union and this
            // would have demoted all five exports.
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
            // Test what this export reaches, not what it adds to the row: a
            // discarded `logInfo` earlier in the body leaves `.clock` in the row
            // without demoting it, and a later clock read would add nothing.
            if (!sinks_the_read and reachesClockOrRandom(reached.capabilities)) {
                row.deterministic = false;
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
            return;
        }

        if (self.userFnOf(binding)) |callee_idx| {
            if (callee_idx == owner) {
                // Self-recursion is captured here; non-self cycles are caught
                // during the dedicated detectRecursion pass.
                row.recursive = true;
            }
            try self.addCallEdge(callee_idx, seen_users);
            return;
        }

        // A module-level binding that holds function values
        // (`const save = cacheSet`) is charged what it holds, as a reference
        // would be. The call still goes through a value, so it also falls
        // through to the lower bound below.
        try self.chargeModuleBinding(binding, owner, row, seen_users);

        // Neither an import nor a user function: the call goes through a value.
        // Returning here left the row untouched, which reads downstream as
        // "this callee contributes nothing" - an under-approximation stated
        // with the confidence of a proof.
        if (!self.calleeIsUnresolvable(binding)) return;
        if (try self.contributeDeclaredCallbackRow(binding, owner, row)) return;
        row.lower_bound = true;
    }

    /// A call whose callee is a member or computed access rooted at a binding
    /// that holds function values (`ops.save()`, `o["f"]()`) runs a function
    /// this walk did not resolve at the call. The functions it can reach are
    /// charged at the reference, but no call edge exists, so the row is a
    /// lower bound: recursion through `ops.a()` leaves no cycle for
    /// `detectRecursion`, and `total` must not be proven for it. A receiver
    /// that holds no function (`s.toUpperCase()`, `items.map(...)`) is
    /// unchanged. Inside a module initializer the answer waits for the closure
    /// over module bindings, so the call is recorded instead.
    fn markCallThroughHolder(self: *Analyzer, callee: NodeIndex, row: *EffectRow) WalkError!void {
        var node = callee;
        var steps: usize = 0;
        while (true) : (steps += 1) {
            const tag = self.ir_view.getTag(node) orelse return;
            switch (tag) {
                .member_access, .optional_chain, .computed_access => {
                    // Reaching the root of an access chain needs at least one
                    // step: a bare identifier callee is `handleCall`'s own.
                    node = (self.ir_view.getMember(node) orelse return).object;
                },
                .identifier => break,
                // exhaustive: only an access chain rooted at an identifier
                // names a binding. A chain rooted at a call or a literal
                // (`f().g()`, `[w][0]()`) has no receiver binding to test;
                // its function values are charged where they are referenced
                // by the callee walk, and the call-result case is left to R6.
                else => return,
            }
        }
        if (steps == 0) return;
        const binding = self.ir_view.getBinding(node) orelse return;
        if (slotIsAtom(binding)) {
            const idx = self.moduleBindingOf(binding) orelse return;
            if (self.module_acc) |acc| {
                try acc.rooted_calls.put(self.allocator, idx, {});
            } else if (self.module_bindings.items[idx].holds) {
                row.lower_bound = true;
            }
            return;
        }
        if (self.holding_names.contains(binding.name_atom)) row.lower_bound = true;
    }

    fn contributeRouteDispatch(
        self: *Analyzer,
        callee: NodeIndex,
        owner: usize,
        row: *EffectRow,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!bool {
        const facts = try self.resolveFacts();
        const resolver = route_resolution.Resolver.init(self.ir_view, self.atoms, facts);
        var targets = try resolver.resolveDispatch(self.allocator, callee) orelse return false;
        defer targets.deinit(self.allocator);

        try self.contributeRouteTargets(targets.functions.items, targets.unresolved, owner, row, seen_users);
        return true;
    }

    fn contributeRouteRoots(
        self: *Analyzer,
        owner: usize,
        row: *EffectRow,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        const facts = try self.resolveFacts();
        const resolver = route_resolution.Resolver.init(self.ir_view, self.atoms, facts);
        var roots = try resolver.routeRoots(self.allocator);
        defer roots.deinit(self.allocator);
        try self.contributeRouteTargets(roots.functions.items, roots.unresolved, owner, row, seen_users);
    }

    fn contributeRouteTargets(
        self: *Analyzer,
        targets: []const NodeIndex,
        unresolved: bool,
        owner: usize,
        row: *EffectRow,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        if (unresolved) row.lower_bound = true;
        for (targets) |fn_node| {
            if (self.functionIndex(fn_node)) |callee_idx| {
                if (callee_idx == owner) row.recursive = true;
                try self.addCallEdge(callee_idx, seen_users);
                continue;
            }

            // An inline route function has no named FunctionEffect row. Walk
            // its body into the dispatching owner so its direct effects and
            // calls to named helpers still contribute to the owner's row.
            const func = self.ir_view.getFunction(fn_node) orelse {
                row.lower_bound = true;
                continue;
            };
            const active = try self.inline_route_stack.getOrPut(self.allocator, fn_node);
            if (active.found_existing) {
                row.recursive = true;
                row.lower_bound = true;
                continue;
            }
            defer _ = self.inline_route_stack.remove(fn_node);
            try self.walkBaseStmt(func.body, owner, row, seen_users);
        }
    }

    fn functionIndex(self: *const Analyzer, fn_node: NodeIndex) ?usize {
        const func = self.ir_view.getFunction(fn_node) orelse return null;
        for (self.functions.items, 0..) |function, index| {
            if (function.body_node == func.body) return index;
        }
        return null;
    }

    /// D2 section 4's I3: a function type carries an effect ceiling, so a call
    /// through a value of that type contributes the type's declared row rather
    /// than defeating the analysis.
    ///
    /// A function type with no capsule declares the empty row - spec 6.5's
    /// "its callback MUST be pure" made representable - so a pure-typed
    /// callback contributes nothing and is not a lower bound. Returns true when
    /// the declared type answered; false leaves the caller to fail closed.
    fn contributeDeclaredCallbackRow(
        self: *Analyzer,
        binding: ir.BindingRef,
        owner: usize,
        row: *EffectRow,
    ) WalkError!bool {
        if (binding.kind != .argument) return false;
        const env = self.type_env orelse return false;
        const param_type = self.declaredParamType(env, binding, owner) orelse return false;
        if (env.pool.getTag(param_type) != .t_function) return false;

        const ret = env.pool.getFunctionInfo(param_type).ret;
        if (ret == type_pool_mod.null_type_idx) return true; // no capsule: empty row

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(self.allocator);
        const status = try env.extractEffectMembers(ret, &names);
        // A payload that is not a closed union of string literals recovers no
        // names, which is indistinguishable from no annotation. ZTS511 exists
        // because that difference matters; fail closed rather than read the
        // empty list as a pure callback.
        if (status.non_literal) return false;

        if (names.items.len == 0) return true; // no capsule: the empty row

        var declared = CapabilitySet.initEmpty();
        for (names.items) |name| {
            const cap = std.meta.stringToEnum(Capability, name) orelse return false;
            declared.insert(cap);
        }
        row.capabilities.setUnion(declared);
        // Same demotions a direct module call makes: reaching a capability is
        // not pure, and reaching the clock or the RNG is not deterministic.
        if (reachesClockOrRandom(declared)) row.deterministic = false;
        row.pure = false;
        return true;
    }

    /// The declared type of `binding`, which names a parameter of the function
    /// at `owner`. Read from the owner's signature rather than the binding
    /// table, so it does not depend on the type checker's parameter pass
    /// having run.
    fn declaredParamType(
        self: *const Analyzer,
        env: *const type_env_mod.TypeEnv,
        binding: ir.BindingRef,
        owner: usize,
    ) ?type_pool_mod.TypeIndex {
        if (owner >= self.functions.items.len) return null;
        const decl_node = self.functions.items[owner].decl_node;

        const fn_node = blk: {
            const tag = self.ir_view.getTag(decl_node) orelse return null;
            if (tag == .function_expr or tag == .arrow_function) break :blk decl_node;
            break :blk (self.ir_view.getVarDecl(decl_node) orelse return null).init;
        };
        const sig = env.getFnSigAt(self.ir_view.signatureOffset(fn_node) orelse return null) orelse return null;
        const func = self.ir_view.getFunction(fn_node) orelse return null;

        for (0..func.params_count) |i| {
            if (i >= sig.param_count) return null;
            const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
            const pb = self.ir_view.paramBinding(param_idx) orelse continue;
            if (pb.slot == binding.slot) return sig.param_types[i];
        }
        return null;
    }

    /// Charge a function value at the identifier that references it, in any
    /// position but a bare callee (`handleCall` charges that one, with the
    /// discarded-call context the sink exemption needs).
    ///
    /// An import is charged to the row as a call to it would be. A user
    /// function other than the owner gets a value edge, so its row reaches the
    /// owner through `propagate` without making the owner recursive. Like the
    /// callback-argument edge this over-approximates: holding a function is
    /// taken as calling it, which can only reject, never wrongly certify.
    fn chargeValueReference(
        self: *Analyzer,
        node: NodeIndex,
        owner: usize,
        row: *EffectRow,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        const binding = self.ir_view.getBinding(node) orelse return;
        if (self.importOf(binding)) |imported| {
            self.fn_value_count += 1;
            self.chargeImportValue(imported, row);
            return;
        }
        if (self.userFnOf(binding)) |callee_idx| {
            self.fn_value_count += 1;
            try self.addValueEdge(callee_idx, owner, seen_users);
            return;
        }
        try self.chargeModuleBinding(binding, owner, row, seen_users);
    }

    /// Record a value edge from the function being walked to `callee_idx`. A
    /// callee already recorded as a call edge needs none: `propagate` merges
    /// that row already.
    fn addValueEdge(
        self: *Analyzer,
        callee_idx: usize,
        owner: usize,
        seen_users: *const std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        if (callee_idx == owner) return;
        if (self.module_acc) |acc| {
            try acc.users.put(self.allocator, callee_idx, {});
            return;
        }
        if (seen_users.contains(callee_idx)) return;
        const gop = try self.seen_values.getOrPut(self.allocator, callee_idx);
        if (!gop.found_existing) try self.value_storage.append(self.allocator, callee_idx);
    }

    /// Put an imported export's effects in `row` without a call node: the
    /// capabilities, clock or randomness, write, and egress it reaches. The
    /// determinism test reads the export's own set, not the row's delta, for
    /// the reason the doc note on `reachesClockOrRandom` gives.
    fn chargeImportValue(self: *const Analyzer, imported: ImportedFunction, row: *EffectRow) void {
        var reached: EffectRow = .{};
        self.insertModuleCapabilities(imported.module, imported.name, &reached);
        row.capabilities.setUnion(reached.capabilities);
        if (reachesClockOrRandom(reached.capabilities)) row.deterministic = false;
        row.pure = false;
        if (self.importEffect(imported.module, imported.name) == .write) row.writes = true;
        if (std.mem.eql(u8, imported.module, fetch_module_specifier) and
            std.mem.eql(u8, imported.name, fetch_sync_export))
        {
            row.has_egress = true;
        }
        // A module neither registry resolves has no effect class to read, and
        // `importEffect` answers `.none` for it, which would leave `read_only`
        // standing. `insertModuleCapabilities` already grants it every
        // capability; its write and egress classes get the same answer. The
        // case is real: `zts check` does not refuse a `zttp-ext:` specifier
        // that nothing registers.
        if (!self.moduleIsKnown(imported.module)) {
            row.writes = true;
            row.has_egress = true;
        }
    }

    fn moduleIsKnown(self: *const Analyzer, module: []const u8) bool {
        if (builtin_modules.fromSpecifier(module) != null) return true;
        const registry = self.manifest_registry orelse return false;
        return registry.fromSpecifier(module) != null;
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
        const callee_idx = self.userFnOf(binding) orelse return;
        if (callee_idx == owner) return;
        try self.addCallEdge(callee_idx, seen_users);
    }

    /// Record a call edge from the function being walked. While the module
    /// pass walks an initializer the edge belongs to that binding instead: it
    /// becomes one of the functions a reference to the binding charges.
    fn addCallEdge(
        self: *Analyzer,
        callee_idx: usize,
        seen_users: *std.AutoHashMapUnmanaged(usize, void),
    ) WalkError!void {
        if (self.module_acc) |acc| {
            try acc.users.put(self.allocator, callee_idx, {});
            return;
        }
        const gop = try seen_users.getOrPut(self.allocator, callee_idx);
        if (!gop.found_existing) try self.callee_storage.append(self.allocator, callee_idx);
    }

    /// The import a reference names, or null.
    ///
    /// `imports` is keyed by slot, and only a module-level binding carries an
    /// atom as its slot. A function local or parameter restarts at slot 0, so
    /// the fifth local of a handler shares slot 4 with whichever module
    /// binding happens to have atom 4 (`length`, for one). A slot-only lookup
    /// resolved that local to the import, charged it that import's row, and
    /// returned before `calleeIsUnresolvable` could mark the row a lower
    /// bound: the same handler was refused or proved depending on what an
    /// unrelated import was called. A module binding referenced from inside a
    /// nested closure is still `.global`, not `.upvalue`, so the filter does not
    /// lose it. A reference that precedes its declaration (`a` calling a later
    /// `b`) resolves as `.undeclared_global`, whose slot is also the atom, so
    /// that kind passes too; dropping it stopped mutual recursion being found.
    fn importOf(self: *const Analyzer, binding: ir.BindingRef) ?ImportedFunction {
        if (!slotIsAtom(binding)) return null;
        return self.imports.get(binding.slot);
    }

    /// The collected user function a reference names, or null. Same slot
    /// collision, same filter, as `importOf`.
    fn userFnOf(self: *const Analyzer, binding: ir.BindingRef) ?usize {
        if (!slotIsAtom(binding)) return null;
        return self.user_fn_by_slot.get(binding.slot);
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

    /// The receiver and property of a member call, but only when the receiver
    /// is an undeclared global.
    ///
    /// This is the sole feeder of the varying-read check, and it has to apply
    /// the same precondition as `flow_checker.isVaryingGlobalRead`, which
    /// requires `binding.kind == .undeclared_global`. Without it the two halves
    /// of one shared list disagree about what a receiver is: a helper taking a
    /// parameter named `performance` or `Date` and calling `.now()` on it was
    /// refused here while the flow checker correctly ignored it.
    fn calleeObjectProperty(self: *const Analyzer, callee: NodeIndex) ?ObjectProperty {
        if (self.ir_view.getTag(callee) != .member_access) return null;
        const member = self.ir_view.getMember(callee) orelse return null;
        // Tag first: `getBinding` decodes binding fields out of the node's raw
        // data, so calling it on a non-identifier receiver (`f().now()`,
        // `obj[k].now()`) traps on an invalid enum rather than returning null.
        if (self.ir_view.getTag(member.object) != .identifier) return null;
        const binding = self.ir_view.getBinding(member.object) orelse return null;
        // `.global` and `.undeclared_global` are both the builtin; a parameter
        // or local is neither. Accepting only `.undeclared_global` here
        // silently stopped flagging a genuine builtin bound as `.global`, which
        // the ratchet caught as a weakened proof. This matches
        // `contract_builder`'s receiver test.
        if (binding.kind != .global and binding.kind != .undeclared_global) return null;
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
                // A referenced function's row reaches the referencing one the
                // same way a called function's does. Recursion is the only
                // field that must not follow a value edge, and it is reset
                // below for both kinds.
                for (self.valueRefsOf(i)) |ref_idx| {
                    merged = merged.merge(self.functions.items[ref_idx].row);
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

        // The loop ran out of iterations with the fixed point still moving, so
        // every row here is a snapshot of an unfinished propagation: a callee
        // effect that had not yet reached its caller is absent from the
        // caller's row, and an absent effect reads as "does not have it". That
        // is the shape a proof is read off, so it surfaces as a pass rather
        // than as a failure.
        //
        // `lower_bound` is the existing word for "this row under-reports, so
        // nothing may read it as an over-approximation", which is exactly the
        // state a non-converged pass leaves behind. Marking every row refuses
        // each capsule property instead of answering it from a row that never
        // finished. Reaching this is not expected - convergence is bounded by
        // the longest acyclic chain plus one - but the bound is an assumption
        // about input shape, and an assumption that silently degrades a verdict
        // is the one that has to be made loud.
        for (self.functions.items) |*fe| fe.row.lower_bound = true;
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

/// Whether `binding.slot` is a name atom rather than a function-local index.
/// Only a module-level binding (`.global`) or a reference to one that is not
/// declared yet (`.undeclared_global`) keys on the atom; `.local`, `.argument`,
/// and `.upvalue` restart at slot 0 in every function.
fn slotIsAtom(binding: ir.BindingRef) bool {
    return binding.kind == .global or binding.kind == .undeclared_global;
}

/// Shares `known_globals.varying_reads` with `flow_checker.isVaryingGlobalRead`
/// rather than keeping a second copy. The two lists drifted apart once already:
/// neither carried `performance.now`, so a handler reading that clock proved
/// `deterministic`.
fn isNonDeterministic(object_name: []const u8, property_name: []const u8) bool {
    return known_globals.isVaryingRead(object_name, property_name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const JsParser = @import("zts-engine").parser.JsParser;
const module_manifest = @import("zts-engine").module_manifest;

fn analyzeNamedRow(source: []const u8, name: []const u8) !EffectRow {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);
    return analyzer.lookup(name) orelse error.FunctionNotFound;
}

fn analyzeHandlerRow(source: []const u8) !EffectRow {
    return analyzeNamedRow(source, "handler");
}

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

test "a call chain too deep to converge marks every row a lower bound" {
    // `propagate` is a monotone join run to a fixed point, bounded by
    // `max_iterations`. It used to fall out of that loop silently, leaving
    // rows mid-propagation: an effect that had not yet climbed to a caller is
    // simply absent from the caller's row, and absent reads as "does not have
    // it". Every capsule property is read off these fields, so the silence
    // surfaced as a pass rather than as a failure.
    //
    // Twenty functions, declared caller-first, so each iteration lifts the
    // effect exactly one hop and sixteen iterations cannot cross twenty. `f1`
    // transitively reaches `Date.now`, so answering `deterministic` for it
    // would be wrong; the row must instead refuse to be read.
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator,
        \\function f1() { return f2(); }
        \\function f2() { return f3(); }
        \\function f3() { return f4(); }
        \\function f4() { return f5(); }
        \\function f5() { return f6(); }
        \\function f6() { return f7(); }
        \\function f7() { return f8(); }
        \\function f8() { return f9(); }
        \\function f9() { return f10(); }
        \\function f10() { return f11(); }
        \\function f11() { return f12(); }
        \\function f12() { return f13(); }
        \\function f13() { return f14(); }
        \\function f14() { return f15(); }
        \\function f15() { return f16(); }
        \\function f16() { return f17(); }
        \\function f17() { return f18(); }
        \\function f18() { return f19(); }
        \\function f19() { return f20(); }
        \\function f20() { return Date.now(); }
    );
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const f1 = analyzer.lookup("f1") orelse return error.FunctionNotFound;
    // The claim is the marker, not "f1 differs from f20": a run in which the
    // chain converged after all would also show a difference, and would be
    // fine. What must never happen is an unconverged row answering a property.
    try testing.expect(f1.lower_bound);

    // And the deepest function, which needed no propagation at all, still
    // carries the effect it reads directly.
    const f20 = analyzer.lookup("f20") orelse return error.FunctionNotFound;
    try testing.expect(!f20.deterministic);
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

test "a write-classified import handed to a callback slot marks the function as writing" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\import { cacheSet } from "zttp:cache";
        \\function store(items) { return items.forEach(cacheSet); }
        \\function clean(items) { return items.map(String); }
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

test "router dispatch joins deterministic effect rows" {
    const direct = try analyzeHandlerRow(
        \\function handler(req) {
        \\  return Response.json({ now: Date.now() });
        \\}
    );
    const routed = try analyzeHandlerRow(
        \\import { routerMatch } from "zttp:router";
        \\function clock(req) { return Response.json({ now: Date.now() }); }
        \\const routes = { "GET /clock": clock };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    );

    try testing.expect(!direct.deterministic);
    try testing.expect(!routed.deterministic);
}

test "router dispatch joins read only effect rows" {
    const direct = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function handler(req) {
        \\  cacheSet("routes", "key", "value");
        \\  return Response.text("ok");
        \\}
    );
    const routed = try analyzeHandlerRow(
        \\import { routerMatch } from "zttp:router";
        \\import { cacheSet } from "zttp:cache";
        \\function write(req) {
        \\  cacheSet("routes", "key", "value");
        \\  return Response.text("ok");
        \\}
        \\const routes = { "POST /write": write };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    );

    try testing.expect(!direct.readOnly());
    try testing.expect(!routed.readOnly());
}

test "router dispatch adds route effects to the dispatching function" {
    const row = try analyzeNamedRow(
        \\import { routerMatch } from "zttp:router";
        \\import { cacheSet } from "zttp:cache";
        \\function write(req) {
        \\  cacheSet("routes", "key", "value");
        \\  return Response.text("ok");
        \\}
        \\const routes = { "POST /write": write };
        \\function dispatch(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
        \\function handler(req) { return Response.text("ok"); }
    , "dispatch");

    try testing.expect(!row.readOnly());
}

test "router roots contribute even when the handler does not dispatch" {
    const row = try analyzeHandlerRow(
        \\import { routerMatch } from "zttp:router";
        \\import { cacheSet } from "zttp:cache";
        \\function write(req) {
        \\  cacheSet("routes", "key", "value");
        \\  return Response.text("ok");
        \\}
        \\const routes = { "POST /write": write };
        \\function handler(req) {
        \\  routerMatch(routes, req);
        \\  return Response.text("ok");
        \\}
    );

    try testing.expect(!row.readOnly());
}

test "clean router dispatch keeps effect properties" {
    const row = try analyzeHandlerRow(
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.text("ok"); }
        \\const routes = { "GET /clean": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    );

    try testing.expect(row.deterministic);
    try testing.expect(row.readOnly());
    try testing.expect(!row.lower_bound);
}

test "unresolved router dispatch leaves the effect row a lower bound" {
    const row = try analyzeHandlerRow(
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.text("ok"); }
        \\function handler(req) {
        \\  const routes = { "GET /clean": clean };
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    );

    try testing.expect(row.lower_bound);
}

test "recursive inline route dispatch fails closed without recursing the analyzer" {
    const row = try analyzeHandlerRow(
        \\import { routerMatch } from "zttp:router";
        \\const routes = {
        \\  "GET /loop": (req) => {
        \\    const found = routerMatch(routes, req);
        \\    if (found === undefined) return Response.text("not found", { status: 404 });
        \\    return found.handler(req);
        \\  }
        \\};
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    );

    try testing.expect(row.recursive);
    try testing.expect(row.lower_bound);
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

test "a cache delete does not reach the clock, a get does" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // `zttp:cache` declares clock + policy_check. The clock is there to decide
    // expiry: `cacheGet` evaluates it, `cacheDelete` unlinks by key and
    // `CacheStore.delete` takes no `now_s` at all. Charging a delete for a
    // clock read makes a handler that only evicts look non-deterministic.
    const source =
        \\import { cacheGet, cacheDelete } from "zttp:cache";
        \\function evict(ns, k) { return cacheDelete(ns, k); }
        \\function lookup(ns, k) { return cacheGet(ns, k); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const evict_fn = analyzer.lookup("evict") orelse return error.FunctionNotFound;
    try testing.expect(evict_fn.capabilities.contains(.policy_check));
    try testing.expect(!evict_fn.capabilities.contains(.clock));

    const lookup_fn = analyzer.lookup("lookup") orelse return error.FunctionNotFound;
    try testing.expect(lookup_fn.capabilities.contains(.clock));
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

test "a clock read after a discarded log call still demotes determinism" {
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    // The discarded `logInfo` puts `.clock` in the row without demoting it.
    // A later call that reaches the clock then adds no new capability, so a
    // test on the newly added set saw nothing and the handler stayed
    // deterministic. The test must be on what the callee itself reaches.
    const source =
        \\import { logInfo } from "zttp:log";
        \\import { jwtVerify } from "zttp:auth";
        \\function direct(t, s) {
        \\  logInfo("served", {});
        \\  return jwtVerify(t, s);
        \\}
        \\function callback(items) {
        \\  logInfo("served", {});
        \\  return items.map(jwtVerify);
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

    const direct = analyzer.lookup("direct") orelse return error.FunctionNotFound;
    try testing.expect(!direct.deterministic);
    const callback = analyzer.lookup("callback") orelse return error.FunctionNotFound;
    try testing.expect(!callback.deterministic);
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

test "a Result combinator's row is the join of its callback's" {
    // Spec 6.1 makes the `zttp:result` combinators effect-row polymorphic: the
    // callback MAY be effectful, and the call's row is the join of the
    // callback's and its operands'. `mapResult` declares `.none` and reaches
    // nothing itself, so the join is entirely this walk's answer - nothing
    // declares it, and nothing but a test would notice if it stopped holding.
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\import { env } from "zttp:env";
        \\import { ok, mapResult } from "zttp:result";
        \\function inline_cb(r) { return mapResult(r, (x) => env("PREFIX") + x); }
        \\function named_cb(x) { return env("PREFIX") + x; }
        \\function via_named(r) { return mapResult(r, named_cb); }
        \\function pure_cb(r) { return mapResult(r, (x) => x + 1); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);

    const inline_cb = analyzer.lookup("inline_cb") orelse return error.FunctionNotFound;
    const via_named = analyzer.lookup("via_named") orelse return error.FunctionNotFound;
    const pure_cb = analyzer.lookup("pure_cb") orelse return error.FunctionNotFound;
    try testing.expect(inline_cb.capabilities.contains(.env));
    try testing.expect(via_named.capabilities.contains(.env));
    // The other half of polymorphic: a pure callback leaves the row empty. A
    // combinator that always contributed its callback's worst case would pass
    // the two assertions above and fail this one.
    try testing.expect(!pure_cb.capabilities.contains(.env));
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

test "an effectful arm contributes its effect to the row" {
    // Spec 5.5 admits effectful arm expressions and calls `match` the
    // idiomatic effectful selection form. Every arm is walked into the same
    // row, so a call in the second arm is not lost because the first arm is
    // pure - taking the first arm's row would report a pure function.
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\import { logInfo } from "zttp:log";
        \\function choose(tag) {
        \\  return match (tag) {
        \\    when "quiet": 0,
        \\    when "loud": logInfo("hi")
        \\  };
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

    const choose = analyzer.lookup("choose") orelse return error.FunctionNotFound;
    try testing.expect(!choose.pure);
}

test "a match whose arms are all pure keeps a pure row" {
    // The control: without it the test above passes for a checker that calls
    // every match impure.
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\function choose(tag) {
        \\  return match (tag) {
        \\    when "quiet": 0,
        \\    when "loud": 1
        \\  };
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

    const choose = analyzer.lookup("choose") orelse return error.FunctionNotFound;
    try testing.expect(choose.pure);
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

        var parser = try @import("zts-engine").parser.JsParser.init(allocator, case.source);
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

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
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

test "a local whose slot equals an import's atom slot is not that import" {
    // `length` is a predefined atom whose index equals the slot of the fifth
    // local in a function body, because module bindings carry their atom as
    // slot while function locals restart at zero. Looking up `imports` by slot
    // alone resolved the local `f` (holding `cacheSet`) to `parseBearer`, and
    // that import is pure, so the call returned before it could set
    // `lower_bound`. Renaming the import made the same handler refused.
    const row = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\import { parseBearer as length } from "zttp:auth";
        \\function handler(a, b, c, d) {
        \\  const f = cacheSet;
        \\  f("ns", "k", "v", 10);
        \\  return 1;
        \\}
    );
    try testing.expect(row.lower_bound);
}

test "the slot filter keeps module bindings reached from a nested closure and from before their declaration" {
    // A closure that names a module import is `.global`, not `.upvalue`, and a
    // call to a function declared further down is `.undeclared_global`. Both
    // must still resolve, or the kind filter trades one fail-open for another.
    const closure = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function handler(items) {
        \\  return items.map((x) => cacheSet("ns", x, "v", 10));
        \\}
    );
    try testing.expect(closure.writes);
    try testing.expect(!closure.lower_bound);

    const forward = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function handler(k) { return later(k); }
        \\function later(k) { return cacheSet("ns", k, "v", 10); }
    );
    try testing.expect(forward.writes);
    try testing.expect(!forward.lower_bound);
}

test "a closure declared in a body is charged to that body" {
    // P4. `walkBaseStmt` skipped a function-valued `const` and a nested
    // function declaration, and `collectFunctionsIn` reads top-level
    // statements only, so no unit ever held the closure's write. The closure
    // was then passed as a value, a path that charges nothing, and the handler
    // proved `read_only`. A function value created in a body is charged to
    // that body where it is created, as an inline callback already is.
    const arrow = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function handler(items) {
        \\  const w = (k) => { cacheSet("ns", k, "v", 10); return 1; };
        \\  items.forEach(w);
        \\  return 1;
        \\}
    );
    try testing.expect(arrow.writes);
    try testing.expect(!arrow.readOnly());

    const declared = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function handler(items) {
        \\  function w(k) { cacheSet("ns", k, "v", 10); return 1; }
        \\  items.forEach(w);
        \\  return 1;
        \\}
    );
    try testing.expect(declared.writes);
    try testing.expect(!declared.readOnly());

    // A call to a body-local closure stays an unresolved callee, and its
    // body's write is now in the row as well.
    const called = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function handler(k) {
        \\  const w = (x) => { cacheSet("ns", x, "v", 10); return 1; };
        \\  return w(k);
        \\}
    );
    try testing.expect(called.lower_bound);
    try testing.expect(called.writes);

    // Control: a pure local closure charges nothing.
    const pure = try analyzeHandlerRow(
        \\function handler(items) {
        \\  const w = (k) => k + 1;
        \\  return items.map(w);
        \\}
    );
    try testing.expect(pure.readOnly());
    try testing.expect(pure.deterministic);
}

test "an import bound to a local and passed as a value is charged where it is referenced" {
    // P1. `const f = cacheSet; items.forEach(f)`: the argument is a local, so
    // neither the call-site lookup nor the argument special case saw an
    // import. The reference in the initializer is the point at which the
    // function value is created, and that is where it is charged.
    const row = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function handler(items) {
        \\  const f = cacheSet;
        \\  items.forEach(f);
        \\  return 1;
        \\}
    );
    try testing.expect(row.writes);
    try testing.expect(!row.readOnly());
}

test "a user function reached through an object member or a local alias is charged" {
    // P2 and P3. A value reference to `w` creates an edge to `w`, so `w`'s row
    // reaches the owner however the value is called later.
    const member = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function w(k) { cacheSet("ns", k, "v", 10); return 1; }
        \\function handler(req) {
        \\  const o = { f: w };
        \\  return o.f("k");
        \\}
    );
    try testing.expect(member.writes);
    try testing.expect(!member.readOnly());

    const alias = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function w(k) { cacheSet("ns", k, "v", 10); return 1; }
        \\function handler(items) {
        \\  const g = w;
        \\  items.forEach(g);
        \\  return 1;
        \\}
    );
    try testing.expect(alias.writes);
    try testing.expect(!alias.readOnly());

    const indexed = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function w(k) { cacheSet("ns", k, "v", 10); return 1; }
        \\function handler(req) {
        \\  return [w][0]("k");
        \\}
    );
    try testing.expect(indexed.writes);
    try testing.expect(!indexed.readOnly());
}

test "a clock or egress export referenced as a value demotes the matching property" {
    const clock = try analyzeHandlerRow(
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(items) {
        \\  const f = jwtVerify;
        \\  return items.map(f);
        \\}
    );
    try testing.expect(!clock.deterministic);

    const egress = try analyzeHandlerRow(
        \\import { fetchSync } from "zttp:fetch";
        \\function handler(items) {
        \\  const f = fetchSync;
        \\  return items.map(f);
        \\}
    );
    try testing.expect(egress.has_egress);
    try testing.expect(!egress.readOnly());

    // The sink exemption is unchanged: a discarded log call with no other
    // clock read stays deterministic and still writes.
    const sunk = try analyzeHandlerRow(
        \\import { logInfo } from "zttp:log";
        \\function handler(req) {
        \\  logInfo("served", {});
        \\  return 1;
        \\}
    );
    try testing.expect(sunk.deterministic);
    try testing.expect(sunk.writes);
}

test "referencing a pure function or a runtime global as a value keeps the row read only" {
    const row = try analyzeHandlerRow(
        \\function fmt(x) { return x + 1; }
        \\function handler(items, s) {
        \\  const g = fmt;
        \\  const a = items.map(String);
        \\  const b = items.map(g);
        \\  return s.toUpperCase();
        \\}
    );
    try testing.expect(row.readOnly());
    try testing.expect(row.deterministic);
    try testing.expect(!row.lower_bound);
}

test "a value reference does not create recursion but a callback call still does" {
    // R3. A reference to a function is not a call. Two functions that only
    // hold each other as values are not recursive, and `total` must not be
    // refused for them. A callback hand-off is a call edge, so recursion
    // through `xs.map(b)` is still found.
    const a_value = try analyzeNamedRow(
        \\function a() { const t = [b]; return t; }
        \\function b() { const u = [a]; return u; }
    , "a");
    try testing.expect(!a_value.recursive);

    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator,
        \\function a(xs) { return xs.map(b); }
        \\function b(x) { return a([x]); }
    );
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

    // The value edge is visible to a reachability walk, the call edge is not
    // widened by it.
    var vparser = try JsParser.init(allocator,
        \\function w() { return 1; }
        \\function handler() { const t = [w]; return t; }
    );
    vparser.setAtomTable(&atoms);
    defer vparser.deinit();
    const vroot = try vparser.parse();
    const vview = IrView.fromIRStore(&vparser.nodes, &vparser.constants);
    var vanalyzer = Analyzer.init(allocator, vview, &atoms);
    defer vanalyzer.deinit();
    try vanalyzer.analyze(vroot);
    var handler_idx: usize = 0;
    for (vanalyzer.all(), 0..) |fe, i| {
        if (std.mem.eql(u8, fe.name, "handler")) handler_idx = i;
    }
    try testing.expectEqual(@as(usize, 0), vanalyzer.calleesOf(handler_idx).len);
    try testing.expectEqual(@as(usize, 1), vanalyzer.valueRefsOf(handler_idx).len);
}

test "a module-level object holding a writing function charges every reference to it" {
    // The module-scope pass. `ops` holds `w`, and nothing in the handler names
    // `w`: the handler reaches it through `ops` as a member receiver, as an
    // argument, and through a second module alias. Each reference to a
    // function-holding module binding charges the functions it holds.
    const prelude =
        \\import { cacheSet } from "zttp:cache";
        \\function w(k) { cacheSet("ns", k, "v", 10); return 1; }
        \\const ops = { save: w };
        \\const ops2 = ops;
        \\function helper(o) { return 1; }
        \\
    ;
    const bodies = [_][]const u8{
        "function handler(req) { return ops.save(\"k\"); }",
        "function handler(req) { return helper(ops); }",
        "function handler(req) { return ops2.save(\"k\"); }",
    };
    inline for (bodies) |body| {
        const row = try analyzeHandlerRow(prelude ++ body);
        try testing.expect(row.writes);
        try testing.expect(!row.readOnly());
    }
}

test "a closure inside a module-level initializer is charged for its own calls" {
    // R2. The initializer's closure calls `cacheSet` in callee position, so a
    // value-reference rule alone would miss it. The module-scope pass walks
    // the initializer like a function body.
    const row = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\const ops = { save: (k) => { cacheSet("ns", k, "v", 10); return 1; } };
        \\function handler(req) { return ops.save("k"); }
    );
    try testing.expect(row.writes);
    try testing.expect(!row.readOnly());

    // An exported binding is a module binding too.
    const exported = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\export const ops = { save: (k) => { cacheSet("ns", k, "v", 10); return 1; } };
        \\function handler(req) { return ops.save("k"); }
    );
    try testing.expect(exported.writes);
}

test "a module-level alias of an import is charged when it is called or passed" {
    const called = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\const save = cacheSet;
        \\function handler(req) { return save("ns", "k", "v", 10); }
    );
    try testing.expect(called.writes);
    // The call goes through a value, so the row is still a lower bound.
    try testing.expect(called.lower_bound);

    const passed = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\const save = cacheSet;
        \\function handler(items) { items.forEach(save); return 1; }
    );
    try testing.expect(passed.writes);
}

test "a module binding declared after the function that references it still charges" {
    // `later` is declared below `handler` and below the closure in `early`.
    // The pass registers every binding before it walks any initializer, so
    // neither order hides the write.
    const row = try analyzeHandlerRow(
        \\import { cacheSet } from "zttp:cache";
        \\function handler(req) { return early.go("k"); }
        \\const early = { go: (k) => later.save(k) };
        \\const later = { save: (k) => { cacheSet("ns", k, "v", 10); return 1; } };
    );
    try testing.expect(row.writes);
}

test "module data and pure module-held functions keep the row read only" {
    const row = try analyzeHandlerRow(
        \\const cfg = { limit: 10, names: ["a", "b"] };
        \\function fmt(x) { return x + 1; }
        \\const table = { f: fmt, g: (x) => x };
        \\function handler(req) {
        \\  const n = cfg.limit;
        \\  return table.f(n);
        \\}
    );
    try testing.expect(row.readOnly());
    try testing.expect(row.deterministic);
}

test "a route function that references the route table is not recursive" {
    // R3. Both routes read `routes`, and `routes` holds both. That is a value
    // reference, not a call: no recursion, so `total` is not refused for it.
    const allocator = testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator,
        \\function listUsers(req) { return Object.keys(routes); }
        \\function getUser(req) { return Object.keys(routes); }
        \\const routes = [{ path: "/u", run: listUsers }, { path: "/u/1", run: getUser }];
    );
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analyzer = Analyzer.init(allocator, view, &atoms);
    defer analyzer.deinit();
    try analyzer.analyze(root);
    const list = analyzer.lookup("listUsers") orelse return error.FunctionNotFound;
    const get = analyzer.lookup("getUser") orelse return error.FunctionNotFound;
    try testing.expect(!list.recursive);
    try testing.expect(!get.recursive);
    var idx: usize = 0;
    for (analyzer.all(), 0..) |fe, i| {
        if (std.mem.eql(u8, fe.name, "listUsers")) idx = i;
    }
    try testing.expect(!(try analyzer.reachesRecursion(analyzer.all()[idx].body_node)));
}

test "a call through a member of a function-holding binding is a lower bound" {
    // R4. Calls through a value-holding receiver reach functions the walk
    // cannot name at the call, so the row cannot claim to have seen
    // everything. Without this, recursion through `ops.a()` leaves no call
    // edge and `total` would be proven for a function that recurses.
    const sources = [_][]const u8{
        // module-level receiver, dotted and computed
        "function w(k) { return k; }\nconst ops = { a: w };\nfunction handler(k) { return ops.a(k); }",
        "function w(k) { return k; }\nconst ops = { a: w };\nfunction handler(k) { return ops[\"a\"](k); }",
        // body-local receiver, directly and from inside a closure
        "function w(k) { return k; }\nfunction handler(k) { const o = { a: w }; return o.a(k); }",
        "function w(k) { return k; }\nfunction handler(xs) { const o = { a: w }; return xs.map((x) => o.a(x)); }",
        // a closure held at module scope that calls through its own binding
        "const ops = { a: (k) => ops.b(k), b: (k) => k };\nfunction handler(k) { return ops.a(k); }",
        // an alias of a holder
        "function w(k) { return k; }\nconst ops = { a: w };\nconst ops2 = ops;\nfunction handler(k) { return ops2.a(k); }",
    };
    inline for (sources) |source| {
        const row = try analyzeHandlerRow(source);
        try testing.expect(row.lower_bound);
    }
}

test "a member call on a receiver that holds no function stays resolved" {
    const row = try analyzeHandlerRow(
        \\const cfg = { names: ["a", "b"] };
        \\function handler(items, s) {
        \\  const d = { n: 1 };
        \\  const a = s.toUpperCase();
        \\  const b = items.map((x) => x + 1);
        \\  const c = cfg.names.join(",");
        \\  return a + d.n + Object.keys(cfg).length;
        \\}
    );
    try testing.expect(!row.lower_bound);
    try testing.expect(row.readOnly());
}

test "an unknown module's export referenced as a value fails closed" {
    // R9. `zts check` does not refuse a `zttp-ext:` specifier that no registry
    // knows, so the value path sees one. Its capabilities are already every
    // capability; its write and egress classes are unknowable, and guessing
    // none for them is the fail-open `insertModuleCapabilities` already
    // refuses for the capability set.
    const unknown = try analyzeHandlerRow(
        \\import { thing } from "zttp-ext:unregistered";
        \\function handler(items) { items.forEach(thing); return 1; }
    );
    try testing.expect(unknown.writes);
    try testing.expect(unknown.has_egress);
    try testing.expect(!unknown.readOnly());

    // Control: a known pure export referenced as a value stays read only.
    const known = try analyzeHandlerRow(
        \\import { parseBearer } from "zttp:auth";
        \\function handler(items) { return items.map(parseBearer); }
    );
    try testing.expect(known.readOnly());
}

test "a local colliding with a pure import keeps a pure closure read only" {
    // Control for the slot filter: the fifth local holds a pure arrow that
    // writes nothing. It is not the import `length`, and the row has nothing
    // to charge for it.
    const row = try analyzeHandlerRow(
        \\import { parseBearer as length } from "zttp:auth";
        \\function handler(a, b, c, d) {
        \\  const f = (x) => x + 1;
        \\  return f(a);
        \\}
    );
    try testing.expect(row.readOnly());
}
