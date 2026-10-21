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
    injection_safe: bool = true,
    idempotent: bool = false,
    state_isolated: bool = true,
    /// True when the handler has no `Date.now()` or `Math.random()` call
    /// sites. Surfaced in the live HUD so authors see `+deterministic`
    /// flip when they introduce a non-deterministic builtin.
    deterministic: bool = true,
    max_io_depth: ?u32 = null,

    // Data flow provenance
    no_secret_leakage: bool = true,
    no_credential_leakage: bool = true,
    input_validated: bool = true,
    pii_contained: bool = true,

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
            .injection_safe = if (contract.properties) |p| p.injection_safe else true,
            .idempotent = if (contract.properties) |p| p.idempotent else false,
            .state_isolated = if (contract.properties) |p| p.state_isolated else true,
            .deterministic = if (contract.properties) |p| p.deterministic else true,
            .max_io_depth = if (contract.properties) |p| p.max_io_depth else null,
            .no_secret_leakage = if (contract.properties) |p| p.no_secret_leakage else true,
            .no_credential_leakage = if (contract.properties) |p| p.no_credential_leakage else true,
            .input_validated = if (contract.properties) |p| p.input_validated else true,
            .pii_contained = if (contract.properties) |p| p.pii_contained else true,
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
