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

pub const BuildError = error{
    /// The entry file could not be read. Distinct from an unreadable import,
    /// which is a rejection inside an otherwise valid graph.
    EntryUnreadable,
    GraphTooLarge,
} || std.mem.Allocator.Error || agent_identity.PathError;

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
/// The runtime graph passes null here and defaults every extensionless
/// specifier to `.ts`; probing instead means `./util` finds `util.tsx`, and a
/// wrong guess would otherwise be recorded as a real target and digested.
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

        const source = zts.file_io.readFile(allocator, abs, max_source_bytes) catch {
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
        .hash = computeHash(module_slice, builtin_hash),
    };
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
    const is_tsx = std.mem.endsWith(u8, importer_rel, ".tsx");
    const is_ts = is_tsx or std.mem.endsWith(u8, importer_rel, ".ts");

    // The parser reads stripped source, exactly as the runtime graph does. A
    // strip failure is not fatal here: an unparseable module still belongs in
    // the graph with its digest, and `check` is what reports the error.
    //
    // The stripped code is copied out and the result released immediately, so
    // this file names only the curated `zts.strip` and never the internal
    // `stripper` module - keeping the module boundary as narrow as the work
    // needs. The copy is one source file's bytes.
    var stripped_code: ?[]u8 = null;
    defer if (stripped_code) |c| allocator.free(c);
    if (is_ts) {
        if (zts.strip(allocator, source, .{ .tsx_mode = is_tsx })) |result| {
            var owned = result;
            stripped_code = allocator.dupe(u8, owned.code) catch null;
            owned.deinit();
        } else |_| {}
    }
    const parse_source = if (stripped_code) |c| c else source;

    var js_parser = parser.JsParser.init(allocator, parse_source) catch return;
    defer js_parser.deinit();
    if (is_tsx or std.mem.endsWith(u8, importer_rel, ".jsx")) js_parser.tokenizer.enableJsx();
    _ = js_parser.parse() catch {};

    const view = parser.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const node_count = view.nodeCount();
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
/// as an absent one.
fn computeHash(modules: []const ModuleRecord, builtin_hash: [64]u8) [64]u8 {
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
    hasher.update(&builtin_hash);
    hasher.update("\x01");
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

/// The digest of the module environment with no entry file: the built-in
/// registry alone. Operations that take no `file` bind this, so `expected` has
/// something to compare and the envelope field is never empty.
pub fn contextFreeHash() [64]u8 {
    return computeHash(&.{}, moduleMetadata.builtinRegistryHash());
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
