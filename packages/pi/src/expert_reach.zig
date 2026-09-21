//! Absolute compiler and runtime acceptance for the bounded reach suite.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const corpus = @import("expert_reach_corpus.zig");
const report = @import("expert_reach_report.zig");
const codegen = @import("expert_codegen_eval.zig");
const identity = @import("expert_evidence_identity.zig");
const common = @import("tools/common.zig");
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;

pub const Evaluation = struct {
    compiler_ok: bool,
    properties_ok: bool,
    intent_passed: bool,
    compiler_output: []const u8,
    intent_stdout: []const u8,
    intent_stderr: []const u8,
};

/// Returned strings belong to allocator. Callers use a per-case arena.
pub fn evaluate(
    allocator: std.mem.Allocator,
    task: corpus.Task,
    workspace_abs: []const u8,
    zttp_bin: []const u8,
) !Evaluation {
    const handler_path = try common.resolveInsideWorkspace(allocator, workspace_abs, task.intent.handler_path);
    defer allocator.free(handler_path);
    var check = try zts_cli.precompile.runCheckOnlyWithOptions(allocator, handler_path, .{ .json_mode = true });
    defer check.deinit(allocator);
    const compiler_ok = check.totalErrors() == 0 and check.contract != null and check.verify_ran;
    var proven: [zts.HandlerProperties.max_proven_specs]?[]const u8 = @splat(null);
    const proven_count = if (check.properties) |properties| properties.provenSpecNames(&proven) else 0;
    var properties_ok = compiler_ok and task.required_properties.len > 0;
    for (task.required_properties) |required| {
        var found = false;
        for (proven[0..proven_count]) |name| {
            if (name) |value| if (std.mem.eql(u8, required, value)) {
                found = true;
                break;
            };
        }
        if (!found) properties_ok = false;
    }
    const compiler_output = try std.json.Stringify.valueAlloc(allocator, .{
        .total_errors = check.totalErrors(),
        .contract_present = check.contract != null,
        .verification_ran = check.verify_ran,
        .required_properties = task.required_properties,
        .proven_properties = proven[0..proven_count],
        .diagnostics = check.json_diagnostics.items,
    }, .{ .whitespace = .indent_2 });
    if (!compiler_ok or !properties_ok) return .{
        .compiler_ok = compiler_ok,
        .properties_ok = properties_ok,
        .intent_passed = false,
        .compiler_output = compiler_output,
        .intent_stdout = "",
        .intent_stderr = "Runtime acceptance was not run because compiler acceptance failed.",
    };
    var intent = codegen.runIntentCheckCaptured(allocator, task.intent, workspace_abs, zttp_bin);
    defer intent.deinit(allocator);
    return .{
        .compiler_ok = compiler_ok,
        .properties_ok = properties_ok,
        .intent_passed = intent.outcome == .passed,
        .compiler_output = compiler_output,
        .intent_stdout = try allocator.dupe(u8, intent.stdout),
        .intent_stderr = try allocator.dupe(u8, intent.stderr),
    };
}

pub fn writeFiles(allocator: std.mem.Allocator, workspace: []const u8, files: []const codegen.SeedFile) !void {
    var backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer backend.deinit();
    for (files) |file| {
        const path = try common.resolveInsideWorkspace(allocator, workspace, file.path);
        defer allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), backend.io(), parent);
        try zts.file_io.writeFile(allocator, path, file.bytes);
    }
}

pub fn digest(allocator: std.mem.Allocator, domain: []const u8, value: anytype) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    const hash = identity.contentDigest(domain, json);
    return allocator.dupe(u8, hash.slice());
}

/// A typed-hole seed must be provable but must not already satisfy the task.
pub fn admitSeed(allocator: std.mem.Allocator, task: corpus.Task, workspace: []const u8, zttp_bin: []const u8) !Evaluation {
    const evaluated = try evaluate(allocator, task, workspace, zttp_bin);
    if (!evaluated.compiler_ok or !evaluated.properties_ok) return error.ReachSeedRejected;
    if (evaluated.intent_passed) return error.ReachSeedAlreadySatisfiesTask;
    return evaluated;
}

/// All references are checked before even a one-task pilot may call a model.
/// Admission output stays outside every model-visible workspace.
pub fn admitReferences(
    allocator: std.mem.Allocator,
    zttp_bin: []const u8,
    output_root: []const u8,
) ![]const report.ExpectedCase {
    try corpus.validate();
    const descriptors = try allocator.alloc(report.ExpectedCase, corpus.tasks.len);
    errdefer allocator.free(descriptors);
    for (corpus.tasks, 0..) |task, index| {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const case_allocator = arena.allocator();
        var workspace = try IsolatedTmp.init(case_allocator, "reach-reference");
        defer workspace.cleanup(case_allocator);
        if (task.mode == .holes) {
            var seed_workspace = try IsolatedTmp.init(case_allocator, "reach-seed");
            defer seed_workspace.cleanup(case_allocator);
            try writeFiles(case_allocator, seed_workspace.abs_path, task.seed_files);
            const seed_evaluation = try admitSeed(case_allocator, task, seed_workspace.abs_path, zttp_bin);
            const seed_evidence = try std.json.Stringify.valueAlloc(case_allocator, seed_evaluation, .{ .whitespace = .indent_2 });
            const seed_output = try std.fmt.allocPrint(case_allocator, "seeds/{s}.json", .{task.id});
            try writeFiles(case_allocator, output_root, &.{.{ .path = seed_output, .bytes = seed_evidence }});
        }
        try writeFiles(case_allocator, workspace.abs_path, task.reference_files);
        const evaluation = try evaluate(case_allocator, task, workspace.abs_path, zttp_bin);
        const evidence = try std.json.Stringify.valueAlloc(case_allocator, evaluation, .{ .whitespace = .indent_2 });
        const path = try std.fmt.allocPrint(case_allocator, "references/{s}.json", .{task.id});
        try writeFiles(case_allocator, output_root, &.{.{ .path = path, .bytes = evidence }});
        if (!evaluation.compiler_ok or !evaluation.properties_ok or !evaluation.intent_passed) {
            std.debug.print("[reach] reference {s} failed; evidence at {s}/{s}\n{s}\n{s}\n{s}\n", .{
                task.id, output_root, path, evaluation.compiler_output, evaluation.intent_stdout, evaluation.intent_stderr,
            });
            return error.ReachReferenceRejected;
        }
        descriptors[index] = .{
            .id = task.id,
            .family = task.family,
            .mode = task.mode,
            .input_hash = try digest(allocator, "reach-input-v1", .{ .prompt = task.prompt, .mode = task.mode, .files = task.seed_files }),
            .reference_hash = try digest(allocator, "reach-reference-v1", task.reference_files),
            .intent_hash = try digest(allocator, "reach-acceptance-v1", .{ .intent = task.intent, .properties = task.required_properties }),
            .admission_hash = try digest(allocator, "reach-admission-v1", evaluation),
        };
    }
    return descriptors;
}

test "reach absolute acceptance refuses a missing handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = try IsolatedTmp.init(allocator, "reach-missing");
    defer tmp.cleanup(allocator);
    const outcome = try evaluate(allocator, corpus.tasks[0], tmp.abs_path, "/unused-zttp");
    try std.testing.expect(!outcome.compiler_ok);
    try std.testing.expect(!outcome.properties_ok);
    try std.testing.expect(!outcome.intent_passed);
}

test "reach acceptance refuses a property absent from a green contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = try IsolatedTmp.init(allocator, "reach-property");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "handler.ts", "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ ok: true }); }");
    var task = corpus.tasks[0];
    task.required_properties = &.{"post_only"};
    const outcome = try evaluate(allocator, task, tmp.abs_path, "/unused-zttp");
    try std.testing.expect(outcome.compiler_ok);
    try std.testing.expect(!outcome.properties_ok);
    try std.testing.expect(!outcome.intent_passed);
}

test "reach references satisfy the compiler and exact runtime acceptance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const repo = try @import("test_support/cwd.zig").cwdPathAlloc(allocator);
    const binary = codegen.locateZttpBinary(allocator, repo) orelse return error.ReachRuntimeBinaryMissing;
    var output = try IsolatedTmp.init(allocator, "reach-admission");
    defer output.cleanup(allocator);
    const admitted = try admitReferences(allocator, binary, output.abs_path);
    try std.testing.expectEqual(@as(usize, 8), admitted.len);
}

test "reach admission refuses a hole seed that already satisfies acceptance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const repo = try @import("test_support/cwd.zig").cwdPathAlloc(allocator);
    const binary = codegen.locateZttpBinary(allocator, repo) orelse return error.ReachRuntimeBinaryMissing;
    var workspace = try IsolatedTmp.init(allocator, "reach-vacuous-seed");
    defer workspace.cleanup(allocator);
    const task = corpus.tasks[1];
    const reference = task.reference_files[0].bytes;
    const body_start = (std.mem.indexOf(u8, reference, "{\n") orelse return error.MissingHandlerBody) + 2;
    const vacuous = try std.mem.concat(allocator, u8, &.{
        reference[0..body_start],
        "  if (req.method === \"OPTIONS\") { return hole(); }\n",
        reference[body_start..],
    });
    try workspace.writeFile(allocator, "handler.ts", vacuous);
    try std.testing.expectError(error.ReachSeedAlreadySatisfiesTask, admitSeed(allocator, task, workspace.abs_path, binary));
}

test "reach runtime acceptance rejects constant success in every family" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const repo = try @import("test_support/cwd.zig").cwdPathAlloc(allocator);
    const binary = codegen.locateZttpBinary(allocator, repo) orelse return error.ReachRuntimeBinaryMissing;
    var checked: usize = 0;
    for (corpus.tasks) |task| {
        if (task.mode != .whole_file) continue;
        var workspace = try IsolatedTmp.init(allocator, "reach-wrong-intent");
        defer workspace.cleanup(allocator);
        try writeFiles(allocator, workspace.abs_path, task.seed_files);
        try workspace.writeFile(allocator, "handler.ts", "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ ok: true }); }");
        const evaluated = try evaluate(allocator, task, workspace.abs_path, binary);
        try std.testing.expect(evaluated.compiler_ok);
        try std.testing.expect(evaluated.properties_ok);
        try std.testing.expect(!evaluated.intent_passed);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), checked);
}

comptime {
    _ = report;
    _ = corpus;
    // The runner selects work as `admitted[0..limit]`, and the only full-scope
    // limit it accepts is `report.full_task_count`. A corpus that stops having
    // exactly that many tasks either slices out of bounds, or silently measures
    // a prefix while still reporting scope `.full`. A validated report cannot
    // catch the second: its denominator is `full_task_count` by construction,
    // so the missing tasks never appear in `selected` to be counted.
    if (corpus.tasks.len != report.full_task_count) @compileError(
        "expert_reach_report.full_task_count must equal expert_reach_corpus.tasks.len",
    );
}
