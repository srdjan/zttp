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
//! The path functions take an `std.Io`:
//! every filesystem call goes through an `Io` instance. Callers that have
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
/// the tree is caught. When the target does not exist yet, the deepest
/// existing ancestor is canonicalized and combined with the remaining tail,
/// closing symlink escapes through an existing parent directory.
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

    const resolved = try canonicalizeExistingOrAncestor(allocator, io, joined);
    defer allocator.free(resolved);

    if (std.mem.eql(u8, resolved, canonical_root)) return allocator.dupe(u8, "");
    if (std.mem.eql(u8, canonical_root, "/")) {
        if (resolved.len <= 1 or resolved[0] != std.fs.path.sep) return error.PathOutsideProjectRoot;
        return allocator.dupe(u8, resolved[1..]);
    }
    if (!std.mem.startsWith(u8, resolved, canonical_root)) return error.PathOutsideProjectRoot;
    // Guard the separator too: `/project-other` starts with `/project` and is a
    // different tree.
    if (resolved.len <= canonical_root.len or resolved[canonical_root.len] != std.fs.path.sep) {
        return error.PathOutsideProjectRoot;
    }
    return allocator.dupe(u8, resolved[canonical_root.len + 1 ..]);
}

fn canonicalizeExistingOrAncestor(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    const lexical = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(lexical);

    if (std.Io.Dir.realPathFileAlloc(.cwd(), io, lexical, allocator)) |real| {
        defer allocator.free(real);
        return allocator.dupe(u8, real);
    } else |_| {}

    var ancestor: []const u8 = lexical;
    while (std.fs.path.dirname(ancestor)) |parent| {
        if (std.mem.eql(u8, parent, ancestor)) break;
        ancestor = parent;
        if (std.Io.Dir.realPathFileAlloc(.cwd(), io, ancestor, allocator)) |real_ancestor| {
            defer allocator.free(real_ancestor);
            const suffix = std.mem.trimStart(u8, lexical[ancestor.len..], "/\\");
            if (suffix.len == 0) return allocator.dupe(u8, real_ancestor);
            return std.fs.path.resolve(allocator, &.{ real_ancestor, suffix });
        } else |_| {}
    }

    return allocator.dupe(u8, lexical);
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

test "canonicalRelPath rejects a nonexistent file under an escaping symlinked directory" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside");

    const outside_abs = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, "outside", a);
    defer a.free(outside_abs);
    tmp.dir.symLink(io, outside_abs, "root/escape_dir", .{}) catch |err| switch (err) {
        error.AccessDenied => return,
        else => return err,
    };

    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, "root", a);
    defer a.free(root);

    try std.testing.expectError(
        error.PathOutsideProjectRoot,
        canonicalRelPath(a, io, root, "escape_dir/new_file.ts"),
    );
}

test "canonicalRelPath handles filesystem root" {
    const a = std.testing.allocator;
    const rel = try canonicalRelPath(a, std.testing.io, "/", "/nonexistent_zttp_root_test/src/handler.ts");
    defer a.free(rel);
    try std.testing.expectEqualStrings("nonexistent_zttp_root_test/src/handler.ts", rel);
}
