//! Identity primitives for the version-2 agent protocol.
//!
//! Spec 4.8 requires every response to bind a profile identity, and every file
//! path to resolve inside an explicit, canonicalized project root. D3 §3 fixes
//! the digest algorithm (SHA-256, lowercase hex, 64 characters) and the
//! canonical path form (absolute, symlinks resolved, dot segments removed,
//! project-root-relative, `/` separators).
//!
//! Path canonicalization lives in tools. The language-profile authority lives
//! with the grammar registry and is only re-exported here for protocol callers.
//!
//! The path functions take an `std.Io` because Zig 0.16 removed `std.fs.cwd()`:
//! every filesystem call goes through an `Io` instance now. Callers that have
//! no backend yet build one the way the rest of the tools do
//! (`std.Io.Threaded.init(allocator, .{ .environ = .empty })`).

const std = @import("std");
const zts = @import("zts");

/// The profile this binary implements. Published in every response envelope and
/// compared against `expected.profile_id`.
pub const profile_id = zts.GrammarCatalog.profile_id;

/// The only schema version this binary serves. A request naming any other
/// version gets the frozen negotiation response.
pub const schema_version: u32 = 2;
pub const supported_schema_versions = [_]u32{2};

pub const PathError = error{
    PathOutsideProjectRoot,
    ProjectRootUnresolvable,
};

/// SHA-256 of the raw bytes, lowercase hex. D3 §3: `source_digest` hashes the
/// file as it sits on disk, uncanonicalized, because repair spans are byte
/// offsets into exactly these bytes.
pub fn sourceDigest(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Canonicalize the project root: absolute, symlinks resolved. A root that does
/// not exist is unresolvable, not silently accepted - every later path check
/// depends on this prefix being real.
pub fn canonicalRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    const resolved = std.Io.Dir.realPathFileAlloc(.cwd(), io, root, allocator) catch
        return error.ProjectRootUnresolvable;
    defer allocator.free(resolved);
    return allocator.dupe(u8, resolved);
}

/// Resolve `path` against an already-canonical root and return the
/// root-relative form. Rejects anything that escapes the root.
///
/// An existing file goes through `realPathFile`, so a symlink pointing out of
/// the tree is caught. A path that does not exist yet resolves lexically, which
/// is enough: a lexical resolve cannot re-enter the root after leaving it.
pub fn canonicalRelPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    canonical_root: []const u8,
    path: []const u8,
) ![]u8 {
    const joined = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.resolve(allocator, &.{ canonical_root, path });
    defer allocator.free(joined);

    const resolved = blk: {
        const real = std.Io.Dir.realPathFileAlloc(.cwd(), io, joined, allocator) catch
            break :blk try std.fs.path.resolve(allocator, &.{joined});
        defer allocator.free(real);
        break :blk try allocator.dupe(u8, real);
    };
    defer allocator.free(resolved);

    if (std.mem.eql(u8, resolved, canonical_root)) return allocator.dupe(u8, "");
    if (!std.mem.startsWith(u8, resolved, canonical_root)) return error.PathOutsideProjectRoot;
    // Guard the separator too: `/project-other` starts with `/project` and is a
    // different tree.
    if (resolved.len <= canonical_root.len or resolved[canonical_root.len] != std.fs.path.sep) {
        return error.PathOutsideProjectRoot;
    }
    return allocator.dupe(u8, resolved[canonical_root.len + 1 ..]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sourceDigest is lowercase hex sha256" {
    const empty = sourceDigest("");
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &empty,
    );
    const abc = sourceDigest("abc");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &abc,
    );
}

test "canonicalRelPath returns a root-relative slash path" {
    const a = std.testing.allocator;
    const rel = try canonicalRelPath(a, std.testing.io, "/project", "/project/src/handler.ts");
    defer a.free(rel);
    try std.testing.expectEqualStrings("src/handler.ts", rel);
}

test "canonicalRelPath collapses dot segments" {
    const a = std.testing.allocator;
    const rel = try canonicalRelPath(a, std.testing.io, "/project", "/project/src/../src/./handler.ts");
    defer a.free(rel);
    try std.testing.expectEqualStrings("src/handler.ts", rel);
}

test "canonicalRelPath rejects a path outside the project root" {
    const a = std.testing.allocator;
    try std.testing.expectError(
        error.PathOutsideProjectRoot,
        canonicalRelPath(a, std.testing.io, "/project", "/project/../secrets.ts"),
    );
    try std.testing.expectError(
        error.PathOutsideProjectRoot,
        canonicalRelPath(a, std.testing.io, "/project", "/project-other/handler.ts"),
    );
}

test "canonicalRelPath maps the root itself to the empty string" {
    const a = std.testing.allocator;
    const rel = try canonicalRelPath(a, std.testing.io, "/project", "/project");
    defer a.free(rel);
    try std.testing.expectEqualStrings("", rel);
}

test "canonicalRelPath resolves a relative path against the root" {
    const a = std.testing.allocator;
    const rel = try canonicalRelPath(a, std.testing.io, "/project", "src/handler.ts");
    defer a.free(rel);
    try std.testing.expectEqualStrings("src/handler.ts", rel);
}

test "canonicalRelPath follows a symlink out of the tree and rejects it" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.ts", .data = "export const x = 1;\n" });

    const outside_abs = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, "outside.ts", a);
    defer a.free(outside_abs);
    tmp.dir.symLink(io, outside_abs, "root/link.ts", .{}) catch |err| switch (err) {
        // A filesystem without symlink support is not a reason to fail the
        // suite; the lexical guard above still covers the escape.
        error.AccessDenied => return,
        else => return err,
    };

    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, "root", a);
    defer a.free(root);

    try std.testing.expectError(
        error.PathOutsideProjectRoot,
        canonicalRelPath(a, io, root, "link.ts"),
    );
}

test "canonicalRelPath keeps a real file inside the root" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/handler.ts", .data = "export const x = 1;\n" });

    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", a);
    defer a.free(root);

    const rel = try canonicalRelPath(a, io, root, "src/handler.ts");
    defer a.free(rel);
    try std.testing.expectEqualStrings("src/handler.ts", rel);
}

test "canonicalRoot rejects a root that does not exist" {
    const a = std.testing.allocator;
    try std.testing.expectError(
        error.ProjectRootUnresolvable,
        canonicalRoot(a, std.testing.io, "/no/such/project/root/here"),
    );
}
