//! One compiler proof over the final aggregate source overlay.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const project_config = @import("project_config");
const change_set = @import("change_set.zig");
const workspace_snapshot = @import("workspace_snapshot.zig");
const common = @import("tools/common.zig");
const ui_payload = @import("ui_payload.zig");
const proof_enrichment = @import("proof_enrichment.zig");

pub const proof_schema_version = "zttp-aggregate-source-proof-v1";

pub const Diagnostic = struct {
    file: []u8,
    code: []u8,
    severity: []u8,
    message: []u8,

    fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.code);
        allocator.free(self.severity);
        allocator.free(self.message);
        self.* = undefined;
    }
};

/// One surface change between the baseline and candidate contracts of the
/// primary proof root: an env var, egress host, API route, or capability.
pub const ContractChange = struct {
    pub const Kind = enum { env, egress, route, capability };

    kind: Kind,
    added: bool,
    /// Env name, egress host, `METHOD path`, or capability name. Owned.
    text: []u8,
};

pub const AggregateProof = struct {
    proof_id: [64]u8,
    policy_hash: [64]u8,
    read_set_digest: [64]u8,
    proof_roots: [][]u8,
    diagnostics: []Diagnostic,
    system_proven: bool,
    baseline_primary_properties: ?ui_payload.PropertiesSnapshot = null,
    primary_properties: ?ui_payload.PropertiesSnapshot = null,
    /// Contract surface changes of the primary root. Null when either side
    /// has no contract, so no comparison ran.
    contract_changes: ?[]ContractChange = &.{},

    pub fn deinit(self: *AggregateProof, allocator: std.mem.Allocator) void {
        for (self.proof_roots) |root| allocator.free(root);
        allocator.free(self.proof_roots);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        if (self.contract_changes) |changes| freeContractChanges(allocator, changes);
        self.* = undefined;
    }
};

pub const Rejection = struct {
    code: []u8,
    message: []u8,

    pub fn deinit(self: *Rejection, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    accepted: AggregateProof,
    rejected: Rejection,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .accepted => |*proof| proof.deinit(allocator),
            .rejected => |*rejection| rejection.deinit(allocator),
        }
        self.* = undefined;
    }
};

const ContextPaths = struct {
    schema_relative: ?[]u8 = null,
    /// The project's capability policy, if it declares one. Held relative to
    /// the workspace root like the other two, so baseline and candidate each
    /// read the copy inside their own materialized snapshot rather than a path
    /// that escapes it.
    policy_relative: ?[]u8 = null,
    /// The `requiredProperties` names of `zttp.json`, owned and unchecked.
    required_properties: []const []const u8 = &.{},

    fn deinit(self: *ContextPaths, allocator: std.mem.Allocator) void {
        if (self.schema_relative) |path| allocator.free(path);
        if (self.policy_relative) |path| allocator.free(path);
        for (self.required_properties) |name| allocator.free(name);
        allocator.free(self.required_properties);
        self.* = .{};
    }
};

pub fn prove(
    allocator: std.mem.Allocator,
    prepared: *change_set.PreparedChangeSet,
    snapshot: *const workspace_snapshot.Snapshot,
) !Result {
    var candidate = try snapshot.materializeCandidate(allocator, prepared);
    defer candidate.deinit();

    var context = discoverConsistentContext(allocator, prepared, &candidate) catch |err| {
        if (err == error.OutOfMemory) return err;
        return rejectedFmt(allocator, "context_discovery_failed", "aggregate proof context failed: {s}", .{@errorName(err)});
    };
    defer context.deinit(allocator);

    normalizeCandidates(allocator, prepared, &candidate, context.schema_relative) catch |err| {
        if (err == error.OutOfMemory) return err;
        return rejectedFmt(allocator, "normalization_failed", "aggregate normalization failed: {s}", .{@errorName(err)});
    };

    var baseline = try snapshot.materializeBaseline(allocator);
    defer baseline.deinit();

    const roots = discoverProofRoots(allocator, prepared, &candidate) catch |err| {
        if (err == error.OutOfMemory) return err;
        return rejectedFmt(allocator, "proof_roots_failed", "aggregate proof roots failed: {s}", .{@errorName(err)});
    };
    var roots_owned = true;
    defer if (roots_owned) {
        for (roots) |root| allocator.free(root);
        allocator.free(roots);
    };

    var baseline_diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(allocator, &baseline_diagnostics);
    var candidate_diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(allocator, &candidate_diagnostics);

    var baseline_primary_properties: ?ui_payload.PropertiesSnapshot = null;
    var primary_properties: ?ui_payload.PropertiesSnapshot = null;
    var baseline_primary_contract: ?zts.HandlerContract = null;
    defer if (baseline_primary_contract) |*contract| contract.deinit(allocator);
    var primary_contract: ?zts.HandlerContract = null;
    defer if (primary_contract) |*contract| contract.deinit(allocator);
    for (roots, 0..) |relative_root, root_index| {
        var baseline_has_handler = false;
        const before_path = try baseline.pathFor(allocator, relative_root);
        defer allocator.free(before_path);
        const after_path = try candidate.pathFor(allocator, relative_root);
        defer allocator.free(after_path);
        const before_schema = try mappedOptionalPath(allocator, &baseline, context.schema_relative);
        defer if (before_schema) |path| allocator.free(path);
        const after_schema = try mappedOptionalPath(allocator, &candidate, context.schema_relative);
        defer if (after_schema) |path| allocator.free(path);
        const before_policy = mappedPolicySource(allocator, &baseline, context.policy_relative) catch |err| {
            if (err == error.OutOfMemory) return err;
            return rejectedFmt(
                allocator,
                "policy_context_failed",
                "baseline capability policy could not be loaded: {s}",
                .{@errorName(err)},
            );
        };
        defer if (before_policy) |src| allocator.free(src);
        const after_policy = mappedPolicySource(allocator, &candidate, context.policy_relative) catch |err| {
            if (err == error.OutOfMemory) return err;
            return rejectedFmt(
                allocator,
                "policy_context_failed",
                "candidate capability policy could not be loaded: {s}",
                .{@errorName(err)},
            );
        };
        defer if (after_policy) |src| allocator.free(src);
        // A policy that does not parse gives the same ZTS000 on both sides, so
        // the diagnostic comparison below would accept the edit with every
        // allow list switched off.
        if (after_policy) |src| {
            if (try policyParseError(allocator, src)) |reason| {
                return rejectedFmt(
                    allocator,
                    "policy_context_failed",
                    policy_unparsable_format,
                    .{ context.policy_relative orelse "", reason },
                );
            }
        }

        if (fileExists(allocator, before_path)) {
            const collected = collectCheckDiagnostics(
                allocator,
                &baseline_diagnostics,
                baseline.root,
                before_path,
                before_schema,
                before_policy,
                root_index == 0,
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                return rejectedFmt(allocator, "baseline_analysis_failed", "baseline analysis failed for {s}: {s}", .{ relative_root, @errorName(err) });
            };
            baseline_has_handler = collected.has_handler == true;
            if (root_index == 0) {
                baseline_primary_properties = collected.properties;
                baseline_primary_contract = collected.contract;
            }
        }
        const collected = collectCheckDiagnostics(
            allocator,
            &candidate_diagnostics,
            candidate.root,
            after_path,
            after_schema,
            after_policy,
            root_index == 0,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            return rejectedFmt(allocator, "candidate_analysis_failed", "candidate analysis failed for {s}: {s}", .{ relative_root, @errorName(err) });
        };
        // Take ownership first: the rejection below must still free the contract.
        if (root_index == 0) primary_contract = collected.contract;
        // A candidate that did not parse is unknown, not handler-less.
        if (baseline_has_handler and collected.has_handler == false) {
            return rejectedFmt(allocator, "handler_export_lost", "aggregate proof rejected {s}: the candidate has no handler export", .{relative_root});
        }
        if (root_index == 0) primary_properties = collected.properties;
    }

    if (firstNewDiagnostic(baseline_diagnostics.items, candidate_diagnostics.items)) |diagnostic| {
        return rejectedFmt(
            allocator,
            diagnostic.code,
            "aggregate proof rejected {s}: {s}: {s}",
            .{ diagnostic.file, diagnostic.code, diagnostic.message },
        );
    }

    if (try requiredPropertyProblem(allocator, context.required_properties, primary_properties)) |message| {
        defer allocator.free(message);
        return rejectedFmt(allocator, "required_property_lost", "{s}", .{message});
    }

    const policy_hash = zts.policyHash();
    const read_set_digest = digestReadSet(snapshot);
    const proof_id = digestProof(prepared, snapshot, roots, false);
    const changes = try contractChanges(allocator, baseline_primary_contract, primary_contract);
    errdefer if (changes) |owned| freeContractChanges(allocator, owned);
    const owned_diagnostics = try candidate_diagnostics.toOwnedSlice(allocator);
    roots_owned = false;
    return .{ .accepted = .{
        .proof_id = proof_id,
        .policy_hash = policy_hash,
        .read_set_digest = read_set_digest,
        .proof_roots = roots,
        .diagnostics = owned_diagnostics,
        .system_proven = false,
        .baseline_primary_properties = baseline_primary_properties,
        .primary_properties = primary_properties,
        .contract_changes = changes,
    } };
}

fn normalizeCandidates(
    allocator: std.mem.Allocator,
    prepared: *change_set.PreparedChangeSet,
    candidate: *const workspace_snapshot.Materialized,
    schema_relative: ?[]const u8,
) !void {
    const schema_path = try mappedOptionalPath(allocator, candidate, schema_relative);
    defer if (schema_path) |path| allocator.free(path);
    for (prepared.changes) |*change| {
        const relative = common.relativeToRoot(prepared.project_root, change.resolved_path);
        const candidate_path = try candidate.pathFor(allocator, relative);
        defer allocator.free(candidate_path);
        var normalized = try zts_cli.canonicalize.normalizeSourceWithOptions(
            allocator,
            change.candidate,
            candidate_path,
            .{ .sql_schema_path = schema_path, .layout = false },
        );
        defer normalized.deinit(allocator);
        if (!normalized.converged or !normalized.fully_canonical or !normalized.changed) continue;

        const replacement = try allocator.dupe(u8, normalized.canonical_source);
        errdefer allocator.free(replacement);
        const trace = try allocator.alloc([]u8, normalized.rewrite_trace.items.len);
        var trace_count: usize = 0;
        errdefer {
            for (trace[0..trace_count]) |item| allocator.free(item);
            allocator.free(trace);
        }
        for (normalized.rewrite_trace.items, 0..) |intent, index| {
            trace[index] = try allocator.dupe(u8, intent.asString());
            trace_count += 1;
        }
        allocator.free(change.candidate);
        for (change.rewrite_trace) |intent| allocator.free(intent);
        allocator.free(change.rewrite_trace);
        change.candidate = replacement;
        change.rewrite_trace = trace;
        try zts.file_io.writeFile(allocator, candidate_path, replacement);
    }
}

fn discoverConsistentContext(
    allocator: std.mem.Allocator,
    prepared: *const change_set.PreparedChangeSet,
    candidate: *const workspace_snapshot.Materialized,
) !ContextPaths {
    var result: ContextPaths = .{};
    errdefer result.deinit(allocator);
    for (prepared.changes, 0..) |change, index| {
        const relative = common.relativeToRoot(prepared.project_root, change.resolved_path);
        const candidate_path = try candidate.pathFor(allocator, relative);
        defer allocator.free(candidate_path);
        var paths = try zts_cli.edit_simulate.discoverProjectPaths(allocator, candidate_path);
        defer paths.deinit(allocator);
        const schema_relative = try relativeOptionalContext(allocator, candidate.root, paths.sqlite);
        defer if (schema_relative) |path| allocator.free(path);
        const policy_relative = try relativeOptionalContext(allocator, candidate.root, paths.policy);
        defer if (policy_relative) |path| allocator.free(path);
        if (index == 0) {
            result.schema_relative = if (schema_relative) |path| try allocator.dupe(u8, path) else null;
            result.policy_relative = if (policy_relative) |path| try allocator.dupe(u8, path) else null;
            result.required_properties = paths.required_properties;
            paths.required_properties = &.{};
        } else {
            if (!optionalEqual(result.schema_relative, schema_relative)) return error.InconsistentSqlContext;
            if (!optionalEqual(result.policy_relative, policy_relative)) return error.InconsistentPolicyContext;
            if (!namesEqual(result.required_properties, paths.required_properties)) return error.InconsistentRequiredProperties;
        }
    }
    return result;
}

/// Read the policy out of a materialized snapshot. Each side reads its own
/// copy, so a change set that edits the policy is measured against the policy
/// each side actually had.
fn mappedPolicySource(
    allocator: std.mem.Allocator,
    materialized: *const workspace_snapshot.Materialized,
    policy_relative: ?[]const u8,
) !?[]u8 {
    const path = try mappedOptionalPath(allocator, materialized, policy_relative) orelse return null;
    defer allocator.free(path);
    return try zts.file_io.readFile(allocator, path, 1024 * 1024);
}

fn relativeOptionalContext(
    allocator: std.mem.Allocator,
    root: []const u8,
    path: ?[]const u8,
) !?[]u8 {
    const value = path orelse return null;
    if (!common.isPathInsideRoot(root, value)) return error.ProofContextOutsideProject;
    return try allocator.dupe(u8, common.relativeToRoot(root, value));
}

fn namesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |l, r| {
        if (!std.mem.eql(u8, l, r)) return false;
    }
    return true;
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn discoverProofRoots(
    allocator: std.mem.Allocator,
    prepared: *const change_set.PreparedChangeSet,
    candidate: *const workspace_snapshot.Materialized,
) ![][]u8 {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit(allocator);
    }

    const manifest_path = try candidate.pathFor(allocator, "zttp.json");
    defer allocator.free(manifest_path);
    if (fileExists(allocator, manifest_path)) {
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        var config = try project_config.loadAbsolute(allocator, io_backend.io(), manifest_path);
        defer config.deinit(allocator);
        const entry = try config.resolvedEntry(allocator);
        defer allocator.free(entry);
        if (fileExists(allocator, entry)) try appendRelativeRoot(allocator, &roots, candidate.root, entry);
    }

    if (roots.items.len == 0) {
        const first_relative = common.relativeToRoot(prepared.project_root, prepared.changes[0].resolved_path);
        try appendUniqueOwned(allocator, &roots, first_relative);
    }

    const reachable = try allocator.alloc(bool, prepared.changes.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    var root_index: usize = 0;
    while (root_index < roots.items.len) : (root_index += 1) {
        markReachableChanges(allocator, prepared, candidate, roots.items[root_index], reachable) catch |err| switch (err) {
            error.ParseError => {},
            else => return err,
        };
    }
    for (prepared.changes, 0..) |change, index| {
        if (reachable[index]) continue;
        const relative = common.relativeToRoot(prepared.project_root, change.resolved_path);
        try appendUniqueOwned(allocator, &roots, relative);
        markReachableChanges(allocator, prepared, candidate, relative, reachable) catch |err| switch (err) {
            error.ParseError => {},
            else => return err,
        };
    }
    return roots.toOwnedSlice(allocator);
}

fn markReachableChanges(
    allocator: std.mem.Allocator,
    prepared: *const change_set.PreparedChangeSet,
    candidate: *const workspace_snapshot.Materialized,
    relative_root: []const u8,
    reachable: []bool,
) !void {
    const root_path = try candidate.pathFor(allocator, relative_root);
    defer allocator.free(root_path);
    for (prepared.changes, 0..) |change, index| {
        const relative = common.relativeToRoot(prepared.project_root, change.resolved_path);
        if (std.mem.eql(u8, relative, relative_root)) reachable[index] = true;
    }
    const source = try zts.file_io.readFile(allocator, root_path, change_set.max_file_bytes);
    defer allocator.free(source);
    var front_end = try zts_cli.precompile.runCheckOnlyFromSourceWithOptions(allocator, source, root_path, .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer front_end.deinit(allocator);
    // A refused file or module graph has no paths to follow. The check of each
    // root reports the coded refusal.
    if (front_end.parse_errors > 0 or front_end.link_errors > 0) return;
    const module_paths = try zts_cli.precompile.discoverModulePaths(allocator, source, root_path);
    defer zts_cli.precompile.freeModulePaths(allocator, module_paths);
    for (module_paths) |module_path| {
        for (prepared.changes, 0..) |change, index| {
            const relative = common.relativeToRoot(prepared.project_root, change.resolved_path);
            const mapped = try candidate.pathFor(allocator, relative);
            defer allocator.free(mapped);
            if (std.mem.eql(u8, module_path, mapped)) reachable[index] = true;
        }
    }
}

fn appendRelativeRoot(
    allocator: std.mem.Allocator,
    roots: *std.ArrayList([]u8),
    root: []const u8,
    absolute: []const u8,
) !void {
    if (!common.isPathInsideRoot(root, absolute)) return error.ProofRootOutsideProject;
    try appendUniqueOwned(allocator, roots, common.relativeToRoot(root, absolute));
}

fn appendUniqueOwned(allocator: std.mem.Allocator, roots: *std.ArrayList([]u8), value: []const u8) !void {
    for (roots.items) |root| if (std.mem.eql(u8, root, value)) return;
    try roots.append(allocator, try allocator.dupe(u8, value));
}

const Collected = struct {
    properties: ?ui_payload.PropertiesSnapshot,
    has_handler: ?bool,
    /// The handler contract, moved out of the check result when the caller
    /// asked to keep it. Owned by the caller.
    contract: ?zts.HandlerContract = null,
};

fn collectCheckDiagnostics(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Diagnostic),
    materialized_root: []const u8,
    handler_path: []const u8,
    schema_path: ?[]const u8,
    policy_source: ?[]const u8,
    keep_contract: bool,
) !Collected {
    var check = zts_cli.precompile.runCheckOnlyWithOptions(allocator, handler_path, .{
        .sql_schema_path = schema_path,
        .json_mode = true,
        .policy_source = policy_source,
    }) catch |full_error| {
        const source = try zts.file_io.readFile(allocator, handler_path, change_set.max_file_bytes);
        defer allocator.free(source);
        var fallback = zts_cli.precompile.runCheckOnlyFromSourceWithOptions(
            allocator,
            source,
            handler_path,
            .{
                .sql_schema_path = schema_path,
                .json_mode = true,
                .skip_contract = true,
                .policy_source = policy_source,
            },
        ) catch return full_error;
        defer fallback.deinit(allocator);
        if (fallback.json_diagnostics.items.len == 0) return full_error;
        // The fallback skips contract and flow analysis, so its diagnostics
        // alone cannot show that the file is still sound. Record the failed
        // full analysis as a diagnostic: a side that already failed the same
        // way matches it, and only a new failure rejects the edit.
        try appendDiagnostic(
            allocator,
            out,
            common.relativeToRoot(materialized_root, handler_path),
            "analysis_incomplete",
            "error",
            @errorName(full_error),
        );
        try appendCheckDiagnostics(allocator, out, materialized_root, fallback.json_diagnostics.items);
        return .{
            .properties = if (fallback.properties) |properties| proof_enrichment.propertiesSnapshot(properties) else null,
            .has_handler = fallback.has_handler,
        };
    };
    defer check.deinit(allocator);
    try appendCheckDiagnostics(allocator, out, materialized_root, check.json_diagnostics.items);
    return .{
        .properties = if (check.properties) |properties| proof_enrichment.propertiesSnapshot(properties) else null,
        .has_handler = check.has_handler,
        .contract = if (keep_contract) takeContract(&check) else null,
    };
}

fn appendCheckDiagnostics(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Diagnostic),
    materialized_root: []const u8,
    diagnostics: anytype,
) !void {
    // A module graph refusal names its modules by path, and each side of the
    // proof has its own scratch root. Without the root, a refusal reads the same
    // on both sides and in each run.
    const scratch_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{materialized_root});
    defer allocator.free(scratch_prefix);
    for (diagnostics) |diagnostic| {
        const file = if (std.fs.path.isAbsolute(diagnostic.file) and common.isPathInsideRoot(materialized_root, diagnostic.file))
            common.relativeToRoot(materialized_root, diagnostic.file)
        else
            diagnostic.file;
        const message = try std.mem.replaceOwned(u8, allocator, diagnostic.message, scratch_prefix, "");
        defer allocator.free(message);
        try appendDiagnostic(allocator, out, file, diagnostic.code, diagnostic.severity, message);
    }
}

fn firstNewDiagnostic(baseline: []const Diagnostic, candidate: []const Diagnostic) ?Diagnostic {
    for (candidate, 0..) |diagnostic, candidate_index| {
        var baseline_count: usize = 0;
        for (baseline) |prior| if (diagnosticEqual(prior, diagnostic)) {
            baseline_count += 1;
        };
        var candidate_count: usize = 0;
        for (candidate[0 .. candidate_index + 1]) |prior| if (diagnosticEqual(prior, diagnostic)) {
            candidate_count += 1;
        };
        if (candidate_count > baseline_count) return diagnostic;
    }
    return null;
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Diagnostic),
    file: []const u8,
    code: []const u8,
    severity: []const u8,
    message: []const u8,
) !void {
    const owned_file = try allocator.dupe(u8, file);
    errdefer allocator.free(owned_file);
    const owned_code = try allocator.dupe(u8, code);
    errdefer allocator.free(owned_code);
    const owned_severity = try allocator.dupe(u8, severity);
    errdefer allocator.free(owned_severity);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    try out.append(allocator, .{
        .file = owned_file,
        .code = owned_code,
        .severity = owned_severity,
        .message = owned_message,
    });
}

fn diagnosticEqual(left: Diagnostic, right: Diagnostic) bool {
    return std.mem.eql(u8, left.file, right.file) and
        std.mem.eql(u8, left.code, right.code) and
        std.mem.eql(u8, left.severity, right.severity) and
        std.mem.eql(u8, left.message, right.message);
}

/// Move the contract out of a check result so `deinit` leaves it alone.
fn takeContract(check: anytype) ?zts.HandlerContract {
    const contract = check.contract;
    check.contract = null;
    return contract;
}

fn freeContractChanges(allocator: std.mem.Allocator, changes: []ContractChange) void {
    for (changes) |change| allocator.free(change.text);
    allocator.free(changes);
}

fn appendChange(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ContractChange),
    kind: ContractChange.Kind,
    added: bool,
    text: []const u8,
) !void {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    try out.append(allocator, .{ .kind = kind, .added = added, .text = owned });
}

fn appendItemChanges(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ContractChange),
    kind: ContractChange.Kind,
    items: []const zts.contract_diff.ItemChange,
) !void {
    for (items) |item| switch (item.status) {
        .added => try appendChange(allocator, out, kind, true, item.value),
        .removed => try appendChange(allocator, out, kind, false, item.value),
        .unchanged => {},
    };
}

/// Env, egress, route, and capability changes between two contracts. The
/// contract diff holds no capability list, so capabilities are compared here
/// from the capability matrix. Either contract missing yields null.
fn contractChanges(
    allocator: std.mem.Allocator,
    baseline: ?zts.HandlerContract,
    candidate: ?zts.HandlerContract,
) !?[]ContractChange {
    const before = baseline orelse return null;
    const after = candidate orelse return null;
    var out: std.ArrayList(ContractChange) = .empty;
    errdefer {
        for (out.items) |change| allocator.free(change.text);
        out.deinit(allocator);
    }
    var diff = try zts.contract_diff.diffContracts(allocator, &before, &after);
    defer diff.deinit(allocator);
    try appendItemChanges(allocator, &out, .env, diff.env_changes.items);
    try appendItemChanges(allocator, &out, .egress, diff.egress_changes.items);
    for (diff.api_route_changes.items) |route| {
        if (route.status == .unchanged) continue;
        const text = try allocator.print("{s} {s}", .{ route.method, route.path });
        defer allocator.free(text);
        try appendChange(allocator, &out, .route, route.status == .added, text);
    }
    if (before.capabilities) |before_caps| if (after.capabilities) |after_caps| {
        for (after_caps.slice()) |capability| {
            if (before_caps.has(capability)) continue;
            try appendChange(allocator, &out, .capability, true, @tagName(capability));
        }
        for (before_caps.slice()) |capability| {
            if (after_caps.has(capability)) continue;
            try appendChange(allocator, &out, .capability, false, @tagName(capability));
        }
    };
    return try out.toOwnedSlice(allocator);
}

fn deinitDiagnostics(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit(allocator);
    diagnostics.deinit(allocator);
}

fn mappedOptionalPath(
    allocator: std.mem.Allocator,
    materialized: *const workspace_snapshot.Materialized,
    relative: ?[]const u8,
) !?[]u8 {
    const path = relative orelse return null;
    return try materialized.pathFor(allocator, path);
}

fn fileExists(allocator: std.mem.Allocator, path: []const u8) bool {
    return zts.file_io.fileExists(allocator, path);
}

/// The reason `zttp.json` `requiredProperties` refuses a candidate, owned, or null when the candidate
/// proves every required property. The test is absolute: the baseline is not consulted. An unknown
/// name is reported before a missing property.
fn requiredPropertyProblem(
    allocator: std.mem.Allocator,
    required: []const []const u8,
    properties: ?ui_payload.PropertiesSnapshot,
) !?[]u8 {
    if (required.len == 0) return null;
    for (required) |name| {
        if (isPropertyName(name)) continue;
        const hint = try zts.suggestionForUnknownProperty(allocator, name);
        defer if (hint) |text| allocator.free(text);
        return try allocator.print(
            "zttp.json requiredProperties names an unknown property {s}: {s}",
            .{ name, hint orelse "" },
        );
    }
    const proven = properties orelse return try allocator.dupe(
        u8,
        "zttp.json requiredProperties requires proven properties, but the candidate has no property result for the primary handler",
    );
    var missing: std.ArrayList(u8) = .empty;
    defer missing.deinit(allocator);
    for (required) |name| {
        if (provesProperty(proven, name)) continue;
        if (missing.items.len > 0) try missing.appendSlice(allocator, ", ");
        try missing.appendSlice(allocator, name);
    }
    if (missing.items.len == 0) return null;
    return try allocator.print(
        "zttp.json requiredProperties requires properties that the candidate does not prove: {s}",
        .{missing.items},
    );
}

/// What the veto's per-root check reports for the primary root of a workspace
/// as it stands, with the `requiredProperties` that the veto would apply.
pub const WorkspaceContract = struct {
    /// The `entry` of `zttp.json`, relative to the workspace root. Owned.
    entry: []u8,
    /// The `requiredProperties` names of `zttp.json`, owned and unchecked.
    required: []const []const u8,
    /// Null when the check gives no property result for the entry.
    properties: ?ui_payload.PropertiesSnapshot,
    /// Null when the contract analysis did not finish.
    contract: ?zts.HandlerContract,

    pub fn deinit(self: *WorkspaceContract, allocator: std.mem.Allocator) void {
        allocator.free(self.entry);
        for (self.required) |name| allocator.free(name);
        allocator.free(self.required);
        if (self.contract) |*contract| contract.deinit(allocator);
        self.* = undefined;
    }
};

const policy_unparsable_format = "capability policy {s} does not parse: {s}";

/// The name of the error that `zts.parsePolicyJson` gives for `source`, or null when the policy parses.
fn policyParseError(allocator: std.mem.Allocator, source: []const u8) error{OutOfMemory}!?[]const u8 {
    var policy = zts.parsePolicyJson(allocator, source) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return @errorName(err);
    };
    policy.deinit(allocator);
    return null;
}

/// The outcome of `checkWorkspace`.
pub const WorkspaceCheck = union(enum) {
    checked: WorkspaceContract,
    /// The reason `prove` would reject every change set: the policy that `zttp.json` names does
    /// not parse. Owned.
    policy_unparsable: []u8,

    pub fn deinit(self: *WorkspaceCheck, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .checked => |*check| check.deinit(allocator),
            .policy_unparsable => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

/// Run the check that `prove` runs on the primary root, on the workspace as it
/// stands: the same `collectCheckDiagnostics`, with the schema and policy that
/// `zttp.json` names. The `/contract` card reads this result, so the card and
/// the veto cannot disagree about what the handler proves. A policy that does not
/// parse gives `policy_unparsable`, as `prove` rejects it.
pub fn checkWorkspace(allocator: std.mem.Allocator, workspace_root: []const u8) !WorkspaceCheck {
    const root = try common.resolveInsideWorkspace(allocator, workspace_root, ".");
    defer allocator.free(root);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "zttp.json" });
    defer allocator.free(manifest_path);
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    var config = project_config.loadAbsolute(allocator, io_backend.io(), manifest_path) catch |err| switch (err) {
        error.SyntaxError, error.UnexpectedEndOfInput, error.InvalidProjectConfig => return error.ManifestInvalid,
        error.InvalidRequiredProperties => return error.RequiredPropertiesInvalid,
        error.DuplicateField => return error.ManifestDuplicateKey,
        else => return err,
    };
    defer config.deinit(allocator);
    const entry_path = try config.resolvedEntry(allocator);
    defer allocator.free(entry_path);
    if (!fileExists(allocator, entry_path)) return error.EntryMissing;
    if (!common.isPathInsideRoot(root, entry_path)) return error.ProofRootOutsideProject;

    var paths = try zts_cli.edit_simulate.discoverProjectPaths(allocator, entry_path);
    defer paths.deinit(allocator);
    const policy_source: ?[]u8 = if (paths.policy) |path| try zts.file_io.readFile(allocator, path, 1024 * 1024) else null;
    defer if (policy_source) |src| allocator.free(src);
    // `prove` rejects every change set under a policy that does not parse, so no property is
    // proven under one.
    if (policy_source) |src| {
        if (try policyParseError(allocator, src)) |reason| {
            const policy_path = paths.policy orelse "";
            return .{ .policy_unparsable = try allocator.print(policy_unparsable_format, .{ common.relativeToRoot(root, policy_path), reason }) };
        }
    }

    const entry = try allocator.dupe(u8, common.relativeToRoot(root, entry_path));
    errdefer allocator.free(entry);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(allocator, &diagnostics);
    const collected = try collectCheckDiagnostics(allocator, &diagnostics, root, entry_path, paths.sqlite, policy_source, true);
    const required = paths.required_properties;
    paths.required_properties = &.{};
    return .{ .checked = .{
        .entry = entry,
        .required = required,
        .properties = collected.properties,
        .contract = collected.contract,
    } };
}

/// The names of `v1_spec_names` that `properties` proves, in that order. The
/// names are borrowed from `v1_spec_names`; the slice is owned.
pub fn provenNames(allocator: std.mem.Allocator, properties: ?ui_payload.PropertiesSnapshot) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    const proven = properties orelse return try out.toOwnedSlice(allocator);
    for (zts.v1_spec_names) |name| {
        if (provesProperty(proven, name)) try out.append(allocator, name);
    }
    return try out.toOwnedSlice(allocator);
}

fn isPropertyName(name: []const u8) bool {
    for (zts.v1_spec_names) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

/// Whether `properties` proves the boolean field called `name`. A name with no field is not proven.
fn provesProperty(properties: ui_payload.PropertiesSnapshot, name: []const u8) bool {
    inline for (@typeInfo(ui_payload.PropertiesSnapshot).@"struct".field_names) |field| {
        if (@FieldType(ui_payload.PropertiesSnapshot, field) == bool and std.mem.eql(u8, field, name)) return @field(properties, field);
    }
    return false;
}

fn rejectedFmt(
    allocator: std.mem.Allocator,
    code: []const u8,
    comptime format: []const u8,
    args: anytype,
) !Result {
    const owned_code = try allocator.dupe(u8, code);
    errdefer allocator.free(owned_code);
    return .{ .rejected = .{
        .code = owned_code,
        .message = try allocator.print(format, args),
    } };
}

fn digestReadSet(snapshot: *const workspace_snapshot.Snapshot) [64]u8 {
    var hasher = FramedHasher.init("zttp-proof-read-set-v1");
    hasher.usizeField("count", snapshot.entries.len);
    for (snapshot.entries) |entry| {
        hasher.field("path", entry.relative_path);
        hasher.field("state", if (entry.state == .absent) "absent" else "present");
        hasher.field("digest", &entry.sha256);
    }
    return hasher.finish();
}

fn digestProof(
    prepared: *const change_set.PreparedChangeSet,
    snapshot: *const workspace_snapshot.Snapshot,
    roots: []const []const u8,
    system_proven: bool,
) [64]u8 {
    var hasher = FramedHasher.init(proof_schema_version);
    hasher.field("compiler-version", zts.version.string);
    hasher.field("profile", zts.GrammarCatalog.profile_id);
    hasher.field("policy", &zts.policyHash());
    hasher.field("grammar", &zts.grammarHash());
    hasher.field("semantics", &zts.semanticsHash());
    hasher.field("diagnostics", &zts.diagnosticCatalogHash());
    // Bind project placement without embedding a host-specific absolute path.
    // Receipts and deterministic flow artifacts must remain replayable after a
    // workspace is copied to another canonical directory.
    hasher.field(
        "project-relative-root",
        common.relativeToRoot(prepared.workspace_root, prepared.project_root),
    );
    hasher.usizeField("change-count", prepared.changes.len);
    for (prepared.changes, 0..) |change, index| {
        hasher.usizeField("change-index", index);
        hasher.field("path", change.authored_path);
        hasher.field("baseline", &change.baseline_sha256);
        var candidate_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(change.candidate, &candidate_digest, .{});
        hasher.field("candidate", &candidate_digest);
    }
    hasher.field("read-set", &digestReadSet(snapshot));
    hasher.usizeField("root-count", roots.len);
    for (roots) |root| hasher.field("root", root);
    hasher.field("system-proven", if (system_proven) "true" else "false");
    return hasher.finish();
}

const FramedHasher = struct {
    state: std.crypto.hash.sha2.Sha256,

    fn init(domain: []const u8) FramedHasher {
        var self: FramedHasher = .{ .state = std.crypto.hash.sha2.Sha256.init(.{}) };
        self.field("domain", domain);
        return self;
    }

    fn frame(self: *FramedHasher, value: []const u8) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(value.len), .big);
        self.state.update(&length);
        self.state.update(value);
    }

    fn field(self: *FramedHasher, label: []const u8, value: []const u8) void {
        self.frame(label);
        self.frame(value);
    }

    fn usizeField(self: *FramedHasher, label: []const u8, value: usize) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @intCast(value), .big);
        self.field(label, &bytes);
    }

    fn finish(self: *FramedHasher) [64]u8 {
        return std.fmt.bytesToHex(self.state.finalResult(), .lower);
    }
};

const testing = std.testing;

test "aggregate proof accepts coordinated source changes that fail separately" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\"}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "src/handler.ts",
        .data = "export function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(\"old\"); }\n",
    });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    const tail = [_]@import("turn.zig").Change{.{
        .file = "src/helper.ts",
        .content = "export function newValue(): string { return \"new\"; }\n",
    }};
    var prepared = try change_set.prepare(testing.allocator, root, .{
        .file = "src/handler.ts",
        .content = "import { newValue } from \"./helper\";\nexport function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(newValue()); }\n",
        .additional = &tail,
    });
    defer prepared.deinit(testing.allocator);
    var snapshot = try workspace_snapshot.Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);
    var result = try prove(testing.allocator, &prepared, &snapshot);
    defer result.deinit(testing.allocator);
    switch (result) {
        .accepted => |proof| {
            try testing.expectEqual(@as(usize, 1), proof.proof_roots.len);
            try testing.expectEqual(@as(usize, 64), proof.proof_id.len);
        },
        .rejected => |rejection| {
            std.debug.print("unexpected rejection: {s}\n", .{rejection.message});
            return error.TestUnexpectedResult;
        },
    }

    var single = try change_set.prepare(testing.allocator, root, .{
        .file = "src/handler.ts",
        .content = "import { newValue } from \"./helper\";\nexport function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(newValue()); }\n",
    });
    defer single.deinit(testing.allocator);
    var single_snapshot = try workspace_snapshot.Snapshot.capture(testing.allocator, &single);
    defer single_snapshot.deinit(testing.allocator);
    var rejected = try prove(testing.allocator, &single, &single_snapshot);
    defer rejected.deinit(testing.allocator);
    try testing.expect(rejected == .rejected);
}

test "aggregate proof rejects a configured policy it cannot load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\",\"policy\":\"missing-policy.json\"}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "src/handler.ts",
        .data = "export function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(\"old\"); }\n",
    });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    var prepared = try change_set.prepare(testing.allocator, root, .{
        .file = "src/handler.ts",
        .content = "export function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(\"new\"); }\n",
    });
    defer prepared.deinit(testing.allocator);
    var snapshot = try workspace_snapshot.Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);

    var result = try prove(testing.allocator, &prepared, &snapshot);
    defer result.deinit(testing.allocator);
    switch (result) {
        .accepted => return error.TestUnexpectedResult,
        .rejected => |rejection| {
            try testing.expectEqualStrings("policy_context_failed", rejection.code);
            try testing.expect(std.mem.indexOf(u8, rejection.message, "baseline") != null);
        },
    }
}

test "proof identity binds ordered candidates and full read set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/handler.ts", .data = "export function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(\"old\"); }\n" });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    var prepared = try change_set.prepare(testing.allocator, root, .{
        .file = "src/handler.ts",
        .content = "export function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(\"new\"); }\n",
    });
    defer prepared.deinit(testing.allocator);
    var snapshot = try workspace_snapshot.Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);
    var first = try prove(testing.allocator, &prepared, &snapshot);
    defer first.deinit(testing.allocator);
    if (first != .accepted) return error.TestUnexpectedResult;
    const first_id = first.accepted.proof_id;

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/unrelated.ts", .data = "export const marker = 1;\n" });
    var updated_snapshot = try workspace_snapshot.Snapshot.capture(testing.allocator, &prepared);
    defer updated_snapshot.deinit(testing.allocator);
    var second = try prove(testing.allocator, &prepared, &updated_snapshot);
    defer second.deinit(testing.allocator);
    if (second != .accepted) return error.TestUnexpectedResult;
    try testing.expect(!std.mem.eql(u8, &first_id, &second.accepted.proof_id));
}

/// Each handler carries one ZTS626 advisory: a front-end diagnostic that does
/// not halt analysis, so the skip_contract fallback has something to report.
const advisory_prefix =
    "structural Command = { kind: \"echo\", text: string } | { kind: \"ping\", text: string };\n" ++
    "function run(cmd: Command): string {\n" ++
    "  return match (cmd) {\n" ++
    "    when { kind: \"echo\" }: cmd.text\n" ++
    "    when { kind: \"ping\" }: \"pong\"\n" ++
    "  };\n" ++
    "}\n";

const handler_body =
    "export function handler(req: Request): Proof<Response, \"state_isolated\"> {\n" ++
    "  const cmd: Command = { kind: \"echo\", text: \"hi\" };\n";

/// Contract analysis refuses this handler with MissingSqlSchema when the
/// project has no sqlite schema.
const sql_advisory_handler = "import { sql } from \"zttp:sql\";\n" ++ advisory_prefix ++ handler_body ++
    "  sql(\"q\", \"SELECT id FROM users WHERE id = :id\");\n" ++
    "  return Response.text(run(cmd));\n}\n";

const plain_advisory_handler = advisory_prefix ++ handler_body ++
    "  return Response.text(run(cmd));\n}\n";

/// Collect check diagnostics for one handler written into a fresh temporary
/// project that has no sqlite schema.
fn collectForSource(allocator: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Diagnostic)) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/handler.ts", .data = source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const handler_path = try std.fs.path.join(allocator, &.{ root, "src/handler.ts" });
    defer allocator.free(handler_path);
    _ = try collectCheckDiagnostics(allocator, out, root, handler_path, null, null, false);
}

test "a failed full analysis is recorded beside the fallback diagnostics" {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(testing.allocator, &diagnostics);
    try collectForSource(testing.allocator, sql_advisory_handler, &diagnostics);

    var incomplete: ?Diagnostic = null;
    var fallback_advisories: usize = 0;
    for (diagnostics.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "analysis_incomplete")) incomplete = diagnostic;
        if (std.mem.eql(u8, diagnostic.code, "ZTS626")) fallback_advisories += 1;
    }
    try testing.expectEqual(@as(usize, 1), fallback_advisories);
    const entry = incomplete orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("src/handler.ts", entry.file);
    try testing.expectEqualStrings("error", entry.severity);
    try testing.expectEqualStrings("MissingSqlSchema", entry.message);
}

test "only a new failed full analysis rejects an edit" {
    var baseline: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(testing.allocator, &baseline);
    var same_failure: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(testing.allocator, &same_failure);
    var clean: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(testing.allocator, &clean);
    // Two temporary projects have different roots, so the entries match only
    // when the file is recorded relative to its root.
    try collectForSource(testing.allocator, sql_advisory_handler, &baseline);
    try collectForSource(testing.allocator, sql_advisory_handler, &same_failure);
    try collectForSource(testing.allocator, plain_advisory_handler, &clean);

    try testing.expect(firstNewDiagnostic(baseline.items, same_failure.items) == null);
    const rejected = firstNewDiagnostic(clean.items, baseline.items) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("analysis_incomplete", rejected.code);
}

/// Prove an edit that replaces `src/handler.ts`. The caller owns the result.
fn replaceHandlerAndProve(baseline_source: []const u8, candidate_source: []const u8) !Result {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\"}",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/handler.ts", .data = baseline_source });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    var prepared = try change_set.prepare(testing.allocator, root, .{ .file = "src/handler.ts", .content = candidate_source });
    defer prepared.deinit(testing.allocator);
    var snapshot = try workspace_snapshot.Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);
    return prove(testing.allocator, &prepared, &snapshot);
}

/// Whether the aggregate proof rejects an edit that replaces `src/handler.ts`.
fn replacedHandlerIsRejected(baseline_source: []const u8, candidate_source: []const u8) !bool {
    var result = try replaceHandlerAndProve(baseline_source, candidate_source);
    defer result.deinit(testing.allocator);
    return result == .rejected;
}

test "aggregate proof rejects an emptied handler whose baseline already has ZTS500" {
    // ZTS310 and ZTS500 in the baseline: an empty candidate with fewer
    // diagnostics must not pass as a sub-multiset of them.
    try testing.expect(try replacedHandlerIsRejected(
        "let count = 0;\n" ++
            "structural Guard<T> = Proof<T, \"state_isolated\">;\n" ++
            "function handler(req: Request): Guard<Response> {\n" ++
            "  count = count + 1;\n" ++
            "  return Response.json({ count: count });\n}\n",
        "",
    ));
    // No capsule: the baseline's ZTS500 message equals the one an empty file gets.
    try testing.expect(try replacedHandlerIsRejected(
        "export function handler(req: Request): Response { return Response.text(\"old\"); }\n",
        "",
    ));
}

test "aggregate proof rejects a lost handler when both sides stop before the contract" {
    // A type error stops the check before the contract on both sides, so
    // neither side has a contract to compare handler lines.
    try testing.expect(try replacedHandlerIsRejected(
        "const n: number = \"x\";\n" ++
            "function handler(req: Request): Response { return Response.text(\"old\"); }\n",
        "const n: number = \"x\";\n" ++
            "function helper(): string { return \"old\"; }\n",
    ));
}

const handler_without_imports =
    "export function handler(req: Request): Response {\n  return Response.text(\"old\");\n}\n";

fn handlerWithMissingImport(comptime text: []const u8) []const u8 {
    return "import { f } from \"./missing.ts\";\n" ++
        "export function handler(req: Request): Response {\n  return Response.text(\"" ++ text ++ "\");\n}\n";
}

test "aggregate proof accepts an edit when both sides carry the same module graph refusal" {
    // Each side of the proof has its own scratch root. The refusal must read
    // the same on both, or a refusal that the edit did not add rejects the edit.
    var result = try replaceHandlerAndProve(handlerWithMissingImport("old"), handlerWithMissingImport("new"));
    defer result.deinit(testing.allocator);
    try testing.expect(result == .accepted);
}

test "aggregate proof reports a new module graph refusal by its workspace path" {
    var result = try replaceHandlerAndProve(handler_without_imports, handlerWithMissingImport("new"));
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("ZTS063", result.rejected.code);
    try testing.expectEqualStrings(
        "aggregate proof rejected src/handler.ts: ZTS063: Module 'src/handler.ts' imports './missing.ts', " ++
            "but that file cannot be read. Check the path and the file name.",
        result.rejected.message,
    );
}

test "aggregate proof reports a swapped env var as a removal and an addition" {
    var result = try replaceHandlerAndProve(
        "import { env } from \"zttp:env\";\n" ++
            "export function handler(req: Request): Response {\n" ++
            "  const greeting = env(\"OLD_NAME\");\n" ++
            "  if (greeting !== undefined) {\n    return Response.text(\"set\");\n  }\n" ++
            "  return Response.text(\"old\");\n}\n",
        "import { env } from \"zttp:env\";\n" ++
            "export function handler(req: Request): Response {\n" ++
            "  const greeting = env(\"NEW_NAME\");\n" ++
            "  if (greeting !== undefined) {\n    return Response.text(\"set\");\n  }\n" ++
            "  return Response.text(\"old\");\n}\n",
    );
    defer result.deinit(testing.allocator);
    const changes = result.accepted.contract_changes orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqual(ContractChange.Kind.env, changes[0].kind);
    try testing.expectEqual(false, changes[0].added);
    try testing.expectEqualStrings("OLD_NAME", changes[0].text);
    try testing.expectEqual(ContractChange.Kind.env, changes[1].kind);
    try testing.expectEqual(true, changes[1].added);
    try testing.expectEqualStrings("NEW_NAME", changes[1].text);
}

test "aggregate proof reports a dropped env var and its capabilities as removals" {
    var result = try replaceHandlerAndProve(
        "import { env } from \"zttp:env\";\n" ++
            "export function handler(req: Request): Response {\n" ++
            "  const name = env(\"APP_NAME\");\n" ++
            "  if (name !== undefined) {\n    return Response.text(\"named\");\n  }\n" ++
            "  return Response.text(\"none\");\n}\n",
        "export function handler(req: Request): Response {\n" ++
            "  return Response.text(\"none\");\n}\n",
    );
    defer result.deinit(testing.allocator);
    const changes = result.accepted.contract_changes orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqual(ContractChange.Kind.env, changes[0].kind);
    try testing.expectEqual(false, changes[0].added);
    try testing.expectEqualStrings("APP_NAME", changes[0].text);
    try testing.expectEqual(ContractChange.Kind.capability, changes[1].kind);
    try testing.expectEqual(false, changes[1].added);
    try testing.expectEqualStrings("env", changes[1].text);
    try testing.expectEqual(ContractChange.Kind.capability, changes[2].kind);
    try testing.expectEqual(false, changes[2].added);
    try testing.expectEqualStrings("policy_check", changes[2].text);
}

test "aggregate proof reports a swapped router route as a removal and an addition" {
    var result = try replaceHandlerAndProve(
        "import { routerMatch } from \"zttp:router\";\n" ++
            "function getHome(req: Request): Response {\n  return Response.text(\"home\");\n}\n" ++
            "function getOld(req: Request): Response {\n  return Response.text(\"old\");\n}\n" ++
            "const routes = {\n  \"GET /\": getHome,\n  \"GET /old\": getOld,\n};\n" ++
            "export function handler(req: Request): Response {\n" ++
            "  const found = routerMatch(routes, req);\n" ++
            "  if (found !== undefined) {\n    return found.handler(req);\n  }\n" ++
            "  return Response.json({ error: \"Not Found\" }, { status: 404 });\n}\n",
        "import { routerMatch } from \"zttp:router\";\n" ++
            "function getHome(req: Request): Response {\n  return Response.text(\"home\");\n}\n" ++
            "function getNew(req: Request): Response {\n  return Response.text(\"new\");\n}\n" ++
            "const routes = {\n  \"GET /\": getHome,\n  \"GET /new\": getNew,\n};\n" ++
            "export function handler(req: Request): Response {\n" ++
            "  const found = routerMatch(routes, req);\n" ++
            "  if (found !== undefined) {\n    return found.handler(req);\n  }\n" ++
            "  return Response.json({ error: \"Not Found\" }, { status: 404 });\n}\n",
    );
    defer result.deinit(testing.allocator);
    const changes = result.accepted.contract_changes orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqual(ContractChange.Kind.route, changes[0].kind);
    try testing.expectEqual(false, changes[0].added);
    try testing.expectEqualStrings("GET /old", changes[0].text);
    try testing.expectEqual(ContractChange.Kind.route, changes[1].kind);
    try testing.expectEqual(true, changes[1].added);
    try testing.expectEqualStrings("GET /new", changes[1].text);
}

test "aggregate proof reports no contract change for an unchanged surface" {
    var result = try replaceHandlerAndProve(
        handler_without_imports,
        "export function handler(req: Request): Response {\n  return Response.text(\"new\");\n}\n",
    );
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), (result.accepted.contract_changes orelse return error.TestUnexpectedResult).len);
}

fn envReadingHandler(comptime answer: []const u8) []const u8 {
    return "import { env } from \"zttp:env\";\n" ++
        "export function handler(req: Request): Response {\n" ++
        "  const name = env(\"APP_NAME\");\n" ++
        "  if (name !== undefined) {\n    return Response.text(\"named\");\n  }\n" ++
        "  return Response.text(\"" ++ answer ++ "\");\n}\n";
}

/// Prove an edit of `src/handler.ts` in a project whose `zttp.json` has the given text. A non-null
/// `policy_source` becomes `policy.json`.
fn proveUnderConfig(zttp_json: []const u8, policy_source: ?[]const u8, baseline_source: []const u8, candidate_source: []const u8) !Result {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zttp.json", .data = zttp_json });
    if (policy_source) |text| try tmp.dir.writeFile(testing.io, .{ .sub_path = "policy.json", .data = text });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/handler.ts", .data = baseline_source });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    var prepared = try change_set.prepare(testing.allocator, root, .{ .file = "src/handler.ts", .content = candidate_source });
    defer prepared.deinit(testing.allocator);
    var snapshot = try workspace_snapshot.Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);
    return prove(testing.allocator, &prepared, &snapshot);
}

/// Prove an edit of `src/handler.ts` in a project whose `zttp.json` names `policy.json` with the given text.
fn proveUnderPolicy(policy_source: []const u8, baseline_source: []const u8, candidate_source: []const u8) !Result {
    return proveUnderConfig("{\"entry\":\"src/handler.ts\",\"policy\":\"policy.json\"}", policy_source, baseline_source, candidate_source);
}

test "aggregate proof rejects an env read that a valid policy forbids" {
    var result = try proveUnderPolicy("{\"env\":{\"allow\":[]}}", handler_without_imports, envReadingHandler("none"));
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("POL001", result.rejected.code);
}

test "aggregate proof rejects a change set when the policy file does not parse" {
    var result = try proveUnderPolicy("{\"env\":{\"allow\":[]}", envReadingHandler("none"), envReadingHandler("changed"));
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("policy_context_failed", result.rejected.code);
    try testing.expectEqualStrings("capability policy policy.json does not parse: UnexpectedEndOfInput", result.rejected.message);
}

const recursive_handler_one =
    "function down(n: number): number { return down(n + 1); }\n" ++
    "export function handler(req: Request): Response { return Response.text(String(down(0))); }\n";
const recursive_handler_two =
    "function down(n: number): number { return down(n + 1); }\n" ++
    "export function handler(req: Request): Response { return Response.text(String(down(1))); }\n";
const plain_handler_changed =
    "export function handler(req: Request): Response {\n  return Response.text(\"new\");\n}\n";
const requires_cost_bounded = "{\"entry\":\"src/handler.ts\",\"requiredProperties\":[\"cost_bounded\"]}";

test "aggregate proof rejects a candidate that lacks a required property the baseline also lacks" {
    var result = try proveUnderConfig(requires_cost_bounded, null, recursive_handler_one, recursive_handler_two);
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("required_property_lost", result.rejected.code);
    try testing.expectEqualStrings(
        "zttp.json requiredProperties requires properties that the candidate does not prove: cost_bounded",
        result.rejected.message,
    );
}

test "aggregate proof accepts a candidate that proves the required property" {
    var result = try proveUnderConfig(requires_cost_bounded, null, handler_without_imports, plain_handler_changed);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .accepted);
}

test "aggregate proof rejects a candidate with no property result when properties are required" {
    // Both sides fail to parse in the same way, so no diagnostic is new and the
    // primary root has no property result.
    var result = try proveUnderConfig(
        requires_cost_bounded,
        null,
        "export function handler(req: Request): Response { return Response.text(\"a\");\n",
        "export function handler(req: Request): Response { return Response.text(\"b\");\n",
    );
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("required_property_lost", result.rejected.code);
    try testing.expectEqualStrings(
        "zttp.json requiredProperties requires proven properties, but the candidate has no property result for the primary handler",
        result.rejected.message,
    );
}

test "aggregate proof names the nearest valid property for an unknown required name" {
    var result = try proveUnderConfig(
        "{\"entry\":\"src/handler.ts\",\"requiredProperties\":[\"cost_bound\"]}",
        null,
        handler_without_imports,
        plain_handler_changed,
    );
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("required_property_lost", result.rejected.code);
    try testing.expectEqualStrings(
        "zttp.json requiredProperties names an unknown property cost_bound: did you mean `cost_bounded`?",
        result.rejected.message,
    );
}

fn snapshotWith(comptime value: bool) ui_payload.PropertiesSnapshot {
    var snapshot: ui_payload.PropertiesSnapshot = undefined;
    inline for (@typeInfo(ui_payload.PropertiesSnapshot).@"struct".field_names) |field| {
        @field(snapshot, field) = if (@FieldType(ui_payload.PropertiesSnapshot, field) == bool) value else null;
    }
    return snapshot;
}

test "every v1 spec name is a valid required property that a snapshot can prove" {
    for (zts.v1_spec_names) |name| {
        try testing.expectEqual(@as(?[]u8, null), try requiredPropertyProblem(testing.allocator, &.{name}, snapshotWith(true)));
    }
}

test "every v1 spec name is named when the candidate does not prove it" {
    for (zts.v1_spec_names) |name| {
        const message = try requiredPropertyProblem(testing.allocator, &.{name}, snapshotWith(false)) orelse return error.TestUnexpectedResult;
        defer testing.allocator.free(message);
        try testing.expect(std.mem.endsWith(u8, message, name));
    }
}

test "required properties name every missing property in file order" {
    const message = try requiredPropertyProblem(
        testing.allocator,
        &.{ "state_isolated", "cost_bounded", "fault_covered" },
        snapshotWith(false),
    ) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings(
        "zttp.json requiredProperties requires properties that the candidate does not prove: state_isolated, cost_bounded, fault_covered",
        message,
    );
}

test "required properties refuse a candidate that has no property result" {
    const message = try requiredPropertyProblem(testing.allocator, &.{"cost_bounded"}, null) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings(
        "zttp.json requiredProperties requires proven properties, but the candidate has no property result for the primary handler",
        message,
    );
}

test "an empty requiredProperties list refuses nothing" {
    try testing.expectEqual(@as(?[]u8, null), try requiredPropertyProblem(testing.allocator, &.{}, null));
}
