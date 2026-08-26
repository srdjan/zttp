//! Edit simulation engine for diff-aware violation analysis.
//!
//! Runs the full analysis pipeline on proposed file content and optionally
//! compares against the original to determine which violations are new.
//! Used by the `zts edit-simulate` CLI subcommand and the interactive
//! expert loop.

const std = @import("std");
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
    /// Optional system manifest for cross-handler type and policy context.
    system_path: ?[]const u8 = null,
    /// Capability policy JSON, as source rather than a path. Boundary callers
    /// that own a workspace read it from the `policy` entry in the nearest
    /// `zttp.json`; the defect-seed suite supplies it inline for a handler that
    /// exists only as a string. When null, no policy is enforced and the POL
    /// rules cannot fire - the same shape as a project that declares none.
    policy_source: ?[]const u8 = null,
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
    // When the caller passes no explicit schema or system manifest, discover
    // the project's from the edited file exactly as the CLI boundary (`run`,
    // `zts check`) does. Without this, every in-process tool that simulates a
    // zttp:sql handler (the repair-apply lane, review patch, ast rewrite,
    // feature apply) throws MissingSqlSchema even though the project has a
    // configured schema. The veto and CLI already pass non-null paths, so
    // discovery only runs for the path-less in-process callers.
    var discovered: ProjectPaths = if (input.sql_schema_path == null or input.system_path == null)
        discoverProjectPaths(allocator, input.file) catch ProjectPaths{}
    else
        .{};
    defer discovered.deinit(allocator);
    const schema_path = input.sql_schema_path orelse discovered.sqlite;
    const system_path = input.system_path orelse discovered.system;

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
            .system_path = system_path,
            .policy_source = input.policy_source,
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
                .system_path = system_path,
                .policy_source = input.policy_source,
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
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    try runWithArgsWriter(allocator, argv, &aw.writer);

    buf = aw.toArrayList();
    if (buf.items.len > 0) {
        _ = std.c.write(std.c.STDOUT_FILENO, buf.items.ptr, buf.items.len);
    }
}

fn runWithArgsWriter(allocator: std.mem.Allocator, argv: []const []const u8, writer: *std.Io.Writer) !void {
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
            printHelp();
            return;
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

    // The CLI owns project context, so it resolves both paths here and
    // `simulate` walks nothing. Root at the edited file: resolving the schema
    // from cwd while leaving system_path null made `simulate` walk a second
    // time from `input.file`, so one invocation could analyze against two
    // different zttp.json files.
    //
    // Fall back to cwd when the file is outside every project. `findStartDir`
    // already reverts to cwd for a path with no dirent, which is the ordinary
    // `--stdin-json` case for a handler that does not exist yet, but a staged
    // draft at /tmp or an absolute path in a sibling checkout does exist and
    // would otherwise walk to `/` and return nothing - turning every zttp:sql
    // simulation into MissingSqlSchema.
    var paths = discoverProjectPaths(allocator, input.file) catch ProjectPaths{};
    if (paths.sqlite == null and paths.system == null) {
        paths.deinit(allocator);
        paths = discoverProjectPaths(allocator, null) catch ProjectPaths{};
    }
    defer paths.deinit(allocator);
    input.sql_schema_path = paths.sqlite;
    input.system_path = paths.system;

    var result = try simulate(allocator, input);
    defer result.deinit(allocator);

    try writeResultJson(writer, &result);
}

/// The two `zttp.json` entries the analyzer reads. Caller frees via `deinit`.
pub const ProjectPaths = struct {
    sqlite: ?[]u8 = null,
    system: ?[]u8 = null,
    policy: ?[]u8 = null,

    pub fn deinit(self: *ProjectPaths, allocator: std.mem.Allocator) void {
        if (self.sqlite) |p| allocator.free(p);
        if (self.system) |p| allocator.free(p);
        if (self.policy) |p| allocator.free(p);
        self.* = .{};
    }
};

/// Resolve the project's SQL schema and system manifest for analysis: the
/// `sqlite` and `system` entries in the nearest `zttp.json` walking up from
/// `start_path` (or cwd when null), resolved against the project root. This is
/// the same source `zttp dev`, `zttp test`, and `zttp doctor` pass to the
/// analyzer, and the same boundary `zts check` uses. A field is null when the
/// project exists but names no such entry.
///
/// Both come from one walk. Resolving them separately walked the ancestor
/// directories and parsed the same manifest twice for every simulated edit.
///
/// A manifest that cannot be read or does not parse is an ERROR, not a null
/// path. Callers that would rather analyze without project context say so at
/// their own call site with `catch`; a caller that publishes a verdict must
/// not be handed a silently weakened one. This is the fail-open class
/// AGENTS.md documents.
pub fn discoverProjectPaths(allocator: std.mem.Allocator, start_path: ?[]const u8) !ProjectPaths {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var project = try project_config_mod.discover(allocator, io, start_path);
    defer if (project) |*p| p.deinit(allocator);
    const cfg = if (project) |*p| p else return .{};
    var paths: ProjectPaths = .{ .sqlite = try cfg.resolvedSqlitePath(allocator) };
    errdefer paths.deinit(allocator);
    paths.system = try cfg.resolvedSystemPath(allocator);
    paths.policy = try cfg.resolvedPolicyPath(allocator);
    return paths;
}

/// Read the project's capability policy: the `policy` entry in the nearest
/// `zttp.json` walking up from `start_path`, resolved against the project root
/// and loaded. Returns null when there is no project, no `policy` entry, or the
/// file cannot be read. Caller frees.
///
/// One resolver for every boundary that owns project context - `zts check`,
/// the `edit-simulate` CLI, and the expert veto - for the reason
/// `discoverProjectSystemPath` already gives: a hand-written copy per caller is
/// how `check` and `edit-simulate` drifted into different verdicts for the same
/// handler.
///
/// An unreadable policy degrades to "no policy" rather than failing the run,
/// matching how a broken manifest degrades to schema-less analysis. A policy
/// that exists and will not PARSE is a diagnostic instead of a silence, and is
/// handled where the source is read.
pub fn discoverProjectPolicySource(allocator: std.mem.Allocator, start_path: ?[]const u8) ?[]u8 {
    var paths = discoverProjectPaths(allocator, start_path) catch return null;
    defer paths.deinit(allocator);
    const path = paths.policy orelse return null;
    return file_io.readFile(allocator, path, 1024 * 1024) catch null;
}

/// Single-path wrapper for the callers that analyze without a system manifest.
/// A broken manifest degrades to schema-less analysis here rather than failing
/// the edit, which is what these callers have always done. Caller frees the
/// returned slice.
pub fn discoverProjectSqlSchemaPath(allocator: std.mem.Allocator, start_path: ?[]const u8) ?[]u8 {
    var paths = discoverProjectPaths(allocator, start_path) catch return null;
    if (paths.system) |p| allocator.free(p);
    paths.system = null;
    if (paths.policy) |p| allocator.free(p);
    paths.policy = null;
    return paths.sqlite;
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

fn deleteTempFile(allocator: std.mem.Allocator, path: []const u8) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);
    _ = std.c.unlink(path_z);
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

fn printHelp() void {
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
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeResultJson empty result" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);

    const result = SimulateResult{};
    try writeResultJson(&aw.writer, &result);

    buf = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"total\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"violations\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"properties\"") == null);
}

test "writeResultJson includes properties when present" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);

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

    buf = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"properties\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"deterministic\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"injection_safe\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"state_isolated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"fault_covered\":false") != null);
    // Without an import forbidding it, behavioral read_only surfaces as declarable.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"read_only\":true") != null);
}

test "writeResultJson reports read_only as not-declarable under a forbidding import" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);

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

    buf = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"read_only\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"retry_safe\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"idempotent\":true") != null);
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

    const handler =
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var uniquifier: u8 = undefined;
    const addr = @intFromPtr(&uniquifier);
    const path = try std.fmt.allocPrint(allocator, "/tmp/zts-edit-sim-json-{x}.ts", .{addr});
    defer allocator.free(path);
    try file_io.writeFile(allocator, path, handler);
    defer deleteTempFile(allocator, path);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    // The redundant --json must be accepted (not error.InvalidArgument).
    try runWithArgsWriter(allocator, &.{ path, "--json" }, &aw.writer);

    buf = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"violations\"") != null);
}

test "simulate flags newly introduced canonical diagnostics" {
    const before =
        \\function parse(x: number): number { return x; }
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;
    const after =
        \\const parse = (x: number): number => x;
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;

    var result = try simulate(std.testing.allocator, .{
        .file = "handler.ts",
        .content = after,
        .before = before,
    });
    defer result.deinit(std.testing.allocator);

    var saw_608 = false;
    for (result.violations.items) |v| {
        if (std.mem.eql(u8, v.code, "ZTS608")) {
            saw_608 = true;
            try std.testing.expect(v.introduced_by_patch);
        }
    }
    try std.testing.expect(saw_608);
    try std.testing.expect(result.new_count > 0);
}

test "simulate preserves sibling module proof context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const before =
        \\import { apiToken, displayName } from "./lib/settings.ts";
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "no_secret_leakage"> {
        \\  if (apiToken() === undefined) return Response.json({ error: "unconfigured" }, { status: 503 });
        \\  return hole();
        \\}
    ;
    const after =
        \\import { apiToken, displayName } from "./lib/settings.ts";
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "no_secret_leakage"> {
        \\  if (apiToken() === undefined) return Response.json({ error: "unconfigured" }, { status: 503 });
        \\  return Response.json({ name: displayName() });
        \\}
    ;
    const settings =
        \\import { env } from "zttp:env";
        \\export structural ApiToken = string | undefined;
        \\export structural DisplayName = string;
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
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    try writeResultJson(&aw.writer, &result);
    buf = aw.toArrayList();
    try std.testing.expect(
        std.mem.indexOf(u8, buf.items, "\"repair_intent\":\"replace_compound_assign_with_explicit\"") != null,
    );
}
