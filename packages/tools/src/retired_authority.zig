//! One refusal predicate for runtime authority that Phase 2 and Phase 3 retired.

const std = @import("std");

pub const Feature = enum {
    durable_module,
    workflow_module,
    queue_module,
    scope_module,
    io_module,
    service_module,
    ledger_module,
    tool_module,
    tool_auth,
    credentials,
    invariant_config,
    declaration_config,
    ledger_config,
    durable_config,
    system_config,

    pub fn sentence(self: Feature) []const u8 {
        return switch (self) {
            .durable_module => "the zttp:durable module",
            .workflow_module => "the zttp:workflow module",
            .queue_module => "the zttp:queue module",
            .scope_module => "the zttp:scope module",
            .io_module => "the zttp:io module",
            .service_module => "the zttp:service module",
            .ledger_module => "the zttp:ledger module",
            .tool_module => "the zttp:tool module",
            .tool_auth => "tool authorization",
            .credentials => "credential references",
            .invariant_config => "the invariants project setting",
            .declaration_config => "the declaration project setting",
            .ledger_config => "the ledger project setting",
            .durable_config => "the durableDir project setting",
            .system_config => "the system project setting",
        };
    }
};

pub const Facts = struct {
    durable_module: bool = false,
    workflow_module: bool = false,
    queue_module: bool = false,
    scope_module: bool = false,
    io_module: bool = false,
    service_module: bool = false,
    ledger_module: bool = false,
    tool_module: bool = false,
    tool_auth: bool = false,
    credentials: bool = false,
    invariant_config: bool = false,
    declaration_config: bool = false,
    ledger_config: bool = false,
    durable_config: bool = false,
    system_config: bool = false,
};

const retired_modules = std.StaticStringMap(Feature).initComptime(.{
    .{ "zttp:durable", .durable_module },
    .{ "zttp:workflow", .workflow_module },
    .{ "zttp:queue", .queue_module },
    .{ "zttp:scope", .scope_module },
    .{ "zttp:io", .io_module },
    .{ "zttp:service", .service_module },
    .{ "zttp:ledger", .ledger_module },
    .{ "zttp:tool", .tool_module },
});

pub fn isRetiredModule(specifier: []const u8) bool {
    return retired_modules.has(specifier);
}

pub fn first(facts: Facts) ?Feature {
    if (facts.durable_module) return .durable_module;
    if (facts.workflow_module) return .workflow_module;
    if (facts.queue_module) return .queue_module;
    if (facts.scope_module) return .scope_module;
    if (facts.io_module) return .io_module;
    if (facts.service_module) return .service_module;
    if (facts.ledger_module) return .ledger_module;
    if (facts.tool_module) return .tool_module;
    if (facts.tool_auth) return .tool_auth;
    if (facts.credentials) return .credentials;
    if (facts.invariant_config) return .invariant_config;
    if (facts.declaration_config) return .declaration_config;
    if (facts.ledger_config) return .ledger_config;
    if (facts.durable_config) return .durable_config;
    if (facts.system_config) return .system_config;
    return null;
}

pub fn projectFacts(object: std.json.ObjectMap) Facts {
    return .{
        .invariant_config = object.contains("invariants"),
        .declaration_config = object.contains("declaration"),
        .ledger_config = object.contains("ledger"),
        .durable_config = object.contains("durableDir"),
        .system_config = object.contains("system"),
        .tool_auth = object.contains("auth"),
        .credentials = object.contains("credentials"),
    };
}

pub fn contractFacts(contract: anytype) Facts {
    // The contract reader refuses retired fields before projection. The
    // current typed contract carries only active obligations and module names.
    var facts: Facts = .{};
    for (contract.modules.items) |module| {
        if (retired_modules.get(module)) |feature| switch (feature) {
            .durable_module => facts.durable_module = true,
            .workflow_module => facts.workflow_module = true,
            .queue_module => facts.queue_module = true,
            .scope_module => facts.scope_module = true,
            .io_module => facts.io_module = true,
            .service_module => facts.service_module = true,
            .ledger_module => facts.ledger_module = true,
            .tool_module => facts.tool_module = true,
            else => unreachable,
        };
    }
    return facts;
}

test "the retired module predicate includes every phase 3 module" {
    const retired = [_][]const u8{
        "zttp:ledger",
        "zttp:tool",
        "zttp:durable",
        "zttp:workflow",
        "zttp:queue",
        "zttp:scope",
        "zttp:io",
        "zttp:service",
    };
    for (retired) |specifier| try std.testing.expect(isRetiredModule(specifier));
    try std.testing.expect(!isRetiredModule("zttp:router"));
}
