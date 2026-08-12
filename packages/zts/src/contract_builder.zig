//! `ContractBuilder` — walks the IR once and produces a HandlerContract.
//! Final extraction of the handler_contract.zig split. handler_contract.zig
//! re-exports `ContractBuilder` so `handler_contract.ContractBuilder` still
//! resolves for external callers (precompile.zig, ws_consistency.zig,
//! root.zig). The builder's tightly-coupled private helpers
//! (containsApiParam, responseVariantMatches, schemaSpecFromCandidate,
//! ParsedRouteKey, contentTypeFor, currentPolicyHashRaw, etc.) move with
//! it; only `extractHost` and `containsString` stay in handler_contract.zig
//! because they're referenced by other split files and external callers.

const std = @import("std");
const handler_contract = @import("zts-contracts").handler_contract;
const contract_types = @import("zts-contracts").contract_types;
const api_schema = @import("api_schema.zig");
const known_globals = @import("zts-base").known_globals;

/// Display form for a varying read, derived from the shared list so a new
/// entry cannot reach the proof card without a snippet.
fn snippetForVaryingRead(object_name: []const u8, property_name: []const u8) []const u8 {
    inline for (known_globals.varying_reads) |read| {
        if (std.mem.eql(u8, object_name, read.object) and
            std.mem.eql(u8, property_name, read.property))
        {
            return read.object ++ "." ++ read.property ++ "()";
        }
    }
    return "a varying global read";
}

const json_utils = @import("zts-base").json_utils;
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const atom_table = @import("zts-engine").atom_table;
const module_binding = @import("zts-engine").module_binding;
const builtin_modules = @import("zts-engine").builtin_modules;
const manifest_registry_mod = @import("manifest_registry.zig");
const module_facts_mod = @import("module_facts.zig");
const module_manifest = @import("zts-engine").module_manifest;
const bytecode = @import("zts-engine").bytecode;
const handler_analyzer = @import("zts-engine").handler_analyzer;
const type_checker_mod = @import("type_checker.zig");
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");
const rule_registry = @import("rule_registry.zig");
const spec_discharge = @import("spec_discharge.zig");
const intent_extractor = @import("intent_extractor.zig");
const saga_extractor = @import("saga_extractor.zig");
const fanout_extractor = @import("fanout_extractor.zig");
const effect_inference = @import("effect_inference.zig");
const function_specs = @import("function_specs.zig");
const JsParser = @import("zts-engine").parser.JsParser;

const Node = ir.Node;
const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;
const HandlerPattern = bytecode.HandlerPattern;
const PatternDispatchTable = bytecode.PatternDispatchTable;
const TypeChecker = type_checker_mod.TypeChecker;
const TypeEnv = type_env_mod.TypeEnv;

const HandlerContract = contract_types.HandlerContract;
const RouteInfo = contract_types.RouteInfo;
const SqlQueryInfo = contract_types.SqlQueryInfo;
const DurableWorkflow = contract_types.DurableWorkflow;
const DurableWorkflowNodeKind = contract_types.DurableWorkflowNodeKind;
const ApiSchemaInfo = contract_types.ApiSchemaInfo;
const ApiParamInfo = contract_types.ApiParamInfo;
const SchemaSpec = contract_types.SchemaSpec;
const ApiBodyInfo = contract_types.ApiBodyInfo;
const ApiResponseInfo = contract_types.ApiResponseInfo;
const ApiRouteInfo = contract_types.ApiRouteInfo;
const VerificationInfo = contract_types.VerificationInfo;
const AotInfo = contract_types.AotInfo;
const FaultCoverageInfo = contract_types.FaultCoverageInfo;
const HandlerProperties = contract_types.HandlerProperties;
const RateLimitInfo = contract_types.RateLimitInfo;
const ServiceCallInfo = contract_types.ServiceCallInfo;
const DurableWorkflowProofLevel = contract_types.DurableWorkflowProofLevel;
const computeCapabilityMatrix = @import("zts-engine").builtin_modules.computeCapabilityMatrix;

const containsString = json_utils.containsString;
const writeJsonString = json_utils.writeJsonString;
const extractHost = handler_contract.extractHost;

fn currentPolicyHashRaw() [32]u8 {
    const hex = rule_registry.policyHash();
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, &hex) catch unreachable;
    return out;
}

/// Builds a HandlerContract by walking the IR once.
/// All strings stored in the contract are duped via the allocator, making
/// the contract safe to use after the parser and atom table are freed.
pub const ContractBuilder = struct {
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*atom_table.AtomTable,
    type_env: ?*const TypeEnv,
    type_checker: ?*const TypeChecker,
    /// Partner virtual-module manifests registered for this compile session.
    /// Borrowed; the registry must outlive the builder.
    manifest_registry: ?*const manifest_registry_mod.Registry = null,

    /// The import and binding index this builder owns, used when no caller
    /// injected one. Built at the start of `build` and not mutated after. The
    /// contract gets copies, not the originals, so the index stays readable
    /// after `build` returns.
    owned_facts: module_facts_mod.ModuleFacts,
    /// Injected index for this compile. When set, `build` reads it and never
    /// builds `owned_facts`, so a compile that already has an index does not
    /// pay for a second identical one. Borrowed; must outlive the builder.
    injected_facts: ?*const module_facts_mod.ModuleFacts = null,

    // Collected data (all strings are duped/owned)
    env_literals: std.ArrayList([]const u8),
    env_dynamic: bool,
    egress_hosts: std.ArrayList([]const u8),
    egress_urls: std.ArrayList([]const u8),
    egress_dynamic: bool,
    service_calls: std.ArrayList(ServiceCallInfo),
    workflow_calls: std.ArrayList(contract_types.WorkflowCallInfo),
    affordances: std.ArrayList(contract_types.EmittedAffordance),
    affordances_dynamic: bool,
    cache_namespaces: std.ArrayList([]const u8),
    cache_dynamic: bool,
    /// Keys passed to `zttp:ratelimit`'s `rateCheck`. The module declares the
    /// `rate_limit_key` extraction on argument 0, and this is the bucket that
    /// extraction writes to.
    rate_limit_keys: std.ArrayList([]const u8) = .empty,
    rate_limit_key_dynamic: bool = false,
    sql_queries: std.ArrayList(SqlQueryInfo),
    sql_dynamic: bool,
    scope_used: bool,
    scope_names: std.ArrayList([]const u8),
    scope_dynamic: bool,
    scope_max_depth: u32 = 0,
    durable_used: bool,
    durable_key_literals: std.ArrayList([]const u8),
    durable_key_dynamic: bool,
    durable_step_names: std.ArrayList([]const u8),
    durable_step_dynamic: bool = false,
    durable_timers: bool = false,
    durable_signal_names: std.ArrayList([]const u8) = .empty,
    durable_signal_dynamic: bool = false,
    durable_producer_key_literals: std.ArrayList([]const u8) = .empty,
    durable_producer_key_dynamic: bool = false,
    durable_workflow: DurableWorkflow = .{},
    durable_run_count: u32 = 0,
    api_schemas: std.ArrayList(ApiSchemaInfo),
    api_request_schema_refs: std.ArrayList([]const u8),
    api_request_schema_dynamic: bool,
    api_routes: std.ArrayList(ApiRouteInfo),
    api_bearer_auth: bool,
    api_jwt_auth: bool,
    api_schemas_dynamic: bool,
    api_routes_dynamic: bool,

    // Partner extension tracking: the per-specifier extracted facts. The
    // bindings themselves live in `facts.extension_bindings`.
    extensions: std.StringHashMapUnmanaged(contract_types.ExtensionContract) = .empty,

    // Effect tracking
    has_nondeterministic_builtin: bool = false,
    /// First call site that broke determinism. Captured for the live-reload
    /// HUD's "Why" line. Borrowed snippet (static string).
    nondeterministic_cause: ?contract_types.PropertyCause = null,

    const EffectSummary = struct {
        has_any_call: bool = false,
        io: module_binding.EffectClass = .none,
        has_bare_write: bool = false,
        has_cache_read: bool = false,
        has_egress: bool = false,

        fn includeCall(self: *EffectSummary, effect: module_binding.EffectClass, is_durable: bool) void {
            switch (effect) {
                .write => {
                    self.io = .write;
                    if (!is_durable) self.has_bare_write = true;
                },
                .read => {
                    if (self.io == .none) self.io = .read;
                },
                .none => {},
            }
        }

        fn includeEgress(self: *EffectSummary) void {
            // fetchSync is a conservative bare write because the HTTP method
            // is not known during contract extraction.
            self.has_egress = true;
            self.has_any_call = true;
            self.io = .write;
            self.has_bare_write = true;
        }
    };

    // The binding types moved to module_facts.zig with the walk that builds
    // them. Aliased here so existing references keep resolving.
    const GenericBinding = module_facts_mod.GenericBinding;
    const ExtensionBinding = module_facts_mod.ExtensionBinding;

    pub fn init(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        atoms: ?*atom_table.AtomTable,
        type_env: ?*const TypeEnv,
        type_checker: ?*const TypeChecker,
    ) ContractBuilder {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .type_env = type_env,
            .type_checker = type_checker,
            // An empty index. `build` replaces it with the real one unless a
            // caller injected one; the property helpers that tests call
            // directly read an empty index rather than requiring a parse.
            .owned_facts = .{ .allocator = allocator },
            .env_literals = .empty,
            .env_dynamic = false,
            .egress_hosts = .empty,
            .egress_urls = .empty,
            .egress_dynamic = false,
            .service_calls = .empty,
            .workflow_calls = .empty,
            .affordances = .empty,
            .affordances_dynamic = false,
            .cache_namespaces = .empty,
            .cache_dynamic = false,
            .sql_queries = .empty,
            .sql_dynamic = false,
            .scope_used = false,
            .scope_names = .empty,
            .scope_dynamic = false,
            .durable_used = false,
            .durable_key_literals = .empty,
            .durable_key_dynamic = false,
            .durable_step_names = .empty,
            .api_schemas = .empty,
            .api_request_schema_refs = .empty,
            .api_request_schema_dynamic = false,
            .api_routes = .empty,
            .api_bearer_auth = false,
            .api_jwt_auth = false,
            .api_schemas_dynamic = false,
            .api_routes_dynamic = false,
        };
    }

    /// Free all builder-owned resources. Safe to call whether or not build()
    /// was called: if build() moved the lists into a HandlerContract, the
    /// items slices are empty and these loops are no-ops.
    /// The index to read: the injected one, else the owned one. Always valid,
    /// because `owned_facts` starts empty rather than undefined.
    fn factsRef(self: *const ContractBuilder) *const module_facts_mod.ModuleFacts {
        return self.injected_facts orelse &self.owned_facts;
    }

    /// Build the owned index over the current IR, or do nothing when a caller
    /// injected one. Called once from `build`; the tests that used to call
    /// `scanImports` directly call this instead, so both go through one path.
    fn buildFacts(self: *ContractBuilder) !void {
        if (self.injected_facts != null) return;
        // Build into a temporary and swap, so a failure here leaves the
        // existing (empty) index intact rather than dangling for deinit.
        const built = try module_facts_mod.ModuleFacts.build(
            self.allocator,
            self.ir_view,
            self.atoms,
            self.manifest_registry,
        );
        self.owned_facts.deinit();
        self.owned_facts = built;
    }

    pub fn deinit(self: *ContractBuilder) void {
        self.owned_facts.deinit();
        var ext_it = self.extensions.iterator();
        while (ext_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.extensions.deinit(self.allocator);
        for (self.env_literals.items) |s| self.allocator.free(s);
        self.env_literals.deinit(self.allocator);
        for (self.egress_hosts.items) |s| self.allocator.free(s);
        self.egress_hosts.deinit(self.allocator);
        for (self.egress_urls.items) |s| self.allocator.free(s);
        self.egress_urls.deinit(self.allocator);
        for (self.service_calls.items) |*call| call.deinit(self.allocator);
        self.service_calls.deinit(self.allocator);
        for (self.workflow_calls.items) |*call| call.deinit(self.allocator);
        self.workflow_calls.deinit(self.allocator);
        for (self.affordances.items) |*aff| aff.deinit(self.allocator);
        self.affordances.deinit(self.allocator);
        for (self.cache_namespaces.items) |s| self.allocator.free(s);
        self.cache_namespaces.deinit(self.allocator);
        for (self.rate_limit_keys.items) |s| self.allocator.free(s);
        self.rate_limit_keys.deinit(self.allocator);
        for (self.sql_queries.items) |*query| query.deinit(self.allocator);
        self.sql_queries.deinit(self.allocator);
        for (self.scope_names.items) |s| self.allocator.free(s);
        self.scope_names.deinit(self.allocator);
        for (self.durable_key_literals.items) |s| self.allocator.free(s);
        self.durable_key_literals.deinit(self.allocator);
        for (self.durable_step_names.items) |s| self.allocator.free(s);
        self.durable_step_names.deinit(self.allocator);
        for (self.durable_signal_names.items) |s| self.allocator.free(s);
        self.durable_signal_names.deinit(self.allocator);
        for (self.durable_producer_key_literals.items) |s| self.allocator.free(s);
        self.durable_producer_key_literals.deinit(self.allocator);
        self.durable_workflow.deinit(self.allocator);
        for (self.api_schemas.items) |schema| {
            self.allocator.free(schema.name);
            self.allocator.free(schema.schema_json);
        }
        self.api_schemas.deinit(self.allocator);
        for (self.api_request_schema_refs.items) |schema_ref| {
            self.allocator.free(schema_ref);
        }
        self.api_request_schema_refs.deinit(self.allocator);
        for (self.api_routes.items) |*route| {
            route.deinit(self.allocator);
        }
        self.api_routes.deinit(self.allocator);
    }

    /// Build the contract from the IR. Single-pass walk over all nodes.
    /// The returned HandlerContract owns all its string data.
    pub fn build(
        self: *ContractBuilder,
        handler_path: []const u8,
        handler_loc: ?ir.SourceLocation,
        handler_fn: ?NodeIndex,
        root: NodeIndex,
        dispatch: ?*const PatternDispatchTable,
        default_response: bool,
        verification: ?VerificationInfo,
    ) !HandlerContract {
        if (self.type_checker) |tc| try tc.ensureHealthy();
        // Phase 1: Build the import index. Modules, imported names, and the
        // slot-keyed bindings the call-site scan resolves against. Built before
        // the effect analyzer so that analyzer can share it instead of building
        // an identical private one; the index depends only on the IR, the atom
        // table, and the registry, so it does not care that effects has not run.
        try self.buildFacts();

        // Proof-carrying functions: infer per-function effect rows across the
        // call graph. The handler's composed row tightens computeProperties;
        // the full table drives capsule discharge after the contract is built.
        var effects = effect_inference.Analyzer.initWithManifestRegistry(
            self.allocator,
            self.ir_view,
            self.atoms,
            self.manifest_registry,
        );
        // `self` is a stable address for the duration of `build`, so the borrow
        // outlives the analyzer.
        effects.facts = self.factsRef();
        // Lets a call through a function-typed parameter contribute that type's
        // declared ceiling instead of defeating the row (D2 section 4, I3).
        effects.type_env = self.type_env;
        defer effects.deinit();
        try effects.analyze(root);

        // Phase 2: Scan all call sites for env/fetchSync/cache usage
        try self.scanCallSites();
        if (self.type_checker) |tc| try tc.ensureHealthy();

        // Author-declared intent assertions. Extraction is strict and
        // fails to `intent.dynamic = true` on any non-literal form rather
        // than degrading, preserving the deterministic-extraction line.
        const intent_value = try self.extractIntentAssertions();

        // Every saga([...]) call site, for ZTS510's compensation-coverage
        // proof (system_linker.zig). Same strict-literal-or-dynamic
        // discipline as intent extraction above.
        var saga_calls = try self.extractSagaCalls();
        errdefer {
            for (saga_calls.items) |*s| s.deinit(self.allocator);
            saga_calls.deinit(self.allocator);
        }

        // Every fanout([...]) descriptor, appended into self.workflow_calls
        // alongside call()'s own extractions from scanCallSites above.
        try self.extractFanoutCalls();

        if (handler_fn) |hf| {
            try self.extractScopeUsage(hf);
            try self.extractDurableWorkflow(handler_path, hf);
        }

        // Phase 3: Compute handler effect properties.
        const properties = try self.computeProperties(effects.lookup("handler"), handler_fn);

        // Phase 3b: Detect rate limiting. The namespace is duped because
        // `rate_limit_keys` stays with the builder, unlike `cache_namespaces`,
        // which the contract takes ownership of below.
        const rate_limit_namespace: ?[]const u8 = if (self.rate_limit_keys.items.len > 0)
            try self.allocator.dupe(u8, self.rate_limit_keys.items[0])
        else
            null;
        errdefer if (rate_limit_namespace) |ns| self.allocator.free(ns);
        const rate_limiting = self.detectRateLimiting(rate_limit_namespace);

        // Build routes from dispatch table
        var routes: std.ArrayList(RouteInfo) = .empty;
        errdefer {
            for (routes.items) |r| self.allocator.free(r.pattern);
            routes.deinit(self.allocator);
        }
        if (dispatch) |d| {
            for (d.patterns) |pattern| {
                const is_aot = switch (pattern.pattern_type) {
                    .exact => true,
                    .prefix => pattern.response_template_prefix != null,
                    else => false,
                };
                if (!is_aot) continue;

                const pattern_dupe = try self.allocator.dupe(u8, pattern.url_bytes);
                errdefer self.allocator.free(pattern_dupe);

                try routes.append(self.allocator, .{
                    .pattern = pattern_dupe,
                    .route_type = switch (pattern.pattern_type) {
                        .exact => "exact",
                        .prefix => "prefix",
                        else => "unknown",
                    },
                    .field = switch (pattern.url_atom) {
                        .path => "path",
                        else => "url",
                    },
                    .status = pattern.status,
                    .content_type = contentTypeFor(pattern.content_type_idx),
                    .aot = is_aot,
                });
            }
        }

        // Compute AOT info
        var aot_info: ?AotInfo = null;
        if (dispatch) |d| {
            var pattern_count: u32 = 0;
            for (d.patterns) |pattern| {
                switch (pattern.pattern_type) {
                    .exact => pattern_count += 1,
                    .prefix => {
                        if (pattern.response_template_prefix != null) pattern_count += 1;
                    },
                    // exhaustive: PatternType has three members and the third is
                    // `.dynamic`, which the enum itself documents as "not
                    // optimizable". Leaving it out of the fast-path count is the
                    // point of the count.
                    else => {},
                }
            }
            aot_info = .{
                .pattern_count = pattern_count,
                .has_default = default_response,
            };
        }

        // The three fallible values the contract literal needs are built
        // before it, each with its own unwind. Inside a struct literal there is
        // no unwind: a later field that fails drops every earlier field's
        // allocation, which the failure sweep reported as a leak.
        var handler_path_copy: []const u8 = try self.allocator.dupe(u8, handler_path);
        errdefer if (handler_path_copy.len != 0) self.allocator.free(handler_path_copy);

        // Copies, not the index's own lists. Moving them would empty the
        // index, and every reader after this point (detectRateLimiting,
        // computeGlobalEffectSummary, and the six analyzers that adopt the
        // index) would see a handler with no imports.
        var modules_copy = try self.factsRef().cloneModules(self.allocator);
        errdefer {
            for (modules_copy.items) |m| self.allocator.free(m);
            modules_copy.deinit(self.allocator);
        }

        var functions_copy = try self.factsRef().cloneFunctions(self.allocator);
        errdefer {
            for (functions_copy.items) |*entry| {
                self.allocator.free(entry.module);
                for (entry.names.items) |n| self.allocator.free(n);
                entry.names.deinit(self.allocator);
            }
            functions_copy.deinit(self.allocator);
        }

        var contract = HandlerContract{
            .handler = .{
                .path = handler_path_copy,
                .line = if (handler_loc) |loc| loc.line else 0,
                .column = if (handler_loc) |loc| loc.column else 0,
            },
            .routes = routes,
            .modules = modules_copy,
            .functions = functions_copy,
            .env = .{
                .literal = self.env_literals,
                .dynamic = self.env_dynamic,
            },
            .egress = .{
                .hosts = self.egress_hosts,
                .urls = self.egress_urls,
                .dynamic = self.egress_dynamic,
            },
            .service_calls = self.service_calls,
            .workflow_calls = self.workflow_calls,
            .affordances = self.affordances,
            .affordances_dynamic = self.affordances_dynamic,
            .cache = .{
                .namespaces = self.cache_namespaces,
                .dynamic = self.cache_dynamic,
            },
            .sql = .{
                .backend = "sqlite",
                .queries = self.sql_queries,
                .dynamic = self.sql_dynamic,
            },
            .durable = .{
                .used = self.durable_used,
                .keys = .{
                    .literal = self.durable_key_literals,
                    .dynamic = self.durable_key_dynamic,
                },
                .steps = self.durable_step_names,
                .timers = self.durable_timers,
                .signals = .{
                    .literal = self.durable_signal_names,
                    .dynamic = self.durable_signal_dynamic,
                },
                .producer_keys = .{
                    .literal = self.durable_producer_key_literals,
                    .dynamic = self.durable_producer_key_dynamic,
                },
                .workflow = self.durable_workflow,
            },
            .scope = .{
                .used = self.scope_used,
                .names = self.scope_names,
                .dynamic = self.scope_dynamic,
                .max_depth = self.scope_max_depth,
            },
            .api = .{
                .schemas = self.api_schemas,
                .requests = .{
                    .schema_refs = self.api_request_schema_refs,
                    .dynamic = self.api_request_schema_dynamic,
                },
                .auth = .{
                    .bearer = self.api_bearer_auth,
                    .jwt = self.api_jwt_auth,
                },
                .routes = self.api_routes,
                .schemas_dynamic = self.api_schemas_dynamic,
                .routes_dynamic = self.api_routes_dynamic,
            },
            .verification = verification,
            .aot = aot_info,
            .rate_limiting = rate_limiting,
            .owned_rate_limit_namespace = rate_limit_namespace,
            .properties = properties,
            .intent = intent_value,
            .sagas = saga_calls,
            .property_provenance = .{
                .deterministic = self.nondeterministic_cause,
            },
            .extensions = self.extensions,
        };

        // Ownership of the moved lists transfers here, at the literal, not at
        // the end of the function. Clearing them now is what lets the contract
        // own its unwind: `deinit()` below frees each list exactly once, and
        // the builder's own `deinit`, plus the two local errdefers above, find
        // them empty. Emptying the locals is not cosmetic - an errdefer cannot
        // be disarmed, so `routes` and `saga_calls` would otherwise be freed
        // twice on the failure path, once by the contract and once by their own
        // unwind.
        routes = .empty;
        saga_calls = .empty;
        handler_path_copy = &.{};
        modules_copy = .empty;
        functions_copy = .empty;
        self.env_literals = .empty;
        self.egress_hosts = .empty;
        self.egress_urls = .empty;
        self.service_calls = .empty;
        self.workflow_calls = .empty;
        self.affordances = .empty;
        self.cache_namespaces = .empty;
        self.sql_queries = .empty;
        self.scope_names = .empty;
        self.durable_key_literals = .empty;
        self.durable_step_names = .empty;
        self.durable_signal_names = .empty;
        self.durable_producer_key_literals = .empty;
        self.durable_workflow = .{};
        self.api_schemas = .empty;
        self.api_request_schema_refs = .empty;
        self.api_routes = .empty;
        self.extensions = .empty;
        // Every phase below can fail, and each one adds to the contract. Before
        // this the partially built contract was simply dropped.
        errdefer contract.deinit(self.allocator);

        contract.capabilities = computeCapabilityMatrix(contract.modules.items);
        contract.policy_hash = currentPolicyHashRaw();

        // Phase 4: Resolve active specs. An explicit handler Spec<...>
        // narrows the set; otherwise every supported v1 spec is active.
        // Downstream surfaces read declared_specs as the mandatory active
        // set when discharging ZTS500/ZTS501/ZTS502.
        try self.populateDeclaredSpecs(&contract, handler_loc);

        // Phase 4b: Proof-carrying functions. Discharge each helper's
        // `Proof<...>` capsule, append helper ZTS500/ZTS502 and caller-demand
        // ZTS606 to spec_diagnostics, and project a CapsuleSummary per helper.
        try self.dischargeFunctionCapsules(&contract, &effects);

        // Phase 4c: handler capability budget. Discharge the handler's
        // `Effects<...>` budget against its inferred capability row and
        // attribute every over-budget capability (ZTS506 / ZTS607).
        try self.dischargeCapabilityBudget(&contract, &effects, handler_loc);
        // After the budget: the remaining-budget figure each hole reports is
        // the declared budget minus what the handler already spends.
        try self.collectHoles(&contract, &effects);

        // Phase 4d: unconditional structural check (ZTS509) - workflow.call/
        // saga/fanout/follow nested inside a durable.step() callback. Unlike
        // 4b/4c, this does not depend on any declared Spec<...>/Effects<...>:
        // the durability loss is silent and real regardless of what the
        // function claims about itself.
        try self.emitNestedWorkflowCallDiagnostics(&contract, &effects);

        // Phase 4e: unconditional structural check (ZTS510) - a statically-
        // analyzable saga([...]) with a non-last step missing `compensate`.
        // Single-contract and purely structural (derived entirely from
        // `contract.sagas`, already extracted above), so - unlike the
        // affordance-link proofs in system_linker.zig - it needs no
        // cross-handler resolution and belongs here, not there.
        try self.emitSagaCompensationDiagnostics(&contract);

        return contract;
    }

    // -----------------------------------------------------------------
    // Phase 4: Author-declared spec extraction
    // -----------------------------------------------------------------

    /// Populate `contract.declared_specs` with the active handler spec set.
    /// An explicit `Response & Spec<...>` (or alias-hop equivalent) narrows
    /// the active set to the declared names. When the handler declares no
    /// `Spec<...>`, every supported v1 spec is active by default.
    fn populateDeclaredSpecs(
        self: *ContractBuilder,
        contract: *HandlerContract,
        handler_loc: ?ir.SourceLocation,
    ) !void {
        var raw_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer raw_names.deinit(self.allocator);

        if (self.type_env) |env| {
            if (handler_loc) |loc| {
                if (loc.line != 0) {
                    if (env.getFnSigByLoc(loc.line)) |sig| {
                        if (sig.return_type != type_pool_mod.null_type_idx) {
                            // A payload this cannot read leaves `raw_names`
                            // empty, which selects the full v1 set below -
                            // the widest, strictest reading, so there is no
                            // fail-open to report here.
                            _ = try env.extractSpecMembers(sig.return_type, &raw_names);
                        }
                    }
                }
            }
        }

        // Owned string copies; sorted for stable contract.json output and
        // de-duplicated to keep ledger entries idempotent across saves.
        var owned: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (owned.items) |s| self.allocator.free(s);
            owned.deinit(self.allocator);
        }

        const declared_specs_implicit = raw_names.items.len == 0;
        const active_names: []const []const u8 = if (declared_specs_implicit)
            &spec_discharge.v1_spec_names
        else
            raw_names.items;

        outer: for (active_names) |raw| {
            for (owned.items) |existing| {
                if (std.mem.eql(u8, existing, raw)) continue :outer;
            }
            const dup = try self.allocator.dupe(u8, raw);
            errdefer self.allocator.free(dup);
            try owned.append(self.allocator, dup);
        }

        std.mem.sort([]const u8, owned.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);

        contract.declared_specs = owned;
        contract.declared_specs_implicit = declared_specs_implicit;
        // The contract owns the list from here. Emptying the local disarms the
        // errdefer above, which would otherwise free it a second time when the
        // discharge below fails and `build`'s own unwind deinits the contract.
        owned = .empty;

        // Discharge: produce ZTS500 / ZTS501 / ZTS502 diagnostics into
        // contract.spec_diagnostics. Downstream consumers (zts check,
        // proof HUD, ledger) read from there. The verifier does not see
        // these because it runs before the contract is built.
        contract.spec_diagnostics = try spec_discharge.dischargeSpecs(
            self.allocator,
            contract.declared_specs.items,
            contract.properties,
            contract.modules.items,
            declared_specs_implicit,
        );
    }

    /// Proof-carrying functions: discharge every helper's `Proof<...>`
    /// capsule against the facts effect inference proved, append the
    /// resulting diagnostics to `contract.spec_diagnostics`, and project a
    /// `CapsuleSummary` per helper into `contract.function_capsules`.
    ///
    /// Two diagnostic kinds are produced. A helper that declared a capsule
    /// property it does not satisfy gets ZTS500 / ZTS502 (its own failure).
    /// A helper that breaks a capsule property the handler's `Spec` demands,
    /// while carrying no capsule declaring that property, gets ZTS606: the
    /// handler's proof cannot compose across that call boundary.
    fn dischargeFunctionCapsules(
        self: *ContractBuilder,
        contract: *HandlerContract,
        analyzer: *const effect_inference.Analyzer,
    ) !void {
        var table = try function_specs.discharge(
            self.allocator,
            analyzer,
            self.type_env,
            self.ir_view,
        );
        defer table.deinit(self.allocator);

        // Capsule properties the handler's Spec demands: the intersection of
        // the declared spec set with the v1 capsule property set.
        var handler_demands = std.EnumSet(spec_discharge.CapsuleProperty).initEmpty();
        for (contract.declared_specs.items) |name| {
            if (spec_discharge.CapsuleProperty.fromName(name)) |p| handler_demands.insert(p);
        }

        const reachable = try handlerReachability(self.allocator, analyzer);
        defer if (reachable) |r| self.allocator.free(r);

        for (table.capsules.items) |*cap| {
            const reachable_from_handler = helperReachable(analyzer, reachable, cap.name);
            // The helper's own capsule discharge (ZTS500 / ZTS502),
            // attributed to the helper.
            for (cap.diagnostics.items) |d| {
                var copy = try d.clone(self.allocator);
                errdefer copy.deinit(self.allocator);
                if (copy.function == null) copy.function = try self.allocator.dupe(u8, cap.name);
                try contract.spec_diagnostics.append(self.allocator, copy);
            }

            // The helper's own `Effects<...>` ceiling discharge
            // (ZTS503 / ZTS504 / ZTS505), attributed to the helper.
            for (cap.effect_diagnostics.items) |d| {
                var copy = try d.clone(self.allocator);
                errdefer copy.deinit(self.allocator);
                if (copy.function == null) copy.function = try self.allocator.dupe(u8, cap.name);
                try contract.spec_diagnostics.append(self.allocator, copy);
            }

            // ZTS606: the handler demands a capsule property this helper
            // breaks, and the helper carries no capsule declaring it. A
            // helper that declared the property already owns a ZTS500, so
            // skipping declared properties avoids double-reporting.
            if (reachable_from_handler) {
                inline for (.{
                    spec_discharge.CapsuleProperty.total,
                    spec_discharge.CapsuleProperty.pure,
                    spec_discharge.CapsuleProperty.read_only,
                    spec_discharge.CapsuleProperty.deterministic,
                }) |prop| {
                    const pname = @tagName(prop);
                    if (handler_demands.contains(prop) and
                        !cap.proven.holds(prop) and
                        !containsString(cap.declared.items, pname))
                    {
                        try contract.spec_diagnostics.append(
                            self.allocator,
                            try makeMissingCapsule(self.allocator, pname, cap.name),
                        );
                    }
                }
            }

            var summary = contract_types.CapsuleSummary{
                .function = try self.allocator.dupe(u8, cap.name),
                .line = cap.line,
                .proven_total = cap.proven.total,
                .proven_pure = cap.proven.pure,
                .proven_read_only = cap.proven.read_only,
                .proven_deterministic = cap.proven.deterministic,
                .discharged = cap.discharged(),
                .exported = cap.exported,
                .handler_reachable = reachable_from_handler,
            };
            errdefer summary.deinit(self.allocator);
            for (cap.declared.items) |name| {
                try summary.declared.append(self.allocator, try self.allocator.dupe(u8, name));
            }
            try contract.function_capsules.append(self.allocator, summary);

            var effect_summary = contract_types.EffectCapsuleSummary{
                .function = try self.allocator.dupe(u8, cap.name),
                .line = cap.line,
                .discharged = cap.effectDischarged(),
                .exported = cap.exported,
                .handler_reachable = reachable_from_handler,
            };
            errdefer effect_summary.deinit(self.allocator);
            for (cap.effect_declared.items) |name| {
                try effect_summary.declared.append(self.allocator, try self.allocator.dupe(u8, name));
            }
            var caps_it = cap.inferred_caps.iterator();
            while (caps_it.next()) |c| {
                try effect_summary.inferred.append(
                    self.allocator,
                    try self.allocator.dupe(u8, @tagName(c)),
                );
            }
            try contract.function_effect_capsules.append(self.allocator, effect_summary);
        }
    }

    /// Collect every `hole()` call site, with the type the expression must
    /// produce and the authority still available to spend filling it.
    ///
    /// A hole is the compiler describing a frame with one expression missing.
    /// What an agent needs at that point is the shape of the gap, not the whole
    /// file - so this publishes the gap rather than leaving it to be
    /// rediscovered by re-running the compiler.
    fn collectHoles(
        self: *ContractBuilder,
        contract: *HandlerContract,
        analyzer: *const effect_inference.Analyzer,
    ) !void {
        // Remaining budget: what the declared budget still allows that the
        // handler's inferred row has not already spent. A property of the
        // handler, not of an individual hole, so it is computed once.
        var remaining = effect_inference.CapabilitySet.initEmpty();
        const budget_declared = contract.capability_budget.len > 0;
        if (budget_declared) {
            for (contract.capability_budget.slice()) |c| remaining.insert(c);
            const functions = analyzer.all();
            if (findFunctionIndex(functions, "handler")) |h| {
                var spent = functions[h].row.capabilities.iterator();
                while (spent.next()) |c| remaining.remove(c);
            }
        }

        var idx: NodeIndex = 0;
        while (idx < self.ir_view.nodeCount()) : (idx += 1) {
            if (self.ir_view.getTag(idx) != .call) continue;
            const call = self.ir_view.getCall(idx) orelse continue;
            if (!self.isHoleCallee(call.callee)) continue;

            const owner = self.enclosingFunctionName(analyzer, idx);
            // The call node is located at `(`. The fill tool replaces the full
            // `hole()` expression and therefore needs the callee's start.
            const loc = self.ir_view.getLoc(call.callee) orelse ir.SourceLocation{ .line = 0, .column = 0, .offset = 0 };

            var type_buf: [256]u8 = undefined;
            const expected = self.expectedTypeForHole(owner, &type_buf);

            var summary = contract_types.HoleSummary{
                .function = try self.allocator.dupe(u8, owner),
                .line = loc.line,
                .column = loc.column,
                .expected_type = try self.allocator.dupe(u8, expected),
                .budget_declared = budget_declared,
            };
            errdefer summary.deinit(self.allocator);
            var it = remaining.iterator();
            while (it.next()) |c| {
                try summary.remaining_budget.append(
                    self.allocator,
                    try self.allocator.dupe(u8, @tagName(c)),
                );
            }

            // What filling this hole has to satisfy. Spec discharge and capsule
            // discharge both ran before this phase, so the failures are already
            // in `contract.spec_diagnostics` and only need attributing: a
            // handler-level diagnostic carries no function name, and a capsule
            // one names the helper it belongs to.
            for (contract.spec_diagnostics.items) |d| {
                // Both kinds are obligations on an expression filling this
                // hole. ZTS500 is the property the function claims and does not
                // hold; ZTS606 is the property the handler demands that this
                // helper breaks without a capsule to declare it. The capability
                // dimension is `remaining_budget`, not these.
                switch (d.kind) {
                    .not_discharged, .missing_capsule => {},
                    // exhaustive: the rest are not obligations on an
                    // expression. `unknown_name` and
                    // `effect_unknown_capability` say the author wrote a name
                    // the v1 set does not have, which no fill can satisfy;
                    // `incompatible_with_import` is settled by the import list
                    // rather than by this expression; the `effect_*` kinds and
                    // `effect_row_lower_bound` are the capability dimension,
                    // which this hole reports as `remaining_budget`; and the
                    // structural kinds (workflow-call-in-step,
                    // saga-compensation) are about program shape elsewhere.
                    // Dropping them here loses nothing: every one is still
                    // reported in `spec_diagnostics`, which this projects from.
                    else => continue,
                }
                const belongs = if (d.function) |f|
                    std.mem.eql(u8, f, owner)
                else
                    std.mem.eql(u8, owner, "handler");
                if (!belongs) continue;
                // One diagnostic can name several properties: the implicit
                // default profile reports every property it demands and the
                // handler does not hold as one comma-joined `spec_name`, which
                // is how the HUD wants to render it. This is a machine surface,
                // so it carries them apart.
                var parts = std.mem.splitSequence(u8, d.spec_name, ", ");
                while (parts.next()) |part| {
                    if (part.len == 0) continue;
                    try summary.undischarged.append(
                        self.allocator,
                        try self.allocator.dupe(u8, part),
                    );
                }
            }

            try self.collectHoleScope(&summary, analyzer, idx);

            try contract.holes.append(self.allocator, summary);
        }
    }

    fn isHoleCallee(self: *const ContractBuilder, callee: NodeIndex) bool {
        if (self.ir_view.getTag(callee) != .identifier) return false;
        const binding = self.ir_view.getBinding(callee) orelse return false;
        const name = self.resolveAtomName(binding.name_atom) orelse return false;
        return std.mem.eql(u8, name, "hole");
    }

    /// Which analyzed function contains this node. Falls back to the top level
    /// rather than guessing when no body claims it.
    fn enclosingFunctionName(
        self: *ContractBuilder,
        analyzer: *const effect_inference.Analyzer,
        node: NodeIndex,
    ) []const u8 {
        for (analyzer.all()) |fe| {
            if (self.subtreeContains(fe.body_node, node)) return fe.name;
        }
        return "<top-level>";
    }

    /// The type the hole must produce. The enclosing function's declared return
    /// type is the one context the compiler already has in hand; anything else
    /// reports "unknown" rather than guessing, because a wrong expected type is
    /// worse for an agent than an honest absence.
    /// Bindings an expression filling this hole can be built from: the
    /// enclosing function's parameters, then every declaration in that function
    /// the hole comes after.
    ///
    /// Ordering is by node index rather than by scope walk. The parser builds
    /// the IR as it reads, so a declaration the hole comes after carries the
    /// lower index and one written below it does not, which is what keeps a
    /// binding that is not initialized yet off the list. Block structure is not
    /// modelled: a binding from a sibling block that already closed is still
    /// listed, so this over-offers rather than under-offers.
    fn collectHoleScope(
        self: *ContractBuilder,
        summary: *contract_types.HoleSummary,
        analyzer: *const effect_inference.Analyzer,
        hole_node: NodeIndex,
    ) !void {
        const owner: *const effect_inference.FunctionEffect = blk: {
            for (analyzer.all()) |*fe| {
                if (self.subtreeContains(fe.body_node, hole_node)) break :blk fe;
            }
            return;
        };

        // `decl_node` is the declaration, which for `function f() {}` wraps the
        // function expression rather than being it.
        const fn_node: NodeIndex = if (self.ir_view.getTag(owner.decl_node) == .function_expr or
            self.ir_view.getTag(owner.decl_node) == .arrow_function)
            owner.decl_node
        else if (self.ir_view.getVarDecl(owner.decl_node)) |vd| vd.init else owner.decl_node;

        if (self.ir_view.getFunction(fn_node)) |func| {
            for (0..func.params_count) |i| {
                const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
                const pb = self.ir_view.paramBinding(param_idx) orelse continue;
                const name = self.resolveAtomName(pb.name_atom) orelse continue;
                try self.appendScopeBinding(summary, name, pb.scope_id, pb.name_atom);
            }
        }

        var idx: NodeIndex = 0;
        while (idx < hole_node) : (idx += 1) {
            if (self.ir_view.getTag(idx) != .var_decl) continue;
            const vd = self.ir_view.getVarDecl(idx) orelse continue;
            // Destructuring binds names this walk cannot name: the binding on
            // the declaration is a placeholder for the whole pattern.
            if (vd.pattern != null_node) continue;
            if (!self.subtreeContains(owner.body_node, idx)) continue;
            const name = self.resolveAtomName(vd.binding.name_atom) orelse continue;
            try self.appendScopeBinding(summary, name, vd.binding.scope_id, vd.binding.name_atom);
        }
    }

    fn appendScopeBinding(
        self: *ContractBuilder,
        summary: *contract_types.HoleSummary,
        name: []const u8,
        scope_id: u16,
        name_atom: u16,
    ) !void {
        for (summary.in_scope.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return;
        }
        var type_buf: [256]u8 = undefined;
        const rendered: []const u8 = blk: {
            const env = self.type_env orelse break :blk "unknown";
            const t = env.getVarTypeByBinding(scope_id, name_atom) orelse break :blk "unknown";
            if (t == type_pool_mod.null_type_idx) break :blk "unknown";
            break :blk env.pool.formatType(env.stripProofMarkers(t), &type_buf);
        };
        try summary.in_scope.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .type_name = try self.allocator.dupe(u8, rendered),
        });
    }

    fn expectedTypeForHole(
        self: *const ContractBuilder,
        function_name: []const u8,
        buf: []u8,
    ) []const u8 {
        const env = self.type_env orelse return "unknown";
        const sig = env.getFnSigByName(function_name) orelse return "unknown";
        if (sig.return_type == type_pool_mod.null_type_idx) return "unknown";
        // Report the value type the expression must produce, not the capsule
        // expansion. `Response & Effects<...>` erases to `Response`: the marker
        // is a compile-time obligation the returned value never carries, so
        // showing it would tell an agent to construct a field that does not
        // exist at runtime.
        return env.pool.formatType(env.stripProofMarkers(sig.return_type), buf);
    }

    fn handlerReachability(
        allocator: std.mem.Allocator,
        analyzer: *const effect_inference.Analyzer,
    ) !?[]bool {
        const functions = analyzer.all();
        const h = findFunctionIndex(functions, "handler") orelse return null;
        var reachable = try allocator.alloc(bool, functions.len);
        errdefer allocator.free(reachable);
        @memset(reachable, false);

        var stack: std.ArrayListUnmanaged(usize) = .empty;
        defer stack.deinit(allocator);
        reachable[h] = true;
        try stack.append(allocator, h);
        while (stack.pop()) |cur| {
            for (analyzer.calleesOf(cur)) |callee| {
                if (callee < reachable.len and !reachable[callee]) {
                    reachable[callee] = true;
                    try stack.append(allocator, callee);
                }
            }
        }
        return reachable;
    }

    fn helperReachable(
        analyzer: *const effect_inference.Analyzer,
        reachable: ?[]const bool,
        name: []const u8,
    ) bool {
        const r = reachable orelse return false;
        if (findFunctionIndex(analyzer.all(), name)) |idx| {
            return idx < r.len and r[idx];
        }
        return false;
    }

    fn findFunctionIndex(functions: []const effect_inference.FunctionEffect, name: []const u8) ?usize {
        for (functions, 0..) |fe, i| {
            if (std.mem.eql(u8, fe.name, name)) return i;
        }
        return null;
    }

    /// Build a ZTS606 diagnostic for a helper that breaks a handler-demanded
    /// capsule property without declaring a capsule for it.
    fn makeMissingCapsule(
        allocator: std.mem.Allocator,
        property: []const u8,
        func: []const u8,
    ) !contract_types.SpecDiagnostic {
        const spec_name = try allocator.dupe(u8, property);
        errdefer allocator.free(spec_name);
        const owned_func = try allocator.dupe(u8, func);
        errdefer allocator.free(owned_func);
        const suggestion = try std.fmt.allocPrint(
            allocator,
            "annotate `{s}` with `Proof<T, \"{s}\">` and satisfy it, or inline the helper into the handler.",
            .{ func, property },
        );
        return .{
            .kind = .missing_capsule,
            .spec_name = spec_name,
            .suggestion = suggestion,
            .function = owned_func,
        };
    }

    /// Phase 4c: discharge the handler's capability budget. The handler
    /// declares its budget with an `Effects<...>` on its return type, exactly
    /// as a helper declares a ceiling - but the handler's budget also bounds
    /// every helper it reaches. The budget is checked `inferred ⊆ declared`.
    /// A capability the handler reaches directly and outside the budget gets
    /// ZTS506; one a reachable helper introduces gets ZTS607, attributed to
    /// that helper. The check runs only against inferred facts - no capability
    /// is ever assumed.
    fn dischargeCapabilityBudget(
        self: *ContractBuilder,
        contract: *HandlerContract,
        analyzer: *const effect_inference.Analyzer,
        handler_loc: ?ir.SourceLocation,
    ) !void {
        const env = self.type_env orelse return;
        const loc = handler_loc orelse return;
        if (loc.line == 0) return;

        const sig = env.getFnSigByLoc(loc.line) orelse return;
        if (sig.return_type == type_pool_mod.null_type_idx) return;

        var raw: std.ArrayListUnmanaged([]const u8) = .empty;
        defer raw.deinit(self.allocator);
        const extraction = try env.extractEffectMembers(sig.return_type, &raw);

        // ZTS511: a budget the extractor cannot read as a closed literal union.
        // Returning here as if nothing were declared is the fail-open: the
        // handler keeps its capabilities and no budget bounds them.
        if (extraction.non_literal) {
            const spec_name = try self.allocator.dupe(u8, "Effects");
            errdefer self.allocator.free(spec_name);
            const suggestion = try self.allocator.dupe(
                u8,
                "write the capability budget as string literals " ++
                    "(`Effects<Response, \"clock\" | \"crypto\">`), or as an alias bound " ++
                    "directly to such a union.",
            );
            errdefer self.allocator.free(suggestion);
            try contract.spec_diagnostics.append(self.allocator, .{
                .kind = .effect_ceiling_not_literal,
                .spec_name = spec_name,
                .suggestion = suggestion,
            });
            return;
        }

        if (raw.items.len == 0) return; // no budget declared, no check

        // Parse the budget. An unknown name is the handler-level analogue of
        // ZTS504; it is reported and dropped from the budget set.
        var budget = effect_inference.CapabilitySet.initEmpty();
        for (raw.items) |name| {
            if (std.meta.stringToEnum(module_binding.ModuleCapability, name)) |cap| {
                budget.insert(cap);
            } else {
                const spec_name = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(spec_name);
                const suggestion = try spec_discharge.suggestionForUnknownCapability(self.allocator, name);
                errdefer if (suggestion) |s| self.allocator.free(s);
                try contract.spec_diagnostics.append(self.allocator, .{
                    .kind = .effect_unknown_capability,
                    .spec_name = spec_name,
                    .suggestion = suggestion,
                });
            }
        }

        // Record the declared budget (valid names only) so the json writer
        // can serialise `sandbox.declaredBudget`.
        contract.capability_budget = capabilityMatrixFromSet(budget);

        // An all-invalid budget leaves an empty ceiling, and the check runs
        // against it. Returning early here used to suppress ZTS506 / ZTS607
        // for every capability the handler reaches, which reads as "budget
        // satisfied" to anything that only counts diagnostics by kind.

        // Locate the handler's FunctionEffect and index.
        const functions = analyzer.all();
        const h = findFunctionIndex(functions, "handler") orelse return;
        const hfe = functions[h];

        // ZTS512: the handler's row is a lower bound, so testing it against
        // the budget proves nothing - the capabilities behind the unresolvable
        // call are not in the set being tested.
        if (hfe.row.lower_bound) {
            const spec_name = try self.allocator.dupe(u8, "Effects");
            errdefer self.allocator.free(spec_name);
            const suggestion = try self.allocator.dupe(
                u8,
                "the handler calls through a value whose body the compiler cannot see, so the " ++
                    "capabilities it reaches are unknown and no budget can bound them. Call the " ++
                    "helper by name, or drop the `Effects<...>` budget this call cannot support.",
            );
            errdefer self.allocator.free(suggestion);
            try contract.spec_diagnostics.append(self.allocator, .{
                .kind = .effect_row_lower_bound,
                .spec_name = spec_name,
                .suggestion = suggestion,
            });
            return;
        }

        // Reachability: the budget bounds only helpers the handler can reach.
        var reachable = try self.allocator.alloc(bool, functions.len);
        defer self.allocator.free(reachable);
        @memset(reachable, false);
        var stack: std.ArrayListUnmanaged(usize) = .empty;
        defer stack.deinit(self.allocator);
        reachable[h] = true;
        try stack.append(self.allocator, h);
        while (stack.pop()) |cur| {
            for (analyzer.calleesOf(cur)) |callee| {
                if (callee < reachable.len and !reachable[callee]) {
                    reachable[callee] = true;
                    try stack.append(self.allocator, callee);
                }
            }
        }

        // Every capability in the handler's transitive row that the budget
        // omits is a violation, attributed to its direct source.
        var cap_it = hfe.row.capabilities.iterator();
        while (cap_it.next()) |cap| {
            if (budget.contains(cap)) continue;
            if (hfe.direct_caps.contains(cap)) {
                try contract.spec_diagnostics.append(
                    self.allocator,
                    try makeBudgetExceeded(self.allocator, @tagName(cap)),
                );
            }
            for (functions, 0..) |fe, i| {
                if (i == h) continue;
                if (!reachable[i]) continue;
                if (!fe.direct_caps.contains(cap)) continue;
                try contract.spec_diagnostics.append(
                    self.allocator,
                    try makeHelperBudgetExceeded(self.allocator, @tagName(cap), fe.name),
                );
            }
        }
    }

    /// Project a capability set into the contract's `CapabilityMatrix` shape,
    /// in canonical enum order with a stable hash.
    fn capabilityMatrixFromSet(set: effect_inference.CapabilitySet) contract_types.CapabilityMatrix {
        var matrix: contract_types.CapabilityMatrix = .{};
        var n: u8 = 0;
        for (std.enums.values(module_binding.ModuleCapability)) |c| {
            if (set.contains(c)) {
                matrix.items[n] = c;
                n += 1;
            }
        }
        matrix.len = n;
        matrix.hash = module_binding.capabilityHash(matrix.slice());
        return matrix;
    }

    /// Build a ZTS506 diagnostic: the handler reaches a capability directly
    /// that is outside its declared `Effects<...>` budget.
    fn makeBudgetExceeded(
        allocator: std.mem.Allocator,
        capability: []const u8,
    ) !contract_types.SpecDiagnostic {
        const spec_name = try allocator.dupe(u8, capability);
        errdefer allocator.free(spec_name);
        const suggestion = try std.fmt.allocPrint(
            allocator,
            "add `{s}` to the handler's `Effects<...>` budget, or remove the call that reaches it.",
            .{capability},
        );
        return .{
            .kind = .budget_exceeded,
            .spec_name = spec_name,
            .suggestion = suggestion,
        };
    }

    /// Build a ZTS607 diagnostic: a handler-reachable helper reaches a
    /// capability outside the handler's declared `Effects<...>` budget.
    fn makeHelperBudgetExceeded(
        allocator: std.mem.Allocator,
        capability: []const u8,
        func: []const u8,
    ) !contract_types.SpecDiagnostic {
        const spec_name = try allocator.dupe(u8, capability);
        errdefer allocator.free(spec_name);
        const owned_func = try allocator.dupe(u8, func);
        errdefer allocator.free(owned_func);
        const suggestion = try std.fmt.allocPrint(
            allocator,
            "helper `{s}` reaches `{s}`; add it to the handler's `Effects<...>` budget, or remove the call.",
            .{ func, capability },
        );
        return .{
            .kind = .helper_budget_exceeded,
            .spec_name = spec_name,
            .suggestion = suggestion,
            .function = owned_func,
        };
    }

    /// Phase 4d: turn every `effects.nested_workflow_calls` entry into a
    /// ZTS509 diagnostic. Unconditional - runs for every function the
    /// analyzer collected, regardless of any declared capsule.
    fn emitNestedWorkflowCallDiagnostics(
        self: *ContractBuilder,
        contract: *HandlerContract,
        effects: *const effect_inference.Analyzer,
    ) !void {
        for (effects.nested_workflow_calls.items) |violation| {
            const func_name = effects.functions.items[violation.owner].name;
            try contract.spec_diagnostics.append(
                self.allocator,
                try makeWorkflowCallInStep(self.allocator, violation.workflow_fn, func_name),
            );
        }
    }

    /// Build a ZTS509 diagnostic: `workflow.call`/`saga`/`fanout`/`follow`
    /// used inside a `durable.step()` callback, where it silently loses
    /// durability instead of failing.
    fn makeWorkflowCallInStep(
        allocator: std.mem.Allocator,
        workflow_fn: []const u8,
        func: []const u8,
    ) !contract_types.SpecDiagnostic {
        const spec_name = try allocator.dupe(u8, workflow_fn);
        errdefer allocator.free(spec_name);
        const owned_func = try allocator.dupe(u8, func);
        errdefer allocator.free(owned_func);
        const suggestion = try std.fmt.allocPrint(
            allocator,
            "`{s}()` only durably records at step depth 0; move it outside the enclosing step() callback in `{s}`.",
            .{ workflow_fn, func },
        );
        return .{
            .kind = .workflow_call_in_step,
            .spec_name = spec_name,
            .suggestion = suggestion,
            .function = owned_func,
        };
    }

    /// Phase 4e: flag every non-last step missing `compensate` in each
    /// statically-analyzable saga. Skips `dynamic` sagas entirely (KTD6 -
    /// unproven, not failed) since their step set cannot be enumerated.
    fn emitSagaCompensationDiagnostics(self: *ContractBuilder, contract: *HandlerContract) !void {
        for (contract.sagas.items) |saga| {
            if (saga.dynamic or saga.steps.items.len == 0) continue;
            for (saga.steps.items[0 .. saga.steps.items.len - 1], 0..) |step, i| {
                if (step.has_compensate) continue;
                try contract.spec_diagnostics.append(
                    self.allocator,
                    try makeSagaStepMissingCompensate(self.allocator, step.name, i, saga.steps.items.len, saga.source_line),
                );
            }
        }
    }

    /// Build a ZTS510 diagnostic: a non-last saga step declares no
    /// `compensate`, so if a later step fails, this step's already-
    /// completed side effect is never undone - a partial-rollback hole.
    fn makeSagaStepMissingCompensate(
        allocator: std.mem.Allocator,
        step_name: []const u8,
        index: usize,
        total: usize,
        source_line: u32,
    ) !contract_types.SpecDiagnostic {
        const spec_name = try allocator.dupe(u8, step_name);
        errdefer allocator.free(spec_name);
        const suggestion = try std.fmt.allocPrint(
            allocator,
            "saga step \"{s}\" ({d} of {d}, line {d}) has no `compensate` - if a later step fails, this step's completed effect is never undone. Add a `compensate` thunk, or move this step last if it has no side effect to undo.",
            .{ step_name, index + 1, total, source_line },
        );
        return .{
            .kind = .saga_step_missing_compensate,
            .spec_name = spec_name,
            .suggestion = suggestion,
        };
    }

    // -----------------------------------------------------------------
    // Phase 1: Import scanning
    // -----------------------------------------------------------------

    // -----------------------------------------------------------------
    // Phase 2: Call site scanning
    // -----------------------------------------------------------------

    fn scanCallSites(self: *ContractBuilder) !void {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .call) continue;

            const call = self.ir_view.getCall(idx) orelse continue;

            // Check what the callee is
            const callee_tag = self.ir_view.getTag(call.callee) orelse continue;

            if (callee_tag == .identifier) {
                const binding = self.ir_view.getBinding(call.callee) orelse continue;

                // Check for fetchSync (undeclared global)
                if (binding.kind == .undeclared_global) {
                    const name = self.resolveAtomName(binding.name_atom) orelse continue;
                    if (std.mem.eql(u8, name, "fetchSync")) {
                        try self.extractLiteralArg(call, .{ .list = &self.egress_hosts, .dynamic = &self.egress_dynamic }, &extractHost);
                        try self.extractLiteralArg(call, .{ .list = &self.egress_urls, .dynamic = &self.egress_dynamic }, null);
                        continue;
                    }
                }

                // resource(data, affordances) is a bare global (builtins/root.zig),
                // not a module import, so it is hooked here by name rather than via
                // the generic binding registry. Extract the affordance set for the
                // system linker's hypermedia resolution (fail-closed: a non-literal
                // affordances arg marks the contract affordances_dynamic).
                if (binding.kind == .global or binding.kind == .undeclared_global) {
                    if (self.resolveAtomName(binding.name_atom)) |name| {
                        if (std.mem.eql(u8, name, "resource")) {
                            try self.extractAffordances(call);
                            continue;
                        }
                    }
                }

                // Check generic bindings from the module binding registry
                for (self.factsRef().generic_bindings.items) |gb| {
                    if (gb.slot != binding.slot) continue;

                    // Apply contract flags
                    if (gb.flags.sets_scope_used) self.scope_used = true;
                    if (gb.flags.sets_durable_used) self.durable_used = true;
                    if (gb.flags.sets_durable_timers) self.durable_timers = true;
                    if (gb.flags.sets_bearer_auth) self.api_bearer_auth = true;
                    if (gb.flags.sets_jwt_auth) self.api_jwt_auth = true;

                    // Process extraction rules
                    for (gb.extractions) |ext| {
                        switch (ext.category) {
                            // Custom extractors for complex multi-arg patterns
                            .sql_registration => try self.extractSqlRegistration(call),
                            .schema_compile => try self.extractSchemaCompile(call),
                            .route_pattern => try self.extractApiRoutesFromCall(call),
                            .service_call => try self.extractServiceCall(call),
                            .workflow_call => try self.extractWorkflowCall(call),
                            // Generic: extract literal from arg N into category bucket
                            else => {
                                if (self.getCategoryTarget(ext.category)) |target| {
                                    const transform: ?*const fn ([]const u8) []const u8 =
                                        if (ext.transform) |t| switch (t) {
                                            .extract_host => &extractHost,
                                            .identity => null,
                                        } else null;
                                    try self.extractLiteralArgAt(call, ext.arg_position, target, transform);
                                }
                            },
                        }
                    }
                    break;
                }

                // Partner extractions route literals into the per-specifier
                // extensions map. `fetch_host` rules also mirror into the
                // top-level egress.hosts so runtime egress policy enforcement
                // sees one uniform list.
                for (self.factsRef().extension_bindings.items) |eb| {
                    if (eb.slot != binding.slot) continue;
                    for (eb.extractions) |rule| {
                        try self.applyExtensionExtraction(call, eb.module_specifier, rule);
                    }
                    break;
                }
            }

            // Detect nondeterministic builtins: Date.now(), Math.random()
            // The durable-step exemption is applied per read below rather than
            // here, because it only holds for reads a step records and
            // replays. `performance.now` is not one, so skipping the whole
            // check inside a step certified it.
            if (!self.has_nondeterministic_builtin and callee_tag == .member_access) {
                const member = self.ir_view.getMember(call.callee) orelse continue;
                const obj_tag = self.ir_view.getTag(member.object) orelse continue;
                if (obj_tag == .identifier) {
                    const binding = self.ir_view.getBinding(member.object) orelse continue;
                    if (binding.kind == .global or binding.kind == .undeclared_global) {
                        const obj_name = self.resolveAtomName(binding.name_atom) orelse continue;
                        const prop_name = self.resolveAtomName(member.property) orelse continue;
                        // Shares `known_globals.varying_reads` with the flow
                        // checker and effect inference. This was a third
                        // hand-copy of the same pair and was missed when the
                        // other two were unified, so `performance.now()` lost
                        // its proof-card location and the HUD printed the
                        // deterministic failure with no line or snippet.
                        // Order matters for cost, not just correctness. The
                        // name check is two string compares; the durable-step
                        // check walks ancestors, so asking it for every member
                        // call in a handler is quadratic enough to trip the
                        // runtime's handler and WebSocket timeouts. Only a read
                        // that actually varies is worth that walk.
                        if (!known_globals.isVaryingRead(obj_name, prop_name)) continue;
                        const exempt = !known_globals.isUnrecordableVaryingRead(obj_name, prop_name) and
                            self.isInsideDurableStepCallback(idx);
                        if (!exempt) {
                            self.has_nondeterministic_builtin = true;
                            // Capture the first call site so the HUD can print
                            // "-deterministic at handler.ts:N: Date.now()".
                            const loc = self.ir_view.getLoc(call.callee) orelse self.ir_view.getLoc(member.object);
                            if (loc) |l| {
                                self.nondeterministic_cause = .{
                                    .line = l.line,
                                    .column = l.column,
                                    .snippet = snippetForVaryingRead(obj_name, prop_name),
                                };
                            }
                        }
                    }
                }
            }
        }
    }

    fn isInsideDurableStepCallback(self: *ContractBuilder, target: NodeIndex) bool {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .call) continue;
            const call = self.ir_view.getCall(idx) orelse continue;
            if (!self.isDurableStepCall(call) or call.args_count < 2) continue;
            const callback = self.ir_view.getListIndex(call.args_start, 1);
            if (!self.isFunctionNode(callback)) continue;
            if (self.subtreeContains(callback, target)) return true;
        }
        return false;
    }

    fn isDurableStepCall(self: *ContractBuilder, call: Node.CallExpr) bool {
        if (self.ir_view.getTag(call.callee) != .identifier) return false;
        const binding = self.ir_view.getBinding(call.callee) orelse return false;
        for (self.factsRef().generic_bindings.items) |gb| {
            if (gb.slot != binding.slot) continue;
            return std.mem.eql(u8, gb.module_specifier, "zttp:durable") and
                std.mem.eql(u8, gb.binding_name, "step");
        }
        return false;
    }

    fn isFunctionNode(self: *const ContractBuilder, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        return tag == .function_decl or tag == .function_expr or tag == .arrow_function;
    }

    fn subtreeContains(self: *ContractBuilder, root: NodeIndex, target: NodeIndex) bool {
        if (root == null_node) return false;
        if (root == target) return true;
        const tag = self.ir_view.getTag(root) orelse return false;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(root) orelse return false;
                for (0..block.stmts_count) |i| {
                    if (self.subtreeContains(self.ir_view.getListIndex(block.stmts_start, @intCast(i)), target)) return true;
                }
            },
            .return_stmt, .expr_stmt => {
                if (self.ir_view.getOptValue(root)) |value| return self.subtreeContains(value, target);
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(root) orelse return false;
                return self.subtreeContains(decl.pattern, target) or self.subtreeContains(decl.init, target);
            },
            .if_stmt => {
                const stmt = self.ir_view.getIfStmt(root) orelse return false;
                return self.subtreeContains(stmt.condition, target) or
                    self.subtreeContains(stmt.then_branch, target) or
                    self.subtreeContains(stmt.else_branch, target);
            },
            .for_of_stmt => {
                const stmt = self.ir_view.getForIter(root) orelse return false;
                return self.subtreeContains(stmt.pattern, target) or
                    self.subtreeContains(stmt.iterable, target) or
                    self.subtreeContains(stmt.body, target);
            },
            .binary_op => {
                const expr = self.ir_view.getBinary(root) orelse return false;
                return self.subtreeContains(expr.left, target) or self.subtreeContains(expr.right, target);
            },
            .unary_op, .spread => {
                const expr = self.ir_view.getUnary(root) orelse return false;
                return self.subtreeContains(expr.operand, target);
            },
            .ternary => {
                const expr = self.ir_view.getTernary(root) orelse return false;
                return self.subtreeContains(expr.condition, target) or
                    self.subtreeContains(expr.then_branch, target) or
                    self.subtreeContains(expr.else_branch, target);
            },
            .call, .method_call => {
                const call = self.ir_view.getCall(root) orelse return false;
                if (self.subtreeContains(call.callee, target)) return true;
                for (0..call.args_count) |i| {
                    if (self.subtreeContains(self.ir_view.getListIndex(call.args_start, @intCast(i)), target)) return true;
                }
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(root) orelse return false;
                return self.subtreeContains(member.object, target) or self.subtreeContains(member.computed, target);
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(root) orelse return false;
                return self.subtreeContains(assign.target, target) or self.subtreeContains(assign.value, target);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(root) orelse return false;
                for (0..arr.elements_count) |i| {
                    if (self.subtreeContains(self.ir_view.getListIndex(arr.elements_start, @intCast(i)), target)) return true;
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(root) orelse return false;
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    if (self.subtreeContains(prop_idx, target)) return true;
                }
            },
            .object_property => {
                const prop = self.ir_view.getProperty(root) orelse return false;
                return self.subtreeContains(prop.key, target) or self.subtreeContains(prop.value, target);
            },
            .function_decl, .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(root) orelse return false;
                return self.subtreeContains(func.body, target);
            },
            .template_literal => {
                const tmpl = self.ir_view.getTemplate(root) orelse return false;
                for (0..tmpl.parts_count) |i| {
                    if (self.subtreeContains(self.ir_view.getListIndex(tmpl.parts_start, @intCast(i)), target)) return true;
                }
            },
            .match_expr => {
                const match = self.ir_view.getMatchExpr(root) orelse return false;
                if (self.subtreeContains(match.discriminant, target)) return true;
                for (0..match.arms_count) |i| {
                    if (self.subtreeContains(self.ir_view.getListIndex(match.arms_start, @intCast(i)), target)) return true;
                }
            },
            .match_arm => {
                const arm = self.ir_view.getMatchArm(root) orelse return false;
                return self.subtreeContains(arm.pattern, target) or self.subtreeContains(arm.body, target);
            },
            // exhaustive: falling through reaches `return false` - the target was
            // not found in this subtree. The arms above cover every node with
            // children to search; the rest are leaves that can only be the
            // target itself, which the identity check at the top already made.
            else => {},
        }
        return false;
    }

    /// Extract a literal string from the first argument of a call and append
    /// it (deduped, owned) to `target`. If the argument is non-literal, set
    /// `dynamic_flag`. An optional `transform` narrows the extracted string
    /// (e.g. extractHost for URLs) - returning empty means "treat as dynamic".
    fn extractLiteralArg(
        self: *ContractBuilder,
        call: Node.CallExpr,
        target: CategoryTarget,
        transform: ?*const fn ([]const u8) []const u8,
    ) !void {
        try self.extractLiteralArgAt(call, 0, target, transform);
    }

    /// Apply one partner-declared extraction rule to a partner-module call
    /// site. Routes a literal argument into the per-specifier extensions
    /// store. `fetch_host` rules additionally mirror the host into the
    /// top-level `egress_hosts` so runtime egress policy sees one uniform
    /// list of allowed hosts.
    fn applyExtensionExtraction(
        self: *ContractBuilder,
        call: Node.CallExpr,
        specifier: []const u8,
        rule: module_manifest.ContractExtractionRule,
    ) !void {
        const transform: ?*const fn ([]const u8) []const u8 =
            if (rule.transform) |t| switch (t) {
                .extract_host => &extractHost,
                .identity => null,
            } else null;

        const bucket = try self.getOrCreateExtensionEntry(specifier);

        switch (rule.category) {
            .fetch_host => {
                // Per-extension copy AND top-level mirror.
                try self.extractLiteralArgAt(call, rule.arg_position, .{ .list = &bucket.egress_hosts, .dynamic = &bucket.egress_dynamic }, transform);
                try self.extractLiteralArgAt(call, rule.arg_position, .{ .list = &self.egress_hosts, .dynamic = &self.egress_dynamic }, transform);
                // Mirror the full URL into egress_urls as well (matching the bare
                // fetchSync path), so system_linker can resolve cross-handler
                // internal calls made through the `zttp:fetch` module import -
                // otherwise "every internal fetch matches a declared route"
                // holds vacuously for module-import callers.
                try self.extractLiteralArgAt(call, rule.arg_position, .{ .list = &self.egress_urls, .dynamic = &self.egress_dynamic }, null);
            },
            .extension_specific => {
                const tag = rule.extension_category orelse return;
                const cat_bucket = try self.getOrCreateCategoryBucket(bucket, tag);
                try self.extractLiteralArgAt(call, rule.arg_position, .{ .list = &cat_bucket.literals, .dynamic = &cat_bucket.dynamic }, transform);
            },
            else => {
                // Other built-in categories from partners route under a
                // category key matching the variant tag name. This keeps the
                // section uniform and lets partners reuse names like
                // `cache_namespace` for proof of cache use without rerouting
                // through built-in policy.
                const tag = @tagName(rule.category);
                const cat_bucket = try self.getOrCreateCategoryBucket(bucket, tag);
                try self.extractLiteralArgAt(call, rule.arg_position, .{ .list = &cat_bucket.literals, .dynamic = &cat_bucket.dynamic }, transform);
            },
        }
    }

    fn getOrCreateExtensionEntry(
        self: *ContractBuilder,
        specifier: []const u8,
    ) !*contract_types.ExtensionContract {
        const entry = try getOrPutDuped(contract_types.ExtensionContract, &self.extensions, self.allocator, specifier);
        // Mirror the manifest's top-level section declaration onto the
        // contract entry the first time we touch this specifier. Subsequent
        // calls are idempotent. The manifest may live longer than this
        // builder so we own the copy.
        if (entry.contract_section == null) {
            const registry = self.manifest_registry orelse return entry;
            const manifest = registry.fromSpecifier(specifier) orelse return entry;
            if (manifest.contract_section) |name| {
                entry.contract_section = try self.allocator.dupe(u8, name);
            }
        }
        return entry;
    }

    fn getOrCreateCategoryBucket(
        self: *ContractBuilder,
        bucket: *contract_types.ExtensionContract,
        tag: []const u8,
    ) !*contract_types.ExtensionCategoryBucket {
        return getOrPutDuped(contract_types.ExtensionCategoryBucket, &bucket.categories, self.allocator, tag);
    }

    /// Insert-or-find on a string-keyed map where the key must be owned by
    /// the map. On miss, duplicates the key with the allocator and
    /// default-initializes the value; on duplicate-alloc failure rolls back
    /// the entry so the map stays consistent.
    fn getOrPutDuped(
        comptime V: type,
        map: *std.StringHashMapUnmanaged(V),
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !*V {
        const gop = try map.getOrPut(allocator, key);
        if (!gop.found_existing) {
            const owned_key = allocator.dupe(u8, key) catch |err| {
                _ = map.remove(key);
                return err;
            };
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    fn extractLiteralArgAt(
        self: *ContractBuilder,
        call: Node.CallExpr,
        arg_pos: u8,
        target: CategoryTarget,
        transform: ?*const fn ([]const u8) []const u8,
    ) !void {
        if (call.args_count <= arg_pos) return;

        const arg_idx = self.ir_view.getListIndex(call.args_start, arg_pos);
        const arg_tag = self.ir_view.getTag(arg_idx) orelse return;

        // Non-string arg -> dynamic; the value cannot be proven at
        // build time. Early-return keeps the literal happy path flat.
        if (arg_tag != .lit_string) {
            target.dynamic.* = true;
            return;
        }

        const str_idx = self.ir_view.getStringIdx(arg_idx) orelse return;
        const raw = self.ir_view.getString(str_idx) orelse return;
        const value = if (transform) |t| t(raw) else raw;

        // Empty post-transform (e.g. extractHost on a URL with no host)
        // is also a dynamic signal.
        if (value.len == 0) {
            target.dynamic.* = true;
            return;
        }

        if (containsString(target.list.items, value)) return;

        const duped = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(duped);
        try target.list.append(self.allocator, duped);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// Map a ContractCategory to the data field pair it writes to.
    const CategoryTarget = struct {
        list: *std.ArrayList([]const u8),
        dynamic: *bool,
    };

    /// Check if a binding slot is tracked for a specific contract category.
    fn isBindingCategory(self: *const ContractBuilder, slot: u16, category: module_binding.ContractCategory) bool {
        for (self.factsRef().generic_bindings.items) |gb| {
            if (gb.slot != slot) continue;
            for (gb.extractions) |ext| {
                if (ext.category == category) return true;
            }
        }
        return false;
    }

    fn getCategoryTarget(self: *ContractBuilder, category: module_binding.ContractCategory) ?CategoryTarget {
        return switch (category) {
            .env => .{ .list = &self.env_literals, .dynamic = &self.env_dynamic },
            .cache_namespace => .{ .list = &self.cache_namespaces, .dynamic = &self.cache_dynamic },
            .scope_name => .{ .list = &self.scope_names, .dynamic = &self.scope_dynamic },
            .durable_key => .{ .list = &self.durable_key_literals, .dynamic = &self.durable_key_dynamic },
            .durable_step => .{ .list = &self.durable_step_names, .dynamic = &self.durable_step_dynamic },
            .durable_signal => .{ .list = &self.durable_signal_names, .dynamic = &self.durable_signal_dynamic },
            .durable_producer_key => .{ .list = &self.durable_producer_key_literals, .dynamic = &self.durable_producer_key_dynamic },
            .request_schema => .{ .list = &self.api_request_schema_refs, .dynamic = &self.api_request_schema_dynamic },
            .fetch_host => .{ .list = &self.egress_hosts, .dynamic = &self.egress_dynamic },
            // Custom categories are dispatched directly, not via generic target
            .rate_limit_key => .{ .list = &self.rate_limit_keys, .dynamic = &self.rate_limit_key_dynamic },
            .sql_registration, .schema_compile, .route_pattern, .service_call, .workflow_call, .cookie_name, .cors_origin => null,
            // Partner-declared categories route through the extensions store, not the built-in target table.
            .extension_specific => null,
        };
    }

    fn extractScopeUsage(self: *ContractBuilder, handler_fn: NodeIndex) !void {
        const func = self.ir_view.getFunction(handler_fn) orelse return;
        try self.walkScopeDepth(func.body, 0);
    }

    fn walkScopeDepth(self: *ContractBuilder, node_idx: NodeIndex, depth: u32) !void {
        if (node_idx == null_node) return;

        const tag = self.ir_view.getTag(node_idx) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node_idx) orelse return;
                var i: u16 = 0;
                while (i < block.stmts_count) : (i += 1) {
                    try self.walkScopeDepth(self.ir_view.getListIndex(block.stmts_start, i), depth);
                }
            },
            .expr_stmt, .throw_stmt, .return_stmt, .assert_stmt => {
                if (self.ir_view.getOptValue(node_idx)) |value_node| {
                    try self.walkScopeDepth(value_node, depth);
                }
            },
            .var_decl, .function_decl => {
                const decl = self.ir_view.getVarDecl(node_idx) orelse return;
                if (decl.init != null_node) try self.walkScopeDepth(decl.init, depth);
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node_idx) orelse return;
                try self.walkScopeDepth(if_stmt.condition, depth);
                try self.walkScopeDepth(if_stmt.then_branch, depth);
                try self.walkScopeDepth(if_stmt.else_branch, depth);
            },
            .switch_stmt => {
                const switch_stmt = self.ir_view.getSwitchStmt(node_idx) orelse return;
                try self.walkScopeDepth(switch_stmt.discriminant, depth);
                var i: u8 = 0;
                while (i < switch_stmt.cases_count) : (i += 1) {
                    try self.walkScopeDepth(self.ir_view.getListIndex(switch_stmt.cases_start, i), depth);
                }
            },
            .case_clause => {
                const case_clause = self.ir_view.getCaseClause(node_idx) orelse return;
                try self.walkScopeDepth(case_clause.test_expr, depth);
                var i: u16 = 0;
                while (i < case_clause.body_count) : (i += 1) {
                    try self.walkScopeDepth(self.ir_view.getListIndex(case_clause.body_start, i), depth);
                }
            },
            .for_of_stmt, .for_in_stmt => {
                const for_iter = self.ir_view.getForIter(node_idx) orelse return;
                try self.walkScopeDepth(for_iter.iterable, depth);
                try self.walkScopeDepth(for_iter.body, depth);
            },
            .binary_op => {
                const binary = self.ir_view.getBinary(node_idx) orelse return;
                try self.walkScopeDepth(binary.left, depth);
                try self.walkScopeDepth(binary.right, depth);
            },
            .unary_op => {
                const unary = self.ir_view.getUnary(node_idx) orelse return;
                try self.walkScopeDepth(unary.operand, depth);
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node_idx) orelse return;
                try self.walkScopeDepth(ternary.condition, depth);
                try self.walkScopeDepth(ternary.then_branch, depth);
                try self.walkScopeDepth(ternary.else_branch, depth);
            },
            .assignment => {
                const assignment = self.ir_view.getAssignment(node_idx) orelse return;
                try self.walkScopeDepth(assignment.target, depth);
                try self.walkScopeDepth(assignment.value, depth);
            },
            .member_access, .computed_access, .optional_chain => {
                const member = self.ir_view.getMember(node_idx) orelse return;
                try self.walkScopeDepth(member.object, depth);
                if (member.computed != null_node) try self.walkScopeDepth(member.computed, depth);
            },
            .array_literal => {
                const array = self.ir_view.getArray(node_idx) orelse return;
                var i: u16 = 0;
                while (i < array.elements_count) : (i += 1) {
                    try self.walkScopeDepth(self.ir_view.getListIndex(array.elements_start, i), depth);
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node_idx) orelse return;
                var i: u16 = 0;
                while (i < obj.properties_count) : (i += 1) {
                    try self.walkScopeDepth(self.ir_view.getListIndex(obj.properties_start, i), depth);
                }
            },
            .object_property => {
                const prop = self.ir_view.getProperty(node_idx) orelse return;
                if (prop.is_computed) try self.walkScopeDepth(prop.key, depth);
                try self.walkScopeDepth(prop.value, depth);
            },
            .call, .method_call, .optional_call => {
                const call = self.ir_view.getCall(node_idx) orelse return;

                if (self.isModuleBindingName(call.callee, "scope")) {
                    self.scope_used = true;

                    const next_depth = depth + 1;
                    if (next_depth > self.scope_max_depth) self.scope_max_depth = next_depth;

                    if (call.args_count > 1) {
                        const callback_idx = self.ir_view.getListIndex(call.args_start, 1);
                        if (self.resolveFunctionNode(callback_idx)) |fn_node| {
                            const fn_expr = self.ir_view.getFunction(fn_node) orelse return;
                            try self.walkScopeDepth(fn_expr.body, next_depth);
                        } else {
                            self.scope_dynamic = true;
                        }
                    } else {
                        self.scope_dynamic = true;
                    }
                    return;
                }

                try self.walkScopeDepth(call.callee, depth);
                var i: u8 = 0;
                while (i < call.args_count) : (i += 1) {
                    try self.walkScopeDepth(self.ir_view.getListIndex(call.args_start, i), depth);
                }
            },
            // exhaustive: scope depth only deepens through the nesting constructs
            // handled above. A leaf carries no scope, so there is nothing to
            // descend into and nothing to count.
            else => {},
        }
    }

    fn isModuleBindingName(self: *const ContractBuilder, callee: NodeIndex, expected: []const u8) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .identifier) return false;

        const binding = self.ir_view.getBinding(callee) orelse return false;
        for (self.factsRef().generic_bindings.items) |gb| {
            if (gb.slot == binding.slot and std.mem.eql(u8, gb.binding_name, expected)) return true;
        }

        if (binding.kind == .global or binding.kind == .undeclared_global) {
            const name = self.resolveAtomName(binding.name_atom) orelse return false;
            return std.mem.eql(u8, name, expected);
        }

        return false;
    }

    const WorkflowCursor = struct {
        node_id: []const u8,
        condition: ?[]const u8 = null,

        fn deinit(self: *WorkflowCursor, allocator: std.mem.Allocator) void {
            if (self.condition) |condition| allocator.free(condition);
        }
    };

    fn extractDurableWorkflow(self: *ContractBuilder, handler_path: []const u8, handler_fn: NodeIndex) !void {
        if (!self.durable_used) return;

        const func = self.ir_view.getFunction(handler_fn) orelse return;
        const run_call = self.findDurableRunCall(func.body) orelse {
            self.durable_workflow.proof_level = .none;
            try self.addWorkflowReason("no durable run callback was statically identified");
            return;
        };

        self.durable_workflow.workflow_id = try self.buildWorkflowId(handler_path, handler_fn, run_call.call_node);
        self.durable_workflow.proof_level = if (self.durable_key_dynamic or self.durable_step_dynamic or self.durable_signal_dynamic or self.durable_run_count > 1)
            .partial
        else
            .complete;

        const callback_fn = self.ir_view.getFunction(run_call.callback_node) orelse {
            self.markWorkflowPartial();
            try self.deriveDurableWorkflowProperties();
            return;
        };

        var cursors: std.ArrayList(WorkflowCursor) = .empty;
        defer self.deinitWorkflowCursors(&cursors);
        try cursors.append(self.allocator, .{
            .node_id = "start",
            .condition = null,
        });

        try self.walkWorkflowBlock(callback_fn.body, &cursors);
        try self.deriveDurableWorkflowProperties();
    }

    const RunCallInfo = struct {
        call_node: NodeIndex,
        callback_node: NodeIndex,
    };

    fn findDurableRunCall(self: *ContractBuilder, node: NodeIndex) ?RunCallInfo {
        if (node == null_node) return null;
        const tag = self.ir_view.getTag(node) orelse return null;

        switch (tag) {
            .block, .program => {
                const block = self.ir_view.getBlock(node) orelse return null;
                var i: u16 = 0;
                while (i < block.stmts_count) : (i += 1) {
                    const stmt_idx = self.ir_view.getListIndex(block.stmts_start, i);
                    if (self.findDurableRunCall(stmt_idx)) |info| return info;
                }
            },
            .return_stmt, .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |value| {
                    return self.findDurableRunCall(value);
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return null;
                if (decl.init != null_node) {
                    return self.findDurableRunCall(decl.init);
                }
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node) orelse return null;
                if (self.findDurableRunCall(if_stmt.then_branch)) |info| return info;
                if (if_stmt.else_branch != null_node) {
                    if (self.findDurableRunCall(if_stmt.else_branch)) |info| return info;
                }
            },
            .call => {
                const call = self.ir_view.getCall(node) orelse return null;
                if (self.isModuleBindingName(call.callee, "run")) {
                    self.durable_run_count += 1;
                    if (call.args_count >= 2) {
                        const callback_node = self.ir_view.getListIndex(call.args_start, 1);
                        if (self.ir_view.getTag(callback_node) == .function_expr or self.ir_view.getTag(callback_node) == .arrow_function) {
                            return .{
                                .call_node = node,
                                .callback_node = callback_node,
                            };
                        }
                    }
                }
            },
            // exhaustive: not finding a `durable.run` call here leaves the handler
            // with no workflow to prove, which claims nothing. The arms above
            // cover every node a call can be reached through.
            else => {},
        }

        return null;
    }

    fn walkWorkflowBlock(self: *ContractBuilder, node: NodeIndex, cursors: *std.ArrayList(WorkflowCursor)) anyerror!void {
        if (node == null_node or cursors.items.len == 0) return;
        const tag = self.ir_view.getTag(node) orelse return;
        if (tag != .block and tag != .program) {
            try self.walkWorkflowStatement(node, cursors);
            return;
        }

        const block = self.ir_view.getBlock(node) orelse return;
        var i: u16 = 0;
        while (i < block.stmts_count and cursors.items.len > 0) : (i += 1) {
            try self.walkWorkflowStatement(self.ir_view.getListIndex(block.stmts_start, i), cursors);
        }
    }

    fn walkWorkflowStatement(self: *ContractBuilder, node: NodeIndex, cursors: *std.ArrayList(WorkflowCursor)) anyerror!void {
        if (node == null_node or cursors.items.len == 0) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .block, .program => try self.walkWorkflowBlock(node, cursors),
            .if_stmt => try self.walkWorkflowIf(node, cursors),
            .return_stmt => try self.appendReturnWorkflowNode(node, cursors),
            .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |expr| {
                    if (!try self.appendWorkflowCall(expr, cursors) and self.isUnhandledWorkflowCall(expr)) {
                        self.markWorkflowPartial();
                    }
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                if (decl.init != null_node) {
                    if (!try self.appendWorkflowCall(decl.init, cursors) and self.isUnhandledWorkflowCall(decl.init)) {
                        self.markWorkflowPartial();
                    }
                }
            },
            .match_expr, .switch_stmt, .for_stmt, .for_of_stmt, .for_in_stmt, .while_stmt, .do_while_stmt => {
                self.markWorkflowPartial();
            },
            // exhaustive: the control-flow kinds above mark the proof partial
            // because the graph cannot model them. What remains carries no
            // workflow call of its own - a nested function declaration is not
            // walked here, but calling it is an unmodeled call at its own
            // statement, which `isUnhandledWorkflowCall` catches and which a
            // regression test covers.
            else => {},
        }
    }

    fn walkWorkflowIf(self: *ContractBuilder, node: NodeIndex, cursors: *std.ArrayList(WorkflowCursor)) anyerror!void {
        const if_stmt = self.ir_view.getIfStmt(node) orelse return;
        const line = if (self.ir_view.getLoc(node)) |loc| loc.line else 0;
        const column = if (self.ir_view.getLoc(node)) |loc| loc.column else 0;

        const branch_node_id = try self.appendWorkflowNode(
            .branch,
            try std.fmt.allocPrint(self.allocator, "if:{d}:{d}", .{ line, column }),
            null,
            null,
            cursors,
        );

        var then_cursors: std.ArrayList(WorkflowCursor) = .empty;
        defer self.deinitWorkflowCursors(&then_cursors);
        try then_cursors.append(self.allocator, .{
            .node_id = branch_node_id,
            .condition = try std.fmt.allocPrint(self.allocator, "then@{d}:{d}", .{ line, column }),
        });
        try self.walkWorkflowStatement(if_stmt.then_branch, &then_cursors);

        var else_cursors: std.ArrayList(WorkflowCursor) = .empty;
        defer self.deinitWorkflowCursors(&else_cursors);
        try else_cursors.append(self.allocator, .{
            .node_id = branch_node_id,
            .condition = try std.fmt.allocPrint(self.allocator, "else@{d}:{d}", .{ line, column }),
        });
        if (if_stmt.else_branch != null_node) {
            try self.walkWorkflowStatement(if_stmt.else_branch, &else_cursors);
        }

        self.deinitWorkflowCursors(cursors);
        for (then_cursors.items) |cursor| {
            try cursors.append(self.allocator, .{
                .node_id = cursor.node_id,
                .condition = if (cursor.condition) |condition| try self.allocator.dupe(u8, condition) else null,
            });
        }
        for (else_cursors.items) |cursor| {
            try cursors.append(self.allocator, .{
                .node_id = cursor.node_id,
                .condition = if (cursor.condition) |condition| try self.allocator.dupe(u8, condition) else null,
            });
        }
    }

    fn appendWorkflowCall(self: *ContractBuilder, expr: NodeIndex, cursors: *std.ArrayList(WorkflowCursor)) anyerror!bool {
        const tag = self.ir_view.getTag(expr) orelse return false;
        if (tag != .call) return false;

        const call = self.ir_view.getCall(expr) orelse return false;
        const workflow_call = (try self.describeWorkflowCall(call)) orelse return false;
        _ = try self.appendWorkflowNode(
            workflow_call.kind,
            workflow_call.label,
            workflow_call.detail,
            null,
            cursors,
        );
        return true;
    }

    fn isUnhandledWorkflowCall(self: *const ContractBuilder, expr: NodeIndex) bool {
        const tag = self.ir_view.getTag(expr) orelse return false;
        if (tag == .method_call) return true;
        if (tag == .call) {
            const call = self.ir_view.getCall(expr) orelse return true;
            return !self.isModeledWorkflowCall(call);
        }
        // The expression isn't itself a bare call, but a call anywhere in
        // its subtree (assignment target/value, binary/ternary operand,
        // etc.) is still an immediate side effect that appendWorkflowCall
        // cannot model as a graph node - treat it as unhandled rather than
        // silently dropping it and over-claiming proof_level == .complete.
        return self.containsUnmodeledCall(expr);
    }

    /// Returns true if a call/method_call appears anywhere in `root`'s
    /// expression subtree. Does not recurse into nested function/arrow
    /// bodies: a call there fires later, at its own statement, which is
    /// checked independently when that statement is walked.
    fn containsUnmodeledCall(self: *const ContractBuilder, root: NodeIndex) bool {
        if (root == null_node) return false;
        const tag = self.ir_view.getTag(root) orelse return false;
        switch (tag) {
            .call, .method_call => return true,
            .binary_op => {
                const expr = self.ir_view.getBinary(root) orelse return false;
                return self.containsUnmodeledCall(expr.left) or self.containsUnmodeledCall(expr.right);
            },
            .unary_op, .spread => {
                const expr = self.ir_view.getUnary(root) orelse return false;
                return self.containsUnmodeledCall(expr.operand);
            },
            .ternary => {
                const expr = self.ir_view.getTernary(root) orelse return false;
                return self.containsUnmodeledCall(expr.condition) or
                    self.containsUnmodeledCall(expr.then_branch) or
                    self.containsUnmodeledCall(expr.else_branch);
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(root) orelse return false;
                return self.containsUnmodeledCall(member.object) or self.containsUnmodeledCall(member.computed);
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(root) orelse return false;
                return self.containsUnmodeledCall(assign.target) or self.containsUnmodeledCall(assign.value);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(root) orelse return false;
                for (0..arr.elements_count) |i| {
                    if (self.containsUnmodeledCall(self.ir_view.getListIndex(arr.elements_start, @intCast(i)))) return true;
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(root) orelse return false;
                for (0..obj.properties_count) |i| {
                    if (self.containsUnmodeledCall(self.ir_view.getListIndex(obj.properties_start, @intCast(i)))) return true;
                }
            },
            .object_property => {
                const prop = self.ir_view.getProperty(root) orelse return false;
                return self.containsUnmodeledCall(prop.key) or self.containsUnmodeledCall(prop.value);
            },
            .template_literal => {
                const tmpl = self.ir_view.getTemplate(root) orelse return false;
                for (0..tmpl.parts_count) |i| {
                    if (self.containsUnmodeledCall(self.ir_view.getListIndex(tmpl.parts_start, @intCast(i)))) return true;
                }
            },
            .match_expr => {
                const match = self.ir_view.getMatchExpr(root) orelse return false;
                if (self.containsUnmodeledCall(match.discriminant)) return true;
                for (0..match.arms_count) |i| {
                    if (self.containsUnmodeledCall(self.ir_view.getListIndex(match.arms_start, @intCast(i)))) return true;
                }
            },
            .match_arm => {
                const arm = self.ir_view.getMatchArm(root) orelse return false;
                return self.containsUnmodeledCall(arm.pattern) or self.containsUnmodeledCall(arm.body);
            },
            // exhaustive: false means "no call in this subtree", and the caller
            // reads that as nothing to model. The arms above cover every
            // expression that can hold one. Nested function and arrow bodies are
            // excluded on purpose, per the doc comment: a call there fires at its
            // own statement, which is walked independently.
            else => {},
        }
        return false;
    }

    fn isModeledWorkflowCall(self: *const ContractBuilder, call: Node.CallExpr) bool {
        return self.isModuleBindingName(call.callee, "step") or
            self.isModuleBindingName(call.callee, "stepWithTimeout") or
            self.isModuleBindingName(call.callee, "sleep") or
            self.isModuleBindingName(call.callee, "sleepUntil") or
            self.isModuleBindingName(call.callee, "waitSignal") or
            self.isModuleBindingName(call.callee, "signal") or
            self.isModuleBindingName(call.callee, "signalAt");
    }

    fn deriveDurableWorkflowProperties(self: *ContractBuilder) !void {
        self.durable_workflow.properties.deinit(self.allocator);
        self.durable_workflow.properties = .{};

        if (self.durable_workflow.proof_level == .none) {
            try self.addWorkflowReason("durable workflow graph is not available");
            return;
        }
        if (self.durable_workflow.nodes.items.len == 0) {
            try self.addWorkflowReason("durable workflow graph has no modeled nodes");
            return;
        }
        if (self.durable_workflow.proof_level != .complete) {
            try self.addWorkflowReason("durable workflow proof is partial due to dynamic names, unmodeled calls, or multiple run calls");
            return;
        }

        var has_return = false;
        var has_wait_signal = false;
        var has_signal_producer = false;
        for (self.durable_workflow.nodes.items) |node| {
            switch (node.kind) {
                .return_response => has_return = true,
                .wait_signal => has_wait_signal = true,
                .signal, .signal_at => has_signal_producer = true,
                // exhaustive: this loop asks three yes/no questions of the graph, and
                // only the node kinds above answer any of them. The rest are
                // steps and sleeps, which bear on neither.
                else => {},
            }
        }

        if (!has_return) {
            try self.addWorkflowReason("durable workflow has no modeled response return");
            return;
        }
        if (has_signal_producer) {
            try self.addWorkflowReason("durable signal producers can duplicate external delivery and are not yet retry-safe");
            return;
        }

        self.durable_workflow.properties.idempotent = true;
        self.durable_workflow.properties.fault_covered = true;
        self.durable_workflow.properties.retry_safe = true;
        try self.addWorkflowReason("complete durable workflow graph uses stable keys, stable names, and modeled recovery nodes");
        if (has_wait_signal) {
            try self.addWorkflowReason("waitSignal resume is covered by durable signal claim recovery");
        }
    }

    fn addWorkflowReason(self: *ContractBuilder, reason: []const u8) !void {
        const owned_reason = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned_reason);
        try self.durable_workflow.properties.reasons.append(self.allocator, owned_reason);
    }

    const WorkflowCall = struct {
        kind: DurableWorkflowNodeKind,
        label: []const u8,
        detail: ?[]const u8 = null,
    };

    fn describeWorkflowCall(self: *ContractBuilder, call: Node.CallExpr) !?WorkflowCall {
        if (self.isModuleBindingName(call.callee, "step")) {
            const label = if (call.args_count > 0)
                self.workflowStringLabel(call.args_start, 0, "<dynamic step>")
            else
                try self.allocator.dupe(u8, "step");
            return .{ .kind = .step, .label = label };
        }
        if (self.isModuleBindingName(call.callee, "stepWithTimeout")) {
            const label = if (call.args_count > 0)
                self.workflowStringLabel(call.args_start, 0, "<dynamic step>")
            else
                try self.allocator.dupe(u8, "stepWithTimeout");
            return .{
                .kind = .step_with_timeout,
                .label = label,
                .detail = self.workflowNumberDetail(call.args_start, 1, "timeoutMs"),
            };
        }
        if (self.isModuleBindingName(call.callee, "sleep")) {
            return .{
                .kind = .sleep,
                .label = try self.allocator.dupe(u8, "sleep"),
                .detail = self.workflowNumberDetail(call.args_start, 0, "delayMs"),
            };
        }
        if (self.isModuleBindingName(call.callee, "sleepUntil")) {
            return .{
                .kind = .sleep_until,
                .label = try self.allocator.dupe(u8, "sleepUntil"),
                .detail = self.workflowNumberDetail(call.args_start, 0, "untilMs"),
            };
        }
        if (self.isModuleBindingName(call.callee, "waitSignal")) {
            const label = if (call.args_count > 0)
                self.workflowStringLabel(call.args_start, 0, "<dynamic signal>")
            else
                try self.allocator.dupe(u8, "waitSignal");
            return .{ .kind = .wait_signal, .label = label };
        }
        if (self.isModuleBindingName(call.callee, "signal")) {
            const label = if (call.args_count > 1)
                self.workflowStringLabel(call.args_start, 1, "<dynamic signal>")
            else
                try self.allocator.dupe(u8, "signal");
            return .{ .kind = .signal, .label = label };
        }
        if (self.isModuleBindingName(call.callee, "signalAt")) {
            const label = if (call.args_count > 1)
                self.workflowStringLabel(call.args_start, 1, "<dynamic signal>")
            else
                try self.allocator.dupe(u8, "signalAt");
            return .{
                .kind = .signal_at,
                .label = label,
                .detail = self.workflowNumberDetail(call.args_start, 2, "atMs"),
            };
        }
        return null;
    }

    fn appendReturnWorkflowNode(self: *ContractBuilder, node: NodeIndex, cursors: *std.ArrayList(WorkflowCursor)) !void {
        if (self.ir_view.getOptValue(node)) |ret_val| {
            if (self.returnExpressionHidesUnmodeledCall(ret_val)) {
                self.markWorkflowPartial();
            }
        }
        const status = self.extractWorkflowReturnStatus(node);
        const label = if (status) |code|
            try std.fmt.allocPrint(self.allocator, "Response {d}", .{code})
        else
            try self.allocator.dupe(u8, "Response");
        _ = try self.appendWorkflowNode(.return_response, label, null, status, cursors);
        self.deinitWorkflowCursors(cursors);
    }

    /// Unlike expr_stmt/var_decl, a return statement's expression is never
    /// routed through appendWorkflowCall/isUnhandledWorkflowCall, so a side
    /// effect placed directly in the return position (or nested in a
    /// Response.* helper's arguments) was silently unmodeled: the graph
    /// still got a clean `.return_response` node and the workflow could be
    /// proven retry-safe/idempotent while executing an unaccounted call on
    /// every (recovered) replay. A `Response.*` helper call itself is the
    /// expected, modeled shape - only its arguments are checked; any other
    /// bare call in return position is unmodeled by definition.
    fn returnExpressionHidesUnmodeledCall(self: *const ContractBuilder, ret_val: NodeIndex) bool {
        const tag = self.ir_view.getTag(ret_val) orelse return false;
        if (tag == .call) {
            if (self.ir_view.getCall(ret_val)) |call| {
                if (self.isResponseHelper(call.callee)) {
                    var i: u16 = 0;
                    while (i < call.args_count) : (i += 1) {
                        if (self.containsUnmodeledCall(self.ir_view.getListIndex(call.args_start, i))) return true;
                    }
                    return false;
                }
            }
            return true;
        }
        if (tag == .method_call) return true;
        return self.containsUnmodeledCall(ret_val);
    }

    fn appendWorkflowNode(
        self: *ContractBuilder,
        kind: DurableWorkflowNodeKind,
        label: []const u8,
        detail: ?[]const u8,
        status: ?u16,
        cursors: *std.ArrayList(WorkflowCursor),
    ) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "n{d}", .{self.durable_workflow.nodes.items.len + 1});
        for (cursors.items) |cursor| {
            try self.durable_workflow.edges.append(self.allocator, .{
                .from = try self.allocator.dupe(u8, cursor.node_id),
                .to = try self.allocator.dupe(u8, id),
                .condition = if (cursor.condition) |condition| try self.allocator.dupe(u8, condition) else null,
            });
        }
        try self.durable_workflow.nodes.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .label = label,
            .detail = detail,
            .status = status,
        });

        self.deinitWorkflowCursors(cursors);
        try cursors.append(self.allocator, .{
            .node_id = id,
            .condition = null,
        });
        return id;
    }

    fn deinitWorkflowCursors(self: *ContractBuilder, cursors: *std.ArrayList(WorkflowCursor)) void {
        for (cursors.items) |*cursor| cursor.deinit(self.allocator);
        cursors.deinit(self.allocator);
        cursors.* = .empty;
    }

    fn workflowStringLabel(
        self: *ContractBuilder,
        args_start: NodeIndex,
        arg_pos: u8,
        fallback: []const u8,
    ) []const u8 {
        const arg_idx = self.ir_view.getListIndex(args_start, arg_pos);
        if (self.getLiteralString(arg_idx)) |label| {
            return self.allocator.dupe(u8, label) catch fallback;
        }
        self.markWorkflowPartial();
        return self.allocator.dupe(u8, fallback) catch fallback;
    }

    fn workflowNumberDetail(self: *ContractBuilder, args_start: NodeIndex, arg_pos: u8, field_name: []const u8) ?[]const u8 {
        const arg_idx = self.ir_view.getListIndex(args_start, arg_pos);
        if (self.getLiteralNumber(arg_idx)) |num| {
            return std.fmt.allocPrint(self.allocator, "{s}={d}", .{ field_name, num }) catch null;
        }
        self.markWorkflowPartial();
        return null;
    }

    fn getLiteralNumber(self: *const ContractBuilder, node_idx: NodeIndex) ?i64 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        return switch (tag) {
            .lit_int => if (self.ir_view.getIntValue(node_idx)) |value| @as(i64, value) else null,
            .lit_float => blk: {
                const float_idx = self.ir_view.getFloatIdx(node_idx) orelse break :blk null;
                const value = self.ir_view.getFloat(float_idx) orelse break :blk null;
                if (@floor(value) != value) break :blk null;
                // @floatFromInt(maxInt(i64)) rounds up to 2^63 in f64; use strict
                // < on the max side so values that overflow i64 return null.
                if (value >= @as(f64, @floatFromInt(std.math.maxInt(i64))) or
                    value < @as(f64, @floatFromInt(std.math.minInt(i64)))) break :blk null;
                break :blk @intFromFloat(value);
            },
            // exhaustive: null means "not a literal number the compiler can read",
            // which leaves the value dynamic rather than pinning a wrong one.
            else => null,
        };
    }

    fn extractWorkflowReturnStatus(self: *const ContractBuilder, node: NodeIndex) ?u16 {
        const ret_val = self.ir_view.getOptValue(node) orelse return null;
        const ret_tag = self.ir_view.getTag(ret_val) orelse return null;
        if (ret_tag != .call and ret_tag != .method_call) return null;

        const call = self.ir_view.getCall(ret_val) orelse return null;
        if (!self.isResponseHelper(call.callee)) return null;
        if (call.args_count < 2) return 200;
        const status = self.extractStatusFromOptionsNode(self.ir_view.getListIndex(call.args_start, 1)) orelse return 200;
        return if (status >= 100 and status <= 599) status else 200;
    }

    fn isResponseHelper(self: *const ContractBuilder, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .member_access) return false;
        const member = self.ir_view.getMember(callee) orelse return false;

        const obj_tag = self.ir_view.getTag(member.object) orelse return false;
        if (obj_tag != .identifier) return false;
        const binding = self.ir_view.getBinding(member.object) orelse return false;
        if (binding.kind != .undeclared_global) return false;

        const obj_name = self.resolveAtomName(binding.name_atom) orelse return false;
        if (!std.mem.eql(u8, obj_name, "Response")) return false;

        const method_name = self.resolveAtomName(member.property) orelse return false;
        return std.mem.eql(u8, method_name, "json") or
            std.mem.eql(u8, method_name, "text") or
            std.mem.eql(u8, method_name, "html") or
            std.mem.eql(u8, method_name, "redirect");
    }

    fn buildWorkflowId(self: *ContractBuilder, handler_path: []const u8, handler_fn: NodeIndex, run_call_node: NodeIndex) ![]const u8 {
        const func = self.ir_view.getFunction(handler_fn) orelse return std.fmt.allocPrint(self.allocator, "{s}:workflow", .{handler_path});
        const func_name = if (func.name_atom != 0)
            (self.resolveAtomName(func.name_atom) orelse "handler")
        else
            "handler";
        const line = if (self.ir_view.getLoc(run_call_node)) |loc| loc.line else 0;
        const column = if (self.ir_view.getLoc(run_call_node)) |loc| loc.column else 0;
        return std.fmt.allocPrint(self.allocator, "{s}:{s}:{d}:{d}", .{
            handler_path,
            func_name,
            line,
            column,
        });
    }

    fn markWorkflowPartial(self: *ContractBuilder) void {
        self.durable_workflow.proof_level = .partial;
    }

    fn extractIntentAssertions(self: *ContractBuilder) !?contract_types.IntentInfo {
        return intent_extractor.extract(.{
            .allocator = self.allocator,
            .ir_view = self.ir_view,
            .resolver = intentAtomResolver,
            .resolver_ctx = @ptrCast(self),
        });
    }

    fn intentAtomResolver(atom_idx: u16, ctx: *const anyopaque) ?[]const u8 {
        const self: *const ContractBuilder = @ptrCast(@alignCast(ctx));
        return self.resolveAtomName(atom_idx);
    }

    fn extractSagaCalls(self: *ContractBuilder) !std.ArrayList(contract_types.SagaCallInfo) {
        return saga_extractor.extract(.{
            .allocator = self.allocator,
            .ir_view = self.ir_view,
            .resolver = intentAtomResolver,
            .resolver_ctx = @ptrCast(self),
        });
    }

    /// Append every `fanout([...])` descriptor's dispatch target into
    /// `self.workflow_calls`, alongside `call(name, init)`'s own extractions
    /// from `scanCallSites` above - the system linker resolves both through
    /// the same `workflow_call` proof.
    fn extractFanoutCalls(self: *ContractBuilder) !void {
        try fanout_extractor.extract(.{
            .allocator = self.allocator,
            .ir_view = self.ir_view,
            .resolver = intentAtomResolver,
            .resolver_ctx = @ptrCast(self),
        }, &self.workflow_calls);
    }

    fn resolveAtomName(self: *const ContractBuilder, atom_idx: u16) ?[]const u8 {
        // Try predefined atoms first
        const atom: object.Atom = @enumFromInt(atom_idx);
        if (atom.toPredefinedName()) |name| return name;

        // Try dynamic atom table
        if (self.atoms) |table| {
            return table.getName(atom);
        }
        return null;
    }

    fn extractSchemaCompile(self: *ContractBuilder, call: Node.CallExpr) !void {
        if (call.args_count < 2) {
            self.api_schemas_dynamic = true;
            return;
        }

        const name_idx = self.ir_view.getListIndex(call.args_start, 0);
        const name = self.getLiteralString(name_idx) orelse {
            self.api_schemas_dynamic = true;
            return;
        };

        const schema_idx = self.ir_view.getListIndex(call.args_start, 1);
        const schema_json = (try self.extractSchemaJson(schema_idx)) orelse {
            self.api_schemas_dynamic = true;
            return;
        };
        errdefer self.allocator.free(schema_json);

        try self.upsertApiSchema(name, schema_json);
    }

    fn extractSqlRegistration(self: *ContractBuilder, call: Node.CallExpr) !void {
        if (call.args_count < 2) {
            self.sql_dynamic = true;
            return;
        }

        const name_idx = self.ir_view.getListIndex(call.args_start, 0);
        const query_name = self.getLiteralString(name_idx) orelse {
            self.sql_dynamic = true;
            return;
        };

        const stmt_idx = self.ir_view.getListIndex(call.args_start, 1);
        const statement = self.getLiteralString(stmt_idx) orelse {
            self.sql_dynamic = true;
            return;
        };

        for (self.sql_queries.items) |query| {
            if (!std.mem.eql(u8, query.name, query_name)) continue;
            if (std.mem.eql(u8, query.statement, statement)) return;
            return error.DuplicateSqlQueryName;
        }

        try self.sql_queries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, query_name),
            .statement = try self.allocator.dupe(u8, statement),
            .operation = "",
            .tables = .empty,
        });
    }

    fn extractSchemaJson(self: *ContractBuilder, node_idx: NodeIndex) !?[]u8 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        switch (tag) {
            .lit_string => {
                const raw = self.getLiteralString(node_idx) orelse return null;
                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return null;
                defer parsed.deinit();
                return try self.allocator.dupe(u8, raw);
            },
            .call => {
                const json_arg = self.getJsonStringifyArg(node_idx) orelse return null;
                return try self.serializeJsonLiteral(json_arg);
            },
            // exhaustive: null is how a non-literal schema argument is spelled, and
            // the caller answers it by setting `api_schemas_dynamic`. Reporting
            // an unreadable schema as unanalyzable is the conservative outcome.
            else => return null,
        }
    }

    fn getJsonStringifyArg(self: *const ContractBuilder, node_idx: NodeIndex) ?NodeIndex {
        const call = self.ir_view.getCall(node_idx) orelse return null;
        if (call.args_count != 1) return null;

        const callee_tag = self.ir_view.getTag(call.callee) orelse return null;
        if (callee_tag != .member_access) return null;

        const member = self.ir_view.getMember(call.callee) orelse return null;
        if (member.property != @intFromEnum(object.Atom.stringify)) return null;

        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
        if (obj_tag != .identifier) return null;

        const binding = self.ir_view.getBinding(member.object) orelse return null;
        if (binding.kind != .global and binding.kind != .undeclared_global) return null;
        if (binding.name_atom != @intFromEnum(object.Atom.JSON)) return null;

        return self.ir_view.getListIndex(call.args_start, 0);
    }

    fn serializeJsonLiteral(self: *ContractBuilder, node_idx: NodeIndex) !?[]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &output);
        const ok = try self.writeJsonLiteralNode(node_idx, &aw.writer);
        if (!ok) {
            output.deinit(self.allocator);
            return null;
        }
        output = aw.toArrayList();
        return try output.toOwnedSlice(self.allocator);
    }

    fn writeJsonLiteralNode(self: *ContractBuilder, node_idx: NodeIndex, writer: anytype) !bool {
        const tag = self.ir_view.getTag(node_idx) orelse return false;
        switch (tag) {
            .lit_int => {
                const value = self.ir_view.getIntValue(node_idx) orelse return false;
                try writer.print("{d}", .{value});
                return true;
            },
            .lit_float => {
                const float_idx = self.ir_view.getFloatIdx(node_idx) orelse return false;
                const value = self.ir_view.getFloat(float_idx) orelse return false;
                try writer.print("{d}", .{value});
                return true;
            },
            .lit_string => {
                const value = self.getLiteralString(node_idx) orelse return false;
                try writeJsonString(writer, value);
                return true;
            },
            .lit_bool => {
                const value = self.ir_view.getBoolValue(node_idx) orelse return false;
                try writer.writeAll(if (value) "true" else "false");
                return true;
            },
            .lit_null => {
                try writer.writeAll("null");
                return true;
            },
            .unary_op => {
                const unary = self.ir_view.getUnary(node_idx) orelse return false;
                if (unary.op != .neg) return false;
                try writer.writeByte('-');
                return self.writeJsonLiteralNode(unary.operand, writer);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node_idx) orelse return false;
                try writer.writeByte('[');
                var i: u16 = 0;
                while (i < arr.elements_count) : (i += 1) {
                    if (i > 0) try writer.writeAll(", ");
                    const elem_idx = self.ir_view.getListIndex(arr.elements_start, i);
                    if (!try self.writeJsonLiteralNode(elem_idx, writer)) return false;
                }
                try writer.writeByte(']');
                return true;
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node_idx) orelse return false;
                try writer.writeByte('{');
                var i: u16 = 0;
                while (i < obj.properties_count) : (i += 1) {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
                    const prop_tag = self.ir_view.getTag(prop_idx) orelse return false;
                    if (prop_tag != .object_property) return false;

                    const prop = self.ir_view.getProperty(prop_idx) orelse return false;
                    const key = self.getObjectPropertyKey(prop.key) orelse return false;

                    if (i > 0) try writer.writeAll(", ");
                    try writeJsonString(writer, key);
                    try writer.writeAll(": ");
                    if (!try self.writeJsonLiteralNode(prop.value, writer)) return false;
                }
                try writer.writeByte('}');
                return true;
            },
            // exhaustive: false abandons the literal serialization, so the caller
            // treats the value as dynamic instead of recording a partial one.
            else => return false,
        }
    }

    fn getObjectPropertyKey(self: *const ContractBuilder, key_idx: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(key_idx) orelse return null;
        return switch (tag) {
            .lit_string => self.getLiteralString(key_idx),
            .identifier => blk: {
                const binding = self.ir_view.getBinding(key_idx) orelse break :blk null;
                break :blk self.resolveAtomName(binding.name_atom);
            },
            // exhaustive: an object key is a string literal or a bare identifier. A
            // computed key is not statically known, and null stops the read
            // rather than inventing a name.
            else => null,
        };
    }

    fn getLiteralString(self: *const ContractBuilder, node_idx: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        if (tag != .lit_string) return null;
        const str_idx = self.ir_view.getStringIdx(node_idx) orelse return null;
        return self.ir_view.getString(str_idx);
    }

    fn upsertApiSchema(self: *ContractBuilder, name: []const u8, schema_json: []const u8) !void {
        for (self.api_schemas.items) |*schema| {
            if (std.mem.eql(u8, schema.name, name)) {
                self.allocator.free(schema.schema_json);
                schema.schema_json = schema_json;
                return;
            }
        }

        try self.api_schemas.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .schema_json = schema_json,
        });
    }

    fn extractApiRoutesFromCall(self: *ContractBuilder, call: Node.CallExpr) !void {
        if (call.args_count < 1) {
            self.api_routes_dynamic = true;
            return;
        }

        const routes_arg = self.ir_view.getListIndex(call.args_start, 0);
        const routes_obj = self.resolveObjectLiteralNode(routes_arg) orelse {
            self.api_routes_dynamic = true;
            return;
        };

        try self.extractApiRoutesFromObject(routes_obj);
    }

    /// Extract the affordance set from a `resource(data, affordances)` call.
    /// Strict-literal and fail-closed: a computed affordances argument sets
    /// `affordances_dynamic`; an affordance whose `href`/`method` is non-literal
    /// (or whose value is not an object literal) is recorded with `dynamic=true`
    /// so the system linker counts it but never claims it resolved.
    fn extractAffordances(self: *ContractBuilder, call: Node.CallExpr) !void {
        if (call.args_count < 2) return;

        const aff_arg_idx = self.ir_view.getListIndex(call.args_start, 1);
        const aff_obj_node = self.resolveObjectLiteralNode(aff_arg_idx) orelse {
            self.affordances_dynamic = true;
            return;
        };
        const aff_obj = self.ir_view.getObject(aff_obj_node) orelse {
            self.affordances_dynamic = true;
            return;
        };

        var i: u16 = 0;
        while (i < aff_obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(aff_obj.properties_start, i);
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const rel = self.getObjectPropertyKey(prop.key) orelse continue;
            try self.extractOneAffordance(rel, prop.value);
        }
    }

    fn extractOneAffordance(self: *ContractBuilder, rel: []const u8, value_idx: NodeIndex) !void {
        var href: []const u8 = "";
        var method: []const u8 = "GET";
        var dynamic = false;

        if (self.resolveObjectLiteralNode(value_idx)) |obj_node| {
            if (self.ir_view.getObject(obj_node)) |obj| {
                var j: u16 = 0;
                while (j < obj.properties_count) : (j += 1) {
                    const p_idx = self.ir_view.getListIndex(obj.properties_start, j);
                    const p = self.ir_view.getProperty(p_idx) orelse continue;
                    const key = self.getObjectPropertyKey(p.key) orelse continue;
                    if (std.mem.eql(u8, key, "href")) {
                        if (self.getLiteralString(p.value)) |h| href = h else dynamic = true;
                    } else if (std.mem.eql(u8, key, "method")) {
                        if (self.getLiteralString(p.value)) |m| method = m else dynamic = true;
                    }
                }
                // An affordance object literal with no statically-known href
                // cannot be resolved to a route.
                if (href.len == 0) dynamic = true;
            } else {
                dynamic = true;
            }
        } else {
            dynamic = true;
        }

        const templated = std.mem.indexOfScalar(u8, href, '{') != null;

        const rel_owned = try self.allocator.dupe(u8, rel);
        errdefer self.allocator.free(rel_owned);
        const method_owned = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_owned);
        const href_owned = try self.allocator.dupe(u8, href);
        errdefer self.allocator.free(href_owned);

        try self.affordances.append(self.allocator, .{
            .rel = rel_owned,
            .method = method_owned,
            .href = href_owned,
            .templated = templated,
            .dynamic = dynamic,
        });
    }

    fn extractServiceCall(self: *ContractBuilder, call: Node.CallExpr) !void {
        var service_call = ServiceCallInfo{
            .service = try self.allocator.dupe(u8, ""),
            .route_pattern = try self.allocator.dupe(u8, ""),
        };
        errdefer service_call.deinit(self.allocator);

        if (call.args_count < 2) {
            service_call.dynamic = true;
            try self.service_calls.append(self.allocator, service_call);
            return;
        }

        const service_idx = self.ir_view.getListIndex(call.args_start, 0);
        if (self.getLiteralString(service_idx)) |service_name| {
            self.allocator.free(service_call.service);
            service_call.service = try self.allocator.dupe(u8, service_name);
        } else {
            service_call.dynamic = true;
        }

        const route_idx = self.ir_view.getListIndex(call.args_start, 1);
        if (self.getLiteralString(route_idx)) |route_pattern| {
            self.allocator.free(service_call.route_pattern);
            service_call.route_pattern = try self.allocator.dupe(u8, route_pattern);
        } else {
            service_call.dynamic = true;
        }

        if (call.args_count > 2) {
            const init_idx = self.ir_view.getListIndex(call.args_start, 2);
            try self.extractServiceCallInit(init_idx, &service_call);
        }

        try self.service_calls.append(self.allocator, service_call);
    }

    fn extractServiceCallInit(self: *ContractBuilder, init_idx: NodeIndex, service_call: *ServiceCallInfo) !void {
        const tag = self.ir_view.getTag(init_idx) orelse {
            service_call.markAllDynamic(self.allocator);
            return;
        };
        if (tag == .lit_null or tag == .lit_undefined) return;

        const init_obj = self.resolveObjectLiteralNode(init_idx) orelse {
            service_call.markAllDynamic(self.allocator);
            return;
        };
        const obj = self.ir_view.getObject(init_obj) orelse return;

        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const key = self.getObjectPropertyKey(prop.key) orelse continue;

            if (std.mem.eql(u8, key, "params")) {
                service_call.path_params.deinitOwned(self.allocator);
                service_call.path_params = try self.extractKnownList(prop.value);
            } else if (std.mem.eql(u8, key, "query")) {
                service_call.query_keys.deinitOwned(self.allocator);
                service_call.query_keys = try self.extractKnownList(prop.value);
            } else if (std.mem.eql(u8, key, "headers")) {
                service_call.header_keys.deinitOwned(self.allocator);
                service_call.header_keys = try self.extractKnownList(prop.value);
            } else if (std.mem.eql(u8, key, "body")) {
                const body_tag = self.ir_view.getTag(prop.value) orelse {
                    service_call.body = .dynamic;
                    continue;
                };
                if (body_tag == .lit_null or body_tag == .lit_undefined) continue;
                service_call.body = if (body_tag == .lit_string) .present else .dynamic;
            }
        }
    }

    /// Extract a `call(name, init?)` dispatch target for the system linker's
    /// `workflow_call` resolution. Mirrors `extractServiceCall`'s
    /// strict-literal-or-dynamic discipline but simpler: `init` has no
    /// path-param-templating or required-query/header proof surface, so only
    /// `method`/`path` feed the synthesized route pattern. Also used by
    /// `fanout_extractor.zig` for each descriptor in a `fanout([...])` array,
    /// and fires automatically for `call(...)` sites nested inside a
    /// `saga([...])` step's `run`/`compensate` closures (the flat, non-nesting-
    /// aware `scanCallSites` walk finds them independently of `saga_extractor`).
    fn extractWorkflowCall(self: *ContractBuilder, call: Node.CallExpr) !void {
        var wc = contract_types.WorkflowCallInfo{
            .target = try self.allocator.dupe(u8, ""),
            .route_pattern = try self.allocator.dupe(u8, ""),
        };
        errdefer wc.deinit(self.allocator);

        if (call.args_count < 1) {
            wc.dynamic = true;
            try self.workflow_calls.append(self.allocator, wc);
            return;
        }

        const name_idx = self.ir_view.getListIndex(call.args_start, 0);
        if (self.getLiteralString(name_idx)) |name| {
            self.allocator.free(wc.target);
            wc.target = try self.allocator.dupe(u8, name);
        } else {
            wc.dynamic = true;
        }

        var method: []const u8 = "GET";
        var path: []const u8 = "/";

        if (call.args_count > 1) {
            const init_idx = self.ir_view.getListIndex(call.args_start, 1);
            self.extractWorkflowCallInit(init_idx, &wc, &method, &path);
        }

        self.allocator.free(wc.route_pattern);
        wc.route_pattern = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ method, path });

        try self.workflow_calls.append(self.allocator, wc);
    }

    /// Parse a `call(name, init)` init object. Recognizes `method`/`path`
    /// (literal strings) and `body`/`headers` (presence only, no proof
    /// surface). Marks `wc.dynamic` on a malformed init node, a non-object
    /// init, an unresolvable property key, a non-literal `method`/`path`
    /// value, or an unrecognized init key - failing closed on unknown keys
    /// exactly like `fanout_extractor.parseDescriptor`. A `null`/`undefined`
    /// init keeps the defaults and stays static. Mirrors
    /// `extractServiceCallInit`'s guard-clause shape.
    fn extractWorkflowCallInit(
        self: *ContractBuilder,
        init_idx: NodeIndex,
        wc: *contract_types.WorkflowCallInfo,
        method: *[]const u8,
        path: *[]const u8,
    ) void {
        const init_tag = self.ir_view.getTag(init_idx) orelse {
            wc.dynamic = true;
            return;
        };
        if (init_tag == .lit_null or init_tag == .lit_undefined) return;

        const init_obj = self.resolveObjectLiteralNode(init_idx) orelse {
            wc.dynamic = true;
            return;
        };
        const obj = self.ir_view.getObject(init_obj) orelse {
            wc.dynamic = true;
            return;
        };

        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const key = self.getObjectPropertyKey(prop.key) orelse {
                wc.dynamic = true;
                continue;
            };
            if (std.mem.eql(u8, key, "method")) {
                if (self.getLiteralString(prop.value)) |m| method.* = m else wc.dynamic = true;
            } else if (std.mem.eql(u8, key, "path")) {
                if (self.getLiteralString(prop.value)) |p| path.* = p else wc.dynamic = true;
            } else if (std.mem.eql(u8, key, "body") or std.mem.eql(u8, key, "headers")) {
                // Presence only; no proof surface (mirrors fanout descriptors).
            } else {
                // Unknown init key: fail closed to dynamic, exactly like
                // fanout_extractor.parseDescriptor rejects unknown siblings.
                wc.dynamic = true;
            }
        }
    }

    fn extractKnownList(self: *ContractBuilder, node_idx: NodeIndex) !ServiceCallInfo.KnownList {
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| self.allocator.free(s);
            items.deinit(self.allocator);
        }
        var dynamic = false;
        try self.extractServiceObjectKeys(node_idx, &items, &dynamic);
        if (dynamic) {
            for (items.items) |s| self.allocator.free(s);
            items.deinit(self.allocator);
            return .dynamic;
        }
        return .{ .complete = items };
    }

    fn extractServiceObjectKeys(
        self: *ContractBuilder,
        node_idx: NodeIndex,
        target: *std.ArrayList([]const u8),
        dynamic_flag: *bool,
    ) !void {
        const obj_idx = self.resolveObjectLiteralNode(node_idx) orelse {
            dynamic_flag.* = true;
            return;
        };
        const obj = self.ir_view.getObject(obj_idx) orelse {
            dynamic_flag.* = true;
            return;
        };

        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop_tag = self.ir_view.getTag(prop_idx) orelse {
                dynamic_flag.* = true;
                continue;
            };
            if (prop_tag != .object_property) {
                dynamic_flag.* = true;
                continue;
            }

            const prop = self.ir_view.getProperty(prop_idx) orelse {
                dynamic_flag.* = true;
                continue;
            };
            const key = self.getObjectPropertyKey(prop.key) orelse {
                dynamic_flag.* = true;
                continue;
            };

            if (!containsString(target.items, key)) {
                try target.append(self.allocator, try self.allocator.dupe(u8, key));
            }
        }
    }

    fn resolveObjectLiteralNode(self: *const ContractBuilder, node_idx: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        switch (tag) {
            .object_literal => return node_idx,
            .identifier => {
                const binding = self.ir_view.getBinding(node_idx) orelse return null;
                return self.findObjectLiteralBinding(binding.slot);
            },
            // exhaustive: null means no object literal was resolved, which leaves
            // the fact unextracted rather than extracted wrongly.
            else => return null,
        }
    }

    fn findObjectLiteralBinding(self: *const ContractBuilder, slot: u16) ?NodeIndex {
        const init_node = self.findBindingInitNode(slot) orelse return null;
        if (self.ir_view.getTag(init_node) == .object_literal) return init_node;
        return null;
    }

    fn findBindingInitNode(self: *const ContractBuilder, slot: u16) ?NodeIndex {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .var_decl) continue;

            const decl = self.ir_view.getVarDecl(idx) orelse continue;
            if (decl.binding.slot != slot or decl.init == null_node) continue;
            return decl.init;
        }
        return null;
    }

    fn findFunctionNodeByBinding(self: *const ContractBuilder, slot: u16) ?NodeIndex {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            switch (tag) {
                .function_decl => {
                    const decl = self.ir_view.getVarDecl(idx) orelse continue;
                    if (decl.binding.slot != slot or decl.init == null_node) continue;
                    const init_tag = self.ir_view.getTag(decl.init) orelse continue;
                    if (init_tag == .function_expr or init_tag == .arrow_function) return decl.init;
                },
                .var_decl => {
                    const decl = self.ir_view.getVarDecl(idx) orelse continue;
                    if (decl.binding.slot != slot or decl.init == null_node) continue;
                    const init_tag = self.ir_view.getTag(decl.init) orelse continue;
                    if (init_tag == .function_expr or init_tag == .arrow_function) return decl.init;
                },
                // exhaustive: only a declaration can bind a function to the slot being
                // searched for. Other statement kinds bind nothing and are skipped.
                else => {},
            }
        }
        return null;
    }

    fn resolveFunctionNode(self: *const ContractBuilder, node_idx: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        switch (tag) {
            .function_decl => {
                const decl = self.ir_view.getVarDecl(node_idx) orelse return null;
                return if (decl.init != null_node) decl.init else null;
            },
            .function_expr, .arrow_function => return node_idx,
            .identifier => {
                const binding = self.ir_view.getBinding(node_idx) orelse return null;
                return self.findFunctionNodeByBinding(binding.slot);
            },
            // exhaustive: null means the expression does not resolve to a function
            // body this can read, so the caller extracts no facts from it rather
            // than facts from the wrong node.
            else => return null,
        }
    }

    fn extractApiRoutesFromObject(self: *ContractBuilder, object_idx: NodeIndex) !void {
        const obj = self.ir_view.getObject(object_idx) orelse return;

        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop_tag = self.ir_view.getTag(prop_idx) orelse continue;
            if (prop_tag != .object_property) continue;

            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const route_key = self.getObjectPropertyKey(prop.key) orelse {
                self.api_routes_dynamic = true;
                continue;
            };
            const parsed = parseRouteKey(route_key) orelse {
                self.api_routes_dynamic = true;
                continue;
            };

            if (self.hasApiRoute(parsed.method, parsed.path)) continue;

            var route = ApiRouteInfo{
                .method = try self.allocator.dupe(u8, parsed.method),
                .path = try self.allocator.dupe(u8, parsed.path),
                .request_schema_refs = .empty,
                .request_schema_dynamic = false,
                .requires_bearer = false,
                .requires_jwt = false,
            };
            errdefer route.deinit(self.allocator);
            try self.appendPathParams(&route);

            if (self.resolveFunctionNode(prop.value)) |fn_node| {
                try self.populateApiRouteFacts(&route, fn_node);
            } else {
                self.api_routes_dynamic = true;
            }

            try self.api_routes.append(self.allocator, route);
        }
    }

    fn hasApiRoute(self: *const ContractBuilder, method: []const u8, path: []const u8) bool {
        for (self.api_routes.items) |route| {
            if (std.mem.eql(u8, route.method, method) and std.mem.eql(u8, route.path, path)) {
                return true;
            }
        }
        return false;
    }

    fn populateApiRouteFacts(self: *ContractBuilder, route: *ApiRouteInfo, fn_node: NodeIndex) !void {
        var analyzer = handler_analyzer.HandlerAnalyzer.init(self.allocator, self.ir_view, self.atoms);
        defer analyzer.deinit();

        if (try analyzer.analyzeDirectReturn(fn_node)) |response| {
            defer if (response.body.len > 0) self.allocator.free(response.body);
            route.response_status = response.status;
            route.response_content_type = try self.allocator.dupe(u8, contentTypeFor(response.content_type_idx));
        }

        const func = self.ir_view.getFunction(fn_node) orelse return;
        const request_binding_slot = self.findRequestBindingSlot(func);
        try self.scanFunctionNodeForApiFacts(func.body, request_binding_slot, route);
        try self.syncRouteRequestBodies(route);
        try self.syncLegacyRouteResponse(route);
    }

    fn findRequestBindingSlot(self: *const ContractBuilder, func: Node.FunctionExpr) ?u16 {
        if (func.params_count == 0) return null;
        const req_param = self.ir_view.getListIndex(func.params_start, 0);
        const req_tag = self.ir_view.getTag(req_param) orelse return null;
        if (req_tag == .identifier) {
            const binding = self.ir_view.getBinding(req_param) orelse return null;
            if (binding.kind == .local or binding.kind == .argument) return binding.slot;
            return null;
        }
        if (req_tag == .pattern_element) {
            const elem = self.ir_view.getPatternElem(req_param) orelse return null;
            if (elem.binding.kind == .local or elem.binding.kind == .argument) return elem.binding.slot;
        }
        return null;
    }

    fn scanFunctionNodeForApiFacts(
        self: *ContractBuilder,
        node_idx: NodeIndex,
        request_binding_slot: ?u16,
        route: *ApiRouteInfo,
    ) !void {
        if (node_idx == null_node) return;

        const tag = self.ir_view.getTag(node_idx) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node_idx) orelse return;
                var i: u16 = 0;
                while (i < block.stmts_count) : (i += 1) {
                    try self.scanFunctionNodeForApiFacts(self.ir_view.getListIndex(block.stmts_start, i), request_binding_slot, route);
                }
            },
            .expr_stmt, .throw_stmt => {
                if (self.ir_view.getOptValue(node_idx)) |value_node| {
                    try self.scanFunctionNodeForApiFacts(value_node, request_binding_slot, route);
                }
            },
            .return_stmt => {
                if (self.ir_view.getOptValue(node_idx)) |value_node| {
                    try self.captureApiResponse(value_node, route);
                    try self.scanFunctionNodeForApiFacts(value_node, request_binding_slot, route);
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node_idx) orelse return;
                if (decl.init != null_node) try self.scanFunctionNodeForApiFacts(decl.init, request_binding_slot, route);
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(if_stmt.condition, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(if_stmt.then_branch, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(if_stmt.else_branch, request_binding_slot, route);
            },
            .switch_stmt => {
                const switch_stmt = self.ir_view.getSwitchStmt(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(switch_stmt.discriminant, request_binding_slot, route);
                var i: u8 = 0;
                while (i < switch_stmt.cases_count) : (i += 1) {
                    try self.scanFunctionNodeForApiFacts(self.ir_view.getListIndex(switch_stmt.cases_start, i), request_binding_slot, route);
                }
            },
            .case_clause => {
                const case_clause = self.ir_view.getCaseClause(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(case_clause.test_expr, request_binding_slot, route);
                var i: u16 = 0;
                while (i < case_clause.body_count) : (i += 1) {
                    try self.scanFunctionNodeForApiFacts(self.ir_view.getListIndex(case_clause.body_start, i), request_binding_slot, route);
                }
            },
            .for_of_stmt, .for_in_stmt => {
                const for_iter = self.ir_view.getForIter(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(for_iter.iterable, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(for_iter.body, request_binding_slot, route);
            },
            .binary_op => {
                const binary = self.ir_view.getBinary(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(binary.left, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(binary.right, request_binding_slot, route);
            },
            .unary_op => {
                const unary = self.ir_view.getUnary(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(unary.operand, request_binding_slot, route);
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(ternary.condition, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(ternary.then_branch, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(ternary.else_branch, request_binding_slot, route);
            },
            .assignment => {
                const assignment = self.ir_view.getAssignment(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(assignment.target, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(assignment.value, request_binding_slot, route);
            },
            .array_literal => {
                const array = self.ir_view.getArray(node_idx) orelse return;
                var i: u16 = 0;
                while (i < array.elements_count) : (i += 1) {
                    try self.scanFunctionNodeForApiFacts(self.ir_view.getListIndex(array.elements_start, i), request_binding_slot, route);
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node_idx) orelse return;
                var i: u16 = 0;
                while (i < obj.properties_count) : (i += 1) {
                    try self.scanFunctionNodeForApiFacts(self.ir_view.getListIndex(obj.properties_start, i), request_binding_slot, route);
                }
            },
            .object_property => {
                const prop = self.ir_view.getProperty(node_idx) orelse return;
                if (prop.is_computed) try self.scanFunctionNodeForApiFacts(prop.key, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(prop.value, request_binding_slot, route);
            },
            .member_access, .computed_access, .optional_chain => {
                try self.captureApiRequestAccess(node_idx, request_binding_slot, route);
                const member = self.ir_view.getMember(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(member.object, request_binding_slot, route);
                try self.scanFunctionNodeForApiFacts(member.computed, request_binding_slot, route);
            },
            .call, .method_call, .optional_call => {
                const call = self.ir_view.getCall(node_idx) orelse return;
                try self.captureApiHeaderGetter(call, request_binding_slot, route);
                const callee_tag = self.ir_view.getTag(call.callee) orelse return;
                if (callee_tag == .identifier) {
                    const binding = self.ir_view.getBinding(call.callee) orelse return;
                    if (self.isBindingCategory(binding.slot, .request_schema)) {
                        const fn_name = self.resolveAtomName(binding.name_atom);
                        const is_decode_query = fn_name != null and std.mem.eql(u8, fn_name.?, "decodeQuery");

                        if (!is_decode_query) {
                            try self.extractLiteralArg(call, .{ .list = &route.request_schema_refs, .dynamic = &route.request_schema_dynamic }, null);
                        }

                        if (call.args_count > 0) {
                            const schema_idx = self.ir_view.getListIndex(call.args_start, 0);
                            if (self.getLiteralString(schema_idx)) |schema_ref| {
                                try self.classifyRequestSchemaCall(route, fn_name, schema_ref);
                            } else if (is_decode_query) {
                                route.query_params_dynamic = true;
                            }
                        }
                    } else {
                        // Check for auth flags via generic bindings
                        for (self.factsRef().generic_bindings.items) |gb| {
                            if (gb.slot == binding.slot) {
                                if (gb.flags.sets_bearer_auth) route.requires_bearer = true;
                                if (gb.flags.sets_jwt_auth) route.requires_jwt = true;
                                break;
                            }
                        }
                    }
                }
                try self.scanFunctionNodeForApiFacts(call.callee, request_binding_slot, route);
                var i: u8 = 0;
                while (i < call.args_count) : (i += 1) {
                    try self.scanFunctionNodeForApiFacts(self.ir_view.getListIndex(call.args_start, i), request_binding_slot, route);
                }
            },
            .match_expr => {
                const match_expr = self.ir_view.getMatchExpr(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(match_expr.discriminant, request_binding_slot, route);
                var i: u8 = 0;
                while (i < match_expr.arms_count) : (i += 1) {
                    try self.scanFunctionNodeForApiFacts(self.ir_view.getListIndex(match_expr.arms_start, i), request_binding_slot, route);
                }
            },
            .match_arm => {
                const arm = self.ir_view.getMatchArm(node_idx) orelse return;
                try self.scanFunctionNodeForApiFacts(arm.body, request_binding_slot, route);
            },
            .break_stmt, .continue_stmt => {},
            .function_decl, .function_expr, .arrow_function => return,
            // exhaustive: API facts are read from the response-producing constructs
            // above. What remains holds no route, status, or schema to record,
            // and a missed fact leaves contract.json quieter, never wronger.
            else => {},
        }
    }

    const ResponseSchemaCandidate = struct {
        status: ?u16 = null,
        content_type: ?[]const u8 = null, // static literal
        schema_ref: ?[]const u8 = null, // owned
        schema_json: ?[]u8 = null, // owned
        dynamic: bool = false,

        fn deinit(self: *ResponseSchemaCandidate, allocator: std.mem.Allocator) void {
            if (self.schema_ref) |schema_ref| allocator.free(schema_ref);
            if (self.schema_json) |schema_json| allocator.free(schema_json);
        }
    };

    fn appendPathParams(self: *ContractBuilder, route: *ApiRouteInfo) !void {
        var i: usize = 0;
        while (i < route.path.len) : (i += 1) {
            if (route.path[i] != ':') continue;

            const start = i + 1;
            var end = start;
            while (end < route.path.len and route.path[end] != '/') : (end += 1) {}
            if (end <= start) continue;

            const name = route.path[start..end];
            if (containsApiParam(route.path_params.items, name)) continue;

            try route.path_params.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name),
                .location = "path",
                .required = true,
                .schema_json = try self.allocator.dupe(u8, "{\"type\":\"string\"}"),
            });
            i = end;
        }
    }

    fn captureApiResponse(self: *ContractBuilder, node_idx: NodeIndex, route: *ApiRouteInfo) !void {
        var candidate = (try self.analyzeApiResponse(node_idx)) orelse return;
        defer candidate.deinit(self.allocator);
        try self.mergeResponseCandidate(route, &candidate);
    }

    fn analyzeApiResponse(self: *ContractBuilder, node_idx: NodeIndex) !?ResponseSchemaCandidate {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        if (tag != .call) return null;

        const call = self.ir_view.getCall(node_idx) orelse return null;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return null;
        if (callee_tag != .member_access) return null;

        const member = self.ir_view.getMember(call.callee) orelse return null;
        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
        if (obj_tag != .identifier) return null;

        const binding = self.ir_view.getBinding(member.object) orelse return null;
        if (binding.kind != .global and binding.kind != .undeclared_global) return null;
        if (binding.name_atom != @intFromEnum(object.Atom.Response)) return null;

        var candidate = ResponseSchemaCandidate{};
        errdefer candidate.deinit(self.allocator);

        switch (@as(object.Atom, @enumFromInt(member.property))) {
            .json => {
                candidate.status = 200;
                candidate.content_type = "application/json";
                if (call.args_count >= 2) {
                    const options_idx = self.ir_view.getListIndex(call.args_start, 1);
                    candidate.status = self.extractStatusFromOptionsNode(options_idx);
                }
                if (call.args_count == 0) {
                    candidate.schema_json = try self.allocator.dupe(u8, "{\"type\":\"object\"}");
                    return candidate;
                }

                const payload_idx = self.ir_view.getListIndex(call.args_start, 0);
                if (try self.extractResponseSchemaRef(payload_idx)) |schema_ref| {
                    candidate.schema_ref = schema_ref;
                    return candidate;
                }
                if (try self.extractResponseSchemaJson(payload_idx)) |schema_json| {
                    candidate.schema_json = schema_json;
                    return candidate;
                }

                candidate.dynamic = true;
                return candidate;
            },
            .text => {
                candidate.status = 200;
                candidate.content_type = "text/plain; charset=utf-8";
                if (call.args_count >= 2) {
                    const options_idx = self.ir_view.getListIndex(call.args_start, 1);
                    candidate.status = self.extractStatusFromOptionsNode(options_idx);
                }
                return candidate;
            },
            .html => {
                candidate.status = 200;
                candidate.content_type = "text/html; charset=utf-8";
                if (call.args_count >= 2) {
                    const options_idx = self.ir_view.getListIndex(call.args_start, 1);
                    candidate.status = self.extractStatusFromOptionsNode(options_idx);
                }
                return candidate;
            },
            .rawJson => {
                candidate.status = 200;
                candidate.content_type = "application/json";
                if (call.args_count >= 2) {
                    const options_idx = self.ir_view.getListIndex(call.args_start, 1);
                    candidate.status = self.extractStatusFromOptionsNode(options_idx);
                }
                return candidate;
            },
            // exhaustive: null means this call is not a Response helper, so there is
            // no documented response to describe.
            else => return null,
        }
    }

    fn mergeResponseCandidate(
        self: *ContractBuilder,
        route: *ApiRouteInfo,
        candidate: *ResponseSchemaCandidate,
    ) !void {
        if (candidate.dynamic) route.responses_dynamic = true;
        try self.appendResponseVariant(route, candidate);
    }

    fn captureApiRequestAccess(
        self: *ContractBuilder,
        node_idx: NodeIndex,
        request_binding_slot: ?u16,
        route: *ApiRouteInfo,
    ) !void {
        const request_slot = request_binding_slot orelse return;
        const tag = self.ir_view.getTag(node_idx) orelse return;
        if (tag != .member_access and tag != .computed_access and tag != .optional_chain) return;

        const member = self.ir_view.getMember(node_idx) orelse return;
        const root_property = self.requestRootProperty(member.object, request_slot) orelse return;
        const leaf_name = self.memberAccessName(member) orelse {
            if (std.mem.eql(u8, root_property, "query")) {
                route.query_params_dynamic = true;
            } else if (std.mem.eql(u8, root_property, "headers")) {
                route.header_params_dynamic = true;
            }
            return;
        };

        if (std.mem.eql(u8, root_property, "query")) {
            try self.appendApiParam(&route.query_params, leaf_name, "query", false, false);
            return;
        }
        if (std.mem.eql(u8, root_property, "headers")) {
            try self.appendApiParam(&route.header_params, leaf_name, "header", false, true);
        }
    }

    fn captureApiHeaderGetter(
        self: *ContractBuilder,
        call: Node.CallExpr,
        request_binding_slot: ?u16,
        route: *ApiRouteInfo,
    ) !void {
        const request_slot = request_binding_slot orelse return;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag != .member_access and callee_tag != .computed_access and callee_tag != .optional_chain) return;

        const member = self.ir_view.getMember(call.callee) orelse return;
        const method_name = self.memberAccessName(member) orelse return;
        if (!std.mem.eql(u8, method_name, "get")) return;

        const root_property = self.requestRootProperty(member.object, request_slot) orelse return;
        if (!std.mem.eql(u8, root_property, "headers")) return;

        if (call.args_count == 0) {
            route.header_params_dynamic = true;
            return;
        }

        const name_idx = self.ir_view.getListIndex(call.args_start, 0);
        const name = self.getLiteralString(name_idx) orelse {
            route.header_params_dynamic = true;
            return;
        };
        try self.appendApiParam(&route.header_params, name, "header", false, true);
    }

    fn requestRootProperty(
        self: *const ContractBuilder,
        node_idx: NodeIndex,
        request_binding_slot: u16,
    ) ?[]const u8 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        if (tag != .member_access and tag != .computed_access and tag != .optional_chain) return null;
        const member = self.ir_view.getMember(node_idx) orelse return null;
        if (!self.isRequestIdentifier(member.object, request_binding_slot)) return null;
        return self.memberAccessName(member);
    }

    fn isRequestIdentifier(self: *const ContractBuilder, node_idx: NodeIndex, request_binding_slot: u16) bool {
        const tag = self.ir_view.getTag(node_idx) orelse return false;
        if (tag != .identifier) return false;
        const binding = self.ir_view.getBinding(node_idx) orelse return false;
        return binding.slot == request_binding_slot;
    }

    fn memberAccessName(self: *const ContractBuilder, member: Node.MemberExpr) ?[]const u8 {
        if (member.computed != null_node) return self.getLiteralString(member.computed);
        return self.resolveAtomName(member.property);
    }

    fn appendApiParam(
        self: *ContractBuilder,
        params: *std.ArrayList(ApiParamInfo),
        raw_name: []const u8,
        location: []const u8,
        required: bool,
        lowercase_name: bool,
    ) !void {
        const needle = if (lowercase_name)
            try lowerAsciiOwned(self.allocator, raw_name)
        else
            try self.allocator.dupe(u8, raw_name);
        defer self.allocator.free(needle);

        if (containsApiParam(params.items, needle)) return;

        try params.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, needle),
            .location = location,
            .required = required,
            .schema_json = try self.allocator.dupe(u8, "{\"type\":\"string\"}"),
        });
    }

    fn syncRouteRequestBodies(self: *ContractBuilder, route: *ApiRouteInfo) !void {
        route.request_bodies_dynamic = route.request_bodies_dynamic or route.request_schema_dynamic;
        if (route.request_bodies.items.len > 0) return;

        for (route.request_schema_refs.items) |schema_ref| {
            if (containsRequestBodySchemaRef(route.request_bodies.items, schema_ref)) continue;
            try route.request_bodies.append(self.allocator, .{
                .content_type = try self.allocator.dupe(u8, "application/json"),
                .schema = .{ .ref = try self.allocator.dupe(u8, schema_ref) },
            });
        }
    }

    fn classifyRequestSchemaCall(
        self: *ContractBuilder,
        route: *ApiRouteInfo,
        fn_name: ?[]const u8,
        schema_ref: []const u8,
    ) !void {
        const name = fn_name orelse return;
        if (std.mem.eql(u8, name, "validateJson") or
            std.mem.eql(u8, name, "coerceJson") or
            std.mem.eql(u8, name, "decodeJson"))
        {
            try self.appendRequestBodySchemaRef(route, "application/json", schema_ref);
        } else if (std.mem.eql(u8, name, "decodeForm")) {
            try self.appendRequestBodySchemaRef(route, "application/x-www-form-urlencoded", schema_ref);
        } else if (std.mem.eql(u8, name, "decodeQuery")) {
            try self.appendQueryParamsFromSchema(route, schema_ref);
        }
    }

    fn appendRequestBodySchemaRef(
        self: *ContractBuilder,
        route: *ApiRouteInfo,
        content_type: []const u8,
        schema_ref: []const u8,
    ) !void {
        for (route.request_bodies.items) |body| {
            const body_content_type = body.content_type orelse continue;
            const body_schema_ref = body.schema.schemaRef() orelse continue;
            if (std.mem.eql(u8, body_content_type, content_type) and std.mem.eql(u8, body_schema_ref, schema_ref)) {
                return;
            }
        }

        try route.request_bodies.append(self.allocator, .{
            .content_type = try self.allocator.dupe(u8, content_type),
            .schema = .{ .ref = try self.allocator.dupe(u8, schema_ref) },
        });
    }

    fn appendQueryParamsFromSchema(self: *ContractBuilder, route: *ApiRouteInfo, schema_ref: []const u8) !void {
        const schema_json = for (self.api_schemas.items) |schema| {
            if (std.mem.eql(u8, schema.name, schema_ref)) break schema.schema_json;
        } else return;

        // Anything unreadable here is an unanalyzable schema, not an absent
        // one: say so with the flag this function already carries rather than
        // returning as if the route took no query parameters.
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, schema_json, .{}) catch {
            route.query_params_dynamic = true;
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            route.query_params_dynamic = true;
            return;
        }

        const props = parsed.value.object.get("properties") orelse return;
        if (props != .object) {
            route.query_params_dynamic = true;
            return;
        }

        var required_names: std.ArrayList([]const u8) = .empty;
        defer required_names.deinit(self.allocator);
        if (parsed.value.object.get("required")) |required_val| {
            if (required_val == .array) {
                for (required_val.array.items) |item| {
                    if (item != .string) continue;
                    try required_names.append(self.allocator, item.string);
                }
            }
        }

        var it = props.object.iterator();
        while (it.next()) |entry| {
            if (!schemaValueSupportsQueryParam(entry.value_ptr.*)) {
                route.query_params_dynamic = true;
                return;
            }

            if (containsApiParam(route.query_params.items, entry.key_ptr.*)) continue;
            const field_schema_json = serializeJsonValue(self.allocator, entry.value_ptr.*) catch {
                route.query_params_dynamic = true;
                return;
            };
            errdefer self.allocator.free(field_schema_json);

            try route.query_params.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.key_ptr.*),
                .location = "query",
                .required = containsString(required_names.items, entry.key_ptr.*),
                .schema_json = field_schema_json,
            });
        }
    }

    fn schemaValueSupportsQueryParam(value_json: std.json.Value) bool {
        if (value_json != .object) return false;
        const obj = value_json.object;

        if (obj.get("enum")) |enum_val| {
            if (enum_val != .array or enum_val.array.items.len == 0) return false;
            for (enum_val.array.items) |item| {
                switch (item) {
                    .string, .integer, .float, .bool => {},
                    // exhaustive: false rejects the schema as a query parameter, which
                    // makes the caller mark the route's query params dynamic.
                    // Rejecting is the conservative direction.
                    else => return false,
                }
            }
            return true;
        }

        const type_val = obj.get("type") orelse return false;
        if (type_val != .string) return false;
        return std.mem.eql(u8, type_val.string, "string") or
            std.mem.eql(u8, type_val.string, "number") or
            std.mem.eql(u8, type_val.string, "integer") or
            std.mem.eql(u8, type_val.string, "boolean");
    }

    fn serializeJsonValue(allocator: std.mem.Allocator, value_json: std.json.Value) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
        try writeJsonValue(value_json, &aw.writer);
        output = aw.toArrayList();
        return try output.toOwnedSlice(allocator);
    }

    fn writeJsonValue(value_json: std.json.Value, writer: anytype) !void {
        switch (value_json) {
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| try writeJsonString(writer, s),
            .array => |arr| {
                try writer.writeByte('[');
                for (arr.items, 0..) |item, idx| {
                    if (idx > 0) try writer.writeAll(",");
                    try writeJsonValue(item, writer);
                }
                try writer.writeByte(']');
            },
            .object => |obj| {
                try writer.writeByte('{');
                var it = obj.iterator();
                var idx: usize = 0;
                while (it.next()) |entry| : (idx += 1) {
                    if (idx > 0) try writer.writeAll(",");
                    try writeJsonString(writer, entry.key_ptr.*);
                    try writer.writeAll(":");
                    try writeJsonValue(entry.value_ptr.*, writer);
                }
                try writer.writeByte('}');
            },
            else => return error.UnsupportedJsonValue,
        }
    }

    fn syncLegacyRouteResponse(self: *ContractBuilder, route: *ApiRouteInfo) !void {
        route.response_status = null;
        if (route.response_content_type) |content_type| self.allocator.free(content_type);
        route.response_content_type = null;
        if (route.response_schema_ref) |schema_ref| self.allocator.free(schema_ref);
        route.response_schema_ref = null;
        if (route.response_schema_json) |schema_json| self.allocator.free(schema_json);
        route.response_schema_json = null;
        route.response_schema_dynamic = route.responses_dynamic;

        if (route.responses.items.len != 1) {
            if (route.responses.items.len > 1) route.response_schema_dynamic = true;
            return;
        }

        const response = route.responses.items[0];
        if (response.schema.isDynamic()) {
            route.response_schema_dynamic = true;
            return;
        }

        route.response_status = response.status;
        if (response.content_type) |content_type| {
            route.response_content_type = try self.allocator.dupe(u8, content_type);
        }
        if (response.schema.schemaRef()) |schema_ref| {
            route.response_schema_ref = try self.allocator.dupe(u8, schema_ref);
        }
        if (response.schema.schemaJson()) |schema_json| {
            route.response_schema_json = try self.allocator.dupe(u8, schema_json);
        }
    }

    fn appendResponseVariant(
        self: *ContractBuilder,
        route: *ApiRouteInfo,
        candidate: *const ResponseSchemaCandidate,
    ) !void {
        for (route.responses.items) |existing| {
            if (responseVariantMatches(existing, candidate)) return;
        }

        try route.responses.append(self.allocator, .{
            .status = candidate.status,
            .content_type = if (candidate.content_type) |content_type|
                try self.allocator.dupe(u8, content_type)
            else
                null,
            .schema = try schemaSpecFromCandidate(self.allocator, candidate),
        });
    }

    fn extractResponseSchemaRef(self: *ContractBuilder, node_idx: NodeIndex) !?[]u8 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        switch (tag) {
            .member_access => {
                const member = self.ir_view.getMember(node_idx) orelse return null;
                const prop_name = self.resolveAtomName(member.property) orelse return null;
                if (!std.mem.eql(u8, prop_name, "value")) return null;

                const obj_tag = self.ir_view.getTag(member.object) orelse return null;
                if (obj_tag != .identifier) return null;
                const binding = self.ir_view.getBinding(member.object) orelse return null;
                return try self.lookupSchemaRefForBinding(binding.slot);
            },
            .identifier => {
                const binding = self.ir_view.getBinding(node_idx) orelse return null;
                const init_node = self.findBindingInitNode(binding.slot) orelse return null;
                return try self.extractResponseSchemaRef(init_node);
            },
            // exhaustive: null means no schema reference was found, leaving the
            // response undocumented rather than documented against the wrong
            // schema.
            else => return null,
        }
    }

    fn lookupSchemaRefForBinding(self: *ContractBuilder, slot: u16) !?[]u8 {
        const init_node = self.findBindingInitNode(slot) orelse return null;
        const tag = self.ir_view.getTag(init_node) orelse return null;
        if (tag != .call) return null;

        const call = self.ir_view.getCall(init_node) orelse return null;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return null;
        if (callee_tag != .identifier) return null;

        const binding = self.ir_view.getBinding(call.callee) orelse return null;
        if (!self.isBindingCategory(binding.slot, .request_schema)) return null;
        if (call.args_count == 0) return null;

        const schema_idx = self.ir_view.getListIndex(call.args_start, 0);
        const schema_name = self.getLiteralString(schema_idx) orelse return null;
        return try self.allocator.dupe(u8, schema_name);
    }

    fn extractResponseSchemaJson(self: *ContractBuilder, node_idx: NodeIndex) !?[]u8 {
        if (self.type_checker == null or self.type_env == null) return null;

        const inferred = self.type_checker.?.inferType(node_idx);
        if (inferred != type_pool_mod.null_type_idx) {
            if (try api_schema.schemaFromType(self.allocator, self.type_env.?, inferred)) |schema_json| {
                return schema_json;
            }
        }

        const tag = self.ir_view.getTag(node_idx) orelse return null;
        if (tag == .identifier) {
            const binding = self.ir_view.getBinding(node_idx) orelse return null;
            const init_node = self.findBindingInitNode(binding.slot) orelse return null;
            return try self.extractResponseSchemaJson(init_node);
        }

        return null;
    }

    fn extractStatusFromOptionsNode(self: *const ContractBuilder, node_idx: NodeIndex) ?u16 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        if (tag != .object_literal) return null;

        const obj = self.ir_view.getObject(node_idx) orelse return null;
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const key = self.getObjectPropertyKey(prop.key) orelse continue;
            if (!std.mem.eql(u8, key, "status")) continue;

            const value_tag = self.ir_view.getTag(prop.value) orelse return null;
            switch (value_tag) {
                .lit_int => {
                    const value = self.ir_view.getIntValue(prop.value) orelse return null;
                    if (value < 0 or value > std.math.maxInt(u16)) return null;
                    return @intCast(value);
                },
                // exhaustive: a status that is not an integer literal is not statically
                // known, and null leaves it unrecorded rather than guessed.
                else => return null,
            }
        }
        return null;
    }

    // -----------------------------------------------------------------
    // Phase 3: Effect classification
    // -----------------------------------------------------------------

    /// Summarize the effect facts that handler property derivation depends on.
    fn computeEffectSummary(self: *const ContractBuilder, handler_fn: ?NodeIndex) !EffectSummary {
        if (handler_fn) |hf| {
            var summary = EffectSummary{};
            var seen_functions: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
            defer seen_functions.deinit(self.allocator);
            try self.includeReachableFunctionEffects(hf, &summary, &seen_functions);
            return summary;
        }

        return self.computeGlobalEffectSummary();
    }

    fn computeGlobalEffectSummary(self: *const ContractBuilder) EffectSummary {
        var summary = EffectSummary{};

        for (self.factsRef().functions.items) |entry| {
            if (builtin_modules.fromSpecifier(entry.module)) |binding| {
                const is_durable = std.mem.eql(u8, binding.specifier, "zttp:durable");
                const is_cache = std.mem.eql(u8, binding.specifier, "zttp:cache");

                for (entry.names.items) |func_name| {
                    summary.has_any_call = true;

                    for (binding.exports) |exp| {
                        if (std.mem.eql(u8, exp.name, func_name)) {
                            summary.includeCall(exp.effect, is_durable);
                            break;
                        }
                    }

                    if (is_cache and std.mem.eql(u8, func_name, "cacheGet")) {
                        summary.has_cache_read = true;
                    }
                }
            } else if (self.manifest_registry) |registry| {
                // Partner-registered module: read effect class from the manifest.
                // Treat extension-declared writes as bare writes (no durable
                // sequencing assumed); deterministic-by-default applies via
                // the verifier's existing logic.
                const manifest = registry.fromSpecifier(entry.module) orelse continue;
                for (entry.names.items) |func_name| {
                    summary.has_any_call = true;
                    for (manifest.exports.items) |exp| {
                        if (std.mem.eql(u8, exp.name, func_name)) {
                            summary.includeCall(exp.effect, false);
                            break;
                        }
                    }
                }
            }
        }

        if (self.egress_hosts.items.len > 0 or self.egress_dynamic) summary.includeEgress();

        return summary;
    }

    fn includeReachableFunctionEffects(
        self: *const ContractBuilder,
        node: NodeIndex,
        summary: *EffectSummary,
        seen_functions: *std.AutoHashMapUnmanaged(NodeIndex, void),
    ) std.mem.Allocator.Error!void {
        const fn_node = self.resolveFunctionNode(node) orelse return;
        const gop = try seen_functions.getOrPut(self.allocator, fn_node);
        if (gop.found_existing) return;

        const func = self.ir_view.getFunction(fn_node) orelse return;
        try self.includeReachableNodeEffects(func.body, summary, seen_functions);
    }

    fn includeReachableNodeEffects(
        self: *const ContractBuilder,
        node: NodeIndex,
        summary: *EffectSummary,
        seen_functions: *std.AutoHashMapUnmanaged(NodeIndex, void),
    ) std.mem.Allocator.Error!void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    try self.includeReachableNodeEffects(
                        self.ir_view.getListIndex(block.stmts_start, @intCast(i)),
                        summary,
                        seen_functions,
                    );
                }
            },
            .if_stmt => {
                const stmt = self.ir_view.getIfStmt(node) orelse return;
                try self.includeReachableNodeEffects(stmt.condition, summary, seen_functions);
                try self.includeReachableNodeEffects(stmt.then_branch, summary, seen_functions);
                try self.includeReachableNodeEffects(stmt.else_branch, summary, seen_functions);
            },
            .for_of_stmt => {
                const stmt = self.ir_view.getForIter(node) orelse return;
                try self.includeReachableNodeEffects(stmt.iterable, summary, seen_functions);
                try self.includeReachableNodeEffects(stmt.body, summary, seen_functions);
            },
            .return_stmt, .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |value| {
                    try self.includeReachableNodeEffects(value, summary, seen_functions);
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                if (decl.init != null_node and !self.isFunctionNode(decl.init)) {
                    try self.includeReachableNodeEffects(decl.init, summary, seen_functions);
                }
            },
            .function_decl => {},
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                try self.includeReachableNodeEffects(bin.left, summary, seen_functions);
                try self.includeReachableNodeEffects(bin.right, summary, seen_functions);
            },
            .unary_op, .spread => {
                const un = self.ir_view.getUnary(node) orelse return;
                try self.includeReachableNodeEffects(un.operand, summary, seen_functions);
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node) orelse return;
                try self.includeReachableNodeEffects(ternary.condition, summary, seen_functions);
                try self.includeReachableNodeEffects(ternary.then_branch, summary, seen_functions);
                try self.includeReachableNodeEffects(ternary.else_branch, summary, seen_functions);
            },
            .call, .method_call => {
                try self.includeReachableCallEffects(node, summary, seen_functions);
                const call = self.ir_view.getCall(node) orelse return;
                try self.includeReachableNodeEffects(call.callee, summary, seen_functions);
                for (0..call.args_count) |i| {
                    try self.includeReachableNodeEffects(
                        self.ir_view.getListIndex(call.args_start, @intCast(i)),
                        summary,
                        seen_functions,
                    );
                }
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                try self.includeReachableNodeEffects(member.object, summary, seen_functions);
                try self.includeReachableNodeEffects(member.computed, summary, seen_functions);
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(node) orelse return;
                try self.includeReachableNodeEffects(assign.target, summary, seen_functions);
                try self.includeReachableNodeEffects(assign.value, summary, seen_functions);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                for (0..arr.elements_count) |i| {
                    try self.includeReachableNodeEffects(
                        self.ir_view.getListIndex(arr.elements_start, @intCast(i)),
                        summary,
                        seen_functions,
                    );
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    try self.includeReachableNodeEffects(prop.value, summary, seen_functions);
                }
            },
            .template_literal => {
                const tmpl = self.ir_view.getTemplate(node) orelse return;
                for (0..tmpl.parts_count) |i| {
                    const part = self.ir_view.getListIndex(tmpl.parts_start, @intCast(i));
                    if (self.ir_view.getOptValue(part)) |value| {
                        try self.includeReachableNodeEffects(value, summary, seen_functions);
                    }
                }
            },
            .match_expr => {
                const match = self.ir_view.getMatchExpr(node) orelse return;
                try self.includeReachableNodeEffects(match.discriminant, summary, seen_functions);
                for (0..match.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(match.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    try self.includeReachableNodeEffects(arm.body, summary, seen_functions);
                }
            },
            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                try self.includeReachableNodeEffects(func.body, summary, seen_functions);
            },
            // exhaustive: every node that can contain a call is walked above,
            // including match_expr and both literal containers. What remains are
            // leaves - identifiers and literals - which reach no effect.
            else => {},
        }
    }

    fn includeReachableCallEffects(
        self: *const ContractBuilder,
        node: NodeIndex,
        summary: *EffectSummary,
        seen_functions: *std.AutoHashMapUnmanaged(NodeIndex, void),
    ) std.mem.Allocator.Error!void {
        const call = self.ir_view.getCall(node) orelse return;
        if (self.ir_view.getTag(call.callee) != .identifier) return;
        const binding = self.ir_view.getBinding(call.callee) orelse return;

        if (binding.kind == .undeclared_global) {
            const name = self.resolveAtomName(binding.name_atom) orelse return;
            if (std.mem.eql(u8, name, "fetchSync")) {
                summary.includeEgress();
                return;
            }
        }

        for (self.factsRef().generic_bindings.items) |gb| {
            if (gb.slot != binding.slot) continue;
            summary.has_any_call = true;
            if (builtin_modules.fromSpecifier(gb.module_specifier)) |module| {
                const is_durable = std.mem.eql(u8, module.specifier, "zttp:durable");
                for (module.exports) |exp| {
                    if (std.mem.eql(u8, exp.name, gb.binding_name)) {
                        summary.includeCall(exp.effect, is_durable);
                        break;
                    }
                }
            }
            if (std.mem.eql(u8, gb.module_specifier, "zttp:cache") and
                std.mem.eql(u8, gb.binding_name, "cacheGet"))
            {
                summary.has_cache_read = true;
            }
            return;
        }

        if (self.manifest_registry) |registry| {
            for (self.factsRef().extension_bindings.items) |eb| {
                if (eb.slot != binding.slot) continue;
                summary.has_any_call = true;
                const manifest = registry.fromSpecifier(eb.module_specifier) orelse return;
                for (manifest.exports.items) |exp| {
                    if (std.mem.eql(u8, exp.name, eb.binding_name)) {
                        summary.includeCall(exp.effect, false);
                        break;
                    }
                }
                return;
            }
        }

        if (self.findFunctionNodeByBinding(binding.slot)) |fn_node| {
            try self.includeReachableFunctionEffects(fn_node, summary, seen_functions);
        }
    }

    /// Derive handler-level properties from the aggregate effect summary.
    /// `handler_row`, when present, is the handler's call-graph composed
    /// effect row: intersecting with it makes a property the handler claims
    /// also account for every helper it transitively calls. This is a
    /// monotone tightening - it can only make a property falser, never
    /// unsoundly true - so the proof composes across helper boundaries.
    fn computeProperties(
        self: *const ContractBuilder,
        handler_row: ?effect_inference.EffectRow,
        handler_fn: ?NodeIndex,
    ) !HandlerProperties {
        const s = try self.computeEffectSummary(handler_fn);

        var read_only = s.io != .write;
        // Determinism is decided by the flow walk, which the caller ANDs in:
        // it answers whether a varying value reaches the response rather than
        // whether one was read at all, so a handler that logs a timestamp and
        // answers a constant keeps the property. The presence scan and the
        // effect row both demote on the read, which cost that handler the
        // property and, through `deterministic and retry_safe`, `idempotent`
        // with it. Both still run: the row answers the per-function question
        // for a helper's `Proof<...>` capsule, which flow cannot reach, and the
        // scan names the first varying call site for the reload HUD.
        //
        // With no handler function there is nothing for flow to walk and
        // nothing to prove, so the property stays unproven rather than
        // defaulting to held.
        const deterministic = handler_fn != null;
        var pure = !s.has_any_call and !s.has_egress;

        if (handler_row) |row| {
            read_only = read_only and row.readOnly();
            pure = pure and row.pure;
        }

        const durable_only_writes = s.io == .write and self.durable_used and !s.has_bare_write;
        // Scope cleanup callbacks run exactly once on unwind; retrying the request
        // would re-run them, violating at-most-once guarantees for resource cleanup.
        const retry_safe = !self.scope_used and (read_only or durable_only_writes);

        // POST-only proof: the AOT route table (routerMatch({...}, req)) must
        // be non-empty, statically enumerable, and every route's method POST.
        var post_only = self.api_routes.items.len > 0 and !self.api_routes_dynamic;
        if (post_only) {
            for (self.api_routes.items) |route| {
                if (!std.ascii.eqlIgnoreCase(route.method, "POST")) {
                    post_only = false;
                    break;
                }
            }
        }

        // read_only here is the BEHAVIORAL fact (the handler performs no state
        // mutations). That is what deploy manifests, the proof report, and the
        // runtime pooling policy consume, so a SELECT-only zttp:sql handler
        // must keep read_only == true. The separate question of whether a handler
        // may *declare* read_only (a zttp:sql/cache import forbids it at the
        // import level, ZTS501) is enforced by spec_discharge and surfaced to the
        // agent via the edit-simulate HUD, not by weakening this behavioral fact.
        return .{
            .pure = pure,
            .read_only = read_only,
            .stateless = read_only and !s.has_cache_read,
            .retry_safe = retry_safe,
            .deterministic = deterministic,
            .has_egress = s.has_egress,
            .idempotent = deterministic and retry_safe,
            .post_only = post_only,
            // The contract builder runs only after strict checking passed
            // (canonical-profile violations are hard `check` errors that block
            // contract construction upstream), so a built contract is always in
            // Canonical Normal Form. See HandlerProperties.canonical.
            .canonical = true,
        };
    }

    /// Detect rate limiting from the primitive that declares it: a
    /// `zttp:ratelimit` `rateCheck` call, whose first argument the module's
    /// own `rate_limit_key` extraction rule puts in `rate_limit_keys`.
    ///
    /// What this replaced answered from two proxies ANDed together: a
    /// `zttp:compose` import and a `cacheIncr` call somewhere. Neither names
    /// rate limiting. A composition import says the author chained guards,
    /// which any middleware does, and an incremented counter is a counter -
    /// a page-view tally increments one too. The conjunction was narrow
    /// enough that no handler in the repository ever satisfied it, so the
    /// field it feeds was never once produced by a compile.
    ///
    /// `dynamic` means the key is computed rather than literal, which is the
    /// common shape (`ip + ":" + path`). The detection still fires: a
    /// deployment rate-limits either way, and only the namespace is unknown.
    fn detectRateLimiting(self: *const ContractBuilder, owned_namespace: ?[]const u8) ?RateLimitInfo {
        if (self.rate_limit_keys.items.len == 0 and !self.rate_limit_key_dynamic) return null;
        return .{
            .namespace = owned_namespace orelse "",
            .dynamic = self.rate_limit_key_dynamic,
        };
    }
};

fn containsApiParam(items: []const ApiParamInfo, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, needle)) return true;
    }
    return false;
}

fn containsRequestBodySchemaRef(items: []const ApiBodyInfo, needle: []const u8) bool {
    for (items) |item| {
        if (item.schema.schemaRef()) |schema_ref| {
            if (std.mem.eql(u8, schema_ref, needle)) return true;
        }
    }
    return false;
}

fn responseVariantMatches(existing: ApiResponseInfo, candidate: *const ContractBuilder.ResponseSchemaCandidate) bool {
    return existing.status == candidate.status and
        eqlOptionalString(existing.content_type, candidate.content_type) and
        eqlOptionalString(existing.schema.schemaRef(), candidate.schema_ref) and
        eqlOptionalString(existing.schema.schemaJson(), candidate.schema_json) and
        existing.schema.isDynamic() == candidate.dynamic;
}

/// Mirror ContractBuilder.ResponseSchemaCandidate's separate fields into the
/// SchemaSpec union. The precedence is `SchemaSpec.fromFields`, shared with the
/// JSON parser and the differ.
fn schemaSpecFromCandidate(
    allocator: std.mem.Allocator,
    candidate: *const ContractBuilder.ResponseSchemaCandidate,
) !SchemaSpec {
    return SchemaSpec.fromFields(
        candidate.schema_ref,
        candidate.schema_json,
        candidate.dynamic,
    ).dupeOwned(allocator);
}

fn eqlOptionalString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn lowerAsciiOwned(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| {
        out[i] = std.ascii.toLower(c);
    }
    return out;
}

const ParsedRouteKey = struct {
    method: []const u8,
    path: []const u8,
};

fn parseRouteKey(raw: []const u8) ?ParsedRouteKey {
    const sep = std.mem.indexOfScalar(u8, raw, ' ') orelse return null;
    if (sep == 0 or sep + 1 >= raw.len) return null;

    const method = raw[0..sep];
    const path = raw[sep + 1 ..];
    if (path.len == 0 or path[0] != '/') return null;

    return .{
        .method = method,
        .path = path,
    };
}

fn contentTypeFor(idx: u8) []const u8 {
    return switch (idx) {
        0 => "application/json",
        1 => "text/plain; charset=utf-8",
        else => "text/html; charset=utf-8",
    };
}
fn appendTrackedFunction(
    builder: *ContractBuilder,
    module_name: []const u8,
    func_name: []const u8,
) !void {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| builder.allocator.free(name);
        names.deinit(builder.allocator);
    }

    try names.append(builder.allocator, try builder.allocator.dupe(u8, func_name));

    try builder.owned_facts.functions.append(builder.allocator, .{
        .module = try builder.allocator.dupe(u8, module_name),
        .names = names,
    });
}

fn expectBuiltinExportEffect(
    module_name: []const u8,
    func_name: []const u8,
    effect: module_binding.EffectClass,
) !void {
    const binding = builtin_modules.fromSpecifier(module_name) orelse return error.MissingModule;
    for (binding.exports) |exp| {
        if (std.mem.eql(u8, exp.name, func_name)) {
            try std.testing.expectEqual(effect, exp.effect);
            return;
        }
    }
    return error.MissingExport;
}

fn buildTestContract(source: []const u8) !HandlerContract {
    const allocator = std.testing.allocator;
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();

    var parser = try JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var builder = ContractBuilder.init(allocator, view, &atoms, null, null);
    defer builder.deinit();

    const handler_fn = findTestFunctionNode(view, &atoms, "handler");
    return try builder.build("handler.ts", null, handler_fn, root, null, false, null);
}

fn findTestFunctionNode(view: IrView, atoms: *atom_table.AtomTable, name: []const u8) ?NodeIndex {
    const node_count = view.nodeCount();
    for (0..node_count) |idx_usize| {
        const idx: NodeIndex = @intCast(idx_usize);
        const tag = view.getTag(idx) orelse continue;
        switch (tag) {
            .function_decl, .var_decl => {
                const decl = view.getVarDecl(idx) orelse continue;
                const binding_name = resolveTestAtomName(atoms, decl.binding.name_atom) orelse continue;
                if (!std.mem.eql(u8, binding_name, name)) continue;
                if (decl.init == null_node) return null;
                const init_tag = view.getTag(decl.init) orelse return null;
                if (init_tag == .function_expr or init_tag == .arrow_function) return decl.init;
                return null;
            },
            // exhaustive: only a declaration binds the named function being looked
            // up; other statement kinds cannot answer the question.
            else => {},
        }
    }
    return null;
}

fn resolveTestAtomName(atoms: *atom_table.AtomTable, atom_idx: u16) ?[]const u8 {
    const atom: object.Atom = @enumFromInt(atom_idx);
    if (atom.isPredefined()) return atom.toPredefinedName();
    return atoms.getName(atom);
}

test "computeProperties pure handler stays pure" {
    var builder = ContractBuilder.init(std.testing.allocator, undefined, null, null, null);
    defer builder.deinit();

    const props = try builder.computeProperties(null, null);

    try std.testing.expect(props.pure);
    try std.testing.expect(props.read_only);
    try std.testing.expect(props.stateless);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(!props.has_egress);
}

test "computeProperties cache read is read-only but not stateless" {
    var builder = ContractBuilder.init(std.testing.allocator, undefined, null, null, null);
    defer builder.deinit();

    try appendTrackedFunction(&builder, "zttp:cache", "cacheGet");

    const props = try builder.computeProperties(null, null);

    try std.testing.expect(!props.pure);
    try std.testing.expect(props.read_only);
    try std.testing.expect(!props.stateless);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(!props.has_egress);
}

test "computeProperties bare writes are not retry safe" {
    var builder = ContractBuilder.init(std.testing.allocator, undefined, null, null, null);
    defer builder.deinit();

    try appendTrackedFunction(&builder, "zttp:cache", "cacheSet");

    const props = try builder.computeProperties(null, null);

    try std.testing.expect(!props.pure);
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.stateless);
    try std.testing.expect(!props.retry_safe);
    try std.testing.expect(!props.has_egress);
}

test "computeProperties registration functions are request-path writes" {
    var builder = ContractBuilder.init(std.testing.allocator, undefined, null, null, null);
    defer builder.deinit();

    try appendTrackedFunction(&builder, "zttp:validate", "schemaCompile");

    const props = try builder.computeProperties(null, null);
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.retry_safe);
}

test "registration module exports declare write effects" {
    try expectBuiltinExportEffect("zttp:sql", "sql", .write);
    try expectBuiltinExportEffect("zttp:validate", "schemaCompile", .write);
    try expectBuiltinExportEffect("zttp:validate", "schemaDrop", .write);
}

test "top-level registration does not demote handler request properties" {
    const source =
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("todo", "{\"type\":\"object\"}");
        \\function handler(req) {
        \\  const parsed = validateJson("todo", req.body);
        \\  if (!parsed.ok) return Response.json({ error: "invalid" }, { status: 400 });
        \\  return Response.json(parsed.value);
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(props.read_only);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(props.idempotent);
}

test "handler-body registration remains a request-path write" {
    const source =
        \\import { schemaCompile } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("todo", "{\"type\":\"object\"}");
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.retry_safe);
    try std.testing.expect(!props.idempotent);
}

test "computeProperties durable-only writes stay retry safe" {
    var builder = ContractBuilder.init(std.testing.allocator, undefined, null, null, null);
    defer builder.deinit();

    try appendTrackedFunction(&builder, "zttp:durable", "step");
    builder.durable_used = true;

    const props = try builder.computeProperties(null, null);

    try std.testing.expect(!props.pure);
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.stateless);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(!props.has_egress);
}

// Determinism is not decided here any more, so the tests that pinned it moved
// to `precompile.zig`, where the flow walk that decides it actually runs.
// `has_nondeterministic_builtin` still records the first varying call site for
// the reload HUD, and `computeProperties` still answers whether there was a
// handler to walk, but neither is the property.

test "saga extractor collects steps and has_compensate flags from a static saga" {
    const source =
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return saga([
        \\    { name: "reserve", run: () => 1, compensate: () => 2 },
        \\    { name: "ship", run: () => 3 },
        \\  ]);
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.sagas.items.len);
    const info = contract.sagas.items[0];
    try std.testing.expect(!info.dynamic);
    try std.testing.expectEqual(@as(usize, 2), info.steps.items.len);
    try std.testing.expectEqualStrings("reserve", info.steps.items[0].name);
    try std.testing.expect(info.steps.items[0].has_compensate);
    try std.testing.expectEqualStrings("ship", info.steps.items[1].name);
    try std.testing.expect(!info.steps.items[1].has_compensate);
    try std.testing.expect(info.compensationProven());
}

test "saga extractor marks a spread-constructed saga dynamic" {
    const source =
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  const extra = [{ name: "x", run: () => 1 }];
        \\  return saga([...extra, { name: "y", run: () => 2 }]);
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.sagas.items.len);
    const info = contract.sagas.items[0];
    try std.testing.expect(info.dynamic);
    try std.testing.expectEqual(@as(usize, 0), info.steps.items.len);
    try std.testing.expect(!info.compensationProven());
}

/// True if `contract.spec_diagnostics` contains a ZTS510 for `step_name`.
fn hasSagaMissingCompensateDiagnostic(contract: *const HandlerContract, step_name: []const u8) bool {
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind != .saga_step_missing_compensate) continue;
        if (std.mem.eql(u8, d.spec_name, step_name)) return true;
    }
    return false;
}

test "ZTS510 fires for a non-last saga step missing compensate" {
    const source =
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return saga([
        \\    { name: "reserve", run: () => 1 },
        \\    { name: "charge", run: () => 2, compensate: () => 3 },
        \\    { name: "ship", run: () => 4 },
        \\  ]);
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(hasSagaMissingCompensateDiagnostic(&contract, "reserve"));
    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "charge"));
    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "ship"));
    try std.testing.expect(!contract.sagas.items[0].compensationProven());
}

test "ZTS510 does not fire when only the last saga step omits compensate" {
    const source =
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return saga([
        \\    { name: "reserve", run: () => 1, compensate: () => 2 },
        \\    { name: "charge", run: () => 3, compensate: () => 4 },
        \\    { name: "ship", run: () => 5 },
        \\  ]);
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "reserve"));
    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "charge"));
    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "ship"));
    try std.testing.expect(contract.sagas.items[0].compensationProven());
}

test "ZTS510 does not fire for a fully-covered static saga" {
    const source =
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return saga([
        \\    { name: "reserve", run: () => 1, compensate: () => 2 },
        \\    { name: "ship", run: () => 3, compensate: () => 4 },
        \\  ]);
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "reserve"));
    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "ship"));
    try std.testing.expect(contract.sagas.items[0].compensationProven());
}

test "ZTS510 never fires for a dynamically-constructed saga" {
    const source =
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  const extra = [{ name: "reserve", run: () => 1 }];
        \\  return saga([...extra, { name: "ship", run: () => 2 }]);
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "reserve"));
    try std.testing.expect(!hasSagaMissingCompensateDiagnostic(&contract, "ship"));
    try std.testing.expect(contract.sagas.items[0].dynamic);
    try std.testing.expect(!contract.sagas.items[0].compensationProven());
}

// The eager-argument case - `step("ts", Date.now())`, where the clock is read
// before the step ever runs and so is not replayed - moved to `precompile.zig`
// with the rest of the determinism tests.

/// True if `contract.spec_diagnostics` contains a ZTS509 for `workflow_fn`.
fn hasWorkflowCallInStepDiagnostic(contract: *const HandlerContract, workflow_fn: []const u8) bool {
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind != .workflow_call_in_step) continue;
        if (std.mem.eql(u8, d.spec_name, workflow_fn)) return true;
    }
    return false;
}

test "ZTS509 fires for call/saga/fanout/follow nested inside step()" {
    const cases = [_]struct { fn_name: []const u8, call_expr: []const u8 }{
        .{ .fn_name = "call", .call_expr = "call(\"billing\", {})" },
        .{ .fn_name = "saga", .call_expr = "saga([])" },
        .{ .fn_name = "fanout", .call_expr = "fanout([])" },
        .{ .fn_name = "follow", .call_expr = "follow(\"/next\")" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\import {{ step }} from "zttp:durable";
            \\import {{ call, saga, fanout, follow }} from "zttp:workflow";
            \\function handler(req) {{
            \\  return step("s", () => {s});
            \\}}
        , .{case.call_expr});
        defer std.testing.allocator.free(source);

        var contract = try buildTestContract(source);
        defer contract.deinit(std.testing.allocator);

        try std.testing.expect(hasWorkflowCallInStepDiagnostic(&contract, case.fn_name));
    }
}

test "ZTS509 does not fire for top-level workflow.call" {
    const source =
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  return call("billing", {});
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(!hasWorkflowCallInStepDiagnostic(&contract, "call"));
}

test "ZTS509 fires through an inline closure nested in step()" {
    // Anonymous closures passed as arguments (e.g. a `.map()` callback)
    // inherit their enclosing function's effect row (see the comment on
    // `.function_expr, .arrow_function` in effect_inference.zig's
    // walkBaseExpr) - depth survives this kind of nesting. A *named local*
    // closure invoked later by identifier does not: that call resolves as
    // neither an import nor a collected top-level function, so its body is
    // never walked. This is an existing limitation of the depth-tracking
    // this diagnostic reuses (the sibling non-determinism check at
    // effect_inference.zig has the same blind spot), not something ZTS509
    // introduces - this test asserts the pattern that is actually covered.
    const source =
        \\import { step } from "zttp:durable";
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  return step("s", () => {
        \\    return [1].map(() => call("billing", {}))[0];
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(hasWorkflowCallInStepDiagnostic(&contract, "call"));
}

test "ZTS509 does not fire for workflow.call in a function never reached from step()" {
    const source =
        \\import { step } from "zttp:durable";
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  return step("s", () => 1);
        \\}
        \\function unrelated() {
        \\  return call("billing", {});
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(!hasWorkflowCallInStepDiagnostic(&contract, "call"));
}

test "durable workflow properties prove stable step workflow" {
    const source =
        \\import { run, step } from "zttp:durable";
        \\function handler(req) {
        \\  return run("job:stable", () => {
        \\    const value = step("charge", () => 1);
        \\    return Response.json({ value });
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(DurableWorkflowProofLevel.complete, contract.durable.workflow.proof_level);
    try std.testing.expect(contract.durable.workflow.properties.retry_safe);
    try std.testing.expect(contract.durable.workflow.properties.idempotent);
    try std.testing.expect(contract.durable.workflow.properties.fault_covered);
}

test "durable workflow properties reject a side effect inside a match arm" {
    // `containsUnmodeledCall` walks every expression that can hold a call, and
    // had no arm for `match_expr` - so a call in a match arm returned false,
    // and `isUnhandledWorkflowCall` read that as "nothing unmodeled here" and
    // over-claimed proof_level == .complete.
    const source =
        \\import { run } from "zttp:durable";
        \\import { cacheSet } from "zttp:cache";
        \\function handler(req) {
        \\  return run("job:match", () => {
        \\    const v = match (req) {
        \\      when { method: "POST" }: cacheSet(req.url, "x")
        \\      default: 0
        \\    };
        \\    return Response.json({ ok: true, v });
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(DurableWorkflowProofLevel.partial, contract.durable.workflow.proof_level);
}

test "durable workflow properties reject unmodeled side effects" {
    const source =
        \\import { run } from "zttp:durable";
        \\import { cacheSet } from "zttp:cache";
        \\function handler(req) {
        \\  return run("job:cache", () => {
        \\    cacheSet(req.url, "x");
        \\    return Response.json({ ok: true });
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(DurableWorkflowProofLevel.partial, contract.durable.workflow.proof_level);
    try std.testing.expect(!contract.durable.workflow.properties.retry_safe);
    try std.testing.expect(!contract.durable.workflow.properties.idempotent);
    try std.testing.expect(!contract.durable.workflow.properties.fault_covered);
}

test "durable workflow properties reject unmodeled side effect hidden behind assignment" {
    const source =
        \\import { run, step } from "zttp:durable";
        \\import { uuid } from "zttp:id";
        \\function handler(req) {
        \\  return run("job:uuid", () => {
        \\    let id = "";
        \\    id = uuid();
        \\    const value = step("charge", () => 1);
        \\    return Response.json({ value, id });
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(DurableWorkflowProofLevel.partial, contract.durable.workflow.proof_level);
    try std.testing.expect(!contract.durable.workflow.properties.retry_safe);
    try std.testing.expect(!contract.durable.workflow.properties.idempotent);
    try std.testing.expect(!contract.durable.workflow.properties.fault_covered);
}

test "durable workflow properties reject unmodeled side effect hidden in return expression" {
    const source =
        \\import { run, step } from "zttp:durable";
        \\import { cacheSet } from "zttp:cache";
        \\function handler(req) {
        \\  return run("job:return-cache", () => {
        \\    const value = step("charge", () => 1);
        \\    return Response.json({ value, cached: cacheSet("k", "v") });
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(DurableWorkflowProofLevel.partial, contract.durable.workflow.proof_level);
    try std.testing.expect(!contract.durable.workflow.properties.retry_safe);
    try std.testing.expect(!contract.durable.workflow.properties.idempotent);
    try std.testing.expect(!contract.durable.workflow.properties.fault_covered);
}

test "durable workflow waitSignal has fault coverage when modeled" {
    const source =
        \\import { run, waitSignal } from "zttp:durable";
        \\function handler(req) {
        \\  return run("job:signal", () => {
        \\    const payload = waitSignal("approved");
        \\    return Response.json(payload);
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(DurableWorkflowProofLevel.complete, contract.durable.workflow.proof_level);
    try std.testing.expect(contract.durable.workflow.properties.fault_covered);
    try std.testing.expect(contract.durable.workflow.properties.retry_safe);
    try std.testing.expectEqual(@as(usize, 2), contract.durable.workflow.properties.reasons.items.len);
}

test "durable workflow dynamic waitSignal is not fault covered" {
    const source =
        \\import { run, waitSignal } from "zttp:durable";
        \\function handler(req) {
        \\  return run("job:signal", () => {
        \\    const payload = waitSignal(req.url);
        \\    return Response.json(payload);
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(DurableWorkflowProofLevel.partial, contract.durable.workflow.proof_level);
    try std.testing.expect(!contract.durable.workflow.properties.fault_covered);
}

test "durable workflow saga call remains partial and unproven" {
    const source =
        \\import { run } from "zttp:durable";
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("job:saga", () => {
        \\    const result = saga([]);
        \\    return Response.json(result);
        \\  });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(DurableWorkflowProofLevel.partial, contract.durable.workflow.proof_level);
    try std.testing.expect(!contract.durable.workflow.properties.retry_safe);
    try std.testing.expect(!contract.durable.workflow.properties.idempotent);
    try std.testing.expect(!contract.durable.workflow.properties.fault_covered);
}

test "computeProperties egress is conservative write" {
    var builder = ContractBuilder.init(std.testing.allocator, undefined, null, null, null);
    defer builder.deinit();

    builder.egress_dynamic = true;

    const props = try builder.computeProperties(null, null);

    try std.testing.expect(!props.pure);
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.stateless);
    try std.testing.expect(!props.retry_safe);
    try std.testing.expect(props.has_egress);
}

test "registered partner manifest contributes effect class to handler properties" {
    const allocator = std.testing.allocator;

    // Partner manifest declares a write-effect export. The handler imports it
    // and calls it; the builder should reflect non-read-only properties.
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:stripe",
        \\  "backend": "native-zig",
        \\  "requiredCapabilities": ["network"],
        \\  "exports": [
        \\    { "name": "chargeCard", "effect": "write", "returns": "result" }
        \\  ]
        \\}
    ;
    var manifest = try module_manifest.parse(allocator, manifest_json);
    errdefer manifest.deinit(allocator);

    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(manifest);

    const source =
        \\import { chargeCard } from "zttp-ext:stripe";
        \\const r = chargeCard("tok");
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();

    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var builder = ContractBuilder.init(allocator, ir_view, &atoms, null, null);
    builder.manifest_registry = &registry;
    defer builder.deinit();

    try builder.buildFacts();

    try std.testing.expect(containsString(builder.owned_facts.modules.items, "zttp-ext:stripe"));
    try std.testing.expectEqual(@as(usize, 1), builder.owned_facts.functions.items.len);
    try std.testing.expectEqualStrings("zttp-ext:stripe", builder.owned_facts.functions.items[0].module);
    try std.testing.expect(containsString(builder.owned_facts.functions.items[0].names.items, "chargeCard"));

    const props = try builder.computeProperties(null, null);
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.idempotent);
    try std.testing.expect(!props.pure);
}

test "partner manifest contractExtractions populate extensions section" {
    const allocator = std.testing.allocator;

    // Partner declares a fetch_host rule on arg 0 and an extension_specific
    // rule (category = payment_gateway) on arg 1.
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:stripe",
        \\  "exports": [
        \\    {
        \\      "name": "charge",
        \\      "effect": "write",
        \\      "returns": "result",
        \\      "contractExtractions": [
        \\        { "category": "fetch_host", "argPosition": 0 },
        \\        { "category": "extension_specific", "extensionCategory": "payment_gateway", "argPosition": 1 }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    var manifest = try module_manifest.parse(allocator, manifest_json);
    errdefer manifest.deinit(allocator);

    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(manifest);

    const source =
        \\import { charge } from "zttp-ext:stripe";
        \\const r = charge("api.stripe.com", "card_charge");
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();

    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var builder = ContractBuilder.init(allocator, ir_view, &atoms, null, null);
    builder.manifest_registry = &registry;
    defer builder.deinit();

    try builder.buildFacts();
    try builder.scanCallSites();

    // Top-level egress mirrors the partner-declared fetch_host (shared-section
    // product decision: write to both).
    try std.testing.expect(containsString(builder.egress_hosts.items, "api.stripe.com"));

    // Per-extension copy lives under extensions["zttp-ext:stripe"].
    const ext = builder.extensions.get("zttp-ext:stripe") orelse return error.TestExpectedExtension;
    try std.testing.expect(containsString(ext.egress_hosts.items, "api.stripe.com"));

    // The payment_gateway category bucket holds the second arg's literal.
    const bucket = ext.categories.get("payment_gateway") orelse return error.TestExpectedCategory;
    try std.testing.expect(containsString(bucket.literals.items, "card_charge"));
}

test "builtin zttp:fetch extracts the Open-Meteo egress host from a literal url" {
    const allocator = std.testing.allocator;

    // Mirrors examples/fetch/weather-forecasts.ts: a single keyless fetch to
    // Open-Meteo. The built-in fetch binding declares a fetch_host/extract_host
    // contract extraction on arg 0, so the host must land in egress_hosts as the
    // sole proven host with dynamic=false. This locks the demo's headline proof.
    const source =
        \\import { fetch } from "zttp:fetch";
        \\const r = fetch("https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current=temperature_2m&timezone=auto", { headers: { "Accept": "application/json" } });
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();

    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var builder = ContractBuilder.init(allocator, ir_view, &atoms, null, null);
    defer builder.deinit();

    try builder.buildFacts();
    try builder.scanCallSites();

    try std.testing.expect(containsString(builder.egress_hosts.items, "api.open-meteo.com"));
    // Exactly one proven host, statically known (not dynamic).
    try std.testing.expectEqual(@as(usize, 1), builder.egress_hosts.items.len);
    try std.testing.expect(!builder.egress_dynamic);
}

fn findAffordanceByRel(items: []const contract_types.EmittedAffordance, rel: []const u8) ?contract_types.EmittedAffordance {
    for (items) |a| {
        if (std.mem.eql(u8, a.rel, rel)) return a;
    }
    return null;
}

fn findWorkflowCallByTarget(items: []const contract_types.WorkflowCallInfo, target: []const u8) ?contract_types.WorkflowCallInfo {
    for (items) |call| {
        if (std.mem.eql(u8, call.target, target)) return call;
    }
    return null;
}

test "resource() affordances are extracted strict-literal with method default and templating" {
    const allocator = std.testing.allocator;

    // `resource` is a bare global; no import. Three affordances: a GET nav link
    // (method defaults to GET), a POST write, and a templated GET (href has a
    // {param} placeholder the linker normalizes before route matching).
    const source =
        \\function handler(req) {
        \\  return resource({ id: 1 }, {
        \\    self: { href: "/orders/1" },
        \\    pay: { href: "/orders/1/pay", method: "POST" },
        \\    item: { href: "/orders/{id}", method: "GET" },
        \\  });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();

    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var builder = ContractBuilder.init(allocator, ir_view, &atoms, null, null);
    defer builder.deinit();

    try builder.buildFacts();
    try builder.scanCallSites();

    try std.testing.expect(!builder.affordances_dynamic);
    try std.testing.expectEqual(@as(usize, 3), builder.affordances.items.len);

    const self_aff = findAffordanceByRel(builder.affordances.items, "self").?;
    try std.testing.expectEqualStrings("/orders/1", self_aff.href);
    try std.testing.expectEqualStrings("GET", self_aff.method);
    try std.testing.expect(!self_aff.dynamic);
    try std.testing.expect(!self_aff.templated);

    const pay = findAffordanceByRel(builder.affordances.items, "pay").?;
    try std.testing.expectEqualStrings("POST", pay.method);
    try std.testing.expectEqualStrings("/orders/1/pay", pay.href);

    const item = findAffordanceByRel(builder.affordances.items, "item").?;
    try std.testing.expect(item.templated);
    try std.testing.expect(!item.dynamic);
}

test "resource() with a computed affordances argument fails closed as affordances_dynamic" {
    const allocator = std.testing.allocator;

    const source =
        \\function handler(req) {
        \\  return resource({ id: 1 }, req.links);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();

    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var builder = ContractBuilder.init(allocator, ir_view, &atoms, null, null);
    defer builder.deinit();

    try builder.buildFacts();
    try builder.scanCallSites();

    try std.testing.expect(builder.affordances_dynamic);
    try std.testing.expectEqual(@as(usize, 0), builder.affordances.items.len);
}

test "resource() affordance with a non-literal href is recorded dynamic, not resolved" {
    const allocator = std.testing.allocator;

    const source =
        \\function handler(req) {
        \\  return resource({ id: 1 }, {
        \\    self: { href: "/orders/1" },
        \\    next: { href: req.nextHref, method: "POST" },
        \\  });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();

    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var builder = ContractBuilder.init(allocator, ir_view, &atoms, null, null);
    defer builder.deinit();

    try builder.buildFacts();
    try builder.scanCallSites();

    // The set is enumerable (object literal), so affordances_dynamic stays false,
    // but the individual non-literal-href affordance is marked dynamic.
    try std.testing.expect(!builder.affordances_dynamic);
    const next = findAffordanceByRel(builder.affordances.items, "next").?;
    try std.testing.expect(next.dynamic);
    const self_aff = findAffordanceByRel(builder.affordances.items, "self").?;
    try std.testing.expect(!self_aff.dynamic);
}

test "workflow call and fanout dispatch targets are extracted" {
    const source =
        \\import { call, fanout } from "zttp:workflow";
        \\function handler(req) {
        \\  call("payments", { method: "POST", path: "/charge" });
        \\  fanout([
        \\    { name: "inventory", path: "/reserve" },
        \\    { name: "pricing", method: "POST", path: "/quote", headers: { accept: "json" } },
        \\  ]);
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), contract.workflow_calls.items.len);

    const payments = findWorkflowCallByTarget(contract.workflow_calls.items, "payments").?;
    try std.testing.expectEqualStrings("POST /charge", payments.route_pattern);
    try std.testing.expect(!payments.dynamic);

    const inventory = findWorkflowCallByTarget(contract.workflow_calls.items, "inventory").?;
    try std.testing.expectEqualStrings("GET /reserve", inventory.route_pattern);
    try std.testing.expect(!inventory.dynamic);

    const pricing = findWorkflowCallByTarget(contract.workflow_calls.items, "pricing").?;
    try std.testing.expectEqualStrings("POST /quote", pricing.route_pattern);
    try std.testing.expect(!pricing.dynamic);
}

test "fanout descriptor with unknown sibling field fails closed" {
    const source =
        \\import { fanout } from "zttp:workflow";
        \\function handler(req) {
        \\  fanout([{ name: "inventory", path: "/reserve", timeoutMs: 50 }]);
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.workflow_calls.items.len);
    try std.testing.expect(contract.workflow_calls.items[0].dynamic);
    try std.testing.expectEqualStrings("", contract.workflow_calls.items[0].target);
    try std.testing.expectEqualStrings("", contract.workflow_calls.items[0].route_pattern);
}

test "workflow call with a non-literal target is recorded dynamic" {
    const source =
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  call(req.url, { method: "POST", path: "/charge" });
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.workflow_calls.items.len);
    try std.testing.expect(contract.workflow_calls.items[0].dynamic);
}

test "workflow call with undefined init keeps GET / defaults and stays static" {
    const source =
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  call("payments", undefined);
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.workflow_calls.items.len);
    try std.testing.expect(!contract.workflow_calls.items[0].dynamic);
    try std.testing.expectEqualStrings("payments", contract.workflow_calls.items[0].target);
    try std.testing.expectEqualStrings("GET /", contract.workflow_calls.items[0].route_pattern);
}

test "workflow call init with an unknown key fails closed to dynamic" {
    const source =
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  call("inventory", { path: "/reserve", timeoutMs: 50 });
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.workflow_calls.items.len);
    // Mirrors fanout's unknown-sibling-field fail-closed behavior: an
    // unrecognized init key marks the call dynamic, not silently ignored.
    try std.testing.expect(contract.workflow_calls.items[0].dynamic);
}

test "workflow call init recognizes body and headers as presence-only" {
    const source =
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  call("inventory", { method: "POST", path: "/reserve", body: { qty: 1 }, headers: { accept: "json" } });
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.workflow_calls.items.len);
    try std.testing.expect(!contract.workflow_calls.items[0].dynamic);
    try std.testing.expectEqualStrings("POST /reserve", contract.workflow_calls.items[0].route_pattern);
}

test "a literal rateCheck key becomes the rate-limit namespace" {
    const source =
        \\import { rateCheck } from "zttp:ratelimit";
        \\function handler(req) {
        \\  const allowed = rateCheck("login-attempts", 5, 60);
        \\  if (!allowed.ok) return Response.json({ error: "slow down" }, { status: 429 });
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    const rl = contract.rate_limiting orelse return error.MissingRateLimit;
    try std.testing.expectEqualStrings("login-attempts", rl.namespace);
    try std.testing.expect(!rl.dynamic);
}

test "a computed rateCheck key still detects rate limiting, with no namespace" {
    // The common production shape. Firing here is the point: a deployment
    // rate-limits whether or not the compiler can name the bucket.
    const source =
        \\import { rateCheck } from "zttp:ratelimit";
        \\function handler(req) {
        \\  const key = req.headers["x-forwarded-for"] ?? "anon";
        \\  const allowed = rateCheck(key, 5, 60);
        \\  if (!allowed.ok) return Response.json({ error: "slow down" }, { status: 429 });
        \\  return Response.json({ ok: true });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    const rl = contract.rate_limiting orelse return error.MissingRateLimit;
    try std.testing.expectEqualStrings("", rl.namespace);
    try std.testing.expect(rl.dynamic);
}

test "an incremented counter alone is not rate limiting" {
    // The signal the old detector half-rested on. A page-view tally is a
    // counter, and calling it a rate limit would put a namespace the
    // deployment must provision into the manifest of a handler that has none.
    const source =
        \\import { cacheIncr } from "zttp:cache";
        \\function handler(req) {
        \\  const views = cacheIncr("page-views", 1);
        \\  return Response.json({ views: views });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(contract.rate_limiting == null);
}

test "post_only is proven for static POST-only routerMatch tables" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\function create(req) { return Response.json({ ok: true }); }
        \\const routes = {
        \\  "POST /orders": create,
        \\  "POST /orders/:id": create,
        \\};
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.json({ error: "not found" }, { status: 404 });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(props.post_only);
}

test "post_only is not proven when a static routerMatch table mixes methods" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\function create(req) { return Response.json({ ok: true }); }
        \\const routes = {
        \\  "POST /orders": create,
        \\  "GET /orders/:id": create,
        \\};
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.json({ error: "not found" }, { status: 404 });
        \\}
    ;
    var contract = try buildTestContract(source);
    defer contract.deinit(std.testing.allocator);

    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(!props.post_only);
}

test "missing manifest registry skips partner imports" {
    const allocator = std.testing.allocator;

    const source =
        \\import { unknownFn } from "zttp-ext:unknown";
        \\const r = unknownFn();
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();

    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var builder = ContractBuilder.init(allocator, ir_view, &atoms, null, null);
    defer builder.deinit();

    try builder.buildFacts();

    try std.testing.expect(!containsString(builder.owned_facts.modules.items, "zttp-ext:unknown"));
    try std.testing.expectEqual(@as(usize, 0), builder.owned_facts.functions.items.len);
}
