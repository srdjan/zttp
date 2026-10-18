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
//!
//! See: /Users/srdjans/.claude/plans/study-following-doc-document-luminous-fog.md

const std = @import("std");

const parser_mod = @import("zts-engine").parser;
const bool_checker_mod = @import("bool_checker.zig");
const type_checker_mod = @import("type_checker.zig");
const strict_checker_mod = @import("strict_checker.zig");
const handler_verifier_mod = @import("handler_verifier.zig");
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
/// The index cannot live inside `ResolvedModule` or `CheckedModule`: both are
/// returned by value, so a pointer into either dangles once the phase function
/// returns. Caller storage is the only stable home, which is the same reason
/// `CheckedModule` borrows `*const ResolvedModule`.
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
        flow.facts = opts.module_facts;
        if (tc_ptr) |tc| flow.setTypeChecker(tc);
        errdefer flow.deinit();
        for (opts.imported_fn_summaries) |*entry| {
            flow.setFileFunctionSummary(entry.slot, &entry.summary);
        }

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

/// The sink summary of a function imported from another file (plan unit F7).
pub const ImportedSummary = flow_checker_mod.ImportedSummary;

/// The sink summary of a function imported from another file, paired with the
/// local binding slot the import produced. The pipeline does no file I/O, so
/// the caller reads and walks those files and hands the answers in. The flow
/// checker copies each summary, so the caller keeps ownership of its own.
pub const ImportedFnSummary = struct {
    slot: u16,
    summary: ImportedSummary,
};

pub const CheckOptions = struct {
    /// Shared import index for this compile. Same lifetime rule as
    /// `ResolveOptions.module_facts`. An options struct rather than a fourth
    /// positional parameter so the next addition does not churn every call site.
    module_facts: ?*const ModuleFacts = null,
    /// Cross-file helper sink summaries. Empty means every such call is treated
    /// as untraceable, which is the conservative direction, not the neutral one.
    imported_fn_summaries: []const ImportedFnSummary = &.{},
};

pub fn check(
    allocator: std.mem.Allocator,
    resolved: *ResolvedModule,
    handler_func: NodeIndex,
    opts: CheckOptions,
) !CheckedModule {
    var checked = try CheckedModule.init(allocator, resolved, opts);
    errdefer checked.deinit();
    _ = try checked.runVerifier(handler_func);
    _ = try checked.runFlow(handler_func);
    return checked;
}

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

    fn finishInitialization(self: *TypeEnvStorage) !void {
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
    /// The type session this compile already ran. When it carries a
    /// `TypeChecker`, the contract is built on that checker rather than on a
    /// second pool, env, and checker constructed identically and re-checked
    /// over the same root.
    resolved: ?*ResolvedModule = null,
    /// File-import effects prepared from earlier modules in one loaded graph.
    /// Borrowed through extraction only.
    imported_effects: []const ImportedEffect = &.{},
    /// Return an owned export table beside the contract.
    capture_export_effects: bool = false,
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

fn consumerTypeSourceForExistingChecker(
    options: ExtractContractOptions,
    parsed: ParsedModule,
    env: *const TypeEnv,
) !type_env_mod.ConsumerTypeSource {
    if (options.source_types) |source| {
        switch (source) {
            .direct => _ = try sourceTypeInput(parsed, .direct),
            .omitted => {},
        }
        const selected = consumerTypeSource(source, env);
        _ = try selected.validate();
        return selected;
    }
    return type_env_mod.ConsumerTypeSource.fromEnvironment(env);
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

    const FullConfig = struct {
        strict: bool = true,
        manifest_registry: ?*const manifest_registry_mod.Registry = null,
        policy_sections: guard_catalog.SectionSet = .{},
    };

    pub const ContractOnlyOptions = struct {
        extraction: ExtractContractOptions = .{},
        select_flow: bool = false,
    };

    pub const ContractContext = struct {
        dispatch: ?*const PatternDispatchTable = null,
        has_default_response: bool = false,
        verification: ?VerificationInfo = null,
        imported_effects: []const ImportedEffect = &.{},
    };

    allocator: std.mem.Allocator = undefined,
    parsed: ParsedModule = undefined,
    profile: Profile = undefined,
    full_opts: FullConfig = .{},
    extraction_opts: ExtractContractOptions = .{},
    source_types: ModuleSourceTypeInput = .omitted,
    contract_context: ContractContext = .{},
    state: SessionState = .uninitialized,
    type_env_storage: TypeEnvStorage = .{},
    extraction_type_env_storage: TypeEnvStorage = .{},
    resolved: ?ResolvedModule = null,
    checked: ?CheckedModule = null,
    standalone_checker: ?TypeChecker = null,
    extraction_checker: ?TypeChecker = null,
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
            .full_opts = .{
                .strict = opts.strict,
                .manifest_registry = opts.manifest_registry,
                .policy_sections = opts.policy_sections,
            },
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
            .flow_state = if (opts.select_flow) .ready else .skipped,
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
            .flow_state = .skipped,
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
        if (self.extraction_checker) |*checker| checker.deinit();
        self.extraction_checker = null;
        if (self.standalone_checker) |*checker| checker.deinit();
        self.standalone_checker = null;
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

    /// Prepare path effect facts once and return the cached outcome.
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
        self.contract_context = context;
    }

    pub fn setImportedEffects(
        self: *ModuleAnalysisSession,
        imported_effects: []const ImportedEffect,
    ) !void {
        if (self.state != .completed) return error.AnalysisNotCompleted;
        if (self.extraction_state != .ready) return error.ContractExtractionAlreadyAttempted;
        self.contract_context.imported_effects = imported_effects;
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
        self.exported_effects = extraction.export_effects;
        extraction.export_effects = null;
        self.extraction_state = .completed;
        return extraction.contract;
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
            self.full_opts.manifest_registry,
        );
        if (hasAuthoredSource(self.source_types)) {
            try self.type_env_storage.initWithSource(
                self.allocator,
                try sourceTypeInput(self.parsed, self.source_types),
            );
        }
        self.resolved = try resolve(self.allocator, self.parsed, .{
            .type_env = self.type_env_storage.envPtr(),
            .strict = self.full_opts.strict,
            .module_facts = &self.contract_facts.?,
            .policy_sections = self.full_opts.policy_sections,
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
        try self.prepareContractFacts(false);
        if (self.flow_state == .ready) {
            self.standalone_flow_checker = FlowChecker.init(
                self.allocator,
                self.parsed.ir_view,
                self.parsed.atoms,
            );
            self.standalone_flow_checker.?.facts = self.completedContractFacts();
        }
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
        });
        self.resolution_state = .completed;
        const resolved = &self.resolved.?;
        if (resolved.bool_error_count > 0 or
            resolved.typeErrorCount() > 0 or
            resolved.strict_error_count > 0)
        {
            return error.SoundModeViolation;
        }

        if (self.extraction_opts.type_check != runContractTypeCheck) return;
        if (resolved.type_checker) |*checker| {
            try checker.ensureHealthy();
            self.contract_type_state = .completed;
        } else {
            try self.completeStandaloneTypeSession();
        }
        try self.prepareContractFacts(false);
    }

    fn completeStandaloneTypeSession(self: *ModuleAnalysisSession) !void {
        if (self.contract_type_state != .ready) return error.AnalysisPassUnavailable;
        self.contract_type_state = .attempted;
        try self.type_env_storage.initWithSource(
            self.allocator,
            try sourceTypeInput(self.parsed, self.source_types),
        );
        self.standalone_checker = TypeChecker.init(
            self.allocator,
            self.parsed.ir_view,
            self.parsed.atoms,
            self.type_env_storage.envPtr().?,
        );
        const checker = &self.standalone_checker.?;
        _ = try checker.check(self.parsed.root);
        try checker.ensureHealthy();
        self.contract_type_state = .completed;
    }

    fn prepareContractFacts(self: *ModuleAnalysisSession, force_distinct: bool) !void {
        if (self.extraction_opts.module_facts != null) return;
        if (!force_distinct and
            self.profile == .sound_extraction and
            self.extraction_opts.manifest_registry == null)
        {
            return;
        }
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
        return if (self.standalone_checker) |*checker| checker else error.AnalysisPassIncomplete;
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
        var opts = if (self.profile == .full) ExtractContractOptions{
            .strict = self.full_opts.strict,
            .manifest_registry = self.full_opts.manifest_registry,
        } else self.extraction_opts;
        opts.source_types = self.source_types;
        opts.resolved = null;
        opts.module_facts = self.completedContractFacts();
        if (self.profile == .contract_only) opts.source_types = .omitted;
        opts.dispatch = self.contract_context.dispatch;
        opts.has_default_response = self.contract_context.has_default_response;
        opts.verification = self.contract_context.verification;
        opts.imported_effects = self.contract_context.imported_effects;
        const checker = try self.completedTypeChecker();
        try checker.ensureHealthy();
        const handler_fn = handler_verifier_mod.findHandlerFunction(
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

    fn extractCustomResult(
        self: *ModuleAnalysisSession,
        filename: []const u8,
    ) !ContractExtraction {
        try self.extraction_type_env_storage.initWithSource(
            self.allocator,
            try sourceTypeInput(self.parsed, self.source_types),
        );
        self.extraction_checker = TypeChecker.init(
            self.allocator,
            self.parsed.ir_view,
            self.parsed.atoms,
            self.extraction_type_env_storage.envPtr().?,
        );
        const checker = &self.extraction_checker.?;
        _ = try self.extraction_opts.type_check(checker, self.parsed.root);
        try self.prepareContractFacts(true);
        try checker.ensureHealthy();

        var opts = self.extraction_opts;
        opts.source_types = self.source_types;
        opts.resolved = null;
        opts.module_facts = self.completedContractFacts();
        opts.dispatch = self.contract_context.dispatch;
        opts.has_default_response = self.contract_context.has_default_response;
        opts.verification = self.contract_context.verification;
        opts.imported_effects = self.contract_context.imported_effects;
        const handler_fn = handler_verifier_mod.findHandlerFunction(
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

/// Build a contract from a type session that the caller completed.
pub fn extractContractFromTypeSession(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    filename: []const u8,
    opts: ExtractContractOptions,
    type_checker: *TypeChecker,
) !HandlerContract {
    var extraction = try extractContractResultFromTypeSession(
        allocator,
        parsed,
        filename,
        opts,
        type_checker,
    );
    if (extraction.export_effects) |*effects| effects.deinit(allocator);
    extraction.export_effects = null;
    return extraction.contract;
}

/// Build a contract and optional export table from a completed type session.
pub fn extractContractResultFromTypeSession(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    filename: []const u8,
    opts: ExtractContractOptions,
    type_checker: *TypeChecker,
) !ContractExtraction {
    if (opts.type_check != runContractTypeCheck or opts.resolved != null) {
        return error.IncompatibleTypeSessionOptions;
    }
    try type_checker.ensureHealthy();
    const source_types = try consumerTypeSourceForExistingChecker(opts, parsed, type_checker.env);

    const handler_fn = handler_verifier_mod.findHandlerFunction(parsed.ir_view, parsed.root);
    const handler_loc = if (handler_fn) |hf| parsed.ir_view.getLoc(hf) else null;
    var extraction = try buildContractResultWithTemporaryFacts(
        allocator,
        parsed,
        filename,
        opts,
        type_checker.env,
        type_checker,
        source_types,
        handler_fn,
        handler_loc,
    );
    errdefer extraction.deinit(allocator);
    try type_checker.ensureHealthy();
    return extraction;
}

/// Build an owned handler contract from an already-parsed module.
pub fn extractContractFromParsed(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    filename: []const u8,
    opts: ExtractContractOptions,
) !HandlerContract {
    var extraction = try extractContractResultFromParsed(allocator, parsed, filename, opts);
    if (extraction.export_effects) |*effects| effects.deinit(allocator);
    extraction.export_effects = null;
    return extraction.contract;
}

/// Build a contract and optional export table from an already-parsed module.
pub fn extractContractResultFromParsed(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    filename: []const u8,
    opts: ExtractContractOptions,
) !ContractExtraction {
    const handler_fn = handler_verifier_mod.findHandlerFunction(parsed.ir_view, parsed.root);
    const handler_loc = if (handler_fn) |hf| parsed.ir_view.getLoc(hf) else null;

    if (opts.type_check == runContractTypeCheck) {
        if (opts.resolved) |resolved| {
            if (resolved.type_checker) |*tc| {
                const source_types = try consumerTypeSourceForExistingChecker(opts, parsed, tc.env);
                var extraction = try buildContractResultWithTemporaryFacts(
                    allocator,
                    parsed,
                    filename,
                    opts,
                    tc.env,
                    tc,
                    source_types,
                    handler_fn,
                    handler_loc,
                );
                errdefer extraction.deinit(allocator);
                try tc.ensureHealthy();
                return extraction;
            }
        }
    }

    const selected = normalizeModuleSourceTypes(opts.source_types);

    var storage: TypeEnvStorage = .{};
    try storage.initWithSource(allocator, try sourceTypeInput(parsed, selected));
    defer storage.deinit(allocator);
    const type_env = storage.envPtr().?;

    var type_checker = TypeChecker.init(
        allocator,
        parsed.ir_view,
        parsed.atoms,
        type_env,
    );
    defer type_checker.deinit();
    _ = try opts.type_check(&type_checker, parsed.root);

    try type_checker.ensureHealthy();
    var extraction = try buildContractResultWithTemporaryFacts(
        allocator,
        parsed,
        filename,
        opts,
        type_env,
        &type_checker,
        consumerTypeSource(selected, type_env),
        handler_fn,
        handler_loc,
    );
    errdefer extraction.deinit(allocator);
    try type_checker.ensureHealthy();
    return extraction;
}

fn buildContractResultWithTemporaryFacts(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    filename: []const u8,
    opts: ExtractContractOptions,
    type_env: *const TypeEnv,
    type_checker: *TypeChecker,
    source_types: type_env_mod.ConsumerTypeSource,
    handler_fn: ?NodeIndex,
    handler_loc: ?ir_mod.SourceLocation,
) !ContractExtraction {
    try type_checker.ensureHealthy();
    var owned_module_facts: ?ModuleFacts = if (opts.module_facts == null)
        try buildModuleFacts(allocator, parsed, opts.manifest_registry)
    else
        null;
    defer if (owned_module_facts) |*facts| facts.deinit();
    const module_facts = opts.module_facts orelse &owned_module_facts.?;

    var effect_facts = try effect_inference.buildEffectFacts(
        allocator,
        parsed.ir_view,
        parsed.atoms,
        parsed.root,
        .{
            .manifest_registry = opts.manifest_registry,
            .module_facts = module_facts,
            .type_source = source_types,
            .imported_effects = opts.imported_effects,
            .contract_projection = .{ .complete = .{ .selected_handler = handler_fn } },
        },
    );
    defer effect_facts.deinit(allocator);

    return buildContractResultOn(
        allocator,
        parsed,
        filename,
        opts,
        type_env,
        type_checker,
        source_types,
        handler_fn,
        handler_loc,
        module_facts,
        &effect_facts,
    );
}

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
    _ = parser_mod.optimizeIR(allocator, &frontend.parser.nodes, &frontend.parser.constants, root) catch {};
    const ir_view = IrView.fromIRStore(&frontend.parser.nodes, &frontend.parser.constants);
    try frontend.parser.type_store.validateRuntimeOwners(allocator, ir_view);
    const parsed = ParsedModule.fromTypedExisting(ir_view, root, &frontend.atoms, &frontend.parser.type_store);
    var contract_opts = opts;
    contract_opts.source_types = opts.source_types orelse .direct;
    if (hasFileImports(ir_view)) {
        const read_file = opts.read_file orelse return error.FileImportReaderRequired;
        return extractMultiModuleContract(allocator, source, filename, read_file, &frontend.atoms, contract_opts);
    }

    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, contract_opts);
    defer analysis.deinit();
    try analysis.complete();
    return analysis.extractContract(filename);
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
    _ = parser_mod.optimizeIR(allocator, &parser.nodes, &parser.constants, root) catch {};
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    try parser.type_store.validateRuntimeOwners(allocator, view);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);
    var options = opts;
    options.source_types = .omitted;
    if (hasFileImports(view)) {
        const reader = options.read_file orelse return error.FileImportReaderRequired;
        return extractMultiModuleContractWithEntry(allocator, source, filename, reader, &atoms, options, true);
    }
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, options);
    defer analysis.deinit();
    try analysis.complete();
    return analysis.extractContract(filename);
}

fn extractVirtualContract(allocator: std.mem.Allocator, source: []const u8, filename: []const u8, opts: ExtractContractOptions) !HandlerContract {
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    _ = parser_mod.optimizeIR(allocator, &parser.nodes, &parser.constants, root) catch {};
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);
    if (hasFileImports(view)) {
        const read_file = opts.read_file orelse return error.FileImportReaderRequired;
        return extractMultiModuleContract(allocator, source, filename, read_file, &atoms, opts);
    }
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, opts);
    defer analysis.deinit();
    try analysis.complete();
    return analysis.extractContract(filename);
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
        const parsed = if (module.source_profile == .direct)
            ParsedModule.fromTypedExisting(module_view, compiled_module.root, atoms, &js_parser.type_store)
        else
            ParsedModule.fromExisting(module_view, compiled_module.root, atoms);

        var module_opts = opts;
        if (is_entry) {
            module_opts.source_types = opts.source_types;
        } else {
            module_opts.source_types = .omitted;
        }
        module_opts.read_file = null;
        module_opts.capture_export_effects = true;
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

/// Format seconds since epoch as UTC ISO-8601 with second precision.
/// The 24-byte buffer leaves room for the full u16 year range.
pub fn formatIsoTimestamp(buf: *[24]u8, seconds_since_epoch: i64) []const u8 {
    const total_secs: u64 = @intCast(@max(0, seconds_since_epoch));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = total_secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u16, @intCast(year_day.year)),
        @as(u4, @intFromEnum(month_day.month)),
        @as(u5, month_day.day_index + 1),
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const JsParser = parser_mod.JsParser;

fn parseSourceForTest(allocator: std.mem.Allocator, source: []const u8) !struct {
    js_parser: JsParser,
    root: NodeIndex,
} {
    var js_parser = try JsParser.init(allocator, source);
    errdefer js_parser.deinit();
    const root = try js_parser.parse();
    return .{ .js_parser = js_parser, .root = root };
}

fn readGraphBaselineFile(allocator: std.mem.Allocator, path: []const u8) modules_mod.module_graph.ReadFileError![]const u8 {
    const source: []const u8 = if (std.mem.endsWith(u8, path, "shared.ts"))
        \\import { sqlOne } from "zttp:sql";
        \\export function shared() {
        \\  return fetchSync("https://shared.example/a");
        \\}
    else if (std.mem.endsWith(u8, path, "left.ts"))
        \\import { shared } from "./shared.ts";
        \\import { env } from "zttp:env";
        \\export function left() {
        \\  shared();
        \\  env("LEFT_TOKEN");
        \\  return fetchSync("https://left.example/a");
        \\}
    else if (std.mem.endsWith(u8, path, "right.ts"))
        \\import { shared } from "./shared.ts";
        \\import { cacheGet } from "zttp:cache";
        \\export function right() {
        \\  shared();
        \\  cacheGet("RIGHT_CACHE", "key");
        \\  return fetchSync("https://right.example/a");
        \\}
    else if (std.mem.endsWith(u8, path, "typed-bad.ts"))
        \\export function request() {
        \\  const port: number = "bad";
        \\  return fetchSync("https://typed-dependency.example/a");
        \\}
    else
        return error.FileNotFound;

    return allocator.dupe(u8, source);
}

fn readSiblingEffectFile(allocator: std.mem.Allocator, path: []const u8) modules_mod.module_graph.ReadFileError![]const u8 {
    if (!std.mem.endsWith(u8, path, "dep.ts")) return error.FileNotFound;
    return allocator.dupe(u8,
        \\import { cacheSet } from "zttp:cache";
        \\export function mutate() { cacheSet("state", "key", "value"); }
    );
}

const GraphCallbackModule = enum {
    shared,
    left,
    right,
    entry,
};

const GraphCallbackProbe = struct {
    modules: [4]GraphCallbackModule = undefined,
    count: usize = 0,
    fail_after: ?usize = null,
};

threadlocal var active_graph_callback_probe: ?*GraphCallbackProbe = null;

fn graphCallbackModule(type_checker: *const TypeChecker) ?GraphCallbackModule {
    for (0..type_checker.ir_view.nodeCount()) |idx| {
        const node: NodeIndex = @intCast(idx);
        const tag = type_checker.ir_view.getTag(node) orelse continue;
        if (tag != .import_decl) continue;
        const import_decl = type_checker.ir_view.getImportDecl(node) orelse continue;
        const module_name = type_checker.ir_view.getString(import_decl.module_idx) orelse continue;
        if (std.mem.eql(u8, module_name, "zttp:sql")) return .shared;
        if (std.mem.eql(u8, module_name, "zttp:env")) return .left;
        if (std.mem.eql(u8, module_name, "zttp:cache")) return .right;
        if (std.mem.eql(u8, module_name, "zttp:fetch")) return .entry;
    }
    return null;
}

fn recordGraphContractTypeCheck(type_checker: *TypeChecker, root: NodeIndex) anyerror!u32 {
    const probe = active_graph_callback_probe orelse return error.GraphCallbackProbeMissing;
    if (probe.count >= probe.modules.len) return error.GraphCallbackCountExceeded;
    probe.modules[probe.count] = graphCallbackModule(type_checker) orelse
        return error.GraphCallbackModuleUnknown;
    probe.count += 1;
    if (probe.fail_after == probe.count) return error.GraphCallbackRefused;
    return type_checker.check(root);
}

fn serializeContractForTest(allocator: std.mem.Allocator, contract: *const HandlerContract) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try handler_contract_mod.writeContractJson(contract, &output.writer);
    return output.toOwnedSlice();
}

fn extractSessionContractForTest(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    opts: ExtractContractOptions,
) !ContractExtraction {
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(
        allocator,
        ParsedModule.fromExisting(view, root, &atoms),
        .{ .extraction = opts },
    );
    defer analysis.deinit();
    try analysis.complete();

    var contract = try analysis.extractContract(filename);
    errdefer contract.deinit(allocator);
    return .{
        .contract = contract,
        .export_effects = analysis.takeExportEffects(),
    };
}

fn hasSpecDiagnosticKind(
    contract: *const HandlerContract,
    kind: handler_contract_mod.SpecDiagnostic.Kind,
) bool {
    for (contract.spec_diagnostics.items) |diagnostic| {
        if (diagnostic.kind == kind) return true;
    }
    return false;
}

fn expectStringSlices(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_item, actual_item| {
        try testing.expectEqualStrings(expected_item, actual_item);
    }
}

test "ParsedModule.fromExisting wraps an IR view" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const x = true;\n");
    defer parsed_state.js_parser.deinit();

    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    try testing.expect(view.isValid(parsed.root));
}

test "pipeline.resolve does not emit a module after analysis allocation failure" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const enabled = true;\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, resolve(failing.allocator(), parsed, .{ .strict = false }));
}

test "TypeEnvStorage rejects a poisoned TypePool" {
    const allocator = testing.allocator;
    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, storage.initWithSource(failing.allocator(), .omitted));
    try testing.expect(storage.envPtr() == null);
    try storage.initWithSource(allocator, .omitted);
    try testing.expect(storage.envPtr() != null);
}

test "TypeEnvStorage rejects a late poisoned TypePool" {
    const allocator = testing.allocator;
    var storage: TypeEnvStorage = .{};
    storage.pool = TypePool.init(allocator);
    defer storage.pool.deinit(allocator);
    try storage.pool.ensureHealthy();
    storage.env = TypeEnv.init(allocator, &storage.pool);
    defer storage.env.deinit();
    try storage.pool.ensureHealthy();
    module_types_mod.populateModuleTypes(&storage.env, &storage.pool, allocator);
    abi_types_mod.populateHandlerAbiTypes(&storage.env, &storage.pool, allocator);
    try storage.pool.ensureHealthy();
    try storage.env.populateSourceTypes(.omitted);
    try storage.pool.ensureHealthy();

    const record = storage.pool.addRecord(allocator, &.{.{
        .name_start = 0,
        .name_len = 0,
        .type_idx = storage.pool.idx_string,
        .optional = false,
    }});
    try storage.pool.ensureHealthy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    _ = storage.pool.makeReadonly(failing.allocator(), record);

    try testing.expectError(error.OutOfMemory, storage.finishInitialization());
    try testing.expect(storage.envPtr() == null);
}

test "TypeEnvStorage initializes module types with omitted source types" {
    const allocator = testing.allocator;
    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);

    try storage.initWithSource(allocator, .omitted);
    try testing.expect(storage.envPtr() != null);
}

test "TypeEnvStorage rejects a second initialization before allocation" {
    const allocator = testing.allocator;
    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);

    try storage.initWithSource(allocator, .omitted);
    const original_env = storage.envPtr().?;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });

    try testing.expectError(
        error.TypeEnvironmentAlreadyInitialized,
        storage.initWithSource(failing.allocator(), .omitted),
    );
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(original_env, storage.envPtr().?);
    try storage.pool.ensureHealthy();

    storage.deinit(allocator);
    try testing.expect(storage.envPtr() == null);
    try storage.initWithSource(allocator, .omitted);
    try testing.expect(storage.envPtr() != null);
    try storage.pool.ensureHealthy();
}

fn rejectingContractTypeCheck(_: *TypeChecker, _: NodeIndex) anyerror!u32 {
    return error.TestTypeCheckRan;
}

test "explicit type session extraction uses the completed caller session" {
    const allocator = testing.allocator;
    const source = "function handler(req) { return Response.text('ok'); }\n";
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.initWithSource(allocator, .omitted);
    var type_checker = TypeChecker.init(allocator, view, null, storage.envPtr().?);
    defer type_checker.deinit();
    _ = try type_checker.check(parsed.root);

    var contract = try extractContractFromTypeSession(
        allocator,
        parsed,
        "explicit-session.ts",
        .{},
        &type_checker,
    );
    defer contract.deinit(allocator);
    try testing.expectEqualStrings("explicit-session.ts", contract.handler.path);
    try testing.expectError(
        error.IncompatibleTypeSessionOptions,
        extractContractFromTypeSession(
            allocator,
            parsed,
            "explicit-session.ts",
            .{ .type_check = rejectingContractTypeCheck },
            &type_checker,
        ),
    );
}

test "ModuleAnalysisSession requires completion and permits one extraction" {
    const allocator = testing.allocator;
    const source = "function handler(req) { return Response.text('ok'); }\n";
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(allocator, parsed, .{});
    defer analysis.deinit();

    try testing.expectError(error.AnalysisNotCompleted, analysis.facts());
    try testing.expectError(error.AnalysisNotCompleted, analysis.pathEffectFacts());
    try testing.expectError(error.AnalysisNotCompleted, analysis.setImportedEffects(&.{}));
    try testing.expectError(error.AnalysisNotCompleted, analysis.extractContract("owner.ts"));
    try analysis.complete();
    try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
    _ = try analysis.facts();
    const first_path_effects = try analysis.pathEffectFacts();
    const second_path_effects = try analysis.pathEffectFacts();
    switch (first_path_effects) {
        .complete => |first| switch (second_path_effects) {
            .complete => |second| try testing.expect(first == second),
            .unavailable => return error.EffectFactsExpected,
        },
        .unavailable => return error.EffectFactsExpected,
    }
    try analysis.setImportedEffects(&.{});

    var contract = try analysis.extractContract("owner.ts");
    defer contract.deinit(allocator);
    try testing.expectEqualStrings("owner.ts", contract.handler.path);
    try testing.expectError(
        error.ContractExtractionAlreadyAttempted,
        analysis.extractContract("owner.ts"),
    );
}

test "ModuleAnalysisSession caches unavailable path effects after one attempt" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(failing.allocator(), parsed, .{});
    defer analysis.deinit();
    try analysis.complete();

    failing.fail_index = failing.alloc_index;
    switch (try analysis.pathEffectFacts()) {
        .unavailable => {},
        .complete => return error.UnavailableEffectFactsExpected,
    }
    try testing.expect(failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    switch (try analysis.pathEffectFacts()) {
        .unavailable => {},
        .complete => return error.UnavailableEffectFactsExpected,
    }
}

test "ModuleAnalysisSession does not retry a refused sound analysis" {
    const allocator = testing.allocator;
    const source =
        \\if ({}) { const unreachable = true; }
        \\function handler(req) { return Response.text("ok"); }
    ;
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, .{ .strict = false });
    defer analysis.deinit();

    try testing.expectError(error.SoundModeViolation, analysis.complete());
    try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
    try testing.expectError(error.AnalysisNotCompleted, analysis.extractContract("refused.ts"));
}

test "ModuleAnalysisSession cleans a partial completion failure" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(failing.allocator(), parsed, .{ .extraction = .{
        .capture_export_effects = true,
    } });
    defer analysis.deinit();

    try testing.expectError(error.OutOfMemory, analysis.complete());
    try testing.expect(failing.has_induced_failure);
    try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
}

test "ModuleAnalysisSession publishes owned exports for both extraction profiles" {
    const allocator = testing.allocator;
    const source =
        \\export function sibling() { return Date.now(); }
        \\function handler(req) { return Response.text("ok"); }
    ;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);

    inline for (.{ ModuleAnalysisSession.Profile.contract_only, .sound_extraction }) |profile| {
        var analysis: ModuleAnalysisSession = .{};
        const extraction_opts = ExtractContractOptions{
            .strict = false,
            .capture_export_effects = true,
        };
        if (profile == .contract_only) {
            try analysis.initContractOnly(allocator, parsed, .{ .extraction = extraction_opts });
        } else {
            try analysis.initSoundExtraction(allocator, parsed, extraction_opts);
        }
        try analysis.complete();

        var contract = try analysis.extractContract("exports.ts");
        const contract_json = try serializeContractForTest(allocator, &contract);
        defer allocator.free(contract_json);
        try testing.expect(std.mem.indexOf(u8, contract_json, "effectAnalysisComplete") == null);
        try testing.expect(std.mem.indexOf(u8, contract_json, "effect_analysis_complete") == null);
        contract.deinit(allocator);
        var effects = analysis.takeExportEffects() orelse return error.ExportEffectsMissing;
        analysis.deinit();
        defer effects.deinit(allocator);

        switch (effects.lookup("sibling")) {
            .callable => |row| try testing.expect(!row.deterministic),
            .data, .blocked => return error.CallableExportExpected,
        }
    }
}

test "contract summary keeps selected handler separate from first named effect row" {
    const allocator = testing.allocator;
    const source =
        \\import { cacheSet } from "zttp:cache";
        \\{
        \\  function handler(req) { return Response.text("local"); }
        \\}
        \\function handler(req): Effects<Response, "clock"> {
        \\  cacheSet("state", "key", "value", 10);
        \\  return Response.text("global");
        \\}
    ;
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, "duplicate-handler.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initFull(allocator, ParsedModule.fromTypedExisting(
        accepted.ir_view,
        accepted.root,
        accepted.atoms,
        accepted.type_store,
    ), .{
        .source_types = .direct,
        .strict = false,
    });
    defer analysis.deinit();
    try analysis.complete();
    var result = try analysis.extractContract("duplicate-handler.ts");
    defer result.deinit(allocator);

    const contract = &result;
    const props = contract.properties orelse return error.MissingProperties;
    try testing.expect(!props.pure);
    try testing.expect(!props.read_only);
    try testing.expect(!props.stateless);
    try testing.expect(!props.retry_safe);
    try testing.expect(props.deterministic);
    try testing.expect(!props.has_egress);
    try testing.expect(!props.idempotent);

    try testing.expect(contract.effect_analysis_complete);
    try testing.expect(contract.capability_budget.has(.clock));
    try testing.expect(!contract.capability_budget.has(.policy_check));
    try testing.expect(!hasSpecDiagnosticKind(contract, .budget_exceeded));
    try testing.expect(!hasSpecDiagnosticKind(contract, .helper_budget_exceeded));
}

test "ambient egress summary follows inline callbacks but not named callback values" {
    const allocator = testing.allocator;
    const named_source =
        \\export function leaky() {
        \\  return fetchSync("https://named.example/a");
        \\}
        \\function handler(req) {
        \\  [1].map(leaky);
        \\  return Response.text("ok");
        \\}
    ;
    const inline_source =
        \\function handler(req) {
        \\  [1].map(() => fetchSync("https://inline.example/a"));
        \\  return Response.text("ok");
        \\}
    ;
    var named = try extractSessionContractForTest(
        allocator,
        named_source,
        "named-callback.ts",
        .{ .strict = false, .capture_export_effects = true },
    );
    defer named.deinit(allocator);
    var inline_callback = try extractSessionContractForTest(
        allocator,
        inline_source,
        "inline-callback.ts",
        .{ .strict = false },
    );
    defer inline_callback.deinit(allocator);

    const named_props = named.contract.properties orelse return error.MissingProperties;
    const inline_props = inline_callback.contract.properties orelse return error.MissingProperties;
    try testing.expect(!named_props.has_egress);
    try testing.expect(inline_props.has_egress);

    const exports = named.export_effects orelse return error.ExportEffectsMissing;
    switch (exports.lookup("leaky")) {
        .callable => |row| {
            try testing.expect(row.pure);
            try testing.expect(!row.has_egress);
            try testing.expect(!row.writes);
            try testing.expect(row.lower_bound);
        },
        .data, .blocked => return error.CallableExportExpected,
    }

    try testing.expectEqual(@as(usize, 1), named.contract.function_effect_capsules.items.len);
    const capsule = named.contract.function_effect_capsules.items[0];
    try testing.expectEqualStrings("leaky", capsule.function);
    try testing.expectEqual(@as(usize, 0), capsule.declared.items.len);
    try testing.expectEqual(@as(usize, 0), capsule.inferred.items.len);
    try testing.expect(!capsule.discharged);
    try testing.expect(capsule.exported);
    try testing.expect(capsule.handler_reachable);
}

test "ambient egress summary keeps raw generic binding precedence" {
    const allocator = testing.allocator;
    const source =
        \\import { env as length } from "zttp:env";
        \\function handler(req) {
        \\  const a = 1;
        \\  const b = 2;
        \\  const c = 3;
        \\  function leaky() { return fetchSync("https://legacy.example/a"); }
        \\  leaky();
        \\  return Response.text("ok");
        \\}
    ;
    var extraction = try extractSessionContractForTest(
        allocator,
        source,
        "generic-precedence.ts",
        .{ .strict = false },
    );
    defer extraction.deinit(allocator);

    const props = extraction.contract.properties orelse return error.MissingProperties;
    try testing.expect(!props.has_egress);
}

test "no-handler properties include every unused builtin import" {
    const allocator = testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        read_only: bool,
        stateless: bool,
        retry_safe: bool,
    }{
        .{
            .source = "import { cacheGet } from \"zttp:cache\";",
            .read_only = true,
            .stateless = false,
            .retry_safe = true,
        },
        .{
            .source = "import { cacheSet } from \"zttp:cache\";",
            .read_only = false,
            .stateless = false,
            .retry_safe = false,
        },
    };

    for (cases) |case| {
        var extraction = try extractSessionContractForTest(
            allocator,
            case.source,
            "no-handler-builtin.ts",
            .{ .strict = false },
        );
        defer extraction.deinit(allocator);
        const contract = &extraction.contract;
        const props = contract.properties orelse return error.MissingProperties;
        try testing.expect(!props.pure);
        try testing.expectEqual(case.read_only, props.read_only);
        try testing.expectEqual(case.stateless, props.stateless);
        try testing.expectEqual(case.retry_safe, props.retry_safe);
        try testing.expect(!props.deterministic);
        try testing.expect(!props.has_egress);
        try testing.expect(!props.idempotent);
        try testing.expect(!contract.effect_analysis_complete);
    }
}

test "no-handler properties include an unused registered partner import" {
    const allocator = testing.allocator;
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:legacy-summary",
        \\  "exports": [
        \\    { "name": "lookup", "effect": "read", "returns": "result" }
        \\  ]
        \\}
    ;
    var manifest = try @import("zts-engine").module_manifest.parse(allocator, manifest_json);
    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    registry.register(manifest) catch |err| {
        manifest.deinit(allocator);
        return err;
    };

    var extraction = try extractSessionContractForTest(
        allocator,
        "import { lookup } from \"zttp-ext:legacy-summary\";",
        "no-handler-partner.ts",
        .{ .strict = false, .manifest_registry = &registry },
    );
    defer extraction.deinit(allocator);

    const contract = &extraction.contract;
    const props = contract.properties orelse return error.MissingProperties;
    try testing.expect(!props.pure);
    try testing.expect(props.read_only);
    try testing.expect(props.stateless);
    try testing.expect(props.retry_safe);
    try testing.expect(!props.deterministic);
    try testing.expect(!props.has_egress);
    try testing.expect(!props.idempotent);
    try testing.expect(!contract.effect_analysis_complete);
}

test "late export capture failure releases a transferred rate limit namespace" {
    const allocator = testing.allocator;
    const source =
        \\import { rateCheck } from "zttp:ratelimit";
        \\export function allowed() { return rateCheck("login-attempts", 5, 60); }
        \\function handler(req) { return Response.text(String(allowed())); }
    ;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);

    const Run = struct {
        fn extract(run_allocator: std.mem.Allocator, module: ParsedModule) !void {
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initContractOnly(run_allocator, module, .{ .extraction = .{
                .capture_export_effects = true,
            } });
            defer analysis.deinit();
            try analysis.complete();

            var contract = try analysis.extractContract("rate-limit.ts");
            defer contract.deinit(run_allocator);
            try testing.expect(contract.rate_limiting != null);
            var effects = analysis.takeExportEffects() orelse return error.ExportEffectsMissing;
            defer effects.deinit(run_allocator);
        }
    };

    var counting = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    try Run.extract(counting.allocator(), parsed);
    try testing.expect(counting.alloc_index > 0);

    var failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = counting.alloc_index - 1,
    });
    try testing.expectError(error.OutOfMemory, Run.extract(failing.allocator(), parsed));
    try testing.expect(failing.has_induced_failure);
}

test "ModuleAnalysisSession refuses extraction retry after allocation failure" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(failing.allocator(), parsed, .{ .extraction = .{
        .capture_export_effects = true,
    } });
    defer analysis.deinit();
    try analysis.complete();

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, analysis.extractContract("allocation.ts"));
    try testing.expect(failing.has_induced_failure);
    try testing.expect(analysis.contract_effect_facts == null);
    try testing.expect(analysis.takeExportEffects() == null);
    try testing.expectError(
        error.ContractExtractionAlreadyAttempted,
        analysis.extractContract("allocation.ts"),
    );
}

test "ModuleAnalysisSession profiles preserve type diagnostic acceptance" {
    const allocator = testing.allocator;
    const source =
        \\const joined = 1 + "y";
        \\function handler(req: Request): Response {
        \\  return Response.text(String(joined));
        \\}
    ;
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, "profile.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const parsed = ParsedModule.fromTypedExisting(
        accepted.ir_view,
        accepted.root,
        accepted.atoms,
        accepted.type_store,
    );

    var contract_only: ModuleAnalysisSession = .{};
    try contract_only.initContractOnly(allocator, parsed, .{
        .extraction = .{ .source_types = .direct },
    });
    defer contract_only.deinit();
    try contract_only.complete();
    var contract = try contract_only.extractContract("profile.ts");
    defer contract.deinit(allocator);

    var sound: ModuleAnalysisSession = .{};
    try sound.initSoundExtraction(allocator, parsed, .{
        .strict = false,
        .source_types = .direct,
    });
    defer sound.deinit();
    try testing.expectError(error.SoundModeViolation, sound.complete());
}

test "ModuleAnalysisSession full profile supports typed and untyped extraction" {
    const allocator = testing.allocator;
    const typed_source = "function handler(req: Request): Response { return Response.text('ok'); }\n";
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, typed_source, "typed.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const typed_parsed = ParsedModule.fromTypedExisting(
        accepted.ir_view,
        accepted.root,
        accepted.atoms,
        accepted.type_store,
    );

    var typed: ModuleAnalysisSession = .{};
    try typed.initFull(allocator, typed_parsed, .{
        .source_types = .direct,
        .strict = false,
    });
    defer typed.deinit();
    try testing.expect(!typed.type_env_storage.initialized);
    try testing.expect(typed.resolved == null);
    try typed.complete();
    try testing.expect((try typed.resolvedForReport()).type_checker != null);
    var typed_contract = try typed.extractContract("typed.ts");
    defer typed_contract.deinit(allocator);

    var untyped_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer untyped_state.js_parser.deinit();
    const untyped_view = IrView.fromIRStore(&untyped_state.js_parser.nodes, &untyped_state.js_parser.constants);
    const untyped_parsed = ParsedModule.fromExisting(untyped_view, untyped_state.root, null);
    var untyped: ModuleAnalysisSession = .{};
    try untyped.initFull(allocator, untyped_parsed, .{ .strict = false });
    defer untyped.deinit();
    try untyped.complete();
    try testing.expect((try untyped.resolvedForReport()).type_checker == null);
    try testing.expectEqual(ModuleAnalysisSession.PassState.ready, untyped.contract_type_state);
    var untyped_contract = try untyped.extractContract("untyped.ts");
    defer untyped_contract.deinit(allocator);
    try testing.expectEqual(ModuleAnalysisSession.PassState.completed, untyped.contract_type_state);
}

test "ModuleAnalysisSession keeps skipped passes distinct" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const handler = handler_verifier_mod.findHandlerFunction(view, parsed.root) orelse
        return error.HandlerNotFound;

    var session: ModuleAnalysisSession = .{};
    try session.initFull(allocator, parsed, .{ .strict = false });
    defer session.deinit();
    try session.complete();
    try testing.expectEqual(ModuleAnalysisSession.PassState.skipped, session.verifier_state);
    try testing.expectEqual(ModuleAnalysisSession.PassState.skipped, session.flow_state);
    try testing.expectError(error.AnalysisPassUnavailable, session.runVerifier(handler));
    try testing.expectError(error.AnalysisPassUnavailable, session.runFlow(handler));
}

test "ModuleAnalysisSession refuses publication after failed selected passes" {
    const allocator = testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) { return Response.text('ok'); }
    ;
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const handler = handler_verifier_mod.findHandlerFunction(view, parsed.root) orelse
        return error.HandlerNotFound;

    inline for (.{ true, false }) |select_verifier| {
        var failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = std.math.maxInt(usize),
        });
        var session: ModuleAnalysisSession = .{};
        try session.initFull(failing.allocator(), parsed, .{
            .strict = false,
            .select_verifier = select_verifier,
            .select_flow = !select_verifier,
        });
        defer session.deinit();
        try session.complete();
        try session.prepareChecked(handler, .{ .module_facts = try session.facts() });

        failing.fail_index = failing.alloc_index;
        if (select_verifier) {
            try testing.expectError(error.OutOfMemory, session.runVerifier(handler));
            try testing.expectError(error.AnalysisPassUnavailable, session.runVerifier(handler));
        } else {
            try testing.expectError(error.OutOfMemory, session.runFlow(handler));
            try testing.expectError(error.AnalysisPassUnavailable, session.runFlow(handler));
        }
        try testing.expect(failing.has_induced_failure);
        failing.fail_index = std.math.maxInt(usize);
        try testing.expectError(error.AnalysisPassIncomplete, session.extractContract("failed-pass.ts"));
        try testing.expect(session.takeExportEffects() == null);
    }
}

test "ModuleAnalysisSession explicit refusal stops selected passes and extraction" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const handler = handler_verifier_mod.findHandlerFunction(view, parsed.root) orelse
        return error.HandlerNotFound;

    var session: ModuleAnalysisSession = .{};
    try session.initFull(allocator, parsed, .{
        .strict = false,
        .select_verifier = true,
        .select_flow = true,
    });
    defer session.deinit();
    try session.complete();
    session.refuseResolution();
    _ = (try session.resolvedForReport()).boolDiagnostics();
    try testing.expectError(error.AnalysisPassUnavailable, session.runVerifier(handler));
    try testing.expectError(error.AnalysisPassUnavailable, session.runFlow(handler));
    try testing.expectError(error.AnalysisNotResolved, session.extractContract("refused.ts"));
}

test "ModuleAnalysisSession contract-only flow can run after extraction" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const handler = handler_verifier_mod.findHandlerFunction(view, parsed.root) orelse
        return error.HandlerNotFound;

    var session: ModuleAnalysisSession = .{};
    try session.initContractOnly(allocator, parsed, .{ .select_flow = true });
    defer session.deinit();
    try session.complete();
    var contract = try session.extractContract("flow-after.ts");
    defer contract.deinit(allocator);
    try testing.expectEqual(@as(u32, 0), try session.runFlow(handler));
    _ = try session.completedFlow();
}

fn extractOwnedSessionResultsForTest(allocator: std.mem.Allocator) !ContractExtraction {
    const source = "export function sibling() { return Date.now(); }\n" ++
        "function handler(req: Request): Response { return Response.text('ok'); }\n";
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initInPlace(allocator, allocator, source, "owned.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const view = IrView.fromIRStore(&frontend.parser.nodes, &frontend.parser.constants);

    var session: ModuleAnalysisSession = .{};
    try session.initContractOnly(
        allocator,
        ParsedModule.fromTypedExisting(view, accepted.root, accepted.atoms, accepted.type_store),
        .{ .extraction = .{ .source_types = .direct, .capture_export_effects = true } },
    );
    defer session.deinit();
    try session.complete();
    var contract = try session.extractContract("owned.ts");
    errdefer contract.deinit(allocator);
    return .{
        .contract = contract,
        .export_effects = session.takeExportEffects() orelse return error.ExportEffectsMissing,
    };
}

test "ModuleAnalysisSession results survive every borrowed input" {
    const allocator = testing.allocator;
    var extraction = try extractOwnedSessionResultsForTest(allocator);
    defer extraction.deinit(allocator);
    try testing.expectEqualStrings("owned.ts", extraction.contract.handler.path);
    switch (extraction.export_effects.?.lookup("sibling")) {
        .callable => |row| try testing.expect(!row.deterministic),
        .data, .blocked => return error.CallableExportExpected,
    }
}

test "ModuleAnalysisSession runs a custom callback only during extraction" {
    const allocator = testing.allocator;
    var source_owner: source_frontend_mod.DirectCheckSource = undefined;
    try source_owner.initInPlace(allocator, allocator, "function handler(req) { return Response.text('ok'); }\n", "custom.ts");
    defer source_owner.deinit();
    const accepted = source_owner.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const parsed = ParsedModule.fromTypedExisting(accepted.ir_view, accepted.root, accepted.atoms, accepted.type_store);
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, .{
        .strict = false,
        .source_types = .direct,
        .type_check = rejectingContractTypeCheck,
        .capture_export_effects = true,
    });
    defer analysis.deinit();

    try analysis.complete();
    try testing.expectError(error.TestTypeCheckRan, analysis.extractContract("custom.ts"));
    try testing.expect(analysis.extraction_checker != null);
    try testing.expect(analysis.resolved.?.type_checker != null);
    try testing.expect(&analysis.extraction_checker.? != &analysis.resolved.?.type_checker.?);
    try testing.expect(analysis.contract_facts == null);
    try testing.expect(analysis.takeExportEffects() == null);
    try testing.expectError(
        error.ContractExtractionAlreadyAttempted,
        analysis.extractContract("custom.ts"),
    );
}

test "ModuleAnalysisSession keeps resolution and contract facts distinct" {
    const allocator = testing.allocator;
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:owner-test",
        \\  "exports": [{ "name": "lookup", "effect": "read", "returns": "result" }]
        \\}
    ;
    var manifest = try @import("zts-engine").module_manifest.parse(allocator, manifest_json);
    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    registry.register(manifest) catch |err| {
        manifest.deinit(allocator);
        return err;
    };

    const source =
        \\import { lookup } from "zttp-ext:owner-test";
        \\function handler(req) { return Response.text("ok"); }
    ;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = try JsParser.init(allocator, source);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    const root = try js_parser.parse();
    const view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);

    var registry_analysis: ModuleAnalysisSession = .{};
    try registry_analysis.initSoundExtraction(allocator, parsed, .{
        .strict = false,
        .manifest_registry = &registry,
    });
    defer registry_analysis.deinit();
    try registry_analysis.complete();
    var registry_contract = try registry_analysis.extractContract("registry.ts");
    defer registry_contract.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), registry_contract.modules.items.len);
    try testing.expectEqualStrings("zttp-ext:owner-test", registry_contract.modules.items[0]);

    var explicit_facts = try buildModuleFacts(allocator, parsed, null);
    defer explicit_facts.deinit();
    var explicit_analysis: ModuleAnalysisSession = .{};
    try explicit_analysis.initSoundExtraction(allocator, parsed, .{
        .strict = false,
        .manifest_registry = &registry,
        .module_facts = &explicit_facts,
    });
    try explicit_analysis.complete();
    var explicit_contract = try explicit_analysis.extractContract("explicit.ts");
    try testing.expectEqual(@as(usize, 0), explicit_contract.modules.items.len);
    explicit_contract.deinit(allocator);
    explicit_analysis.deinit();
    try testing.expectEqual(@as(usize, 1), explicit_facts.imports.items.len);
}

test "pipeline.check does not emit a module after verifier allocation failure" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "function handler(req) {}\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .strict = false });
    defer resolved.deinit();
    const handler_func = handler_verifier_mod.findHandlerFunction(view, parsed_state.root) orelse
        return error.HandlerNotFound;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, check(failing.allocator(), &resolved, handler_func, .{}));
}

test "pipeline.check rejects a TypePool poisoned after resolve" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "function handler(req) { return Response.text('ok'); }\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var storage: TypeEnvStorage = .{};
    try storage.initWithSource(allocator, .omitted);
    defer storage.deinit(allocator);

    var resolved = try resolve(allocator, parsed, .{ .type_env = storage.envPtr(), .strict = false });
    defer resolved.deinit();
    const handler_func = handler_verifier_mod.findHandlerFunction(view, parsed_state.root) orelse
        return error.HandlerNotFound;

    const record = storage.pool.addRecord(allocator, &.{.{
        .name_start = 0,
        .name_len = 0,
        .type_idx = storage.pool.idx_string,
        .optional = false,
    }});
    try storage.pool.ensureHealthy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    _ = storage.pool.makeReadonly(failing.allocator(), record);

    try testing.expectError(error.OutOfMemory, check(allocator, &resolved, handler_func, .{}));
}

test "CheckedModule runs verifier and flow independently or together" {
    const allocator = testing.allocator;
    const source = "function handler(req) { return Response.text('ok'); }\n";
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .strict = false });
    defer resolved.deinit();
    const handler_func = handler_verifier_mod.findHandlerFunction(view, parsed_state.root) orelse
        return error.HandlerNotFound;

    var verifier_only = try CheckedModule.init(allocator, &resolved, .{});
    defer verifier_only.deinit();
    try testing.expectEqual(@as(u32, 0), try verifier_only.runVerifier(handler_func));
    try testing.expect(verifier_only.verifierCompleted());
    try testing.expect(!verifier_only.flowCompleted());

    var flow_only = try CheckedModule.init(allocator, &resolved, .{});
    defer flow_only.deinit();
    try testing.expectEqual(@as(u32, 0), try flow_only.runFlow(handler_func));
    try testing.expect(!flow_only.verifierCompleted());
    try testing.expect(flow_only.flowCompleted());

    var both = try check(allocator, &resolved, handler_func, .{});
    defer both.deinit();
    try testing.expect(both.verifierCompleted());
    try testing.expect(both.flowCompleted());
}

test "CheckedModule rejects completed and failed pass retries" {
    const allocator = testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) { return Response.text('ok'); }
    ;
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .strict = false });
    defer resolved.deinit();
    const handler_func = handler_verifier_mod.findHandlerFunction(view, parsed_state.root) orelse
        return error.HandlerNotFound;

    var completed = try CheckedModule.init(allocator, &resolved, .{});
    defer completed.deinit();
    _ = try completed.runVerifier(handler_func);
    _ = try completed.runFlow(handler_func);
    try testing.expectError(error.PassAlreadyRun, completed.runVerifier(handler_func));
    try testing.expectError(error.PassAlreadyRun, completed.runFlow(handler_func));

    var verifier_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failed_verifier = try CheckedModule.init(verifier_failing.allocator(), &resolved, .{});
    defer failed_verifier.deinit();
    try testing.expectError(error.OutOfMemory, failed_verifier.runVerifier(handler_func));
    try testing.expect(verifier_failing.has_induced_failure);
    try testing.expectError(error.PassAlreadyRun, failed_verifier.runVerifier(handler_func));
    try testing.expect(!failed_verifier.verifierCompleted());

    var flow_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failed_flow = try CheckedModule.init(flow_failing.allocator(), &resolved, .{});
    defer failed_flow.deinit();
    try testing.expectError(error.OutOfMemory, failed_flow.runFlow(handler_func));
    try testing.expect(flow_failing.has_induced_failure);
    try testing.expectError(error.PassAlreadyRun, failed_flow.runFlow(handler_func));
    try testing.expect(!failed_flow.flowCompleted());
}

test "missing handler leaves checked passes incomplete" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const value = true;\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .strict = false });
    defer resolved.deinit();

    try testing.expect(handler_verifier_mod.findHandlerFunction(view, parsed_state.root) == null);
    var checked = try CheckedModule.init(allocator, &resolved, .{});
    defer checked.deinit();
    try testing.expect(!checked.verifierCompleted());
    try testing.expect(!checked.flowCompleted());
}

fn completedFlowProperties(checked: *const CheckedModule) !flow_checker_mod.FlowProperties {
    if (!checked.flowCompleted()) return error.FlowNotCompleted;
    return checked.flow_checker.getProperties();
}

test "flow projection requires completion and preserves leaking and safe results" {
    const allocator = testing.allocator;
    const leaking_source =
        \\import { env } from "zttp:env";
        \\function handler(req) { return Response.json({ value: env("SECRET") }); }
    ;
    var leaking_state = try parseSourceForTest(allocator, leaking_source);
    defer leaking_state.js_parser.deinit();
    const leaking_view = IrView.fromIRStore(&leaking_state.js_parser.nodes, &leaking_state.js_parser.constants);
    const leaking_parsed = ParsedModule.fromExisting(leaking_view, leaking_state.root, null);
    var leaking_resolved = try resolve(allocator, leaking_parsed, .{ .strict = false });
    defer leaking_resolved.deinit();
    const leaking_handler = handler_verifier_mod.findHandlerFunction(leaking_view, leaking_state.root) orelse
        return error.HandlerNotFound;
    var leaking = try CheckedModule.init(allocator, &leaking_resolved, .{});
    defer leaking.deinit();

    try testing.expectError(error.FlowNotCompleted, completedFlowProperties(&leaking));
    _ = try leaking.runFlow(leaking_handler);
    try testing.expect(!(try completedFlowProperties(&leaking)).no_secret_leakage);

    const safe_source = "function handler(req) { return Response.json({ value: 'safe' }); }\n";
    var safe_state = try parseSourceForTest(allocator, safe_source);
    defer safe_state.js_parser.deinit();
    const safe_view = IrView.fromIRStore(&safe_state.js_parser.nodes, &safe_state.js_parser.constants);
    const safe_parsed = ParsedModule.fromExisting(safe_view, safe_state.root, null);
    var safe_resolved = try resolve(allocator, safe_parsed, .{ .strict = false });
    defer safe_resolved.deinit();
    const safe_handler = handler_verifier_mod.findHandlerFunction(safe_view, safe_state.root) orelse
        return error.HandlerNotFound;
    var safe = try CheckedModule.init(allocator, &safe_resolved, .{});
    defer safe.deinit();
    _ = try safe.runFlow(safe_handler);
    try testing.expect((try completedFlowProperties(&safe)).no_secret_leakage);
}

test "pipeline.resolve runs BoolChecker on clean source" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const x = true;\nconst y = !x;\n");
    defer parsed_state.js_parser.deinit();

    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{});
    defer resolved.deinit();

    try testing.expectEqual(@as(u32, 0), resolved.bool_error_count);
    try testing.expectEqual(@as(u32, 0), resolved.typeErrorCount());
    try testing.expectEqual(@as(usize, 0), resolved.typeDiagnostics().len);
}

test "pipeline.resolve flags pointless object truthy condition" {
    const allocator = testing.allocator;
    // Mirror bool_checker.zig:2258 — object literal in `if` is always truthy.
    const source: []const u8 = "if ({}) { let x = 1; }";

    var js_parser = try JsParser.init(allocator, source);
    defer js_parser.deinit();
    const root = try js_parser.parse();
    const ir_view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);

    const parsed = ParsedModule.fromExisting(ir_view, root, null);
    var resolved = try resolve(allocator, parsed, .{});
    defer resolved.deinit();

    // One object-literal condition gives one diagnostic, as the bool checker's
    // own `if ({})` test pins.
    try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
    try testing.expectEqual(@as(usize, 1), resolved.boolDiagnostics().len);
    try testing.expectEqual(bool_checker_mod.DiagnosticKind.condition_not_boolean, resolved.boolDiagnostics()[0].kind);
}

test "pipeline.resolve rejects optional module value in boolean context" {
    const allocator = testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\const secret = env("TOKEN");
        \\if (!secret) { const missing = true; }
    ;
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.initWithSource(allocator, .omitted);

    var resolved = try resolve(allocator, parsed, .{
        .type_env = storage.envPtr(),
        .strict = false,
    });
    defer resolved.deinit();

    try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
    try testing.expectEqual(bool_checker_mod.DiagnosticKind.not_operand_not_boolean, resolved.boolDiagnostics()[0].kind);
}

test "pipeline.resolve runs strict checker without type context" {
    const allocator = testing.allocator;
    const source: []const u8 = "function handler(req) { let x = 1; return Response.json({ x: x }); }";

    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();

    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .type_env = null });
    defer resolved.deinit();

    try testing.expect(resolved.strict_checker != null);
    try testing.expect(resolved.strict_error_count > 0);
    var saw_avoidable_let = false;
    for (resolved.strictDiagnostics()) |diag| {
        if (diag.kind == .avoidable_let) saw_avoidable_let = true;
    }
    try testing.expect(saw_avoidable_let);
}

test "extractContract accepts authored TypeScript and honors strict opt out" {
    const source =
        \\function handler(req: Request): Response {
        \\  let message: string = "ok";
        \\  return Response.text(message);
        \\}
    ;

    var contract = try extractContract(testing.allocator, source, "handler.ts", .{
        .strict = false,
    });
    defer contract.deinit(testing.allocator);

    try testing.expectEqualStrings("handler.ts", contract.handler.path);
}

test "extractContract preserves single-file custom callback output" {
    const allocator = testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  const value = env("TOKEN");
        \\  return Response.json({ value: value });
        \\}
    ;
    const Callback = struct {
        var call_count: usize = 0;

        fn check(type_checker: *TypeChecker, root: NodeIndex) anyerror!u32 {
            const error_count = try type_checker.check(root);
            try testing.expectEqual(@as(u32, 0), error_count);
            try testing.expectEqual(@as(usize, 0), type_checker.getDiagnostics().len);
            call_count += 1;
            // Preserve acceptance of a nonzero callback count without diagnostics.
            return 7;
        }
    };

    var default_contract = try extractContract(allocator, source, "handler.ts", .{
        .strict = false,
    });
    defer default_contract.deinit(allocator);

    Callback.call_count = 0;
    var custom_contract = try extractContract(allocator, source, "handler.ts", .{
        .strict = false,
        .type_check = Callback.check,
    });
    defer custom_contract.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), Callback.call_count);
    try expectStringSlices(&.{"TOKEN"}, custom_contract.env.literal.items);
    try expectStringSlices(&.{"zttp:env"}, custom_contract.modules.items);

    const default_json = try serializeContractForTest(allocator, &default_contract);
    defer allocator.free(default_json);
    const custom_json = try serializeContractForTest(allocator, &custom_contract);
    defer allocator.free(custom_json);
    try testing.expectEqualStrings(default_json, custom_json);
}

test "extractContract rejects boolean diagnostics with strict disabled" {
    const source =
        \\if ({}) { const unreachable: boolean = true; }
        \\function handler(req: Request): Response { return Response.text("ok"); }
    ;

    try testing.expectError(
        error.SoundModeViolation,
        extractContract(testing.allocator, source, "handler.ts", .{
            .strict = false,
        }),
    );
}

test "extractContract keeps typed and virtual entry source rules distinct" {
    const allocator = testing.allocator;
    const typed_source =
        \\function handler(req: Request): Response {
        \\  const port: number = "bad";
        \\  return Response.text(String(port));
        \\}
    ;

    try testing.expectError(
        error.SoundModeViolation,
        extractContract(allocator, typed_source, "typed-entry.ts", .{ .strict = false }),
    );

    var untyped_contract = try extractContract(
        allocator,
        "function handler(req) { const port = \"bad\"; return Response.text(String(port)); }",
        "<untyped-entry>",
        .{ .strict = false },
    );
    defer untyped_contract.deinit(allocator);
    try testing.expectEqualStrings("<untyped-entry>", untyped_contract.handler.path);

    try testing.expectError(
        error.UnsupportedSourceExtension,
        extractContract(allocator, "function handler(req) { return Response.text(\"ok\"); }", "mapped-entry.js", .{ .strict = false }),
    );
}

test "extractContract keeps dependency annotations outside entry typing" {
    const source =
        \\import { request } from "./typed-bad.ts";
        \\function handler(req) { return Response.text("ok"); }
    ;

    var contract = try extractContract(testing.allocator, source, "/baseline/type-entry.ts", .{
        .strict = false,
        .read_file = readGraphBaselineFile,
    });
    defer contract.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), contract.egress.endpoints.items.len);
    try testing.expectEqualStrings(
        "https://typed-dependency.example:443",
        contract.egress.endpoints.items[0],
    );
}

test "extractContract preserves graph callback order and merged contract bytes" {
    const allocator = testing.allocator;
    const source =
        \\import { left } from "./left.ts";
        \\import { right } from "./right.ts";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req: Request): Response {
        \\  left();
        \\  right();
        \\  return fetchSync("https://entry.example/a");
        \\}
    ;
    const options = ExtractContractOptions{
        .strict = false,
        .type_check = recordGraphContractTypeCheck,
        .read_file = readGraphBaselineFile,
    };

    var success_probe = GraphCallbackProbe{};
    active_graph_callback_probe = &success_probe;
    defer active_graph_callback_probe = null;
    var custom_contract = try extractContract(allocator, source, "/baseline/entry.ts", options);
    active_graph_callback_probe = null;
    defer custom_contract.deinit(allocator);

    try testing.expectEqual(@as(usize, 4), success_probe.count);
    try testing.expectEqualSlices(
        GraphCallbackModule,
        &.{ .shared, .left, .right, .entry },
        success_probe.modules[0..success_probe.count],
    );
    try expectStringSlices(
        &.{
            "https://shared.example:443",
            "https://left.example:443",
            "https://right.example:443",
            "https://entry.example:443",
        },
        custom_contract.egress.endpoints.items,
    );
    try expectStringSlices(&.{"LEFT_TOKEN"}, custom_contract.env.literal.items);
    try expectStringSlices(&.{"RIGHT_CACHE"}, custom_contract.cache.namespaces.items);

    var default_contract = try extractContract(allocator, source, "/baseline/entry.ts", .{
        .strict = false,
        .read_file = readGraphBaselineFile,
    });
    defer default_contract.deinit(allocator);
    const custom_json = try serializeContractForTest(allocator, &custom_contract);
    defer allocator.free(custom_json);
    const default_json = try serializeContractForTest(allocator, &default_contract);
    defer allocator.free(default_json);
    try testing.expectEqualStrings(default_json, custom_json);

    var refusal_probe = GraphCallbackProbe{ .fail_after = 2 };
    active_graph_callback_probe = &refusal_probe;
    try testing.expectError(
        error.GraphCallbackRefused,
        extractContract(allocator, source, "/baseline/entry.ts", options),
    );
    try testing.expectEqual(@as(usize, 2), refusal_probe.count);
    try testing.expectEqualSlices(
        GraphCallbackModule,
        &.{ .shared, .left },
        refusal_probe.modules[0..refusal_probe.count],
    );
}

test "loaded graph corrects entry effects before merge" {
    const allocator = testing.allocator;
    const entry_source =
        \\import { mutate } from "./dep.ts";
        \\function handler(req) { mutate(); return Response.text("ok"); }
    ;
    var graph = modules_mod.ModuleGraph.init(allocator);
    defer graph.deinit();
    try graph.build("/effects/entry.ts", entry_source, readSiblingEffectFile);

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var strings = string_mod.StringTable.init(allocator);
    defer strings.deinit();
    var compiler = modules_mod.ModuleCompiler.init(allocator, &atoms, &strings);
    var compiled = try compiler.compileAll(&graph);
    defer compiled.deinit();
    defer {
        for (compiled.codegens) |*codegen| codegen.freeOwnedConstantPayloads();
    }

    const profiles = [_]ModuleAnalysisSession.Profile{ .contract_only, .sound_extraction };
    for (profiles) |profile| {
        var merged = try handler_contract_mod.initMergedContract(allocator, "/effects/entry.ts");
        defer merged.deinit(allocator);
        var loaded: std.ArrayList(LoadedModuleEffects) = .empty;
        defer {
            for (loaded.items) |*item| item.deinit(allocator);
            loaded.deinit(allocator);
        }

        for (compiled.modules, compiled.parsers, 0..) |module, *parser, index| {
            const graph_index = graph.execution_order[index];
            const graph_module = &graph.module_list.items[graph_index];
            const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
            const parsed = ParsedModule.fromExisting(view, module.root, &atoms);
            var analysis: ModuleAnalysisSession = .{};
            const extraction_opts = ExtractContractOptions{
                .strict = false,
                .capture_export_effects = true,
            };
            if (profile == .contract_only) {
                try analysis.initContractOnly(allocator, parsed, .{ .extraction = extraction_opts });
            } else {
                try analysis.initSoundExtraction(allocator, parsed, extraction_opts);
            }
            defer analysis.deinit();
            try analysis.complete();

            const imported = try importedEffectsForLoadedModule(
                allocator,
                &graph,
                graph_index,
                try analysis.facts(),
                loaded.items,
            );
            defer allocator.free(imported);
            try analysis.setImportedEffects(imported);

            var contract = try analysis.extractContract(graph_module.path);
            defer contract.deinit(allocator);
            const is_entry = index == compiled.modules.len - 1;
            if (is_entry) {
                const properties = contract.properties orelse return error.PropertiesMissing;
                try testing.expect(!properties.read_only);
                try testing.expect(!properties.stateless);
            }
            try handler_contract_mod.mergeModuleContract(allocator, &merged, &contract, is_entry);

            var effects = analysis.takeExportEffects() orelse return error.ExportEffectsMissing;
            loaded.append(allocator, .{
                .graph_index = graph_index,
                .effects = effects,
            }) catch |err| {
                effects.deinit(allocator);
                return err;
            };
        }
        try testing.expect(merged.properties == null);
    }
}

test "extractContract merges capabilities from relative imports" {
    const allocator = testing.allocator;
    const file_io = @import("zts-engine").file_io;

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const dependency_path = try std.fmt.allocPrint(allocator, "{s}/dependency.ts", .{dir});
    defer allocator.free(dependency_path);
    try file_io.writeFile(
        allocator,
        dependency_path,
        "export function request() { return fetchSync('http://localhost:1'); }",
    );

    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.ts", .{dir});
    defer allocator.free(entry_path);
    const source =
        "import { request } from './dependency.ts'; function handler(req) { return request(req, undefined); }";

    var contract = try extractContract(allocator, source, entry_path, .{
        .strict = false,
        .read_file = file_io.readFileForModuleGraph,
    });
    defer contract.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), contract.egress.endpoints.items.len);
    try testing.expectEqualStrings("http://localhost:1", contract.egress.endpoints.items[0]);

    try file_io.writeFile(
        allocator,
        dependency_path,
        "if ({}) { const unreachable = true; } export function request() { return fetchSync('http://localhost:1'); }",
    );
    try testing.expectError(
        error.SoundModeViolation,
        extractContract(allocator, source, entry_path, .{
            .strict = false,
            .read_file = file_io.readFileForModuleGraph,
        }),
    );

    try file_io.writeFile(
        allocator,
        dependency_path,
        "export function request() { let response = fetchSync('http://localhost:1'); return response; }",
    );
    var non_strict_contract = try extractContract(allocator, source, entry_path, .{
        .strict = false,
        .read_file = file_io.readFileForModuleGraph,
    });
    non_strict_contract.deinit(allocator);
    try testing.expectError(
        error.SoundModeViolation,
        extractContract(allocator, source, entry_path, .{
            .strict = true,
            .read_file = file_io.readFileForModuleGraph,
        }),
    );
}

test "an injected index is used by all four analyzers instead of private ones" {
    // The half of C2's gate that cannot pass vacuously. C1 made injection
    // behavior-neutral by construction - an analyzer with no index builds an
    // identical private one - so identical output proves nothing about whether
    // the work is shared. `owned_facts == null` proves it directly.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) { return Response.json({ok: true}); }
    ;

    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var facts = try buildModuleFacts(allocator, parsed, null);
    defer facts.deinit();
    // The index must be non-trivial, or the assertions below would hold for an
    // empty one and say nothing.
    try std.testing.expect(facts.imports.items.len >= 2);

    var resolved = try resolve(allocator, parsed, .{ .module_facts = &facts });
    defer resolved.deinit();

    try std.testing.expectEqual(&facts, resolved.bool_checker.facts.?);
    try std.testing.expect(resolved.bool_checker.owned_facts == null);
    try std.testing.expect(resolved.strict_checker != null);
    try std.testing.expectEqual(&facts, resolved.strict_checker.?.facts.?);
    try std.testing.expect(resolved.strict_checker.?.owned_facts == null);

    const handler_func = handler_verifier_mod.findHandlerFunction(view, parsed_state.root).?;
    var checked = try check(allocator, &resolved, handler_func, .{ .module_facts = &facts });
    defer checked.deinit();

    try std.testing.expectEqual(&facts, checked.verifier.facts.?);
    try std.testing.expect(checked.verifier.owned_facts == null);
    try std.testing.expectEqual(&facts, checked.flow_checker.facts.?);
    try std.testing.expect(checked.flow_checker.owned_facts == null);
}

test "with no injected index each analyzer still builds its own" {
    // The fallback C1 relies on and C3 still needs, since precompile has sites
    // C3 has not reached. Asserted so a future change cannot quietly make
    // injection mandatory.
    const allocator = std.testing.allocator;
    const source = "import { env } from \"zttp:env\";\n";

    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var resolved = try resolve(allocator, parsed, .{});
    defer resolved.deinit();

    try std.testing.expect(resolved.bool_checker.facts == null);
    try std.testing.expect(resolved.bool_checker.owned_facts != null);
}

/// Parse, resolve, check, and extract a contract, releasing everything it
/// allocated. Used by the failure sweep below: the acceptance criterion for
/// reset item 0a is that every compile path, including every failure stage,
/// leaks nothing, and a sweep can only assert that against one function that
/// owns the whole sequence.
fn runCompilePhasesForTest(allocator: std.mem.Allocator, source: []const u8) !void {
    var js_parser = try JsParser.init(allocator, source);
    defer js_parser.deinit();
    const root = try js_parser.parse();

    const view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, null);

    const handler_func = handler_verifier_mod.findHandlerFunction(view, root) orelse
        return error.HandlerNotFound;

    var session: ModuleAnalysisSession = .{};
    try session.initFull(allocator, parsed, .{
        .strict = false,
        .select_verifier = true,
        .select_flow = true,
    });
    defer session.deinit();
    try session.complete();
    try session.prepareChecked(handler_func, .{ .module_facts = try session.facts() });
    _ = try session.runVerifier(handler_func);
    _ = try session.runFlow(handler_func);

    var contract = try session.extractContract("sweep.ts");
    contract.deinit(allocator);
}

test "every compile stage releases what it allocated at any failure index" {
    const allocator = testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\function handler(req) {
        \\  const make = () => sha256("x");
        \\  if (req.url === "/a") return Response.json({ hash: make() });
        \\  return Response.text("ok");
        \\}
        \\
    ;
    // The successful run first, both as a control and to learn how many
    // allocations the sweep has to cover.
    var counting = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
    try runCompilePhasesForTest(counting.allocator(), source);
    const total = counting.alloc_index;
    try testing.expect(total > 0);

    // Each iteration fails one allocation. A leak on any unwind path is
    // reported by std.testing.allocator when the test ends, which is the
    // assertion; the error value itself is not interesting.
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = i });
        runCompilePhasesForTest(failing.allocator(), source) catch {};
    }
}

// ---------------------------------------------------------------------------
// The refused-expression type (`t_error`) and its containment
// ---------------------------------------------------------------------------

/// What a probe sees: the phases the real pipeline ran over one TypeScript
/// source. The error type is private to the type checker, so every probe goes
/// through the real phases and reads what the other checkers decided.
const Session = struct {
    allocator: std.mem.Allocator,
    resolved: *ResolvedModule,
    parsed: ParsedModule,
    handler: ?NodeIndex,
};

fn withSession(
    allocator: std.mem.Allocator,
    source: []const u8,
    comptime run: fn (Session) anyerror!void,
) !void {
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initInPlace(allocator, allocator, source, "probe.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const view = IrView.fromIRStore(&frontend.parser.nodes, &frontend.parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, accepted.root, accepted.atoms, accepted.type_store);

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.initWithSource(allocator, .{ .direct = .{
        .store = accepted.type_store,
        .ir_view = view,
        .atoms = accepted.atoms,
    } });

    var resolved = try resolve(allocator, parsed, .{ .type_env = storage.envPtr(), .strict = true });
    defer resolved.deinit();
    try run(.{
        .allocator = allocator,
        .resolved = &resolved,
        .parsed = parsed,
        .handler = handler_verifier_mod.findHandlerFunction(view, accepted.root),
    });
}

fn countKind(diagnostics: anytype, kind: anytype) usize {
    var count: usize = 0;
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind == kind) count += 1;
    }
    return count;
}

test "one refused operator gives one type diagnostic" {
    const source =
        \\function handler(req: Request): Response {
        \\  const n: number = 1;
        \\  const m: number = n + "y";
        \\  return Response.text(String(m));
        \\}
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(type_checker_mod.DiagnosticKind.string_add, diagnostics[0].kind);
            try testing.expectEqual(@as(usize, 1), session.resolved.type_checker.?.refusedExpressionCount());
        }
    }.run);
}

test "a refused value used again gives no second diagnostic" {
    // The refused sum flows into a binding, a call argument, and a ternary.
    // Each used to raise a mismatch of its own on top of ZTS105.
    const source =
        \\function twice(x: number): number {
        \\  return x + x;
        \\}
        \\function handler(req: Request): Response {
        \\  const n: number = 1;
        \\  const m = n + "y";
        \\  const k: number = m;
        \\  const t: number = twice(m);
        \\  const u: number = n === 1 ? m : 2;
        \\  return Response.text(String(k + t + u));
        \\}
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(type_checker_mod.DiagnosticKind.string_add, diagnostics[0].kind);
        }
    }.run);
}

test "the error type exists only where a type error was reported" {
    // A refused expression implies a reported error. That is the direction a
    // regression breaks: an error type with no diagnostic would be accepted
    // everywhere, silently. The converse holds too: a source with no refused
    // operator never produces the type.
    const refusing = [_][]const u8{
        "function f(n: number): number {\n  const m: number = n + \"y\";\n  return m;\n}",
        "function f(n: number): string {\n  const s = n + \"y\" + \"z\";\n  return s;\n}",
        "function f(n: number): string {\n  const s = n + \"y\";\n  return s.toUpperCase();\n}",
        "function f(n: number): number {\n  return n === 1 ? n + \"y\" : 2;\n}",
        "const n: number = 1;\nif (n + \"y\") { const k = 1; }",
    };
    const clean = [_][]const u8{
        "function f(n: number): number {\n  const m: number = n + 2;\n  return m;\n}",
        "function f(parts: string[]): string {\n  return parts.join(\"\");\n}",
        "const a: string = \"x\";\nconst b = a === \"x\" ? 1 : 2;",
    };
    inline for (refusing) |source| {
        try withSession(testing.allocator, source, struct {
            fn run(session: Session) anyerror!void {
                try testing.expect(session.resolved.type_checker.?.refusedExpressionCount() > 0);
                try testing.expect(session.resolved.typeErrorCount() > 0);
                // Every source adds a string to the number `n`, so the first
                // reported error is the string-add refusal.
                try testing.expectEqual(type_checker_mod.DiagnosticKind.string_add, session.resolved.typeDiagnostics()[0].kind);
            }
        }.run);
    }
    inline for (clean) |source| {
        try withSession(testing.allocator, source, struct {
            fn run(session: Session) anyerror!void {
                try testing.expectEqual(@as(usize, 0), session.resolved.type_checker.?.refusedExpressionCount());
                try testing.expectEqual(@as(u32, 0), session.resolved.typeErrorCount());
            }
        }.run);
    }
}

test "the public inference getter hides the error type and any type built from it" {
    const source =
        \\const n: number = 1;
        \\const joined = n + "y";
        \\const list = [n + "y", "z"];
        \\const pick = n === 1 ? n + "y" : "z";
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const checker = &session.resolved.type_checker.?;
            const view = session.parsed.ir_view;
            var seen: usize = 0;
            var node: NodeIndex = 0;
            while (node < view.nodeCount()) : (node += 1) {
                const tag = view.getTag(node) orelse continue;
                // Every expression kind the sources above build from a refused sum.
                switch (tag) {
                    .binary_op, .array_literal, .ternary => {},
                    else => continue,
                }
                const inferred = checker.inferTypeWithoutDiagnostics(node);
                // Whatever another checker is handed must not mention the error
                // type, however deep: it is unknown to them or a real type.
                try testing.expect(!checker.env.pool.mentionsError(inferred));
                if (tag == .binary_op) {
                    const bin = view.getBinary(node) orelse continue;
                    if (bin.op == .add) {
                        try testing.expectEqual(type_pool_mod.null_type_idx, inferred);
                        seen += 1;
                    }
                }
            }
            try testing.expect(seen >= 3);
        }
    }.run);
}

test "a refused condition is still refused by the boolean checker" {
    // If the error type leaked, `isAssignableTo(error, boolean)` would answer
    // yes and the condition would pass as boolean.
    try withSession(testing.allocator, "const n: number = 1;\nif (n + \"y\") { const k = 1; }", struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(usize, 1), session.resolved.typeDiagnostics().len);
            try testing.expectEqual(
                @as(usize, 1),
                countKind(session.resolved.boolDiagnostics(), bool_checker_mod.DiagnosticKind.condition_not_boolean),
            );
        }
    }.run);
    try withSession(testing.allocator, "const n: number = 1;\nconst q: boolean = !(n + \"y\");", struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(
                @as(usize, 1),
                countKind(session.resolved.boolDiagnostics(), bool_checker_mod.DiagnosticKind.not_operand_not_boolean),
            );
        }
    }.run);
}

test "a refused operand is unknown to the strict checker, not a type it can reason from" {
    // If the error type leaked, `isAssignableTo(null, error)` would answer yes
    // and the strict checker would claim the operand admits null (ZTS624), a
    // statement about a type it was never given.
    try withSession(testing.allocator, "const n: number = 1;\nconst q = (n + \"y\") ?? 0;", struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(usize, 1), session.resolved.typeDiagnostics().len);
            try testing.expectEqual(
                @as(usize, 0),
                countKind(session.resolved.strictDiagnostics(), strict_checker_mod.DiagnosticKind.nullish_operator_on_null),
            );
        }
    }.run);
}

const refused_flow_source =
    \\import { env } from "zttp:env";
    \\function handler(req: Request): Response {
    \\  const token = env("API_TOKEN");
    \\  const joined = token + "!";
    \\  const shout = joined.toUpperCase();
    \\  return Response.text(shout);
    \\}
;

test "an error-typed receiver does not make the flow checker or the verifier clean" {
    // `joined` holds a refused sum, so its binding type is the error type and
    // `joined.toUpperCase()` has an error-typed receiver. The flow checker asks
    // the type checker what the receiver is; it must get "unknown", and the
    // secret must still reach the response as a finding. The verifier does not
    // read inferred types, and its verdict is unchanged.
    try withSession(testing.allocator, refused_flow_source, struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(usize, 1), session.resolved.typeDiagnostics().len);
            var checked = try check(session.allocator, session.resolved, session.handler.?, .{});
            defer checked.deinit();
            try testing.expectEqual(
                @as(usize, 1),
                countKind(checked.flowDiagnostics(), flow_checker_mod.DiagnosticKind.secret_in_response),
            );
            try testing.expectEqual(
                @as(usize, 1),
                countKind(checked.verifierDiagnostics(), handler_verifier_mod.DiagnosticKind.unchecked_optional_use),
            );
        }
    }.run);
}

test "a refused payload is a dynamic response schema in the contract, not an inferred one" {
    // The contract builder asks the type checker for the payload's type to
    // derive a response schema. A refused payload must come back unknown, which
    // the builder records as a dynamic response, never as a concrete schema.
    const head = "import { routerMatch } from \"zttp:router\";\n" ++
        "function getX(req: Request): Response {\n  const n: number = 1;\n";
    const tail = "\n  return Response.json(joined);\n}\n" ++
        "const routes = { \"GET /x\": getX };\n" ++
        "function handler(req: Request): Response {\n" ++
        "  const found = routerMatch(routes, req);\n" ++
        "  if (found !== undefined) {\n    return found.handler(req);\n  }\n" ++
        "  return Response.json({ error: \"Not Found\" }, { status: 404 });\n}";
    try withSession(testing.allocator, head ++ "  const joined = n + \"y\";" ++ tail, struct {
        fn run(session: Session) anyerror!void {
            try testing.expect(session.resolved.type_checker.?.refusedExpressionCount() > 0);
            var contract = try extractContractFromParsed(session.allocator, session.parsed, "probe.ts", .{
                .source_types = .direct,
                .resolved = session.resolved,
            });
            defer contract.deinit(session.allocator);
            try testing.expectEqual(@as(usize, 1), contract.api.routes.items.len);
            const route = contract.api.routes.items[0];
            try testing.expectEqual(@as(usize, 1), route.responses.items.len);
            try testing.expect(route.responses.items[0].schema == .dynamic);
        }
    }.run);
    // The same route with an unrefused payload does infer a schema, so the
    // dynamic answer above comes from the refusal and not from the route shape.
    try withSession(testing.allocator, head ++ "  const joined = n + 2;" ++ tail, struct {
        fn run(session: Session) anyerror!void {
            var contract = try extractContractFromParsed(session.allocator, session.parsed, "probe.ts", .{
                .source_types = .direct,
                .resolved = session.resolved,
            });
            defer contract.deinit(session.allocator);
            const route = contract.api.routes.items[0];
            try testing.expect(route.responses.items[0].schema == .inline_json);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// One message per node when `check` reports every computed stage
// ---------------------------------------------------------------------------

test "dropRepeatsOfTypeErrors removes a boolean diagnostic on the node a type error names" {
    try withSession(testing.allocator, "const n: number = 1;\nif (n + \"y\") { const k = 1; }", struct {
        fn run(session: Session) anyerror!void {
            const resolved = session.resolved;
            // Both stages report the same expression before the drop.
            try testing.expectEqual(@as(usize, 1), resolved.typeDiagnostics().len);
            try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
            resolved.dropRepeatsOfTypeErrors();
            try testing.expectEqual(@as(usize, 1), resolved.typeDiagnostics().len);
            try testing.expectEqual(@as(usize, 0), resolved.boolDiagnostics().len);
            try testing.expectEqual(@as(u32, 0), resolved.bool_error_count);
        }
    }.run);
}

test "dropRepeatsOfTypeErrors keeps a boolean diagnostic on a different node" {
    const source =
        \\const n: number = 1;
        \\const m: number = n + "y";
        \\if (5) { const k = 1; }
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const resolved = session.resolved;
            resolved.dropRepeatsOfTypeErrors();
            try testing.expectEqual(@as(usize, 1), resolved.typeDiagnostics().len);
            try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
        }
    }.run);
}

test "dropRepeatsOfTypeErrors removes a strict diagnostic below a type error and keeps one beside it" {
    // The first call has too many arguments (a type error on the call node), and
    // its second argument is a partly annotated arrow (ZTS601 below that node).
    // The second statement holds the same arrow outside any type error.
    const source =
        \\function one(a: number): number {
        \\  return a;
        \\}
        \\function handler(req: Request): Response {
        \\  const x: number = one(1, (a: number, b) => a);
        \\  const y = (a: number, b) => a;
        \\  return Response.text(String(x));
        \\}
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const resolved = session.resolved;
            try testing.expect(resolved.typeErrorCount() > 0);
            const before = countKind(resolved.strictDiagnostics(), strict_checker_mod.DiagnosticKind.missing_public_annotation);
            resolved.dropRepeatsOfTypeErrors();
            const after = countKind(resolved.strictDiagnostics(), strict_checker_mod.DiagnosticKind.missing_public_annotation);
            // One diagnostic below the call node and one in the second statement.
            try testing.expectEqual(@as(usize, 2), before);
            try testing.expectEqual(@as(usize, 1), after);
        }
    }.run);
}

test "dropRepeatsOfTypeErrors does nothing without a type error" {
    try withSession(testing.allocator, "const n: number = 1;\nif (5) { const k = 1; }", struct {
        fn run(session: Session) anyerror!void {
            const resolved = session.resolved;
            resolved.dropRepeatsOfTypeErrors();
            try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// Boolean-context operands typed under the guards of `&&` and `||`
// ---------------------------------------------------------------------------

/// The boolean checker's error count over one source that passes the type
/// checker, read through the real phases.
fn expectBoolErrors(source: []const u8, comptime expected: u32) !void {
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(expected, session.resolved.bool_error_count);
        }
    }.run);
}

const guard_union_decl = "structural Ev = { kind: \"a\", flag: boolean } | { kind: \"b\", n: number };\n";

test "the right operand of && is typed under the left operand's guard" {
    // An optional boolean read after an undefined test.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v !== undefined && v;",
        0,
    );
    // A discriminant test selects the member that has the field.
    try expectBoolErrors(
        guard_union_decl ++ "const f = (e: Ev): boolean => e.kind === \"a\" && e.flag;",
        0,
    );
    // A chain of tests: each guard reaches every operand to its right.
    try expectBoolErrors(
        "const f = (a: boolean | undefined, b: boolean | undefined): boolean =>" ++
            " a !== undefined && b !== undefined && a && b;",
        0,
    );
    // A condition that is itself a conjunction, in `if` and in a ternary.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): number => { if (v !== undefined && v) { return 1; } return 0; };",
        0,
    );
    try expectBoolErrors(
        "const f = (v: boolean | undefined): number => v !== undefined && v ? 1 : 0;",
        0,
    );
}

test "the right operand of || is typed under the negated left guard" {
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v === undefined || !v;",
        0,
    );
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v === undefined || v;",
        0,
    );
    // The disjunction of two tests is false only when both failed.
    try expectBoolErrors(
        "const f = (a: boolean | undefined, b: boolean | undefined): boolean =>" ++
            " a === undefined || b === undefined || a || b;",
        0,
    );
}

test "a guard does not reach an operand the left side does not decide" {
    // `||` runs its right side when the left one was false, so a test that
    // narrows the true branch narrows nothing there.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v !== undefined || v;",
        1,
    );
    // `&&` runs its right side when the left one was true.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v === undefined && v;",
        1,
    );
    // The false side of a conjunction decides neither of its operands.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => (v !== undefined && v) || v;",
        1,
    );
    // An operand with no guard keeps its declared type.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v && true;",
        1,
    );
}

test "a guard of && ends with the expression it guards" {
    try expectBoolErrors(
        "const f = (v: boolean | undefined): number => {\n" ++
            "  const both = v !== undefined && v;\n" ++
            "  return v ? 1 : 0;\n" ++
            "};",
        1,
    );
}

test "the walk records a boolean-context operand's type inside a function declaration" {
    // The boolean checker does not walk a `function` declaration body, so a
    // corpus case cannot see these types yet. The type checker does walk it,
    // and the recorded types are what the boolean checker will read.
    const source =
        \\function f(v: boolean | undefined): boolean {
        \\  return v !== undefined && v;
        \\}
        \\function g(v: boolean | undefined): boolean {
        \\  return v === undefined || !v;
        \\}
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const checker = &session.resolved.type_checker.?;
            const view = session.parsed.ir_view;
            var operands: usize = 0;
            var idx: NodeIndex = 0;
            while (idx < view.nodeCount()) : (idx += 1) {
                if (view.getTag(idx) != .binary_op) continue;
                const bin = view.getBinary(idx) orelse continue;
                if (bin.op != .and_op and bin.op != .or_op) continue;
                for ([_]NodeIndex{ bin.left, bin.right }) |operand| {
                    const recorded = checker.contextTypeOf(operand) orelse return error.OperandNotRecorded;
                    try testing.expect(checker.env.isAssignableTo(recorded, checker.env.pool.idx_boolean));
                    operands += 1;
                }
            }
            try testing.expectEqual(@as(usize, 4), operands);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// Boolean-context false positives: intrinsic guards, nested members, typeof
// over unknown, and for-of element variables
// ---------------------------------------------------------------------------

/// Fail unless the type checker recorded a boolean type for each of the
/// `expected` boolean-context operands of `source`: the conditions of `if` and
/// ternary, and the operands of `!`, `&&` and `||`. The boolean checker walks
/// only arrows and module code today, so a `function` declaration is read here
/// through the types the type checker recorded, which are the ones the boolean
/// checker will read once it walks those bodies.
fn expectEveryContextBoolean(source: []const u8, comptime expected: usize) !void {
    const Probe = struct {
        fn operand(checker: *type_checker_mod.TypeChecker, node: NodeIndex) !void {
            const recorded = checker.contextTypeOf(node) orelse return error.OperandNotRecorded;
            try testing.expect(checker.env.isAssignableTo(recorded, checker.env.pool.idx_boolean));
        }
        fn run(session: Session) anyerror!void {
            const checker = &session.resolved.type_checker.?;
            const view = session.parsed.ir_view;
            var seen: usize = 0;
            var idx: NodeIndex = 0;
            while (idx < view.nodeCount()) : (idx += 1) {
                switch (view.getTag(idx) orelse continue) {
                    .if_stmt => {
                        try operand(checker, (view.getIfStmt(idx) orelse continue).condition);
                        seen += 1;
                    },
                    .ternary => {
                        try operand(checker, (view.getTernary(idx) orelse continue).condition);
                        seen += 1;
                    },
                    .unary_op => {
                        const un = view.getUnary(idx) orelse continue;
                        if (un.op != .not) continue;
                        try operand(checker, un.operand);
                        seen += 1;
                    },
                    .binary_op => {
                        const bin = view.getBinary(idx) orelse continue;
                        if (bin.op != .and_op and bin.op != .or_op) continue;
                        try operand(checker, bin.left);
                        try operand(checker, bin.right);
                        seen += 2;
                    },
                    else => {},
                }
            }
            try testing.expectEqual(expected, seen);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "isDict and isBytes are booleans in every boolean context" {
    try expectBoolErrors(
        "const f = (d: unknown): number => { if (isDict(d)) { return 1; } return 0; };",
        0,
    );
    try expectBoolErrors(
        "const f = (d: unknown): boolean => !isDict(d) || (isBytes(d) && true);",
        0,
    );
    try expectBoolErrors(
        "const f = (d: unknown): number => isBytes(d) ? 1 : 0;",
        0,
    );
    // Control: an unknown value itself is still not a boolean.
    try expectBoolErrors(
        "const f = (d: unknown): number => { if (d) { return 1; } return 0; };",
        1,
    );
    try expectEveryContextBoolean(
        \\function classify(doc: unknown): number {
        \\  if (isDict(doc)) { return 1; }
        \\  return !isBytes(doc) ? 2 : 3;
        \\}
    , 3);
}

test "a member read through a record parameter's named field is typed" {
    const todo = "structural Todo = { text: string, done: boolean };\n";
    try expectBoolErrors(
        todo ++ "const f = (p: { todo: Todo }): number => p.todo.done ? 1 : 0;",
        0,
    );
    try expectBoolErrors(
        todo ++ "const f = (p: { todo: Todo }): boolean => !p.todo.done && p.todo.done;",
        0,
    );
    // Control: the field read resolves to its declared type, which is a string.
    try expectBoolErrors(
        todo ++ "const f = (p: { todo: Todo }): number => p.todo.text ? 1 : 0;",
        1,
    );
    try expectEveryContextBoolean(todo ++
        \\function progress(props: { todo: Todo }): number {
        \\  return props.todo.done ? 1 : 0;
        \\}
    , 1);
}

test "typeof over an unknown value refines it to the named primitive" {
    try expectBoolErrors(
        "const f = (v: unknown): number => { if (typeof v === \"boolean\") { if (v) { return 1; } } return 0; };",
        0,
    );
    // The negated form refines the other branch.
    try expectBoolErrors(
        "const f = (v: unknown): number => { if (typeof v !== \"boolean\") { return 0; } return v ? 1 : 0; };",
        0,
    );
    // Control: a refinement to a string is not a boolean.
    try expectBoolErrors(
        "const f = (v: unknown): number => { if (typeof v === \"string\") { if (v) { return 1; } } return 0; };",
        1,
    );
    // Control: the refinement ends with the branch.
    try expectBoolErrors(
        "const f = (v: unknown): number => { if (typeof v === \"boolean\") { return 1; } return v ? 1 : 0; };",
        1,
    );
    try expectEveryContextBoolean(
        \\function flagOf(v: unknown): number {
        \\  if (typeof v === "boolean") {
        \\    if (v) { return 1; }
        \\  }
        \\  return 0;
        \\}
    , 2);
}

test "the element variable of for-of over an array takes the element type" {
    try expectBoolErrors(
        "const f = (flags: boolean[]): number => { for (const flag of flags) { if (flag) { return 1; } } return 0; };",
        0,
    );
    // Control: a string element is not a boolean.
    try expectBoolErrors(
        "const f = (names: string[]): number => { for (const name of names) { if (name) { return 1; } } return 0; };",
        1,
    );
    try expectEveryContextBoolean(
        \\function firstSet(flags: boolean[]): number {
        \\  for (const flag of flags) {
        \\    if (flag) { return 1; }
        \\  }
        \\  return 0;
        \\}
    , 1);
}

// ---------------------------------------------------------------------------
// Declared parameter types in the boolean checker's diagnostics
// ---------------------------------------------------------------------------

/// Whether the boolean checker reported a diagnostic of `kind` over one source.
fn expectBoolKind(source: []const u8, comptime kind: bool_checker_mod.DiagnosticKind, comptime expected: bool) !void {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            var seen = false;
            for (session.resolved.boolDiagnostics()) |diagnostic| {
                if (diagnostic.kind == kind) seen = true;
            }
            try testing.expectEqual(expected, seen);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "arithmetic on a parameter declared string is refused" {
    try expectBoolKind(
        "const f = (s: string): number => s - 1;",
        .arithmetic_on_non_numeric,
        true,
    );
    try expectBoolKind(
        "const f = (b: boolean): number => b * 2;",
        .arithmetic_on_non_numeric,
        true,
    );
    try expectBoolKind(
        "const f = (xs: number[]): number => 2 / xs;",
        .arithmetic_on_non_numeric,
        true,
    );
    // An optional string is not a number either.
    try expectBoolKind(
        "const f = (s: string | undefined): number => s - 1;",
        .arithmetic_on_non_numeric,
        true,
    );
    // A union of string literals is a string.
    try expectBoolKind(
        "const f = (m: \"GET\" | \"POST\"): number => m - 1;",
        .arithmetic_on_non_numeric,
        true,
    );
}

test "arithmetic on a parameter declared number is accepted" {
    try expectBoolKind(
        "const f = (n: number, m: number): number => n - m * 2;",
        .arithmetic_on_non_numeric,
        false,
    );
    // The lattice has no optional number, so this stays undecided.
    try expectBoolKind(
        "const f = (n: number | undefined): number => n - 1;",
        .arithmetic_on_non_numeric,
        false,
    );
    // Unknown and generic parameters stay undecided.
    try expectBoolKind(
        "const f = (v: unknown): number => v - 1;",
        .arithmetic_on_non_numeric,
        false,
    );
}

test "plus on a parameter declared boolean or object is refused" {
    try expectBoolKind(
        "const f = (b: boolean): number => b + 1;",
        .add_on_non_addable,
        true,
    );
    try expectBoolKind(
        "const f = (xs: number[]): number => 1 + xs;",
        .add_on_non_addable,
        true,
    );
    try expectBoolKind(
        "const f = (a: number, b: number): number => a + b;",
        .add_on_non_addable,
        false,
    );
}

test "a fallback on a parameter that cannot be undefined is reported" {
    try expectBoolKind(
        "const f = (s: string): string => s ?? \"x\";",
        .nullish_on_non_nullable,
        true,
    );
    try expectBoolKind(
        "const f = (s: string | undefined): string => s ?? \"x\";",
        .nullish_on_non_nullable,
        false,
    );
    try expectBoolKind(
        "const f = (n: number | undefined): number => n ?? 1;",
        .nullish_on_non_nullable,
        false,
    );
}

test "a comparison with undefined or typeof on a parameter with a known type is reported" {
    try expectBoolKind(
        "const f = (s: string): boolean => s === undefined;",
        .tautological_comparison,
        true,
    );
    try expectBoolKind(
        "const f = (s: string): boolean => typeof s === \"string\";",
        .tautological_comparison,
        true,
    );
    try expectBoolKind(
        "const f = (s: string | undefined): boolean => s === undefined;",
        .tautological_comparison,
        false,
    );
    try expectBoolKind(
        "const f = (v: unknown): boolean => typeof v === \"string\";",
        .tautological_comparison,
        false,
    );
}

test "a typed parameter does not change the bytecode annotations" {
    // The declared type feeds the diagnostics only. Specializing an operator
    // on a declared parameter type would move precompiled bytecode.
    try withSession(testing.allocator, "const f = (a: number, b: number): number => a + b;", struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(u32, 0), session.resolved.bool_checker.node_types.count());
        }
    }.run);
}

const ExistingCheckerEntry = enum { type_session, resolved };

fn extractExistingCheckerForTest(
    allocator: std.mem.Allocator,
    entry: ExistingCheckerEntry,
    parsed: ParsedModule,
    options: ExtractContractOptions,
    checker: *TypeChecker,
    resolved: *ResolvedModule,
) !HandlerContract {
    return switch (entry) {
        .type_session => extractContractFromTypeSession(
            allocator,
            parsed,
            "existing-checker.ts",
            options,
            checker,
        ),
        .resolved => blk: {
            var selected = options;
            selected.resolved = resolved;
            break :blk extractContractFromParsed(
                allocator,
                parsed,
                "existing-checker.ts",
                selected,
            );
        },
    };
}

fn expectExistingCheckerFacts(contract: *const HandlerContract, authored: bool) !void {
    try testing.expectEqual(@as(usize, 1), contract.holes.items.len);
    try testing.expectEqualStrings(
        if (authored) "string" else "unknown",
        contract.holes.items[0].expected_type,
    );
    var saw_proof = false;
    for (contract.function_capsules.items) |capsule| {
        if (!std.mem.eql(u8, capsule.function, "proved")) continue;
        try testing.expectEqual(if (authored) @as(usize, 1) else 0, capsule.declared.items.len);
        if (authored) try testing.expectEqualStrings("deterministic", capsule.declared.items[0]);
        saw_proof = true;
    }
    try testing.expect(saw_proof);
    var saw_effect = false;
    for (contract.function_effect_capsules.items) |capsule| {
        if (!std.mem.eql(u8, capsule.function, "effectful")) continue;
        try testing.expectEqual(if (authored) @as(usize, 1) else 0, capsule.declared.items.len);
        if (authored) {
            try testing.expectEqualStrings("crypto", capsule.declared.items[0]);
            try testing.expectEqual(@as(usize, 1), capsule.inferred.items.len);
            try testing.expectEqualStrings("crypto", capsule.inferred.items[0]);
        }
        saw_effect = true;
    }
    try testing.expect(saw_effect);
}

test "existing checker APIs preserve source selection and direct ownership" {
    const allocator = testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\function proved(value: string): Proof<string, "deterministic"> { return value; }
        \\function effectful(value: string): Effects<string, "crypto"> { return sha256(value); }
        \\function incomplete(): string { return hole(); }
        \\function handler(req: Request): Response {
        \\  return Response.text(effectful(proved(incomplete())));
        \\}
        \\
    ;
    var direct_atoms = AtomTable.init(allocator);
    defer direct_atoms.deinit();
    var direct_parser = try JsParser.initTyped(allocator, allocator, source);
    defer direct_parser.deinit();
    direct_parser.setAtomTable(&direct_atoms);
    const direct_root = try direct_parser.parse();
    const direct_view = IrView.fromIRStore(&direct_parser.nodes, &direct_parser.constants);
    const direct_parsed = ParsedModule.fromTypedExisting(
        direct_view,
        direct_root,
        &direct_atoms,
        &direct_parser.type_store,
    );
    const direct_unbound = ParsedModule.fromExisting(direct_view, direct_root, &direct_atoms);
    var direct_storage: TypeEnvStorage = .{};
    defer direct_storage.deinit(allocator);
    try direct_storage.initWithSource(allocator, .{ .direct = .{
        .store = &direct_parser.type_store,
        .ir_view = direct_view,
        .atoms = &direct_atoms,
    } });
    var direct_checker = TypeChecker.init(allocator, direct_view, &direct_atoms, direct_storage.envPtr().?);
    defer direct_checker.deinit();
    _ = try direct_checker.check(direct_root);
    var direct_resolved = try resolve(allocator, direct_parsed, .{
        .type_env = direct_storage.envPtr(),
        .strict = false,
    });
    defer direct_resolved.deinit();

    var baseline_json: ?[]u8 = null;
    defer if (baseline_json) |bytes| allocator.free(bytes);
    inline for (.{ ExistingCheckerEntry.type_session, .resolved }) |entry| {
        var omitted = try extractExistingCheckerForTest(
            allocator,
            entry,
            direct_parsed,
            .{ .source_types = .omitted },
            &direct_checker,
            &direct_resolved,
        );
        defer omitted.deinit(allocator);
        try expectExistingCheckerFacts(&omitted, false);

        var direct = try extractExistingCheckerForTest(
            allocator,
            entry,
            direct_parsed,
            .{ .source_types = .direct },
            &direct_checker,
            &direct_resolved,
        );
        defer direct.deinit(allocator);
        try expectExistingCheckerFacts(&direct, true);
        const direct_json = try serializeContractForTest(allocator, &direct);
        defer allocator.free(direct_json);
        if (baseline_json) |expected| {
            try testing.expectEqualStrings(expected, direct_json);
        } else {
            baseline_json = try allocator.dupe(u8, direct_json);
        }

        try testing.expectError(
            error.DirectTypeSyntaxUnavailable,
            extractExistingCheckerForTest(
                allocator,
                entry,
                direct_unbound,
                .{ .source_types = .direct },
                &direct_checker,
                &direct_resolved,
            ),
        );
    }
}

threadlocal var source_selection_graph_reads: usize = 0;

const sourceSelectionGraphEntry =
    \\import { helper } from "./dep.ts";
    \\function handler(req: Request): Proof<Response, "pure"> { return Response.text(helper()); }
;

fn readSourceSelectionGraphFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) modules_mod.module_graph.ReadFileError![]const u8 {
    source_selection_graph_reads += 1;
    if (!std.mem.endsWith(u8, path, "dep.ts")) return error.FileNotFound;
    return allocator.dupe(u8,
        \\export function helper(): Proof<string, "deterministic"> { return "ok"; }
    );
}

test "contract-only graph sessions omit every supplied source selection" {
    const allocator = testing.allocator;
    const entry_path = "/source-selection/entry.ts";
    var graph = modules_mod.ModuleGraph.init(allocator);
    defer graph.deinit();
    try graph.build(entry_path, sourceSelectionGraphEntry, readSourceSelectionGraphFile);
    try testing.expectEqual(@as(usize, 2), graph.module_list.items.len);
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var strings = string_mod.StringTable.init(allocator);
    defer strings.deinit();
    var compiler = modules_mod.ModuleCompiler.init(allocator, &atoms, &strings);
    var compiled = try compiler.compileAll(&graph);
    defer compiled.deinit();
    defer for (compiled.codegens) |*codegen| codegen.freeOwnedConstantPayloads();
    try testing.expectEqual(@as(usize, 2), compiled.modules.len);

    const modes = [_]ModuleSourceTypeInput{ .omitted, .direct };
    try testing.expectEqual(@as(usize, 2), modes.len);
    var baseline: [2]?[]u8 = @splat(null);
    defer for (baseline) |bytes| if (bytes) |owned| allocator.free(owned);
    var merged_baseline: ?[]u8 = null;
    defer if (merged_baseline) |owned| allocator.free(owned);
    var observations: usize = 0;
    for (modes) |mode| {
        var merged = try handler_contract_mod.initMergedContract(allocator, entry_path);
        defer merged.deinit(allocator);
        for (compiled.modules, compiled.parsers, 0..) |module, *parser, index| {
            const graph_module = &graph.module_list.items[graph.execution_order[index]];
            const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
            const parsed = ParsedModule.fromTypedExisting(view, module.root, &atoms, &parser.type_store);
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initContractOnly(allocator, parsed, .{ .extraction = .{
                .source_types = mode,
                .strict = false,
            } });
            defer analysis.deinit();
            try analysis.complete();
            try testing.expectEqual(type_env_mod.SourceTypeMode.omitted, analysis.type_env_storage.envPtr().?.sourceTypeMode().?);
            var contract = try analysis.extractContract(graph_module.path);
            defer contract.deinit(allocator);
            const is_entry = index == compiled.modules.len - 1;
            const capsule_count: usize = if (is_entry) 0 else 1;
            try testing.expectEqual(capsule_count, contract.function_capsules.items.len);
            try testing.expectEqual(capsule_count, contract.function_effect_capsules.items.len);
            for (contract.function_capsules.items) |capsule| {
                try testing.expectEqualStrings("helper", capsule.function);
                try testing.expectEqual(@as(usize, 0), capsule.declared.items.len);
            }
            for (contract.function_effect_capsules.items) |capsule| {
                try testing.expectEqualStrings("helper", capsule.function);
                try testing.expectEqual(@as(usize, 0), capsule.declared.items.len);
            }
            try testing.expect(contract.declared_specs_implicit);
            const defaults = @import("spec_discharge.zig").v1_spec_names;
            try testing.expect(defaults.len > 1);
            try testing.expectEqual(defaults.len, contract.declared_specs.items.len);
            for (defaults) |expected| {
                var matches: usize = 0;
                for (contract.declared_specs.items) |actual| {
                    if (std.mem.eql(u8, expected, actual)) matches += 1;
                }
                try testing.expectEqual(@as(usize, 1), matches);
            }
            const json = try serializeContractForTest(allocator, &contract);
            defer allocator.free(json);
            if (baseline[index]) |expected| {
                try testing.expectEqualStrings(expected, json);
            } else {
                baseline[index] = try allocator.dupe(u8, json);
            }
            try handler_contract_mod.mergeModuleContract(allocator, &merged, &contract, index == compiled.modules.len - 1);
            observations += 1;
        }
        try testing.expect(merged.properties == null);
        const merged_json = try serializeContractForTest(allocator, &merged);
        defer allocator.free(merged_json);
        if (merged_baseline) |expected| {
            try testing.expectEqualStrings(expected, merged_json);
        } else {
            merged_baseline = try allocator.dupe(u8, merged_json);
        }
    }
    try testing.expectEqual(@as(usize, 4), observations);
}

test "source graph uses compiled direct entry types and omits dependency types" {
    const allocator = testing.allocator;
    const Probe = struct {
        var entries: usize = 0;
        var dependencies: usize = 0;

        fn check(checker: *TypeChecker, root: NodeIndex) anyerror!u32 {
            if (checker.env.getSourceFnSigByName("handler")) |signature| {
                try testing.expectEqual(type_env_mod.SourceTypeMode.direct, checker.env.sourceTypeMode().?);
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                defer names.deinit(checker.env.allocator);
                _ = try checker.env.extractProofMembers(signature.return_type, &names);
                try testing.expectEqual(@as(usize, 1), names.items.len);
                try testing.expectEqualStrings("pure", names.items[0]);
                entries += 1;
            } else {
                try testing.expectEqual(type_env_mod.SourceTypeMode.omitted, checker.env.sourceTypeMode().?);
                try testing.expect(checker.env.getSourceFnSigByName("helper") == null);
                dependencies += 1;
            }
            return checker.check(root);
        }
    };
    const selections = [_]?ModuleSourceTypeInput{ .direct, null };
    for (selections) |selection| {
        Probe.entries = 0;
        Probe.dependencies = 0;
        source_selection_graph_reads = 0;
        var direct = try extractContract(allocator, sourceSelectionGraphEntry, "/source-selection/entry.ts", .{
            .source_types = selection,
            .read_file = readSourceSelectionGraphFile,
            .type_check = Probe.check,
            .strict = false,
        });
        defer direct.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), source_selection_graph_reads);
        try testing.expectEqual(@as(usize, 1), Probe.entries);
        try testing.expectEqual(@as(usize, 1), Probe.dependencies);
        try testing.expect(direct.properties == null);
    }
}

fn expectOmittedHelperReceipt(
    contract: *const HandlerContract,
    function_name: []const u8,
    expected_type: []const u8,
    expected_json_len: usize,
    expected_json_sha256: []const u8,
) !void {
    try testing.expectEqual(@as(usize, 1), contract.function_capsules.items.len);
    const proof = contract.function_capsules.items[0];
    try testing.expectEqualStrings(function_name, proof.function);
    try testing.expectEqual(@as(u32, 1), proof.line);
    try testing.expectEqual(@as(usize, 0), proof.declared.items.len);
    try testing.expect(proof.proven_total);
    try testing.expect(proof.proven_pure);
    try testing.expect(proof.proven_read_only);
    try testing.expect(proof.proven_deterministic);
    try testing.expect(!proof.discharged);
    try testing.expect(!proof.exported);
    try testing.expect(proof.handler_reachable);

    try testing.expectEqual(@as(usize, 1), contract.function_effect_capsules.items.len);
    const effect = contract.function_effect_capsules.items[0];
    try testing.expectEqualStrings(function_name, effect.function);
    try testing.expectEqual(@as(u32, 1), effect.line);
    try testing.expectEqual(@as(usize, 0), effect.declared.items.len);
    try testing.expectEqual(@as(usize, 0), effect.inferred.items.len);
    try testing.expect(!effect.discharged);
    try testing.expect(!effect.exported);
    try testing.expect(effect.handler_reachable);

    try testing.expectEqual(@as(usize, 1), contract.holes.items.len);
    const hole = contract.holes.items[0];
    try testing.expectEqualStrings(function_name, hole.function);
    try testing.expectEqual(@as(u32, 1), hole.line);
    try testing.expectEqual(@as(u32, 36), hole.column);
    try testing.expectEqualStrings(expected_type, hole.expected_type);
    try testing.expectEqual(@as(usize, 0), hole.remaining_budget.items.len);
    try testing.expect(!hole.budget_declared);
    try testing.expectEqual(@as(usize, 0), hole.undischarged.items.len);
    try testing.expectEqual(@as(usize, 0), hole.in_scope.items.len);
    try testing.expectEqual(@as(usize, 1), contract.spec_diagnostics.items.len);

    const json = try serializeContractForTest(testing.allocator, contract);
    defer testing.allocator.free(json);
    try testing.expectEqual(expected_json_len, json.len);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(json);
    const actual_hash = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    try testing.expectEqualStrings(expected_json_sha256, &actual_hash);
}

fn extractOmittedContractForTest(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
) !HandlerContract {
    var source_owner: source_frontend_mod.DirectCheckSource = undefined;
    try source_owner.initInPlace(allocator, allocator, source, filename);
    defer source_owner.deinit();
    const accepted = source_owner.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(
        allocator,
        ParsedModule.fromTypedExisting(accepted.ir_view, accepted.root, accepted.atoms, accepted.type_store),
        .{},
    );
    defer analysis.deinit();
    try analysis.complete();
    try testing.expectEqual(
        type_env_mod.SourceTypeMode.omitted,
        analysis.type_env_storage.envPtr().?.sourceTypeMode().?,
    );
    return analysis.extractContract(filename);
}

test "explicit omitted selection preserves native ABI holes and hides authored signatures" {
    const allocator = testing.allocator;
    const abi_source =
        \\function isDict(): number { return hole(); }
        \\function handler(req: Request): Response { return Response.text(String(isDict(undefined))); }
    ;
    var abi_contract = try extractOmittedContractForTest(
        allocator,
        abi_source,
        "omitted-abi-is-dict.ts",
    );
    defer abi_contract.deinit(allocator);
    try expectOmittedHelperReceipt(
        &abi_contract,
        "isDict",
        "boolean",
        3327,
        "037a0a073d25ac480f1dbe3dd763b172f28a11d4e3e8d7ca5ba7b4100cb98326",
    );

    const helper_source =
        \\function helper(): number { return hole(); }
        \\function handler(req: Request): Response { return Response.text(String(helper())); }
    ;
    var helper_contract = try extractOmittedContractForTest(
        allocator,
        helper_source,
        "omitted-ordinary-helper.ts",
    );
    defer helper_contract.deinit(allocator);
    try expectOmittedHelperReceipt(
        &helper_contract,
        "helper",
        "unknown",
        3331,
        "ef4f812d850d1b201999fcdcfbfd4766c024d008cb40cfdd8c0b5665b3e66c48",
    );

    var source_owner: source_frontend_mod.DirectCheckSource = undefined;
    try source_owner.initInPlace(allocator, allocator, abi_source, "authored-is-dict.ts");
    defer source_owner.deinit();
    const accepted = source_owner.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const parsed = ParsedModule.fromTypedExisting(accepted.ir_view, accepted.root, accepted.atoms, accepted.type_store);
    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.initWithSource(allocator, .{ .direct = .{
        .store = accepted.type_store,
        .ir_view = accepted.ir_view,
        .atoms = accepted.atoms,
    } });
    var checker = TypeChecker.init(allocator, accepted.ir_view, accepted.atoms, storage.envPtr().?);
    defer checker.deinit();
    _ = try checker.check(accepted.root);
    var resolved = try resolve(allocator, parsed, .{
        .type_env = storage.envPtr(),
        .strict = false,
    });
    defer resolved.deinit();
    var explicit_omitted = try extractExistingCheckerForTest(
        allocator,
        .resolved,
        parsed,
        .{ .source_types = .omitted },
        &checker,
        &resolved,
    );
    defer explicit_omitted.deinit(allocator);
    try testing.expectEqual(type_env_mod.SourceTypeMode.direct, storage.envPtr().?.sourceTypeMode().?);
    try testing.expectEqual(@as(usize, 1), explicit_omitted.holes.items.len);
    try testing.expectEqualStrings("unknown", explicit_omitted.holes.items[0].expected_type);
}

test "an empty parser-owned Store selects direct and remains distinct from omitted" {
    const allocator = testing.allocator;
    const source = "function handler(req) { return Response.text(\"ok\"); }\n";
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(allocator, allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try testing.expect(std.meta.eql(
        parser.type_store.checkpoint(),
        std.mem.zeroes(TypeSyntax.Store.Checkpoint),
    ));
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const typed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);

    var direct: ModuleAnalysisSession = .{};
    try direct.initSoundExtraction(allocator, typed, .{
        .source_types = .direct,
        .strict = false,
    });
    defer direct.deinit();
    try direct.complete();
    try testing.expectEqual(
        type_env_mod.SourceTypeMode.direct,
        direct.type_env_storage.envPtr().?.sourceTypeMode().?,
    );

    var omitted: ModuleAnalysisSession = .{};
    try omitted.initSoundExtraction(allocator, typed, .{
        .source_types = .omitted,
        .strict = false,
    });
    defer omitted.deinit();
    try omitted.complete();
    try testing.expectEqual(
        type_env_mod.SourceTypeMode.omitted,
        omitted.type_env_storage.envPtr().?.sourceTypeMode().?,
    );

    var missing: ModuleAnalysisSession = .{};
    try missing.initSoundExtraction(
        allocator,
        ParsedModule.fromExisting(view, root, &atoms),
        .{ .source_types = .direct, .strict = false },
    );
    defer missing.deinit();
    try testing.expectError(error.DirectTypeSyntaxUnavailable, missing.complete());
    try testing.expectError(error.AnalysisAlreadyAttempted, missing.complete());
}

test "consumer entry points reject operational source failures before semantic absence" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const value = 1;\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);

    var poisoned_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var poisoned_pool = TypePool.init(poisoned_allocator.allocator());
    defer poisoned_pool.deinit(poisoned_allocator.allocator());
    try testing.expect(poisoned_allocator.has_induced_failure);
    var poisoned_env = TypeEnv.init(allocator, &poisoned_pool);
    defer poisoned_env.deinit();
    try testing.expectError(error.OutOfMemory, effect_inference.buildEffectFacts(
        allocator,
        view,
        null,
        parsed_state.root,
        .{ .type_source = .{ .direct = &poisoned_env } },
    ));

    var failed_env_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    var failed_env_pool = TypePool.init(failed_env_allocator.allocator());
    defer failed_env_pool.deinit(failed_env_allocator.allocator());
    var failed_env = TypeEnv.init(failed_env_allocator.allocator(), &failed_env_pool);
    defer failed_env.deinit();
    try failed_env.ensureHealthy();
    try failed_env_pool.ensureHealthy();
    failed_env_allocator.fail_index = failed_env_allocator.alloc_index;
    failed_env.putTypeAlias("induced_failure", failed_env_pool.idx_string);
    try testing.expect(failed_env_allocator.has_induced_failure);
    try testing.expectError(error.OutOfMemory, failed_env.ensureHealthy());
    try failed_env_pool.ensureHealthy();
    try testing.expectError(error.OutOfMemory, effect_inference.buildEffectFacts(
        allocator,
        view,
        null,
        parsed_state.root,
        .{ .type_source = .{ .direct = &failed_env } },
    ));

    var healthy_pool = TypePool.init(allocator);
    defer healthy_pool.deinit(allocator);
    var healthy_env = TypeEnv.init(allocator, &healthy_pool);
    defer healthy_env.deinit();
    var empty_store = TypeSyntax.Store.init(allocator, "const value = 1;\n");
    defer empty_store.deinit();
    var source_atoms = AtomTable.init(allocator);
    defer source_atoms.deinit();
    try healthy_env.populateSourceTypes(.{ .direct = .{
        .store = &empty_store,
        .ir_view = view,
        .atoms = &source_atoms,
    } });
    var omitted_env_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    var omitted_pool = TypePool.init(omitted_env_allocator.allocator());
    defer omitted_pool.deinit(omitted_env_allocator.allocator());
    var omitted_env = TypeEnv.init(omitted_env_allocator.allocator(), &omitted_pool);
    defer omitted_env.deinit();
    try omitted_env.populateSourceTypes(.omitted);
    try omitted_env.ensureHealthy();
    try omitted_pool.ensureHealthy();
    omitted_env_allocator.fail_index = omitted_env_allocator.alloc_index;
    omitted_env.putTypeAlias("induced_failure", omitted_pool.idx_string);
    try testing.expect(omitted_env_allocator.has_induced_failure);
    try testing.expectError(error.OutOfMemory, omitted_env.ensureHealthy());
    try omitted_pool.ensureHealthy();
    try testing.expectError(
        error.OutOfMemory,
        type_env_mod.ConsumerTypeSource.fromEnvironment(&omitted_env),
    );

    var omitted_pool_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failed_omitted_pool = TypePool.init(omitted_pool_allocator.allocator());
    defer failed_omitted_pool.deinit(omitted_pool_allocator.allocator());
    try testing.expect(omitted_pool_allocator.has_induced_failure);
    var failed_omitted_pool_env = TypeEnv.init(allocator, &failed_omitted_pool);
    defer failed_omitted_pool_env.deinit();
    try failed_omitted_pool_env.populateSourceTypes(.omitted);
    try testing.expectError(
        error.OutOfMemory,
        type_env_mod.ConsumerTypeSource.fromEnvironment(&failed_omitted_pool_env),
    );

    var healthy_omitted_pool = TypePool.init(allocator);
    defer healthy_omitted_pool.deinit(allocator);
    var healthy_omitted_env = TypeEnv.init(allocator, &healthy_omitted_pool);
    defer healthy_omitted_env.deinit();
    try healthy_omitted_env.populateSourceTypes(.omitted);
    var wrong_mode = effect_inference.Analyzer.init(allocator, view, null);
    defer wrong_mode.deinit();
    wrong_mode.type_source = .{ .direct = &healthy_omitted_env };
    try testing.expectError(error.TypeSourceModeMismatch, wrong_mode.analyze(parsed_state.root));

    var builder_facts = try ModuleFacts.build(allocator, view, null, null);
    defer builder_facts.deinit();
    var builder_effects = try effect_inference.buildEffectFacts(allocator, view, null, parsed_state.root, .{});
    defer builder_effects.deinit(allocator);

    var other_pool = TypePool.init(allocator);
    defer other_pool.deinit(allocator);
    var other_env = TypeEnv.init(allocator, &other_pool);
    defer other_env.deinit();
    try other_env.populateSourceTypes(.{ .direct = .{
        .store = &empty_store,
        .ir_view = view,
        .atoms = &source_atoms,
    } });
    var wrong_environment = ContractBuilder.initForBuild(
        allocator,
        view,
        null,
        &healthy_env,
        null,
        &builder_facts,
        &builder_effects,
    );
    defer wrong_environment.deinit();
    wrong_environment.effect_facts = null;
    wrong_environment.source_types = .{ .direct = &other_env };
    try testing.expectError(error.TypeSourceEnvironmentMismatch, wrong_environment.build(
        "operational.ts",
        null,
        null,
        parsed_state.root,
        null,
        false,
        null,
    ));

    var poisoned_builder = ContractBuilder.initForBuild(
        allocator,
        view,
        null,
        &poisoned_env,
        null,
        &builder_facts,
        &builder_effects,
    );
    defer poisoned_builder.deinit();
    poisoned_builder.effect_facts = null;
    poisoned_builder.source_types = .{ .direct = &poisoned_env };
    try testing.expectError(error.OutOfMemory, poisoned_builder.build(
        "operational.ts",
        null,
        null,
        parsed_state.root,
        null,
        false,
        null,
    ));

    var healthy_builder = ContractBuilder.initForBuild(
        allocator,
        view,
        null,
        &healthy_env,
        null,
        &builder_facts,
        &builder_effects,
    );
    defer healthy_builder.deinit();
    healthy_builder.effect_facts = null;
    healthy_builder.source_types = .{ .direct = &healthy_env };
    try testing.expectError(error.CompletedEffectFactsRequired, healthy_builder.build(
        "operational.ts",
        null,
        null,
        parsed_state.root,
        null,
        false,
        null,
    ));
}

const directCallbackSource =
    \\structural CryptoValue = Effects<string, "crypto">;
    \\function run(callback: (value: string) => CryptoValue, value: string): Effects<string, "crypto"> {
    \\  return callback(value);
    \\}
    \\function handler(req: Request): Response { return Response.text("ok"); }
;

fn expectDirectCallbackFacts(facts: *const EffectFacts) !void {
    var found = false;
    for (facts.all()) |function| {
        if (!std.mem.eql(u8, function.name, "run")) continue;
        try testing.expect(function.row.capabilities.contains(.crypto));
        try testing.expect(!function.row.lower_bound);
        try testing.expect(function.row.deterministic);
        found = true;
    }
    try testing.expect(found);
}

test "direct session population closes allocation failures without retry" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(allocator, allocator, directCallbackSource);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);
    const Run = struct {
        fn populate(run_allocator: std.mem.Allocator, module: ParsedModule) !void {
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(run_allocator, module, .{
                .source_types = .direct,
                .strict = false,
            });
            defer analysis.deinit();
            analysis.complete() catch |err| {
                try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
                return err;
            };
            try testing.expectEqual(
                type_env_mod.SourceTypeMode.direct,
                analysis.type_env_storage.envPtr().?.sourceTypeMode().?,
            );
            try analysis.type_env_storage.envPtr().?.ensureHealthy();
            try analysis.type_env_storage.envPtr().?.pool.ensureHealthy();
        }
    };

    var counting = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    try Run.populate(counting.allocator(), parsed);
    try testing.expect(counting.alloc_index > 0);
    var failures: usize = 0;
    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        Run.populate(failing.allocator(), parsed) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            failures += 1;
            continue;
        };
        try testing.expect(!failing.has_induced_failure);
    }
    try testing.expect(failures > 0);
}

test "direct callback effect projection closes every allocation failure" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(allocator, allocator, directCallbackSource);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var marker_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    var marker_storage: TypeEnvStorage = .{};
    defer marker_storage.deinit(marker_allocator.allocator());
    try marker_storage.initWithSource(marker_allocator.allocator(), .{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } });
    {
        var marker_control = try effect_inference.buildEffectFacts(
            marker_allocator.allocator(),
            view,
            &atoms,
            root,
            .{ .type_source = .{ .direct = marker_storage.envPtr().? } },
        );
        defer marker_control.deinit(marker_allocator.allocator());
        try expectDirectCallbackFacts(&marker_control);
    }

    marker_allocator.fail_index = marker_allocator.alloc_index;
    try testing.expectError(error.OutOfMemory, effect_inference.buildEffectFacts(
        allocator,
        view,
        &atoms,
        root,
        .{ .type_source = .{ .direct = marker_storage.envPtr().? } },
    ));
    try testing.expect(marker_allocator.has_induced_failure);
    try marker_storage.envPtr().?.ensureHealthy();
    try marker_storage.envPtr().?.pool.ensureHealthy();

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.initWithSource(allocator, .{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } });
    var module_facts = try ModuleFacts.build(allocator, view, &atoms, null);
    defer module_facts.deinit();
    const handler = handler_verifier_mod.findHandlerFunction(view, root);
    const Run = struct {
        fn project(
            run_allocator: std.mem.Allocator,
            ir_view: IrView,
            atom_table: *AtomTable,
            program: NodeIndex,
            env: *const TypeEnv,
            facts: *const ModuleFacts,
            selected_handler: ?NodeIndex,
        ) !void {
            var effects = try effect_inference.buildEffectFacts(
                run_allocator,
                ir_view,
                atom_table,
                program,
                .{
                    .module_facts = facts,
                    .type_source = .{ .direct = env },
                    .contract_projection = .{ .complete = .{
                        .selected_handler = selected_handler,
                    } },
                },
            );
            defer effects.deinit(run_allocator);
            try expectDirectCallbackFacts(&effects);
            _ = try effects.requireContract();
        }
    };

    var counting = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    try Run.project(
        counting.allocator(),
        view,
        &atoms,
        root,
        storage.envPtr().?,
        &module_facts,
        handler,
    );
    try testing.expect(counting.alloc_index > 0);
    var failures: usize = 0;
    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        Run.project(
            failing.allocator(),
            view,
            &atoms,
            root,
            storage.envPtr().?,
            &module_facts,
            handler,
        ) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            failures += 1;
            continue;
        };
        try testing.expect(!failing.has_induced_failure);
    }
    try testing.expect(failures > 0);
}

test "direct extraction keeps attempted state across allocation failures" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(allocator, allocator, directCallbackSource);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);
    const Run = struct {
        const Outcome = enum {
            success,
            failed_before_effects,
            failed_after_effects,
        };

        fn control(base: std.mem.Allocator, module: ParsedModule) !usize {
            var counting = std.testing.FailingAllocator.init(base, .{
                .fail_index = std.math.maxInt(usize),
            });
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(counting.allocator(), module, .{
                .source_types = .direct,
                .strict = false,
                .capture_export_effects = true,
            });
            defer analysis.deinit();
            try analysis.complete();
            const before = counting.alloc_index;
            var contract = try analysis.extractContract("direct-extraction.ts");
            defer contract.deinit(counting.allocator());
            var export_effects = analysis.takeExportEffects() orelse
                return error.ExportEffectsMissing;
            defer export_effects.deinit(counting.allocator());
            try testing.expectEqual(ModuleAnalysisSession.PassState.completed, analysis.extraction_state);
            try testing.expectEqual(@as(usize, 1), contract.function_effect_capsules.items.len);
            try testing.expectEqualStrings(
                "run",
                contract.function_effect_capsules.items[0].function,
            );
            return counting.alloc_index - before;
        }

        fn failAt(
            base: std.mem.Allocator,
            module: ParsedModule,
            offset: usize,
        ) !Outcome {
            var failing = std.testing.FailingAllocator.init(base, .{
                .fail_index = std.math.maxInt(usize),
            });
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(failing.allocator(), module, .{
                .source_types = .direct,
                .strict = false,
                .capture_export_effects = true,
            });
            defer analysis.deinit();
            try analysis.complete();
            failing.fail_index = failing.alloc_index + offset;
            const result = analysis.extractContract("direct-extraction.ts");
            if (result) |contract_value| {
                var contract = contract_value;
                defer contract.deinit(failing.allocator());
                var export_effects = analysis.takeExportEffects() orelse
                    return error.ExportEffectsMissing;
                defer export_effects.deinit(failing.allocator());
                try testing.expect(!failing.has_induced_failure);
                return .success;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expect(failing.has_induced_failure);
                try testing.expectEqual(ModuleAnalysisSession.PassState.attempted, analysis.extraction_state);
                try testing.expect(analysis.takeExportEffects() == null);
                try testing.expectError(
                    error.ContractExtractionAlreadyAttempted,
                    analysis.extractContract("direct-extraction.ts"),
                );
                try testing.expectEqual(
                    type_env_mod.SourceTypeMode.direct,
                    analysis.type_env_storage.envPtr().?.sourceTypeMode().?,
                );
                try analysis.type_env_storage.envPtr().?.ensureHealthy();
                try analysis.type_env_storage.envPtr().?.pool.ensureHealthy();
                return if (analysis.contract_effect_facts != null)
                    .failed_after_effects
                else
                    .failed_before_effects;
            }
        }
    };

    const allocation_count = try Run.control(allocator, parsed);
    try testing.expect(allocation_count > 0);
    var failures_before_effects: usize = 0;
    var failures_after_effects: usize = 0;
    for (0..allocation_count) |offset| {
        switch (try Run.failAt(allocator, parsed, offset)) {
            .success => {},
            .failed_before_effects => failures_before_effects += 1,
            .failed_after_effects => failures_after_effects += 1,
        }
    }
    try testing.expect(failures_before_effects > 0);
    try testing.expect(failures_after_effects > 0);
}

test "serialization failure preserves a completed direct extraction" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initTyped(allocator, allocator, directCallbackSource);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(
        allocator,
        ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store),
        .{ .source_types = .direct, .strict = false },
    );
    defer analysis.deinit();
    try analysis.complete();
    var contract = try analysis.extractContract("serialization.ts");
    defer contract.deinit(allocator);
    const baseline = try serializeContractForTest(allocator, &contract);
    defer allocator.free(baseline);
    try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
    try testing.expectError(
        error.ContractExtractionAlreadyAttempted,
        analysis.extractContract("serialization.ts"),
    );

    var counting = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    const counted = try serializeContractForTest(counting.allocator(), &contract);
    counting.allocator().free(counted);
    try testing.expect(counting.alloc_index > 0);

    var failures: usize = 0;
    var failures_after_progress: usize = 0;
    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const attempted = serializeContractForTest(failing.allocator(), &contract);
        if (attempted) |bytes| {
            defer failing.allocator().free(bytes);
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqualStrings(baseline, bytes);
        } else |err| {
            switch (err) {
                error.OutOfMemory, error.WriteFailed => {},
            }
            try testing.expect(failing.has_induced_failure);
            failures += 1;
            if (fail_index > 0) failures_after_progress += 1;
        }

        try testing.expectEqual(ModuleAnalysisSession.PassState.completed, analysis.extraction_state);
        try analysis.type_env_storage.envPtr().?.ensureHealthy();
        try analysis.type_env_storage.envPtr().?.pool.ensureHealthy();
        try testing.expectEqualStrings("serialization.ts", contract.handler.path);
        const after_failure = try serializeContractForTest(allocator, &contract);
        defer allocator.free(after_failure);
        try testing.expectEqualStrings(baseline, after_failure);
    }
    try testing.expect(failures > 0);
    try testing.expect(failures_after_progress > 0);
}

test "prepared evaluation contracts omit authored signatures and capsules" {
    const source = "function helper(value: number): string { return \"ok\"; } function handler(req: Request): Effects<Response, \"env\"> { return Response.text(helper(\"wrong\")); }";
    var actual = try extractPreparedEvalContract(std.testing.allocator, source, "<eval>", .{ .strict = false });
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<eval>", actual.handler.path);
    try std.testing.expectEqual(@as(usize, 1), actual.function_capsules.items.len);
    try std.testing.expectEqualStrings("helper", actual.function_capsules.items[0].function);
    try std.testing.expectEqual(@as(usize, 0), actual.function_capsules.items[0].declared.items.len);
    try std.testing.expectEqual(@as(usize, 1), actual.function_effect_capsules.items.len);
    try std.testing.expectEqualStrings("helper", actual.function_effect_capsules.items[0].function);
    try std.testing.expectEqual(@as(usize, 0), actual.function_effect_capsules.items[0].declared.items.len);
    try std.testing.expect(actual.declared_specs_implicit);
    try std.testing.expectError(error.UnsupportedSourceExtension, extractPreparedEvalContract(std.testing.allocator, source, "inline.ts", .{}));
}
