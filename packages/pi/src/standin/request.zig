//! Pure decoding for Chat Completions requests sent to the stand-in.

const std = @import("std");

pub const ParsedRequest = struct {
    ask: []const u8,
    step_index: usize,
    /// The target file's bytes, recovered from a read tool's output.
    ///
    /// Null means no complete read has succeeded yet, which is NOT the same as
    /// an empty file. A failed read has no content field, and a read whose pages
    /// have not reached the end of the file is still in progress; both arrive
    /// here as null. A playbook that authored from either would rewrite from an
    /// incomplete baseline.
    ///
    /// Pages are concatenated in offset order, so a file larger than one page
    /// is readable: `pending_read` names the next page to request.
    source: ?[]const u8 = null,
    /// The next page the stand-in must request before authoring can proceed.
    ///
    /// Set while a read is in progress. Paging round trips deliberately do not
    /// advance `step_index`, so a multi-page read leaves every playbook's step
    /// numbering unchanged.
    pending_read: ?PendingRead = null,
    /// Raw content of the LAST tool message in the current turn.
    ///
    /// Null before any tool result. Read it through a real JSON parse and refuse
    /// incomplete source whenever authoring depends on it.
    last_output: ?[]const u8 = null,
    /// Function-call outputs in this turn carrying the loop's veto rejection
    /// preamble. Separates "past the apply step because the edit landed" from
    /// "past it because the compiler bounced it", which the step index alone
    /// cannot express since both advance it by one.
    rejected_drafts: usize = 0,
};

pub const PendingRead = struct {
    path: []const u8,
    offset: usize,
    /// Zero-based index of the continuation page, used only to keep each
    /// paging tool call's identifier distinct from its predecessors.
    page_index: usize,
};

pub const ParseError = error{
    InvalidRequest,
    MissingAsk,
};

/// User-role items the loop appends DURING a turn, which must not be mistaken
/// for the start of a new one.
///
/// Both the veto retry nudge and the compiler-authored repair note reach the
/// wire as `{"role":"user"}` - `extra_user_text` is a user message and a
/// `system_note` is serialized as one - so the shape that distinguishes them
/// from an ask is their opening text and nothing else. Until this table had
/// three rows, a rejected draft reset `ask`, `step_index`, and `source`, and the
/// playbook restarted from step 0 against the retry nudge as its ask. Nothing
/// noticed because no stand-in draft has ever failed the veto.
///
/// Duplicated from the authors rather than imported: pulling `loop.zig` in here
/// would drag the whole agent into the stand-in executable. A gate asserts the
/// two copies agree, in both directions, the way the negative corpus is held
/// against `expert_eval.cases`.
pub const continuation_prefixes = [_][]const u8{
    "[expert workflow]",
    "Your previous edit failed compiler verification",
    "Compiler-authored repair for your last edit",
};

/// Opening words of the tool result the loop writes when the veto rejects a
/// draft. Held against `loop.veto_reject_preamble` by the same gate.
pub const veto_reject_preamble = "The compiler rejected this edit.";
pub const compaction_summary_marker = "[zttp compaction summary v1]";

fn isContinuation(text: []const u8) bool {
    for (continuation_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }
    return false;
}

pub fn parse(arena: std.mem.Allocator, body: []const u8) !ParsedRequest {
    const root_value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return ParseError.InvalidRequest,
    };
    if (root_value != .object) return ParseError.InvalidRequest;
    const messages_value = root_value.object.get("messages") orelse return ParseError.InvalidRequest;
    if (messages_value != .array) return ParseError.InvalidRequest;

    var ask: ?[]const u8 = null;
    var step_index: usize = 0;
    var source: ?[]const u8 = null;
    var last_output: ?[]const u8 = null;
    var rejected_drafts: usize = 0;
    var read_path: ?[]const u8 = null;
    var pending_read: ?PendingRead = null;
    var pages = std.ArrayList(u8).empty;
    var page_bytes: usize = 0;
    var continuation_pages: usize = 0;
    // A compaction summary reaches the wire as two consecutive user messages:
    // the marker, then the summary body. Set after the marker, cleared by the
    // next message of any kind.
    var summary_follows = false;

    // Everything here is scoped to the CURRENT turn, and a plain user message
    // is what starts one. The transcript is cumulative, so counting across the
    // whole array would carry the previous task's tool outputs into this one:
    // a second ask in the same session would start past the end of its own
    // playbook and answer the first ask's question.
    for (messages_value.array.items) |item_value| {
        if (item_value != .object) return ParseError.InvalidRequest;
        const item = item_value.object;
        const role_value = item.get("role") orelse return ParseError.InvalidRequest;
        if (role_value != .string) return ParseError.InvalidRequest;
        const role = role_value.string;
        const follows_marker = summary_follows;
        summary_follows = false;

        if (std.mem.eql(u8, role, "assistant")) {
            if (readCallPath(arena, item)) |path| read_path = path;
        }

        if (std.mem.eql(u8, role, "tool")) {
            const output_value = item.get("content") orelse return ParseError.InvalidRequest;
            if (output_value != .string) return ParseError.InvalidRequest;
            if (try readPage(arena, output_value.string)) |page| {
                // A continuation page answers the stand-in's own paging
                // call, not a playbook step, so it must not advance the
                // step index the playbooks are written against.
                if (page.offset == 0) {
                    step_index += 1;
                    pages.clearRetainingCapacity();
                    page_bytes = 0;
                } else if (page.offset != page_bytes) {
                    // A page out of order cannot be concatenated into a
                    // faithful baseline; drop the read rather than
                    // author from spliced bytes.
                    pages.clearRetainingCapacity();
                    page_bytes = 0;
                    pending_read = null;
                    last_output = output_value.string;
                    continue;
                }
                try pages.appendSlice(arena, page.content);
                page_bytes += page.content.len;
                if (page.next_offset) |next| {
                    pending_read = .{
                        .path = read_path orelse "",
                        .offset = next,
                        .page_index = continuation_pages,
                    };
                    continuation_pages += 1;
                } else {
                    // Duped because a later read in the same turn reuses
                    // this buffer's capacity.
                    source = try arena.dupe(u8, pages.items);
                    pending_read = null;
                }
            } else {
                // An output that is not a page cannot answer a pending
                // continuation read. Abandon the read: leaving it set
                // re-issues the identical call until the turn's tool
                // budget aborts.
                if (pending_read != null) {
                    pending_read = null;
                    pages.clearRetainingCapacity();
                    page_bytes = 0;
                }
                step_index += 1;
            }
            last_output = output_value.string;
            if (std.mem.startsWith(u8, output_value.string, veto_reject_preamble)) {
                rejected_drafts += 1;
            }
        }

        if (std.mem.eql(u8, role, "user")) {
            const content_value = item.get("content") orelse return ParseError.InvalidRequest;
            if (content_value != .string) return ParseError.InvalidRequest;
            const text = content_value.string;
            if (std.mem.eql(u8, text, compaction_summary_marker)) {
                summary_follows = true;
                continue;
            }
            if (follows_marker) {
                if (originalRequestFromSummary(text)) |original_request| {
                    ask = original_request;
                    step_index = 0;
                    source = null;
                    last_output = null;
                    rejected_drafts = 0;
                    pending_read = null;
                    read_path = null;
                    pages.clearRetainingCapacity();
                    page_bytes = 0;
                    continuation_pages = 0;
                }
                continue;
            }
            // The workflow note and the loop's retry messages ride along as
            // further user messages on the same turn, so none of them may reset
            // the turn they belong to.
            if (!isContinuation(text)) {
                ask = text;
                step_index = 0;
                source = null;
                last_output = null;
                rejected_drafts = 0;
                pending_read = null;
                read_path = null;
                pages.clearRetainingCapacity();
                page_bytes = 0;
                continuation_pages = 0;
            }
        }
    }

    return .{
        .ask = ask orelse return ParseError.MissingAsk,
        .step_index = step_index,
        .source = source,
        .pending_read = pending_read,
        .last_output = last_output,
        .rejected_drafts = rejected_drafts,
    };
}

fn originalRequestFromSummary(summary: []const u8) ?[]const u8 {
    const heading = "## Original Request";
    const start = std.mem.lastIndexOf(u8, summary, heading) orelse return null;
    const content_start = start + heading.len;
    const end = std.mem.indexOfPos(u8, summary, content_start, "\n## Early Progress") orelse
        summary.len;
    const request = std.mem.trim(u8, summary[content_start..end], " \t\r\n");
    return if (request.len == 0) null else request;
}

const ReadPage = struct {
    offset: usize,
    next_offset: ?usize,
    content: []const u8,
};

/// Decode one `workspace_read_file` page. Null for any other tool output,
/// including a failed read, which carries no content field.
///
/// Identified by shape rather than by the preceding call, because a compacted
/// history can carry an output whose call is gone.
fn readPage(arena: std.mem.Allocator, output: []const u8) !?ReadPage {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (value != .object) return null;
    const offset = value.object.get("offset") orelse return null;
    if (offset != .integer or offset.integer < 0) return null;
    const content = value.object.get("content") orelse return null;
    if (content != .string) return null;
    const complete = value.object.get("complete") orelse return null;
    if (complete != .bool) return null;
    var next: ?usize = null;
    if (!complete.bool) {
        const next_value = value.object.get("next_offset") orelse return null;
        if (next_value != .integer or next_value.integer < 0) return null;
        next = @intCast(next_value.integer);
    }
    return .{
        .offset = @intCast(offset.integer),
        .next_offset = next,
        .content = content.string,
    };
}

/// The path of the last `workspace_read_file` call in an assistant message, so
/// a continuation page can be requested for the same file. Null when the
/// message carries no such call.
fn readCallPath(arena: std.mem.Allocator, item: std.json.ObjectMap) ?[]const u8 {
    const calls_value = item.get("tool_calls") orelse return null;
    if (calls_value != .array) return null;
    var found: ?[]const u8 = null;
    for (calls_value.array.items) |call_value| {
        if (call_value != .object) continue;
        const function_value = call_value.object.get("function") orelse continue;
        if (function_value != .object) continue;
        const function = function_value.object;
        const name_value = function.get("name") orelse continue;
        if (name_value != .string or !std.mem.eql(u8, name_value.string, "workspace_read_file")) continue;
        const args_value = function.get("arguments") orelse continue;
        if (args_value != .string) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_value.string, .{}) catch continue;
        if (parsed != .object) continue;
        const path_value = parsed.object.get("path") orelse continue;
        if (path_value != .string) continue;
        found = path_value.string;
    }
    return found;
}

const testing = std.testing;

test "stand-in request parsing recovers the ask, source, and stateless step index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Add a GET /health route to handler.ts"},
        \\  {"role":"user","content":"[expert workflow] kind=route_add"},
        \\  {"role":"assistant","content":null,"tool_calls":[{"id":"call-0","type":"function","function":{"name":"workspace_read_file","arguments":"{\"path\":\"handler.ts\"}"}}]},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"role":"tool","tool_call_id":"call-1","content":"[]"}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Add a GET /health route to handler.ts", parsed.ask);
    try testing.expectEqual(@as(usize, 2), parsed.step_index);
    try testing.expectEqualStrings("function handler() {}", parsed.source.?);
}

test "stand-in request parsing pages a file larger than one read page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const first_page =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Add a GET /health route to handler.ts"},
        \\  {"role":"assistant","content":null,"tool_calls":[{"id":"call-0","type":"function","function":{"name":"workspace_read_file","arguments":"{\"path\":\"handler.ts\"}"}}]},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":false,\"offset\":0,\"next_offset\":9,\"content\":\"function \"}"}
        \\]}
    ;
    const mid = try parse(arena.allocator(), first_page);
    // The read step is consumed once, and the baseline is refused until the
    // last page lands.
    try testing.expectEqual(@as(usize, 1), mid.step_index);
    try testing.expect(mid.source == null);
    try testing.expectEqualStrings("handler.ts", mid.pending_read.?.path);
    try testing.expectEqual(@as(usize, 9), mid.pending_read.?.offset);

    const both_pages =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Add a GET /health route to handler.ts"},
        \\  {"role":"assistant","content":null,"tool_calls":[{"id":"call-0","type":"function","function":{"name":"workspace_read_file","arguments":"{\"path\":\"handler.ts\"}"}}]},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":false,\"offset\":0,\"next_offset\":9,\"content\":\"function \"}"},
        \\  {"role":"assistant","content":null,"tool_calls":[{"id":"call-900","type":"function","function":{"name":"workspace_read_file","arguments":"{\"path\":\"handler.ts\",\"offset\":9}"}}]},
        \\  {"role":"tool","tool_call_id":"call-900","content":"{\"ok\":true,\"complete\":true,\"offset\":9,\"next_offset\":null,\"content\":\"handler() {}\"}"}
        \\]}
    ;
    const done = try parse(arena.allocator(), both_pages);
    // Paging round trips leave the playbook's step numbering untouched.
    try testing.expectEqual(@as(usize, 1), done.step_index);
    try testing.expect(done.pending_read == null);
    try testing.expectEqualStrings("function handler() {}", done.source.?);
}

test "stand-in request parsing restores a split-turn ask from compacted context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"[zttp compaction summary v1]"},
        \\  {"role":"user","content":"## Goal\nOld SQLite work\n\n## Original Request\nAdd a GET /health route to handler.ts\n\n## Early Progress\nRead handler\n\n## Context for Suffix\nContinue verification"},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Add a GET /health route to handler.ts", parsed.ask);
    try testing.expectEqual(@as(usize, 1), parsed.step_index);
    try testing.expectEqualStrings(
        "function handler() {}",
        parsed.source orelse return error.TestExpectedSource,
    );
}

test "stand-in request parsing scopes the turn to the latest ask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A completed add-route turn followed by a fresh ask. Counting across the
    // whole transcript would report step 4 and answer the first question.
    const body =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Add a GET /health route to handler.ts"},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"role":"tool","tool_call_id":"call-1","content":"[]"},
        \\  {"role":"tool","tool_call_id":"call-2","content":"{\"ok\":true}"},
        \\  {"role":"user","content":"Explain what this handler does"},
        \\  {"role":"user","content":"[expert workflow] kind=review_explain"}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Explain what this handler does", parsed.ask);
    try testing.expectEqual(@as(usize, 0), parsed.step_index);
    try testing.expect(parsed.source == null);
}

test "stand-in request parsing reports an incomplete read as null, not empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A bounded page remains valid JSON but is not a complete authoring
    // baseline. Authoring from it would overwrite the omitted suffix.
    const body =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Add a GET /health route to handler.ts"},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":false,\"offset\":0,\"next_offset\":12,\"content\":\"function han\"}"}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqual(@as(usize, 1), parsed.step_index);
    try testing.expect(parsed.source == null);
}

test "stand-in request parsing keeps the turn through a veto rejection and its retry notice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // What the wire looks like after a draft is bounced: the failed apply lands
    // as a tool message, and the loop's nudge follows as a user message.
    // Treating that nudge as a new ask restarts the playbook at step 0 with the
    // nudge as its ask, which is what happened before the prefix table existed.
    const body =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Fix the ZTS303 compiler error in handler.ts"},
        \\  {"role":"user","content":"[expert workflow] kind=violation_fix"},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"role":"tool","tool_call_id":"call-1","content":"The compiler rejected this edit. Fix every flagged violation below:\n\nZTS303"},
        \\  {"role":"user","content":"Your previous edit failed compiler verification (attempt 1/5). Emit a new, complete edit."}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Fix the ZTS303 compiler error in handler.ts", parsed.ask);
    try testing.expectEqual(@as(usize, 2), parsed.step_index);
    try testing.expectEqualStrings("function handler() {}", parsed.source.?);
    try testing.expectEqual(@as(usize, 1), parsed.rejected_drafts);
}

test "stand-in request parsing keeps the turn through a compiler-authored repair note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Fix the ZTS604 compiler error in handler.ts"},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"role":"user","content":"Compiler-authored repair for your last edit. Apply these changes verbatim."}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Fix the ZTS604 compiler error in handler.ts", parsed.ask);
    try testing.expectEqual(@as(usize, 1), parsed.step_index);
    try testing.expectEqual(@as(usize, 0), parsed.rejected_drafts);
}

test "stand-in request parsing recovers the last tool output verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The hole arm needs the coordinates a tool returned, which `source` cannot
    // carry: it holds only the `content` field of a read. The last output is the
    // raw string, so a playbook parses it itself and refuses what it cannot read.
    const body =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Fill the remaining hole in handler.ts"},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"role":"tool","tool_call_id":"call-1","content":"{\"ok\":true,\"proposed_content\":\"return Response.json({});\"}"}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings(
        "{\"ok\":true,\"proposed_content\":\"return Response.json({});\"}",
        parsed.last_output.?,
    );
    // The read still wins for `source`: a later output with no `content` field
    // must not erase the file the playbook is editing.
    try testing.expectEqualStrings("function handler() {}", parsed.source.?);

    // And a fresh ask clears it, for the same reason it clears the step index.
    const second =
        \\{"model":"standin","messages":[
        \\  {"role":"user","content":"Fill the remaining hole in handler.ts"},
        \\  {"role":"tool","tool_call_id":"call-0","content":"{\"ok\":true}"},
        \\  {"role":"user","content":"Explain what this handler does"}
        \\]}
    ;
    const parsed2 = try parse(arena.allocator(), second);
    try testing.expect(parsed2.last_output == null);
}
