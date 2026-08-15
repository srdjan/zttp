//! Pure decoding for OpenAI Responses API requests sent to the stand-in.

const std = @import("std");

pub const ParsedRequest = struct {
    ask: []const u8,
    step_index: usize,
    /// The target file's bytes, recovered from a read tool's output.
    ///
    /// Null means no complete read has succeeded yet, which is NOT the same as
    /// an empty file. A paged read is valid JSON but carries `complete:false`;
    /// a failed read has no content field. Both arrive here as null. A playbook
    /// that authored from either would rewrite from an incomplete baseline.
    source: ?[]const u8 = null,
    /// Raw `output` string of the LAST function_call_output in the current turn.
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
    const input_value = root_value.object.get("input") orelse return ParseError.InvalidRequest;
    if (input_value != .array) return ParseError.InvalidRequest;

    var ask: ?[]const u8 = null;
    var step_index: usize = 0;
    var source: ?[]const u8 = null;
    var last_output: ?[]const u8 = null;
    var rejected_drafts: usize = 0;

    // Everything here is scoped to the CURRENT turn, and a plain user message
    // is what starts one. The transcript is cumulative, so counting across the
    // whole array would carry the previous task's tool outputs into this one:
    // a second ask in the same session would start past the end of its own
    // playbook and answer the first ask's question.
    for (input_value.array.items) |item_value| {
        if (item_value != .object) return ParseError.InvalidRequest;
        const item = item_value.object;

        if (item.get("type")) |type_value| {
            if (type_value != .string) return ParseError.InvalidRequest;
            if (std.mem.eql(u8, type_value.string, "function_call_output")) {
                step_index += 1;
                if (item.get("output")) |output_value| {
                    if (output_value != .string) return ParseError.InvalidRequest;
                    if (try readSource(arena, output_value.string)) |content| source = content;
                    last_output = output_value.string;
                    if (std.mem.startsWith(u8, output_value.string, veto_reject_preamble)) {
                        rejected_drafts += 1;
                    }
                }
            }
        }

        if (isUserMessage(item)) {
            const message = try readInputText(item);
            if (message.compaction_summary) {
                if (originalRequestFromSummary(message.text)) |original_request| {
                    ask = original_request;
                    step_index = 0;
                    source = null;
                    last_output = null;
                    rejected_drafts = 0;
                }
                continue;
            }
            // The workflow note and the loop's retry messages ride along as
            // further user messages on the same turn, so none of them may reset
            // the turn they belong to.
            if (!isContinuation(message.text)) {
                ask = message.text;
                step_index = 0;
                source = null;
                last_output = null;
                rejected_drafts = 0;
            }
        }
    }

    return .{
        .ask = ask orelse return ParseError.MissingAsk,
        .step_index = step_index,
        .source = source,
        .last_output = last_output,
        .rejected_drafts = rejected_drafts,
    };
}

fn isUserMessage(item: std.json.ObjectMap) bool {
    const role = item.get("role") orelse return false;
    return role == .string and std.mem.eql(u8, role.string, "user");
}

const InputText = struct {
    text: []const u8,
    compaction_summary: bool = false,
};

fn readInputText(item: std.json.ObjectMap) !InputText {
    const content_value = item.get("content") orelse return ParseError.InvalidRequest;
    if (content_value != .array) return ParseError.InvalidRequest;
    var first_text: ?[]const u8 = null;
    for (content_value.array.items) |part_value| {
        if (part_value != .object) return ParseError.InvalidRequest;
        const part = part_value.object;
        const type_value = part.get("type") orelse continue;
        if (type_value != .string) return ParseError.InvalidRequest;
        if (!std.mem.eql(u8, type_value.string, "input_text")) continue;
        const text_value = part.get("text") orelse return ParseError.InvalidRequest;
        if (text_value != .string) return ParseError.InvalidRequest;
        if (first_text == null) {
            first_text = text_value.string;
            continue;
        }
        const first = first_text orelse return ParseError.InvalidRequest;
        if (std.mem.eql(u8, first, compaction_summary_marker)) {
            return .{ .text = text_value.string, .compaction_summary = true };
        }
    }
    return .{ .text = first_text orelse return ParseError.InvalidRequest };
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

fn readSource(arena: std.mem.Allocator, output: []const u8) !?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (value != .object) return null;
    const complete = value.object.get("complete") orelse return null;
    const offset = value.object.get("offset") orelse return null;
    if (complete != .bool or !complete.bool or offset != .integer or offset.integer != 0) return null;
    const content = value.object.get("content") orelse return null;
    if (content != .string) return null;
    return content.string;
}

const testing = std.testing;

test "stand-in request parsing recovers the ask, source, and stateless step index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Add a GET /health route to handler.ts"}]},
        \\  {"role":"user","content":[{"type":"input_text","text":"[expert workflow] kind=route_add"}]},
        \\  {"type":"function_call","call_id":"call-0","name":"workspace_read_file","arguments":"{\"path\":\"handler.ts\"}"},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"type":"function_call_output","call_id":"call-1","output":"[]"}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Add a GET /health route to handler.ts", parsed.ask);
    try testing.expectEqual(@as(usize, 2), parsed.step_index);
    try testing.expectEqualStrings("function handler() {}", parsed.source.?);
}

test "stand-in request parsing restores a split-turn ask from compacted context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[
        \\    {"type":"input_text","text":"[zttp compaction summary v1]"},
        \\    {"type":"input_text","text":"## Goal\nOld SQLite work\n\n## Original Request\nAdd a GET /health route to handler.ts\n\n## Early Progress\nRead handler\n\n## Context for Suffix\nContinue verification"}
        \\  ]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"}
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
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Add a GET /health route to handler.ts"}]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"type":"function_call_output","call_id":"call-1","output":"[]"},
        \\  {"type":"function_call_output","call_id":"call-2","output":"{\"ok\":true}"},
        \\  {"role":"user","content":[{"type":"input_text","text":"Explain what this handler does"}]},
        \\  {"role":"user","content":[{"type":"input_text","text":"[expert workflow] kind=review_explain"}]}
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
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Add a GET /health route to handler.ts"}]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"complete\":false,\"offset\":0,\"next_offset\":12,\"content\":\"function han\"}"}
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
    // as a function_call_output, and the loop's nudge follows as a user message.
    // Treating that nudge as a new ask restarts the playbook at step 0 with the
    // nudge as its ask, which is what happened before the prefix table existed.
    const body =
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Fix the ZTS300 compiler error in handler.ts"}]},
        \\  {"role":"user","content":[{"type":"input_text","text":"[expert workflow] kind=violation_fix"}]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"type":"function_call_output","call_id":"call-1","output":"The compiler rejected this edit. Fix every flagged violation below:\n\nZTS300"},
        \\  {"role":"user","content":[{"type":"input_text","text":"Your previous edit failed compiler verification (attempt 1/5). Emit a new, complete edit."}]}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Fix the ZTS300 compiler error in handler.ts", parsed.ask);
    try testing.expectEqual(@as(usize, 2), parsed.step_index);
    try testing.expectEqualStrings("function handler() {}", parsed.source.?);
    try testing.expectEqual(@as(usize, 1), parsed.rejected_drafts);
}

test "stand-in request parsing keeps the turn through a compiler-authored repair note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Fix the ZTS604 compiler error in handler.ts"}]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"role":"user","content":[{"type":"input_text","text":"Compiler-authored repair for your last edit. Apply these changes verbatim."}]}
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
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Fill the remaining hole in handler.ts"}]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"complete\":true,\"offset\":0,\"content\":\"function handler() {}\"}"},
        \\  {"type":"function_call_output","call_id":"call-1","output":"{\"ok\":true,\"proposed_content\":\"return Response.json({});\"}"}
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
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Fill the remaining hole in handler.ts"}]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true}"},
        \\  {"role":"user","content":[{"type":"input_text","text":"Explain what this handler does"}]}
        \\]}
    ;
    const parsed2 = try parse(arena.allocator(), second);
    try testing.expect(parsed2.last_output == null);
}
