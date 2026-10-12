//! One refusal predicate for runtime authority that Phase 2 retired.

const std = @import("std");

pub const Feature = enum {
    ledger_module,
    tool_module,
    tool_catalog,
    tool_auth,
    credentials,
    classification_declaration,
    capability_ceiling,
    invariant_config,
    declaration_config,
    ledger_config,

    pub fn sentence(self: Feature) []const u8 {
        return switch (self) {
            .ledger_module => "the zttp:ledger module",
            .tool_module => "the zttp:tool module",
            .tool_catalog => "a tool catalog",
            .tool_auth => "tool authorization",
            .credentials => "credential references",
            .classification_declaration => "classification declarations",
            .capability_ceiling => "a capability ceiling",
            .invariant_config => "the invariants project setting",
            .declaration_config => "the declaration project setting",
            .ledger_config => "the ledger project setting",
        };
    }
};

pub const Facts = struct {
    ledger_module: bool = false,
    tool_module: bool = false,
    tool_catalog: bool = false,
    tool_auth: bool = false,
    credentials: bool = false,
    classification_declaration: bool = false,
    capability_ceiling: bool = false,
    invariant_config: bool = false,
    declaration_config: bool = false,
    ledger_config: bool = false,
};

pub fn isRetiredModule(specifier: []const u8) bool {
    return std.mem.eql(u8, specifier, "zttp:ledger") or
        std.mem.eql(u8, specifier, "zttp:tool");
}

pub fn first(facts: Facts) ?Feature {
    if (facts.ledger_module) return .ledger_module;
    if (facts.tool_module) return .tool_module;
    if (facts.tool_catalog) return .tool_catalog;
    if (facts.tool_auth) return .tool_auth;
    if (facts.credentials) return .credentials;
    if (facts.classification_declaration) return .classification_declaration;
    if (facts.capability_ceiling) return .capability_ceiling;
    if (facts.invariant_config) return .invariant_config;
    if (facts.declaration_config) return .declaration_config;
    if (facts.ledger_config) return .ledger_config;
    return null;
}

pub fn refuse(facts: Facts) error{UnsupportedRuntimeAuthority}!void {
    if (first(facts) != null) return error.UnsupportedRuntimeAuthority;
}

pub fn projectFacts(object: std.json.ObjectMap) Facts {
    return .{
        .invariant_config = object.contains("invariants"),
        .declaration_config = object.contains("declaration"),
        .ledger_config = object.contains("ledger"),
        .tool_auth = object.contains("auth"),
        .credentials = object.contains("credentials"),
    };
}

pub fn contractFacts(contract: anytype) Facts {
    var facts: Facts = .{
        .tool_catalog = contract.tools.items.len != 0,
        .tool_auth = contract.tool_auth != null,
        .credentials = contract.credentials.len != 0,
        .classification_declaration = contract.classifications.items.len != 0,
        .capability_ceiling = contract.ceiling != null,
    };
    for (contract.modules.items) |module| {
        if (std.mem.eql(u8, module, "zttp:ledger")) facts.ledger_module = true;
        if (std.mem.eql(u8, module, "zttp:tool")) facts.tool_module = true;
    }
    return facts;
}
