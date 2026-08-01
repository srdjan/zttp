//! zts_expert_holes - report every `hole()` in a file, with the frame the
//! compiler already knows about each one.
//!
//! A hole is the compiler describing a program with one expression missing.
//! Filling it needs three facts: where the gap is, what type the expression
//! must produce, and what capability budget is still unspent. All three come
//! out of the contract already, and `zts_check` already carries them - buried
//! in a full proof envelope the agent has to search.
//!
//! Narrowing that to the gaps themselves is the point rather than a
//! convenience. A turn that regenerates a whole file emits from the model's
//! full distribution and lets the veto reject; a turn that fills one typed hole
//! in a known context is choosing one expression. The narrower the frame, the
//! smaller the emittable set - which is the mechanism, not a nicety.

const std = @import("std");
const zts = @import("zts");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");

const name = "zts_expert_holes";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "holes",
    .effect = .execute_process,
    .description =
    \\List every `hole()` in a handler with the frame around it: the
    \\enclosing function, the line and column, the type the expression
    \\must produce, and the capability budget the handler declared but
    \\has not yet spent.
    \\
    \\`hole()` is typed `never`, so a program with holes still type-checks
    \\and still proves its properties - the compiler describes the frame
    \\and only the expression is missing. Reaching one at runtime answers
    \\501, not 500.
    \\
    \\Fill one hole per turn, using the reported expected type and the
    \\remaining budget, rather than regenerating the file. An empty list
    \\means the program has no holes left.
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

    // Same command `zts_check` runs. Re-deriving the contract in-process would
    // be a second implementation of the thing being reported on, and the value
    // here is the projection, not the analysis.
    const argv = [_][]const u8{ "zig", "build", "cli", "--", "check", relative, "--json" };
    var outcome = try common.runCommand(allocator, root, &argv);
    defer outcome.deinit(allocator);

    const holes = extractHolesArray(outcome.stdout) orelse {
        // No envelope means the file did not get far enough to produce a
        // contract. Hand back what the command said rather than reporting
        // "no holes", which would read as a finished program.
        return try common.commandOutcomeToToolResult(allocator, &argv, &outcome);
    };

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try text.appendSlice(allocator, "{\"path\":\"");
    try text.appendSlice(allocator, relative);
    try text.appendSlice(allocator, "\",\"holes\":");
    try text.appendSlice(allocator, holes);
    try text.appendSlice(allocator, "}\n");

    return .{ .ok = true, .llm_text = try text.toOwnedSlice(allocator) };
}

/// Slice out the `"holes":[...]` array from a `zts check --json` envelope.
///
/// A brace/bracket scan rather than a JSON parse: the envelope is large, the
/// array is self-delimiting, and a parse would allocate the whole proof tree to
/// return one field. Returns null when the key is absent, which is how a run
/// that produced no contract is distinguished from one with no holes.
fn extractHolesArray(stdout: []const u8) ?[]const u8 {
    const key = "\"holes\":";
    const key_at = std.mem.indexOf(u8, stdout, key) orelse return null;
    const start = key_at + key.len;
    if (start >= stdout.len or stdout[start] != '[') return null;

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < stdout.len) : (i += 1) {
        const c = stdout[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return stdout[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

const testing = std.testing;

test "extractHolesArray slices the array out of a full envelope" {
    const envelope =
        \\{"success":true,"proof":{"properties":{},"holes":[{"function":"handler","line":5}]},"diagnostics":[]}
    ;
    const got = extractHolesArray(envelope).?;
    try testing.expectEqualStrings("[{\"function\":\"handler\",\"line\":5}]", got);
}

test "extractHolesArray handles an empty array and a bracket inside a string" {
    try testing.expectEqualStrings("[]", extractHolesArray("{\"holes\":[]}").?);
    const tricky =
        \\{"holes":[{"expectedType":"a]b"}]}
    ;
    try testing.expectEqualStrings("[{\"expectedType\":\"a]b\"}]", extractHolesArray(tricky).?);
}

test "extractHolesArray reports absence rather than emptiness" {
    // A run that produced no contract must not read as a program with no
    // holes; the caller falls back to the raw command output.
    try testing.expect(extractHolesArray("{\"success\":false}") == null);
}

test "tool description names the three facts a fill needs" {
    try testing.expect(std.mem.indexOf(u8, tool.description, "expected type") != null or
        std.mem.indexOf(u8, tool.description, "type the expression") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "budget") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "Fill one hole per turn") != null);
}
