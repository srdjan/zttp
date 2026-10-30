//! Typed pipeline phases for the zts compiler (WS2).
//!
//! Threads three phase wrappers across compilation:
//!
//!   ParsedModule    — IR is built; nothing has been checked yet.
//!   ResolvedModule  — Boolean and (optional) type checks have run.
//!   CheckedModule   - Handler verification and flow analysis can run independently.
//!
//! Each wrapper owns its pass structs by value (so a single `deinit()` cleans up
//! everything the wrapper added) and exposes diagnostics through accessors.
//! `CheckedModule` borrows `*const ResolvedModule` because `HandlerVerifier`
//! holds a pointer back to the `TypeChecker` and the borrow keeps that target
//! address stable in caller storage.
//! `ModuleAnalysisSession` owns these wrappers for one complete module analysis.
//! Its profiles preserve the different full, contract-only, and sound paths.
//!
//! Pass-ordering invariants ("type-check before flow-check", "resolve before
//! check") are encoded in the function signatures. `CheckedModule.init` only
//! accepts a `ResolvedModule`, never a `ParsedModule`. Construction of `ParsedModule` is
//! still permissive in this phase (`fromExisting`) — gating that constructor is
//! WS5 work. A fourth `LoweredModule` phase is intentionally not added: it would
//! need `precompile.zig`'s codegen-bearing orchestrator to migrate here first,
//! and introducing the type before it has a real producer would ship dead API.
//!
//! That migration was planned and then DECLINED, so this is a settled decision
//! rather than pending work. It had no performance or correctness justification
//! — `PathGenerator` and `FlowChecker` were measured constructing once per
//! compile, not twice — and the split it required is real: production code in
//! this file performs zero file, process, or libc IO, while `precompile.zig`
//! carries 148 such references, so the orchestration cannot move without
//! drawing a boundary that does not exist today. Revisit only with a concrete
//! consumer for a fourth phase, such as a build cache or an incremental
//! compile. See `pre-rebase:docs/archive/plans/2026-07-30-007-lowered-module-plan.md`.

const std = @import("std");

const parser_mod = @import("zts-engine").parser;
const bool_checker_mod = @import("bool_checker.zig");
const type_checker_mod = @import("type_checker.zig");
const strict_checker_mod = @import("strict_checker.zig");
const handler_verifier_mod = @import("handler_verifier.zig");
const handler_function_mod = @import("handler_function.zig");
const flow_checker_mod = @import("flow_checker.zig");
const module_facts_mod = @import("module_facts.zig");
const context_mod = @import("zts-engine").context;
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");
const guard_catalog = @import("zts-base").guard_catalog;
const modules_mod = @import("zts-engine").modules;
const module_types_mod = @import("module_types.zig");
const abi_types_mod = @import("abi_types.zig");
const ir_mod = @import("zts-engine").parser.ir;
const handler_contract_mod = @import("zts-contracts").handler_contract;
const contract_builder_mod = @import("contract_builder.zig");
const manifest_registry_mod = @import("manifest_registry.zig");
const bytecode_mod = @import("zts-engine").bytecode;
const source_diagnostics = @import("zts-base").source_diagnostics;
const source_frontend_mod = @import("zts-engine").source_frontend;
const compat_mod = @import("zts-base").compat;
const string_mod = @import("zts-engine").string;
const effect_inference = @import("effect_inference.zig");

const NodeIndex = ir_mod.NodeIndex;
const IrView = ir_mod.IrView;
const BoolChecker = bool_checker_mod.BoolChecker;
const TypeChecker = type_checker_mod.TypeChecker;
const StrictChecker = strict_checker_mod.StrictChecker;
const HandlerVerifier = handler_verifier_mod.HandlerVerifier;
const FlowChecker = flow_checker_mod.FlowChecker;
const AtomTable = context_mod.AtomTable;
const TypeEnv = type_env_mod.TypeEnv;
const TypePool = type_pool_mod.TypePool;
const TypeSyntax = parser_mod.type_syntax;
const HandlerContract = handler_contract_mod.HandlerContract;
const VerificationInfo = handler_contract_mod.VerificationInfo;
const ContractBuilder = contract_builder_mod.ContractBuilder;
const PatternDispatchTable = bytecode_mod.PatternDispatchTable;

/// Public because `buildModuleFacts` returns one and callers outside the
/// package need to name it. Reaching `zts.module_facts` directly for the same
/// type would widen the internal surface the boundary gate pins.
pub const ModuleFacts = module_facts_mod.ModuleFacts;
pub const EffectRow = effect_inference.EffectRow;
pub const EffectFacts = effect_inference.EffectFacts;
pub const EffectFactsRef = effect_inference.EffectFactsRef;
pub const ExportEffect = effect_inference.ExportEffect;
pub const ImportedEffect = effect_inference.ImportedEffect;
pub const ExportEffects = effect_inference.ExportEffects;

/// One completed module effect table, keyed by its stable graph identity.
pub const LoadedModuleEffects = struct {
    graph_index: modules_mod.module_graph.ModuleIndex,
    effects: ExportEffects,

    pub fn deinit(self: *LoadedModuleEffects, allocator: std.mem.Allocator) void {
        self.effects.deinit(allocator);
    }
};

/// Resolve file-import slots against completed modules from the same loaded graph.
/// The returned slice owns no names. The caller frees only the slice itself.
pub fn importedEffectsForLoadedModule(
    allocator: std.mem.Allocator,
    graph: *const modules_mod.ModuleGraph,
    module_index: modules_mod.module_graph.ModuleIndex,
    facts: *const ModuleFacts,
    available: []const LoadedModuleEffects,
) ![]ImportedEffect {
    var imported: std.ArrayList(ImportedEffect) = .empty;
    errdefer imported.deinit(allocator);

    const importing_path = graph.module_list.items[module_index].path;
    const importing_dir = modules_mod.file_resolver.dirName(importing_path);
    for (facts.imports.items) |record| {
        const resolved = modules_mod.resolver.resolve(record.module_specifier);
        const specifier = switch (resolved) {
            .file => |file| file,
            .virtual, .unknown => continue,
        };
        const path = try modules_mod.file_resolver.resolve(
            allocator,
            specifier,
            importing_dir,
            null,
        );
        const dependency_index = graph.modules.get(path);
        allocator.free(path);
        var effect: ExportEffect = .blocked;
        if (dependency_index) |wanted| {
            for (available) |*loaded| {
                if (loaded.graph_index != wanted) continue;
                effect = loaded.effects.lookup(record.imported_name);
                break;
            }
        }
        try imported.append(allocator, .{ .slot = record.slot, .effect = effect });
    }
    return imported.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Phase 1: Parsed
// ---------------------------------------------------------------------------

pub const ParsedModule = struct {
    ir_view: IrView,
    root: NodeIndex,
    atoms: ?*AtomTable,
    type_store: ?*const TypeSyntax.Store = null,
    /// The parser remains owned by the caller through the analysis session.
    scopes: ?*const @import("zts-engine").parser.ScopeAnalyzer = null,

    /// Adopt an already-parsed IR. Transitional: tighter gating belongs to WS5.
    pub fn fromExisting(ir_view: IrView, root: NodeIndex, atoms: ?*AtomTable) ParsedModule {
        return .{ .ir_view = ir_view, .root = root, .atoms = atoms };
    }

    pub fn fromTypedExisting(
        ir_view: IrView,
        root: NodeIndex,
        atoms: *AtomTable,
        type_store: *const TypeSyntax.Store,
    ) ParsedModule {
        return .{
            .ir_view = ir_view,
            .root = root,
            .atoms = atoms,
            .type_store = type_store,
        };
    }
};

/// Build the shared import index for a parsed module. Caller owns the result
/// and must keep it alive for as long as any analyzer that received it, exactly
/// like `ResolveOptions.type_env`.
///
/// A shared borrowed index cannot live inline inside `ResolvedModule` or
/// `CheckedModule`: both move by value, so other analyzers' pointers into them
/// would dangle. A checker's private fallback can live inline because it retains
/// no pointer to its own storage. Shared facts need stable caller storage, as
/// does the `ResolvedModule` that `CheckedModule` borrows.
pub fn buildModuleFacts(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    registry: ?*const @import("manifest_registry.zig").Registry,
) !ModuleFacts {
    return ModuleFacts.build(allocator, parsed.ir_view, parsed.atoms, registry);
}

// ---------------------------------------------------------------------------
// Phase 2: Resolved (boolean + optional type checks)
// ---------------------------------------------------------------------------

pub const ResolveOptions = struct {
    /// When non-null, runs the TypeChecker as part of resolution. The pointed-to
    /// TypeEnv must outlive the returned ResolvedModule.
    type_env: ?*TypeEnv = null,
    /// Canonical import index built from this parsed module. Kept separate
    /// from module_facts, whose injected contract projections may be partial.
    /// The caller keeps this storage stable for the resolved checker's lifetime.
    type_import_facts: ?*const ModuleFacts = null,
    /// Default-on strict ZigTS profile (ZTS6xx). Type-directed rules run when
    /// type context exists; syntax/profile rules still run for untyped sources.
    strict: bool = true,
    /// Shared import index for this compile, built once by the caller. The
    /// pointed-to index must outlive the returned ResolvedModule. When null each
    /// analyzer builds a private one, which is what an un-migrated caller does.
    module_facts: ?*const ModuleFacts = null,
    /// Which sections the configured capability policy declares. Empty means no
    /// policy file, which is what a caller that has none passes.
    policy_sections: guard_catalog.SectionSet = .{},
};

pub const ResolvedModule = struct {
    parsed: ParsedModule,
    bool_checker: BoolChecker,
    type_checker: ?TypeChecker,
    strict_checker: ?StrictChecker,
    bool_error_count: u32,
    strict_error_count: u32,

    pub fn deinit(self: *ResolvedModule) void {
        self.bool_checker.deinit();
        if (self.strict_checker) |*sc| sc.deinit();
        if (self.type_checker) |*tc| tc.deinit();
    }

    pub fn boolDiagnostics(self: *const ResolvedModule) []const bool_checker_mod.Diagnostic {
        return self.bool_checker.getDiagnostics();
    }

    pub fn typeDiagnostics(self: *const ResolvedModule) []const type_checker_mod.Diagnostic {
        if (self.type_checker) |*tc| return tc.getDiagnostics();
        return &.{};
    }

    pub fn strictDiagnostics(self: *const ResolvedModule) []const strict_checker_mod.Diagnostic {
        if (self.strict_checker) |*sc| return sc.getDiagnostics();
        return &.{};
    }

    pub fn typeErrorCount(self: *const ResolvedModule) u32 {
        var error_count: u32 = 0;
        for (self.typeDiagnostics()) |diagnostic| {
            if (diagnostic.severity == .err) error_count += 1;
        }
        return error_count;
    }

    /// Remove each boolean and strict diagnostic whose node is, or lies under, a
    /// node that already has a type error. The type error says what is wrong
    /// with that expression, and a second message about the same expression or
    /// about a part of it only repeats it. The check still fails on the type
    /// error, so no refusal is lost; the removed message returns once the type
    /// error is fixed, if it still applies. `resolve` keeps these diagnostics,
    /// because the containment tests above read them there: only a caller that
    /// reports to a person calls this.
    pub fn dropRepeatsOfTypeErrors(self: *ResolvedModule) void {
        const tc = if (self.type_checker) |*checker| checker else return;
        var has_error = false;
        for (tc.getDiagnostics()) |diagnostic| {
            if (diagnostic.severity == .err) has_error = true;
        }
        if (!has_error) return;

        const Covered = struct {
            view: IrView,
            type_diagnostics: []const type_checker_mod.Diagnostic,

            fn covers(self_: @This(), node: NodeIndex) bool {
                if (node == ir_mod.null_node) return false;
                for (self_.type_diagnostics) |diagnostic| {
                    if (diagnostic.severity != .err) continue;
                    if (self_.view.subtreeContains(diagnostic.node, node)) return true;
                }
                return false;
            }
        };
        const covered: Covered = .{
            .view = self.parsed.ir_view,
            .type_diagnostics = tc.getDiagnostics(),
        };
        self.bool_error_count = self.bool_checker.dropDiagnostics(covered, Covered.covers);
        if (self.strict_checker) |*sc| {
            self.strict_error_count = sc.dropDiagnostics(covered, Covered.covers);
        }
    }

    pub fn formatBoolDiagnostics(
        self: *const ResolvedModule,
        source: source_diagnostics.SourceView,
        writer: anytype,
    ) !void {
        try self.bool_checker.formatDiagnostics(source, writer);
    }

    pub fn formatTypeDiagnostics(
        self: *const ResolvedModule,
        source: source_diagnostics.SourceView,
        writer: anytype,
    ) !void {
        if (self.type_checker) |*tc| try tc.formatDiagnostics(source, writer);
    }

    pub fn formatStrictDiagnostics(
        self: *const ResolvedModule,
        source: source_diagnostics.SourceView,
        writer: anytype,
    ) !void {
        if (self.strict_checker) |*sc| try sc.formatDiagnostics(source, writer);
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    opts: ResolveOptions,
) !ResolvedModule {
    var type_checker_opt: ?TypeChecker = null;
    if (opts.type_env) |env| {
        var tc = TypeChecker.init(
            allocator,
            parsed.ir_view,
            parsed.atoms,
            env,
        );
        errdefer tc.deinit();
        tc.import_facts = opts.type_import_facts;
        tc.scopes = parsed.scopes;
        // The strict checker reports a match that is not exhaustive as ZTS603,
        // so the type checker leaves its ZTS205 out when strict runs.
        tc.strict_checker_follows = opts.strict;
        _ = try tc.check(parsed.root);
        type_checker_opt = tc;
    }
    errdefer if (type_checker_opt) |*tc| tc.deinit();

    var bool_checker = BoolChecker.init(allocator, parsed.ir_view, parsed.atoms);
    bool_checker.facts = opts.module_facts;
    bool_checker.authoritative_type_checker = if (type_checker_opt) |*tc| tc else null;
    errdefer bool_checker.deinit();
    const bool_errors = try bool_checker.check(parsed.root);
    // The pointer targets stack-local optional storage. Consumers use the
    // stored diagnostics and node types after this check, not this pointer.
    bool_checker.authoritative_type_checker = null;

    var strict_checker_opt: ?StrictChecker = null;
    var strict_errors: u32 = 0;
    if (opts.strict) {
        const env_ptr: ?*const TypeEnv = if (type_checker_opt) |*tc| tc.env else null;
        const tc_ptr: ?*TypeChecker = if (type_checker_opt) |*tc| tc else null;
        var sc = StrictChecker.init(
            allocator,
            parsed.ir_view,
            parsed.atoms,
            env_ptr,
            tc_ptr,
        );
        sc.facts = opts.module_facts;
        sc.policy_sections = opts.policy_sections;
        errdefer sc.deinit();
        strict_errors = try sc.check(parsed.root);
        if (type_checker_opt) |*tc| try tc.ensureHealthy();
        // The borrowed TypeEnv/TypeChecker pointers were stack-local; releasing
        // them via seal() before the ResolvedModule is moved out keeps any
        // stray future use a clean nullopt instead of UB.
        sc.seal();
        strict_checker_opt = sc;
    }

    return .{
        .parsed = parsed,
        .bool_checker = bool_checker,
        .type_checker = type_checker_opt,
        .strict_checker = strict_checker_opt,
        .bool_error_count = bool_errors,
        .strict_error_count = strict_errors,
    };
}

// ---------------------------------------------------------------------------
// Phase 3: Checked (handler verification + flow analysis)
// ---------------------------------------------------------------------------

const CheckedPassState = enum {
    ready,
    attempted,
    completed,
};

pub const CheckedModule = struct {
    resolved: *const ResolvedModule,
    verifier: HandlerVerifier,
    flow_checker: FlowChecker,
    verifier_error_count: u32,
    flow_error_count: u32,
    verifier_state: CheckedPassState,
    flow_state: CheckedPassState,

    pub fn init(
        allocator: std.mem.Allocator,
        resolved: *ResolvedModule,
        opts: CheckOptions,
    ) !CheckedModule {
        const tc_ptr: ?*TypeChecker = if (resolved.type_checker) |*tc| tc else null;
        const env_ptr: ?*const TypeEnv = if (resolved.type_checker) |*tc| tc.env else null;

        var verifier = HandlerVerifier.init(
            allocator,
            resolved.parsed.ir_view,
            resolved.parsed.atoms,
            env_ptr,
            tc_ptr,
        );
        verifier.facts = opts.module_facts;
        errdefer verifier.deinit();

        var flow = FlowChecker.init(
            allocator,
            resolved.parsed.ir_view,
            resolved.parsed.atoms,
        );
        flow.scopes = resolved.parsed.scopes;
        flow.modules = opts.flow_modules;
        flow.initialization_order = opts.flow_initialization_order;
        flow.modules_complete = opts.flow_modules_complete;
        flow.env_public = opts.env_public;
        if (tc_ptr) |tc| flow.setTypeChecker(tc);
        errdefer flow.deinit();

        return .{
            .resolved = resolved,
            .verifier = verifier,
            .flow_checker = flow,
            .verifier_error_count = 0,
            .flow_error_count = 0,
            .verifier_state = .ready,
            .flow_state = .ready,
        };
    }

    pub fn deinit(self: *CheckedModule) void {
        self.flow_checker.deinit();
        self.verifier.deinit();
        // Caller owns `resolved`; don't deinit it here.
    }

    pub fn verifierDiagnostics(self: *const CheckedModule) []const handler_verifier_mod.Diagnostic {
        return self.verifier.getDiagnostics();
    }

    pub fn flowDiagnostics(self: *const CheckedModule) []const flow_checker_mod.Diagnostic {
        return self.flow_checker.getDiagnostics();
    }

    pub fn defendedPaths(self: *const CheckedModule) []const flow_checker_mod.DefendedPath {
        return self.flow_checker.getDefendedPaths();
    }

    pub fn verifierCompleted(self: *const CheckedModule) bool {
        return self.verifier_state == .completed;
    }

    pub fn flowCompleted(self: *const CheckedModule) bool {
        return self.flow_state == .completed;
    }

    pub fn runVerifier(self: *CheckedModule, handler_func: NodeIndex) !u32 {
        if (self.verifier_state != .ready) return error.PassAlreadyRun;
        self.verifier_state = .attempted;

        const error_count = try self.verifier.verify(handler_func);
        if (self.resolved.type_checker) |*tc| try tc.ensureHealthy();
        self.verifier_error_count = error_count;
        self.verifier_state = .completed;
        return error_count;
    }

    pub fn runFlow(self: *CheckedModule, handler_func: NodeIndex) !u32 {
        if (self.flow_state != .ready) return error.PassAlreadyRun;
        self.flow_state = .attempted;

        const error_count = try self.flow_checker.check(handler_func);
        if (self.resolved.type_checker) |*tc| try tc.ensureHealthy();
        self.flow_error_count = error_count;
        self.flow_state = .completed;
        return error_count;
    }
};

pub fn flowImportBindingKey(view: IrView, slot: u16) ?u32 {
    for (0..view.nodeCount()) |index| {
        const node: ir_mod.NodeIndex = @intCast(index);
        switch (view.getTag(node) orelse continue) {
            .import_specifier, .import_default, .import_namespace => {},
            // exhaustive: a node that is not an import specifier cannot bind the slot; no match returns null and the caller raises ImportNotFound.
            else => continue,
        }
        const specifier = view.getImportSpec(node) orelse continue;
        if (specifier.local_binding.slot == slot)
            return (@as(u32, specifier.local_binding.scope_id) << 16) | slot;
    }
    return null;
}

pub fn flowExportedFunctionNode(view: IrView, atoms: *AtomTable, name: []const u8) ?ir_mod.NodeIndex {
    for (0..view.nodeCount()) |index| {
        const node: ir_mod.NodeIndex = @intCast(index);
        if ((view.getTag(node) orelse continue) != .export_decl) continue;
        const exported = view.getExportDecl(node) orelse continue;
        if (exported.declaration == ir_mod.null_node) continue;
        const tag = view.getTag(exported.declaration) orelse continue;
        if (tag != .function_decl and tag != .var_decl) continue;
        const declaration = view.getVarDecl(exported.declaration) orelse continue;
        const atom: @import("zts-engine").object.Atom = @fromBackingInt(@intCast(declaration.binding.name_atom));
        const declared_name = atom.toPredefinedName() orelse atoms.getName(atom) orelse continue;
        if (!std.mem.eql(u8, declared_name, name)) continue;
        const function_tag = view.getTag(declaration.init) orelse continue;
        if (function_tag == .function_expr or function_tag == .arrow_function) return declaration.init;
    }
    return null;
}

/// The sink summary of a function imported from another file (plan unit F7).
// Borrowed source snapshots for the replacement flow evaluator. The I/O-owning
// tools retain these owners; the compiler never loads a file itself.
pub const FlowModuleView = @import("flow_interp.zig").ModuleView;
pub const FlowModuleId = @import("flow_interp.zig").ModuleId;
pub const FlowFunctionRef = @import("flow_interp.zig").FunctionRef;
pub const FlowImportTarget = @import("flow_interp.zig").ImportTarget;
pub const FlowCaptureTable = @import("flow_interp.zig").CaptureTable;

/// Overlay completed flow facts without replacing unrelated contract facts.
pub fn projectFlowProperties(contract: *HandlerContract, flow: flow_checker_mod.FlowProperties) void {
    if (contract.properties) |*properties| {
        properties.no_secret_leakage = flow.no_secret_leakage;
        properties.no_credential_leakage = flow.no_credential_leakage;
        properties.input_validated = flow.input_validated;
        properties.pii_contained = flow.pii_contained;
        properties.injection_safe = flow.injection_safe;
        properties.deterministic = properties.deterministic and flow.deterministic;
        properties.idempotent = properties.deterministic and properties.retry_safe;
    }
}

pub const CheckOptions = struct {
    /// Shared import index for this compile. Same lifetime rule as
    /// `ResolveOptions.module_facts`. An options struct rather than a fourth
    /// positional parameter so the next addition does not churn every call site.
    module_facts: ?*const ModuleFacts = null,
    /// Borrow the exact parser snapshots selected by the caller's traversal.
    flow_modules: []const FlowModuleView = &.{},
    flow_initialization_order: []const FlowModuleId = &.{},
    flow_modules_complete: bool = true,
    /// The policy's `env.public` names. Borrowed, and must outlive the session.
    /// Empty means every literal `env` name is secret (D-014).
    env_public: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// TypeEnvStorage - bundle of TypePool + TypeEnv with a stable address.
// `TypeEnv.init` captures `*TypePool`, so the pool must outlive the environment.
// The bundle must stay in final owner storage after initialization.
// ---------------------------------------------------------------------------

pub const TypeEnvStorage = struct {
    pool: TypePool = undefined,
    env: TypeEnv = undefined,
    initialized: bool = false,

    pub fn initWithSource(
        self: *TypeEnvStorage,
        allocator: std.mem.Allocator,
        source: type_env_mod.SourceTypeInput,
    ) !void {
        if (self.initialized) return error.TypeEnvironmentAlreadyInitialized;
        self.pool = TypePool.init(allocator);
        errdefer self.pool.deinit(allocator);
        try self.pool.ensureHealthy();
        self.env = TypeEnv.init(allocator, &self.pool);
        errdefer self.env.deinit();
        try self.pool.ensureHealthy();
        module_types_mod.populateModuleTypes(&self.env, &self.pool, allocator);
        abi_types_mod.populateHandlerAbiTypes(&self.env, &self.pool, allocator);
        try self.pool.ensureHealthy();
        try self.env.populateSourceTypes(source);
        try self.finishInitialization();
    }

    pub fn finishInitialization(self: *TypeEnvStorage) !void {
        try self.pool.ensureHealthy();
        self.initialized = true;
    }

    pub fn deinit(self: *TypeEnvStorage, allocator: std.mem.Allocator) void {
        if (!self.initialized) return;
        self.env.deinit();
        self.pool.deinit(allocator);
        self.initialized = false;
    }

    pub fn envPtr(self: *TypeEnvStorage) ?*TypeEnv {
        return if (self.initialized) &self.env else null;
    }
};

// ---------------------------------------------------------------------------
// One-shot contract extraction
// ---------------------------------------------------------------------------

pub const ContractTypeCheckFn = *const fn (*TypeChecker, NodeIndex) anyerror!u32;

pub const ExtractContractOptions = struct {
    strict: bool = true,
    dispatch: ?*const PatternDispatchTable = null,
    has_default_response: bool = false,
    verification: ?VerificationInfo = null,
    source_types: ?ModuleSourceTypeInput = null,
    manifest_registry: ?*const manifest_registry_mod.Registry = null,
    type_check: ContractTypeCheckFn = runContractTypeCheck,
    read_file: ?modules_mod.module_graph.ReadFileFn = null,
    /// Shared import index for this compile. When set, `ContractBuilder` reads
    /// it instead of building an identical private one. Same lifetime rule as
    /// `ResolveOptions.module_facts`: it must outlive the returned contract's
    /// construction, not the contract itself, since the contract gets copies.
    module_facts: ?*const ModuleFacts = null,
    /// File-import effects prepared from earlier modules in one loaded graph.
    /// Borrowed through extraction only.
    imported_effects: []const ImportedEffect = &.{},
    /// Return an owned export table beside the contract.
    capture_export_effects: bool = false,
    /// Select the flow pass for `.sound_extraction`: `extractContract` runs it and applies
    /// the result to the contract.
    flow: bool = false,
};

pub const ModuleSourceTypeInput = union(type_env_mod.SourceTypeMode) {
    omitted,
    direct,
};

fn normalizeModuleSourceTypes(explicit: ?ModuleSourceTypeInput) ModuleSourceTypeInput {
    return explicit orelse .omitted;
}

fn sourceTypeInput(
    parsed: ParsedModule,
    source: ModuleSourceTypeInput,
) !type_env_mod.SourceTypeInput {
    return switch (source) {
        .omitted => .omitted,
        .direct => .{ .direct = .{
            .store = parsed.type_store orelse return error.DirectTypeSyntaxUnavailable,
            .ir_view = parsed.ir_view,
            .atoms = parsed.atoms orelse return error.DirectTypeSyntaxUnavailable,
        } },
    };
}

fn consumerTypeSource(
    source: ModuleSourceTypeInput,
    env: *const TypeEnv,
) type_env_mod.ConsumerTypeSource {
    return switch (source) {
        .omitted => .omitted,
        .direct => .{ .direct = env },
    };
}

fn hasAuthoredSource(source: ModuleSourceTypeInput) bool {
    return switch (source) {
        .omitted => false,
        .direct => true,
    };
}

/// Owned outputs from one transactional contract extraction.
pub const ContractExtraction = struct {
    contract: HandlerContract,
    export_effects: ?ExportEffects = null,

    pub fn deinit(self: *ContractExtraction, allocator: std.mem.Allocator) void {
        self.contract.deinit(allocator);
        if (self.export_effects) |*effects| effects.deinit(allocator);
        self.export_effects = null;
    }
};

fn runContractTypeCheck(type_checker: *TypeChecker, root: NodeIndex) anyerror!u32 {
    return type_checker.check(root);
}

/// Owns the selected analysis passes for one parsed module.
/// Initialize this value in final caller storage before calling complete.
pub const ModuleAnalysisSession = struct {
    pub const Profile = enum {
        full,
        contract_only,
        sound_extraction,
    };

    pub const PassState = enum {
        skipped,
        ready,
        attempted,
        completed,
        refused,
    };

    const SessionState = enum {
        uninitialized,
        ready,
        analysis_attempted,
        completed,
    };

    const PathEffectState = union(enum) {
        unattempted,
        complete: EffectFacts,
        unavailable,
    };

    pub const FullOptions = struct {
        /// Borrowed through session completion and extraction.
        source_types: ?ModuleSourceTypeInput = null,
        strict: bool = true,
        manifest_registry: ?*const manifest_registry_mod.Registry = null,
        policy_sections: guard_catalog.SectionSet = .{},
        select_verifier: bool = false,
        select_flow: bool = false,
    };

    pub const ContractOnlyOptions = struct {
        extraction: ExtractContractOptions = .{},
    };

    pub const ContractContext = struct {
        dispatch: ?*const PatternDispatchTable = null,
        has_default_response: bool = false,
        verification: ?VerificationInfo = null,
        /// Borrowed immutably through path fact preparation and extraction.
        imported_effects: []const ImportedEffect = &.{},
    };

    allocator: std.mem.Allocator = undefined,
    parsed: ParsedModule = undefined,
    profile: Profile = undefined,
    /// One option set for every profile. `.full` fills only `strict` and `manifest_registry`.
    extraction_opts: ExtractContractOptions = .{},
    policy_sections: guard_catalog.SectionSet = .{},
    /// `env.public` names for the standalone flow checker of a contract-only session.
    env_public: []const []const u8 = &.{},
    source_types: ModuleSourceTypeInput = .omitted,
    contract_context: ContractContext = .{},
    state: SessionState = .uninitialized,
    type_env_storage: TypeEnvStorage = .{},
    extraction_type_env_storage: TypeEnvStorage = .{},
    resolved: ?ResolvedModule = null,
    checked: ?CheckedModule = null,
    /// The checker the contract pass owns when `resolved` has none: the standalone
    /// session, or the custom `type_check` callback session. Never both.
    contract_checker: ?TypeChecker = null,
    standalone_flow_checker: ?FlowChecker = null,
    resolution_facts: ?ModuleFacts = null,
    contract_facts: ?ModuleFacts = null,
    contract_effect_facts: ?EffectFacts = null,
    exported_effects: ?ExportEffects = null,
    path_effect_state: PathEffectState = .unattempted,
    resolution_state: PassState = .skipped,
    contract_type_state: PassState = .skipped,
    verifier_state: PassState = .skipped,
    flow_state: PassState = .skipped,
    flow_error_count: u32 = 0,
    extraction_state: PassState = .skipped,

    pub fn initFull(
        self: *ModuleAnalysisSession,
        allocator: std.mem.Allocator,
        parsed: ParsedModule,
        opts: FullOptions,
    ) !void {
        if (self.state != .uninitialized) return error.AnalysisAlreadyInitialized;
        const source_types = normalizeModuleSourceTypes(opts.source_types);
        self.* = .{
            .allocator = allocator,
            .parsed = parsed,
            .profile = .full,
            .extraction_opts = .{
                .strict = opts.strict,
                .manifest_registry = opts.manifest_registry,
            },
            .policy_sections = opts.policy_sections,
            .source_types = source_types,
            .state = .ready,
            .resolution_state = .ready,
            .contract_type_state = .ready,
            .verifier_state = if (opts.select_verifier) .ready else .skipped,
            .flow_state = if (opts.select_flow) .ready else .skipped,
            .extraction_state = .ready,
        };
    }

    pub fn initContractOnly(
        self: *ModuleAnalysisSession,
        allocator: std.mem.Allocator,
        parsed: ParsedModule,
        opts: ContractOnlyOptions,
    ) !void {
        if (self.state != .uninitialized) return error.AnalysisAlreadyInitialized;
        self.* = .{
            .allocator = allocator,
            .parsed = parsed,
            .profile = .contract_only,
            .extraction_opts = opts.extraction,
            .source_types = .omitted,
            .contract_context = contextFromExtractOptions(opts.extraction),
            .state = .ready,
            .contract_type_state = .ready,
            .verifier_state = .skipped,
            .flow_state = .skipped,
            .extraction_state = .ready,
        };
    }

    pub fn initSoundExtraction(
        self: *ModuleAnalysisSession,
        allocator: std.mem.Allocator,
        parsed: ParsedModule,
        opts: ExtractContractOptions,
    ) !void {
        if (self.state != .uninitialized) return error.AnalysisAlreadyInitialized;
        const source_types = normalizeModuleSourceTypes(opts.source_types);
        self.* = .{
            .allocator = allocator,
            .parsed = parsed,
            .profile = .sound_extraction,
            .extraction_opts = opts,
            .source_types = source_types,
            .contract_context = contextFromExtractOptions(opts),
            .state = .ready,
            .resolution_state = .ready,
            .contract_type_state = .ready,
            .verifier_state = .skipped,
            .flow_state = if (opts.flow) .ready else .skipped,
            .extraction_state = .ready,
        };
    }

    pub fn deinit(self: *ModuleAnalysisSession) void {
        if (self.state == .uninitialized) return;

        switch (self.path_effect_state) {
            .complete => |*owned_effects| owned_effects.deinit(self.allocator),
            .unattempted, .unavailable => {},
        }
        self.path_effect_state = .unattempted;
        if (self.exported_effects) |*effects| effects.deinit(self.allocator);
        self.exported_effects = null;
        if (self.checked) |*checked| checked.deinit();
        self.checked = null;
        if (self.standalone_flow_checker) |*flow| flow.deinit();
        self.standalone_flow_checker = null;
        if (self.contract_checker) |*checker| checker.deinit();
        self.contract_checker = null;
        if (self.resolved) |*resolved| resolved.deinit();
        self.resolved = null;
        self.extraction_type_env_storage.deinit(self.allocator);
        self.type_env_storage.deinit(self.allocator);
        if (self.contract_facts) |*owned_contract| owned_contract.deinit();
        self.contract_facts = null;
        if (self.contract_effect_facts) |*owned_effects| owned_effects.deinit(self.allocator);
        self.contract_effect_facts = null;
        if (self.resolution_facts) |*owned_resolution| owned_resolution.deinit();
        self.resolution_facts = null;
        self.state = .uninitialized;
    }

    pub fn complete(self: *ModuleAnalysisSession) !void {
        if (self.state != .ready) return error.AnalysisAlreadyAttempted;
        self.state = .analysis_attempted;

        switch (self.profile) {
            .full => try self.completeFull(),
            .contract_only => try self.completeContractOnly(),
            .sound_extraction => try self.completeSoundExtraction(),
        }
        self.state = .completed;
    }

    pub fn facts(self: *ModuleAnalysisSession) !*const ModuleFacts {
        if (self.state != .completed) return error.AnalysisNotCompleted;
        return self.completedContractFacts();
    }

    /// Prepare path effect facts once and freeze their imported dependencies.
    ///
    /// Effect analysis failure is conservative for path coverage. The path
    /// generator receives `.unavailable` and reports recursion instead of
    /// aborting path enumeration.
    pub fn pathEffectFacts(self: *ModuleAnalysisSession) !EffectFactsRef {
        if (self.state != .completed) return error.AnalysisNotCompleted;
        switch (self.path_effect_state) {
            .complete => |*completed_effects| return .{ .complete = completed_effects },
            .unavailable => return .unavailable,
            .unattempted => {},
        }

        const owned_effects = effect_inference.buildEffectFacts(
            self.allocator,
            self.parsed.ir_view,
            self.parsed.atoms,
            self.parsed.root,
            // Sibling results keep a handler that calls a clean helper from a
            // relative import costed, and carry a sibling's recursion or escaped
            // function value into the handler. Without them every such import
            // is a blocked result, which is a lower bound.
            .{ .imported_effects = self.contract_context.imported_effects },
        ) catch {
            self.path_effect_state = .unavailable;
            return .unavailable;
        };
        self.path_effect_state = .{ .complete = owned_effects };
        return switch (self.path_effect_state) {
            .complete => |*published_effects| .{ .complete = published_effects },
            .unattempted, .unavailable => unreachable,
        };
    }

    pub fn resolvedForReport(self: *ModuleAnalysisSession) !*ResolvedModule {
        if (self.state != .completed) return error.AnalysisNotCompleted;
        return if (self.resolved) |*resolved| resolved else error.AnalysisNotResolved;
    }

    pub fn refuseResolution(self: *ModuleAnalysisSession) void {
        if (self.resolution_state != .completed) return;
        self.resolution_state = .refused;
        if (self.verifier_state == .ready) self.verifier_state = .refused;
        if (self.flow_state == .ready) self.flow_state = .refused;
        if (self.extraction_state == .ready) self.extraction_state = .refused;
    }

    pub fn prepareChecked(
        self: *ModuleAnalysisSession,
        handler_func: ?NodeIndex,
        opts: CheckOptions,
    ) !void {
        if (self.profile != .full or self.resolution_state != .completed) {
            return error.AnalysisNotResolved;
        }
        if (self.verifier_state == .skipped and self.flow_state == .skipped) return;
        if (self.checked != null) return error.AnalysisPassAlreadyPrepared;
        if (handler_func == null) return;
        self.checked = try CheckedModule.init(
            self.allocator,
            try self.resolvedForReport(),
            opts,
        );
    }

    pub fn runVerifier(self: *ModuleAnalysisSession, handler_func: NodeIndex) !u32 {
        if (self.verifier_state != .ready) return error.AnalysisPassUnavailable;
        self.verifier_state = .attempted;
        const checked = if (self.checked) |*value| value else return error.AnalysisPassUnavailable;
        const count = try checked.runVerifier(handler_func);
        if (!checked.verifierCompleted()) return error.AnalysisPassIncomplete;
        self.verifier_state = .completed;
        return count;
    }

    pub fn runFlow(self: *ModuleAnalysisSession, handler_func: NodeIndex) !u32 {
        if (self.flow_state != .ready) return error.AnalysisPassUnavailable;
        self.flow_state = .attempted;
        const count = if (self.checked) |*checked|
            try checked.runFlow(handler_func)
        else if (self.standalone_flow_checker) |*flow|
            try flow.check(handler_func)
        else
            return error.AnalysisPassUnavailable;
        if (self.checked) |*checked| {
            if (!checked.flowCompleted()) return error.AnalysisPassIncomplete;
        }
        self.flow_state = .completed;
        self.flow_error_count = count;
        return count;
    }

    pub fn checkedModule(self: *ModuleAnalysisSession) ?*CheckedModule {
        return if (self.checked) |*checked| checked else null;
    }

    pub fn completedFlow(self: *ModuleAnalysisSession) !*const FlowChecker {
        if (self.flow_state != .completed) return error.AnalysisPassIncomplete;
        if (self.checked) |*checked| {
            if (!checked.flowCompleted()) return error.AnalysisPassIncomplete;
            return &checked.flow_checker;
        }
        return if (self.standalone_flow_checker) |*flow| flow else error.AnalysisPassIncomplete;
    }

    pub fn setContractContext(
        self: *ModuleAnalysisSession,
        context: ContractContext,
    ) !void {
        if (self.state != .completed) return error.AnalysisNotCompleted;
        if (self.extraction_state != .ready) return error.ContractExtractionAlreadyAttempted;
        try self.requireUnchangedPublishedEffects(context.imported_effects);
        self.contract_context = context;
    }

    pub fn setImportedEffects(
        self: *ModuleAnalysisSession,
        imported_effects: []const ImportedEffect,
    ) !void {
        if (self.state != .completed) return error.AnalysisNotCompleted;
        if (self.extraction_state != .ready) return error.ContractExtractionAlreadyAttempted;
        try self.requireUnchangedPublishedEffects(imported_effects);
        self.contract_context.imported_effects = imported_effects;
    }

    fn requireUnchangedPublishedEffects(
        self: *const ModuleAnalysisSession,
        imported_effects: []const ImportedEffect,
    ) !void {
        if (self.path_effect_state == .unattempted) return;
        // An unavailable attempt is cached too. Metadata may still change,
        // but contract extraction must see the same effect-producing inputs.
        const current = self.contract_context.imported_effects;
        if (current.len != imported_effects.len) return error.ImportedEffectsFrozen;
        for (current, imported_effects) |before, after| {
            if (before.slot != after.slot or
                std.meta.activeTag(before.effect) != std.meta.activeTag(after.effect))
                return error.ImportedEffectsFrozen;
            switch (before.effect) {
                .callable => |row| if (!row.eql(after.effect.callable)) return error.ImportedEffectsFrozen,
                .data => |row| if (!row.eql(after.effect.data)) return error.ImportedEffectsFrozen,
                .blocked => {},
            }
        }
    }

    pub fn extractContract(
        self: *ModuleAnalysisSession,
        filename: []const u8,
    ) !HandlerContract {
        if (self.state != .completed) return error.AnalysisNotCompleted;
        if (self.resolution_state == .refused) return error.AnalysisNotResolved;
        if (self.verifier_state == .attempted or self.flow_state == .attempted) {
            return error.AnalysisPassIncomplete;
        }
        if (self.extraction_state != .ready) return error.ContractExtractionAlreadyAttempted;
        self.extraction_state = .attempted;

        var extraction = switch (self.profile) {
            .full, .contract_only => try self.extractDefaultResult(filename),
            .sound_extraction => if (self.extraction_opts.type_check == runContractTypeCheck)
                try self.extractDefaultResult(filename)
            else
                try self.extractCustomResult(filename),
        };
        errdefer extraction.deinit(self.allocator);

        if (self.resolved) |*resolved| {
            if (resolved.typeErrorCount() > 0) return error.SoundModeViolation;
        }
        try self.applyFlow(&extraction.contract);
        self.exported_effects = extraction.export_effects;
        extraction.export_effects = null;
        self.extraction_state = .completed;
        return extraction.contract;
    }

    /// Apply the selected flow pass to the contract, running it first when it has not run.
    /// A module with no handler function keeps the builder defaults.
    fn applyFlow(self: *ModuleAnalysisSession, contract: *HandlerContract) !void {
        switch (self.flow_state) {
            .skipped => return,
            .ready, .completed => {},
            .attempted, .refused => return error.AnalysisPassIncomplete,
        }
        const handler = handler_function_mod.findHandlerFunction(
            self.parsed.ir_view,
            self.parsed.root,
        ) orelse return;
        if (self.flow_state == .ready) _ = try self.runFlow(handler);
        projectFlowProperties(contract, (try self.completedFlow()).getProperties());
    }

    /// Error count of the completed flow pass.
    pub fn flowErrorCount(self: *const ModuleAnalysisSession) u32 {
        return self.flow_error_count;
    }

    /// Transfer the export table after a successful extraction.
    pub fn takeExportEffects(self: *ModuleAnalysisSession) ?ExportEffects {
        if (self.extraction_state != .completed) return null;
        const result = self.exported_effects;
        self.exported_effects = null;
        return result;
    }

    fn completeFull(self: *ModuleAnalysisSession) !void {
        self.contract_facts = try buildModuleFacts(
            self.allocator,
            self.parsed,
            self.extraction_opts.manifest_registry,
        );
        if (hasAuthoredSource(self.source_types)) {
            try self.type_env_storage.initWithSource(
                self.allocator,
                try sourceTypeInput(self.parsed, self.source_types),
            );
        }
        self.resolved = try resolve(self.allocator, self.parsed, .{
            .type_env = self.type_env_storage.envPtr(),
            .strict = self.extraction_opts.strict,
            .module_facts = &self.contract_facts.?,
            .type_import_facts = &self.contract_facts.?,
            .policy_sections = self.policy_sections,
        });
        if (self.resolved.?.type_checker) |*checker| try checker.ensureHealthy();
        self.resolution_state = .completed;
        if (self.resolved.?.type_checker != null) self.contract_type_state = .completed;
    }

    fn completeContractOnly(self: *ModuleAnalysisSession) !void {
        if (self.extraction_opts.type_check != runContractTypeCheck) {
            return error.IncompatibleAnalysisProfile;
        }

        try self.completeStandaloneTypeSession();
        try self.prepareContractFacts();
        try self.prepareStandaloneFlow();
    }

    /// The flow checker of a profile with no `CheckedModule`. It sees no module views.
    fn prepareStandaloneFlow(self: *ModuleAnalysisSession) !void {
        if (self.flow_state != .ready) return;
        self.standalone_flow_checker = FlowChecker.init(
            self.allocator,
            self.parsed.ir_view,
            self.parsed.atoms,
        );
        self.standalone_flow_checker.?.scopes = self.parsed.scopes;
        self.standalone_flow_checker.?.env_public = self.env_public;
    }

    fn completeSoundExtraction(self: *ModuleAnalysisSession) !void {
        self.resolution_facts = try buildModuleFacts(self.allocator, self.parsed, null);
        const resolution_facts = &self.resolution_facts.?;

        if (hasAuthoredSource(self.source_types)) {
            try self.type_env_storage.initWithSource(
                self.allocator,
                try sourceTypeInput(self.parsed, self.source_types),
            );
        }
        self.resolved = try resolve(self.allocator, self.parsed, .{
            .type_env = self.type_env_storage.envPtr(),
            .strict = self.extraction_opts.strict,
            .module_facts = resolution_facts,
            .type_import_facts = resolution_facts,
        });
        self.resolution_state = .completed;
        const resolved = &self.resolved.?;
        if (resolved.bool_error_count > 0 or
            resolved.typeErrorCount() > 0 or
            resolved.strict_error_count > 0)
        {
            return error.SoundModeViolation;
        }

        try self.prepareStandaloneFlow();

        if (self.extraction_opts.type_check != runContractTypeCheck) return;
        if (resolved.type_checker) |*checker| {
            try checker.ensureHealthy();
            self.contract_type_state = .completed;
        } else {
            try self.completeStandaloneTypeSession();
        }
        try self.prepareContractFacts();
    }

    fn completeStandaloneTypeSession(self: *ModuleAnalysisSession) !void {
        if (self.contract_type_state != .ready) return error.AnalysisPassUnavailable;
        self.contract_type_state = .attempted;
        try self.type_env_storage.initWithSource(
            self.allocator,
            try sourceTypeInput(self.parsed, self.source_types),
        );
        self.contract_checker = TypeChecker.init(
            self.allocator,
            self.parsed.ir_view,
            self.parsed.atoms,
            self.type_env_storage.envPtr().?,
        );
        const checker = &self.contract_checker.?;
        checker.scopes = self.parsed.scopes;
        checker.import_facts = if (self.resolution_facts) |*facts_value|
            facts_value
        else if (self.contract_facts) |*facts_value|
            facts_value
        else
            null;
        _ = try checker.check(self.parsed.root);
        try checker.ensureHealthy();
        self.contract_type_state = .completed;
    }

    fn prepareContractFacts(self: *ModuleAnalysisSession) !void {
        if (self.extraction_opts.module_facts != null) return;
        // Without a registry the contract facts equal the resolution facts, so one copy serves both.
        if (self.profile == .sound_extraction and self.extraction_opts.manifest_registry == null) return;
        self.contract_facts = try buildModuleFacts(
            self.allocator,
            self.parsed,
            self.extraction_opts.manifest_registry,
        );
    }

    fn completedContractFacts(self: *ModuleAnalysisSession) *const ModuleFacts {
        if (self.profile != .full) {
            if (self.extraction_opts.module_facts) |injected| return injected;
        }
        if (self.contract_facts) |*owned_contract| return owned_contract;
        // Graph import mapping precedes custom extraction callbacks.
        if (self.resolution_facts) |*owned_resolution| return owned_resolution;
        unreachable;
    }

    fn completedTypeChecker(self: *ModuleAnalysisSession) !*TypeChecker {
        if (self.contract_type_state == .ready) {
            try self.completeStandaloneTypeSession();
        }
        if (self.contract_type_state != .completed) return error.AnalysisPassIncomplete;
        if (self.resolved) |*resolved| {
            if (resolved.type_checker) |*checker| return checker;
        }
        return if (self.contract_checker) |*checker| checker else error.AnalysisPassIncomplete;
    }

    fn prepareContractEffectFacts(
        self: *ModuleAnalysisSession,
        opts: ExtractContractOptions,
        type_env: *const TypeEnv,
        handler_fn: ?NodeIndex,
    ) !*const EffectFacts {
        if (self.contract_effect_facts != null) return error.ContractEffectFactsAlreadyPrepared;
        const built = try effect_inference.buildEffectFacts(
            self.allocator,
            self.parsed.ir_view,
            self.parsed.atoms,
            self.parsed.root,
            .{
                .manifest_registry = opts.manifest_registry,
                .module_facts = self.completedContractFacts(),
                .type_source = consumerTypeSource(self.source_types, type_env),
                .imported_effects = opts.imported_effects,
                .contract_projection = .{ .complete = .{ .selected_handler = handler_fn } },
            },
        );
        self.contract_effect_facts = built;
        return &self.contract_effect_facts.?;
    }

    fn extractDefaultResult(
        self: *ModuleAnalysisSession,
        filename: []const u8,
    ) !ContractExtraction {
        const checker = try self.completedTypeChecker();
        try checker.ensureHealthy();
        return self.extractCheckedResult(filename, self.extraction_opts, checker);
    }

    fn extractCustomResult(
        self: *ModuleAnalysisSession,
        filename: []const u8,
    ) !ContractExtraction {
        try self.extraction_type_env_storage.initWithSource(
            self.allocator,
            try sourceTypeInput(self.parsed, self.source_types),
        );
        self.contract_checker = TypeChecker.init(
            self.allocator,
            self.parsed.ir_view,
            self.parsed.atoms,
            self.extraction_type_env_storage.envPtr().?,
        );
        const checker = &self.contract_checker.?;
        checker.scopes = self.parsed.scopes;
        checker.import_facts = if (self.resolution_facts) |*facts_value| facts_value else null;
        _ = try self.extraction_opts.type_check(checker, self.parsed.root);
        try self.prepareContractFacts();
        try checker.ensureHealthy();
        return self.extractCheckedResult(filename, self.extraction_opts, checker);
    }

    fn extractCheckedResult(
        self: *ModuleAnalysisSession,
        filename: []const u8,
        base_opts: ExtractContractOptions,
        checker: *TypeChecker,
    ) !ContractExtraction {
        var opts = base_opts;
        opts.source_types = if (self.profile == .contract_only) .omitted else self.source_types;
        opts.module_facts = self.completedContractFacts();
        opts.dispatch = self.contract_context.dispatch;
        opts.has_default_response = self.contract_context.has_default_response;
        opts.verification = self.contract_context.verification;
        opts.imported_effects = self.contract_context.imported_effects;
        const handler_fn = handler_function_mod.findHandlerFunction(
            self.parsed.ir_view,
            self.parsed.root,
        );
        const handler_loc = if (handler_fn) |handler| self.parsed.ir_view.getLoc(handler) else null;
        const effects = try self.prepareContractEffectFacts(opts, checker.env, handler_fn);
        var extraction = try buildContractResultOn(
            self.allocator,
            self.parsed,
            filename,
            opts,
            checker.env,
            checker,
            consumerTypeSource(self.source_types, checker.env),
            handler_fn,
            handler_loc,
            self.completedContractFacts(),
            effects,
        );
        errdefer extraction.deinit(self.allocator);
        try checker.ensureHealthy();
        return extraction;
    }

    fn contextFromExtractOptions(opts: ExtractContractOptions) ContractContext {
        return .{
            .dispatch = opts.dispatch,
            .has_default_response = opts.has_default_response,
            .verification = opts.verification,
            .imported_effects = opts.imported_effects,
        };
    }
};

/// Build a contract from completed immutable module and effect facts.
fn buildContractResultOn(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    filename: []const u8,
    opts: ExtractContractOptions,
    type_env: *const TypeEnv,
    type_checker: *TypeChecker,
    source_types: type_env_mod.ConsumerTypeSource,
    handler_fn: ?NodeIndex,
    handler_loc: ?ir_mod.SourceLocation,
    module_facts: *const ModuleFacts,
    effect_facts: *const EffectFacts,
) !ContractExtraction {
    var builder = ContractBuilder.initForBuildWithTypeSource(
        allocator,
        parsed.ir_view,
        parsed.atoms,
        type_env,
        type_checker,
        source_types,
        module_facts,
        effect_facts,
    );
    builder.manifest_registry = opts.manifest_registry;
    builder.capture_export_effects = opts.capture_export_effects;
    builder.strict_passed = opts.strict;
    defer builder.deinit();

    var contract = try builder.build(
        filename,
        handler_loc,
        handler_fn,
        parsed.root,
        opts.dispatch,
        opts.has_default_response,
        opts.verification,
    );
    errdefer contract.deinit(allocator);
    return .{
        .contract = contract,
        .export_effects = builder.takeExportEffects(),
    };
}

/// Parse and resolve the original source, then return
/// an owned handler contract. The caller must deinit the returned contract.
pub fn extractContract(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    opts: ExtractContractOptions,
) !HandlerContract {
    if (source_frontend_mod.classifyPath(filename) == .virtual_javascript) {
        return extractVirtualContract(allocator, source, filename, opts);
    }
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, filename);
    defer frontend.deinit();
    const root = switch (frontend.parse_outcome) {
        .accepted => |accepted| accepted,
        .parser_refused => |refusal| return refusal.first_error,
        .terminal_admission_refused => |failure| return source_frontend_mod.prepareErrorForAdmissionFailure(failure),
        .recovered_admission_refused => unreachable,
    };
    const ir_view = IrView.fromIRStore(&frontend.parser.nodes, &frontend.parser.constants);
    try frontend.parser.type_store.validateRuntimeOwners(allocator, ir_view);
    var parsed = ParsedModule.fromTypedExisting(ir_view, root, &frontend.atoms, &frontend.parser.type_store);
    parsed.scopes = &frontend.parser.scopes;
    var contract_opts = opts;
    contract_opts.source_types = opts.source_types orelse .direct;
    if (hasFileImports(ir_view)) {
        const read_file = opts.read_file orelse return error.FileImportReaderRequired;
        return extractMultiModuleContract(allocator, source, filename, read_file, &frontend.atoms, contract_opts);
    }

    var single_module_opts = contract_opts;
    single_module_opts.flow = true;
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, single_module_opts);
    defer analysis.deinit();
    try analysis.complete();
    var contract = try analysis.extractContract(filename);
    errdefer contract.deinit(allocator);
    return contract;
}

/// Extract authority from prepared evaluation while omitting authored signatures and capsules.
pub fn extractPreparedEvalContract(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    opts: ExtractContractOptions,
) !HandlerContract {
    if (source_frontend_mod.classifyPath(filename) != .virtual_javascript) return error.UnsupportedSourceExtension;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try parser_mod.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = switch (try parser.parseAdmission()) {
        .accepted => |root| root,
        .parser_refused => |refusal| return refusal.first_error,
        .terminal_admission_refused => |failure| return source_frontend_mod.prepareErrorForAdmissionFailure(failure),
        .recovered_admission_refused => return error.AdmissionRefused,
    };
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    try parser.type_store.validateRuntimeOwners(allocator, view);
    var parsed = ParsedModule.fromExisting(view, root, &atoms);
    parsed.scopes = &parser.scopes;
    var options = opts;
    options.source_types = .omitted;
    if (hasFileImports(view)) {
        const reader = options.read_file orelse return error.FileImportReaderRequired;
        return extractMultiModuleContractWithEntry(allocator, source, filename, reader, &atoms, options, true);
    }
    var single_module_opts = options;
    single_module_opts.flow = true;
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, single_module_opts);
    defer analysis.deinit();
    try analysis.complete();
    var contract = try analysis.extractContract(filename);
    errdefer contract.deinit(allocator);
    return contract;
}

fn extractVirtualContract(allocator: std.mem.Allocator, source: []const u8, filename: []const u8, opts: ExtractContractOptions) !HandlerContract {
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var parsed = ParsedModule.fromExisting(view, root, &atoms);
    parsed.scopes = &parser.scopes;
    if (hasFileImports(view)) {
        const read_file = opts.read_file orelse return error.FileImportReaderRequired;
        return extractMultiModuleContract(allocator, source, filename, read_file, &atoms, opts);
    }
    var single_module_opts = opts;
    single_module_opts.flow = true;
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, single_module_opts);
    defer analysis.deinit();
    try analysis.complete();
    var contract = try analysis.extractContract(filename);
    errdefer contract.deinit(allocator);
    return contract;
}

fn hasFileImports(ir_view: IrView) bool {
    for (0..ir_view.nodeCount()) |idx| {
        const tag = ir_view.getTag(@intCast(idx)) orelse continue;
        if (tag != .import_decl) continue;

        const import_decl = ir_view.getImportDecl(@intCast(idx)) orelse continue;
        const module_name = ir_view.getString(import_decl.module_idx) orelse continue;
        switch (modules_mod.resolver.resolve(module_name)) {
            .file => return true,
            .virtual, .unknown => {},
        }
    }
    return false;
}

fn extractMultiModuleContract(
    allocator: std.mem.Allocator,
    entry_source: []const u8,
    entry_filename: []const u8,
    read_file: modules_mod.module_graph.ReadFileFn,
    atoms: *AtomTable,
    opts: ExtractContractOptions,
) !HandlerContract {
    return extractMultiModuleContractWithEntry(allocator, entry_source, entry_filename, read_file, atoms, opts, false);
}

fn extractMultiModuleContractWithEntry(
    allocator: std.mem.Allocator,
    entry_source: []const u8,
    entry_filename: []const u8,
    read_file: modules_mod.module_graph.ReadFileFn,
    atoms: *AtomTable,
    opts: ExtractContractOptions,
    prepared_eval: bool,
) !HandlerContract {
    var graph = modules_mod.ModuleGraph.init(allocator);
    defer graph.deinit();
    if (prepared_eval) {
        try graph.buildPreparedEval(entry_filename, entry_source, read_file);
    } else {
        try graph.build(entry_filename, entry_source, read_file);
    }

    var strings = string_mod.StringTable.init(allocator);
    defer strings.deinit();

    var module_compiler = modules_mod.ModuleCompiler.init(allocator, atoms, &strings);
    var compile_result = try module_compiler.compileAll(&graph);
    defer compile_result.deinit();
    defer {
        for (compile_result.codegens) |*codegen| codegen.freeOwnedConstantPayloads();
    }

    var merged = try handler_contract_mod.initMergedContract(allocator, entry_filename);
    errdefer merged.deinit(allocator);

    var loaded_effects: std.ArrayList(LoadedModuleEffects) = .empty;
    defer {
        for (loaded_effects.items) |*loaded| loaded.deinit(allocator);
        loaded_effects.deinit(allocator);
    }

    const entry_index = compile_result.modules.len - 1;
    for (compile_result.modules, compile_result.parsers, 0..) |compiled_module, *js_parser, idx| {
        const graph_idx = graph.execution_order[idx];
        const module = &graph.module_list.items[graph_idx];
        const is_entry = idx == entry_index;
        const module_view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
        var parsed = if (module.source_profile == .direct)
            ParsedModule.fromTypedExisting(module_view, compiled_module.root, atoms, &js_parser.type_store)
        else
            ParsedModule.fromExisting(module_view, compiled_module.root, atoms);
        parsed.scopes = &js_parser.scopes;

        var module_opts = opts;
        if (is_entry) {
            module_opts.source_types = opts.source_types;
        } else {
            module_opts.source_types = .omitted;
        }
        module_opts.read_file = null;
        module_opts.capture_export_effects = true;
        module_opts.flow = false;
        if (!is_entry) {
            module_opts.dispatch = null;
            module_opts.has_default_response = false;
            module_opts.verification = null;
        }

        var analysis: ModuleAnalysisSession = .{};
        try analysis.initSoundExtraction(allocator, parsed, module_opts);
        defer analysis.deinit();
        try analysis.complete();

        const imported_effects = try importedEffectsForLoadedModule(
            allocator,
            &graph,
            graph_idx,
            try analysis.facts(),
            loaded_effects.items,
        );
        defer allocator.free(imported_effects);
        try analysis.setImportedEffects(imported_effects);

        var module_contract = try analysis.extractContract(module.path);
        defer module_contract.deinit(allocator);
        try handler_contract_mod.mergeModuleContract(allocator, &merged, &module_contract, is_entry);

        var export_effects = analysis.takeExportEffects() orelse
            return error.ExportEffectsNotCaptured;
        loaded_effects.append(allocator, .{
            .graph_index = graph_idx,
            .effects = export_effects,
        }) catch |err| {
            export_effects.deinit(allocator);
            return err;
        };
    }

    return merged;
}

comptime {
    _ = @import("pipeline_tests.zig");
}
