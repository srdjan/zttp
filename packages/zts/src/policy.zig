//! Policy capability gating - Phase 1 (in-process).
//!
//! Defines the PolicyInput / PolicyResult ABI and provides a LocalPolicyChecker
//! that consults the existing RuntimePolicy allowlists.
//!
//! Phase 1 actions: env.read, cache.read, cache.write, db.read, db.write,
//! http.outbound. Unknown actions and missing required resources fail closed.

const std = @import("std");
const handler_policy = @import("handler_policy.zig");
const security_events = @import("security_events.zig");

const RuntimePolicy = handler_policy.RuntimePolicy;

/// What a denial names. Each is one of a fixed set, and none of them is a
/// value the request chose: an egress decision is about an endpoint, and the
/// endpoint a denied request asked for is attacker-influenced text.
///
/// Two of these five have no producer: nothing constructs a denial event whose
/// resource kind is `env_key` or `cache_namespace`. They are kept, because
/// deleting them would delete the record of a real gap rather than close it -
/// `Action` below has `env_read` and `cache_read`, so those denials happen, and
/// they are emitted without naming what was denied. An operator reading the
/// event log can see that a cache read was refused and not which namespace.
/// The names say what the events owe; removing them would make the log look
/// complete.
pub const resource_kind_endpoint = "endpoint";
pub const resource_kind_address_scope = "address_scope";
pub const resource_kind_env_key = "env_key";
pub const resource_kind_cache_namespace = "cache_namespace";
pub const resource_kind_sql_query = "sql_query";

pub const Action = enum {
    env_read,
    cache_read,
    cache_write,
    db_read,
    db_write,
    http_outbound,

    pub fn fromString(s: []const u8) ?Action {
        if (std.mem.eql(u8, s, "env.read")) return .env_read;
        if (std.mem.eql(u8, s, "cache.read")) return .cache_read;
        if (std.mem.eql(u8, s, "cache.write")) return .cache_write;
        if (std.mem.eql(u8, s, "db.read")) return .db_read;
        if (std.mem.eql(u8, s, "db.write")) return .db_write;
        if (std.mem.eql(u8, s, "http.outbound")) return .http_outbound;
        return null;
    }

    pub fn toString(self: Action) []const u8 {
        return switch (self) {
            .env_read => "env.read",
            .cache_read => "cache.read",
            .cache_write => "cache.write",
            .db_read => "db.read",
            .db_write => "db.write",
            .http_outbound => "http.outbound",
        };
    }
};

pub const Actor = union(enum) {
    anonymous,
    user: []const u8,
    service: []const u8,
};

pub const Resource = struct {
    kind: []const u8,
    id: ?[]const u8 = null,
};

pub const Environment = struct {
    service: []const u8 = "zttp",
    mode: []const u8 = "prod",
};

pub const PolicyInput = struct {
    actor: Actor = .anonymous,
    action: Action,
    resource: ?Resource = null,
    env: Environment = .{},
    timestamp_ns: u64 = 0,
    policy_generation: u64 = 0,
};

pub const DenyReason = enum {
    unknown_action,
    missing_resource,
    not_in_allowlist,
    /// The endpoint was allowed and the address it resolved to was not. A
    /// separate reason because it is a separate check: the name passed and the
    /// answer did not.
    address_scope_not_allowed,
    policy_unavailable,

    pub fn toString(self: DenyReason) []const u8 {
        return switch (self) {
            .unknown_action => "unknown_action",
            .missing_resource => "missing_resource",
            .not_in_allowlist => "not_in_allowlist",
            .address_scope_not_allowed => "address_scope_not_allowed",
            .policy_unavailable => "policy_unavailable",
        };
    }
};

pub const PolicyResult = union(enum) {
    allow,
    deny: DenyReason,
};

/// In-process Phase 1 checker. Consults the RuntimePolicy allowlists for
/// known actions. Missing resource ids and unsatisfied allowlists deny.
/// When an allowlist is permissive (not enabled), the underlying
/// RuntimeAllowList returns true; the checker mirrors that behavior so
/// adopting this layer does not change runtime semantics.
pub const LocalPolicyChecker = struct {
    runtime_policy: *const RuntimePolicy,

    pub fn init(runtime_policy: *const RuntimePolicy) LocalPolicyChecker {
        return .{ .runtime_policy = runtime_policy };
    }

    pub fn check(self: LocalPolicyChecker, input: PolicyInput) PolicyResult {
        const resource = input.resource orelse return .{ .deny = .missing_resource };
        const id = resource.id orelse return .{ .deny = .missing_resource };

        const allowed = switch (input.action) {
            .env_read => self.runtime_policy.allowsEnv(id),
            .cache_read, .cache_write => self.runtime_policy.allowsCacheNamespace(id),
            .db_read => self.runtime_policy.allowsSqlQuery(id),
            .db_write => self.runtime_policy.allowsSqlWrite(id),
            // The resource for an outbound request is the endpoint, normalized
            // by the caller. This checker compares; it does not canonicalize,
            // so a value that arrives unnormalized matches nothing and denies.
            .http_outbound => self.runtime_policy.allowsEgressEndpoint(id),
        };

        return if (allowed) .allow else .{ .deny = .not_in_allowlist };
    }
};

/// Wasm-backed policy checker - Phase 2 skeleton.
///
/// `LocalPolicyChecker` and `WasmPolicyChecker` are interchangeable: both
/// expose `check(input: PolicyInput) PolicyResult`. The runtime picks one at
/// startup based on whether a Wasm artifact is present on disk. Call sites
/// do not change between the two modes.
pub const WasmPolicyChecker = struct {
    pub fn check(self: WasmPolicyChecker, input: PolicyInput) PolicyResult {
        _ = self;
        _ = input;
        return .{ .deny = .policy_unavailable };
    }
};

/// Emit a generic policy_denied event to the process-wide security stream.
/// Spec section 12: every denial fires; allow-decisions may be sampled.
///
/// The event names the guard that refused and not the value it refused. That
/// is deliberate and it is why `input.resource.id` is read for the decision
/// and dropped here: a denied value is chosen by the request, so an event
/// carrying it gives one distinct event per distinct attempt - an unbounded
/// set for whatever aggregates these - and copies attacker-supplied text into
/// an operator's log. What stays is bounded: the action, the resource kind,
/// the sink, and the reason. The developer still sees the actual value, in the
/// error the handler receives, which goes to whoever wrote the handler rather
/// than to everyone reading the stream.
pub fn emitDenied(input: PolicyInput, reason: DenyReason) void {
    const resource = input.resource orelse Resource{ .kind = "", .id = "" };
    security_events.emitGlobal(security_events.SecurityEvent.initPolicyDenied(
        input.env.service,
        input.action.toString(),
        resource.kind,
        sinkFor(input.action),
        reason.toString(),
        input.policy_generation,
    ));
}

/// The sink each action is decided at, named as the acceptance kernel names it.
fn sinkFor(action: Action) []const u8 {
    return switch (action) {
        .env_read => "env_read",
        .cache_read, .cache_write => "cache_operation",
        .db_read, .db_write => "sql_execute",
        .http_outbound => "egress_connect",
    };
}

// =========================================================================
// Tests
// =========================================================================

test "a denial event carries the sink, not the value that was refused" {
    try security_events.initGlobal(std.testing.allocator, 8);
    defer security_events.deinitGlobal();

    emitDenied(.{
        .action = .http_outbound,
        .resource = .{ .kind = resource_kind_endpoint, .id = "https://evil.example.com:443" },
        .policy_generation = 41,
    }, .not_in_allowlist);

    const stream = security_events.getGlobal() orelse return error.TestUnexpectedResult;
    var drained: [8]security_events.SecurityEvent = undefined;
    const count = stream.drain(&drained);
    // Floor: an empty drain makes every assertion below vacuous.
    try std.testing.expectEqual(@as(usize, 1), count);

    const event = drained[0];
    try std.testing.expectEqualStrings("http.outbound", event.actionSlice());
    try std.testing.expectEqualStrings(resource_kind_endpoint, event.resourceKindSlice());
    try std.testing.expectEqualStrings("egress_connect", event.resourceIdSlice());
    try std.testing.expectEqualStrings("not_in_allowlist", event.detailSlice());
    try std.testing.expectEqual(@as(u64, 41), event.policy_generation);
    // The refused endpoint appears nowhere in the event, in whole or in part.
    for ([_][]const u8{ "evil.example.com", "evil", "443" }) |part| {
        try std.testing.expect(std.mem.indexOf(u8, event.resourceIdSlice(), part) == null);
        try std.testing.expect(std.mem.indexOf(u8, event.detailSlice(), part) == null);
        try std.testing.expect(std.mem.indexOf(u8, event.resourceKindSlice(), part) == null);
        try std.testing.expect(std.mem.indexOf(u8, event.moduleSlice(), part) == null);
    }
}

test "every action names the sink that decides it" {
    // The set is closed, so a new action cannot reach the stream without a
    // sink name chosen for it.
    const cases = [_]struct { action: Action, sink: []const u8 }{
        .{ .action = .env_read, .sink = "env_read" },
        .{ .action = .cache_read, .sink = "cache_operation" },
        .{ .action = .cache_write, .sink = "cache_operation" },
        .{ .action = .db_read, .sink = "sql_execute" },
        .{ .action = .db_write, .sink = "sql_execute" },
        .{ .action = .http_outbound, .sink = "egress_connect" },
    };
    try std.testing.expectEqual(@typeInfo(Action).@"enum".fields.len, cases.len);
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.sink, sinkFor(case.action));
    }
}

test "Action round-trips through fromString/toString" {
    const cases = [_]Action{ .env_read, .cache_read, .cache_write, .db_read, .db_write, .http_outbound };
    for (cases) |action| {
        const s = action.toString();
        const parsed = Action.fromString(s) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(action, parsed);
    }
}

test "Action.fromString rejects unknown" {
    try std.testing.expect(Action.fromString("db.migrate") == null);
    try std.testing.expect(Action.fromString("") == null);
}

test "checker denies on missing resource" {
    const policy = RuntimePolicy{};
    const checker = LocalPolicyChecker.init(&policy);
    const result = checker.check(.{ .action = .db_write });
    try std.testing.expectEqual(DenyReason.missing_resource, result.deny);
}

test "checker denies on resource without id" {
    const policy = RuntimePolicy{};
    const checker = LocalPolicyChecker.init(&policy);
    const result = checker.check(.{
        .action = .db_write,
        .resource = .{ .kind = "sql_query" },
    });
    try std.testing.expectEqual(DenyReason.missing_resource, result.deny);
}

test "checker allows when allowlist matches" {
    const policy = RuntimePolicy{
        .sql = .{ .enabled = true, .values = &[_][]const u8{"upsert_user"} },
    };
    const checker = LocalPolicyChecker.init(&policy);
    const result = checker.check(.{
        .action = .db_write,
        .resource = .{ .kind = "sql_query", .id = "upsert_user" },
    });
    try std.testing.expectEqual(PolicyResult.allow, result);
}

test "checker denies when allowlist excludes" {
    const policy = RuntimePolicy{
        .sql = .{ .enabled = true, .values = &[_][]const u8{"upsert_user"} },
    };
    const checker = LocalPolicyChecker.init(&policy);
    const result = checker.check(.{
        .action = .db_write,
        .resource = .{ .kind = "sql_query", .id = "drop_table" },
    });
    try std.testing.expectEqual(DenyReason.not_in_allowlist, result.deny);
}

test "WasmPolicyChecker fails closed while phase 2 is unavailable" {
    const checker = WasmPolicyChecker{};
    const result = checker.check(.{
        .action = .http_outbound,
        .resource = .{ .kind = resource_kind_endpoint, .id = "https://api.example.com:443" },
    });
    try std.testing.expectEqual(DenyReason.policy_unavailable, result.deny);
}

test "checker is permissive when allowlist section is omitted" {
    // RuntimePolicy with all sections at default (enabled=false) matches the
    // current handler_policy behavior: callers without a contract-derived
    // policy see no restrictions.
    const policy = RuntimePolicy{};
    const checker = LocalPolicyChecker.init(&policy);

    const cases = [_]struct { action: Action, kind: []const u8, id: []const u8 }{
        .{ .action = .env_read, .kind = "env_var", .id = "ANY_VAR" },
        .{ .action = .cache_read, .kind = "namespace", .id = "any_ns" },
        .{ .action = .cache_write, .kind = "namespace", .id = "any_ns" },
        .{ .action = .db_read, .kind = "sql_query", .id = "any_query" },
        .{ .action = .db_write, .kind = "sql_query", .id = "any_query" },
        .{ .action = .http_outbound, .kind = "host", .id = "any.example.com" },
    };
    for (cases) |c| {
        const result = checker.check(.{
            .action = c.action,
            .resource = .{ .kind = c.kind, .id = c.id },
        });
        try std.testing.expectEqual(PolicyResult.allow, result);
    }
}

// -------------------------------------------------------------------------
// Golden fixtures (spec section 13). Each fixture pairs a PolicyInput with
// an expected PolicyResult. Embedded at build time via @embedFile so tests
// stay hermetic.
// -------------------------------------------------------------------------

const fixture_files = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "allow_db_write_listed", .source = @embedFile("fixtures/policy/allow_db_write_listed.json") },
    .{ .name = "deny_db_write_unlisted", .source = @embedFile("fixtures/policy/deny_db_write_unlisted.json") },
    .{ .name = "deny_unknown_action", .source = @embedFile("fixtures/policy/deny_unknown_action.json") },
    .{ .name = "deny_missing_resource", .source = @embedFile("fixtures/policy/deny_missing_resource.json") },
};

fn runFixture(allocator: std.mem.Allocator, source: []const u8) !PolicyResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const input_obj = root.get("input").?.object;
    const action_str = input_obj.get("action").?.string;
    const action = Action.fromString(action_str) orelse return .{ .deny = .unknown_action };

    var resource: ?Resource = null;
    if (input_obj.get("resource")) |res_val| {
        const res_obj = res_val.object;
        const kind = res_obj.get("kind").?.string;
        const id: ?[]const u8 = if (res_obj.get("id")) |id_val| id_val.string else null;
        resource = .{ .kind = kind, .id = id };
    }

    var sql_values: std.ArrayList([]const u8) = .empty;
    defer sql_values.deinit(allocator);
    var egress_values: std.ArrayList([]const u8) = .empty;
    defer egress_values.deinit(allocator);
    var env_values: std.ArrayList([]const u8) = .empty;
    defer env_values.deinit(allocator);
    var cache_values: std.ArrayList([]const u8) = .empty;
    defer cache_values.deinit(allocator);

    var policy = RuntimePolicy{};
    if (root.get("policy")) |policy_val| {
        const policy_obj = policy_val.object;
        if (policy_obj.get("sql")) |arr| {
            for (arr.array.items) |item| try sql_values.append(allocator, item.string);
            policy.sql = .{ .enabled = true, .values = sql_values.items };
        }
        if (policy_obj.get("egress")) |arr| {
            for (arr.array.items) |item| try egress_values.append(allocator, item.string);
            policy.egress = .{ .enabled = true, .values = egress_values.items };
        }
        if (policy_obj.get("env")) |arr| {
            for (arr.array.items) |item| try env_values.append(allocator, item.string);
            policy.env = .{ .enabled = true, .values = env_values.items };
        }
        if (policy_obj.get("cache")) |arr| {
            for (arr.array.items) |item| try cache_values.append(allocator, item.string);
            policy.cache = .{ .enabled = true, .values = cache_values.items };
        }
    }

    const checker = LocalPolicyChecker.init(&policy);
    return checker.check(.{ .action = action, .resource = resource });
}

test "golden fixtures match expected results" {
    const allocator = std.testing.allocator;
    for (fixture_files) |fix| {
        const result = try runFixture(allocator, fix.source);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fix.source, .{});
        defer parsed.deinit();
        const expected = parsed.value.object.get("expected").?.object;
        const expected_kind = expected.get("kind").?.string;

        if (std.mem.eql(u8, expected_kind, "allow")) {
            std.testing.expectEqual(PolicyResult.allow, result) catch |err| {
                std.debug.print("fixture {s} expected allow, got {any}\n", .{ fix.name, result });
                return err;
            };
        } else if (std.mem.eql(u8, expected_kind, "deny")) {
            const expected_reason = expected.get("reason").?.string;
            const got_reason = switch (result) {
                .allow => {
                    std.debug.print("fixture {s} expected deny/{s}, got allow\n", .{ fix.name, expected_reason });
                    return error.TestUnexpectedResult;
                },
                .deny => |r| r.toString(),
            };
            std.testing.expectEqualStrings(expected_reason, got_reason) catch |err| {
                std.debug.print("fixture {s} reason mismatch: expected {s} got {s}\n", .{ fix.name, expected_reason, got_reason });
                return err;
            };
        } else {
            return error.UnknownExpectedKind;
        }
    }
}

test "http.outbound is decided on the endpoint, not the host" {
    const policy = RuntimePolicy{
        .egress = .{ .enabled = true, .values = &[_][]const u8{"https://api.stripe.com:443"} },
    };
    const checker = LocalPolicyChecker.init(&policy);
    const allowed = checker.check(.{
        .action = .http_outbound,
        .resource = .{ .kind = resource_kind_endpoint, .id = "https://api.stripe.com:443" },
    });
    try std.testing.expectEqual(PolicyResult.allow, allowed);

    // The same host under another scheme or port is another server.
    const other_scheme = checker.check(.{
        .action = .http_outbound,
        .resource = .{ .kind = resource_kind_endpoint, .id = "http://api.stripe.com:80" },
    });
    try std.testing.expectEqual(DenyReason.not_in_allowlist, other_scheme.deny);

    const other = checker.check(.{
        .action = .http_outbound,
        .resource = .{ .kind = resource_kind_endpoint, .id = "https://evil.example.com:443" },
    });
    try std.testing.expectEqual(DenyReason.not_in_allowlist, other.deny);
}

test "WasmPolicyChecker matches LocalPolicyChecker for known fixtures" {
    // Phase 2 contract: the Wasm-backed checker must produce identical
    // results to the in-process checker for all fixtures in
    // packages/zts/src/fixtures/policy/. This test will fail until the
    // interpreter is implemented; it locks in the equivalence contract.
    return error.SkipZigTest; // remove this line once Phase 2 lands
}
