const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");

const name = "zts_check";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "zts check",
    .effect = .execute_process,
    .context_policy = .structured_digest,
    .model_exposure = .local_only,
    .description =
    \\Run `zts check --json` for a handler path. On success the output
    \\includes a "proof.properties" object with compiler-proven behavioral
    \\and data-flow properties such as pure, read_only, stateless,
    \\retry_safe, deterministic, idempotent, injection_safe,
    \\state_isolated, fault_covered, result_safe, and related leakage /
    \\validation flags. Use this to inspect the current on-disk proof state
    \\of a file before editing. `propose_change_set` drafts are validated before
    \\they are written to disk, so use the compiler veto proof_card to
    \\validate post-edit properties instead.
    ,
    .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    return registry_mod.helpers.decodeSingleStringField(allocator, args_json, "path");
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) return registry_mod.ToolResult.err(allocator, name ++ ": requires a path\n");

    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, args[0]);
    defer allocator.free(absolute);
    const relative = common.relativeToRoot(root, absolute);

    const argv = [_][]const u8{ "zts", "check", relative, "--json" };
    var outcome = try common.checkJsonOutcome(allocator, absolute, relative);
    defer outcome.deinit(allocator);
    return try common.commandOutcomeToToolResult(allocator, &argv, &outcome);
}

const testing = std.testing;

test "tool description matches the current zts check properties contract" {
    try testing.expect(std.mem.indexOf(u8, tool.description, "pure") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "result_safe") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "current on-disk proof state") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "proof_card") != null);
}

const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
const cwd_support = @import("../test_support/cwd.zig");

test "zts_check runs in a workspace that has no build.zig" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "zts-check-inproc");
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
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"exit_code\":0") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "proof") != null);
}

test "zts_check reports a failing handler as not ok" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "zts-check-inproc-bad");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "handler.ts", "function handler(");

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var result = try execute(allocator, &.{"handler.ts"});
    defer result.deinit(allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"exit_code\":1") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "success") != null);
}
