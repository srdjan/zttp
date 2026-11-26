//! Shared JSON string utilities used by handler_contract, type_checker,
//! api_schema, contract_diff, and other modules that serialize JSON.

const std = @import("std");

pub fn writeJsonStringContent(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f => {
                try writer.print("\\u{x:0>4}", .{@as(u16, c)});
            },
            else => try writer.writeByte(c),
        }
    }
}

pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonStringContent(writer, s);
    try writer.writeByte('"');
}

/// Write a fixed-size byte array as a quoted lowercase-hex JSON string.
pub fn writeJsonHex(writer: anytype, bytes: anytype) !void {
    try writer.writeByte('"');
    try writer.writeAll(&std.fmt.bytesToHex(bytes, .lower));
    try writer.writeByte('"');
}

pub fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn unescapeJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                'b' => try result.append(allocator, 0x08),
                'f' => try result.append(allocator, 0x0C),
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                '/' => try result.append(allocator, '/'),
                'u' => {
                    // \uXXXX unicode escape (including UTF-16 surrogate pairs) -> UTF-8
                    if (i + 4 < input.len) {
                        const hex = input[i + 1 .. i + 5];
                        const code_unit = std.fmt.parseInt(u21, hex, 16) catch {
                            try result.append(allocator, 'u');
                            continue;
                        };
                        var codepoint: u21 = code_unit;
                        var advance: usize = 4;
                        if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
                            // High surrogate: require a paired low surrogate \uDC00..\uDFFF.
                            if (i + 10 < input.len and input[i + 5] == '\\' and input[i + 6] == 'u') {
                                const low = std.fmt.parseInt(u21, input[i + 7 .. i + 11], 16) catch {
                                    try result.append(allocator, 'u');
                                    continue;
                                };
                                if (low >= 0xDC00 and low <= 0xDFFF) {
                                    codepoint = 0x10000 + ((code_unit - 0xD800) << 10) + (low - 0xDC00);
                                    advance = 10;
                                } else {
                                    try result.append(allocator, 'u');
                                    continue;
                                }
                            } else {
                                try result.append(allocator, 'u');
                                continue;
                            }
                        }
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                            try result.append(allocator, 'u');
                            continue;
                        };
                        try result.appendSlice(allocator, buf[0..len]);
                        i += advance;
                    } else {
                        try result.append(allocator, 'u');
                    }
                },
                else => try result.append(allocator, input[i]),
            }
        } else {
            try result.append(allocator, input[i]);
        }
    }
    return try result.toOwnedSlice(allocator);
}

test "unescapeJson decodes backspace, formfeed, BMP unicode, and UTF-16 surrogate pairs" {
    const allocator = std.testing.allocator;

    const bf = try unescapeJson(allocator, "a\\bb\\fc\\nd");
    defer allocator.free(bf);
    try std.testing.expectEqualStrings("a\x08b\x0Cc\nd", bf);

    const bmp = try unescapeJson(allocator, "caf\\u00e9");
    defer allocator.free(bmp);
    try std.testing.expectEqualStrings("caf\xC3\xA9", bmp);

    const emoji = try unescapeJson(allocator, "hi \\uD83D\\uDE00!");
    defer allocator.free(emoji);
    try std.testing.expectEqualStrings("hi \xF0\x9F\x98\x80!", emoji);

    const clef = try unescapeJson(allocator, "\\uD834\\uDD1E");
    defer allocator.free(clef);
    try std.testing.expectEqualStrings("\xF0\x9D\x84\x9E", clef);

    // Unpaired high surrogate falls back without panicking or corrupting UTF-8.
    const lone_high = try unescapeJson(allocator, "\\uD83Dx");
    defer allocator.free(lone_high);
    try std.testing.expectEqualStrings("uD83Dx", lone_high);
}
