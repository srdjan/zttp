const std = @import("std");
const zts = @import("zts");
const json_diag = @import("json_diagnostics.zig");
const expert_meta = @import("expert_meta.zig");
const writeJsonString = zts.writeJsonString;

const file_io = zts.file_io;
const builtin_modules = zts.builtin_modules;
const moduleMetadata = zts.ModuleMetadata;

/// Write the v1 verify-modules envelope to `writer`. Single source of truth
/// for the shape documented in docs/zts-expert-contract.md.
pub fn writeJsonEnvelope(
    writer: anytype,
    result: *const VerifyResult,
    policy_hash: [64]u8,
) !void {
    try writer.print(
        "{{\"ok\":{s},\"policy_version\":\"{s}\",\"policy_hash\":\"{s}\",\"checked_files\":[",
        .{
            if (result.hasErrors()) "false" else "true",
            expert_meta.policy_version,
            policy_hash,
        },
    );
    for (result.checked_files.items, 0..) |path, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, path);
    }
    try writer.writeAll("],\"violations\":[");
    for (result.diagnostics.items, 0..) |*diag, i| {
        if (i > 0) try writer.writeByte(',');
        try json_diag.writeDiagnosticJson(writer, &diag.diag);
    }
    try writer.writeAll("]}\n");
}

pub const OwnedDiagnostic = struct {
    diag: json_diag.JsonDiagnostic,
    owned_message: ?[]u8 = null,
    owned_suggestion: ?[]u8 = null,

    pub fn deinit(self: *OwnedDiagnostic, allocator: std.mem.Allocator) void {
        if (self.owned_message) |msg| allocator.free(msg);
        if (self.owned_suggestion) |msg| allocator.free(msg);
    }

    fn initOwned(
        allocator: std.mem.Allocator,
        code: []const u8,
        severity: []const u8,
        message: []const u8,
        file: []const u8,
        line: u32,
        column: u32,
        suggestion: ?[]const u8,
    ) !OwnedDiagnostic {
        const owned_message = try allocator.dupe(u8, message);
        const owned_suggestion = if (suggestion) |value| try allocator.dupe(u8, value) else null;
        return .{
            .diag = .{
                .code = code,
                .severity = severity,
                .message = owned_message,
                .file = file,
                .line = line,
                .column = column,
                .suggestion = owned_suggestion,
            },
            .owned_message = owned_message,
            .owned_suggestion = owned_suggestion,
        };
    }
};

pub const VerifyResult = struct {
    checked_files: std.ArrayList([]const u8) = .empty,
    diagnostics: std.ArrayList(OwnedDiagnostic) = .empty,

    pub fn deinit(self: *VerifyResult, allocator: std.mem.Allocator) void {
        self.checked_files.deinit(allocator);
        for (self.diagnostics.items) |*diag| diag.deinit(allocator);
        self.diagnostics.deinit(allocator);
    }

    pub fn hasErrors(self: *const VerifyResult) bool {
        for (self.diagnostics.items) |diag| {
            if (std.mem.eql(u8, diag.diag.severity, "error")) return true;
        }
        return false;
    }
};

pub const VerifyOptions = struct {
    strict: bool = false,
};

const CapabilityRule = struct {
    capability: []const u8,
    helpers: []const []const u8,
};

const ForbiddenPattern = struct {
    code: []const u8,
    pattern: []const u8,
    message: []const u8,
    suggestion: []const u8,
};

const capability_rules = [_]CapabilityRule{
    .{ .capability = "env", .helpers = &.{ "readEnvChecked", "readEnvForActiveModule" } },
    .{ .capability = "clock", .helpers = &.{ "clockNowMsChecked", "clockNowNsChecked", "clockNowSecsChecked", "nowMsForActiveModule", "nowNsForActiveModule" } },
    .{ .capability = "random", .helpers = &.{ "fillRandomChecked", "fillRandomForActiveModule" } },
    .{ .capability = "crypto", .helpers = &.{ "sha256Checked", "sha256ForActiveModule", "hmacSha256Checked", "hmacSha256ForActiveModule" } },
    .{ .capability = "stderr", .helpers = &.{ "writeStderrChecked", "writeStderrForActiveModule" } },
    .{ .capability = "runtime_callback", .helpers = &.{ "runtimeCallbackCapabilityChecked", "getRuntimeCallbackStateChecked" } },
    .{ .capability = "sqlite", .helpers = &.{ "sqliteCapabilityChecked", "getSqliteStateChecked", "openSqliteDbChecked" } },
    .{ .capability = "filesystem", .helpers = &.{"readFileChecked"} },
    .{ .capability = "network", .helpers = &.{"requireCapability(handle, .network)"} },
    .{ .capability = "policy_check", .helpers = &.{ "allowsEnvChecked", "allowsEnvForActiveModule", "allowsCacheNamespaceChecked", "allowsCacheNamespaceForActiveModule", "allowsSqlQueryChecked", "allowsSqlQueryForActiveModule", "allowsSqlWriteChecked", "allowsSqlWriteForActiveModule" } },
};

const forbidden_patterns = [_]ForbiddenPattern{
    .{
        .code = "ZVM001",
        .pattern = "capability_policy.",
        .message = "virtual module accesses runtime capability_policy directly",
        .suggestion = "use checked policy helpers from packages/zts/src/module_binding.zig",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.c.getenv",
        .message = "virtual module reads environment variables directly",
        .suggestion = "use readEnvChecked instead of std.c.getenv",
    },
    .{
        .code = "ZVM001",
        .pattern = "file_io.readFile",
        .message = "virtual module reads files directly",
        .suggestion = "use readFileChecked instead of file_io.readFile",
    },
    .{
        .code = "ZVM001",
        .pattern = "Db.openReadWriteCreate",
        .message = "virtual module opens SQLite directly",
        .suggestion = "use openSqliteDbChecked instead of Db.openReadWriteCreate",
    },
    .{
        .code = "ZVM001",
        .pattern = "compat.realtimeNowMs",
        .message = "virtual module reads the clock directly",
        .suggestion = "use clockNowMsChecked instead of compat.realtimeNowMs",
    },
    .{
        .code = "ZVM001",
        .pattern = "compat.realtimeNowNs",
        .message = "virtual module reads the clock directly",
        .suggestion = "use clockNowNsChecked instead of compat.realtimeNowNs",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.c.write(",
        .message = "virtual module writes to stderr directly",
        .suggestion = "use writeStderrChecked instead of std.c.write",
    },
    .{
        .code = "ZVM001",
        .pattern = "HmacSha256.create",
        .message = "virtual module performs HMAC directly",
        .suggestion = "use hmacSha256Checked instead of HmacSha256.create",
    },
    .{
        .code = "ZVM001",
        .pattern = "Sha256.init",
        .message = "virtual module hashes directly",
        .suggestion = "use sha256Checked instead of Sha256.init",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.net.",
        .message = "virtual module opens network connections directly",
        .suggestion = "delegate outbound HTTP through the capability-gated zttp:fetch runtime callback",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.Io.net.",
        .message = "virtual module opens network connections directly",
        .suggestion = "delegate outbound HTTP through the capability-gated zttp:fetch runtime callback",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.http.Client",
        .message = "virtual module constructs an HTTP client directly",
        .suggestion = "delegate outbound HTTP through the capability-gated zttp:fetch runtime callback",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.posix.socket",
        .message = "virtual module opens sockets directly",
        .suggestion = "delegate outbound HTTP through the capability-gated zttp:fetch runtime callback",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.process.Child",
        .message = "virtual module spawns child processes directly",
        .suggestion = "move process execution outside the virtual module boundary",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.process.spawn",
        .message = "virtual module spawns child processes directly",
        .suggestion = "move process execution outside the virtual module boundary",
    },
    .{
        .code = "ZVM001",
        .pattern = "execv",
        .message = "virtual module replaces the current process directly",
        .suggestion = "move process execution outside the virtual module boundary",
    },
    .{
        .code = "ZVM001",
        .pattern = "std.posix.fork",
        .message = "virtual module forks the current process directly",
        .suggestion = "move process execution outside the virtual module boundary",
    },
};

pub fn verifyPaths(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    options: VerifyOptions,
) !VerifyResult {
    var result = VerifyResult{};
    errdefer result.deinit(allocator);

    for (paths) |path| {
        try result.checked_files.append(allocator, path);
        try auditPath(allocator, path, &result.diagnostics, options);
    }

    return result;
}

pub fn verifyBuiltins(allocator: std.mem.Allocator, options: VerifyOptions) !VerifyResult {
    var result = VerifyResult{};
    errdefer result.deinit(allocator);

    for (builtin_modules.governanceEntries()) |entry| {
        try result.checked_files.append(allocator, entry.module_path);
        try result.checked_files.append(allocator, entry.spec_path);
        try auditModuleAndSpec(allocator, entry.module_path, entry.spec_path, &result.diagnostics, options);
    }

    return result;
}

pub fn verifyManifestPath(allocator: std.mem.Allocator, path: []const u8) !VerifyResult {
    var result = VerifyResult{};
    errdefer result.deinit(allocator);

    try result.checked_files.append(allocator, path);
    const content = file_io.readFile(allocator, path, 256 * 1024) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "failed to read module manifest: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try appendDiagnostic(allocator, &result.diagnostics, "ZVM010", "error", message, path, 1, 1, "ensure the manifest exists and is readable");
        return result;
    };
    defer allocator.free(content);

    var manifest = moduleMetadata.parse(allocator, content) catch |err| {
        try appendManifestDiagnostic(allocator, &result.diagnostics, path, err);
        return result;
    };
    defer manifest.deinit(allocator);

    return result;
}

fn auditPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
    options: VerifyOptions,
) !void {
    if (findBuiltinEntryByModulePath(path)) |entry| {
        const spec_path = try resolveCompanionPath(allocator, path, entry.module_path, entry.spec_path);
        defer allocator.free(spec_path);
        try auditModuleAndSpec(allocator, path, spec_path, diagnostics, options);
        return;
    }

    if (findBuiltinEntryBySpecPath(path)) |entry| {
        const module_path = try resolveCompanionPath(allocator, path, entry.spec_path, entry.module_path);
        defer allocator.free(module_path);

        if (!file_io.fileExists(allocator, module_path)) {
            try appendDiagnostic(
                allocator,
                diagnostics,
                "ZVM006",
                "error",
                "module spec has no matching Zig module file",
                path,
                1,
                1,
                "create or restore the matching file under packages/zts/src/modules/",
            );
            return;
        }

        try auditModuleContentWithSpecPath(allocator, module_path, path, diagnostics);
        return;
    }

    if (looksLikeBuiltinAdjacentPath(path)) {
        return;
    }

    try appendDiagnostic(
        allocator,
        diagnostics,
        "ZVM000",
        "error",
        "verify-modules only accepts built-in module Zig files or module spec JSON files",
        path,
        1,
        1,
        "pass a path under packages/modules/src/, packages/zts/src/modules/, or packages/modules/module-specs/",
    );
}

fn auditModuleAndSpec(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    spec_path: []const u8,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
    options: VerifyOptions,
) !void {
    if (!file_io.fileExists(allocator, spec_path)) {
        try auditModuleContentWithSpecPath(allocator, module_path, null, diagnostics);
        try appendDiagnostic(
            allocator,
            diagnostics,
            "ZVM003",
            if (options.strict) "error" else "warning",
            "built-in module has no module spec artifact",
            module_path,
            1,
            1,
            "add packages/modules/module-specs/<module>.json for this built-in module",
        );
        return;
    }

    try auditModuleContentWithSpecPath(allocator, module_path, spec_path, diagnostics);
}

fn auditModuleContentWithSpecPath(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    spec_path: ?[]const u8,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
) !void {
    const module_content = file_io.readFile(allocator, module_path, 512 * 1024) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "failed to read module file: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try appendDiagnostic(allocator, diagnostics, "ZVM000", "error", message, module_path, 1, 1, "ensure the file exists and is readable");
        return;
    };
    defer allocator.free(module_content);

    var binding_caps = try parseBindingCapabilities(allocator, module_content);
    defer binding_caps.deinit(allocator);

    const specifier = parseBindingSpecifier(module_content);

    try checkForbiddenPatterns(allocator, module_path, module_content, diagnostics);
    try checkCapabilityHelperDrift(allocator, module_path, module_content, binding_caps.items, diagnostics);
    try checkLabelDerivation(allocator, module_path, module_content, specifier, diagnostics);

    if (spec_path) |path| {
        const spec_content = file_io.readFile(allocator, path, 256 * 1024) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "failed to read module spec: {s}", .{@errorName(err)});
            defer allocator.free(message);
            try appendDiagnostic(allocator, diagnostics, "ZVM000", "error", message, path, 1, 1, "ensure the spec file exists and is readable");
            return;
        };
        defer allocator.free(spec_content);

        var manifest = moduleMetadata.parse(allocator, spec_content) catch |err| {
            try appendManifestDiagnostic(allocator, diagnostics, path, err);
            return;
        };
        defer manifest.deinit(allocator);

        if (specifier == null or !std.mem.eql(u8, specifier.?, manifest.specifier)) {
            try appendDiagnostic(
                allocator,
                diagnostics,
                "ZVM004",
                "error",
                "module specifier differs between Zig binding and module spec",
                path,
                1,
                1,
                "keep `specifier` identical in the Zig binding and the module spec",
            );
        }

        if (!sameCapabilities(binding_caps.items, manifest.required_capabilities.items)) {
            try appendDiagnostic(
                allocator,
                diagnostics,
                "ZVM005",
                "error",
                "requiredCapabilities in the module spec drift from required_capabilities in the Zig binding",
                path,
                1,
                1,
                "update the module spec and binding so they declare the same capability set",
            );
        }

        const binding = builtin_modules.fromSpecifier(manifest.specifier) orelse {
            try appendDiagnostic(
                allocator,
                diagnostics,
                "ZVM007",
                "error",
                "module spec has no matching built-in binding",
                path,
                1,
                1,
                "register the binding in packages/zts/src/builtin_modules.zig or remove the stale spec",
            );
            return;
        };
        try checkBindingExportDrift(allocator, path, binding, &manifest, diagnostics);
    }
}

fn checkBindingExportDrift(
    allocator: std.mem.Allocator,
    spec_path: []const u8,
    binding: *const zts.module_binding.ModuleBinding,
    manifest: *const moduleMetadata.Manifest,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
) !void {
    for (binding.exports) |binding_export| {
        const manifest_export = findManifestExport(manifest.exports.items, binding_export.name) orelse {
            const message = try std.fmt.allocPrint(
                allocator,
                "module spec is missing export `{s}` from the Zig binding",
                .{binding_export.name},
            );
            defer allocator.free(message);
            try appendDiagnostic(
                allocator,
                diagnostics,
                "ZVM007",
                "error",
                message,
                spec_path,
                1,
                1,
                "add the export to the module spec or remove it from the binding",
            );
            continue;
        };

        if (binding_export.effect != manifest_export.effect) {
            const message = try std.fmt.allocPrint(
                allocator,
                "module spec export `{s}` effect `{s}` differs from Zig binding effect `{s}`",
                .{ binding_export.name, @tagName(manifest_export.effect), @tagName(binding_export.effect) },
            );
            defer allocator.free(message);
            try appendDiagnostic(
                allocator,
                diagnostics,
                "ZVM008",
                "error",
                message,
                spec_path,
                1,
                1,
                "keep export effect metadata identical in the Zig binding and module spec",
            );
        }

        if (binding_export.returns != manifest_export.returns) {
            const message = try std.fmt.allocPrint(
                allocator,
                "module spec export `{s}` returns `{s}` differs from Zig binding returns `{s}`",
                .{ binding_export.name, @tagName(manifest_export.returns), @tagName(binding_export.returns) },
            );
            defer allocator.free(message);
            try appendDiagnostic(
                allocator,
                diagnostics,
                "ZVM009",
                "error",
                message,
                spec_path,
                1,
                1,
                "keep export return metadata identical in the Zig binding and module spec",
            );
        }
    }

    for (manifest.exports.items) |manifest_export| {
        if (findBindingExport(binding.exports, manifest_export.name) != null) continue;
        const message = try std.fmt.allocPrint(
            allocator,
            "module spec declares export `{s}` that is not present in the Zig binding",
            .{manifest_export.name},
        );
        defer allocator.free(message);
        try appendDiagnostic(
            allocator,
            diagnostics,
            "ZVM007",
            "error",
            message,
            spec_path,
            1,
            1,
            "remove the stale export from the module spec or add it to the binding",
        );
    }
}

fn findManifestExport(exports: []const moduleMetadata.Export, name: []const u8) ?*const moduleMetadata.Export {
    for (exports) |*export_item| {
        if (std.mem.eql(u8, export_item.name, name)) return export_item;
    }
    return null;
}

fn findBindingExport(
    exports: []const zts.module_binding.FunctionBinding,
    name: []const u8,
) ?*const zts.module_binding.FunctionBinding {
    for (exports) |*export_item| {
        if (std.mem.eql(u8, export_item.name, name)) return export_item;
    }
    return null;
}

fn appendManifestDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
    path: []const u8,
    err: moduleMetadata.Error,
) !void {
    const message = try std.fmt.allocPrint(allocator, "invalid module manifest: {s}", .{@errorName(err)});
    defer allocator.free(message);
    try appendDiagnostic(
        allocator,
        diagnostics,
        "ZVM010",
        "error",
        message,
        path,
        1,
        1,
        "fix the manifest schema, enum values, duplicate exports, or required metadata",
    );
}

fn checkForbiddenPatterns(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
) !void {
    for (forbidden_patterns) |rule| {
        if (std.mem.indexOf(u8, content, rule.pattern)) |offset| {
            try appendDiagnostic(
                allocator,
                diagnostics,
                rule.code,
                "error",
                rule.message,
                path,
                lineNumber(content, offset),
                1,
                rule.suggestion,
            );
        }
    }
}

/// Return kinds whose value can carry data that arrived as an argument.
/// `unknown` is in the carrying set on purpose: an undeclared return is not
/// evidence that nothing flows through it, and the conservative reading is the
/// only one a flow lattice may take from silence.
fn returnKindCarriesData(kind: []const u8) bool {
    const carrying = [_][]const u8{
        "string", "object", "optional_string", "optional_object",
        "result", "dict",   "bytes",           "unknown",
    };
    for (carrying) |c| if (std.mem.eql(u8, c, kind)) return true;
    return false;
}

/// An export that returns a data-carrying kind and still answers
/// `return_labels` alone, with the reason that is the correct answer for it.
///
/// `derives_from_args` is opt-in, and its doc comment names three shapes that
/// must NOT set it: a result that is a fact *about* the arguments rather than
/// data from them, a result that comes from elsewhere (storage, a fresh draw,
/// the host), and a deliberate declassifier. Those are real, so the gate below
/// cannot simply demand the flag everywhere. What it can demand is that the
/// abstention was decided rather than forgotten, which is what a row here is.
///
/// Measured when this table was written: of 49 data-carrying exports, 21 set
/// `derives_from_args`, 9 declare `.validated`, and these 18 abstain. The class
/// this gate exists to stop has already recurred four times - an empty label
/// set, then `validateJson`, `coerceJson` and `decodeJson` - and each time it
/// was fixed at the export rather than at the thing that let the export ship.
const LabelAbstainRow = struct {
    specifier: []const u8,
    export_name: []const u8,
    reason: []const u8,
};

const label_abstain_rows = [_]LabelAbstainRow{
    .{ .specifier = "zttp:cache", .export_name = "cacheGet", .reason = "result comes from storage, not from the arguments" },
    .{ .specifier = "zttp:cache", .export_name = "cacheStats", .reason = "counters about the cache, not data from the arguments" },
    .{ .specifier = "zttp:ratelimit", .export_name = "rateCheck", .reason = "a decision about the key, not the key's data" },
    .{ .specifier = "zttp:sql", .export_name = "sqlOne", .reason = "row comes from storage; the argument is a registered query name" },
    .{ .specifier = "zttp:sql", .export_name = "sqlMany", .reason = "rows come from storage; the argument is a registered query name" },
    .{ .specifier = "zttp:sql", .export_name = "sqlExec", .reason = "result is an affected-row count from storage" },
    .{ .specifier = "zttp:fetch", .export_name = "fetch", .reason = "response comes from the network; labelled `.external` at the source" },
    .{ .specifier = "zttp:fetch", .export_name = "fetchWithRetry", .reason = "response comes from the network; labelled `.external` at the source" },
    .{ .specifier = "zttp:service", .export_name = "serviceCall", .reason = "response comes from the peer service; labelled `.external`" },
    .{ .specifier = "zttp:env", .export_name = "env", .reason = "value comes from the host; labelled `.secret` at the source" },
    .{ .specifier = "zttp:tool", .export_name = "agentPrompt", .reason = "prompt comes from the admitted request, with no arguments; labelled `.user_input` at the source, and admission does not validate it for egress" },
    .{ .specifier = "zttp:id", .export_name = "uuid", .reason = "a fresh draw, unrelated to any argument" },
    .{ .specifier = "zttp:id", .export_name = "ulid", .reason = "a fresh draw, unrelated to any argument" },
    .{ .specifier = "zttp:id", .export_name = "nanoid", .reason = "a fresh draw, unrelated to any argument" },
    .{ .specifier = "zttp:log", .export_name = "logDebug", .reason = "a sink; the return carries nothing back to the caller" },
    .{ .specifier = "zttp:log", .export_name = "logInfo", .reason = "a sink; the return carries nothing back to the caller" },
    .{ .specifier = "zttp:log", .export_name = "logWarn", .reason = "a sink; the return carries nothing back to the caller" },
    .{ .specifier = "zttp:log", .export_name = "logError", .reason = "a sink; the return carries nothing back to the caller" },
    .{ .specifier = "zttp:text", .export_name = "mask", .reason = "deliberate declassifier: it exists to make a secret printable, so it declares `declassifies` for secret and credential and keeps every other input label" },
};

fn labelAbstainReason(specifier: ?[]const u8, export_name: []const u8) ?[]const u8 {
    const spec = specifier orelse return null;
    for (label_abstain_rows) |row| {
        if (std.mem.eql(u8, row.specifier, spec) and std.mem.eql(u8, row.export_name, export_name)) {
            return row.reason;
        }
    }
    return null;
}

/// ZVM011. An export whose return can carry argument data must say how the
/// flow checker should label its result: `derives_from_args = true` to union
/// the arguments in, `.validated = true` in `return_labels` to route through
/// the validator path, or a row in `label_abstain_rows` giving the reason
/// neither applies.
///
/// The default without any of those is `return_labels` alone, which the field's
/// own doc calls a fail-open: "an export declaring nothing answers the empty
/// set, which is a positive claim that its result carries no provenance."
/// Nothing checked that claim until this gate.
fn checkLabelDerivation(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    specifier: ?[]const u8,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
) !void {
    var it = ExportBindingIterator.init(content);
    while (it.next()) |binding| {
        if (!returnKindCarriesData(binding.return_kind)) continue;
        if (binding.derives_from_args or binding.declares_validated) continue;
        if (labelAbstainReason(specifier, binding.name) != null) continue;

        const message = try std.fmt.allocPrint(
            allocator,
            "export `{s}` returns `{s}`, which can carry argument data, but sets neither " ++
                "`derives_from_args` nor `.validated` in `return_labels`; its result would answer " ++
                "the empty label set, which claims it carries no provenance",
            .{ binding.name, binding.return_kind },
        );
        defer allocator.free(message);
        try appendDiagnostic(
            allocator,
            diagnostics,
            "ZVM011",
            "error",
            message,
            path,
            lineNumber(content, binding.offset),
            1,
            "set `derives_from_args = true` if the result carries argument data, declare " ++
                "`.validated = true` if it validates, or add a row to `label_abstain_rows` in " ++
                "module_audit.zig saying why neither applies",
        );
    }
}

/// Walks `.name = "..."` markers and keeps the ones that are function bindings.
/// `.module_func` is the discriminator: every `FunctionBinding` carries it and
/// the enclosing `ModuleBinding.name` does not.
const ExportBindingIterator = struct {
    content: []const u8,
    cursor: usize = 0,

    const Binding = struct {
        name: []const u8,
        return_kind: []const u8,
        derives_from_args: bool,
        declares_validated: bool,
        offset: usize,
    };

    fn init(content: []const u8) ExportBindingIterator {
        return .{ .content = content };
    }

    fn next(self: *ExportBindingIterator) ?Binding {
        const marker = ".name = \"";
        while (std.mem.indexOfPos(u8, self.content, self.cursor, marker)) |idx| {
            const name_start = idx + marker.len;
            const name_end = std.mem.indexOfScalarPos(u8, self.content, name_start, '"') orelse {
                self.cursor = self.content.len;
                return null;
            };
            const name = self.content[name_start..name_end];

            // The block runs to the next export marker, or to end of file.
            const body_end = if (std.mem.indexOfPos(u8, self.content, name_end, marker)) |n| n else self.content.len;
            const body = self.content[name_end..body_end];
            self.cursor = name_end;

            if (std.mem.indexOf(u8, body, ".module_func") == null) continue;

            return .{
                .name = name,
                .return_kind = parseReturnKind(body) orelse "unknown",
                .derives_from_args = std.mem.indexOf(u8, body, "derives_from_args = true") != null,
                .declares_validated = parseDeclaresValidated(body),
                .offset = idx,
            };
        }
        return null;
    }
};

fn parseReturnKind(body: []const u8) ?[]const u8 {
    const marker = ".returns = .";
    const idx = std.mem.indexOf(u8, body, marker) orelse return null;
    const start = idx + marker.len;
    var end = start;
    while (end < body.len and isIdentChar(body[end])) : (end += 1) {}
    if (end == start) return null;
    return body[start..end];
}

/// `.validated = true` inside this binding's own `return_labels` literal, not
/// anywhere in the block: a neighbouring field must not be read as this one.
fn parseDeclaresValidated(body: []const u8) bool {
    const marker = ".return_labels = .{";
    const idx = std.mem.indexOf(u8, body, marker) orelse return false;
    const start = idx + marker.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '}') orelse return false;
    return std.mem.indexOf(u8, body[start..end], ".validated = true") != null;
}

fn checkCapabilityHelperDrift(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    declared_capabilities: []const []const u8,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
) !void {
    for (capability_rules) |rule| {
        var used = false;
        var offset: usize = 0;
        for (rule.helpers) |helper| {
            if (std.mem.indexOf(u8, content, helper)) |idx| {
                used = true;
                offset = idx;
                break;
            }
        }
        if (used and !containsString(declared_capabilities, rule.capability)) {
            const message = try std.fmt.allocPrint(
                allocator,
                "module uses `{s}` capability helpers but does not declare `.{s}` in required_capabilities",
                .{ rule.capability, rule.capability },
            );
            defer allocator.free(message);
            try appendDiagnostic(
                allocator,
                diagnostics,
                "ZVM002",
                "error",
                message,
                path,
                lineNumber(content, offset),
                1,
                "declare the capability in both the Zig binding and the module spec",
            );
        }
    }
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(OwnedDiagnostic),
    code: []const u8,
    severity: []const u8,
    message: []const u8,
    file: []const u8,
    line: u32,
    column: u32,
    suggestion: ?[]const u8,
) !void {
    try diagnostics.append(allocator, try OwnedDiagnostic.initOwned(
        allocator,
        code,
        severity,
        message,
        file,
        line,
        column,
        suggestion,
    ));
}

fn parseBindingSpecifier(content: []const u8) ?[]const u8 {
    return parseAssignedString(content, "specifier = ");
}

fn parseBindingCapabilities(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList([]const u8) {
    var caps: std.ArrayList([]const u8) = .empty;
    errdefer caps.deinit(allocator);

    const marker = "required_capabilities = &.{";
    const start = std.mem.indexOf(u8, content, marker) orelse return caps;
    const body_start = start + marker.len;
    const body_end_rel = std.mem.indexOfScalarPos(u8, content, body_start, '}') orelse return caps;
    const body = content[body_start..body_end_rel];

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '.') continue;
        const start_name = i + 1;
        var end_name = start_name;
        while (end_name < body.len and isIdentChar(body[end_name])) : (end_name += 1) {}
        if (end_name > start_name) {
            const cap = body[start_name..end_name];
            if (!containsString(caps.items, cap)) {
                try caps.append(allocator, cap);
            }
        }
        i = end_name;
    }

    return caps;
}

fn parseAssignedString(content: []const u8, marker: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, content, marker) orelse return null;
    const first_quote = std.mem.indexOfScalarPos(u8, content, idx + marker.len, '"') orelse return null;
    const end_quote = std.mem.indexOfScalarPos(u8, content, first_quote + 1, '"') orelse return null;
    return content[first_quote + 1 .. end_quote];
}

fn looksLikeBuiltinAdjacentPath(path: []const u8) bool {
    const in_legacy_modules_dir = std.mem.indexOf(u8, path, "packages/zts/src/modules/") != null and std.mem.endsWith(u8, path, ".zig");
    const in_peer_modules_dir = std.mem.indexOf(u8, path, "packages/modules/src/") != null and std.mem.endsWith(u8, path, ".zig");
    const in_specs_dir = std.mem.indexOf(u8, path, "packages/modules/module-specs/") != null and std.mem.endsWith(u8, path, ".json");
    return in_legacy_modules_dir or in_peer_modules_dir or in_specs_dir;
}

fn findBuiltinEntryByModulePath(path: []const u8) ?*const builtin_modules.BuiltinGovernanceEntry {
    for (builtin_modules.governanceEntries()) |*entry| {
        if (pathMatchesCanonical(path, entry.module_path)) return entry;
    }
    return null;
}

fn findBuiltinEntryBySpecPath(path: []const u8) ?*const builtin_modules.BuiltinGovernanceEntry {
    for (builtin_modules.governanceEntries()) |*entry| {
        if (pathMatchesCanonical(path, entry.spec_path)) return entry;
    }
    return null;
}

fn pathMatchesCanonical(path: []const u8, canonical_path: []const u8) bool {
    if (std.mem.eql(u8, path, canonical_path)) return true;
    if (!std.mem.endsWith(u8, path, canonical_path)) return false;
    const prefix_len = path.len - canonical_path.len;
    return prefix_len > 0 and path[prefix_len - 1] == '/';
}

fn resolveCompanionPath(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    canonical_input: []const u8,
    canonical_target: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, input_path, canonical_input)) {
        return allocator.dupe(u8, canonical_target);
    }

    const prefix_len = input_path.len - canonical_input.len;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{
        input_path[0..prefix_len],
        canonical_target,
    });
}

fn sameCapabilities(
    binding_caps: []const []const u8,
    manifest_caps: []const moduleMetadata.CapabilityDeclaration,
) bool {
    if (binding_caps.len != manifest_caps.len) return false;
    for (binding_caps) |item| {
        const cap = std.meta.stringToEnum(zts.module_binding.ModuleCapability, item) orelse return false;
        var found = false;
        for (manifest_caps) |decl| {
            if (decl.effective == cap) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn lineNumber(content: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (content[0..@min(offset, content.len)]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn isIdentChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "parse binding capabilities from Zig binding" {
    const source =
        \\pub const binding = mb.ModuleBinding{
        \\    .required_capabilities = &.{ .env, .policy_check },
        \\};
    ;

    var caps = try parseBindingCapabilities(std.testing.allocator, source);
    defer caps.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), caps.items.len);
    try std.testing.expect(containsString(caps.items, "env"));
    try std.testing.expect(containsString(caps.items, "policy_check"));
}

test "ZVM011 fires on a data-carrying export that declares no derivation" {
    const allocator = std.testing.allocator;
    var diags: std.ArrayList(OwnedDiagnostic) = .empty;
    defer {
        for (diags.items) |*diag| diag.deinit(allocator);
        diags.deinit(allocator);
    }

    const source =
        \\pub const binding = mb.ModuleBinding{
        \\    .specifier = "zttp:test",
        \\    .exports = &.{
        \\        .{
        \\            .name = "slugify",
        \\            .module_func = slugifyImpl,
        \\            .arg_count = 1,
        \\            .returns = .string,
        \\        },
        \\    },
        \\};
    ;

    try checkLabelDerivation(allocator, "packages/modules/src/test.zig", source, "zttp:test", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("ZVM011", diags.items[0].diag.code);
    // Names the export, so the diagnostic points at the binding to edit.
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].diag.message, "slugify") != null);
}

test "ZVM011 is silent when the export says how its result is labelled" {
    const allocator = std.testing.allocator;

    // Each of the three admitted answers, checked separately so a run in which
    // only one of them works cannot pass as all three.
    const cases = [_][]const u8{
        // derives_from_args: arguments union into the result.
        \\pub const binding = mb.ModuleBinding{
        \\    .specifier = "zttp:test",
        \\    .exports = &.{
        \\        .{ .name = "sha256", .module_func = f, .returns = .string, .derives_from_args = true },
        \\    },
        \\};
        ,
        // validated: routed through the validator path instead.
        \\pub const binding = mb.ModuleBinding{
        \\    .specifier = "zttp:test",
        \\    .exports = &.{
        \\        .{ .name = "parseIt", .module_func = f, .returns = .result, .return_labels = .{ .validated = true } },
        \\    },
        \\};
        ,
        // A non-carrying return has nothing to say.
        \\pub const binding = mb.ModuleBinding{
        \\    .specifier = "zttp:test",
        \\    .exports = &.{
        \\        .{ .name = "timingSafeEqual", .module_func = f, .returns = .boolean },
        \\    },
        \\};
        ,
    };

    for (cases) |source| {
        var diags: std.ArrayList(OwnedDiagnostic) = .empty;
        defer {
            for (diags.items) |*diag| diag.deinit(allocator);
            diags.deinit(allocator);
        }
        try checkLabelDerivation(allocator, "packages/modules/src/test.zig", source, "zttp:test", &diags);
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    }
}

test "ZVM011 reads validated from this binding's own return_labels" {
    // A neighbouring export declaring `.validated` must not answer for this
    // one. Without the scoped parse both bindings look validated, because the
    // string appears somewhere in the block.
    const allocator = std.testing.allocator;
    var diags: std.ArrayList(OwnedDiagnostic) = .empty;
    defer {
        for (diags.items) |*diag| diag.deinit(allocator);
        diags.deinit(allocator);
    }

    const source =
        \\pub const binding = mb.ModuleBinding{
        \\    .specifier = "zttp:test",
        \\    .exports = &.{
        \\        .{ .name = "checkIt", .module_func = f, .returns = .result, .return_labels = .{ .validated = true } },
        \\        .{ .name = "passThrough", .module_func = f, .returns = .string, .return_labels = .{} },
        \\    },
        \\};
    ;

    try checkLabelDerivation(allocator, "packages/modules/src/test.zig", source, "zttp:test", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].diag.message, "passThrough") != null);
}

test "every label_abstain_rows row names an export that still abstains" {
    // The other direction, and the one that rots. A row whose export gained
    // `derives_from_args`, was renamed, or was deleted is a waiver for nothing,
    // and it would go on silently excusing a name that no longer exists.
    const allocator = std.testing.allocator;

    var seen_exports: usize = 0;
    var matched = [_]bool{false} ** label_abstain_rows.len;

    for (builtin_modules.governanceEntries()) |entry| {
        const content = file_io.readFile(allocator, entry.module_path, 512 * 1024) catch continue;
        defer allocator.free(content);
        const specifier = parseBindingSpecifier(content) orelse continue;

        var it = ExportBindingIterator.init(content);
        while (it.next()) |b| {
            seen_exports += 1;
            const abstains = returnKindCarriesData(b.return_kind) and
                !b.derives_from_args and !b.declares_validated;
            for (label_abstain_rows, 0..) |row, i| {
                if (!std.mem.eql(u8, row.specifier, specifier)) continue;
                if (!std.mem.eql(u8, row.export_name, b.name)) continue;
                if (abstains) matched[i] = true;
            }
        }
    }

    // The floor. A sweep that parsed nothing would satisfy every assertion
    // below it, so the count is asserted before the counts derived from it.
    try std.testing.expect(seen_exports >= 40);

    for (label_abstain_rows, 0..) |row, i| {
        if (!matched[i]) {
            std.debug.print(
                "stale label_abstain_rows row: {s}.{s} no longer abstains (or no longer exists)\n",
                .{ row.specifier, row.export_name },
            );
            return error.StaleAbstainRow;
        }
    }
}

test "verify module reports helper use without declared capability" {
    const allocator = std.testing.allocator;
    var diags: std.ArrayList(OwnedDiagnostic) = .empty;
    defer {
        for (diags.items) |*diag| diag.deinit(allocator);
        diags.deinit(allocator);
    }

    const source =
        \\pub const binding = mb.ModuleBinding{
        \\    .specifier = "zttp:test",
        \\    .required_capabilities = &.{},
        \\};
        \\
        \\fn useClock() void {
        \\    _ = clockNowMsChecked();
        \\}
    ;

    var caps = try parseBindingCapabilities(allocator, source);
    defer caps.deinit(allocator);

    try checkCapabilityHelperDrift(allocator, "packages/zts/src/modules/test.zig", source, caps.items, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("ZVM002", diags.items[0].diag.code);
}

test "verify module reports network capability use without declaration" {
    const allocator = std.testing.allocator;
    var diags: std.ArrayList(OwnedDiagnostic) = .empty;
    defer {
        for (diags.items) |*diag| diag.deinit(allocator);
        diags.deinit(allocator);
    }

    const source =
        \\pub const binding = mb.ModuleBinding{
        \\    .specifier = "zttp:test",
        \\    .required_capabilities = &.{},
        \\};
        \\
        \\fn useNetwork(handle: *sdk.ModuleHandle) !void {
        \\    try sdk.requireCapability(handle, .network);
        \\}
    ;

    var caps = try parseBindingCapabilities(allocator, source);
    defer caps.deinit(allocator);

    try checkCapabilityHelperDrift(allocator, "packages/modules/src/net/test.zig", source, caps.items, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("ZVM002", diags.items[0].diag.code);
}

test "verify module rejects direct TCP connections" {
    const allocator = std.testing.allocator;
    var diags: std.ArrayList(OwnedDiagnostic) = .empty;
    defer {
        for (diags.items) |*diag| diag.deinit(allocator);
        diags.deinit(allocator);
    }

    const source =
        \\fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
        \\    _ = try std.net.tcpConnectToHost(allocator, host, port);
        \\}
    ;

    try checkForbiddenPatterns(allocator, "packages/modules/src/net/test.zig", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("ZVM001", diags.items[0].diag.code);
}

test "verify module rejects raw HTTP clients and sockets" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        "const stream = try std.Io.net.IpAddress.connect(&address, io, .{});",
        "var client = std.http.Client{ .allocator = allocator, .io = io };",
        "const fd = try std.posix.socket(domain, socket_type, protocol);",
    };

    for (sources) |source| {
        var diags: std.ArrayList(OwnedDiagnostic) = .empty;
        defer {
            for (diags.items) |*diag| diag.deinit(allocator);
            diags.deinit(allocator);
        }

        try checkForbiddenPatterns(allocator, "packages/modules/src/net/test.zig", source, &diags);
        try std.testing.expectEqual(@as(usize, 1), diags.items.len);
        try std.testing.expectEqualStrings("ZVM001", diags.items[0].diag.code);
    }
}

test "verify module rejects child process spawning" {
    const allocator = std.testing.allocator;
    var diags: std.ArrayList(OwnedDiagnostic) = .empty;
    defer {
        for (diags.items) |*diag| diag.deinit(allocator);
        diags.deinit(allocator);
    }

    const source =
        \\fn spawn(io: std.Io) !void {
        \\    var child = try std.process.Child.spawn(io, .{ .argv = &.{"tool"} });
        \\    _ = try child.wait(io);
        \\}
    ;

    try checkForbiddenPatterns(allocator, "packages/modules/src/platform/test.zig", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("ZVM001", diags.items[0].diag.code);
}

test "verify module rejects process spawn exec and fork APIs" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        "var child = try std.process.spawn(io, .{ .argv = argv });",
        "return std.posix.execvpeZ_expandArg0(.no_expand, file, child_argv, envp);",
        "const pid = try std.posix.fork();",
    };

    for (sources) |source| {
        var diags: std.ArrayList(OwnedDiagnostic) = .empty;
        defer {
            for (diags.items) |*diag| diag.deinit(allocator);
            diags.deinit(allocator);
        }

        try checkForbiddenPatterns(allocator, "packages/modules/src/platform/test.zig", source, &diags);
        try std.testing.expectEqual(@as(usize, 1), diags.items.len);
        try std.testing.expectEqualStrings("ZVM001", diags.items[0].diag.code);
    }
}

test "sanctioned outbound callback module audits cleanly" {
    var result = try verifyPaths(
        std.testing.allocator,
        &.{"packages/modules/src/net/fetch.zig"},
        .{},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "registry-driven companion path mapping preserves rooted paths" {
    const allocator = std.testing.allocator;
    const module_path = "/tmp/work/packages/zts/src/modules/http_mod.zig";
    const spec_path = try resolveCompanionPath(
        allocator,
        module_path,
        "packages/zts/src/modules/http_mod.zig",
        "packages/modules/module-specs/http-mod.json",
    );
    defer allocator.free(spec_path);
    try std.testing.expectEqualStrings("/tmp/work/packages/modules/module-specs/http-mod.json", spec_path);
}

test "writeJsonEnvelope on empty VerifyResult emits the ok envelope" {
    var result: VerifyResult = .{};
    defer result.deinit(std.testing.allocator);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);

    const hash = zts.policyHash();
    try writeJsonEnvelope(&aw.writer, &result, hash);

    buf = aw.toArrayList();
    const s = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, s, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"checked_files\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"violations\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"policy_version\":\"2026.04.2\"") != null);
    try std.testing.expectEqual(@as(u8, '\n'), s[s.len - 1]);
}

test "verifyPaths ignores internal helper files outside the public built-in set" {
    var result = try verifyPaths(
        std.testing.allocator,
        &.{"packages/zts/src/modules/internal/util.zig"},
        .{},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.checked_files.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "verifyBuiltins reports the authoritative public module and spec set" {
    var result = try verifyBuiltins(std.testing.allocator, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(builtin_modules.governanceEntries().len * 2, result.checked_files.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    try std.testing.expect(containsString(result.checked_files.items, "packages/modules/src/platform/env.zig"));
    try std.testing.expect(containsString(result.checked_files.items, "packages/modules/module-specs/platform/env.json"));
}

test "pathMatchesCanonical requires a path-separator boundary" {
    try std.testing.expect(pathMatchesCanonical("packages/zts/src/modules/env.zig", "packages/zts/src/modules/env.zig"));
    try std.testing.expect(pathMatchesCanonical("/repo/packages/zts/src/modules/env.zig", "packages/zts/src/modules/env.zig"));
    try std.testing.expect(!pathMatchesCanonical("xpackages/zts/src/modules/env.zig", "packages/zts/src/modules/env.zig"));
}
