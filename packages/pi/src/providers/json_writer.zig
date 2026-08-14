//! Provider-neutral JSON string serializer.

const std = @import("std");

pub fn writeString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x00...0x08, 0x0b...0x0c, 0x0e...0x1f => {
                    try writer.print("\\u{x:0>4}", .{@as(u16, byte)});
                },
                else => try writer.writeByte(byte),
            }
            index += 1;
            continue;
        }

        // Replace incomplete or invalid UTF-8 rather than emitting a request
        // body that a provider will reject.
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.writeAll("\u{FFFD}");
            index += 1;
            continue;
        };
        if (index + sequence_len > text.len or
            !std.unicode.utf8ValidateSlice(text[index .. index + sequence_len]))
        {
            try writer.writeAll("\u{FFFD}");
            index += 1;
            continue;
        }
        try writer.writeAll(text[index .. index + sequence_len]);
        index += sequence_len;
    }
    try writer.writeByte('"');
}
