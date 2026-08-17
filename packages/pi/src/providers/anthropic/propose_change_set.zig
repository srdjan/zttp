//! Provider-neutral bridge from `propose_change_set` tool calls to the turn
//! machine's first-class ordered change-set reply.

const std = @import("std");
const turn = @import("../../turn.zig");
const tool_catalog = @import("../tool_catalog.zig");

pub const tool_name = tool_catalog.propose_change_set.name;
pub const tool_description = tool_catalog.propose_change_set.description;
pub const input_schema_literal = tool_catalog.propose_change_set.input_schema;

pub const max_changes: usize = 32;

pub const RemapError = error{
    InvalidChangeSetArgs,
    OutputTruncated,
};

/// Which refusal fired, for diagnostics only.
///
/// `maybeRemap` refuses ten distinct shapes and returned one error for all of
/// them. That was survivable while nothing depended on telling them apart, and
/// stopped being so once `InvalidChangeSetArgs` began sinking corpus recordings:
/// three occurrences in six runs, each a different case, and no way to say
/// whether the model had added an explanatory field, duplicated a key, or
/// forged a host-authoritative one. The body that would answer it is gone by
/// then - the capture refuses it and the diagnostics record is metadata-only.
///
/// This is a tag, never content. It carries no bytes from the model.
pub const RejectionShape = enum {
    truncated,
    args_not_json,
    args_not_object,
    args_extra_top_level_key,
    changes_missing,
    changes_not_array,
    changes_empty,
    changes_too_many,
    change_not_object,
    change_file_missing,
    change_content_missing,
    change_host_authoritative_key,
    change_extra_field,
    change_field_type,
};

const host_authoritative_keys = tool_catalog.propose_change_set.host_authoritative_keys;

fn remapFailure(
    stop_reason: ?[]const u8,
    shape: RejectionShape,
    observed: ?*?RejectionShape,
) RemapError {
    if (stop_reason) |reason| {
        if (std.mem.eql(u8, reason, "max_tokens")) {
            if (observed) |out| out.* = .truncated;
            return error.OutputTruncated;
        }
    }
    if (observed) |out| out.* = shape;
    return error.InvalidChangeSetArgs;
}

pub fn maybeRemap(
    arena: std.mem.Allocator,
    reply: turn.AssistantReply,
    stop_reason: ?[]const u8,
) !turn.AssistantReply {
    return maybeRemapObserved(arena, reply, stop_reason, null);
}

/// `maybeRemap`, reporting which refusal fired through `observed`.
///
/// Separate rather than a parameter on the one function because nine of the ten
/// call sites have nowhere to put the answer; only the recording clients do.
pub fn maybeRemapObserved(
    arena: std.mem.Allocator,
    reply: turn.AssistantReply,
    stop_reason: ?[]const u8,
    observed: ?*?RejectionShape,
) !turn.AssistantReply {
    switch (reply.response) {
        .tool_calls => |calls| {
            if (calls.len != 1) return reply;
            if (!std.mem.eql(u8, calls[0].name, tool_name)) return reply;

            // Ordered to attribute, not merely to refuse. The accept set is
            // identical to the single-error version this replaces - every
            // condition below still has to hold - but a missing field, an extra
            // field and a forged host-authoritative field now report as three
            // different things instead of one.
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, calls[0].args_json, .{
                .duplicate_field_behavior = .@"error",
            }) catch return remapFailure(stop_reason, .args_not_json, observed);
            if (parsed != .object) return remapFailure(stop_reason, .args_not_object, observed);
            const changes_value = parsed.object.get("changes") orelse
                return remapFailure(stop_reason, .changes_missing, observed);
            if (parsed.object.count() != 1) {
                return remapFailure(stop_reason, .args_extra_top_level_key, observed);
            }
            if (changes_value != .array) return remapFailure(stop_reason, .changes_not_array, observed);
            if (changes_value.array.items.len == 0) {
                return remapFailure(stop_reason, .changes_empty, observed);
            }
            if (changes_value.array.items.len > max_changes) {
                return remapFailure(stop_reason, .changes_too_many, observed);
            }

            const additional = try arena.alloc(turn.Change, changes_value.array.items.len - 1);
            var first: turn.Change = undefined;
            for (changes_value.array.items, 0..) |value, index| {
                if (value != .object) return remapFailure(stop_reason, .change_not_object, observed);
                const file_value = value.object.get("file") orelse
                    return remapFailure(stop_reason, .change_file_missing, observed);
                const content_value = value.object.get("content") orelse
                    return remapFailure(stop_reason, .change_content_missing, observed);
                // Before the arity check, so a forged baseline reports as what
                // it is rather than as "wrong number of fields".
                for (host_authoritative_keys) |key| {
                    if (value.object.get(key) != null) {
                        return remapFailure(stop_reason, .change_host_authoritative_key, observed);
                    }
                }
                if (value.object.count() != 2) {
                    return remapFailure(stop_reason, .change_extra_field, observed);
                }
                if (file_value != .string or content_value != .string or file_value.string.len == 0) {
                    return remapFailure(stop_reason, .change_field_type, observed);
                }
                const change: turn.Change = .{ .file = file_value.string, .content = content_value.string };
                if (index == 0) {
                    first = change;
                } else {
                    additional[index - 1] = change;
                }
            }

            return .{
                .preamble = reply.preamble,
                .response = .{ .change_set = .{
                    .file = first.file,
                    .content = first.content,
                    .additional = additional,
                    .reasoning_content = calls[0].reasoning_content,
                } },
            };
        },
        else => return reply,
    }
}

const testing = std.testing;

test "single proposal becomes an ordered change set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{.{
        .id = "toolu_changes",
        .name = tool_name,
        .args_json =
        \\{"changes":[{"file":"src/a.ts","content":"a"},{"file":"src/b.tsx","content":"b"}]}
        ,
        .reasoning_content = "opaque continuation",
    }};
    const out = try maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null);
    switch (out.response) {
        .change_set => |set| {
            try testing.expectEqual(@as(usize, 2), set.len());
            try testing.expectEqualStrings("src/a.ts", set.at(0).file);
            try testing.expectEqualStrings("src/b.tsx", set.at(1).file);
            try testing.expectEqualStrings("opaque continuation", set.reasoning_content.?);
        },
        else => return error.TestFailed,
    }
}

test "each refusal reports its own shape" {
    // The enum is only worth having if distinct inputs reach distinct tags. A
    // test that merely checked "some shape was reported" would pass on a
    // function that answered `args_not_json` to everything - which is exactly
    // the single-error behaviour this replaces.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { args: []const u8, shape: RejectionShape }{
        .{ .args = "{", .shape = .args_not_json },
        // Duplicate keys parse as an error by construction, so they land here
        // rather than in a shape of their own.
        .{ .args = "{\"changes\":[],\"changes\":[]}", .shape = .args_not_json },
        .{ .args = "[]", .shape = .args_not_object },
        .{ .args = "{}", .shape = .changes_missing },
        .{ .args = "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\"}],\"extra\":true}", .shape = .args_extra_top_level_key },
        .{ .args = "{\"changes\":{}}", .shape = .changes_not_array },
        .{ .args = "{\"changes\":[]}", .shape = .changes_empty },
        .{ .args = "{\"changes\":[1]}", .shape = .change_not_object },
        .{ .args = "{\"changes\":[{\"content\":\"x\"}]}", .shape = .change_file_missing },
        .{ .args = "{\"changes\":[{\"file\":\"a.ts\"}]}", .shape = .change_content_missing },
        .{ .args = "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\",\"baseline_sha256\":\"forged\"}]}", .shape = .change_host_authoritative_key },
        .{ .args = "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\",\"note\":\"why\"}]}", .shape = .change_extra_field },
        .{ .args = "{\"changes\":[{\"file\":\"\",\"content\":\"x\"}]}", .shape = .change_field_type },
    };

    for (cases) |case| {
        const calls = [_]turn.ToolCall{.{ .id = "toolu_bad", .name = tool_name, .args_json = case.args }};
        var observed: ?RejectionShape = null;
        try testing.expectError(
            error.InvalidChangeSetArgs,
            maybeRemapObserved(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null, &observed),
        );
        try testing.expectEqual(case.shape, observed orelse return error.TestExpectedShape);
    }
}

test "truncation outranks the shape it would otherwise report" {
    // A response cut off mid-object is unparseable, so without the stop-reason
    // check it would report `args_not_json` and send the reader hunting for a
    // malformed proposal that never existed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{.{
        .id = "toolu_bad",
        .name = tool_name,
        .args_json = "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"",
    }};
    var observed: ?RejectionShape = null;
    try testing.expectError(
        error.OutputTruncated,
        maybeRemapObserved(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, "max_tokens", &observed),
    );
    try testing.expectEqual(RejectionShape.truncated, observed orelse return error.TestExpectedShape);
}

test "proposal shape fails closed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const invalid = [_][]const u8{
        "{}",
        "{\"changes\":[]}",
        "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\",\"extra\":true}]}",
        "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\",\"baseline_sha256\":\"forged\"}]}",
        "{\"changes\":[{\"file\":\"a.ts\",\"file\":\"b.ts\",\"content\":\"x\"}]}",
        "{\"changes\":[{\"file\":\"\",\"content\":\"x\"}]}",
        "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\"}],\"extra\":true}",
    };
    for (invalid) |args_json| {
        const calls = [_]turn.ToolCall{.{ .id = "toolu_bad", .name = tool_name, .args_json = args_json }};
        try testing.expectError(
            error.InvalidChangeSetArgs,
            maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null),
        );
    }
}

test "truncated proposal reports the recoverable error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{.{
        .id = "toolu_bad",
        .name = tool_name,
        .args_json = "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"",
    }};
    try testing.expectError(
        error.OutputTruncated,
        maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, "max_tokens"),
    );
}

test "mixed proposal batch remains a normal tool batch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_changes", .name = tool_name, .args_json = "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\"}]}" },
        .{ .id = "toolu_meta", .name = "zts_expert_meta", .args_json = "{}" },
    };
    const out = try maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null);
    try testing.expect(out.response == .tool_calls);
}
