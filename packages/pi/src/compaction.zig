//! Pure compaction policy and summary-contract helpers.
//!
//! This module never calls a model, writes a checkpoint, or mutates a
//! transcript. It selects a safe retained suffix, serializes only the span a
//! standalone summarizer may see, validates the returned summary shape, and
//! derives cumulative file facts from typed tool calls.

const std = @import("std");
const context_budget = @import("context_budget.zig");
const models = @import("providers/models.zig");
const tool_catalog = @import("providers/tool_catalog.zig");
const transcript_mod = @import("transcript.zig");
const turn_mod = @import("turn.zig");
const ui_payload_mod = @import("ui_payload.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;

pub const default_max_input_tokens: u64 = 40_000;
pub const default_reserve_tokens: u64 = 16_384;
pub const default_keep_recent_tokens: u64 = 20_000;
pub const max_summary_tokens: u64 = 4_096;
/// A smaller allowance cannot reliably emit the mandatory summary headings
/// plus enough content to preserve a useful continuation.
pub const minimum_summary_tokens: u64 = 512;
pub const minimum_reserve_tokens: u64 = minimum_summary_tokens * 4;
pub const max_summary_tool_result_bytes: usize = 2_000;

pub const SummaryRequest = struct {
    system_prompt: []const u8,
    user_prompt: []const u8,
    max_output_tokens: u32,
};

pub const SummaryResponse = struct {
    response: turn_mod.AssistantReply.Response,
    usage: turn_mod.Usage = .{},
};

pub const Summarizer = struct {
    context: *anyopaque,
    summarize_fn: *const fn (
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: SummaryRequest,
    ) anyerror!SummaryResponse,

    pub fn summarize(
        self: Summarizer,
        arena: std.mem.Allocator,
        request: SummaryRequest,
    ) !SummaryResponse {
        return self.summarize_fn(self.context, arena, request);
    }
};

pub const Settings = struct {
    max_input_tokens: u64 = default_max_input_tokens,
    reserve_tokens: u64 = default_reserve_tokens,
    keep_recent_tokens: u64 = default_keep_recent_tokens,
};

pub const Capacity = struct {
    admitted_input_tokens: u64,
    summary_allowance_tokens: u64,
    effective_keep_recent_tokens: u64,
};

pub const CapacityError = error{
    InvalidCompactionSettings,
    NoPostSummaryCapacity,
};

pub fn deriveCapacity(
    settings: Settings,
    model: *const models.Model,
    fixed_input_tokens: u64,
    normal_request_framing_tokens: u64,
) CapacityError!Capacity {
    if (settings.reserve_tokens >= model.capabilities.context_window_tokens or
        settings.max_input_tokens == 0 or
        settings.keep_recent_tokens == 0)
    {
        return error.InvalidCompactionSettings;
    }
    const hard_input_tokens = model.capabilities.context_window_tokens - settings.reserve_tokens;
    const admitted = @min(settings.max_input_tokens, hard_input_tokens);
    const allowance = @min(
        max_summary_tokens,
        @min(model.request_policy.max_output_tokens, settings.reserve_tokens / 4),
    );
    if (allowance < minimum_summary_tokens) return error.InvalidCompactionSettings;
    const reserved = fixed_input_tokens +| normal_request_framing_tokens +| allowance;
    if (reserved >= admitted) return error.NoPostSummaryCapacity;
    return .{
        .admitted_input_tokens = admitted,
        .summary_allowance_tokens = allowance,
        .effective_keep_recent_tokens = @min(settings.keep_recent_tokens, admitted - reserved),
    };
}

pub const NotCompactableReason = enum {
    no_valid_cut,
    oversized_current_user,
    unresolved_tool_pair,
    invalid_tool_pair,
};

pub const Ready = struct {
    summarize_start: usize,
    summarize_end: usize,
    prefix_start: ?usize = null,
    prefix_end: ?usize = null,
    first_kept_index: usize,
    first_kept_entry_id: transcript_mod.EntryId,

    pub fn isSplitTurn(self: Ready) bool {
        return self.prefix_start != null;
    }
};

pub const Preparation = union(enum) {
    no_change,
    not_compactable: NotCompactableReason,
    ready: Ready,
};

pub fn prepare(
    allocator: std.mem.Allocator,
    transcript: *const transcript_mod.Transcript,
    keep_recent_tokens: u64,
) !Preparation {
    const active_start = try transcript.activeStartIndex();
    const entries = transcript.entries.items;
    if (active_start == entries.len) return .no_change;

    switch (try validateToolPairs(allocator, entries[active_start..])) {
        .valid => {},
        .unresolved => return .{ .not_compactable = .unresolved_tool_pair },
        .invalid => return .{ .not_compactable = .invalid_tool_pair },
    }

    var total_tokens: u64 = 0;
    for (entries[active_start..]) |*entry| total_tokens +|= entryTokens(entry);
    if (total_tokens <= keep_recent_tokens) return .no_change;

    var suffix_tokens: u64 = 0;
    var threshold = entries.len;
    var i = entries.len;
    while (i > active_start) {
        i -= 1;
        const tokens = entryTokens(&entries[i]);
        if (suffix_tokens +| tokens > keep_recent_tokens) {
            threshold = i + 1;
            break;
        }
        suffix_tokens +|= tokens;
        threshold = i;
    }
    if (threshold <= active_start) threshold = active_start + 1;

    if (firstWholeTurnBoundary(entries, threshold)) |cut| {
        return .{ .ready = .{
            .summarize_start = active_start,
            .summarize_end = cut,
            .first_kept_index = cut,
            .first_kept_entry_id = entryIdAtCut(transcript, cut),
        } };
    }

    const current_turn_start = lastUserAtOrBefore(entries, threshold) orelse active_start;
    if (current_turn_start < active_start or entries[current_turn_start] != .user_text) {
        const split_cut = splitBoundary(entries, active_start, threshold) orelse {
            return .{ .not_compactable = .no_valid_cut };
        };
        if (split_cut <= active_start or split_cut > entries.len) {
            return .{ .not_compactable = .no_valid_cut };
        }
        return .{ .ready = .{
            .summarize_start = active_start,
            .summarize_end = split_cut,
            .first_kept_index = split_cut,
            .first_kept_entry_id = entryIdAtCut(transcript, split_cut),
        } };
    }
    const split_cut = splitBoundary(entries, current_turn_start, threshold) orelse {
        if (current_turn_start == active_start and entries[current_turn_start] == .user_text) {
            return .{ .not_compactable = .oversized_current_user };
        }
        return .{ .not_compactable = .no_valid_cut };
    };
    if (split_cut <= current_turn_start or split_cut > entries.len) {
        return .{ .not_compactable = .no_valid_cut };
    }
    return .{ .ready = .{
        .summarize_start = active_start,
        .summarize_end = current_turn_start,
        .prefix_start = current_turn_start,
        .prefix_end = split_cut,
        .first_kept_index = split_cut,
        .first_kept_entry_id = entryIdAtCut(transcript, split_cut),
    } };
}

fn entryIdAtCut(transcript: *const transcript_mod.Transcript, cut: usize) transcript_mod.EntryId {
    std.debug.assert(cut <= transcript.len());
    return if (cut == transcript.len()) transcript.nextEntryId() else transcript.entryIdAt(cut);
}

fn entryTokens(entry: *const transcript_mod.OwnedEntry) u64 {
    const bytes: u64 = switch (entry.*) {
        .user_text, .model_text, .system_note => |body| jsonStringPayloadBytes(body) +| 24,
        .assistant_tool_use => |calls| blk: {
            var total: u64 = 32;
            for (calls) |call| {
                total +|= jsonStringPayloadBytes(call.id) +|
                    jsonStringPayloadBytes(call.name) +|
                    jsonStringPayloadBytes(call.args_json) +| 32;
                if (call.reasoning_content) |reasoning| {
                    total +|= jsonStringPayloadBytes(reasoning);
                }
            }
            break :blk total;
        },
        .tool_result => |result| jsonStringPayloadBytes(result.tool_use_id) +|
            jsonStringPayloadBytes(result.tool_name) +|
            jsonStringPayloadBytes(result.llm_text) +| 40,
        .proof_card, .diagnostic_box, .verified_patch => 0,
    };
    return context_budget.estimateBytes(bytes);
}

/// Provider request bodies are JSON. Count the encoded payload, excluding the
/// two delimiter quotes, so retained suffix planning includes the framing that
/// exact request admission later observes. Opaque reasoning and tool output
/// commonly contain quotes, backslashes, and newlines, making raw byte counts
/// unsafe near the limit.
fn jsonStringPayloadBytes(value: []const u8) u64 {
    var total: u64 = 0;
    for (value) |byte| {
        total +|= switch (byte) {
            '"', '\\', '\n', '\r', '\t', 0x08, 0x0c => 2,
            0x00...0x07, 0x0b, 0x0e...0x1f => 6,
            else => 1,
        };
    }
    return total;
}

fn firstWholeTurnBoundary(
    entries: []const transcript_mod.OwnedEntry,
    threshold: usize,
) ?usize {
    var i = threshold;
    while (i < entries.len) : (i += 1) {
        if (entries[i] == .user_text) return i;
    }
    return null;
}

fn lastUserAtOrBefore(
    entries: []const transcript_mod.OwnedEntry,
    threshold: usize,
) ?usize {
    if (entries.len == 0) return null;
    var i = @min(threshold, entries.len - 1) + 1;
    while (i > 0) {
        i -= 1;
        if (entries[i] == .user_text) return i;
    }
    return null;
}

fn splitBoundary(
    entries: []const transcript_mod.OwnedEntry,
    turn_start: usize,
    threshold: usize,
) ?usize {
    var i = @max(turn_start + 1, threshold);
    while (i < entries.len) : (i += 1) {
        if (isAssistantBoundary(entries[i])) return i;
    }
    // A closed tool pair can end with a tool result whose preceding assistant
    // message is itself larger than the retained-suffix target. Backing up to
    // that assistant boundary would retain the mandatory provider reasoning
    // verbatim and defeat compaction. The exclusive tail boundary is safe once
    // validateToolPairs has proved that no tool call is unresolved. Keep an
    // oversized standalone user request verbatim rather than summarizing away
    // the only authoritative statement of the task.
    if (entries.len > turn_start + 1 or entries[turn_start] != .user_text) {
        return entries.len;
    }
    return null;
}

fn isAssistantBoundary(entry: transcript_mod.OwnedEntry) bool {
    return entry == .model_text or entry == .assistant_tool_use;
}

const PairState = enum { valid, unresolved, invalid };

fn validateToolPairs(
    allocator: std.mem.Allocator,
    entries: []const transcript_mod.OwnedEntry,
) !PairState {
    var open_calls: std.StringHashMapUnmanaged(void) = .empty;
    defer open_calls.deinit(allocator);
    for (entries) |entry| switch (entry) {
        .assistant_tool_use => |batch| for (batch) |call| {
            const result = try open_calls.getOrPut(allocator, call.id);
            if (result.found_existing) return .invalid;
        },
        .tool_result => |result| {
            if (!open_calls.remove(result.tool_use_id)) return .invalid;
        },
        else => {},
    };
    if (open_calls.count() != 0) return .unresolved;
    return .valid;
}

pub fn serializeSpan(
    allocator: std.mem.Allocator,
    transcript: *const transcript_mod.Transcript,
    start: usize,
    end: usize,
) ![]u8 {
    if (start > end or end > transcript.len()) return error.InvalidCompactionSpan;
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();
    for (transcript.entries.items[start..end]) |*entry| try serializeEntry(allocator, buffer.writer(), entry);
    return buffer.toOwnedSlice();
}

fn serializeEntry(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    entry: *const transcript_mod.OwnedEntry,
) !void {
    switch (entry.*) {
        .user_text => |body| try writeSection(writer, "User", body),
        .model_text => |body| try writeSection(writer, "Assistant", body),
        .system_note => |body| try writeSection(writer, "Internal context", body),
        .proof_card => |message| try writeSection(writer, "Verification: proof", message.llm_text),
        .diagnostic_box => |message| try writeSection(writer, "Verification: diagnostics", message.llm_text),
        .verified_patch => |message| try writeSection(writer, "Verification: applied patch", message.llm_text),
        .assistant_tool_use => |calls| {
            try writer.writeAll("[Assistant tool calls]:\n");
            for (calls) |call| {
                try writer.writeAll("- id=");
                try writer.writeAll(call.id);
                try writer.writeAll(" name=");
                try writer.writeAll(call.name);
                try writer.writeAll(" args=");
                const projected_args = try tool_catalog.projectArgsForModel(
                    allocator,
                    call.name,
                    call.args_json,
                );
                defer if (projected_args) |args| allocator.free(args);
                try writer.writeAll(projected_args orelse call.args_json);
                try writer.writeByte('\n');
            }
            try writer.writeByte('\n');
        },
        .tool_result => |result| {
            const capped = try capUtf8WithCount(allocator, result.llm_text, max_summary_tool_result_bytes);
            defer allocator.free(capped);
            try writer.writeAll("[Tool result]: id=");
            try writer.writeAll(result.tool_use_id);
            try writer.writeAll(" name=");
            try writer.writeAll(result.tool_name);
            try writer.writeAll(" status=");
            try writer.writeAll(if (result.ok) "ok" else "error");
            try writer.writeByte('\n');
            try writer.writeAll(capped);
            try writer.writeAll("\n\n");
        },
    }
}

fn writeSection(writer: *std.Io.Writer, label: []const u8, body: []const u8) !void {
    try writer.writeByte('[');
    try writer.writeAll(label);
    try writer.writeAll("]:\n");
    try writer.writeAll(body);
    try writer.writeAll("\n\n");
}

pub fn capUtf8WithCount(
    allocator: std.mem.Allocator,
    body: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (body.len <= max_bytes) return allocator.dupe(u8, body);
    const prefix = "\n...[truncated ";
    const suffix = " bytes]";
    var digits_buffer: [20]u8 = undefined;
    const maximum_digits = std.fmt.bufPrint(&digits_buffer, "{d}", .{body.len}) catch unreachable;
    const marker_reserve = prefix.len + maximum_digits.len + suffix.len;
    if (marker_reserve >= max_bytes) return allocator.dupe(u8, "...[truncated]");

    var keep = max_bytes - marker_reserve;
    while (keep > 0 and keep < body.len and body[keep] & 0xc0 == 0x80) keep -= 1;
    const dropped = body.len - keep;
    const digits = std.fmt.bufPrint(&digits_buffer, "{d}", .{dropped}) catch unreachable;
    const result = try allocator.alloc(u8, keep + prefix.len + digits.len + suffix.len);
    @memcpy(result[0..keep], body[0..keep]);
    var offset = keep;
    @memcpy(result[offset..][0..prefix.len], prefix);
    offset += prefix.len;
    @memcpy(result[offset..][0..digits.len], digits);
    offset += digits.len;
    @memcpy(result[offset..][0..suffix.len], suffix);
    return result;
}

pub const FileOps = struct {
    read_files: [][]u8,
    modified_files: [][]u8,

    pub fn deinit(self: *FileOps, allocator: std.mem.Allocator) void {
        for (self.read_files) |file| allocator.free(file);
        for (self.modified_files) |file| allocator.free(file);
        allocator.free(self.read_files);
        allocator.free(self.modified_files);
        self.* = undefined;
    }
};

pub fn extractFileOps(
    allocator: std.mem.Allocator,
    transcript: *const transcript_mod.Transcript,
    start: usize,
    end: usize,
) !FileOps {
    if (start > end or end > transcript.len()) return error.InvalidCompactionSpan;
    var reads: std.ArrayList([]u8) = .empty;
    defer reads.deinit(allocator);
    errdefer for (reads.items) |file| allocator.free(file);
    var modified: std.ArrayList([]u8) = .empty;
    defer modified.deinit(allocator);
    errdefer for (modified.items) |file| allocator.free(file);

    if (transcript.projection) |projection| {
        for (projection.read_files) |file| try addUnique(allocator, &reads, file);
        for (projection.modified_files) |file| try addUnique(allocator, &modified, file);
    }
    var successful_calls: std.StringHashMapUnmanaged(void) = .empty;
    defer successful_calls.deinit(allocator);
    for (transcript.entries.items[start..end]) |entry| switch (entry) {
        .tool_result => |result| if (result.ok) {
            try successful_calls.put(allocator, result.tool_use_id, {});
        },
        .verified_patch => |message| if (message.ui_payload) |payload| switch (payload) {
            .verified_patch => |patch| try addUnique(allocator, &modified, patch.file),
            else => {},
        },
        else => {},
    };
    for (transcript.entries.items[start..end]) |entry| switch (entry) {
        .assistant_tool_use => |calls| for (calls) |call| {
            if (std.mem.eql(u8, call.name, "propose_change_set")) continue;
            if (!successful_calls.contains(call.id)) continue;
            try extractCallFiles(allocator, &reads, call.args_json);
        },
        else => {},
    };
    sortFiles(reads.items);
    sortFiles(modified.items);
    const read_files = try reads.toOwnedSlice(allocator);
    errdefer {
        for (read_files) |file| allocator.free(file);
        allocator.free(read_files);
    }
    const modified_files = try modified.toOwnedSlice(allocator);
    errdefer {
        for (modified_files) |file| allocator.free(file);
        allocator.free(modified_files);
    }
    return .{
        .read_files = read_files,
        .modified_files = modified_files,
    };
}

fn extractCallFiles(
    allocator: std.mem.Allocator,
    reads: *std.ArrayList([]u8),
    args_json: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("path")) |value| if (value == .string) {
        try addUnique(allocator, reads, value.string);
    };
    if (parsed.value.object.get("file")) |value| if (value == .string) {
        try addUnique(allocator, reads, value.string);
    };
    if (parsed.value.object.get("files")) |value| if (value == .array) {
        for (value.array.items) |item| if (item == .string) {
            try addUnique(allocator, reads, item.string);
        };
    };
}

fn addUnique(
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]u8),
    file: []const u8,
) !void {
    if (file.len == 0) return;
    for (files.items) |present| if (std.mem.eql(u8, present, file)) return;
    const copy = try allocator.dupe(u8, file);
    errdefer allocator.free(copy);
    try files.append(allocator, copy);
}

fn sortFiles(files: [][]u8) void {
    std.mem.sort([]u8, files, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

pub const regular_system_prompt =
    "Summarize completed coding-agent history for continuation. " ++
    "Do not continue the conversation. Return only the required Markdown sections. " ++
    "Preserve goals, user constraints, decisions, blocked state, exact tool facts, and next actions. " ++
    "Do not emit <read-files> or <modified-files> blocks; the host appends those separately.";

pub const prefix_system_prompt =
    "Summarize only the early prefix of one active coding-agent turn. " ++
    "Do not continue the task. Return only Original Request, Early Progress, and Context for Suffix.";

pub fn buildRegularPrompt(
    allocator: std.mem.Allocator,
    previous_summary: ?[]const u8,
    conversation: []const u8,
    focus: ?[]const u8,
) ![]u8 {
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    if (previous_summary) |previous| {
        try writer.writeAll("Previous validated summary:\n<previous-summary>\n");
        // Projection summaries end with host-authored file-fact blocks. They
        // are cumulative typed state, not model prose. Feeding them back to a
        // repeated summarization invites the model to copy them into its
        // response, which correctly fails validation as invented file facts.
        // The controller carries those lists separately through FileOps, so
        // only the narrative belongs in the summarizer prompt.
        try writer.writeAll(summaryNarrative(previous));
        try writer.writeAll("\n</previous-summary>\n\n");
    }
    try writer.writeAll("New conversation span:\n<conversation>\n");
    try writer.writeAll(conversation);
    try writer.writeAll("</conversation>\n\n");
    if (focus) |instructions| if (std.mem.trim(u8, instructions, " \t\r\n").len > 0) {
        try writer.writeAll("Optional focus, subordinate to the fixed contract:\n<focus>\n");
        try writer.writeAll(std.mem.trim(u8, instructions, " \t\r\n"));
        try writer.writeAll("\n</focus>\n\n");
    };
    try writer.writeAll(
        "Return exactly this section structure with substantive content in every leaf section:\n" ++
            "## Goal\n\n" ++
            "## Constraints & Preferences\n\n" ++
            "## Progress\n" ++
            "### Done\n\n" ++
            "### In Progress\n\n" ++
            "### Blocked\n\n" ++
            "## Key Decisions\n\n" ++
            "## Next Steps\n\n" ++
            "## Critical Context\n",
    );
    return buffer.toOwnedSlice();
}

fn summaryNarrative(summary: []const u8) []const u8 {
    const marker = "\n\n<read-files>\n";
    const marker_start = std.mem.lastIndexOf(u8, summary, marker) orelse return summary;
    return summary[0..marker_start];
}

pub fn buildPrefixPrompt(
    allocator: std.mem.Allocator,
    conversation: []const u8,
    focus: ?[]const u8,
) ![]u8 {
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    try writer.writeAll("Active turn prefix:\n<conversation>\n");
    try writer.writeAll(conversation);
    try writer.writeAll("</conversation>\n\n");
    if (focus) |instructions| if (std.mem.trim(u8, instructions, " \t\r\n").len > 0) {
        try writer.writeAll("Optional focus, subordinate to the fixed contract:\n<focus>\n");
        try writer.writeAll(std.mem.trim(u8, instructions, " \t\r\n"));
        try writer.writeAll("\n</focus>\n\n");
    };
    try writer.writeAll(
        "Return exactly:\n" ++
            "## Original Request\n\n" ++
            "## Early Progress\n\n" ++
            "## Context for Suffix\n",
    );
    return buffer.toOwnedSlice();
}

const regular_headings = [_][]const u8{
    "## Goal",
    "## Constraints & Preferences",
    "## Progress",
    "### Done",
    "### In Progress",
    "### Blocked",
    "## Key Decisions",
    "## Next Steps",
    "## Critical Context",
};

const prefix_headings = [_][]const u8{
    "## Original Request",
    "## Early Progress",
    "## Context for Suffix",
};

pub fn validateRegularSummary(summary: []const u8) !void {
    if (std.mem.indexOf(u8, summary, "<read-files>") != null or
        std.mem.indexOf(u8, summary, "<modified-files>") != null)
    {
        return error.SummaryInventedFileFacts;
    }
    return validateHeadings(summary, &regular_headings, 2);
}

pub fn validatePrefixSummary(summary: []const u8) !void {
    return validateHeadings(summary, &prefix_headings, null);
}

fn validateHeadings(
    summary: []const u8,
    headings: []const []const u8,
    empty_content_heading: ?usize,
) !void {
    const trimmed = std.mem.trim(u8, summary, " \t\r\n");
    if (trimmed.len == 0) return error.EmptySummary;
    if (!std.mem.startsWith(u8, trimmed, headings[0])) return error.MalformedSummary;

    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "##")) continue;
        var known = false;
        for (headings) |heading| {
            if (std.mem.eql(u8, line, heading)) {
                known = true;
                break;
            }
        }
        if (!known) return error.MalformedSummary;
    }

    var positions: [regular_headings.len]usize = undefined;
    if (headings.len > positions.len) unreachable;
    for (headings, 0..) |heading, index| {
        positions[index] = findHeading(trimmed, heading, if (index == 0) 0 else positions[index - 1] + headings[index - 1].len) orelse
            return error.MalformedSummary;
        if (findHeading(trimmed, heading, positions[index] + heading.len) != null) {
            return error.MalformedSummary;
        }
    }
    for (headings, 0..) |heading, index| {
        if (index > 0 and positions[index] <= positions[index - 1]) return error.MalformedSummary;
        if (empty_content_heading) |empty_index| {
            if (index == empty_index) continue;
        }
        const content_start = positions[index] + heading.len;
        const content_end = if (index + 1 < headings.len) positions[index + 1] else trimmed.len;
        if (std.mem.trim(u8, trimmed[content_start..content_end], " \t\r\n").len == 0) {
            return error.MalformedSummary;
        }
    }
}

fn findHeading(text: []const u8, heading: []const u8, start: usize) ?usize {
    var cursor = start;
    while (std.mem.indexOfPos(u8, text, cursor, heading)) |position| {
        const before_ok = position == 0 or text[position - 1] == '\n';
        const after = position + heading.len;
        const after_ok = after == text.len or text[after] == '\n' or text[after] == '\r';
        if (before_ok and after_ok) return position;
        cursor = position + 1;
    }
    return null;
}

pub fn assembleSummary(
    allocator: std.mem.Allocator,
    regular_summary: ?[]const u8,
    prefix_summary: ?[]const u8,
    file_ops: FileOps,
) ![]u8 {
    if (regular_summary == null and prefix_summary == null) return error.EmptySummary;
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    if (regular_summary) |summary| try writer.writeAll(std.mem.trim(u8, summary, " \t\r\n"));
    if (prefix_summary) |summary| {
        if (regular_summary != null) try writer.writeAll("\n\n");
        try writer.writeAll(std.mem.trim(u8, summary, " \t\r\n"));
    }
    try writer.writeAll("\n\n<read-files>\n");
    for (file_ops.read_files) |file| {
        try writer.writeAll(file);
        try writer.writeByte('\n');
    }
    try writer.writeAll("</read-files>\n\n<modified-files>\n");
    for (file_ops.modified_files) |file| {
        try writer.writeAll(file);
        try writer.writeByte('\n');
    }
    try writer.writeAll("</modified-files>");
    return buffer.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const turn = turn_mod;

fn addText(tr: *transcript_mod.Transcript, kind: enum { user, assistant }, body: []const u8) !void {
    try tr.append(testing.allocator, switch (kind) {
        .user => .{ .user_text = body },
        .assistant => .{ .model_text = body },
    });
}

test "deriveCapacity reserves summary output on the 40960-token Qwen model" {
    const model = try models.resolveForProvider(.local, "mlx-community/Qwen3-8B-4bit");
    const capacity = try deriveCapacity(.{}, model, 8_000, 500);
    try testing.expectEqual(@as(u64, 24_576), capacity.admitted_input_tokens);
    try testing.expectEqual(@as(u64, 4_096), capacity.summary_allowance_tokens);
    try testing.expectEqual(@as(u64, 11_980), capacity.effective_keep_recent_tokens);
    try testing.expectError(error.NoPostSummaryCapacity, deriveCapacity(.{}, model, 20_000, 500));
    try testing.expectError(
        error.InvalidCompactionSettings,
        deriveCapacity(.{ .reserve_tokens = minimum_reserve_tokens - 1 }, model, 8_000, 500),
    );
}

test "prepare returns no change for empty and small active history" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    try testing.expect((try prepare(testing.allocator, &tr, 10)) == .no_change);
    try addText(&tr, .user, "small");
    try testing.expect((try prepare(testing.allocator, &tr, 100)) == .no_change);
}

test "prepare prefers a whole external-user turn boundary" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    try addText(&tr, .user, "first " ** 100);
    try addText(&tr, .assistant, "answer " ** 100);
    try addText(&tr, .user, "second");
    try addText(&tr, .assistant, "kept");
    // Wide enough for the whole two-entry turn and far short of the 700-byte
    // assistant answer before it, in the request density `entryTokens` uses.
    const ready = (try prepare(testing.allocator, &tr, 30)).ready;
    try testing.expect(!ready.isSplitTurn());
    try testing.expectEqual(@as(usize, 2), ready.first_kept_index);
    try testing.expectEqual(@as(transcript_mod.EntryId, 3), ready.first_kept_entry_id);
}

test "prepare splits an oversized turn only at an assistant boundary" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    try addText(&tr, .user, "large request");
    try addText(&tr, .assistant, "early " ** 100);
    const calls = [_]turn.ToolCall{.{ .id = "call_1", .name = "workspace_read_file", .args_json = "{\"path\":\"a.ts\"}" }};
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "result " ** 100,
    } });
    try addText(&tr, .assistant, "late answer");
    const ready = (try prepare(testing.allocator, &tr, 30)).ready;
    try testing.expect(ready.isSplitTurn());
    try testing.expect(ready.first_kept_index != 3);
    try testing.expect(ready.first_kept_index < tr.len());
    try testing.expect(isAssistantBoundary(tr.entries.items[ready.first_kept_index]));
}

test "prepare repeatedly compacts an active split-turn suffix without its user entry" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    try addText(&tr, .user, "original request");
    try addText(&tr, .assistant, "early " ** 100);
    try addText(&tr, .assistant, "middle " ** 100);
    try addText(&tr, .assistant, "retained answer");
    try tr.replaceProjection(testing.allocator, "validated prior split summary", 2);

    const ready = (try prepare(testing.allocator, &tr, 10)).ready;
    try testing.expectEqual(@as(usize, 1), ready.summarize_start);
    try testing.expect(ready.summarize_end > ready.summarize_start);
    try testing.expectEqual(ready.summarize_end, ready.first_kept_index);
    try testing.expect(!ready.isSplitTurn());
}

test "prepare protects unresolved pairs and an oversized single user ask" {
    var unresolved: transcript_mod.Transcript = .{};
    defer unresolved.deinit(testing.allocator);
    try addText(&unresolved, .user, "request");
    const calls = [_]turn.ToolCall{.{ .id = "call_1", .name = "workspace_read_file", .args_json = "{}" }};
    try unresolved.append(testing.allocator, .{ .assistant_tool_use = &calls });
    const pair_result = try prepare(testing.allocator, &unresolved, 1);
    try testing.expectEqual(NotCompactableReason.unresolved_tool_pair, pair_result.not_compactable);

    var oversized: transcript_mod.Transcript = .{};
    defer oversized.deinit(testing.allocator);
    try addText(&oversized, .user, "x" ** 1000);
    const user_result = try prepare(testing.allocator, &oversized, 1);
    try testing.expectEqual(NotCompactableReason.oversized_current_user, user_result.not_compactable);
}

test "prepare counts opaque tool reasoning when selecting the retained suffix" {
    const reasoning = try testing.allocator.alloc(u8, 44_720);
    defer testing.allocator.free(reasoning);
    @memset(reasoning, 'r');
    const first_result = try testing.allocator.alloc(u8, 5_000);
    defer testing.allocator.free(first_result);
    @memset(first_result, 'x');

    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    try tr.append(testing.allocator, .{ .user_text = "finish the workflow" });
    const large_call = [_]turn.ToolCall{.{
        .id = "large",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
        .reasoning_content = reasoning,
    }};
    try tr.append(testing.allocator, .{ .assistant_tool_use = &large_call });
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "large",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = first_result,
    } });
    const recent_call = [_]turn.ToolCall{.{
        .id = "recent",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"zttp.json\"}",
    }};
    try tr.append(testing.allocator, .{ .assistant_tool_use = &recent_call });
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "recent",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "{}",
    } });

    const result = try prepare(testing.allocator, &tr, 12_000);
    switch (result) {
        .ready => |ready| {
            try testing.expectEqual(@as(usize, 3), ready.first_kept_index);
            try testing.expectEqual(@as(transcript_mod.EntryId, 4), ready.first_kept_entry_id);
        },
        else => return error.TestExpectedCompactionCut,
    }
}

test "prepare summarizes a completed oversized tool tail instead of retaining it" {
    const reasoning = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(reasoning);
    @memset(reasoning, 'r');

    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    try tr.append(testing.allocator, .{ .user_text = "finish the repair" });
    const calls = [_]turn.ToolCall{.{
        .id = "large",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
        .reasoning_content = reasoning,
    }};
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "large",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "closed",
    } });

    const result = try prepare(testing.allocator, &tr, 20_000);
    switch (result) {
        .ready => |ready| {
            try testing.expect(ready.isSplitTurn());
            try testing.expectEqual(tr.len(), ready.first_kept_index);
            try testing.expectEqual(tr.nextEntryId(), ready.first_kept_entry_id);
            try testing.expectEqual(tr.len(), ready.prefix_end.?);
        },
        else => return error.TestExpectedCompactionCut,
    }
}

test "tool pair validation permits an id reused after its result" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    const calls = [_]turn.ToolCall{.{
        .id = "provider-reused-id",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"a.ts\"}",
    }};
    for (0..2) |_| {
        try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
        try tr.append(testing.allocator, .{ .tool_result = .{
            .tool_use_id = "provider-reused-id",
            .tool_name = "workspace_read_file",
            .ok = true,
            .llm_text = "ok",
        } });
    }

    try testing.expectEqual(PairState.valid, try validateToolPairs(testing.allocator, tr.entries.items));
}

test "serializeSpan uses explicit labels exact args and a UTF-8-safe 2000-byte tool cap" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    try addText(&tr, .user, "inspect");
    const calls = [_]turn.ToolCall{.{
        .id = "call_1",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"a.ts\",\"range\":{\"start\":1}}",
    }};
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "é" ** 1200,
    } });
    const serialized = try serializeSpan(testing.allocator, &tr, 0, tr.len());
    defer testing.allocator.free(serialized);
    try testing.expect(std.mem.indexOf(u8, serialized, "[User]:\ninspect") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "args={\"path\":\"a.ts\",\"range\":{\"start\":1}}") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "[Tool result]: id=call_1") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "...[truncated ") != null);
    try testing.expect(std.unicode.utf8ValidateSlice(serialized));
}

test "serializeSpan hides host propose_change_set baseline from the summarizer" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    const raw_args =
        "{\"changes\":[{\"file\":\"handler.ts\",\"content\":\"new\",\"before\":\"old\",\"baseline_state\":\"present\",\"baseline_sha256\":\"0123456789abcdef\"}]}";
    const calls = [_]turn.ToolCall{.{
        .id = "apply_1",
        .name = "propose_change_set",
        .args_json = raw_args,
    }};
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });

    const serialized = try serializeSpan(testing.allocator, &tr, 0, tr.len());
    defer testing.allocator.free(serialized);

    switch (tr.at(0).*) {
        .assistant_tool_use => |raw_calls| try testing.expectEqualStrings(raw_args, raw_calls[0].args_json),
        else => return error.TestExpectedRawToolUse,
    }
    try testing.expect(std.mem.indexOf(u8, serialized, "args={\"changes\":[{\"file\":\"handler.ts\",\"content\":\"new\"}]}") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "baseline_state") == null);
    try testing.expect(std.mem.indexOf(u8, serialized, "baseline_sha256") == null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"before\"") == null);
}

test "extractFileOps is cumulative unique and deterministic" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    const calls = [_]turn.ToolCall{
        .{ .id = "r2", .name = "workspace_read_file", .args_json = "{\"path\":\"z.ts\"}" },
        .{ .id = "r1", .name = "zts_check", .args_json = "{\"file\":\"a.ts\"}" },
        .{ .id = "e1", .name = "propose_change_set", .args_json = "{\"changes\":[{\"file\":\"m.ts\",\"content\":\"x\"}]}" },
    };
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
    for (calls) |call| try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = call.id,
        .tool_name = call.name,
        .ok = !std.mem.eql(u8, call.id, "e1"),
        .llm_text = "ok",
    } });
    const patch_source: ui_payload_mod.UiPayload = .{ .verified_patch = .{
        .file = @constCast("m.ts"),
        .policy_hash = @constCast("a" ** 64),
        .applied_at_unix_ms = 1,
        .stats = .{ .total = 0, .new = 0 },
        .before = null,
        .after = @constCast("x"),
        .unified_diff = @constCast(""),
        .hunks = &.{},
        .violations = &.{},
        .before_properties = null,
        .after_properties = null,
        .prove = null,
        .system = null,
        .rule_citations = &.{},
        .post_apply_ok = true,
        .post_apply_summary = null,
    } };
    const patch_text = try testing.allocator.dupe(u8, "verified: m.ts");
    errdefer testing.allocator.free(patch_text);
    var patch_payload = try patch_source.clone(testing.allocator);
    errdefer patch_payload.deinit(testing.allocator);
    try tr.entries.append(testing.allocator, .{ .verified_patch = .{
        .llm_text = patch_text,
        .ui_payload = patch_payload,
    } });
    var ops = try extractFileOps(testing.allocator, &tr, 0, tr.len());
    defer ops.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), ops.read_files.len);
    try testing.expectEqualStrings("a.ts", ops.read_files[0]);
    try testing.expectEqualStrings("z.ts", ops.read_files[1]);
    try testing.expectEqualStrings("m.ts", ops.modified_files[0]);
}

test "extractFileOps excludes failed reads and rejected edit attempts" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    const calls = [_]turn.ToolCall{
        .{ .id = "read-failed", .name = "workspace_read_file", .args_json = "{\"path\":\"missing.ts\"}" },
        .{ .id = "edit-rejected", .name = "propose_change_set", .args_json = "{\"changes\":[{\"file\":\"rejected.ts\",\"content\":\"x\"}]}" },
    };
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
    for (calls) |call| try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = call.id,
        .tool_name = call.name,
        .ok = false,
        .llm_text = "rejected",
    } });

    var ops = try extractFileOps(testing.allocator, &tr, 0, tr.len());
    defer ops.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ops.read_files.len);
    try testing.expectEqual(@as(usize, 0), ops.modified_files.len);
}

const valid_regular =
    "## Goal\nShip compaction\n\n" ++
    "## Constraints & Preferences\n- Preserve proofs\n\n" ++
    "## Progress\n### Done\n- [x] Core\n\n" ++
    "### In Progress\n- [ ] Wiring\n\n" ++
    "### Blocked\n- None\n\n" ++
    "## Key Decisions\n- Host owns files\n\n" ++
    "## Next Steps\n1. Test\n\n" ++
    "## Critical Context\n- Keep IDs";

test "summary validators reject empty malformed and model-authored file facts" {
    try validateRegularSummary(valid_regular);
    try testing.expectError(error.EmptySummary, validateRegularSummary(" \n"));
    try testing.expectError(error.MalformedSummary, validateRegularSummary("## Goal\nx"));
    const invented = valid_regular ++ "\n<read-files>\nx.ts\n</read-files>";
    try testing.expectError(error.SummaryInventedFileFacts, validateRegularSummary(invented));
    try validatePrefixSummary(
        "## Original Request\nBuild it\n\n## Early Progress\nCore done\n\n## Context for Suffix\nContinue wiring",
    );
}

test "regular prompt contains previous summary new span focus and fixed contract" {
    const prompt = try buildRegularPrompt(testing.allocator, valid_regular, "[User]:\nnew", "focus on blocked work");
    defer testing.allocator.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "<previous-summary>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "[User]:\nnew") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "focus on blocked work") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "## Critical Context") != null);
}

test "repeated compaction does not feed host file facts back to the summarizer" {
    const previous = valid_regular ++
        "\n\n<read-files>\nhandler.ts\n</read-files>\n\n" ++
        "<modified-files>\nhandler.ts\n</modified-files>";
    const prompt = try buildRegularPrompt(testing.allocator, previous, "[User]:\ncontinue", null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, valid_regular) != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<read-files>") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<modified-files>") == null);
}
