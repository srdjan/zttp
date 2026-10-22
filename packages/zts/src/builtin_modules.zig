//! Built-in Module Registry
//!
//! Lists all built-in virtual module bindings. This is the single source of
//! truth for which modules exist - all consumers (resolver, type checker,
//! verifier, contract builder) read from this list.
//!
//! The list is a fixed array; the build adds no third-party modules.

const descriptors = @import("zts-base").module_descriptors;
const mb = @import("module_binding.zig");
const adapter = @import("module_binding_adapter.zig");
const ModuleBinding = mb.ModuleBinding;
const file_io = @import("file_io.zig");
const contract_types = @import("zts-contracts").contract_types;
const module_authorization = @import("zts-base").module_authorization;
const std = @import("std");
const modules = @import("zttp-modules");

// Namespaced to avoid shadowing the `<name>_binding` locals used in the
// governance-assertion tests at the bottom of this file.
const ported = struct {
    const env = adapter.adaptModuleBinding(modules.catalog.env);
    const crypto = adapter.adaptModuleBinding(modules.catalog.crypto);
    const router = adapter.adaptModuleBinding(modules.catalog.router);
    const auth = adapter.adaptModuleBinding(modules.catalog.auth);
    const validate = adapter.adaptModuleBinding(modules.catalog.validate);
    const decode = adapter.adaptModuleBinding(modules.catalog.decode);
    const cache = adapter.adaptModuleBinding(modules.catalog.cache);
    const ratelimit = adapter.adaptModuleBinding(modules.catalog.ratelimit);
    const url = adapter.adaptModuleBinding(modules.catalog.url);
    const id = adapter.adaptModuleBinding(modules.catalog.id);
    const http = adapter.adaptModuleBinding(modules.catalog.http_mod);
    const log = adapter.adaptModuleBinding(modules.catalog.log);
    const text = adapter.adaptModuleBinding(modules.catalog.text);
    const time = adapter.adaptModuleBinding(modules.catalog.time);
    const sse = adapter.adaptModuleBinding(modules.catalog.sse);
};

// installState helpers run during runtime bootstrap, outside any
// module invocation — they can't go through the SDK's handle-gated
// setModuleState and stay on this side of the peer-package boundary.
const sql_mod = @import("modules/data/sql.zig");
const fetch_mod = @import("modules/net/fetch.zig");

// These modules use engine-owned values and context state.
const collections_mod = @import("modules/data/collections.zig");
const bytes_mod = @import("modules/data/bytes_mod.zig");
const json_mod = @import("modules/data/json_mod.zig");
const result_mod = @import("modules/data/result_mod.zig");

/// All in-tree virtual module bindings, in registration order.
pub const builtins = [_]ModuleBinding{
    ported.env,
    ported.crypto,
    ported.router,
    ported.auth,
    ported.validate,
    ported.decode,
    ported.cache,
    collections_mod.binding,
    bytes_mod.binding,
    json_mod.binding,
    result_mod.binding,
    sql_mod.binding,
    ported.url,
    ported.id,
    ported.http,
    ported.log,
    ported.text,
    ported.time,
    ported.ratelimit,
    fetch_mod.binding,
    ported.sse,
};

/// The registry: the core built-ins.
pub const all = builtins;

/// Semantic metadata projected in registration order from the runtime declarations.
/// Runtime registration and registry identity continue to use `all`.
pub const metadata = descriptors.describeModules(&all);

/// Number of built-in modules.
pub const count = all.len;

pub const BuiltinGovernanceEntry = struct {
    specifier: []const u8,
    module_path: []const u8,
    spec_path: []const u8,
};

pub const builtin_governance_entries = [_]BuiltinGovernanceEntry{
    .{ .specifier = "zttp:env", .module_path = "packages/modules/src/platform/env.zig", .spec_path = "packages/modules/module-specs/platform/env.json" },
    .{ .specifier = "zttp:crypto", .module_path = "packages/modules/src/security/crypto.zig", .spec_path = "packages/modules/module-specs/security/crypto.json" },
    .{ .specifier = "zttp:router", .module_path = "packages/modules/src/http/router.zig", .spec_path = "packages/modules/module-specs/http/router.json" },
    .{ .specifier = "zttp:auth", .module_path = "packages/modules/src/security/auth.zig", .spec_path = "packages/modules/module-specs/security/auth.json" },
    .{ .specifier = "zttp:validate", .module_path = "packages/modules/src/security/validate.zig", .spec_path = "packages/modules/module-specs/security/validate.json" },
    .{ .specifier = "zttp:decode", .module_path = "packages/modules/src/security/decode.zig", .spec_path = "packages/modules/module-specs/security/decode.json" },
    .{ .specifier = "zttp:cache", .module_path = "packages/modules/src/data/cache.zig", .spec_path = "packages/modules/module-specs/data/cache.json" },
    .{ .specifier = "zttp:collections", .module_path = "packages/zts/src/modules/data/collections.zig", .spec_path = "packages/modules/module-specs/data/collections.json" },
    .{ .specifier = "zttp:bytes", .module_path = "packages/zts/src/modules/data/bytes_mod.zig", .spec_path = "packages/modules/module-specs/data/bytes.json" },
    .{ .specifier = "zttp:json", .module_path = "packages/zts/src/modules/data/json_mod.zig", .spec_path = "packages/modules/module-specs/data/json.json" },
    .{ .specifier = "zttp:result", .module_path = "packages/zts/src/modules/data/result_mod.zig", .spec_path = "packages/modules/module-specs/data/result.json" },
    .{ .specifier = "zttp:sql", .module_path = "packages/modules/src/data/sql.zig", .spec_path = "packages/modules/module-specs/data/sql.json" },
    .{ .specifier = "zttp:url", .module_path = "packages/modules/src/http/url.zig", .spec_path = "packages/modules/module-specs/http/url.json" },
    .{ .specifier = "zttp:id", .module_path = "packages/modules/src/platform/id.zig", .spec_path = "packages/modules/module-specs/platform/id.json" },
    .{ .specifier = "zttp:http", .module_path = "packages/modules/src/http/http_mod.zig", .spec_path = "packages/modules/module-specs/http/http-mod.json" },
    .{ .specifier = "zttp:log", .module_path = "packages/modules/src/platform/log.zig", .spec_path = "packages/modules/module-specs/platform/log.json" },
    .{ .specifier = "zttp:text", .module_path = "packages/modules/src/platform/text.zig", .spec_path = "packages/modules/module-specs/platform/text.json" },
    .{ .specifier = "zttp:time", .module_path = "packages/modules/src/platform/time.zig", .spec_path = "packages/modules/module-specs/platform/time.json" },
    .{ .specifier = "zttp:ratelimit", .module_path = "packages/modules/src/data/ratelimit.zig", .spec_path = "packages/modules/module-specs/data/ratelimit.json" },
    .{ .specifier = "zttp:fetch", .module_path = "packages/modules/src/net/fetch.zig", .spec_path = "packages/modules/module-specs/net/fetch.json" },
    .{ .specifier = "zttp:sse", .module_path = "packages/modules/src/net/sse.zig", .spec_path = "packages/modules/module-specs/net/sse.json" },
};

comptime {
    if (builtin_governance_entries.len != builtins.len) {
        @compileError("builtin_governance_entries must stay in sync with builtin_modules.builtins");
    }
    for (builtin_governance_entries, builtins) |entry, binding| {
        if (!std.mem.eql(u8, entry.specifier, binding.specifier)) {
            @compileError("builtin_governance_entries specifier drift: " ++ entry.specifier ++ " vs " ++ binding.specifier);
        }
    }
    for (modules.all_bindings) |module_binding| {
        if (!hasBuiltinSpecifier(module_binding.specifier)) {
            @compileError("zttp-modules binding missing from builtin registry: " ++ module_binding.specifier);
        }
    }
}

pub fn governanceEntries() []const BuiltinGovernanceEntry {
    return &builtin_governance_entries;
}

fn hasBuiltinSpecifier(comptime specifier: []const u8) bool {
    for (builtins) |binding| {
        if (std.mem.eql(u8, binding.specifier, specifier)) return true;
    }
    return false;
}

// Validate all bindings at compile time. Produces compile errors for
// duplicate specifiers, duplicate function names, or state inconsistency.
comptime {
    mb.validateBindings(&all);
}

/// Look up a built-in module by specifier string.
pub fn fromSpecifier(specifier: []const u8) ?*const ModuleBinding {
    for (&all) |*b| {
        if (std.mem.eql(u8, b.specifier, specifier)) return b;
    }
    return null;
}

/// Look up semantic metadata without exposing callbacks or lifecycle hooks.
pub fn descriptorFromSpecifier(specifier: []const u8) ?*const descriptors.ModuleDescriptor {
    for (&metadata) |*descriptor| {
        if (std.mem.eql(u8, descriptor.specifier, specifier)) return descriptor;
    }
    return null;
}

pub fn findDescriptor(specifier: []const u8, export_name: []const u8) ?descriptors.ExportDescriptor {
    const descriptor = descriptorFromSpecifier(specifier) orelse return null;
    for (descriptor.exports) |*function| {
        if (std.mem.eql(u8, function.name, export_name)) {
            return .{ .module = descriptor, .function = function };
        }
    }
    return null;
}

/// Get the binding for a specific export from a specific module.
pub fn findExport(
    specifier: []const u8,
    func_name: []const u8,
) ?struct { binding: *const ModuleBinding, func: *const mb.FunctionBinding } {
    const binding = fromSpecifier(specifier) orelse return null;
    for (binding.exports) |*f| {
        if (std.mem.eql(u8, f.name, func_name)) {
            return .{ .binding = binding, .func = f };
        }
    }
    return null;
}

/// Get the binding for a function name (searches all modules).
pub fn findFunction(func_name: []const u8) ?struct { binding: *const ModuleBinding, func: *const mb.FunctionBinding } {
    for (&all) |*b| {
        for (b.exports) |*f| {
            if (std.mem.eql(u8, f.name, func_name)) {
                return .{ .binding = b, .func = f };
            }
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

// Uniqueness of specifiers and function names is enforced at compile time
// by the validateBindings() call above. Only behavioral tests below.

test "fromSpecifier finds known modules" {
    try std.testing.expect(fromSpecifier("zttp:env") != null);
    try std.testing.expect(fromSpecifier("zttp:crypto") != null);
    try std.testing.expect(fromSpecifier("zttp:cache") != null);
    try std.testing.expect(fromSpecifier("zttp:url") != null);
    try std.testing.expect(fromSpecifier("zttp:id") != null);
    try std.testing.expect(fromSpecifier("zttp:sse") != null);
    try std.testing.expect(fromSpecifier("zttp-ext:math") == null);
    try std.testing.expect(fromSpecifier("zttp:unknown") == null);
}

test "findFunction finds known functions" {
    const result = findFunction("sha256");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("zttp:crypto", result.?.binding.specifier);
    try std.testing.expectEqual(mb.ReturnKind.string, result.?.func.returns);
}

test "findExport finds known module export" {
    const result = findExport("zttp:crypto", "sha256");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("zttp:crypto", result.?.binding.specifier);
    try std.testing.expectEqual(mb.ReturnKind.string, result.?.func.returns);
}

test "findFunction finds result-producing functions" {
    const result = findFunction("jwtVerify");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(mb.ReturnKind.result, result.?.func.returns);
}

test "findFunction finds optional-producing functions" {
    const env_fn = findFunction("env");
    try std.testing.expect(env_fn != null);
    try std.testing.expectEqual(mb.ReturnKind.optional_string, env_fn.?.func.returns);

    const cache_fn = findFunction("cacheGet");
    try std.testing.expect(cache_fn != null);
    try std.testing.expectEqual(mb.ReturnKind.optional_string, cache_fn.?.func.returns);

    const router_fn = findFunction("routerMatch");
    try std.testing.expect(router_fn != null);
    try std.testing.expectEqual(mb.ReturnKind.optional_object, router_fn.?.func.returns);
}

test "failure_severity annotations on failable functions" {
    // Critical: auth and validation failures. A bad webhook signature is an
    // authentication failure and returns boolean false.
    try std.testing.expectEqual(mb.FailureSeverity.critical, findFunction("jwtVerify").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.critical, findFunction("verifyWebhookSignature").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.critical, findFunction("validateJson").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.critical, findFunction("validateObject").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.critical, findFunction("coerceJson").?.func.failure_severity);

    // Expected: cache miss, missing config, route not matched
    try std.testing.expectEqual(mb.FailureSeverity.expected, findFunction("env").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.expected, findFunction("cacheGet").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.expected, findFunction("routerMatch").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.expected, findFunction("parseBearer").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.expected, findFunction("sqlOne").?.func.failure_severity);
    // cacheSet returns false on bad arguments, a clock error, or capacity
    // exceeded, and a failed write can leave an earlier value in place.
    try std.testing.expectEqual(mb.FailureSeverity.expected, findFunction("cacheSet").?.func.failure_severity);
    // Upstream: a non-2xx answer from an external endpoint.
    try std.testing.expectEqual(mb.FailureSeverity.upstream, findFunction("fetch").?.func.failure_severity);

    // None: functions that always succeed
    try std.testing.expectEqual(mb.FailureSeverity.none, findFunction("sha256").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.none, findFunction("urlParse").?.func.failure_severity);
    try std.testing.expectEqual(mb.FailureSeverity.none, findFunction("urlEncode").?.func.failure_severity);
}

fn bindingHasCapability(binding: *const ModuleBinding, capability: mb.ModuleCapability) bool {
    for (binding.required_capabilities) |item| {
        if (item == capability) return true;
    }
    return false;
}

test "module capability annotations cover audited helper-enforced built-ins" {
    const env_binding = fromSpecifier("zttp:env").?;
    try std.testing.expect(bindingHasCapability(env_binding, .env));
    try std.testing.expect(bindingHasCapability(env_binding, .policy_check));

    const crypto_binding = fromSpecifier("zttp:crypto").?;
    try std.testing.expect(bindingHasCapability(crypto_binding, .crypto));

    const auth_binding = fromSpecifier("zttp:auth").?;
    try std.testing.expect(bindingHasCapability(auth_binding, .crypto));
    try std.testing.expect(bindingHasCapability(auth_binding, .clock));

    const id_binding = fromSpecifier("zttp:id").?;
    try std.testing.expect(bindingHasCapability(id_binding, .random));
    try std.testing.expect(bindingHasCapability(id_binding, .clock));

    const log_binding = fromSpecifier("zttp:log").?;
    try std.testing.expect(bindingHasCapability(log_binding, .stderr));
    try std.testing.expect(bindingHasCapability(log_binding, .clock));

    const cache_binding = fromSpecifier("zttp:cache").?;
    try std.testing.expect(bindingHasCapability(cache_binding, .clock));
    try std.testing.expect(bindingHasCapability(cache_binding, .policy_check));

    const sql_binding = fromSpecifier("zttp:sql").?;
    try std.testing.expect(bindingHasCapability(sql_binding, .sqlite));
    try std.testing.expect(bindingHasCapability(sql_binding, .policy_check));

    const ratelimit_binding = fromSpecifier("zttp:ratelimit").?;
    try std.testing.expect(bindingHasCapability(ratelimit_binding, .clock));

    const url_binding = fromSpecifier("zttp:url").?;
    try std.testing.expectEqual(@as(usize, 0), url_binding.required_capabilities.len);
}

test "every in-tree builtin module has a module spec artifact" {
    inline for (builtin_governance_entries) |entry| {
        try std.testing.expect(file_io.fileExists(std.testing.allocator, entry.spec_path));
        const contents = try file_io.readFile(std.testing.allocator, entry.spec_path, 64 * 1024);
        defer std.testing.allocator.free(contents);
        try std.testing.expect(contents.len > 0);
        // The artifact is rendered from the binding, so it names the same specifier.
        try std.testing.expect(std.mem.indexOf(u8, contents, "\"specifier\": \"" ++ entry.specifier ++ "\"") != null);
    }
}

test "governance entries stay aligned with public built-ins" {
    const entries = governanceEntries();
    try std.testing.expectEqual(builtins.len, entries.len);
    try std.testing.expectEqualStrings("zttp:env", entries[0].specifier);
    try std.testing.expectEqualStrings("packages/modules/src/platform/env.zig", entries[0].module_path);
    try std.testing.expectEqualStrings("packages/modules/module-specs/platform/env.json", entries[0].spec_path);
    try std.testing.expectEqualStrings("zttp:sse", entries[entries.len - 1].specifier);
}

/// Union `required_capabilities` across every module resolved from
/// `specifiers`. Unknown specifiers (third-party modules not in the linked
/// registry) are silently skipped.
pub fn computeCapabilityMatrix(specifiers: []const []const u8) contract_types.CapabilityMatrix {
    var matrix: contract_types.CapabilityMatrix = .{};
    var seen = [_]bool{false} ** module_authorization.capability_count;
    for (specifiers) |spec| {
        const binding = fromSpecifier(spec) orelse continue;
        for (binding.required_capabilities) |c| {
            seen[@intFromEnum(c)] = true;
        }
    }
    var n: u8 = 0;
    for (std.enums.values(module_authorization.ModuleCapability)) |c| {
        if (seen[@intFromEnum(c)]) {
            matrix.items[n] = c;
            n += 1;
        }
    }
    matrix.len = n;
    matrix.hash = module_authorization.capabilityHash(matrix.slice());
    return matrix;
}

test "computeCapabilityMatrix unions crypto and auth into canonical set" {
    const specs = [_][]const u8{ "zttp:crypto", "zttp:auth" };
    const matrix = computeCapabilityMatrix(&specs);

    // auth needs crypto + clock, crypto needs crypto. Union = {crypto, clock}.
    // Canonical order is enum-declaration order: clock before crypto.
    try std.testing.expectEqual(@as(u8, 2), matrix.len);
    try std.testing.expectEqual(module_authorization.ModuleCapability.clock, matrix.items[0]);
    try std.testing.expectEqual(module_authorization.ModuleCapability.crypto, matrix.items[1]);

    // Hash is non-zero and deterministic
    try std.testing.expect(!std.mem.allEqual(u8, &matrix.hash, 0));
    const again = computeCapabilityMatrix(&specs);
    try std.testing.expectEqualSlices(u8, &matrix.hash, &again.hash);
}

test "computeCapabilityMatrix is order-independent for hash" {
    const specs_ab = [_][]const u8{ "zttp:crypto", "zttp:auth" };
    const specs_ba = [_][]const u8{ "zttp:auth", "zttp:crypto" };
    const a = computeCapabilityMatrix(&specs_ab);
    const b = computeCapabilityMatrix(&specs_ba);
    try std.testing.expectEqualSlices(u8, &a.hash, &b.hash);
    try std.testing.expectEqual(a.len, b.len);
}

test "computeCapabilityMatrix skips unknown specifiers" {
    const specs = [_][]const u8{ "zttp:crypto", "zttp:does-not-exist" };
    const matrix = computeCapabilityMatrix(&specs);
    try std.testing.expectEqual(@as(u8, 1), matrix.len);
    try std.testing.expectEqual(module_authorization.ModuleCapability.crypto, matrix.items[0]);
}

test "computeCapabilityMatrix empty input has empty len and zero hash-of-empty" {
    const matrix = computeCapabilityMatrix(&.{});
    try std.testing.expectEqual(@as(u8, 0), matrix.len);
    // Hash of an empty canonical list must still be deterministic
    const again = computeCapabilityMatrix(&.{});
    try std.testing.expectEqualSlices(u8, &matrix.hash, &again.hash);
}

test "CapabilityMatrix.has finds present and misses absent" {
    const specs = [_][]const u8{"zttp:log"};
    const matrix = computeCapabilityMatrix(&specs);
    try std.testing.expect(matrix.has(.stderr));
    try std.testing.expect(matrix.has(.clock));
    try std.testing.expect(!matrix.has(.crypto));
}

test "the builder's copy of the zttp:validate keyword list matches the module's" {
    // The build refuses a call that names a schema `zttp:validate` would
    // refuse (ZTS514) by reading `validate_keywords.supported`. A keyword
    // added to the module and not to the copy would make the build refuse a
    // schema that compiles; one removed from the module would let through a
    // schema that does not.
    const module_list = &@import("zttp-modules").security.validate.supported_keywords;
    const builder_list = &@import("zts-base").validate_keywords.supported;
    try std.testing.expectEqual(module_list.len, builder_list.len);
    for (module_list, builder_list) |a, b| try std.testing.expectEqualStrings(a, b);
}

test "semantic descriptors preserve every builtin payload and registration order" {
    try std.testing.expectEqual(@as(usize, 21), metadata.len);
    try std.testing.expectEqual(all.len, metadata.len);
    for (all, metadata) |binding, descriptor| {
        inline for (std.meta.fields(descriptors.ModuleDescriptor)) |field| {
            if (comptime !std.mem.eql(u8, field.name, "exports")) {
                try std.testing.expectEqualDeep(@field(binding, field.name), @field(descriptor, field.name));
            }
        }
        try std.testing.expect(binding.exports.len > 0);
        try std.testing.expectEqual(binding.exports.len, descriptor.exports.len);
        for (binding.exports, descriptor.exports) |function, semantic| {
            inline for (std.meta.fields(descriptors.FunctionDescriptor)) |field| {
                if (comptime std.mem.eql(u8, field.name, "return_labels") or std.mem.eql(u8, field.name, "declassifies")) {
                    inline for (std.meta.fields(descriptors.LabelSet)) |label| {
                        try std.testing.expectEqual(@field(@field(function, field.name), label.name), @field(@field(semantic, field.name), label.name));
                    }
                } else {
                    try std.testing.expectEqualDeep(@field(function, field.name), @field(semantic, field.name));
                }
            }
            const found = findDescriptor(binding.specifier, function.name).?;
            try std.testing.expectEqualStrings(descriptor.specifier, found.module.specifier);
            try std.testing.expectEqualStrings(semantic.name, found.function.name);
        }
    }
    try std.testing.expect(descriptorFromSpecifier("zttp:unknown") == null);
    try std.testing.expect(findDescriptor("zttp:env", "missing") == null);
}
