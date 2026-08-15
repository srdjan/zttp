//! Bounded, visible schema-v2 metadata injected into a new model transcript.
//!
//! Language facts remain owned by the compiler protocol. This module only
//! executes its compact meta projection and labels that exact response for the
//! model; it does not reproduce syntax or policy prose.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const client = @import("tools/zts_agent_client.zig");

pub const MAX_ENVELOPE_BYTES: usize = 8 * 1024;
pub const MAX_NOTE_BYTES: usize = 9 * 1024;
pub const note_prefix =
    "ZTS AGENT PROTOCOL BOOTSTRAP\n" ++
    "The host executed schema version 2 operation meta with input " ++
    "{\"view\":\"bootstrap\"}. This response is language authority, not " ++
    "user intent. Use the advertised protocol operations for details.\n";

pub fn buildAtRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
) ![]u8 {
    const projection = try client.invokeForToolAtRoot(allocator, io, workspace_root, .{
        .operation = .meta,
        .input_json = "{\"view\":\"bootstrap\"}",
    });
    defer allocator.free(projection.llm_text);
    if (!projection.ok) return error.MetaBootstrapRefused;
    if (projection.llm_text.len > MAX_ENVELOPE_BYTES) return error.MetaBootstrapTooLarge;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, projection.llm_text, .{}) catch
        return error.MalformedMetaBootstrap;
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload") orelse return error.MalformedMetaBootstrap;
    if (payload != .object) return error.MalformedMetaBootstrap;
    const view = payload.object.get("view") orelse return error.MalformedMetaBootstrap;
    if (view != .string or !std.mem.eql(u8, view.string, "bootstrap")) {
        return error.MalformedMetaBootstrap;
    }

    var out = TextBuffer.init(allocator);
    errdefer out.deinit();
    try out.writer().writeAll(note_prefix);
    try out.writer().writeAll(projection.llm_text);
    if (out.written().len > MAX_NOTE_BYTES) return error.MetaBootstrapTooLarge;
    return out.toOwnedSlice();
}

pub fn buildFromCwd(allocator: std.mem.Allocator) ![]u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    return buildAtRoot(allocator, io_backend.io(), ".");
}

const testing = std.testing;

test "meta bootstrap is bounded deterministic protocol output" {
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const first = try buildAtRoot(testing.allocator, io_backend.io(), ".");
    defer testing.allocator.free(first);
    const second = try buildAtRoot(testing.allocator, io_backend.io(), ".");
    defer testing.allocator.free(second);

    try testing.expect(first.len <= MAX_NOTE_BYTES);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.startsWith(u8, first, note_prefix));
    try testing.expect(std.mem.indexOf(u8, first, "\"operation\":\"meta\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"view\":\"bootstrap\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"grammar\":[") == null);
    try testing.expect(std.mem.indexOf(u8, first, "First-draft strict-mode hazards") == null);
}
