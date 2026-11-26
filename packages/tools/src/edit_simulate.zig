//! Edit simulation engine for diff-aware violation analysis.
//!
//! Runs the full analysis pipeline on proposed file content and optionally
//! compares against the original to determine which violations are new.
//! Used by the `zts edit-simulate` CLI subcommand and the interactive
//! expert loop.

const std = @import("std");
const writeAllFd = @import("precompile_util.zig").writeAllFd;
const zts = @import("zts");
const precompile = @import("precompile.zig");
const project_config_mod = @import("project_config");
const json_diag = precompile.json_diag;
const file_io = zts.file_io;
const writeJsonString = zts.writeJsonString;
const HandlerProperties = zts.HandlerProperties;

/// Largest request body the stdin readers accept. Published in
/// `meta.payload.limits`.
pub const max_stdin_json_bytes: usize = 20 * 1024 * 1024;

pub const EditSimulateInput = struct {
    file: []const u8,
    content: []const u8,
    before: ?[]const u8 = null,
    /// SQL schema for zttp:sql query validation. Boundary callers that own
    /// project context (the expert veto, the edit-simulate CLI) resolve it
    /// via `discoverProjectPaths`; when null, zttp:sql edits fail analysis
    /// with MissingSqlSchema exactly like a schema-less `check`.
    sql_schema_path: ?[]const u8 = null,
    /// Capability policy JSON, as source rather than a path. Boundary callers
    /// that own a workspace read it from the `policy` entry in the nearest
    /// `zttp.json`; the defect-seed suite supplies it inline for a handler that
    /// exists only as a string. When null, no policy is enforced and the POL
    /// rules cannot fire - the same shape as a project that declares none.
    policy_source: ?[]const u8 = null,
    /// Optional ancestor boundary for project discovery (`zttp.json`).
    stop_at_dir: ?[]const u8 = null,
    // When either is null, simulation discovers it the way `zts check` does,
    // walking up from `file`. That walk is not purely file-rooted:
    // `project_config.findStartDir` reverts to process cwd for a path with no
    // dirent, which is the ordinary `--stdin-json` case for a handler that
    // does not exist on disk yet.
};

pub const SimulatedViolation = struct {
    code: []const u8,
    severity: []const u8,
    message: []const u8,
    help: ?[]const u8,
    line: u32,
    column: u32,
    introduced_by_patch: bool,
    /// The checker's typed repair primitive for this diagnostic, when it has
    /// one. `zts_expert_ast_rewrite` takes exactly this value as its `intent`
    /// argument, and its own end-to-end test describes the contract as "the
    /// agent reads the diagnostic's repair_intent and invokes the matching AST
    /// primitive" - but the diagnostic surface the agent reads never carried
    /// it, so the argument had to be guessed. A tag, not an allocation: the
    /// enum is copied by value and nothing here owns it.
    repair_intent: ?zts.RepairIntent = null,
};

pub const SimulateResult = struct {
    violations: std.ArrayListUnmanaged(SimulatedViolation) = .empty,
    total: u32 = 0,
    new_count: u32 = 0,
    preexisting_count: u32 = 0,
    /// Behavioral properties from contract extraction. Present only when the
    /// analysis pipeline reached the contract phase (no parse or type errors).
    /// `properties.read_only` is the BEHAVIORAL fact (no state mutations).
    properties: ?HandlerProperties = null,
    /// True when an imported module (zttp:sql / zttp:cache) forbids DECLARING
    /// read_only (ZTS501), even though the handler may be behaviorally read-only.
    /// The agent-facing HUD reports read_only as held only when behavioral AND
    /// not forbidden, so the agent is never told to declare a property the import
    /// would reject. The behavioral `properties.read_only` is left intact for the
    /// receipt and other proof consumers.
    read_only_forbidden_by_import: bool = false,

    pub fn deinit(self: *SimulateResult, allocator: std.mem.Allocator) void {
        for (self.violations.items) |v| {
            allocator.free(v.code);
            allocator.free(v.severity);
            allocator.free(v.message);
            if (v.help) |help| allocator.free(help);
        }
        self.violations.deinit(allocator);
    }
};

/// Run analysis on proposed content and optionally diff against before content.
pub fn simulate(
    allocator: std.mem.Allocator,
    input: EditSimulateInput,
) !SimulateResult {
    // When the caller passes no explicit schema, discover the project's paths
    // from the edited file exactly as the CLI boundary (`run`,
    // `zts check`) does. Without this, every in-process tool that simulates a
    // zttp:sql handler (the repair-apply lane, review patch, ast rewrite,
    // feature apply) throws MissingSqlSchema even though the project has a
    // configured schema. A caller that already owns the schema and policy
    // passes both and skips discovery.
    var discovered: ProjectPaths = if (input.sql_schema_path == null or
        input.policy_source == null)
        try discoverProjectPathsBounded(allocator, input.file, input.stop_at_dir)
    else
        .{};
    defer discovered.deinit(allocator);
    const schema_path = input.sql_schema_path orelse discovered.sqlite;
    const discovered_policy_source: ?[]u8 = if (input.policy_source != null)
        null
    else if (discovered.policy) |path|
        try file_io.readFile(allocator, path, 1024 * 1024)
    else
        null;
    defer if (discovered_policy_source) |source| allocator.free(source);
    const policy_source = input.policy_source orelse discovered_policy_source;

    // Analyze the proposed bytes under the original file identity. Writing
    // them to `/tmp` severed relative imports, so a valid sibling helper was
    // treated as an unknown external call and four Proof properties failed in
    // edit-simulate even though `zts check` accepted the same handler.
    var new_check = try precompile.runCheckOnlyFromSourceWithOptions(
        allocator,
        input.content,
        input.file,
        .{
            .sql_schema_path = schema_path,
            .json_mode = true,
            .policy_source = policy_source,
        },
    );
    defer new_check.deinit(allocator);

    var baseline_counts: ?std.AutoHashMapUnmanaged(ViolationKey, u32) = null;
    defer if (baseline_counts) |*bk| bk.deinit(allocator);

    if (input.before) |before_content| {
        var old_check = try precompile.runCheckOnlyFromSourceWithOptions(
            allocator,
            before_content,
            input.file,
            .{
                .sql_schema_path = schema_path,
                .json_mode = true,
                .policy_source = policy_source,
            },
        );
        defer old_check.deinit(allocator);

        baseline_counts = .empty;
        for (old_check.json_diagnostics.items) |diag| {
            try addViolationKeyCount(allocator, &baseline_counts.?, violationKey(&diag));
        }
    }

    var result = SimulateResult{
        .properties = new_check.properties,
        .read_only_forbidden_by_import = if (new_check.contract) |c|
            zts.spec_discharge.readOnlyForbiddenByImport(c.modules.items)
        else
            false,
    };
    errdefer result.deinit(allocator);

    for (new_check.json_diagnostics.items) |diag| {
        const is_new = if (baseline_counts) |*bk|
            !consumeViolationKeyCount(bk, violationKey(&diag))
        else
            true;

        const code = try allocator.dupe(u8, diag.code);
        errdefer allocator.free(code);
        const severity = try allocator.dupe(u8, diag.severity);
        errdefer allocator.free(severity);
        const message = try allocator.dupe(u8, diag.message);
        errdefer allocator.free(message);
        const help = if (diag.suggestion) |suggestion| try allocator.dupe(u8, suggestion) else null;
        errdefer if (help) |h| allocator.free(h);

        try result.violations.append(allocator, .{
            .repair_intent = diag.repair_intent,
            .code = code,
            .severity = severity,
            .message = message,
            .help = help,
            .line = diag.line,
            .column = diag.column,
            .introduced_by_patch = is_new,
        });

        result.total += 1;
        if (is_new) {
            result.new_count += 1;
        } else {
            result.preexisting_count += 1;
        }
    }

    return result;
}

/// Read EditSimulateInput from stdin JSON.
pub fn readStdinJson(allocator: std.mem.Allocator) !EditSimulateInput {
    const stdin_data = readAllStdin(allocator) catch |err| switch (err) {
        error.StdinTooLarge => return error.StdinTooLarge,
        else => return error.StdinReadFailed,
    };
    defer allocator.free(stdin_data);

    if (stdin_data.len == 0) return error.StdinReadFailed;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stdin_data, .{}) catch
        return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JsonParseError;
    const obj = parsed.value.object;

    const file_val = obj.get("file") orelse return error.InvalidInput;
    const content_val = obj.get("content") orelse return error.InvalidInput;
    if (file_val != .string or content_val != .string) return error.InvalidInput;

    const before_val = obj.get("before");
    const before: ?[]const u8 = if (before_val) |bv|
        (if (bv == .string) bv.string else null)
    else
        null;

    const file = try allocator.dupe(u8, file_val.string);
    errdefer allocator.free(file);
    const content = try allocator.dupe(u8, content_val.string);
    errdefer allocator.free(content);
    const owned_before = if (before) |b| try allocator.dupe(u8, b) else null;
    errdefer if (owned_before) |b| allocator.free(b);

    return .{
        .file = file,
        .content = content,
        .before = owned_before,
    };
}

/// Write SimulateResult as JSON to writer.
pub fn writeResultJson(writer: anytype, result: *const SimulateResult) !void {
    try writer.writeAll("{\"violations\":[");
    for (result.violations.items, 0..) |v, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"code\":");
        try writeJsonString(writer, v.code);
        try writer.writeAll(",\"severity\":");
        try writeJsonString(writer, v.severity);
        try writer.writeAll(",\"message\":");
        try writeJsonString(writer, v.message);
        try writer.writeAll(",\"line\":");
        try writer.print("{d}", .{v.line});
        try writer.writeAll(",\"column\":");
        try writer.print("{d}", .{v.column});
        try writer.writeAll(",\"introduced_by_patch\":");
        try writer.writeAll(if (v.introduced_by_patch) "true" else "false");
        if (v.help) |h| {
            try writer.writeAll(",\"suggestion\":");
            try writeJsonString(writer, h);
        }
        if (v.repair_intent) |intent| {
            try writer.writeAll(",\"repair_intent\":");
            try writeJsonString(writer, intent.asString());
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"summary\":{\"total\":");
    try writer.print("{d}", .{result.total});
    try writer.writeAll(",\"new\":");
    try writer.print("{d}", .{result.new_count});
    try writer.writeAll(",\"preexisting\":");
    try writer.print("{d}", .{result.preexisting_count});
    try writer.writeAll("}");
    if (result.properties) |p| {
        // read_only is reported as DECLARABLE here (behavioral AND not import-
        // forbidden): this HUD is what the agent reads to decide what Spec to
        // declare, and declaring read_only with a zttp:sql/cache import is a
        // ZTS501 error. The behavioral fact stays in `result.properties`.
        const read_only_declarable = p.read_only and !result.read_only_forbidden_by_import;
        try writer.print(",\"properties\":{{\"pure\":{},\"read_only\":{},\"deterministic\":{},\"retry_safe\":{},\"idempotent\":{},\"state_isolated\":{},\"injection_safe\":{},\"fault_covered\":{}}}", .{
            p.pure,
            read_only_declarable,
            p.deterministic,
            p.retry_safe,
            p.idempotent,
            p.state_isolated,
            p.injection_safe,
            p.fault_covered,
        });
    }
    try writer.writeAll("}\n");
}

/// CLI entry point for `zts edit-simulate`.
pub fn runWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const verdict_available = try runWithArgsWriter(allocator, argv, &aw.writer);

    const written = aw.written();
    if (written.len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, written);
    }
    if (!verdict_available) std.process.exit(1);
}

fn runWithArgsWriter(allocator: std.mem.Allocator, argv: []const []const u8, writer: *std.Io.Writer) !bool {
    var stdin_json = false;
    var handler_path: ?[]const u8 = null;
    var before_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--stdin-json")) {
            stdin_json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            // edit-simulate is JSON-by-default; accept a redundant --json so
            // IDE/CI callers that always pass it do not hit InvalidArgument.
            continue;
        }
        if (std.mem.eql(u8, arg, "--before")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            before_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            try printHelp();
            return true;
        }
        if (!std.mem.startsWith(u8, arg, "-") and handler_path == null) {
            handler_path = arg;
            continue;
        }
        return error.InvalidArgument;
    }

    var owned_content: ?[]const u8 = null;
    defer if (owned_content) |c| allocator.free(c);
    var owned_before: ?[]const u8 = null;
    defer if (owned_before) |b| allocator.free(b);
    var owned_file: ?[]const u8 = null;
    defer if (owned_file) |f| allocator.free(f);

    var input: EditSimulateInput = if (stdin_json) blk: {
        const parsed = try readStdinJson(allocator);
        owned_file = parsed.file;
        owned_content = parsed.content;
        if (parsed.before) |b| owned_before = b;
        break :blk parsed;
    } else blk: {
        const path = handler_path orelse return error.MissingArgument;
        owned_content = try file_io.readFile(allocator, path, 10 * 1024 * 1024);
        if (before_path) |bp| {
            owned_before = try file_io.readFile(allocator, bp, 10 * 1024 * 1024);
        }
        break :blk .{
            .file = path,
            .content = owned_content.?,
            .before = owned_before,
        };
    };

    // The CLI owns project context, so it resolves project paths here and
    // `simulate` walks nothing. Root at the edited file: resolving the schema
    // from cwd made `simulate` walk a second time from `input.file`, so one
    // invocation could analyze against two different zttp.json files.
    //
    // Fall back to cwd when the file is outside every project. `findStartDir`
    // already reverts to cwd for a path with no dirent, which is the ordinary
    // `--stdin-json` case for a handler that does not exist yet, but a staged
    // draft at /tmp or an absolute path in a sibling checkout does exist and
    // would otherwise walk to `/` and return nothing - turning every zttp:sql
    // simulation into MissingSqlSchema.
    var paths = discoverProjectPaths(allocator, input.file) catch {
        try writeProjectContextFailure(writer, input.file);
        return false;
    };
    if (!paths.found) {
        paths.deinit(allocator);
        paths = discoverProjectPaths(allocator, null) catch {
            try writeProjectContextFailure(writer, input.file);
            return false;
        };
    }
    defer paths.deinit(allocator);
    input.sql_schema_path = paths.sqlite;

    // The policy is read here rather than in `simulate`, for the same reason
    // the paths are: one walk per invocation, rooted at the edited file, so
    // this command and `zts check` cannot reach different verdicts for the
    // same handler.
    const policy_source = if (paths.policy) |path|
        file_io.readFile(allocator, path, 1024 * 1024) catch {
            try writeProjectContextFailure(writer, input.file);
            return false;
        }
    else
        null;
    defer if (policy_source) |src| allocator.free(src);
    input.policy_source = policy_source;

    var result = try simulate(allocator, input);
    defer result.deinit(allocator);

    try writeResultJson(writer, &result);
    return true;
}

fn writeProjectContextFailure(writer: anytype, file: []const u8) !void {
    try writer.writeAll("{\"violations\":[{\"code\":");
    try writeJsonString(writer, zts.DiagnosticCatalog.driverCode(.compiler_io_failure));
    try writer.writeAll(",\"severity\":\"error\",\"message\":");
    try writeJsonString(writer, "configured project analysis context could not be loaded");
    try writer.writeAll(",\"line\":1,\"column\":1,\"introduced_by_patch\":true,\"suggestion\":");
    try writeJsonString(writer, "repair zttp.json and restore its referenced analysis files");
    try writer.writeAll(",\"file\":");
    try writeJsonString(writer, file);
    try writer.writeAll("}],\"summary\":{\"total\":1,\"new\":1,\"preexisting\":0}}\n");
}

/// The `zttp.json` entries the analyzer reads. Caller frees via `deinit`.
pub const ProjectPaths = project_config_mod.AnalysisContext;

/// Resolve the project's SQL schema and capability policy for analysis.
pub fn discoverProjectPaths(allocator: std.mem.Allocator, start_path: ?[]const u8) !ProjectPaths {
    return discoverProjectPathsBounded(allocator, start_path, null);
}

pub fn discoverProjectPathsBounded(
    allocator: std.mem.Allocator,
    start_path: ?[]const u8,
    stop_at_dir: ?[]const u8,
) !ProjectPaths {
    return project_config_mod.discoverAnalysisContext(allocator, start_path, stop_at_dir);
}

pub fn discoverProjectPolicySource(allocator: std.mem.Allocator, start_path: ?[]const u8) !?[]u8 {
    var paths = try discoverProjectPaths(allocator, start_path);
    defer paths.deinit(allocator);
    return try paths.readPolicySource(allocator);
}

/// Single-path wrapper for callers that need only a SQL schema.
/// A broken manifest degrades to schema-less analysis here rather than failing
/// the edit, which is what these callers have always done. Caller frees the
/// returned slice.
pub fn discoverProjectSqlSchemaPath(allocator: std.mem.Allocator, start_path: ?[]const u8) ?[]u8 {
    var paths = discoverProjectPaths(allocator, start_path) catch return null;
    const sqlite = paths.sqlite;
    paths.sqlite = null;
    paths.deinit(allocator);
    return sqlite;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Value-type composite key for comparing violations. Line numbers are excluded
/// because edits shift them; duplicate occurrences are handled by multiset
/// counts instead of a plain set.
const ViolationKey = struct {
    code_hash: u64,
    msg_hash: u64,
};

fn violationKey(diag: *const json_diag.JsonDiagnostic) ViolationKey {
    return .{
        .code_hash = std.hash.Wyhash.hash(0, diag.code),
        .msg_hash = std.hash.Wyhash.hash(0, diag.message),
    };
}

fn addViolationKeyCount(
    allocator: std.mem.Allocator,
    counts: *std.AutoHashMapUnmanaged(ViolationKey, u32),
    key: ViolationKey,
) !void {
    const entry = try counts.getOrPut(allocator, key);
    if (entry.found_existing) {
        entry.value_ptr.* += 1;
    } else {
        entry.value_ptr.* = 1;
    }
}

fn consumeViolationKeyCount(
    counts: *std.AutoHashMapUnmanaged(ViolationKey, u32),
    key: ViolationKey,
) bool {
    const value = counts.getPtr(key) orelse return false;
    if (value.* == 0) return false;
    value.* -= 1;
    return true;
}

/// Read stdin to EOF, capped at `max_stdin_json_bytes`. Public so the v2
/// agent transport reads its request through the same capped reader.
pub fn readAllStdin(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &read_buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) break;
        if (buf.items.len + n > max_stdin_json_bytes) return error.StdinTooLarge;
        try buf.appendSlice(allocator, read_buf[0..n]);
    }
    return buf.toOwnedSlice(allocator);
}

fn printHelp() !void {
    const help =
        \\zts edit-simulate - simulate an edit and report violations
        \\
        \\Usage:
        \\  zts edit-simulate [handler.ts] [--before old.ts] [--stdin-json]
        \\
        \\Options:
        \\  --stdin-json    Read input as JSON from stdin: {"file", "content", "before"?}
        \\  --before FILE   Original file for diff-aware analysis
        \\
        \\zttp:sql queries validate against the project's SQL schema, discovered
        \\from the "sqlite" entry in the nearest zttp.json.
        \\
        \\Output: JSON with violations array and summary (total, new, preexisting).
        \\
    ;
    try writeAllFd(std.c.STDOUT_FILENO, help);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeResultJson empty result" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const result = SimulateResult{};
    try writeResultJson(&aw.writer, &result);

    const written = aw.written();
    try std.testing.expect(std.mem.find(u8, written, "\"total\":0") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"violations\":[]") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"properties\"") == null);
}

test "writeResultJson includes properties when present" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const result = SimulateResult{
        .properties = .{
            .pure = false,
            .read_only = true,
            .stateless = false,
            .retry_safe = true,
            .deterministic = true,
            .has_egress = false,
            .injection_safe = true,
            .state_isolated = true,
            .fault_covered = false,
        },
    };
    try writeResultJson(&aw.writer, &result);

    const written = aw.written();
    try std.testing.expect(std.mem.find(u8, written, "\"properties\"") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"deterministic\":true") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"injection_safe\":true") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"state_isolated\":true") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"fault_covered\":false") != null);
    // Without an import forbidding it, behavioral read_only surfaces as declarable.
    try std.testing.expect(std.mem.find(u8, written, "\"read_only\":true") != null);
}

test "writeResultJson reports read_only as not-declarable under a forbidding import" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    // A behaviorally read-only handler (a SELECT) whose zttp:sql import forbids
    // DECLARING read_only: the HUD the agent reads must show read_only:false so it
    // does not declare a property ZTS501 would reject. The other held properties
    // (retry_safe/idempotent) are unaffected.
    const result = SimulateResult{
        .properties = .{
            .pure = false,
            .read_only = true,
            .stateless = true,
            .retry_safe = true,
            .deterministic = true,
            .has_egress = false,
            .injection_safe = true,
            .state_isolated = true,
            .idempotent = true,
            .fault_covered = false,
        },
        .read_only_forbidden_by_import = true,
    };
    try writeResultJson(&aw.writer, &result);

    const written = aw.written();
    try std.testing.expect(std.mem.find(u8, written, "\"read_only\":false") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"retry_safe\":true") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"idempotent\":true") != null);
}

test "violationKey excludes line numbers" {
    const diag1 = json_diag.JsonDiagnostic{
        .code = "ZTS303",
        .severity = "error",
        .message = "unchecked result",
        .file = "handler.ts",
        .line = 10,
        .column = 4,
        .suggestion = null,
    };
    const diag2 = json_diag.JsonDiagnostic{
        .code = "ZTS303",
        .severity = "error",
        .message = "unchecked result",
        .file = "handler.ts",
        .line = 20,
        .column = 4,
        .suggestion = null,
    };

    const key1 = violationKey(&diag1);
    const key2 = violationKey(&diag2);

    try std.testing.expectEqual(key1.code_hash, key2.code_hash);
    try std.testing.expectEqual(key1.msg_hash, key2.msg_hash);
}

test "violation key counts preserve duplicate diagnostics" {
    var counts: std.AutoHashMapUnmanaged(ViolationKey, u32) = .empty;
    defer counts.deinit(std.testing.allocator);

    const key = ViolationKey{ .code_hash = 1, .msg_hash = 2 };
    try addViolationKeyCount(std.testing.allocator, &counts, key);
    try addViolationKeyCount(std.testing.allocator, &counts, key);

    try std.testing.expect(consumeViolationKeyCount(&counts, key));
    try std.testing.expect(consumeViolationKeyCount(&counts, key));
    try std.testing.expect(!consumeViolationKeyCount(&counts, key));
}

test "runWithArgs accepts redundant --json flag" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const handler =
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = handler });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
    defer allocator.free(path);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // The redundant --json must be accepted (not error.InvalidArgument).
    _ = try runWithArgsWriter(allocator, &.{ path, "--json" }, &aw.writer);

    try std.testing.expect(std.mem.find(u8, aw.written(), "\"violations\"") != null);
}

test "simulate flags newly introduced canonical diagnostics" {
    const before =
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const a = 1;
        \\  return Response.json({ a: a });
        \\}
    ;
    const after =
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  let a = 1;
        \\  return Response.json({ a: a });
        \\}
    ;

    var result = try simulate(std.testing.allocator, .{
        .file = "handler.ts",
        .content = after,
        .before = before,
    });
    defer result.deinit(std.testing.allocator);

    var saw_604 = false;
    var introduced: u32 = 0;
    for (result.violations.items) |v| {
        if (v.introduced_by_patch) introduced += 1;
        if (std.mem.eql(u8, v.code, "ZTS604")) {
            saw_604 = true;
            try std.testing.expect(v.introduced_by_patch);
        }
    }
    try std.testing.expect(saw_604);
    try std.testing.expect(introduced > 0);
    try std.testing.expectEqual(introduced, result.new_count);
}

test "simulate preserves sibling module proof context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const before =
        \\import { apiToken, displayName } from "./lib/settings.ts";
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "no_secret_leakage"> {
        \\  if (apiToken() === undefined) { return Response.json({ error: "unconfigured" }, { status: 503 }); }
        \\  return hole();
        \\}
    ;
    const after =
        \\import { apiToken, displayName } from "./lib/settings.ts";
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "no_secret_leakage"> {
        \\  if (apiToken() === undefined) { return Response.json({ error: "unconfigured" }, { status: 503 }); }
        \\  return Response.json({ name: displayName() });
        \\}
    ;
    const settings =
        \\import { env } from "zttp:env";
        \\export type ApiToken = string | undefined;
        \\export type DisplayName = string;
        \\export function apiToken(): ApiToken { return env("API_TOKEN"); }
        \\export function displayName(): DisplayName { return env("APP_NAME") ?? "unnamed"; }
    ;

    try tmp.dir.createDirPath(std.testing.io, "lib");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = before });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/settings.ts", .data = settings });

    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", std.testing.allocator);
    defer std.testing.allocator.free(handler_path);

    var result = try simulate(std.testing.allocator, .{
        .file = handler_path,
        .content = after,
        .before = before,
        // `displayName` returns `APP_NAME`, so the policy lists it in `env.public`.
        .policy_source = "{\"env\":{\"allow\":[\"API_TOKEN\",\"APP_NAME\"],\"public\":[\"APP_NAME\"]}}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), result.total);
    try std.testing.expectEqual(@as(u32, 0), result.new_count);
    const properties = result.properties orelse return error.MissingProperties;
    try std.testing.expect(properties.deterministic);
    try std.testing.expect(properties.read_only);
    try std.testing.expect(properties.retry_safe);
    try std.testing.expect(properties.idempotent);
}

test "simulate refuses a configured policy it cannot load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\",\"policy\":\"missing-policy.json\"}",
    });
    const source =
        \\function handler(req: Request): Guardrails<Response> {
        \\  return Response.text("ok");
        \\}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/handler.ts", .data = source });

    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/handler.ts", std.testing.allocator);
    defer std.testing.allocator.free(handler_path);

    try std.testing.expectError(error.FileNotFound, simulate(std.testing.allocator, .{
        .file = handler_path,
        .content = source,
    }));

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const verdict_available = try runWithArgsWriter(std.testing.allocator, &.{handler_path}, &aw.writer);
    const written = aw.written();
    try std.testing.expect(!verdict_available);
    try std.testing.expect(std.mem.find(u8, written, "missing-policy.json") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, written, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const violations = root.get("violations").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqualStrings("ZTS000", violations[0].object.get("code").?.string);
    const summary = root.get("summary").?.object;
    try std.testing.expectEqual(@as(i64, 1), summary.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.get("new").?.integer);
    try std.testing.expectEqual(@as(i64, 0), summary.get("preexisting").?.integer);
}

test "simulate reports an unmapped analyzer failure as ZTS000" {
    const source =
        \\import { sql } from "zttp:sql";
        \\sql("getUser", "SELECT id FROM users");
        \\function handler(req: Request): Response { return Response.text("ok"); }
    ;
    var result = try simulate(std.testing.allocator, .{
        .file = "handler.ts",
        .content = source,
        .sql_schema_path = "/nonexistent/zttp-unmapped-schema.sql",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), result.total);
    try std.testing.expectEqualStrings("ZTS000", result.violations.items[0].code);
    try std.testing.expect(result.properties == null);
}

test "simulate reports type resolution failures as ZTS000" {
    const source =
        \\const value: `` = "x";
        \\function handler(req: Request): Response { return Response.text("ok"); }
    ;
    var result = try simulate(std.testing.allocator, .{
        .file = "handler.ts",
        .content = source,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), result.total);
    try std.testing.expectEqualStrings("ZTS000", result.violations.items[0].code);
    try std.testing.expectEqualStrings("the analyzer stopped with error.UnresolvedTypeBinding", result.violations.items[0].message);
    try std.testing.expect(result.properties == null);
}

test "simulate vetoes a nonexistent virtual module export" {
    const source =
        \\import { requireJWT } from "zttp:auth";
        \\function handler(req: Request): Response {
        \\  return Response.json({ authenticated: true });
        \\}
    ;
    var result = try simulate(std.testing.allocator, .{
        .file = "handler.ts",
        .content = source,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.new_count);
    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqualStrings("ZTS207", result.violations.items[0].code);
    try std.testing.expect(result.violations.items[0].introduced_by_patch);
}

test "a repairable diagnostic carries its repair intent to the caller" {
    // `zts_expert_ast_rewrite` takes the intent as an argument and its own
    // end-to-end test describes the contract as "the agent reads the
    // diagnostic's repair_intent and invokes the matching AST primitive". The
    // diagnostic surface the agent reads never carried it, so the argument had
    // to be guessed, and across nineteen recorded corpus cases the tool was
    // called zero times.
    const source =
        \\export function handler(req: Request): Response {
        \\  let x = 1;
        \\  x += 1;
        \\  return Response.json({ x: x });
        \\}
    ;
    var result = try simulate(std.testing.allocator, .{ .file = "handler.ts", .content = source });
    defer result.deinit(std.testing.allocator);

    var saw: ?zts.RepairIntent = null;
    for (result.violations.items) |v| {
        if (std.mem.eql(u8, v.code, "ZTS613")) saw = v.repair_intent;
    }
    const intent = saw orelse return error.TestExpectedRepairIntent;
    try std.testing.expectEqual(zts.RepairIntent.replace_compound_assign_with_explicit, intent);

    // And it has to survive serialization, because the JSON is what the tool
    // returns as the model's text - the struct field alone reaches nobody.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeResultJson(&aw.writer, &result);
    try std.testing.expect(
        std.mem.find(u8, aw.written(), "\"repair_intent\":\"replace_compound_assign_with_explicit\"") != null,
    );
}

test "discoverProjectSqlSchemaPath frees required_properties and policy without leaking" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zttp.json",
        .data =
        \\{
        \\  "entry": "src/handler.ts",
        \\  "sqlite": "schema.sql",
        \\  "policy": "policy.json",
        \\  "requiredProperties": ["state_isolated", "deterministic"]
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/handler.ts", .data = "" });

    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/handler.ts", allocator);
    defer allocator.free(handler_path);

    const schema_path = discoverProjectSqlSchemaPath(allocator, handler_path) orelse return error.TestExpectedSchemaPath;
    defer allocator.free(schema_path);
    try std.testing.expect(std.mem.endsWith(u8, schema_path, "schema.sql"));
}

test "discoverProjectPaths marks found when zttp.json has neither sqlite nor policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\"}",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/handler.ts", .data = "" });

    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/handler.ts", allocator);
    defer allocator.free(handler_path);

    var paths = try discoverProjectPaths(allocator, handler_path);
    defer paths.deinit(allocator);
    try std.testing.expect(paths.found);
    try std.testing.expect(paths.sqlite == null);
    try std.testing.expect(paths.policy == null);
}
