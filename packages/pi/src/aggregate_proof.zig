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

pub const AggregateProof = struct {
    proof_id: [64]u8,
    policy_hash: [64]u8,
    read_set_digest: [64]u8,
    proof_roots: [][]u8,
    diagnostics: []Diagnostic,
    system_proven: bool,
    baseline_primary_properties: ?ui_payload.PropertiesSnapshot = null,
    primary_properties: ?ui_payload.PropertiesSnapshot = null,

    pub fn deinit(self: *AggregateProof, allocator: std.mem.Allocator) void {
        for (self.proof_roots) |root| allocator.free(root);
        allocator.free(self.proof_roots);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
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

    fn deinit(self: *ContextPaths, allocator: std.mem.Allocator) void {
        if (self.schema_relative) |path| allocator.free(path);
        if (self.policy_relative) |path| allocator.free(path);
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
    for (roots, 0..) |relative_root, root_index| {
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

        if (fileExists(allocator, before_path)) {
            const properties = collectCheckDiagnostics(
                allocator,
                &baseline_diagnostics,
                baseline.root,
                before_path,
                before_schema,
                before_policy,
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                return rejectedFmt(allocator, "baseline_analysis_failed", "baseline analysis failed for {s}: {s}", .{ relative_root, @errorName(err) });
            };
            if (root_index == 0) baseline_primary_properties = properties;
        }
        const properties = collectCheckDiagnostics(
            allocator,
            &candidate_diagnostics,
            candidate.root,
            after_path,
            after_schema,
            after_policy,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            return rejectedFmt(allocator, "candidate_analysis_failed", "candidate analysis failed for {s}: {s}", .{ relative_root, @errorName(err) });
        };
        if (root_index == 0) primary_properties = properties;
    }

    if (firstNewDiagnostic(baseline_diagnostics.items, candidate_diagnostics.items)) |diagnostic| {
        return rejectedFmt(
            allocator,
            diagnostic.code,
            "aggregate proof rejected {s}: {s}: {s}",
            .{ diagnostic.file, diagnostic.code, diagnostic.message },
        );
    }

    const policy_hash = zts.policyHash();
    const read_set_digest = digestReadSet(snapshot);
    const proof_id = digestProof(prepared, snapshot, roots, false);
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
        } else {
            if (!optionalEqual(result.schema_relative, schema_relative)) return error.InconsistentSqlContext;
            if (!optionalEqual(result.policy_relative, policy_relative)) return error.InconsistentPolicyContext;
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
    if (front_end.parse_errors > 0) return;
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

fn collectCheckDiagnostics(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Diagnostic),
    materialized_root: []const u8,
    handler_path: []const u8,
    schema_path: ?[]const u8,
    policy_source: ?[]const u8,
) !?ui_payload.PropertiesSnapshot {
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
        return if (fallback.properties) |properties| proof_enrichment.propertiesSnapshot(properties) else null;
    };
    defer check.deinit(allocator);
    try appendCheckDiagnostics(allocator, out, materialized_root, check.json_diagnostics.items);
    return if (check.properties) |properties| proof_enrichment.propertiesSnapshot(properties) else null;
}

fn appendCheckDiagnostics(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Diagnostic),
    materialized_root: []const u8,
    diagnostics: anytype,
) !void {
    for (diagnostics) |diagnostic| {
        const file = if (std.fs.path.isAbsolute(diagnostic.file) and common.isPathInsideRoot(materialized_root, diagnostic.file))
            common.relativeToRoot(materialized_root, diagnostic.file)
        else
            diagnostic.file;
        try appendDiagnostic(allocator, out, file, diagnostic.code, diagnostic.severity, diagnostic.message);
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
    _ = try collectCheckDiagnostics(allocator, out, root, handler_path, null, null);
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
