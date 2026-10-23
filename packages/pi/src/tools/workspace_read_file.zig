const std = @import("std");
const zts = @import("zts");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");
const json_writer = @import("../providers/json_writer.zig");
const cwd_support = @import("../test_support/cwd.zig");
const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;

const name = "workspace_read_file";
const default_page_bytes: usize = common.max_text_page_bytes;

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "read file",
    .effect = .read_workspace,
    .context_policy = .replayable_preview,
    .model_exposure = .visible,
    .description = "Read a bounded, replayable page of a workspace file. Continue with next_offset until complete.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"start_line\":{\"type\":\"integer\",\"minimum\":1},\"end_line\":{\"type\":\"integer\",\"minimum\":1},\"offset\":{\"type\":\"integer\",\"minimum\":0},\"max_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":6144}},\"required\":[\"path\"]}",
    .decode_json = registry_mod.helpers.decodeJsonPassthrough,
    .execute = execute,
};

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    var path_opt: ?[]const u8 = null;
    var start_line: usize = 1;
    var end_line: ?usize = null;
    var offset: usize = 0;
    var max_bytes: usize = default_page_bytes;
    // A JSON-derived path must outlive `parsed.deinit()` (it is used below for
    // resolveInsideWorkspace + the file read); the raw `args` slices are
    // caller-owned and outlive this call, so only the parsed value is duped.
    var owned_path: ?[]u8 = null;
    defer if (owned_path) |p| allocator.free(p);

    if (args.len > 0 and args[0].len > 0 and args[0][0] == '{') {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0], .{}) catch {
            return registry_mod.ToolResult.err(allocator, name ++ ": invalid JSON input\n");
        };
        defer parsed.deinit();
        if (parsed.value != .object) return registry_mod.ToolResult.err(allocator, name ++ ": expected JSON object\n");
        const obj = parsed.value.object;
        const path_val = obj.get("path") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing path\n");
        if (path_val != .string) return registry_mod.ToolResult.err(allocator, name ++ ": path must be a string\n");
        owned_path = try allocator.dupe(u8, path_val.string);
        path_opt = owned_path;
        if (obj.get("start_line")) |value| {
            if (value != .integer or value.integer <= 0) return registry_mod.ToolResult.err(allocator, name ++ ": start_line must be a positive integer\n");
            start_line = @intCast(value.integer);
        }
        if (obj.get("end_line")) |value| {
            if (value != .integer or value.integer <= 0) return registry_mod.ToolResult.err(allocator, name ++ ": end_line must be a positive integer\n");
            end_line = @intCast(value.integer);
        }
        if (obj.get("offset")) |value| {
            if (value != .integer or value.integer < 0) return registry_mod.ToolResult.err(allocator, name ++ ": offset must be a non-negative integer\n");
            offset = @intCast(value.integer);
        }
        if (obj.get("max_bytes")) |value| {
            if (value != .integer or value.integer <= 0 or value.integer > default_page_bytes) {
                return registry_mod.ToolResult.err(allocator, name ++ ": max_bytes must be between 1 and 6144\n");
            }
            max_bytes = @intCast(value.integer);
        }
    } else if (args.len > 0) {
        path_opt = args[0];
    } else {
        return registry_mod.ToolResult.err(allocator, name ++ ": missing path\n");
    }

    const path = path_opt.?;
    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, path);
    defer allocator.free(absolute);
    const relative = common.relativeToRoot(root, absolute);

    if (try ignoredRefusal(allocator, root, relative)) |refusal| {
        return .{ .ok = false, .llm_text = refusal };
    }

    const content = try zts.file_io.readFile(allocator, relative, common.default_output_limit);
    defer allocator.free(content);

    var line_no: usize = 1;
    var selected = std.ArrayList(u8).empty;
    defer selected.deinit(allocator);
    var wrote_any = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no < start_line) continue;
        if (end_line) |last| {
            if (line_no > last) break;
        }
        if (wrote_any) try selected.append(allocator, '\n');
        try selected.appendSlice(allocator, line);
        wrote_any = true;
    }

    return renderPage(
        allocator,
        relative,
        start_line,
        end_line,
        selected.items,
        offset,
        max_bytes,
    );
}

/// Return an owned refusal message when `relative` is a path the tool must not
/// read, or null when the read may proceed. The message never carries file
/// content.
///
/// The check runs `git check-ignore -v -- <relative>` in the workspace root.
/// Exit 0 means ignored and the tool refuses, naming the matching pattern and
/// its source. Exit 1 means not ignored and the tool reads. Any other result
/// (not a git repository, git missing, git failure) applies the fixed
/// basename deny list in `isSecretBasename`.
///
/// `common.runCommand` runs git with an empty environment and no HOME, so the
/// global git excludes file does not apply. A workspace nested inside a
/// parent repository that ignores it reads every file as ignored.
fn ignoredRefusal(
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
) !?[]u8 {
    const argv = [_][]const u8{ "git", "check-ignore", "-v", "--", relative };
    const maybe_outcome: ?common.CommandOutcome = common.runCommand(allocator, root, &argv) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (maybe_outcome) |outcome_value| {
        var outcome = outcome_value;
        defer outcome.deinit(allocator);
        if (outcome.exit_code) |code| {
            if (code == 1) return null;
            if (code == 0) {
                const line_end = std.mem.indexOfScalar(u8, outcome.stdout, '\n') orelse outcome.stdout.len;
                const line = outcome.stdout[0..line_end];
                const match = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len];
                return try allocator.print(name ++ ": path is ignored by git and is not readable (source:line:pattern {s})\n", .{match});
            }
        }
    }
    if (isSecretBasename(std.fs.path.basename(relative))) {
        return try allocator.dupe(u8, name ++ ": path matches the secret file deny list and is not readable\n");
    }
    return null;
}

/// Fixed deny list used when git cannot answer: `.env`, `.env.*`, `*.pem`,
/// `*.key`, `id_rsa*`, `id_ed25519*`.
fn isSecretBasename(base: []const u8) bool {
    return std.mem.eql(u8, base, ".env") or
        std.mem.startsWith(u8, base, ".env.") or
        std.mem.endsWith(u8, base, ".pem") or
        std.mem.endsWith(u8, base, ".key") or
        std.mem.startsWith(u8, base, "id_rsa") or
        std.mem.startsWith(u8, base, "id_ed25519");
}

/// Render the largest page at `offset` whose complete envelope stays inside
/// `max_projected_tool_result_bytes`. The envelope is measured rather than
/// bounded by the worst-case six-byte JSON expansion, because assuming that
/// expansion for ordinary source costs the model eight round trips per page.
fn renderPage(
    allocator: std.mem.Allocator,
    path: []const u8,
    start_line: usize,
    end_line: ?usize,
    selected: []const u8,
    offset: usize,
    max_bytes: usize,
) !registry_mod.ToolResult {
    const Context = struct {
        allocator: std.mem.Allocator,
        path: []const u8,
        start_line: usize,
        end_line: ?usize,
        selected: []const u8,
        offset: usize,

        fn render(self: @This(), budget: usize) !registry_mod.ToolResult {
            return renderPageWithin(
                self.allocator,
                self.path,
                self.start_line,
                self.end_line,
                self.selected,
                self.offset,
                budget,
            );
        }
    };
    return common.renderShrinkingPage(selected, offset, max_bytes, Context{
        .allocator = allocator,
        .path = path,
        .start_line = start_line,
        .end_line = end_line,
        .selected = selected,
        .offset = offset,
    }, Context.render);
}

fn renderPageWithin(
    allocator: std.mem.Allocator,
    path: []const u8,
    start_line: usize,
    end_line: ?usize,
    selected: []const u8,
    offset: usize,
    max_bytes: usize,
) !registry_mod.ToolResult {
    const page = common.textPage(selected, offset, max_bytes) catch |err| switch (err) {
        error.InvalidUtf8Text => return registry_mod.ToolResult.err(allocator, name ++ ": file content is not valid UTF-8\n"),
        error.InvalidTextOffset => return registry_mod.ToolResult.err(allocator, name ++ ": offset is not a valid content boundary\n"),
    };

    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    try w.writeAll("{\"ok\":true,\"path\":");
    try json_writer.writeString(w, path);
    try w.writeAll(",\"start_line\":");
    try w.print("{d}", .{start_line});
    try w.writeAll(",\"end_line\":");
    if (end_line) |last| {
        try w.print("{d}", .{last});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"offset\":");
    try w.print("{d}", .{offset});
    try w.writeAll(",\"page_end\":");
    try w.print("{d}", .{page.end});
    try w.writeAll(",\"total_bytes\":");
    try w.print("{d}", .{page.total_bytes});
    try w.writeAll(",\"omitted_before_bytes\":");
    try w.print("{d}", .{offset});
    try w.writeAll(",\"omitted_after_bytes\":");
    try w.print("{d}", .{page.total_bytes - page.end});
    try w.writeAll(",\"complete\":");
    try w.writeAll(if (page.complete()) "true" else "false");
    try w.writeAll(",\"next_offset\":");
    if (page.nextOffset()) |next| {
        try w.print("{d}", .{next});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"content\":");
    try json_writer.writeString(w, page.content);
    try w.writeAll("}\n");

    const llm_text = try text_buf.toOwnedSlice();
    errdefer allocator.free(llm_text);
    if (llm_text.len > common.max_projected_tool_result_bytes) {
        return error.ToolContextProjectionTooLarge;
    }
    return .{ .ok = true, .llm_text = llm_text };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "workspace_read_file: missing path arg returns structured error" {
    var result = try execute(testing.allocator, &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "missing path") != null);
}

test "workspace_read_file: malformed JSON args returns structured error" {
    var result = try execute(testing.allocator, &.{"{not json"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "invalid JSON input") != null);
}

test "workspace_read_file: JSON args without path returns structured error" {
    var result = try execute(testing.allocator, &.{"{\"start_line\":1}"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "missing path") != null);
}

test "workspace_read_file: negative start_line returns structured error" {
    var result = try execute(testing.allocator, &.{"{\"path\":\"x\",\"start_line\":-1}"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "start_line must be a positive integer") != null);
}

test "workspace_read_file: replayable pages reconstruct exact UTF-8 bytes" {
    const source = "alpha\nblåbær\nomega";
    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(testing.allocator);
    var offset: usize = 0;
    while (offset < source.len) {
        var result = try renderPage(testing.allocator, "handler.ts", 1, null, source, offset, 7);
        defer result.deinit(testing.allocator);
        try testing.expect(result.llm_text.len <= common.max_projected_tool_result_bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const content = obj.get("content").?.string;
        try rebuilt.appendSlice(testing.allocator, content);
        const next = obj.get("next_offset").?;
        if (next == .null) break;
        offset = @intCast(next.integer);
    }
    try testing.expectEqualStrings(source, rebuilt.items);
}

test "workspace_read_file: incomplete first page is explicit and valid JSON" {
    const source = "0123456789";
    var result = try renderPage(testing.allocator, "handler.ts", 1, null, source, 0, 4);
    defer result.deinit(testing.allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("complete").?.bool);
    try testing.expectEqual(@as(i64, 4), parsed.value.object.get("next_offset").?.integer);
    try testing.expectEqualStrings("0123", parsed.value.object.get("content").?.string);
}

test "workspace_read_file: ../ escape is rejected by resolveInsideWorkspace" {
    try testing.expectError(
        error.PathOutsideWorkspace,
        execute(testing.allocator, &.{"../../etc/passwd"}),
    );
}

test "workspace_read_file: missing too-large and empty files stay distinct" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "workspace-read-boundaries");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "empty.ts", "");
    const oversized = try allocator.alloc(u8, common.default_output_limit + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try tmp.writeFile(allocator, "oversized.ts", oversized);

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    try testing.expectError(error.FileNotFound, execute(allocator, &.{"missing.ts"}));
    try testing.expectError(error.FileTooBig, execute(allocator, &.{"oversized.ts"}));
    var empty = try execute(allocator, &.{"empty.ts"});
    defer empty.deinit(allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, empty.llm_text, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("complete").?.bool);
    try testing.expectEqualStrings("", parsed.value.object.get("content").?.string);
}

fn initGitWorkspace(allocator: std.mem.Allocator, tmp: *const IsolatedTmp) !void {
    const argv = [_][]const u8{ "git", "init", "-q" };
    var outcome = try common.runCommand(allocator, tmp.abs_path, &argv);
    defer outcome.deinit(allocator);
    try testing.expect(outcome.ok);
}

test "workspace_read_file: refuses a gitignored file without returning its content" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "workspace-read-ignored");
    defer tmp.cleanup(allocator);
    try initGitWorkspace(allocator, &tmp);
    try tmp.writeFile(allocator, ".gitignore", ".env\n");
    try tmp.writeFile(allocator, ".env", "API_KEY=hunter2\n");
    try tmp.writeFile(allocator, "notes.txt", "plain notes\n");

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var refused = try execute(allocator, &.{".env"});
    defer refused.deinit(allocator);
    try testing.expect(!refused.ok);
    try testing.expect(std.mem.indexOf(u8, refused.llm_text, "ignored by git") != null);
    try testing.expect(std.mem.indexOf(u8, refused.llm_text, ".gitignore:1:.env") != null);
    try testing.expect(std.mem.indexOf(u8, refused.llm_text, "hunter2") == null);

    var allowed = try execute(allocator, &.{"notes.txt"});
    defer allowed.deinit(allocator);
    try testing.expect(allowed.ok);
    try testing.expect(std.mem.indexOf(u8, allowed.llm_text, "plain notes") != null);
}

test "workspace_read_file: a non-git workspace applies the secret deny list" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "workspace-read-denylist");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, ".env", "API_KEY=hunter2\n");
    try tmp.writeFile(allocator, "config/server.pem", "PEM-BODY\n");
    try tmp.writeFile(allocator, "notes.txt", "plain notes\n");

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    inline for (.{ ".env", "config/server.pem" }) |denied| {
        var refused = try execute(allocator, &.{denied});
        defer refused.deinit(allocator);
        try testing.expect(!refused.ok);
        try testing.expect(std.mem.indexOf(u8, refused.llm_text, "deny list") != null);
        try testing.expect(std.mem.indexOf(u8, refused.llm_text, "hunter2") == null);
        try testing.expect(std.mem.indexOf(u8, refused.llm_text, "PEM-BODY") == null);
    }

    var allowed = try execute(allocator, &.{"notes.txt"});
    defer allowed.deinit(allocator);
    try testing.expect(allowed.ok);
}

test "workspace_read_file: deny list matches the documented basenames only" {
    try testing.expect(isSecretBasename(".env"));
    try testing.expect(isSecretBasename(".env.local"));
    try testing.expect(isSecretBasename("tls.pem"));
    try testing.expect(isSecretBasename("signing.key"));
    try testing.expect(isSecretBasename("id_rsa.pub"));
    try testing.expect(isSecretBasename("id_ed25519"));
    try testing.expect(!isSecretBasename("environment.ts"));
    try testing.expect(!isSecretBasename("keyboard.ts"));
    try testing.expect(!isSecretBasename("handler.ts"));
}
