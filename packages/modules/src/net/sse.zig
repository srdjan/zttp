const std = @import("std");

pub const max_body_bytes_limit: usize = 8 * 1024 * 1024;
pub const max_block_bytes_limit: usize = 8 * 1024 * 1024;
pub const max_events_limit: usize = 65_536;

pub const Bounds = struct {
    max_body_bytes: usize,
    max_block_bytes: usize,
    max_events: usize,
};

pub const FailureTag = enum {
    invalid_bound,
    body_too_large,
    block_too_large,
    too_many_events,
    invalid_utf8,
    unterminated_event,
};

pub const Failure = struct {
    tag: FailureTag,
    offset: usize,
};

/// `event` borrows from the input body unless it is the static `message`
/// default. `data` borrows from the owned data storage in `EventList`.
/// `id_index` refers to one shared entry in `EventList.ids`.
pub const Event = struct {
    event: []const u8,
    data: []const u8,
    id_index: usize,
};

/// Event names and ids borrow from the body passed to `frame`. The caller must
/// keep that body alive until this list is deinitialized.
pub const EventList = struct {
    allocator: std.mem.Allocator,
    events: []Event,
    ids: []const []const u8,
    data_storage: []u8,

    pub fn deinit(self: *EventList) void {
        self.allocator.free(self.events);
        self.allocator.free(self.ids);
        self.allocator.free(self.data_storage);
        self.* = undefined;
    }

    pub fn idFor(self: *const EventList, event: Event) []const u8 {
        std.debug.assert(event.id_index < self.ids.len);
        return self.ids[event.id_index];
    }
};

pub const FrameResult = union(enum) {
    ok: EventList,
    err: Failure,
};

const Stats = struct {
    events: usize = 0,
    ids: usize = 1,
    data_bytes: usize = 0,
};

const Output = struct {
    events: []Event,
    ids: [][]const u8,
    data: []u8,
    event_cursor: usize = 0,
    id_cursor: usize = 1,
    data_cursor: usize = 0,
};

const Parser = struct {
    body: []const u8,
    bounds: Bounds,
    output: ?*Output,
    stats: Stats = .{},
    cursor: usize,
    line_start: usize,
    block_start: usize,
    field_in_block: bool = false,
    saw_data: bool = false,
    block_data_start: usize = 0,
    block_data_bytes: usize = 0,
    event_name: ?[]const u8 = null,
    current_id_value: []const u8 = "",
    current_id_index: ?usize = 0,

    fn init(body: []const u8, bounds: Bounds, output: ?*Output) Parser {
        const content_start: usize = if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) 3 else 0;
        if (output) |out| out.ids[0] = "";
        return .{
            .body = body,
            .bounds = bounds,
            .output = output,
            .cursor = content_start,
            .line_start = content_start,
            .block_start = content_start,
        };
    }

    fn run(self: *Parser) ?Failure {
        while (self.cursor < self.body.len) {
            const byte = self.body[self.cursor];
            if (byte == '\r' or byte == '\n') {
                const line_end = self.cursor;
                if (self.consumeBlockByte(self.cursor)) |failure| return failure;
                self.cursor += 1;

                if (byte == '\r' and self.cursor < self.body.len and self.body[self.cursor] == '\n') {
                    if (self.consumeBlockByte(self.cursor)) |failure| return failure;
                    self.cursor += 1;
                }

                if (self.processLine(self.body[self.line_start..line_end])) |failure| return failure;
                self.line_start = self.cursor;
                continue;
            }

            if (self.consumeCodepoint()) |failure| return failure;
        }

        if (self.line_start < self.body.len or self.field_in_block) {
            return .{ .tag = .unterminated_event, .offset = self.block_start };
        }
        return null;
    }

    fn consumeBlockByte(self: *const Parser, offset: usize) ?Failure {
        std.debug.assert(offset >= self.block_start);
        if (offset - self.block_start >= self.bounds.max_block_bytes) {
            return .{ .tag = .block_too_large, .offset = self.block_start };
        }
        return null;
    }

    fn consumeCodepoint(self: *Parser) ?Failure {
        const start = self.cursor;
        if (self.consumeBlockByte(start)) |failure| return failure;

        const lead = self.body[start];
        const width: usize = switch (lead) {
            0x00...0x7F => 1,
            0xC2...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => return .{ .tag = .invalid_utf8, .offset = start },
        };

        var index: usize = 1;
        while (index < width) : (index += 1) {
            if (start + index >= self.body.len) {
                return .{ .tag = .invalid_utf8, .offset = start };
            }
            if (self.consumeBlockByte(start + index)) |failure| return failure;
            if (!validContinuation(lead, index, self.body[start + index])) {
                return .{ .tag = .invalid_utf8, .offset = start };
            }
        }
        self.cursor += width;
        return null;
    }

    fn validContinuation(lead: u8, index: usize, byte: u8) bool {
        if (index > 1) return byte >= 0x80 and byte <= 0xBF;
        return switch (lead) {
            0xE0 => byte >= 0xA0 and byte <= 0xBF,
            0xED => byte >= 0x80 and byte <= 0x9F,
            0xF0 => byte >= 0x90 and byte <= 0xBF,
            0xF4 => byte >= 0x80 and byte <= 0x8F,
            else => byte >= 0x80 and byte <= 0xBF,
        };
    }

    fn processLine(self: *Parser, line: []const u8) ?Failure {
        if (line.len == 0) {
            if (self.dispatch()) |failure| return failure;
            self.resetBlock();
            self.block_start = self.cursor;
            return null;
        }

        if (line[0] == ':') return null;
        self.field_in_block = true;

        const colon = std.mem.findScalar(u8, line, ':');
        const field = if (colon) |colon_index| line[0..colon_index] else line;
        var value = if (colon) |colon_index| line[colon_index + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            self.event_name = value;
        } else if (std.mem.eql(u8, field, "data")) {
            self.appendData(value);
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.findScalar(u8, value, 0) == null) self.setId(value);
        }
        return null;
    }

    fn appendData(self: *Parser, value: []const u8) void {
        if (!self.saw_data) {
            self.saw_data = true;
            self.block_data_start = self.stats.data_bytes;
        } else {
            if (self.output) |out| {
                out.data[out.data_cursor] = '\n';
                out.data_cursor += 1;
            }
            self.stats.data_bytes += 1;
            self.block_data_bytes += 1;
        }

        if (self.output) |out| {
            @memcpy(out.data[out.data_cursor..][0..value.len], value);
            out.data_cursor += value.len;
        }
        self.stats.data_bytes += value.len;
        self.block_data_bytes += value.len;
    }

    fn setId(self: *Parser, value: []const u8) void {
        if (value.len == 0) {
            self.current_id_value = "";
            self.current_id_index = 0;
            return;
        }

        self.current_id_value = value;
        self.current_id_index = null;
    }

    fn dispatch(self: *Parser) ?Failure {
        if (!self.saw_data) return null;
        if (self.stats.events >= self.bounds.max_events) {
            return .{ .tag = .too_many_events, .offset = self.block_start };
        }

        const id_index = self.ensureCurrentIdStored();

        if (self.output) |out| {
            out.events[out.event_cursor] = .{
                .event = if (self.event_name) |name| if (name.len == 0) "message" else name else "message",
                .data = out.data[self.block_data_start..][0..self.block_data_bytes],
                .id_index = id_index,
            };
            out.event_cursor += 1;
        }
        self.stats.events += 1;
        return null;
    }

    fn ensureCurrentIdStored(self: *Parser) usize {
        if (self.current_id_index) |index| return index;

        const index = self.stats.ids;
        self.stats.ids += 1;
        self.current_id_index = index;
        if (self.output) |out| {
            out.ids[out.id_cursor] = self.current_id_value;
            out.id_cursor += 1;
        }
        return index;
    }

    fn resetBlock(self: *Parser) void {
        self.field_in_block = false;
        self.saw_data = false;
        self.block_data_start = self.stats.data_bytes;
        self.block_data_bytes = 0;
        self.event_name = null;
    }
};

/// Frames one complete buffered event stream. The first pass validates the
/// stream and measures exact output sizes. The second pass fills those exact
/// allocations. The output borrows event names and ids from `body`; event data
/// and metadata are owned by the returned list.
pub fn frame(allocator: std.mem.Allocator, body: []const u8, bounds: Bounds) std.mem.Allocator.Error!FrameResult {
    if (bounds.max_body_bytes == 0 or bounds.max_body_bytes > max_body_bytes_limit or
        bounds.max_block_bytes == 0 or bounds.max_block_bytes > max_block_bytes_limit or
        bounds.max_events == 0 or bounds.max_events > max_events_limit)
    {
        return .{ .err = .{ .tag = .invalid_bound, .offset = 0 } };
    }
    if (body.len > bounds.max_body_bytes) {
        return .{ .err = .{ .tag = .body_too_large, .offset = bounds.max_body_bytes } };
    }

    var sizing = Parser.init(body, bounds, null);
    if (sizing.run()) |failure| return .{ .err = failure };

    const events = try allocator.alloc(Event, sizing.stats.events);
    errdefer allocator.free(events);
    const ids = try allocator.alloc([]const u8, sizing.stats.ids);
    errdefer allocator.free(ids);
    const data = try allocator.alloc(u8, sizing.stats.data_bytes);
    errdefer allocator.free(data);

    var output = Output{ .events = events, .ids = ids, .data = data };
    var filling = Parser.init(body, bounds, &output);
    if (filling.run()) |failure| {
        allocator.free(data);
        allocator.free(ids);
        allocator.free(events);
        return .{ .err = failure };
    }

    std.debug.assert(filling.stats.events == sizing.stats.events);
    std.debug.assert(filling.stats.ids == sizing.stats.ids);
    std.debug.assert(filling.stats.data_bytes == sizing.stats.data_bytes);
    std.debug.assert(output.event_cursor == events.len);
    std.debug.assert(output.id_cursor == ids.len);
    std.debug.assert(output.data_cursor == data.len);

    return .{ .ok = .{
        .allocator = allocator,
        .events = events,
        .ids = ids,
        .data_storage = data,
    } };
}

const generous_bounds = Bounds{
    .max_body_bytes = max_body_bytes_limit,
    .max_block_bytes = max_block_bytes_limit,
    .max_events = max_events_limit,
};

const ExpectedEvent = struct {
    event: []const u8 = "message",
    data: []const u8,
    id: []const u8 = "",
};

fn expectFrames(body: []const u8, bounds: Bounds, expected: []const ExpectedEvent) !void {
    const result = try frame(std.testing.allocator, body, bounds);
    switch (result) {
        .err => |failure| {
            std.debug.print("unexpected SSE failure: {s} at {d}\n", .{ @tagName(failure.tag), failure.offset });
            return error.UnexpectedSseFailure;
        },
        .ok => |list_value| {
            var list = list_value;
            defer list.deinit();
            try std.testing.expectEqual(expected.len, list.events.len);
            for (expected, list.events) |want, actual| {
                try std.testing.expectEqualStrings(want.event, actual.event);
                try std.testing.expectEqualStrings(want.data, actual.data);
                try std.testing.expectEqualStrings(want.id, list.idFor(actual));
            }
        },
    }
}

fn expectFailure(body: []const u8, bounds: Bounds, expected: Failure) !void {
    const result = try frame(std.testing.allocator, body, bounds);
    switch (result) {
        .err => |actual| try std.testing.expectEqual(expected, actual),
        .ok => |list_value| {
            var list = list_value;
            defer list.deinit();
            return error.ExpectedSseFailure;
        },
    }
}

test "SSE corpus covers the framing rules" {
    const Case = struct {
        name: []const u8,
        body: []const u8,
        expected: []const ExpectedEvent,
    };
    const corpus = [_]Case{
        .{ .name = "empty", .body = "", .expected = &.{} },
        .{ .name = "LF", .body = "data: one\n\n", .expected = &.{.{ .data = "one" }} },
        .{ .name = "CRLF", .body = "data: two\r\n\r\n", .expected = &.{.{ .data = "two" }} },
        .{ .name = "CR", .body = "data: three\r\r", .expected = &.{.{ .data = "three" }} },
        .{ .name = "CRLF is one line end", .body = "data: one\r\ndata: two\r\n\r\n", .expected = &.{.{ .data = "one\ntwo" }} },
        .{ .name = "comment", .body = ": ignored\ndata: kept\n\n", .expected = &.{.{ .data = "kept" }} },
        .{ .name = "multi-line data", .body = "data: first\ndata: second\n\n", .expected = &.{.{ .data = "first\nsecond" }} },
        .{ .name = "event name", .body = "event: update\ndata: payload\n\n", .expected = &.{.{ .event = "update", .data = "payload" }} },
        .{ .name = "last event name wins", .body = "event: first\nevent: second\ndata: payload\n\n", .expected = &.{.{ .event = "second", .data = "payload" }} },
        .{ .name = "empty event name defaults to message", .body = "event: stale\nevent:\ndata: payload\n\n", .expected = &.{.{ .data = "payload" }} },
        .{ .name = "field without colon", .body = "data\n\n", .expected = &.{.{ .data = "" }} },
        .{ .name = "only first colon separates", .body = "data:a:b\n\n", .expected = &.{.{ .data = "a:b" }} },
        .{ .name = "field names are case-sensitive", .body = "Data: dropped\ndata: kept\n\n", .expected = &.{.{ .data = "kept" }} },
        .{ .name = "one leading space removed", .body = "data: one\ndata:  two\n\n", .expected = &.{.{ .data = "one\n two" }} },
        .{ .name = "one trailing LF removed", .body = "data:\ndata:\n\n", .expected = &.{.{ .data = "\n" }} },
        .{ .name = "retry and unknown fields ignored", .body = "retry: 10\nother: x\ndata: yes\n\n", .expected = &.{.{ .data = "yes" }} },
        .{ .name = "data-less dispatch resets event", .body = "event: stale\n\ndata: fresh\n\n", .expected = &.{.{ .data = "fresh" }} },
        .{ .name = "leading BOM", .body = "\xEF\xBB\xBFdata: bom\n\n", .expected = &.{.{ .data = "bom" }} },
        .{ .name = "second leading BOM is field content", .body = "\xEF\xBB\xBF\xEF\xBB\xBFdata: dropped\n\n", .expected = &.{} },
        .{ .name = "valid multibyte data", .body = "event: \xE2\x98\x83\ndata: caf\xC3\xA9 \xF0\x9F\x98\x80\n\n", .expected = &.{.{ .event = "\xE2\x98\x83", .data = "caf\xC3\xA9 \xF0\x9F\x98\x80" }} },
        .{ .name = "DONE remains data", .body = "data: [DONE]\n\n", .expected = &.{.{ .data = "[DONE]" }} },
    };

    try std.testing.expect(corpus.len > 0);
    for (corpus) |case| {
        errdefer std.debug.print("SSE corpus case failed: {s}\n", .{case.name});
        try expectFrames(case.body, generous_bounds, case.expected);
    }
}

test "SSE ids persist reset and ignore values containing NUL" {
    const body =
        "id: alpha\n" ++
        "data: one\n\n" ++
        "data: two\n\n" ++
        "id: bad\x00id\n" ++
        "data: three\n\n" ++
        "id:\n" ++
        "data: four\n\n";
    try expectFrames(body, generous_bounds, &.{
        .{ .data = "one", .id = "alpha" },
        .{ .data = "two", .id = "alpha" },
        .{ .data = "three", .id = "alpha" },
        .{ .data = "four", .id = "" },
    });
}

test "SSE stores only ids used by dispatched events" {
    const body = "id: overwritten\nid: used\ndata: one\n\ndata: two\n\nid: unused\n\n";
    const result = try frame(std.testing.allocator, body, generous_bounds);
    switch (result) {
        .err => return error.UnexpectedSseFailure,
        .ok => |list_value| {
            var list = list_value;
            defer list.deinit();
            try std.testing.expectEqual(@as(usize, 2), list.events.len);
            try std.testing.expectEqual(@as(usize, 2), list.ids.len);
            try std.testing.expectEqualStrings("used", list.ids[1]);
            try std.testing.expectEqual(list.events[0].id_index, list.events[1].id_index);
        },
    }
}

test "SSE EOF state distinguishes terminated comments and blocks" {
    try expectFrames(": comment\n", generous_bounds, &.{});
    try expectFrames(": comment\r", generous_bounds, &.{});
    try expectFrames("event: unused\n\n", generous_bounds, &.{});
    try expectFrames("event: unused\r\r", generous_bounds, &.{});

    const cases = [_]struct { body: []const u8, offset: usize }{
        .{ .body = ": trailing comment", .offset = 0 },
        .{ .body = "data: value", .offset = 0 },
        .{ .body = "event:", .offset = 0 },
        .{ .body = "id:", .offset = 0 },
        .{ .body = "data: value\n", .offset = 0 },
        .{ .body = "data: value\r", .offset = 0 },
        .{ .body = "event:\n", .offset = 0 },
        .{ .body = "id:\n", .offset = 0 },
        .{ .body = "ignored: field\n", .offset = 0 },
        .{ .body = "data: done\n\nevent: pending\n", .offset = 12 },
    };
    for (cases) |case| {
        try expectFailure(case.body, generous_bounds, .{ .tag = .unterminated_event, .offset = case.offset });
    }
}

test "SSE rejects malformed UTF-8 classes at the lead byte" {
    const cases = [_][]const u8{
        "data:\xE2\x82",
        "data:\x80\n\n",
        "data:\xC0\xAF\n\n",
        "data:\xED\xA0\x80\n\n",
        "data:\xF4\x90\x80\x80\n\n",
    };
    for (cases) |body| {
        try expectFailure(body, generous_bounds, .{ .tag = .invalid_utf8, .offset = 5 });
    }
}

test "SSE bounds and failure offsets are exact" {
    const invalid_bounds = [_]Bounds{
        .{ .max_body_bytes = 0, .max_block_bytes = 1, .max_events = 1 },
        .{ .max_body_bytes = max_body_bytes_limit + 1, .max_block_bytes = 1, .max_events = 1 },
        .{ .max_body_bytes = 1, .max_block_bytes = 0, .max_events = 1 },
        .{ .max_body_bytes = 1, .max_block_bytes = max_block_bytes_limit + 1, .max_events = 1 },
        .{ .max_body_bytes = 1, .max_block_bytes = 1, .max_events = 0 },
        .{ .max_body_bytes = 1, .max_block_bytes = 1, .max_events = max_events_limit + 1 },
    };
    for (invalid_bounds) |bounds| {
        try expectFailure("abc", bounds, .{ .tag = .invalid_bound, .offset = 0 });
    }

    try expectFailure("abc", .{ .max_body_bytes = 2, .max_block_bytes = 2, .max_events = 1 }, .{ .tag = .body_too_large, .offset = 2 });
    try expectFailure("data:a\n\ndata:bb\n\n", .{ .max_body_bytes = 17, .max_block_bytes = 8, .max_events = 2 }, .{ .tag = .block_too_large, .offset = 8 });
    try expectFailure("data:a\n\ndata:b\n\n", .{ .max_body_bytes = 16, .max_block_bytes = 8, .max_events = 1 }, .{ .tag = .too_many_events, .offset = 8 });
    try expectFailure("data:\xFF\n\n", generous_bounds, .{ .tag = .invalid_utf8, .offset = 5 });
    try expectFailure("\xEF\xBB\xBFdata:x\n", generous_bounds, .{ .tag = .unterminated_event, .offset = 3 });
}

test "SSE accepts inclusive bound endpoints and counts BOM offsets" {
    try expectFrames("", .{ .max_body_bytes = 1, .max_block_bytes = 1, .max_events = 1 }, &.{});
    try expectFrames("\n", .{ .max_body_bytes = 1, .max_block_bytes = 1, .max_events = 1 }, &.{});
    try expectFrames("data:x\n\n", .{ .max_body_bytes = 8, .max_block_bytes = 8, .max_events = 1 }, &.{.{ .data = "x" }});
    try expectFrames("", .{ .max_body_bytes = max_body_bytes_limit, .max_block_bytes = max_block_bytes_limit, .max_events = max_events_limit }, &.{});
    try expectFailure("\xEF\xBB\xBFdata:\xFF\n\n", generous_bounds, .{ .tag = .invalid_utf8, .offset = 8 });
    try expectFailure("\xEF\xBB\xBFdata:x\n\n", .{ .max_body_bytes = 11, .max_block_bytes = 7, .max_events = 1 }, .{ .tag = .block_too_large, .offset = 3 });
}

test "SSE failure order follows bounds then scan order" {
    try expectFailure("\xFF", .{ .max_body_bytes = 0, .max_block_bytes = 1, .max_events = 1 }, .{ .tag = .invalid_bound, .offset = 0 });
    try expectFailure("\xFFx", .{ .max_body_bytes = 1, .max_block_bytes = 1, .max_events = 1 }, .{ .tag = .body_too_large, .offset = 1 });
    try expectFailure("a\xFF", .{ .max_body_bytes = 2, .max_block_bytes = 1, .max_events = 1 }, .{ .tag = .block_too_large, .offset = 0 });
    try expectFailure("\xFFa", .{ .max_body_bytes = 2, .max_block_bytes = 1, .max_events = 1 }, .{ .tag = .invalid_utf8, .offset = 0 });
    try expectFailure("data:a\n\ndata:b\n\n", .{ .max_body_bytes = 16, .max_block_bytes = 7, .max_events = 1 }, .{ .tag = .block_too_large, .offset = 0 });
    try expectFailure("data:a\n\ndata:b\n\n\xFF", .{ .max_body_bytes = 17, .max_block_bytes = 8, .max_events = 1 }, .{ .tag = .too_many_events, .offset = 8 });
    try expectFailure("data:\xFF", generous_bounds, .{ .tag = .invalid_utf8, .offset = 5 });
}

test "SSE checks UTF-8 and block bounds in byte scan order" {
    try expectFailure("\xC2A", .{ .max_body_bytes = 2, .max_block_bytes = 1, .max_events = 1 }, .{ .tag = .block_too_large, .offset = 0 });
    try expectFailure("\xE2A\x80", .{ .max_body_bytes = 3, .max_block_bytes = 2, .max_events = 1 }, .{ .tag = .invalid_utf8, .offset = 0 });
    try expectFailure("\xE2\x82", .{ .max_body_bytes = 2, .max_block_bytes = 1, .max_events = 1 }, .{ .tag = .block_too_large, .offset = 0 });
}

test "SSE CRLF bytes both count toward the block bound" {
    try expectFrames("data:x\r\n\r\n", .{ .max_body_bytes = 10, .max_block_bytes = 10, .max_events = 1 }, &.{.{ .data = "x" }});
    try expectFailure("data:x\r\n\r\n", .{ .max_body_bytes = 10, .max_block_bytes = 9, .max_events = 1 }, .{ .tag = .block_too_large, .offset = 0 });
}

test "SSE persistent ids use shared storage" {
    const id_len = 4096;
    const event_count = 1024;
    const first_prefix = "id:";
    const first_suffix = "\ndata:x\n\n";
    const later_event = "data:x\n\n";
    const body_len = first_prefix.len + id_len + first_suffix.len + (event_count - 1) * later_event.len;
    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);

    var cursor: usize = 0;
    @memcpy(body[cursor..][0..first_prefix.len], first_prefix);
    cursor += first_prefix.len;
    @memset(body[cursor..][0..id_len], 'a');
    const id_start = cursor;
    cursor += id_len;
    @memcpy(body[cursor..][0..first_suffix.len], first_suffix);
    cursor += first_suffix.len;
    var event_index: usize = 1;
    while (event_index < event_count) : (event_index += 1) {
        @memcpy(body[cursor..][0..later_event.len], later_event);
        cursor += later_event.len;
    }
    try std.testing.expectEqual(body.len, cursor);

    const result = try frame(std.testing.allocator, body, .{
        .max_body_bytes = body.len,
        .max_block_bytes = first_prefix.len + id_len + first_suffix.len,
        .max_events = event_count,
    });
    switch (result) {
        .err => return error.UnexpectedSseFailure,
        .ok => |list_value| {
            var list = list_value;
            defer list.deinit();
            try std.testing.expectEqual(event_count, list.events.len);
            try std.testing.expectEqual(@as(usize, 2), list.ids.len);
            try std.testing.expectEqual(body[id_start..][0..id_len].ptr, list.ids[1].ptr);
            for (list.events) |event| {
                try std.testing.expectEqual(@as(usize, 1), event.id_index);
                try std.testing.expectEqual(list.ids[1].ptr, list.idFor(event).ptr);
            }
        },
    }
}

test "SSE failure tag census has a probe for every tag" {
    const Probe = struct {
        body: []const u8,
        bounds: Bounds,
        failure: Failure,
    };
    const probes = [_]Probe{
        .{ .body = "", .bounds = .{ .max_body_bytes = 0, .max_block_bytes = 1, .max_events = 1 }, .failure = .{ .tag = .invalid_bound, .offset = 0 } },
        .{ .body = "ab", .bounds = .{ .max_body_bytes = 1, .max_block_bytes = 1, .max_events = 1 }, .failure = .{ .tag = .body_too_large, .offset = 1 } },
        .{ .body = "ab", .bounds = .{ .max_body_bytes = 2, .max_block_bytes = 1, .max_events = 1 }, .failure = .{ .tag = .block_too_large, .offset = 0 } },
        .{ .body = "data:a\n\ndata:b\n\n", .bounds = .{ .max_body_bytes = 16, .max_block_bytes = 8, .max_events = 1 }, .failure = .{ .tag = .too_many_events, .offset = 8 } },
        .{ .body = "\xFF", .bounds = generous_bounds, .failure = .{ .tag = .invalid_utf8, .offset = 0 } },
        .{ .body = "event:x", .bounds = generous_bounds, .failure = .{ .tag = .unterminated_event, .offset = 0 } },
    };
    try std.testing.expect(probes.len > 0);

    const tag_fields = @typeInfo(FailureTag).@"enum".fields;
    var seen = [_]bool{false} ** tag_fields.len;
    for (probes) |probe| {
        try expectFailure(probe.body, probe.bounds, probe.failure);
        seen[@intFromEnum(probe.failure.tag)] = true;
    }
    inline for (tag_fields) |field| {
        try std.testing.expect(seen[field.value]);
    }
}

fn frameUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    const result = try frame(allocator, "id: shared\ndata: one\n\ndata: two\n\n", generous_bounds);
    switch (result) {
        .err => return error.UnexpectedSseFailure,
        .ok => |list_value| {
            var list = list_value;
            list.deinit();
        },
    }
}

test "SSE frame frees partial output after every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, frameUnderAllocationFailure, .{});
}
