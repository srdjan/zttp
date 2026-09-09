//! Pure release-version alignment checks for the release passport.

const std = @import("std");

pub const Alignment = enum {
    missing,
    malformed_marker,
    mismatch,
    aligned,
};

pub fn check(
    zon: ?[]const u8,
    marker: ?[]const u8,
    root: ?[]const u8,
    zts_zon: ?[]const u8,
    runtime_zon: ?[]const u8,
) Alignment {
    if (zon == null or marker == null or root == null or zts_zon == null or runtime_zon == null) {
        return .missing;
    }
    const version = extractZonVersion(zon.?) orelse return .missing;
    const marker_version = extractVersionMarker(marker.?) orelse return .malformed_marker;
    if (!std.mem.eql(u8, marker_version, version) or
        !rootHasVersion(root.?, version) or
        !std.mem.eql(u8, extractZonVersion(zts_zon.?) orelse "", version) or
        !std.mem.eql(u8, extractZonVersion(runtime_zon.?) orelse "", version))
    {
        return .mismatch;
    }
    return .aligned;
}

pub fn extractZonVersion(bytes: []const u8) ?[]const u8 {
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const value_start = start + marker.len;
    const rest = bytes[value_start..];
    const value_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..value_end];
}

pub fn extractVersionMarker(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') return null;
    const version = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfAny(u8, version, "\r\n") != null) return null;
    _ = std.SemanticVersion.parse(version) catch return null;
    return version;
}

fn rootHasVersion(bytes: []const u8, expected: []const u8) bool {
    const marker = "string = \"";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return false;
    const value_start = start + marker.len;
    const rest = bytes[value_start..];
    const value_end = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
    return std.mem.eql(u8, rest[0..value_end], expected);
}

test "VERSION requires one SemVer line with a trailing newline" {
    try std.testing.expectEqualStrings("0.20.0", extractVersionMarker("0.20.0\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), extractVersionMarker("0.20.0"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractVersionMarker("0.20.0\nextra\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractVersionMarker("0.20.0\r\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractVersionMarker("v0.20.0\n"));
}

test "alignment requires every release version source to agree" {
    const zon = ".{ .version = \"0.20.0\" }\n";
    const root = "pub const string = \"0.20.0\";\n";
    try std.testing.expectEqual(Alignment.aligned, check(zon, "0.20.0\n", root, zon, zon));
    try std.testing.expectEqual(Alignment.missing, check(zon, null, root, zon, zon));
    try std.testing.expectEqual(Alignment.malformed_marker, check(zon, "0.20.0", root, zon, zon));
    try std.testing.expectEqual(Alignment.mismatch, check(zon, "0.19.0\n", root, zon, zon));
    try std.testing.expectEqual(Alignment.mismatch, check(zon, "0.20.0\n", "pub const string = \"0.19.0\";", zon, zon));
}
