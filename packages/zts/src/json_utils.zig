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

/// Write an optional string as a quoted JSON string, or the literal `null`.
pub fn writeJsonStringOrNull(writer: anytype, s: ?[]const u8) !void {
    if (s) |v| {
        try writeJsonString(writer, v);
    } else {
        try writer.writeAll("null");
    }
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
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                '/' => try result.append(allocator, '/'),
                'u' => {
                    // \uXXXX unicode escape -> UTF-8
                    if (i + 4 < input.len) {
                        const hex = input[i + 1 .. i + 5];
                        const codepoint = std.fmt.parseInt(u21, hex, 16) catch {
                            try result.append(allocator, 'u');
                            continue;
                        };
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                            try result.append(allocator, 'u');
                            continue;
                        };
                        try result.appendSlice(allocator, buf[0..len]);
                        i += 4;
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
