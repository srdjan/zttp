const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");

const name = "workspace_gen_tests";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "gen tests",
    .effect = .write_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description =
    \\Generate a JSONL test suite from the handler's compiler-proven behavioral
    \\paths and write it alongside the handler (e.g. handler.test.jsonl). Each
    \\proven execution path becomes one test case: a synthesized request, ordered
    \\I/O stubs, and expected response status. Call this after editing a handler
    \\to keep the test suite in sync with the implementation. The generated file
    \\is immediately runnable via `zig build run -- handler.ts --test file.jsonl`.
    ,
    .input_schema =
    \\{"type":"object","properties":{"handler_path":{"type":"string","description":"Path to the handler file"},"output_path":{"type":"string","description":"Path for the JSONL output. Defaults to the handler stem + .test.jsonl in the same directory."}},"required":["handler_path"]}
    ,
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolArgsJson;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{}) catch {
        return error.InvalidToolArgsJson;
    };
    if (parsed != .object) return error.InvalidToolArgsJson;
    const obj = parsed.object;

    const handler_val = obj.get("handler_path") orelse return error.InvalidToolArgsJson;
    if (handler_val != .string) return error.InvalidToolArgsJson;

    if (obj.get("output_path")) |output_val| {
        if (output_val != .string) return error.InvalidToolArgsJson;
        const out = try allocator.alloc([]const u8, 2);
        out[0] = handler_val.string;
        out[1] = output_val.string;
        return out;
    }
    return registry_mod.helpers.singleArg(allocator, handler_val.string);
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) return registry_mod.ToolResult.err(allocator, name ++ ": requires handler_path\n");

    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, args[0]);
    defer allocator.free(absolute);
    const relative = common.relativeToRoot(root, absolute);

    const has_explicit_output = args.len > 1 and args[1].len > 0;
    var output_abs_owned: ?[]u8 = null;
    defer if (output_abs_owned) |p| allocator.free(p);
    var output_path_owned: ?[]u8 = null;
    defer if (output_path_owned) |p| allocator.free(p);

    const output_path: []const u8 = if (has_explicit_output) blk: {
        const output_abs = try common.resolveInsideWorkspace(allocator, root, args[1]);
        output_abs_owned = output_abs;
        break :blk common.relativeToRoot(root, output_abs);
    } else blk: {
        const ext = std.fs.path.extension(relative);
        const stem = relative[0 .. relative.len - ext.len];
        const owned = try allocator.print("{s}.test.jsonl", .{stem});
        output_path_owned = owned;
        break :blk owned;
    };

    const argv = [_][]const u8{ "zts", "gen-tests", relative, "-o", output_path };
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const count = zts_cli.precompile.runGenTests(allocator, relative, &buf.writer) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const message = try allocator.print("gen-tests failed: {s}\n", .{@errorName(err)});
            defer allocator.free(message);
            var outcome = try common.inProcessOutcome(allocator, 1, "", message);
            defer outcome.deinit(allocator);
            return try common.commandOutcomeToToolResult(allocator, &argv, &outcome);
        },
    };
    try zts.file_io.writeFile(allocator, output_path, buf.written());
    const message = try allocator.print("Wrote {d} test{s} to {s}\n", .{
        count,
        if (count == 1) @as([]const u8, "") else "s",
        output_path,
    });
    defer allocator.free(message);
    var outcome = try common.inProcessOutcome(allocator, 0, "", message);
    defer outcome.deinit(allocator);
    return try common.commandOutcomeToToolResult(allocator, &argv, &outcome);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tool description mentions behavioral paths" {
    try testing.expect(std.mem.indexOf(u8, tool.description, "behavioral") != null);
}

test "missing args returns not-ok" {
    var result = try execute(testing.allocator, &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "requires handler_path") != null);
}

test "out-of-workspace output_path is rejected" {
    try testing.expectError(
        error.PathOutsideWorkspace,
        execute(testing.allocator, &.{ "handler.ts", "/etc/evil.test.jsonl" }),
    );
    try testing.expectError(
        error.PathOutsideWorkspace,
        execute(testing.allocator, &.{ "handler.ts", "../../../../../../outside.test.jsonl" }),
    );
}

const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
const cwd_support = @import("../test_support/cwd.zig");

test "workspace_gen_tests writes the suite in a workspace that has no build.zig" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "gen-tests-inproc");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "handler.ts",
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ ok: true });
        \\}
        \\
    );

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var result = try execute(allocator, &.{"handler.ts"});
    defer result.deinit(allocator);
    try testing.expect(result.ok);

    const written = try zts.file_io.readFile(allocator, "handler.test.jsonl", 1024 * 1024);
    defer allocator.free(written);
    try testing.expect(written.len > 0);
}
