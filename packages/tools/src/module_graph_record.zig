//! The resolved module environment for one entry file, and its digest.
//!
//! Spec 4.8's `modules` operation returns the resolved relative graph with
//! source digests, the built-in registry, every resolution decision and rejected
//! candidate, and one digest over the whole environment. D3 §3 fixes that
//! digest's pre-image.
//!
//! This walker reuses `resolver.resolve` and `file_resolver.resolve`, the same
//! calls the runtime's `ModuleGraph` makes, so the two cannot disagree about
//! where a specifier points. It exists separately because `ModuleGraph`
//! (`packages/zts/src/modules/internal/module_graph.zig:150-215`) discards the
//! specifier text once it has a path, skips virtual and unknown specifiers
//! entirely, keeps no digests, and records no rejected candidate. All four are
//! protocol requirements and none is an execution concern.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const moduleMetadata = zts.ModuleMetadata;

const resolver = zts.modules.resolver;
const file_resolver = zts.modules.file_resolver;
const parser = zts.parser;

/// Largest source file the walker will read. Matches `canonicalize.collect`.
/// Published in `meta.payload.limits`.
pub const max_source_bytes: usize = 10 * 1024 * 1024;

/// Guards a pathological import graph. The runtime graph caps nesting depth at
/// 32; this caps total modules, since the walker is breadth-first and a wide
/// graph is as expensive as a deep one. Published in `meta.payload.limits`.
pub const max_modules: usize = 1024;

pub const ImportKind = enum {
    /// A `zttp:*` module served by a built-in binding.
    builtin,
    /// A `zttp-ext:*` module served by an extension manifest.
    extension,
    /// A relative or absolute source file inside the project root.
    relative,
    /// A specifier that resolves to nothing this compiler knows.
    unresolved,
};

pub const ImportRecord = struct {
    /// The specifier exactly as written in source.
    specifier: []const u8,
    kind: ImportKind,
    /// The built-in specifier, the canonical root-relative path, or "" when the
    /// specifier resolved to nothing.
    target: []const u8,
};

pub const ModuleRecord = struct {
    /// Canonical root-relative path, `/` separated.
    path: []const u8,
    source_digest: [64]u8,
    /// Imports in source order.
    imports: []ImportRecord,
};

pub const Rejection = struct {
    specifier: []const u8,
    /// Canonical root-relative path of the module that wrote the import.
    importer: []const u8,
    /// One of the closed reasons below. Static string.
    reason: []const u8,
};

pub const rejection_path_outside_root = "path_outside_project_root";
pub const rejection_file_unreadable = "file_unreadable";
pub const rejection_unknown_specifier = "unknown_specifier";
pub const rejection_extension_unavailable = "extension_manifest_unavailable";
/// The parser failed on the module, so its import list may be partial or empty.
/// Recorded with an empty specifier and the module as the importer.
pub const rejection_parse_failed = "parse_failed";

pub const BuildError = error{
    /// The entry file could not be read. Distinct from an unreadable import,
    /// which is a rejection inside an otherwise valid graph.
    EntryUnreadable,
    GraphTooLarge,
    UnsupportedSourceExtension,
} || zts.SourceObservationError || std.mem.Allocator.Error || agent_identity.PathError;

pub const GraphRecord = struct {
    /// Ascending canonical-path order, never traversal order, so the digest
    /// does not depend on which file was the entry.
    modules: []ModuleRecord,
    rejected: []Rejection,
    builtin_registry_hash: [64]u8,
    hash: [64]u8,

    pub fn deinit(self: *GraphRecord, allocator: std.mem.Allocator) void {
        for (self.modules) |m| {
            allocator.free(m.path);
            for (m.imports) |imp| {
                allocator.free(imp.specifier);
                allocator.free(imp.target);
            }
            allocator.free(m.imports);
        }
        allocator.free(self.modules);
        for (self.rejected) |r| {
            allocator.free(r.specifier);
            allocator.free(r.importer);
        }
        allocator.free(self.rejected);
        self.* = undefined;
    }
};

/// Existence probe for `file_resolver`, whose callback type carries no context.
/// The runtime graph passes null here. This probe confirms each resolved path
/// before the graph records and digests the target.
fn probeExists(path: []const u8) bool {
    return zts.file_io.fileExists(std.heap.smp_allocator, path);
}

/// Build the resolved graph reachable from `entry_rel`, a path already inside
/// `canonical_root`.
pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    canonical_root: []const u8,
    entry_rel: []const u8,
) BuildError!GraphRecord {
    return buildInternal(allocator, io, canonical_root, entry_rel, null);
}

/// Build the resolved graph as if `entry_source` were the entry module's bytes,
/// without writing them to disk. Imported modules still come from the project.
/// This lets a writer derive and validate the post-edit identity before the
/// mutation it will bind to that identity.
pub fn buildWithEntrySource(
    allocator: std.mem.Allocator,
    io: std.Io,
    canonical_root: []const u8,
    entry_rel: []const u8,
    entry_source: []const u8,
) BuildError!GraphRecord {
    return buildInternal(allocator, io, canonical_root, entry_rel, entry_source);
}

fn buildInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    canonical_root: []const u8,
    entry_rel: []const u8,
    entry_source: ?[]const u8,
) BuildError!GraphRecord {
    var modules: std.ArrayList(ModuleRecord) = .empty;
    errdefer {
        for (modules.items) |m| {
            allocator.free(m.path);
            for (m.imports) |imp| {
                allocator.free(imp.specifier);
                allocator.free(imp.target);
            }
            allocator.free(m.imports);
        }
        modules.deinit(allocator);
    }

    var rejected: std.ArrayList(Rejection) = .empty;
    errdefer {
        for (rejected.items) |r| {
            allocator.free(r.specifier);
            allocator.free(r.importer);
        }
        rejected.deinit(allocator);
    }

    // Canonical relative paths already queued or visited. Keys are borrowed
    // from `queue`, which owns them until they move into a ModuleRecord.
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();

    var queue: std.ArrayList([]const u8) = .empty;
    defer {
        for (queue.items) |p| allocator.free(p);
        queue.deinit(allocator);
    }

    const entry_owned = try agent_identity.canonicalRelPath(allocator, io, canonical_root, entry_rel);
    try queue.append(allocator, entry_owned);
    try seen.put(entry_owned, {});

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const rel = queue.items[head];
        if (modules.items.len >= max_modules) return error.GraphTooLarge;

        const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, rel });
        defer allocator.free(abs);

        const source = if (head == 0 and entry_source != null)
            try allocator.dupe(u8, entry_source.?)
        else
            zts.file_io.readFile(allocator, abs, max_source_bytes) catch {
                // The entry file must exist; a missing import is a rejection the
                // importer already recorded, so this module is simply dropped.
                if (head == 0) return error.EntryUnreadable;
                continue;
            };
        defer allocator.free(source);

        var imports: std.ArrayList(ImportRecord) = .empty;
        errdefer {
            for (imports.items) |imp| {
                allocator.free(imp.specifier);
                allocator.free(imp.target);
            }
            imports.deinit(allocator);
        }

        try collectImports(allocator, io, canonical_root, rel, abs, source, &imports, &rejected, &queue, &seen);

        try modules.append(allocator, .{
            .path = try allocator.dupe(u8, rel),
            .source_digest = agent_identity.sourceDigest(source),
            .imports = try imports.toOwnedSlice(allocator),
        });
    }

    const module_slice = try modules.toOwnedSlice(allocator);
    std.mem.sort(ModuleRecord, module_slice, {}, lessModule);
    const rejected_slice = try rejected.toOwnedSlice(allocator);
    std.mem.sort(Rejection, rejected_slice, {}, lessRejection);

    const builtin_hash = moduleMetadata.builtinRegistryHash();
    return .{
        .modules = module_slice,
        .rejected = rejected_slice,
        .builtin_registry_hash = builtin_hash,
        .hash = computeHash(module_slice, rejected_slice, builtin_hash),
    };
}

fn recordParseFailure(
    allocator: std.mem.Allocator,
    rejected: *std.ArrayList(Rejection),
    importer_rel: []const u8,
) !void {
    const specifier = try allocator.dupe(u8, "");
    errdefer allocator.free(specifier);
    const importer = try allocator.dupe(u8, importer_rel);
    errdefer allocator.free(importer);
    try rejected.append(allocator, .{
        .specifier = specifier,
        .importer = importer,
        .reason = rejection_parse_failed,
    });
}

fn collectImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    canonical_root: []const u8,
    importer_rel: []const u8,
    importer_abs: []const u8,
    source: []const u8,
    imports: *std.ArrayList(ImportRecord),
    rejected: *std.ArrayList(Rejection),
    queue: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    const kind = zts.classifySourcePath(importer_rel);
    if (kind == .unsupported) return error.UnsupportedSourceExtension;
    const typed = if (kind.isTyped()) typed: {
        if (try zts.checkSourceAdmission(allocator, source)) |failure| {
            zts.logAdmissionFailure(source, failure);
            break :typed false;
        }
        break :typed true;
    } else false;
    var js_parser = (if (typed)
        parser.JsParser.initAdmission(allocator, allocator, source, .compile)
    else
        parser.JsParser.init(allocator, source)) catch |err| switch (err) {
        // Init fails only on allocation.
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer js_parser.deinit();
    _ = js_parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try recordParseFailure(allocator, rejected, importer_rel),
    };

    const view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const node_count = js_parser.getRetainedImportNodeCount();
    var idx: usize = 0;
    while (idx < node_count) : (idx += 1) {
        const node: u32 = @intCast(idx);
        const tag = view.getTag(node) orelse continue;
        if (tag != .import_decl) continue;
        const decl = view.getImportDecl(node) orelse continue;
        const specifier = view.getString(decl.module_idx) orelse continue;

        switch (resolver.resolve(specifier)) {
            .virtual => try imports.append(allocator, .{
                .specifier = try allocator.dupe(u8, specifier),
                .kind = .builtin,
                .target = try allocator.dupe(u8, specifier),
            }),
            .unknown => {
                const is_ext = std.mem.startsWith(u8, specifier, "zttp-ext:");
                try rejected.append(allocator, .{
                    .specifier = try allocator.dupe(u8, specifier),
                    .importer = try allocator.dupe(u8, importer_rel),
                    // Phase 1 authenticates no extension manifests, so an
                    // extension specifier is recorded as unavailable rather
                    // than silently treated as resolved.
                    .reason = if (is_ext) rejection_extension_unavailable else rejection_unknown_specifier,
                });
                try imports.append(allocator, .{
                    .specifier = try allocator.dupe(u8, specifier),
                    .kind = if (is_ext) .extension else .unresolved,
                    .target = try allocator.dupe(u8, ""),
                });
            },
            .file => |spec| {
                const importing_dir = file_resolver.dirName(importer_abs);
                const target_abs = file_resolver.resolve(allocator, spec, importing_dir, probeExists) catch {
                    try rejected.append(allocator, .{
                        .specifier = try allocator.dupe(u8, specifier),
                        .importer = try allocator.dupe(u8, importer_rel),
                        .reason = rejection_file_unreadable,
                    });
                    try imports.append(allocator, .{
                        .specifier = try allocator.dupe(u8, specifier),
                        .kind = .relative,
                        .target = try allocator.dupe(u8, ""),
                    });
                    continue;
                };
                defer allocator.free(target_abs);

                const target_rel = agent_identity.canonicalRelPath(allocator, io, canonical_root, target_abs) catch {
                    try rejected.append(allocator, .{
                        .specifier = try allocator.dupe(u8, specifier),
                        .importer = try allocator.dupe(u8, importer_rel),
                        .reason = rejection_path_outside_root,
                    });
                    try imports.append(allocator, .{
                        .specifier = try allocator.dupe(u8, specifier),
                        .kind = .relative,
                        .target = try allocator.dupe(u8, ""),
                    });
                    continue;
                };
                errdefer allocator.free(target_rel);

                try imports.append(allocator, .{
                    .specifier = try allocator.dupe(u8, specifier),
                    .kind = .relative,
                    .target = try allocator.dupe(u8, target_rel),
                });

                if (!zts.file_io.fileExists(allocator, target_abs)) {
                    try rejected.append(allocator, .{
                        .specifier = try allocator.dupe(u8, specifier),
                        .importer = try allocator.dupe(u8, importer_rel),
                        .reason = rejection_file_unreadable,
                    });
                    allocator.free(target_rel);
                    continue;
                }

                if (seen.contains(target_rel)) {
                    allocator.free(target_rel);
                    continue;
                }
                try queue.append(allocator, target_rel);
                try seen.put(target_rel, {});
            },
        }
    }
}

fn lessModule(_: void, a: ModuleRecord, b: ModuleRecord) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn lessRejection(_: void, a: Rejection, b: Rejection) bool {
    return switch (std.mem.order(u8, a.importer, b.importer)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.specifier, b.specifier) == .lt,
    };
}

/// D3 §3: for each module in ascending canonical-path order,
/// `path \0 source_digest \0` then each import in source order as
/// `specifier \0 resolved_kind \0 resolved_target \0`, record-terminated; then
/// the built-in registry hash, terminated. The extension-manifest section
/// appends after the builtin hash once manifests are authenticated, so the
/// terminator is unconditional and an empty section is not the same pre-image
/// as an absent one. Each rejection then appends `importer \0 specifier \0
/// reason \0 \x02` after the modules and before the builtin hash, so an empty
/// rejection list leaves the pre-image unchanged.
fn computeHash(modules: []const ModuleRecord, rejected: []const Rejection, builtin_hash: [64]u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (modules) |m| {
        hasher.update(m.path);
        hasher.update("\x00");
        hasher.update(&m.source_digest);
        hasher.update("\x00");
        for (m.imports) |imp| {
            hasher.update(imp.specifier);
            hasher.update("\x00");
            hasher.update(@tagName(imp.kind));
            hasher.update("\x00");
            hasher.update(imp.target);
            hasher.update("\x00");
        }
        hasher.update("\x01");
    }
    for (rejected) |r| {
        hasher.update(r.importer);
        hasher.update("\x00");
        hasher.update(r.specifier);
        hasher.update("\x00");
        hasher.update(r.reason);
        hasher.update("\x00");
        hasher.update("\x02");
    }
    hasher.update(&builtin_hash);
    hasher.update("\x01");
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

/// The digest of the module environment with no entry file: the built-in
/// registry alone. Operations that take no `file` bind this, so `expected` has
/// something to compare and the envelope field is never empty.
pub fn contextFreeHash() [64]u8 {
    return computeHash(&.{}, &.{}, moduleMetadata.builtinRegistryHash());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tmpRoot(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![]u8 {
    const owned = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", allocator);
    defer allocator.free(owned);
    return allocator.dupe(u8, owned);
}

test "graph records imports in source order with kinds" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "util.ts",
        .data = "export function two() { return 2; }\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data =
        \\import { env } from "zttp:env";
        \\import { two } from "./util.ts";
        \\export function handler(req) { return Response.json({ n: two(), e: env("X") }); }
        \\
    });

    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    var graph = try build(a, std.testing.io, root, "handler.ts");
    defer graph.deinit(a);

    try testing.expectEqual(@as(usize, 2), graph.modules.len);
    // Ascending canonical-path order, not traversal order.
    try testing.expectEqualStrings("handler.ts", graph.modules[0].path);
    try testing.expectEqualStrings("util.ts", graph.modules[1].path);

    const imports = graph.modules[0].imports;
    try testing.expectEqual(@as(usize, 2), imports.len);
    try testing.expectEqualStrings("zttp:env", imports[0].specifier);
    try testing.expectEqual(ImportKind.builtin, imports[0].kind);
    try testing.expectEqualStrings("zttp:env", imports[0].target);
    try testing.expectEqualStrings("./util.ts", imports[1].specifier);
    try testing.expectEqual(ImportKind.relative, imports[1].kind);
    try testing.expectEqualStrings("util.ts", imports[1].target);
    try testing.expectEqual(@as(usize, 0), graph.rejected.len);
}

test "graph hash does not depend on which module was the entry" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A cycle, so both entries reach the same two-module set.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.ts",
        .data = "import { b } from \"./b.ts\";\nexport const a = b;\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "b.ts",
        .data = "import { a } from \"./a.ts\";\nexport const b = 1;\n",
    });

    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    var from_a = try build(a, std.testing.io, root, "a.ts");
    defer from_a.deinit(a);
    var from_b = try build(a, std.testing.io, root, "b.ts");
    defer from_b.deinit(a);

    try testing.expectEqual(@as(usize, 2), from_a.modules.len);
    try testing.expectEqual(@as(usize, 2), from_b.modules.len);
    try testing.expectEqualSlices(u8, &from_a.hash, &from_b.hash);
}

test "graph hash changes when a source byte changes" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "h.ts",
        .data = "export function handler(req) { return Response.json({ n: 1 }); }\n",
    });

    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    var before = try build(a, std.testing.io, root, "h.ts");
    const first = before.hash;
    before.deinit(a);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "h.ts",
        .data = "export function handler(req) { return Response.json({ n: 2 }); }\n",
    });
    var after = try build(a, std.testing.io, root, "h.ts");
    defer after.deinit(a);

    try testing.expect(!std.mem.eql(u8, &first, &after.hash));
}

test "entry source override recomputes the graph without writing" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original =
        "import { one } from \"./one.ts\";\nexport const value = one;\n";
    const proposed =
        "import { two } from \"./two.ts\";\nexport const value = two;\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "h.ts", .data = original });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one.ts", .data = "export const one = 1;\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "two.ts", .data = "export const two = 2;\n" });

    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    var before = try build(a, std.testing.io, root, "h.ts");
    defer before.deinit(a);
    var after = try buildWithEntrySource(a, std.testing.io, root, "h.ts", proposed);
    defer after.deinit(a);

    try testing.expect(!std.mem.eql(u8, &before.hash, &after.hash));
    try testing.expectEqual(@as(usize, 2), after.modules.len);
    try testing.expectEqualStrings("two.ts", after.modules[0].imports[0].target);

    const on_disk = try tmp.dir.readFileAlloc(std.testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(original, on_disk);
}

test "an import escaping the project root is rejected, not resolved" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "outside.ts",
        .data = "export const x = 1;\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app/handler.ts",
        .data = "import { x } from \"../outside.ts\";\nexport const y = x;\n",
    });

    const base = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, "app", a);
    defer a.free(base);

    var graph = try build(a, std.testing.io, base, "handler.ts");
    defer graph.deinit(a);

    try testing.expectEqual(@as(usize, 1), graph.modules.len);
    try testing.expectEqual(@as(usize, 1), graph.rejected.len);
    try testing.expectEqualStrings(rejection_path_outside_root, graph.rejected[0].reason);
    try testing.expectEqualStrings("handler.ts", graph.rejected[0].importer);
    // The import is still recorded, with no target: an agent must see that the
    // module named something the compiler refused.
    try testing.expectEqualStrings("", graph.modules[0].imports[0].target);
}

test "a missing import is a rejection, not a build failure" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "h.ts",
        .data = "import { gone } from \"./gone.ts\";\nexport const x = gone;\n",
    });

    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    var graph = try build(a, std.testing.io, root, "h.ts");
    defer graph.deinit(a);

    try testing.expectEqual(@as(usize, 1), graph.modules.len);
    try testing.expectEqual(@as(usize, 1), graph.rejected.len);
    try testing.expectEqualStrings(rejection_file_unreadable, graph.rejected[0].reason);
}

test "an extension specifier is recorded as unavailable in phase 1" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "h.ts",
        .data = "import { charge } from \"zttp-ext:stripe\";\nexport const x = charge;\n",
    });

    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    var graph = try build(a, std.testing.io, root, "h.ts");
    defer graph.deinit(a);

    try testing.expectEqual(ImportKind.extension, graph.modules[0].imports[0].kind);
    try testing.expectEqual(@as(usize, 1), graph.rejected.len);
    try testing.expectEqualStrings(rejection_extension_unavailable, graph.rejected[0].reason);
}

test "an unreadable entry file fails the build" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    try testing.expectError(
        error.EntryUnreadable,
        build(a, std.testing.io, root, "nope.ts"),
    );
}

test "a JavaScript entry extension is refused" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "handler.js",
        .data = "export function handler(req) { return Response.text('ok'); }\n",
    });
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    try testing.expectError(
        error.UnsupportedSourceExtension,
        build(a, std.testing.io, root, "handler.js"),
    );
}

test "an entry outside the project root is refused before any read" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "app");
    const base = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, "app", a);
    defer a.free(base);

    try testing.expectError(
        error.PathOutsideProjectRoot,
        build(a, std.testing.io, base, "../escape.ts"),
    );
}

test "contextFreeHash is the builtin-only digest and is stable" {
    const h = contextFreeHash();
    try testing.expectEqualSlices(u8, &h, &contextFreeHash());
    try testing.expectEqual(@as(usize, 64), h.len);
    for (h) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(hex);
    }
}

test "tolerant graph observation preserves imports before failed top-level statements" {
    const ExpectedImport = struct { specifier: []const u8, kind: ImportKind, target: []const u8 };
    const ExpectedRejection = struct { specifier: []const u8, importer: []const u8, reason: []const u8 };
    const parse_failed: ExpectedRejection = .{ .specifier = "", .importer = "entry.ts", .reason = "parse_failed" };
    const cases = [_]struct {
        source: []const u8,
        modules: usize,
        imports: []const ExpectedImport,
        rejected: []const ExpectedRejection,
    }{
        .{ .source = "import { env } from \"zttp:env\"; const broken = ; import { now } from \"zttp:clock\";", .modules = 1, .imports = &.{.{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }}, .rejected = &.{parse_failed} },
        .{ .source = "const broken = ; import { env } from \"zttp:env\";", .modules = 1, .imports = &.{}, .rejected = &.{parse_failed} },
        .{ .source = "function wrapper() { const broken = ; import { env } from \"zttp:env\"; } import { now } from \"zttp:clock\";", .modules = 1, .imports = &.{ .{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }, .{ .specifier = "zttp:clock", .kind = .unresolved, .target = "" } }, .rejected = &.{ parse_failed, .{ .specifier = "zttp:clock", .importer = "entry.ts", .reason = "unknown_specifier" } } },
        .{ .source = "function wrapper() { const broken = ; import { env } from \"zttp:env\"; }", .modules = 1, .imports = &.{.{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }}, .rejected = &.{parse_failed} },
        .{ .source = "import { env } from \"zttp:env\"; while (true) {} import { now } from \"zttp:clock\";", .modules = 1, .imports = &.{.{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }}, .rejected = &.{parse_failed} },
        .{ .source = "import { env } from \"zttp:env\"; const value: any = 1; import { now } from \"zttp:clock\";", .modules = 1, .imports = &.{.{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }}, .rejected = &.{parse_failed} },
        .{ .source = "const value: any = 1; import { env } from \"zttp:env\";", .modules = 1, .imports = &.{}, .rejected = &.{parse_failed} },
        .{ .source = "import { env } from \"zttp:env\"; import type { A } /* ; */ from \"./dep\"; import { now } from \"zttp:clock\";", .modules = 1, .imports = &.{.{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }}, .rejected = &.{parse_failed} },
        .{ .source = "import { a } from \"unknown\"; import { b } from \"zttp-ext:missing\"; import { c } from \"../outside\"; import { answer } from \"./dep\";", .modules = 2, .imports = &.{ .{ .specifier = "unknown", .kind = .unresolved, .target = "" }, .{ .specifier = "zttp-ext:missing", .kind = .extension, .target = "" }, .{ .specifier = "../outside", .kind = .relative, .target = "" }, .{ .specifier = "./dep", .kind = .relative, .target = "dep.ts" } }, .rejected = &.{ .{ .specifier = "../outside", .importer = "entry.ts", .reason = "path_outside_project_root" }, .{ .specifier = "unknown", .importer = "entry.ts", .reason = "unknown_specifier" }, .{ .specifier = "zttp-ext:missing", .importer = "entry.ts", .reason = "extension_manifest_unavailable" } } },
        .{ .source = "structural Broken = number |; import { env } from \"zttp:env\";", .modules = 1, .imports = &.{.{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }}, .rejected = &.{} },
        .{ .source = "import { env } from \"zttp:env\"; function wrapper() { const broken = ; const value: number = 1; } import { now } from \"zttp:clock\";", .modules = 1, .imports = &.{ .{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }, .{ .specifier = "zttp:clock", .kind = .unresolved, .target = "" } }, .rejected = &.{ parse_failed, .{ .specifier = "zttp:clock", .importer = "entry.ts", .reason = "unknown_specifier" } } },
        .{ .source = "function wrapper() { import { env } from \"zttp:env\"; const broken = ; } import { now } from \"zttp:clock\";", .modules = 1, .imports = &.{ .{ .specifier = "zttp:env", .kind = .builtin, .target = "zttp:env" }, .{ .specifier = "zttp:clock", .kind = .unresolved, .target = "" } }, .rejected = &.{ parse_failed, .{ .specifier = "zttp:clock", .importer = "entry.ts", .reason = "unknown_specifier" } } },
    };
    try testing.expectEqual(@as(usize, 12), cases.len);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "entry.ts", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dep.ts", .data = "export const answer: number = 1;" });
    const root = try tmpRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    for (cases) |case| {
        var graph = try buildWithEntrySource(testing.allocator, testing.io, root, "entry.ts", case.source);
        defer graph.deinit(testing.allocator);
        try testing.expectEqual(case.modules, graph.modules.len);
        const entry = entry: {
            for (graph.modules) |module| if (std.mem.eql(u8, module.path, "entry.ts")) break :entry module;
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualSlices(u8, &agent_identity.sourceDigest(case.source), &entry.source_digest);
        try testing.expectEqual(case.imports.len, entry.imports.len);
        for (case.imports, entry.imports) |want, found| {
            try testing.expectEqualStrings(want.specifier, found.specifier);
            try testing.expectEqual(want.kind, found.kind);
            try testing.expectEqualStrings(want.target, found.target);
        }
        try testing.expectEqual(case.rejected.len, graph.rejected.len);
        for (case.rejected, graph.rejected) |want, found| {
            try testing.expectEqualStrings(want.specifier, found.specifier);
            try testing.expectEqualStrings(want.importer, found.importer);
            try testing.expectEqualStrings(want.reason, found.reason);
        }
    }
}

test "a parse failure is a rejection that changes the graph hash" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "entry.ts", .data = "" });
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);

    var graph = try buildWithEntrySource(a, testing.io, root, "entry.ts", "const broken = ;");
    defer graph.deinit(a);
    try testing.expectEqual(@as(usize, 1), graph.rejected.len);
    try testing.expectEqualStrings(rejection_parse_failed, graph.rejected[0].reason);
    try testing.expectEqualStrings("entry.ts", graph.rejected[0].importer);

    const builtin = moduleMetadata.builtinRegistryHash();
    const without = computeHash(graph.modules, &.{}, builtin);
    try testing.expect(!std.mem.eql(u8, &without, &graph.hash));
}

test "a graph with no rejections hashes as the modules-only pre-image" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "entry.ts", .data = "" });
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);
    var graph = try buildWithEntrySource(a, testing.io, root, "entry.ts", "import { env } from \"zttp:env\";\nexport const x = 1;\n");
    defer graph.deinit(a);
    try testing.expectEqual(@as(usize, 0), graph.rejected.len);

    // The pre-image as it stood before rejections were hashed, written out
    // independently of `computeHash`.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (graph.modules) |m| {
        hasher.update(m.path);
        hasher.update("\x00");
        hasher.update(&m.source_digest);
        hasher.update("\x00");
        for (m.imports) |imp| {
            hasher.update(imp.specifier);
            hasher.update("\x00");
            hasher.update(@tagName(imp.kind));
            hasher.update("\x00");
            hasher.update(imp.target);
            hasher.update("\x00");
        }
        hasher.update("\x01");
    }
    hasher.update(&graph.builtin_registry_hash);
    hasher.update("\x01");
    const expected = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    try testing.expectEqualSlices(u8, &expected, &graph.hash);
}
