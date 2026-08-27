//! `zttp proofs bundle` packages a handler's contract, optional binary,
//! and optional replay artifacts into a directory layout a third party
//! can verify deterministically. `zttp proofs verify <dir>` re-checks
//! every SHA-256 in the manifest against the actual file bytes.
//!
//! Layout under `--out <dir>`:
//!   - bundle.json            manifest (tool version, sha256s of all parts)
//!   - handler.contract.json  byte-for-byte copy of the input contract
//!   - binary                 copy of `--binary <path>` (when supplied)
//!   - binary.sha256          hex digest as a text file (when supplied)
//!   - replay/<filename>      copy of `--replay <path>` (when supplied)
//!
//! Hard redaction guardrail: the bundle is built from explicit file
//! arguments only. `rejectSuspiciousPath` blocks parent-dir traversal and
//! system roots. `verify` additionally rejects manifest component paths
//! that are absolute or contain `..` segments, so a crafted bundle.json
//! cannot make the verifier hash files outside the bundle directory.
//! Contracts are not introspected for value fields; the contract format
//! is the authority on what fields exist.

const std = @import("std");
const zts = @import("zts");
const static_mod = @import("../server_static.zig");

pub const tool_version: []const u8 = "zttp-bundle-1";

pub const BundleArgs = struct {
    contract_path: []const u8,
    binary_path: ?[]const u8 = null,
    replay_path: ?[]const u8 = null,
    out_dir: []const u8,
};

pub const ComponentVerdict = struct {
    name: []const u8,
    pass: bool,
    expected_sha: [64]u8,
    actual_sha: [64]u8,
};

pub fn writeBundle(allocator: std.mem.Allocator, args: BundleArgs, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.contract_path.len == 0) {
        try stderr.writeAll("zttp proofs bundle: --contract <path> is required\n");
        return error.MissingContractArg;
    }
    if (args.out_dir.len == 0) {
        try stderr.writeAll("zttp proofs bundle: --out <dir> is required\n");
        return error.MissingOutArg;
    }

    try rejectSuspiciousPath(args.contract_path);
    if (args.binary_path) |p| try rejectSuspiciousPath(p);
    if (args.replay_path) |p| try rejectSuspiciousPath(p);
    try rejectSuspiciousPath(args.out_dir);

    try ensureDir(allocator, args.out_dir);

    const contract_bytes = try zts.file_io.readFile(allocator, args.contract_path, 256 * 1024 * 1024);
    defer allocator.free(contract_bytes);
    const contract_sha = sha256Hex(contract_bytes);
    const contract_dest = try std.fs.path.join(allocator, &.{ args.out_dir, "handler.contract.json" });
    defer allocator.free(contract_dest);
    try zts.file_io.writeFile(allocator, contract_dest, contract_bytes);

    var binary_sha_hex: ?[64]u8 = null;
    if (args.binary_path) |path| {
        const binary_bytes = try zts.file_io.readFile(allocator, path, 256 * 1024 * 1024);
        defer allocator.free(binary_bytes);
        const sha = sha256Hex(binary_bytes);
        binary_sha_hex = sha;
        const bin_dest = try std.fs.path.join(allocator, &.{ args.out_dir, "binary" });
        defer allocator.free(bin_dest);
        try zts.file_io.writeFile(allocator, bin_dest, binary_bytes);
        const sha_dest = try std.fs.path.join(allocator, &.{ args.out_dir, "binary.sha256" });
        defer allocator.free(sha_dest);
        try zts.file_io.writeFile(allocator, sha_dest, &sha);
    }

    var replay_sha_hex: ?[64]u8 = null;
    var replay_basename: ?[]const u8 = null;
    if (args.replay_path) |path| {
        // Replay traces are JSONL records, expected to be KB-MB. Cap below
        // the 256 MiB contract/binary limit so a misrouted binary blob
        // path fails fast instead of silently bundling.
        const replay_bytes = try zts.file_io.readFile(allocator, path, 32 * 1024 * 1024);
        defer allocator.free(replay_bytes);
        const sha = sha256Hex(replay_bytes);
        replay_sha_hex = sha;

        const replay_dir = try std.fs.path.join(allocator, &.{ args.out_dir, "replay" });
        defer allocator.free(replay_dir);
        try ensureDir(allocator, replay_dir);

        const basename = std.fs.path.basename(path);
        replay_basename = basename;
        const replay_dest = try std.fs.path.join(allocator, &.{ replay_dir, basename });
        defer allocator.free(replay_dest);
        try zts.file_io.writeFile(allocator, replay_dest, replay_bytes);
    }

    var manifest_buf: std.ArrayList(u8) = .empty;
    defer manifest_buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &manifest_buf);
    try writeManifest(&aw.writer, .{
        .contract_sha = contract_sha,
        .binary_sha = binary_sha_hex,
        .replay_sha = replay_sha_hex,
        .replay_basename = replay_basename,
    });
    manifest_buf = aw.toArrayList();

    const manifest_dest = try std.fs.path.join(allocator, &.{ args.out_dir, "bundle.json" });
    defer allocator.free(manifest_dest);
    try zts.file_io.writeFile(allocator, manifest_dest, manifest_buf.items);

    try stdout.print("Wrote bundle to {s}/\n", .{args.out_dir});
    try stdout.print("  handler.contract.json  sha256={s}\n", .{contract_sha});
    if (binary_sha_hex) |s| try stdout.print("  binary                 sha256={s}\n", .{s});
    if (replay_sha_hex) |s| try stdout.print("  replay/{s}         sha256={s}\n", .{ replay_basename.?, s });
}

const ManifestFields = struct {
    contract_sha: [64]u8,
    binary_sha: ?[64]u8,
    replay_sha: ?[64]u8,
    replay_basename: ?[]const u8,
};

fn writeManifest(writer: *std.Io.Writer, m: ManifestFields) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"toolVersion\": \"{s}\",\n", .{tool_version});
    try writer.writeAll("  \"createdAt\": \"1970-01-01T00:00:00Z\",\n");
    try writer.writeAll("  \"components\": {\n");
    try writer.print("    \"contract\": {{ \"path\": \"handler.contract.json\", \"sha256\": \"{s}\" }}", .{m.contract_sha});
    if (m.binary_sha) |s| {
        try writer.writeAll(",\n");
        try writer.print("    \"binary\": {{ \"path\": \"binary\", \"sha256\": \"{s}\" }}", .{s});
    }
    if (m.replay_sha) |s| {
        try writer.writeAll(",\n");
        try writer.print("    \"replay\": {{ \"path\": \"replay/{s}\", \"sha256\": \"{s}\" }}", .{ m.replay_basename.?, s });
    }
    try writer.writeAll("\n  }\n}\n");
}

pub fn verify(allocator: std.mem.Allocator, bundle_dir_path: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    try rejectSuspiciousPath(bundle_dir_path);

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var bundle_dir = std.Io.Dir.cwd().openDir(io, bundle_dir_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop => return error.SuspiciousPath,
        else => {
            try stderr.print("zttp proofs verify: cannot open bundle directory '{s}'\n", .{bundle_dir_path});
            return error.NoBundleJson;
        },
    };
    defer bundle_dir.close(io);

    const manifest_bytes = readBundleManifest(allocator, io, bundle_dir, 16 * 1024 * 1024, stderr) catch |err| switch (err) {
        error.SuspiciousPath => return err,
        else => {
            try stderr.print("zttp proofs verify: cannot read manifest at '{s}/bundle.json'\n", .{bundle_dir_path});
            return error.NoBundleJson;
        },
    };
    defer allocator.free(manifest_bytes);

    var verdicts: std.ArrayList(ComponentVerdict) = .empty;
    defer {
        for (verdicts.items) |v| allocator.free(v.name);
        verdicts.deinit(allocator);
    }
    try verifyComponents(allocator, io, bundle_dir, manifest_bytes, &verdicts, stderr);

    // Fail closed: a manifest the component scanner could not parse (e.g. `{}`
    // or a format it does not recognize) yields zero verdicts, and an empty
    // loop would otherwise print "verified" and exit 0 having checked nothing.
    if (verdicts.items.len == 0) {
        try stderr.print("zttp proofs verify: no components found in manifest '{s}/bundle.json'\n", .{bundle_dir_path});
        return error.NoComponentsVerified;
    }

    var any_failed = false;
    for (verdicts.items) |v| {
        const label: []const u8 = if (v.pass) "OK  " else "FAIL";
        try stdout.print("  {s}  {s}\n", .{ label, v.name });
        if (!v.pass) {
            any_failed = true;
            try stdout.print("        expected sha256 {s}\n", .{v.expected_sha});
            try stdout.print("        actual   sha256 {s}\n", .{v.actual_sha});
        }
    }

    if (any_failed) return error.Sha256Mismatch;
    try stdout.writeAll("\nBundle verified: every component sha256 matches the manifest.\n");
}

fn readBundleManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    bundle_dir: std.Io.Dir,
    max_bytes: usize,
    stderr: *std.Io.Writer,
) ![]u8 {
    const name = "bundle.json";
    const stat = bundle_dir.statFile(io, name, .{ .follow_symlinks = false }) catch return error.FileNotFound;
    if (stat.kind == .sym_link) {
        try stderr.writeAll("zttp proofs verify: bundle.json must not be a symlink\n");
        return error.SuspiciousPath;
    }
    if (stat.kind != .file or stat.size > max_bytes) return error.InvalidManifest;
    const size = std.math.cast(usize, stat.size) orelse return error.InvalidManifest;
    const file = bundle_dir.openFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop => return error.SuspiciousPath,
        else => return err,
    };
    defer file.close(io);

    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    reader.interface.readSliceAll(bytes) catch return error.FileReadFailed;
    _ = reader.interface.takeByte() catch |err| switch (err) {
        error.EndOfStream => return bytes,
        else => return error.FileReadFailed,
    };
    return error.InvalidManifest;
}

fn verifyComponents(
    allocator: std.mem.Allocator,
    io: std.Io,
    bundle_dir: std.Io.Dir,
    manifest_bytes: []const u8,
    out: *std.ArrayList(ComponentVerdict),
    stderr: *std.Io.Writer,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{}) catch {
        try stderr.writeAll("zttp proofs verify: bundle manifest is not valid JSON\n");
        return error.InvalidManifest;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    const components_value = root.get("components") orelse return error.InvalidManifest;
    const components = switch (components_value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    if (components.count() == 0 or components.count() > 3) return error.InvalidManifest;
    _ = components.get("contract") orelse return error.InvalidManifest;

    var paths: [3][]const u8 = undefined;
    var path_count: usize = 0;
    var iterator = components.iterator();
    while (iterator.next()) |component| {
        const name = component.key_ptr.*;
        if (!isSupportedComponent(name)) return error.InvalidManifest;
        const fields = switch (component.value_ptr.*) {
            .object => |object| object,
            else => return error.InvalidManifest,
        };
        if (fields.count() != 2) return error.InvalidManifest;
        const path_value = fields.get("path") orelse return error.InvalidManifest;
        const sha_value = fields.get("sha256") orelse return error.InvalidManifest;
        const path = switch (path_value) {
            .string => |value| value,
            else => return error.InvalidManifest,
        };
        const expected_sha = switch (sha_value) {
            .string => |value| parseSha256(value) orelse return error.InvalidManifest,
            else => return error.InvalidManifest,
        };
        for (paths[0..path_count]) |seen| {
            if (std.mem.eql(u8, seen, path)) return error.InvalidManifest;
        }
        paths[path_count] = path;
        path_count += 1;

        // The manifest is untrusted input: an absolute or `..`-containing
        // component path would make the verifier hash arbitrary files.
        if (!static_mod.isPathSafe(path)) {
            try stderr.print("zttp proofs verify: component path '{s}' escapes the bundle directory\n", .{path});
            return error.SuspiciousPath;
        }
        const actual = hashBundleFile(io, bundle_dir, path, 256 * 1024 * 1024, stderr) catch |err| switch (err) {
            error.SuspiciousPath => return err,
            else => return error.MissingComponent,
        };

        const name_dup = try allocator.dupe(u8, name);
        errdefer allocator.free(name_dup);
        try out.append(allocator, .{
            .name = name_dup,
            .pass = std.mem.eql(u8, &actual, &expected_sha),
            .expected_sha = expected_sha,
            .actual_sha = actual,
        });
    }
}

fn hashBundleFile(
    io: std.Io,
    bundle_dir: std.Io.Dir,
    relative_path: []const u8,
    max_bytes: usize,
    stderr: *std.Io.Writer,
) ![64]u8 {
    if (!static_mod.isPathSafe(relative_path)) {
        try stderr.print("zttp proofs verify: component path '{s}' escapes the bundle directory\n", .{relative_path});
        return error.SuspiciousPath;
    }

    var parts = std.mem.splitAny(u8, relative_path, "/\\");
    var component = parts.next() orelse return error.SuspiciousPath;
    if (component.len == 0) return error.SuspiciousPath;
    var current = bundle_dir;
    var current_owned = false;
    defer if (current_owned) current.close(io);

    while (parts.next()) |next| {
        if (next.len == 0) return error.SuspiciousPath;
        const stat = current.statFile(io, component, .{ .follow_symlinks = false }) catch return error.FileNotFound;
        if (stat.kind == .sym_link) {
            try stderr.print("zttp proofs verify: component path '{s}' contains a symlink\n", .{relative_path});
            return error.SuspiciousPath;
        }
        if (stat.kind != .directory) return error.NotDir;
        const child = current.openDir(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop, error.NotDir => {
                try stderr.print("zttp proofs verify: component path '{s}' contains an invalid directory\n", .{relative_path});
                return error.SuspiciousPath;
            },
            else => return err,
        };
        if (current_owned) current.close(io);
        current = child;
        current_owned = true;
        component = next;
    }

    const final_stat = current.statFile(io, component, .{ .follow_symlinks = false }) catch return error.FileNotFound;
    if (final_stat.kind == .sym_link) {
        try stderr.print("zttp proofs verify: component path '{s}' contains a symlink\n", .{relative_path});
        return error.SuspiciousPath;
    }
    const file = current.openFile(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop => {
            try stderr.print("zttp proofs verify: component path '{s}' contains a symlink\n", .{relative_path});
            return error.SuspiciousPath;
        },
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > max_bytes) return error.FileTooBig;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: usize = 0;
    // The reader's own buffer must not also be the read destination: a
    // component past one chunk then copies a slice onto itself.
    var reader_buffer: [4096]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    while (true) {
        const count = reader.interface.readSliceShort(&chunk) catch return error.FileReadFailed;
        if (count == 0) break;
        if (count > max_bytes -| total) return error.FileTooBig;
        total += count;
        hasher.update(chunk[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn isSupportedComponent(name: []const u8) bool {
    return std.mem.eql(u8, name, "contract") or
        std.mem.eql(u8, name, "binary") or
        std.mem.eql(u8, name, "replay");
}

fn parseSha256(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    }
    var result: [64]u8 = undefined;
    @memcpy(&result, value);
    return result;
}

fn rejectSuspiciousPath(path: []const u8) !void {
    if (path.len == 0) return;
    if (std.mem.indexOf(u8, path, "..") != null) return error.SuspiciousPath;
    if (std.mem.startsWith(u8, path, "/etc/") or std.mem.startsWith(u8, path, "/var/")) return error.SuspiciousPath;
}

fn ensureDir(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    switch (std.posix.errno(std.posix.system.mkdir(path_z, 0o755))) {
        .SUCCESS, .EXIST => {},
        else => return error.MakeDirFailed,
    }
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sha256Hex of empty buffer matches known digest" {
    const sha = sha256Hex("");
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &sha);
}

test "rejectSuspiciousPath blocks parent traversal and system roots" {
    try std.testing.expectError(error.SuspiciousPath, rejectSuspiciousPath("../etc/passwd"));
    try std.testing.expectError(error.SuspiciousPath, rejectSuspiciousPath("/etc/shadow"));
    try std.testing.expectError(error.SuspiciousPath, rejectSuspiciousPath("/var/log/whatever"));
    try rejectSuspiciousPath("contract.json");
    try rejectSuspiciousPath("./out/bundle");
}

test "bundle manifest accepts only supported names and lowercase digests" {
    try std.testing.expect(isSupportedComponent("contract"));
    try std.testing.expect(isSupportedComponent("binary"));
    try std.testing.expect(isSupportedComponent("replay"));
    try std.testing.expect(!isSupportedComponent("extra"));
    try std.testing.expect(parseSha256("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    try std.testing.expect(parseSha256("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") == null);
    try std.testing.expect(parseSha256("short") == null);
}

const test_chdir = @import("../proof_ledger.zig").chdirTmpForTest;

test "verify rejects a manifest component path with parent traversal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // The target exists outside the bundle dir and its sha256 matches the
    // manifest, so a verifier that read it would report the component OK.
    try zts.file_io.writeFile(std.testing.allocator, "secret", "outside-the-bundle");
    try ensureDir(std.testing.allocator, "bundle");
    const secret_sha = sha256Hex("outside-the-bundle");
    var manifest_buf: [256]u8 = undefined;
    const manifest = try std.fmt.bufPrint(
        &manifest_buf,
        "{{\n  \"components\": {{\n    \"contract\": {{ \"path\": \"../secret\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{secret_sha},
    );
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.SuspiciousPath, verify(std.testing.allocator, "bundle", &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "OK") == null);
    try std.testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "../secret") != null);
}

test "verify rejects an absolute manifest component path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try zts.file_io.writeFile(std.testing.allocator, "secret", "outside-the-bundle");
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const abs_secret = try std.fs.path.join(std.testing.allocator, &.{ cwd, "secret" });
    defer std.testing.allocator.free(abs_secret);

    try ensureDir(std.testing.allocator, "bundle");
    const secret_sha = sha256Hex("outside-the-bundle");
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\n  \"components\": {{\n    \"contract\": {{ \"path\": \"{s}\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{ abs_secret, secret_sha },
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.SuspiciousPath, verify(std.testing.allocator, "bundle", &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "OK") == null);
    try std.testing.expect(std.mem.indexOf(u8, err.writer.buffered(), abs_secret) != null);
}

test "verify rejects a symlink component without hashing its target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try zts.file_io.writeFile(std.testing.allocator, "secret", "outside-the-bundle");
    try ensureDir(std.testing.allocator, "bundle");
    try tmp.dir.symLink(std.testing.io, "../secret", "bundle/handler.contract.json", .{});
    const secret_sha = sha256Hex("outside-the-bundle");
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\n  \"components\": {{\n    \"contract\": {{ \"path\": \"handler.contract.json\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{secret_sha},
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.SuspiciousPath, verify(std.testing.allocator, "bundle", &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "OK") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "actual") == null);
    try std.testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "handler.contract.json") != null);
}

test "verify rejects an intermediate directory symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureDir(std.testing.allocator, "bundle");
    try ensureDir(std.testing.allocator, "outside");
    try zts.file_io.writeFile(std.testing.allocator, "bundle/handler.contract.json", "contract");
    try zts.file_io.writeFile(std.testing.allocator, "outside/trace.jsonl", "outside-the-bundle");
    try tmp.dir.symLink(std.testing.io, "../outside", "bundle/replay", .{ .is_directory = true });
    const secret_sha = sha256Hex("outside-the-bundle");
    const contract_sha = sha256Hex("contract");
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\n  \"components\": {{\n    \"contract\": {{ \"path\": \"handler.contract.json\", \"sha256\": \"{s}\" }},\n    \"replay\": {{ \"path\": \"replay/trace.jsonl\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{ contract_sha, secret_sha },
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.SuspiciousPath, verify(std.testing.allocator, "bundle", &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "OK") == null);
    try std.testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "replay/trace.jsonl") != null);
}

test "verify rejects duplicate component paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureDir(std.testing.allocator, "bundle");
    try zts.file_io.writeFile(std.testing.allocator, "bundle/component", "same-file");
    const sha = sha256Hex("same-file");
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"components\":{{\"contract\":{{\"path\":\"component\",\"sha256\":\"{s}\"}},\"binary\":{{\"path\":\"component\",\"sha256\":\"{s}\"}}}}}}",
        .{ sha, sha },
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.InvalidManifest, verify(std.testing.allocator, "bundle", &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "OK") == null);
}

test "verify rejects unsupported manifest components" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureDir(std.testing.allocator, "bundle");
    try zts.file_io.writeFile(std.testing.allocator, "bundle/component", "data");
    const sha = sha256Hex("data");
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"components\":{{\"extra\":{{\"path\":\"component\",\"sha256\":\"{s}\"}}}}}}",
        .{sha},
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.InvalidManifest, verify(std.testing.allocator, "bundle", &out.writer, &err.writer));
}

test "verify rejects a supported manifest without a contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureDir(std.testing.allocator, "bundle");
    try zts.file_io.writeFile(std.testing.allocator, "bundle/trace.jsonl", "valid-replay");
    const sha = sha256Hex("valid-replay");
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"components\":{{\"replay\":{{\"path\":\"trace.jsonl\",\"sha256\":\"{s}\"}}}}}}",
        .{sha},
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.InvalidManifest, verify(std.testing.allocator, "bundle", &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "Bundle verified") == null);
}

test "verify passes a bundle written by writeBundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try zts.file_io.writeFile(std.testing.allocator, "contract.json", "{\"routes\":[]}");
    try zts.file_io.writeFile(std.testing.allocator, "trace.jsonl", "{\"event\":\"ok\"}\n");

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try writeBundle(std.testing.allocator, .{
        .contract_path = "contract.json",
        .replay_path = "trace.jsonl",
        .out_dir = "bundle",
    }, &out.writer, &err.writer);

    var verify_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer verify_out.deinit();
    var verify_err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer verify_err.deinit();
    try verify(std.testing.allocator, "bundle", &verify_out.writer, &verify_err.writer);
    const text = verify_out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Bundle verified") != null);
}

test "verify hashes a component larger than one read buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // Three chunks past the 64 KiB read buffer, so a reader that reads into
    // its own buffer corrupts the digest instead of matching the manifest.
    const big = try std.testing.allocator.alloc(u8, 200 * 1024);
    defer std.testing.allocator.free(big);
    for (big, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try zts.file_io.writeFile(std.testing.allocator, "contract.json", big);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try writeBundle(std.testing.allocator, .{
        .contract_path = "contract.json",
        .out_dir = "bundle",
    }, &out.writer, &err.writer);

    var verify_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer verify_out.deinit();
    var verify_err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer verify_err.deinit();
    try verify(std.testing.allocator, "bundle", &verify_out.writer, &verify_err.writer);
    try std.testing.expect(std.mem.indexOf(u8, verify_out.writer.buffered(), "Bundle verified") != null);
}
