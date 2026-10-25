//! Text reports of a handler contract: sandbox and properties.

const zts = @import("zts");
const HandlerContract = zts.HandlerContract;
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;

pub fn printSandboxReport(contract: *const HandlerContract) void {
    const env_restricted = !contract.env.dynamic;
    const egress_restricted = !contract.egress.dynamic;
    const cache_restricted = !contract.cache.dynamic;
    const sql_restricted = !contract.sql.dynamic;

    if (env_restricted and egress_restricted and cache_restricted and sql_restricted) {
        debugPrint("Sandbox: complete (all access statically proven)\n", .{});
    } else {
        debugPrint("Sandbox derived from contract:\n", .{});
    }

    printSandboxSection("env", contract.env.literal.items, env_restricted, "no dynamic access");
    printSandboxSection("egress", contract.egress.endpoints.items, egress_restricted, "no dynamic access");
    printSandboxSection("cache", contract.cache.namespaces.items, cache_restricted, "no dynamic access");
    printSqlSandboxSection(contract);
}

pub fn printPropertiesReport(contract: *const HandlerContract) void {
    const props = contract.properties orelse return;

    debugPrint("Handler Properties:\n", .{});

    const fields = [_]struct { name: []const u8, value: bool, desc: []const u8 }{
        .{ .name = "pure", .value = props.pure, .desc = "handler is a deterministic function of the request" },
        .{ .name = "read_only", .value = props.read_only, .desc = "no state mutations via virtual modules" },
        .{ .name = "stateless", .value = props.stateless, .desc = "independent of mutable state" },
        .{ .name = "retry_safe", .value = props.retry_safe, .desc = "safe for Lambda auto-retry on timeout" },
        .{ .name = "deterministic", .value = props.deterministic, .desc = "no Date.now(), Math.random(), or performance.now()" },
        .{ .name = "injection_safe", .value = props.injection_safe, .desc = "no unvalidated input in sinks" },
        .{ .name = "idempotent", .value = props.idempotent, .desc = "safe for at-least-once delivery" },
        .{ .name = "state_isolated", .value = props.state_isolated, .desc = "no cross-request data leakage" },
        .{ .name = "result_safe", .value = props.result_safe, .desc = "all result.ok accesses guarded (requires -Dverify)" },
        .{ .name = "optional_safe", .value = props.optional_safe, .desc = "all optionals narrowed before use (requires -Dverify)" },
    };

    for (fields) |f| {
        const label = if (f.value) "PROVEN" else "---   ";
        debugPrint("  {s} {s: <15} {s}\n", .{ label, f.name, f.desc });
    }

    if (props.max_io_depth) |depth| {
        debugPrint("  PROVEN {s: <15} max {d} I/O calls per request\n", .{ "max_io_depth", depth });
    }
    if (contract.cost_envelope) |envelope| {
        switch (envelope.total) {
            .constant => {},
            .linear => |linear| {
                debugPrint(
                    "  PROVEN {s: <15} total <= {d}+{d}*|source| calls per request ({s})\n",
                    .{ "cost_envelope", linear.base, linear.coefficient, linear.source.desc },
                );
            },
            .unbounded => |source| {
                debugPrint("  ---    {s: <15} unbounded ({s})\n", .{ "cost_envelope", source.desc });
            },
        }
    }
}

fn printSqlSandboxSection(contract: *const HandlerContract) void {
    if (contract.sql.dynamic) {
        debugPrint("  sql: unrestricted (dynamic access detected)\n", .{});
        return;
    }
    if (contract.sql.queries.items.len == 0) {
        debugPrint("  sql: restricted to [] (none proven, no dynamic access)\n", .{});
        return;
    }

    debugPrint("  sql: restricted to [", .{});
    for (contract.sql.queries.items, 0..) |query, idx| {
        if (idx > 0) debugPrint(", ", .{});
        debugPrint("{s}", .{query.name});
    }
    debugPrint("] ({d} proven, no dynamic access)\n", .{contract.sql.queries.items.len});
}

fn printSandboxSection(name: []const u8, items: []const []const u8, restricted: bool, reason: []const u8) void {
    if (!restricted) {
        debugPrint("  {s}: unrestricted (dynamic access detected)\n", .{name});
        return;
    }
    if (items.len == 0) {
        debugPrint("  {s}: restricted to [] (none proven, {s})\n", .{ name, reason });
        return;
    }
    debugPrint("  {s}: restricted to [", .{name});
    for (items, 0..) |item, i| {
        if (i > 0) debugPrint(", ", .{});
        debugPrint("{s}", .{item});
    }
    debugPrint("] ({d} proven, {s})\n", .{ items.len, reason });
}
