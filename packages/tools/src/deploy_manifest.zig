//! Proven Deployment Facts
//!
//! Extracts platform-agnostic proven deployment facts from compiler-proven
//! handler contracts. The contract captures exactly what a handler does (env
//! vars, egress hosts, cache namespaces, routes) as proven facts - not
//! heuristic guesses.
//!
//! `proof-review`, `live_reload`, and `build_command` consume
//! `extractProvenFacts`, the fact types, and `default_cost_body_limit`.

const std = @import("std");
const zts = @import("zts");
const handler_contract = zts.handler_contract;
const HandlerContract = zts.HandlerContract;

// -------------------------------------------------------------------------
// Platform-agnostic proven facts
// -------------------------------------------------------------------------

pub const ProofLevel = zts.ContractProof.Level;
pub const default_cost_body_limit: u64 = 1024 * 1024;

pub const ProvenRoute = struct {
    pattern: []const u8,
    is_prefix: bool,
};

pub const ProvenFacts = struct {
    handler_name: []const u8,
    handler_path: []const u8,

    env_vars: []const []const u8,
    env_proven: bool,

    egress_endpoints: []const []const u8,
    egress_proven: bool,

    cache_namespaces: []const []const u8,
    cache_proven: bool,

    routes: []const ProvenRoute,

    proof_level: ProofLevel,
    checks_passed: []const []const u8,

    retry_safe: bool = false,
    read_only: bool = false,
    injection_safe: bool = false,
    idempotent: bool = false,
    state_isolated: bool = false,
    /// True when the handler has no `Date.now()` or `Math.random()` call
    /// sites. Surfaced in the live HUD so authors see `+deterministic`
    /// flip when they introduce a non-deterministic builtin.
    deterministic: bool = false,
    max_io_depth: ?u32 = null,

    // Data flow provenance
    no_secret_leakage: bool = false,
    no_credential_leakage: bool = false,
    input_validated: bool = false,
    pii_contained: bool = false,

    // Verification
    results_safe: bool = false,

    // Fault coverage
    fault_covered: bool = false,
};

// -------------------------------------------------------------------------
// Fact extraction
// -------------------------------------------------------------------------

/// Derive platform-agnostic ProvenFacts from a HandlerContract.
/// All slices in the returned struct point into the contract's owned data
/// or into the checks_buf. The caller must keep the contract alive while
/// using the facts. checks_buf is allocated and must be freed by the caller.
pub fn extractProvenFacts(
    allocator: std.mem.Allocator,
    contract: *const HandlerContract,
) !struct { facts: ProvenFacts, checks_buf: [][]const u8, routes_buf: []ProvenRoute } {
    // Handler name: strip directory and extension from path
    const handler_name = extractHandlerName(contract.handler.path);

    // Collect checks that passed
    var checks: std.ArrayList([]const u8) = .empty;
    errdefer checks.deinit(allocator);

    if (contract.verification) |v| {
        if (v.exhaustive_returns) try checks.append(allocator, "exhaustiveReturns");
        if (v.results_safe) try checks.append(allocator, "resultsSafe");
        if (v.bytecode_verified) try checks.append(allocator, "bytecodeVerified");
    }

    // Build routes from contract
    var routes: std.ArrayList(ProvenRoute) = .empty;
    errdefer routes.deinit(allocator);

    for (contract.routes.items) |route| {
        try routes.append(allocator, .{
            .pattern = route.pattern,
            .is_prefix = std.mem.eql(u8, route.route_type, "prefix"),
        });
    }

    const checks_buf = try checks.toOwnedSlice(allocator);
    errdefer allocator.free(checks_buf);
    const routes_buf = try routes.toOwnedSlice(allocator);

    const proof_level = deriveProofLevel(contract);

    return .{
        .facts = .{
            .handler_name = handler_name,
            .handler_path = contract.handler.path,
            .env_vars = contract.env.literal.items,
            .env_proven = !contract.env.dynamic,
            .egress_endpoints = contract.egress.endpoints.items,
            .egress_proven = !contract.egress.dynamic,
            .cache_namespaces = contract.cache.namespaces.items,
            .cache_proven = !contract.cache.dynamic,
            .routes = routes_buf,
            .proof_level = proof_level,
            .checks_passed = checks_buf,
            .retry_safe = if (contract.properties) |p| p.retry_safe else false,
            .read_only = if (contract.properties) |p| p.read_only else false,
            .injection_safe = if (contract.properties) |p| p.injection_safe else false,
            .idempotent = if (contract.properties) |p| p.idempotent else false,
            .state_isolated = if (contract.properties) |p| p.state_isolated else false,
            .deterministic = if (contract.properties) |p| p.deterministic else false,
            .max_io_depth = if (contract.properties) |p| p.max_io_depth else null,
            .no_secret_leakage = if (contract.properties) |p| p.no_secret_leakage else false,
            .no_credential_leakage = if (contract.properties) |p| p.no_credential_leakage else false,
            .input_validated = if (contract.properties) |p| p.input_validated else false,
            .pii_contained = if (contract.properties) |p| p.pii_contained else false,
            .results_safe = if (contract.verification) |v| v.results_safe else false,
            .fault_covered = if (contract.properties) |p| p.fault_covered else false,
        },
        .checks_buf = checks_buf,
        .routes_buf = routes_buf,
    };
}

fn extractHandlerName(path: []const u8) []const u8 {
    // Find last '/' for filename start
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/') start = i + 1;
    }
    const filename = path[start..];

    // Strip extension
    var end = filename.len;
    for (filename, 0..) |c, i| {
        if (c == '.') end = i;
    }
    if (end == 0) return filename;
    return filename[0..end];
}

pub const deriveProofLevel = zts.ContractProof.level;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn makeTestContract(allocator: std.mem.Allocator) !HandlerContract {
    const path = try allocator.dupe(u8, "handler.ts");
    return handler_contract.emptyContract(path);
}

test "extractHandlerName basic" {
    try std.testing.expectEqualStrings("handler", extractHandlerName("handler.ts"));
    try std.testing.expectEqualStrings("my-handler", extractHandlerName("my-handler.ts"));
}

test "deriveProofLevel none when no verification" {
    const allocator = std.testing.allocator;
    var contract = try makeTestContract(allocator);
    defer contract.deinit(allocator);

    try std.testing.expectEqual(ProofLevel.none, deriveProofLevel(&contract));
}

test "deriveProofLevel complete when all checks pass and no dynamic" {
    const allocator = std.testing.allocator;
    var contract = try makeTestContract(allocator);
    defer contract.deinit(allocator);

    contract.verification = .{
        .exhaustive_returns = true,
        .results_safe = true,
        .unreachable_code = false,
        .bytecode_verified = true,
    };

    try std.testing.expectEqual(ProofLevel.complete, deriveProofLevel(&contract));
}

test "deriveProofLevel partial when dynamic env" {
    const allocator = std.testing.allocator;
    var contract = try makeTestContract(allocator);
    defer contract.deinit(allocator);

    contract.verification = .{
        .exhaustive_returns = true,
        .results_safe = true,
        .unreachable_code = false,
        .bytecode_verified = true,
    };
    contract.env.dynamic = true;

    try std.testing.expectEqual(ProofLevel.partial, deriveProofLevel(&contract));
}

test "deriveProofLevel partial when check fails" {
    const allocator = std.testing.allocator;
    var contract = try makeTestContract(allocator);
    defer contract.deinit(allocator);

    contract.verification = .{
        .exhaustive_returns = true,
        .results_safe = false,
        .unreachable_code = false,
        .bytecode_verified = true,
    };

    try std.testing.expectEqual(ProofLevel.partial, deriveProofLevel(&contract));
}

test "extractProvenFacts minimal contract" {
    const allocator = std.testing.allocator;
    var contract = try makeTestContract(allocator);
    defer contract.deinit(allocator);

    const result = try extractProvenFacts(allocator, &contract);
    defer allocator.free(result.checks_buf);
    defer allocator.free(result.routes_buf);

    const facts = result.facts;
    try std.testing.expectEqualStrings("handler", facts.handler_name);
    try std.testing.expectEqualStrings("handler.ts", facts.handler_path);
    try std.testing.expectEqual(@as(usize, 0), facts.env_vars.len);
    try std.testing.expect(facts.env_proven);
    try std.testing.expectEqual(@as(usize, 0), facts.routes.len);
    try std.testing.expectEqual(ProofLevel.none, facts.proof_level);
}

test "extractProvenFacts with env and egress" {
    const allocator = std.testing.allocator;
    var contract = try makeTestContract(allocator);
    defer contract.deinit(allocator);

    const env1 = try allocator.dupe(u8, "JWT_SECRET");
    try contract.env.literal.append(allocator, env1);
    const env2 = try allocator.dupe(u8, "API_KEY");
    try contract.env.literal.append(allocator, env2);

    const host1 = try allocator.dupe(u8, "api.stripe.com");
    try contract.egress.endpoints.append(allocator, host1);
    contract.egress.dynamic = true;

    contract.verification = .{
        .exhaustive_returns = true,
        .results_safe = true,
        .unreachable_code = false,
        .bytecode_verified = true,
    };

    const result = try extractProvenFacts(allocator, &contract);
    defer allocator.free(result.checks_buf);
    defer allocator.free(result.routes_buf);

    const facts = result.facts;
    try std.testing.expectEqual(@as(usize, 2), facts.env_vars.len);
    try std.testing.expectEqualStrings("JWT_SECRET", facts.env_vars[0]);
    try std.testing.expectEqualStrings("API_KEY", facts.env_vars[1]);
    try std.testing.expect(facts.env_proven);
    try std.testing.expectEqual(@as(usize, 1), facts.egress_endpoints.len);
    try std.testing.expect(!facts.egress_proven);
    try std.testing.expectEqual(ProofLevel.partial, facts.proof_level);
    try std.testing.expectEqual(@as(usize, 3), facts.checks_passed.len);
}

/// The seven properties whose absence must read as false. A contract with
/// `properties == null` proved none of them.
const security_property_names = [_][]const u8{
    "injection_safe",
    "state_isolated",
    "deterministic",
    "no_secret_leakage",
    "no_credential_leakage",
    "input_validated",
    "pii_contained",
};

test "extractProvenFacts reads every security property as false when properties is null" {
    const allocator = std.testing.allocator;
    var contract = try makeTestContract(allocator);
    defer contract.deinit(allocator);
    try std.testing.expect(contract.properties == null);

    const result = try extractProvenFacts(allocator, &contract);
    defer allocator.free(result.checks_buf);
    defer allocator.free(result.routes_buf);

    inline for (security_property_names) |name| {
        try std.testing.expect(!@field(result.facts, name));
    }
}

test "extractProvenFacts keeps a proven property when properties is set" {
    const allocator = std.testing.allocator;
    var contract = try makeTestContract(allocator);
    defer contract.deinit(allocator);
    contract.properties = .{
        .pure = false,
        .read_only = false,
        .stateless = false,
        .retry_safe = false,
        .deterministic = true,
        .has_egress = false,
        .injection_safe = true,
    };

    const result = try extractProvenFacts(allocator, &contract);
    defer allocator.free(result.checks_buf);
    defer allocator.free(result.routes_buf);

    try std.testing.expect(result.facts.injection_safe);
    try std.testing.expect(result.facts.deterministic);
}

// A property that nothing proved reads as not held. No `bool` field of
// `ProvenFacts` may default to true, so a new property added with `= true`
// fails the build instead of reading as proven. A field with no default is
// allowed: the producer must then state it.
comptime {
    const info = @typeInfo(ProvenFacts).@"struct";
    for (info.field_names, info.field_attrs) |field, attrs| {
        if (@FieldType(ProvenFacts, field) == bool) {
            if (attrs.defaultValue(bool)) |default| {
                if (default) @compileError("ProvenFacts." ++ field ++ " must default to false");
            }
        }
    }
}

// -------------------------------------------------------------------------
// Projection census: HandlerProperties -> ProvenFacts
// -------------------------------------------------------------------------

/// One field that the projection leaves out, with the reason.
const Exclusion = struct {
    name: []const u8,
    reason: []const u8,
};

fn isExcluded(comptime excluded: []const Exclusion, comptime name: []const u8) bool {
    for (excluded) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

/// Return the first problem in the field projection from `Source` to `Target`, or null.
/// Every source field is excluded or has a target field of the same name and type.
/// Every target field is excluded or has a source field of the same name.
/// Each exclusion names a field on its own side and states a reason.
fn projectionProblem(
    comptime Source: type,
    comptime Target: type,
    comptime source_excluded: []const Exclusion,
    comptime target_excluded: []const Exclusion,
) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const names = @typeName(Source) ++ " -> " ++ @typeName(Target);
    for (source_excluded) |entry| {
        if (!@hasField(Source, entry.name)) return names ++ ": source exclusion names no field: " ++ entry.name;
        if (entry.reason.len == 0) return names ++ ": source exclusion has no reason: " ++ entry.name;
    }
    for (target_excluded) |entry| {
        if (!@hasField(Target, entry.name)) return names ++ ": target exclusion names no field: " ++ entry.name;
        if (entry.reason.len == 0) return names ++ ": target exclusion has no reason: " ++ entry.name;
    }
    for (@typeInfo(Source).@"struct".field_names) |field| {
        if (isExcluded(source_excluded, field)) continue;
        if (!@hasField(Target, field) or isExcluded(target_excluded, field))
            return names ++ ": unclassified source field: " ++ field;
        if (@FieldType(Target, field) != @FieldType(Source, field))
            return names ++ ": field type differs: " ++ field;
    }
    for (@typeInfo(Target).@"struct".field_names) |field| {
        if (isExcluded(target_excluded, field)) continue;
        if (!@hasField(Source, field) or isExcluded(source_excluded, field))
            return names ++ ": unclassified target field: " ++ field;
    }
    return null;
}

const not_carried = "ProvenFacts has no field for it, so neither the review card nor the proof ledger shows it";

/// The `HandlerProperties` fields that `ProvenFacts` does not copy by name.
const facts_source_exclusions = [_]Exclusion{
    .{ .name = "pure", .reason = not_carried },
    .{ .name = "stateless", .reason = not_carried },
    .{ .name = "has_egress", .reason = "an inverse fact that the monotonic ratchets leave out on purpose; egress_endpoints and egress_proven carry the egress surface" },
    .{ .name = "result_safe", .reason = "ProvenFacts.results_safe reads contract.verification.results_safe instead" },
    .{ .name = "optional_safe", .reason = not_carried },
    .{ .name = "post_only", .reason = not_carried },
    .{ .name = "canonical", .reason = not_carried },
    .{ .name = "cost_bounded", .reason = not_carried },
};

/// The `ProvenFacts` fields that do not come from `HandlerProperties`, each with its source.
const facts_target_exclusions = [_]Exclusion{
    .{ .name = "handler_name", .reason = "the file stem of contract.handler.path" },
    .{ .name = "handler_path", .reason = "contract.handler.path" },
    .{ .name = "env_vars", .reason = "contract.env.literal" },
    .{ .name = "env_proven", .reason = "not contract.env.dynamic" },
    .{ .name = "egress_endpoints", .reason = "contract.egress.endpoints" },
    .{ .name = "egress_proven", .reason = "not contract.egress.dynamic" },
    .{ .name = "cache_namespaces", .reason = "contract.cache.namespaces" },
    .{ .name = "cache_proven", .reason = "not contract.cache.dynamic" },
    .{ .name = "routes", .reason = "contract.routes" },
    .{ .name = "proof_level", .reason = "deriveProofLevel over the contract verification and dynamic flags" },
    .{ .name = "checks_passed", .reason = "the passed flags of contract.verification" },
    .{ .name = "results_safe", .reason = "contract.verification.results_safe, not HandlerProperties.result_safe" },
};

comptime {
    if (projectionProblem(zts.HandlerProperties, ProvenFacts, &facts_source_exclusions, &facts_target_exclusions)) |problem|
        @compileError(problem);
}

test "extractProvenFacts copies every HandlerProperties field that ProvenFacts carries" {
    const allocator = std.testing.allocator;
    // Run once with every flag true and once with every flag false, so a field
    // that the projection forgets reads as a default in at least one run.
    const flag_values = [_]bool{ true, false };
    inline for (flag_values) |flag| {
        var contract = try makeTestContract(allocator);
        defer contract.deinit(allocator);
        var source = std.mem.zeroes(zts.HandlerProperties);
        inline for (@typeInfo(zts.HandlerProperties).@"struct".field_names) |field| {
            if (@FieldType(zts.HandlerProperties, field) == bool) @field(source, field) = flag;
        }
        source.max_io_depth = if (flag) 7 else null;
        contract.properties = source;

        const result = try extractProvenFacts(allocator, &contract);
        defer allocator.free(result.checks_buf);
        defer allocator.free(result.routes_buf);

        var compared: usize = 0;
        inline for (@typeInfo(zts.HandlerProperties).@"struct".field_names) |field| {
            if (comptime !isExcluded(&facts_source_exclusions, field)) {
                try std.testing.expectEqual(@field(source, field), @field(result.facts, field));
                compared += 1;
            }
        }
        // The floor: twelve of the twenty fields are carried.
        try std.testing.expectEqual(@as(usize, 12), compared);
    }
}

test "extractProvenFacts reads results_safe from verification and not from result_safe" {
    const allocator = std.testing.allocator;
    const flag_values = [_]bool{ true, false };
    inline for (flag_values) |flag| {
        var contract = try makeTestContract(allocator);
        defer contract.deinit(allocator);
        var source = std.mem.zeroes(zts.HandlerProperties);
        // The property bit takes the opposite value, so a copy from it would show.
        source.result_safe = !flag;
        contract.properties = source;
        contract.verification = .{
            .exhaustive_returns = false,
            .results_safe = flag,
            .unreachable_code = false,
            .bytecode_verified = false,
        };

        const result = try extractProvenFacts(allocator, &contract);
        defer allocator.free(result.checks_buf);
        defer allocator.free(result.routes_buf);
        try std.testing.expectEqual(flag, result.facts.results_safe);
    }
}

test "projectionProblem refuses an unclassified field, a type change, and a bad exclusion" {
    const Source = struct { kept: bool, dropped: bool };
    const Target = struct { kept: bool };
    const dropped = [_]Exclusion{.{ .name = "dropped", .reason = "not needed" }};
    try std.testing.expect(comptime projectionProblem(Source, Target, &dropped, &.{}) == null);
    // A source field with neither a target field nor an exclusion.
    try std.testing.expect(comptime projectionProblem(Source, Target, &.{}, &.{}) != null);
    // A target field with no source field, and the same field once an exclusion names it.
    const Wider = struct { kept: bool, extra: bool };
    try std.testing.expect(comptime projectionProblem(Target, Wider, &.{}, &.{}) != null);
    const extra = [_]Exclusion{.{ .name = "extra", .reason = "set from another source" }};
    try std.testing.expect(comptime projectionProblem(Target, Wider, &.{}, &extra) == null);
    // A type change.
    const Retyped = struct { kept: u8 };
    try std.testing.expect(comptime projectionProblem(Target, Retyped, &.{}, &.{}) != null);
    // An exclusion that names no field, and one with no reason.
    const ghost = [_]Exclusion{.{ .name = "ghost", .reason = "no such field" }};
    try std.testing.expect(comptime projectionProblem(Target, Target, &ghost, &.{}) != null);
    const silent = [_]Exclusion{.{ .name = "dropped", .reason = "" }};
    try std.testing.expect(comptime projectionProblem(Source, Target, &silent, &.{}) != null);
}
