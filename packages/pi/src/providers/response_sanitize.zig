//! Identical response parsing, inspection, and reasoning removal for both Chat Completions
//! providers. The two clients differ only in which reasoning fields a stored response keeps;
//! they pass that rule in as `ReasoningRule`. Each client keeps its own `decodeResponseValue`
//! because tool-call ids and raw tool envelopes differ.

const std = @import("std");
const zts = @import("zts");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const capture_sink = @import("capture_sink.zig");

pub const max_response_body_bytes: usize = 16 * 1024 * 1024;
pub const max_response_json_depth: usize = 64;

/// Which reasoning fields survive sanitizing.
pub const ReasoningRule = enum {
    /// Remove `reasoning` at every depth. `reasoning_content` stays (local).
    reasoning_only,
    /// Remove `reasoning` at every depth. Keep `reasoning_content` only on a message that has a
    /// non-empty tool-call batch. DeepSeek V4 requires that one opaque continuation back
    /// verbatim; final-answer reasoning stays private (DeepSeek).
    keep_tool_call_continuation,
};

pub const SanitizedResponse = struct {
    value: std.json.Value,
    bytes: []u8,
};

const max_parser_warnings = @typeInfo(capture_sink.ParserWarning).@"enum".field_names.len;

pub const ResponseInspection = struct {
    finish_reason: ?capture_sink.FinishReason = null,
    completion_tokens: ?u64 = null,
    field_presence: capture_sink.ResponseFieldPresence = .{},
    warnings: [max_parser_warnings]capture_sink.ParserWarning = undefined,
    warning_count: usize = 0,

    pub fn addWarning(self: *ResponseInspection, warning: capture_sink.ParserWarning) void {
        for (self.warnings[0..self.warning_count]) |existing| {
            if (existing == warning) return;
        }
        if (self.warning_count == self.warnings.len) return;
        self.warnings[self.warning_count] = warning;
        self.warning_count += 1;
    }

    pub fn warningSlice(self: *const ResponseInspection) []const capture_sink.ParserWarning {
        return self.warnings[0..self.warning_count];
    }
};

fn inspectResponseValue(inspection: *ResponseInspection, root: std.json.Value, rule: ReasoningRule) void {
    if (root != .object) {
        inspection.addWarning(.root_not_object);
        return;
    }

    inspectUsage(inspection, root.object.get("usage"));

    const choices = root.object.get("choices") orelse {
        inspection.addWarning(.choices_missing);
        return;
    };
    inspection.field_presence.choices = true;
    if (choices != .array) {
        inspection.addWarning(.choices_not_array);
        return;
    }
    if (choices.array.items.len == 0) {
        inspection.addWarning(.choices_empty);
        return;
    }

    inspection.field_presence.first_choice = true;
    const choice = choices.array.items[0];
    if (choice != .object) {
        inspection.addWarning(.first_choice_not_object);
        return;
    }
    if (choice.object.get("finish_reason")) |finish_reason| {
        inspection.field_presence.finish_reason = true;
        switch (finish_reason) {
            .string => |value| {
                if (std.meta.stringToEnum(capture_sink.FinishReason, value)) |known| {
                    inspection.finish_reason = known;
                } else {
                    inspection.addWarning(.finish_reason_unknown);
                }
            },
            .null => inspection.addWarning(.finish_reason_null),
            else => inspection.addWarning(.finish_reason_invalid),
        }
    }

    const message = choice.object.get("message") orelse {
        inspection.addWarning(.message_missing);
        inspection.addWarning(.assistant_output_missing);
        return;
    };
    inspection.field_presence.message = true;
    if (message != .object) {
        inspection.addWarning(.message_not_object);
        inspection.addWarning(.assistant_output_missing);
        return;
    }

    var has_output = false;
    if (message.object.get("content")) |content| {
        inspection.field_presence.content = true;
        switch (content) {
            .string => |value| {
                if (value.len == 0) {
                    inspection.addWarning(.content_empty);
                } else {
                    has_output = true;
                }
            },
            .null => inspection.addWarning(.content_null),
            else => inspection.addWarning(.content_invalid),
        }
    }
    inspection.field_presence.reasoning = message.object.get("reasoning") != null or
        (rule == .keep_tool_call_continuation and message.object.get("reasoning_content") != null);
    if (message.object.get("tool_calls")) |tool_calls| {
        inspection.field_presence.tool_calls = true;
        if (tool_calls != .array) {
            inspection.addWarning(.tool_calls_invalid);
        } else if (tool_calls.array.items.len == 0) {
            inspection.addWarning(.tool_calls_empty);
        } else {
            has_output = true;
        }
    }
    if (!has_output) inspection.addWarning(.assistant_output_missing);
}

fn inspectUsage(inspection: *ResponseInspection, maybe_usage: ?std.json.Value) void {
    const usage = maybe_usage orelse {
        inspection.addWarning(.usage_missing);
        inspection.addWarning(.completion_tokens_missing);
        return;
    };
    inspection.field_presence.usage = true;
    if (usage == .null) {
        inspection.addWarning(.completion_tokens_missing);
        return;
    }
    if (usage != .object) {
        inspection.addWarning(.usage_invalid);
        inspection.addWarning(.completion_tokens_missing);
        return;
    }
    const completion_tokens = usage.object.get("completion_tokens") orelse {
        inspection.addWarning(.completion_tokens_missing);
        return;
    };
    inspection.field_presence.completion_tokens = true;
    if (completion_tokens != .integer or completion_tokens.integer < 0) {
        inspection.addWarning(.completion_tokens_invalid);
        return;
    }
    inspection.completion_tokens = @intCast(completion_tokens.integer);
}

pub fn monotonicNowNs() ?u64 {
    return zts.monotonicNowNs() catch null;
}

pub fn elapsedMs(started_ns: ?u64) ?u64 {
    const start = started_ns orelse return null;
    const end = monotonicNowNs() orelse return null;
    return (end -| start) / std.time.ns_per_ms;
}

pub fn parseSanitizedResponseWithInspection(
    arena: std.mem.Allocator,
    response_body: []const u8,
    inspection: ?*ResponseInspection,
    rule: ReasoningRule,
) !SanitizedResponse {
    if (response_body.len > max_response_body_bytes) {
        if (inspection) |value| value.addWarning(.response_too_large);
        return error.ResponseTooLarge;
    }
    validateResponseDepth(arena, response_body) catch |err| {
        if (inspection) |value| value.addWarning(.json_parse_failed);
        return err;
    };
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, response_body, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_response_body_bytes,
    }) catch {
        if (inspection) |value| value.addWarning(.json_parse_failed);
        return error.InvalidResponseJson;
    };
    if (inspection) |value| inspectResponseValue(value, root, rule);
    removeReasoning(&root, rule);
    var out = TextBuffer.init(arena);
    defer out.deinit();
    std.json.Stringify.value(root, .{}, out.writer()) catch return error.InvalidResponseJson;
    return .{ .value = root, .bytes = try out.toOwnedSlice() };
}

fn validateResponseDepth(arena: std.mem.Allocator, response_body: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(arena, response_body);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch return error.InvalidResponseJson;
        if (scanner.stackHeight() > max_response_json_depth) return error.InvalidResponseJson;
        if (token == .end_of_document) return;
    }
}

fn removeReasoning(value: *std.json.Value, rule: ReasoningRule) void {
    switch (value.*) {
        .object => |*object| {
            if (rule == .keep_tool_call_continuation) {
                const has_tool_calls = if (object.get("tool_calls")) |calls|
                    calls == .array and calls.array.items.len > 0
                else
                    false;
                if (!has_tool_calls) _ = object.orderedRemove("reasoning_content");
            }
            _ = object.orderedRemove("reasoning");
            for (object.values()) |*child| removeReasoning(child, rule);
        },
        .array => |*array| for (array.items) |*child| removeReasoning(child, rule),
        else => {},
    }
}
