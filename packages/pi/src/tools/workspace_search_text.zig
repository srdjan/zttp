const std = @import("std");
const zts = @import("zts");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");
const json_writer = @import("../providers/json_writer.zig");

const name = "workspace_search_text";
const max_search_matches: usize = 10_000;

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "search text",
    .effect = .execute_process,
    .context_policy = .replayable_preview,
    .model_exposure = .visible,
    .description = "Search a bounded page of path/line matches. Continue with next_offset until it is null; read the cited line for complete text. inventory_complete is false when the match inventory itself hit its ceiling, so narrow the query or path.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"maxLength\":512},\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\",\"minimum\":0},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":50}},\"required\":[\"query\"]}",
    .decode_json = registry_mod.helpers.decodeJsonPassthrough,
    .execute = execute,
};

/// Resolved invocation args. When the input is JSON, `query`/`path` point into
/// `owned_query`/`owned_path`, which the caller frees via `deinit`. When the
/// input is positional, they alias the caller-owned `args` slices and the owned
/// buffers are null. Either way the slices outlive the JSON parse tree.
const ParsedArgs = struct {
    query: []const u8,
    path: []const u8,
    limit: usize,
    offset: usize,
    owned_query: ?[]u8 = null,
    owned_path: ?[]u8 = null,

    fn deinit(self: *const ParsedArgs, allocator: std.mem.Allocator) void {
        if (self.owned_query) |q| allocator.free(q);
        if (self.owned_path) |p| allocator.free(p);
    }
};

const ParseResult = union(enum) {
    ok: ParsedArgs,
    /// A structured error to hand straight back to the caller (owns its text).
    err: registry_mod.ToolResult,
};

fn queryIsSingleLine(query: []const u8) bool {
    return std.mem.findAny(u8, query, "\n\x00") == null;
}

/// Parse and validate the tool input. JSON-derived strings are duped only after
/// every field validates, so no error path leaks an allocation, and the duped
/// query/path outlive `parsed.deinit()` (the use-after-free fixed in ae881b6).
fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParseResult {
    if (args.len > 0 and args[0].len > 0 and args[0][0] == '{') {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0], .{}) catch {
            return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": invalid JSON input\n") };
        };
        defer parsed.deinit();
        if (parsed.value != .object) return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": expected JSON object\n") };
        const obj = parsed.value.object;
        const query_val = obj.get("query") orelse return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": missing query\n") };
        if (query_val != .string) return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": query must be a string\n") };
        if (query_val.string.len > 512) return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": query must be at most 512 bytes\n") };
        if (!queryIsSingleLine(query_val.string)) return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": query must not contain a newline or NUL byte\n") };

        var path_str: ?[]const u8 = null;
        if (obj.get("path")) |value| {
            if (value != .string) return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": path must be a string\n") };
            path_str = value.string;
        }
        var limit: usize = 50;
        if (obj.get("limit")) |value| {
            if (value != .integer or value.integer <= 0 or value.integer > 50) return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": limit must be between 1 and 50\n") };
            limit = @intCast(value.integer);
        }
        var offset: usize = 0;
        if (obj.get("offset")) |value| {
            if (value != .integer or value.integer < 0) return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": offset must be a non-negative integer\n") };
            offset = @intCast(value.integer);
        }

        // Everything validated: dupe the strings out of the parse tree before it
        // is torn down on return.
        const owned_query = try allocator.dupe(u8, query_val.string);
        errdefer allocator.free(owned_query);
        const owned_path: ?[]u8 = if (path_str) |ps| try allocator.dupe(u8, ps) else null;

        return .{ .ok = .{
            .query = owned_query,
            .path = owned_path orelse ".",
            .limit = limit,
            .offset = offset,
            .owned_query = owned_query,
            .owned_path = owned_path,
        } };
    } else if (args.len > 0) {
        if (!queryIsSingleLine(args[0])) return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": query must not contain a newline or NUL byte\n") };
        return .{ .ok = .{
            .query = args[0],
            .path = if (args.len > 1) args[1] else ".",
            .limit = 50,
            .offset = 0,
        } };
    } else {
        return .{ .err = try registry_mod.ToolResult.err(allocator, name ++ ": missing query\n") };
    }
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    const parsed_args = switch (try parseArgs(allocator, args)) {
        .err => |e| return e,
        .ok => |p| p,
    };
    defer parsed_args.deinit(allocator);

    const query = parsed_args.query;
    const path = parsed_args.path;
    const limit = parsed_args.limit;
    const offset = parsed_args.offset;

    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, path);
    defer allocator.free(absolute);
    const relative = common.relativeToRoot(root, absolute);

    // Search via `rg` when present, otherwise fall back to an in-process search
    // for an explicitly named file.
    // `runCommand` spawns children under an empty environ and resolves a bare
    // `rg` against PATH; when ripgrep is not installed the exec fails with
    // FileNotFound. Rather than surfacing that as a cryptic tool error (the
    // problem the sibling workspace_list_files tool already fixed), the safe
    // fallback searches one caller-selected file. Directory fallback refuses
    // because it cannot reproduce ripgrep's ignore policy.
    var output = searchWithRipgrep(allocator, root, relative, query) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.StreamTooLong => try searchInProcess(
            allocator,
            root,
            absolute,
            query,
            max_search_matches + 1,
        ),
        else => return err,
    };
    defer output.deinit(allocator);

    const semantic_ok = output.ok;
    return renderSearchOutput(allocator, query, offset, limit, semantic_ok, &output);
}

fn renderSearchOutput(
    allocator: std.mem.Allocator,
    query: []const u8,
    offset: usize,
    limit: usize,
    semantic_ok: bool,
    output: *const SearchOutput,
) !registry_mod.ToolResult {
    // An inventory that hit its ceiling still answers the query for the page the
    // caller asked for. Refusing the whole search there returns zero matches for
    // a common term, which is strictly less useful than a bounded page plus the
    // statement that the inventory was cut.
    var records = std.ArrayList(SearchRecord).empty;
    defer records.deinit(allocator);
    try parseSearchRecords(allocator, output.stdout, &records);
    std.mem.sort(SearchRecord, records.items, {}, struct {
        fn lessThan(_: void, a: SearchRecord, b: SearchRecord) bool {
            const path_order = std.mem.order(u8, a.path, b.path);
            if (path_order != .eq) return path_order == .lt;
            const line_order = std.mem.order(u8, a.line_text, b.line_text);
            if (line_order != .eq) return line_order == .lt;
            return std.mem.lessThan(u8, a.text, b.text);
        }
    }.lessThan);
    if (offset > records.items.len) {
        return registry_mod.ToolResult.err(allocator, name ++ ": offset exceeds the current match inventory\n");
    }

    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();

    try w.writeAll("{\"ok\":");
    try w.writeAll(if (semantic_ok) "true" else "false");
    try w.writeAll(",\"query\":");
    try json_writer.writeString(w, query);
    try w.writeAll(",\"offset\":");
    try w.print("{d}", .{offset});
    try w.writeAll(",\"matches\":[");

    var returned: usize = 0;
    // Paging state only. A cut inventory is reported by `inventory_complete`;
    // folding it in here would publish a `next_offset` one past the last record
    // and turn the final page into a hard projection error.
    var has_more = false;
    for (records.items[offset..]) |record| {
        if (returned >= limit) {
            has_more = true;
            break;
        }
        const preview_end = common.utf8PrefixEnd(record.text, @min(record.text.len, 512));
        const before = text_buf.written().len;
        if (returned > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try json_writer.writeString(w, record.path);
        try w.writeAll(",\"line\":");
        try w.print("{d}", .{record.line});
        try w.writeAll(",\"text\":");
        try json_writer.writeString(w, record.text[0..preview_end]);
        try w.writeAll(",\"text_complete\":");
        try w.writeAll(if (preview_end == record.text.len) "true" else "false");
        try w.writeAll(",\"text_omitted_bytes\":");
        try w.print("{d}", .{record.text.len - preview_end});
        try w.writeByte('}');
        if (text_buf.written().len + 768 > common.max_projected_tool_result_bytes) {
            text_buf.shrinkRetainingCapacity(before);
            has_more = true;
            break;
        }
        returned += 1;
    }
    if (returned == 0 and has_more) return error.ToolContextEntryTooLarge;

    try w.writeAll("],\"returned\":");
    try w.print("{d}", .{returned});
    try w.writeAll(",\"truncated\":");
    try w.writeAll(if (has_more) "true" else "false");
    try w.writeAll(",\"inventory_complete\":");
    try w.writeAll(if (output.complete) "true" else "false");
    try w.writeAll(",\"next_offset\":");
    if (has_more) {
        try w.print("{d}", .{offset + returned});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"stderr\":");
    const stderr_end = common.utf8PrefixEnd(output.stderr, @min(output.stderr.len, 256));
    try json_writer.writeString(w, output.stderr[0..stderr_end]);
    try w.writeAll(",\"stderr_omitted_bytes\":");
    try w.print("{d}", .{output.stderr.len - stderr_end});
    try w.writeAll("}\n");

    const llm_text = try text_buf.toOwnedSlice();
    errdefer allocator.free(llm_text);
    if (llm_text.len > common.max_projected_tool_result_bytes) return error.ToolContextProjectionTooLarge;
    return .{ .ok = semantic_ok, .llm_text = llm_text };
}

const SearchRecord = struct {
    path: []const u8,
    line_text: []const u8,
    line: usize,
    text: []const u8,
};

/// Decode `path\x00line:text\n` records. NUL terminates the path because it
/// cannot occur in a file name. This keeps colons and newlines in legal paths
/// distinct from the line number and match text. A malformed internal record is
/// an error because skipping it would make the published inventory and offsets
/// inaccurate.
fn parseSearchRecords(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    records: *std.ArrayList(SearchRecord),
) !void {
    var start: usize = 0;
    while (start < bytes.len) {
        const nul_offset = std.mem.findScalar(u8, bytes[start..], 0) orelse return error.InvalidSearchOutput;
        const nul = start + nul_offset;
        const path = bytes[start..nul];
        if (path.len == 0) return error.InvalidSearchOutput;

        const payload_start = nul + 1;
        const newline_offset = std.mem.findScalar(u8, bytes[payload_start..], '\n') orelse return error.InvalidSearchOutput;
        const newline = payload_start + newline_offset;
        const payload = bytes[payload_start..newline];
        const colon = std.mem.findScalar(u8, payload, ':') orelse return error.InvalidSearchOutput;
        const line_text = payload[0..colon];
        const line = std.fmt.parseInt(usize, line_text, 10) catch return error.InvalidSearchOutput;
        if (line == 0) return error.InvalidSearchOutput;

        try records.append(allocator, .{
            .path = path,
            .line_text = line_text,
            .line = line,
            .text = payload[colon + 1 ..],
        });
        start = newline + 1;
    }
}

/// Both ripgrep and the in-process fallback emit `path\x00line:text\n` records
/// so parsing, sorting, paging, and JSON rendering stay single-sourced.
const SearchOutput = struct {
    stdout: []u8,
    stderr: []u8,
    ok: bool,
    complete: bool = true,

    fn deinit(self: *SearchOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// The trailing "--" ends rg's flag parsing, so a model-controlled query
/// beginning with "-" (e.g. "--pre", which executes a command) is always
/// treated as the search pattern, never as an rg option.
const rg_argv_prefix = [_][]const u8{ "rg", "-n", "--fixed-strings", "--no-heading", "--with-filename", "--null", "--color", "never", "--hidden", "-g", "!.git", "-g", "!zig-out", "-g", "!.zig-cache", "-g", "!node_modules", "-g", "!.zttp", "--" };

fn buildRgArgv(
    buf: *[rg_argv_prefix.len + 2][]const u8,
    relative: []const u8,
    query: []const u8,
) []const []const u8 {
    @memcpy(buf[0..rg_argv_prefix.len], &rg_argv_prefix);
    buf[rg_argv_prefix.len] = query;
    if (std.mem.eql(u8, relative, ".")) return buf[0 .. rg_argv_prefix.len + 1];
    buf[rg_argv_prefix.len + 1] = relative;
    return buf[0 .. rg_argv_prefix.len + 2];
}

fn searchWithRipgrep(
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
    query: []const u8,
) !SearchOutput {
    var argv_buf: [rg_argv_prefix.len + 2][]const u8 = undefined;
    const argv = buildRgArgv(&argv_buf, relative, query);

    var outcome = try common.runCommand(allocator, root, argv);
    // Capture the verdict fields before deinit clears them, then move the
    // stdout/stderr buffers into SearchOutput so the outcome's own deinit does
    // not free what we are returning.
    // rg exits 1 with no stderr when there are simply no matches; treat that as
    // a successful (empty) search, matching the prior behavior.
    const no_matches = outcome.exit_code != null and outcome.exit_code.? == 1 and outcome.stderr.len == 0;
    const ok = outcome.ok or no_matches;
    const out_stdout = outcome.stdout;
    const out_stderr = outcome.stderr;
    outcome.stdout = &.{};
    outcome.stderr = &.{};
    outcome.deinit(allocator);

    return .{ .stdout = out_stdout, .stderr = out_stderr, .ok = ok };
}

/// In-process substring search used when ripgrep is unavailable or its bounded
/// output buffer fills. An explicitly named file is safe to search because the
/// caller selected it. A recursive fallback would need to reproduce `.gitignore`,
/// `.ignore`, `.rgignore`, and global ignore policy before it could promise the
/// same file set as ripgrep, so directory targets return a structured refusal.
fn searchInProcess(
    allocator: std.mem.Allocator,
    root: []const u8,
    target_abs: []const u8,
    query: []const u8,
    limit: usize,
) !SearchOutput {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    const target_stat = try std.Io.Dir.cwd().statFile(io, target_abs, .{ .follow_symlinks = false });
    if (target_stat.kind == .directory) {
        const stdout = try out.toOwnedSlice(allocator);
        errdefer allocator.free(stdout);
        return .{
            .stdout = stdout,
            .stderr = try allocator.dupe(u8, "recursive fallback cannot apply ripgrep ignore policy; name one file path, or use ripgrep with a narrower query"),
            .ok = false,
            .complete = false,
        };
    }
    if (target_stat.kind != .file) return error.UnsupportedFileType;

    var count: usize = 0;
    try grepFile(
        allocator,
        root,
        target_abs,
        query,
        limit,
        &out,
        &count,
    );

    return .{
        .stdout = try out.toOwnedSlice(allocator),
        .stderr = try allocator.dupe(u8, ""),
        .ok = true,
        .complete = count < limit,
    };
}

fn grepFile(
    allocator: std.mem.Allocator,
    root: []const u8,
    file_abs: []const u8,
    query: []const u8,
    limit: usize,
    out: *std.ArrayList(u8),
    count: *usize,
) !void {
    // Bound each file read. A failed read must not report a complete search.
    const contents = try zts.file_io.readFile(allocator, file_abs, 16 * 1024 * 1024);
    defer allocator.free(contents);
    if (std.mem.indexOfScalar(u8, contents, 0) != null) return; // skip binary files
    // A stray non-UTF-8 byte does not make a text file unsearchable: the match
    // preview is cut on a codepoint boundary and `json_writer.writeString`
    // replaces any invalid sequence, so the envelope stays well-formed. Skipping
    // the whole file instead reports "no matches" for a symbol that exists.

    const rel = common.relativeToRoot(root, file_abs);
    var line_no: usize = 1;
    var line_start: usize = 0;
    while (line_start < contents.len) {
        const line_end = if (std.mem.findScalar(u8, contents[line_start..], '\n')) |offset|
            line_start + offset
        else
            contents.len;
        const line = contents[line_start..line_end];
        if (std.mem.indexOf(u8, line, query) != null) {
            if (count.* >= limit) return;
            try out.print(allocator, "{s}\x00{d}:{s}\n", .{ rel, line_no, line });
            count.* += 1;
        }
        if (line_end == contents.len) break;
        line_start = line_end + 1;
        line_no += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "workspace_search_text: missing query arg returns structured error" {
    var result = try execute(testing.allocator, &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "missing query") != null);
}

test "workspace_search_text: JSON args without query returns structured error" {
    var result = try execute(testing.allocator, &.{"{\"path\":\".\"}"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "missing query") != null);
}

test "workspace_search_text: non-string query returns structured error" {
    var result = try execute(testing.allocator, &.{"{\"query\":42}"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "query must be a string") != null);
}

test "workspace_search_text: malformed JSON returns structured error" {
    var result = try execute(testing.allocator, &.{"{not"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "invalid JSON input") != null);
}

test "workspace_search_text: multiline query returns structured error" {
    var result = try tool.execute(testing.allocator, &.{"{\"query\":\"a\\nb\"}"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "newline") != null);
}

test "workspace_search_text: paged previews retain exact match locators" {
    const stdout =
        "src/a.ts\x002:first match\n" ++
        "src/b.ts\x007:second match\n" ++
        "src/c.ts\x009:third match\n";
    const output: SearchOutput = .{
        .stdout = @constCast(stdout),
        .stderr = @constCast(""),
        .ok = true,
    };
    var result = try renderSearchOutput(testing.allocator, "match", 1, 1, true, &output);
    defer result.deinit(testing.allocator);
    try testing.expect(result.llm_text.len <= common.max_projected_tool_result_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), obj.get("next_offset").?.integer);
    const matches = obj.get("matches").?.array.items;
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("src/b.ts", matches[0].object.get("path").?.string);
    try testing.expectEqual(@as(i64, 7), matches[0].object.get("line").?.integer);
    try testing.expectEqualStrings("second match", matches[0].object.get("text").?.string);
}

test "workspace_search_text: malformed match frames are rejected" {
    const output: SearchOutput = .{
        .stdout = @constCast("src/a.ts\x00not-a-line:first match\n"),
        .stderr = @constCast(""),
        .ok = true,
    };
    try testing.expectError(
        error.InvalidSearchOutput,
        renderSearchOutput(testing.allocator, "match", 0, 1, true, &output),
    );
}

test "workspace_search_text: dash-leading query reaches rg as a pattern, after --" {
    var buf: [rg_argv_prefix.len + 2][]const u8 = undefined;

    const argv_root = buildRgArgv(&buf, ".", "--pre=touch");
    try testing.expectEqualStrings("--", argv_root[argv_root.len - 2]);
    try testing.expectEqualStrings("--pre=touch", argv_root[argv_root.len - 1]);

    const argv_sub = buildRgArgv(&buf, "src", "-e");
    try testing.expectEqualStrings("--", argv_sub[argv_sub.len - 3]);
    try testing.expectEqualStrings("-e", argv_sub[argv_sub.len - 2]);
    try testing.expectEqualStrings("src", argv_sub[argv_sub.len - 1]);
}

test "workspace_search_text: ../ escape is rejected by resolveInsideWorkspace" {
    try testing.expectError(
        error.PathOutsideWorkspace,
        execute(testing.allocator, &.{ "needle", "../../etc" }),
    );
}

// Unwrap a successful parse for tests, freeing the error and failing the test
// on a structured error. The returned ParsedArgs owns its buffers; the caller
// deinits it.
fn parseOk(allocator: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    var result = try parseArgs(allocator, args);
    switch (result) {
        .err => |*e| {
            e.deinit(allocator);
            return error.UnexpectedParseError;
        },
        .ok => |p| return p,
    }
}

test "workspace_search_text: JSON-derived query survives parse-tree teardown (ae881b6 use-after-free)" {
    // The values must still read correctly after the JSON tree they were parsed
    // from is freed. Before ae881b6 the query was a dangling slice into that
    // freed tree, reaching `rg` as garbage (zero matches). The testing allocator
    // also flags a leak if the owned buffers escape.
    const p = try parseOk(testing.allocator, &.{"{\"query\":\"needle-xyz\",\"path\":\"src\",\"limit\":5}"});
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("needle-xyz", p.query);
    try testing.expectEqualStrings("src", p.path);
    try testing.expectEqual(@as(usize, 5), p.limit);
}

test "workspace_search_text: positional args do not allocate owned buffers" {
    const p = try parseOk(testing.allocator, &.{ "needle", "sub/dir" });
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("needle", p.query);
    try testing.expectEqualStrings("sub/dir", p.path);
    try testing.expect(p.owned_query == null);
    try testing.expect(p.owned_path == null);
}

const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
const cwd_support = @import("../test_support/cwd.zig");

test "workspace_search_text: public tool API preserves a colon path and treats the query literally" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "search-colon-path");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "src/a:b.ts", "axb\na.b\n");

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var result = try tool.execute(
        allocator,
        &.{"{\"query\":\"a.b\",\"path\":\"src/a:b.ts\"}"},
    );
    defer result.deinit(allocator);
    try testing.expect(result.ok);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.llm_text, .{});
    defer parsed.deinit();
    const matches = parsed.value.object.get("matches").?.array.items;
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("src/a:b.ts", matches[0].object.get("path").?.string);
    try testing.expectEqual(@as(i64, 2), matches[0].object.get("line").?.integer);
    try testing.expectEqualStrings("a.b", matches[0].object.get("text").?.string);
}

test "workspace_search_text: public tool API bounds an explicit file and refuses recursive fallback" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "search-stream-limit");
    defer tmp.cleanup(allocator);

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);
    for (0..max_search_matches + 2) |_| {
        try contents.appendSlice(allocator, "needle-0123456789\n");
    }
    try tmp.writeFile(allocator, "bulk.txt", contents.items);

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var file_result = try tool.execute(
        allocator,
        &.{"{\"query\":\"needle\",\"path\":\"bulk.txt\",\"limit\":1}"},
    );
    defer file_result.deinit(allocator);
    try testing.expect(file_result.ok);
    var parsed_file = try std.json.parseFromSlice(std.json.Value, allocator, file_result.llm_text, .{});
    defer parsed_file.deinit();
    try testing.expectEqual(@as(i64, 1), parsed_file.value.object.get("returned").?.integer);
    try testing.expect(!parsed_file.value.object.get("inventory_complete").?.bool);

    var directory_result = try tool.execute(
        allocator,
        &.{"{\"query\":\"needle\",\"path\":\".\",\"limit\":1}"},
    );
    defer directory_result.deinit(allocator);
    try testing.expect(!directory_result.ok);
    var parsed_directory = try std.json.parseFromSlice(std.json.Value, allocator, directory_result.llm_text, .{});
    defer parsed_directory.deinit();
    try testing.expect(!parsed_directory.value.object.get("inventory_complete").?.bool);
    try testing.expect(std.mem.indexOf(
        u8,
        parsed_directory.value.object.get("stderr").?.string,
        "ignore policy",
    ) != null);
}

test "workspace_search_text: in-process fallback searches one explicit file" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "search-inprocess");
    defer tmp.cleanup(allocator);

    try tmp.writeFile(allocator, "src/handler.ts", "const x = 1;\nfind-me here\nbye\n");
    const handler_path = try tmp.childPath(allocator, "src/handler.ts");
    defer allocator.free(handler_path);

    var output = try searchInProcess(allocator, tmp.abs_path, handler_path, "find-me", 50);
    defer output.deinit(allocator);

    try testing.expect(output.ok);
    try testing.expect(output.complete);
    try testing.expect(std.mem.indexOf(u8, output.stdout, "src/handler.ts\x002:find-me here") != null);
}

test "workspace_search_text: in-process recursive fallback refuses without ignore policy" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "search-inprocess-dir");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, ".gitignore", ".env\n");
    try tmp.writeFile(allocator, ".env", "secret-needle\n");

    var output = try searchInProcess(allocator, tmp.abs_path, tmp.abs_path, "secret-needle", 50);
    defer output.deinit(allocator);

    try testing.expect(!output.ok);
    try testing.expect(!output.complete);
    try testing.expectEqual(@as(usize, 0), output.stdout.len);
    try testing.expect(std.mem.indexOf(u8, output.stderr, "ignore policy") != null);
}

test "workspace_search_text: in-process fallback propagates a missing named file" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "search-inprocess-missing");
    defer tmp.cleanup(allocator);
    const file_path = try tmp.childPath(allocator, "missing.txt");
    defer allocator.free(file_path);

    try testing.expectError(
        error.FileNotFound,
        searchInProcess(allocator, tmp.abs_path, file_path, "needle", 50),
    );
}

test "workspace_search_text: in-process fallback honors the match limit" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "search-inprocess-limit");
    defer tmp.cleanup(allocator);

    try tmp.writeFile(allocator, "a.txt", "needle\nneedle\nneedle\n");
    const file_path = try tmp.childPath(allocator, "a.txt");
    defer allocator.free(file_path);

    var output = try searchInProcess(allocator, tmp.abs_path, file_path, "needle", 2);
    defer output.deinit(allocator);

    var records = std.ArrayList(SearchRecord).empty;
    defer records.deinit(allocator);
    try parseSearchRecords(allocator, output.stdout, &records);
    try testing.expectEqual(@as(usize, 2), records.items.len);
    try testing.expect(!output.complete);
}

test "workspace_search_text: in-process fallback skips binary files" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "search-inprocess-binary");
    defer tmp.cleanup(allocator);

    // A NUL byte marks the file as binary; ripgrep skips these by default.
    try tmp.writeFile(allocator, "blob.bin", "find-me\x00more\n");
    const file_path = try tmp.childPath(allocator, "blob.bin");
    defer allocator.free(file_path);

    var output = try searchInProcess(allocator, tmp.abs_path, file_path, "find-me", 50);
    defer output.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), output.stdout.len);
    try testing.expect(output.complete);
}

fn searchFileUnderAllocationFailure(
    allocator: std.mem.Allocator,
    root: []const u8,
    file_path: []const u8,
) !void {
    var output = try searchInProcess(allocator, root, file_path, "needle", 50);
    defer output.deinit(allocator);
}

test "workspace_search_text: in-process fallback propagates allocation failure" {
    const allocator = testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "search-inprocess-oom");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "a.txt", "needle\n");
    const file_path = try tmp.childPath(allocator, "a.txt");
    defer allocator.free(file_path);

    try testing.checkAllAllocationFailures(
        allocator,
        searchFileUnderAllocationFailure,
        .{ tmp.abs_path, file_path },
    );
}
