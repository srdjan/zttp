//! `ModuleFacts` — the import and binding index, built once per compile.
//!
//! This is the one part of contract construction that is a pure function of
//! the import declarations and the module binding registry. `ContractBuilder`
//! derived it inline as `scanImports`; six other engine files
//! (`path_generator`, `handler_verifier`, `strict_checker`, `flow_checker`,
//! `effect_inference`, `bool_checker`) each re-derive their own subset of the
//! same walk. The index lives in its own file so those six can read it later
//! without importing the 5,000-line builder they do not otherwise need.
//!
//! Built once, then immutable. Nothing appends to a `ModuleFacts` after
//! `build` returns. `ContractBuilder.build` therefore COPIES `modules` and
//! `functions` into the `HandlerContract` rather than moving them, which is
//! what it did before: a move is a mutation, and it would leave the index
//! empty for every later reader.
//!
//! The ordering of all three collections is load-bearing, not incidental.
//! `modules` is in first-appearance node order, `functions` is in
//! first-appearance module order, and each entry's `names` is in specifier
//! order. `virtual_modules` in the committed contract goldens is a direct
//! projection of `modules`, so a reordering here moves golden bytes.

const std = @import("std");
const contract_types = @import("contract_types.zig");
const ir = @import("parser/ir.zig");
const object = @import("object.zig");
const context = @import("context.zig");
const module_binding = @import("module_binding.zig");
const builtin_modules = @import("builtin_modules.zig");
const manifest_registry_mod = @import("manifest_registry.zig");
const module_manifest = @import("module_manifest.zig");
const json_utils = @import("json_utils.zig");

const IrView = ir.IrView;
const NodeIndex = ir.NodeIndex;
const HandlerContract = contract_types.HandlerContract;
const containsString = json_utils.containsString;

/// A tracked binding: maps a local variable slot to its `FunctionBinding`
/// metadata from the builtin module registry. `extractions` borrows from the
/// comptime binding tables, so it outlives any compile.
pub const GenericBinding = struct {
    slot: u16,
    module_specifier: []const u8,
    binding_name: []const u8,
    extractions: []const module_binding.ContractExtraction,
    flags: module_binding.ContractFlags,
};

/// Like `GenericBinding` but for partner-registered modules. The extraction
/// rules borrow from the live `ManifestRegistry`, so the registry must
/// outlive the facts.
pub const ExtensionBinding = struct {
    slot: u16,
    module_specifier: []const u8,
    binding_name: []const u8,
    extractions: []const module_manifest.ContractExtractionRule,
};

/// One imported specifier, recorded whatever its module resolves to.
///
/// This is the collection the analyzers read. It is deliberately UNFILTERED:
/// `strict_checker` and `effect_inference` record every import including
/// modules that are neither builtin nor partner-registered, while
/// `path_generator`, `flow_checker`, `bool_checker`, and `handler_verifier`
/// record only resolved ones. A superset here lets each apply its own filter at
/// read time, so no analyzer's behavior changes.
///
/// It is also distinct from `generic_bindings`, which records only functions
/// carrying contract extractions or flags: `sha256` has no `generic_bindings`
/// entry but does have an `ImportRecord`.
pub const ImportRecord = struct {
    pub const Resolution = enum { builtin, partner, unresolved };

    /// Local binding slot, the key every analyzer looks up by.
    slot: u16,
    module_specifier: []const u8,
    /// The name as written in the import, not the local alias. For
    /// `import { env as e }` this is `env` while `slot` is `e`'s slot.
    imported_name: []const u8,
    resolution: Resolution,
};

/// The immutable import index. All strings in `modules` and `functions` are
/// owned; both binding lists hold borrowed extraction rules.
pub const ModuleFacts = struct {
    allocator: std.mem.Allocator,

    /// Virtual modules imported by this handler, deduplicated, in
    /// first-appearance node order.
    modules: std.ArrayList([]const u8) = .empty,
    /// Imported names per module, merged by module specifier, in
    /// first-appearance order.
    functions: std.ArrayList(HandlerContract.FunctionEntry) = .empty,
    /// Slot-keyed bindings for builtin modules whose functions carry contract
    /// extraction rules or contract flags.
    generic_bindings: std.ArrayList(GenericBinding) = .empty,
    /// Slot-keyed bindings for partner modules whose exports carry extraction
    /// rules.
    extension_bindings: std.ArrayList(ExtensionBinding) = .empty,
    /// Every imported specifier, unfiltered. See `ImportRecord`.
    imports: std.ArrayList(ImportRecord) = .empty,

    /// Walk every `import_decl` in the IR and index the virtual-module imports.
    ///
    /// Takes exactly what the walk reads: the IR, the atom table that resolves
    /// specifier names, and the partner registry. It does NOT take a `TypeEnv`
    /// or a `TypeChecker`, which is the evidence that this walk is separable
    /// while the builder's other four traversals are not.
    pub fn build(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        atoms: ?*context.AtomTable,
        registry: ?*const manifest_registry_mod.Registry,
    ) !ModuleFacts {
        var self = ModuleFacts{ .allocator = allocator };
        errdefer self.deinit();

        const node_count = ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = ir_view.getTag(idx) orelse continue;
            if (tag != .import_decl) continue;

            const import_decl = ir_view.getImportDecl(idx) orelse continue;
            const module_str = ir_view.getString(import_decl.module_idx) orelse continue;

            // Classify rather than skip. The four collections below still see
            // only virtual modules - built-in or partner-registered - exactly as
            // before, so `ContractBuilder`'s output and the contract goldens are
            // unaffected. `imports` sees everything, because two analyzers need
            // the unresolved ones.
            const resolution: ImportRecord.Resolution = blk: {
                if (builtin_modules.fromSpecifier(module_str) != null) break :blk .builtin;
                if (registry) |reg| {
                    if (reg.fromSpecifier(module_str) != null) break :blk .partner;
                }
                break :blk .unresolved;
            };
            const resolved = resolution != .unresolved;

            // Add module to list (deduplicated, duped)
            if (resolved and !containsString(self.modules.items, module_str)) {
                const duped = try allocator.dupe(u8, module_str);
                errdefer allocator.free(duped);
                try self.modules.append(allocator, duped);
            }

            // Scan specifiers to track function names and binding slots.
            //
            // `func_names` owns every name it holds from `consumed` onward.
            // The merge below transfers or frees them one at a time, so the
            // errdefer must not free what has already been dealt with:
            // `existing.names.append` takes ownership without removing the
            // item from `func_names.items`, so a blanket free would be a
            // double free. The original `scanImports` had no errdefer here at
            // all and leaked the whole list under allocation failure.
            var func_names: std.ArrayList([]const u8) = .empty;
            var consumed: usize = 0;
            errdefer {
                for (func_names.items[consumed..]) |n| allocator.free(n);
                func_names.deinit(allocator);
            }
            var func_module_str: []const u8 = "";

            var j: u8 = 0;
            while (j < import_decl.specifiers_count) : (j += 1) {
                const spec_idx = ir_view.getListIndex(import_decl.specifiers_start, j);
                const spec = ir_view.getImportSpec(spec_idx) orelse continue;
                const imported_name = resolveAtomName(ir_view, atoms, spec.imported_atom) orelse continue;

                // Record the import whatever its module resolved to. Owned
                // strings, because the facts outlive the parser and the atom
                // table these borrow from.
                {
                    const mod_duped = try allocator.dupe(u8, module_str);
                    errdefer allocator.free(mod_duped);
                    const nm_duped = try allocator.dupe(u8, imported_name);
                    errdefer allocator.free(nm_duped);
                    try self.imports.append(allocator, .{
                        .slot = spec.local_binding.slot,
                        .module_specifier = mod_duped,
                        .imported_name = nm_duped,
                        .resolution = resolution,
                    });
                }

                if (!resolved) continue;

                // No errdefer on `name_duped`: after a successful append the
                // list owns it and the scope errdefer above frees it, so an
                // errdefer here would free it twice when a later allocation in
                // this same iteration fails.
                const name_duped = try allocator.dupe(u8, imported_name);
                func_names.append(allocator, name_duped) catch |err| {
                    allocator.free(name_duped);
                    return err;
                };
                func_module_str = module_str;

                // Look up the function in the binding registry and track its
                // contract extraction rules and flags for the call-site scan.
                if (builtin_modules.findExport(module_str, imported_name)) |entry| {
                    const has_extractions = entry.func.contract_extractions.len > 0;
                    const has_flags = entry.func.contract_flags.sets_scope_used or
                        entry.func.contract_flags.sets_durable_used or
                        entry.func.contract_flags.sets_durable_timers or
                        entry.func.contract_flags.sets_bearer_auth or
                        entry.func.contract_flags.sets_jwt_auth;
                    if (has_extractions or has_flags) {
                        try self.generic_bindings.append(allocator, .{
                            .slot = spec.local_binding.slot,
                            .module_specifier = entry.binding.specifier,
                            .binding_name = imported_name,
                            .extractions = entry.func.contract_extractions,
                            .flags = entry.func.contract_flags,
                        });
                    }
                } else if (registry) |reg| {
                    if (reg.findExport(module_str, imported_name)) |partner_exp| {
                        if (partner_exp.contract_extractions.items.len > 0) {
                            try self.extension_bindings.append(allocator, .{
                                .slot = spec.local_binding.slot,
                                .module_specifier = reg.fromSpecifier(module_str).?.specifier,
                                .binding_name = imported_name,
                                .extractions = partner_exp.contract_extractions.items,
                            });
                        }
                    }
                }
            }

            if (func_names.items.len > 0) {
                // Merge with existing entry for same module, or add new
                var merged = false;
                for (self.functions.items) |*existing| {
                    if (std.mem.eql(u8, existing.module, func_module_str)) {
                        for (func_names.items) |name| {
                            // Count it as dealt with before the transfer, so a
                            // failed append frees it here and the errdefer
                            // never sees it twice.
                            consumed += 1;
                            if (!containsString(existing.names.items, name)) {
                                existing.names.append(allocator, name) catch |err| {
                                    allocator.free(name);
                                    return err;
                                };
                            } else {
                                allocator.free(name);
                            }
                        }
                        func_names.deinit(allocator);
                        func_names = .empty;
                        consumed = 0;
                        merged = true;
                        break;
                    }
                }
                if (!merged) {
                    const module_duped = try allocator.dupe(u8, func_module_str);
                    errdefer allocator.free(module_duped);
                    try self.functions.append(allocator, .{
                        .module = module_duped,
                        .names = func_names,
                    });
                    // The entry owns the names now. Disarm the errdefer.
                    func_names = .empty;
                    consumed = 0;
                }
            } else {
                func_names.deinit(allocator);
            }
        }

        return self;
    }

    pub fn deinit(self: *ModuleFacts) void {
        for (self.modules.items) |s| self.allocator.free(s);
        self.modules.deinit(self.allocator);
        for (self.functions.items) |*entry| {
            self.allocator.free(entry.module);
            for (entry.names.items) |n| self.allocator.free(n);
            entry.names.deinit(self.allocator);
        }
        self.functions.deinit(self.allocator);
        self.generic_bindings.deinit(self.allocator);
        self.extension_bindings.deinit(self.allocator);
        for (self.imports.items) |rec| {
            self.allocator.free(rec.module_specifier);
            self.allocator.free(rec.imported_name);
        }
        self.imports.deinit(self.allocator);
    }

    /// True when this handler imports `specifier`.
    pub fn importsModule(self: *const ModuleFacts, specifier: []const u8) bool {
        return containsString(self.modules.items, specifier);
    }

    /// Deep-copy `modules` for a `HandlerContract`, which owns its strings.
    /// The index keeps its own copy so later readers still see the imports.
    pub fn cloneModules(self: *const ModuleFacts, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit(allocator);
        }
        try out.ensureTotalCapacityPrecise(allocator, self.modules.items.len);
        for (self.modules.items) |s| {
            const duped = try allocator.dupe(u8, s);
            errdefer allocator.free(duped);
            try out.append(allocator, duped);
        }
        return out;
    }

    /// Deep-copy `functions` for a `HandlerContract`. See `cloneModules`.
    pub fn cloneFunctions(self: *const ModuleFacts, allocator: std.mem.Allocator) !std.ArrayList(HandlerContract.FunctionEntry) {
        var out: std.ArrayList(HandlerContract.FunctionEntry) = .empty;
        errdefer {
            for (out.items) |*entry| {
                allocator.free(entry.module);
                for (entry.names.items) |n| allocator.free(n);
                entry.names.deinit(allocator);
            }
            out.deinit(allocator);
        }
        try out.ensureTotalCapacityPrecise(allocator, self.functions.items.len);
        for (self.functions.items) |entry| {
            const module_duped = try allocator.dupe(u8, entry.module);
            errdefer allocator.free(module_duped);

            var names: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (names.items) |n| allocator.free(n);
                names.deinit(allocator);
            }
            try names.ensureTotalCapacityPrecise(allocator, entry.names.items.len);
            for (entry.names.items) |n| {
                const name_duped = try allocator.dupe(u8, n);
                errdefer allocator.free(name_duped);
                try names.append(allocator, name_duped);
            }

            try out.append(allocator, .{ .module = module_duped, .names = names });
        }
        return out;
    }
};

fn resolveAtomName(ir_view: IrView, atoms: ?*context.AtomTable, atom_idx: u16) ?[]const u8 {
    if (atoms) |table| {
        // With atom table: predefined atoms first, then the dynamic table.
        const atom: object.Atom = @enumFromInt(atom_idx);
        if (atom.toPredefinedName()) |name| return name;
        return table.getName(atom);
    }
    // Without an atom table (standalone parser): predefined atoms and string
    // constants share the u16 index space. String constants take priority
    // because import specifiers, the main use case here, go through addString;
    // predefined atom names are keywords and builtins, never import specifier
    // names.
    //
    // This branch exists because `bool_checker` had it and the index did not.
    // Its `checkSourceFull` harness builds a checker with no atom table, so
    // without this fallback the index resolved no names there and nine sound-mode
    // tests failed. Copied verbatim from `bool_checker.resolveAtomName` rather
    // than reinvented, so the two cannot drift.
    if (ir_view.getString(atom_idx)) |name| return name;
    const atom: object.Atom = @enumFromInt(atom_idx);
    return atom.toPredefinedName();
}

// ---------------------------------------------------------------------------
// Tests
//
// These carry more weight than they look like they do. The four committed
// contract goldens observe `modules` (as `virtual_modules`) but nothing
// emits `functions`, and `contract_json_parser.zig` never parses the
// `functions` key that the writer emits, so a writer round-trip cannot cover
// it either. Break the merge or the dedup below and no golden byte moves.
// This block is the only gate on that behavior.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Parse `source` and build the index over it. The caller owns the returned
/// facts; `Harness.deinit` frees the parser and atom table that the facts
/// borrowed names from, so call it only after the assertions.
const Harness = struct {
    parser: @import("parser/parse.zig").Parser,
    atoms: context.AtomTable,

    fn init(allocator: std.mem.Allocator, source: []const u8) !*Harness {
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);

        self.* = .{
            .parser = try @import("parser/parse.zig").Parser.init(allocator, source),
            .atoms = context.AtomTable.init(allocator),
        };
        errdefer {
            self.parser.deinit();
            self.atoms.deinit();
        }

        self.parser.setAtomTable(&self.atoms);
        _ = try self.parser.parse();
        return self;
    }

    fn view(self: *Harness) IrView {
        return IrView.fromIRStore(&self.parser.nodes, &self.parser.constants);
    }

    fn deinit(self: *Harness, allocator: std.mem.Allocator) void {
        self.parser.deinit();
        self.atoms.deinit();
        allocator.destroy(self);
    }
};

test "module facts index a builtin import" {
    const allocator = testing.allocator;
    const h = try Harness.init(allocator, "import { env } from \"zttp:env\";\n");
    defer h.deinit(allocator);

    var facts = try ModuleFacts.build(allocator, h.view(), &h.atoms, null);
    defer facts.deinit();

    try testing.expect(facts.importsModule("zttp:env"));
    try testing.expectEqual(@as(usize, 1), facts.functions.items.len);
    try testing.expectEqualStrings("zttp:env", facts.functions.items[0].module);
    try testing.expectEqualStrings("env", facts.functions.items[0].names.items[0]);
}

test "module facts keep first-appearance module order" {
    const allocator = testing.allocator;
    const h = try Harness.init(allocator,
        \\import { sha256 } from "zttp:crypto";
        \\import { env } from "zttp:env";
        \\import { uuid } from "zttp:id";
    );
    defer h.deinit(allocator);

    var facts = try ModuleFacts.build(allocator, h.view(), &h.atoms, null);
    defer facts.deinit();

    // Order is what the goldens pin. Sorting or hashing here moves bytes in
    // `virtual_modules`.
    try testing.expectEqual(@as(usize, 3), facts.modules.items.len);
    try testing.expectEqualStrings("zttp:crypto", facts.modules.items[0]);
    try testing.expectEqualStrings("zttp:env", facts.modules.items[1]);
    try testing.expectEqualStrings("zttp:id", facts.modules.items[2]);
}

test "module facts merge two imports of one module into one entry" {
    const allocator = testing.allocator;
    const h = try Harness.init(allocator,
        \\import { sha256 } from "zttp:crypto";
        \\import { base64Encode } from "zttp:crypto";
    );
    defer h.deinit(allocator);

    var facts = try ModuleFacts.build(allocator, h.view(), &h.atoms, null);
    defer facts.deinit();

    try testing.expectEqual(@as(usize, 1), facts.modules.items.len);
    try testing.expectEqual(@as(usize, 1), facts.functions.items.len);
    try testing.expectEqual(@as(usize, 2), facts.functions.items[0].names.items.len);
    try testing.expectEqualStrings("sha256", facts.functions.items[0].names.items[0]);
    try testing.expectEqualStrings("base64Encode", facts.functions.items[0].names.items[1]);
}

test "module facts deduplicate a name imported twice" {
    const allocator = testing.allocator;
    const h = try Harness.init(allocator,
        \\import { sha256 } from "zttp:crypto";
        \\import { sha256 } from "zttp:crypto";
    );
    defer h.deinit(allocator);

    var facts = try ModuleFacts.build(allocator, h.view(), &h.atoms, null);
    defer facts.deinit();

    // The duplicate is freed rather than appended. If the free is dropped the
    // testing allocator reports the leak here and nowhere else.
    try testing.expectEqual(@as(usize, 1), facts.functions.items.len);
    try testing.expectEqual(@as(usize, 1), facts.functions.items[0].names.items.len);
}

test "module facts skip a module that is neither builtin nor registered" {
    const allocator = testing.allocator;
    const h = try Harness.init(allocator, "import { thing } from \"zttp-ext:unknown\";\n");
    defer h.deinit(allocator);

    var facts = try ModuleFacts.build(allocator, h.view(), &h.atoms, null);
    defer facts.deinit();

    try testing.expect(!facts.importsModule("zttp-ext:unknown"));
    try testing.expectEqual(@as(usize, 0), facts.functions.items.len);
}

test "module facts record a slot binding for a function with extraction rules" {
    const allocator = testing.allocator;
    // `env` carries contract extractions: that is what puts it in
    // generic_bindings for the call-site scan to find by slot.
    const h = try Harness.init(allocator,
        \\import { env } from "zttp:env";
        \\const k = env("KEY");
    );
    defer h.deinit(allocator);

    var facts = try ModuleFacts.build(allocator, h.view(), &h.atoms, null);
    defer facts.deinit();

    try testing.expectEqual(@as(usize, 1), facts.generic_bindings.items.len);
    const gb = facts.generic_bindings.items[0];
    try testing.expectEqualStrings("zttp:env", gb.module_specifier);
    try testing.expectEqualStrings("env", gb.binding_name);
    try testing.expect(gb.extractions.len > 0);
}

test "module facts index a partner import through the registry" {
    const allocator = testing.allocator;
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:stripe",
        \\  "backend": "native-zig",
        \\  "requiredCapabilities": ["network"],
        \\  "exports": [
        \\    { "name": "chargeCard", "effect": "write", "returns": "result" }
        \\  ]
        \\}
    ;
    var manifest = try module_manifest.parse(allocator, manifest_json);
    errdefer manifest.deinit(allocator);

    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(manifest);

    const h = try Harness.init(allocator, "import { chargeCard } from \"zttp-ext:stripe\";\n");
    defer h.deinit(allocator);

    var facts = try ModuleFacts.build(allocator, h.view(), &h.atoms, &registry);
    defer facts.deinit();

    try testing.expect(facts.importsModule("zttp-ext:stripe"));
    try testing.expectEqual(@as(usize, 1), facts.functions.items.len);
    try testing.expectEqualStrings("zttp-ext:stripe", facts.functions.items[0].module);
    try testing.expectEqualStrings("chargeCard", facts.functions.items[0].names.items[0]);
}

test "cloned modules and functions match the index and own their storage" {
    const allocator = testing.allocator;
    const h = try Harness.init(allocator,
        \\import { sha256, base64Encode } from "zttp:crypto";
        \\import { env } from "zttp:env";
    );
    defer h.deinit(allocator);

    var facts = try ModuleFacts.build(allocator, h.view(), &h.atoms, null);
    defer facts.deinit();

    var modules = try facts.cloneModules(allocator);
    defer {
        for (modules.items) |s| allocator.free(s);
        modules.deinit(allocator);
    }
    var functions = try facts.cloneFunctions(allocator);
    defer {
        for (functions.items) |*e| {
            allocator.free(e.module);
            for (e.names.items) |n| allocator.free(n);
            e.names.deinit(allocator);
        }
        functions.deinit(allocator);
    }

    try testing.expectEqual(facts.modules.items.len, modules.items.len);
    for (facts.modules.items, modules.items) |want, got| {
        try testing.expectEqualStrings(want, got);
        // Separate storage, not an aliased slice: the contract must survive
        // the index being freed.
        try testing.expect(want.ptr != got.ptr);
    }

    try testing.expectEqual(facts.functions.items.len, functions.items.len);
    for (facts.functions.items, functions.items) |want, got| {
        try testing.expectEqualStrings(want.module, got.module);
        try testing.expect(want.module.ptr != got.module.ptr);
        try testing.expectEqual(want.names.items.len, got.names.items.len);
        for (want.names.items, got.names.items) |wn, gn| {
            try testing.expectEqualStrings(wn, gn);
            try testing.expect(wn.ptr != gn.ptr);
        }
    }
}

const import_corpus = @import("tests/import_corpus.zig");

test "every import is recorded, whatever its module resolves to" {
    const a = testing.allocator;

    // A builtin, an unresolved module, and an alias. All three appear in
    // `imports`; only the builtin reaches `modules`.
    const h = try Harness.init(a,
        \\import { env as e } from "zttp:env";
        \\import { thing } from "zttp-ext:unknown";
    );
    defer h.deinit(a);

    var facts = try ModuleFacts.build(a, h.view(), &h.atoms, null);
    defer facts.deinit();

    try testing.expectEqual(@as(usize, 2), facts.imports.items.len);

    const first = facts.imports.items[0];
    try testing.expectEqualStrings("zttp:env", first.module_specifier);
    // The imported name, not the local alias.
    try testing.expectEqualStrings("env", first.imported_name);
    try testing.expectEqual(ImportRecord.Resolution.builtin, first.resolution);

    const second = facts.imports.items[1];
    try testing.expectEqualStrings("zttp-ext:unknown", second.module_specifier);
    try testing.expectEqualStrings("thing", second.imported_name);
    try testing.expectEqual(ImportRecord.Resolution.unresolved, second.resolution);

    // The unresolved module must NOT leak into the four legacy collections:
    // that is what keeps ContractBuilder's output and the contract goldens
    // unchanged.
    try testing.expectEqual(@as(usize, 1), facts.modules.items.len);
    try testing.expectEqualStrings("zttp:env", facts.modules.items[0]);
    try testing.expectEqual(@as(usize, 1), facts.functions.items.len);
    try testing.expectEqualStrings("zttp:env", facts.functions.items[0].module);
}

test "a function with no extractions is in imports but not generic_bindings" {
    const a = testing.allocator;
    // The gap that made the index unusable by the six analyzers before C1.
    const h = try Harness.init(a, "import { sha256 } from \"zttp:crypto\";\n");
    defer h.deinit(a);

    var facts = try ModuleFacts.build(a, h.view(), &h.atoms, null);
    defer facts.deinit();

    try testing.expectEqual(@as(usize, 0), facts.generic_bindings.items.len);
    try testing.expectEqual(@as(usize, 1), facts.imports.items.len);
    try testing.expectEqualStrings("sha256", facts.imports.items[0].imported_name);
    try testing.expectEqual(ImportRecord.Resolution.builtin, facts.imports.items[0].resolution);
}

test "a partner import is recorded as partner" {
    const a = testing.allocator;
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:stripe",
        \\  "backend": "native-zig",
        \\  "requiredCapabilities": ["network"],
        \\  "exports": [
        \\    { "name": "chargeCard", "effect": "write", "returns": "result" }
        \\  ]
        \\}
    ;
    var manifest = try module_manifest.parse(a, manifest_json);
    errdefer manifest.deinit(a);
    var registry = manifest_registry_mod.Registry.init(a);
    defer registry.deinit();
    try registry.register(manifest);

    const h = try Harness.init(a, "import { chargeCard } from \"zttp-ext:stripe\";\n");
    defer h.deinit(a);

    var facts = try ModuleFacts.build(a, h.view(), &h.atoms, &registry);
    defer facts.deinit();

    try testing.expectEqual(@as(usize, 1), facts.imports.items.len);
    try testing.expectEqual(ImportRecord.Resolution.partner, facts.imports.items[0].resolution);
}

test "the whole shared corpus builds an index without error" {
    // Cheap coverage that every case the six differential tests will run over
    // is at least parseable and indexable. A corpus entry that fails to parse
    // would make a later differential test vacuously pass.
    const a = testing.allocator;
    for (import_corpus.cases) |case| {
        const h = Harness.init(a, case.source) catch |err| {
            std.debug.print("\ncorpus case failed to parse: {s}\n", .{case.label});
            return err;
        };
        defer h.deinit(a);

        var facts = try ModuleFacts.build(a, h.view(), &h.atoms, null);
        defer facts.deinit();

        // Every recorded import must carry a non-empty specifier and name, so a
        // later test comparing against a scan cannot match on empty strings.
        for (facts.imports.items) |rec| {
            try testing.expect(rec.module_specifier.len > 0);
            try testing.expect(rec.imported_name.len > 0);
        }
    }
}

test "module facts survive allocation failure at every step" {
    const source =
        \\import { sha256, base64Encode } from "zttp:crypto";
        \\import { env } from "zttp:env";
        \\import { sha256 } from "zttp:crypto";
    ;
    // Parse with the ordinary allocator and run the failing allocator over
    // `build` and the two clones only. The ladder is evidence about the code
    // this file adds; whether the parser is allocation-failure clean is a
    // separate question with a separate owner.
    const h = try Harness.init(testing.allocator, source);
    defer h.deinit(testing.allocator);

    const Ctx = struct {
        fn run(allocator: std.mem.Allocator, view: IrView, atoms: *context.AtomTable) !void {
            var facts = try ModuleFacts.build(allocator, view, atoms, null);
            defer facts.deinit();

            var modules = try facts.cloneModules(allocator);
            defer {
                for (modules.items) |s| allocator.free(s);
                modules.deinit(allocator);
            }
            var functions = try facts.cloneFunctions(allocator);
            defer {
                for (functions.items) |*e| {
                    allocator.free(e.module);
                    for (e.names.items) |n| allocator.free(n);
                    e.names.deinit(allocator);
                }
                functions.deinit(allocator);
            }
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.run, .{ h.view(), &h.atoms });
}

test "the index resolves import names with no atom table" {
    // The gap that nine bool_checker sound-mode tests found and this file's
    // corpus test missed: `checkSourceFull` builds a checker with no atom table,
    // and without the string-constant fallback the index resolves no names at
    // all. Pinned here so the fallback cannot be removed as dead code.
    const a = testing.allocator;

    var parser = try @import("parser/parse.zig").Parser.init(a, "import { env } from \"zttp:env\";\n");
    defer parser.deinit();
    // No setAtomTable: this is the standalone-parser path.
    _ = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var facts = try ModuleFacts.build(a, view, null, null);
    defer facts.deinit();

    try testing.expectEqual(@as(usize, 1), facts.imports.items.len);
    try testing.expectEqualStrings("zttp:env", facts.imports.items[0].module_specifier);
    try testing.expectEqualStrings("env", facts.imports.items[0].imported_name);
    try testing.expect(facts.importsModule("zttp:env"));
}
