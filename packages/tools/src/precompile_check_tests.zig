//! Tests of the CHECK facade, its import readers, and its fault coverage and termination claims.

const std = @import("std");
const pcc = @import("zttp_proof_checker");
const zts = @import("zts");
const ir = zts.parser;
const handler_contract = zts.handler_contract;
const json_diag = @import("json_diagnostics.zig");
const check_mod = @import("precompile_check.zig");
const CheckResult = check_mod.CheckResult;
const StageSet = check_mod.StageSet;
const formatProofCard = check_mod.formatProofCard;
const appendExportCapsuleDiagnostics = check_mod.appendExportCapsuleDiagnostics;
const imports_mod = @import("precompile_imports.zig");
const ImportReader = imports_mod.ImportReader;
const flowModulesForSingleModule = imports_mod.flowModulesForSingleModule;
const max_import_depth = imports_mod.max_import_depth;
const ImportedFile = imports_mod.ImportedFile;
const collectImportedFailableCalls = imports_mod.collectImportedFailableCalls;
const resolveCheckImportPath = imports_mod.resolveCheckImportPath;
const check_run_mod = @import("precompile_check_run.zig");
const runCheckOnlyFromSourceWithOptions = check_run_mod.runCheckOnlyFromSourceWithOptions;
const runCheckOnlyFromSourceWithPathAllocator = check_run_mod.runCheckOnlyFromSourceWithPathAllocator;
const runCheckOnlyWithOptions = check_run_mod.runCheckOnlyWithOptions;

const shared_analysis_clean_source =
    \\structural Guardrails<T> = Proof<T, "result_safe">;
    \\
    \\function handler(req: Request): Guardrails<Response> {
    \\  return Response.json({ ok: true });
    \\}
;

test "default check records its exact public stage set" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(
        allocator,
        shared_analysis_clean_source,
        "shared-analysis-default.ts",
        .{ .json_mode = true },
    );
    defer result.deinit(allocator);

    const expected = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    try std.testing.expectEqual(expected, result.stages_run);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(result.verify_ran);
    try std.testing.expect(result.contract != null);
}

test "skip_contract stops after the exact computed stage set" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(
        allocator,
        shared_analysis_clean_source,
        "shared-analysis-skip-contract.ts",
        .{
            .json_mode = true,
            .skip_contract = true,
        },
    );
    defer result.deinit(allocator);

    const expected = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    try std.testing.expectEqual(expected, result.stages_run);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(!result.verify_ran);
    try std.testing.expect(!result.results_safe);
    try std.testing.expect(!result.optionals_safe);
    try std.testing.expect(result.properties == null);
    try std.testing.expect(result.contract == null);
    try std.testing.expect(result.proof_trace_json == null);
}

test "shared check reports an unmapped analyzer failure as ZTS000" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sql } from "zttp:sql";
        \\sql("getUser", "SELECT id FROM users");
        \\function handler(req: Request): Response { return Response.text("ok"); }
    ;
    for ([_]bool{ false, true }) |json_mode| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = json_mode,
            .sql_schema_path = "/nonexistent/zttp-unmapped-schema.sql",
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try std.testing.expect(result.properties == null);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        const diagnostic = result.json_diagnostics.items[0];
        try std.testing.expectEqualStrings("ZTS000", diagnostic.code);
        try std.testing.expectEqualStrings("error", diagnostic.severity);
        try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "FileNotFound") != null);
        if (!json_mode) {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            formatProofCard(&writer.writer, &result, "handler.ts");
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.written(), "ZTS000"));
            try std.testing.expect(std.mem.indexOf(u8, writer.written(), "FileNotFound") != null);
        }
    }
}

test "runCheckOnly propagates path analysis allocation failure" {
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  const value = env("NAME") ?? "world";
        \\  return Response.text(value);
        \\}
    ;
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        runCheckOnlyFromSourceWithPathAllocator(
            std.testing.allocator,
            failing.allocator(),
            source,
            "path-analysis-entrypoint-oom.ts",
            .{},
        ),
    );
}

const AllocationImportReader = struct {
    file_count: usize,
    reads: usize = 0,

    fn read(raw: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *AllocationImportReader = @ptrCast(@alignCast(raw));
        self.reads += 1;
        const name = std.fs.path.basename(path);
        if (!std.mem.startsWith(u8, name, "lib") or !std.mem.endsWith(u8, name, ".ts")) return error.FileNotFound;
        const index = try std.fmt.parseInt(usize, name[3 .. name.len - 3], 10);
        if (index >= self.file_count) return error.FileNotFound;
        // Modules share one namespace, so each file binds its own helper name.
        if (index + 1 == self.file_count) return allocator.print("export function helper{d}(): string {{ return 'ok'; }}", .{index});
        return allocator.print("import {{ helper{d} }} from './lib{d}.ts'; export function helper{d}(): string {{ return helper{d}(); }}", .{ index + 1, index + 1, index, index + 1 });
    }
};

fn checkImportAllocationFixture(allocator: std.mem.Allocator, reader: *AllocationImportReader) !CheckResult {
    const source =
        \\import { helper0 } from "./lib0.ts";
        \\function handler(req: Request): Proof<Response, "canonical" | "cost_bounded"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    return runCheckOnlyFromSourceWithOptions(allocator, source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = .{ .context = reader, .read = AllocationImportReader.read },
    });
}

fn expectImportAllocationCleanup(file_count: usize, expected_reads: usize) !void {
    var baseline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer baseline_arena.deinit();
    var counted = std.testing.FailingAllocator.init(baseline_arena.allocator(), .{ .resize_fail_index = 0 });
    var reader: AllocationImportReader = .{ .file_count = file_count };
    var baseline = try checkImportAllocationFixture(counted.allocator(), &reader);
    {
        defer baseline.deinit(counted.allocator());
        try std.testing.expectEqual(@as(u32, 0), baseline.totalErrors());
        try std.testing.expectEqual(@as(u32, 1), baseline.paths_enumerated);
        // The module graph reads each file once. The fault scan then reads each
        // file again through the same reader.
        try std.testing.expectEqual(expected_reads, reader.reads);
        const contract = baseline.contract orelse return error.TestUnexpectedResult;
        const coverage = contract.fault_coverage orelse return error.TestUnexpectedResult;
        try std.testing.expect(coverage.analysis_complete);
        try std.testing.expectEqual(@as(u32, 0), coverage.unseen_calls);
    }
    try std.testing.expect(counted.alloc_index > 0);
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);

    // Accounting checks every release through CHECK's allocator. The arena
    // also reclaims a failed probe's storage before the next failure point.
    for (0..counted.alloc_index) |fail_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = fail_index, .resize_fail_index = 0 });
        var failed_reader: AllocationImportReader = .{ .file_count = file_count };
        if (checkImportAllocationFixture(failing.allocator(), &failed_reader)) |value| {
            var result = value;
            result.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        if (failing.allocated_bytes != failing.freed_bytes) {
            std.debug.print("CHECK import cleanup: files={d}, failure_index={d}\n", .{ file_count, fail_index });
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "CHECK releases allocations when the graph checks a sibling import" {
    try expectImportAllocationCleanup(1, 2);
}

test "CHECK releases allocations when the graph checks a chain of seven imports" {
    try expectImportAllocationCleanup(7, 14);
}

test "runCheckOnlyFromSource: helper reaching outside its Effects ceiling gets ZTS503" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): Effects<string, "env"> {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(digest("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "ceiling.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var saw_503 = false;
    var saw_505 = false;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind == .effect_undeclared and std.mem.eql(u8, d.spec_name, "crypto")) saw_503 = true;
        if (d.kind == .effect_over_declared and std.mem.eql(u8, d.spec_name, "env")) saw_505 = true;
    }
    try std.testing.expect(saw_503);
    try std.testing.expect(saw_505);
    try std.testing.expect(contract.function_effect_capsules.items.len >= 1);

    // `digest` declares "env" and calls sha256, which reaches "crypto".
    var digest_index: ?usize = null;
    for (contract.function_effect_capsules.items, 0..) |capsule, i| {
        if (std.mem.eql(u8, capsule.function, "digest")) digest_index = i;
    }
    const digest = contract.function_effect_capsules.items[digest_index orelse return error.TestUnexpectedResult];
    try std.testing.expectEqual(@as(usize, 1), digest.declared.items.len);
    try std.testing.expectEqualStrings("env", digest.declared.items[0]);
    var saw_crypto = false;
    for (digest.inferred.items) |name| {
        if (std.mem.eql(u8, name, "crypto")) saw_crypto = true;
    }
    try std.testing.expect(saw_crypto);
}

test "runCheckOnlyFromSource: helper exceeding handler Effects budget gets ZTS607" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): string {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "env"> {
        \\  return Response.text(digest("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "budget.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var saw_607 = false;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind == .helper_budget_exceeded) {
            saw_607 = true;
            try std.testing.expectEqualStrings("crypto", d.spec_name);
            try std.testing.expectEqualStrings("digest", d.function.?);
        }
    }
    try std.testing.expect(saw_607);
    // The handler's declared budget is recorded on the contract.
    try std.testing.expectEqual(@as(u8, 1), contract.capability_budget.len);
}

test "runCheckOnlyFromSource: canonical reused arrow helper fails strict check" {
    const allocator = std.testing.allocator;
    const source =
        \\const parse = (x: number): number => x;
        \\
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-arrow.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var n608: u32 = 0;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS608")) {
            n608 += 1;
            try std.testing.expectEqualStrings("error", d.severity);
        }
    }
    // One reused arrow helper, one diagnostic, counted as the only strict error.
    try std.testing.expectEqual(@as(u32, 1), n608);
    try std.testing.expectEqual(n608, result.strict_errors);
}

test "runCheckOnlyFromSource: one-way public helper effects diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\nominal Digest = string;
        \\
        \\export function digest(s: Digest): Digest {
        \\  const out: Digest = sha256(s);
        \\  return out;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  const seed: Digest = "x";
        \\  return Response.text(digest(seed));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-effects.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var n610: u32 = 0;
    var n611: u32 = 0;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS610")) {
            n610 += 1;
            try std.testing.expectEqualStrings("error", d.severity);
        }
        if (std.mem.eql(u8, d.code, "ZTS611")) n611 += 1;
    }
    // `digest` is the only exported helper. The handler declares no Spec, so the
    // default profile also owes it a Proof capsule (ZTS611). Each canonical
    // diagnostic adds one canonical error.
    try std.testing.expectEqual(@as(u32, 1), n610);
    try std.testing.expectEqual(@as(u32, 1), n611);
    try std.testing.expectEqual(n610 + n611, result.canonical_errors);
}

test "runCheckOnlyFromSource: one-way public helper proof diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\nominal Stable = string;
        \\
        \\export function stable(s: Stable): Stable {
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const seed: Stable = "x";
        \\  return Response.text(stable(seed));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-proof.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var n611: u32 = 0;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS611")) {
            n611 += 1;
            try std.testing.expectEqualStrings("error", d.severity);
        }
    }
    // `stable` is the only exported helper, so one diagnostic and one canonical error.
    try std.testing.expectEqual(@as(u32, 1), n611);
    try std.testing.expectEqual(n611, result.canonical_errors);
    try std.testing.expect(result.totalErrors() > 0);
}

test "runCheckOnlyFromSource: proof capsule diagnostic covers an unreachable exported helper" {
    const allocator = std.testing.allocator;
    // `unrelated` is exported and the handler never calls it. Export is what
    // the rule conditions on: the module's public surface owes its callers a
    // capsule whether or not this handler is one of them.
    const source =
        \\nominal Unrelated = string;
        \\
        \\export function unrelated(s: Unrelated): Unrelated {
        \\  return s;
        \\}
        \\
        \\function stable(s: string): string {
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(stable("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-unrelated-proof.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var n611: u32 = 0;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS611")) n611 += 1;
    }
    // Only `unrelated` is exported: `stable` is internal and owes no capsule.
    try std.testing.expectEqual(@as(u32, 1), n611);
    try std.testing.expectEqual(n611, result.canonical_errors);
}

test "runCheckOnlyFromSource: proof capsule diagnostic ignores non-capsule specs" {
    const allocator = std.testing.allocator;
    const source =
        \\nominal Stable = string;
        \\
        \\export function stable(s: Stable): Stable {
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  const seed: Stable = "x";
        \\  return Response.text(stable(seed));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-result-safe-proof.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    for (result.json_diagnostics.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.code, "ZTS611"));
    }
    try std.testing.expectEqual(@as(u32, 0), result.canonical_errors);
}

test "formatProofCard: a parse failure marks the stages that did not run as skipped" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, "const b = while;\n", "bad.ts", .{});
    defer result.deinit(allocator);
    try std.testing.expect(result.parse_errors > 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "bad.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Parse ") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "FAIL (") != null);
    for ([_][]const u8{ "Types ", "Sound mode ", "Strict ZigTS " }) |stage| {
        const at = std.mem.indexOf(u8, buf.items, stage) orelse return error.TestExpectedStageLine;
        const line_end = std.mem.indexOfScalarPos(u8, buf.items, at, '\n') orelse buf.items.len;
        try std.testing.expect(std.mem.endsWith(u8, buf.items[at..line_end], "SKIPPED (parse failed)"));
    }
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "OK") == null);
}

test "formatProofCard: canonical public helper diagnostics are visible in text mode" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\nominal Digest = string;
        \\
        \\export function digest(s: Digest): Digest {
        \\  const out: Digest = sha256(s);
        \\  return out;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  const seed: Digest = "x";
        \\  return Response.text(digest(seed));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-effects-text.ts", .{});
    defer result.deinit(allocator);
    try std.testing.expect(result.canonical_errors > 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "one-way-effects-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Canonical diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ZTS610") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "one-way-effects-text.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Effects<...>") != null);
}

test "formatProofCard: capability policy diagnostics are visible in text mode" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const value = env("OTHER_NAME") ?? "x";
        \\  return Response.json({ value: value });
        \\}
    ;
    const policy_source =
        \\{ "env": { "allow": ["APP_NAME"] } }
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "policy-text.ts", .{
        .policy_source = policy_source,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), result.policy_errors);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "policy-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Capability policy diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "POL001") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "OTHER_NAME") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "add it to the policy file") != null);
}

test "runCheckOnlyWithOptions: json mode emits ZTS000 for an unreadable handler" {
    const allocator = std.testing.allocator;
    // A missing handler in JSON mode must produce a structured ZTS000 result,
    // not a propagated Zig error that would dump a raw stack trace to IDE/CI.
    var result = try runCheckOnlyWithOptions(
        allocator,
        "/nonexistent/zttp-cli2-missing.ts",
        .{ .json_mode = true },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(StageSet.empty, result.stages_run);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS000", diagnostic.code);
    try std.testing.expectEqualStrings("error", diagnostic.severity);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "cannot read handler file") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.file, "zttp-cli2-missing.ts") != null);
    try std.testing.expect(result.contract == null);
    try std.testing.expect(result.properties == null);
    try std.testing.expect(result.proof_trace_json == null);
}

test "runCheckOnlyWithOptions: non-json mode still propagates a missing-handler error" {
    const allocator = std.testing.allocator;
    // Without --json, the readable line is printed and the error propagates so
    // the CLI maps it to a clean exit; assert the error path is preserved.
    try std.testing.expectError(
        error.FileNotFound,
        runCheckOnlyWithOptions(allocator, "/nonexistent/zttp-cli2-missing.ts", .{ .json_mode = false }),
    );
}

test "formatProofCard: spec-less handler renders ZTS500 lines matching the footer count" {
    const allocator = std.testing.allocator;
    // A handler with no Proof<T, P> activates the default proof profile, whose
    // unsatisfiable properties trip error-severity ZTS500 spec diagnostics.
    // Assert that they render and that the printed error lines equal the
    // footer count.
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ now: Date.now() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "spec-less-text.ts", .{});
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var spec_err_count: usize = 0;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind.severity() == .err) spec_err_count += 1;
    }
    try std.testing.expect(spec_err_count > 0);
    // The footer count is exactly the error-severity spec diagnostics for this
    // handler (no other error category fires), so the printed lines must match.
    try std.testing.expectEqual(@as(u32, @intCast(spec_err_count)), result.totalErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "spec-less-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Spec diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ZTS500") != null);

    // Count printed error-severity spec lines: each renders as "    ZTSxxx (error) ".
    var printed: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, buf.items, search_from, " (error) ")) |pos| {
        printed += 1;
        search_from = pos + " (error) ".len;
    }
    try std.testing.expectEqual(spec_err_count, printed);
}

test "formatFailureSections: lists the spec errors without the stage rows" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ now: Date.now() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "sections-text.ts", .{});
    defer result.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    check_mod.formatFailureSections(&aw.writer, &result, "sections-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ZTS500") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Parse ...") == null);
}

test "formatProofCard: the card names the demotion site --json already carried" {
    // The two surfaces were said to share one source of truth, and did not:
    // `--json` printed "; demoted at line L:C by `snippet`" from `diag.cause`
    // and the card spelled its own suffix without it. So `zttp check` named the
    // failing spec and left out the line number, which is the half that turns
    // one property into one edit.
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ at: Date.now() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "demoted-text.ts", .{});
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var caused: usize = 0;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind.severity() == .err and d.cause != null) caused += 1;
    }
    // The floor: with no caused diagnostic the assertions below would pass over
    // a card that renders nothing at all.
    try std.testing.expect(caused > 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "demoted-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "demoted at line") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Date.now()") != null);
}

test "formatFailureSections: the card names the file of a cause in an imported file" {
    // The cause of a write in an imported file carries the file. The card then
    // prints "dep.ts:4:12" in place of "line 4:12", as the ZTS310 row does.
    const allocator = std.testing.allocator;
    const source =
        \\let count: number = 0;
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  count = count + 1;
        \\  return Response.text(String(count));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "dep-cause-text.ts", .{});
    defer result.deinit(allocator);

    const contract = &(result.contract orelse return error.TestUnexpectedResult);
    // The floor: the first diagnostic is the ZTS500 of `read_only`.
    try std.testing.expectEqualStrings("read_only", contract.spec_diagnostics.items[0].spec_name);
    contract.spec_diagnostics.items[0].cause = .{
        .line = 4,
        .column = 12,
        .snippet = handler_contract.state_write_snippet,
        .file = try allocator.dupe(u8, "dep.ts"),
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    check_mod.formatFailureSections(&aw.writer, &result, "dep-cause-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(
        u8,
        buf.items,
        "declared Proof capsule was not discharged by handler proof (failing spec: read_only; demoted at dep.ts:4:12 by `a write to module state`)\n",
    ) != null);
}

test "formatFailureSections: a cause with no file keeps the line-only suffix" {
    const allocator = std.testing.allocator;
    const source =
        \\let count: number = 0;
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  count = count + 1;
        \\  return Response.text(String(count));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "site-cause-text.ts", .{});
    defer result.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    check_mod.formatFailureSections(&aw.writer, &result, "site-cause-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(
        u8,
        buf.items,
        "declared Proof capsule was not discharged by handler proof (failing spec: read_only; demoted at line 3:9 by `a write to module state`)\n",
    ) != null);
}

fn stateWriteVerifierFacts(file: ?[]const u8) check_run_mod.ContractFacts {
    return .{ .verifier = .{
        .state_isolated = false,
        .shares_state = true,
        .result_safe = true,
        .optional_safe = true,
        .state_write = .{ .line = 4, .column = 12, .snippet = handler_contract.state_write_snippet, .file = file },
    } };
}

test "applyContractFacts owns the file of a state-write cause and frees the one it replaces" {
    const allocator = std.testing.allocator;
    var contract = handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    contract.properties = .{
        .pure = true,
        .read_only = true,
        .stateless = true,
        .retry_safe = true,
        .deterministic = true,
        .has_egress = false,
        .idempotent = true,
        .state_isolated = true,
    };

    try check_run_mod.applyContractFacts(allocator, &contract, stateWriteVerifierFacts("first.ts"));
    try std.testing.expectEqualStrings("first.ts", contract.property_provenance.state_write.?.file orelse return error.TestUnexpectedResult);

    // A second application replaces the cause, and the first file is freed.
    try check_run_mod.applyContractFacts(allocator, &contract, stateWriteVerifierFacts("second.ts"));
    try std.testing.expectEqualStrings("second.ts", contract.property_provenance.state_write.?.file orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("second.ts", contract.owned_state_write_file orelse return error.TestUnexpectedResult);

    // A cause with no file leaves nothing owned.
    try check_run_mod.applyContractFacts(allocator, &contract, stateWriteVerifierFacts(null));
    try std.testing.expect(contract.property_provenance.state_write.?.file == null);
    try std.testing.expect(contract.owned_state_write_file == null);

    try check_run_mod.applyContractFacts(allocator, &contract, stateWriteVerifierFacts("third.ts"));
    try std.testing.expectEqualStrings("third.ts", contract.property_provenance.state_write.?.file orelse return error.TestUnexpectedResult);
}

fn applyStateWriteTwice(allocator: std.mem.Allocator) !void {
    var contract = handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    contract.properties = .{
        .pure = true,
        .read_only = true,
        .stateless = true,
        .retry_safe = true,
        .deterministic = true,
        .has_egress = false,
        .idempotent = true,
        .state_isolated = true,
    };
    try check_run_mod.applyContractFacts(allocator, &contract, stateWriteVerifierFacts("first.ts"));
    try check_run_mod.applyContractFacts(allocator, &contract, stateWriteVerifierFacts("second.ts"));
}

test "a failed allocation while recording a state-write file leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, applyStateWriteTwice, .{});
}

fn refreshKeepingHelperRow(allocator: std.mem.Allocator) !void {
    var contract = handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    const helper_row = zts.SpecDiagnostic{
        .kind = .not_discharged,
        .spec_name = "read_only",
        .cause = .{ .line = 4, .column = 9, .snippet = "a write to module state", .file = "b.ts" },
        .suggestion = "remove `read_only` from the capsule",
        .function = "tally",
        .site = .{ .file = "a.ts", .line = 3, .column = 8 },
    };
    var owned = try helper_row.clone(allocator);
    contract.spec_diagnostics.append(allocator, owned) catch |err| {
        owned.deinit(allocator);
        return err;
    };
    try check_mod.refreshContractSpecDiagnostics(allocator, &contract);
}

test "a failed allocation while refreshing spec diagnostics leaks no kept helper row" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, refreshKeepingHelperRow, .{});
}

test "formatProofCard: strict canonical diagnostics are visible in text mode" {
    const allocator = std.testing.allocator;
    const source =
        \\const parse = (x: number): number => x;
        \\
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-arrow-text.ts", .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), result.canonical_errors);
    try std.testing.expect(result.strict_errors > 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "one-way-arrow-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Canonical diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ZTS608") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "one-way-arrow-text.ts") != null);
}

test "runCheckOnlyFromSource: composed Spec and Effects preserves handler budget diagnostics" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function handler(req: Request): Proof<Effects<Response, "env">, "state_isolated"> {
        \\  return Response.text(sha256("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "composed-budget.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var saw_506 = false;
    var saw_json_506 = false;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind == .budget_exceeded and std.mem.eql(u8, d.spec_name, "crypto")) {
            saw_506 = true;
            try std.testing.expect(d.function == null);
        }
    }
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS506")) saw_json_506 = true;
    }
    try std.testing.expect(saw_506);
    try std.testing.expect(saw_json_506);
}

test "runCheckOnlyFromSource: missing capsule ignores unreachable helpers" {
    const allocator = std.testing.allocator;
    const source =
        \\function unused(): string {
        \\  return String(Date.now());
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "unreachable-capsule.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind == .missing_capsule) return error.TestUnexpectedResult;
    }
}

test "runCheckOnlyFromSource: handler Effects budget covering reached capabilities is clean" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  return Response.text(sha256("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "ok.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    for (contract.spec_diagnostics.items) |d| {
        try std.testing.expect(d.kind != .budget_exceeded);
        try std.testing.expect(d.kind != .helper_budget_exceeded);
    }
}

test "runCheckOnlyFromSource: a helper with no Effects ceiling is never flagged" {
    const allocator = std.testing.allocator;
    // `digest` reaches crypto but declares no `Effects<...>` ceiling, and the
    // handler declares no budget. Capsules are opt-in: nothing is flagged.
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): string {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(digest("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "noceiling.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    for (contract.spec_diagnostics.items) |d| {
        try std.testing.expect(d.kind != .effect_undeclared);
        try std.testing.expect(d.kind != .effect_over_declared);
        try std.testing.expect(d.kind != .budget_exceeded);
        try std.testing.expect(d.kind != .helper_budget_exceeded);
    }
}

test "holes: each site reports its expected type and the unspent budget" {
    const allocator = std.testing.allocator;
    // Two holes in different return positions. The handler's budget declares
    // three capabilities and spends two, so `crypto` is what is left to spend
    // filling either hole.
    const source =
        \\import { env } from "zttp:env";
        \\
        \\function slug(s: string): string {
        \\  return hole();
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "env" | "policy_check" | "crypto"> {
        \\  if (req.method === "GET") {
        \\    return Response.json({ region: env("REGION"), slug: slug("x") });
        \\  }
        \\  return hole();
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 2), contract.holes.items.len);

    var saw_slug = false;
    var saw_handler = false;
    for (contract.holes.items) |h| {
        if (std.mem.eql(u8, h.function, "slug")) {
            saw_slug = true;
            try std.testing.expectEqualStrings("string", h.expected_type);
        }
        if (std.mem.eql(u8, h.function, "handler")) {
            saw_handler = true;
            // The capsule expansion is erased: the returned value never carries
            // the phantom marker field, so reporting it would be a lie about
            // what the expression must construct.
            try std.testing.expectEqualStrings("Response", h.expected_type);
        }
        try std.testing.expect(h.budget_declared);
        try std.testing.expectEqual(@as(usize, 1), h.remaining_budget.items.len);
        try std.testing.expectEqualStrings("crypto", h.remaining_budget.items[0]);
    }
    try std.testing.expect(saw_slug);
    try std.testing.expect(saw_handler);
}

test "holes: each site reports the properties its own function has not discharged" {
    const allocator = std.testing.allocator;
    // The handler declares no Spec, so the default profile demands the full
    // set and reports every property it does not hold. `mint` breaks two the
    // handler needs and carries no capsule declaring them (ZTS606), so a hole
    // in `mint` owes those rather than the handler's list.
    const source =
        \\import { uuid } from "zttp:id";
        \\
        \\function mint(): string {
        \\  const v = uuid();
        \\  return hole();
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  if (req.method === "GET") return Response.json({ id: mint() });
        \\  return hole();
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 2), contract.holes.items.len);

    for (contract.holes.items) |h| {
        // Every entry is a single property name. The implicit default profile
        // reports its failures as one comma-joined diagnostic, which is right
        // for the HUD and useless to a consumer that wants to match on names.
        try std.testing.expect(h.undischarged.items.len > 0);
        for (h.undischarged.items) |name| {
            try std.testing.expect(std.mem.indexOfScalar(u8, name, ',') == null);
            try std.testing.expect(std.mem.indexOfScalar(u8, name, ' ') == null);
        }

        if (std.mem.eql(u8, h.function, "mint")) {
            // Attributed to the helper, so the handler's own failures are not
            // on this list: `pure` is there because `mint` breaks it, not
            // because the handler does.
            var saw_deterministic = false;
            for (h.undischarged.items) |name| {
                if (std.mem.eql(u8, name, "deterministic")) saw_deterministic = true;
            }
            try std.testing.expect(saw_deterministic);
        }
    }
}

test "holes: each site reports the bindings it can be filled from" {
    const allocator = std.testing.allocator;
    // `later` is declared below the hole, so it is not material an expression
    // there can use, and neither is the hole's own binding.
    const source =
        \\function handler(req: Request): Response {
        \\  const early: string = "a";
        \\  const filled: string = hole();
        \\  const later: number = 3;
        \\  return Response.json({ filled: filled, later: later });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 1), contract.holes.items.len);

    const in_scope = contract.holes.items[0].in_scope.items;
    try std.testing.expectEqual(@as(usize, 2), in_scope.len);
    // The parameter first, then declarations in the order they were written.
    try std.testing.expectEqualStrings("req", in_scope[0].name);
    try std.testing.expectEqualStrings("Request", in_scope[0].type_name);
    try std.testing.expectEqualStrings("early", in_scope[1].name);
    try std.testing.expectEqualStrings("string", in_scope[1].type_name);
}

test "holes: a binding with no annotation is reported as unknown" {
    const allocator = std.testing.allocator;
    // An honest absence rather than a guess: an agent that reads a wrong type
    // writes an expression that does not compile.
    const source =
        \\import { uuid } from "zttp:id";
        \\function mint(): string {
        \\  const v = uuid();
        \\  return hole();
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ id: mint() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 1), contract.holes.items.len);

    const in_scope = contract.holes.items[0].in_scope.items;
    try std.testing.expectEqual(@as(usize, 1), in_scope.len);
    try std.testing.expectEqualStrings("v", in_scope[0].name);
    try std.testing.expectEqualStrings("unknown", in_scope[0].type_name);
}

test "holes: a hole inside a nested function declaration is attributed to the enclosing function" {
    const allocator = std.testing.allocator;
    // A function declaration holds its function as the `init` of var_decl
    // data. Reading it as function data left the hole with no owner.
    const source =
        \\function handler(req: Request): Response {
        \\  const outer: string = "a";
        \\  function inner(): string {
        \\    const local: string = "b";
        \\    return hole();
        \\  }
        \\  return Response.json({ v: inner() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 1), contract.holes.items.len);
    try std.testing.expectEqualStrings("handler", contract.holes.items[0].function);

    const in_scope = contract.holes.items[0].in_scope.items;
    try std.testing.expectEqual(@as(usize, 3), in_scope.len);
    try std.testing.expectEqualStrings("req", in_scope[0].name);
    try std.testing.expectEqualStrings("outer", in_scope[1].name);
    try std.testing.expectEqualStrings("local", in_scope[2].name);
}

test "holes: a hole inside a nested function declaration expects the nested function's return type" {
    const allocator = std.testing.allocator;
    // The hole is attributed to the enclosing function, which keeps its scope,
    // but the expression it stands for returns from the nested function, so
    // the expected type is the nested declaration's, not the handler's. The
    // innermost declaration wins.
    const source =
        \\function handler(req: Request): Response {
        \\  function inner(): string {
        \\    return hole();
        \\  }
        \\  function outer(): string {
        \\    function deep(): number {
        \\      return hole();
        \\    }
        \\    return String(deep());
        \\  }
        \\  return Response.json({ v: inner(), w: outer() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 2), contract.holes.items.len);
    for (contract.holes.items) |h| try std.testing.expectEqualStrings("handler", h.function);
    try std.testing.expectEqualStrings("string", contract.holes.items[0].expected_type);
    try std.testing.expectEqualStrings("number", contract.holes.items[1].expected_type);
}

test "holes: a finished program reports none" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "done.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 0), contract.holes.items.len);
}

test "ZTS623: a module-internal helper may not declare an Effects ceiling" {
    const allocator = std.testing.allocator;
    // Spec 5.7 makes placement decidable: exported with a nonempty row MUST
    // declare, module-internal MUST NOT. The internal ceiling proves nothing
    // the compiler does not infer, and ZTS607 already bounds the helper through
    // the handler's budget.
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): Effects<string, "crypto"> {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  return Response.text(digest("zttp"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "internal.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_623 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS623")) saw_623 = true;
    }
    try std.testing.expect(saw_623);
}

test "ZTS623: dropping the internal ceiling satisfies the placement rule" {
    const allocator = std.testing.allocator;
    // Same program with the internal ceiling removed. The handler's budget
    // still bounds `digest`, so nothing about the proof weakens.
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): string {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  return Response.text(digest("zttp"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "internal.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    for (result.json_diagnostics.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.code, "ZTS623"));
        // The budget check must still be satisfied: no helper-budget breach.
        try std.testing.expect(!std.mem.eql(u8, d.code, "ZTS607"));
    }
}

test "appendExportCapsuleDiagnostics: the docs mode asks only for a Proof capsule" {
    const allocator = std.testing.allocator;
    // This mode covers the proof half alone: ZTS610 already refuses exactly the
    // helpers an effects warning would ask about.
    const source =
        \\import { env } from "zttp:env";
        \\
        \\nominal Region = string;
        \\
        \\export function region(): Region {
        \\  const value: Region = env("REGION") ?? "unknown";
        \\  return value;
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(region());
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "docs.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    appendExportCapsuleDiagnostics(allocator, &result, "docs.ts");

    var saw_507 = false;
    var saw_508 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS507")) saw_507 = true;
        if (std.mem.eql(u8, d.code, "ZTS508")) saw_508 = true;
    }
    try std.testing.expect(!saw_507);
    try std.testing.expect(saw_508);
    // The capability that would have been ZTS507's subject is still reported,
    // unconditionally and as an error, by the always-on rule.
    var saw_610 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS610")) saw_610 = true;
    }
    try std.testing.expect(saw_610);
}

test "runCheckOnly keeps mirrored properties aligned with finalized fault coverage" {
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\
        \\function handler(req: Request): Proof<Response, "fault_covered"> {
        \\  const auth = jwtVerify("token", "secret");
        \\  if (!auth.ok) {
        \\    return Response.text("unauthorized", { status: 401 });
        \\  }
        \\  return Response.text("ok");
        \\}
    ;

    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(result.fault_total > 0);

    const mirrored = result.properties orelse return error.MissingProperties;
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const finalized = contract.properties orelse return error.MissingProperties;

    try std.testing.expect(finalized.fault_covered);
    try std.testing.expectEqual(finalized.fault_covered, mirrored.fault_covered);
}

test "runCheckOnlyFromSource keeps diagnostics off stderr in test mode" {
    // Regression guard: every non-JSON std.debug.print diagnostic in
    // runCheckOnlyFromSource must stay gated behind !builtin.is_test.
    // The Zig build runner flags any test that writes to stderr, so a
    // dropped gate here turns a passing test into a build failure
    // (this is exactly how the strict-diagnostic leak was caught).
    const source =
        \\function handler(req: Request): Response {
        \\  const path = req.path;
        \\  const data = fetchSync(["https://example.internal", path].join(""));
        \\  return Response.json(data);
        \\}
    ;

    // json_mode = false routes diagnostics through the std.debug.print path.
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{});
    defer result.deinit(std.testing.allocator);

    // Strict mode (default) rejects the implicit-unknown fetchSync result.
    try std.testing.expect(result.strict_errors > 0);
    try std.testing.expect(result.totalErrors() > 0);
}

test "runCheckOnlyFromSource: ZTS202 arg-count message survives json capture without use-after-free" {
    // Regression (ENG-3): the ZTS202/ZTS203 dynamic message is allocPrint'd on
    // the checker allocator, which the pipeline tears down before the JSON is
    // serialized. fromCheckerDiagnostic must dupe the message into the
    // long-lived CheckResult allocator at capture time, or the --json /
    // edit-simulate surface reads freed bytes (0xaa in debug). Using the
    // leak-checked testing.allocator also proves the new owned-message path has
    // no leak or double-free.
    const allocator = std.testing.allocator;
    const source =
        \\function digest(s: string): string {
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(digest());
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "argcount.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_202 = false;
    for (result.json_diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.code, "ZTS202")) continue;
        saw_202 = true;
        // The message must be intact, not freed-memory garbage.
        try std.testing.expect(std.unicode.utf8ValidateSlice(d.message));
        try std.testing.expect(std.mem.indexOfScalar(u8, d.message, 0xaa) == null);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "wrong number of arguments") != null);
    }
    try std.testing.expect(saw_202);
}

test "a pure-typed callback parameter contributes the empty row" {
    const allocator = std.testing.allocator;
    // D2 section 4's I3: a function type with no capsule declares the empty
    // row - spec 6.5's "its callback MUST be pure" made representable. The
    // call through `f` does not report ZTS512.
    const source =
        \\nominal Count = number;
        \\
        \\export function apply(f: (n: number) => number, x: Count): Effects<number, "clock"> {
        \\  return f(x);
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "pure-callback.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_512 = false;
    var saw_505 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS512")) saw_512 = true;
        if (std.mem.eql(u8, d.code, "ZTS505")) saw_505 = true;
    }
    try std.testing.expect(!saw_512);
    // The row is empty, so declaring "clock" is over-declaration - a real
    // answer about the program where there had been a refusal to answer.
    try std.testing.expect(saw_505);
}

test "an unreached exported helper with a nonempty row reports ZTS610" {
    const allocator = std.testing.allocator;
    // Spec 5.7 says "an exported function with a nonempty inferred effect row
    // MUST declare" with no reachability condition. `unused` is never called
    // from the handler and still owes a ceiling.
    const source =
        \\import { env } from "zttp:env";
        \\
        \\structural OptionalSecret = string | undefined;
        \\
        \\export function unused(): OptionalSecret {
        \\  return env("API_KEY");
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "unreached-helper.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var repair: ?[]const u8 = null;
    for (result.json_diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.code, "ZTS610")) continue;
        repair = d.suggestion;
    }
    const found = repair orelse return error.MissingZTS610;
    // The repair is computed from the inferred row, not a fixed string.
    try std.testing.expect(std.mem.indexOf(u8, found, "env") != null);
}

test "zts check --types path rejects exported handler local mismatch" {
    const source =
        \\export function handler(req: Request): Response {
        \\  const n: number = "not a number";
        \\  return Response.json({});
        \\}
    ;

    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "exported-local.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expect(result.totalErrors() >= 1);
}

test "check reports a boolean error and a type error on different nodes" {
    // The type stage and the boolean stage each find a different mistake. The
    // check shows both and does not stop at the first stage with errors.
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n: number = 1;
        \\  const m: number = n + "y";
        \\  if (5) {
        \\    return Response.text("a");
        \\  }
        \\  return Response.text(String(m));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "two-stages.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.bool_errors);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(usize, 2), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS100", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("ZTS105", result.json_diagnostics.items[1].code);
}

test "check reports one message for a condition that is a refused operator" {
    // `n + "y"` is the type error and also the condition. The boolean checker
    // would add ZTS100 for the same expression.
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n: number = 1;
        \\  if (n + "y") {
        \\    return Response.text("a");
        \\  }
        \\  return Response.text("b");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "one-node.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), result.bool_errors);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS105", result.json_diagnostics.items[0].code);
}

test "check reports a strict error beside a type error" {
    // An unannotated handler is ZTS601, and the refused sum is ZTS105.
    const source =
        \\function handler(req: Request) {
        \\  const n: number = 1;
        \\  const m: number = n + "y";
        \\  return Response.text(String(m));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "strict-beside.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.strict_errors);
    try std.testing.expectEqual(@as(usize, 2), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS105", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("ZTS601", result.json_diagnostics.items[1].code);
}

test "check still stops before the verifier when a computed stage has an error" {
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n: number = 1;
        \\  if (n + "y") {
        \\    return Response.text("a");
        \\  }
        \\  return Response.text("b");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "stops.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expect(result.totalErrors() > 0);
    try std.testing.expect(!result.verify_ran);
}

test "runCheckOnlyFromSource: no Spec activates all supported specs for TS" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ now: Date.now() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "default-specs.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(zts.spec_discharge.v1_specs.len, contract.declared_specs.items.len);
    for (zts.spec_discharge.v1_specs) |spec| {
        try std.testing.expect(handler_contract.containsString(contract.declared_specs.items, spec.name));
    }
    // The default profile's error-severity spec diagnostics are the only errors.
    var spec_err_count: usize = 0;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind.severity() == .err) spec_err_count += 1;
    }
    try std.testing.expect(spec_err_count > 0);
    try std.testing.expectEqual(@as(u32, @intCast(spec_err_count)), result.totalErrors());
}

test "runCheckOnlyFromSource refuses unsupported source extensions with ZTS052" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    for ([_][]const u8{ "handler.js", "handler.tsx" }) |filename| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, filename, .{
            .json_mode = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expectEqualStrings("ZTS052", result.json_diagnostics.items[0].code);
        try std.testing.expectEqualStrings(filename, result.json_diagnostics.items[0].file);
        try std.testing.expect(result.contract == null);
    }
}

test "runCheckOnlyFromSource refuses raw JSX in TypeScript with ZTS002" {
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.html(<main>hello</main>);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS002", result.json_diagnostics.items[0].code);
    try std.testing.expect(result.contract == null);
}

test "CHECK refuses an erased type prefix with ZTS002 at the angle bracket" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, diagnostic: CompoundDiagnostic }{
        .{ .source = "const x = <T>(1);\n", .diagnostic = .{ .code = "ZTS002", .message = "raw JSX is not supported; use ordinary TypeScript expressions", .line = 1, .column = 11 } },
        .{ .source = "const x = <T> { id: 1 };\n", .diagnostic = .{ .code = "ZTS002", .message = "raw JSX is not supported; use ordinary TypeScript expressions", .line = 1, .column = 11 } },
        .{ .source = "<T> { const a = 1; }\n", .diagnostic = .{ .code = "ZTS002", .message = "raw JSX is not supported; use ordinary TypeScript expressions", .line = 1, .column = 1 } },
        .{ .source = "const x = (<T>(1));\n", .diagnostic = .{ .code = "ZTS002", .message = "raw JSX is not supported; use ordinary TypeScript expressions", .line = 1, .column = 12 } },
        .{ .source = "const f = <T>(value /* ( */): number => value;\n", .diagnostic = .{ .code = "ZTS002", .message = "raw JSX is not supported; use ordinary TypeScript expressions", .line = 1, .column = 11 } },
    };
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
    }
}

test "CHECK refuses an empty predicate narrowing at the token after is" {
    const allocator = std.testing.allocator;
    const handler_line = "export function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    const missing = "type annotation";
    const unverified = "Return one admitted narrowing test over the named parameter, combined with &&, || or !.";
    const cases = [_]struct {
        source: []const u8,
        parse_errors: u32,
        diagnostic: CompoundDiagnostic,
    }{
        // Narrowing ends at a newline.
        .{ .source = handler_line ++ "function isS(x: unknown): x is\n{ return true; }\n", .parse_errors = 1, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 3, .column = 1, .suggestion = missing } },
        // Narrowing ends at a trailing space and a newline.
        .{ .source = handler_line ++ "function isS(x: unknown): x is \n{ return true; }\n", .parse_errors = 1, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 3, .column = 1, .suggestion = missing } },
        // Narrowing ends at two spaces, a newline, and an indented brace.
        .{ .source = handler_line ++ "function isS(x: unknown): x is  \n  { return true; }\n", .parse_errors = 1, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 3, .column = 3, .suggestion = missing } },
        // Arrow forms.
        .{ .source = handler_line ++ "const isS = (x: unknown): x is\n=> true;\n", .parse_errors = 1, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 3, .column = 1, .suggestion = missing } },
        .{ .source = handler_line ++ "const isS = (x: unknown): x is => true;\n", .parse_errors = 1, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 2, .column = 32, .suggestion = missing } },
        // A comment after is leaves the narrowing empty.
        .{ .source = handler_line ++ "function isS(x: unknown): x is /* c */ { return true; }\n", .parse_errors = 1, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 2, .column = 40, .suggestion = missing } },
        .{ .source = handler_line ++ "function isS(x: unknown): x is // c\n{ return true; }\n", .parse_errors = 1, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 3, .column = 1, .suggestion = missing } },
        // A real narrowing keeps the ZTS211 verdict of the body check.
        .{ .source = handler_line ++ "function isS(x: unknown): x is\tstring { return true; }\n", .parse_errors = 0, .diagnostic = .{ .code = "ZTS211", .message = "type predicate 'isS' is not verified by its body", .line = 2, .column = 1, .suggestion = unverified } },
        .{ .source = handler_line ++ "function isS(x: unknown): x is\nstring { return true; }\n", .parse_errors = 0, .diagnostic = .{ .code = "ZTS211", .message = "type predicate 'isS' is not verified by its body", .line = 2, .column = 1, .suggestion = unverified } },
        .{ .source = handler_line ++ "function isS(x: unknown): x is string { return true; }\n", .parse_errors = 0, .diagnostic = .{ .code = "ZTS211", .message = "type predicate 'isS' is not verified by its body", .line = 2, .column = 1, .suggestion = unverified } },
    };
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(case.parse_errors, result.parse_errors);
    }
}

test "CHECK keeps the current tolerated annotation text suffix" {
    const source =
        \\function handler(req: Request): Response {
        \\  const text: string tolerated_suffix = "ready";
        \\  return Response.text(text);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "annotation-suffix.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(std.testing.allocator);

    const expected = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    try std.testing.expectEqual(expected, result.stages_run);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expect(result.contract == null);
}

test "CHECK retains the recognized type before a tolerated annotation suffix" {
    const source =
        \\function handler(req: Request): Response {
        \\  const text: string tolerated_suffix = 1;
        \\  return Response.text(text);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "annotation-suffix.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(std.testing.allocator);

    const expected = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    try std.testing.expectEqual(expected, result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS200", result.json_diagnostics.items[0].code);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource treats declared comptime as an ordinary function" {
    const source =
        \\function comptime(value: string): string { return value; }
        \\function handler(req: Request): Response {
        \\  return Response.text(comptime("ready"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
}

test "runCheckOnlyFromSource refuses unbound comptime and resource through ZTS629" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        ambient: []const u8,
    }{
        .{
            .name = "comptime.ts",
            .source =
            \\function handler(req: Request): Response {
            \\  return Response.text(String(comptime("ready")));
            \\}
            ,
            .ambient = "comptime",
        },
        .{
            .name = "resource.ts",
            .source =
            \\function handler(req: Request): Response {
            \\  return Response.text(String(resource("item")));
            \\}
            ,
            .ambient = "resource",
        },
    };

    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, case.name, .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);

        const diagnostic = for (result.json_diagnostics.items) |candidate| {
            if (std.mem.eql(u8, candidate.code, "ZTS629")) break candidate;
        } else return error.TestExpectedEqual;
        var expected_message: [96]u8 = undefined;
        const message = try std.fmt.bufPrint(&expected_message, "unpublished ambient global '{s}'", .{case.ambient});
        try std.testing.expectEqualStrings(message, diagnostic.message);
        try std.testing.expect(result.contract == null);
    }
}

test "runCheckOnlyFromSource refuses the retired zttp types import with ZTS053" {
    const allocator = std.testing.allocator;
    const source =
        \\import type { Spec } from "zttp:types";
        \\function handler(req: Request): Response & Spec<"deterministic"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS053", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses default parameters with ZTS054" {
    const allocator = std.testing.allocator;
    const source =
        \\function label(prefix: string = "item"): string {
        \\  return prefix;
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS054", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses optional parameter shorthand with ZTS055" {
    const allocator = std.testing.allocator;
    const source =
        \\function label(prefix?: string): string {
        \\  return prefix ?? "item";
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS055", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "replace `name?: T` with `name: T | undefined`",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses default exports with ZTS056" {
    const allocator = std.testing.allocator;
    const source =
        \\export default function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS056", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "write a named export, for example `export function handler(...) { ... }`",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses mutable exports with ZTS057" {
    const allocator = std.testing.allocator;
    const source =
        \\export let version: number = 1;
        \\export function handler(req: Request): Response {
        \\  return Response.json({ version: version });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS057", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "use `export const` for module values and keep reassignment inside a function activation",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses Array generic spelling with ZTS058" {
    const allocator = std.testing.allocator;
    const source =
        \\function first(items: Array<number>): number {
        \\  return items[0];
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS058", diagnostic.code);
    try std.testing.expectEqualStrings("write `T[]`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses ReadonlyArray generic spelling with ZTS059" {
    const allocator = std.testing.allocator;
    const source =
        \\function first(items: ReadonlyArray<number>): number {
        \\  return items[0];
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS059", diagnostic.code);
    try std.testing.expectEqualStrings("write `readonly T[]`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses void type spelling with ZTS060" {
    const allocator = std.testing.allocator;
    const source =
        \\function ignore(value: string): void {
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS060", diagnostic.code);
    try std.testing.expectEqualStrings("write `undefined`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource reports ZTS061 for a raw exported boundary" {
    const allocator = std.testing.allocator;
    const source =
        \\export function expose(value: string): string {
        \\  return value;
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.text(expose("ok"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var zts061_count: usize = 0;
    for (result.json_diagnostics.items) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.code, "ZTS061")) continue;
        zts061_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "type `string` exposes raw `string`") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), zts061_count);
    try std.testing.expectEqual(@as(u32, 2), result.strict_errors);
}

test "runCheckOnlyFromSource explicitly refuses unary void" {
    const allocator = std.testing.allocator;
    const source =
        \\const ignored = void 0;
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("evaluate the operand as a statement when its effects are required, then use `undefined` explicitly", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses debugger statements" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  debugger;
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("remove the statement", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses empty statements" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  ;
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("remove the standalone `;`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses when wildcard arms" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const status = match (req.method) {
        \\    when _: 200,
        \\  };
        \\  return Response.json({ status: status });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("write `default:`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses object declaration destructuring" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const { method, url } = req;
        \\  return Response.json({ method: method, url: url });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("bind the source to a name, then read each member with explicit `const` bindings", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses destructuring renames" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const { method: requestMethod } = req;
        \\  return Response.json({ method: requestMethod });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("bind the source to a name, then read each member with explicit `const` bindings", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses array declaration destructuring" {
    const allocator = std.testing.allocator;
    const source =
        \\function first(pair: [string, number]): string {
        \\  const [name, count] = pair;
        \\  return name + String(count);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("bind the source to a name, then read each element with explicit indexed `const` bindings", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses object literal shorthand" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const value = req.method;
        \\  return Response.json({ value });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("write the field and value explicitly, for example `{ value: value }`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses computed record keys" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const key = req.method;
        \\  return Response.json({ [key]: "value" });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("use a literal field name, or `Dict` for dynamic keys", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses the in operator" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const present = "authorization" in req.headers;
        \\  return Response.json({ present: present });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("use the explicit predicate for the value kind, such as `dictHas`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses unary plus" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const value = +req.path;
        \\  return Response.json({ value: value });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("remove it from a number expression, or use an admitted boundary parser for text", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses optional calls" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const value = req.callback?.();
        \\  return Response.json({ value: value });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("check for `undefined`, then call the function directly", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses optional computed access" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const value = req.headers?.["authorization"];
        \\  return Response.json({ value: value });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("check for `undefined`, then use indexed access", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses template interpolation" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const message = `hello ${req.method}`;
        \\  return Response.text(message);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("build a string array with explicit `String(...)` conversions and call `.join(\"\")`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses string addition" {
    const allocator = std.testing.allocator;
    const source =
        \\function concatText(left: string, right: string): string {
        \\  return left + right;
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.text(concatText("hello ", "world"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS105", diagnostic.code);
    try std.testing.expectEqualStrings("build a string array with explicit `String(...)` conversions and call `.join(\"\")`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource keeps numeric addition" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const total = 20 + 22;
        \\  return Response.json({ total: total });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses an unpublished ambient global" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const secret = process.env.JWT_SECRET;
        \\  return Response.json({ authenticated: secret !== undefined });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.strict_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS629", diagnostic.code);
    try std.testing.expectEqualStrings("unpublished ambient global 'process'", diagnostic.message);
    try std.testing.expectEqualStrings("Import a published virtual-module capability or use an ambient name listed by meta.ambient_names.", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource repairs raw fetchSync through zttp fetch" {
    const source =
        \\function handler(req: Request): Response {
        \\  return fetchSync("https://example.internal");
        \\}
    ;

    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    const diagnostic = for (result.json_diagnostics.items) |candidate| {
        if (std.mem.eql(u8, candidate.code, "ZTS629")) break candidate;
    } else return error.TestExpectedEqual;

    try std.testing.expectEqualStrings("unpublished ambient global 'fetchSync'", diagnostic.message);
    try std.testing.expectEqualStrings(
        "Import `fetch` from `zttp:fetch` and call `fetch(...)`; raw `fetchSync` is outside the model-minimal ambient namespace.",
        diagnostic.suggestion.?,
    );
}

test "runCheckOnlyFromSource: explicit Spec narrows active spec set" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "declared-only.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), contract.declared_specs.items.len);
    try std.testing.expectEqualStrings("deterministic", contract.declared_specs.items[0]);
    try std.testing.expectEqual(@as(usize, 0), contract.spec_diagnostics.items.len);
}

test "runCheckOnlyFromSource: explicit unknown Spec suppresses defaults and emits ZTS502" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Proof<Response, "made_up"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "unknown-only.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), contract.declared_specs.items.len);
    try std.testing.expectEqualStrings("made_up", contract.declared_specs.items[0]);
    try std.testing.expectEqual(@as(usize, 1), contract.spec_diagnostics.items.len);
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.unknown_name, contract.spec_diagnostics.items[0].kind);
}

test "runCheckOnly returns structured diagnostics for invalid virtual imports" {
    const cases = [_]struct {
        source: []const u8,
        code: []const u8,
        message: []const u8,
    }{
        .{
            .source =
            \\import { send } from "zttp:websocket";
            \\function handler(req: Request): Response { return Response.json({ ok: true }); }
            ,
            .code = "ZTS206",
            .message = "unknown virtual module 'zttp:websocket'",
        },
        .{
            .source =
            \\import { requireJWT } from "zttp:auth";
            \\function handler(req: Request): Response { return Response.json({ ok: true }); }
            ,
            .code = "ZTS207",
            .message = "module 'zttp:auth' does not export 'requireJWT'",
        },
    };

    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            case.source,
            "handler.ts",
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expectEqualStrings(case.code, result.json_diagnostics.items[0].code);
        try std.testing.expectEqualStrings(case.message, result.json_diagnostics.items[0].message);
    }
}

test "check reports a handler even when it stops before the contract" {
    const allocator = std.testing.allocator;
    const handler = "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    const mistyped = "function handler(req: Request): Response { const n: number = \"x\"; return Response.text(\"ok\"); }\n";
    const helper = "function helper(): string { return \"ok\"; }\n";
    const unparsed = "function handler(req: Request): Response { var n = 1; return Response.text(\"ok\"); }\n";
    const cases = [_]struct { source: []const u8, skip_contract: bool, has_handler: ?bool }{
        .{ .source = handler, .skip_contract = true, .has_handler = true },
        .{ .source = mistyped, .skip_contract = false, .has_handler = true },
        .{ .source = helper, .skip_contract = true, .has_handler = false },
        .{ .source = unparsed, .skip_contract = false, .has_handler = null },
    };
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = case.skip_contract,
        });
        defer result.deinit(allocator);
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(case.has_handler, result.has_handler);
    }
}

test "check without a handler does not claim state isolation" {
    const allocator = std.testing.allocator;
    const source =
        \\const greeting: string = "hi";
        \\function helper(): string { return greeting; }
        \\
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "lib.ts", .{ .json_mode = true });
    defer result.deinit(allocator);

    try std.testing.expect(!result.verify_ran);
    try std.testing.expect(!result.state_isolated);
    try std.testing.expect(!result.no_unreachable);
    const props = (result.contract orelse return error.TestUnexpectedResult).properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(!props.state_isolated);
}

test "check records unreachable code in the contract verification" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\  return Response.text("never");
        \\}
        \\
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.verify_errors);
    try std.testing.expect(!result.no_unreachable);
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const verification = contract.verification orelse return error.TestUnexpectedResult;
    try std.testing.expect(verification.unreachable_code);
}

// The obligation past the sixteenth member of a generic intersection.
//
// `instantiateCompositeMembers` once copied members into a fixed `[16]TypeIndex`
// buffer and rebuilt the intersection from that prefix, so a seventeenth member
// was dropped and the value that should have failed it was accepted. The copy is
// allocator-backed now, and `type_env.zig` unit-tests that seventeen members
// survive the pool. These two cases assert the end-user verdict instead: what
// `zts check` answers about a value that violates only the last obligation.
//
// The fixture must keep its generic application. `instantiateCompositeMembers`
// returns `.unchanged` when no member changed, so an intersection of plain record
// literals never rebuilds from the copied prefix - measured: the same seventeen
// members written without `Box<string>` reject under the truncating implementation
// too, and would have stood here as a permanent false pass.
const wide_intersection_members =
    \\structural Box<T> = { boxed: T };
    \\structural Wide =
    \\  Box<string> &
    \\  { f01: string } & { f02: string } & { f03: string } & { f04: string } &
    \\  { f05: string } & { f06: string } & { f07: string } & { f08: string } &
    \\  { f09: string } & { f10: string } & { f11: string } & { f12: string } &
    \\  { f13: string } & { f14: string } & { f15: string } &
    \\  { last: string };
    \\
;

const wide_intersection_satisfied =
    \\function handler(req: Request): Response {
    \\  const v: Wide = { boxed: "b", f01: "v", f02: "v", f03: "v", f04: "v",
    \\    f05: "v", f06: "v", f07: "v", f08: "v", f09: "v", f10: "v", f11: "v",
    \\    f12: "v", f13: "v", f14: "v", f15: "v", last: "v" };
    \\  return Response.json(v);
    \\}
    \\
;

const wide_intersection_violated =
    \\function handler(req: Request): Response {
    \\  const v: Wide = { boxed: "b", f01: "v", f02: "v", f03: "v", f04: "v",
    \\    f05: "v", f06: "v", f07: "v", f08: "v", f09: "v", f10: "v", f11: "v",
    \\    f12: "v", f13: "v", f14: "v", f15: "v" };
    \\  return Response.json(v);
    \\}
    \\
;

test "generic intersection fixture carries the members it claims" {
    // The floor. Both assertions below are about the seventeenth member, and a
    // fixture that lost a member, or lost `Box<`, satisfies them over a shape
    // that cannot reproduce the defect at all.
    try std.testing.expect(std.mem.indexOf(u8, wide_intersection_members, "Box<string>") != null);
    try std.testing.expectEqual(@as(usize, 16), std.mem.count(u8, wide_intersection_members, ": string }"));
    try std.testing.expect(std.mem.indexOf(u8, wide_intersection_members, "{ last: string }") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_intersection_violated, "last:") == null);
    try std.testing.expect(std.mem.indexOf(u8, wide_intersection_satisfied, "last: \"v\"") != null);
}

test "zts check rejects a value that violates only the seventeenth intersection member" {
    const allocator = std.testing.allocator;
    const source = try std.mem.concat(allocator, u8, &.{ wide_intersection_members, wide_intersection_violated });
    defer allocator.free(source);

    var check = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer check.deinit(allocator);

    // The exact count, not "more than zero": a second type error would mean the
    // fixture stopped isolating the obligation it names.
    try std.testing.expectEqual(@as(u32, 1), check.type_errors);
    try std.testing.expectEqual(@as(u32, 0), check.parse_errors);
}

test "zts check accepts the same value once the seventeenth member is satisfied" {
    const allocator = std.testing.allocator;
    const source = try std.mem.concat(allocator, u8, &.{ wide_intersection_members, wide_intersection_satisfied });
    defer allocator.free(source);

    var check = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer check.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), check.type_errors);
    try std.testing.expectEqual(@as(u32, 0), check.parse_errors);
}

// An intersection member spelled as a name carries the same weight as one
// spelled inline.
//
// `resolveType` substitutes an alias name only when the whole annotation matches
// it, so a name written inside a compound expression stays a `t_ref`
// (`type_env.zig`, "TypeEnv intersection alias type AB = A & B"). An unresolved
// name reaches the blanket-true that D1 amendment A1 will delete, so the member
// was discharged instead of checked: this pair once measured 0 named against 1
// inline, the same value missing the same field.
//
// The intersection-target loop applies A1's rule at that one site now
// (`type_pool.zig`, "Intersection target"), so both spellings reject. The pair
// stays because the asymmetry is what a regression here looks like: a change
// that reopens the fail-open moves `named` back to 0 while leaving `inlined`
// green, and only the contrast catches that.
const named_intersection_members =
    \\structural A = { a: string };
    \\structural B = { b: string };
    \\structural AB = A & B;
    \\function handler(req: Request): Response {
    \\  const v: AB = { a: "x" };
    \\  return Response.json(v);
    \\}
    \\
;

const inline_intersection_members =
    \\structural AB = { a: string } & { b: string };
    \\function handler(req: Request): Response {
    \\  const v: AB = { a: "x" };
    \\  return Response.json(v);
    \\}
    \\
;

test "a named intersection member is checked, like the inline spelling" {
    const allocator = std.testing.allocator;

    var named = try runCheckOnlyFromSourceWithOptions(allocator, named_intersection_members, "handler.ts", .{
        .json_mode = true,
    });
    defer named.deinit(allocator);
    var inlined = try runCheckOnlyFromSourceWithOptions(allocator, inline_intersection_members, "handler.ts", .{
        .json_mode = true,
    });
    defer inlined.deinit(allocator);

    // Neither source may fail to parse, or both counts below are zero for a
    // reason that has nothing to do with assignability.
    try std.testing.expectEqual(@as(u32, 0), named.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), inlined.parse_errors);

    // The contrast is the claim: the same missing field, rejected either way.
    // Asserting both, rather than only the named case, is what makes a silent
    // return to the fail-open visible.
    try std.testing.expectEqual(@as(u32, 1), inlined.type_errors);
    try std.testing.expectEqual(@as(u32, 1), named.type_errors);
}

test "check keeps typed imported builtin methods deterministic" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data =
        \\import { normalizeLabel } from "./label.ts";
        \\function handler(req: Request): Response {
        \\  const body = req.body ?? "";
        \\  return Response.json({ label: normalizeLabel(body) });
        \\}
        \\
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "label.ts", .data =
        \\export structural LabelText = string;
        \\export structural NormalizedLabel = string;
        \\export function normalizeLabel(text: LabelText): NormalizedLabel {
        \\  return text.trim().toLowerCase();
        \\}
        \\
    });
    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
    defer allocator.free(handler_path);

    var result = try runCheckOnlyWithOptions(allocator, handler_path, .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(properties.deterministic);
    try std.testing.expect(properties.idempotent);
    try std.testing.expect(properties.no_secret_leakage);
    try std.testing.expect(properties.no_credential_leakage);
}

/// A handler file with sibling modules in one temporary directory, for the
/// cross-file flow tests. `check` runs the analyzer the way `zttp check` does.
const SiblingFixture = struct {
    tmp: std.testing.TmpDir,
    handler_path: [:0]u8,

    fn init(handler_source: []const u8) !SiblingFixture {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = handler_source });
        const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
        return .{ .tmp = tmp, .handler_path = handler_path };
    }

    fn deinit(self: *SiblingFixture) void {
        std.testing.allocator.free(self.handler_path);
        self.tmp.cleanup();
    }

    fn add(self: *SiblingFixture, name: []const u8, source: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = source });
    }

    fn check(self: *SiblingFixture) !CheckResult {
        return runCheckOnlyWithOptions(std.testing.allocator, self.handler_path, .{ .json_mode = true });
    }
};

/// The check refused the handler: no contract, one error counted, and the first
/// finding has `code` under `file_name` in the directory of the fixture.
fn expectRefusedAt(fixture: *const SiblingFixture, result: *const CheckResult, code: []const u8, file_name: []const u8) !void {
    const allocator = std.testing.allocator;
    const directory = std.fs.path.dirname(fixture.handler_path) orelse return error.TestUnexpectedResult;
    const expected = try std.fs.path.join(allocator, &.{ directory, file_name });
    defer allocator.free(expected);
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expect(result.json_diagnostics.items.len >= 1);
    try std.testing.expectEqualStrings(code, result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings(expected, result.json_diagnostics.items[0].file);
}

fn hasDiagnosticCode(result: *const CheckResult, code: []const u8) bool {
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

/// The first diagnostic with `code`, or null.
fn diagnosticWithCode(result: *const CheckResult, code: []const u8) ?json_diag.JsonDiagnostic {
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code)) return d;
    }
    return null;
}

const sibling_cache_writer =
    \\import { cacheSet } from "zttp:cache";
    \\export function save(): undefined {
    \\  cacheSet("items", "key", "value");
    \\  return undefined;
    \\}
    \\
;

test "CHECK applies a sibling writer effect to handler properties" {
    var fixture = try SiblingFixture.init(
        \\import { save } from "./dep.ts";
        \\function handler(req: Request): Proof<Response, "read_only" | "retry_safe"> {
        \\  save();
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", sibling_cache_writer);

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
    try std.testing.expect(!properties.idempotent);
    var refused_read_only = false;
    var refused_retry_safe = false;
    // The merged contract lists the module of the dependency, as the build does:
    // `read_only` is incompatible with the import (ZTS501), and `retry_safe` is
    // not discharged (ZTS500).
    for (result.contract.?.spec_diagnostics.items) |diagnostic| {
        if (diagnostic.kind == .incompatible_with_import and std.mem.eql(u8, diagnostic.spec_name, "read_only")) refused_read_only = true;
        if (diagnostic.kind == .not_discharged and std.mem.eql(u8, diagnostic.spec_name, "retry_safe")) refused_retry_safe = true;
    }
    try std.testing.expect(refused_read_only);
    try std.testing.expect(refused_retry_safe);
}

test "CHECK applies sibling effects through an alias and a holder" {
    const cases = [_]struct {
        imported_name: []const u8,
        call: []const u8,
        dependency: []const u8,
    }{
        .{
            .imported_name = "saveAlias",
            .call = "saveAlias()",
            .dependency =
            \\import { cacheSet } from "zttp:cache";
            \\function save(): undefined { cacheSet("items", "key", "value"); return undefined; }
            \\export const saveAlias = save;
            \\
            ,
        },
        .{
            .imported_name = "holder",
            .call = "holder.save()",
            .dependency =
            \\import { cacheSet } from "zttp:cache";
            \\function save(): undefined { cacheSet("items", "key", "value"); return undefined; }
            \\export const holder: { save: () => undefined } = { save: save };
            \\
            ,
        },
    };

    for (cases) |case| {
        const handler = try std.testing.allocator.print("import {{ {s} }} from \"./dep.ts\";\nfunction handler(req: Request): Response {{ {s}; return Response.text(\"ok\"); }}\n", .{ case.imported_name, case.call });
        defer std.testing.allocator.free(handler);
        var fixture = try SiblingFixture.init(handler);
        defer fixture.deinit();
        try fixture.add("dep.ts", case.dependency);

        var result = try fixture.check();
        defer result.deinit(std.testing.allocator);
        const properties = result.contract.?.properties.?;
        try std.testing.expect(!properties.read_only);
        try std.testing.expect(!properties.retry_safe);
    }
}

test "CHECK applies a sibling writer effect through two imports" {
    var fixture = try SiblingFixture.init(
        \\import { relay } from "./a.ts";
        \\function handler(req: Request): Response { relay(); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { save } from "./dep.ts";
        \\export function relay(): undefined { return save(); }
        \\
    );
    try fixture.add("dep.ts", sibling_cache_writer);

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
}

test "CHECK reports incomplete effects for an imported callback invocation" {
    var fixture = try SiblingFixture.init(
        \\import { run } from "./dep.ts";
        \\function clean(): undefined { return undefined; }
        \\function handler(req: Request): Response { run(clean); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function run(callback: () => undefined): undefined { callback(); return undefined; }
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
    try std.testing.expect(properties.has_egress);
    try std.testing.expect(!contract.effect_analysis_complete);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.proof_trace_json orelse return error.TestUnexpectedResult,
        "Effect analysis is incomplete",
    ) != null);
}

test "CHECK preserves sibling cache reads and egress facts" {
    const cases = [_]struct {
        name: []const u8,
        dependency: []const u8,
        stateless: bool,
        has_egress: bool,
    }{
        .{
            .name = "readIt",
            .dependency =
            \\import { cacheGet } from "zttp:cache";
            \\export function readIt(): string | undefined { return cacheGet("items", "key"); }
            \\
            ,
            .stateless = false,
            .has_egress = false,
        },
        .{
            .name = "readIt",
            .dependency =
            \\import { fetch } from "zttp:fetch";
            \\export function readIt(): string { fetch("https://example.com"); return "x"; }
            \\
            ,
            .stateless = false,
            .has_egress = true,
        },
    };

    for (cases) |case| {
        const handler = try std.testing.allocator.print("import {{ {s} }} from \"./dep.ts\";\nfunction handler(req: Request): Response {{ return Response.text({s}() ?? \"\"); }}\n", .{ case.name, case.name });
        defer std.testing.allocator.free(handler);
        var fixture = try SiblingFixture.init(handler);
        defer fixture.deinit();
        try fixture.add("dep.ts", case.dependency);

        var result = try fixture.check();
        defer result.deinit(std.testing.allocator);
        const properties = result.contract.?.properties.?;
        try std.testing.expectEqual(case.stateless, properties.stateless);
        try std.testing.expectEqual(case.has_egress, properties.has_egress);
    }
}

test "CHECK keeps pure and data sibling controls clean" {
    var fixture = try SiblingFixture.init(
        \\import { pure, label } from "./dep.ts";
        \\function handler(req: Request): Response { return Response.text(pure(label)); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function pure(value: string): string { return value.toUpperCase(); }
        \\export const label = "clean";
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(properties.read_only);
    try std.testing.expect(properties.retry_safe);
    try std.testing.expect(properties.stateless);
    try std.testing.expect(!properties.has_egress);
}

test "CHECK reports a ZTS310 warning for a push onto an imported const array" {
    var fixture = try SiblingFixture.init(
        \\import { seen } from "./dep.ts";
        \\function pick(): number[] {
        \\  return seen;
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  const alias = pick();
        \\  alias.push(1);
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export const seen: number[] = [];
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(!result.state_isolated);
    const diagnostic = diagnosticWithCode(&result, "ZTS310") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("warning", diagnostic.severity);
    try std.testing.expectEqual(@as(u32, 7), diagnostic.line);
}

fn countDiagnosticsWithCode(result: *const CheckResult, code: []const u8) usize {
    var count: usize = 0;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code)) count += 1;
    }
    return count;
}

/// The check has exactly one ZTS310 finding. It is a warning at `line` of
/// `file_name` in the directory of the fixture.
fn expectOneStateWriteAt(fixture: *const SiblingFixture, result: *const CheckResult, file_name: []const u8, line: u32) !void {
    const allocator = std.testing.allocator;
    const directory = std.fs.path.dirname(fixture.handler_path) orelse return error.TestUnexpectedResult;
    const expected = try std.fs.path.join(allocator, &.{ directory, file_name });
    defer allocator.free(expected);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticsWithCode(result, "ZTS310"));
    const diagnostic = diagnosticWithCode(result, "ZTS310") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("warning", diagnostic.severity);
    try std.testing.expectEqualStrings(expected, diagnostic.file);
    try std.testing.expectEqual(line, diagnostic.line);
}

const sibling_record_handler =
    \\import { record } from "./dep.ts";
    \\function handler(req: Request): Proof<Response, "result_safe"> {
    \\  record();
    \\  return Response.text("ok");
    \\}
    \\
;

test "CHECK reports a ZTS310 warning at the push of a dependency onto its own module array" {
    var fixture = try SiblingFixture.init(sibling_record_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\const seen: number[] = [];
        \\export function record(): undefined {
        \\  seen.push(1);
        \\  return undefined;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.state_isolated);
    try expectOneStateWriteAt(&fixture, &result, "dep.ts", 3);
}

test "CHECK keeps the position of a flow-only dependency ZTS310 whose column passes the end of the entry line" {
    // Line 3 of the entry, `  record();`, has 11 columns. Reading the
    // dependency position 3:23 against the entry text carried it onto line 4.
    // Only the flow evaluator finds this write, so its row joins the result
    // after the entry rows.
    var fixture = try SiblingFixture.init(sibling_record_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  const n = 1; xs.push(n);
        \\  return undefined;
        \\}
        \\export function record(): undefined {
        \\  addTo(seen);
        \\  return undefined;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try expectOneStateWriteAt(&fixture, &result, "dep.ts", 3);
    const diagnostic = diagnosticWithCode(&result, "ZTS310") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 23), diagnostic.column);
}

test "CHECK reports a ZTS310 warning at a dependency push that only the flow evaluator finds" {
    var fixture = try SiblingFixture.init(sibling_record_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\export function record(): undefined {
        \\  addTo(seen);
        \\  return undefined;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.state_isolated);
    try expectOneStateWriteAt(&fixture, &result, "dep.ts", 3);
}

const sibling_add_helper =
    \\export function addTo(xs: number[]): undefined {
    \\  xs.push(1);
    \\  return undefined;
    \\}
    \\
;

test "CHECK reports a ZTS310 warning in the helper that writes an imported array passed to it" {
    var fixture = try SiblingFixture.init(
        \\import { seen } from "./data.ts";
        \\import { addTo } from "./helpers.ts";
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  addTo(seen);
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("data.ts", "export const seen: number[] = [];\n");
    try fixture.add("helpers.ts", sibling_add_helper);

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.state_isolated);
    try expectOneStateWriteAt(&fixture, &result, "helpers.ts", 2);
}

test "CHECK keeps state_isolated when an imported helper writes a request-local array" {
    var fixture = try SiblingFixture.init(
        \\import { addTo } from "./helpers.ts";
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  const local: number[] = [];
        \\  addTo(local);
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("helpers.ts", sibling_add_helper);

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.state_isolated);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticsWithCode(&result, "ZTS310"));
}

test "CHECK keeps state_isolated when a dependency writes a local array during module initialization" {
    var fixture = try SiblingFixture.init(
        \\import { table } from "./dep.ts";
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(table.length));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\function build(): number[] {
        \\  const out: number[] = [];
        \\  out.push(1);
        \\  return out;
        \\}
        \\export const table: number[] = build();
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.state_isolated);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticsWithCode(&result, "ZTS310"));
}

// The verifier names the push inside `build` whether or not a request runs it,
// so a write during initialization alone still removes state_isolated.
test "CHECK reports the verifier ZTS310 for a dependency helper that writes its module array during initialization" {
    var fixture = try SiblingFixture.init(
        \\import { table } from "./dep.ts";
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(table.length));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\const log: number[] = [];
        \\function build(): number[] {
        \\  log.push(1);
        \\  return log;
        \\}
        \\export const table: number[] = build();
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.state_isolated);
    try expectOneStateWriteAt(&fixture, &result, "dep.ts", 3);
}

test "CHECK does not classify a factory-produced callable as data" {
    var fixture = try SiblingFixture.init(
        \\import { save } from "./dep.ts";
        \\function handler(req: Request): Response { save(); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { cacheSet } from "zttp:cache";
        \\function writer(): undefined { cacheSet("items", "key", "value"); return undefined; }
        \\function factory(): () => undefined { return writer; }
        \\export const save = factory();
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
}

test "CHECK refuses a sibling that is missing, lacks the export, or does not parse" {
    const cases = [_]struct { dependency: ?[]const u8, code: []const u8, file: []const u8 }{
        .{ .dependency = null, .code = "ZTS063", .file = "handler.ts" },
        .{ .dependency = "export function other(): string { return \"ok\"; }\n", .code = "ZTS063", .file = "handler.ts" },
        .{ .dependency = "export function work( {{{\n", .code = "ZTS001", .file = "dep.ts" },
    };
    for (cases) |case| {
        const dependency = case.dependency;
        var fixture = try SiblingFixture.init(
            \\import { work } from "./dep.ts";
            \\function handler(req: Request): Response { work(); return Response.text("ok"); }
            \\
        );
        defer fixture.deinit();
        if (dependency) |source| try fixture.add("dep.ts", source);

        var result = try fixture.check();
        defer result.deinit(std.testing.allocator);
        try expectRefusedAt(&fixture, &result, case.code, case.file);
    }
}

test "CHECK refuses an import cycle between siblings, under the first module of the cycle" {
    var fixture = try SiblingFixture.init(
        \\import { first } from "./a.ts";
        \\function handler(req: Request): Response { first(); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { second } from "./b.ts";
        \\export function first(): undefined { return second(); }
        \\
    );
    try fixture.add("b.ts",
        \\import { first } from "./a.ts";
        \\export function second(): undefined { return first(); }
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try expectRefusedAt(&fixture, &result, "ZTS063", "a.ts");
}

// The module graph has no depth limit, as the build has none: the effects of
// all eight files are known and none writes. The fault scan keeps its limit of
// `max_import_depth` files, so `fault_covered` stays unproven.
test "CHECK follows a chain of eight siblings and leaves fault_covered unproven" {
    var fixture = try SiblingFixture.init(
        \\import { f0 } from "./f0.ts";
        \\function handler(req: Request): Response { f0(); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    for (0..max_import_depth) |index| {
        const name = try std.testing.allocator.print("f{d}.ts", .{index});
        defer std.testing.allocator.free(name);
        const source = if (index + 1 < max_import_depth)
            try std.testing.allocator.print("import {{ f{d} }} from \"./f{d}.ts\";\nexport function f{d}(): undefined {{ return f{d}(); }}\n", .{ index + 1, index + 1, index, index + 1 })
        else
            try std.testing.allocator.print("export function f{d}(): undefined {{ return undefined; }}\n", .{index});
        defer std.testing.allocator.free(source);
        try fixture.add(name, source);
    }

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(properties.read_only);
    try std.testing.expect(properties.retry_safe);
    try std.testing.expect(!properties.fault_covered);
}

const logs_param_helper =
    \\import { logInfo } from "zttp:log";
    \\export function logIt(x: string): number {
    \\  logInfo(x, { n: 1 });
    \\  return 1;
    \\}
    \\
;

test "an imported helper that logs its secret parameter refuses the call that passes one" {
    var fixture = try SiblingFixture.init(
        \\import { env } from "zttp:env";
        \\import { logIt } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const s = env("API_TOKEN") ?? "";
        \\  const n = logIt(s);
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", logs_param_helper);
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
    const diag = diagnosticWithCode(&result, "ZTS402") orelse return error.TestExpectedEqual;
    // The report names the importer's call, the same text a direct sink has,
    // and says where in the imported file the sink is.
    try std.testing.expectEqualStrings("secret data flows into console output", diag.message);
    try std.testing.expectEqual(@as(u32, 5), diag.line);
    const dependency_path = try std.fs.path.resolve(std.testing.allocator, &.{ std.fs.path.dirname(fixture.handler_path).?, "dep.ts" });
    defer std.testing.allocator.free(dependency_path);
    try std.testing.expect(std.mem.indexOf(u8, diag.suggestion orelse "", dependency_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.suggestion orelse "", ":3:") != null);
}

test "an imported helper called with a clean literal keeps no_secret_leakage" {
    var fixture = try SiblingFixture.init(
        \\import { logIt } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = logIt("hello");
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", logs_param_helper);
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.contract.?.properties.?.no_secret_leakage);
    try std.testing.expect(!hasDiagnosticCode(&result, "ZTS402"));
}

test "an imported helper that logs its own secret refuses every call" {
    var fixture = try SiblingFixture.init(
        \\import { logOwn } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = logOwn();
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { env } from "zttp:env";
        \\import { logInfo } from "zttp:log";
        \\export function logOwn(): number {
        \\  logInfo(env("API_TOKEN") ?? "", { n: 1 });
        \\  return 1;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
    try std.testing.expect(hasDiagnosticCode(&result, "ZTS402"));
}

test "an imported helper that returns its parameter in a response refuses a secret" {
    var fixture = try SiblingFixture.init(
        \\import { env } from "zttp:env";
        \\import { wrap } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const s = env("API_TOKEN") ?? "";
        \\  return wrap(s);
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function wrap(x: string): Response {
        \\  return Response.json({ v: x });
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
}

test "a sink two imports deep reports at the handler's call" {
    const handler =
        \\import { env } from "zttp:env";
        \\import { relay } from "./a.ts";
        \\function handler(req: Request): Response {
        \\  const s = env("API_TOKEN") ?? "";
        \\  const n = relay(s);
        \\  return Response.json({ ok: n });
        \\}
        \\
    ;
    var fixture = try SiblingFixture.init(handler);
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { logIt } from "./dep.ts";
        \\export function relay(x: string): number {
        \\  return logIt(x);
        \\}
        \\
    );
    try fixture.add("dep.ts", logs_param_helper);
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
    try std.testing.expect(hasDiagnosticCode(&result, "ZTS402"));

    // Control: the same chain called with a literal leaks nothing.
    var clean = try SiblingFixture.init(
        \\import { relay } from "./a.ts";
        \\function handler(req: Request): Response {
        \\  const n = relay("hello");
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer clean.deinit();
    try clean.add("a.ts",
        \\import { logIt } from "./dep.ts";
        \\export function relay(x: string): number {
        \\  return logIt(x);
        \\}
        \\
    );
    try clean.add("dep.ts", logs_param_helper);
    var clean_result = try clean.check();
    defer clean_result.deinit(std.testing.allocator);
    try std.testing.expect(clean_result.contract.?.properties.?.no_secret_leakage);
}

test "an imported helper whose file will not parse is refused under that file" {
    var fixture = try SiblingFixture.init(
        \\import { env } from "zttp:env";
        \\import { logIt } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = logIt(env("API_TOKEN") ?? "");
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", "export function logIt(x: string): number {{{\n");
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try expectRefusedAt(&fixture, &result, "ZTS003", "dep.ts");
}

test "an imported helper with more parameters than the summary cap leaves the secret unproven" {
    var fixture = try SiblingFixture.init(
        \\import { env } from "zttp:env";
        \\import { many } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const s = env("API_TOKEN") ?? "";
        \\  const n = many("a", "b", "c", "d", "e", "f", "g", "h", s);
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { logInfo } from "zttp:log";
        \\export function many(a: string, b: string, c: string, d: string, e: string, f: string, g: string, h: string, i: string): number {
        \\  logInfo(i, { n: 1 });
        \\  return 1;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
}

test "an imported helper that sends its user input to a host demotes the importer's egress properties" {
    var fixture = try SiblingFixture.init(
        \\import { postIt } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = postIt(req.url);
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { fetch } from "zttp:fetch";
        \\export function postIt(x: string): number {
        \\  const r = fetch("https://api.example.com/x", { method: "POST", body: x });
        \\  return 1;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.injection_safe);
    try std.testing.expect(!properties.input_validated);
}

test "an imported helper reads the authorization header of the request it is passed" {
    var fixture = try SiblingFixture.init(
        \\import { audit } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = audit(req);
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { logInfo } from "zttp:log";
        \\export function audit(req: Request): number {
        \\  logInfo(req.headers["authorization"] ?? "", { n: 1 });
        \\  return 1;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.contract.?.properties.?.no_credential_leakage);
}

/// Exercise the public check pipeline. The census below counts properties only
/// after the direct and routed sources both falsify that exact property.
const RoutedPropertyProbe = struct {
    property: []const u8,
    proof_property: ?pcc.proof_system.Property = null,
    flow_property: ?zts.counterexample.PropertyTag = null,
    imports: []const u8 = "",
    globals: []const u8 = "",
    body: []const u8,
};

fn routedPropertySource(allocator: std.mem.Allocator, probe: RoutedPropertyProbe, routed: bool) ![]u8 {
    const annotation = if (std.mem.eql(u8, probe.property, "response_total")) "state_isolated" else probe.property;
    if (!routed) return allocator.print("{s}\n{s}\nfunction handler(req: Request): Proof<Response, \"{s}\"> {{ {s} }}\n", .{ probe.imports, probe.globals, annotation, probe.body });
    return allocator.print("import {{ routerMatch }} from \"zttp:router\";\n{s}\n{s}\n" ++
        "function route(req: Request): Response {{ {s} }}\n" ++
        "const routes = {{ \"GET /probe\": route }};\n" ++
        "function handler(req: Request): Proof<Response, \"{s}\"> {{\n" ++
        "const found = routerMatch(routes, req);\n" ++
        "if (found === undefined) return Response.text(\"not found\", {{ status: 404 }});\n" ++
        "return found.handler(req);\n}}\n", .{ probe.imports, probe.globals, probe.body, annotation });
}

fn routedProbeHolds(comptime property: []const u8, result: CheckResult) !bool {
    if (comptime std.mem.eql(u8, property, "response_total")) return result.exhaustive_returns;
    const contract = result.contract orelse {
        std.debug.print("router census has no contract for {s}\n", .{property});
        for (result.json_diagnostics.items) |diagnostic| {
            std.debug.print("{s}: {s}\n", .{ diagnostic.code, diagnostic.message });
        }
        return error.MissingProbeContract;
    };
    const properties = contract.properties orelse return error.MissingProbeProperties;
    return @field(properties, property);
}

test "router property census observes direct and routed violations for every obligation" {
    const allocator = std.testing.allocator;
    const probes = [_]RoutedPropertyProbe{
        .{ .property = "response_total", .proof_property = .response_total, .body = "if (req.method === \"GET\") return Response.text(\"ok\");" },
        .{ .property = "result_safe", .proof_property = .results_checked, .imports = "import { jwtVerify } from \"zttp:auth\";", .body = "const result = jwtVerify(req.url, \"secret\"); return Response.json({ claims: result.value });" },
        .{ .property = "state_isolated", .proof_property = .state_isolated, .globals = "let counter: number = 0;", .body = "counter = counter + 1; return Response.json({ counter: counter });" },
        .{ .property = "deterministic", .proof_property = .deterministic, .body = "return Response.json({ now: Date.now() });" },
        .{ .property = "read_only", .proof_property = .read_only, .imports = "import { cacheSet } from \"zttp:cache\";", .body = "cacheSet(\"probe\", \"key\", req.url, 60); return Response.text(\"ok\");" },
        .{ .property = "retry_safe", .proof_property = .retry_safe, .imports = "import { cacheSet } from \"zttp:cache\";", .body = "cacheSet(\"probe\", \"key\", req.url, 60); return Response.text(\"ok\");" },
        .{ .property = "no_secret_leakage", .proof_property = .no_secret_leakage, .flow_property = .no_secret_leakage, .imports = "import { env } from \"zttp:env\";", .body = "return Response.json({ key: env(\"SECRET_KEY\") });" },
        .{ .property = "no_credential_leakage", .flow_property = .no_credential_leakage, .body = "return Response.json({ credential: req.headers.get(\"authorization\") });" },
        .{ .property = "input_validated", .flow_property = .input_validated, .imports = "import { fetch } from \"zttp:fetch\";", .body = "fetch(\"https://api.example.com/collect\", { body: req.body ?? \"\" }); return Response.text(\"ok\");" },
        .{ .property = "pii_contained", .flow_property = .pii_contained, .imports = "import { fetch } from \"zttp:fetch\";", .body = "fetch(\"https://example.com\", { method: \"POST\", body: req.url }); return Response.text(\"ok\");" },
        .{ .property = "injection_safe", .flow_property = .injection_safe, .body = "return Response.html(req.url);" },
        .{ .property = "fault_covered", .imports = "import { jwtVerify } from \"zttp:auth\";", .body = "const result = jwtVerify(req.url, \"secret\"); if (!result.ok) return Response.text(\"accepted failure\", { status: 200 }); return Response.text(\"ok\");" },
        .{ .property = "optional_safe", .imports = "import { env } from \"zttp:env\";", .body = "const value = env(\"HOME\"); return Response.json({ length: value.length });" },
    };
    var proof_observed = std.enums.EnumSet(pcc.proof_system.Property).empty;
    var flow_observed = std.enums.EnumSet(zts.counterexample.PropertyTag).empty;
    inline for (probes) |probe| {
        for ([_]bool{ false, true }) |routed| {
            const source = try routedPropertySource(allocator, probe, routed);
            defer allocator.free(source);
            var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "router-census.ts", .{ .json_mode = true });
            defer result.deinit(allocator);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
            if (try routedProbeHolds(probe.property, result)) {
                std.debug.print("router census still proves {s} (routed={})\n", .{ probe.property, routed });
                return error.RoutedPropertyNotRejected;
            }
        }
        if (probe.proof_property) |property| proof_observed.insert(property);
        if (probe.flow_property) |property| flow_observed.insert(property);
    }

    // A capability ceiling is checked through the public policy result. Its
    // module scan covers the whole IR, including route functions.
    const capability_probe = RoutedPropertyProbe{
        .property = "state_isolated",
        .imports = "import { env } from \"zttp:env\";",
        .body = "env(\"FORBIDDEN\"); return Response.text(\"ok\");",
    };
    for ([_]bool{ false, true }) |routed| {
        const source = try routedPropertySource(allocator, capability_probe, routed);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "router-capability-census.ts", .{
            .json_mode = true,
            .policy_source = "{\"env\":{\"allow\":[\"PUBLIC_KEY\"]}}",
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.policy_errors);
        var forbidden_env = false;
        for (result.json_diagnostics.items) |diagnostic| {
            if (std.mem.eql(u8, diagnostic.code, "POL001")) forbidden_env = true;
        }
        try std.testing.expect(forbidden_env);
    }
    proof_observed.insert(.capability_bounded);
    inline for (@typeInfo(pcc.proof_system.Property).@"enum".field_names) |field| {
        try std.testing.expect(proof_observed.contains(@fromBackingInt(@intCast(@backingInt(@field(pcc.proof_system.Property, field))))));
    }
    inline for (@typeInfo(zts.counterexample.PropertyTag).@"enum".field_names) |field| {
        try std.testing.expect(flow_observed.contains(@fromBackingInt(@intCast(@backingInt(@field(zts.counterexample.PropertyTag, field))))));
    }
}

test "router public checks prove clean routes and fail closed on unresolved dispatch" {
    const allocator = std.testing.allocator;
    const clean_probe = RoutedPropertyProbe{
        .property = "deterministic",
        .body = "return Response.text(\"ok\");",
    };
    const source = try routedPropertySource(allocator, clean_probe, true);
    defer allocator.free(source);
    var clean = try runCheckOnlyFromSourceWithOptions(allocator, source, "router-clean.ts", .{ .json_mode = true });
    defer clean.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), clean.totalErrors());
    try std.testing.expect(clean.exhaustive_returns);
    // Route-only analysis paths are not runnable handler behavior samples.
    try std.testing.expect(!clean.contract.?.behaviors_exhaustive);
    const direct_source = try routedPropertySource(allocator, clean_probe, false);
    defer allocator.free(direct_source);
    var direct = try runCheckOnlyFromSourceWithOptions(allocator, direct_source, "direct-clean.ts", .{ .json_mode = true });
    defer direct.deinit(allocator);
    try std.testing.expect(direct.contract.?.behaviors_exhaustive);
    const clean_properties = clean.contract.?.properties.?;
    const checked_fields = .{
        "result_safe",       "optional_safe",         "state_isolated",  "deterministic", "read_only",
        "retry_safe",        "stateless",             "idempotent",      "fault_covered", "cost_bounded",
        "no_secret_leakage", "no_credential_leakage", "input_validated", "pii_contained", "injection_safe",
    };
    inline for (checked_fields) |field| try std.testing.expect(@field(clean_properties, field));

    // An assignment makes the dispatch unstable even though both visible
    // function bodies are clean. No property may treat missing call facts as
    // evidence that the call is safe.
    const unresolved_source =
        \\import { routerMatch } from "zttp:router";
        \\function route(req: Request): Response { return Response.text("ok"); }
        \\const routes = { "GET /probe": route };
        \\routes["GET /probe"] = route;
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    ;
    var unresolved = try runCheckOnlyFromSourceWithOptions(allocator, unresolved_source, "router-unresolved.ts", .{ .json_mode = true });
    defer unresolved.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), unresolved.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), unresolved.type_errors);
    try std.testing.expect(!unresolved.exhaustive_returns);
    const unresolved_properties = unresolved.contract.?.properties.?;
    // The structural verifier still has no exhaustive route facts, and an
    // unresolved dispatch shares state with later requests, so the read-only
    // family is cleared with `deterministic`. Flow can prove the five other
    // properties from the actual clean replacement function.
    const flow_fields = .{ "no_secret_leakage", "no_credential_leakage", "input_validated", "pii_contained", "injection_safe" };
    inline for (checked_fields) |field| {
        const is_flow = comptime blk: {
            for (flow_fields) |flow_field| if (std.mem.eql(u8, field, flow_field)) break :blk true;
            break :blk false;
        };
        try std.testing.expectEqual(is_flow, @field(unresolved_properties, field));
    }
}

// ---------------------------------------------------------------------------
// Fault coverage reads the files the handler imports (R4 unit F2)
// ---------------------------------------------------------------------------

/// A handler whose one `fetch` is checked, and which calls `enrich` from a
/// sibling file. Whether `fault_covered` holds depends on that sibling.
const fault_sibling_handler =
    \\import { fetch } from "zttp:fetch";
    \\import { enrich } from "./dep.ts";
    \\function handler(req: Request): Response {
    \\  const res = fetch("https://api.example.com/a");
    \\  if (!res.ok) {
    \\    return Response.json({ error: "upstream" }, { status: 502 });
    \\  }
    \\  return Response.json({ a: res.body, b: enrich() });
    \\}
    \\
;

const fault_unchecked_helper =
    \\import { fetch } from "zttp:fetch";
    \\export function enrich(): string {
    \\  const res = fetch("https://api.example.com/b");
    \\  return res.body;
    \\}
    \\
;

fn faultCovered(result: *const CheckResult) !bool {
    return (result.contract orelse return error.TestExpectedEqual).properties.?.fault_covered;
}

fn faultUnseenCalls(result: *const CheckResult) !u32 {
    return (result.contract orelse return error.TestExpectedEqual).fault_coverage.?.unseen_calls;
}

/// The text that names the first unseen call, from the handler's provenance.
fn faultCauseSnippet(result: *const CheckResult) ![]const u8 {
    const contract = result.contract orelse return error.TestExpectedEqual;
    const cause = contract.property_provenance.fault_covered orelse return error.TestExpectedEqual;
    return cause.snippet;
}

test "a sibling helper with an unchecked fetch blocks fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts", fault_unchecked_helper);
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqual(@as(u32, 1), try faultUnseenCalls(&result));
    // The cause sits on the handler's import line and names the sibling.
    const cause = result.contract.?.property_provenance.fault_covered.?;
    try std.testing.expectEqual(@as(u32, 2), cause.line);
    try std.testing.expectEqualStrings("fetch in ./dep.ts", cause.snippet);
    // The proof trace prints the same text.
    try std.testing.expect(std.mem.indexOf(u8, result.proof_trace_json orelse "", "The first is `fetch in ./dep.ts`.") != null);
}

test "a sibling helper with only pure code keeps fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function enrich(): string {
        \\  return "pure".toUpperCase();
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(try faultCovered(&result));
    try std.testing.expectEqual(@as(u32, 0), try faultUnseenCalls(&result));
    try std.testing.expect(result.contract.?.property_provenance.fault_covered == null);
}

test "a failable call two files deep blocks fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { inner } from "./deeper.ts";
        \\export function enrich(): string {
        \\  return inner();
        \\}
        \\
    );
    try fixture.add("deeper.ts",
        \\import { fetch } from "zttp:fetch";
        \\export function inner(): string {
        \\  const res = fetch("https://api.example.com/c");
        \\  return res.body;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqualStrings("fetch in ./deeper.ts", try faultCauseSnippet(&result));
}

test "a sibling that exports a failable builtin as a value blocks fault_covered" {
    var fixture = try SiblingFixture.init(
        \\import { fetch } from "zttp:fetch";
        \\import { enrich } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok) {
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  const kept = enrich;
        \\  return Response.json({ a: res.body });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { fetch } from "zttp:fetch";
        \\export const enrich = fetch;
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqualStrings("fetch in ./dep.ts", try faultCauseSnippet(&result));
}

test "a sibling that does not exist is refused at the handler" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try expectRefusedAt(&fixture, &result, "ZTS063", "handler.ts");
}

test "a sibling that does not parse is refused under that sibling" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts", "export function enrich( {{{\n");
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try expectRefusedAt(&fixture, &result, "ZTS001", "dep.ts");
}

test "a bare specifier import blocks fault_covered" {
    var fixture = try SiblingFixture.init(
        \\import { fetch } from "zttp:fetch";
        \\import { identity } from "lodash";
        \\function handler(req: Request): Response {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok) {
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  return Response.json({ a: res.body });
        \\}
        \\
    );
    defer fixture.deinit();
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqualStrings("lodash (not a relative path)", try faultCauseSnippet(&result));
}

test "an import cycle through the handler is refused under the handler" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    // The helper imports the handler back.
    try fixture.add("dep.ts",
        \\import { handler } from "./handler.ts";
        \\export function enrich(): string {
        \\  return "x";
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try expectRefusedAt(&fixture, &result, "ZTS063", "handler.ts");
}

test "an import cycle between siblings is refused under the first sibling of the cycle" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { other } from "./other.ts";
        \\export function enrich(): string {
        \\  return other();
        \\}
        \\
    );
    try fixture.add("other.ts",
        \\import { enrich } from "./dep.ts";
        \\import { fetch } from "zttp:fetch";
        \\export function other(): string {
        \\  const res = fetch("https://api.example.com/d");
        \\  return res.body;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try expectRefusedAt(&fixture, &result, "ZTS063", "dep.ts");
}

test "two names imported from one failing sibling count once per record" {
    var fixture = try SiblingFixture.init(
        \\import { fetch } from "zttp:fetch";
        \\import { enrich, extra } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok) {
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  return Response.json({ a: res.body, b: enrich(), c: extra() });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { fetch } from "zttp:fetch";
        \\export function enrich(): string {
        \\  const res = fetch("https://api.example.com/b");
        \\  return res.body;
        \\}
        \\export function extra(): string {
        \\  return "x";
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    // One unseen call for each import record, not for each call site.
    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqual(@as(u32, 2), try faultUnseenCalls(&result));
}

test "a chain of imports past the depth limit blocks fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    // dep.ts -> f1.ts -> ... -> f9.ts, nine files below the handler.
    try fixture.add("dep.ts",
        \\import { f1 } from "./f1.ts";
        \\export function enrich(): string { return f1(); }
        \\
    );
    var index: usize = 1;
    while (index <= 9) : (index += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.ts", .{index});
        var body_buf: [128]u8 = undefined;
        const body = if (index < 9)
            try std.fmt.bufPrint(&body_buf, "import {{ f{d} }} from \"./f{d}.ts\";\nexport function f{d}(): string {{ return f{d}(); }}\n", .{ index + 1, index + 1, index, index + 1 })
        else
            try std.fmt.bufPrint(&body_buf, "export function f9(): string {{ return \"end\"; }}\n", .{});
        try fixture.add(name, body);
    }
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expect(std.mem.endsWith(u8, try faultCauseSnippet(&result), "(import chain too deep)"));
}

test "collectImportedFailableCalls answers every non-builtin record" {
    const handler_source =
        \\import { fetch } from "zttp:fetch";
        \\import { enrich } from "./dep.ts";
        \\import { identity } from "lodash";
        \\function handler(req) {
        \\  return Response.json({ a: identity(enrich()) });
        \\}
        \\
    ;
    var fixture = try SiblingFixture.init(handler_source);
    defer fixture.deinit();
    try fixture.add("dep.ts", "export function enrich(): string { return \"x\"; }\n");

    const allocator = std.testing.allocator;
    var parser = try zts.parser.JsParser.initAdmission(allocator, allocator, handler_source, .compile);
    defer parser.deinit();
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var facts = try zts.pipeline.buildModuleFacts(allocator, zts.pipeline.ParsedModule.fromExisting(view, root, &atoms), null);
    defer facts.deinit();

    var scan = (try collectImportedFailableCalls(allocator, &facts, fixture.handler_path, null)) orelse return error.TestExpectedEqual;
    defer scan.deinit(allocator);

    // `fetch` is a builtin and has no entry; the other two records do.
    try std.testing.expectEqual(@as(usize, 2), scan.entries.items.len);
    var clean: usize = 0;
    var blocked: usize = 0;
    for (scan.entries.items) |entry| switch (entry.scan) {
        .clean => clean += 1,
        .blocked => |b| {
            blocked += 1;
            try std.testing.expectEqual(zts.PathGenerator.BlockReason.not_relative, b.reason);
        },
        .failable => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 1), clean);
    try std.testing.expectEqual(@as(usize, 1), blocked);
}

// ---------------------------------------------------------------------------
// Public CHECK reader trace
// ---------------------------------------------------------------------------

/// Records each resolved request path and serves the matching source revision.
const TracingImportReader = struct {
    sources: []const []const u8,
    paths: std.ArrayList([]u8) = .empty,

    fn deinit(self: *TracingImportReader, allocator: std.mem.Allocator) void {
        for (self.paths.items) |path| allocator.free(path);
        self.paths.deinit(allocator);
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *TracingImportReader = @ptrCast(@alignCast(context));
        const read_index = self.paths.items.len;
        const path_copy = try allocator.dupe(u8, path);
        self.paths.append(allocator, path_copy) catch |err| {
            allocator.free(path_copy);
            return err;
        };
        if (read_index >= self.sources.len) return error.UnexpectedRead;
        return allocator.dupe(u8, self.sources[read_index]);
    }

    fn reader(self: *TracingImportReader) ImportReader {
        return .{ .context = self, .read = read };
    }
};

test "flow loading of a single module borrows a virtual JavaScript parser and stays incomplete for a bare specifier" {
    const allocator = std.testing.allocator;
    const source = "import { greet } from \"lodash\"; function handler(req) { return greet(); }";
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var parsed = zts.pipeline.ParsedModule.fromExisting(view, root, &atoms);
    parsed.scopes = &parser.scopes;
    var facts = try zts.pipeline.buildModuleFacts(allocator, parsed, null);
    defer facts.deinit();
    var graph = try flowModulesForSingleModule(allocator, parsed, source, &facts, "/virtual/<handler>");
    defer graph.deinit();
    try std.testing.expect(!graph.complete);
    try std.testing.expectEqual(@as(usize, 1), graph.views.items.len);
    try std.testing.expect(graph.views.items[0].atoms == &atoms);
    try std.testing.expectEqual(view.nodeCount(), graph.views.items[0].ir_view.nodeCount());
    try std.testing.expectEqual(@as(usize, 0), graph.views.items[0].imports.len);
    try std.testing.expectEqual(@as(usize, 0), graph.imported_effects.items.len);
    try std.testing.expectEqualSlices(zts.pipeline.FlowModuleId, &.{0}, graph.initialization_order.items);
}

test "flow loading of a single module is complete when every import is a builtin" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response { return Response.text(env("NAME") ?? ""); }
    ;
    var source_owner: zts.DirectCheckSource = undefined;
    try source_owner.initInPlace(allocator, allocator, source, "/virtual/handler.ts");
    defer source_owner.deinit();
    const parsed = zts.parsedModuleFromDirectCheck(&source_owner) orelse return error.TestUnexpectedResult;
    var facts = try zts.pipeline.buildModuleFacts(allocator, parsed, null);
    defer facts.deinit();
    var graph = try flowModulesForSingleModule(allocator, parsed, source, &facts, "/virtual/handler.ts");
    defer graph.deinit();
    try std.testing.expect(graph.complete);
    try std.testing.expectEqual(@as(usize, 1), graph.views.items.len);
    try std.testing.expectEqualSlices(zts.pipeline.FlowModuleId, &.{0}, graph.initialization_order.items);
}

test "CHECK reads a shared dependency once in the graph and once in the fault scan" {
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { outer as first } from "./a.ts";
        \\import { outer as second } from "./a.ts";
        \\function handler(req: Request): Proof<Response, "no_secret_leakage" | "canonical"> {
        \\  return Response.json({ a: first(), b: second() });
        \\}
        \\
    ;
    const parent =
        \\import { inner } from "./b.ts";
        \\export function outer(): string { return inner(); }
        \\
    ;
    // The second read of b.ts is the one that the fault scan sees. It holds an
    // unchecked fetch that the graph read did not contain.
    const sources = [_][]const u8{
        parent,
        "export function inner(): string { return \"first\"; }\n",
        parent,
        "export function inner(): string { return \"second\"; }\n" ++ fault_unchecked_helper,
    };
    var reader: TracingImportReader = .{ .sources = &sources };
    defer reader.deinit(allocator);

    var result = try runCheckOnlyFromSourceWithOptions(allocator, handler_source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = reader.reader(),
    });
    defer result.deinit(allocator);

    const expected_paths = [_][]const u8{ "/virtual/a.ts", "/virtual/b.ts", "/virtual/a.ts", "/virtual/b.ts" };
    try std.testing.expectEqual(expected_paths.len, reader.paths.items.len);
    for (expected_paths, reader.paths.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(result.imports_complete);
    try std.testing.expect(!try faultCovered(&result));
}

test "CHECK keeps the reader trace for two names imported from one file" {
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { first, second } from "./lib.ts";
        \\function handler(req: Request): Proof<Response, "no_secret_leakage" | "canonical"> {
        \\  return Response.json({ first: first(), second: second() });
        \\}
        \\
    ;
    // The module graph reads the file once, and the fault scan reads it once
    // more through the same reader. The first revision writes and holds an
    // unchecked fetch, so the effects and the egress come from the read of the
    // graph. Only the second revision is fault-clean, so a fault scan that
    // reused the first read would fail the unseen-call assertion.
    const reader_sources = [_][]const u8{
        "import { cacheSet } from \"zttp:cache\";\n" ++
            "export function first(): string { cacheSet(\"n\", \"k\", \"v\"); return \"first\"; }\n" ++
            "export function second(): string { return \"second\"; }\n" ++
            fault_unchecked_helper,
        "export function first(): string { return \"first\"; }\n" ++
            "export function second(): string { return \"second\"; }\n",
    };
    var tracing_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer tracing_reader.deinit(allocator);

    var result = try runCheckOnlyFromSourceWithOptions(allocator, handler_source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = tracing_reader.reader(),
    });
    defer result.deinit(allocator);

    const expected_paths = [_][]const u8{
        "/virtual/lib.ts",
        "/virtual/lib.ts",
    };
    try std.testing.expectEqual(expected_paths.len, tracing_reader.paths.items.len);
    for (expected_paths, tracing_reader.paths.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }

    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(u32, 1), result.paths_enumerated);
    try std.testing.expect(result.paths_exhaustive);
    try std.testing.expect(result.proof_trace_json != null);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(properties.no_secret_leakage);
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
    try std.testing.expect(!properties.idempotent);
    try std.testing.expect(!properties.stateless);
    try std.testing.expect(properties.has_egress);
    try std.testing.expectEqual(true, properties.fault_covered);
    try std.testing.expectEqual(@as(usize, 1), contract.behaviors.items.len);
    try std.testing.expect(contract.behaviors_exhaustive);
    try std.testing.expectEqual(handler_contract.FaultCoverageInfo{
        .total_failable = 0,
        .covered = 0,
        .warnings = 0,
        .unseen_calls = 0,
        .upstream_fallback_sites = 0,
        .analysis_complete = true,
    }, contract.fault_coverage orelse return error.TestUnexpectedResult);
}

test "CHECK refuses an imported file with an unterminated string, under the path of that file" {
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { clean } from "./lib.ts";
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(clean("x"));
        \\}
        \\
    ;
    const dependency =
        "const marker: \"open\n" ++
        " = \"open\";\n" ++
        "export function clean(value: string): string { return value.toUpperCase(); }\n";
    const reader_sources = [_][]const u8{ dependency, dependency };
    var tracing_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer tracing_reader.deinit(allocator);

    var result = try runCheckOnlyFromSourceWithOptions(
        allocator,
        handler_source,
        "/virtual/handler.ts",
        .{
            .json_mode = true,
            .import_reader = tracing_reader.reader(),
        },
    );
    defer result.deinit(allocator);

    const expected_paths = [_][]const u8{
        "/virtual/lib.ts",
    };
    try std.testing.expectEqual(expected_paths.len, tracing_reader.paths.items.len);
    for (expected_paths, tracing_reader.paths.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS008", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("/virtual/lib.ts", result.json_diagnostics.items[0].file);
}

test "CHECK stops at the first dependency with a type error and reads each file once" {
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { outer } from "./a.ts";
        \\function handler(req: Request): Response { return Response.text(outer()); }
        \\
    ;
    const failed_outer =
        \\import { inner } from "./b.ts";
        \\export function outer(): string {
        \\  const value: number = "wrong";
        \\  return inner();
        \\}
        \\
    ;
    const reader_sources = [_][]const u8{
        failed_outer,
        "export function inner(): string { return \"ok\"; }\n",
    };
    var tracing_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer tracing_reader.deinit(allocator);

    var result = try runCheckOnlyFromSourceWithOptions(allocator, handler_source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = tracing_reader.reader(),
    });
    defer result.deinit(allocator);

    const expected_paths = [_][]const u8{
        "/virtual/a.ts",
        "/virtual/b.ts",
    };
    try std.testing.expectEqual(expected_paths.len, tracing_reader.paths.items.len);
    for (expected_paths, tracing_reader.paths.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }

    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS200", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("/virtual/a.ts", result.json_diagnostics.items[0].file);
}

test "CHECK resolves an extensionless import against the importer directory" {
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { save } from "./lib";
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(save("x"));
        \\}
        \\
    ;
    const dependency =
        "import { cacheSet } from \"zttp:cache\";\n" ++
        "export function save(value: string): string { cacheSet(\"n\", \"k\", value); return value; }\n";
    const reader_sources = [_][]const u8{ dependency, dependency };
    var tracing_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer tracing_reader.deinit(allocator);

    var result = try runCheckOnlyFromSourceWithOptions(allocator, handler_source, "src/handler.ts", .{
        .json_mode = true,
        .import_reader = tracing_reader.reader(),
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), tracing_reader.paths.items.len);
    try std.testing.expectEqualStrings("src/lib.ts", tracing_reader.paths.items[0]);
    try std.testing.expectEqualStrings("src/lib.ts", tracing_reader.paths.items[1]);
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(contract.effect_analysis_complete);
    try std.testing.expect(!properties.read_only);
}

test "CHECK gives an extensionless import the verdict of its explicit form" {
    const allocator = std.testing.allocator;
    const bare_source =
        \\import { clean } from "./lib";
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(clean("x"));
        \\}
        \\
    ;
    const explicit_source =
        \\import { clean } from "./lib.ts";
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(clean("x"));
        \\}
        \\
    ;
    const dependency = "export function clean(value: string): string { return value.toUpperCase(); }\n";
    const reader_sources = [_][]const u8{ dependency, dependency };
    var bare_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer bare_reader.deinit(allocator);
    var explicit_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer explicit_reader.deinit(allocator);

    var bare = try runCheckOnlyFromSourceWithOptions(allocator, bare_source, "handler.ts", .{
        .json_mode = true,
        .import_reader = bare_reader.reader(),
    });
    defer bare.deinit(allocator);
    var explicit = try runCheckOnlyFromSourceWithOptions(allocator, explicit_source, "handler.ts", .{
        .json_mode = true,
        .import_reader = explicit_reader.reader(),
    });
    defer explicit.deinit(allocator);

    try std.testing.expectEqualStrings("lib.ts", bare_reader.paths.items[0]);
    try std.testing.expectEqualStrings("lib.ts", explicit_reader.paths.items[0]);
    const bare_properties = bare.contract.?.properties.?;
    const explicit_properties = explicit.contract.?.properties.?;
    try std.testing.expect(explicit_properties.read_only);
    try std.testing.expectEqual(explicit_properties.read_only, bare_properties.read_only);
    try std.testing.expectEqual(explicit.contract.?.effect_analysis_complete, bare.contract.?.effect_analysis_complete);
}
// ---------------------------------------------------------------------------
// One loader for an imported file
// ---------------------------------------------------------------------------

/// Serves one in-memory file named `lib.ts` and refuses every other path.
const MemoryImportReader = struct {
    source: []const u8,
    reads: u32 = 0,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *MemoryImportReader = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (!std.mem.endsWith(u8, path, "lib.ts")) return error.FileNotFound;
        return allocator.dupe(u8, self.source);
    }

    fn reader(self: *MemoryImportReader) ImportReader {
        return .{ .context = self, .read = read };
    }
};

const reader_parity_entry =
    \\import { f } from "./lib.ts";
    \\export function handler(req: Request): Proof<Response, "result_safe"> {
    \\  return Response.text(f());
    \\}
    \\
;

const reader_parity_clean_lib = "export function f(): string {\n  return \"x\";\n}\n";

const reader_parity_broken_lib = "export function f(): string {\n  const n: number = \"a\";\n  return \"x\";\n}\n";

test "CHECK reports the type error of a dependency that the base reader serves, under the dependency path" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(reader_parity_entry);
    defer fixture.deinit();
    try fixture.add("lib.ts", reader_parity_clean_lib);
    const lib_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(fixture.handler_path).?, "lib.ts" });
    defer allocator.free(lib_path);

    var base: MemoryImportReader = .{ .source = reader_parity_broken_lib };
    var result = try runCheckOnlyWithOptions(allocator, fixture.handler_path, .{
        .json_mode = true,
        .import_reader = base.reader(),
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.json_diagnostics.items.len > 0);
    try std.testing.expectEqualStrings("ZTS200", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings(lib_path, result.json_diagnostics.items[0].file);
    try std.testing.expect(result.totalErrors() > 0);
}

test "text mode counts a dependency type error and prints its Types line" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(reader_parity_entry);
    defer fixture.deinit();
    try fixture.add("lib.ts", reader_parity_broken_lib);
    var result = try runCheckOnlyWithOptions(allocator, fixture.handler_path, .{ .json_mode = false });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.link_errors);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "handler.ts");
    buf = aw.toArrayList();
    try std.testing.expectEqualStrings(
        "\ncheck: handler.ts\n\n" ++
            "  Parse .................. OK (5 lines)\n" ++
            "  Types .................. FAIL (1 errors)\n" ++
            "  Sound mode ............. OK\n" ++
            "  Strict ZigTS ........... OK\n" ++
            "\n\n  1 errors, 0 warnings\n",
        buf.items,
    );
}

test "text mode counts a missing import as a link error and prints a Module graph line" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(reader_parity_entry);
    defer fixture.deinit();
    var result = try runCheckOnlyWithOptions(allocator, fixture.handler_path, .{ .json_mode = false });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), result.link_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqualStrings("ZTS063", result.json_diagnostics.items[0].code);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "handler.ts");
    buf = aw.toArrayList();
    try std.testing.expectEqualStrings(
        "\ncheck: handler.ts\n\n" ++
            "  Parse .................. OK (5 lines)\n" ++
            "  Types .................. OK\n" ++
            "  Sound mode ............. OK\n" ++
            "  Strict ZigTS ........... OK\n" ++
            "  Module graph ........... FAIL (1 errors)\n" ++
            "\n\n  1 errors, 0 warnings\n",
        buf.items,
    );
}

test "CHECK without the contract reports a dependency type error under the dependency path" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(reader_parity_entry);
    defer fixture.deinit();
    try fixture.add("lib.ts", reader_parity_broken_lib);
    var result = try runCheckOnlyWithOptions(allocator, fixture.handler_path, .{ .json_mode = true, .skip_contract = true });
    defer result.deinit(allocator);

    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS200", result.json_diagnostics.items[0].code);
    try expectRefusedAt(&fixture, &result, "ZTS200", "lib.ts");
}

test "CHECK without the contract refuses a generic import with ZTS064" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { pick } from "./lib.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text(pick("a"));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("lib.ts", "export function pick<T>(x: T): T {\n  return x;\n}\n");
    var result = try runCheckOnlyWithOptions(allocator, fixture.handler_path, .{ .json_mode = true, .skip_contract = true });
    defer result.deinit(allocator);

    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(u32, 1), result.link_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try expectRefusedAt(&fixture, &result, "ZTS064", "handler.ts");
}

test "CHECK reads a clean dependency from the base reader when the working tree dependency has a type error" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(reader_parity_entry);
    defer fixture.deinit();
    try fixture.add("lib.ts", reader_parity_broken_lib);

    var base: MemoryImportReader = .{ .source = reader_parity_clean_lib };
    var result = try runCheckOnlyWithOptions(allocator, fixture.handler_path, .{
        .json_mode = true,
        .import_reader = base.reader(),
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());

    var tree = try runCheckOnlyWithOptions(allocator, fixture.handler_path, .{ .json_mode = true });
    defer tree.deinit(allocator);
    try std.testing.expectEqualStrings("ZTS200", tree.json_diagnostics.items[0].code);
}

test "ImportedFile loads the file a reader serves and reduces it to module facts" {
    var served: MemoryImportReader = .{ .source =
        \\import { fetch } from "zttp:fetch";
        \\export function enrich(): string {
        \\  return "x";
        \\}
        \\
    };
    var file: ImportedFile = undefined;
    try file.load(std.testing.allocator, served.reader(), "/virtual/lib.ts");
    defer file.deinit();

    try std.testing.expectEqual(@as(u32, 1), served.reads);
    try std.testing.expectEqual(@as(usize, 1), file.module_facts.imports.items.len);
    try std.testing.expectEqualStrings("zttp:fetch", file.module_facts.imports.items[0].module_specifier);
}

test "ImportedFile is unreadable when the reader fails or the source does not parse" {
    var served: MemoryImportReader = .{ .source = "export function enrich(): string { return \"x\"; }\n" };
    var file: ImportedFile = undefined;
    // The reader refuses this path, and the loader leaves nothing to free.
    try std.testing.expectError(error.Unreadable, file.load(std.testing.allocator, served.reader(), "/virtual/other.ts"));
    try std.testing.expectEqual(@as(u32, 1), served.reads);

    var broken: MemoryImportReader = .{ .source = "const b = while;\n" };
    try std.testing.expectError(error.Unreadable, file.load(std.testing.allocator, broken.reader(), "/virtual/lib.ts"));
    try std.testing.expectEqual(@as(u32, 1), broken.reads);
}

test "ImportedFile without a reader reads the working tree" {
    var fixture = try SiblingFixture.init("function handler(req) { return Response.text(\"x\"); }\n");
    defer fixture.deinit();
    try fixture.add("lib.ts", "export function enrich(): string { return \"x\"; }\n");
    const lib_path = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(fixture.handler_path).?, "lib.ts" });
    defer std.testing.allocator.free(lib_path);

    var file: ImportedFile = undefined;
    try file.load(std.testing.allocator, null, lib_path);
    defer file.deinit();
    try std.testing.expectEqual(@as(usize, 0), file.module_facts.imports.items.len);

    var missing: ImportedFile = undefined;
    try std.testing.expectError(error.Unreadable, missing.load(std.testing.allocator, null, "/nonexistent/zttp-u7/lib.ts"));
}

test "the analyzer refuses every retired module with ZTS206" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { module: []const u8, symbol: []const u8 }{
        .{ .module = "zttp:durable", .symbol = "run" },
        .{ .module = "zttp:workflow", .symbol = "call" },
        .{ .module = "zttp:queue", .symbol = "send" },
        .{ .module = "zttp:scope", .symbol = "scope" },
        .{ .module = "zttp:io", .symbol = "parallel" },
        .{ .module = "zttp:service", .symbol = "serviceCall" },
        .{ .module = "zttp:ledger", .symbol = "balance" },
        .{ .module = "zttp:tool", .symbol = "toolInput" },
    };
    for (cases) |case| {
        const source = try allocator.print("import {{ {s} }} from \"{s}\";\n" ++
            "function handler(req: Request): Response {{ return Response.text(\"ready\"); }}\n", .{ case.symbol, case.module });
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        const diagnostic = result.json_diagnostics.items[0];
        try std.testing.expectEqualStrings("ZTS206", diagnostic.code);
        const message = try allocator.print("unknown virtual module '{s}'", .{case.module});
        defer allocator.free(message);
        try std.testing.expectEqualStrings(message, diagnostic.message);
        try std.testing.expect(result.contract == null);
    }
}

test "ordinary calls and explicit HTML rendering remain accepted" {
    const source =
        \\function title(value: string): string { return value; }
        \\function handler(req: Request): Response {
        \\  return Response.html(renderToString(h("main", null, title("ready"))));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
}

const CompoundDiagnostic = struct {
    code: []const u8,
    message: []const u8,
    line: u32,
    column: u32,
    suggestion: ?[]const u8 = null,
};

fn compoundSource(allocator: std.mem.Allocator, annotation: []const u8) ![]u8 {
    return allocator.print("function handler(req: Request): Response {{\n" ++
        "  const value: {s} = undefined;\n" ++
        "  return Response.text(\"ok\");\n" ++
        "}}\n", .{annotation});
}

fn expectCompoundDiagnostic(
    actual: json_diag.JsonDiagnostic,
    expected: CompoundDiagnostic,
) !void {
    try std.testing.expectEqualStrings(expected.code, actual.code);
    try std.testing.expectEqualStrings("error", actual.severity);
    try std.testing.expectEqualStrings(expected.message, actual.message);
    try std.testing.expectEqualStrings("handler.ts", actual.file);
    try std.testing.expectEqual(expected.line, actual.line);
    try std.testing.expectEqual(expected.column, actual.column);
    // A row that names no suggestion expects the fixed help of its code.
    const suggestion = expected.suggestion orelse fixedHelp(expected.code);
    try std.testing.expectEqualStrings(suggestion, actual.suggestion orelse "(null)");
    try std.testing.expect(actual.repair_intent == null);
}

/// The fixed help string each refusal code carries when its site writes none.
fn fixedHelp(code: []const u8) []const u8 {
    const rows = [_]struct { code: []const u8, help: []const u8 }{
        .{ .code = "ZTS002", .help = "Write a complete expression or statement at this position." },
        .{ .code = "ZTS012", .help = "Write decimal digits, or 0x, 0o, 0b with digits. Use no underscore and no leading zero. Give an exponent a digit." },
        .{ .code = "ZTS013", .help = "Replace the escape with a supported one, or remove the backslash." },
        .{ .code = "ZTS026", .help = "Remove await. Handlers run synchronously, so call the function directly." },
        .{ .code = "ZTS045", .help = "Join the string onto one line, or write the newline as \\n." },
        .{ .code = "ZTS047", .help = "Add a semicolon at the end of the statement." },
        .{ .code = "ZTS200", .help = "Change the value or the declared type so that the two types match." },
        .{ .code = "ZTS201", .help = "Read a property that the type declares, or add the property to the type." },
        .{ .code = "ZTS202", .help = "Pass exactly as many arguments as the function declares parameters." },
        .{ .code = "ZTS203", .help = "Pass a value of the parameter type, or change the parameter type." },
        .{ .code = "ZTS209", .help = "Pass a type argument that satisfies the constraint, or relax the constraint." },
    };
    for (rows) |row| if (std.mem.eql(u8, row.code, code)) return row.help;
    return "(null)";
}

test "CHECK preserves repeated-name fallback through growth and source offsets" {
    const allocator = std.testing.allocator;
    const Layout = enum { plain, reordered, same_line };
    const cases = [_]struct {
        count: usize,
        layout: Layout,
        leading_spaces: usize,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{ .count = 6, .layout = .plain, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 8, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 8, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 6, .layout = .plain, .leading_spaces = 1, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 8, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 8, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 6, .layout = .reordered, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 2, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 8, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 6, .layout = .same_line, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 1, .column = 244, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 47, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 238, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .plain, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 9, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 9, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .plain, .leading_spaces = 1, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 9, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 9, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .reordered, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS202", .message = "wrong number of arguments: expected 2, got 1", .line = 9, .column = 8, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .same_line, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 1, .column = 303, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 47, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 297, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 12, .layout = .plain, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 14, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 14, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 12, .layout = .plain, .leading_spaces = 1, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 14, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 14, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 12, .layout = .reordered, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 2, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 14, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 12, .layout = .same_line, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 1, .column = 598, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 47, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 592, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 13, .layout = .plain, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 15, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 15, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 13, .layout = .plain, .leading_spaces = 1, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 15, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 15, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 13, .layout = .reordered, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 2, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 15, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 13, .layout = .same_line, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 1, .column = 657, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 47, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 651, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .reordered, .leading_spaces = 3, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 2, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 9, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
    };
    const number_function = "function useNumber(value: number): number {\n  inner(value);\n  function inner(item: number): number { return item; }\n  return value;\n}\n";
    const text_function = "function useText(value: string): string {\n  inner(value, \"\");\n  function inner(item: string, suffix: string): string { return item; }\n  return value;\n}\n";
    const handler = "export function handler(req: Request): Response {\n  return Response.json({ number: useNumber(1), text: useText(\"x\") });\n}\n";
    const expected_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    var observed: usize = 0;
    for (cases) |case| {
        try std.testing.expect(case.count >= 5);
        try std.testing.expect(case.count <= 13);
        try std.testing.expect(case.leading_spaces <= 3);
        var source_writer = std.Io.Writer.Allocating.init(allocator);
        defer source_writer.deinit();
        for (0..case.leading_spaces) |_| try source_writer.writer.writeByte(' ');
        try source_writer.writer.writeAll(if (case.layout == .reordered) text_function else number_function);
        for (0..case.count - 5) |index| {
            try source_writer.writer.print("function padding{d}(value: number): number {{ return value; }}\n", .{index});
        }
        try source_writer.writer.writeAll(if (case.layout == .reordered) number_function else text_function);
        try source_writer.writer.writeAll(handler);
        if (case.layout == .same_line) try source_writer.writer.writeByte('\n');
        const source = try allocator.dupe(u8, source_writer.written());
        defer allocator.free(source);
        if (case.layout == .same_line) {
            for (source[0 .. source.len - 1]) |*byte| {
                if (byte.* == '\n') byte.* = ' ';
            }
        }
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        const error_count: u32 = @intCast(case.diagnostics.len);
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        try std.testing.expectEqual(error_count - 1, result.strict_errors);
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(error_count, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 17), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves compound type diagnostics and semantic prefixes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        annotation: []const u8,
        message: []const u8,
    }{
        .{ .annotation = "{ \"x\": number }", .message = "type 'undefined' is not assignable to type '{  }'" },
        .{ .annotation = "{ x number }", .message = "type 'undefined' is not assignable to type '{  }'" },
        .{ .annotation = "{ x: }", .message = "type 'undefined' is not assignable to type '{ x: unknown }'" },
        .{ .annotation = "{ /*c*/ x: number }", .message = "type 'undefined' is not assignable to type '{  }'" },
        .{ .annotation = "{ x: number /*c*/ }", .message = "type 'undefined' is not assignable to type '{ x: number }'" },
        .{ .annotation = "{ x: number y: string }", .message = "type 'undefined' is not assignable to type '{ x: number; y: string }'" },
        .{ .annotation = "number |", .message = "type 'undefined' is not assignable to type 'number'" },
        .{ .annotation = "{ x: number } &", .message = "type 'undefined' is not assignable to type '{ x: number }'" },
        .{ .annotation = "(x: number y: string) => number", .message = "type 'undefined' is not assignable to type '(x: number, y: string) => number'" },
        .{ .annotation = "(x: number) number", .message = "type 'undefined' is not assignable to type '(x: number) => void'" },
        .{ .annotation = "(x: number) =>", .message = "type 'undefined' is not assignable to type '(x: number) => void'" },
        .{ .annotation = "(number)", .message = "type 'undefined' is not assignable to type 'number'" },
        .{ .annotation = "() => number", .message = "type 'undefined' is not assignable to type '() => number'" },
        .{ .annotation = "number [ ]", .message = "type 'undefined' is not assignable to type 'number'" },
        .{ .annotation = "number /*c*/ []", .message = "type 'undefined' is not assignable to type 'number'" },
        .{ .annotation = "{ cb: (x?: number) => number }", .message = "type 'undefined' is not assignable to type '{ cb: (x: number) => number }'" },
        .{ .annotation = "{ any: number }", .message = "type 'undefined' is not assignable to type '{ any: number }'" },
        .{ .annotation = "string | 200", .message = "type 'undefined' is not assignable to type 'string | 200'" },
        .{ .annotation = "string | 1.5", .message = "type 'undefined' is not assignable to type 'string | 1'" },
        .{ .annotation = "string | 0x10", .message = "type 'undefined' is not assignable to type 'string | 0'" },
        .{ .annotation = "string | 1_000", .message = "type 'undefined' is not assignable to type 'string | 1'" },
        .{ .annotation = "true", .message = "type 'undefined' is not assignable to type 'true'" },
        .{ .annotation = "`\\${string}`", .message = "type 'undefined' is not assignable to type '`\\${string}`'" },
        .{ .annotation = "`x${}`", .message = "type 'undefined' is not assignable to type '`x${unknown}`'" },
        .{ .annotation = "\"GET\"", .message = "type 'undefined' is not assignable to type '\"GET\"'" },
        .{ .annotation = "(200)", .message = "type 'undefined' is not assignable to type '200'" },
        .{ .annotation = "(| number | string)", .message = "type 'undefined' is not assignable to type 'number | string'" },
        .{ .annotation = "readonly number[]", .message = "type 'undefined' is not assignable to type 'readonly number[]'" },
        .{ .annotation = "[string, number]", .message = "type 'undefined' is not assignable to type '[string, number]'" },
        .{ .annotation = "readonly [string, number]", .message = "type 'undefined' is not assignable to type '[string, number]'" },
        .{ .annotation = "`outer${`any`}`", .message = "type 'undefined' is not assignable to type '`outer${`any`}`'" },
    };
    const expected_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    var observed: usize = 0;
    for (cases) |case| {
        const source = try compoundSource(allocator, case.annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS200",
            .message = case.message,
            .line = 2,
            .column = 3,
        });
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 31), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves compound root admission parse diagnostics" {
    const allocator = std.testing.allocator;
    const annotations = [_][]const u8{
        "| number | string",
        "& { x: number }",
        "1.5",
        "0x10",
        "1e3",
        "1_000",
        "32768",
        "/*c*/ number",
    };
    const expected_stages = StageSet.initMany(&.{ .strip, .parse });
    const expected = [_]CompoundDiagnostic{
        .{
            .code = "ZTS002",
            .message = "const declarations must have an initializer",
            .line = 2,
            .column = 14,
        },
        .{
            .code = "ZTS047",
            .message = "statement is not terminated; this profile has no automatic semicolon insertion",
            .line = 2,
            .column = 9,
        },
    };
    var observed: usize = 0;
    for (annotations) |annotation| {
        const source = try compoundSource(allocator, annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 2), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
        try std.testing.expectEqual(expected.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, expected) |actual, diagnostic| {
            try expectCompoundDiagnostic(actual, diagnostic);
        }
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), annotations.len);
    try std.testing.expectEqual(annotations.len, observed);
}

test "CHECK preserves compound unclosed syntax diagnostics" {
    const allocator = std.testing.allocator;
    const annotations = [_][]const u8{
        "{ x: number",
        "`a${number",
        "(x: number => number",
        "number [",
    };
    const expected_stages = StageSet.initMany(&.{ .strip, .parse });
    const expected = [_]CompoundDiagnostic{
        .{
            .code = "ZTS002",
            .message = "const declarations must have an initializer",
            .line = 5,
            .column = 1,
        },
        .{
            .code = "ZTS047",
            .message = "statement is not terminated; this profile has no automatic semicolon insertion",
            .line = 2,
            .column = 9,
        },
    };
    var observed: usize = 0;
    for (annotations) |annotation| {
        const source = try compoundSource(allocator, annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 2), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
        try std.testing.expectEqual(expected.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, expected) |actual, diagnostic| {
            try expectCompoundDiagnostic(actual, diagnostic);
        }
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), annotations.len);
    try std.testing.expectEqual(annotations.len, observed);
}

test "CHECK preserves preparation diagnostics and recovery boundaries" {
    const allocator = std.testing.allocator;
    const any_suggestion = "use specific types (string, number, object) or union types instead";
    const cases = [_]struct {
        annotation: []const u8,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{
            .annotation = "(x?: number) => number",
            .diagnostics = &.{.{
                .code = "ZTS055",
                .message = "optional parameter shorthand is not part of this profile",
                .line = 2,
                .column = 18,
                .suggestion = "replace `name?: T` with `name: T | undefined`",
            }},
        },
        .{
            .annotation = "{ value: any }",
            .diagnostics = &.{.{
                .code = "ZTS041",
                .message = "'any' type is not supported",
                .line = 2,
                .column = 25,
                .suggestion = any_suggestion,
            }},
        },
        .{
            .annotation = "number many",
            .diagnostics = &.{.{
                .code = "ZTS041",
                .message = "'any' type is not supported",
                .line = 2,
                .column = 24,
                .suggestion = any_suggestion,
            }},
        },
        .{
            .annotation = "number Array<string>",
            .diagnostics = &.{.{
                .code = "ZTS058",
                .message = "`Array<T>` is not a type spelling in this profile",
                .line = 2,
                .column = 23,
                .suggestion = "write `T[]`",
            }},
        },
        .{
            .annotation = "number ReadonlyArray<string>",
            .diagnostics = &.{.{
                .code = "ZTS059",
                .message = "`ReadonlyArray<T>` is not a type spelling in this profile",
                .line = 2,
                .column = 23,
                .suggestion = "write `readonly T[]`",
            }},
        },
        .{
            .annotation = "any Array<string>",
            .diagnostics = &.{
                .{
                    .code = "ZTS041",
                    .message = "'any' type is not supported",
                    .line = 2,
                    .column = 16,
                    .suggestion = any_suggestion,
                },
                .{
                    .code = "ZTS058",
                    .message = "`Array<T>` is not a type spelling in this profile",
                    .line = 2,
                    .column = 20,
                    .suggestion = "write `T[]`",
                },
            },
        },
        .{
            .annotation = &@as([513:0]u8, @splat('(')) ++ "number" ++ &@as([513:0]u8, @splat(')')) ++ " any",
            .diagnostics = &.{.{
                .code = "ZTS044",
                .message = "type syntax nests too deeply",
                .line = 2,
                .column = 528,
                .suggestion = "simplify or split it (nesting limit is 512)",
            }},
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        const source = try compoundSource(allocator, case.annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
        const count: u32 = @intCast(case.diagnostics.len);
        try std.testing.expect(count > 0);
        try std.testing.expectEqual(count, result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(count, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, diagnostic| {
            try expectCompoundDiagnostic(actual, diagnostic);
        }
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), cases.len);
    try std.testing.expectEqual(cases.len, observed);

    const CompatibilityStage = enum { strip, parse, contract_without_handler, contract };
    const proof_suggestion =
        "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, " ++
        "but it does not hold: cost_bounded, deterministic, fault_covered, idempotent, injection_safe, input_validated, no_credential_leakage, no_secret_leakage, optional_safe, pii_contained, result_safe, state_isolated. " ++
        "Return a narrow Proof capsule with only the properties it holds, e.g. " ++
        "`function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | " ++
        "\"pure\" | \"stateless\" | \"canonical\">`.";
    const compatibility_cases = [_]struct {
        name: []const u8,
        source: []const u8,
        stage: CompatibilityStage,
        parse_errors: u32,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{
            .name = "caught_then_comment",
            .source = "const value: \"open\n = \"open\";\n/* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS008",
                .message = "unterminated string literal",
                .line = 1,
                .column = 19,
                .suggestion = "close the quote, or write the newline as \\n",
            }},
        },
        .{
            .name = "comment_only",
            .source = "/* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "prior_hard_rows",
            .source = "const first: any = 1;\nconst second: void = undefined;\n/* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS060",
                .message = "`void` is not a type spelling in this profile",
                .line = 2,
                .column = 15,
                .suggestion = "write `undefined`",
            }},
        },
        .{
            .name = "prior_parser_error",
            .source = "const broken = ;\n/* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "parameter_type_comment",
            .source = "function f(value: string /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "general_type_comment",
            .source = "const value: string /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "interface_body_comment",
            .source = "interface Shape { /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS049",
                .message = "`interface` is not a declaration form in this profile",
                .line = 1,
                .column = 1,
                .suggestion = "write `structural Name = { ... };`",
            }},
        },
        .{
            .name = "template_text_control",
            .source = "const value = `/* unfinished`;\n",
            .stage = .contract_without_handler,
            .parse_errors = 0,
            .diagnostics = &.{.{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 1,
                .column = 1,
                .suggestion = proof_suggestion,
            }},
        },
        .{
            .name = "template_interpolation_control",
            .source = "const text = `${/* unfinished}`;\n",
            .stage = .parse,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS001",
                .message = "template interpolation is not supported",
                .line = 1,
                .column = 14,
                .suggestion = "build a string array with explicit `String(...)` conversions and call `.join(\"\")`",
            }},
        },
        .{
            .name = "generic_owner_nonmatch",
            .source = "const x = <void> + 1; /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS060",
                .message = "`void` is not a type spelling in this profile",
                .line = 1,
                .column = 12,
                .suggestion = "write `undefined`",
            }},
        },
        .{
            .name = "assertion_comment",
            .source = "const x = y as number /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS042",
                .message = "'as' type assertion is not supported",
                .line = 1,
                .column = 16,
                .suggestion = "use type-safe patterns instead",
            }},
        },
        .{
            .name = "annotation_void_comment",
            .source = "const x: void /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "assertion_later_void",
            .source = "const x = y as number | void;\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS042",
                .message = "'as' type assertion is not supported",
                .line = 1,
                .column = 16,
                .suggestion = "use type-safe patterns instead",
            }},
        },
        .{
            .name = "assertion_any_comment",
            .source = "const x = y as number | any /* unfinished\n",
            .stage = .strip,
            .parse_errors = 2,
            .diagnostics = &.{
                .{
                    .code = "ZTS042",
                    .message = "'as' type assertion is not supported",
                    .line = 1,
                    .column = 16,
                    .suggestion = "use type-safe patterns instead",
                },
                .{
                    .code = "ZTS041",
                    .message = "'any' type is not supported",
                    .line = 1,
                    .column = 25,
                    .suggestion = any_suggestion,
                },
            },
        },
        .{
            .name = "terminal_template_depth",
            .source = "function f(): `${" ++ &@as([512:0]u8, @splat('{')) ++ " return 1; }\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS044",
                .message = "type syntax nests too deeply",
                .line = 1,
                .column = 529,
                .suggestion = "simplify or split it (nesting limit is 512)",
            }},
        },
        .{
            .name = "template_tail_slash",
            .source = "const text = `${1}` / 2; import type { Spec } from \"zttp:types\"; / 3;\n",
            .stage = .parse,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS001",
                .message = "template interpolation is not supported",
                .line = 1,
                .column = 14,
                .suggestion = "build a string array with explicit `String(...)` conversions and call `.join(\"\")`",
            }},
        },
        .{
            .name = "later_parser_error",
            .source = "const broken = ;\nconst later = ;\n",
            .stage = .parse,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS002",
                .message = "expected expression",
                .line = 1,
                .column = 16,
            }},
        },
        .{
            .name = "recovery_first_template_head",
            .source = "const broken = ; `${function f(x: any) {}}`;\n",
            .stage = .parse,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS002",
                .message = "expected expression",
                .line = 1,
                .column = 16,
            }},
        },
        .{
            .name = "template_tail_slash_boundary",
            .source = "const text = `${1}` / 2;import type { Spec } from \"zttp:types\"; / 3;\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS053",
                .message = "`zttp:types` is not a module in this profile",
                .line = 1,
                .column = 25,
                .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names",
            }},
        },
    };
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    const handler_free_contract_stages = StageSet.initMany(&.{
        .strip,  .parse,    .imports, .boolean, .types,
        .strict, .contract, .trace,   .spec,    .canonical,
    });
    var compatibility_observed: usize = 0;
    for (compatibility_cases) |case| {
        errdefer std.debug.print("CHECK compatibility baseline failed: {s}\n", .{case.name});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);

        const expected_stages = switch (case.stage) {
            .strip => StageSet.initMany(&.{.strip}),
            .parse => StageSet.initMany(&.{ .strip, .parse }),
            .contract_without_handler => handler_free_contract_stages,
            .contract => full_stages,
        };
        const has_contract = switch (case.stage) {
            .strip, .parse => false,
            .contract_without_handler, .contract => true,
        };
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(case.parse_errors, result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(has_contract, result.contract != null);
        const expected_errors: u32 = if (has_contract)
            @intCast(case.diagnostics.len)
        else
            case.parse_errors;
        try std.testing.expectEqual(expected_errors, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        compatibility_observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 19), compatibility_cases.len);
    try std.testing.expectEqual(compatibility_cases.len, compatibility_observed);
}

test "CHECK routes a TypeScript path and refuses a virtual path with ZTS052" {
    const source =
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var typed = try runCheckOnlyFromSourceWithOptions(
        std.testing.allocator,
        source,
        "routing.ts",
        .{ .json_mode = true },
    );
    defer typed.deinit(std.testing.allocator);
    try std.testing.expect(typed.is_typescript);
    try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), typed.stages_run);
    try std.testing.expectEqual(@as(u32, 0), typed.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), typed.strict_errors);
    try std.testing.expectEqual(@as(u32, 1), typed.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), typed.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS601", typed.json_diagnostics.items[0].code);
    try std.testing.expect(!typed.verify_ran);
    try std.testing.expect(typed.contract == null);

    var virtual = try runCheckOnlyFromSourceWithOptions(
        std.testing.allocator,
        source,
        "<routing>",
        .{ .json_mode = true },
    );
    defer virtual.deinit(std.testing.allocator);
    try std.testing.expect(!virtual.is_typescript);
    try std.testing.expectEqual(@as(u32, 1), virtual.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), virtual.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), virtual.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS052", virtual.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("<routing>", virtual.json_diagnostics.items[0].file);
    try std.testing.expect(virtual.contract == null);
}

test "CHECK preserves source preparation allocation failure projection" {
    const source = "const value: string = \"ok\";\n";
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var result = try runCheckOnlyFromSourceWithOptions(
        failing.allocator(),
        source,
        "allocation.ts",
        .{ .json_mode = true },
    );
    defer result.deinit(failing.allocator());

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expect(result.contract == null);
}

test "CHECK preserves validation allocation failure projection" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "import type ");
    for (0..513) |_| try source.appendSlice(std.testing.allocator, "`${");
    try source.appendSlice(std.testing.allocator, "value");
    for (0..513) |_| try source.appendSlice(std.testing.allocator, "}`");
    try source.appendSlice(std.testing.allocator, ";\n");

    var calibration = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
        .resize_fail_index = std.math.maxInt(usize),
    });
    var atoms = zts.AtomTable.init(calibration.allocator());
    defer atoms.deinit();
    var parser = try zts.parser.JsParser.initAdmission(
        calibration.allocator(),
        calibration.allocator(),
        source.items,
        .collect,
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = switch (try parser.parseAdmission()) {
        .accepted => |accepted| accepted,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.type_only_modules.items.len);
    const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);
    try std.testing.expectEqual(zts.parser.NodeTag.program, view.getTag(root).?);

    const validation_alloc_index = calibration.alloc_index;
    const validation_resize_index = calibration.resize_index;
    calibration.fail_index = validation_alloc_index;
    calibration.resize_fail_index = validation_resize_index;
    try std.testing.expectError(
        error.OutOfMemory,
        parser.type_store.validateRuntimeOwners(calibration.allocator(), view),
    );
    try std.testing.expect(calibration.has_induced_failure);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = validation_alloc_index,
        .resize_fail_index = validation_resize_index,
    });
    var result = try runCheckOnlyFromSourceWithOptions(
        failing.allocator(),
        source.items,
        "validation-allocation.ts",
        .{ .json_mode = true },
    );
    defer result.deinit(failing.allocator());

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expect(result.contract == null);
}

test "CHECK reports absent compound analysis failures as ZTS000" {
    const allocator = std.testing.allocator;
    const annotations = [_][]const u8{
        "``",
        "((())) | Unsupported",
        "((()))[] | string",
        "((())) | ((p0: number, p1: number, p2: number, p3: number, " ++
            "p4: number, p5: number, p6: number, p7: number, " ++
            "p8: number, p9: number, p10: number, p11: number, " ++
            "p12: number, p13: number, p14: number, p15: number) => number)",
    };
    var observed: usize = 0;
    for (annotations) |annotation| {
        const source = try compoundSource(allocator, annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expectEqualStrings("ZTS000", result.json_diagnostics.items[0].code);
        try std.testing.expectEqualStrings("the analyzer stopped with error.UnresolvedTypeBinding", result.json_diagnostics.items[0].message);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), annotations.len);
    try std.testing.expectEqual(annotations.len, observed);
}

test "CHECK reports absent generic semantic types as ZTS000" {
    const source =
        "structural Empty<T> = ();\n" ++
        "const bare: Empty = \"x\";\n" ++
        "const applied: Empty<string> = \"x\";\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS000", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("the analyzer stopped with error.UnresolvedTypeBinding", result.json_diagnostics.items[0].message);
}

test "CHECK preserves declaration admission and named type outcomes" {
    const allocator = std.testing.allocator;
    const FailureStage = enum { parse, types, contract };
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        stage: FailureStage,
        diagnostic: CompoundDiagnostic,
    }{
        .{ .name = "root", .source = "structural Alias = number;\nconst value: Alias = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .name = "leading_spaces", .source = "  structural Alias = number;\nconst value: Alias = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 3, .suggestion = null } },
        .{ .name = "after_newline", .source = "const seed = 1;\n  structural Alias = number;\nconst value: Alias = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 2, .column = 3, .suggestion = null } },
        .{ .name = "after_semicolon", .source = "const seed = 1; structural Alias = number;\nconst value: Alias = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 17, .suggestion = null } },
        .{ .name = "nested_left", .source = "function handler(req: Request): Response {\nstructural Alias = number;\nconst value: Alias = \"x\";\nreturn Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "nested_indented", .source = "function handler(req: Request): Response {\n  structural Alias = number;\n  const value: Alias = \"x\";\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 2, .column = 3, .suggestion = null } },
        .{ .name = "nominal_runtime_collision", .source = "nominal UserId = string;\nfunction UserId(value: string): string {\n  return value;\n}\nfunction handler(req: Request): Response {\n  const value = UserId(\"x\");\n  return Response.text(value);\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS214", .message = "`UserId` is a nominal type, not a constructor", .line = 6, .column = 23, .suggestion = "brand at an annotated declaration: `const x: Name = value;`" } },
        .{ .name = "structural_runtime_collision", .source = "structural UserId = string;\nfunction UserId(value: string): string {\n  return value;\n}\nfunction handler(req: Request): Response {\n  const value = UserId(\"x\");\n  return Response.json({ value: value, now: Date.now() });\n}\n", .stage = .contract, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .name = "eager_alias", .source = "structural A = string;\nstructural B = A;\nstructural A = number;\nconst value: B = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 4, .column = 1, .suggestion = null } },
        .{ .name = "forward_alias", .source = "structural B = A;\nstructural A = string;\nstructural A = number;\nconst value: B = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'A'", .line = 4, .column = 1, .suggestion = null } },
        .{ .name = "nested_alias_global", .source = "function define(): number {\nstructural A = string;\nreturn 1;\n}\nconst value: A = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 5, .column = 1, .suggestion = null } },
        .{ .name = "unused_cycle", .source = "structural A = A | number;\nfunction handler(req: Request): Response {\n  return Response.json({ now: Date.now() });\n}\n", .stage = .contract, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .name = "used_cycle", .source = "structural A = A | number;\nconst value: A = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS212", .message = "recursive type alias 'A' has a cycle no data constructor guards", .line = 2, .column = 1, .suggestion = "route the recursion through a record, a tuple, or an array, the way `type JsonValue = ... | readonly JsonValue[]` does; a union or intersection edge does not guard it" } },
        .{ .name = "forward_alias_number", .source = "structural B = A;\nstructural A = string;\nstructural A = number;\nconst value: B = 1;\nfunction handler(req: Request): Response {\n  return Response.json({ now: Date.now() });\n}\n", .stage = .contract, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .name = "suffixed_alias_string", .source = "structural A = string;\nstructural B = A tolerated_suffix;\nstructural A = number;\nconst value: B = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'A'", .line = 4, .column = 1, .suggestion = null } },
        .{ .name = "suffixed_alias_number", .source = "structural A = string;\nstructural B = A tolerated_suffix;\nstructural A = number;\nconst value: B = 1;\nfunction handler(req: Request): Response {\n  return Response.json({ now: Date.now() });\n}\n", .stage = .contract, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .name = "primitive_declaration", .source = "structural string = number;\nstructural B = string;\nconst value: B = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "primitive_annotation", .source = "structural string = number;\nconst value: string = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .name = "primitive_nominal", .source = "structural string = number;\nnominal UserId = string;\nconst value: UserId = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'UserId'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "primitive_nested", .source = "structural string = number;\nstructural B = string | boolean;\nconst value: B = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string | boolean'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "named_arrays", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: Alias[][] = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'Alias[]'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "grouped_arrays", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: (Alias)[][] = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'Alias[][]'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "readonly_root", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: readonly Items = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'readonly string[]'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "readonly_record", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: { field: readonly Items } = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type '{ field: Readonly<Items> }'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "readonly_tuple", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: [readonly Items] = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type '[Readonly<Items>]'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "readonly_nullable", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: readonly Items | undefined = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'readonly string[] | undefined'", .line = 3, .column = 1, .suggestion = null } },
    };
    const types_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("declaration baseline failed: {s}\n", .{case.name});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        switch (case.stage) {
            .parse => {
                try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
                try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .types => {
                try std.testing.expectEqual(types_stages, result.stages_run);
                try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
                try std.testing.expectEqual(@as(u32, 1), result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .contract => {
                try std.testing.expectEqual(full_stages, result.stages_run);
                try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract != null);
            },
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 26), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves declaration suffix refusals and empty bodies" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        strip_refusal: bool,
        diagnostic: CompoundDiagnostic,
    }{
        .{ .source = "structural Alias = number any;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" } },
        .{ .source = "structural Alias = number void;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 27, .suggestion = "write `undefined`" } },
        .{ .source = "structural Alias = number Array<string>;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS058", .message = "`Array<T>` is not a type spelling in this profile", .line = 1, .column = 27, .suggestion = "write `T[]`" } },
        .{ .source = "structural Alias = number ReadonlyArray<string>;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS059", .message = "`ReadonlyArray<T>` is not a type spelling in this profile", .line = 1, .column = 27, .suggestion = "write `readonly T[]`" } },
        .{ .source = "structural Alias = ;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .source = "structural Alias = ();\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
    };
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        if (case.strip_refusal) {
            try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expect(result.contract == null);
        } else {
            try std.testing.expectEqual(full_stages, result.stages_run);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expect(result.contract != null);
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves nominal refusals and keyword alias names" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        strip_refusal: bool,
        diagnostic: CompoundDiagnostic,
    }{
        .{ .source = "nominal Bad = void;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad = Array<string>;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad = ReadonlyArray<string>;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad = (x?: number) => number;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad = any;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" } },
        .{ .source = "nominal Bad = ;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 12, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad   ;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "structural true = number;\nconst value: true = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .source = "structural null = number;\nconst value: null = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .source = "structural undefined = number;\nconst value: undefined = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .source = "structural function = number;\nconst value: function = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        if (case.strip_refusal) {
            try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        } else {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 12), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK retains distinct nominal any and scalar refusal positions" {
    const allocator = std.testing.allocator;
    const source =
        "nominal Bad = number any;\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 2), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
    try std.testing.expect(result.contract == null);
    const expected = [_]CompoundDiagnostic{
        .{
            .code = "ZTS041",
            .message = "'any' type is not supported",
            .line = 1,
            .column = 22,
            .suggestion = "use specific types (string, number, object) or union types instead",
        },
        .{
            .code = "ZTS048",
            .message = "a nominal declaration carries scalar identity only",
            .line = 1,
            .column = 15,
            .suggestion = "its base must be `string`, `number`, or `boolean`",
        },
    };
    try std.testing.expectEqual(expected.len, result.json_diagnostics.items.len);
    for (result.json_diagnostics.items, expected) |actual, diagnostic| {
        try expectCompoundDiagnostic(actual, diagnostic);
    }
}

test "CHECK admits declaration literals and blank-line continuations" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, message: []const u8, line: u32 }{
        .{ .source = "structural N = 1;\nconst value: N = 2;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .message = "type '2' is not assignable to type '1'", .line = 2 },
        .{ .source = "structural U = | number | string;\nconst value: U = true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .message = "type 'true' is not assignable to type 'number | string'", .line = 2 },
        .{ .source = "structural A = number |\n\nstring;\nconst value: A = true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .message = "type 'true' is not assignable to type 'number | string'", .line = 4 },
        .{ .source = "structural A = { id: number } &\n\n{ tag: string };\nconst value: A = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .message = "type '1' is not assignable to type '{ id: number } & { tag: string }'", .line = 4 },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS200",
            .message = case.message,
            .line = case.line,
            .column = 1,
        });
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves comment gaps around type declarations" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        diagnostic: CompoundDiagnostic,
    }{
        .{ .source = "structural /*c*/ A = number;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 1, .suggestion = null } },
        .{ .source = "structural A /*c*/ = number;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .diagnostic = .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 20, .suggestion = null } },
        .{ .source = "structural A = number\n/*c*/;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .diagnostic = .{ .code = "ZTS001", .message = "empty statements are not supported", .line = 2, .column = 6, .suggestion = "remove the standalone `;`" } },
    };
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
        try std.testing.expect(result.contract == null);
    }
}

test "CHECK preserves generic admission and projection outcomes" {
    const allocator = std.testing.allocator;
    const FailureStage = enum { strip, parse, types, contract };
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        stage: FailureStage,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{ .name = "adjacent_function", .source = "function id<T>(x: T): T { return x; }\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "spaced_function", .source = "function id <T>(x: T): T { return x; }\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostics = &.{.{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 18, .suggestion = "')'" }} },
        .{ .name = "generic_arrow", .source = "const id = <T>(x: T): T => x;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "spaced_alias", .source = "structural Box <T> = { value: T };\nconst probe: Box<string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "nested_function", .source = "function outer(): number {\n  function id<T>(x: T): T { return x; }\n  return id(\"x\");\n}\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 3, .column = 3, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" }} },
        .{ .name = "function_default", .source = "function make<T = string>(x: T): T { return x; }\nconst probe: number = make(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "alias_default", .source = "structural Box<T = string> = { value: T };\nconst probe: Box<string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "function_constraint_default", .source = "function id<T extends string = number>(x: T): T { return x; }\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "alias_constraint_default", .source = "structural Box<T extends string = number> = { value: T };\nconst probe: Box<number> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: number }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "eight_parameters", .source = "function f<A,B,C,D,E,F,G,H>(x: H): H { return x; }\nconst probe: number = f<string,string,string,string,string,string,string,string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "nine_parameters_eight_arguments", .source = "function f<A,B,C,D,E,F,G,H,I>(x: I): I { return x; }\nconst probe: number = f<string,string,string,string,string,string,string,string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected I, got \"x\"", .line = 2, .column = 82, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'I' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "nine_parameters_nine_arguments", .source = "function f<A,B,C,D,E,F,G,H,I>(x: I): I { return x; }\nconst probe: number = f<string,string,string,string,string,string,string,string,string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected I, got \"x\"", .line = 2, .column = 89, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'I' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "nine_alias_parameters", .source = "structural N<A,B,C,D,E,F,G,H,I> = I;\nconst probe: N<string,string,string,string,string,string,string,string,number> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'N<string, string, string, string, string, string, string, string, number>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "nongeneric_then_generic", .source = "structural Box = number;\nstructural Box<T> = T;\nconst bare: Box = \"x\";\nconst applied: Box<string> = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null }, .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 4, .column = 1, .suggestion = null } } },
        .{ .name = "generic_then_nongeneric", .source = "structural Box<T> = T;\nstructural Box = number;\nconst bare: Box = \"x\";\nconst applied: Box<string> = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null }, .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 4, .column = 1, .suggestion = null } } },
        .{ .name = "alias_before_parameter", .source = "structural T = number;\nfunction f<T>(x: T): T { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T'", .line = 3, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'number' is not assignable to type 'string'", .line = 3, .column = 1, .suggestion = null } } },
        .{ .name = "duplicate_parameters", .source = "function f<T,T>(x: T): T { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T'", .line = 2, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "repeated_generic_alias", .source = "structural Box<T> = { value: T };\nstructural Box<T> = T;\nconst probe: Box<string> = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 3, .column = 1, .suggestion = null }} },
        .{ .name = "repeated_nongeneric_alias", .source = "structural Box = string;\nstructural Box = number;\nconst probe: Box = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null }} },
        .{ .name = "application_array", .source = "structural Box<T> = { value: T };\nconst probe: Box<string>[] = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "grouped_application_array", .source = "structural Box<T> = { value: T };\nconst probe: (Box<string>)[] = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Box<string>[]'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "nested_application", .source = "structural Box<T> = { value: T };\nconst probe: Box<Box<string>> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: { value: string } }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "readonly_application", .source = "structural Box<T> = { value: T };\nconst probe: Readonly<Box<string>> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "union_application", .source = "structural Box<T> = { value: T };\nconst probe: Box<string> | number = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string } | number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "record_application", .source = "structural Box<T> = { value: T };\nconst probe: { field: Box<string> } = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ field: Box<string> }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "tuple_application", .source = "structural Box<T> = { value: T };\nconst probe: [Box<string>] = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '[Box<string>]'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "adjacent_call", .source = "function id<T>(x: T): T { return x; }\nconst probe: number = id<string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "spaced_call", .source = "function id<T>(x: T): T { return x; }\nconst probe: number = id<string> (\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'boolean' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "comparison_control", .source = "const cond = true;\nconst left = 1;\nconst right = 2;\nconst value = cond ? left < right : right > left;\nfunction handler(req: Request): Response {\n  return Response.json({ now: Date.now() });\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "shift_control", .source = "const value = 8 >> 1;\nfunction handler(req: Request): Response {\n  return Response.json({ now: Date.now() });\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "comparison_shift_control", .source = "const a = 1;\nconst b = 2;\nconst c = 1;\nconst value = a < b >> c;\nfunction handler(req: Request): Response {\n  return Response.json({ now: Date.now() });\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "comparison_unsigned_shift_control", .source = "const a = 1;\nconst b = 2;\nconst c = 1;\nconst value = a < b >>> c;\nfunction handler(req: Request): Response {\n  return Response.json({ now: Date.now() });\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "method_call", .source = "const object = { id: <T>(value: T): T => value };\nconst probe: number = object.id<string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.json({ now: Date.now() });\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 3, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: cost_bounded, deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\">`." }} },
        .{ .name = "triple_closer", .source = "structural Box<T> = { value: T };\nconst probe: Box<Box<Box<string>>> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: { value: { value: string } } }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "application_missing_comma", .source = "structural Box<T> = { value: T };\nconst probe: Box<string number> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Box<string, number>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "application_missing_close", .source = "structural Box<T> = { value: T };\nconst probe: Box<string = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostics = &.{ .{ .code = "ZTS002", .message = "const declarations must have an initializer", .line = 6, .column = 1, .suggestion = null }, .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 2, .column = 7, .suggestion = null } } },
        .{ .name = "call_missing_comma", .source = "function id<T>(value: T): T { return value; }\nconst probe: number = id<string number>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "call_missing_close", .source = "function id<T>(value: T): T { return value; }\nconst probe: number = id<string(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'boolean' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "user_alias_too_few", .source = "structural Duo<A,B> = { first: A; second: B };\nconst probe: Duo<string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Duo<string>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "user_alias_too_many", .source = "structural Duo<A,B> = { first: A; second: B };\nconst probe: Duo<string,number,boolean> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Duo<string, number, boolean>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "partial_surplus", .source = "structural User = { id: number };\nconst probe: Partial<User,string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ id?: number }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "partial_missing", .source = "structural User = { id: number };\nconst probe: Partial<> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Partial<>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "dict_one", .source = "const probe: Dict<string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Dict<string>'", .line = 1, .column = 1, .suggestion = null }} },
        .{ .name = "dict_three", .source = "const probe: Dict<string,number,boolean> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Dict<string, number, boolean>'", .line = 1, .column = 1, .suggestion = null }} },
        .{ .name = "proof_replacement", .source = "structural Proof<T,P> = T;\nconst probe: Proof<number,\"pure\"> = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "effects_replacement", .source = "structural Effects<T,E> = T;\nconst probe: Effects<number,\"env\"> = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "forward_constraint", .source = "function f<T,U extends T>(a: T,b: U): U { return b; }\nconst probe: string = f(1,2);\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument 2 for 'U' does not satisfy constraint T", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'U' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "nested_comma_constraint", .source = "function f<T extends Record<string,number>>(value: T): T { return value; }\nconst probe: number = f({ id: \"x\" });\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument { id: \"x\" } for 'T' does not satisfy constraint Record<string, number>", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "removed_constraint", .source = "function f<T extends any>(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument \"x\" for 'T' does not satisfy constraint any", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "removed_call_argument", .source = "function id<T>(value: T): T { return value; }\nconst probe: number = id<any>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected any, got \"x\"", .line = 2, .column = 31, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'any' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "removed_default", .source = "function f<T = any>(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "unclosed_function_angles", .source = "function f<T(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostics = &.{.{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 11, .suggestion = "'('" }} },
        .{ .name = "utility_collision", .source = "structural Partial<T> = number;\nstructural User = { id: string };\nconst probe: Partial<User> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ id?: string }'", .line = 3, .column = 1, .suggestion = null }} },
        .{ .name = "void_constraint", .source = "function f<T extends void>(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostics = &.{.{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" }} },
        .{ .name = "array_default", .source = "function f<T = Array<string>>(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostics = &.{.{ .code = "ZTS058", .message = "`Array<T>` is not a type spelling in this profile", .line = 1, .column = 16, .suggestion = "write `T[]`" }} },
        .{ .name = "array_call_argument", .source = "function id<T>(value: T): T { return value; }\nconst probe: number = id<Array<string>>(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostics = &.{.{ .code = "ZTS058", .message = "`Array<T>` is not a type spelling in this profile", .line = 2, .column = 26, .suggestion = "write `T[]`" }} },
        .{ .name = "quoted_comma_one_call", .source = "function f<T>(x: T): T { return x; }\nconst probe: number = f<\"a,b\">(\"a\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS210", .message = "wrong number of type arguments: expected 1, got 2", .line = 2, .column = 31, .suggestion = "Give one type argument for each declared type parameter." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "quoted_comma_two_call", .source = "function f<T,U>(x: T,y: U): T { return x; }\nconst probe: number = f<\"a,b\">(\"a\",1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected b, got 1", .line = 2, .column = 36, .suggestion = null }, .{ .code = "ZTS200", .message = "type '\"a\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "quoted_angle_default", .source = "function f<T = \">\",U = number>(x: U): U { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T'", .line = 2, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'U' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "quoted_comma_default", .source = "function f<T = \"a,b\",U = number>(x: U): U { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T'", .line = 2, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'U' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "comment_call", .source = "function f<T>(x: T): T { return x; }\nconst probe: number = f<string /* , */>(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS210", .message = "wrong number of type arguments: expected 1, got 2", .line = 2, .column = 40, .suggestion = "Give one type argument for each declared type parameter." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "comment_parameters", .source = "function f<T /* , */ ,U>(x: T,y: U): T { return x; }\nconst probe: number = f(\"x\",1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter '*/'", .line = 2, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "dictkey_constraint", .source = "function f<T extends DictKey>(x: T): T { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'number' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "dictkey_default", .source = "function f<T extends DictKey = string>(x: T): T { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument 1 for 'T' does not satisfy constraint DictKey", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "readonly_inline_record", .source = "const probe: { field: Readonly<{ id: number }> } = undefined;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ field: { id: number } }'", .line = 1, .column = 1, .suggestion = null }} },
        .{ .name = "readonly_inline_tuple", .source = "const probe: [Readonly<{ id: number }>] = undefined;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '[{ id: number }]'", .line = 1, .column = 1, .suggestion = null }} },
        .{ .name = "name32_root", .source = "function f<TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT>(x: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT): TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT { return x; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "name33_root", .source = "function f<TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT>(x: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT): TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT { return x; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "name32_array", .source = "function f<TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT>(x: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT[]): TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT[] { return x; }\nconst probe: number[] = f([\"x\"]);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string[]' is not assignable to type 'number[]'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "name33_array", .source = "function f<TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT>(x: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT[]): TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT[] { return x; }\nconst probe: number[] = f([\"x\"]);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string[]' is not assignable to type 'number[]'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "empty_first_name", .source = "function f<=string,T extends number>(x: T): T { return x; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "constraint_control", .source = "function f<T extends number>(x: T): T { return x; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument \"x\" for 'T' does not satisfy constraint number", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "empty_alias_parameters", .source = "structural Box<> = number;\nconst bare: Box = \"x\";\nconst applied: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'Box'", .line = 2, .column = 1, .suggestion = null }, .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null } } },
        .{ .name = "parenthesized_arrow_spaced_window", .source = "const id = (<T> (value: T): T => value);\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T>'", .line = 2, .column = 25, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "parenthesized_arrow_adjacent_window", .source = "const id = (<T>(value: T): T => value);\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "assignment_arrow_spaced_window", .source = "const id = <T> (value: T): T => value;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "empty_generic_alias_body", .source = "structural Box<> = ;\nconst bare: Box = \"x\";\nconst applied: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'Box'", .line = 2, .column = 1, .suggestion = null }, .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'Box<>'", .line = 3, .column = 1, .suggestion = null } } },
    };
    const types_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("generic baseline failed: {s}\n", .{case.name});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expect(case.diagnostics.len > 0);
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        const errors: u32 = @intCast(case.diagnostics.len);
        try std.testing.expectEqual(errors, result.totalErrors());
        switch (case.stage) {
            .strip => {
                try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
                try std.testing.expectEqual(errors, result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .parse => {
                try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
                try std.testing.expectEqual(errors, result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .types => {
                try std.testing.expectEqual(types_stages, result.stages_run);
                try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
                try std.testing.expectEqual(errors, result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .contract => {
                try std.testing.expectEqual(full_stages, result.stages_run);
                try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract != null);
            },
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 77), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves ignored generic syntax and raw semantic projection" {
    const cases = [_][]const u8{
        "structural Box<T>=T;\nconst value: Box<number> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T> = T;\nconst value: Box<number>=\"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T = (left < right)> = number;\nconst value: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T extends { value: Missing < } = boolean> = number;\nconst value: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T extends Wrap<{ value: Missing < }, string> = boolean> = number;\nconst value: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T = /x> = number; /* tail */\nconst value: Box<string> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T = (left > right)> = number;\nconst value: Box<string> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T extends { value: Missing > }> = number;\nconst value: Box<string> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T extends \"a=b\" = boolean> = number;\nconst value: Box<string> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T = Wrap<(x: string) => number, string>> = number;\nconst value: Box<string,number> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
    };
    const stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    var observed: usize = 0;
    for (cases) |source| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS200",
            .message = "type '\"x\"' is not assignable to type 'number'",
            .line = 2,
            .column = 1,
            .suggestion = null,
        });
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves a caught generic string diagnostic" {
    const source =
        "structural Box<T = (\"x\n)> = number;\n" ++
        "const value: Box<string> = \"x\";\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
        .code = "ZTS008",
        .message = "unterminated string literal",
        .line = 1,
        .column = 23,
        .suggestion = "close the quote, or write the newline as \\n",
    });
}

test "CHECK preserves the any suffix refusal in a generic alias name" {
    const source =
        "structural Many<A,B,C,D,E,F,G,H> = H;\n" ++
        "const value: Many<string,string,string,string,string,string,string,number> = undefined;\n";
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
        .code = "ZTS041",
        .message = "'any' type is not supported",
        .line = 2,
        .column = 15,
        .suggestion = "use specific types (string, number, object) or union types instead",
    });
}

test "CHECK preserves the general generic arrow window after an assignment comment" {
    const source =
        "const id = /* gap */ <T> (value: T): T => value;\n" ++
        "const probe: number = id(\"x\");\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 2), result.type_errors);
    try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(usize, 2), result.json_diagnostics.items.len);
    try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
        .code = "ZTS208",
        .message = "no argument determines type parameter 'T>'",
        .line = 2,
        .column = 25,
        .suggestion = "Name the type argument at the call site.",
    });
    try expectCompoundDiagnostic(result.json_diagnostics.items[1], .{
        .code = "ZTS200",
        .message = "type 'T' is not assignable to type 'number'",
        .line = 2,
        .column = 1,
        .suggestion = null,
    });
}

test "CHECK preserves arrow capture after line comment text" {
    const cases = [_]struct {
        source: []const u8,
        parse_refusal: bool,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{
            .source = "const id = // note\n<T> (value: T): T => value;\n" ++
                "const probe: number = id(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parse_refusal = false,
            .diagnostics = &.{
                .{ .code = "ZTS208", .message = "no argument determines type parameter 'T>'", .line = 3, .column = 25, .suggestion = "Name the type argument at the call site." },
                .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null },
            },
        },
        .{
            .source = "const id = // note=\n<T> (value: T): T => value;\n" ++
                "const probe: number = id(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parse_refusal = false,
            .diagnostics = &.{
                .{ .code = "ZTS208", .message = "no argument determines type parameter 'T>'", .line = 3, .column = 25, .suggestion = "Name the type argument at the call site." },
                .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null },
            },
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        try std.testing.expect(result.contract == null);
        if (case.parse_refusal) {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        } else {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 2), result.type_errors);
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK reads a generic arrow after a line comment like one with no comment" {
    const source =
        "const id = // note\n<T>(value: T): T => value;\n" ++
        "const probe: number = id(\"x\");\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
        .code = "ZTS200",
        .message = "type 'string' is not assignable to type 'number'",
        .line = 3,
        .column = 1,
        .suggestion = null,
    });
}

test "CHECK parses a generic arrow after return" {
    const cases = [_][]const u8{
        "function make() { return <T>(value: T): T => value; }\n",
        "function make() { return <T extends string = string>(value: T): T => value; }\n",
        "function make() { return <T>\n(value: T): T => value; }\n",
    };
    inline for (cases) |head| {
        const source = head ++
            "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    }
}

test "CHECK classifies predicate targets and quoted return types" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        type_failure: bool,
        diagnostic: CompoundDiagnostic,
    }{
        .{ .source = "function guard(value: unknown): missing is string { return true; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .type_failure = true, .diagnostic = .{ .code = "ZTS211", .message = "type predicate on 'guard' does not name an annotated parameter of 'guard'", .line = 1, .column = 1, .suggestion = "Name an annotated parameter of the function before 'is'." } },
        .{ .source = "function guard(value: unknown): \"x is y\" { return true; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .type_failure = true, .diagnostic = .{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 1, .column = 44, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" } },
        .{ .source = "function guard(value: unknown): value\tis\tstring { return true; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .type_failure = true, .diagnostic = .{ .code = "ZTS211", .message = "type predicate 'guard' is not verified by its body", .line = 1, .column = 1, .suggestion = "Return one admitted narrowing test over the named parameter, combined with &&, || or !." } },
    };
    const typed_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        if (case.type_failure) {
            try std.testing.expectEqual(@as(u32, 1), result.type_errors);
            try std.testing.expectEqual(typed_stages, result.stages_run);
            try std.testing.expect(result.contract == null);
        } else {
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
            try std.testing.expectEqual(full_stages, result.stages_run);
            try std.testing.expect(result.contract != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), cases.len);
}

test "CHECK preserves nominal declarations with ignored generic lists" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        strip_refusal: bool,
        diagnostic: CompoundDiagnostic,
    }{
        .{ .source = "nominal Id<T> = string;\nconst value: Id = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'Id'", .line = 2, .column = 1, .suggestion = null } },
        .{ .source = "nominal Id<T> = T;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 17, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
    };
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        if (case.strip_refusal) {
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
            try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
        } else {
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 1), result.type_errors);
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
}

test "CHECK preserves orphan generic prefix refusal positions" {
    const cases = [_]struct { source: []const u8, column: u32 }{
        .{ .source = "const value = <T> extends string;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .column = 19 },
        .{ .source = "const value = (<T> extends string);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .column = 20 },
        .{ .source = "<T> extends string;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .column = 5 },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS002",
            .message = "expected expression",
            .line = 1,
            .column = case.column,
            .suggestion = null,
        });
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves adjacent generic prefix refusals" {
    const cases = [_]struct { prefix: []const u8, column: u32 }{
        .{ .prefix = "const value = <T><U>{ id: 1 };", .column = 15 },
        .{ .prefix = "const value = <T><U>(1);", .column = 15 },
        .{ .prefix = "const value = (<T><U>{ id: 1 });", .column = 16 },
        .{ .prefix = "const value = (<T><U>(1));", .column = 16 },
        .{ .prefix = "<T><U>{ const value = 1; }", .column = 1 },
    };
    inline for (cases) |case| {
        const source = case.prefix ++ "\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n";
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS002",
            .message = "raw JSX is not supported; use ordinary TypeScript expressions",
            .line = 1,
            .column = case.column,
            .suggestion = null,
        });
    }
    try std.testing.expectEqual(@as(usize, 5), cases.len);
}

test "CHECK preserves typed parameter refusals across function header comments" {
    const cases = [_]struct {
        source: []const u8,
        parameter_column: ?u32,
    }{
        .{
            .source = "function /* gap */ identity<T>(value: T): T { return value; }\n" ++
                "const probe: number = identity(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parameter_column = 37,
        },
        .{
            .source = "function identity<T>/* gap */(value: T): T { return value; }\n" ++
                "const probe: number = identity(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parameter_column = 36,
        },
        .{
            .source = "function identity<T>(value: T): T { return value; }\n" ++
                "const probe: number = identity(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parameter_column = null,
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expect(result.contract == null);
        if (case.parameter_column) |column| {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
            try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
                .code = "ZTS003",
                .message = "unexpected token",
                .line = 1,
                .column = column,
                .suggestion = "')'",
            });
        } else {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 1), result.type_errors);
            try expectCompoundDiagnostic(result.json_diagnostics.items[0], .{
                .code = "ZTS200",
                .message = "type 'string' is not assignable to type 'number'",
                .line = 2,
                .column = 1,
                .suggestion = null,
            });
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves typed arrow return forms and parameter refusals" {
    const FailureStage = enum { strip, parse, types, strict, contract };
    const proof_diagnostic: CompoundDiagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." };
    // A module whose function value sits in a record or is returned by another function
    // proves no termination claim, so `cost_bounded` leaves the demanded profile.
    const proof_diagnostic_without_cost: CompoundDiagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: cost_bounded, deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\">`." };
    const cases = [_]struct { source: []const u8, stage: FailureStage, diagnostic: CompoundDiagnostic }{
        .{ .source = "const guard = (candidate, marker: unknown): boolean => typeof candidate === \"string\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .strict, .diagnostic = .{ .code = "ZTS601", .message = "strict ZigTS requires explicit function parameter and return types", .line = 1, .column = 15, .suggestion = "annotate each parameter and the return type, for example `function handler(req: Request): Response`" } },
        .{ .source = "const echo = (value: string): string => value;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const echo = (value?: string): string => value;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 20, .suggestion = "replace `name?: T` with `name: T | undefined`" } },
        .{ .source = "const echo = (value?) => value;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 20, .suggestion = "')'" } },
        .{ .source = "function echo(value?: string): string { return value; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 20, .suggestion = "replace `name?: T` with `name: T | undefined`" } },
        .{ .source = "function echo(value?) { return value; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 20, .suggestion = "')'" } },
        .{ .source = "const echo = (value: string = \"x\"): string => value;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 29, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" } },
        .{ .source = "const echo = async (value: string): string => value;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS001", .message = "'async' functions are not supported", .line = 1, .column = 14, .suggestion = "handlers run synchronously - use 'fetch' from zttp:fetch for outbound I/O" } },
        .{ .source = "const result = [\"a\"].map((value: string): string => value);\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const object = { echo: (value: string): string => value };\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = proof_diagnostic_without_cost },
        .{ .source = "const echo = ((value: string): string => value);\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const make = (): (value: string) => string => (value: string): string => value;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = proof_diagnostic_without_cost },
        .{ .source = "const guard = (value: unknown): missing is string => true;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS211", .message = "type predicate \x27guard\x27 must be a named module-level function declaration", .line = 1, .column = 1, .suggestion = "Declare the predicate as a function declaration at module level, or return boolean." } },
        .{ .source = "const guard = (value: unknown): \"x is y\" => true;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 1, .column = 15, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" } },
        .{ .source = "const guard = (value: unknown): value\tis\tstring => true;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS211", .message = "type predicate \x27guard\x27 must be a named module-level function declaration", .line = 1, .column = 1, .suggestion = "Declare the predicate as a function declaration at module level, or return boolean." } },
        .{ .source = "const guard = (readonly: unknown): readonly\tis\tstring => true;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS211", .message = "type predicate \x27guard\x27 must be a named module-level function declaration", .line = 1, .column = 1, .suggestion = "Declare the predicate as a function declaration at module level, or return boolean." } },
        .{ .source = "const echo = value: string => value;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 14, .suggestion = null } },
        .{ .source = "const choice = true ? \"a\" : \"b\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const choice = true ? (1) : (2);\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const make = (): (value: string) => string;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "unexpected ')'", .line = 1, .column = 16, .suggestion = null } },
        .{ .source = "function guard(value: unknown): value is { return true; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 42, .suggestion = "type annotation" } },
        .{ .source = "const guard = (value: unknown): value is => true;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 42, .suggestion = "type annotation" } },
        .{ .source = "function guard(value: unknown): value\tis { return true; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 42, .suggestion = "type annotation" } },
        .{ .source = "const guard = (value: unknown): value\tis => true;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 42, .suggestion = "type annotation" } },
        .{ .source = "function guard(value: unknown): value is string   { return true; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS211", .message = "type predicate 'guard' is not verified by its body", .line = 1, .column = 1, .suggestion = "Return one admitted narrowing test over the named parameter, combined with &&, || or !." } },
        .{ .source = "const guard = (value: unknown): value is string   => true;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS211", .message = "type predicate \x27guard\x27 must be a named module-level function declaration", .line = 1, .column = 1, .suggestion = "Declare the predicate as a function declaration at module level, or return boolean." } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("arrow baseline failed for source:\n{s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        const expected_stages = switch (case.stage) {
            .strip => StageSet.initMany(&.{.strip}),
            .parse => StageSet.initMany(&.{ .strip, .parse }),
            .types, .strict => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }),
            .contract => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict, .verifier, .flow, .contract, .paths, .trace, .spec, .canonical }),
        };
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.stage == .strip or case.stage == .parse) 1 else 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .types) 1 else 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .strict) 1 else 0), result.strict_errors);
        try std.testing.expectEqual(case.stage == .contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 26), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves predicate marker classification" {
    const FailureStage = enum { types, contract };
    const cases = [_]struct {
        source: []const u8,
        stage: FailureStage,
        diagnostic: CompoundDiagnostic,
    }{
        .{
            .source = "function guard(candidate: unknown): candidate is \"a is b\" { return true; }\n",
            .stage = .types,
            .diagnostic = .{
                .code = "ZTS211",
                .message = "type predicate 'guard' is not verified by its body",
                .line = 1,
                .column = 1,
                .suggestion = "Return one admitted narrowing test over the named parameter, combined with &&, || or !.",
            },
        },
        .{
            .source = "function guard(candidate: unknown): candidate\tis \"a is b\" { return true; }\n",
            .stage = .types,
            .diagnostic = .{
                .code = "ZTS211",
                .message = "type predicate 'guard' is not verified by its body",
                .line = 1,
                .column = 1,
                .suggestion = "Return one admitted narrowing test over the named parameter, combined with &&, || or !.",
            },
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            case.source,
            "handler.ts",
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        const expected_stages = switch (case.stage) {
            .types => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }),
            .contract => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict, .contract, .trace, .spec, .canonical }),
        };
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .types) 1 else 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(case.stage == .contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves type-only module admission and refusal diagnostics" {
    const FailureStage = enum { strip, parse, contract };
    const proof_diagnostic: CompoundDiagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." };
    const cases = [_]struct { source: []const u8, stage: FailureStage, diagnostic: CompoundDiagnostic }{
        .{ .source = "import type { A } from \"./a\";\nexport type { B }\nexport structural Shape = { value: string };\nexport nominal Id = string;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 6, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number { import type { A } from \"./a\"; return 1; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 29, .suggestion = null } },
        .{ .source = "function helper(): number { export type { A }; return 1; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'export' must be followed by 'function', 'const', or 'let'", .line = 1, .column = 29, .suggestion = null } },
        .{ .source = "{ import type { A } from \"./a\"; const live = 1; }\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 3, .suggestion = null } },
        .{ .source = "import type { A } from \"./a;b\";\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 3, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 24, .suggestion = null } },
        .{ .source = "import /* gap */ type { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 1, .suggestion = null } },
        .{ .source = "import type { Spec } from \"zttp:types\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 1, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" } },
        .{ .source = "import type { A } /* \"zttp:types\" */ from \"./a\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 1, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" } },
        .{ .source = "export type { Spec } from \"zttp:types\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "export type { A }   \nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 3, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "export type\n{ A };\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'export' must be followed by 'function', 'const', or 'let'", .line = 1, .column = 1, .suggestion = null } },
        .{ .source = "import\ntype { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 3, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "import type nonsense;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "export type { broken nonsense };\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {\n  import type { A } from \"./a\";\n  return 1;\n}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 2, .column = 3, .suggestion = null } },
        .{ .source = "function helper(): number {\n  export type { A };\n  return 1;\n}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'export' must be followed by 'function', 'const', or 'let'", .line = 2, .column = 3, .suggestion = null } },
        .{ .source = "{\n  import type { A } from \"./a\";\n  const live = 1;\n}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 2, .column = 3, .suggestion = null } },
        .{ .source = "{import type { A } from \"./a\";}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {import type { A } from \"./a\";return 1;}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {export type { A };return 1;}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "{\nimport type { A } from \"./a\";\n}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 4, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {\nimport type { A } from \"./a\";\nreturn 1;\n}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 5, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {\nexport type { A };\nreturn 1;\n}\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 5, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = " import type { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 2, .suggestion = null } },
        .{ .source = "const live: number = 1;import type { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "const live: number = 1; import type { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 25, .suggestion = null } },
        .{ .source = "import type { A } from \"./a\";export type { B };\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'export' must be followed by 'function', 'const', or 'let'", .line = 1, .column = 30, .suggestion = null } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("module baseline failed for source:\n{s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        const expected_stages = switch (case.stage) {
            .strip => StageSet.initMany(&.{.strip}),
            .parse => StageSet.initMany(&.{ .strip, .parse }),
            .contract => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict, .verifier, .flow, .contract, .paths, .trace, .spec, .canonical }),
        };
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.stage == .contract) 0 else 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(case.stage == .contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 28), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves lexical diagnostics inside type-only modules" {
    const cases = [_]struct { source: []const u8, contract: bool, diagnostics: []const CompoundDiagnostic }{
        .{ .source = "import type \"open\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 18, .suggestion = "close the quote, or write the newline as \\n" },
        } },
        .{ .source = "import type \"open\\\nclosed\";\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = true, .diagnostics = &.{
            .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 4, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." },
        } },
        .{ .source = "import type `${" ++ (&@as([511:0]u8, @splat('{'))) ++ "1" ++ (&@as([512:0]u8, @splat('}'))) ++ "}`;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = true, .diagnostics = &.{
            .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 3, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." },
        } },
        .{ .source = "import type `${" ++ (&@as([512:0]u8, @splat('{'))) ++ ";" ++ (&@as([513:0]u8, @splat('}'))) ++ "}`;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS044", .message = "type syntax nests too deeply", .line = 1, .column = 527, .suggestion = "simplify or split it (nesting limit is 512)" },
        } },
        .{ .source = "import type " ++ (@as([(511) * ("`${").len]u8, @bitCast(@as([511][("`${").len]u8, @splat(("`${").*))))) ++ "1" ++ (@as([(511) * ("}`").len]u8, @bitCast(@as([511][("}`").len]u8, @splat(("}`").*))))) ++ ";\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = true, .diagnostics = &.{
            .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 3, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." },
        } },
        .{ .source = "import type " ++ (@as([(513) * ("`${").len]u8, @bitCast(@as([513][("`${").len]u8, @splat(("`${").*))))) ++ "1" ++ (@as([(513) * ("}`").len]u8, @bitCast(@as([513][("}`").len]u8, @splat(("}`").*))))) ++ ";\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = true, .diagnostics = &.{
            .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 3, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." },
        } },
        .{ .source = "import type \"open\nimport type { Spec } from \"zttp:types\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 2, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "import type `${\"open\n\"}`;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 21, .suggestion = "close the quote, or write the newline as \\n" },
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 2, .column = 5, .suggestion = "close the quote, or write the newline as \\n" },
        } },
        .{ .source = "import type \"open\nconst broken = ;\nimport type { Spec } from \"zttp:types\";\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 3, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "import type `${" ++ (&@as([511:0]u8, @splat('{'))) ++ "`${" ++ (&@as([512:0]u8, @splat('{'))) ++ ";" ++ (&@as([513:0]u8, @splat('}'))) ++ "}`" ++ (&@as([512:0]u8, @splat('}'))) ++ "}`;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.json({ now: Date.now() }); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS044", .message = "type syntax nests too deeply", .line = 1, .column = 1041, .suggestion = "simplify or split it (nesting limit is 512)" },
        } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("module lexical baseline failed for source:\n{s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        const expected_stages = if (case.contract)
            StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict, .verifier, .flow, .contract, .paths, .trace, .spec, .canonical })
        else
            StageSet.initMany(&.{.strip});
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.contract) 0 else @intCast(case.diagnostics.len)), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(case.contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves typed generic arrows and comment classification" {
    const FailureStage = enum { parse, types, strict };
    const cases = [_]struct { source: []const u8, stage: FailureStage, diagnostics: []const CompoundDiagnostic }{
        .{ .source = "const id=<T>(value: T): T => value;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null },
        } },
        .{ .source = "const id=(<T> (value: T): T => value);\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{
            .{ .code = "ZTS208", .message = "no argument determines type parameter 'T>'", .line = 2, .column = 25, .suggestion = "Name the type argument at the call site." },
            .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null },
        } },
        .{ .source = "const id = // note\n<T = string>(value: T): T => value;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null },
        } },
        .{ .source = "const id = // note=\n<T = string> (value: T): T => value;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null },
        } },
        .{ .source = "function // note\nidentity<T>(value) { return value; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strict, .diagnostics = &.{
            .{ .code = "ZTS601", .message = "strict ZigTS requires explicit function parameter and return types", .line = 2, .column = 12, .suggestion = "annotate each parameter and the return type, for example `function handler(req: Request): Response`" },
        } },
        .{ .source = "function identity<T>// note\n(value) { return value; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strict, .diagnostics = &.{
            .{ .code = "ZTS601", .message = "strict ZigTS requires explicit function parameter and return types", .line = 2, .column = 1, .suggestion = "annotate each parameter and the return type, for example `function handler(req: Request): Response`" },
        } },
        .{ .source = "function /* before */ identity<T>/* after */(value) { return value; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostics = &.{
            .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 31, .suggestion = "'('" },
        } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("generic header baseline failed for source:\n{s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        const expected_count: u32 = @intCast(case.diagnostics.len);
        try std.testing.expectEqual(expected_count, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        const expected_stages = if (case.stage == .parse)
            StageSet.initMany(&.{ .strip, .parse })
        else
            StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.stage == .parse) expected_count else 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .types) expected_count else 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .strict) expected_count else 0), result.strict_errors);
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves repeated global declaration bindings" {
    const Case = enum {
        two_typed,
        typed_untyped,
        untyped_typed_bad,
        two_typed_bad,
    };
    const proof_suggestion =
        "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, " ++
        "but it does not hold: cost_bounded, deterministic, fault_covered, idempotent, injection_safe, input_validated, no_credential_leakage, no_secret_leakage, optional_safe, pii_contained, result_safe, state_isolated. " ++
        "Return a narrow Proof capsule with only the properties it holds, e.g. " ++
        "`function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | " ++
        "\"pure\" | \"stateless\" | \"canonical\">`.";
    const cases = [_]struct {
        case: Case,
        source: []const u8,
        type_errors: u32,
        has_contract: bool,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{
            .case = .two_typed,
            .source = "const value: number = 1;\n" ++
                "const value: string = \"x\";\n",
            .type_errors = 0,
            .has_contract = true,
            .diagnostics = &.{.{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 1,
                .column = 1,
                .suggestion = proof_suggestion,
            }},
        },
        .{
            .case = .typed_untyped,
            .source = "const value: number = 1;\n" ++
                "const value = \"x\";\n",
            .type_errors = 0,
            .has_contract = true,
            .diagnostics = &.{.{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 1,
                .column = 1,
                .suggestion = proof_suggestion,
            }},
        },
        .{
            .case = .untyped_typed_bad,
            .source = "const value = 1;\n" ++
                "const value: string = 2;\n",
            .type_errors = 1,
            .has_contract = false,
            .diagnostics = &.{.{
                .code = "ZTS200",
                .message = "type '2' is not assignable to type 'string'",
                .line = 2,
                .column = 1,
            }},
        },
        .{
            .case = .two_typed_bad,
            .source = "const value: number = \"x\";\n" ++
                "const value: string = 2;\n",
            .type_errors = 2,
            .has_contract = false,
            .diagnostics = &.{
                .{
                    .code = "ZTS200",
                    .message = "type '\"x\"' is not assignable to type 'number'",
                    .line = 1,
                    .column = 1,
                },
                .{
                    .code = "ZTS200",
                    .message = "type '2' is not assignable to type 'string'",
                    .line = 2,
                    .column = 1,
                },
            },
        },
    };
    var seen = std.EnumSet(Case).empty;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            case.source,
            "handler.ts",
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(case.type_errors, result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        try std.testing.expectEqual(case.has_contract, result.contract != null);
        seen.insert(case.case);
    }
    try std.testing.expectEqual(@typeInfo(Case).@"enum".field_names.len, seen.count());
}

test "CHECK preserves nominal generic diagnostic order before scalar refusal" {
    const cases = [_]struct { source: []const u8, diagnostics: []const CompoundDiagnostic }{
        .{ .source = "nominal Id<T extends void> = T;", .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" },
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 30, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "nominal Id<T extends void>;", .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" },
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 27, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "nominal Id<T extends void> = ;", .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" },
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 30, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "nominal Id<T extends any> = T;", .diagnostics = &.{
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 29, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "nominal Id<T extends void> = any;", .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" },
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 30, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        const expected_count: u32 = @intCast(case.diagnostics.len);
        try std.testing.expectEqual(expected_count, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
        try std.testing.expectEqual(expected_count, result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves measured lookup winners shadows and captures" {
    const ambient_suggestion =
        "Import a published virtual-module capability or use an ambient name listed by " ++
        "meta.ambient_names.";
    const predicate_suggestion =
        "Return one admitted narrowing test over the named parameter, combined with &&, || or !.";
    const return_suggestion =
        "the enclosing function's declared return type is what this value must match; " ++
        "when it comes back from a virtual-module call, wrap it rather than returning it directly";
    const untyped_contract_suggestion =
        "this handler returns no Proof<T, P> capsule, so the compiler must prove the full " ++
        "default profile, but it does not hold: deterministic, idempotent, pure. Return a narrow " ++
        "Proof capsule with only the properties it holds, e.g. `function handler(req: Request): " ++
        "Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"fault_covered\" | " ++
        "\"stateless\" | \"result_safe\" | \"optional_safe\" | " ++
        "\"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | " ++
        "\"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`.";
    const capture_contract_suggestion =
        "this handler returns no Proof<T, P> capsule, so the compiler must prove the full " ++
        "default profile, but it does not hold: cost_bounded, idempotent, pure, " ++
        "read_only, retry_safe, stateless. Return a narrow Proof capsule with only the " ++
        "properties it holds, e.g. `function handler(req: Request): Proof<Response, " ++
        "\"state_isolated\" | \"fault_covered\" | \"result_safe\" | \"optional_safe\" | " ++
        "\"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | " ++
        "\"pii_contained\" | \"injection_safe\" | \"canonical\">`.";
    const cases = [_]struct {
        source: []const u8,
        type_errors: u32,
        strict_errors: u32,
        has_contract: bool,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{
            .source =
            \\function useNumber(value: number): number {
            \\  inner(value);
            \\  function inner(item: number): number { return item; }
            \\  return value;
            \\}
            \\function useText(value: string): string {
            \\  inner(value, "");
            \\  function inner(item: string, suffix: string): string { return item; }
            \\  return value;
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ number: useNumber(1), text: useText("x") });
            \\}
            \\
            ,
            .type_errors = 1,
            .strict_errors = 2,
            .has_contract = false,
            .diagnostics = &.{
                .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 7, .column = 9 },
                .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = ambient_suggestion },
                .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 7, .column = 3, .suggestion = ambient_suggestion },
            },
        },
        .{
            .source =
            \\{
            \\  function isText(value: string | number): value is string {
            \\    return typeof value === "string";
            \\  }
            \\  const raw: string | number = "first";
            \\  if (isText(raw)) { const text: string = raw; }
            \\}
            \\{
            \\  function isText(skip: number, value: string | number): value is string {
            \\    return typeof value === "string";
            \\  }
            \\  const raw: string | number = "second";
            \\  if (isText(0, raw)) { const text: string = raw; }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ ok: true });
            \\}
            \\
            ,
            .type_errors = 2,
            .strict_errors = 0,
            .has_contract = false,
            .diagnostics = &.{
                .{ .code = "ZTS211", .message = "type predicate 'isText' is not verified by its body", .line = 9, .column = 3, .suggestion = predicate_suggestion },
                .{ .code = "ZTS200", .message = "type 'string | number' is not assignable to type 'string'", .line = 13, .column = 25 },
            },
        },
        .{
            .source =
            \\function numericValue(): number {
            \\  const value: number = make();
            \\  function make(): number { return 1; }
            \\  return value;
            \\}
            \\function textValue(): string {
            \\  const value: string = make();
            \\  function make(): string { return "text"; }
            \\  return value;
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ number: numericValue(), text: textValue() });
            \\}
            \\
            ,
            .type_errors = 1,
            .strict_errors = 1,
            .has_contract = false,
            .diagnostics = &.{
                .{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 3 },
                .{ .code = "ZTS629", .message = "unpublished ambient global 'make'", .line = 7, .column = 25, .suggestion = ambient_suggestion },
            },
        },
        .{
            .source =
            \\const item: number = 1;
            \\function readItem(): string {
            \\  const item = "inferred";
            \\  {
            \\    const item: string = "typed";
            \\    return item;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ top: item, nested: readItem(), now: Date.now() });
            \\}
            \\
            ,
            .type_errors = 0,
            .strict_errors = 0,
            .has_contract = true,
            .diagnostics = &.{.{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 9,
                .column = 24,
                .suggestion = untyped_contract_suggestion,
            }},
        },
        .{
            .source =
            \\function compute(): number {
            \\  const value: number = 1;
            \\  const readOuter = (): number => value;
            \\  {
            \\    const value: string = "inner";
            \\    const readInner = (): string => value;
            \\    const outerResult: number = readOuter();
            \\    const innerResult: string = readInner();
            \\    return outerResult;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ value: compute() });
            \\}
            \\
            ,
            .type_errors = 0,
            .strict_errors = 0,
            .has_contract = true,
            .diagnostics = &.{
                .{
                    .code = "ZTS500",
                    .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                    .line = 12,
                    .column = 24,
                    .suggestion = capture_contract_suggestion,
                },
                .{
                    .code = "ZTS606",
                    .message = "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: pure)",
                    .line = 1,
                    .column = 1,
                    .suggestion = "the handler returns no Proof<T, P> capsule, so the default profile demands `pure`, and `compute` breaks it: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or make `compute` hold `pure` and annotate it with `Proof<T, \"pure\">`.",
                },
                .{
                    .code = "ZTS606",
                    .message = "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: read_only)",
                    .line = 1,
                    .column = 1,
                    .suggestion = "the handler returns no Proof<T, P> capsule, so the default profile demands `read_only`, and `compute` breaks it: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or make `compute` hold `read_only` and annotate it with `Proof<T, \"read_only\">`.",
                },
                .{
                    .code = "ZTS606",
                    .message = "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: deterministic)",
                    .line = 1,
                    .column = 1,
                    .suggestion = "the handler returns no Proof<T, P> capsule, so the default profile demands `deterministic`, and `compute` breaks it: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or make `compute` hold `deterministic` and annotate it with `Proof<T, \"deterministic\">`.",
                },
            },
        },
        .{
            .source =
            \\const item: number = 1;
            \\function readItem(): string {
            \\  const item = "inferred";
            \\  {
            \\    const item: string = 2;
            \\    return item;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ top: item, nested: readItem() });
            \\}
            \\
            ,
            .type_errors = 1,
            .strict_errors = 0,
            .has_contract = false,
            .diagnostics = &.{.{
                .code = "ZTS200",
                .message = "type '2' is not assignable to type 'string'",
                .line = 5,
                .column = 5,
            }},
        },
        .{
            .source =
            \\function compute(): number {
            \\  const value: number = 1;
            \\  const readOuter = (): number => value;
            \\  {
            \\    const value: string = "inner";
            \\    const readInner = (): number => value;
            \\    const outerResult: number = readOuter();
            \\    const innerResult: number = readInner();
            \\    return outerResult;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ value: compute() });
            \\}
            \\
            ,
            .type_errors = 1,
            .strict_errors = 0,
            .has_contract = false,
            .diagnostics = &.{.{
                .code = "ZTS204",
                .message = "return type does not match declared return type",
                .line = 6,
                .column = 23,
                .suggestion = return_suggestion,
            }},
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            case.source,
            "handler.ts",
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(case.type_errors, result.type_errors);
        try std.testing.expectEqual(case.strict_errors, result.strict_errors);
        try std.testing.expectEqual(
            @as(u32, @intCast(case.diagnostics.len)),
            result.totalErrors(),
        );
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        try std.testing.expectEqual(case.has_contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves measured recovery contexts and raw recognition guards" {
    const allocator = std.testing.allocator;
    const any_message = "'any' type is not supported";
    const any_suggestion = "use specific types (string, number, object) or union types instead";
    const namespace_message = "'import * as X' namespace imports are not supported; use named imports: import { x } from \"module\"";
    const type_diagnostic: CompoundDiagnostic = .{
        .code = "ZTS050",
        .message = "`type` is not a declaration form in this profile",
        .line = 1,
        .column = 1,
        .suggestion = "write `structural Name = ...;`",
    };
    const interface_diagnostic: CompoundDiagnostic = .{
        .code = "ZTS049",
        .message = "`interface` is not a declaration form in this profile",
        .line = 1,
        .column = 1,
        .suggestion = "write `structural Name = { ... };`",
    };
    const default_diagnostic: CompoundDiagnostic = .{
        .code = "ZTS054",
        .message = "default parameters are not part of this profile",
        .line = 1,
        .column = 14,
        .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body",
    };
    const nominal_diagnostic: CompoundDiagnostic = .{
        .code = "ZTS048",
        .message = "a nominal declaration carries scalar identity only",
        .line = 1,
        .column = 11,
        .suggestion = "its base must be `string`, `number`, or `boolean`",
    };
    const cases = [_]struct {
        source: []const u8,
        parser_stage: bool,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{
            .source = "while (true) { const x: any = 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS041", .message = any_message, .line = 1, .column = 25, .suggestion = any_suggestion }},
        },
        .{
            .source = "const x: /* closed */ any = 1;\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS002", .message = "const declarations must have an initializer", .line = 1, .column = 8 },
                .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 7 },
            },
        },
        .{
            .source = "function f(x: /* closed */ any) { return x; }\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 13, .suggestion = "')'" }},
        },
        .{
            .source = "function f(): /* closed */ any { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 13, .suggestion = "'{'" }},
        },
        .{
            .source = "const x = value as \"open\n; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 1, .column = 20, .suggestion = "use type-safe patterns instead" },
                .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 25, .suggestion = "close the quote, or write the newline as \\n" },
                .{ .code = "ZTS041", .message = any_message, .line = 2, .column = 16, .suggestion = any_suggestion },
            },
        },
        .{
            .source = "import * as ns from \"./dep.ts\";\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS002", .message = namespace_message, .line = 1, .column = 1 }},
        },
        .{
            .source = "import * as ns from \"./dep.ts\";\nconst x = value as number;\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 2, .column = 20, .suggestion = "use type-safe patterns instead" }},
        },
        .{
            .source = "import * as ns from \"./dep.ts\"\nconst x = value as number;\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS002", .message = namespace_message, .line = 1, .column = 1 }},
        },
        .{
            .source = "function f(): number {\n  while (true) { const x: number = 1; }\n  return 1;\n}\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS001", .message = "'while' is not supported", .line = 2, .column = 3, .suggestion = "use 'for-of' with a finite collection instead" }},
        },
        .{
            .source = " export default 1;\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS001", .message = "default exports are not supported", .line = 1, .column = 9, .suggestion = "write a named export, for example `export function handler(...) { ... }`" }},
        },
        .{
            .source = "export/*c*/let x = 1;\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS001", .message = "mutable exports are not supported", .line = 1, .column = 12, .suggestion = "use `export const` for module values and keep reassignment inside a function activation" }},
        },
        .{
            .source = "type Alias/* c */ = any;\n",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "type Alias<T>/* c */ = any;\n",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "interface Shape;\n",
            .parser_stage = false,
            .diagnostics = &.{interface_diagnostic},
        },
        .{
            .source = "interface Shape/*c*/;\n",
            .parser_stage = false,
            .diagnostics = &.{interface_diagnostic},
        },
        .{
            .source = "nominal Bad = T\n;type Alias = number;\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" }},
        },
        .{
            .source = "type Alias /* open",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "type Alias<T> /* open",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "interface A {} ;type B = number;\n",
            .parser_stage = false,
            .diagnostics = &.{interface_diagnostic},
        },
        .{
            .source = "type A = number\n;type B = number;\n",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "interface A {} ;\ntype B = number;\n",
            .parser_stage = false,
            .diagnostics = &.{
                interface_diagnostic,
                .{ .code = "ZTS050", .message = "`type` is not a declaration form in this profile", .line = 2, .column = 1, .suggestion = "write `structural Name = ...;`" },
            },
        },
        .{
            .source = "function f(x = function () {}, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{ default_diagnostic, .{ .code = "ZTS041", .message = any_message, .line = 1, .column = 35, .suggestion = any_suggestion } },
        },
        .{
            .source = "function f({ x }, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS041", .message = any_message, .line = 1, .column = 22, .suggestion = any_suggestion }},
        },
        .{
            .source = "function f(x = 1, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{ default_diagnostic, .{ .code = "ZTS041", .message = any_message, .line = 1, .column = 22, .suggestion = any_suggestion } },
        },
        .{
            .source = "nominal N /* gap */ = string;\n",
            .parser_stage = false,
            .diagnostics = &.{nominal_diagnostic},
        },
        .{
            .source = "nominal N /* gap */ = any;\n",
            .parser_stage = false,
            .diagnostics = &.{nominal_diagnostic},
        },
        .{
            .source = "nominal N<T> /* gap */ = string;\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 14, .suggestion = "its base must be `string`, `number`, or `boolean`" }},
        },
        .{
            .source = "nominal N /* open",
            .parser_stage = false,
            .diagnostics = &.{nominal_diagnostic},
        },
        .{
            .source = "nominal /* gap */ N = string;\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 1 }},
        },
        .{
            .source = "function f({ x } = {}, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 18, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: any = {}, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 19, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 23, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 32, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: /* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 42, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: Box<number, string>, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 43, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: \"open\n, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 24, .suggestion = "close the quote, or write the newline as \\n" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 6, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x = y => y, z: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 14, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 18, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x = a == b, z: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 14, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 18, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 19, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }?: number, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 17, .suggestion = "replace `name?: T` with `name: T | undefined`" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 31, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function outer(): number { function inner({ x }) { return 1; } while (true) {} return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "destructured parameters are not supported", .line = 1, .column = 43, .suggestion = "bind one parameter, then read its members explicitly in the body" },
                .{ .code = "ZTS001", .message = "'while' is not supported", .line = 1, .column = 64, .suggestion = "use 'for-of' with a finite collection instead" },
            },
        },
        .{
            .source = "function outer(): number { function inner({ x }: /* gap */ number) { return 1; } while (true) {} return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "destructured parameters are not supported", .line = 1, .column = 43, .suggestion = "bind one parameter, then read its members explicitly in the body" },
                .{ .code = "ZTS001", .message = "'while' is not supported", .line = 1, .column = 82, .suggestion = "use 'for-of' with a finite collection instead" },
            },
        },
        .{
            .source = "function outer(): number { function inner({ x }) { return 1; } const later: any = 1; return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 77, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 38, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }:\n /* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 3, .column = 1, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: /* closed */ any, y: void) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 40, .suggestion = "write `undefined`" },
            },
        },
        .{
            .source = "function f({ x }:\n /* closed */ any,\n y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 4, .column = 1, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* closed */ any, y = 1) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 37, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
            },
        },
        .{
            .source = "function f(x:\t/* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 38, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x:\r /* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 39, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* closed */ any, y: /* closed */ any, z: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 61, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* closed */ number, y: number) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 13, .suggestion = "')'" },
            },
        },
        .{
            .source = "const x:\n /* closed */ number = 1; const y: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 36, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f():\n /* closed */ number { return 1; } const y: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 45, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x:\r any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const x:\r any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 10, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f():\r any { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x?\r: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 13, .suggestion = "replace `name?: T` with `name: T | undefined`" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 16, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x:\r number, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 26, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const x:\r /* closed */ number = 1; const y: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 45, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f():\r /* closed */ number { return 1; } const y: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 58, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const seed =\r 1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 30, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const seed = 1 ===\r 1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 36, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 14, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 23, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function\r f(x: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f\r(x: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function\r (x: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 24, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f<T>\r(x: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 18, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f<T>\r; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 29, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = <T>\r(x: any) => x;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 18, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = <T>\r value; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 36, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = id<T>\r(1); const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 35, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural\r X = number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 37, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural X\r = number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 37, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural X<T>\r = number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 40, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural X =\r number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 37, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural X = number\n\r; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 16, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const seed =\r1; type\r X = any;\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 17 },
            },
        },
        .{
            .source = "nominal N =\r any;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 13, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "interface X extends\r any {};\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 21, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS049", .message = "`interface` is not a declaration form in this profile", .line = 1, .column = 1, .suggestion = "write `structural Name = { ... };`" },
            },
        },
        .{
            .source = "import\r type { X } from './x.ts'; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 47, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "export\r type { X } from './x.ts'; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 47, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "export\r structural X = number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 44, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "export\r default\r 1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS056", .message = "default exports are not part of this profile", .line = 1, .column = 1, .suggestion = "write a named export, for example `export function handler(...) { ... }`" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 32, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "export\r let value: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS057", .message = "mutable exports are not part of this profile", .line = 1, .column = 1, .suggestion = "use `export const` for module values and keep reassignment inside a function activation" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 19, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const seed = value as\r any;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 1, .column = 23, .suggestion = "use type-safe patterns instead" },
            },
        },
        .{
            .source = "const seed = value satisfies\r any;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS043", .message = "'satisfies' type assertion is not supported", .line = 1, .column = 30, .suggestion = "use type-safe patterns instead" },
            },
        },
        .{
            .source = "const seed: () =>\r any = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 19, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(): () =>\r any { return value; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 21, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: () =>\r any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 22, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f: (x: any) =>\r any = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 14, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 22, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f: (x: void) =>\r number = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 14, .suggestion = "write `undefined`" },
            },
        },
        .{
            .source = "const f: (x: void) =>\r any = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 23, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 14, .suggestion = "write `undefined`" },
            },
        },
        .{
            .source = "const f: (x: \"open\n) =>\r any = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 19, .suggestion = "close the quote, or write the newline as \\n" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 6, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f: () =>\r () =>\r any = value;\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS002", .message = "const declarations must have an initializer", .line = 1, .column = 20 },
                .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 7 },
            },
        },
        .{
            .source = "interface X extends () =>\r any {};\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 28, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS049", .message = "`interface` is not a declaration form in this profile", .line = 1, .column = 1, .suggestion = "write `structural Name = { ... };`" },
            },
        },
        .{
            .source = "const f = value as () =>\r any;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 1, .column = 20, .suggestion = "use type-safe patterns instead" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function/* gap */f<T>(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "default parameters are not supported", .line = 1, .column = 25, .suggestion = "accept `T | undefined` and resolve the default at the start of the body" },
            },
        },
        .{
            .source = "function/* gap */f<T>(x?\r: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 24, .suggestion = "')'" },
            },
        },
        .{
            .source = "function/* gap */f(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "default parameters are not supported", .line = 1, .column = 22, .suggestion = "accept `T | undefined` and resolve the default at the start of the body" },
            },
        },
        .{
            .source = "function f<T>/* gap */(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "default parameters are not supported", .line = 1, .column = 26, .suggestion = "accept `T | undefined` and resolve the default at the start of the body" },
            },
        },
        .{
            .source = "function/* gap */f<T>({x}: /* gap */ number, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "destructured parameters are not supported", .line = 1, .column = 23, .suggestion = "bind one parameter, then read its members explicitly in the body" },
            },
        },
        .{
            .source = "function/* gap */f(x: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 21, .suggestion = "')'" },
            },
        },
        .{
            .source = "function f/* gap */(x: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 22, .suggestion = "')'" },
            },
        },
        .{
            .source = "function f/* gap */(x?: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 22, .suggestion = "')'" },
            },
        },
        .{
            .source = "function f/* gap */(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "default parameters are not supported", .line = 1, .column = 23, .suggestion = "accept `T | undefined` and resolve the default at the start of the body" },
            },
        },
        .{
            .source = "function f<T = string>\r; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 38, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f<T = string>\r; const seed =\r1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 53, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: number) { const seed =\r1; const later: any = 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 53, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* gap */ number) {} const seed =\r1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 66, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function(x: number) { return 1; };\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "function expressions are not supported", .line = 1, .column = 11, .suggestion = "use arrow functions '(x) => x * 2' or function declarations 'function name() { }' instead" },
            },
        },
        .{
            .source = "const f = function(x?: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 21, .suggestion = "replace `name?: T` with `name: T | undefined`" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 24, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function(x = 1, y: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 22, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 30, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function<T>\r(x: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 26, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function g<T>\r(x: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 28, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function/* gap */(x: any) { return 1; };\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "function expressions are not supported", .line = 1, .column = 11, .suggestion = "use arrow functions '(x) => x * 2' or function declarations 'function name() { }' instead" },
            },
        },
        .{
            .source = "function f<T as number>\r; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 39, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f<T = string>\r;\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 24, .suggestion = "'('" },
            },
        },
        .{
            .source = "function f<T> /* unfinished\n",
            .parser_stage = false,
            .diagnostics = &.{},
        },
        .{ .source = "import\r { value } from './x.ts'; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 47, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "export type\r { X }; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 34, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "import\r type { X } from \"open\nconst later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 29, .suggestion = "close the quote, or write the newline as \\n" },
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 14, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "const seed =\r1;import\r type { X } from 'zttp:types';\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 1, .column = 15, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "import\r type `${\"open\n}` from 'zttp:types';\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 1, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "const seed =\r1;export\r default\r 1; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS056", .message = "default exports are not part of this profile", .line = 1, .column = 15, .suggestion = "write a named export, for example `export function handler(...) { ... }`" },
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 46, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "export\r const seed = 1; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 38, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "const value = <T>\r extends Missing; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 49, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
    };
    try std.testing.expectEqual(@as(usize, 124), cases.len);
    for (cases) |case| {
        errdefer std.debug.print("CHECK recovery context failed: {s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        const stages = if (case.parser_stage)
            StageSet.initMany(&.{ .strip, .parse })
        else
            StageSet.initMany(&.{.strip});
        try std.testing.expectEqual(stages, result.stages_run);
        const expected_errors: u32 = @intCast(@max(1, case.diagnostics.len));
        try std.testing.expectEqual(expected_errors, result.parse_errors);
        try std.testing.expectEqual(expected_errors, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        try std.testing.expect(result.is_typescript);
        try std.testing.expect(!result.verify_ran);
        try std.testing.expect(result.contract == null);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
    }
}

test "CHECK preserves absent structural aliases at comment boundaries" {
    const cases = [_]struct {
        source: []const u8,
        diagnostics: []const CompoundDiagnostic,
    }{
        .{ .source = "structural X/* c */\nfunction handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }\n", .diagnostics = &.{} },
        .{ .source = "structural X/* c */\nfunction handler(req: Request): Proof<Response, \"pure\"> { const x: X = 1; return Response.text(\"ok\"); }\n", .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'X'", .line = 2, .column = 59 },
        } },
        .{ .source = "structural X<T>/* c */\nfunction handler(req: Request): Proof<Response, \"pure\"> { const x: X<number> = 1; return Response.text(\"ok\"); }\n", .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'X<number>'", .line = 2, .column = 59 },
        } },
        .{ .source = "structural X\r /* c */\nfunction handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }\n", .diagnostics = &.{} },
    };
    try std.testing.expectEqual(@as(usize, 4), cases.len);
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expect(result.stages_run.contains(.types));
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.type_errors);
        try std.testing.expectEqual(result.type_errors, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectCompoundDiagnostic(actual, expected);
        }
        try std.testing.expectEqual(case.diagnostics.len == 0, result.contract != null);
    }
}

test "CHECK preserves raw module recovery and the complete nested parser batch" {
    const cases = [_]struct { source: []const u8, parser_stage: bool, diagnostics: []const CompoundDiagnostic }{
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .parser_stage = true, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 24, .suggestion = null },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst later = \"open\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 2, .column = 20, .suggestion = "close the quote, or write the newline as \\n" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 14, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "function f() {\nimport type { A } /* ; */ from \"./a\";\nconst live = 1;\n}\n", .parser_stage = true, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "expected expression", .line = 2, .column = 24, .suggestion = null },
            .{ .code = "ZTS003", .message = "unexpected token", .line = 5, .column = 1, .suggestion = "'}'" },
        } },
        .{ .source = "function f() {\nimport type { A } /* ; */ from \"./a\";\nconst live: \"const\" = 1;\n}\n", .parser_stage = true, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "expected expression", .line = 2, .column = 24, .suggestion = null },
            .{ .code = "ZTS003", .message = "unexpected token", .line = 5, .column = 1, .suggestion = "'}'" },
        } },
        .{ .source = "function f() {\nimport type { A } /* ; */ from \"./a\";\nconst live: \"return\" = 1;\n}\n", .parser_stage = true, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "expected expression", .line = 2, .column = 24, .suggestion = null },
            .{ .code = "ZTS003", .message = "unexpected token", .line = 5, .column = 1, .suggestion = "'}'" },
        } },
    };
    try std.testing.expectEqual(@as(usize, 6), cases.len);
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(if (case.parser_stage) StageSet.initMany(&.{ .strip, .parse }) else StageSet.initMany(&.{.strip}), result.stages_run);
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.parse_errors);
        try std.testing.expectEqual(result.parse_errors, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| try expectCompoundDiagnostic(actual, expected);
        try std.testing.expect(result.contract == null);
    }
}

test "CHECK preserves spaced function call-list selection and strict refusal" {
    const cases = [_]struct { source: []const u8, strict: bool, diagnostic: CompoundDiagnostic }{
        .{ .source = "function id <T>(x) { return x; }\nfunction handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }\n", .strict = true, .diagnostic = .{ .code = "ZTS601", .message = "strict ZigTS requires explicit function parameter and return types", .line = 1, .column = 16, .suggestion = "annotate each parameter and the return type, for example `function handler(req: Request): Response`" } },
        .{ .source = "function id <T> (x) { return x; }\nfunction handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }\n", .strict = false, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 13, .suggestion = "'('" } },
    };
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        const stages = if (case.strict) StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }) else StageSet.initMany(&.{ .strip, .parse });
        try std.testing.expectEqual(stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.strict) 0 else 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, if (case.strict) 1 else 0), result.strict_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expect(result.contract == null);
    }
}

test "CHECK observes every admission kind after the measured recovery divergence" {
    const Kind = zts.parser.type_syntax.AdmissionKind;
    const cases = [_]struct { source: []const u8, kind: ?Kind, diagnostics: []const CompoundDiagnostic }{
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value: any = 1;\n", .kind = .any_type, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 14, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value = source as string;\n", .kind = .as_assertion, .diagnostics = &.{
            .{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 2, .column = 25, .suggestion = "use type-safe patterns instead" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value = source satisfies string;\n", .kind = .satisfies_assertion, .diagnostics = &.{
            .{ .code = "ZTS043", .message = "'satisfies' type assertion is not supported", .line = 2, .column = 32, .suggestion = "use type-safe patterns instead" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value = \"open\nconst after = 1;\n", .kind = .unterminated_string, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 2, .column = 20, .suggestion = "close the quote, or write the newline as \\n" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nnominal Box = T;\n", .kind = .nominal_base_not_scalar, .diagnostics = &.{
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 2, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\ninterface Box { value: string }\n", .kind = .interface_declaration, .diagnostics = &.{
            .{ .code = "ZTS049", .message = "`interface` is not a declaration form in this profile", .line = 2, .column = 1, .suggestion = "write `structural Name = { ... };`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\ntype Box = string;\n", .kind = .type_alias_declaration, .diagnostics = &.{
            .{ .code = "ZTS050", .message = "`type` is not a declaration form in this profile", .line = 2, .column = 1, .suggestion = "write `structural Name = ...;`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\ndistinct type Box = string;\n", .kind = .distinct_type_declaration, .diagnostics = &.{
            .{ .code = "ZTS051", .message = "`distinct type` is not a declaration form in this profile", .line = 2, .column = 1, .suggestion = "write `nominal Name = string;`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nimport type { Value } from 'zttp:types';\n", .kind = .retired_types_import, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 2, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(value = 1) { return value; }\n", .kind = .default_parameter, .diagnostics = &.{
            .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 2, .column = 18, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(value?: string) { return value; }\n", .kind = .optional_parameter, .diagnostics = &.{
            .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 2, .column = 17, .suggestion = "replace `name?: T` with `name: T | undefined`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nexport default 1;\n", .kind = .default_export, .diagnostics = &.{
            .{ .code = "ZTS056", .message = "default exports are not part of this profile", .line = 2, .column = 1, .suggestion = "write a named export, for example `export function handler(...) { ... }`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nexport let value = 1;\n", .kind = .mutable_export, .diagnostics = &.{
            .{ .code = "ZTS057", .message = "mutable exports are not part of this profile", .line = 2, .column = 1, .suggestion = "use `export const` for module values and keep reassignment inside a function activation" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = Array<string>;\n", .kind = .array_type_alias, .diagnostics = &.{
            .{ .code = "ZTS058", .message = "`Array<T>` is not a type spelling in this profile", .line = 2, .column = 18, .suggestion = "write `T[]`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = ReadonlyArray<string>;\n", .kind = .readonly_array_type_alias, .diagnostics = &.{
            .{ .code = "ZTS059", .message = "`ReadonlyArray<T>` is not a type spelling in this profile", .line = 2, .column = 18, .suggestion = "write `readonly T[]`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = void;\n", .kind = .void_type, .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 2, .column = 18, .suggestion = "write `undefined`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value: {{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{ string;\n", .kind = .nesting_too_deep, .diagnostics = &.{
            .{ .code = "ZTS044", .message = "type syntax nests too deeply", .line = 2, .column = 526, .suggestion = "simplify or split it (nesting limit is 512)" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\n/* unfinished\n", .kind = null, .diagnostics = &.{} },
    };
    try std.testing.expectEqual(@as(usize, 18), cases.len);
    try std.testing.expectEqual(@typeInfo(Kind).@"enum".field_names.len + 1, cases.len);
    var seen = std.EnumSet(Kind).empty;
    var location_free: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("recovery producer failed: {any}\n", .{case.kind});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| try expectCompoundDiagnostic(actual, expected);
        try std.testing.expect(result.contract == null);
        if (case.kind) |kind| {
            try std.testing.expect(!seen.contains(kind));
            try std.testing.expectEqual(@as(usize, 1), case.diagnostics.len);
            seen.insert(kind);
        } else {
            try std.testing.expectEqual(@as(usize, 0), case.diagnostics.len);
            location_free += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), location_free);
    inline for (std.meta.tags(Kind)) |kind| try std.testing.expect(seen.contains(kind));
}

test "CHECK preserves raw recovery header comments" {
    const cases = [_]struct { source: []const u8, parser_stage: bool, diagnostic: CompoundDiagnostic }{
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(/* x = 1 */) { return 1; }\n", .parser_stage = false, .diagnostic = .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 2, .column = 17, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(/* ) */) { return 1; }\n", .parser_stage = true, .diagnostic = .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 24, .suggestion = null } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(/* unfinished\n", .parser_stage = true, .diagnostic = .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 24, .suggestion = null } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(x: number, /* x = 1 */) { return 1; }\n", .parser_stage = false, .diagnostic = .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 2, .column = 28, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" } },
    };
    try std.testing.expectEqual(@as(usize, 4), cases.len);
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(if (case.parser_stage) StageSet.initMany(&.{ .strip, .parse }) else StageSet.initMany(&.{.strip}), result.stages_run);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expect(result.contract == null);
    }
}

// ---------------------------------------------------------------------------
// Termination claims over function values
//
// Each probe recurses without end through a function value: a returned value,
// a stored value, a callback, a holder, or a binding with no initializer. Every
// one of them passed `zts check` with `cost_bounded` proven, and the helper
// capsules proved `total`. The assertions name the claim itself, never a
// neighbouring property.
// ---------------------------------------------------------------------------

const TerminationProbe = struct {
    name: []const u8,
    source: []const u8,
    /// The probe has a helper that declares `Proof<T, "total">`, so the
    /// capsule must be refused.
    total_refused: bool,
};

fn hasFailingSpecTotal(result: *const CheckResult) bool {
    for (result.json_diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "failing spec: total") != null) return true;
    }
    return false;
}

fn terminationRefused(probe: TerminationProbe) !bool {
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, probe.source, "probe.ts", .{ .json_mode = true });
    defer result.deinit(std.testing.allocator);
    const props = result.properties orelse return error.MissingProperties;
    var refused = true;
    if (props.cost_bounded) {
        std.debug.print("termination probe {s}: cost_bounded was proven\n", .{probe.name});
        refused = false;
    }
    if (probe.total_refused and !hasFailingSpecTotal(&result)) {
        std.debug.print("termination probe {s}: total was not refused\n", .{probe.name});
        refused = false;
    }
    return refused;
}

fn expectTerminationKept(name: []const u8, source: []const u8) !void {
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "control.ts", .{ .json_mode = true });
    defer result.deinit(std.testing.allocator);
    const props = result.properties orelse return error.MissingProperties;
    if (!props.cost_bounded) {
        std.debug.print("termination control {s}: cost_bounded was refused\n", .{name});
        return error.CostBoundedRefused;
    }
    if (hasFailingSpecTotal(&result)) {
        std.debug.print("termination control {s}: total was refused\n", .{name});
        return error.TotalRefused;
    }
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
}

test "CHECK refuses termination claims when a function value recurses without end" {
    const probes = [_]TerminationProbe{
        // A returned or stored value.
        .{ .name = "p2g", .total_refused = true, .source =
        \\structural Fn = (n: number) => number;
        \\structural Ops = { a: Fn };
        \\function wrap(o: Ops): Ops {
        \\  return o;
        \\}
        \\function down(n: number): Proof<number, "total"> {
        \\  const o: Ops = { a: down };
        \\  return wrap(o).a(n);
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        .{ .name = "q1", .total_refused = true, .source =
        \\function down(n: number): Proof<number, "total"> {
        \\  return [down][0](n);
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        // A callback.
        .{ .name = "r1", .total_refused = true, .source =
        \\structural Fn = (n: number) => number;
        \\function apply(f: Fn, n: number): number {
        \\  return f(n);
        \\}
        \\function down(n: number): Proof<number, "total"> {
        \\  return apply(down, n);
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        .{ .name = "r4", .total_refused = true, .source =
        \\function down(n: number): Proof<number, "total"> {
        \\  return [n].map(down)[0] ?? n;
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        .{ .name = "r6", .total_refused = true, .source =
        \\structural Step = (n: number, self: Step) => number;
        \\function down(n: number, self: Step): Proof<number, "total"> {
        \\  return self(n, self);
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ v: down(3, down) });
        \\}
        },
        // A holder.
        .{ .name = "p2c", .total_refused = true, .source =
        \\structural Ops = { a: (n: number) => number };
        \\function down(n: number): Proof<number, "total"> {
        \\  const ops: Ops = { a: down };
        \\  return ops.a(n);
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        .{ .name = "f6", .total_refused = false, .source =
        \\structural Ops = { f: (n: number) => number };
        \\const g: Ops = { f: (x: number): number => g.f(x) };
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: g.f(3) });
        \\}
        },
        // A nested function that calls itself.
        .{ .name = "f1b", .total_refused = false, .source =
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  function g(x: number): number {
        \\    return g(x);
        \\  }
        \\  return Response.json({ v: g(3) });
        \\}
        },
        // Local or module state.
        .{ .name = "f3", .total_refused = false, .source =
        \\structural Fn = (n: number) => number;
        \\function inc(x: number): number {
        \\  return x + 1;
        \\}
        \\let cb: Fn = inc;
        \\function down(n: number): number {
        \\  return cb(n);
        \\}
        \\function arm(): number {
        \\  cb = down;
        \\  return 0;
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  const a = arm();
        \\  return Response.json({ v: down(3) + a });
        \\}
        },
        .{ .name = "fc1", .total_refused = true, .source =
        \\structural Fn = (n: number) => number;
        \\let slot: Fn = (n: number): number => n;
        \\function down(n: number): Proof<number, "total"> {
        \\  return slot(n);
        \\}
        \\function arm(n: number): number {
        \\  slot = down;
        \\  return n;
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: arm(1) + down(3) });
        \\}
        },
        .{ .name = "g1", .total_refused = true, .source =
        \\structural Fn = (n: number) => number;
        \\let slot: Fn = (n: number): number => n;
        \\function down(items: number[], n: number): Proof<number, "total"> {
        \\  return items.map(slot)[0] ?? n;
        \\}
        \\function arm(n: number): number {
        \\  slot = (x: number): number => down([x], x);
        \\  return n;
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: arm(1) + down([3], 3) });
        \\}
        },
        // Bindings with no initializer to read.
        .{ .name = "g2", .total_refused = false, .source =
        \\structural Ops = { f: (n: number) => number };
        \\function down(n: number): number {
        \\  return down(n);
        \\}
        \\function compute(): Ops {
        \\  return { f: down };
        \\}
        \\const cfg: Ops = compute();
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: cfg.f(3) });
        \\}
        },
        .{ .name = "g3b", .total_refused = true, .source =
        \\structural Fn = (n: number) => number;
        \\function down(n: number): Proof<number, "total"> {
        \\  const fs: Fn[] = [down];
        \\  for (const f of fs) {
        \\    return [1].map(f)[0] ?? n;
        \\  }
        \\  return n;
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        .{ .name = "g3c", .total_refused = true, .source =
        \\structural Fn = (n: number) => number;
        \\structural Ops = { a: Fn };
        \\function down(n: number): Proof<number, "total"> {
        \\  const o: Ops = { a: down };
        \\  return match (o) {
        \\    when { a: g }: [1].map(g)[0] ?? n
        \\    default: n
        \\  };
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        // A function value that is only the second argument of a builtin.
        .{ .name = "h4", .total_refused = true, .source =
        \\structural Fn = (n: number) => number;
        \\function down(n: number): Proof<number, "total"> {
        \\  const xs: number[] = [n];
        \\  return xs.reduce((acc: Fn, x: number): Fn => acc, down)(n);
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        // An inline arrow handed to a named helper.
        .{ .name = "p4", .total_refused = false, .source =
        \\structural Step = (g: Step) => number;
        \\function loop(f: Step): number {
        \\  return f(f);
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: loop((g: Step): number => loop(g)) });
        \\}
        },
        // A function declared in a body, handed to a builtin that calls it.
        .{ .name = "n1", .total_refused = true, .source =
        \\function down(n: number): Proof<number, "total"> {
        \\  function g(x: number): number {
        \\    const xs: number[] = [x];
        \\    return xs.map(g)[0] ?? x;
        \\  }
        \\  const seed: number[] = [n];
        \\  return seed.map(g)[0] ?? n;
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  return Response.json({ v: down(3) });
        \\}
        },
        // Direct self-recursion by name stays refused.
        .{ .name = "p2r", .total_refused = true, .source =
        \\function down(n: number): Proof<number, "total"> {
        \\  return down(n);
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ v: down(3) });
        \\}
        },
    };
    var failures: usize = 0;
    for (probes) |probe| {
        if (!try terminationRefused(probe)) failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "CHECK keeps termination claims when no function value escapes" {
    // Builtins that call a named, non-recursive callback.
    try expectTerminationKept("builtins",
        \\function fmt(x: number): string {
        \\  return String(x);
        \\}
        \\function norm(s: string): Proof<string, "total"> {
        \\  return s.trim().toLowerCase();
        \\}
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  const h = req.headers.get("x") ?? "";
        \\  const items: number[] = [1, 2, 3];
        \\  return Response.json({ a: norm(h), b: items.map(fmt) });
        \\}
    );
    // Inline callbacks to the zttp:result combinators.
    try expectTerminationKept("result-combinators",
        \\import { andThen, mapResult, ok, unwrapOr } from "zttp:result";
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  const doubled = mapResult(ok(21), (n) => n * 2);
        \\  const chained = andThen(doubled, (n) => ok(n + 1));
        \\  return Response.json({ v: unwrapOr(chained, 0) });
        \\}
    );
    // A routed handler: the table is the first argument of a stable routerMatch.
    try expectTerminationKept("routed",
        \\import { routerMatch } from "zttp:router";
        \\function getHealth(req: Request): Response {
        \\  return Response.text("ok");
        \\}
        \\const routes = { "GET /health": getHealth };
        \\function handler(req: Request): Proof<Response, "cost_bounded"> {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) {
        \\    return found.handler(req);
        \\  }
        \\  return Response.text("404");
        \\}
    );
}

test "CHECK extensionless imports use reader revisions in both traversals" {
    const allocator = std.testing.allocator;
    const source =
        \\import { value } from "./helper";
        \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
        \\  return Response.text(value());
        \\}
    ;
    const dependencies = [_][]const u8{
        "export function value(): string { return \"ok\"; }",
        "import { env } from \"zttp:env\"; export function value(): string { return env(\"API_SECRET\") ?? \"\"; }",
    };
    for (dependencies, 0..) |dependency, index| {
        var reader: TracingImportReader = .{ .sources = &.{ dependency, dependencies[0] } };
        defer reader.deinit(allocator);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "/virtual/no-disk/handler.ts", .{
            .json_mode = true,
            .import_reader = reader.reader(),
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(usize, 2), reader.paths.items.len);
        for (reader.paths.items) |path| try std.testing.expectEqualStrings("/virtual/no-disk/helper.ts", path);
        // The second, clean fault revision must not replace the flow revision.
        try std.testing.expectEqual(index == 0, result.contract.?.properties.?.no_secret_leakage);
        try std.testing.expectEqual(index != 0, hasDiagnosticCode(&result, "ZTS400"));
        try std.testing.expect(result.contract.?.properties.?.no_credential_leakage);
    }
}

test "CHECK mask declassifies only a literal bound of 4 or less on an unmodified source value (D-015)" {
    const allocator = std.testing.allocator;
    const header =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
        \\  const s = env("API_SECRET") ?? "";
        \\
    ;
    const bodies = [_]struct { body: []const u8, holds: bool }{
        .{ .body = "  return Response.text(mask(s, 4));\n}", .holds = true },
        .{ .body = "  return Response.text(mask(s, 5));\n}", .holds = false },
        .{ .body = "  return Response.text(mask(s.slice(0, 13), 4));\n}", .holds = false },
        .{
            .body = "  const a = mask(s.slice(0, s.length - 12), 4);\n" ++
                "  const b = mask(s.slice(0, s.length - 8), 4);\n" ++
                "  const c = mask(s.slice(0, s.length - 4), 4);\n" ++
                "  return Response.text([a, b, c, mask(s, 4)].join(\"\"));\n}",
            .holds = false,
        },
    };
    inline for (bodies) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, header ++ case.body, "/virtual/no-disk/handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(case.holds, result.contract.?.properties.?.no_secret_leakage);
        try std.testing.expectEqual(!case.holds, hasDiagnosticCode(&result, "ZTS400"));
    }
}

test "CHECK import path selection preserves explicit names and normalized cycle identity" {
    const allocator = std.testing.allocator;
    const spellings = [_][]const u8{ "./helper", "./helper.ts", "./nested/../helper" };
    for (spellings) |specifier| {
        const path = try resolveCheckImportPath(allocator, "/virtual", specifier);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("/virtual/helper.ts", path);
    }
    const explicit = try resolveCheckImportPath(allocator, "/virtual", "./helper.custom");
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("/virtual/helper.custom", explicit);
}

/// The behavioral verdict that `zts prove-behavior` reports for an edit.
fn proveBehaviorVerdict(
    allocator: std.mem.Allocator,
    before_src: []const u8,
    after_src: []const u8,
) !zts.contract_diff.Classification {
    var before = try runCheckOnlyFromSourceWithOptions(allocator, before_src, "handler.ts", .{ .json_mode = true });
    defer before.deinit(allocator);
    var after = try runCheckOnlyFromSourceWithOptions(allocator, after_src, "handler.ts", .{ .json_mode = true });
    defer after.deinit(allocator);
    const before_contract = before.contract orelse return error.NoContractFromBefore;
    const after_contract = after.contract orelse return error.NoContractFromAfter;
    var diff = try zts.contract_diff.diffContractsFromSources(allocator, &before_contract, &after_contract, before_src, after_src);
    defer diff.deinit(allocator);
    return diff.behavioralVerdict();
}

const io_nested_return_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  return Response.text(String(cacheSet("items", "k2", "v", 60)));
    \\}
;

const io_nested_return_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  return Response.text(String(true));
    \\}
;

const io_nested_const_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  const n = String(cacheSet("items", "k2", "v", 60));
    \\  return Response.text(n);
    \\}
;

const io_nested_const_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  const n = String(true);
    \\  return Response.text(n);
    \\}
;

const io_same_source =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  const a = req.url;
    \\  cacheSet("items", a, "v", 60);
    \\  return Response.text("ok");
    \\}
;

test "prove-behavior: a module call nested in a returned expression is breaking when removed" {
    const verdict = try proveBehaviorVerdict(std.testing.allocator, io_nested_return_a, io_nested_return_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, verdict);
}

test "prove-behavior: a module call nested in a const initializer is breaking when removed" {
    const verdict = try proveBehaviorVerdict(std.testing.allocator, io_nested_const_a, io_nested_const_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, verdict);
}

test "prove-behavior: a handler diffed with itself stays equivalent after nested calls are tracked" {
    const sources = [_][]const u8{ io_nested_return_a, io_nested_const_a, io_same_source };
    for (sources) |source| {
        const verdict = try proveBehaviorVerdict(std.testing.allocator, source, source);
        try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, verdict);
    }
}

test "prove-behavior: a module call in a ternary branch is breaking when removed" {
    // ZTS612 refuses an effectful arm, so the call is a pure module export.
    const before =
        \\import { slugify } from "zttp:text";
        \\export function handler(req: Request): Response {
        \\  const n = req.method === "GET" ? slugify(req.url) : "no";
        \\  return Response.text(n);
        \\}
    ;
    const after =
        \\import { slugify } from "zttp:text";
        \\export function handler(req: Request): Response {
        \\  const n = req.method === "GET" ? req.url : "no";
        \\  return Response.text(n);
        \\}
    ;
    const verdict = try proveBehaviorVerdict(std.testing.allocator, before, after);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, verdict);
}

test "prove-behavior: a module call in the right operand of ?? is breaking when removed" {
    const before =
        \\import { cacheGet, cacheSet } from "zttp:cache";
        \\export function handler(req: Request): Response {
        \\  const hit = cacheGet("items", "k");
        \\  const n = hit ?? String(cacheSet("items", "k", "v", 60));
        \\  return Response.text(n);
        \\}
    ;
    const after =
        \\import { cacheGet, cacheSet } from "zttp:cache";
        \\export function handler(req: Request): Response {
        \\  const hit = cacheGet("items", "k");
        \\  const n = hit ?? "none";
        \\  return Response.text(n);
        \\}
    ;
    const verdict = try proveBehaviorVerdict(std.testing.allocator, before, after);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, verdict);
}

test "prove-behavior: a module call in the right operand of && is breaking when removed" {
    const before =
        \\import { cacheSet } from "zttp:cache";
        \\export function handler(req: Request): Response {
        \\  cacheSet("items", "k", "v", 60);
        \\  const ok = req.method === "GET" && cacheSet("items", "k2", "v", 60);
        \\  return Response.text(String(ok));
        \\}
    ;
    const after =
        \\import { cacheSet } from "zttp:cache";
        \\export function handler(req: Request): Response {
        \\  cacheSet("items", "k", "v", 60);
        \\  const ok = req.method === "GET" && true;
        \\  return Response.text(String(ok));
        \\}
    ;
    const verdict = try proveBehaviorVerdict(std.testing.allocator, before, after);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, verdict);
}

const NestedCallPair = struct { name: []const u8, before: []const u8, after: []const u8 };

const io_if_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  if (String(cacheSet("items", "k2", "v", 60)) === req.url) {
    \\    return Response.text("yes");
    \\  }
    \\  return Response.text("no");
    \\}
;

const io_if_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  if (String(true) === req.url) {
    \\    return Response.text("yes");
    \\  }
    \\  return Response.text("no");
    \\}
;

const io_ife_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  if (req.method === "GET") {
    \\    return Response.text("yes");
    \\  } else if (String(cacheSet("items", "k2", "v", 60)) === req.url) {
    \\    return Response.text("maybe");
    \\  }
    \\  return Response.text("no");
    \\}
;

const io_ife_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  if (req.method === "GET") {
    \\    return Response.text("yes");
    \\  } else if (String(true) === req.url) {
    \\    return Response.text("maybe");
    \\  }
    \\  return Response.text("no");
    \\}
;

const io_ifn_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  if (String(cacheSet("items", "k2", "v", 60)) === req.url) {
    \\    cacheSet("items", "k3", "v", 60);
    \\  }
    \\  return Response.text("no");
    \\}
;

const io_ifn_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  if (String(true) === req.url) {
    \\    cacheSet("items", "k3", "v", 60);
    \\  }
    \\  return Response.text("no");
    \\}
;

const io_for_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  for (const x of [String(cacheSet("items", "k2", "v", 60))]) {
    \\    cacheSet("items", x, "v", 60);
    \\  }
    \\  return Response.text("ok");
    \\}
;

const io_for_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  for (const x of [String(true)]) {
    \\    cacheSet("items", x, "v", 60);
    \\  }
    \\  return Response.text("ok");
    \\}
;

const io_match_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  const out = match (String(cacheSet("items", "k2", "v", 60))) {
    \\    when "true": "yes"
    \\    default: "no"
    \\  };
    \\  return Response.text(out);
    \\}
;

const io_match_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  const out = match (String(true)) {
    \\    when "true": "yes"
    \\    default: "no"
    \\  };
    \\  return Response.text(out);
    \\}
;

const io_map_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  const xs = ["a", "b"];
    \\  const ys = xs.map((x) => String(cacheSet("items", x, "v", 60)));
    \\  return Response.text(ys.join(","));
    \\}
;

const io_map_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  const xs = ["a", "b"];
    \\  const ys = xs.map((x) => String(true));
    \\  return Response.text(ys.join(","));
    \\}
;

const io_each_a =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  const xs = ["a", "b"];
    \\  xs.forEach((x) => {
    \\    cacheSet("items", x, "v", 60);
    \\  });
    \\  return Response.text("ok");
    \\}
;

const io_each_b =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k", "v", 60);
    \\  const xs = ["a", "b"];
    \\  xs.forEach((x) => {
    \\    String(x);
    \\  });
    \\  return Response.text("ok");
    \\}
;

const nested_call_pairs = [_]NestedCallPair{
    .{ .name = "if condition, then-branch returns", .before = io_if_a, .after = io_if_b },
    .{ .name = "else-if condition", .before = io_ife_a, .after = io_ife_b },
    .{ .name = "if condition, fall-through", .before = io_ifn_a, .after = io_ifn_b },
    .{ .name = "for...of iterable", .before = io_for_a, .after = io_for_b },
    .{ .name = "match discriminant", .before = io_match_a, .after = io_match_b },
    .{ .name = "inline map callback", .before = io_map_a, .after = io_map_b },
    .{ .name = "inline forEach callback", .before = io_each_a, .after = io_each_b },
};

test "prove-behavior: a module call removed from a condition, iterable, discriminant, or inline callback is breaking" {
    for (nested_call_pairs) |pair| {
        errdefer std.debug.print("pair: {s}\n", .{pair.name});
        const verdict = try proveBehaviorVerdict(std.testing.allocator, pair.before, pair.after);
        try std.testing.expectEqual(zts.contract_diff.Classification.breaking, verdict);
    }
}

test "prove-behavior: a handler with a call in a condition, iterable, discriminant, or inline callback diffs equivalent with itself" {
    for (nested_call_pairs) |pair| {
        errdefer std.debug.print("pair: {s}\n", .{pair.name});
        const verdict = try proveBehaviorVerdict(std.testing.allocator, pair.before, pair.before);
        try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, verdict);
    }
}

const ProveBehaviorOutcome = struct {
    verdict: zts.contract_diff.Classification,
    laws_fired: usize,
};

/// Like `proveBehaviorVerdict`, and also counts the laws the diff used.
fn proveBehaviorOutcome(
    allocator: std.mem.Allocator,
    before_src: []const u8,
    after_src: []const u8,
) !ProveBehaviorOutcome {
    var before = try runCheckOnlyFromSourceWithOptions(allocator, before_src, "handler.ts", .{ .json_mode = true });
    defer before.deinit(allocator);
    var after = try runCheckOnlyFromSourceWithOptions(allocator, after_src, "handler.ts", .{ .json_mode = true });
    defer after.deinit(allocator);
    const before_contract = before.contract orelse return error.NoContractFromBefore;
    const after_contract = after.contract orelse return error.NoContractFromAfter;
    var diff = try zts.contract_diff.diffContractsFromSources(allocator, &before_contract, &after_contract, before_src, after_src);
    defer diff.deinit(allocator);
    return .{ .verdict = diff.behavioralVerdict(), .laws_fired = diff.laws_used.items.len };
}

const two_dynamic_writes =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  const a = req.url;
    \\  const b = req.method;
    \\  cacheSet("items", a, "v", 60);
    \\  cacheSet("items", b, "v", 60);
    \\  return Response.text("ok");
    \\}
;

const one_dynamic_write =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  const a = req.url;
    \\  const b = req.method;
    \\  cacheSet("items", a, "v", 60);
    \\  return Response.text("ok");
    \\}
;

const two_literal_writes =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k1", "v", 60);
    \\  cacheSet("items", "k2", "v", 60);
    \\  return Response.text("ok");
    \\}
;

const one_literal_write =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k1", "v", 60);
    \\  return Response.text("ok");
    \\}
;

const same_literal_twice =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "k1", "v", 60);
    \\  cacheSet("items", "k1", "v", 60);
    \\  return Response.text("ok");
    \\}
;

const same_pipe_literal_twice =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "a|b", "v", 60);
    \\  cacheSet("items", "a|b", "v", 60);
    \\  return Response.text("ok");
    \\}
;

const one_pipe_literal =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  cacheSet("items", "a|b", "v", 60);
    \\  return Response.text("ok");
    \\}
;

test "prove-behavior: dropping the second of two dynamic-key writes is breaking and fires no law" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, two_dynamic_writes, one_dynamic_write);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, outcome.verdict);
    try std.testing.expectEqual(@as(usize, 0), outcome.laws_fired);
}

test "prove-behavior: dropping the second of two different literal-key writes is breaking" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, two_literal_writes, one_literal_write);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, outcome.verdict);
}

test "prove-behavior: collapsing two identical literal-key writes stays equivalent modulo laws" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, same_literal_twice, one_literal_write);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent_modulo_laws, outcome.verdict);
    try std.testing.expectEqual(@as(usize, 1), outcome.laws_fired);
}

test "prove-behavior: a string literal that holds a pipe is unknown and does not collapse" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, same_pipe_literal_twice, one_pipe_literal);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, outcome.verdict);
    try std.testing.expectEqual(@as(usize, 0), outcome.laws_fired);
}

const one_dynamic_key_url =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  const a = req.url;
    \\  const b = req.method;
    \\  cacheSet("items", a, "v", 60);
    \\  return Response.text("ok");
    \\}
;

const one_dynamic_key_method =
    \\import { cacheSet } from "zttp:cache";
    \\export function handler(req: Request): Response {
    \\  const a = req.url;
    \\  const b = req.method;
    \\  cacheSet("items", b, "v", 60);
    \\  return Response.text("ok");
    \\}
;

const one_dynamic_key_url_reformatted =
    \\import { cacheSet } from "zttp:cache";
    \\// The key is the request url.
    \\export function handler(req: Request): Response {
    \\    const a = req.url;   // read the url
    \\
    \\    const b = req.method;
    \\    cacheSet( "items",  a, "v", 60 );
    \\    return Response.text( "ok" );
    \\}
;

test "prove-behavior: changing which dynamic value a call receives is breaking" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, one_dynamic_key_url, one_dynamic_key_method);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, outcome.verdict);
}

test "prove-behavior: a handler with a dynamic argument diffs equivalent with itself" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, one_dynamic_key_url, one_dynamic_key_url);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, outcome.verdict);
}

test "prove-behavior: a comment and whitespace edit to a dynamic-argument handler stays equivalent" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, one_dynamic_key_url, one_dynamic_key_url_reformatted);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, outcome.verdict);
}

test "diffContracts without sources reads a dynamic argument strictly" {
    // The contracts name both keys `?`. Without the proof of one program, a
    // handler is not equivalent to itself, and an edit never reads as safe.
    const allocator = std.testing.allocator;
    var before = try runCheckOnlyFromSourceWithOptions(allocator, one_dynamic_key_url, "handler.ts", .{ .json_mode = true });
    defer before.deinit(allocator);
    var after = try runCheckOnlyFromSourceWithOptions(allocator, one_dynamic_key_method, "handler.ts", .{ .json_mode = true });
    defer after.deinit(allocator);
    const before_contract = before.contract orelse return error.NoContractFromBefore;
    const after_contract = after.contract orelse return error.NoContractFromAfter;

    var strict_self = try zts.contract_diff.diffContracts(allocator, &before_contract, &before_contract);
    defer strict_self.deinit(allocator);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, strict_self.behavioralVerdict());

    var strict_edit = try zts.contract_diff.diffContracts(allocator, &before_contract, &after_contract);
    defer strict_edit.deinit(allocator);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, strict_edit.behavioralVerdict());
}

/// Answers every import read with one source, so the handler under test sees a
/// helper file without a disk.
const FixedImportReader = struct {
    source: []const u8,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const self: *FixedImportReader = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, self.source);
    }

    fn reader(self: *FixedImportReader) ImportReader {
        return .{ .context = self, .read = read };
    }
};

test "diffContractsFromSources keeps the strict reading when the handler imports a local file" {
    // The handler source is the same on both sides, so the syntax trees are
    // identical. The helper that computes the cache key is not: it reads the
    // url before and the method after. The contract names `key(req)` as `?` on
    // both sides, so only the strict reading refuses to call the edit a no-op.
    // The cost: the handler is `breaking` against itself.
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { cacheSet } from "zttp:cache";
        \\import { key } from "./helper.ts";
        \\export function handler(req: Request): Response {
        \\  cacheSet("items", key(req), "v", 60);
        \\  return Response.text("ok");
        \\}
    ;
    const helper_before = "export function key(req: Request): string { return req.url; }";
    const helper_after = "export function key(req: Request): string { return req.method; }";

    var before_reader: FixedImportReader = .{ .source = helper_before };
    var after_reader: FixedImportReader = .{ .source = helper_after };
    var before = try runCheckOnlyFromSourceWithOptions(allocator, handler_source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = before_reader.reader(),
    });
    defer before.deinit(allocator);
    var after = try runCheckOnlyFromSourceWithOptions(allocator, handler_source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = after_reader.reader(),
    });
    defer after.deinit(allocator);
    const before_contract = before.contract orelse return error.NoContractFromBefore;
    const after_contract = after.contract orelse return error.NoContractFromAfter;

    var diff = try zts.contract_diff.diffContractsFromSources(
        allocator,
        &before_contract,
        &after_contract,
        handler_source,
        handler_source,
    );
    defer diff.deinit(allocator);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, diff.behavioralVerdict());
}

const assert_error_a =
    \\export function handler(req: Request): Response {
    \\  const ok = req.method === "GET";
    \\  assert ok, Response.text("no");
    \\  return Response.text("ok");
    \\}
;

const assert_error_b =
    \\export function handler(req: Request): Response {
    \\  const ok = req.method === "GET";
    \\  assert ok, Response.text("changed", { status: 500 });
    \\  return Response.text("ok");
    \\}
;

const if_error_a =
    \\export function handler(req: Request): Response {
    \\  const ok = req.method === "GET";
    \\  if (!ok) {
    \\    return Response.text("no");
    \\  }
    \\  return Response.text("ok");
    \\}
;

const if_error_b =
    \\export function handler(req: Request): Response {
    \\  const ok = req.method === "GET";
    \\  if (!ok) {
    \\    return Response.text("changed", { status: 500 });
    \\  }
    \\  return Response.text("ok");
    \\}
;

test "prove-behavior: changing the status of an assert error response is breaking" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, assert_error_a, assert_error_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, outcome.verdict);
}

test "prove-behavior: changing the status of an if error response stays breaking" {
    const outcome = try proveBehaviorOutcome(std.testing.allocator, if_error_a, if_error_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, outcome.verdict);
}

test "prove-behavior: handlers with an assert diff equivalent with themselves" {
    const sources = [_][]const u8{ assert_error_a, assert_error_b, if_error_a };
    for (sources) |source| {
        const outcome = try proveBehaviorOutcome(std.testing.allocator, source, source);
        try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, outcome.verdict);
    }
}

test "prove-behavior: changing the status of an assert error response reports one changed response" {
    const allocator = std.testing.allocator;
    var before = try runCheckOnlyFromSourceWithOptions(allocator, assert_error_a, "handler.ts", .{ .json_mode = true });
    defer before.deinit(allocator);
    var after = try runCheckOnlyFromSourceWithOptions(allocator, assert_error_b, "handler.ts", .{ .json_mode = true });
    defer after.deinit(allocator);
    const before_contract = before.contract orelse return error.NoContractFromBefore;
    const after_contract = after.contract orelse return error.NoContractFromAfter;
    var diff = try zts.contract_diff.diffContractsFromSources(allocator, &before_contract, &after_contract, assert_error_a, assert_error_b);
    defer diff.deinit(allocator);
    const bd = diff.behavior_diff orelse return error.NoBehaviorDiff;
    try std.testing.expectEqual(@as(u32, 1), bd.response_changed);
}

const match_return_a =
    \\export function handler(req: Request): Response {
    \\  const m = req.method;
    \\  return match (m) {
    \\    when "GET": Response.text("get")
    \\    default: Response.text("other", { status: 405 })
    \\  };
    \\}
;

const match_return_added_arm =
    \\export function handler(req: Request): Response {
    \\  const m = req.method;
    \\  return match (m) {
    \\    when "GET": Response.text("get")
    \\    when "POST": Response.text("post", { status: 201 })
    \\    default: Response.text("other", { status: 405 })
    \\  };
    \\}
;

const match_return_changed_status =
    \\export function handler(req: Request): Response {
    \\  const m = req.method;
    \\  return match (m) {
    \\    when "GET": Response.text("get")
    \\    default: Response.text("other", { status: 500 })
    \\  };
    \\}
;

test "prove-behavior: adding an arm to a returned match is breaking with a path count counterexample" {
    const allocator = std.testing.allocator;
    var before = try runCheckOnlyFromSourceWithOptions(allocator, match_return_a, "handler.ts", .{ .json_mode = true });
    defer before.deinit(allocator);
    var after = try runCheckOnlyFromSourceWithOptions(allocator, match_return_added_arm, "handler.ts", .{ .json_mode = true });
    defer after.deinit(allocator);
    const before_contract = before.contract orelse return error.NoContractFromBefore;
    const after_contract = after.contract orelse return error.NoContractFromAfter;
    var diff = try zts.contract_diff.diffContractsFromSources(allocator, &before_contract, &after_contract, match_return_a, match_return_added_arm);
    defer diff.deinit(allocator);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, diff.behavioralVerdict());
    try std.testing.expectEqualStrings("behavior path count differs", diff.canonical_counterexample orelse return error.NoCounterexample);
}

test "prove-behavior: changing the status of a returned match arm reports one changed response" {
    const allocator = std.testing.allocator;
    var before = try runCheckOnlyFromSourceWithOptions(allocator, match_return_a, "handler.ts", .{ .json_mode = true });
    defer before.deinit(allocator);
    var after = try runCheckOnlyFromSourceWithOptions(allocator, match_return_changed_status, "handler.ts", .{ .json_mode = true });
    defer after.deinit(allocator);
    const before_contract = before.contract orelse return error.NoContractFromBefore;
    const after_contract = after.contract orelse return error.NoContractFromAfter;
    var diff = try zts.contract_diff.diffContractsFromSources(allocator, &before_contract, &after_contract, match_return_a, match_return_changed_status);
    defer diff.deinit(allocator);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, diff.behavioralVerdict());
    const bd = diff.behavior_diff orelse return error.NoBehaviorDiff;
    try std.testing.expectEqual(@as(u32, 1), bd.response_changed);
}

test "prove-behavior: handlers that return a match diff equivalent with themselves" {
    const sources = [_][]const u8{ match_return_a, match_return_added_arm, match_return_changed_status };
    for (sources) |source| {
        const outcome = try proveBehaviorOutcome(std.testing.allocator, source, source);
        try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, outcome.verdict);
    }
}

// P1: a returned value whose status the generator cannot read is `unknown`,
// and `unknown` never equals a known status in the behavior diff.

const ProveCounts = struct {
    verdict: zts.contract_diff.Classification,
    preserved: u32,
    response_changed: u32,
    removed: u32,
    added: u32,
};

fn proveBehaviorCounts(
    allocator: std.mem.Allocator,
    before_src: []const u8,
    after_src: []const u8,
) !ProveCounts {
    return proveBehaviorCountsRead(allocator, before_src, after_src, null);
}

fn proveBehaviorCountsRead(
    allocator: std.mem.Allocator,
    before_src: []const u8,
    after_src: []const u8,
    import_reader: ?ImportReader,
) !ProveCounts {
    var before = try runCheckOnlyFromSourceWithOptions(allocator, before_src, "handler.ts", .{ .json_mode = true, .import_reader = import_reader });
    defer before.deinit(allocator);
    var after = try runCheckOnlyFromSourceWithOptions(allocator, after_src, "handler.ts", .{ .json_mode = true, .import_reader = import_reader });
    defer after.deinit(allocator);
    const before_contract = before.contract orelse return error.NoContractFromBefore;
    const after_contract = after.contract orelse return error.NoContractFromAfter;
    var diff = try zts.contract_diff.diffContractsFromSources(allocator, &before_contract, &after_contract, before_src, after_src);
    defer diff.deinit(allocator);
    const bd = diff.behavior_diff orelse return error.NoBehaviorDiff;
    return .{
        .verdict = diff.behavioralVerdict(),
        .preserved = bd.preserved,
        .response_changed = bd.response_changed,
        .removed = bd.removed,
        .added = bd.added,
    };
}

const p1_helper_a =
    \\function status(): number { return 200; }
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const s = status();
    \\  return Response.json({ a: 1 }, { status: s });
    \\}
;

const p1_helper_b =
    \\function status(): number { return 404; }
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const s = status();
    \\  return Response.json({ a: 1 }, { status: s });
    \\}
;

const p1_computed_a =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const s = 200 + 0;
    \\  return Response.json({ a: 1 }, { status: s });
    \\}
;

const p1_computed_b =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const s = 404 + 0;
    \\  return Response.json({ a: 1 }, { status: s });
    \\}
;

const p1_ternary_a =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const s = req.method === "GET" ? 200 : 404;
    \\  return Response.json({ a: 1 }, { status: s });
    \\}
;

const p1_ternary_b =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const s = req.method === "POST" ? 200 : 404;
    \\  return Response.json({ a: 1 }, { status: s });
    \\}
;

const p1_raw_a =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.rawJson("{}", { status: 200 });
    \\}
;

const p1_raw_b =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.rawJson("{}", { status: 404 });
    \\}
;

const p1_redirect_default =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.redirect("/x");
    \\}
;

const p1_redirect_301 =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.redirect("/x", 301);
    \\}
;

const p1_json_default =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.json({ a: 1 });
    \\}
;

const p1_range_200 =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.json({ a: 1 }, { status: 200 });
    \\}
;

const p1_range_700 =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.json({ a: 1 }, { status: 700 });
    \\}
;

const p1_retvoid_a =
    \\function handler(req: Request): Response {
    \\  return Response.json({ ok: true });
    \\}
;

const p1_retvoid_b =
    \\function handler(req: Request): Response {
    \\  return;
    \\}
;

const p1_literal_404 =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.json({ a: 1 }, { status: 404 });
    \\}
;

test "prove-behavior: a status from a helper call that changes is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, p1_helper_a, p1_helper_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
    try std.testing.expectEqual(@as(u32, 0), counts.preserved);
}

test "prove-behavior: a computed status that changes is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, p1_computed_a, p1_computed_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: a status chosen by a ternary is breaking when the condition changes" {
    const counts = try proveBehaviorCounts(std.testing.allocator, p1_ternary_a, p1_ternary_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: a literal rawJson status change is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, p1_raw_a, p1_raw_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: a redirect status change is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, p1_redirect_default, p1_redirect_301);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: a redirect against a 200 response is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, p1_redirect_default, p1_json_default);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: an out-of-range literal status runs as 500 and is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, p1_range_200, p1_range_700);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: a bare return runs as 500 and differs from a response" {
    const counts = try proveBehaviorCounts(std.testing.allocator, p1_retvoid_a, p1_retvoid_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: a literal 500 and an out-of-range literal are equal statuses" {
    const counts = try proveBehaviorCounts(
        std.testing.allocator,
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ a: 1 }, { status: 500 });
        \\}
    ,
        p1_range_700,
    );
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.preserved);
}

test "prove-behavior: P1 controls keep their verdicts" {
    const allocator = std.testing.allocator;
    const literal = try proveBehaviorCounts(allocator, p1_range_200, p1_literal_404);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, literal.verdict);
    try std.testing.expectEqual(@as(u32, 1), literal.response_changed);
    const literal_self = try proveBehaviorCounts(allocator, p1_range_200, p1_range_200);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, literal_self.verdict);
    const unknown_self = try proveBehaviorCounts(allocator, p1_helper_a, p1_helper_a);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, unknown_self.verdict);
    const unknown_comment = try proveBehaviorCounts(allocator, p1_helper_a, p1_helper_a ++ "\n// a comment\n");
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, unknown_comment.verdict);
    const redirect_self = try proveBehaviorCounts(allocator, p1_redirect_default, p1_redirect_default);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, redirect_self.verdict);
}

test "prove-behavior: an unknown status with a local import is breaking against itself" {
    const source = "import { x } from \"./lib.ts\";\n" ++ p1_helper_a;
    var lib: FixedImportReader = .{ .source = "export function x(): number { return 1; }\n" };
    const counts = try proveBehaviorCountsRead(std.testing.allocator, source, source, lib.reader());
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: a local import that cannot be read leaves no contract to diff" {
    const allocator = std.testing.allocator;
    const source = "import { x } from \"./missing.ts\";\n" ++ p1_helper_a;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "/virtual/handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(u32, 1), result.link_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS063", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("/virtual/handler.ts", result.json_diagnostics.items[0].file);
}

test "contract: the status of a returned value follows the runtime rules" {
    const K = zts.handler_contract.ResponseStatus;
    const pre = "function handler(req: Request): Response {\n";
    const cases = [_]struct { body: []const u8, expected: K }{
        .{ .body = "  return Response.json({ a: 1 });\n}", .expected = .{ .known = 200 } },
        .{ .body = "  return Response.text(\"x\", { status: 404 });\n}", .expected = .{ .known = 404 } },
        .{ .body = "  return Response.html(\"x\", { status: 201 });\n}", .expected = .{ .known = 201 } },
        .{ .body = "  return Response.rawJson(\"{}\");\n}", .expected = .{ .known = 200 } },
        .{ .body = "  return Response.rawJson(\"{}\", { status: 404 });\n}", .expected = .{ .known = 404 } },
        .{ .body = "  return Response.redirect(\"/x\");\n}", .expected = .{ .known = 302 } },
        .{ .body = "  return Response.redirect(\"/x\", 301);\n}", .expected = .{ .known = 301 } },
        .{ .body = "  return Response.redirect(\"/x\", 99);\n}", .expected = .{ .known = 500 } },
        .{ .body = "  const s = 301;\n  return Response.redirect(\"/x\", s);\n}", .expected = .unknown },
        .{ .body = "  return Response.json({ a: 1 }, { status: 99 });\n}", .expected = .{ .known = 500 } },
        .{ .body = "  return Response.json({ a: 1 }, { status: 600 });\n}", .expected = .{ .known = 500 } },
        .{ .body = "  return Response.json({ a: 1 }, { status: 0 });\n}", .expected = .{ .known = 500 } },
        .{ .body = "  return Response.json({ a: 1 }, { status: 100 });\n}", .expected = .{ .known = 100 } },
        .{ .body = "  return Response.json({ a: 1 }, { status: 599 });\n}", .expected = .{ .known = 599 } },
        .{ .body = "  const s = 404;\n  return Response.json({ a: 1 }, { status: s });\n}", .expected = .unknown },
        .{ .body = "  const o = { status: 404 };\n  return Response.json({ a: 1 }, o);\n}", .expected = .unknown },
        .{ .body = "  const b = { status: 404 };\n  return Response.json({ a: 1 }, { ...b });\n}", .expected = .unknown },
        .{ .body = "  const b = { status: 404 };\n  return Response.json({ a: 1 }, { ...b, status: 201 });\n}", .expected = .{ .known = 201 } },
        .{ .body = "  const r = Response.json({ a: 1 }, { status: 404 });\n  return r;\n}", .expected = .unknown },
        .{ .body = "  return;\n}", .expected = .{ .known = 500 } },
    };
    for (cases) |case| {
        const allocator = std.testing.allocator;
        const source = try std.mem.concat(allocator, u8, &.{ pre, case.body });
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        const contract = result.contract orelse return error.NoContract;
        try std.testing.expectEqual(@as(usize, 1), contract.behaviors.items.len);
        try std.testing.expectEqual(case.expected, contract.behaviors.items[0].response_status);
    }
}

test "contract: an unknown status is written as null" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, p1_helper_a, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const contract = result.contract orelse return error.NoContract;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try zts.handler_contract.writeContractJson(&contract, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"status\": null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"status\": 200,") == null);
}

test "diff: a strict self-diff of an unknown status is breaking and a same-program diff is equivalent" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, p1_helper_a, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const contract = result.contract orelse return error.NoContract;

    var strict = try zts.contract_diff.diffContracts(allocator, &contract, &contract);
    defer strict.deinit(allocator);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, strict.behavioralVerdict());
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, strict.classify());

    var same = try zts.contract_diff.diffContractsFromSources(allocator, &contract, &contract, p1_helper_a, p1_helper_a);
    defer same.deinit(allocator);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, same.behavioralVerdict());
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, same.classify());
}

test "gen-tests: the expect line of an unknown status holds no status key" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = p1_helper_b });
    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
    defer allocator.free(handler_path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const count = try @import("precompile_gen_tests.zig").runGenTests(allocator, handler_path, &out.writer);
    try std.testing.expectEqual(@as(u32, 1), count);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    _ = lines.next();
    _ = lines.next();
    try std.testing.expectEqualStrings("{\"type\":\"expect\"}", lines.next() orelse return error.NoThirdLine);
}

// 4a and 4d: the arms of a `match` carry the request constraints of the
// equal `if` chain, and a `match` bound to a name forks at its declaration.

const arm_methods_a =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    when "POST": Response.json({ a: 2 }, { status: 201 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\}
;

const arm_methods_put =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    when "PUT": Response.json({ a: 2 }, { status: 201 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\}
;

const arm_methods_reordered =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return match (req.method) {
    \\    when "POST": Response.json({ a: 2 }, { status: 201 })
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\}
;

const arm_method_only =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\}
;

const arm_url_only =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return match (req.url) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\}
;

const arm_header_echo =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const k = req.headers.get("x-kind") ?? "";
    \\  return match (k) {
    \\    when "echo": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 2 }, { status: 404 })
    \\  };
    \\}
;

const arm_header_other =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const k = req.headers.get("x-kind") ?? "";
    \\  return match (k) {
    \\    when "other": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 2 }, { status: 404 })
    \\  };
    \\}
;

const arm_record_health =
    \\function handler(req: Request): Response {
    \\  return match (req) {
    \\    when { method: "GET", path: "/health" }: Response.json({ ok: true })
    \\    when { method: "GET", path: "/version" }:
    \\      Response.json({ version: "1.0.0" })
    \\    when { method: "POST", path: "/echo" }: Response.json(req.body)
    \\    default: Response.text("Not Found", { status: 404 })
    \\  };
    \\}
;

const arm_record_healthz =
    \\function handler(req: Request): Response {
    \\  return match (req) {
    \\    when { method: "GET", path: "/healthz" }: Response.json({ ok: true })
    \\    when { method: "GET", path: "/version" }:
    \\      Response.json({ version: "1.0.0" })
    \\    when { method: "POST", path: "/echo" }: Response.json(req.body)
    \\    default: Response.text("Not Found", { status: 404 })
    \\  };
    \\}
;

const bound_methods_a =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    when "POST": Response.json({ a: 2 }, { status: 201 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\  return r;
    \\}
;

const bound_methods_status =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    when "POST": Response.json({ a: 2 }, { status: 202 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\  return r;
    \\}
;

const bound_methods_put =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    when "PUT": Response.json({ a: 2 }, { status: 201 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\  return r;
    \\}
;

const bound_status_get_200 =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const s = match (req.method) {
    \\    when "GET": 200
    \\    default: 200
    \\  };
    \\  return Response.json({ a: 1 }, { status: s });
    \\}
;

const bound_status_get_404 =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const s = match (req.method) {
    \\    when "GET": 200
    \\    default: 404
    \\  };
    \\  return Response.json({ a: 1 }, { status: s });
    \\}
;

const bound_call_in_get =
    \\import { sha256 } from "zttp:crypto";
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.text(sha256("a"))
    \\    default: Response.text("none")
    \\  };
    \\  return r;
    \\}
;

const bound_call_in_default =
    \\import { sha256 } from "zttp:crypto";
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.text("none")
    \\    default: Response.text(sha256("a"))
    \\  };
    \\  return r;
    \\}
;

const bound_never_returned_a =
    \\import { sha256 } from "zttp:crypto";
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const unused = match (req.method) {
    \\    when "GET": Response.text(sha256("a"))
    \\    default: Response.text("none")
    \\  };
    \\  return Response.text("ok");
    \\}
;

const bound_never_returned_b =
    \\import { sha256 } from "zttp:crypto";
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const unused = match (req.method) {
    \\    when "GET": Response.text("none")
    \\    default: Response.text(sha256("a"))
    \\  };
    \\  return Response.text("ok");
    \\}
;

const bound_property_written =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\  r.status = 500;
    \\  return r;
    \\}
;

const bound_let_reassigned =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  let r = match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\  r = Response.text("x", { status: 500 });
    \\  return r;
    \\}
;

const bound_written_in_closure_returned =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\  const fix = (): number => {
    \\    r.status = 500;
    \\    return 1;
    \\  };
    \\  const n = fix();
    \\  return r;
    \\}
;

const bound_written_through_alias =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\  const q = r;
    \\  q.status = 500;
    \\  return r;
    \\}
;

const bound_passed_to_helper =
    \\function setStatus(res: Response): number {
    \\  res.status = 500;
    \\  return 1;
    \\}
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = match (req.method) {
    \\    when "GET": Response.json({ a: 1 }, { status: 200 })
    \\    default: Response.json({ a: 3 }, { status: 404 })
    \\  };
    \\  const n = setStatus(r);
    \\  return r;
    \\}
;

const bound_pure_arms =
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const label = match (req.method) {
    \\    when "GET": "read"
    \\    default: "other"
    \\  };
    \\  return Response.json({ label: label });
    \\}
;

fn expectStatuses(
    source: []const u8,
    expected: []const zts.handler_contract.ResponseStatus,
) !void {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const contract = result.contract orelse return error.NoContract;
    try std.testing.expectEqual(expected.len, contract.behaviors.items.len);
    for (expected, contract.behaviors.items) |status, behavior| {
        try std.testing.expectEqual(status, behavior.response_status);
    }
}

test "prove-behavior: a changed arm pattern with the same status is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, arm_methods_a, arm_methods_put);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    // The default path keeps no condition, and its request is the first method
    // that the negations leave: PUT before, POST after. Its key moves too.
    try std.testing.expectEqual(@as(u32, 1), counts.preserved);
    try std.testing.expectEqual(@as(u32, 2), counts.removed);
    try std.testing.expectEqual(@as(u32, 2), counts.added);
}

test "prove-behavior: a changed match discriminant is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, arm_method_only, arm_url_only);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
}

test "prove-behavior: a changed record arm pattern on the request is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, arm_record_health, arm_record_healthz);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 5), counts.preserved);
    try std.testing.expectEqual(@as(u32, 1), counts.removed);
    try std.testing.expectEqual(@as(u32, 1), counts.added);
}

test "prove-behavior: match arm controls keep their verdicts" {
    const allocator = std.testing.allocator;
    const reordered = try proveBehaviorCounts(allocator, arm_methods_a, arm_methods_reordered);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, reordered.verdict);
    const header = try proveBehaviorCounts(allocator, arm_header_echo, arm_header_other);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, header.verdict);
    const self = try proveBehaviorCounts(allocator, arm_methods_a, arm_methods_a);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, self.verdict);
    try std.testing.expectEqual(@as(u32, 3), self.preserved);
}

test "contract: a routing match has the paths of the equal if chain" {
    const K = zts.handler_contract.ResponseStatus;
    try expectStatuses(arm_record_health, &[_]K{
        .{ .known = 200 },
        .{ .known = 200 },
        .{ .known = 404 },
        .{ .known = 404 },
        .{ .known = 200 },
        .{ .known = 404 },
    });
}

test "gen-tests: match arms emit the request each arm needs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = arm_methods_a });
    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
    defer allocator.free(handler_path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const count = try @import("precompile_gen_tests.zig").runGenTests(allocator, handler_path, &out.writer);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqualStrings(
        \\{"type":"test","name":"path 1 GET"}
        \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":200}
        \\{"type":"test","name":"path 2 !GET POST"}
        \\{"type":"request","method":"POST","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":201}
        \\{"type":"test","name":"path 3 !GET !POST"}
        \\{"type":"request","method":"PUT","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":404}
        \\
    , out.written());
}

test "contract: a bound match that is returned forks one path per arm" {
    const K = zts.handler_contract.ResponseStatus;
    try expectStatuses(bound_methods_a, &[_]K{ .{ .known = 200 }, .{ .known = 201 }, .{ .known = 404 } });
}

test "prove-behavior: a changed arm status of a bound match is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, bound_methods_a, bound_methods_status);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 2), counts.preserved);
    try std.testing.expectEqual(@as(u32, 1), counts.response_changed);
}

test "prove-behavior: a changed arm pattern of a bound match is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, bound_methods_a, bound_methods_put);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
    try std.testing.expectEqual(@as(u32, 1), counts.preserved);
    try std.testing.expectEqual(@as(u32, 2), counts.removed);
    try std.testing.expectEqual(@as(u32, 2), counts.added);
}

test "prove-behavior: a status chosen by a bound match is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, bound_status_get_200, bound_status_get_404);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
}

test "prove-behavior: a module call that moves between arms of a bound match is breaking" {
    const counts = try proveBehaviorCounts(std.testing.allocator, bound_call_in_get, bound_call_in_default);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
}

test "prove-behavior: a bound match that is never returned still forks its module calls" {
    const counts = try proveBehaviorCounts(std.testing.allocator, bound_never_returned_a, bound_never_returned_b);
    try std.testing.expectEqual(zts.contract_diff.Classification.breaking, counts.verdict);
}

test "contract: a bound match whose name is written or reassigned has an unknown status" {
    const K = zts.handler_contract.ResponseStatus;
    try expectStatuses(bound_property_written, &[_]K{ .unknown, .unknown });
    try expectStatuses(bound_let_reassigned, &[_]K{ .unknown, .unknown });
    // A closure writes `r` through an upvalue, whose binding key differs from
    // the declaration's; the write still blocks resolution.
    try expectStatuses(bound_written_in_closure_returned, &[_]K{ .unknown, .unknown });
    // An alias or a helper argument shares the object, so a write through it
    // changes the value of `r`.
    try expectStatuses(bound_written_through_alias, &[_]K{ .unknown, .unknown });
    try expectStatuses(bound_passed_to_helper, &[_]K{ .unknown, .unknown });
}

test "contract: a bound match with only pure arms does not fork" {
    const K = zts.handler_contract.ResponseStatus;
    try expectStatuses(bound_pure_arms, &[_]K{.{ .known = 200 }});
}

test "prove-behavior: bound match controls keep their verdicts" {
    const counts = try proveBehaviorCounts(std.testing.allocator, bound_methods_a, bound_methods_a);
    try std.testing.expectEqual(zts.contract_diff.Classification.equivalent, counts.verdict);
    try std.testing.expectEqual(@as(u32, 3), counts.preserved);
}

// 3a and Decision 29: a module call that a same-file function makes, or that
// sits in an `if` branch that does not return, is on the path.

const imp_cache = "import { cacheGet, cacheSet } from \"zttp:cache\";\n";

const named_closure_a = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const load = (): string | undefined => cacheGet("ns", "one");
    \\  const x = load();
    \\  return Response.json({ ok: true });
    \\}
;
const named_closure_b = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const load = (): string | undefined => cacheGet("ns", "two");
    \\  const x = load();
    \\  return Response.json({ ok: true });
    \\}
;
const top_one = imp_cache ++
    \\function load(): string | undefined { return cacheGet("ns", "one"); }
    \\function handler(req: Request): Response {
    \\  const x = load();
    \\  return Response.json({ ok: true });
    \\}
;
const top_two = imp_cache ++
    \\function load(): string | undefined { return cacheGet("ns", "two"); }
    \\function handler(req: Request): Response {
    \\  const x = load();
    \\  return Response.json({ ok: true });
    \\}
;
const nested_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  function load(): string | undefined { return cacheGet("ns", "one"); }
    \\  const x = load();
    \\  return Response.json({ ok: true });
    \\}
;
const nested_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  function load(): string | undefined { return cacheGet("ns", "two"); }
    \\  const x = load();
    \\  return Response.json({ ok: true });
    \\}
;
const byname_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const load = (k: string): string | undefined => cacheGet("ns", "one");
    \\  const xs = ["a"].map(load);
    \\  return Response.json({ ok: true });
    \\}
;
const byname_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const load = (k: string): string | undefined => cacheGet("ns", "two");
    \\  const xs = ["a"].map(load);
    \\  return Response.json({ ok: true });
    \\}
;
const uncalled_one = imp_cache ++
    \\function load(): string | undefined { return cacheGet("ns", "one"); }
    \\function handler(req: Request): Response {
    \\  return Response.json({ ok: true });
    \\}
;
const uncalled_two = imp_cache ++
    \\function load(): string | undefined { return cacheGet("ns", "two"); }
    \\function handler(req: Request): Response {
    \\  return Response.json({ ok: true });
    \\}
;
const direct_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const x = cacheGet("ns", "one");
    \\  return Response.json({ ok: true });
    \\}
;
const direct_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const x = cacheGet("ns", "two");
    \\  return Response.json({ ok: true });
    \\}
;
const letfn_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  let g = (): string | undefined => cacheGet("ns", "one");
    \\  g = (): string | undefined => cacheGet("ns", "z");
    \\  const x = g();
    \\  return Response.json({ ok: true });
    \\}
;
const letfn_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  let g = (): string | undefined => cacheGet("ns", "two");
    \\  g = (): string | undefined => cacheGet("ns", "z");
    \\  const x = g();
    \\  return Response.json({ ok: true });
    \\}
;
const alias_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const g = (): string | undefined => cacheGet("ns", "one");
    \\  const h = g;
    \\  const x = h();
    \\  return Response.json({ ok: true });
    \\}
;
const alias_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const g = (): string | undefined => cacheGet("ns", "two");
    \\  const h = g;
    \\  const x = h();
    \\  return Response.json({ ok: true });
    \\}
;
const upvalue_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const load = (): string | undefined => cacheGet("ns", "one");
    \\  const xs = ["a"].map((k: string): string | undefined => load());
    \\  return Response.json({ ok: true });
    \\}
;
const upvalue_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const load = (): string | undefined => cacheGet("ns", "two");
    \\  const xs = ["a"].map((k: string): string | undefined => load());
    \\  return Response.json({ ok: true });
    \\}
;
const chain_one = imp_cache ++
    \\function inner(): string | undefined { return cacheGet("ns", "one"); }
    \\function outer(): string | undefined { return inner(); }
    \\function handler(req: Request): Response {
    \\  const x = outer();
    \\  return Response.json({ ok: true });
    \\}
;
const chain_two = imp_cache ++
    \\function inner(): string | undefined { return cacheGet("ns", "two"); }
    \\function outer(): string | undefined { return inner(); }
    \\function handler(req: Request): Response {
    \\  const x = outer();
    \\  return Response.json({ ok: true });
    \\}
;
const recursive_one = imp_cache ++
    \\function spin(n: number): number {
    \\  cacheSet("ns", "one", "v");
    \\  return spin(n);
    \\}
    \\function handler(req: Request): Response {
    \\  const x = spin(1);
    \\  return Response.json({ ok: true });
    \\}
;
const recursive_two = imp_cache ++
    \\function spin(n: number): number {
    \\  cacheSet("ns", "two", "v");
    \\  return spin(n);
    \\}
    \\function handler(req: Request): Response {
    \\  const x = spin(1);
    \\  return Response.json({ ok: true });
    \\}
;
const ifcall_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "POST") {
    \\    cacheSet("ns", "one", "v");
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const ifcall_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "POST") {
    \\    cacheSet("ns", "two", "v");
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const ifelse_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "GET") {
    \\    cacheSet("ns", "x", "v");
    \\  } else {
    \\    cacheSet("ns", "one", "v");
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const ifelse_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "GET") {
    \\    cacheSet("ns", "x", "v");
    \\  } else {
    \\    cacheSet("ns", "two", "v");
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const ifnested_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "POST") {
    \\    if (req.url === "/x") {
    \\      cacheSet("ns", "one", "v");
    \\    }
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const ifnested_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "POST") {
    \\    if (req.url === "/x") {
    \\      cacheSet("ns", "two", "v");
    \\    }
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const ifhelper_one = imp_cache ++
    \\function save(): string | undefined { return cacheGet("ns", "one"); }
    \\function handler(req: Request): Response {
    \\  if (req.method === "POST") {
    \\    save();
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const ifhelper_two = imp_cache ++
    \\function save(): string | undefined { return cacheGet("ns", "two"); }
    \\function handler(req: Request): Response {
    \\  if (req.method === "POST") {
    \\    save();
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const ifreturn_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "POST") {
    \\    cacheSet("ns", "one", "v");
    \\    return Response.json({ ok: true });
    \\  }
    \\  return Response.json({ ok: false });
    \\}
;
const ifreturn_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "POST") {
    \\    cacheSet("ns", "two", "v");
    \\    return Response.json({ ok: true });
    \\  }
    \\  return Response.json({ ok: false });
    \\}
;

fn expectVerdict(
    expected: zts.contract_diff.Classification,
    before_src: []const u8,
    after_src: []const u8,
) !void {
    try std.testing.expectEqual(expected, try proveBehaviorVerdict(std.testing.allocator, before_src, after_src));
}

test "prove-behavior: a module call in a named closure is on the path" {
    try expectVerdict(.breaking, named_closure_a, named_closure_b);
}

test "prove-behavior: a module call in a module-level helper is on the path" {
    try expectVerdict(.breaking, top_one, top_two);
}

test "prove-behavior: a module call in a nested function declaration is on the path" {
    try expectVerdict(.breaking, nested_one, nested_two);
}

test "prove-behavior: a closure passed by name records its call" {
    try expectVerdict(.breaking, byname_one, byname_two);
}

test "prove-behavior: a closure called from inside an inline callback is on the path" {
    try expectVerdict(.breaking, upvalue_one, upvalue_two);
}

test "prove-behavior: a helper that calls a helper is on the path" {
    try expectVerdict(.breaking, chain_one, chain_two);
}

test "prove-behavior: a recursive helper is expanded once and ends" {
    try expectVerdict(.breaking, recursive_one, recursive_two);
}

test "prove-behavior: helper expansion controls keep their verdicts" {
    try expectVerdict(.equivalent, uncalled_one, uncalled_two);
    try expectVerdict(.breaking, direct_one, direct_two);
    try expectVerdict(.equivalent, top_one, top_one);
}

test "prove-behavior: a closure bound with let or reached through an alias is not expanded" {
    try expectVerdict(.equivalent, letfn_one, letfn_two);
    try expectVerdict(.equivalent, alias_one, alias_two);
}

test "prove-behavior: a module call in an if branch that does not return is on the path" {
    try expectVerdict(.breaking, ifcall_one, ifcall_two);
}

test "prove-behavior: a module call in an else branch that does not return is on the path" {
    try expectVerdict(.breaking, ifelse_one, ifelse_two);
}

test "prove-behavior: a module call in a nested if branch that does not return is on the path" {
    try expectVerdict(.breaking, ifnested_one, ifnested_two);
}

test "prove-behavior: a helper called in an if branch that does not return keeps its calls" {
    try expectVerdict(.breaking, ifhelper_one, ifhelper_two);
}

const loop_if_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const items = ["x", "y"];
    \\  for (const item of items) {
    \\    if (req.method === "POST") {
    \\      cacheSet("ns", "one", item);
    \\    }
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;
const loop_if_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  const items = ["x", "y"];
    \\  for (const item of items) {
    \\    if (req.method === "POST") {
    \\      cacheSet("ns", "two", item);
    \\    }
    \\  }
    \\  return Response.json({ ok: true });
    \\}
;

test "prove-behavior: a module call in an if branch inside a loop body is on the path" {
    try expectVerdict(.breaking, loop_if_one, loop_if_two);
    try expectVerdict(.equivalent, loop_if_one, loop_if_one);
}

const elsefall_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  let label = "none";
    \\  if (req.method === "GET") {
    \\    return Response.json({ ok: true });
    \\  } else {
    \\    label = "write";
    \\  }
    \\  cacheSet("ns", "one", label);
    \\  return Response.json({ label: label });
    \\}
;
const elsefall_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  let label = "none";
    \\  if (req.method === "GET") {
    \\    return Response.json({ ok: true });
    \\  } else {
    \\    label = "write";
    \\  }
    \\  cacheSet("ns", "two", label);
    \\  return Response.json({ label: label });
    \\}
;
const elsefall_call_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "GET") {
    \\    return Response.json({ ok: true });
    \\  } else {
    \\    cacheSet("ns", "one", "v");
    \\  }
    \\  return Response.json({ ok: false });
    \\}
;
const elsefall_call_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  if (req.method === "GET") {
    \\    return Response.json({ ok: true });
    \\  } else {
    \\    cacheSet("ns", "two", "v");
    \\  }
    \\  return Response.json({ ok: false });
    \\}
;
const elsefall_chain_one = imp_cache ++
    \\function handler(req: Request): Response {
    \\  let label = "none";
    \\  if (req.method === "GET") {
    \\    return Response.json({ ok: true });
    \\  } else if (req.method === "PUT") {
    \\    label = "put";
    \\  } else {
    \\    label = "other";
    \\  }
    \\  cacheSet("ns", "one", label);
    \\  return Response.json({ label: label });
    \\}
;
const elsefall_chain_two = imp_cache ++
    \\function handler(req: Request): Response {
    \\  let label = "none";
    \\  if (req.method === "GET") {
    \\    return Response.json({ ok: true });
    \\  } else if (req.method === "PUT") {
    \\    label = "put";
    \\  } else {
    \\    label = "other";
    \\  }
    \\  cacheSet("ns", "two", label);
    \\  return Response.json({ label: label });
    \\}
;

test "prove-behavior: a call after an if whose else branch falls through is on the path" {
    try expectVerdict(.breaking, elsefall_one, elsefall_two);
    try expectVerdict(.breaking, elsefall_call_one, elsefall_call_two);
    try expectVerdict(.breaking, elsefall_chain_one, elsefall_chain_two);
    try expectVerdict(.equivalent, elsefall_one, elsefall_one);
    try expectVerdict(.equivalent, elsefall_chain_one, elsefall_chain_one);
}

test "contract: an if whose else branch falls through keeps the path after it" {
    const K = zts.handler_contract.ResponseStatus;
    try expectStatuses(elsefall_one, &[_]K{ .{ .known = 200 }, .{ .known = 200 } });
    // The inner `if` holds no module call, so it adds no path of its own.
    try expectStatuses(elsefall_chain_one, &[_]K{ .{ .known = 200 }, .{ .known = 200 } });
}

test "prove-behavior: if branch controls keep their verdicts" {
    try expectVerdict(.breaking, ifreturn_one, ifreturn_two);
    try expectVerdict(.equivalent, ifcall_one, ifcall_one);
    try expectVerdict(.equivalent, ifelse_one, ifelse_one);
}

// D-014: every literal `env()` name is secret unless the policy lists it in
// `env.public`. These tests run the production check path, with the policy as
// the project would hand it over, and read the verdict the way a user does:
// the `no_secret_leakage` property and the ZTS400 diagnostic.

const env_leak_template =
    \\import {{ env }} from "zttp:env";
    \\
    \\function handler(req: Request): Response {{
    \\  return Response.json({{ v: env("{s}") ?? "" }});
    \\}}
;

/// Whether the env name `name`, returned in a response, is refused under `policy`.
fn envNameIsRefused(allocator: std.mem.Allocator, name: []const u8, policy: ?[]const u8) !bool {
    const source = try std.fmt.allocPrint(allocator, env_leak_template, .{name});
    defer allocator.free(source);
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "env-name.ts", .{
        .json_mode = true,
        .policy_source = policy,
    });
    defer result.deinit(allocator);
    const properties = result.properties orelse return error.NoHandlerProperties;
    const refused = hasDiagnosticCode(&result, "ZTS400");
    // The verdict and the diagnostic must agree: a held property with ZTS400,
    // or a refused one without it, is a defect of its own.
    try std.testing.expectEqual(refused, !properties.no_secret_leakage);
    return refused;
}

test "env: a name is refused with no policy, whatever its spelling" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "DB_PASS", "DATABASE_URL", "STRIPE_SK", "APP_NAME" }) |name| {
        try std.testing.expect(try envNameIsRefused(allocator, name, null));
    }
}

test "env: a name that the policy lists in env.public holds" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "DB_PASS", "DATABASE_URL", "STRIPE_SK", "APP_NAME" }) |name| {
        const policy = try std.fmt.allocPrint(allocator, "{{\"env\":{{\"allow\":[\"{s}\"],\"public\":[\"{s}\"]}}}}", .{ name, name });
        defer allocator.free(policy);
        try std.testing.expect(!try envNameIsRefused(allocator, name, policy));
    }
}

test "env: a policy that lists the name only in allow does not make it public" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try envNameIsRefused(allocator, "APP_NAME", "{\"env\":{\"allow\":[\"APP_NAME\"]}}"));
    // Another name in public does not vouch for this one either.
    try std.testing.expect(try envNameIsRefused(allocator, "APP_NAME", "{\"env\":{\"allow\":[\"APP_NAME\",\"PORT\"],\"public\":[\"PORT\"]}}"));
}

test "env: the public match is exact, so a different case is refused" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try envNameIsRefused(allocator, "APP_NAME", "{\"env\":{\"allow\":[\"app_name\"],\"public\":[\"app_name\"]}}"));
}

test "env: a computed name is refused even when every listed name is public" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\
        \\function pick(): string { return "APP_NAME"; }
        \\
        \\function handler(req: Request): Response {
        \\  const k = pick();
        \\  return Response.json({ v: env(k) ?? "" });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "env-computed.ts", .{
        .json_mode = true,
        .policy_source = "{\"env\":{\"allow\":[\"APP_NAME\"],\"public\":[\"APP_NAME\"]}}",
    });
    defer result.deinit(allocator);
    const properties = result.properties orelse return error.NoHandlerProperties;
    try std.testing.expect(!properties.no_secret_leakage);
    try std.testing.expect(hasDiagnosticCode(&result, "ZTS400"));
}

test "env: a policy that does not parse keeps every name secret" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try envNameIsRefused(allocator, "APP_NAME", "{\"env\":{\"public\":[\"APP_NAME\"]}}"));
}

test "env: the contract discloses the public names, and a policy without them discloses none" {
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator, env_leak_template, .{"APP_NAME"});
    defer allocator.free(source);

    var with_public = try runCheckOnlyFromSourceWithOptions(allocator, source, "env-contract.ts", .{
        .json_mode = true,
        .policy_source = "{\"env\":{\"allow\":[\"APP_NAME\"],\"public\":[\"APP_NAME\"]}}",
    });
    defer with_public.deinit(allocator);
    const disclosed = with_public.contract orelse return error.NoContract;
    try std.testing.expectEqual(@as(usize, 1), disclosed.env.public.items.len);
    try std.testing.expectEqualStrings("APP_NAME", disclosed.env.public.items[0]);

    var allow_only = try runCheckOnlyFromSourceWithOptions(allocator, source, "env-contract.ts", .{
        .json_mode = true,
        .policy_source = "{\"env\":{\"allow\":[\"APP_NAME\"]}}",
    });
    defer allow_only.deinit(allocator);
    const undisclosed = allow_only.contract orelse return error.NoContract;
    try std.testing.expectEqual(@as(usize, 0), undisclosed.env.public.items.len);
}

test "scanSource lists the relative imports CHECK follows and the handler function without checking types" {
    const allocator = std.testing.allocator;
    const source =
        \\import { cacheSet } from "zttp:cache";
        \\import { a, b } from "./lib/a.ts";
        \\import { c } from "../shared/c";
        \\const n: number = "mistyped";
        \\function handler(req: Request): Response { return Response.text("ok"); }
        \\
    ;
    var scan = try imports_mod.scanSource(allocator, source, "app/handler.ts");
    defer scan.deinit(allocator);
    try std.testing.expect(scan.has_handler);
    try std.testing.expectEqual(@as(usize, 2), scan.imports.len);
    try std.testing.expectEqualStrings("app/lib/a.ts", scan.imports[0]);
    try std.testing.expectEqualStrings("shared/c.ts", scan.imports[1]);

    var helper = try imports_mod.scanSource(allocator, "export function f(): string { return \"x\"; }\n", "lib.ts");
    defer helper.deinit(allocator);
    try std.testing.expect(!helper.has_handler);
    try std.testing.expectEqual(@as(usize, 0), helper.imports.len);

    try std.testing.expectError(
        error.Unparseable,
        imports_mod.scanSource(allocator, "import { a } from \"./a.ts\";\nfunction handler(\n", "broken.ts"),
    );
}

// A2: a value from the network or from stored state differs between two runs
// of the same request, so a handler or helper that returns it is not
// deterministic.
fn varyingProbe(allocator: std.mem.Allocator, imports: []const u8, handler_body: []const u8, helper_body: []const u8) !CheckResult {
    const source = try std.fmt.allocPrint(
        allocator,
        "{s}\nfunction load(): unknown {{ {s} }}\nfunction handler(req: Request): Response {{ {s} }}\n",
        .{ imports, helper_body, handler_body },
    );
    defer allocator.free(source);
    return runCheckOnlyFromSourceWithOptions(allocator, source, "a2-probe.ts", .{ .json_mode = true });
}

fn probeHandlerDeterministic(result: *const CheckResult) !bool {
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    return properties.deterministic;
}

fn probeHelperDeterministic(result: *const CheckResult) !bool {
    const contract = result.contract orelse return error.TestUnexpectedResult;
    for (contract.function_capsules.items) |capsule| {
        if (std.mem.eql(u8, capsule.function, "load")) return capsule.proven_deterministic;
    }
    return error.TestUnexpectedResult;
}

const fetch_import = "import { fetch, fetchWithRetry } from \"zttp:fetch\";";
const constant_helper = "return \"x\";";
const constant_handler = "return Response.text(\"ok\");";

test "A2: a handler that returns a fetch result is not deterministic" {
    const allocator = std.testing.allocator;
    var result = try varyingProbe(allocator, fetch_import, "return fetch(\"https://api.example.com/data\");", constant_helper);
    defer result.deinit(allocator);
    try std.testing.expect(!try probeHandlerDeterministic(&result));
}

test "A2: a handler that answers a fetch body is not deterministic" {
    const allocator = std.testing.allocator;
    var result = try varyingProbe(allocator, fetch_import, "const r = fetch(\"https://api.example.com/data\"); return Response.text(r.body);", constant_helper);
    defer result.deinit(allocator);
    try std.testing.expect(!try probeHandlerDeterministic(&result));
}

test "A2: a handler that returns a fetchWithRetry result is not deterministic" {
    const allocator = std.testing.allocator;
    var result = try varyingProbe(allocator, fetch_import, "return fetchWithRetry(\"https://api.example.com/data\", {}, {});", constant_helper);
    defer result.deinit(allocator);
    try std.testing.expect(!try probeHandlerDeterministic(&result));
}

test "A2: a helper that returns a fetch result is not a deterministic capsule" {
    const allocator = std.testing.allocator;
    var result = try varyingProbe(allocator, fetch_import, constant_handler, "return fetch(\"https://api.example.com/data\");");
    defer result.deinit(allocator);
    try std.testing.expect(!try probeHelperDeterministic(&result));
}

test "A2: a helper that returns a fetchWithRetry result is not a deterministic capsule" {
    const allocator = std.testing.allocator;
    var result = try varyingProbe(allocator, fetch_import, constant_handler, "return fetchWithRetry(\"https://api.example.com/data\", {}, {});");
    defer result.deinit(allocator);
    try std.testing.expect(!try probeHelperDeterministic(&result));
}

test "A2: a helper that reads the cache without a clock is not a deterministic capsule" {
    const allocator = std.testing.allocator;
    var cache_stats = try varyingProbe(allocator, "import { cacheStats } from \"zttp:cache\";", constant_handler, "return cacheStats();");
    defer cache_stats.deinit(allocator);
    try std.testing.expect(!try probeHelperDeterministic(&cache_stats));
}

test "A2: a helper that reads SQL is not a deterministic capsule" {
    const allocator = std.testing.allocator;
    var sql_one = try varyingProbe(allocator, "import { sqlOne } from \"zttp:sql\";", constant_handler, "return sqlOne(\"q\", {});");
    defer sql_one.deinit(allocator);
    try std.testing.expect(!try probeHelperDeterministic(&sql_one));
}

test "A2: a fetch whose result is discarded keeps the handler deterministic" {
    const allocator = std.testing.allocator;
    var result = try varyingProbe(allocator, fetch_import, "fetch(\"https://api.example.com/hook\"); return Response.text(\"ok\");", constant_helper);
    defer result.deinit(allocator);
    try std.testing.expect(try probeHandlerDeterministic(&result));
}

test "A2: a handler and a helper with no varying source stay deterministic" {
    const allocator = std.testing.allocator;
    var result = try varyingProbe(allocator, fetch_import, constant_handler, constant_helper);
    defer result.deinit(allocator);
    try std.testing.expect(try probeHandlerDeterministic(&result));
    try std.testing.expect(try probeHelperDeterministic(&result));
}

// ---------------------------------------------------------------------------
// A3: a read on a value that may be undefined (ZTS309), and a Dict read (ZTS201).
// Each case runs the public check and compares the exact list of diagnostics,
// `CODE@line`, in report order. "clean" means no diagnostic at all.
// ---------------------------------------------------------------------------

const AbsentReadCase = struct {
    name: []const u8,
    expect: []const u8,
    source: []const u8,
};

fn absentReadSummary(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "absent-read.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    if (result.json_diagnostics.items.len == 0) return allocator.dupe(u8, "clean");
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (result.json_diagnostics.items, 0..) |diagnostic, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.print("{s}@{d}", .{ diagnostic.code, diagnostic.line });
    }
    return allocator.dupe(u8, out.written());
}

fn expectAbsentReadCases(cases: []const AbsentReadCase) !void {
    const allocator = std.testing.allocator;
    var failures: usize = 0;
    for (cases) |case| {
        const got = try absentReadSummary(allocator, case.source);
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, case.expect)) {
            failures += 1;
            std.debug.print("A3 case {s}: expected {s}, got {s}\n", .{ case.name, case.expect, got });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

const absent_read_refused = [_]AbsentReadCase{
    .{ .name = "user_structural_with_the_exact_result_shape", .expect = "ZTS309@6,ZTS500@4", .source =
    \\structural X = { x: number };
    \\structural R = { ok: boolean; value?: X; error?: string; errors?: string };
    \\function mk(): R { return { ok: false }; }
    \\function handler(req: Request): Response {
    \\  const r = mk();
    \\  return Response.json({ a: r.value.x });
    \\}
    },
    .{ .name = "n19_typed_decl", .expect = "ZTS200@4", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p: P = ps[0];
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "p01_optchain_bind", .expect = "ZTS309@6,ZTS500@3", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = undefined;
    \\  const q = p?.q;
    \\  return Response.json({ a: q.age });
    \\}
    },
    .{ .name = "p02_computed_record_key", .expect = "ZTS309@5,ZTS500@3", .source =
    \\structural P = { age: number };
    \\structural W = { p: P | undefined };
    \\function handler(req: Request): Response {
    \\  const w: W = { p: undefined };
    \\  return Response.json({ a: w["p"].age });
    \\}
    },
    .{ .name = "p03_match_arm_nullable_field", .expect = "ZTS216@6,ZTS309@7,ZTS500@3", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q | undefined };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = { q: undefined };
    \\  return match (p) {
    \\    when undefined: Response.json({ a: 0 })
    \\    when { q: v }: Response.json({ a: v.age })
    \\  };
    \\}
    },
    .{ .name = "p04_optional_field", .expect = "ZTS309@5,ZTS500@3", .source =
    \\structural P = { age: number };
    \\structural W = { p?: P };
    \\function handler(req: Request): Response {
    \\  const w: W = {};
    \\  return Response.json({ a: w.p.age });
    \\}
    },
    .{ .name = "p05_callback_param_unannotated", .expect = "ZTS309@4,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: (P | undefined)[] = [undefined];
    \\  return Response.json({ a: ps.map((x) => x.age) });
    \\}
    },
    .{ .name = "p06_typed_decl_from_untyped_init", .expect = "ZTS200@5", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = undefined;
    \\  const q: Q = p?.q;
    \\  return Response.json({ a: q.age });
    \\}
    },
    .{ .name = "p08_ternary_cond_kill", .expect = "ZTS107@8,ZTS309@8,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  let p: P | undefined = { age: 1 };
    \\  const reset = (): boolean => {
    \\    p = undefined;
    \\    return true;
    \\  };
    \\  const a: number = p !== undefined && reset() ? p.age : 0;
    \\  return Response.json({ a: a });
    \\}
    },
    .{ .name = "p10_union_of_arrays", .expect = "ZTS309@5,ZTS500@3", .source =
    \\structural P = { age: number };
    \\structural Q = { age: number };
    \\function handler(req: Request): Response {
    \\  const xs: P[] | Q[] = [];
    \\  return Response.json({ a: xs[0].age });
    \\}
    },
    .{ .name = "p11_optchain_then_member", .expect = "ZTS309@5,ZTS500@3", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q | undefined };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = { q: undefined };
    \\  return Response.json({ a: p?.q.age });
    \\}
    },
    .{ .name = "p20_match_nonident_scrutinee", .expect = "ZTS309@7,ZTS500@3", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q | undefined };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [{ q: undefined }];
    \\  return match (ps[0]) {
    \\    when undefined: Response.json({ a: 0 })
    \\    when { q: v }: Response.json({ a: v.age })
    \\  };
    \\}
    },
    .{ .name = "p28_ternary_assign_in_cond", .expect = "ZTS309@5,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  let p: P | undefined = ps[0];
    \\  const a: number = p !== undefined && (p = ps[1]) !== undefined ? p.age : 0;
    \\  return Response.json({ a: a });
    \\}
    },
    .{ .name = "p33_tracker_vs_phase_computed", .expect = "ZTS309@4,ZTS400@4,ZTS500@2", .source =
    \\import { env } from "zttp:env";
    \\function handler(req: Request): Response {
    \\  const name = env("APP_NAME");
    \\  return Response.json({ n: name["length"] });
    \\}
    },
    .{ .name = "p38_both_branches_assign", .expect = "ZTS309@6,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  let p: P | undefined = ps[0];
    \\  if (p === undefined) { p = { age: 0 }; } else { p = { age: 1 }; }
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "p40_ternary_cond_kill_assign", .expect = "ZTS309@5,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  let p: P | undefined = ps[0];
    \\  const a: number = p !== undefined && (p = ps[1]) === undefined ? p.age : 0;
    \\  return Response.json({ a: a });
    \\}
    },
    .{ .name = "p42_match_nullable_scrutinee", .expect = "ZTS309@8,ZTS500@3", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q | undefined };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [{ q: undefined }];
    \\  const p = ps[0];
    \\  return match (p) {
    \\    when undefined: Response.json({ a: 0 })
    \\    when { q: v }: Response.json({ a: v.age })
    \\  };
    \\}
    },
    .{ .name = "q10_match_call_result", .expect = "ZTS309@10,ZTS500@6", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q | undefined };
    \\function first(ps: P[]): P | undefined {
    \\  return ps[0];
    \\}
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [{ q: undefined }];
    \\  return match (first(ps)) {
    \\    when undefined: Response.json({ a: 0 })
    \\    when { q: v }: Response.json({ a: v.age })
    \\  };
    \\}
    },
    .{ .name = "q13_nested_match_default_read", .expect = "ZTS309@10,ZTS500@3", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q | undefined };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  return match (p) {
    \\    when undefined: Response.json({ a: 0 })
    \\    when { q: v }: match (v) {
    \\      when undefined: Response.json({ a: 0 })
    \\      default: Response.json({ a: v.age })
    \\    }
    \\  };
    \\}
    },
    .{ .name = "q14_undefined_arm_reads", .expect = "ZTS309@6,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  return match (p) {
    \\    when undefined: Response.json({ a: p.age })
    \\    when { age: a }: Response.json({ a: a })
    \\  };
    \\}
    },
    .{ .name = "q15_default_after_undefined_arm", .expect = "ZTS309@7,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  return match (p) {
    \\    when undefined: Response.json({ a: 0 })
    \\    default: Response.json({ a: p.age })
    \\  };
    \\}
    },
    .{ .name = "q16_read_after_match", .expect = "ZTS309@9,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  const a: number = match (p) {
    \\    when undefined: 0
    \\    default: 1
    \\  };
    \\  return Response.json({ a: a, b: p.age });
    \\}
    },
    .{ .name = "q20_result_shaped_record", .expect = "ZTS309@5,ZTS500@3", .source =
    \\structural P = { age: number };
    \\structural R = { ok: boolean; value?: P; error?: string };
    \\function handler(req: Request): Response {
    \\  const r: R = { ok: false };
    \\  return Response.json({ a: r.value.age });
    \\}
    },
    .{ .name = "r01_decl", .expect = "ZTS309@4,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = undefined;
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "r02_empty_index", .expect = "ZTS309@5,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "r03_helper_param", .expect = "ZTS309@3,ZTS500@5", .source =
    \\structural P = { age: number };
    \\function f(p: P | undefined): number {
    \\  return p.age;
    \\}
    \\function handler(req: Request): Response {
    \\  return Response.json({ a: f(undefined) });
    \\}
    },
    .{ .name = "r04_direct_index", .expect = "ZTS309@4,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  return Response.json({ a: ps[0].age });
    \\}
    },
    .{ .name = "r05_computed_on_nullable", .expect = "ZTS309@4,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = undefined;
    \\  return Response.json({ a: p["age"] });
    \\}
    },
    .{ .name = "r06_method_call", .expect = "ZTS309@3,ZTS500@1", .source =
    \\function handler(req: Request): Response {
    \\  const xs: string[] = [];
    \\  return Response.json({ a: xs[0].trim() });
    \\}
    },
    .{ .name = "r07_length", .expect = "ZTS309@3,ZTS500@1", .source =
    \\function handler(req: Request): Response {
    \\  const xs: string[] = [];
    \\  return Response.json({ a: xs[0].length });
    \\}
    },
    .{ .name = "r08_for_of", .expect = "ZTS309@4,ZTS500@1", .source =
    \\function handler(req: Request): Response {
    \\  const xs: number[] | undefined = undefined;
    \\  const out: number[] = [];
    \\  for (const x of xs) { out.push(x); }
    \\  return Response.json({ a: out });
    \\}
    },
    .{ .name = "r09_array_spread", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Response {
    \\  const xs: number[] | undefined = undefined;
    \\  const ys: number[] = [...xs];
    \\  return Response.json({ a: ys });
    \\}
    },
    .{ .name = "r09_array_spread_without_annotation_reaches_flow", .expect = "ZTS309@3,ZTS500@1", .source =
    \\function handler(req: Request): Response {
    \\  const xs: number[] | undefined = undefined;
    \\  const ys = [...xs];
    \\  return Response.json({ a: ys });
    \\}
    },
    .{ .name = "r10_union3", .expect = "ZTS309@5,ZTS500@3", .source =
    \\structural P = { age: number };
    \\structural Q = { age: number, name: string };
    \\function handler(req: Request): Response {
    \\  const p: P | Q | undefined = undefined;
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "r11_nested_index", .expect = "ZTS309@3,ZTS500@1", .source =
    \\function handler(req: Request): Response {
    \\  const m: number[][] = [];
    \\  const n: number = m[0][0] ?? 0;
    \\  return Response.json({ a: n });
    \\}
    },
    .{ .name = "r12_field_nullable", .expect = "ZTS309@5,ZTS500@3", .source =
    \\structural P = { age: number };
    \\structural W = { p: P | undefined };
    \\function handler(req: Request): Response {
    \\  const w: W = { p: undefined };
    \\  return Response.json({ a: w.p.age });
    \\}
    },
    .{ .name = "r14_req_body", .expect = "ZTS309@2,ZTS500@1", .source =
    \\function handler(req: Request): Response {
    \\  return Response.json({ a: req.body.length });
    \\}
    },
    .{ .name = "r17_assign_through", .expect = "ZTS309@4,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = undefined;
    \\  p.age = 3;
    \\  return Response.json({ a: 1 });
    \\}
    },
    .{ .name = "r18_find", .expect = "ZTS309@5,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps.find((x: P): boolean => x.age > 1);
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "r20_env_existing", .expect = "ZTS309@4,ZTS400@4,ZTS500@2", .source =
    \\import { env } from "zttp:env";
    \\function handler(req: Request): Response {
    \\  const name = env("APP_NAME");
    \\  return Response.json({ n: name.length });
    \\}
    },
    .{ .name = "r22_length_guard", .expect = "ZTS309@4,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const a: number = ps.length > 0 ? ps[0].age : 0;
    \\  return Response.json({ a: a });
    \\}
    },
    .{ .name = "r24_tuple_oob", .expect = "ZTS309@4,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const t: [P, P] = [{ age: 1 }, { age: 2 }];
    \\  return Response.json({ a: t[2].age });
    \\}
    },
    .{ .name = "r29_env_in_helper", .expect = "ZTS309@4,ZTS400@7,ZTS500@6,ZTS606@2", .source =
    \\import { env } from "zttp:env";
    \\function h(): number {
    \\  const name = env("APP_NAME");
    \\  return name.length;
    \\}
    \\function handler(req: Request): Response {
    \\  return Response.json({ n: h() });
    \\}
    },
    .{ .name = "r30_capsule", .expect = "ZTS309@4", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const ps: P[] = [];
    \\  return Response.json({ a: ps[0].age });
    \\}
    },
    .{ .name = "r31_reassign_to_index", .expect = "ZTS309@6,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  let p: P | undefined = { age: 1 };
    \\  p = ps[0];
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "r32_closure_unguarded", .expect = "ZTS309@5,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  const f = (): number => p.age;
    \\  return Response.json({ a: f() });
    \\}
    },
    .{ .name = "s01_union_result_unnarrowed", .expect = "ZTS309@6,ZTS500@4", .source =
    \\structural P = { age: number };
    \\structural R = { ok: true; value: P } | { ok: false; error: string };
    \\function mk(): R { return { ok: false, error: "x" }; }
    \\function handler(req: Request): Response {
    \\  const r = mk();
    \\  return Response.json({ a: r.value.age });
    \\}
    },
    .{ .name = "s05_upvalue_name_collision", .expect = "ZTS303@11,ZTS500@9,ZTS606@4", .source =
    \\import { parseJson } from "zttp:json";
    \\structural P = { age: number };
    \\structural R = { ok: boolean; value?: P; error?: string };
    \\function other(): number {
    \\  const r = parseJson("{}");
    \\  if (!r.ok) return 0;
    \\  return 1;
    \\}
    \\function handler(req: Request): Response {
    \\  const r: R = { ok: false };
    \\  const read = (): number => r.value.age;
    \\  return Response.json({ a: read(), b: other() });
    \\}
    },
    .{ .name = "s05b_upvalue_no_collision", .expect = "ZTS309@5,ZTS500@3", .source =
    \\structural P = { age: number };
    \\structural R = { ok: boolean; value?: P; error?: string };
    \\function handler(req: Request): Response {
    \\  const r: R = { ok: false };
    \\  const read = (): number => r.value.age;
    \\  return Response.json({ a: read() });
    \\}
    },
    .{ .name = "u01_match_on_unknown_binding", .expect = "ZTS309@7,ZTS500@3", .source =
    \\import { parseJson } from "zttp:json";
    \\structural N = { first: string };
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return match (parsed.value) {
    \\    when { name: n }: Response.json({ a: n.first })
    \\    default: Response.json({ a: "none" })
    \\  };
    \\}
    },
    .{ .name = "u08_match_unknown_nested_pattern", .expect = "ZTS309@6,ZTS500@2", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return match (parsed.value) {
    \\    when { name: { first: f } }: Response.json({ a: f.len })
    \\    default: Response.json({ a: "none" })
    \\  };
    \\}
    },
    .{ .name = "u09_match_unknown_shorthand", .expect = "ZTS309@6,ZTS500@2", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return match (parsed.value) {
    \\    when { name }: Response.json({ a: name.first })
    \\    default: Response.json({ a: "none" })
    \\  };
    \\}
    },
    .{ .name = "u08b_record_in_array_pattern_on_unknown", .expect = "ZTS309@6,ZTS500@2", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return match (parsed.value) {
    \\    when [{ name: n }]: Response.json({ a: n.len })
    \\    default: Response.json({ a: "none" })
    \\  };
    \\}
    },
    .{ .name = "r21_arith", .expect = "ZTS106@3", .source =
    \\function handler(req: Request): Response {
    \\  const xs: number[] = [1, 2];
    \\  return Response.json({ a: 1 + xs[5] });
    \\}
    },
    .{ .name = "t1_object_values_element_call", .expect = "ZTS309@4,ZTS500@2", .source =
    \\structural P = { f: number };
    \\function handler(req: Request): Response {
    \\  const o: P = { f: 1 };
    \\  Object.values(o)[0].f(1);
    \\  return Response.text("ok");
    \\}
    },
};

const absent_read_accepted = [_]AbsentReadCase{
    .{ .name = "union_annotation_present_initializer_narrows", .expect = "clean", .source =
    \\structural P = { age: number };
    \\structural Q = { age: number; n: number };
    \\function handler(req: Request): Response {
    \\  const p: P | Q | undefined = { age: 1 };
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "validated_value_bound_then_read", .expect = "ZTS500@3", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"}},\"required\":[\"title\"]}");
    \\function handler(req: Request): Response {
    \\  const parsed = validateJson("todo", req.body ?? "");
    \\  if (!parsed.ok) {
    \\    return Response.json({ error: "invalid body" }, { status: 400 });
    \\  }
    \\  const t = parsed.value;
    \\  const n: string = parsed.value.title;
    \\  return Response.json({ a: t.title, n: n, l: parsed.value.title.length });
    \\}
    },
    .{ .name = "result_error_returned_as_string", .expect = "ZTS303@3,ZTS401@5,ZTS500@2", .source =
    \\import { jwtVerify } from "zttp:auth";
    \\function handler(req: Request): Response {
    \\  const read = (): string => jwtVerify("t", "s").error;
    \\  const again = read;
    \\  return Response.text(again());
    \\}
    },
    .{ .name = "d5_requestjson", .expect = "ZTS201@5,ZTS201@5", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  return Response.json({ isd: isDict(f), idxUndef: f["a"] === undefined, memUndef: f.a === undefined });
    \\}
    },
    .{ .name = "n01_eq_return", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  if (p === undefined) {
    \\    return Response.json({ a: 0 });
    \\  }
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "n02_neq_block", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  if (p !== undefined) {
    \\    return Response.json({ a: p.age });
    \\  }
    \\  return Response.json({ a: 0 });
    \\}
    },
    .{ .name = "n05_chain", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  return Response.json({ a: ps[0]?.age ?? 0 });
    \\}
    },
    .{ .name = "n06_nullish_obj", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const d: P = { age: 0 };
    \\  const p = ps[0] ?? d;
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "n07_assert", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  assert p !== undefined, Response.json({ error: "none" }, { status: 404 });
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "n08_and", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  const ok: boolean = p !== undefined && p.age > 1;
    \\  return Response.json({ a: ok });
    \\}
    },
    .{ .name = "n09_or", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  const bad: boolean = p === undefined || p.age > 1;
    \\  return Response.json({ a: bad });
    \\}
    },
    .{ .name = "n10_ternary", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  const a: number = p !== undefined ? p.age : 0;
    \\  return Response.json({ a: a });
    \\}
    },
    .{ .name = "n13b_helper_guard_proof", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function f(p: P | undefined): number {
    \\  if (p === undefined) return 0;
    \\  return p.age;
    \\}
    \\function handler(req: Request): Proof<Response, "optional_safe"> {
    \\  return Response.json({ a: f(undefined) });
    \\}
    },
    .{ .name = "n15_match", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  return match (p) {
    \\    when undefined: Response.json({ a: 0 })
    \\    when { age }: Response.json({ a: age })
    \\  };
    \\}
    },
    .{ .name = "n16_req_body_guard", .expect = "clean", .source =
    \\function handler(req: Request): Response {
    \\  const b = req.body;
    \\  if (b === undefined) return Response.json({ a: 0 });
    \\  return Response.json({ a: b.length });
    \\}
    },
    .{ .name = "n21_reassign_straight", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  let p: P | undefined = ps[0];
    \\  p = { age: 0 };
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "n26_decl_present_init", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = { age: 1 };
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "n28_closure_capture_const", .expect = "ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  if (p === undefined) return Response.json({ a: 0 });
    \\  const f = (): number => p.age;
    \\  return Response.json({ a: f() });
    \\}
    },
    .{ .name = "n29_closure_in_block", .expect = "ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const q = ps[0];
    \\  if (q !== undefined) {
    \\    const f = (): number => q.age;
    \\    return Response.json({ a: f() });
    \\  }
    \\  return Response.json({ a: 0 });
    \\}
    },
    .{ .name = "p12_unknown_read", .expect = "clean", .source =
    \\function handler(req: Request): Response {
    \\  const u: unknown = undefined;
    \\  return Response.json({ a: u.age });
    \\}
    },
    .{ .name = "p27_assert_then_ternary_else", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  const a: number = p === undefined ? 0 : p.age;
    \\  return Response.json({ a: a });
    \\}
    },
    .{ .name = "p39_ternary_both_senses", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p: P | undefined = ps[0];
    \\  const a: number = p !== undefined ? p.age : 0;
    \\  const b: number = p === undefined ? 0 : p.age;
    \\  return Response.json({ a: a + b });
    \\}
    },
    .{ .name = "p41_decl_narrow_then_guard", .expect = "ZTS107@4", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = { age: 1 };
    \\  if (p === undefined) return Response.json({ a: 0 });
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "p44_decl_narrow_then_ternary_guard", .expect = "ZTS107@4", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = { age: 1 };
    \\  const a: number = p === undefined ? 0 : p.age;
    \\  return Response.json({ a: a });
    \\}
    },
    .{ .name = "q12_nested_match_ok", .expect = "clean", .source =
    \\structural Q = { age: number };
    \\structural P = { q: Q | undefined };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  return match (p) {
    \\    when undefined: Response.json({ a: 0 })
    \\    when { q: v }: match (v) {
    \\      when undefined: Response.json({ a: 0 })
    \\      when { age: a }: Response.json({ a: a })
    \\    }
    \\  };
    \\}
    },
    .{ .name = "q17_guard_after_match_ok", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  const a: number = match (p) {
    \\    when undefined: 0
    \\    default: 1
    \\  };
    \\  if (p === undefined) return Response.json({ a: a });
    \\  return Response.json({ a: a, b: p.age });
    \\}
    },
    .{ .name = "q33_ternary_guard_const", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const ps: P[] = [];
    \\  const p = ps[0];
    \\  const a: number = p !== undefined ? p.age : 0;
    \\  const b: number = p === undefined ? 0 : p.age;
    \\  return Response.json({ a: a, b: b });
    \\}
    },
    .{ .name = "r13_null", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const p: P | null = null;
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "r15_header_index", .expect = "clean", .source =
    \\function handler(req: Request): Response {
    \\  return Response.json({ a: req.headers["x"].length });
    \\}
    },
    .{ .name = "r16_query_member", .expect = "clean", .source =
    \\function handler(req: Request): Response {
    \\  return Response.json({ a: req.query.q.length });
    \\}
    },
    .{ .name = "r23_tuple_in_range", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const t: [P, P] = [{ age: 1 }, { age: 2 }];
    \\  return Response.json({ a: t[0].age });
    \\}
    },
    .{ .name = "r27_object_spread", .expect = "clean", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const p: P | undefined = undefined;
    \\  return Response.json({ ...p, b: 1 });
    \\}
    },
    .{ .name = "s01b_union_result_if_narrowed", .expect = "clean", .source =
    \\structural P = { age: number };
    \\structural R = { ok: true; value: P } | { ok: false; error: string };
    \\function mk(): R { return { ok: false, error: "x" }; }
    \\function handler(req: Request): Response {
    \\  const r = mk();
    \\  if (!r.ok) return Response.json({ e: r.error }, { status: 400 });
    \\  return Response.json({ a: r.value.age });
    \\}
    },
    .{ .name = "s01c_union_narrowed_assign", .expect = "clean", .source =
    \\structural P = { age: number };
    \\structural R = { ok: true; value: P } | { ok: false; error: string };
    \\function mk(): R { return { ok: false, error: "x" }; }
    \\function handler(req: Request): Response {
    \\  const r = mk();
    \\  if (!r.ok) return Response.json({ e: r.error }, { status: 400 });
    \\  const v: P = r.value;
    \\  return Response.json({ a: v.age });
    \\}
    },
    .{ .name = "s01d_union_unnarrowed_assign_is_a_type_error", .expect = "ZTS200@6", .source =
    \\structural P = { age: number };
    \\structural R = { ok: true; value: P } | { ok: false; error: string };
    \\function mk(): R { return { ok: false, error: "x" }; }
    \\function handler(req: Request): Response {
    \\  const r = mk();
    \\  const v: number = r.value;
    \\  return Response.json({ a: v });
    \\}
    },
    .{ .name = "u05_dictget_unknown_read", .expect = "ZTS500@3", .source =
    \\import { parseJson } from "zttp:json";
    \\import { dictGet } from "zttp:collections";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  const v = dictGet(f, "zz");
    \\  return Response.json({ a: v.age });
    \\}
    },
    .{ .name = "u06_param_unknown_read", .expect = "clean", .source =
    \\function age(p: unknown): unknown { return p.age; }
    \\function handler(req: Request): Response {
    \\  return Response.json({ a: age(undefined) });
    \\}
    },
};

const absent_read_dict = [_]AbsentReadCase{
    .{ .name = "e3_dictget_chain", .expect = "ZTS500@2", .source =
    \\import { dictGet } from "zttp:collections";
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: parsed.error.kind }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "not_dict" }, { status: 502 });
    \\  const c = dictGet(f, "b");
    \\  if (!isDict(c)) return Response.json({ error: "no_b" }, { status: 502 });
    \\  return Response.json({ a: dictGet(f, "a"), c: dictGet(c, "c") });
    \\}
    },
    .{ .name = "k01_dict_computed_key", .expect = "ZTS201@8", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1,\"b\":{\"c\":2}}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  const k = "a";
    \\  return Response.json({ v: f[k] });
    \\}
    },
    .{ .name = "k03_dict_nullish", .expect = "ZTS201@7", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1,\"b\":{\"c\":2}}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  return Response.json({ v: f["a"] ?? 0 });
    \\}
    },
    .{ .name = "k04_dict_nested_member", .expect = "ZTS201@7", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1,\"b\":{\"c\":2}}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  return Response.json({ v: f.b.c });
    \\}
    },
    .{ .name = "k06_record_with_dict_field", .expect = "ZTS201@8", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1,\"b\":{\"c\":2}}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  const rec = { d: f, n: 1 };
    \\  return Response.json({ v: rec.d.a, n: rec.n });
    \\}
    },
    .{ .name = "k07_dict_param", .expect = "ZTS201@3", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function pick(d: Dict<unknown, unknown>): unknown {
    \\  return d["a"] ?? 0;
    \\}
    \\function handler(req: Request): Response {
    \\  return Response.json({ v: pick(dictEmpty()) });
    \\}
    },
    .{ .name = "k08_dict_or_undefined", .expect = "ZTS201@8", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1,\"b\":{\"c\":2}}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  const d = req.method === "GET" ? f : undefined;
    \\  return Response.json({ v: d?.a });
    \\}
    },
    .{ .name = "k08b_dict_or_undefined_narrowed", .expect = "ZTS201@9", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1,\"b\":{\"c\":2}}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  const d = req.method === "GET" ? f : undefined;
    \\  if (d === undefined) return Response.json({ v: 0 });
    \\  return Response.json({ v: d.a });
    \\}
    },
    .{ .name = "k11_dict_index_in_compare", .expect = "ZTS201@7", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1,\"b\":{\"c\":2}}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  return Response.json({ v: f["a"] === undefined ? "absent" : "present" });
    \\}
    },
    .{ .name = "n25_dict_guard", .expect = "ZTS201@4", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const d: Dict<string, P> = {};
    \\  const p = d["k"];
    \\  if (p === undefined) return Response.json({ a: 0 });
    \\  return Response.json({ a: p.age });
    \\}
    },
    .{ .name = "n30_unknown_isdict", .expect = "ZTS201@4", .source =
    \\function handler(req: Request): Response {
    \\  const f: unknown = req.json();
    \\  if (!isDict(f)) return Response.json({ error: "bad" }, { status: 502 });
    \\  return Response.json({ a: f.latitude });
    \\}
    },
    .{ .name = "p31_dict_nullable_value", .expect = "ZTS201@4", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const d: Dict<string, P | undefined> = {};
    \\  return Response.json({ a: d["k"].age });
    \\}
    },
    .{ .name = "q30_isdict_member_vs_index", .expect = "ZTS201@4,ZTS201@4,ZTS201@4", .source =
    \\function handler(req: Request): Response {
    \\  const f: unknown = req.json();
    \\  if (!isDict(f)) return Response.json({ error: "bad" }, { status: 502 });
    \\  return Response.json({ a: f.latitude, b: f["latitude"], c: f.current.time });
    \\}
    },
    .{ .name = "q34_requestjson_isdict_runtime", .expect = "ZTS201@6,ZTS201@6", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "not_dict" }, { status: 502 });
    \\  return Response.json({ t: f.current.time, lat: f.latitude });
    \\}
    },
    .{ .name = "q34b_requestjson_isdict_index", .expect = "ZTS201@6,ZTS201@8", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "not_dict" }, { status: 502 });
    \\  const c = f["current"];
    \\  if (!isDict(c)) return Response.json({ error: "no_current" }, { status: 502 });
    \\  return Response.json({ t: c["time"], lat: f["latitude"] });
    \\}
    },
    .{ .name = "q35_dict_contents", .expect = "ZTS201@6,ZTS201@6,ZTS201@6", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "not_dict" }, { status: 502 });
    \\  return Response.json({ a: f["latitude"], b: f["current"], c: isDict(f["current"]) });
    \\}
    },
    .{ .name = "q37_dictget_runtime", .expect = "ZTS201@7", .source =
    \\import { dictGet } from "zttp:collections";
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "not_dict" }, { status: 502 });
    \\  return Response.json({ a: dictGet(f, "latitude"), b: f["latitude"] });
    \\}
    },
    .{ .name = "r25_dict", .expect = "ZTS201@4", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Response {
    \\  const d: Dict<string, P> = {};
    \\  return Response.json({ a: d["k"].age });
    \\}
    },
    .{ .name = "rt02_dict_nested", .expect = "ZTS201@7", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{\"a\":1,\"b\":{\"c\":2}}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const f = parsed.value;
    \\  if (!isDict(f)) return Response.json({ error: "nd" }, { status: 502 });
    \\  return Response.json({ v: f.b.c });
    \\}
    },
};

// A3 part 2a (Decision 44a): the `.value` of `requestJson` and `parseJson` is a
// Dict at run time, so a member, index, optional-chain, or computed read on it
// is refused as ZTS201. A guard, `decodeJson`, a stringify, and every other
// source of `unknown` stay as they were.
const absent_read_json_value = [_]AbsentReadCase{
    .{ .name = "requestjson_member", .expect = "ZTS201@4", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return Response.json({ a: parsed.value.name });
    \\}
    },
    .{ .name = "parsejson_index", .expect = "ZTS201@5", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return Response.json({ a: parsed.value["name"] });
    \\}
    },
    .{ .name = "requestjson_optional_chain", .expect = "ZTS201@5", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const v = parsed.value;
    \\  return Response.json({ a: v?.name });
    \\}
    },
    .{ .name = "parsejson_computed", .expect = "ZTS201@7", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const v = parsed.value;
    \\  const k = "name";
    \\  return Response.json({ a: v[k] });
    \\}
    },
    .{ .name = "requestjson_nested_member", .expect = "ZTS201@5", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const v = parsed.value;
    \\  return Response.json({ a: v.a.b });
    \\}
    },
    .{ .name = "parsejson_error_field_read_stays_accepted_value_member_refused", .expect = "ZTS201@5", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: parsed.error.kind }, { status: 400 });
    \\  return Response.json({ a: parsed.value.name });
    \\}
    },
    .{ .name = "parsejson_chained_member_read", .expect = "ZTS201@5", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return Response.json({ a: parsed.value.name.first });
    \\}
    },
    .{ .name = "parsejsonbytes_member", .expect = "ZTS201@5", .source =
    \\import { parseJsonBytes } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJsonBytes(requestBody(req));
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return Response.json({ a: parsed.value.name });
    \\}
    },
    .{ .name = "control_parsejsonbytes_isdict_dictget", .expect = "ZTS500@3", .source =
    \\import { parseJsonBytes } from "zttp:json";
    \\import { dictGet } from "zttp:collections";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJsonBytes(requestBody(req));
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const v = parsed.value;
    \\  if (!isDict(v)) return Response.json({ error: "not_dict" }, { status: 400 });
    \\  return Response.json({ a: dictGet(v, "name") });
    \\}
    },
    .{ .name = "json_value_in_ternary_union", .expect = "ZTS201@7", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const other: string = "x";
    \\  const flag = req.method === "GET";
    \\  const v = flag ? parsed.value : other;
    \\  return Response.json({ a: v.name });
    \\}
    },
    .{ .name = "json_value_or_undefined", .expect = "ZTS201@5", .source =
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const v = req.method === "GET" ? parsed.value : undefined;
    \\  return Response.json({ a: v.name });
    \\}
    },
    .{ .name = "json_value_with_a_record", .expect = "ZTS201@7", .source =
    \\structural R = { n: number };
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const r: R = { n: 1 };
    \\  const v = req.method === "GET" ? r : parsed.value;
    \\  return Response.json({ a: v.n });
    \\}
    },
    .{ .name = "control_union_of_plain_records", .expect = "clean", .source =
    \\structural A = { n: number };
    \\structural B = { n: number; m: number };
    \\function handler(req: Request): Response {
    \\  const a: A = { n: 1 };
    \\  const b: B = { n: 2, m: 3 };
    \\  const v = req.method === "GET" ? a : b;
    \\  return Response.json({ a: v.n });
    \\}
    },
    .{ .name = "control_isdict_then_dictget", .expect = "ZTS500@2", .source =
    \\import { dictGet } from "zttp:collections";
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const v = parsed.value;
    \\  if (!isDict(v)) return Response.json({ error: "not_dict" }, { status: 400 });
    \\  return Response.json({ a: dictGet(v, "name") });
    \\}
    },
    .{ .name = "control_typeof_string_narrows", .expect = "ZTS500@2", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Response {
    \\  const parsed = parseJson("{}");
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const v = parsed.value;
    \\  if (typeof v === "string") return Response.json({ a: v.length });
    \\  return Response.json({ a: 0 });
    \\}
    },
    .{ .name = "control_stringify_then_validate", .expect = "ZTS500@3", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"}},\"required\":[\"title\"]}");
    \\function handler(req: Request): Response {
    \\  const parsed = requestJson(req);
    \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  const checked = validateJson("todo", JSON.stringify(parsed.value));
    \\  if (!checked.ok) return Response.json({ error: "invalid" }, { status: 400 });
    \\  return Response.json({ a: checked.value.title });
    \\}
    },
    .{ .name = "control_decodejson_member_read", .expect = "ZTS500@2", .source =
    \\import { decodeJson } from "zttp:decode";
    \\function handler(req: Request): Response {
    \\  const decoded = decodeJson("todo", "{}");
    \\  if (!decoded.ok) return Response.json({ error: "bad" }, { status: 400 });
    \\  return Response.json({ a: decoded.value.title });
    \\}
    },
    .{ .name = "control_jwtverify_value_after_ok_check", .expect = "ZTS401@5,ZTS500@2", .source =
    \\import { jwtVerify } from "zttp:auth";
    \\function handler(req: Request): Response {
    \\  const r = jwtVerify("token", "secret");
    \\  if (!r.ok) return Response.json({ error: "bad" }, { status: 401 });
    \\  return Response.json({ claims: r.value });
    \\}
    },
    .{ .name = "control_fetch_json_member_read", .expect = "ZTS500@2", .source =
    \\import { fetch } from "zttp:fetch";
    \\function handler(req: Request): Response {
    \\  const res = fetch("https://api.example.com/a");
    \\  if (!res.ok) return Response.json({ error: "upstream" }, { status: 502 });
    \\  const j = res.json();
    \\  return Response.json({ a: j.name });
    \\}
    },
};

test "A3 part 2a: a member or index read on a parsed JSON value is refused as ZTS201" {
    try expectAbsentReadCases(&absent_read_json_value);
}

test "A3 part 2a: the ZTS201 repair on a parsed JSON value names decodeJson and dictGet" {
    const source =
        \\function handler(req: Request): Response {
        \\  const parsed = requestJson(req);
        \\  if (!parsed.ok) return Response.json({ error: "bad" }, { status: 400 });
        \\  return Response.json({ a: parsed.value.name });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "json-value.ts", .{ .json_mode = true });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS201", diagnostic.code);
    try std.testing.expectEqualStrings(
        "decode the value with decodeJson(schema, text), or check isDict(v) and read with dictGet(v, key)",
        diagnostic.suggestion.?,
    );
}

test "A3: a read on a value that may be undefined is refused as ZTS309" {
    try expectAbsentReadCases(&absent_read_refused);
}

test "A3: a guarded, narrowed, or unchecked-by-design read is still accepted" {
    try expectAbsentReadCases(&absent_read_accepted);
}

test "A3: a member or index read on a Dict is refused as ZTS201 and dictGet is accepted" {
    try expectAbsentReadCases(&absent_read_dict);
}

test "A3: one ZTS309 for each read, with its own line and column" {
    const source =
        \\structural P = { age: number };
        \\function handler(req: Request): Response {
        \\  const ps: P[] = [];
        \\  const a = ps[0].age + ps[1].age;
        \\  const b = ps[2].age;
        \\  return Response.json({ a: a, b: b });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "absent-count.ts", .{ .json_mode = true });
    defer result.deinit(std.testing.allocator);
    var lines: [8]u32 = undefined;
    var columns: [8]u32 = undefined;
    var count: usize = 0;
    for (result.json_diagnostics.items) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.code, "ZTS309")) continue;
        lines[count] = diagnostic.line;
        columns[count] = diagnostic.column;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualSlices(u32, &.{ 4, 4, 5 }, lines[0..count]);
    try std.testing.expectEqualSlices(u32, &.{ 18, 30, 18 }, columns[0..count]);
}

const absent_read_string_index = [_]AbsentReadCase{
    .{ .name = "q2_string_index_then_method", .expect = "ZTS201@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s: string = "ab";
    \\  const c: string = s[0];
    \\  return Response.text(c.toUpperCase());
    \\}
    },
    .{ .name = "q7_string_or_array_index_then_method", .expect = "ZTS309@3", .source =
    \\function pick(x: string | string[]): string {
    \\  const c = x[0];
    \\  return c.toUpperCase();
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text(pick("ab"));
    \\}
    },
    .{ .name = "r33_string_index_then_member", .expect = "ZTS201@3", .source =
    \\function handler(req: Request): Response {
    \\  const s: string = "abc";
    \\  return Response.json({ a: s[5].length });
    \\}
    },
    .{ .name = "control_charat_and_length", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s: string = "ab";
    \\  return Response.text([s.charAt(0).toUpperCase(), String(s.length)].join(""));
    \\}
    },
};

test "string index: an index read on a string or on a string union is refused" {
    try expectAbsentReadCases(&absent_read_string_index);
}

const absent_read_member_access = [_]AbsentReadCase{
    .{ .name = "q1_number_to_fixed", .expect = "ZTS201@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const n = 3;
    \\  if (n.toFixed(2) === "3.00") {
    \\    return Response.text("ok");
    \\  }
    \\  return Response.text("no");
    \\}
    },
    .{ .name = "q1_number_to_string", .expect = "ZTS201@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const n = 3;
    \\  return Response.text(n.toString());
    \\}
    },
    .{ .name = "q3_absent_value_from_dict_get", .expect = "ZTS309@5", .source =
    \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d = dictSet(dictEmpty(), "k", 5);
    \\  const v = dictGet(d, "k");
    \\  return Response.text(v.trim());
    \\}
    },
    .{ .name = "q8_union_record_and_string", .expect = "ZTS309@4", .source =
    \\structural P = { age: number };
    \\function show(x: P | string): string {
    \\  const a = x.age;
    \\  return a.toFixed(1);
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text("ok");
    \\}
    },
    .{ .name = "q11_call_through_a_member_a_union_member_lacks", .expect = "ZTS201@4", .source =
    \\structural A = { kind: "a"; f: (n: number) => number };
    \\structural B = { kind: "b"; g: number };
    \\function run(x: A | B): number {
    \\  return x.f(2);
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const b: B = { kind: "b", g: 1 };
    \\  return Response.text(String(run(b)));
    \\}
    },
    .{ .name = "control_string_array_and_record_function_members", .expect = "clean", .source =
    \\structural A = { f: (n: number) => number };
    \\function double(n: number): number {
    \\  return n * 2;
    \\}
    \\function run(r: A, xs: number[], s: string): string {
    \\  const n = r.f(2) + xs.length + s.length;
    \\  return s.toUpperCase();
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const a: A = { f: double };
    \\  return Response.text(run(a, [1, 2], "abc"));
    \\}
    },
};

test "member access: a member read or call on a value that cannot hold it is refused" {
    try expectAbsentReadCases(&absent_read_member_access);
}

const absent_read_dict_types = [_]AbsentReadCase{
    .{ .name = "q3_member_on_the_value_of_a_typed_dict_get", .expect = "ZTS309@4", .source =
    \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const v = dictGet(dictSet(dictEmpty(), "k", 5), "k");
    \\  return Response.text(v.trim());
    \\}
    },
    .{ .name = "q4_typed_dict_from_dict_set", .expect = "clean", .source =
    \\import { dictEmpty, dictSet, dictHas } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<string, number> = dictSet(dictEmpty(), "a", 1);
    \\  return Response.text(String(dictHas(d, "a")));
    \\}
    },
    .{ .name = "control_typed_dict_through_a_parameter", .expect = "clean", .source =
    \\import { dictEmpty, dictSet, dictGet, dictHas } from "zttp:collections";
    \\function count(d: Dict<string, number>): number {
    \\  const v = dictGet(d, "a");
    \\  return dictHas(d, "a") ? (v ?? 0) : 0;
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text(String(count(dictSet(dictEmpty(), "a", 1))));
    \\}
    },
};

test "dict types: a typed Dict reaches the exports and the unchecked read of its value is refused" {
    try expectAbsentReadCases(&absent_read_dict_types);
}

const absent_read_dict_callbacks = [_]AbsentReadCase{
    .{ .name = "k1b_fold_over_a_typed_dict_adds_the_values", .expect = "clean", .source =
    \\import { dictEmpty, dictSet, dictFold } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d = dictSet(dictSet(dictEmpty(), "a", 1), "b", 2);
    \\  const total = dictFold(d, (acc, value, key) => acc + value, 0);
    \\  return Response.text(String(total));
    \\}
    },
    .{ .name = "k1b_fold_over_a_dict_from_isdict_adds_unknown_values", .expect = "ZTS106@6,ZTS106@6", .source =
    \\import { dictFold } from "zttp:collections";
    \\function total(u: unknown): number {
    \\  if (!isDict(u)) {
    \\    return 0;
    \\  }
    \\  const sum = dictFold(u, (acc, value, key) => acc + value, 0);
    \\  return 1;
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text(String(total(req.url)));
    \\}
    },
};

test "dict callbacks: a fold over a typed Dict is clean and a fold over a Dict from isDict refuses an unknown value" {
    try expectAbsentReadCases(&absent_read_dict_callbacks);
}

const absent_read_result_error = [_]AbsentReadCase{
    .{ .name = "q9_error_of_validatejson_after_not_ok_may_be_undefined", .expect = "ZTS309@6", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = validateJson("todo", "{}");
    \\  if (!r.ok) {
    \\    return Response.text(String(r.error.length + 1));
    \\  }
    \\  return Response.text("ok");
    \\}
    },
    .{ .name = "q9_error_of_parsejson_after_not_ok_is_a_record", .expect = "clean", .source =
    \\import { parseJson } from "zttp:json";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = parseJson("{}");
    \\  if (!r.ok) {
    \\    return Response.text(String(r.error.kind));
    \\  }
    \\  return Response.text("ok");
    \\}
    },
    .{ .name = "q9_value_of_validatejson_after_ok_is_unchanged", .expect = "clean", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = validateJson("todo", "{}");
    \\  if (r.ok) {
    \\    return Response.text(String(r.value.title));
    \\  }
    \\  return Response.text("bad");
    \\}
    },
    .{ .name = "q9_error_of_a_mapped_validatejson_result_may_be_undefined", .expect = "ZTS309@8", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\import { mapResult } from "zttp:result";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = validateJson("todo", "{}");
    \\  const m = mapResult(r, (v) => 1);
    \\  if (!m.ok) {
    \\    return Response.text(String(m.error.length + 1));
    \\  }
    \\  return Response.text("ok");
    \\}
    },
    .{ .name = "q9_unchecked_error_read_reports_zts303_once", .expect = "ZTS303@5", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = validateJson("todo", "{}");
    \\  return Response.text(String(r.error.length));
    \\}
    },
    .{ .name = "q9_errors_read_after_not_ok_is_unchanged", .expect = "clean", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = validateJson("todo", "{}");
    \\  if (!r.ok) {
    \\    return Response.text(String(r.errors.length));
    \\  }
    \\  return Response.text("ok");
    \\}
    },
    .{ .name = "q9_guarded_error_read_is_clean", .expect = "clean", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = validateJson("todo", "{}");
    \\  if (!r.ok) {
    \\    const e = r.error;
    \\    if (e === undefined) {
    \\      return Response.text("invalid");
    \\    }
    \\    return Response.text(String(e.length));
    \\  }
    \\  return Response.text("ok");
    \\}
    },
};

test "result error: a read of an error that a schema failure leaves absent is refused once" {
    try expectAbsentReadCases(&absent_read_result_error);
}

const absent_read_result_value = [_]AbsentReadCase{
    .{ .name = "q18_value_that_admits_undefined_after_ok_may_be_undefined", .expect = "ZTS309@6", .source =
    \\import { ok } from "zttp:result";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = ok(req.headers.get("x-missing"));
    \\  let n = 0;
    \\  if (r.ok) {
    \\    n = r.value.length + 1;
    \\  }
    \\  return Response.text(String(n));
    \\}
    },
    .{ .name = "r4_number_value_after_ok_is_clean", .expect = "clean", .source =
    \\import { ok } from "zttp:result";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = ok(1);
    \\  let n = 0;
    \\  if (r.ok) {
    \\    n = r.value + 1;
    \\  }
    \\  return Response.text(String(n));
    \\}
    },
    .{ .name = "r4_string_value_after_ok_is_clean", .expect = "clean", .source =
    \\import { ok } from "zttp:result";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = ok("a");
    \\  let s = "";
    \\  if (r.ok) {
    \\    s = r.value.trim();
    \\  }
    \\  return Response.text(s);
    \\}
    },
    .{ .name = "r4_unchecked_value_keeps_zts303_only", .expect = "ZTS303@4", .source =
    \\import { ok } from "zttp:result";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = ok(req.headers.get("x"));
    \\  return Response.text(String(r.value.length));
    \\}
    },
};

test "result value: a read of a value that may be undefined after the ok check is refused once" {
    try expectAbsentReadCases(&absent_read_result_value);
}

const absent_read_untyped_operand = [_]AbsentReadCase{
    .{ .name = "u3_member_read_on_unknown_in_multiplication", .expect = "ZTS104@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const u: unknown = JSON.parse("{}");
    \\  const n = u.n * 2;
    \\  return Response.text(String(n));
    \\}
    },
    .{ .name = "u3_member_read_on_unknown_in_addition", .expect = "ZTS106@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const u: unknown = JSON.parse("{}");
    \\  const n = u.n + 1;
    \\  return Response.text(String(n));
    \\}
    },
    .{ .name = "u3_index_then_member_read_keeps_zts309", .expect = "ZTS309@4", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ps: P[] = [];
    \\  return Response.text(String(ps[0].age + 1));
    \\}
    },
    .{ .name = "u3_typed_operand_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s: string = req.url;
    \\  return Response.text(String(s.length + 1));
    \\}
    },
    .{ .name = "u3_published_let_example_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  let total = 0;
    \\  for (const n of [1, 2, 3]) {
    \\    total = total + n;
    \\  }
    \\  return Response.text(String(total));
    \\}
    },
    .{ .name = "u3_parenthesized_sum_of_an_optional_gets_one_diagnostic", .expect = "ZTS106@2", .source =
    \\function f(x: number | undefined): number {
    \\  return (x + 1) * 2;
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text(String(f(1)));
    \\}
    },
    .{ .name = "u3_error_of_validatejson_after_not_ok_keeps_zts309", .expect = "ZTS309@6", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = validateJson("todo", "{}");
    \\  if (!r.ok) {
    \\    return Response.text(String(r.error.length + 1));
    \\  }
    \\  return Response.text("ok");
    \\}
    },
    .{ .name = "u3_value_that_admits_undefined_after_ok_keeps_zts309", .expect = "ZTS309@6", .source =
    \\import { ok } from "zttp:result";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = ok(req.headers.get("x-missing"));
    \\  let n = 0;
    \\  if (r.ok) {
    \\    n = r.value.length + 1;
    \\  }
    \\  return Response.text(String(n));
    \\}
    },
    .{ .name = "u3_parameters_of_a_named_function_get_zts601_only", .expect = "ZTS601@1,ZTS600@5", .source =
    \\function add(a, b) {
    \\  return a + b;
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text(String(add(1, 2)));
    \\}
    },
    .{ .name = "u3_captured_parameter_of_a_named_function_gets_zts601_only", .expect = "ZTS601@1", .source =
    \\function mk(base) {
    \\  const g = (v: number): number => v + base;
    \\  return g;
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "u3_unannotated_anonymous_arrow_gets_the_untyped_operand_refusal", .expect = "ZTS106@1", .source =
    \\const handler = (req) => Response.text(String(req.url.length + 1));
    },
};

test "untyped operand: strict code refuses an arithmetic operand with no type and keeps the other diagnostics" {
    try expectAbsentReadCases(&absent_read_untyped_operand);
}

const container_writes = [_]AbsentReadCase{
    .{ .name = "w1_q17_record_field_write", .expect = "ZTS200@4", .source =
    \\structural P = { name: string };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const p: P = { name: "a" };
    \\  p.name = 5;
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_q19_record_string_key_write", .expect = "ZTS200@4", .source =
    \\structural P = { name: string };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const p: P = { name: "a" };
    \\  p["name"] = 5;
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_q20_nested_record_write", .expect = "ZTS200@5", .source =
    \\structural P = { name: string };
    \\structural Q = { a: P };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const q: Q = { a: { name: "x" } };
    \\  q.a.name = 7;
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_q16_array_push_wrong_element", .expect = "ZTS203@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const xs: number[] = [1];
    \\  xs.push("a");
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_q16_array_index_write_wrong_element", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const xs: number[] = [1];
    \\  xs[0] = "a";
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_q14_array_literal_binding_index_write", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ys = ["a", "b"];
    \\  ys[0] = 5;
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_tuple_literal_index_write", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const u: [string, number] = ["a", 1];
    \\  u[0] = 5;
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_tuple_dynamic_index_write", .expect = "ZTS200@4", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t: [string, string] = ["a", "b"];
    \\  const i: number = 1;
    \\  t[i] = true;
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_tuple_length_write", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t: [string, string] = ["a", "b"];
    \\  t.length = 0;
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_tuple_push", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t: [string, string] = ["a", "b"];
    \\  t.push("c");
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_tuple_pop", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t: [string, string] = ["a", "b"];
    \\  t.pop();
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_tuple_shift", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t: [string, string] = ["a", "b"];
    \\  t.shift();
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_tuple_unshift", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t: [string, string] = ["a", "b"];
    \\  t.unshift("c");
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_tuple_splice", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t: [string, string] = ["a", "b"];
    \\  t.splice(0, 1);
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_array_unshift_wrong_element", .expect = "ZTS203@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const xs: number[] = [1];
    \\  xs.unshift("a");
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_array_splice_wrong_inserted_element", .expect = "ZTS203@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const xs: number[] = [1];
    \\  xs.splice(0, 1, "a");
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_union_receiver_member_refuses_the_value", .expect = "ZTS200@5", .source =
    \\structural A = { v: number };
    \\structural B = { v: string };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ab: A | B = { v: 1 };
    \\  ab.v = 5;
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_declared_literal_field", .expect = "ZTS200@4", .source =
    \\structural S = { kind: "a" | "b" };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s: S = { kind: "a" };
    \\  s.kind = "c";
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_declared_literal_tuple_element", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const g: ["GET", number] = ["GET", 1];
    \\  g[0] = "POST";
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_unannotated_nested_array_write_wrong_type", .expect = "ZTS200@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const q = { a: { n: 0 }, xs: [1] };
    \\  q.a.n = "x";
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_array_push_to_empty_typed_array_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const xs: number[] = [];
    \\  xs.push(1);
    \\  return Response.text(String(xs.length));
    \\}
    },
    .{ .name = "w1_record_field_write_of_matching_type_is_clean", .expect = "clean", .source =
    \\structural P = { name: string };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const p: P = { name: "a" };
    \\  p.name = "b";
    \\  return Response.text(p.name);
    \\}
    },
    .{ .name = "w1_array_length_write_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const xs: number[] = [1, 2];
    \\  xs.length = 0;
    \\  return Response.text(String(xs.length));
    \\}
    },
    .{ .name = "w1_counter_idiom_on_unannotated_object_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const o = { n: 0 };
    \\  o.n = 1;
    \\  return Response.text(String(o.n));
    \\}
    },
    .{ .name = "w1_unannotated_nested_writes_are_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const q = { a: { n: 0 }, xs: [1], t: ["x", 1] };
    \\  q.a.n = 2;
    \\  q.xs.push(3);
    \\  q.a = { n: 5 };
    \\  q.t[0] = "y";
    \\  return Response.text(String(q.a.n));
    \\}
    },
    .{ .name = "w1_collecting_into_empty_array_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const out = [];
    \\  for (const item of [1, 2]) {
    \\    out.push(item);
    \\  }
    \\  return Response.text(String(out.length));
    \\}
    },
    .{ .name = "w1_write_of_a_value_with_no_type_is_clean", .expect = "clean", .source =
    \\structural P = { name: string };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const p: P = { name: "a" };
    \\  p.name = [1, 2].reduce((acc, v) => acc, "");
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_splice_start_and_count_are_not_checked_against_the_element", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ws: string[] = ["a", "b"];
    \\  ws.splice(0, 1);
    \\  return Response.text(String(ws.length));
    \\}
    },
    .{ .name = "w1_readonly_array_push_reports_only_the_readonly_mutation", .expect = "ZTS215@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ro: readonly string[] = ["a"];
    \\  ro.push(5);
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_push_into_declared_literal_union_array", .expect = "ZTS203@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ms: ("a" | "b")[] = ["a"];
    \\  ms.push("c");
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "w1_write_of_literal_union_field_in_unannotated_object_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const o = { k: req.method === "GET" ? "a" : "b" };
    \\  o.k = "c";
    \\  return Response.text(o.k);
    \\}
    },
    .{ .name = "w1_write_of_record_element_in_unannotated_object_array_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const q = { xs: [{ n: 0 }] };
    \\  q.xs[0] = { n: 5 };
    \\  return Response.text(String(q.xs.length));
    \\}
    },
    .{ .name = "w1_tuple_reads_are_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t: [string, string] = ["a", "b"];
    \\  const m = t.map((x) => x);
    \\  const s = t.slice(0, 1);
    \\  return Response.text(String(t.length + m.length + s.length));
    \\}
    },
    .{ .name = "w1_mutation_and_write_on_a_fresh_array_literal_are_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const last = [1, 2].pop();
    \\  const n = ["a", 1].push(2);
    \\  [1, 2][0] = 5;
    \\  return Response.json({ last: last, n: n });
    \\}
    },
    .{ .name = "w1_write_into_an_unannotated_array_literal_binding_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ys = [{ n: 0 }];
    \\  ys[0] = { n: 5 };
    \\  return Response.text(String(ys.length));
    \\}
    },
    .{ .name = "w1_write_through_an_alias_of_an_unannotated_literal_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const table = { hits: 0 };
    \\  const t = table;
    \\  t.hits = 1;
    \\  return Response.text(String(table.hits));
    \\}
    },
    .{ .name = "w1_write_through_an_unannotated_alias_of_a_declared_record", .expect = "ZTS200@5", .source =
    \\structural S = { kind: "a" | "b" };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s: S = { kind: "a" };
    \\  const alias = s;
    \\  alias.kind = "c";
    \\  return Response.text(s.kind);
    \\}
    },
    .{ .name = "w1_write_into_an_unannotated_function_result", .expect = "ZTS200@5", .source =
    \\structural S = { kind: "a" | "b" };
    \\function mk(): S { return { kind: "a" }; }
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = mk();
    \\  r.kind = "c";
    \\  return Response.text(r.kind);
    \\}
    },
};

test "container writes: a write must fit the slot type, and a tuple keeps its length" {
    try expectAbsentReadCases(&container_writes);
}

const absent_read_untyped_receiver = [_]AbsentReadCase{
    .{ .name = "n1_accumulator_with_no_type_q12c", .expect = "ZTS201@2", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s = [1, 2].reduce((acc, v) => acc.toFixed(2), "");
    \\  return Response.text(String(s));
    \\}
    },
    .{ .name = "n1_loop_variable_over_numbers_keeps_its_zts201_q12d", .expect = "ZTS201@4", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  let out = "";
    \\  for (const s of [1, 2]) {
    \\    out = s.toUpperCase();
    \\  }
    \\  return Response.text(out);
    \\}
    },
    .{ .name = "n1_builtin_namespaces_and_request_headers_are_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const o = { a: 1 };
    \\  const m = Math.max(1, 2);
    \\  const j = JSON.stringify({ a: 1 });
    \\  const k = Object.keys(o).length;
    \\  const h = req.headers.get("x");
    \\  return Response.json({ m: m, j: j, k: k, h: h });
    \\}
    },
    .{ .name = "n1_empty_array_collecting_with_push_is_clean_fr1", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const out = [];
    \\  for (const item of [1, 2]) {
    \\    out.push(item);
    \\  }
    \\  return Response.text(String(out.length));
    \\}
    },
    .{ .name = "n1_index_then_member_call_keeps_zts309", .expect = "ZTS309@4,ZTS401@4,ZTS500@2", .source =
    \\structural P = { age: number };
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ps: P[] = [];
    \\  return Response.text(String(ps[0].age.toFixed(2)));
    \\}
    },
    .{ .name = "n1_error_of_validatejson_after_not_ok_keeps_zts309", .expect = "ZTS309@6,ZTS401@6,ZTS500@3", .source =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = validateJson("todo", "{}");
    \\  if (!r.ok) {
    \\    return Response.text(String(r.error.length.toFixed(2)));
    \\  }
    \\  return Response.text("ok");
    \\}
    },
    .{ .name = "n1_value_that_admits_undefined_after_ok_keeps_zts309", .expect = "ZTS309@6,ZTS401@8,ZTS500@2", .source =
    \\import { ok } from "zttp:result";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const r = ok(req.headers.get("x-missing"));
    \\  let n = "";
    \\  if (r.ok) {
    \\    n = String(r.value.length.toFixed(2));
    \\  }
    \\  return Response.text(n);
    \\}
    },
    .{ .name = "n1_parameter_of_a_named_function_gets_zts601_only", .expect = "ZTS601@1", .source =
    \\function f(a) {
    \\  return a.trim();
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text(req.url);
    \\}
    },
    .{ .name = "n1_captured_parameter_of_a_named_function_gets_zts601_only", .expect = "ZTS601@1", .source =
    \\function mk(base) {
    \\  const g = (v: string): string => base.trim();
    \\  return g;
    \\}
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "n1_unannotated_anonymous_arrow_gets_the_untyped_receiver_refusal_fr4", .expect = "ZTS201@1", .source =
    \\const handler = (req) => Response.text(req.url.trim());
    },
    .{ .name = "n1_member_of_parsed_json_is_refused", .expect = "ZTS201@2", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s = JSON.parse(req.url).name.trim();
    \\  return Response.text(s);
    \\}
    },
    .{ .name = "n1_array_literal_with_an_untyped_element_keeps_array_members", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s = req.headers["x-tag"] ?? "";
    \\  const ns = [s].map((x: unknown): number => String(x).length);
    \\  return Response.json({ n: ns.length });
    \\}
    },
    .{ .name = "n1_array_literal_with_an_untyped_element_refuses_a_string_callback", .expect = "ZTS203@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s = req.headers["x-tag"] ?? "";
    \\  const ns = [s].map((x: string): number => x.length);
    \\  return Response.json({ n: ns.length });
    \\}
    },
    .{ .name = "n1_array_literal_with_an_untyped_element_refuses_a_member_arrays_lack", .expect = "ZTS201@3", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const s = req.headers["x-tag"] ?? "";
    \\  const ns = [s].foo();
    \\  return Response.text("x");
    \\}
    },
    .{ .name = "n1_member_call_on_an_empty_array_literal_is_clean", .expect = "clean", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text(String([].pop()));
    \\}
    },
    .{ .name = "n1_range_has_no_array_members", .expect = "ZTS201@2", .source =
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const ns = range(3).map((x: number): number => x);
    \\  return Response.text("x");
    \\}
    },
};

test "untyped receiver: strict code refuses a member call on a value with no type and keeps the other diagnostics" {
    try expectAbsentReadCases(&absent_read_untyped_receiver);
}

const json_dict_key = [_]AbsentReadCase{
    .{ .name = "j1_number_and_string_keys_q10", .expect = "ZTS213@3", .source =
    \\import { dictEmpty, dictSet } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.json(dictSet(dictSet(dictEmpty(), 2, "x"), "k", 1));
    \\}
    },
    .{ .name = "j1_number_key_in_a_record_field", .expect = "ZTS213@4", .source =
    \\import { dictEmpty, dictSet } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<number, string> = dictSet(dictEmpty(), 1, "x");
    \\  return Response.json({ m: d });
    \\}
    },
    .{ .name = "j1_boolean_key_in_an_array", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const b: Dict<boolean, number> = dictEmpty();
    \\  return Response.json([b]);
    \\}
    },
    .{ .name = "j1_nominal_number_key", .expect = "ZTS213@5", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\nominal Port = number;
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const p: Dict<Port, string> = dictEmpty();
    \\  return Response.json(p);
    \\}
    },
    .{ .name = "j1_named_union_key_with_a_number", .expect = "ZTS213@5", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\structural Key = number | string;
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const k: Dict<Key, string> = dictEmpty();
    \\  return Response.json(k);
    \\}
    },
    .{ .name = "j1_null_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<null, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_undefined_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<undefined, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_number_literal_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<1, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_boolean_literal_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<true, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_array_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<string[], number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_tuple_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<[string], number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_bytes_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<Bytes, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_dict_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<Dict<string, string>, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_record_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<{ a: string }, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_function_alias_key", .expect = "ZTS213@5", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\structural Fn = (x: number) => number;
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<Fn, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_string_or_undefined_key", .expect = "ZTS213@4", .source =
    \\import { dictEmpty } from "zttp:collections";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<string | undefined, number> = dictEmpty();
    \\  return Response.json(d);
    \\}
    },
    .{ .name = "j1_string_literal_template_nominal_and_unknown_keys_are_clean", .expect = "clean", .source =
    \\import { dictEmpty, dictSet } from "zttp:collections";
    \\nominal UserId = string;
    \\structural Name = "a" | "b";
    \\function handler(req: Request): Proof<Response, "read_only"> {
    \\  const d: Dict<string, number> = dictSet(dictEmpty(), "a", 1);
    \\  const e: Dict<"a" | "b", number> = dictEmpty();
    \\  const n: Dict<Name, number> = dictEmpty();
    \\  const i: Dict<UserId, number> = dictEmpty();
    \\  const u: Dict<unknown, unknown> = dictEmpty();
    \\  const t: Dict<`/a/${string}`, number> = dictEmpty();
    \\  return Response.json({ d: d, e: e, n: n, i: i, u: u, t: t, z: dictEmpty() });
    \\}
    },
};

test "JSON payload: Response.json refuses a Dict whose key type admits a value that is not a string" {
    try expectAbsentReadCases(&json_dict_key);
}

const ObserverProbe = struct {
    calls: u32 = 0,
    verifier_count: usize = 0,
    flow_count: usize = 0,

    fn onChecked(context: *anyopaque, checked: check_run_mod.CheckedView) error{OutOfMemory}!void {
        const self: *ObserverProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.verifier_count = checked.verifier_diagnostics.len;
        self.flow_count = checked.flow_diagnostics.len;
    }
};

test "observer sees the verifier and flow diagnostics of a leaking handler once" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response { const s: string = env("SECRET_KEY") ?? ""; return Response.text(s); }
    ;
    var probe: ObserverProbe = .{};
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "leak.ts", .{
        .json_mode = true,
        .observer = .{ .context = &probe, .on_checked = ObserverProbe.onChecked },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.verifier_count);
    try std.testing.expectEqual(@as(usize, 1), probe.flow_count);
    try std.testing.expectEqual(@as(u32, 1), result.flow_errors + result.flow_warnings);
}

test "observer sees the ZTS310 warning of a write that only the flow evaluator found" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined { xs.push(1); return undefined; }
        \\function handler(req: Request): Proof<Response, "result_safe"> { addTo(seen); return Response.text("ok"); }
    ;
    var probe: ObserverProbe = .{};
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "write.ts", .{
        .json_mode = true,
        .observer = .{ .context = &probe, .on_checked = ObserverProbe.onChecked },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.verifier_count);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS310", result.json_diagnostics.items[0].code);
    try std.testing.expectEqual(@as(u32, 2), result.json_diagnostics.items[0].line);
}

test "observer is not called for a file with no handler" {
    const allocator = std.testing.allocator;
    var probe: ObserverProbe = .{};
    var result = try runCheckOnlyFromSourceWithOptions(allocator, "const x: number = 1;", "nohandler.ts", .{
        .json_mode = true,
        .observer = .{ .context = &probe, .on_checked = ObserverProbe.onChecked },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), probe.calls);
}

const result_head =
    \\import { parseJson } from "zttp:json";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = parseJson("1");
    \\
;

/// Run the check on `source` and return the first JSON diagnostic with `code`
/// after the check, and its atom table, has returned.
fn checkFirstWithCode(source: []const u8, code: []const u8, result: *CheckResult) !json_diag.JsonDiagnostic {
    result.* = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "shape.ts", .{
        .json_mode = true,
    });
    for (result.json_diagnostics.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, code)) return diagnostic;
    }
    return error.DiagnosticNotReported;
}

test "ZTS620 on a Result ok member is tagged unrecognized_guard with its subject" {
    var result: CheckResult = undefined;
    const diagnostic = try checkFirstWithCode(result_head ++
        \\  if (r.ok === true) {
        \\    return Response.text("a");
        \\  }
        \\  return Response.text("b");
        \\}
    , "ZTS620", &result);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(zts.ResultShape.unrecognized_guard, diagnostic.result_shape.?);
    try std.testing.expectEqualStrings("r", diagnostic.result_subject.?);
    try std.testing.expect(diagnostic.result_subject_owned);
}

test "ZTS201 on a Result member is tagged unknown_member and a plain record is not" {
    var result: CheckResult = undefined;
    const diagnostic = try checkFirstWithCode(result_head ++
        \\  const x = r.foo;
        \\  return Response.text("b");
        \\}
    , "ZTS201", &result);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(zts.ResultShape.unknown_member, diagnostic.result_shape.?);
    try std.testing.expectEqualStrings("r", diagnostic.result_subject.?);
    // The atom table is gone: the JSON line is the one the check wrote before the tags existed.
    var line: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();
    try json_diag.writeDiagnosticJson(&line.writer, &diagnostic);
    try std.testing.expectEqualStrings(
        "{\"code\":\"ZTS201\",\"severity\":\"error\",\"message\":\"property does not exist on type\",\"file\":\"shape.ts\",\"line\":5,\"column\":14,\"suggestion\":\"Read a property that the type declares, or add the property to the type.\",\"repair_intent\":null}",
        line.written(),
    );

    var plain: CheckResult = undefined;
    const plain_diagnostic = try checkFirstWithCode(
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const p = { a: 1 };
        \\  const x = p.foo;
        \\  return Response.text("b");
        \\}
    , "ZTS201", &plain);
    defer plain.deinit(std.testing.allocator);
    try std.testing.expect(plain_diagnostic.result_shape == null);
    try std.testing.expect(plain_diagnostic.result_subject == null);
    try std.testing.expect(!plain_diagnostic.result_subject_owned);
}

test "ZTS204 on a returned Result is tagged returned with its subject" {
    var result: CheckResult = undefined;
    const diagnostic = try checkFirstWithCode(result_head ++
        \\  return r;
        \\}
    , "ZTS204", &result);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(zts.ResultShape.returned, diagnostic.result_shape.?);
    try std.testing.expectEqualStrings("r", diagnostic.result_subject.?);
}

test "ZTS100 on an isOk call is tagged method_call with its subject" {
    var result: CheckResult = undefined;
    const diagnostic = try checkFirstWithCode(result_head ++
        \\  if (r.isOk()) {
        \\    return Response.text("a");
        \\  }
        \\  return Response.text("b");
        \\}
    , "ZTS100", &result);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(zts.ResultShape.method_call, diagnostic.result_shape.?);
    try std.testing.expectEqualStrings("r", diagnostic.result_subject.?);
}

// ---------------------------------------------------------------------------
// State isolation reaches every function of the program (G1b)
// ---------------------------------------------------------------------------

const helper_count_source =
    \\let count = 0;
    \\function bump(): number {
    \\  count = count + 1;
    \\  return count;
    \\}
    \\export function handler(req: Request): Proof<Response, "state_isolated"> {
    \\  return Response.text(String(bump()));
    \\}
;

test "check does not prove state isolation when a same-file helper mutates module state" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, helper_count_source, "helper-count.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expect(!result.state_isolated);
}

const StateIsolationCase = struct {
    name: []const u8,
    source: []const u8,
    state_isolated: bool,
};

test "state isolation across helper shapes" {
    const allocator = std.testing.allocator;
    const cases = [_]StateIsolationCase{
        .{ .name = "helper declared before the handler", .state_isolated = false, .source = helper_count_source },
        .{ .name = "helper declared after the handler", .state_isolated = false, .source =
        \\let count = 0;
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text("ok");
        \\}
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        },
        .{ .name = "top-level arrow", .state_isolated = false, .source =
        \\let count = 0;
        \\const bump = (): number => {
        \\  count = count + 1;
        \\  return count;
        \\};
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(bump()));
        \\}
        },
        .{ .name = "function in an object literal", .state_isolated = false, .source =
        \\let count = 0;
        \\const ops = {
        \\  bump: (): number => {
        \\    count = count + 1;
        \\    return count;
        \\  },
        \\};
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(ops.bump()));
        \\}
        },
        .{ .name = "function nested in a helper", .state_isolated = false, .source =
        \\let count = 0;
        \\function outer(): number {
        \\  const inner = (): number => {
        \\    count = count + 1;
        \\    return count;
        \\  };
        \\  return inner();
        \\}
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(outer()));
        \\}
        },
        .{ .name = "member write through an alias of a module object", .state_isolated = false, .source =
        \\const table = { hits: 0 };
        \\function touch(): number {
        \\  const t = table;
        \\  t.hits = 1;
        \\  return t.hits;
        \\}
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(touch()));
        \\}
        },
        .{ .name = "helper called only at module initialization", .state_isolated = false, .source =
        \\let count = 0;
        \\function seed(): number {
        \\  count = 5;
        \\  return count;
        \\}
        \\const start = seed();
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(start));
        \\}
        },
        .{ .name = "helper that writes only its own locals", .state_isolated = true, .source =
        \\const count = 0;
        \\function local(): number {
        \\  let n: number = 0;
        \\  n = n + 1;
        \\  return n;
        \\}
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(local() + count));
        \\}
        },
        .{ .name = "helper with a local that shadows a module name", .state_isolated = true, .source =
        \\const count = 0;
        \\function shadow(): number {
        \\  let count: number = 1;
        \\  count = count + 1;
        \\  return count;
        \\}
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(shadow()));
        \\}
        },
        .{ .name = "handler with a local that shadows a module name", .state_isolated = true, .source =
        \\const count = 0;
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  let count: number = 1;
        \\  count = count + 1;
        \\  return Response.text(String(count));
        \\}
        },
    };
    for (cases) |case| {
        errdefer std.debug.print("state isolation case failed: {s}\n", .{case.name});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "helper-case.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(case.state_isolated, result.state_isolated);
        const properties = (result.contract orelse return error.TestUnexpectedResult).properties orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.state_isolated, properties.state_isolated);
    }
}

test "a direct handler mutation is still the ZTS310 error" {
    const allocator = std.testing.allocator;
    const source =
        \\let count = 0;
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  count = count + 1;
        \\  return Response.text(String(count));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "direct-count.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expect(!result.state_isolated);
    try std.testing.expect(result.totalErrors() > 0);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("error", diagnostics[0].severity);
}

test "a helper mutation is a ZTS310 warning that names a helper and adds no error" {
    const allocator = std.testing.allocator;
    const source =
        \\let count = 0;
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text(String(bump()));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "helper-warning.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(!result.state_isolated);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("warning", diagnostics[0].severity);
    try std.testing.expectEqualStrings("helper function mutates module-scope variable (breaks cross-request isolation)", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].line);
}

test "check refuses a helper mutation only when the capsule demands state_isolated" {
    const allocator = std.testing.allocator;

    // The capsule names the property, so the check refuses.
    var demanded = try runCheckOnlyFromSourceWithOptions(allocator, helper_count_source, "helper-demanded.ts", .{ .json_mode = true });
    defer demanded.deinit(allocator);
    try std.testing.expect(!demanded.state_isolated);
    try std.testing.expectEqual(@as(u32, 1), demanded.totalErrors());
    try std.testing.expectEqual(@as(usize, 2), demanded.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS310", demanded.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("ZTS500", demanded.json_diagnostics.items[1].code);

    // No capsule: the default profile demands the property, so the check refuses.
    const bare_source =
        \\let count = 0;
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(bump()));
        \\}
    ;
    var bare = try runCheckOnlyFromSourceWithOptions(allocator, bare_source, "helper-bare.ts", .{ .json_mode = true });
    defer bare.deinit(allocator);
    try std.testing.expect(!bare.state_isolated);
    try std.testing.expectEqual(@as(u32, 4), bare.totalErrors());
    try std.testing.expectEqual(@as(usize, 5), bare.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS310", bare.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("ZTS500", bare.json_diagnostics.items[1].code);
    try std.testing.expectEqualStrings("ZTS606", bare.json_diagnostics.items[2].code);
    try std.testing.expectEqualStrings("helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: pure)", bare.json_diagnostics.items[2].message);
    try std.testing.expectEqualStrings("helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: read_only)", bare.json_diagnostics.items[3].message);
    try std.testing.expectEqualStrings("helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: deterministic)", bare.json_diagnostics.items[4].message);

    // A capsule that leaves the property out: the check passes with the warning only.
    const narrow_source =
        \\let count = 0;
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text(String(bump()));
        \\}
    ;
    var narrow = try runCheckOnlyFromSourceWithOptions(allocator, narrow_source, "helper-narrow.ts", .{ .json_mode = true });
    defer narrow.deinit(allocator);
    try std.testing.expect(!narrow.state_isolated);
    try std.testing.expectEqual(@as(u32, 0), narrow.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), narrow.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS310", narrow.json_diagnostics.items[0].code);
}

const clock_helper_default_suggestion =
    "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, " ++
    "but it does not hold: deterministic, idempotent, pure. Return a narrow Proof capsule with only the " ++
    "properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | " ++
    "\"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | " ++
    "\"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | " ++
    "\"injection_safe\" | \"canonical\" | \"cost_bounded\">`.";

const default_profile_zts500_message =
    "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold";

test "a clock helper under the default profile gets default-profile ZTS606 text next to the ZTS500 row" {
    const allocator = std.testing.allocator;
    const source =
        \\function stamp(): number {
        \\  return Date.now();
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(stamp()));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 3), result.totalErrors());
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try expectCompoundDiagnostic(diagnostics[0], .{
        .code = "ZTS500",
        .message = default_profile_zts500_message,
        .line = 5,
        .column = 24,
        .suggestion = clock_helper_default_suggestion,
    });
    try expectCompoundDiagnostic(diagnostics[1], .{
        .code = "ZTS606",
        .message = "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: pure)",
        .line = 1,
        .column = 1,
        .suggestion = "the handler returns no Proof<T, P> capsule, so the default profile demands `pure`, and `stamp` breaks it: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or make `stamp` hold `pure` and annotate it with `Proof<T, \"pure\">`.",
    });
    try expectCompoundDiagnostic(diagnostics[2], .{
        .code = "ZTS606",
        .message = "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: deterministic)",
        .line = 1,
        .column = 1,
        .suggestion = "the handler returns no Proof<T, P> capsule, so the default profile demands `deterministic`, and `stamp` breaks it: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or make `stamp` hold `deterministic` and annotate it with `Proof<T, \"deterministic\">`.",
    });
}

test "control: a clock helper under a declared deterministic capsule keeps the authored ZTS606 text" {
    const allocator = std.testing.allocator;
    const source =
        \\function stamp(): number {
        \\  return Date.now();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(stamp()));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[0].code);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[1].code);
    try std.testing.expectEqualStrings("helper breaks a handler-demanded property and carries no Proof<...> capsule (failing spec: deterministic)", diagnostics[1].message);
    try std.testing.expectEqualStrings("annotate `stamp` with `Proof<T, \"deterministic\">` and satisfy it, or inline the helper into the handler.", diagnostics[1].suggestion orelse "(null)");
}

test "a module write in a helper under the default profile gets the default-profile write text on each ZTS606 row" {
    const allocator = std.testing.allocator;
    const source =
        \\const store: number[] = [];
        \\
        \\function bump(): number {
        \\  store.push(1);
        \\  return store.length;
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(bump()));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4), result.totalErrors());
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 5), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings(default_profile_zts500_message, diagnostics[1].message);
    try expectCompoundDiagnostic(diagnostics[2], .{
        .code = "ZTS606",
        .message = "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: pure)",
        .line = 3,
        .column = 1,
        .suggestion = "the handler returns no Proof<T, P> capsule, so the default profile demands `pure`, and `bump` reaches a write to module state at line 4: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or copy the value into a local before the write.",
    });
    try expectCompoundDiagnostic(diagnostics[3], .{
        .code = "ZTS606",
        .message = "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: read_only)",
        .line = 3,
        .column = 1,
        .suggestion = "the handler returns no Proof<T, P> capsule, so the default profile demands `read_only`, and `bump` reaches a write to module state at line 4: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or copy the value into a local before the write.",
    });
    try expectCompoundDiagnostic(diagnostics[4], .{
        .code = "ZTS606",
        .message = "helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: deterministic)",
        .line = 3,
        .column = 1,
        .suggestion = "the handler returns no Proof<T, P> capsule, so the default profile demands `deterministic`, and `bump` reaches a write to module state at line 4: declare the narrow Proof<T, P> capsule that the handler's ZTS500 row suggests, or copy the value into a local before the write.",
    });
}

test "a clock helper whose value the handler drops keeps the default-profile ZTS500 row next to two ZTS606 rows" {
    const allocator = std.testing.allocator;
    const source =
        \\function stamp(): number {
        \\  return Date.now();
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  const t = stamp();
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 4), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS305", diagnostics[0].code);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings(default_profile_zts500_message, diagnostics[1].message);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[2].code);
    try std.testing.expectEqualStrings("helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: pure)", diagnostics[2].message);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[3].code);
    try std.testing.expectEqualStrings("helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: deterministic)", diagnostics[3].message);
}

const clock_helper_dropped_suggestion =
    "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, " ++
    "but it does not hold: pure. Return a narrow Proof capsule with only the properties it holds, e.g. " ++
    "`function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"idempotent\" | " ++
    "\"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | " ++
    "\"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | " ++
    "\"injection_safe\" | \"canonical\" | \"cost_bounded\">`.";

const clock_helper_dropped_source =
    \\function stamp(): number {
    \\  return Date.now();
    \\}
    \\
    \\export function handler(req: Request): Response {
    \\  const t = stamp();
    \\  return Response.text("ok");
    \\}
;

test "a clock helper whose value the handler drops gets a ZTS500 capsule that leaves out the property of each ZTS606 row" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, clock_helper_dropped_source, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 4), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS305", diagnostics[0].code);
    try expectCompoundDiagnostic(diagnostics[1], .{
        .code = "ZTS500",
        .message = default_profile_zts500_message,
        .line = 5,
        .column = 24,
        .suggestion = clock_helper_dropped_suggestion,
    });
    try std.testing.expectEqualStrings("ZTS606", diagnostics[2].code);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[3].code);
}

test "control: the capsule that the ZTS500 row suggests for a clock helper clears every spec diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\function stamp(): number {
        \\  return Date.now();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "fault_covered" | "stateless" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
        \\  const t = stamp();
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS305", diagnostics[0].code);
}

const shared_state_default_help =
    "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, " ++
    "but it does not hold: deterministic, idempotent, optional_safe, pure, read_only, result_safe, retry_safe, state_isolated, stateless. " ++
    "Return a narrow Proof capsule with only the properties it holds, e.g. " ++
    "`function handler(req: Request): Proof<Response, \"fault_covered\" | \"no_secret_leakage\" | \"no_credential_leakage\" | " ++
    "\"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`.";

const shared_state_default_help_line3 = shared_state_default_help ++
    " The write to module state at line 3 removes deterministic, idempotent, pure, read_only, retry_safe, state_isolated, stateless. " ++
    "To keep them, copy the value into a local before the write, or move the state to zttp:cache.";

fn expectSharedStateClearsProperties(result: *const CheckResult) !void {
    const props = result.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(!props.state_isolated);
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.retry_safe);
    try std.testing.expect(!props.deterministic);
    try std.testing.expect(!props.idempotent);
    try std.testing.expect(!props.pure);
    try std.testing.expect(!props.stateless);
}

test "a helper module write unproves a narrow capsule that claims the read-only family" {
    const allocator = std.testing.allocator;
    const source =
        \\const state: { n: number } = { n: 0 };
        \\function bump(): number {
        \\  state.n = state.n + 1;
        \\  return state.n;
        \\}
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "retry_safe" | "idempotent"> {
        \\  return Response.text(String(bump()));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "narrow-helper.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try expectSharedStateClearsProperties(&result);
    try std.testing.expectEqual(@as(u32, 6), result.totalErrors());
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 7), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("warning", diagnostics[0].severity);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("declared Proof capsule was not discharged by handler proof (failing spec: deterministic; demoted at line 3:11 by `a write to module state`)", diagnostics[1].message);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[2].code);
    try std.testing.expectEqualStrings("declared Proof capsule was not discharged by handler proof (failing spec: idempotent; demoted at line 3:11 by `a write to module state`)", diagnostics[2].message);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[3].code);
    try std.testing.expectEqualStrings("declared Proof capsule was not discharged by handler proof (failing spec: read_only; demoted at line 3:11 by `a write to module state`)", diagnostics[3].message);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[4].code);
    try std.testing.expectEqualStrings("declared Proof capsule was not discharged by handler proof (failing spec: retry_safe; demoted at line 3:11 by `a write to module state`)", diagnostics[4].message);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[5].code);
    try std.testing.expectEqualStrings("helper breaks a handler-demanded property and carries no Proof<...> capsule (failing spec: read_only)", diagnostics[5].message);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[6].code);
    try std.testing.expectEqualStrings("helper breaks a handler-demanded property and carries no Proof<...> capsule (failing spec: deterministic)", diagnostics[6].message);
}

test "a module let reassignment unproves the read-only family and the default help names none of it" {
    const allocator = std.testing.allocator;
    const source =
        \\let count: number = 0;
        \\function handler(req: Request): Response {
        \\  count = count + 1;
        \\  return Response.text(String(count));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "let-reassign.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try expectSharedStateClearsProperties(&result);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings(shared_state_default_help_line3, diagnostics[1].suggestion orelse return error.TestUnexpectedResult);
}

test "a module array push unproves the read-only family and the default help names none of it" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function handler(req: Request): Response {
        \\  seen.push(1);
        \\  return Response.text(String(seen.length));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "push.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try expectSharedStateClearsProperties(&result);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings(shared_state_default_help_line3, diagnostics[1].suggestion orelse return error.TestUnexpectedResult);
}

test "a read of a module array keeps the read-only family proven" {
    const allocator = std.testing.allocator;
    const source =
        \\const table: number[] = [1, 2];
        \\function handler(req: Request): Response {
        \\  return Response.text(String(table.length));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "read-table.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const props = result.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(props.state_isolated);
    try std.testing.expect(props.read_only);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(props.deterministic);
    try std.testing.expect(props.idempotent);
    try std.testing.expect(props.pure);
    try std.testing.expect(props.stateless);
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
}

fn expectReadOnlyFamilyUnproven(result: *const CheckResult) !void {
    const props = result.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(!props.state_isolated);
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.retry_safe);
    try std.testing.expect(!props.deterministic);
    try std.testing.expect(!props.idempotent);
    try std.testing.expect(!props.pure);
    try std.testing.expect(!props.stateless);
}

fn expectReadOnlyFamilyProven(result: *const CheckResult) !void {
    const props = result.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(props.state_isolated);
    try std.testing.expect(props.read_only);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(props.deterministic);
    try std.testing.expect(props.idempotent);
    try std.testing.expect(props.pure);
    try std.testing.expect(props.stateless);
}

test "a helper that pushes onto its parameter, called with a module array, unproves the read-only family" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\  addTo(seen);
        \\  return Response.text(String(seen.length));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "g1.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try expectReadOnlyFamilyUnproven(&result);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 5), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("warning", diagnostics[0].severity);
    try std.testing.expectEqualStrings("a request writes state that outlives it (breaks cross-request isolation)", diagnostics[0].message);
    try std.testing.expectEqualStrings("copy the value into a local before the write, or move the state to zttp:cache", diagnostics[0].suggestion orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].line);
    try std.testing.expectEqualStrings("g1.ts", diagnostics[0].file);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[2].code);
    try std.testing.expectEqualStrings("helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: pure)", diagnostics[2].message);
    try std.testing.expectEqualStrings("helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: read_only)", diagnostics[3].message);
    try std.testing.expectEqualStrings("helper breaks a property of the default proof profile and carries no Proof<...> capsule (failing spec: deterministic)", diagnostics[4].message);
    try std.testing.expectEqual(@as(u32, 1), result.verify_warnings);
}

test "a fresh factory array and a same-site factory row written by a request keep the read-only family proven" {
    const allocator = std.testing.allocator;
    const fresh =
        \\function fresh(): number[] {
        \\  return [];
        \\}
        \\function make(): number[] {
        \\  return fresh();
        \\}
        \\const table: number[] = make();
        \\function handler(req: Request): Response {
        \\  const local: number[] = make();
        \\  local.push(1);
        \\  return Response.text(String(local.length + table.length));
        \\}
    ;
    var p3 = try runCheckOnlyFromSourceWithOptions(allocator, fresh, "p3.ts", .{ .json_mode = true });
    defer p3.deinit(allocator);
    try expectReadOnlyFamilyProven(&p3);
    try std.testing.expectEqual(@as(usize, 0), p3.json_diagnostics.items.len);

    const same_site =
        \\structural Row = { n: number };
        \\function makeRow(): Row {
        \\  return { n: 0 };
        \\}
        \\function build(): Row {
        \\  return makeRow();
        \\}
        \\const shared: Row = build();
        \\function handler(req: Request): Response {
        \\  const mine: Row = build();
        \\  mine.n = mine.n + 1;
        \\  return Response.text(String(shared.n + mine.n));
        \\}
    ;
    var p9 = try runCheckOnlyFromSourceWithOptions(allocator, same_site, "p9.ts", .{ .json_mode = true });
    defer p9.deinit(allocator);
    try expectReadOnlyFamilyProven(&p9);
    try std.testing.expectEqual(@as(usize, 0), p9.json_diagnostics.items.len);
}

test "a dictGet on a module table keeps the read-only family proven" {
    const allocator = std.testing.allocator;
    const source =
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\const TABLE = dictSet(dictEmpty(), "a", 1);
        \\function handler(req: Request): Proof<Response, "state_isolated" | "read_only" | "retry_safe"> {
        \\  return Response.json({ value: dictGet(TABLE, "a") });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "dict-table.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const props = result.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(props.state_isolated);
    try std.testing.expect(props.read_only);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(props.deterministic);
    try std.testing.expect(props.idempotent);
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
}

// The write is `xs.push(1)` on line 3, whose call paren is at column 10.
const capsule_failure_pure = "helper's declared Proof capsule does not hold (failing spec: pure; demoted at line 3:10 by `a write to module state`)";
const capsule_failure_read_only = "helper's declared Proof capsule does not hold (failing spec: read_only; demoted at line 3:10 by `a write to module state`)";
// The write is `seen.push(1)` on line 3, whose call paren is at column 12.
const capsule_failure_pure_direct = "helper's declared Proof capsule does not hold (failing spec: pure; demoted at line 3:12 by `a write to module state`)";
const capsule_failure_read_only_direct = "helper's declared Proof capsule does not hold (failing spec: read_only; demoted at line 3:12 by `a write to module state`)";

test "a Proof capsule on a helper that pushes onto its parameter, called with a module array, fails ZTS500" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function bump(xs: number[]): Proof<number, "pure" | "read_only"> {
        \\  xs.push(1);
        \\  return xs.length;
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(bump(seen)));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-param.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("warning", diagnostics[0].severity);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].line);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("error", diagnostics[1].severity);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].line);
    try std.testing.expectEqualStrings(capsule_failure_pure, diagnostics[1].message);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[2].code);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[2].line);
    try std.testing.expectEqualStrings(capsule_failure_read_only, diagnostics[2].message);
}

test "a Proof capsule on a helper that pushes onto a module array fails ZTS500 when the handler calls it" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function bump(): Proof<number, "pure" | "read_only"> {
        \\  seen.push(1);
        \\  return seen.length;
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(bump()));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-direct.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].line);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("error", diagnostics[1].severity);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].line);
    try std.testing.expectEqualStrings(capsule_failure_pure_direct, diagnostics[1].message);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[2].code);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[2].line);
    try std.testing.expectEqualStrings(capsule_failure_read_only_direct, diagnostics[2].message);
}

test "a Proof capsule on a helper that pushes onto a module array fails ZTS500 when no handler calls it" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function bump(): Proof<number, "pure" | "read_only"> {
        \\  seen.push(1);
        \\  return seen.length;
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-unreached.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].line);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("error", diagnostics[1].severity);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].line);
    try std.testing.expectEqualStrings(capsule_failure_pure_direct, diagnostics[1].message);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[2].code);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[2].line);
    try std.testing.expectEqualStrings(capsule_failure_read_only_direct, diagnostics[2].message);
}

test "a Proof capsule on a helper that pushes onto a request-local array stays discharged" {
    const allocator = std.testing.allocator;
    const source =
        \\function bump(xs: number[]): Proof<number, "pure" | "read_only"> {
        \\  xs.push(1);
        \\  return xs.length;
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  const local: number[] = [];
        \\  return Response.text(String(bump(local)));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-local.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
}

test "a deterministic capsule on a helper that writes through a module array parameter fails ZTS500" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function bump(xs: number[]): Proof<number, "deterministic"> {
        \\  xs.push(1);
        \\  return xs.length;
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(bump(seen)));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-deterministic.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("error", diagnostics[1].severity);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].line);
    try std.testing.expectEqualStrings("helper's declared Proof capsule does not hold (failing spec: deterministic; demoted at line 3:10 by `a write to module state`)", diagnostics[1].message);
}

test "a capsule that calls a plain writer with a module array fails ZTS500" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function bump(xs: number[]): number {
        \\  xs.push(1);
        \\  return xs.length;
        \\}
        \\function outer(xs: number[]): Proof<number, "pure"> {
        \\  return bump(xs);
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(outer(seen)));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-outer.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].line);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqual(@as(u32, 6), diagnostics[1].line);
    try std.testing.expectEqualStrings("helper's declared Proof capsule does not hold (failing spec: pure; demoted at line 3:10 by `a write to module state`)", diagnostics[1].message);
}

test "a capsule called once with a local and once with a module array fails ZTS500" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function bump(xs: number[]): Proof<number, "pure" | "read_only"> {
        \\  xs.push(1);
        \\  return xs.length;
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  const local: number[] = [];
        \\  return Response.text(String(bump(local) + bump(seen)));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-union.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].line);
    try std.testing.expectEqualStrings(capsule_failure_pure, diagnostics[1].message);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[2].code);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[2].line);
    try std.testing.expectEqualStrings(capsule_failure_read_only, diagnostics[2].message);
}

test "a pure capsule on a factory helper keeps the factory shapes proven" {
    const allocator = std.testing.allocator;
    const fresh =
        \\function fresh(): Proof<number[], "pure"> {
        \\  return [];
        \\}
        \\function make(): Proof<number[], "pure"> {
        \\  return fresh();
        \\}
        \\const table: number[] = make();
        \\function handler(req: Request): Response {
        \\  const local: number[] = make();
        \\  local.push(1);
        \\  return Response.text(String(local.length + table.length));
        \\}
    ;
    var p3 = try runCheckOnlyFromSourceWithOptions(allocator, fresh, "capsule-p3.ts", .{ .json_mode = true });
    defer p3.deinit(allocator);
    try expectReadOnlyFamilyProven(&p3);
    try std.testing.expectEqual(@as(usize, 0), p3.json_diagnostics.items.len);

    const same_site =
        \\structural Row = { n: number };
        \\function makeRow(): Row {
        \\  return { n: 0 };
        \\}
        \\function build(): Row {
        \\  return makeRow();
        \\}
        \\function inc(r: Row): Proof<number, "pure"> {
        \\  r.n = r.n + 1;
        \\  return r.n;
        \\}
        \\const shared: Row = build();
        \\function handler(req: Request): Response {
        \\  const mine: Row = build();
        \\  return Response.text(String(shared.n + inc(mine)));
        \\}
    ;
    var p9 = try runCheckOnlyFromSourceWithOptions(allocator, same_site, "capsule-p9.ts", .{ .json_mode = true });
    defer p9.deinit(allocator);
    try expectReadOnlyFamilyProven(&p9);
    try std.testing.expectEqual(@as(usize, 0), p9.json_diagnostics.items.len);
}

test "a capsule that calls a plain module writer fails ZTS500 when no handler calls either" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function bump(): number {
        \\  seen.push(1);
        \\  return seen.length;
        \\}
        \\function outer(): Proof<number, "pure"> {
        \\  return bump();
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-unreached-outer.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].line);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqual(@as(u32, 6), diagnostics[1].line);
    try std.testing.expectEqualStrings(capsule_failure_pure_direct, diagnostics[1].message);
}

const write_remedy_line3 = "line 3 writes module state: copy the value into a local before the write, or move the state to zttp:cache.";

test "the deterministic ZTS500 of a helper write names the write line and the write remedy" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  addTo(seen);
        \\  return Response.text(String(seen.length));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "write-hint.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS310", diagnostics[0].code);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("declared Proof capsule was not discharged by handler proof (failing spec: deterministic; demoted at line 3:10 by `a write to module state`)", diagnostics[1].message);
    try std.testing.expectEqualStrings(write_remedy_line3, diagnostics[1].suggestion orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[2].code);
    try std.testing.expectEqualStrings("`addTo` reaches a write to module state at line 3: copy the value into a local before the write, or move the state to zttp:cache.", diagnostics[2].suggestion orelse return error.TestUnexpectedResult);
}

test "the deterministic ZTS500 keeps the Date.now() cause when a write also removed the property" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  addTo(seen);
        \\  return Response.text(String(seen.length + Date.now()));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "write-and-clock.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("declared Proof capsule was not discharged by handler proof (failing spec: deterministic; demoted at line 8:49 by `Date.now()`)", diagnostics[1].message);
    try std.testing.expectEqualStrings("remove Date.now(), Math.random(), and performance.now() from the response path.", diagnostics[1].suggestion orelse return error.TestUnexpectedResult);
}

test "the pure ZTS500 of a capsule helper names the write line and the write remedy" {
    const allocator = std.testing.allocator;
    const source =
        \\const seen: number[] = [];
        \\function bump(xs: number[]): Proof<number, "pure"> {
        \\  xs.push(1);
        \\  return xs.length;
        \\}
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(bump(seen)));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "capsule-write-hint.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[1].code);
    try std.testing.expectEqualStrings("helper's declared Proof capsule does not hold (failing spec: pure; demoted at line 3:10 by `a write to module state`)", diagnostics[1].message);
    try std.testing.expectEqualStrings(write_remedy_line3, diagnostics[1].suggestion orelse return error.TestUnexpectedResult);
}

test "the state_isolated ZTS500 of a direct handler write names the write line and the write remedy" {
    const allocator = std.testing.allocator;
    const source =
        \\let counter: number = 0;
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  counter = counter + 1;
        \\  return Response.text(String(counter));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "direct-write-hint.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    var found = false;
    for (result.json_diagnostics.items) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.code, "ZTS500")) continue;
        found = true;
        try std.testing.expectEqualStrings("declared Proof capsule was not discharged by handler proof (failing spec: state_isolated; demoted at line 3:11 by `a write to module state`)", diagnostic.message);
        try std.testing.expectEqualStrings(write_remedy_line3, diagnostic.suggestion orelse return error.TestUnexpectedResult);
    }
    try std.testing.expect(found);
}

test "a helper ZTS500 reports the helper's declaration line, not the handler's" {
    const allocator = std.testing.allocator;
    const source =
        \\function stamp(): Proof<number, "pure"> {
        \\  return Date.now();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  const t = stamp();
        \\  return Response.text(String(t));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "helper-site.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[0].code);
    try std.testing.expectEqualStrings("helper-site.ts", diagnostics[0].file);
    try std.testing.expectEqual(@as(u32, 1), diagnostics[0].line);
    try std.testing.expectEqual(@as(u16, 1), diagnostics[0].column);
    try std.testing.expectEqualStrings(
        "helper's declared Proof capsule does not hold (failing spec: pure)",
        diagnostics[0].message,
    );
}

test "formatProofCard: a helper ZTS500 line names the helper's declaration line" {
    const allocator = std.testing.allocator;
    const source =
        \\function stamp(): Proof<number, "pure"> {
        \\  return Date.now();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  const t = stamp();
        \\  return Response.text(String(t));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "helper-card.ts", .{});
    defer result.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    check_mod.formatFailureSections(&aw.writer, &result, "helper-card.ts");
    buf = aw.toArrayList();

    const start = std.mem.indexOf(u8, buf.items, "\n  Spec diagnostics:\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "\n  Spec diagnostics:\n" ++
            "    ZTS500 (error) helper-card.ts:1:1  helper's declared Proof capsule does not hold (failing spec: pure)\n" ++
            "      help: remove module calls and clock or RNG reads so the helper stays pure.\n",
        buf.items[start..],
    );
}

test "an arrow helper ZTS500 reports the helper's declaration line" {
    const allocator = std.testing.allocator;
    const source =
        \\const stamp = (): Proof<number, "pure"> => {
        \\  return Date.now();
        \\};
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  const t = stamp();
        \\  return Response.text(String(t));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "arrow-helper-site.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[0].code);
    try std.testing.expectEqualStrings("arrow-helper-site.ts", diagnostics[0].file);
    try std.testing.expectEqual(@as(u32, 1), diagnostics[0].line);
    try std.testing.expectEqual(@as(u16, 1), diagnostics[0].column);
    try std.testing.expectEqualStrings(
        "helper's declared Proof capsule does not hold (failing spec: pure)",
        diagnostics[0].message,
    );
}

test "an arrow helper with a true Proof capsule gives no diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\const double = (x: number): Proof<number, "pure" | "total"> => x * 2;
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  const t = double(21);
        \\  return Response.text(String(t));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "arrow-helper-true.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
}

test "an arrow helper that reaches a capability outside its Effects ceiling gives ZTS503" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\const digest = (): Effects<string, "clock"> => {
        \\  return sha256("a");
        \\};
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  const d = digest();
        \\  return Response.text(d);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "arrow-helper-effects.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS623", diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].line);
    try std.testing.expectEqualStrings("ZTS503", diagnostics[1].code);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[1].line);
    try std.testing.expectEqualStrings("ZTS505", diagnostics[2].code);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[2].line);
}

test "a handler ZTS500 keeps the handler's line" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ at: Date.now() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler-site.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[0].code);
    try std.testing.expectEqualStrings("handler-site.ts", diagnostics[0].file);
    try std.testing.expectEqual(@as(u32, 1), diagnostics[0].line);
    try std.testing.expectEqualStrings(
        "declared Proof capsule was not discharged by handler proof (failing spec: deterministic; demoted at line 2:34 by `Date.now()`)",
        diagnostics[0].message,
    );
}

test "a ZTS606 row reports the helper's declaration line" {
    const allocator = std.testing.allocator;
    const source =
        \\// Proves: a helper that breaks a property the handler demands, with no capsule of its own, is refused (ZTS606).
        \\function stamp(): string {
        \\    return String(Date.now());
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\    return Response.text(stamp());
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "missing-site.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const diagnostics = result.json_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS500", diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 6), diagnostics[0].line);
    try std.testing.expectEqualStrings("ZTS606", diagnostics[1].code);
    try std.testing.expectEqualStrings("missing-site.ts", diagnostics[1].file);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].line);
    try std.testing.expectEqual(@as(u16, 1), diagnostics[1].column);
}

// ---------------------------------------------------------------------------
// Dependency helper capsules: a helper in an imported module is held to the
// `Proof<...>` and `Effects<...>` that it declares (capsules U3).
// ---------------------------------------------------------------------------

const capsule_stamp_handler =
    \\import { stamp } from "./dep.ts";
    \\
    \\export function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t = stamp();
    \\  return Response.text(String(t));
    \\}
    \\
;

/// The first finding with `code` in a file whose path ends with `file_suffix`.
fn findingInFile(result: *const CheckResult, code: []const u8, file_suffix: []const u8) ?json_diag.JsonDiagnostic {
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code) and std.mem.endsWith(u8, d.file, file_suffix)) return d;
    }
    return null;
}

test "CHECK refuses a false Proof capsule on a helper of an imported module" {
    var fixture = try SiblingFixture.init(capsule_stamp_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function stamp(): Proof<number, "pure"> {
        \\  return Date.now();
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const allocator = std.testing.allocator;
    const directory = std.fs.path.dirname(fixture.handler_path) orelse return error.TestUnexpectedResult;
    const expected_file = try std.fs.path.join(allocator, &.{ directory, "dep.ts" });
    defer allocator.free(expected_file);

    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const row = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS500", row.code);
    try std.testing.expectEqualStrings("error", row.severity);
    try std.testing.expectEqualStrings(expected_file, row.file);
    try std.testing.expectEqual(@as(u32, 1), row.line);
    try std.testing.expectEqual(@as(u16, 8), row.column);
    try std.testing.expectEqualStrings(
        "helper's declared Proof capsule does not hold (failing spec: pure)",
        row.message,
    );
    const contract = result.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), contract.spec_diagnostics.items.len);
    try std.testing.expectEqualStrings("stamp", contract.spec_diagnostics.items[0].function orelse return error.TestUnexpectedResult);
}

// ---------------------------------------------------------------------------
// The write in an imported file that breaks the handler's capsule (dependency
// write causes U2).
// ---------------------------------------------------------------------------

fn siblingFilePath(fixture: *const SiblingFixture, name: []const u8) ![]u8 {
    const directory = std.fs.path.dirname(fixture.handler_path) orelse return error.TestUnexpectedResult;
    return std.fs.path.join(std.testing.allocator, &.{ directory, name });
}

const remember_handler =
    \\import { remember } from "./dep.ts";
    \\
    \\export function handler(req: Request): Proof<Response, "read_only"> {
    \\  const n = remember(1);
    \\  return Response.text(String(n));
    \\}
    \\
;

const remember_dep =
    \\const seen: number[] = [];
    \\
    \\export function remember(x: number): number {
    \\  seen.push(x);
    \\  return x;
    \\}
    \\
;

test "CHECK names the write in an imported file as the cause of a failing read_only capsule" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(remember_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts", remember_dep);

    var result = try fixture.check();
    defer result.deinit(allocator);
    const dep_path = try siblingFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);

    const write = diagnosticWithCode(&result, "ZTS310") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(dep_path, write.file);
    try std.testing.expectEqual(@as(u32, 4), write.line);
    try std.testing.expectEqual(@as(u16, 12), write.column);

    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    const message = try std.fmt.allocPrint(
        allocator,
        "declared Proof capsule was not discharged by handler proof (failing spec: read_only; demoted at {s}:4:12 by `a write to module state`)",
        .{dep_path},
    );
    defer allocator.free(message);
    try std.testing.expectEqualStrings(message, row.message);
    const suggestion = try std.fmt.allocPrint(
        allocator,
        "`{s}` line 4 writes module state, and a module-state write in any imported file removes `read_only`: remove every write to module state that a ZTS310 row names, or remove `read_only` from the capsule.",
        .{dep_path},
    );
    defer allocator.free(suggestion);
    try std.testing.expectEqualStrings(suggestion, row.suggestion orelse return error.TestUnexpectedResult);
}

test "CHECK names the uncalled writer of a dependency as the cause of a failing deterministic capsule" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { tally } from "./a.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { bump } from "./b.ts";
        \\
        \\export function tally(): number {
        \\  return bump();
        \\}
        \\
    );
    try fixture.add("b.ts", cross_writer_b);

    var result = try fixture.check();
    defer result.deinit(allocator);
    const dep_path = try siblingFilePath(&fixture, "b.ts");
    defer allocator.free(dep_path);

    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    const message = try std.fmt.allocPrint(
        allocator,
        "declared Proof capsule was not discharged by handler proof (failing spec: deterministic; demoted at {s}:4:9 by `a write to module state`)",
        .{dep_path},
    );
    defer allocator.free(message);
    try std.testing.expectEqualStrings(message, row.message);
    const suggestion = try std.fmt.allocPrint(
        allocator,
        "`{s}` line 4 writes module state, and a module-state write in any imported file removes `deterministic`: remove every write to module state that a ZTS310 row names, or remove `deterministic` from the capsule.",
        .{dep_path},
    );
    defer allocator.free(suggestion);
    try std.testing.expectEqualStrings(suggestion, row.suggestion orelse return error.TestUnexpectedResult);
}

const bump_default_handler =
    \\import { bump } from "./dep.ts";
    \\
    \\export function handler(req: Request): Response {
    \\  return Response.text(String(bump()));
    \\}
    \\
;

test "CHECK names the write of a dependency in the default-profile suggestion" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(bump_default_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts", cross_writer_b);

    var result = try fixture.check();
    defer result.deinit(allocator);
    const dep_path = try siblingFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);

    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    const ending = try std.fmt.allocPrint(
        allocator,
        " The write to module state at `{s}` line 4 removes deterministic, idempotent, read_only, retry_safe, state_isolated, stateless. To keep them, remove every write to module state that a ZTS310 row names.",
        .{dep_path},
    );
    defer allocator.free(ending);
    try std.testing.expect(std.mem.endsWith(u8, row.suggestion orelse return error.TestUnexpectedResult, ending));
}

test "CHECK names the entry write when the entry and a dependency both write module state" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { bump } from "./dep.ts";
        \\let hits = 0;
        \\function mark(): number {
        \\  hits = hits + 1;
        \\  return hits;
        \\}
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(mark() + bump()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", cross_writer_b);

    var result = try fixture.check();
    defer result.deinit(allocator);
    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "declared Proof capsule was not discharged by handler proof (failing spec: read_only; demoted at line 4:8 by `a write to module state`)",
        row.message,
    );
    try std.testing.expectEqualStrings(
        "line 4 writes module state: copy the value into a local before the write, or move the state to zttp:cache.",
        row.suggestion orelse return error.TestUnexpectedResult,
    );
}

test "CHECK names the write of the dependency that runs first" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { bumpA } from "./a.ts";
        \\import { bumpB } from "./b.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(bumpA() + bumpB()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { base } from "./b.ts";
        \\let hitsA = 0;
        \\export function bumpA(): number {
        \\  hitsA = hitsA + 1;
        \\  return hitsA + base();
        \\}
        \\
    );
    try fixture.add("b.ts",
        \\let hitsB = 0;
        \\
        \\export function base(): number {
        \\  return 1;
        \\}
        \\
        \\export function bumpB(): number {
        \\  hitsB = hitsB + 1;
        \\  return hitsB;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(allocator);
    const dep_path = try siblingFilePath(&fixture, "b.ts");
    defer allocator.free(dep_path);

    // Each write has its ZTS310 row, which the remedy points to.
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticsWithCode(&result, "ZTS310"));
    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    const suggestion = try std.fmt.allocPrint(
        allocator,
        "`{s}` line 8 writes module state, and a module-state write in any imported file removes `read_only`: remove every write to module state that a ZTS310 row names, or remove `read_only` from the capsule.",
        .{dep_path},
    );
    defer allocator.free(suggestion);
    try std.testing.expectEqualStrings(suggestion, row.suggestion orelse return error.TestUnexpectedResult);
}

test "CHECK names the earlier of two writes in one imported file" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { first, second } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(second() + first()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\let hits = 0;
        \\
        \\export function first(): number {
        \\  hits = hits + 1;
        \\  return hits;
        \\}
        \\
        \\export function second(): number {
        \\  hits = hits + 2;
        \\  return hits;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(allocator);
    const dep_path = try siblingFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);

    try std.testing.expectEqual(@as(usize, 2), countDiagnosticsWithCode(&result, "ZTS310"));
    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    const message = try std.fmt.allocPrint(
        allocator,
        "declared Proof capsule was not discharged by handler proof (failing spec: read_only; demoted at {s}:4:8 by `a write to module state`)",
        .{dep_path},
    );
    defer allocator.free(message);
    try std.testing.expectEqualStrings(message, row.message);
}

test "CHECK names the flow-only write of a dependency that comes before a verifier write" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { record } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(record()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\let count = 0;
        \\export function record(): number {
        \\  addTo(seen);
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(allocator);
    const dep_path = try siblingFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);

    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    const suggestion = try std.fmt.allocPrint(
        allocator,
        "`{s}` line 3 writes module state, and a module-state write in any imported file removes `read_only`: remove every write to module state that a ZTS310 row names, or remove `read_only` from the capsule.",
        .{dep_path},
    );
    defer allocator.free(suggestion);
    try std.testing.expectEqualStrings(suggestion, row.suggestion orelse return error.TestUnexpectedResult);
}

const cache_and_count_dep =
    \\import { cacheSet } from "zttp:cache";
    \\let count = 0;
    \\export function save(): number {
    \\  cacheSet("items", "key", "value");
    \\  count = count + 1;
    \\  return count;
    \\}
    \\
;

test "CHECK names the write of a dependency for deterministic when the dependency also writes the cache" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { save } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(String(save()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", cache_and_count_dep);

    var result = try fixture.check();
    defer result.deinit(allocator);
    const dep_path = try siblingFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);
    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    const suggestion = try std.fmt.allocPrint(
        allocator,
        "`{s}` line 5 writes module state, and a module-state write in any imported file removes `deterministic`: remove every write to module state that a ZTS310 row names, or remove `deterministic` from the capsule.",
        .{dep_path},
    );
    defer allocator.free(suggestion);
    try std.testing.expectEqualStrings(suggestion, row.suggestion orelse return error.TestUnexpectedResult);
}

test "CHECK reports the import conflict and no write cause for read_only when a dependency writes the cache" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { save } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(save()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", cache_and_count_dep);

    var result = try fixture.check();
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticsWithCode(&result, "ZTS500"));
    const row = findingInFile(&result, "ZTS501", "/handler.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "drop `read_only` from your proof-property set, or remove the zttp:cache import from this handler.",
        row.suggestion orelse return error.TestUnexpectedResult,
    );
}

test "CHECK leaves a property that a dependency removes out of the write sentence of the default profile" {
    const allocator = std.testing.allocator;
    var fixture = try SiblingFixture.init(
        \\import { bump } from "./dep.ts";
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(bump()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { cacheSet } from "zttp:cache";
        \\let count = 0;
        \\export function save(): undefined {
        \\  cacheSet("items", "key", "value");
        \\  return undefined;
        \\}
        \\export function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(allocator);
    const dep_path = try siblingFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);
    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    const ending = try std.fmt.allocPrint(
        allocator,
        " The write to module state at `{s}` line 8 removes deterministic, state_isolated. To keep them, remove every write to module state that a ZTS310 row names.",
        .{dep_path},
    );
    defer allocator.free(ending);
    try std.testing.expect(std.mem.endsWith(u8, row.suggestion orelse return error.TestUnexpectedResult, ending));
}

test "CHECK keeps the one-file texts for a write in the handler file" {
    const allocator = std.testing.allocator;
    var read_only = try checkOneFile(
        \\const seen: number[] = [];
        \\
        \\function remember(x: number): number {
        \\  seen.push(x);
        \\  return x;
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  const n = remember(1);
        \\  return Response.text(String(n));
        \\}
        \\
    );
    defer read_only.deinit(allocator);
    const read_only_row = diagnosticWithCode(&read_only, "ZTS500") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "declared Proof capsule was not discharged by handler proof (failing spec: read_only; demoted at line 4:12 by `a write to module state`)",
        read_only_row.message,
    );
    try std.testing.expectEqualStrings(
        "line 4 writes module state: copy the value into a local before the write, or move the state to zttp:cache.",
        read_only_row.suggestion orelse return error.TestUnexpectedResult,
    );

    var default_profile = try checkOneFile(
        \\let count = 0;
        \\
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(bump()));
        \\}
        \\
    );
    defer default_profile.deinit(allocator);
    const default_row = diagnosticWithCode(&default_profile, "ZTS500") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(
        u8,
        default_row.suggestion orelse return error.TestUnexpectedResult,
        " The write to module state at line 4 removes deterministic, idempotent, pure, read_only, retry_safe, state_isolated, stateless. To keep them, copy the value into a local before the write, or move the state to zttp:cache.",
    ));
}

fn checkOneFile(source: []const u8) !CheckResult {
    var fixture = try SiblingFixture.init(source);
    defer fixture.deinit();
    return fixture.check();
}

test "CHECK refuses an Effects ceiling that a dependency helper breaks and warns on one it never reaches" {
    var fixture = try SiblingFixture.init(
        \\import { digest } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(digest());
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { sha256 } from "zttp:crypto";
        \\
        \\export function digest(): Effects<string, "clock"> {
        \\  return sha256("a");
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const breach = findingInFile(&result, "ZTS503", "/dep.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error", breach.severity);
    try std.testing.expectEqual(@as(u32, 3), breach.line);
    const over = findingInFile(&result, "ZTS505", "/dep.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("warning", over.severity);
    try std.testing.expectEqual(@as(u32, 3), over.line);
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticsWithCode(&result, "ZTS611"));
}

test "CHECK refuses a false Proof capsule on an arrow helper of an imported module" {
    var fixture = try SiblingFixture.init(capsule_stamp_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\const clock = (): Proof<number, "pure"> => {
        \\  return Date.now();
        \\};
        \\
        \\export function stamp(): number {
        \\  return clock();
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/dep.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), row.line);
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticsWithCode(&result, "ZTS500"));
}

test "CHECK refuses a false Proof capsule on a dependency helper that no module calls" {
    var fixture = try SiblingFixture.init(
        \\import { one } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(one()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function unused(): Proof<number, "pure"> {
        \\  return Date.now();
        \\}
        \\
        \\export function one(): number {
        \\  return 1;
        \\}
        \\
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/dep.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), row.line);
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticsWithCode(&result, "ZTS500"));
}

test "CHECK names the module-state write behind a false capsule on a dependency helper" {
    var fixture = try SiblingFixture.init(
        \\import { bump } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(bump()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\let count: number = 0;
        \\
        \\export function bump(): Proof<number, "pure"> {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/dep.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), row.line);
    try std.testing.expectEqualStrings(
        "helper's declared Proof capsule does not hold (failing spec: pure; demoted at line 4:9 by `a write to module state`)",
        row.message,
    );
}

test "CHECK refuses a read_only capsule on a dependency helper whose write only the flow evaluator finds" {
    var fixture = try SiblingFixture.init(
        \\import { run } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(run()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\const seen: number[] = [];
        \\
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\
        \\function record(): Proof<number, "read_only"> {
        \\  addTo(seen);
        \\  return 1;
        \\}
        \\
        \\export function run(): number {
        \\  return record();
        \\}
        \\
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/dep.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 8), row.line);
}

test "CHECK accepts a true Proof capsule on a dependency helper" {
    var fixture = try SiblingFixture.init(
        \\import { double } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(double(2)));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function double(x: number): Proof<number, "pure" | "total"> {
        \\  return x * 2;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.contract.?.spec_diagnostics.items.len);
}

const capsule_through_handler =
    \\import { viaB } from "./a.ts";
    \\
    \\export function handler(req: Request): Proof<Response, "read_only"> {
    \\  return Response.text(String(viaB()));
    \\}
    \\
;

const capsule_b_pure =
    \\export function one(): number {
    \\  return 1;
    \\}
    \\
;

test "CHECK composes a dependency helper capsule through a third file" {
    var fixture = try SiblingFixture.init(capsule_through_handler);
    defer fixture.deinit();
    try fixture.add("b.ts", capsule_b_pure);
    try fixture.add("a.ts",
        \\import { one } from "./b.ts";
        \\
        \\export function viaB(): Proof<number, "read_only"> {
        \\  return one();
        \\}
        \\
    );
    var held = try fixture.check();
    defer held.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), held.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), held.contract.?.spec_diagnostics.items.len);

    try fixture.add("a.ts",
        \\import { one } from "./b.ts";
        \\
        \\export function viaB(): Proof<number, "pure"> {
        \\  return one();
        \\}
        \\
    );
    var refused = try fixture.check();
    defer refused.deinit(std.testing.allocator);
    const row = findingInFile(&refused, "ZTS500", "/a.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), row.line);
}

test "CHECK refuses deterministic on a dependency helper that calls a clock reader of a third file" {
    var fixture = try SiblingFixture.init(capsule_through_handler);
    defer fixture.deinit();
    try fixture.add("b.ts",
        \\export function one(): number {
        \\  return Date.now();
        \\}
        \\
    );
    try fixture.add("a.ts",
        \\import { one } from "./b.ts";
        \\
        \\export function viaB(): Proof<number, "deterministic"> {
        \\  return one();
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/a.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), row.line);
}

// ---------------------------------------------------------------------------
// A helper capsule over a module-state writer in another file (writers U2).
// ---------------------------------------------------------------------------

const cross_writer_b =
    \\let count = 0;
    \\
    \\export function bump(): number {
    \\  count = count + 1;
    \\  return count;
    \\}
    \\
;

const cross_writer_handler =
    \\import { bump } from "./b.ts";
    \\
    \\function tally(): Proof<number, "read_only"> {
    \\  return bump();
    \\}
    \\
    \\export function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  return Response.text("ok");
    \\}
    \\
;

const cross_writer_unused_import_handler =
    \\import { tally } from "./a.ts";
    \\
    \\export function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  return Response.text("ok");
    \\}
    \\
;

const cross_writer_suggestion =
    "`tally` reaches `bump` from `./b.ts`, which writes module state, so it cannot prove `read_only`: remove `read_only` from the capsule, or stop reaching `bump`.";

/// The finding at `index` has `code`, a file that ends with `file_suffix`, and
/// the position `line:column`.
fn expectFindingAt(result: *const CheckResult, index: usize, code: []const u8, file_suffix: []const u8, line: u32, column: u32) !void {
    try std.testing.expect(index < result.json_diagnostics.items.len);
    const row = result.json_diagnostics.items[index];
    try std.testing.expectEqualStrings(code, row.code);
    try std.testing.expect(std.mem.endsWith(u8, row.file, file_suffix));
    try std.testing.expectEqual(line, row.line);
    try std.testing.expectEqual(column, row.column);
}

test "CHECK refuses read_only on a helper that calls a module-state writer of an imported file" {
    var fixture = try SiblingFixture.init(cross_writer_handler);
    defer fixture.deinit();
    try fixture.add("b.ts", cross_writer_b);

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.json_diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticsWithCode(&result, "ZTS310"));
    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error", row.severity);
    try std.testing.expectEqual(@as(u32, 3), row.line);
    try std.testing.expectEqual(@as(u32, 1), row.column);
    try std.testing.expectEqualStrings(
        "helper's declared Proof capsule does not hold (failing spec: read_only)",
        row.message,
    );
    try std.testing.expectEqualStrings(cross_writer_suggestion, row.suggestion orelse return error.TestUnexpectedResult);
}

test "CHECK keeps the handler verdicts when a helper over a module-state writer fails read_only" {
    var fixture = try SiblingFixture.init(cross_writer_handler);
    defer fixture.deinit();
    try fixture.add("b.ts", cross_writer_b);

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const contract = result.contract orelse return error.TestUnexpectedResult;
    try std.testing.expect(contract.properties.?.injection_safe);
    try std.testing.expectEqual(@as(usize, 1), contract.spec_diagnostics.items.len);
    try std.testing.expectEqualStrings("tally", contract.spec_diagnostics.items[0].function orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("read_only", contract.spec_diagnostics.items[0].spec_name);
}

test "CHECK refuses read_only on a dependency helper that calls a module-state writer of a third file" {
    var fixture = try SiblingFixture.init(cross_writer_unused_import_handler);
    defer fixture.deinit();
    try fixture.add("b.ts", cross_writer_b);
    try fixture.add("a.ts",
        \\import { bump } from "./b.ts";
        \\
        \\export function tally(): Proof<number, "read_only"> {
        \\  return bump();
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/a.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), row.line);
    try std.testing.expectEqual(@as(u32, 8), row.column);
    try std.testing.expectEqualStrings(cross_writer_suggestion, row.suggestion orelse return error.TestUnexpectedResult);
}

test "CHECK refuses read_only on a helper that calls an inline arrow writer held by an imported object" {
    var fixture = try SiblingFixture.init(
        \\import { api } from "./b.ts";
        \\
        \\function tally(): Proof<number, "read_only"> {
        \\  return api.bump();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("b.ts",
        \\let count = 0;
        \\
        \\export const api = { bump: (): number => { count = count + 1; return count; } };
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), row.line);
    try std.testing.expectEqual(@as(u32, 1), row.column);
}

test "CHECK refuses read_only on a helper that calls a named writer through an imported holder" {
    var fixture = try SiblingFixture.init(
        \\import { api } from "./b.ts";
        \\
        \\function tally(): Proof<number, "read_only"> {
        \\  return api.bump();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("b.ts",
        \\let count = 0;
        \\
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
        \\export const api = { bump: bump };
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/handler.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), row.line);
    try std.testing.expectEqual(@as(u32, 1), row.column);
}

test "CHECK refuses read_only on a helper over a relay export over a writer of a third file" {
    var fixture = try SiblingFixture.init(cross_writer_unused_import_handler);
    defer fixture.deinit();
    try fixture.add("c.ts", cross_writer_b);
    try fixture.add("b.ts",
        \\import { bump } from "./c.ts";
        \\
        \\export function relay(): number {
        \\  return bump();
        \\}
        \\
    );
    try fixture.add("a.ts",
        \\import { relay } from "./b.ts";
        \\
        \\export function tally(): Proof<number, "read_only"> {
        \\  return relay();
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const row = findingInFile(&result, "ZTS500", "/a.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), row.line);
    try std.testing.expectEqual(@as(u32, 8), row.column);
}

test "CHECK keeps read_only on a helper over a clean export of a module that also holds a writer" {
    var fixture = try SiblingFixture.init(
        \\import { peek } from "./b.ts";
        \\
        \\function tally(): Proof<number, "read_only"> {
        \\  return peek();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text(String(tally()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("b.ts",
        \\let count = 0;
        \\
        \\export function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
        \\export function peek(): number {
        \\  return 1;
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticsWithCode(&result, "ZTS500"));
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.contract.?.spec_diagnostics.items.len);
}

test "CHECK pins the findings of an uncapsuled helper over an imported writer under a read_only handler" {
    var called = try SiblingFixture.init(
        \\import { bump } from "./b.ts";
        \\
        \\function tally(): number {
        \\  return bump();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  const n = tally();
        \\  return Response.text(String(n));
        \\}
        \\
    );
    defer called.deinit();
    try called.add("b.ts", cross_writer_b);
    var called_result = try called.check();
    defer called_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), called_result.json_diagnostics.items.len);
    try expectFindingAt(&called_result, 0, "ZTS310", "/b.ts", 4, 9);
    try expectFindingAt(&called_result, 1, "ZTS500", "/handler.ts", 7, 24);
    try expectFindingAt(&called_result, 2, "ZTS606", "/handler.ts", 3, 1);

    var uncalled = try SiblingFixture.init(
        \\import { bump } from "./b.ts";
        \\
        \\function tally(): number {
        \\  return bump();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer uncalled.deinit();
    try uncalled.add("b.ts", cross_writer_b);
    var uncalled_result = try uncalled.check();
    defer uncalled_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), uncalled_result.json_diagnostics.items.len);
    try expectFindingAt(&uncalled_result, 0, "ZTS310", "/b.ts", 4, 9);
    try expectFindingAt(&uncalled_result, 1, "ZTS500", "/handler.ts", 7, 24);
}

test "CHECK warns on an Effects capability that a dependency helper never reaches" {
    var fixture = try SiblingFixture.init(
        \\import { label } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(label());
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function label(): Effects<string, "clock"> {
        \\  return "x";
        \\}
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    const row = findingInFile(&result, "ZTS505", "/dep.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("warning", row.severity);
    try std.testing.expectEqual(@as(u32, 1), row.line);
}
