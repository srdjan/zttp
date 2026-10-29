//! Pure release-version alignment checks for the release passport.

const std = @import("std");

pub const Alignment = enum {
    missing,
    malformed_marker,
    mismatch,
    aligned,
};

/// The bytes of every file that carries a copy of the release version.
/// `null` means the file could not be read.
pub const Sources = struct {
    zon: ?[]const u8,
    marker: ?[]const u8,
    root: ?[]const u8,
    zts_zon: ?[]const u8,
    runtime_zon: ?[]const u8,
    install: ?[]const u8,
};

/// `VERSION` is the authority. Every other copy must equal it.
pub fn check(sources: Sources) Alignment {
    const marker_bytes = sources.marker orelse return .missing;
    const zon_bytes = sources.zon orelse return .missing;
    const root_bytes = sources.root orelse return .missing;
    const zts_zon_bytes = sources.zts_zon orelse return .missing;
    const runtime_zon_bytes = sources.runtime_zon orelse return .missing;
    const install_bytes = sources.install orelse return .missing;
    const version = extractVersionMarker(marker_bytes) orelse return .malformed_marker;
    if (!std.mem.eql(u8, extractZonVersion(zon_bytes) orelse "", version) or
        !rootHasVersion(root_bytes, version) or
        !std.mem.eql(u8, extractZonVersion(zts_zon_bytes) orelse "", version) or
        !std.mem.eql(u8, extractZonVersion(runtime_zon_bytes) orelse "", version) or
        !std.mem.eql(u8, extractInstallVersion(install_bytes) orelse "", version))
    {
        return .mismatch;
    }
    return .aligned;
}

/// Name of the first source that disagrees with `VERSION`, or null when the
/// sources are aligned or `VERSION` itself is unusable.
pub fn firstDrift(sources: Sources) ?[]const u8 {
    const marker_bytes = sources.marker orelse return "VERSION (unreadable)";
    const version = extractVersionMarker(marker_bytes) orelse return "VERSION (malformed)";
    const zon = sources.zon orelse return "build.zig.zon (unreadable)";
    if (!std.mem.eql(u8, extractZonVersion(zon) orelse "", version)) return "build.zig.zon";
    const root = sources.root orelse return "packages/zts/src/root.zig (unreadable)";
    if (!rootHasVersion(root, version)) return "packages/zts/src/root.zig";
    const zts_zon = sources.zts_zon orelse return "packages/zts/build.zig.zon (unreadable)";
    if (!std.mem.eql(u8, extractZonVersion(zts_zon) orelse "", version)) return "packages/zts/build.zig.zon";
    const runtime_zon = sources.runtime_zon orelse return "packages/runtime/build.zig.zon (unreadable)";
    if (!std.mem.eql(u8, extractZonVersion(runtime_zon) orelse "", version)) return "packages/runtime/build.zig.zon";
    const install = sources.install orelse return "install.sh (unreadable)";
    if (!std.mem.eql(u8, extractInstallVersion(install) orelse "", version)) return "install.sh";
    return null;
}

pub fn extractZonVersion(bytes: []const u8) ?[]const u8 {
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const value_start = start + marker.len;
    const rest = bytes[value_start..];
    const value_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..value_end];
}

/// The version in the installer comment `(current: vX.Y.Z)`, without the `v`.
pub fn extractInstallVersion(bytes: []const u8) ?[]const u8 {
    const marker = "(current: v";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const rest = bytes[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    return rest[0..end];
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
    const version = extractVersionMarker("0.20.0\n") orelse return error.MissingVersion;
    try std.testing.expectEqualStrings("0.20.0", version);
    try std.testing.expectEqual(@as(?[]const u8, null), extractVersionMarker("0.20.0"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractVersionMarker("0.20.0\nextra\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractVersionMarker("0.20.0\r\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractVersionMarker("v0.20.0\n"));
}

const test_zon = ".{ .version = \"0.20.0\" }\n";
const test_root = "pub const string = \"0.20.0\";\n";
const test_install = "#   ZTTP_VERSION - pin (current: v0.20.0)\n";

fn testSources() Sources {
    return .{
        .zon = test_zon,
        .marker = "0.20.0\n",
        .root = test_root,
        .zts_zon = test_zon,
        .runtime_zon = test_zon,
        .install = test_install,
    };
}

test "alignment requires every release version source to agree" {
    try std.testing.expectEqual(Alignment.aligned, check(testSources()));
    try std.testing.expectEqual(@as(?[]const u8, null), firstDrift(testSources()));

    var missing = testSources();
    missing.marker = null;
    try std.testing.expectEqual(Alignment.missing, check(missing));

    var malformed = testSources();
    malformed.marker = "0.20.0";
    try std.testing.expectEqual(Alignment.malformed_marker, check(malformed));

    var stale_marker = testSources();
    stale_marker.marker = "0.19.0\n";
    try std.testing.expectEqual(Alignment.mismatch, check(stale_marker));
    try std.testing.expectEqualStrings("build.zig.zon", firstDrift(stale_marker) orelse "");

    var stale_root = testSources();
    stale_root.root = "pub const string = \"0.19.0\";";
    try std.testing.expectEqual(Alignment.mismatch, check(stale_root));
    try std.testing.expectEqualStrings("packages/zts/src/root.zig", firstDrift(stale_root) orelse "");
}

test "alignment names a drifted installer comment" {
    var stale_install = testSources();
    stale_install.install = "(current: v0.19.0)\n";
    try std.testing.expectEqual(Alignment.mismatch, check(stale_install));
    try std.testing.expectEqualStrings("install.sh", firstDrift(stale_install) orelse "");

    var no_install = testSources();
    no_install.install = null;
    try std.testing.expectEqual(Alignment.missing, check(no_install));
}
