//! Module-root shim for the development-only stand-in executable.

const std = @import("std");
const standin = @import("standin/main.zig");
const playbook = @import("standin/playbook.zig");
const request = @import("standin/request.zig");
const range = @import("standin/range.zig");
const sse_parser = @import("providers/openai/sse_parser.zig");
const response_assembler = @import("providers/openai/response_assembler.zig");
const apply_edit = @import("providers/anthropic/apply_edit.zig");
const standin_range_doc = @import("standin_range_doc");

pub fn main(init: std.process.Init.Minimal) !void {
    try standin.main(init);
}

test {
    _ = request;
    _ = playbook;
    _ = range;
    _ = @import("standin/server.zig");
}

test "stand-in tool SSE survives the real parser, assembler, and apply-edit remapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = try playbook.renderResponse(allocator, .{
        .ask = "Add a GET /health route to handler.ts",
        .step_index = 3,
        .source = "function handler(req: Request): Response { return Response.json({ old: true }); }\n",
    });
    const events = try sse_parser.parseAll(allocator, body);
    const outcome = try response_assembler.assemble(allocator, events);
    const reply = try apply_edit.maybeRemap(allocator, outcome.reply, outcome.stop_reason);
    switch (reply.response) {
        .edit => |edit| {
            try std.testing.expectEqualStrings("handler.ts", edit.file);
            try std.testing.expect(std.mem.indexOf(u8, edit.content, "\"GET /health\": handleGetHealth") != null);
        },
        else => return error.TestExpectedEqual,
    }
}

test "stand-in miss SSE survives the real parser and assembler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = try playbook.renderResponse(allocator, .{
        .ask = "Protect this handler with bearer JWT auth",
        .step_index = 0,
        .source = "",
    });
    const events = try sse_parser.parseAll(allocator, body);
    const outcome = try response_assembler.assemble(allocator, events);
    switch (outcome.reply.response) {
        .final_text => |text| try std.testing.expectEqualStrings(
            "[standin-miss] The deterministic playbook server understood the ask as: \"Protect this handler with bearer JWT auth\". " ++
                "The supported range is explain, review, add-route, add-env, write-test, fix, and fill-hole. " ++
                "Run `zig build zttp-standin -- --range` to inspect it. Use a hosted model, or point " ++
                "ZTS_OPENAI_BASE_URL at a real local model.",
            text,
        ),
        else => return error.TestExpectedEqual,
    }
}

test "stand-in command parses --range and renders the generated document" {
    const command = try standin.parseCommandArgs(&.{"--range"});
    switch (command) {
        .range => {},
        else => return error.TestExpectedEqual,
    }

    const document = try range.renderDocument(std.testing.allocator);
    defer std.testing.allocator.free(document);
    try std.testing.expectEqualStrings(standin_range_doc.contents, document);
}

test "stand-in command parses --port 4312" {
    const command = try standin.parseCommandArgs(&.{ "--port", "4312" });
    switch (command) {
        .serve => |port| try std.testing.expectEqual(@as(u16, 4312), port),
        else => return error.TestExpectedEqual,
    }
}

test "stand-in command rejects --range with --port" {
    try std.testing.expectError(
        error.InvalidArgumentCombination,
        standin.parseCommandArgs(&.{ "--range", "--port", "4312" }),
    );
}
