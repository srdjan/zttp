//! Shared `verify-paths` v1 envelope writer. See docs/zts-expert-contract.md.
//!
//! Diagnostics from `precompile.runCheckOnlyWithOptions` are serialized inside the loop
//! while the per-file CheckResult is still alive, so no cross-iteration
//! borrowed strings survive into the envelope.

const std = @import("std");
const zts = @import("zts");
const writeJsonString = zts.writeJsonString;
const project_config_mod = @import("project_config");
const precompile = @import("precompile.zig");
const json_diag = precompile.json_diag;
const expert_meta = @import("expert_meta.zig");

pub const VerifyPathsOutcome = struct {
    ok: bool,
};

pub const Diagnostic = json_diag.JsonDiagnostic;

/// Walk `paths`, run the full analysis per file, and invoke `ctx.emit(*const
/// Diagnostic)` for every violation (including synthesized ZTS000 entries for
/// files that fail to load). The diagnostic's string fields are only
/// guaranteed valid for the duration of the `emit` call; consumers that need
/// to persist them must copy inside the callback. `file` is normalized to the
/// caller-supplied argv path so temp-file checker paths stay invisible.
pub fn collect(
    scratch: std.mem.Allocator,
    paths: []const []const u8,
    ctx: anytype,
) !VerifyPathsOutcome {
    var has_errors = false;
    for (paths) |path| {
        var analysis_ctx = project_config_mod.discoverAnalysisContext(scratch, path, null) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const fake: Diagnostic = .{
                .code = zts.DiagnosticCatalog.driverCode(.compiler_io_failure),
                .severity = "error",
                .message = @errorName(err),
                .file = path,
                .line = 0,
                .column = 0,
                .suggestion = null,
            };
            try ctx.emit(&fake);
            has_errors = true;
            continue;
        };
        defer analysis_ctx.deinit(scratch);
        const policy_source = analysis_ctx.readPolicySource(scratch) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const fake: Diagnostic = .{
                .code = zts.DiagnosticCatalog.driverCode(.compiler_io_failure),
                .severity = "error",
                .message = @errorName(err),
                .file = path,
                .line = 0,
                .column = 0,
                .suggestion = null,
            };
            try ctx.emit(&fake);
            has_errors = true;
            continue;
        };
        defer if (policy_source) |src| scratch.free(src);

        var result = precompile.runCheckOnlyWithOptions(scratch, path, .{
            .sql_schema_path = analysis_ctx.sqlite,
            .policy_source = policy_source,
            .json_mode = true,
        }) catch |err| {
            const fake: Diagnostic = .{
                .code = zts.DiagnosticCatalog.driverCode(.compiler_io_failure),
                .severity = "error",
                .message = @errorName(err),
                .file = path,
                .line = 0,
                .column = 0,
                .suggestion = null,
            };
            try ctx.emit(&fake);
            has_errors = true;
            continue;
        };
        defer result.deinit(scratch);

        if (result.totalErrors() > 0) has_errors = true;

        for (result.json_diagnostics.items) |diag| {
            var with_file = diag;
            if (with_file.file.len == 0) with_file.file = path;
            try ctx.emit(&with_file);
        }
    }
    return .{ .ok = !has_errors };
}

/// Run full analysis on `paths` and write the v1 JSON envelope to `writer`.
/// `scratch` is used for per-file CheckResult allocations and an internal
/// violations buffer; neither outlives this call. The writer's bytes are
/// the authoritative contract — see docs/zts-expert-contract.md.
pub fn writeJsonEnvelope(
    scratch: std.mem.Allocator,
    writer: anytype,
    paths: []const []const u8,
) !VerifyPathsOutcome {
    var vio_aw: std.Io.Writer.Allocating = .init(scratch);
    defer vio_aw.deinit();

    var emitter = JsonEmitter{ .writer = &vio_aw.writer, .first = true };
    const outcome = try collect(scratch, paths, &emitter);

    try writer.print(
        "{{\"ok\":{s},\"policy_version\":\"{s}\",\"policy_hash\":\"{s}\",\"checked_files\":[",
        .{
            if (outcome.ok) "true" else "false",
            expert_meta.policy_version,
            zts.policyHash(),
        },
    );
    for (paths, 0..) |path, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, path);
    }
    try writer.writeAll("],\"violations\":[");
    try writer.writeAll(vio_aw.written());
    try writer.writeAll("]}\n");

    return outcome;
}

const JsonEmitter = struct {
    writer: *std.Io.Writer,
    first: bool,

    pub fn emit(self: *JsonEmitter, diag: *const Diagnostic) !void {
        if (!self.first) try self.writer.writeByte(',');
        self.first = false;
        try json_diag.writeDiagnosticJson(self.writer, diag);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeJsonEnvelope with empty paths emits an ok v1 envelope" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const outcome = try writeJsonEnvelope(std.testing.allocator, &aw.writer, &.{});
    const s = aw.written();

    try std.testing.expect(outcome.ok);
    try std.testing.expect(std.mem.find(u8, s, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, s, "\"checked_files\":[]") != null);
    try std.testing.expect(std.mem.find(u8, s, "\"violations\":[]") != null);
    try std.testing.expect(std.mem.find(u8, s, "\"policy_version\":\"2026.04.2\"") != null);
    try std.testing.expectEqual(@as(u8, '\n'), s[s.len - 1]);
}

test "writeJsonEnvelope on a non-existent path emits a ZTS000 envelope" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const paths = [_][]const u8{"/tmp/zts-verify-paths-core-not-real.ts"};
    const outcome = try writeJsonEnvelope(std.testing.allocator, &aw.writer, &paths);
    const s = aw.written();

    try std.testing.expect(!outcome.ok);
    try std.testing.expect(std.mem.find(u8, s, "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, s, "\"ZTS000\"") != null);
    try std.testing.expect(std.mem.find(u8, s, "/tmp/zts-verify-paths-core-not-real.ts") != null);
}

test "writeJsonEnvelope surfaces ZTS400 for a flow violation" {
    // The agent-facing `verify-paths` surface must include flow_checker
    // diagnostics, not only the bool/type/verifier cascade. Before flow
    // diagnostics were wired into json_diagnostics, this same handler
    // would produce `"ok":true,"violations":[]`.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Annotated: the strict checker now rejects an unannotated handler with
    // ZTS601 before flow analysis runs, so the unannotated form this test used
    // to carry never reached the flow diagnostic it exists to check.
    const fixture =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  const secret = env("SECRET_KEY");
        \\  if (secret !== undefined) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "leak.ts", .data = fixture });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try tmp_dir.dir.realPathFile(std.testing.io, "leak.ts", &path_buf);
    const abs_path = path_buf[0..abs_len];
    const paths = [_][]const u8{abs_path};

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const outcome = try writeJsonEnvelope(allocator, &aw.writer, &paths);
    const s = aw.written();

    try std.testing.expect(!outcome.ok);
    try std.testing.expect(std.mem.find(u8, s, "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, s, "\"ZTS400\"") != null);
    try std.testing.expect(std.mem.find(u8, s, "secret data flows into response body") != null);
}

test "writeJsonEnvelope canonical diagnostics make ok false" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const fixture =
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  let a = 1;
        \\  return Response.json({ a: a });
        \\}
    ;
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "canonical.ts", .data = fixture });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try tmp_dir.dir.realPathFile(std.testing.io, "canonical.ts", &path_buf);
    const abs_path = path_buf[0..abs_len];
    const paths = [_][]const u8{abs_path};

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const outcome = try writeJsonEnvelope(allocator, &aw.writer, &paths);
    const s = aw.written();

    try std.testing.expect(!outcome.ok);
    try std.testing.expect(std.mem.find(u8, s, "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, s, "\"ZTS604\"") != null);
    try std.testing.expect(std.mem.find(u8, s, "\"severity\":\"error\"") != null);
}

test "writeJsonEnvelope canonical clean file keeps ok true" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const fixture =
        \\function parse(x: number): number { return x; }
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "canonical.ts", .data = fixture });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try tmp_dir.dir.realPathFile(std.testing.io, "canonical.ts", &path_buf);
    const abs_path = path_buf[0..abs_len];
    const paths = [_][]const u8{abs_path};

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const outcome = try writeJsonEnvelope(allocator, &aw.writer, &paths);
    const s = aw.written();

    try std.testing.expect(outcome.ok);
    try std.testing.expect(std.mem.find(u8, s, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, s, "\"ZTS608\"") == null);
}

test "writeJsonEnvelope preserves imported module file attribution" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "entry.ts",
        .data =
        \\import { greet } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text(greet());
        \\}
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "dep.ts",
        .data =
        \\export function greet(): string {
        \\  let msg = "hi";
        \\  return msg;
        \\}
        ,
    });

    const entry_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "entry.ts", allocator);
    defer allocator.free(entry_path);
    const dep_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "dep.ts", allocator);
    defer allocator.free(dep_path);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const outcome = try writeJsonEnvelope(allocator, &aw.writer, &.{entry_path});
    try std.testing.expect(!outcome.ok);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, aw.written(), .{});
    defer parsed.deinit();
    const violations = parsed.value.object.get("violations").?.array.items;
    try std.testing.expect(violations.len >= 1);
    var saw_dep = false;
    for (violations) |v| {
        if (std.mem.eql(u8, v.object.get("file").?.string, dep_path)) saw_dep = true;
    }
    try std.testing.expect(saw_dep);
}
