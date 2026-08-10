//! zts - Zig TypeScript compiler
//!
//! A performance-oriented JavaScript engine featuring:
//! - Generational GC with bump allocation
//! - SIMD-accelerated string operations
//! - Hidden classes and inline caching
//! - Lock-free runtime pooling
//!
//! ## Quick Start
//!
//! ```zig
//! const zts = @import("zts");
//!
//! // Create a runtime pool
//! var pool = try zts.LockFreePool.init(allocator, .{});
//! defer pool.deinit();
//!
//! // Acquire a runtime
//! const runtime = try pool.acquire();
//! defer pool.release(runtime);
//!
//! // Execute JavaScript
//! const result = runtime.ctx.eval("1 + 2");
//! ```
//!
//! ## Stability of this surface
//!
//! Two tiers are re-exported below:
//!
//! - **Stable public surface** - the convenience type and entry-point
//!   re-exports near the bottom of this file (`JSValue`, `Context`, `GC`,
//!   `LockFreePool`, `Runtime`, `Interpreter`, `Parser`, `strip`,
//!   `createContext`, ...). These are the curated surface for embedding the
//!   engine and are kept deliberately small and stable.
//! - **Internal implementation modules** - the `pub const <module> =
//!   @import("...")` re-exports in the next section. They are exposed only so
//!   the in-repo runtime, tools, and pi packages can share implementation; they
//!   are NOT a curated public API and may change between releases without
//!   notice. Depend on them only from within this repository, and prefer the
//!   curated types above for anything new.
//!
//! The second tier is gated, not merely documented.
//! `scripts/module-boundary.allow` records which internal module each consumer
//! package may name, and `scripts/check-module-boundary.sh` (the
//! `test-module-boundary` build step, which `zig build test` depends on) fails
//! both on an unlisted reach and on a listed row nothing uses any more. That
//! is an allowlist, not a compiler-enforced split: every consumer still
//! imports one `zts` module and they all move together under one test suite.

// The four tiers this umbrella re-exports. Each is a separate build module,
// declared in packages/zts/build.zig and layered lowest-first:
//
//   zts-base <- zts-contracts <- zts-engine <- zts-compiler
//
// This file names all four and nothing names this file, so the umbrella adds
// no edge to that graph. A tier reaching another tier by relative path would
// compile a second copy of the file into itself;
// scripts/check-zts-layering.sh fails on that, and so does zig.
const base = @import("zts-base");
const contracts = @import("zts-contracts");
const engine = @import("zts-engine");
const compiler = @import("zts-compiler");

const std = @import("std");
const diagnostic_projection = compiler.diagnostic_projection;
// The contract extraction pass. Named here rather than through
// `handler_contract.zig`, which holds the contract's data and serialization and
// must not drag the extractor's dependencies along behind an alias.
const contract_builder = compiler.contract_builder;

// ============================================================================
// Internal implementation modules (no cross-release stability guarantee).
// Exposed for the in-repo runtime/tools/pi packages; prefer the curated public
// types in the "Stable public surface" section below. See the Stability note
// at the top of this file.
// ============================================================================
pub const value = engine.value;
pub const heap = engine.heap;
pub const gc = engine.gc;
pub const string = engine.string;
pub const object = engine.object;
pub const context = engine.context;
pub const bytecode = engine.bytecode;
pub const interpreter = engine.interpreter;

pub const builtins = engine.builtins;
// New two-pass parser with proper function compilation
pub const parser = engine.parser;
// Note: Legacy single-pass parser removed; use parser/root.zig
pub const pool = engine.pool;
pub const http = engine.http;
pub const bytes = engine.bytes;
pub const stripper = engine.stripper;
pub const comptime_eval = engine.comptime_eval;
pub const bytecode_cache = engine.bytecode_cache;
pub const bytecode_opt = engine.bytecode_opt;
pub const arena = engine.arena;
pub const handler_analyzer = engine.handler_analyzer;
pub const handler_verifier = compiler.handler_verifier;
pub const handler_contract = contracts.handler_contract;
pub const handler_policy = engine.handler_policy;
pub const policy = engine.policy;
pub const bool_checker = compiler.bool_checker;
pub const flow_checker = compiler.flow_checker;
pub const path_generator = compiler.path_generator;
pub const counterexample = compiler.counterexample;
pub const proof_trace = compiler.proof_trace;
pub const witness_corpus = compiler.witness_corpus;
pub const repair_plan = compiler.repair_plan;
pub const json_utils = base.json_utils;
pub const behavior_canonical = compiler.behavior_canonical;
pub const fault_coverage = compiler.fault_coverage;
pub const property_diagnostics = compiler.property_diagnostics;
pub const route_match = base.route_match;
pub const type_map = base.type_map;
pub const type_pool = compiler.type_pool;
pub const type_key = compiler.type_key;
pub const type_env = compiler.type_env;
pub const service_types = contracts.service_types;
pub const type_checker = compiler.type_checker;
pub const strict_checker = compiler.strict_checker;
pub const effect_inference = compiler.effect_inference;
pub const pipeline = compiler.pipeline;
pub const bytecode_verifier = engine.bytecode_verifier;
pub const trace = engine.trace;
pub const file_io = engine.file_io;
pub const module_slots = base.module_slots;
pub const contract_diff = compiler.contract_diff;
pub const system_linker = compiler.system_linker;
pub const perf_receipt = contracts.perf_receipt;
pub const equivalence_receipt = contracts.equivalence_receipt;
pub const rule_registry = compiler.rule_registry;
pub const idiom_registry = compiler.idiom_registry;
pub const restriction_registry = compiler.restriction_registry;
pub const repair_intent = compiler.repair_intent;
pub const repair_validator = compiler.repair_validator;
pub const ws_consistency = compiler.ws_consistency;
pub const spec_discharge = compiler.spec_discharge;
pub const function_specs = compiler.function_specs;
pub const module_binding = engine.module_binding;
pub const module_manifest = engine.module_manifest;
pub const manifest_registry = compiler.manifest_registry;
pub const builtin_modules = engine.builtin_modules;
pub const module_facts = compiler.module_facts;
pub const security_events = engine.security_events;
pub const wasm = engine.wasm;
pub const sqlite = engine.sqlite;
pub const sql_analysis = compiler.sql_analysis;
pub const modules = engine.modules;
pub const compat = base.compat;
pub const semantics = compiler.semantics;
pub const semantics_check = compiler.semantics_check;
pub const semantics_smt = compiler.semantics_smt;
pub const semantics_audit = compiler.semantics_audit;
pub const semantics_corpus = compiler.semantics_corpus;
pub const semantics_render = compiler.semantics_render;
pub const module_spec_render = compiler.module_spec_render;

// ============================================================================
// Stable public surface: primary types and entry points for embedding the
// engine. This is the curated API; keep it small and stable.
// ============================================================================
pub const JSValue = value.JSValue;
pub const Context = context.Context;
pub const GC = gc.GC;
pub const GCConfig = gc.GCConfig;
pub const Heap = heap.Heap;
pub const LockFreePool = pool.LockFreePool;
pub const Runtime = pool.LockFreePool.Runtime;
pub const Interpreter = interpreter.Interpreter;
pub const Opcode = bytecode.Opcode;
pub const FunctionBytecode = bytecode.FunctionBytecode;
pub const FunctionBytecodeCompact = bytecode.FunctionBytecodeCompact;
pub const Atom = object.Atom;
pub const AtomTable = context.AtomTable;
/// Per-request cost accounting: the `Meter` a `Context` carries and the
/// `ModuleClass` buckets it charges against.
pub const CostMeter = context.cost_meter;
pub const HiddenClassIndex = object.HiddenClassIndex;
pub const HiddenClassPool = object.HiddenClassPool;
pub const JSObject = object.JSObject;
pub const NativeFn = object.NativeFn;
pub const InlineCache = object.InlineCache;
pub const JSString = string.JSString;
pub const StringTable = string.StringTable;
pub const createString = string.createString;
pub const Parser = parser.Parser;
/// Read-only view over a parsed IR store, for walking a program without
/// holding the parser.
pub const IrView = parser.IrView;
pub const StripResult = stripper.StripResult;
pub const StripOptions = stripper.StripOptions;
pub const StripDiagnostic = stripper.StripDiagnostic;
pub const StripDiagnosticKind = stripper.StripDiagnosticKind;
pub const ComptimeEnv = stripper.ComptimeEnv;
/// The text a diagnostic is rendered against, plus the mapping that moves a
/// position from the stripped parse back into it. A consumer that reports a
/// position to a human or to a repair needs this, not the stripped text.
pub const SourceView = stripper.SourceView;
pub const SourcePosition = stripper.Position;
pub const strip = stripper.strip;
pub const ComptimeEvaluator = comptime_eval.ComptimeEvaluator;
pub const ComptimeValue = comptime_eval.ComptimeValue;
pub const emitLiteral = comptime_eval.emitLiteral;

/// Return the borrowed contents of a 1-based source line without its newline.
/// Empty input and the empty line after a trailing newline are not lines.
pub fn sourceLine(source: []const u8, line: u32) ?[]const u8 {
    return bool_checker.getSourceLine(source, line);
}

test "stable sourceLine preserves source line boundaries" {
    try std.testing.expect(sourceLine("content", 0) == null);
    try std.testing.expect(sourceLine("", 1) == null);

    const source = "first\n\nfinal";
    try std.testing.expectEqualStrings("first", sourceLine(source, 1).?);
    try std.testing.expectEqualStrings("", sourceLine(source, 2).?);
    try std.testing.expectEqualStrings("final", sourceLine(source, 3).?);
    try std.testing.expect(sourceLine(source, 4) == null);

    try std.testing.expectEqualStrings("", sourceLine("\ncontent", 1).?);
    try std.testing.expect(sourceLine("content\n", 2) == null);
}

pub const BytecodeCache = bytecode_cache.BytecodeCache;
pub const BytecodeOptimizer = bytecode_opt.BytecodeOptimizer;
pub const optimizeBytecode = bytecode_opt.optimizeBytecode;
pub const OptStats = bytecode_opt.OptStats;
pub const HandlerAnalyzer = handler_analyzer.HandlerAnalyzer;
pub const HandlerVerifier = handler_verifier.HandlerVerifier;
pub const findHandlerFunction = handler_verifier.findHandlerFunction;
pub const BoolChecker = bool_checker.BoolChecker;
pub const FlowChecker = flow_checker.FlowChecker;
pub const PathGenerator = path_generator.PathGenerator;
pub const TypeMap = type_map.TypeMap;
pub const TypeMapEntry = type_map.TypeMapEntry;
pub const TypeMapKind = type_map.TypeMapKind;
pub const TypePool = type_pool.TypePool;
pub const TypePoolError = type_pool.TypePoolError;
pub const TypeIndex = type_pool.TypeIndex;
pub const null_type_idx = type_pool.null_type_idx;
pub const parseTypeExpr = type_pool.parseTypeExpr;
/// Structural identity of a type, for a consumer that needs to say two types
/// are the same without holding a pool index. The frozen-signature gate pins
/// every virtual-module export by this digest.
pub const typeDigest = type_key.typeDigest;
pub const TypeEnv = type_env.TypeEnv;
pub const TypeChecker = type_checker.TypeChecker;
pub const StrictChecker = strict_checker.StrictChecker;
pub const EffectAnalyzer = effect_inference.Analyzer;
pub const EffectRow = effect_inference.EffectRow;
pub const FunctionEffect = effect_inference.FunctionEffect;
pub const BytecodeVerifier = bytecode_verifier;
pub const ContractBuilder = contract_builder.ContractBuilder;
pub const HandlerContract = handler_contract.HandlerContract;

/// What a build proved about a handler: pure, read-only, stateless, retry-safe,
/// deterministic, and the rest. Curated alongside `HandlerContract` because it
/// is one of that type's fields, and every consumer that reads a contract reads
/// this - sixteen call sites across the runtime, the tools and the expert agent
/// reached `handler_contract` for it before it had a curated name.
pub const HandlerProperties = handler_contract.HandlerProperties;
pub const ContractProof = struct {
    pub const Level = contract_diff.ProofLevel;

    pub fn level(contract: *const HandlerContract) Level {
        return contract_diff.deriveProofLevel(contract);
    }

    pub fn claimScope(contract: *const HandlerContract) []const u8 {
        return contract_diff.claimScope(contract.properties);
    }
};

/// Stable identity of the analyzer policy linked into this build.
pub fn policyHash() [64]u8 {
    return rule_registry.policyHash();
}

test "stable policyHash exposes the policy registry identity" {
    const stable_hash = policyHash();
    const registry_hash = rule_registry.policyHash();
    try std.testing.expectEqualStrings(&registry_hash, &stable_hash);
}

/// Borrowed, read-only access to the analyzer rule catalog.
pub const PolicyCatalog = struct {
    pub const Category = rule_registry.RuleCategory;
    pub const Rule = rule_registry.RuleEntry;

    pub const SearchResults = rule_registry.SearchResults;

    pub fn rules() []const Rule {
        return &rule_registry.all_rules;
    }

    pub fn findByName(name: []const u8) ?*const Rule {
        return rule_registry.findByName(name);
    }

    pub fn findByCode(code: []const u8) ?*const Rule {
        return rule_registry.findByCode(code);
    }

    pub fn search(keyword: []const u8) SearchResults {
        return rule_registry.search(keyword);
    }

    pub fn isCanonicalProfileCode(code: []const u8) bool {
        return rule_registry.isCanonicalProfileCode(code);
    }
};

test "stable PolicyCatalog exposes borrowed rule queries" {
    const rules = PolicyCatalog.rules();
    try std.testing.expectEqual(rule_registry.all_rules.len, rules.len);
    try std.testing.expect(rules.len >= 35);

    const first: *const PolicyCatalog.Rule = &rules[0];
    const category: PolicyCatalog.Category = first.category;
    try std.testing.expectEqual(first, PolicyCatalog.findByName(first.name).?);
    try std.testing.expectEqual(first, PolicyCatalog.findByCode(first.code).?);
    try std.testing.expectEqualStrings(first.category.label(), category.label());
    try std.testing.expect(PolicyCatalog.findByName("not-a-rule") == null);
    try std.testing.expect(PolicyCatalog.findByCode("ZTS9999") == null);

    const exact = PolicyCatalog.search(first.name);
    try std.testing.expect(exact.constSlice().len > 0);
    var found_first = false;
    for (exact.constSlice()) |rule| {
        if (rule == first) found_first = true;
    }
    try std.testing.expect(found_first);

    const all = PolicyCatalog.search("");
    try std.testing.expectEqual(rules.len, all.constSlice().len);
    const missing = PolicyCatalog.search("not-a-rule-or-description");
    try std.testing.expectEqual(@as(usize, 0), missing.constSlice().len);

    try std.testing.expect(PolicyCatalog.isCanonicalProfileCode("ZTS604"));
    try std.testing.expect(!PolicyCatalog.isCanonicalProfileCode("ZTS500"));
}

/// Stable identity of the idiom preference table linked into this build.
pub fn idiomTableHash() [64]u8 {
    return idiom_registry.tableHash();
}

/// Borrowed, read-only access to the idiom preference table.
pub const IdiomCatalog = struct {
    pub const Idiom = idiom_registry.IdiomEntry;

    pub fn idioms() []const Idiom {
        return &idiom_registry.entries;
    }

    pub fn findByRewriteRule(intentName: []const u8) ?*const Idiom {
        return idiom_registry.findByRewriteRule(intentName);
    }
};

/// Stable identity of the restriction matrix linked into this build.
pub fn restrictionMatrixHash() [64]u8 {
    return restriction_registry.matrixHash();
}

/// Borrowed, read-only access to the analyzer restriction matrix.
pub const RestrictionCatalog = struct {
    pub const Nature = restriction_registry.Nature;
    pub const Restriction = restriction_registry.RestrictionEntry;

    pub fn restrictions() []const Restriction {
        return &restriction_registry.entries;
    }

    pub fn findById(id: []const u8) ?*const Restriction {
        return restriction_registry.findById(id);
    }

    pub fn v1Count() usize {
        return restriction_registry.v1_count;
    }
};

test "stable policy metadata catalogs expose borrowed queries and hashes" {
    const idioms = IdiomCatalog.idioms();
    try std.testing.expectEqual(idiom_registry.entries.len, idioms.len);
    try std.testing.expect(idioms.len > 0);
    const wired = IdiomCatalog.findByRewriteRule("drop_unused_index_alias") orelse
        return error.TestExpectedIdiom;
    const internalWired = idiom_registry.findByRewriteRule("drop_unused_index_alias") orelse
        return error.TestExpectedInternalIdiom;
    try std.testing.expectEqual(internalWired, wired);
    try std.testing.expect(IdiomCatalog.findByRewriteRule("not-a-rewrite") == null);
    try std.testing.expectEqualStrings(&idiom_registry.tableHash(), &idiomTableHash());

    const restrictions = RestrictionCatalog.restrictions();
    try std.testing.expectEqual(restriction_registry.entries.len, restrictions.len);
    try std.testing.expect(restrictions.len > RestrictionCatalog.v1Count());
    const first: *const RestrictionCatalog.Restriction = &restrictions[0];
    const nature: RestrictionCatalog.Nature = first.nature;
    const found = RestrictionCatalog.findById(first.id) orelse
        return error.TestExpectedRestriction;
    try std.testing.expectEqual(first, found);
    try std.testing.expectEqualStrings(first.nature.label(), nature.label());
    try std.testing.expectEqual(restriction_registry.v1_count, RestrictionCatalog.v1Count());
    try std.testing.expect(RestrictionCatalog.findById("restriction.missing") == null);
    try std.testing.expectEqualStrings(
        &restriction_registry.matrixHash(),
        &restrictionMatrixHash(),
    );
}

pub const DiagnosticProjection = diagnostic_projection;

test "DiagnosticProjection exposes stable tagged checker codes" {
    try std.testing.expectEqualStrings(
        "ZTS100",
        DiagnosticProjection.code(.boolean, .condition_not_boolean),
    );
    try std.testing.expectEqualStrings(
        "ZTS200",
        DiagnosticProjection.code(.type, .type_mismatch),
    );
    try std.testing.expectEqualStrings(
        "ZTS300",
        DiagnosticProjection.code(.verifier, .missing_return_else),
    );
    try std.testing.expectEqualStrings(
        "ZTS400",
        DiagnosticProjection.code(.flow, .secret_in_response),
    );
    try std.testing.expectEqualStrings(
        "ZTS600",
        DiagnosticProjection.code(.strict, .implicit_unknown),
    );
}
pub const SpecDiagnostic = handler_contract.SpecDiagnostic;
pub const writeContractJson = handler_contract.writeContractJson;
pub const HandlerPolicy = handler_policy.HandlerPolicy;
pub const RuntimePolicy = handler_policy.RuntimePolicy;
pub const PolicyInput = policy.PolicyInput;
pub const PolicyResult = policy.PolicyResult;
pub const LocalPolicyChecker = policy.LocalPolicyChecker;
pub const PatternDispatchTable = bytecode.PatternDispatchTable;
pub const HandlerPattern = bytecode.HandlerPattern;
pub const HandlerFlags = bytecode.HandlerFlags;
pub const TraceRecorder = trace.TraceRecorder;
pub const TRACE_STATE_SLOT = trace.TRACE_STATE_SLOT;

/// Serialize a string as a JSON string literal, escaping per RFC 8259. Every
/// consumer that writes JSON by hand reached `json_utils` for this one function.
pub const writeJsonString = json_utils.writeJsonString;

/// Every virtual module linked into this build: the core built-ins plus any
/// explicitly registered extensions. Iterate it to register the module set.
pub const builtinModules = builtin_modules.all;

/// Union the capabilities every named module requires, resolved through the
/// registry linked into this build. The runtime compares the result against
/// an embedded contract's stored matrix to detect drift.
pub const computeCapabilityMatrix = builtin_modules.computeCapabilityMatrix;

/// Install the JavaScript global built-ins into a fresh context.
pub const initBuiltins = builtins.initBuiltins;

/// Resolve a predefined atom by name, for a caller holding a name but no
/// `AtomTable`.
pub const lookupPredefinedAtom = object.lookupPredefinedAtom;

/// Monotonic clock, for measuring elapsed time. Not comparable across
/// processes and unrelated to wall-clock time.
pub const monotonicNowNs = compat.monotonicNowNs;

/// Wall-clock time in milliseconds since the Unix epoch.
pub const realtimeNowMs = compat.realtimeNowMs;

/// Enumerate the failable paths a handler can take and report which are
/// covered.
pub const FaultCoverageChecker = fault_coverage.FaultCoverageChecker;

/// One finding from the handler verifier, with its location and kind.
/// Qualified because `Diagnostic` alone says nothing about which checker
/// produced it - compare `SpecDiagnostic` and `StripDiagnostic`.
pub const VerifierDiagnostic = handler_verifier.Diagnostic;

/// Search for a concrete input that refutes a proof obligation.
pub const solveCounterexample = counterexample.solve;

/// Compare route patterns segment by segment. `:name` and `{name}` are
/// symmetric one-segment wildcards. `*` is literal, and trailing slashes are
/// significant.
pub const routePatternsMatch = route_match.pathsMatch;

/// Compatibility alias for callers of the original stable export. New code
/// should use `routePatternsMatch`.
pub const pathsMatch = routePatternsMatch;

test "stable routePatternsMatch preserves route pattern semantics" {
    try std.testing.expect(routePatternsMatch("/orders/:id", "/orders/42"));
    try std.testing.expect(!routePatternsMatch("/assets/*", "/assets/app.js"));
    try std.testing.expect(!routePatternsMatch("/orders", "/orders/"));
}

test "stable pathsMatch compatibility alias remains callable" {
    try std.testing.expect(pathsMatch("/orders/:id", "/orders/42"));
}

/// Classify a single SQL statement: which tables it touches and whether it
/// writes.
pub const analyzeSqlStatement = sql_analysis.analyzeStatement;

/// Encode a semantics refutation for the SMT layer.
pub const encodeRefutation = semantics_audit.encodeRefutation;

/// Render a module semantics spec as TypeScript.
pub const renderSpecTs = semantics_render.renderSpecTs;

/// Parse a multi-handler system configuration from its on-disk form.
pub const parseSystemConfig = system_linker.parseSystemConfig;

/// How much of a linked system is proven. Qualified to keep it distinct from
/// `ContractProof.Level`, which grades a single handler's contract.
pub const SystemProofLevel = system_linker.ProofLevel;

/// The registry of installed extension manifests. `Registry` alone is too
/// generic for a surface this small, so the curated name says which registry.
pub const ManifestRegistry = manifest_registry.Registry;

/// Stable module-manifest data and identity operations used by tooling.
/// Parsed manifests own their strings and lists and retain the underlying
/// manifest's explicit `deinit` contract.
pub const ModuleMetadata = struct {
    pub const Error = module_manifest.ManifestError;
    pub const Manifest = module_manifest.Manifest;
    pub const Export = module_manifest.Export;
    pub const ContractExtractionRule = module_manifest.ContractExtractionRule;
    pub const CapabilityDeclaration = module_manifest.CapabilityDeclaration;

    /// Parse a module manifest from its on-disk JSON form. The result owns its
    /// strings and lists; call `deinit`.
    pub const parse = module_manifest.parse;

    pub fn builtinRegistryHash() [64]u8 {
        return module_manifest.registryHashFromBindings(&builtin_modules.all);
    }
};

test "stable ModuleMetadata exposes manifest types and builtin registry identity" {
    const source =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:stable-metadata",
        \\  "requiredCapabilities": ["clock"],
        \\  "exports": [{
        \\    "name": "fetch",
        \\    "effect": "read",
        \\    "returns": "string",
        \\    "failureSeverity": "none",
        \\    "contractExtractions": [{"category": "fetch_host"}]
        \\  }]
        \\}
    ;

    var manifest: ModuleMetadata.Manifest = try ModuleMetadata.parse(std.testing.allocator, source);
    defer manifest.deinit(std.testing.allocator);

    const capability: ModuleMetadata.CapabilityDeclaration = manifest.required_capabilities.items[0];
    const export_entry: ModuleMetadata.Export = manifest.exports.items[0];
    const rule: ModuleMetadata.ContractExtractionRule = export_entry.contract_extractions.items[0];
    const parse_error: ModuleMetadata.Error = error.InvalidJson;

    try std.testing.expectEqualStrings("zttp-ext:stable-metadata", manifest.specifier);
    try std.testing.expectEqual(module_binding.ModuleCapability.clock, capability.effective);
    try std.testing.expectEqualStrings("fetch", export_entry.name);
    try std.testing.expectEqual(module_binding.ContractCategory.fetch_host, rule.category);
    try std.testing.expectEqual(error.InvalidJson, parse_error);

    const stable_hash = ModuleMetadata.builtinRegistryHash();
    const internal_hash = module_manifest.registryHashFromBindings(&builtin_modules.all);
    try std.testing.expectEqualStrings(&internal_hash, &stable_hash);
}

/// A single author-facing repair proposal, as produced by the analyzer and
/// consumed by the expert agent and the canonicalizer.
pub const RepairIntent = repair_intent.RepairIntent;

/// Stable access to the repair validator registry and its independent
/// application check. The catalog is borrowed and read-only.
pub const RepairPolicy = struct {
    pub const Validator = repair_validator.Row;
    pub const Discharge = repair_validator.Discharge;

    pub fn validators() []const Validator {
        return &repair_validator.rows;
    }

    pub fn findValidator(intent: RepairIntent) ?Validator {
        return repair_validator.find(intent);
    }

    pub fn isGradable(intent: RepairIntent) bool {
        return repair_validator.gradable(intent);
    }

    pub fn validateApplication(
        intent: RepairIntent,
        original: []const u8,
        repaired: []const u8,
        line: u32,
    ) Discharge {
        return repair_validator.validateApplication(intent, original, repaired, line);
    }
};

test "stable RepairPolicy exposes validator catalog and discharge" {
    const validators = RepairPolicy.validators();
    try std.testing.expectEqual(repair_validator.rows.len, validators.len);
    try std.testing.expect(validators.len > 0);

    const first: RepairPolicy.Validator = validators[0];
    const found = RepairPolicy.findValidator(first.intent) orelse
        return error.TestExpectedRepairValidator;
    try std.testing.expectEqual(first.intent, found.intent);
    try std.testing.expectEqual(first.method, found.method);
    try std.testing.expectEqual(first.status, found.status);

    try std.testing.expect(RepairPolicy.isGradable(.replace_let_with_const));
    try std.testing.expect(!RepairPolicy.isGradable(.add_trailing_return));

    const accepted: RepairPolicy.Discharge = RepairPolicy.validateApplication(
        .replace_let_with_const,
        "let value = 1;\n",
        "const value = 1;\n",
        1,
    );
    try std.testing.expectEqual(RepairPolicy.Discharge.equivalent, accepted);

    const refused = RepairPolicy.validateApplication(
        .replace_let_with_const,
        "let value = 1;\n",
        "let value = 2;\n",
        1,
    );
    switch (refused) {
        .not_law_shape => |reason| try std.testing.expect(reason.len > 0),
        else => return error.TestExpectedRepairRefusal,
    }

    const unimplemented = RepairPolicy.validateApplication(
        .add_trailing_return,
        "function handler() {}\n",
        "function handler() { return null; }\n",
        1,
    );
    switch (unimplemented) {
        .no_validator => {},
        else => return error.TestExpectedMissingRepairValidator,
    }
}

/// Version information
pub const version = struct {
    pub const major = 0;
    pub const minor = 18;
    pub const patch = 0;
    pub const string = "0.18.0";
};

/// Create a new standalone context (not pooled)
pub fn createContext(allocator: std.mem.Allocator, gc_config: GCConfig) !*Context {
    const gc_state = try allocator.create(GC);
    errdefer allocator.destroy(gc_state);

    gc_state.* = try GC.init(allocator, gc_config);
    errdefer gc_state.deinit();

    // Initialize heap for size-class allocation and wire up to GC
    const heap_state = try allocator.create(heap.Heap);
    errdefer allocator.destroy(heap_state);
    heap_state.* = heap.Heap.init(allocator, .{});
    gc_state.setHeap(heap_state);

    return try Context.init(allocator, gc_state, .{});
}

/// Destroy a standalone context
pub fn destroyContext(ctx: *Context) void {
    const allocator = ctx.allocator;
    const gc_state = ctx.gc_state;
    const heap_state = gc_state.heap_ptr;
    ctx.deinit();
    gc_state.deinit();
    if (heap_state) |h| {
        h.deinit();
        allocator.destroy(h);
    }
    allocator.destroy(gc_state);
}

// Run all module tests
test {
    std.testing.refAllDecls(@This());
}

// The parity gate and modules/internal/compiler.zig are anchored in
// engine_root.zig, the module that owns them.

test "version" {
    try std.testing.expectEqualStrings("0.18.0", version.string);
}

test "ContractProof projects proof metadata through the stable surface" {
    var contract = handler_contract.emptyContract("handler.ts");

    try std.testing.expectEqual(ContractProof.Level.none, ContractProof.level(&contract));
    try std.testing.expectEqualStrings("structural", ContractProof.claimScope(&contract));

    contract.verification = .{
        .exhaustive_returns = true,
        .results_safe = true,
        .unreachable_code = false,
        .bytecode_verified = true,
    };
    contract.properties = .{
        .pure = true,
        .read_only = true,
        .stateless = true,
        .retry_safe = true,
        .deterministic = true,
        .has_egress = false,
    };

    try std.testing.expectEqual(ContractProof.Level.complete, ContractProof.level(&contract));
    try std.testing.expectEqualStrings("pure", ContractProof.claimScope(&contract));

    contract.env.dynamic = true;
    contract.properties.?.pure = false;

    try std.testing.expectEqual(ContractProof.Level.partial, ContractProof.level(&contract));
    try std.testing.expectEqualStrings("deterministic", ContractProof.claimScope(&contract));
}

test "create and destroy context" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();

    const allocator = test_arena.allocator();
    const ctx = try createContext(allocator, .{ .nursery_size = 4096 });
    defer destroyContext(ctx);

    try std.testing.expect(ctx.sp == 0);
}
