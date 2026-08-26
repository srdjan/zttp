//! `zts-training-export` - emit the sealed ZTS training contract bundle.
//!
//! A training pipeline that learns ZTS from this compiler must learn it from a
//! named, hashed artifact rather than from the working tree. This command emits
//! that artifact: every rule, feature, restriction, module export, and published
//! example the compiler advertises, plus the identity hashes that say exactly
//! which compiler said them.
//!
//! Held-out evaluation material is excluded by construction, not by filtering.
//! Every section below is rendered from a registry compiled into this binary.
//! The exporter never opens the recorded corpora under `packages/pi/`, so there
//! is no filter here that could fail open and leak an evaluation case into
//! training data.
//!
//! Provenance is supplied by the caller rather than read from git. The analyzer
//! spawns no processes (see `scripts/check-runtime-purity.sh`), and a renderer
//! that reads no ambient state is a renderer whose output a test can predict.
//! `scripts/zts-training-export.sh` is the caller that runs git.

const std = @import("std");
const zts = @import("zts");
const precompile = @import("precompile.zig");
const json_diag = precompile.json_diag;
const describe_rule = @import("describe_rule.zig");
const example_registry = @import("example_registry.zig");
const expert_meta = @import("expert_meta.zig");

const policy_catalog = zts.PolicyCatalog;
const moduleMetadata = zts.ModuleMetadata;
const file_io = zts.file_io;

/// Consumers bind this string. A change to the shape of `manifest.json`, to the
/// set of emitted files, or to the bundle-id derivation is a new version, and a
/// consumer that does not recognize the version must refuse the bundle rather
/// than read the fields it happens to know.
pub const schema = "zttp.zts-training-export/v1";

/// Which generation of verifier soundness produced the labels in this bundle.
///
/// Bump this when a soundness fix changes what the compiler considers proven,
/// because every label recorded before that fix is then a claim the current
/// compiler would not make. A trainer that mixes epochs trains on two different
/// definitions of correct. This is deliberately separate from `policy_version`:
/// a rule can be added, worded, or re-coded without invalidating a single past
/// verdict, and that is a policy change and not an epoch change.
pub const soundness_epoch = "2026.08.1";

/// Floors on the exporter's own input, asserted before any count it publishes
/// means anything. A registry that failed to link, or a section whose renderer
/// silently produced nothing, would otherwise ship as a valid bundle describing
/// a language with no rules. Measured on 2026-08-26: 72 rules, 21 syntax
/// examples, 3 module examples. Raising a floor after adding entries is
/// expected; lowering one needs a reason in the commit.
const min_rule_count = 72;
const min_syntax_example_count = 21;
const min_module_example_count = 3;

pub const ExportError = error{
    RuleFloorUnmet,
    SyntaxExampleFloorUnmet,
    ModuleExampleFloorUnmet,
    EmptySection,
    DirtyWorktree,
    InvalidCommit,
    MissingOutputDirectory,
};

/// Where the bundle came from. Both fields are required: a bundle that cannot
/// name its commit cannot be reproduced, and one exported from a dirty tree
/// describes source that exists on exactly one machine.
pub const Provenance = struct {
    commit: []const u8,
    worktree_clean: bool,
};

pub const File = struct {
    /// Static literal, relative to the bundle root. Never freed.
    path: []const u8,
    /// Owned by the bundle.
    contents: []const u8,
    digest: [64]u8,
};

pub const Bundle = struct {
    /// Content files, ascending by path. `manifest.json` is not among them: a
    /// file cannot carry its own digest.
    files: []File,
    /// Owned. The `manifest.json` body.
    manifest: []const u8,
    bundle_id: [64]u8,

    pub fn deinit(self: *Bundle, allocator: std.mem.Allocator) void {
        for (self.files) |f| allocator.free(f.contents);
        allocator.free(self.files);
        allocator.free(self.manifest);
        self.files = &.{};
        self.manifest = &.{};
    }

    pub fn find(self: *const Bundle, path: []const u8) ?*const File {
        for (self.files) |*f| {
            if (std.mem.eql(u8, f.path, path)) return f;
        }
        return null;
    }
};

const manifest_path = "manifest.json";

/// Emitted in this order, which is also ascending path order. A test asserts
/// the sortedness the bundle id depends on rather than trusting this list.
const sections = [_]struct {
    path: []const u8,
    render: *const fn (std.mem.Allocator) anyerror![]u8,
}{
    .{ .path = "examples.json", .render = renderExamples },
    .{ .path = "features.json", .render = renderFeatures },
    .{ .path = "modules.json", .render = renderModules },
    .{ .path = "restrictions.json", .render = renderRestrictions },
    .{ .path = "rules.json", .render = renderRules },
    .{ .path = "semantics.ts", .render = renderSemantics },
};

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Build the whole bundle in memory. Pure with respect to the filesystem and
/// the clock, so a test can compare two renders byte for byte.
pub fn renderBundle(allocator: std.mem.Allocator, provenance: Provenance) !Bundle {
    if (!provenance.worktree_clean) return ExportError.DirtyWorktree;
    try validateCommit(provenance.commit);

    const rules = policy_catalog.rules();
    if (rules.len < min_rule_count) return ExportError.RuleFloorUnmet;
    if (example_registry.examples.len < min_syntax_example_count) {
        return ExportError.SyntaxExampleFloorUnmet;
    }
    if (example_registry.module_examples.len < min_module_example_count) {
        return ExportError.ModuleExampleFloorUnmet;
    }

    var files = try allocator.alloc(File, sections.len);
    var built: usize = 0;
    errdefer {
        for (files[0..built]) |f| allocator.free(f.contents);
        allocator.free(files);
    }

    for (sections, 0..) |section, i| {
        const contents = try section.render(allocator);
        // A renderer that produced nothing is a broken renderer, not an empty
        // section: every registry this command reads has a non-zero floor.
        if (contents.len == 0) {
            allocator.free(contents);
            return ExportError.EmptySection;
        }
        files[i] = .{
            .path = section.path,
            .contents = contents,
            .digest = sha256Hex(contents),
        };
        built = i + 1;
    }

    const bundle_id = computeBundleId(files);
    const manifest = try renderManifest(allocator, files, bundle_id, provenance);

    return .{ .files = files, .manifest = manifest, .bundle_id = bundle_id };
}

fn renderRules(allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    const rules = policy_catalog.rules();
    const counts = expert_meta.category_counts;
    try aw.writer.print(
        "{{\"count\":{d},\"categories\":{{\"verifier\":{d},\"policy\":{d},\"property\":{d}}},\"rules\":[",
        .{ rules.len, counts.verifier, counts.policy, counts.property },
    );
    for (rules, 0..) |*entry, i| {
        if (i != 0) try aw.writer.writeAll(",");
        try describe_rule.writeRuleJson(&aw.writer, entry);
    }
    try aw.writer.writeAll("]}\n");

    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

fn renderFeatures(allocator: std.mem.Allocator) anyerror![]u8 {
    return renderThrough(allocator, json_diag.writeFeaturesJson);
}

fn renderRestrictions(allocator: std.mem.Allocator) anyerror![]u8 {
    return renderThrough(allocator, json_diag.writeRestrictionsJson);
}

fn renderModules(allocator: std.mem.Allocator) anyerror![]u8 {
    return renderThrough(allocator, json_diag.writeModulesJson);
}

/// Shared shape for the three sections the analyzer already publishes as JSON.
/// The export re-uses those writers rather than a second renderer, so a bundle
/// and `zts features --json` can never disagree.
fn renderThrough(
    allocator: std.mem.Allocator,
    comptime write: fn (anytype) anyerror!void,
) anyerror![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    try write(&aw.writer);
    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

fn renderSemantics(allocator: std.mem.Allocator) anyerror![]u8 {
    return zts.renderSpecTs(allocator);
}

fn renderExamples(allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    try aw.writer.print(
        "{{\"catalog_hash\":\"{s}\",\"syntax\":[",
        .{example_registry.catalogHash()},
    );
    for (&example_registry.examples, 0..) |entry, i| {
        if (i != 0) try aw.writer.writeAll(",");
        try aw.writer.writeAll("{\"feature\":");
        try writeJsonString(&aw.writer, entry.feature);
        try aw.writer.writeAll(",\"source\":");
        try writeJsonString(&aw.writer, entry.source);
        try aw.writer.writeAll("}");
    }
    try aw.writer.writeAll("],\"modules\":[");
    for (&example_registry.module_examples, 0..) |entry, i| {
        if (i != 0) try aw.writer.writeAll(",");
        try aw.writer.writeAll("{\"name\":");
        try writeJsonString(&aw.writer, entry.name);
        try aw.writer.writeAll(",\"purpose\":");
        try writeJsonString(&aw.writer, entry.purpose);
        try aw.writer.writeAll(",\"modules\":[");
        for (entry.modules, 0..) |specifier, j| {
            if (j != 0) try aw.writer.writeAll(",");
            try writeJsonString(&aw.writer, specifier);
        }
        try aw.writer.writeAll("],\"source\":");
        try writeJsonString(&aw.writer, entry.source);
        try aw.writer.writeAll("}");
    }
    try aw.writer.writeAll("]}\n");

    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

fn renderManifest(
    allocator: std.mem.Allocator,
    files: []const File,
    bundle_id: [64]u8,
    provenance: Provenance,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &aw.writer;

    const counts = expert_meta.category_counts;

    try w.print("{{\n  \"schema\": \"{s}\",\n", .{schema});
    try w.print("  \"bundle_id\": \"{s}\",\n", .{bundle_id});
    try w.print("  \"compiler_version\": \"{s}\",\n", .{expert_meta.compiler_version});
    try w.print("  \"policy_version\": \"{s}\",\n", .{expert_meta.policy_version});
    try w.print("  \"soundness_epoch\": \"{s}\",\n", .{soundness_epoch});

    try w.writeAll("  \"identity\": {\n");
    try w.print("    \"policy_hash\": \"{s}\",\n", .{zts.policyHash()});
    try w.print("    \"diagnostic_catalog_hash\": \"{s}\",\n", .{zts.diagnosticCatalogHash()});
    try w.print("    \"grammar_hash\": \"{s}\",\n", .{zts.grammarHash()});
    try w.print("    \"tsx_frontend_grammar_hash\": \"{s}\",\n", .{zts.tsxFrontendGrammarHash()});
    try w.print("    \"semantics_hash\": \"{s}\",\n", .{zts.semanticsHash()});
    try w.print("    \"idiom_table_hash\": \"{s}\",\n", .{zts.idiomTableHash()});
    try w.print("    \"module_registry_hash\": \"{s}\",\n", .{moduleMetadata.builtinRegistryHash()});
    try w.print("    \"example_catalog_hash\": \"{s}\"\n", .{example_registry.catalogHash()});
    try w.writeAll("  },\n");

    try w.writeAll("  \"counts\": {\n");
    try w.print("    \"rules\": {d},\n", .{policy_catalog.rules().len});
    try w.print("    \"verifier\": {d},\n", .{counts.verifier});
    try w.print("    \"policy\": {d},\n", .{counts.policy});
    try w.print("    \"property\": {d},\n", .{counts.property});
    try w.print("    \"syntax_examples\": {d},\n", .{example_registry.examples.len});
    try w.print("    \"module_examples\": {d}\n", .{example_registry.module_examples.len});
    try w.writeAll("  },\n");

    // Recorded, not hashed into `bundle_id`. The id answers "which compiler
    // authority is this", and two clean checkouts of the same commit on two
    // machines must answer it identically.
    try w.writeAll("  \"provenance\": {\n");
    try w.print("    \"commit\": \"{s}\",\n", .{provenance.commit});
    try w.writeAll("    \"worktree\": \"clean\"\n");
    try w.writeAll("  },\n");

    try w.writeAll("  \"files\": [\n");
    for (files, 0..) |f, i| {
        try w.print("    {{ \"path\": \"{s}\", \"sha256\": \"{s}\" }}", .{ f.path, f.digest });
        try w.writeAll(if (i + 1 == files.len) "\n" else ",\n");
    }
    try w.writeAll("  ]\n}\n");

    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Identity of the compiler authority in this bundle. Every field is labelled
/// before it is absorbed, so two different fields cannot produce one stream:
/// a rule count of 72 and an example count of 72 are distinguishable inputs.
fn computeBundleId(files: []const File) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    absorb(&hasher, "schema", schema);
    absorb(&hasher, "compiler-version", expert_meta.compiler_version);
    absorb(&hasher, "policy-version", expert_meta.policy_version);
    absorb(&hasher, "soundness-epoch", soundness_epoch);
    absorb(&hasher, "policy-hash", &zts.policyHash());
    absorb(&hasher, "diagnostic-catalog-hash", &zts.diagnosticCatalogHash());
    absorb(&hasher, "grammar-hash", &zts.grammarHash());
    absorb(&hasher, "tsx-frontend-grammar-hash", &zts.tsxFrontendGrammarHash());
    absorb(&hasher, "semantics-hash", &zts.semanticsHash());
    absorb(&hasher, "idiom-table-hash", &zts.idiomTableHash());
    absorb(&hasher, "module-registry-hash", &moduleMetadata.builtinRegistryHash());
    absorb(&hasher, "example-catalog-hash", &example_registry.catalogHash());
    absorbUsize(&hasher, "file-count", files.len);
    for (files) |f| {
        absorb(&hasher, "file-path", f.path);
        absorb(&hasher, "file-digest", &f.digest);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn absorb(hasher: *std.crypto.hash.sha2.Sha256, label: []const u8, value: []const u8) void {
    hasher.update(label);
    hasher.update("\x00");
    hasher.update(value);
    hasher.update("\x00");
}

fn absorbUsize(hasher: *std.crypto.hash.sha2.Sha256, label: []const u8, value: usize) void {
    var scratch: [20]u8 = undefined;
    const rendered = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch unreachable;
    absorb(hasher, label, rendered);
}

/// An abbreviated or uppercase commit is refused rather than normalized. The
/// manifest is quoted into JSON without escaping, and a validated hex string is
/// what makes that safe as well as reproducible.
fn validateCommit(commit: []const u8) !void {
    if (commit.len < 7 or commit.len > 64) return ExportError.InvalidCommit;
    for (commit) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return ExportError.InvalidCommit;
    }
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeAll("\"");
}

// ---------------------------------------------------------------------------
// Command
// ---------------------------------------------------------------------------

fn isHelpToken(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help");
}

/// Create `path` and every missing parent, one segment at a time. `std.fs.cwd()`
/// is unavailable in this build, so this follows the POSIX `mkdir` idiom the
/// runtime already uses (`capsule.mkdirIfAbsent`), which lives in a package
/// tools cannot import. `.EXIST` is success.
fn makePath(allocator: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0) return ExportError.MissingOutputDirectory;

    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/' and i + 1 != path.len) continue;
        const end = if (path[i] == '/') i else i + 1;
        // A leading '/' or a repeated separator yields an empty segment.
        if (end == 0) continue;
        try mkdirIfAbsent(allocator, path[0..end]);
    }
}

fn mkdirIfAbsent(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    switch (std.posix.errno(std.posix.system.mkdir(path_z, 0o755))) {
        .SUCCESS, .EXIST => {},
        else => return error.MakeDirFailed,
    }
}

fn writeOut(s: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, s.ptr, s.len);
}

fn fail(message: []const u8) noreturn {
    _ = std.c.write(std.c.STDERR_FILENO, message.ptr, message.len);
    std.process.exit(2);
}

const usage_text =
    \\zts-training-export - emit the sealed ZTS training contract bundle
    \\
    \\Usage: zts zts-training-export --out <dir> --commit <sha> --worktree clean|dirty [--json]
    \\
    \\Options:
    \\  --out <dir>            Bundle output directory. Created if absent.
    \\  --commit <sha>         Lowercase hex commit the export describes.
    \\  --worktree clean|dirty State of the tree at that commit. `dirty` is refused.
    \\  --json                 Emit the result line as JSON.
    \\
    \\Both --commit and --worktree are required: this command reads no git state
    \\of its own, so a bundle that cannot name its source is refused rather than
    \\emitted with the field left blank. scripts/zts-training-export.sh supplies
    \\them.
    \\
;

pub fn runTrainingExportCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var out_dir: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var worktree: ?[]const u8 = null;
    var json_mode = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            out_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--commit")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            commit = argv[i];
        } else if (std.mem.eql(u8, arg, "--worktree")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            worktree = argv[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (isHelpToken(arg)) {
            writeOut(usage_text);
            return;
        } else {
            return error.InvalidArgument;
        }
    }

    const dir = out_dir orelse return ExportError.MissingOutputDirectory;
    const sha = commit orelse return ExportError.InvalidCommit;
    const state = worktree orelse return ExportError.DirtyWorktree;

    const clean = if (std.mem.eql(u8, state, "clean"))
        true
    else if (std.mem.eql(u8, state, "dirty"))
        false
    else
        return error.InvalidArgument;

    // Every refusal below is a condition an operator can act on, so it exits
    // with a sentence rather than a stack trace. A dirty tree is the common
    // one and the message has to say what to do about it.
    var bundle = renderBundle(allocator, .{ .commit = sha, .worktree_clean = clean }) catch |err| switch (err) {
        ExportError.DirtyWorktree => fail(
            \\zts-training-export: refusing to export from a dirty worktree.
            \\A bundle names one commit. Commit or stash the changes, then retry.
            \\
        ),
        ExportError.InvalidCommit => fail(
            \\zts-training-export: --commit must be 7 to 64 lowercase hex characters.
            \\
        ),
        ExportError.RuleFloorUnmet,
        ExportError.SyntaxExampleFloorUnmet,
        ExportError.ModuleExampleFloorUnmet,
        => fail(
            \\zts-training-export: a compiled-in registry is below its floor.
            \\This binary would describe a language with fewer rules or examples
            \\than the export asserts. See the floors in training_export.zig.
            \\
        ),
        ExportError.EmptySection => fail(
            \\zts-training-export: a section renderer produced no bytes.
            \\
        ),
        else => return err,
    };
    defer bundle.deinit(allocator);

    try makePath(allocator, dir);

    for (bundle.files) |f| {
        const path = try std.fs.path.join(allocator, &.{ dir, f.path });
        defer allocator.free(path);
        try file_io.writeFile(allocator, path, f.contents);
    }
    // Written last. A reader that finds a manifest can rely on every file it
    // names already being on disk with the digest it claims.
    const manifest_full = try std.fs.path.join(allocator, &.{ dir, manifest_path });
    defer allocator.free(manifest_full);
    try file_io.writeFile(allocator, manifest_full, bundle.manifest);

    const line = if (json_mode)
        try std.fmt.allocPrint(
            allocator,
            "{{\"bundleId\":\"{s}\",\"out\":\"{s}\",\"files\":{d}}}\n",
            .{ bundle.bundle_id, dir, bundle.files.len + 1 },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "zts-training-export: {d} files -> {s}\n  bundle {s}\n",
            .{ bundle.files.len + 1, dir, bundle.bundle_id },
        );
    defer allocator.free(line);
    writeOut(line);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_provenance: Provenance = .{
    .commit = "5a994c33aa11bb22cc33dd44ee55ff6677889900",
    .worktree_clean = true,
};

test "renderBundle emits every declared section with a matching digest" {
    const allocator = std.testing.allocator;
    var bundle = try renderBundle(allocator, test_provenance);
    defer bundle.deinit(allocator);

    try std.testing.expectEqual(sections.len, bundle.files.len);
    for (bundle.files) |f| {
        try std.testing.expect(f.contents.len > 0);
        try std.testing.expectEqualStrings(&sha256Hex(f.contents), &f.digest);
    }
    try std.testing.expect(bundle.find("rules.json") != null);
    try std.testing.expect(bundle.find("semantics.ts") != null);
    try std.testing.expect(bundle.find("manifest.json") == null);
}

test "renderBundle is deterministic across runs" {
    const allocator = std.testing.allocator;

    var first = try renderBundle(allocator, test_provenance);
    defer first.deinit(allocator);
    var second = try renderBundle(allocator, test_provenance);
    defer second.deinit(allocator);

    try std.testing.expectEqualStrings(&first.bundle_id, &second.bundle_id);
    try std.testing.expectEqualStrings(first.manifest, second.manifest);
    try std.testing.expectEqual(first.files.len, second.files.len);
    for (first.files, second.files) |a, b| {
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqualStrings(a.contents, b.contents);
    }
}

test "file list is sorted, so the bundle id does not depend on emission order" {
    var previous: []const u8 = "";
    for (sections) |section| {
        try std.testing.expect(std.mem.order(u8, previous, section.path) == .lt);
        previous = section.path;
    }
}

test "bundle id changes when a file digest changes" {
    const allocator = std.testing.allocator;
    var bundle = try renderBundle(allocator, test_provenance);
    defer bundle.deinit(allocator);

    const baseline = computeBundleId(bundle.files);
    try std.testing.expectEqualStrings(&bundle.bundle_id, &baseline);

    var tampered = try allocator.alloc(File, bundle.files.len);
    defer allocator.free(tampered);
    @memcpy(tampered, bundle.files);
    tampered[0].digest[0] = if (tampered[0].digest[0] == 'a') 'b' else 'a';

    const changed = computeBundleId(tampered);
    try std.testing.expect(!std.mem.eql(u8, &baseline, &changed));
}

test "bundle id ignores provenance so two clean checkouts agree" {
    const allocator = std.testing.allocator;

    var mine = try renderBundle(allocator, test_provenance);
    defer mine.deinit(allocator);
    var theirs = try renderBundle(allocator, .{
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .worktree_clean = true,
    });
    defer theirs.deinit(allocator);

    try std.testing.expectEqualStrings(&mine.bundle_id, &theirs.bundle_id);
    // The manifests still differ: the commit is recorded even though it is not
    // part of the identity.
    try std.testing.expect(!std.mem.eql(u8, mine.manifest, theirs.manifest));
}

test "a dirty worktree is refused" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(ExportError.DirtyWorktree, renderBundle(allocator, .{
        .commit = test_provenance.commit,
        .worktree_clean = false,
    }));
}

test "a commit that is not lowercase hex is refused" {
    const allocator = std.testing.allocator;
    const rejected = [_][]const u8{
        "",
        "abc123",
        "5A994C33AA11BB22CC33DD44EE55FF6677889900",
        "5a994c33aa11bb22cc33dd44ee55ff667788990z",
        "not-a-commit-at-all",
    };
    for (rejected) |commit| {
        try std.testing.expectError(ExportError.InvalidCommit, renderBundle(allocator, .{
            .commit = commit,
            .worktree_clean = true,
        }));
    }
    try validateCommit("5a994c3");
    try validateCommit(test_provenance.commit);
}

test "the registry floors this export asserts still hold" {
    // These are the floors renderBundle checks. Asserting them here too means a
    // registry that shrinks fails a named test rather than only failing an
    // export nobody ran this week.
    try std.testing.expect(policy_catalog.rules().len >= min_rule_count);
    try std.testing.expect(example_registry.examples.len >= min_syntax_example_count);
    try std.testing.expect(example_registry.module_examples.len >= min_module_example_count);
}

test "manifest names the schema, the epoch, and every emitted file" {
    const allocator = std.testing.allocator;
    var bundle = try renderBundle(allocator, test_provenance);
    defer bundle.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, bundle.manifest, schema) != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.manifest, soundness_epoch) != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.manifest, &bundle.bundle_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.manifest, test_provenance.commit) != null);
    for (bundle.files) |f| {
        try std.testing.expect(std.mem.indexOf(u8, bundle.manifest, f.path) != null);
        try std.testing.expect(std.mem.indexOf(u8, bundle.manifest, &f.digest) != null);
    }
}

test "manifest parses as JSON and reports the measured rule count" {
    const allocator = std.testing.allocator;
    var bundle = try renderBundle(allocator, test_provenance);
    defer bundle.deinit(allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bundle.manifest, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings(schema, root.get("schema").?.string);
    const counts = root.get("counts").?.object;
    try std.testing.expectEqual(
        @as(i64, @intCast(policy_catalog.rules().len)),
        counts.get("rules").?.integer,
    );
    try std.testing.expectEqualStrings(
        "clean",
        root.get("provenance").?.object.get("worktree").?.string,
    );
    try std.testing.expectEqual(
        @as(usize, sections.len),
        root.get("files").?.array.items.len,
    );
}

test "rules section carries every advertised rule" {
    const allocator = std.testing.allocator;
    const rendered = try renderRules(allocator);
    defer allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const rules = root.get("rules").?.array;
    try std.testing.expectEqual(policy_catalog.rules().len, rules.items.len);
    try std.testing.expectEqual(
        @as(i64, @intCast(policy_catalog.rules().len)),
        root.get("count").?.integer,
    );
}

test "examples section carries both catalogs and its own catalog hash" {
    const allocator = std.testing.allocator;
    const rendered = try renderExamples(allocator);
    defer allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(
        example_registry.examples.len,
        root.get("syntax").?.array.items.len,
    );
    try std.testing.expectEqual(
        example_registry.module_examples.len,
        root.get("modules").?.array.items.len,
    );
    try std.testing.expectEqualStrings(
        &example_registry.catalogHash(),
        root.get("catalog_hash").?.string,
    );
}

test "writeJsonString escapes what would otherwise break the manifest" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    try writeJsonString(&aw.writer, "a\"b\\c\nd\te\x01");
    buf = aw.toArrayList();
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001\"", buf.items);
}
