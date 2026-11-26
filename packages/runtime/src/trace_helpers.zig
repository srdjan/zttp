const std = @import("std");
const HttpHeader = @import("http_types.zig").HttpHeader;

/// Parse a simple JSON object {"key":"value",...} into header list.
pub fn parseHeadersFromJson(
    allocator: std.mem.Allocator,
    json: []const u8,
    headers: *std.ArrayListUnmanaged(HttpHeader),
) !void {
    if (json.len < 2 or json[0] != '{') return;

    var pos: usize = 1;
    while (pos < json.len) {
        // Skip whitespace and commas
        while (pos < json.len and (json[pos] == ' ' or json[pos] == ',' or json[pos] == '\n')) : (pos += 1) {}
        if (pos >= json.len or json[pos] == '}') break;

        // Parse key
        if (json[pos] != '"') break;
        pos += 1;
        const key_start = pos;
        while (pos < json.len and json[pos] != '"') {
            if (json[pos] == '\\') {
                pos += 2;
                if (pos > json.len) {
                    pos = json.len;
                    break;
                }
            } else {
                pos += 1;
            }
        }
        if (pos >= json.len) break; // unclosed key string
        const key = json[key_start..pos];
        pos += 1; // skip closing quote

        // Skip colon
        while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) : (pos += 1) {}

        // Parse value
        if (pos >= json.len or json[pos] != '"') break;
        pos += 1;
        const val_start = pos;
        while (pos < json.len and json[pos] != '"') {
            if (json[pos] == '\\') {
                pos += 2;
                if (pos > json.len) {
                    pos = json.len;
                    break;
                }
            } else {
                pos += 1;
            }
        }
        if (pos >= json.len) break; // unclosed value string
        const val = json[val_start..pos];
        pos += 1; // skip closing quote

        try headers.append(allocator, .{ .key = key, .value = val });
    }
}

test "parseHeadersFromJson: basic object" {
    var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer headers.deinit(std.testing.allocator);

    try parseHeadersFromJson(std.testing.allocator, "{\"content-type\":\"application/json\",\"authorization\":\"Bearer tok\"}", &headers);

    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("content-type", headers.items[0].key);
    try std.testing.expectEqualStrings("application/json", headers.items[0].value);
    try std.testing.expectEqualStrings("authorization", headers.items[1].key);
    try std.testing.expectEqualStrings("Bearer tok", headers.items[1].value);
}

test "parseHeadersFromJson: empty object" {
    var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer headers.deinit(std.testing.allocator);

    try parseHeadersFromJson(std.testing.allocator, "{}", &headers);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);
}

test "parseHeadersFromJson: malformed input" {
    var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer headers.deinit(std.testing.allocator);

    try parseHeadersFromJson(std.testing.allocator, "", &headers);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);

    try parseHeadersFromJson(std.testing.allocator, "not json", &headers);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);
}

test "parseHeadersFromJson: trailing backslash does not panic out of bounds" {
    var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer headers.deinit(std.testing.allocator);

    try parseHeadersFromJson(std.testing.allocator, "{\"a\\", &headers);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);

    try parseHeadersFromJson(std.testing.allocator, "{\"a\":\"b\\", &headers);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);

    try parseHeadersFromJson(std.testing.allocator, "{\"k\":\"v\",\"a\":\"b\\", &headers);
    try std.testing.expectEqual(@as(usize, 1), headers.items.len);
    try std.testing.expectEqualStrings("k", headers.items[0].key);
    try std.testing.expectEqualStrings("v", headers.items[0].value);
}
