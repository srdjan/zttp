//! Typed pipeline phases for the zts compiler (WS2).
//!
//! Threads three phase wrappers across compilation:
//!
//!   ParsedModule    — IR is built; nothing has been checked yet.
//!   ResolvedModule  — Boolean and (optional) type checks have run.
//!   CheckedModule   — Handler verification + flow analysis have run.
//!
//! Each wrapper owns its pass structs by value (so a single `deinit()` cleans up
//! everything the wrapper added) and exposes diagnostics through accessors.
//! `CheckedModule` borrows `*const ResolvedModule` because `HandlerVerifier`
//! holds a pointer back to the `TypeChecker` and the borrow keeps that target
//! address stable in caller storage.
//!
//! Pass-ordering invariants ("type-check before flow-check", "resolve before
//! check") are encoded in the function signatures: `check` only accepts a
//! `ResolvedModule`, never a `ParsedModule`. Construction of `ParsedModule` is
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
//! compile. See `docs/archive/plans/2026-07-30-007-lowered-module-plan.md`.
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
const type_map_mod = @import("zts-base").type_map;
const service_types_mod = @import("zts-contracts").service_types;
const modules_mod = @import("zts-engine").modules;
const module_types_mod = @import("module_types.zig");
const ir_mod = @import("zts-engine").parser.ir;
const handler_contract_mod = @import("zts-contracts").handler_contract;
const contract_builder_mod = @import("contract_builder.zig");
const manifest_registry_mod = @import("manifest_registry.zig");
const bytecode_mod = @import("zts-engine").bytecode;
const stripper_mod = @import("zts-engine").stripper;
const compat_mod = @import("zts-base").compat;
const string_mod = @import("zts-engine").string;

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
const TypeMap = type_map_mod.TypeMap;
const ServiceTypeContext = service_types_mod.ServiceTypeContext;
const HandlerContract = handler_contract_mod.HandlerContract;
const VerificationInfo = handler_contract_mod.VerificationInfo;
const ContractBuilder = contract_builder_mod.ContractBuilder;
const PatternDispatchTable = bytecode_mod.PatternDispatchTable;
/// Public because `buildModuleFacts` returns one and callers outside the
/// package need to name it. Reaching `zts.module_facts` directly for the same
/// type would widen the internal surface the boundary gate pins.
pub const ModuleFacts = module_facts_mod.ModuleFacts;

// ---------------------------------------------------------------------------
// Phase 1: Parsed
// ---------------------------------------------------------------------------

pub const ParsedModule = struct {
    ir_view: IrView,
    root: NodeIndex,
    atoms: ?*AtomTable,

    /// Adopt an already-parsed IR. Transitional: tighter gating belongs to WS5.
    pub fn fromExisting(ir_view: IrView, root: NodeIndex, atoms: ?*AtomTable) ParsedModule {
        return .{ .ir_view = ir_view, .root = root, .atoms = atoms };
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
    service_type_context: ?*const ServiceTypeContext = null,
    /// Default-on strict ZigTS profile (ZTS6xx). Type-directed rules run when
    /// type context exists; syntax/profile rules still run for untyped sources.
    strict: bool = true,
    /// Shared import index for this compile, built once by the caller. The
    /// pointed-to index must outlive the returned ResolvedModule. When null each
    /// analyzer builds a private one, which is what an un-migrated caller does.
    module_facts: ?*const ModuleFacts = null,
};

pub const ResolvedModule = struct {
    parsed: ParsedModule,
    bool_checker: BoolChecker,
    type_checker: ?TypeChecker,
    strict_checker: ?StrictChecker,
    bool_error_count: u32,
    type_error_count: u32,
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

    pub fn formatBoolDiagnostics(
        self: *const ResolvedModule,
        source: []const u8,
        writer: anytype,
    ) !void {
        try self.bool_checker.formatDiagnostics(source, writer);
    }

    pub fn formatTypeDiagnostics(
        self: *const ResolvedModule,
        source: []const u8,
        writer: anytype,
    ) !void {
        if (self.type_checker) |*tc| try tc.formatDiagnostics(source, writer);
    }

    pub fn formatStrictDiagnostics(
        self: *const ResolvedModule,
        source: []const u8,
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
    var bool_checker = BoolChecker.init(allocator, parsed.ir_view, parsed.atoms);
    bool_checker.facts = opts.module_facts;
    errdefer bool_checker.deinit();
    const bool_errors = try bool_checker.check(parsed.root);

    var type_checker_opt: ?TypeChecker = null;
    var type_errors: u32 = 0;
    if (opts.type_env) |env| {
        var tc = TypeChecker.init(
            allocator,
            parsed.ir_view,
            parsed.atoms,
            env,
            opts.service_type_context,
        );
        errdefer tc.deinit();
        type_errors = try tc.check(parsed.root);
        type_checker_opt = tc;
    }

    var strict_checker_opt: ?StrictChecker = null;
    var strict_errors: u32 = 0;
    if (opts.strict) {
        const env_ptr: ?*const TypeEnv = if (type_checker_opt) |*tc| tc.env else null;
        const tc_ptr: ?*const TypeChecker = if (type_checker_opt) |*tc| tc else null;
        var sc = StrictChecker.init(
            allocator,
            parsed.ir_view,
            parsed.atoms,
            env_ptr,
            tc_ptr,
        );
        sc.facts = opts.module_facts;
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
        .type_error_count = type_errors,
        .strict_error_count = strict_errors,
    };
}

// ---------------------------------------------------------------------------
// Phase 3: Checked (handler verification + flow analysis)
// ---------------------------------------------------------------------------

pub const CheckedModule = struct {
    resolved: *const ResolvedModule,
    verifier: HandlerVerifier,
    flow_checker: FlowChecker,
    verifier_error_count: u32,
    flow_error_count: u32,

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
};

/// Return labels of a function imported from another file, paired with the
/// local binding slot the import produced. The pipeline does no file I/O, so
/// the caller reads and walks those files and hands the answers in.
pub const ImportedFnLabels = struct {
    slot: u16,
    labels: @import("zts-engine").module_binding.LabelSet,
};

pub const CheckOptions = struct {
    /// Shared import index for this compile. Same lifetime rule as
    /// `ResolveOptions.module_facts`. An options struct rather than a fourth
    /// positional parameter so the next addition does not churn every call site.
    module_facts: ?*const ModuleFacts = null,
    /// Cross-file helper return labels. Empty means every such call is treated
    /// as untraceable, which is the conservative direction, not the neutral one.
    imported_fn_labels: []const ImportedFnLabels = &.{},
};

pub fn check(
    allocator: std.mem.Allocator,
    resolved: *const ResolvedModule,
    handler_func: NodeIndex,
    opts: CheckOptions,
) !CheckedModule {
    const tc_ptr: ?*const TypeChecker = if (resolved.type_checker) |*tc| tc else null;
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
    const verifier_errors = try verifier.verify(handler_func);
    if (tc_ptr) |tc| try tc.ensureHealthy();

    var flow = FlowChecker.init(
        allocator,
        resolved.parsed.ir_view,
        resolved.parsed.atoms,
    );
    flow.facts = opts.module_facts;
    errdefer flow.deinit();
    for (opts.imported_fn_labels) |entry| {
        flow.setFileFunctionLabels(entry.slot, entry.labels);
    }
    const flow_errors = try flow.check(handler_func);

    return .{
        .resolved = resolved,
        .verifier = verifier,
        .flow_checker = flow,
        .verifier_error_count = verifier_errors,
        .flow_error_count = flow_errors,
    };
}

// ---------------------------------------------------------------------------
// TypeEnvStorage — caller-owned bundle of TypePool + TypeEnv with a stable
// address. `TypeEnv.init` captures `*TypePool`, so the pool must outlive the
// env and live at a fixed address; bundling them into one struct guarantees
// both. `init` requires a pointer-receiver because `populateFromTypeMap` and
// the env's pool reference both need stable addresses.
// ---------------------------------------------------------------------------

pub const TypeEnvStorage = struct {
    pool: TypePool = undefined,
    env: TypeEnv = undefined,
    initialized: bool = false,

    pub fn init(
        self: *TypeEnvStorage,
        allocator: std.mem.Allocator,
        type_map: *const TypeMap,
    ) !void {
        self.pool = TypePool.init(allocator);
        errdefer self.pool.deinit(allocator);
        try self.pool.ensureHealthy();
        self.env = TypeEnv.init(allocator, &self.pool);
        errdefer self.env.deinit();
        try self.pool.ensureHealthy();
        module_types_mod.populateModuleTypes(&self.env, &self.pool, allocator);
        try self.pool.ensureHealthy();
        self.env.populateFromTypeMap(type_map);
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
    type_map: ?*const TypeMap = null,
    service_type_context: ?*const ServiceTypeContext = null,
    manifest_registry: ?*const manifest_registry_mod.Registry = null,
    type_check: ContractTypeCheckFn = runContractTypeCheck,
    build_time: ?[]const u8 = null,
    git_commit: []const u8 = "unknown",
    version: ?[]const u8 = null,
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
    ///
    /// It does not replace `type_map`: a resolve with no type env (an untyped
    /// source) leaves `type_checker` null, and extraction then builds its own
    /// session from `type_map` as before. It also does not apply when
    /// `type_check` is overridden, because a caller that replaced the check
    /// wants it to run.
    resolved: ?*const ResolvedModule = null,
};

fn runContractTypeCheck(type_checker: *TypeChecker, root: NodeIndex) anyerror!u32 {
    return type_checker.check(root);
}

/// Build an owned handler contract from an already-parsed module.
pub fn extractContractFromParsed(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    filename: []const u8,
    opts: ExtractContractOptions,
) !HandlerContract {
    const handler_fn = handler_verifier_mod.findHandlerFunction(parsed.ir_view, parsed.root);
    const handler_loc = if (handler_fn) |hf| parsed.ir_view.getLoc(hf) else null;

    if (opts.type_check == runContractTypeCheck) {
        if (opts.resolved) |resolved| {
            if (resolved.type_checker) |*tc| {
                var contract = try buildContractOn(
                    allocator,
                    parsed,
                    filename,
                    opts,
                    tc.env,
                    tc,
                    handler_fn,
                    handler_loc,
                );
                errdefer contract.deinit(allocator);
                try tc.ensureHealthy();
                return contract;
            }
        }
    }

    var type_pool = TypePool.init(allocator);
    defer type_pool.deinit(allocator);

    var type_env = TypeEnv.init(allocator, &type_pool);
    defer type_env.deinit();
    module_types_mod.populateModuleTypes(&type_env, &type_pool, allocator);
    if (opts.type_map) |type_map| {
        type_env.populateFromTypeMap(type_map);
    }

    var type_checker = TypeChecker.init(
        allocator,
        parsed.ir_view,
        parsed.atoms,
        &type_env,
        opts.service_type_context,
    );
    defer type_checker.deinit();
    _ = try opts.type_check(&type_checker, parsed.root);

    var contract = try buildContractOn(
        allocator,
        parsed,
        filename,
        opts,
        &type_env,
        &type_checker,
        handler_fn,
        handler_loc,
    );
    errdefer contract.deinit(allocator);
    try type_checker.ensureHealthy();
    return contract;
}

/// The half of contract extraction that does not care where the type session
/// came from: a freshly built one, or the one `resolve` already ran.
fn buildContractOn(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    filename: []const u8,
    opts: ExtractContractOptions,
    type_env: *const TypeEnv,
    type_checker: *const TypeChecker,
    handler_fn: ?NodeIndex,
    handler_loc: ?ir_mod.SourceLocation,
) !HandlerContract {
    var builder = ContractBuilder.init(
        allocator,
        parsed.ir_view,
        parsed.atoms,
        type_env,
        type_checker,
    );
    builder.manifest_registry = opts.manifest_registry;
    builder.injected_facts = opts.module_facts;
    defer builder.deinit();

    return builder.build(
        filename,
        handler_loc,
        handler_fn,
        parsed.root,
        opts.dispatch,
        opts.has_default_response,
        opts.verification,
    );
}

/// Strip TypeScript/TSX when needed, parse and resolve the source, then return
/// an owned handler contract. The caller must deinit the returned contract.
pub fn extractContract(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    opts: ExtractContractOptions,
) !HandlerContract {
    var source_to_parse = source;
    var strip_result: ?stripper_mod.StripResult = null;
    defer if (strip_result) |*result| result.deinit();

    const is_ts = std.mem.endsWith(u8, filename, ".ts");
    const is_tsx = std.mem.endsWith(u8, filename, ".tsx");
    if (is_ts or is_tsx) {
        var timestamp_buf: [24]u8 = undefined;
        const build_time = opts.build_time orelse formatIsoTimestamp(&timestamp_buf, blk: {
            const milliseconds = compat_mod.realtimeNowMs() catch break :blk 0;
            break :blk @divTrunc(milliseconds, 1000);
        });
        strip_result = try stripper_mod.strip(allocator, source, .{
            .tsx_mode = is_tsx,
            .enable_comptime = true,
            .comptime_env = .{
                .build_time = build_time,
                .git_commit = opts.git_commit,
                .version = opts.version,
                .env_vars = null,
            },
        });
        const stripped = strip_result orelse unreachable;
        source_to_parse = stripped.code;
    }

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    var js_parser = try parser_mod.JsParser.init(allocator, source_to_parse);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    if (std.mem.endsWith(u8, filename, ".jsx") or is_tsx) {
        js_parser.tokenizer.enableJsx();
    }

    const root = try js_parser.parse();
    _ = parser_mod.optimizeIR(
        allocator,
        &js_parser.nodes,
        &js_parser.constants,
        root,
    ) catch {};

    const ir_view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = ParsedModule.fromExisting(ir_view, root, &atoms);
    const effective_type_map = if (strip_result) |*result| &result.type_map else opts.type_map;
    var contract_opts = opts;
    contract_opts.type_map = effective_type_map;
    if (hasFileImports(ir_view)) {
        const read_file = opts.read_file orelse return error.FileImportReaderRequired;
        return extractMultiModuleContract(
            allocator,
            source_to_parse,
            filename,
            read_file,
            &atoms,
            contract_opts,
        );
    }

    var type_env_storage: TypeEnvStorage = .{};
    defer type_env_storage.deinit(allocator);
    if (effective_type_map) |type_map| {
        try type_env_storage.init(allocator, type_map);
    }

    // One index for this module, owned here for the same reason precompile owns
    // its own: the phase structs cannot hold a stable address for it.
    var module_facts = try buildModuleFacts(allocator, parsed, null);
    defer module_facts.deinit();

    var resolved = try resolve(allocator, parsed, .{
        .type_env = type_env_storage.envPtr(),
        .service_type_context = opts.service_type_context,
        .strict = opts.strict,
        .module_facts = &module_facts,
    });
    defer resolved.deinit();

    if (resolved.bool_error_count > 0 or
        resolved.type_error_count > 0 or
        resolved.strict_error_count > 0)
    {
        return error.SoundModeViolation;
    }

    return extractContractFromParsed(allocator, parsed, filename, contract_opts);
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
    var graph = modules_mod.ModuleGraph.init(allocator);
    defer graph.deinit();
    try graph.build(entry_filename, entry_source, read_file);

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

    const entry_index = compile_result.modules.len - 1;
    for (compile_result.modules, compile_result.parsers, 0..) |compiled_module, *js_parser, idx| {
        const graph_idx = graph.execution_order[idx];
        const module = &graph.module_list.items[graph_idx];
        const is_entry = idx == entry_index;
        const module_view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
        const parsed = ParsedModule.fromExisting(module_view, compiled_module.root, atoms);

        var module_opts = opts;
        module_opts.type_map = if (is_entry) opts.type_map else null;
        module_opts.read_file = null;
        if (!is_entry) {
            module_opts.dispatch = null;
            module_opts.has_default_response = false;
            module_opts.verification = null;
        }

        var type_env_storage: TypeEnvStorage = .{};
        defer type_env_storage.deinit(allocator);
        if (module_opts.type_map) |type_map| {
            try type_env_storage.init(allocator, type_map);
        }
        // Per module, not per compile: each module in the graph has its own IR,
        // so an index built over one says nothing about another.
        var module_facts = try buildModuleFacts(allocator, parsed, null);
        defer module_facts.deinit();

        var resolved = try resolve(allocator, parsed, .{
            .type_env = type_env_storage.envPtr(),
            .service_type_context = module_opts.service_type_context,
            .strict = module_opts.strict,
            .module_facts = &module_facts,
        });
        defer resolved.deinit();
        if (resolved.bool_error_count > 0 or
            resolved.type_error_count > 0 or
            resolved.strict_error_count > 0)
        {
            return error.SoundModeViolation;
        }

        var module_contract = try extractContractFromParsed(allocator, parsed, module.path, module_opts);
        defer module_contract.deinit(allocator);
        try handler_contract_mod.mergeModuleContract(allocator, &merged, &module_contract, is_entry);
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
    var type_map = TypeMap.init("");
    defer type_map.deinit(allocator);

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, storage.init(failing.allocator(), &type_map));
    try testing.expect(storage.envPtr() == null);
}

test "TypeEnvStorage rejects a late poisoned TypePool" {
    const allocator = testing.allocator;
    var type_map = TypeMap.init("");
    defer type_map.deinit(allocator);

    var storage: TypeEnvStorage = .{};
    storage.pool = TypePool.init(allocator);
    defer storage.pool.deinit(allocator);
    try storage.pool.ensureHealthy();
    storage.env = TypeEnv.init(allocator, &storage.pool);
    defer storage.env.deinit();
    try storage.pool.ensureHealthy();
    module_types_mod.populateModuleTypes(&storage.env, &storage.pool, allocator);
    try storage.pool.ensureHealthy();
    storage.env.populateFromTypeMap(&type_map);
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

    var type_map = TypeMap.init("");
    defer type_map.deinit(allocator);
    var storage: TypeEnvStorage = .{};
    try storage.init(allocator, &type_map);
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

test "pipeline.resolve runs BoolChecker on clean source" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const x = true;\nconst y = !x;\n");
    defer parsed_state.js_parser.deinit();

    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{});
    defer resolved.deinit();

    try testing.expectEqual(@as(u32, 0), resolved.bool_error_count);
    try testing.expectEqual(@as(u32, 0), resolved.type_error_count);
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

    try testing.expect(resolved.bool_error_count > 0);
    try testing.expect(resolved.boolDiagnostics().len > 0);
}

test "pipeline.resolve runs strict checker without type context" {
    const allocator = testing.allocator;
    const source: []const u8 = "function handler(req) { let x = 1; return Response.json({x}); }";

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

test "extractContract strips TypeScript and honors strict opt out" {
    const source =
        \\function handler(req: Request): Response {
        \\  let message: string = "ok";
        \\  return Response.text(message);
        \\}
    ;

    var contract = try extractContract(testing.allocator, source, "handler.ts", .{
        .strict = false,
        .version = "test",
    });
    defer contract.deinit(testing.allocator);

    try testing.expectEqualStrings("handler.ts", contract.handler.path);
}

test "extractContract parses TSX" {
    const source =
        \\function handler(req: Request): Response {
        \\  const body = <main>ok</main>;
        \\  _ = body;
        \\  return Response.text("ok");
        \\}
    ;

    var contract = try extractContract(testing.allocator, source, "handler.tsx", .{
        .strict = false,
        .version = "test",
    });
    defer contract.deinit(testing.allocator);

    try testing.expectEqualStrings("handler.tsx", contract.handler.path);
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
            .version = "test",
        }),
    );
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
        .version = "test",
        .read_file = file_io.readFileForModuleGraph,
    });
    defer contract.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), contract.egress.hosts.items.len);
    try testing.expectEqualStrings("localhost", contract.egress.hosts.items[0]);

    try file_io.writeFile(
        allocator,
        dependency_path,
        "if ({}) { const unreachable = true; } export function request() { return fetchSync('http://localhost:1'); }",
    );
    try testing.expectError(
        error.SoundModeViolation,
        extractContract(allocator, source, entry_path, .{
            .strict = false,
            .version = "test",
            .read_file = file_io.readFileForModuleGraph,
        }),
    );

    try file_io.writeFile(
        allocator,
        dependency_path,
        "export function request() { let response = fetchSync('http://localhost:1'); return response; }",
    );
    try testing.expectError(
        error.SoundModeViolation,
        extractContract(allocator, source, entry_path, .{
            .strict = true,
            .version = "test",
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
fn runCompilePhasesForTest(allocator: std.mem.Allocator, source: []const u8, type_map: *const TypeMap) !void {
    var js_parser = try JsParser.init(allocator, source);
    defer js_parser.deinit();
    const root = try js_parser.parse();

    const view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, null);

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.init(allocator, type_map);

    var resolved = try resolve(allocator, parsed, .{ .type_env = storage.envPtr(), .strict = false });
    defer resolved.deinit();

    const handler_func = handler_verifier_mod.findHandlerFunction(view, root) orelse
        return error.HandlerNotFound;

    var checked = try check(allocator, &resolved, handler_func, .{});
    defer checked.deinit();

    var contract = try extractContractFromParsed(allocator, parsed, "sweep.ts", .{
        .strict = false,
        .resolved = &resolved,
    });
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
    var type_map = TypeMap.init("");
    defer type_map.deinit(allocator);

    // The successful run first, both as a control and to learn how many
    // allocations the sweep has to cover.
    var counting = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
    try runCompilePhasesForTest(counting.allocator(), source, &type_map);
    const total = counting.alloc_index;
    try testing.expect(total > 0);

    // Each iteration fails one allocation. A leak on any unwind path is
    // reported by std.testing.allocator when the test ends, which is the
    // assertion; the error value itself is not interesting.
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = i });
        runCompilePhasesForTest(failing.allocator(), source, &type_map) catch {};
    }
}
