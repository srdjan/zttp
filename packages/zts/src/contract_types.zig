//! Contract data types for `HandlerContract`. Extracted from
//! handler_contract.zig as the third step of the split. handler_contract.zig
//! re-exports every public name from this file so existing callers
//! (`handler_contract.HandlerContract`, `handler_contract.ApiRouteInfo`, etc.)
//! continue to resolve. Constructors that are tightly coupled to the types
//! they build (`emptyApiInfo`, `emptySqlInfo`, `emptyContract`,
//! `computeCapabilityMatrix`) live here too.

const std = @import("std");
// The capability enum and its two derived helpers, straight from the leaf
// file that defines them. `module_binding.zig` re-exports the same three
// names, but reaching them there would pull the module bridge, the SDK
// adapter and the engine into every consumer of a contract.
const module_binding = @import("zts-base").module_authorization;
const profile_identity = @import("zts-base").profile_identity;

fn dupeOptionalString(allocator: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try allocator.dupe(u8, v) else null;
}

pub const HandlerLoc = struct {
    path: []const u8, // owned
    line: u32,
    column: u32,
};
pub const CoreProfile = profile_identity.CoreProfile;
/// Exact language identity used to turn authored source into core bytecode.
/// Hashes are raw SHA-256 bytes on the domain type and lowercase hex on wire.
pub const SourceIdentity = struct {
    core_profile: CoreProfile = profile_identity.core_profile,
    core_grammar_hash: [32]u8 = @as([32]u8, @splat(0)),
    semantics_hash: [32]u8 = @as([32]u8, @splat(0)),
    pub fn isStamped(self: SourceIdentity) bool {
        return !std.mem.allEqual(u8, &self.core_grammar_hash, 0) and
            !std.mem.allEqual(u8, &self.semantics_hash, 0);
    }
};

pub const RouteInfo = struct {
    pattern: []const u8, // owned
    route_type: []const u8, // static literal, not owned
    field: []const u8, // static literal, not owned
    status: u16,
    content_type: []const u8, // static literal, not owned
    aot: bool,
};

pub const EnvInfo = struct {
    literal: std.ArrayList([]const u8), // each entry owned
    dynamic: bool,
    /// The names the policy's `env.public` declared non-secret when the
    /// contract was built (D-014). Disclosure only: the runtime policy does not
    /// carry it, and an empty list is not written.
    public: std.ArrayList([]const u8) = .empty, // each entry owned
};

pub const EgressInfo = struct {
    /// Normalized `scheme://host:port`, one per literal destination the
    /// compiler saw. A host name names no destination: the same host under a
    /// different scheme or port is a different server, so the contract records
    /// what the runtime will compare - see `zts.endpoint`.
    endpoints: std.ArrayList([]const u8), // each entry owned
    urls: std.ArrayList([]const u8) = .empty, // full fetchSync URLs, each entry owned
    dynamic: bool,
};

/// Bucket of partner-extracted literals for one declared category.
pub const ExtensionCategoryBucket = struct {
    literals: std.ArrayList([]const u8) = .empty, // each entry owned
    dynamic: bool = false,

    pub fn deinit(self: *ExtensionCategoryBucket, allocator: std.mem.Allocator) void {
        for (self.literals.items) |s| allocator.free(s);
        self.literals.deinit(allocator);
    }
};

/// Per-specifier proof facts derived from a partner virtual-module
/// manifest's `contractExtractions`. Lands under `contract.json` at
/// `extensions.<specifier>`. The keys of `categories` are the partner-declared
/// `extension_category` tags (e.g. "payment_gateway", "llm_egress").
pub const ExtensionContract = struct {
    /// Per-extension copy of egress hosts. The same hosts also land in the
    /// top-level `egress.endpoints` list so runtime policy enforcement stays
    /// uniform; this duplicate preserves provenance.
    egress_endpoints: std.ArrayList([]const u8) = .empty, // each entry owned
    egress_dynamic: bool = false,
    /// Partner-declared category tag -> bucket of extracted literals. Keys
    /// are owned; lookup is structural.
    categories: std.StringHashMapUnmanaged(ExtensionCategoryBucket) = .empty,
    /// Optional partner-declared top-level contract section name. When non-
    /// null, the writer mirrors this extension's category buckets under a
    /// top-level `<name>` block. Owned by the contract.
    contract_section: ?[]u8 = null,

    pub fn deinit(self: *ExtensionContract, allocator: std.mem.Allocator) void {
        for (self.egress_endpoints.items) |s| allocator.free(s);
        self.egress_endpoints.deinit(allocator);
        var it = self.categories.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.categories.deinit(allocator);
        if (self.contract_section) |slice| allocator.free(slice);
    }
};

pub const CacheInfo = struct {
    namespaces: std.ArrayList([]const u8), // each entry owned
    dynamic: bool,
};

pub const SqlQueryInfo = struct {
    name: []const u8, // owned
    statement: []const u8, // owned
    operation: []const u8 = "", // static literal after validation
    tables: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *SqlQueryInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.statement);
        for (self.tables.items) |table| allocator.free(table);
        self.tables.deinit(allocator);
    }
};

pub const SqlInfo = struct {
    backend: []const u8 = "sqlite",
    queries: std.ArrayList(SqlQueryInfo),
    dynamic: bool,

    pub fn deinit(self: *SqlInfo, allocator: std.mem.Allocator) void {
        for (self.queries.items) |*query| query.deinit(allocator);
        self.queries.deinit(allocator);
    }
};

pub const ApiSchemaInfo = struct {
    name: []const u8, // owned
    schema_json: []const u8, // owned JSON source
};

pub const ApiRequestInfo = struct {
    schema_refs: std.ArrayList([]const u8), // each entry owned
    dynamic: bool,
};

pub const ApiAuthInfo = struct {
    bearer: bool,
    jwt: bool,
};

pub const ApiParamInfo = struct {
    name: []const u8, // owned
    location: []const u8 = "path", // static literal
    required: bool = false,
    schema_json: []const u8, // owned JSON source

    pub fn deinit(self: *ApiParamInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.schema_json);
    }

    pub fn dupeOwned(self: ApiParamInfo, allocator: std.mem.Allocator) !ApiParamInfo {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const schema_json = try allocator.dupe(u8, self.schema_json);
        return .{
            .name = name,
            .location = self.location,
            .required = self.required,
            .schema_json = schema_json,
        };
    }
};

pub const SchemaSpec = union(enum) {
    none,
    ref: []const u8, // owned
    inline_json: []const u8, // owned
    dynamic,

    /// Build a spec from the separate scalar fields the wire format, the
    /// builder's candidates, and the differ all carry. This is where the
    /// precedence (dynamic > inline JSON > ref > none) is decided, once - it is
    /// the round-trip invariant, so a copy that reorders these checks makes a
    /// contract read back as something other than what was written.
    ///
    /// The payload slices are borrowed from the arguments. Chain `dupeOwned` for
    /// an owned spec; that way only the winning branch allocates.
    pub fn fromFields(
        schema_ref: ?[]const u8,
        schema_json: ?[]const u8,
        dynamic: bool,
    ) SchemaSpec {
        if (dynamic) return .dynamic;
        if (schema_json) |json| return .{ .inline_json = json };
        if (schema_ref) |reference| return .{ .ref = reference };
        return .none;
    }

    pub fn schemaRef(self: SchemaSpec) ?[]const u8 {
        return switch (self) {
            .ref => |s| s,
            else => null,
        };
    }

    pub fn schemaJson(self: SchemaSpec) ?[]const u8 {
        return switch (self) {
            .inline_json => |s| s,
            else => null,
        };
    }

    pub fn isDynamic(self: SchemaSpec) bool {
        return self == .dynamic;
    }

    pub fn deinitOwned(self: SchemaSpec, allocator: std.mem.Allocator) void {
        switch (self) {
            .ref => |s| allocator.free(s),
            .inline_json => |s| allocator.free(s),
            .none, .dynamic => {},
        }
    }

    pub fn dupeOwned(self: SchemaSpec, allocator: std.mem.Allocator) !SchemaSpec {
        return switch (self) {
            .none => .none,
            .ref => |s| .{ .ref = try allocator.dupe(u8, s) },
            .inline_json => |s| .{ .inline_json = try allocator.dupe(u8, s) },
            .dynamic => .dynamic,
        };
    }
};

pub const ApiBodyInfo = struct {
    content_type: ?[]const u8 = null, // owned when present
    schema: SchemaSpec = .none,

    pub fn deinit(self: *ApiBodyInfo, allocator: std.mem.Allocator) void {
        if (self.content_type) |content_type| allocator.free(content_type);
        self.schema.deinitOwned(allocator);
    }

    pub fn dupeOwned(self: ApiBodyInfo, allocator: std.mem.Allocator) !ApiBodyInfo {
        const content_type = try dupeOptionalString(allocator, self.content_type);
        errdefer if (content_type) |c| allocator.free(c);
        const schema = try self.schema.dupeOwned(allocator);
        return .{ .content_type = content_type, .schema = schema };
    }
};

pub const ApiResponseInfo = struct {
    status: ?u16 = null,
    content_type: ?[]const u8 = null, // owned when present
    schema: SchemaSpec = .none,

    pub fn deinit(self: *ApiResponseInfo, allocator: std.mem.Allocator) void {
        if (self.content_type) |content_type| allocator.free(content_type);
        self.schema.deinitOwned(allocator);
    }

    pub fn dupeOwned(self: ApiResponseInfo, allocator: std.mem.Allocator) !ApiResponseInfo {
        const content_type = try dupeOptionalString(allocator, self.content_type);
        errdefer if (content_type) |c| allocator.free(c);
        const schema = try self.schema.dupeOwned(allocator);
        return .{ .status = self.status, .content_type = content_type, .schema = schema };
    }
};

pub const ApiRouteInfo = struct {
    method: []const u8, // owned
    path: []const u8, // owned
    request_schema_refs: std.ArrayList([]const u8), // each entry owned
    request_schema_dynamic: bool,
    requires_bearer: bool,
    requires_jwt: bool,
    path_params: std.ArrayList(ApiParamInfo) = .empty,
    query_params: std.ArrayList(ApiParamInfo) = .empty,
    header_params: std.ArrayList(ApiParamInfo) = .empty,
    query_params_dynamic: bool = false,
    header_params_dynamic: bool = false,
    request_bodies: std.ArrayList(ApiBodyInfo) = .empty,
    request_bodies_dynamic: bool = false,
    responses: std.ArrayList(ApiResponseInfo) = .empty,
    responses_dynamic: bool = false,
    // Legacy scalar response fields, kept for backward compatibility with
    // older contract.json consumers. backfillApiRouteCollections bridges
    // these into the responses collection during deserialization.
    response_status: ?u16 = null,
    response_content_type: ?[]const u8 = null, // owned when present
    response_schema_ref: ?[]const u8 = null, // owned when present
    response_schema_json: ?[]const u8 = null, // owned when present
    response_schema_dynamic: bool = false,

    pub fn deinit(self: *ApiRouteInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        for (self.request_schema_refs.items) |schema_ref| {
            allocator.free(schema_ref);
        }
        self.request_schema_refs.deinit(allocator);
        for (self.path_params.items) |*param| {
            param.deinit(allocator);
        }
        self.path_params.deinit(allocator);
        for (self.query_params.items) |*param| {
            param.deinit(allocator);
        }
        self.query_params.deinit(allocator);
        for (self.header_params.items) |*param| {
            param.deinit(allocator);
        }
        self.header_params.deinit(allocator);
        for (self.request_bodies.items) |*body| {
            body.deinit(allocator);
        }
        self.request_bodies.deinit(allocator);
        for (self.responses.items) |*response| {
            response.deinit(allocator);
        }
        self.responses.deinit(allocator);
        if (self.response_content_type) |content_type| {
            allocator.free(content_type);
        }
        if (self.response_schema_ref) |schema_ref| {
            allocator.free(schema_ref);
        }
        if (self.response_schema_json) |schema_json| {
            allocator.free(schema_json);
        }
    }
};

pub const ApiInfo = struct {
    schemas: std.ArrayList(ApiSchemaInfo),
    requests: ApiRequestInfo,
    auth: ApiAuthInfo,
    routes: std.ArrayList(ApiRouteInfo),
    schemas_dynamic: bool,
    routes_dynamic: bool,

    pub fn deinit(self: *ApiInfo, allocator: std.mem.Allocator) void {
        for (self.schemas.items) |schema| {
            allocator.free(schema.name);
            allocator.free(schema.schema_json);
        }
        self.schemas.deinit(allocator);
        for (self.requests.schema_refs.items) |schema_ref| {
            allocator.free(schema_ref);
        }
        self.requests.schema_refs.deinit(allocator);
        for (self.routes.items) |*route| {
            route.deinit(allocator);
        }
        self.routes.deinit(allocator);
    }
};

pub fn emptyApiInfo() ApiInfo {
    return .{
        .schemas = .empty,
        .requests = .{ .schema_refs = .empty, .dynamic = false },
        .auth = .{ .bearer = false, .jwt = false },
        .routes = .empty,
        .schemas_dynamic = false,
        .routes_dynamic = false,
    };
}

pub fn emptySqlInfo() SqlInfo {
    return .{
        .backend = "sqlite",
        .queries = .empty,
        .dynamic = false,
    };
}

/// Create a minimal empty contract with the given handler path (owned by caller).
pub fn emptyContract(path: []const u8) HandlerContract {
    return .{
        .handler = .{ .path = path, .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{ .literal = .empty, .dynamic = false },
        .egress = .{ .endpoints = .empty, .dynamic = false },
        .cache = .{ .namespaces = .empty, .dynamic = false },
        .sql = emptySqlInfo(),
        .api = emptyApiInfo(),
        .verification = null,
        .aot = null,
    };
}

pub const VerificationInfo = struct {
    exhaustive_returns: bool,
    results_safe: bool,
    unreachable_code: bool,
    /// Bytecode passed structural verification (opcode validity, bounds, stack discipline)
    bytecode_verified: bool = false,
};

pub const AotInfo = struct {
    pattern_count: u32,
    has_default: bool,
};

pub const FaultCoverageInfo = struct {
    total_failable: u32,
    covered: u32,
    warnings: u32,
    /// Failable calls the path walk never recorded on any path. Such a call is
    /// neither counted nor covered, so one of them blocks `isCovered`. Not
    /// serialized: a decoded contract reports zero, and the property bit the
    /// build stamped is what a consumer reads.
    unseen_calls: u32 = 0,
    /// Covered upstream sites whose failure path returns 2xx. Not serialized:
    /// a count for the proof trace, which reports it as `upstreamFallbackSites`.
    upstream_fallback_sites: u32 = 0,
    /// `PathGenerator.faultAnalysisComplete()` when the build stamped the
    /// record: false when a loop, recursion, a limit, or an unresolved route
    /// dispatch left the path set a summary. No default, so each constructor
    /// states it. Not serialized as its own key: `isCovered` carries it, and a
    /// decoded record restores it from `isCovered`. After a decode a false
    /// value therefore cannot be told apart from `unseen_calls > 0`; both only
    /// say that `isCovered` was false although every counted site is covered.
    analysis_complete: bool,

    pub fn isCovered(self: FaultCoverageInfo) bool {
        return self.covered == self.total_failable and self.unseen_calls == 0 and self.analysis_complete;
    }
};

/// Handler-level properties derived from effect classification of virtual
/// module function calls. Computed during contract extraction by checking
/// each imported function's EffectClass (read/write/none).
pub const HandlerProperties = struct {
    /// No virtual module calls. Pure function of request.
    pure: bool,
    /// Only read-classified functions. No state mutations.
    read_only: bool,
    /// Read-only AND no cacheGet. Independent of mutable state.
    stateless: bool,
    /// Read-only. Safe for Lambda retry.
    retry_safe: bool,
    /// No Date.now(), Math.random(), or performance.now() usage.
    deterministic: bool,
    /// Uses fetchSync (conservative write).
    has_egress: bool,
    // --- Data flow provenance (from FlowChecker) ---
    /// No {secret} data reaches response bodies or headers, logs, or external
    /// egress. A write to cache or SQL is not a sink. Store readers carry
    /// {unknown}.
    no_secret_leakage: bool = true,
    /// No {credential} data reaches response bodies or headers, logs, or external
    /// egress (URL, headers, or body). The store exclusion matches
    /// `no_secret_leakage`.
    no_credential_leakage: bool = true,
    /// All {user_input} data passes through validation before external egress.
    input_validated: bool = true,
    /// {user_input} data does not flow to external egress hosts.
    pii_contained: bool = true,
    // --- Derived properties ---
    /// Deterministic AND read_only.
    /// Safe for at-least-once delivery and automatic retry.
    idempotent: bool = false,
    /// Maximum number of I/O calls on any single execution path.
    /// Enables compile-time Lambda timeout derivation.
    max_io_depth: ?u32 = null,
    /// No unvalidated user input reaches sensitive sinks.
    /// Proves SQL injection and XSS prevention.
    injection_safe: bool = true,
    /// No module-scope variable mutations inside handler body.
    /// Proves cross-request data isolation.
    state_isolated: bool = true,
    // --- Fault coverage (from FaultCoverageChecker) ---
    /// Every failable I/O call site has an explicit failure path.
    fault_covered: bool = false,
    // --- Result and optional safety (from HandlerVerifier, when -Dverify is run) ---
    /// Proven: every result.ok access is guarded before use.
    /// False = unproven (verification not run). True = verified safe.
    result_safe: bool = false,
    /// Proven: every optional value from virtual modules is narrowed before use.
    /// False = unproven (verification not run). True = verified safe.
    optional_safe: bool = false,
    /// The handler's AOT route table (`routerMatch({...}, req)`) is non-empty,
    /// statically enumerable, and every route's method is POST. False when
    /// the route table is empty, dynamic, or mixes in a non-POST method - a
    /// handler using an ad hoc `if (req.method !== "POST")` guard without the
    /// `routerMatch` convention does not earn this proof for free.
    post_only: bool = false,
    // --- Canonical normal form (from the strict_checker ZTS6xx gate) ---
    /// The handler source is in Canonical Normal Form: zero canonical-profile
    /// (ZTS6xx) diagnostics at `error` severity. Those are hard `check` errors,
    /// so a contract is only ever built for a handler carrying none of them,
    /// and the contract builder sets this true unconditionally. The chip makes
    /// the always-on gate explicit and attestable; `Proof<T, "canonical">`
    /// discharges against it.
    ///
    /// An advisory in the same band does not deny it, and that is the rule
    /// rather than an omission: spec 4.2.1's idiom rows report a preference
    /// about a program that is already correct, and a row whose precondition
    /// fails emits no rewrite, so there is nothing an author could do to clear
    /// it. `no ZTS6xx diagnostics` was the old wording and it stopped being
    /// true when the first idiom row started reporting.
    canonical: bool = false,
    /// The handler's total cost bound is expressible (constant or linear):
    /// no unbounded loop over an unidentifiable source, and path enumeration
    /// was exhaustive. Derived from cost_envelope.total in precompile stage 9.
    cost_bounded: bool = false,

    /// Canonical list of property names that are currently proven true. The
    /// order is stable across builds (struct-field declaration order) so
    /// cross-build diffs surface added/dropped names instead of reordered
    /// noise. Returns slices into static field-name strings; no allocation.
    /// The returned count is clamped to `out.len`; callers wanting the full
    /// set should size against `max_proven_specs`.
    pub fn provenSpecNames(self: *const HandlerProperties, out: []?[]const u8) usize {
        var count: usize = 0;
        inline for (@typeInfo(HandlerProperties).@"struct".field_names) |field| {
            if (@FieldType(HandlerProperties, field) == bool and isMonotonicProvenSpec(field) and @field(self, field)) {
                if (count < out.len) {
                    out[count] = field;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Compile-time upper bound on the proven-set size, equal to the count of
    /// boolean fields in `HandlerProperties`. Caller-side buffers should size
    /// against this so `provenSpecNames` never overflows.
    pub const max_proven_specs: usize = blk: {
        var n: usize = 0;
        for (@typeInfo(HandlerProperties).@"struct".field_names) |field| {
            if (@FieldType(HandlerProperties, field) == bool and isMonotonicProvenSpec(field)) n += 1;
        }
        break :blk n;
    };

    /// True when a property name belongs in monotonic proof ratchets. Positive
    /// safety guarantees are monotonic; inverse facts such as `has_egress`
    /// are deliberately excluded so removing risky behavior cannot regress.
    pub fn isMonotonicProvenSpecName(name: []const u8) bool {
        inline for (@typeInfo(HandlerProperties).@"struct".field_names) |field| {
            if (@FieldType(HandlerProperties, field) == bool and isMonotonicProvenSpec(field) and std.mem.eql(u8, field, name)) {
                return true;
            }
        }
        return false;
    }

    /// Translate a snake_case `HandlerProperties` field name (e.g. "read_only")
    /// to the camelCase JSON key the writer emits (e.g. "readOnly"). Driven by
    /// `@typeInfo` so adding a field automatically extends both the JSON
    /// writer's emitted keys and the parser's camel-to-snake lookup. Returns
    /// null for names that are not field names of this struct.
    pub fn camelKeyFor(snake_field_name: []const u8) ?[]const u8 {
        inline for (@typeInfo(HandlerProperties).@"struct".field_names) |field| {
            if (std.mem.eql(u8, field, snake_field_name)) {
                return comptime snakeToCamel(field);
            }
        }
        return null;
    }

    /// A property left out of a list that covers only part of `HandlerProperties`, with the reason.
    pub const Exclusion = struct {
        name: []const u8,
        reason: []const u8,
    };

    /// One `Exclusion` per name, all with the same reason.
    pub fn exclusions(comptime names: []const []const u8, comptime reason: []const u8) [names.len]Exclusion {
        var out: [names.len]Exclusion = undefined;
        for (names, 0..) |name, index| out[index] = .{ .name = name, .reason = reason };
        return out;
    }

    /// The first problem in how `Members` covers `HandlerProperties`, or null. `Members` is an
    /// enum or a struct whose field names are property names. Every `HandlerProperties` field is a
    /// member or is excluded with a reason, every member is a `HandlerProperties` field (of the
    /// same type, for a struct), and no name is both. A list that covers only part of the
    /// properties spells the rest out, so a new field forces a decision in every list. Use it
    /// in a `comptime` block: `if (HandlerProperties.coverageProblem(List, &excluded)) |problem|
    /// @compileError(problem);`. It checks names, never order: a registry hash depends on
    /// the order of an enum, and `test-meta-drift` owns that.
    pub fn coverageProblem(comptime Members: type, comptime excluded: []const Exclusion) ?[]const u8 {
        comptime {
            @setEvalBranchQuota(100_000);
            const label = @typeName(Members);
            const member_names = switch (@typeInfo(Members)) {
                .@"enum" => |info| info.field_names,
                .@"struct" => |info| info.field_names,
                else => @compileError(label ++ " is neither an enum nor a struct"),
            };
            if (@typeInfo(Members) == .@"struct") {
                for (member_names) |name| {
                    if (@hasField(HandlerProperties, name) and @FieldType(Members, name) != @FieldType(HandlerProperties, name))
                        return label ++ ": field type differs from HandlerProperties: " ++ name;
                }
            }
            if (namesCoverageProblem(label, member_names, excluded)) |problem| return problem;
            return null;
        }
    }

    /// `coverageProblem` for a table that names properties as data: `label` names the table in the
    /// message, `member_names` are the names it carries.
    pub fn namesCoverageProblem(comptime label: []const u8, comptime member_names: []const []const u8, comptime excluded: []const Exclusion) ?[]const u8 {
        comptime {
            @setEvalBranchQuota(100_000);
            for (excluded) |entry| {
                if (!@hasField(HandlerProperties, entry.name)) return label ++ ": exclusion names no HandlerProperties field: " ++ entry.name;
                if (entry.reason.len == 0) return label ++ ": exclusion has no reason: " ++ entry.name;
                if (containsName(member_names, entry.name)) return label ++ ": property is both a member and excluded: " ++ entry.name;
            }
            for (member_names) |name| {
                if (!@hasField(HandlerProperties, name)) return label ++ ": member is not a HandlerProperties field: " ++ name;
            }
            for (@typeInfo(HandlerProperties).@"struct".field_names) |field| {
                if (containsName(member_names, field) or isExcludedName(excluded, field)) continue;
                return label ++ ": HandlerProperties field is neither a member nor excluded: " ++ field;
            }
            return null;
        }
    }
};

fn isMonotonicProvenSpec(comptime field_name: []const u8) bool {
    return !std.mem.eql(u8, field_name, "has_egress");
}

fn containsName(comptime names: anytype, comptime name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn isExcludedName(comptime excluded: []const HandlerProperties.Exclusion, comptime name: []const u8) bool {
    for (excluded) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

/// Compile-time snake_case -> camelCase, e.g. "no_secret_leakage" -> "noSecretLeakage".
fn snakeToCamel(comptime snake: []const u8) []const u8 {
    comptime {
        var buf: [snake.len]u8 = undefined;
        var len: usize = 0;
        var upper_next = false;
        for (snake) |c| {
            if (c == '_') {
                upper_next = true;
                continue;
            }
            buf[len] = if (upper_next and c >= 'a' and c <= 'z') c - 32 else c;
            len += 1;
            upper_next = false;
        }
        const out = buf[0..len].*;
        return &out;
    }
}

test "HandlerProperties.provenSpecNames excludes inverse-polarity facts" {
    const props = HandlerProperties{
        .pure = false,
        .read_only = false,
        .stateless = false,
        .retry_safe = false,
        .deterministic = false,
        .has_egress = true,
    };

    var buf: [HandlerProperties.max_proven_specs]?[]const u8 = undefined;
    const count = props.provenSpecNames(&buf);
    try std.testing.expect(count > 0);
    var found_no_secret_leakage = false;
    for (buf[0..count]) |name_opt| {
        try std.testing.expect(!std.mem.eql(u8, name_opt.?, "has_egress"));
        // Fields set false above are not proven, so they are not named.
        try std.testing.expect(!std.mem.eql(u8, name_opt.?, "pure"));
        try std.testing.expect(!std.mem.eql(u8, name_opt.?, "deterministic"));
        // The default leaves no_secret_leakage true, so it is among the names.
        if (std.mem.eql(u8, name_opt.?, "no_secret_leakage")) found_no_secret_leakage = true;
    }
    try std.testing.expect(found_no_secret_leakage);
    try std.testing.expect(!HandlerProperties.isMonotonicProvenSpecName("has_egress"));
    try std.testing.expect(HandlerProperties.isMonotonicProvenSpecName("no_secret_leakage"));
}

test "coverageProblem names each way a property list can drift from HandlerProperties" {
    const Unknown = enum { pure, nonsense };
    const Partial = enum { pure };
    const WrongType = struct { max_io_depth: bool };
    const none = [_]HandlerProperties.Exclusion{};
    try std.testing.expect(std.mem.endsWith(u8, comptime HandlerProperties.coverageProblem(Unknown, &none).?, "member is not a HandlerProperties field: nonsense"));
    try std.testing.expect(std.mem.endsWith(u8, comptime HandlerProperties.coverageProblem(Partial, &none).?, "HandlerProperties field is neither a member nor excluded: read_only"));
    try std.testing.expect(std.mem.endsWith(u8, comptime HandlerProperties.coverageProblem(WrongType, &none).?, "field type differs from HandlerProperties: max_io_depth"));
    const missing = [_]HandlerProperties.Exclusion{.{ .name = "gone", .reason = "x" }};
    try std.testing.expect(std.mem.endsWith(u8, comptime HandlerProperties.coverageProblem(Partial, &missing).?, "exclusion names no HandlerProperties field: gone"));
    const no_reason = [_]HandlerProperties.Exclusion{.{ .name = "read_only", .reason = "" }};
    try std.testing.expect(std.mem.endsWith(u8, comptime HandlerProperties.coverageProblem(Partial, &no_reason).?, "exclusion has no reason: read_only"));
    const both = [_]HandlerProperties.Exclusion{.{ .name = "pure", .reason = "x" }};
    try std.testing.expect(std.mem.endsWith(u8, comptime HandlerProperties.coverageProblem(Partial, &both).?, "property is both a member and excluded: pure"));
    try std.testing.expect(std.mem.endsWith(u8, comptime HandlerProperties.namesCoverageProblem("table", &.{ "pure", "nonsense" }, &none).?, "member is not a HandlerProperties field: nonsense"));
    try std.testing.expect(std.mem.endsWith(u8, comptime HandlerProperties.namesCoverageProblem("table", &.{"pure"}, &none).?, "HandlerProperties field is neither a member nor excluded: read_only"));
    const two = HandlerProperties.exclusions(&.{ "pure", "read_only" }, "why");
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("why", two[1].reason);
}

test "Bound.addBorrowed degrades mixed linear sources to unbounded" {
    const first = Bound{ .linear = .{
        .coefficient = 1,
        .base = 0,
        .source = .{ .line = 4, .column = 2, .desc = "for...of over `ids`" },
    } };
    const second = Bound{ .linear = .{
        .coefficient = 1,
        .base = 0,
        .source = .{ .line = 8, .column = 2, .desc = "for...of over `names`" },
    } };

    const combined = Bound.addBorrowed(first, second);
    try std.testing.expectEqual(BoundClass.unbounded, combined.class());
    try std.testing.expectEqualStrings("for...of over `names`", combined.unbounded.desc);
}

test "Bound.maxBorrowed picks the wider class" {
    const constant = Bound{ .constant = 4 };
    const linear = Bound{ .linear = .{
        .coefficient = 1,
        .base = 0,
        .source = .{ .line = 4, .column = 2, .desc = "for...of over `ids`" },
    } };
    const unbounded = Bound{ .unbounded = .{ .line = 9, .column = 1, .desc = "unknown" } };

    try std.testing.expectEqual(BoundClass.linear, Bound.maxBorrowed(constant, linear).class());
    try std.testing.expectEqual(BoundClass.unbounded, Bound.maxBorrowed(linear, unbounded).class());
}

test "Bound.worstCaseAt evaluates linear at a body limit" {
    const bound = Bound{ .linear = .{
        .coefficient = 3,
        .base = 2,
        .source = .{ .line = 4, .column = 2, .desc = "for...of over `ids`" },
    } };

    try std.testing.expectEqual(@as(?u64, 20), bound.worstCaseAt(10));
    try std.testing.expectEqual(@as(?u64, null), (Bound{ .unbounded = .{} }).worstCaseAt(10));
}

pub const RateLimitInfo = struct {
    namespace: []const u8,
    dynamic: bool,
};

/// Why a handler property was demoted from its optimistic default. Captured
/// at the classifier site that decided to clear a boolean in
/// `HandlerProperties` so the live-reload HUD can name both the file:line
/// and the construct that caused the regression. Snippet is borrowed
/// (typically a static const string like "Date.now()"); the contract owns
/// no extra allocation.
pub const PropertyCause = struct {
    line: u32,
    column: u32,
    snippet: []const u8, // borrowed; static literal or arena-tied
};

/// Per-property source provenance. All fields default to null; populated
/// only at the clearing site for properties that were demoted from their
/// optimistic default. Lives alongside `HandlerProperties` on the contract;
/// not serialized into contract.json (purely a build-time artifact for the
/// proof HUD's regression line).
pub const PropertyProvenance = struct {
    deterministic: ?PropertyCause = null,
    /// The first failable call the path walk never recorded. The snippet is the
    /// export name, a static string from the module binding.
    fault_covered: ?PropertyCause = null,

    /// Single dispatch over the field set so the live HUD and the
    /// counterexample pipeline never drift on which provenance fields exist.
    /// Returns null for fields the verifier does not yet record causes for.
    pub fn causeFor(self: *const PropertyProvenance, field: []const u8) ?PropertyCause {
        if (std.mem.eql(u8, field, "deterministic")) return self.deterministic;
        if (std.mem.eql(u8, field, "fault_covered")) return self.fault_covered;
        return null;
    }
};

test "PropertyProvenance.causeFor round-trips deterministic" {
    const p = PropertyProvenance{
        .deterministic = .{ .line = 14, .column = 9, .snippet = "Date.now()" },
    };
    const got = p.causeFor("deterministic").?;
    try std.testing.expectEqual(@as(u32, 14), got.line);
    try std.testing.expectEqualStrings("Date.now()", got.snippet);
}

test "PropertyProvenance.causeFor returns null for unset and unknown" {
    const empty = PropertyProvenance{};
    try std.testing.expect(empty.causeFor("deterministic") == null);

    const p = PropertyProvenance{
        .deterministic = .{ .line = 1, .column = 1, .snippet = "x" },
    };
    try std.testing.expect(p.causeFor("read_only") == null);
    try std.testing.expect(p.causeFor("") == null);
}

/// One discharge result per declared spec. Produced by
/// `spec_discharge.dischargeSpecs` and stored on `HandlerContract`. Owned
/// strings are tagged on the field. Lives in contract_types.zig (not
/// spec_discharge.zig) to avoid an import cycle: spec_discharge needs
/// HandlerProperties from this file.
pub const SpecDiagnostic = struct {
    kind: Kind,
    /// Owned copy of the declared spec name.
    spec_name: []const u8,
    /// For .not_discharged with a known cause, the file:line:snippet captured
    /// at the classifier site that demoted the property. Borrowed; must not
    /// outlive the contract that owns the underlying snippet (which itself
    /// is typically a static string literal).
    cause: ?PropertyCause = null,
    /// For .incompatible_with_import: the offending module specifier
    /// (owned). null for the other kinds.
    incompatible_module: ?[]const u8 = null,
    /// For .not_discharged on a cause-only property: a per-property
    /// suggestion string the HUD renders as `Try: <suggestion>`. Owned when
    /// present.
    suggestion: ?[]const u8 = null,
    /// For capsule diagnostics (helper ZTS500 / ZTS502, and ZTS606): the
    /// name of the user-defined function the diagnostic is attributed to.
    /// Owned when present; null for handler-level Spec diagnostics, where
    /// the handler is implied.
    function: ?[]const u8 = null,
    /// True when this diagnostic comes from the IMPLICIT default spec set:
    /// the handler declared no `Proof<T, P>`, so the full v1 profile is active
    /// and every unsatisfiable property trips ZTS500/ZTS501. Lets downstream
    /// surfaces explain that no Spec was authored and recommend declaring a
    /// narrow one, instead of claiming the author "declared" a spec they
    /// never wrote. Transient: not serialized to contract.json; recomputed
    /// on each fresh check.
    implicit_default: bool = false,

    pub const Severity = enum { err, warn };

    pub const Kind = enum {
        /// ZTS500: the corresponding property is false (handler Spec) or the
        /// declared capsule property does not hold (helper Proof).
        not_discharged,
        /// ZTS501: the spec contradicts a virtual-module import the
        /// handler declared.
        incompatible_with_import,
        /// ZTS502: the spec / capsule property name is not in the v1 set.
        unknown_name,
        /// ZTS606: a handler-reachable helper breaks a property the
        /// handler's Spec demands and carries no `Proof<...>` capsule
        /// declaring it. The proof cannot compose across the call boundary.
        missing_capsule,
        /// ZTS503: a function reaches a capability outside its declared
        /// `Effects<...>` ceiling.
        effect_undeclared,
        /// ZTS504: an `Effects<...>` ceiling names an unknown capability.
        effect_unknown_capability,
        /// ZTS505 (warning): an `Effects<...>` ceiling names a capability the
        /// function never reaches.
        effect_over_declared,
        /// ZTS506: the handler reaches a capability directly that is outside
        /// its declared `Effects<...>` budget.
        budget_exceeded,
        /// ZTS607: a handler-reachable helper reaches a capability outside
        /// the handler's declared `Effects<...>` budget.
        helper_budget_exceeded,
        /// ZTS508 (warning): an exported helper carries no `Proof<...>`
        /// capsule. Emitted only under the opt-in docs mode.
        ///
        /// There is no effects counterpart. ZTS507 held that place until
        /// phase 5 dropped `handler_reachable` from ZTS610, at which point the
        /// two predicates - exported, undeclared, nonempty inferred row - were
        /// the same one, and the warning was a quieter duplicate of an error.
        /// This one survives because ZTS611 requires the handler to declare a
        /// proof-supported `Proof<T, P>` and this does not.
        missing_proof_capsule_export,
        /// ZTS511: an `Effects<...>` ceiling whose capability payload is not a
        /// closed union of string literals. The extractor recovers no names,
        /// which is indistinguishable from no annotation, so the ceiling check
        /// is skipped while the function keeps reaching capabilities. Reported
        /// instead of silently extracting zero names.
        effect_ceiling_not_literal,
        /// ZTS512: the function calls through a value the compiler cannot
        /// resolve (a function-typed parameter, a local holding a function, an
        /// unknown global), so its inferred effect row is a lower bound. A
        /// ceiling or budget check needs an over-approximation; discharging
        /// against a lower bound would certify a program nobody analysed.
        effect_row_lower_bound,
        /// ZTS514: a `validateJson`, `validateObject`, `coerceJson`, or
        /// `decodeJson` call names a schema `zttp:validate` cannot compile, so
        /// it fails on every input. `spec_name` is the schema name.
        schema_not_compilable,

        pub fn code(self: Kind) []const u8 {
            return switch (self) {
                .not_discharged => "ZTS500",
                .incompatible_with_import => "ZTS501",
                .unknown_name => "ZTS502",
                .missing_capsule => "ZTS606",
                .effect_undeclared => "ZTS503",
                .effect_unknown_capability => "ZTS504",
                .effect_over_declared => "ZTS505",
                .budget_exceeded => "ZTS506",
                .helper_budget_exceeded => "ZTS607",
                .missing_proof_capsule_export => "ZTS508",
                .effect_ceiling_not_literal => "ZTS511",
                .effect_row_lower_bound => "ZTS512",
                .schema_not_compilable => "ZTS514",
            };
        }

        /// Diagnostic severity. Over-declaration and the docs-mode
        /// missing-capsule prompts are advisory; everything else is an error.
        pub fn severity(self: Kind) Severity {
            return switch (self) {
                .effect_over_declared,
                .missing_proof_capsule_export,
                => .warn,
                else => .err,
            };
        }
    };

    pub fn deinit(self: *SpecDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.spec_name);
        if (self.incompatible_module) |m| allocator.free(m);
        if (self.suggestion) |s| allocator.free(s);
        if (self.function) |f| allocator.free(f);
        // cause snippet is borrowed; do not free.
    }

    /// Deep-copy. The caller owns the result and must `deinit` it. Used to
    /// lift capsule diagnostics out of a transient table and to carry them
    /// across a spec-diagnostic refresh.
    pub fn clone(self: SpecDiagnostic, allocator: std.mem.Allocator) !SpecDiagnostic {
        const spec_name = try allocator.dupe(u8, self.spec_name);
        errdefer allocator.free(spec_name);
        const incompatible_module = try dupeOptionalString(allocator, self.incompatible_module);
        errdefer if (incompatible_module) |m| allocator.free(m);
        const suggestion = try dupeOptionalString(allocator, self.suggestion);
        errdefer if (suggestion) |s| allocator.free(s);
        const function = try dupeOptionalString(allocator, self.function);
        return .{
            .kind = self.kind,
            .spec_name = spec_name,
            .cause = self.cause,
            .incompatible_module = incompatible_module,
            .suggestion = suggestion,
            .function = function,
            .implicit_default = self.implicit_default,
        };
    }
};

// -------------------------------------------------------------------------
// Behavioral contract types
// -------------------------------------------------------------------------

/// A condition that distinguishes one execution path from another.
/// Conditions are derived from branch points in the handler's IR tree.
pub const PathCondition = struct {
    kind: Kind,
    module: ?[]const u8 = null, // for io conditions (owned)
    func: ?[]const u8 = null, // for io conditions (owned)
    value: ?[]const u8 = null, // for req conditions (owned)

    pub const Kind = enum {
        io_ok,
        io_fail,
        req_method,
        req_url,
    };

    pub fn deinit(self: *PathCondition, allocator: std.mem.Allocator) void {
        if (self.module) |m| allocator.free(m);
        if (self.func) |f| allocator.free(f);
        if (self.value) |v| allocator.free(v);
    }

    pub fn dupeOwned(self: PathCondition, allocator: std.mem.Allocator) !PathCondition {
        const module = try dupeOptionalString(allocator, self.module);
        errdefer if (module) |m| allocator.free(m);
        const func = try dupeOptionalString(allocator, self.func);
        errdefer if (func) |f| allocator.free(f);
        const value = try dupeOptionalString(allocator, self.value);
        return .{ .kind = self.kind, .module = module, .func = func, .value = value };
    }
};

/// A single I/O call in a behavior path's sequence.
pub const PathIoCall = struct {
    module: []const u8, // owned
    func: []const u8, // owned
    /// Canonical argument signature used by the behavior-path canonicalizer.
    /// Pipe-delimited, one token per argument position:
    ///   "lit:<raw>"   - string literal that holds no `|`
    ///   "int:<raw>"   - integer literal
    ///   "bool:true"   - boolean literal
    ///   "bool:false"
    ///   "?"           - dynamic or unknown, and a string literal that holds `|`
    /// No token other than `?` holds `|`. Two `?` tokens are never equal:
    /// each may hold a different value, so the canonicalizer collapses no
    /// pair of calls whose signature has a `?`.
    /// `null` means the path generator did not record arguments for this
    /// call (older contracts, or a call site where we could not walk the
    /// arguments). A null signature disables all rewrites on this call.
    arg_signature: ?[]const u8 = null, // owned when non-null

    pub fn deinit(self: *PathIoCall, allocator: std.mem.Allocator) void {
        allocator.free(self.module);
        allocator.free(self.func);
        if (self.arg_signature) |sig| allocator.free(sig);
    }

    pub fn dupeOwned(self: PathIoCall, allocator: std.mem.Allocator) !PathIoCall {
        const module = try allocator.dupe(u8, self.module);
        errdefer allocator.free(module);
        const func = try allocator.dupe(u8, self.func);
        errdefer allocator.free(func);
        const arg_signature = try dupeOptionalString(allocator, self.arg_signature);
        return .{ .module = module, .func = func, .arg_signature = arg_signature };
    }
};

/// The HTTP status of one behavior path: a value the analysis read, or one it
/// could not read. A verdict never compares two `ResponseStatus` values with
/// `==`, `!=`, or `std.meta.eql`: `contract_diff.zig` decides equality in one
/// place, and `unknown` equals no known status.
pub const ResponseStatus = union(enum) {
    known: u16,
    unknown,

    /// The status when it is known. Unknown reads as absent.
    pub fn knownValue(self: ResponseStatus) ?u16 {
        return switch (self) {
            .known => |value| value,
            .unknown => null,
        };
    }

    /// Whether the status is known and equals `value`. For display and for
    /// tests of one literal; it is not a verdict comparison between two paths.
    pub fn isKnown(self: ResponseStatus, value: u16) bool {
        return switch (self) {
            .known => |known| known == value,
            .unknown => false,
        };
    }
};

/// One exhaustively-enumerated execution path through the handler.
/// Each path is a unique combination of (route, I/O outcomes, response).
pub const BehaviorPath = struct {
    route_method: []const u8, // owned
    route_pattern: []const u8, // owned
    conditions: std.ArrayList(PathCondition),
    io_sequence: std.ArrayList(PathIoCall),
    response_status: ResponseStatus,
    io_depth: u32,
    is_failure_path: bool,

    pub fn deinit(self: *BehaviorPath, allocator: std.mem.Allocator) void {
        allocator.free(self.route_method);
        allocator.free(self.route_pattern);
        for (self.conditions.items) |*c| {
            @constCast(c).deinit(allocator);
        }
        self.conditions.deinit(allocator);
        for (self.io_sequence.items) |*io| {
            @constCast(io).deinit(allocator);
        }
        self.io_sequence.deinit(allocator);
    }

    pub fn dupeOwned(self: *const BehaviorPath, allocator: std.mem.Allocator) !BehaviorPath {
        var conditions: std.ArrayList(PathCondition) = .empty;
        errdefer {
            for (conditions.items) |*c| @constCast(c).deinit(allocator);
            conditions.deinit(allocator);
        }
        try conditions.ensureTotalCapacity(allocator, self.conditions.items.len);
        for (self.conditions.items) |c| {
            conditions.appendAssumeCapacity(try c.dupeOwned(allocator));
        }

        var io_sequence: std.ArrayList(PathIoCall) = .empty;
        errdefer {
            for (io_sequence.items) |*io| @constCast(io).deinit(allocator);
            io_sequence.deinit(allocator);
        }
        try io_sequence.ensureTotalCapacity(allocator, self.io_sequence.items.len);
        for (self.io_sequence.items) |io| {
            io_sequence.appendAssumeCapacity(try io.dupeOwned(allocator));
        }

        const route_method = try allocator.dupe(u8, self.route_method);
        errdefer allocator.free(route_method);
        const route_pattern = try allocator.dupe(u8, self.route_pattern);
        return .{
            .route_method = route_method,
            .route_pattern = route_pattern,
            .conditions = conditions,
            .io_sequence = io_sequence,
            .response_status = self.response_status,
            .io_depth = self.io_depth,
            .is_failure_path = self.is_failure_path,
        };
    }
};

// --- Cost contract types ---

/// Widening order for cost bounds. Used by contract_diff's cost lane:
/// constant -> linear -> unbounded only ever widens.
pub const BoundClass = enum(u2) {
    constant = 0,
    linear = 1,
    unbounded = 2,

    pub fn widerThan(self: BoundClass, other: BoundClass) bool {
        return @backingInt(self) > @backingInt(other);
    }

    pub fn asString(self: BoundClass) []const u8 {
        return switch (self) {
            .constant => "constant",
            .linear => "linear",
            .unbounded => "unbounded",
        };
    }
};

/// Names the source construct a non-constant bound depends on. CostEnvelope
/// owns provenance desc strings; every other Bound value borrows them.
pub const BoundProvenance = struct {
    line: u32 = 0,
    column: u32 = 0,
    desc: []const u8 = "",
};

/// A symbolic worst-path call-count bound.
pub const Bound = union(enum) {
    /// Exactly this many calls on the worst path.
    constant: u32,
    /// `base + coefficient * |source|` calls for one undischarged collection.
    linear: Linear,
    /// No expressible bound.
    unbounded: BoundProvenance,

    pub const Linear = struct {
        coefficient: u32,
        base: u32 = 0,
        source: BoundProvenance,
    };

    pub fn class(self: Bound) BoundClass {
        return switch (self) {
            .constant => .constant,
            .linear => .linear,
            .unbounded => .unbounded,
        };
    }

    /// Sequential composition along one path. Non-allocating; the result
    /// borrows provenance from the inputs. Saturating u32 arithmetic.
    pub fn addBorrowed(a: Bound, b: Bound) Bound {
        return switch (a) {
            .constant => |av| switch (b) {
                .constant => |bv| .{ .constant = saturatingAddU32(av, bv) },
                .linear => |bl| .{ .linear = .{
                    .coefficient = bl.coefficient,
                    .base = saturatingAddU32(bl.base, av),
                    .source = bl.source,
                } },
                .unbounded => |bp| .{ .unbounded = bp },
            },
            .linear => |al| switch (b) {
                .constant => |bv| .{ .linear = .{
                    .coefficient = al.coefficient,
                    .base = saturatingAddU32(al.base, bv),
                    .source = al.source,
                } },
                .linear => |bl| if (sameProvenance(al.source, bl.source)) .{ .linear = .{
                    .coefficient = saturatingAddU32(al.coefficient, bl.coefficient),
                    .base = saturatingAddU32(al.base, bl.base),
                    .source = al.source,
                } } else .{ .unbounded = bl.source },
                .unbounded => |bp| .{ .unbounded = bp },
            },
            .unbounded => |ap| .{ .unbounded = ap },
        };
    }

    /// Worst-of across alternative paths (or handlers). Non-allocating,
    /// borrows provenance. Wider class wins.
    pub fn maxBorrowed(a: Bound, b: Bound) Bound {
        const ac = a.class();
        const bc = b.class();
        if (ac.widerThan(bc)) return a;
        if (bc.widerThan(ac)) return b;

        return switch (a) {
            .constant => |av| .{ .constant = @max(av, b.constant) },
            .linear => |al| blk: {
                const bl = b.linear;
                if (bl.coefficient > al.coefficient) break :blk b;
                if (bl.coefficient == al.coefficient and bl.base > al.base) break :blk b;
                break :blk a;
            },
            .unbounded => a,
        };
    }

    /// Deep copy that owns its desc strings.
    pub fn dupeOwned(self: Bound, allocator: std.mem.Allocator) !Bound {
        return switch (self) {
            .constant => |v| .{ .constant = v },
            .linear => |l| .{ .linear = .{
                .coefficient = l.coefficient,
                .base = l.base,
                .source = try dupeProvenance(allocator, l.source),
            } },
            .unbounded => |p| .{ .unbounded = try dupeProvenance(allocator, p) },
        };
    }

    /// Free desc strings. Call ONLY on owned bounds.
    pub fn deinitOwned(self: *Bound, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .constant => {},
            .linear => |l| allocator.free(l.source.desc),
            .unbounded => |p| allocator.free(p.desc),
        }
    }

    /// Concrete worst case at a request-body byte limit.
    pub fn worstCaseAt(self: Bound, body_limit_bytes: u64) ?u64 {
        return switch (self) {
            .constant => |v| v,
            .linear => |l| blk: {
                const source_ceiling = body_limit_bytes / 2 + 1;
                const product = std.math.mul(u64, l.coefficient, source_ceiling) catch std.math.maxInt(u64);
                break :blk std.math.add(u64, l.base, product) catch std.math.maxInt(u64);
            },
            .unbounded => null,
        };
    }
};

fn saturatingAddU32(a: u32, b: u32) u32 {
    const sum, const overflow = @addWithOverflow(a, b);
    return if (overflow != 0) std.math.maxInt(u32) else sum;
}

fn sameProvenance(a: BoundProvenance, b: BoundProvenance) bool {
    return a.line == b.line and
        a.column == b.column and
        std.mem.eql(u8, a.desc, b.desc);
}

fn dupeProvenance(allocator: std.mem.Allocator, p: BoundProvenance) !BoundProvenance {
    return .{
        .line = p.line,
        .column = p.column,
        .desc = try allocator.dupe(u8, p.desc),
    };
}

/// One module's worst-path bound.
pub const CostEntry = struct {
    module: []const u8, // owned
    bound: Bound, // owned
};

/// Per-handler cost envelope: worst-path call bounds per virtual module,
/// plus the combined total.
pub const CostEnvelope = struct {
    entries: std.ArrayList(CostEntry) = .empty,
    total: Bound = .{ .constant = 0 },

    pub fn find(self: *const CostEnvelope, module: []const u8) ?*const Bound {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.module, module)) return &entry.bound;
        }
        return null;
    }

    pub fn deinit(self: *CostEnvelope, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            allocator.free(entry.module);
            entry.bound.deinitOwned(allocator);
        }
        self.entries.deinit(allocator);
        self.total.deinitOwned(allocator);
    }

    pub fn dupeOwned(self: *const CostEnvelope, allocator: std.mem.Allocator) !CostEnvelope {
        var copy = CostEnvelope{
            .entries = .empty,
            .total = try self.total.dupeOwned(allocator),
        };
        errdefer copy.deinit(allocator);

        try copy.entries.ensureTotalCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |entry| {
            const module = try allocator.dupe(u8, entry.module);
            errdefer allocator.free(module);
            const bound = try entry.bound.dupeOwned(allocator);
            copy.entries.appendAssumeCapacity(.{
                .module = module,
                .bound = bound,
            });
        }
        return copy;
    }
};

pub const CapabilityMatrix = struct {
    items: [module_binding.capability_count]module_binding.ModuleCapability = undefined,
    len: u8 = 0,
    hash: [32]u8 = @as([32]u8, @splat(0)),

    pub const empty: CapabilityMatrix = .{};

    pub fn slice(self: *const CapabilityMatrix) []const module_binding.ModuleCapability {
        return self.items[0..self.len];
    }

    pub fn has(self: *const CapabilityMatrix, cap: module_binding.ModuleCapability) bool {
        for (self.slice()) |c| {
            if (c == cap) return true;
        }
        return false;
    }
};

// `computeCapabilityMatrix` lives in `builtin_modules.zig`: it resolves each
// specifier through the linked module registry, and that registry is the
// engine's, not the contract's. Keeping the function here made every holder
// of a contract import the whole registry. The matrix type above needs only
// the capability vocabulary and stays.

/// Author-declared intent assertions. Extracted from a static-literal
/// `export const intent = { assertions: [...] }` in the handler module.
/// Lives **outside** the proof boundary: assertions are runnable examples,
/// not new compiler obligations. They are extracted into the contract
/// (`HandlerContract.intent.assertions`) at build time; executing each entry
/// through the handler test path is deferred.
///
/// Dynamic forms (function, spread, computed) must fail extraction rather
/// than degrading to "unknown", to preserve the deterministic-extraction
/// guardrail.
pub const IntentExpectedHeader = struct {
    name: []const u8, // owned
    value: []const u8, // owned

    pub fn deinit(self: *IntentExpectedHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const IntentAssertion = struct {
    /// Author-supplied label, used in the runner's pass/fail report.
    name: []const u8, // owned
    /// HTTP method, e.g. "GET". Uppercased at extraction.
    method: []const u8, // owned
    /// Request path including any query string.
    path: []const u8, // owned
    /// Optional raw JSON body (as written in the literal). Owned; the
    /// runner parses this when constructing the synthetic request.
    request_body_json: ?[]const u8 = null,
    /// Optional expected response status; null means no status assertion.
    expected_status: ?u16 = null,
    /// Optional raw JSON body fragment expected in the response. Subset
    /// matching at runtime (every key in expected_body_json must appear
    /// with the same value in the actual response).
    expected_body_json: ?[]const u8 = null,
    /// Optional headers expected on the response, each compared
    /// case-insensitively by name.
    expected_headers: std.ArrayList(IntentExpectedHeader) = .empty,
    /// One-based source span pointing at the assertion literal, used by
    /// the runner's failure messages and by the contract diff viewer.
    source_line: u32 = 0,
    source_column: u32 = 0,

    pub fn deinit(self: *IntentAssertion, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.method);
        allocator.free(self.path);
        if (self.request_body_json) |b| allocator.free(b);
        if (self.expected_body_json) |b| allocator.free(b);
        for (self.expected_headers.items) |*h| h.deinit(allocator);
        self.expected_headers.deinit(allocator);
    }
};

pub const IntentInfo = struct {
    assertions: std.ArrayList(IntentAssertion) = .empty,
    /// True when the author declared `intent` but the value was dynamic.
    /// Set by the extractor; surfaces as `intent.dynamic = true` in the
    /// contract and a per-section verdict on the contract diff (Stream B).
    dynamic: bool = false,

    pub fn deinit(self: *IntentInfo, allocator: std.mem.Allocator) void {
        for (self.assertions.items) |*a| a.deinit(allocator);
        self.assertions.deinit(allocator);
    }
};

/// One function summary for a declared proof capsule.
pub const CapsuleSummary = struct {
    /// Owned copy of the function name.
    function: []const u8,
    /// 1-based source line of the function declaration.
    line: u32,
    /// Owned, de-duplicated capsule property names declared via `Proof<...>`.
    declared: std.ArrayList([]const u8) = .empty,
    proven_total: bool = false,
    proven_pure: bool = false,
    proven_read_only: bool = false,
    proven_deterministic: bool = false,
    /// True when the function declared a capsule and every property held.
    discharged: bool = false,
    /// True when the helper is exported. Used by the opt-in docs mode.
    exported: bool = false,
    /// True when the handler can reach this helper through the analyzed call
    /// graph. Used by canonical diagnostics so unrelated exported helpers do
    /// not break a handler proof.
    handler_reachable: bool = false,

    pub fn deinit(self: *CapsuleSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.function);
        for (self.declared.items) |s| allocator.free(s);
        self.declared.deinit(allocator);
    }
};

/// One helper function's effect capsule, projected for the `effectCapsules`
/// JSON envelope. Transient: populated during build, consumed by
/// `zts check --json`, never serialized into contract.json.
pub const EffectCapsuleSummary = struct {
    /// Owned copy of the function name.
    function: []const u8,
    /// 1-based source line of the function declaration.
    line: u32,
    /// Owned capability names declared via `Effects<...>`.
    declared: std.ArrayList([]const u8) = .empty,
    /// Owned capability names effect inference computed for the function.
    inferred: std.ArrayList([]const u8) = .empty,
    /// True when the function declared a ceiling and every reached
    /// capability fell inside it.
    discharged: bool = false,
    /// True when the helper is exported. Used by the opt-in docs mode.
    exported: bool = false,
    /// True when the handler can reach this helper through the analyzed call
    /// graph.
    handler_reachable: bool = false,

    pub fn deinit(self: *EffectCapsuleSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.function);
        for (self.declared.items) |s| allocator.free(s);
        self.declared.deinit(allocator);
        for (self.inferred.items) |s| allocator.free(s);
        self.inferred.deinit(allocator);
    }
};

/// One `hole()` call site, projected for the `holes` JSON envelope.
///
/// A hole is the compiler describing a frame with one expression missing. The
/// agent's job at that point is to write that expression, not to regenerate the
/// file, so what it needs is the shape of the gap: where it is, what type goes
/// there, and what authority is still available to spend filling it.
/// One binding visible at a hole. Both fields owned.
pub const ScopeBinding = struct {
    name: []const u8,
    /// Rendered type, or "unknown" when no annotation reaches this binding.
    type_name: []const u8,

    pub fn deinit(self: *ScopeBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type_name);
    }
};

pub const HoleSummary = struct {
    /// Owned name of the function the hole sits in, or "<top-level>".
    function: []const u8,
    /// 1-based source line and column of the `hole()` call.
    line: u32,
    column: u32,
    /// Owned rendering of the type the expression must produce. The enclosing
    /// function's declared return type when the hole is in return position;
    /// "unknown" when the context does not pin one down.
    expected_type: []const u8,
    /// Owned capability names the handler's declared budget still allows and
    /// its inferred row has not already spent. Empty when no budget is
    /// declared, which is not the same as "no capabilities available" - read it
    /// beside `budget_declared`.
    remaining_budget: std.ArrayList([]const u8) = .empty,
    /// False when the handler declares no `Effects<...>` budget, in which case
    /// `remaining_budget` is empty because there is nothing to subtract from.
    budget_declared: bool = false,
    /// Owned names of the properties still undischarged in the function this
    /// hole sits in - what filling it has to satisfy, or at least not break.
    /// Attributed by function: a hole in a helper carries that helper's
    /// capsule failures, and a hole in the handler carries the handler's.
    undischarged: std.ArrayList([]const u8) = .empty,
    /// Bindings visible where the hole sits, innermost scope first, each with
    /// its rendered type or "unknown". The material an expression filling the
    /// hole can be built from.
    in_scope: std.ArrayList(ScopeBinding) = .empty,

    pub fn deinit(self: *HoleSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.function);
        allocator.free(self.expected_type);
        for (self.undischarged.items) |s| allocator.free(s);
        self.undischarged.deinit(allocator);
        for (self.in_scope.items) |*b| b.deinit(allocator);
        self.in_scope.deinit(allocator);
        for (self.remaining_budget.items) |s| allocator.free(s);
        self.remaining_budget.deinit(allocator);
    }
};

pub const HandlerContract = struct {
    version: u32 = 25,
    handler: HandlerLoc,
    routes: std.ArrayList(RouteInfo),
    modules: std.ArrayList([]const u8), // each entry owned
    functions: std.ArrayList(FunctionEntry),
    env: EnvInfo,
    egress: EgressInfo,
    cache: CacheInfo,
    sql: SqlInfo,
    api: ApiInfo,
    verification: ?VerificationInfo,
    aot: ?AotInfo,
    fault_coverage: ?FaultCoverageInfo = null,
    rate_limiting: ?RateLimitInfo = null,
    /// Set only when a decoded rate-limit namespace does not also appear in
    /// `cache.namespaces`. Transient and not serialized independently.
    owned_rate_limit_namespace: ?[]const u8 = null,
    /// Backs `property_provenance.fault_covered.snippet` when that cause names an
    /// imported file, which is built at check time and so is not a static string.
    /// Transient and not serialized.
    owned_fault_cause_snippet: ?[]const u8 = null,
    properties: ?HandlerProperties = null,
    /// True when effect inference resolved every callable that contributed to
    /// `properties`. Transient analysis state; contract JSON does not emit it.
    effect_analysis_complete: bool = true,
    /// Author-declared intent assertions. Null when the handler module
    /// has no `export const intent` literal. See `IntentInfo` for shape.
    intent: ?IntentInfo = null,
    /// In-memory provenance for demoted properties. Not serialized; populated
    /// during build for the live-reload HUD's "Why" line. Snippets are
    /// borrowed static strings, so deinit is a no-op.
    property_provenance: PropertyProvenance = .{},
    /// Active handler specs. An explicit `Proof<Response, "name" | ...>` on
    /// the handler return type narrows this set; without one, every supported
    /// v1 spec is active by default. Each entry is an owned spec name string.
    /// The verifier emits ZTS500 for any member whose corresponding
    /// `HandlerProperties` field is false.
    declared_specs: std.ArrayList([]const u8) = .empty,
    /// True when `declared_specs` is the IMPLICIT default profile (the
    /// handler return type carried no `Proof<T, P>`), rather than an
    /// author-declared set. Drives the actionable "declare a narrow Spec"
    /// diagnostic. Transient: not serialized; recomputed each build.
    declared_specs_implicit: bool = false,
    /// Per-specifier proof facts produced by partner virtual-module manifest
    /// `contractExtractions`. Keys are owned specifier strings (e.g.
    /// `"zttp-ext:stripe"`); values own all nested data. Emitted under
    /// `extensions` in contract.json.
    extensions: std.StringHashMapUnmanaged(ExtensionContract) = .empty,
    /// Per-spec discharge diagnostics produced by `spec_discharge.dischargeSpecs`.
    /// Empty when every declared spec is satisfied. Owned by the contract;
    /// each entry's deinit must run before the contract is freed.
    spec_diagnostics: std.ArrayList(SpecDiagnostic) = .empty,
    /// Per-helper proof capsules (`Proof<...>` discharge results). Transient
    /// analysis output: populated during build, rendered as `proofCapsules`
    /// in the `--json` analysis envelope. NOT serialized into contract.json
    /// and NOT part of the signed attestation surface - the json writer
    /// skips it. Owned by the contract.
    function_capsules: std.ArrayList(CapsuleSummary) = .empty,
    /// Per-helper effect capsules (`Effects<...>` discharge results).
    /// Transient analysis output: populated during build, rendered as
    /// `effectCapsules` in the `--json` analysis envelope. NOT serialized
    /// into contract.json. Owned by the contract.
    function_effect_capsules: std.ArrayList(EffectCapsuleSummary) = .empty,
    /// Every `hole()` call site in the handler. Empty for a finished program.
    holes: std.ArrayList(HoleSummary) = .empty,
    behaviors: std.ArrayList(BehaviorPath) = .empty,
    behaviors_exhaustive: bool = false,
    /// Per-module worst-path cost bounds derived from path enumeration.
    /// Null when no handler function was found (mirrors properties == null).
    cost_envelope: ?CostEnvelope = null,
    /// Null when the contract carries no `sandbox` block at all, which an
    /// older contract.json can do. That is a different statement from an
    /// empty matrix, which says the handler needs no capabilities. The
    /// runtime relies on the distinction: `verifyCapabilityMatrix` skips on
    /// null and compares hashes otherwise, so collapsing the two would make
    /// a pre-sandbox binary refuse to serve.
    capabilities: ?CapabilityMatrix = null,
    /// The capability budget the handler declared via `Effects<...>` on its
    /// return type. Empty when the handler declares no budget. Serialized
    /// into contract.json under `sandbox.declaredBudget`.
    capability_budget: CapabilityMatrix = .empty,
    /// Core parser and opcode identity used for this artifact.
    /// A compiler-produced contract always carries non-zero hashes.
    source_identity: SourceIdentity = .{},
    /// SHA-256 of the compiled handler bytecode. Stamped by the build
    /// pipeline after compile and verified at runtime startup.
    artifact_sha256: [32]u8 = @as([32]u8, @splat(0)),
    /// SHA-256 of the zts rule registry used to extract this contract.
    /// Populated in `build()`; verified at runtime against the registry the
    /// running binary was linked with.
    policy_hash: [32]u8 = @as([32]u8, @splat(0)),
    /// SHA-256 of the embedded Wasm policy artifact (Phase 2). All-zeros
    /// means no Wasm policy is present; the runtime falls back to the
    /// in-process LocalPolicyChecker. Non-zero values are verified at startup
    /// against the artifact on disk before the WasmPool is populated.
    wasm_policy_hash: [32]u8 = @as([32]u8, @splat(0)),

    pub const FunctionEntry = struct {
        module: []const u8, // owned
        names: std.ArrayList([]const u8), // each entry owned
    };

    pub fn deinit(self: *HandlerContract, allocator: std.mem.Allocator) void {
        allocator.free(self.handler.path);
        for (self.routes.items) |route| {
            allocator.free(route.pattern);
        }
        self.routes.deinit(allocator);
        for (self.modules.items) |m| {
            allocator.free(m);
        }
        self.modules.deinit(allocator);
        for (self.functions.items) |*entry| {
            allocator.free(entry.module);
            for (entry.names.items) |n| {
                allocator.free(n);
            }
            entry.names.deinit(allocator);
        }
        self.functions.deinit(allocator);
        for (self.env.literal.items) |s| {
            allocator.free(s);
        }
        self.env.literal.deinit(allocator);
        for (self.env.public.items) |s| {
            allocator.free(s);
        }
        self.env.public.deinit(allocator);
        for (self.egress.endpoints.items) |s| {
            allocator.free(s);
        }
        self.egress.endpoints.deinit(allocator);
        for (self.egress.urls.items) |s| {
            allocator.free(s);
        }
        self.egress.urls.deinit(allocator);
        for (self.cache.namespaces.items) |s| {
            allocator.free(s);
        }
        self.cache.namespaces.deinit(allocator);
        if (self.owned_rate_limit_namespace) |namespace| allocator.free(namespace);
        if (self.owned_fault_cause_snippet) |snippet| allocator.free(snippet);
        self.sql.deinit(allocator);
        self.api.deinit(allocator);
        for (self.behaviors.items) |*b| {
            @constCast(b).deinit(allocator);
        }
        self.behaviors.deinit(allocator);
        if (self.cost_envelope) |*envelope| envelope.deinit(allocator);
        for (self.declared_specs.items) |s| {
            allocator.free(s);
        }
        self.declared_specs.deinit(allocator);
        for (self.spec_diagnostics.items) |*d| {
            @constCast(d).deinit(allocator);
        }
        self.spec_diagnostics.deinit(allocator);
        for (self.function_capsules.items) |*c| {
            @constCast(c).deinit(allocator);
        }
        self.function_capsules.deinit(allocator);
        for (self.function_effect_capsules.items) |*c| {
            @constCast(c).deinit(allocator);
        }
        self.function_effect_capsules.deinit(allocator);
        for (self.holes.items) |*h| {
            @constCast(h).deinit(allocator);
        }
        self.holes.deinit(allocator);
        var ext_it = self.extensions.iterator();
        while (ext_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.extensions.deinit(allocator);
        if (self.intent) |*i| i.deinit(allocator);
    }
};

fn deepCopyAndFree(allocator: std.mem.Allocator) !void {
    const param = ApiParamInfo{ .name = "id", .schema_json = "{\"type\":\"string\"}" };
    var param_copy = try param.dupeOwned(allocator);
    param_copy.deinit(allocator);

    const body = ApiBodyInfo{ .content_type = "application/json", .schema = .{ .ref = "Item" } };
    var body_copy = try body.dupeOwned(allocator);
    body_copy.deinit(allocator);

    const response = ApiResponseInfo{ .status = 200, .content_type = "text/plain", .schema = .{ .inline_json = "{}" } };
    var response_copy = try response.dupeOwned(allocator);
    response_copy.deinit(allocator);

    const condition = PathCondition{ .kind = .io_ok, .module = "zttp:cache", .func = "cacheGet", .value = "v" };
    var condition_copy = try condition.dupeOwned(allocator);
    condition_copy.deinit(allocator);

    const io_call = PathIoCall{ .module = "zttp:cache", .func = "cacheGet", .arg_signature = "lit:k" };
    var io_copy = try io_call.dupeOwned(allocator);
    io_copy.deinit(allocator);

    const path = BehaviorPath{
        .route_method = "GET",
        .route_pattern = "/items",
        .conditions = .empty,
        .io_sequence = .empty,
        .response_status = .{ .known = 200 },
        .io_depth = 0,
        .is_failure_path = false,
    };
    var path_copy = try path.dupeOwned(allocator);
    path_copy.deinit(allocator);
}

test "dupeOwned copies release every allocation on each failing allocation path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, deepCopyAndFree, .{});
}
