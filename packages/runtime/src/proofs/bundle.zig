//! `zttp proofs bundle` packages a handler's contract, optional binary,
//! extracted artifact certificate, and optional replay artifacts into a
//! directory layout a third party can verify deterministically. `zttp proofs
//! verify <dir>` checks every SHA-256, then runs independent artifact proof
//! acceptance when the binary and certificate are present.
//!
//! Layout under `--out <dir>`:
//!   - bundle.json            manifest (tool version, sha256s of all parts)
//!   - handler.contract.json  byte-for-byte copy of the input contract
//!   - binary                 copy of `--binary <path>` (when supplied)
//!   - binary.sha256          hex digest as a text file (when supplied)
//!   - certificate            copy extracted from the binary (when supplied)
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
const pcc = @import("zttp_proof_checker");
const artifact_graph = @import("../artifact_graph.zig");
const contract_runtime = @import("../contract_runtime.zig");
const self_extract = @import("../self_extract.zig");
const static_mod = @import("../server_static.zig");
const guard_report = @import("guard_report.zig");

/// Bumped to 2 for the certificate component. The verifier checks this for
/// equality: a version-1 bundle carried hashes and nothing that could be
/// semantically checked, so reading one under the current rules would report an
/// assurance it never had.
pub const tool_version: []const u8 = "zttp-bundle-2";

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
    var certificate_sha_hex: ?[64]u8 = null;
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

        // Lift the certificate out of the artifact so a verifier can read it
        // without re-deriving the container layout. The copy is redundant with
        // the binary on purpose: it is what makes `certificate` a component
        // with its own hash in the manifest, and the verifier checks it against
        // the artifact anyway.
        if (payloadFromBinary(allocator, binary_bytes)) |parsed| {
            var payload = parsed;
            defer payload.deinit(allocator);
            if (payload.certificate) |certificate| {
                certificate_sha_hex = sha256Hex(certificate);
                const cert_dest = try std.fs.path.join(allocator, &.{ args.out_dir, "certificate" });
                defer allocator.free(cert_dest);
                try zts.file_io.writeFile(allocator, cert_dest, certificate);
            }
        }
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
        .certificate_sha = certificate_sha_hex,
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
    if (certificate_sha_hex) |s| try stdout.print("  certificate            sha256={s}\n", .{s});
    if (binary_sha_hex != null and certificate_sha_hex == null) {
        try stdout.writeAll("  certificate            absent: this artifact carries no proof\n");
    }
    if (replay_sha_hex) |s| try stdout.print("  replay/{s}         sha256={s}\n", .{ replay_basename.?, s });
}

const ManifestFields = struct {
    contract_sha: [64]u8,
    binary_sha: ?[64]u8,
    certificate_sha: ?[64]u8,
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
    if (m.certificate_sha) |s| {
        try writer.writeAll(",\n");
        try writer.print("    \"certificate\": {{ \"path\": \"certificate\", \"sha256\": \"{s}\" }}", .{s});
    }
    if (m.replay_sha) |s| {
        try writer.writeAll(",\n");
        try writer.print("    \"replay\": {{ \"path\": \"replay/{s}\", \"sha256\": \"{s}\" }}", .{ m.replay_basename.?, s });
    }
    try writer.writeAll("\n  }\n}\n");
}

/// Verify a bundle.
///
/// Integrity and proof are reported as separate states, because they are
/// separate things: matching hashes say the bundle holds the bytes the manifest
/// names, and nothing more. `require_proof` is for a caller that needs the
/// stronger state to be an exit code rather than a line of output - a bundle
/// with no certificate is not a failure of the bundle, only of what it can
/// establish.
pub fn verify(
    allocator: std.mem.Allocator,
    bundle_dir_path: []const u8,
    require_proof: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
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
    var has_binary = false;
    var has_certificate = false;
    for (verdicts.items) |v| {
        const label: []const u8 = if (v.pass) "OK  " else "FAIL";
        try stdout.print("  {s}  {s}\n", .{ label, v.name });
        if (std.mem.eql(u8, v.name, "binary")) has_binary = true;
        if (std.mem.eql(u8, v.name, "certificate")) has_certificate = true;
        if (!v.pass) {
            any_failed = true;
            try stdout.print("        expected sha256 {s}\n", .{v.expected_sha});
            try stdout.print("        actual   sha256 {s}\n", .{v.actual_sha});
        }
    }

    if (any_failed) {
        try stdout.writeAll("\nIntegrity: FAILED - a component does not match the manifest.\n");
        return error.Sha256Mismatch;
    }
    try stdout.print(
        "\nIntegrity: verified ({d} component(s) match the manifest)\n",
        .{verdicts.items.len},
    );

    // Integrity is one state. What the artifact does is another, and a bundle
    // that only matched hashes has established nothing about it. Say which one
    // was reached rather than printing a single word that reads as both.
    if (!has_binary or !has_certificate) {
        try stdout.writeAll(
            "Proof:     not checked - this bundle carries no artifact and certificate to check\n",
        );
        if (require_proof) return error.NoProofToCheck;
        return;
    }

    verifySemantics(allocator, io, bundle_dir, stdout, stderr) catch |err| switch (err) {
        // Nothing to check is not the same as checked and refused. A caller
        // that needs the stronger state says so; one that does not gets the
        // line and a zero exit.
        error.NoProofToCheck => if (require_proof) return err,
        else => return err,
    };
}

/// Rebuild the executable graph from the bundled artifact and run consumer
/// acceptance over the bundled certificate.
///
/// The certificate component is read from the bundle, but everything it is
/// checked against comes from the artifact: the inventory is derived from the
/// payload sections, not from the manifest and not from the certificate's own
/// list.
fn verifySemantics(
    allocator: std.mem.Allocator,
    io: std.Io,
    bundle_dir: std.Io.Dir,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const binary_bytes = readBundleFile(allocator, io, bundle_dir, "binary", 256 * 1024 * 1024) catch {
        try stderr.writeAll("zttp proofs verify: cannot read the bundled artifact\n");
        return error.InvalidManifest;
    };
    defer allocator.free(binary_bytes);

    var payload = payloadFromBinary(allocator, binary_bytes) orelse {
        try stdout.writeAll(
            "Proof:     not checked - the bundled file carries no readable deployment payload\n",
        );
        return error.NoProofToCheck;
    };
    defer payload.deinit(allocator);

    const certificate = payload.certificate orelse {
        try stdout.writeAll("Proof:     not checked - the artifact carries no certificate\n");
        return error.NoProofToCheck;
    };

    var identity = artifact_graph.Identity{};
    var raw: ?contract_runtime.RawRuntimeContract = null;
    defer if (raw) |*value| value.deinit();
    if (payload.contract_json) |json| {
        raw = contract_runtime.parseContractJson(allocator, json) catch null;
        if (raw) |*value| {
            const view = value.rawView();
            identity = .{
                .module_specifiers = view.modules,
                .core_profile_id = view.source_identity.core_profile.id(),
                .core_grammar_hash = view.source_identity.core_grammar_hash,
                .semantics_hash = view.source_identity.semantics_hash,
                .capability_hash = if (view.capabilities) |caps| caps.hash else [_]u8{0} ** 32,
                .frontend_profile_id = if (view.source_identity.frontend) |f| f.profile.id() else null,
                .frontend_grammar_hash = if (view.source_identity.frontend) |f| f.grammar_hash else null,
            };
        }
    }

    const assessment = try @import("../proof_activation.zig").accept(allocator, .{
        .certificate = certificate,
        .bytecode = payload.bytecode,
        .dep_bytecodes = payload.dep_bytecodes,
        .contract_section = payload.contract_json,
        .policy_section_digest = payload.policy_section_sha256,
        .identity = identity,
        .provenance = if (payload.attestation_jws != null) .unchecked else .absent,
    }, pcc.policy.production);

    if (assessment.rejection) |rejection| {
        try stdout.print(
            "Proof:     REJECTED at {s} ({s}); reached {s}\n",
            .{ rejection.stage.name(), rejection.code.text(), assessment.semantic.name() },
        );
        try stdout.print(
            "           {s} rebuilding and recertifying this handler.\n",
            .{if (rejection.recertifiable) "Resolvable by" else "Not resolvable by"},
        );
        return error.ProofRejected;
    }

    try stdout.print(
        "Proof:     {s} (weakest edge: {s}; {d} disclosed edge(s) the consumer did not check{s})\n",
        .{
            assessment.semantic.name(),
            if (assessment.grade) |grade| grade.name() else "none",
            assessment.disclosed_edges,
            if (assessment.development_only) ", development artifact" else "",
        },
    );
    // Coverage on its own line, never inside the proof line above. A covered
    // guard is a promise to check a value at request time; the line above is
    // about what was proved before the artifact shipped.
    var guard_buf: [256]u8 = undefined;
    var guard_writer = std.Io.Writer.fixed(&guard_buf);
    guard_report.writeSummary(&guard_writer, assessment.guards) catch {};
    try stdout.print("Guards:    {s}\n", .{guard_writer.buffered()});
    try stdout.print(
        "Signature: {s}\n",
        .{switch (assessment.provenance) {
            .absent => "absent - this artifact is unsigned, which does not weaken the proof above",
            .unchecked => "present, not checked here - run `zttp verify <url>` against a running deployment",
            .signature_verified => "verified, key not pinned",
            .trusted_origin => "verified against a pinned key",
        }},
    );
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
    // The bundle format is checked for equality, not for a lower bound. A
    // version-1 bundle carried component hashes and no certificate; reading one
    // here would print an assurance report about evidence it never held.
    const version_value = root.get("toolVersion") orelse {
        try stderr.writeAll("zttp proofs verify: bundle manifest has no toolVersion\n");
        return error.InvalidManifest;
    };
    const version = switch (version_value) {
        .string => |value| value,
        else => return error.InvalidManifest,
    };
    if (!std.mem.eql(u8, version, tool_version)) {
        try stderr.print(
            "zttp proofs verify: bundle format '{s}' is not '{s}'. Rebuild the bundle with the current toolchain.\n",
            .{ version, tool_version },
        );
        return error.UnsupportedBundleVersion;
    }

    const components_value = root.get("components") orelse return error.InvalidManifest;
    const components = switch (components_value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    if (components.count() == 0 or components.count() > 4) return error.InvalidManifest;
    _ = components.get("contract") orelse return error.InvalidManifest;

    var paths: [4][]const u8 = undefined;
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

/// Read one bundle file, refusing a symlink and a size above the cap.
///
/// The path is a fixed name this file chose, never a manifest string, so the
/// traversal guards `hashBundleFile` needs do not apply here. The symlink check
/// does: the bundle directory is attacker-supplied even when the names are not.
fn readBundleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    bundle_dir: std.Io.Dir,
    name: []const u8,
    max_bytes: usize,
) ![]u8 {
    const stat = bundle_dir.statFile(io, name, .{ .follow_symlinks = false }) catch return error.FileNotFound;
    if (stat.kind != .file) return error.SuspiciousPath;
    if (stat.size > max_bytes) return error.FileTooBig;
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    var file = bundle_dir.openFile(io, name, .{ .follow_symlinks = false }) catch return error.FileNotFound;
    defer file.close(io);
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);
    // The reader's own buffer must not also be the read destination.
    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var offset: usize = 0;
    while (offset < size) {
        const read = reader.interface.readSliceShort(buffer[offset..]) catch return error.FileReadFailed;
        if (read == 0) break;
        offset += read;
    }
    if (offset != size) return error.IncompleteRead;
    return buffer;
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
        std.mem.eql(u8, name, "certificate") or
        std.mem.eql(u8, name, "replay");
}

/// Read a deployment artifact's payload out of its bytes.
///
/// Returns null when the file is a plain binary. A payload framed correctly in
/// a format this build cannot read is not null: `readTrailer` says so, and the
/// caller reports it rather than treating the artifact as unproven.
fn payloadFromBinary(allocator: std.mem.Allocator, bytes: []const u8) ?self_extract.Payload {
    if (bytes.len < self_extract.TRAILER_SIZE) return null;
    const trailer_start = bytes.len - self_extract.TRAILER_SIZE;
    const trailer = self_extract.readTrailer(
        @intCast(bytes.len),
        bytes[trailer_start..][0..self_extract.TRAILER_SIZE],
    ) catch return null;

    const start: usize = @intCast(trailer.payload_offset);
    const size: usize = @intCast(trailer.payload_size);
    if (start + size > bytes.len) return null;
    const payload_bytes = bytes[start..][0..size];
    if (std.hash.crc.Crc32.hash(payload_bytes) != trailer.checksum) return null;
    return (self_extract.parse(allocator, payload_bytes) catch return null) orelse null;
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
        "{{\n  \"toolVersion\": \"" ++ tool_version ++ "\",\n  \"components\": {{\n    \"contract\": {{ \"path\": \"../secret\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{secret_sha},
    );
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.SuspiciousPath, verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "OK") == null);
    try std.testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "../secret") != null);
}

test "a bundle from the previous format is refused with a rebuild diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureDir(std.testing.allocator, "bundle");
    try zts.file_io.writeFile(std.testing.allocator, "bundle/handler.contract.json", "{}");
    const contract_sha = sha256Hex("{}");
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\n  \"toolVersion\": \"zttp-bundle-1\",\n  \"components\": {{\n    \"contract\": {{ \"path\": \"handler.contract.json\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{contract_sha},
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(
        error.UnsupportedBundleVersion,
        verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer),
    );
    // The diagnostic names both formats and says what to do about it.
    const text = err.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "zttp-bundle-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tool_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Rebuild") != null);
}

test "a manifest with no toolVersion is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try ensureDir(std.testing.allocator, "bundle");
    try zts.file_io.writeFile(
        std.testing.allocator,
        "bundle/bundle.json",
        "{\n  \"components\": {}\n}\n",
    );

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(
        error.InvalidManifest,
        verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer),
    );
}

test "a hash-only bundle establishes integrity, and says so when proof was required" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try test_chdir(&tmp);
    defer std.testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try zts.file_io.writeFile(std.testing.allocator, "handler.contract.json", "{\"version\":18}");

    var write_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer write_out.deinit();
    var write_err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer write_err.deinit();
    try writeBundle(std.testing.allocator, .{
        .contract_path = "handler.contract.json",
        .out_dir = "bundle",
    }, &write_out.writer, &write_err.writer);

    // Without a demand for proof, integrity alone is a success.
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer);
    const text = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "Integrity: verified") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Proof:     not checked") != null);

    // With one, the same bundle is not enough, and the exit says so.
    var strict_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer strict_out.deinit();
    var strict_err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer strict_err.deinit();
    try std.testing.expectError(
        error.NoProofToCheck,
        verify(std.testing.allocator, "bundle", true, &strict_out.writer, &strict_err.writer),
    );
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
        "{{\n  \"toolVersion\": \"" ++ tool_version ++ "\",\n  \"components\": {{\n    \"contract\": {{ \"path\": \"{s}\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{ abs_secret, secret_sha },
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.SuspiciousPath, verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer));
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
        "{{\n  \"toolVersion\": \"" ++ tool_version ++ "\",\n  \"components\": {{\n    \"contract\": {{ \"path\": \"handler.contract.json\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{secret_sha},
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.SuspiciousPath, verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer));
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
        "{{\n  \"toolVersion\": \"" ++ tool_version ++ "\",\n  \"components\": {{\n    \"contract\": {{ \"path\": \"handler.contract.json\", \"sha256\": \"{s}\" }},\n    \"replay\": {{ \"path\": \"replay/trace.jsonl\", \"sha256\": \"{s}\" }}\n  }}\n}}\n",
        .{ contract_sha, secret_sha },
    );
    defer std.testing.allocator.free(manifest);
    try zts.file_io.writeFile(std.testing.allocator, "bundle/bundle.json", manifest);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try std.testing.expectError(error.SuspiciousPath, verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer));
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
    try std.testing.expectError(error.InvalidManifest, verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer));
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
    try std.testing.expectError(error.InvalidManifest, verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer));
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
    try std.testing.expectError(error.InvalidManifest, verify(std.testing.allocator, "bundle", false, &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "Integrity: verified") == null);
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
    try verify(std.testing.allocator, "bundle", false, &verify_out.writer, &verify_err.writer);
    const text = verify_out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Integrity: verified") != null);
    // Integrity is reported on its own line, and the absence of anything to
    // check semantically is reported on another. A caller reading one word
    // cannot mistake the first state for the second.
    try std.testing.expect(std.mem.indexOf(u8, text, "Proof:     not checked") != null);
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
    try verify(std.testing.allocator, "bundle", false, &verify_out.writer, &verify_err.writer);
    try std.testing.expect(std.mem.indexOf(u8, verify_out.writer.buffered(), "Integrity: verified") != null);
}
