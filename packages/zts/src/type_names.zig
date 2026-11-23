//! The closed type namespace (ZTS065).
//!
//! A type name in source type syntax must be a primitive, an ambient type from
//! `ambient_names.types`, a `type` declaration in the module
//! (earlier or later in the file), an imported name, or a type parameter.
//! Any other name is refused at the name. The pass runs once, after the parse,
//! because a forward reference needs every declaration of the file.
//!
//! An `import type { Name } from "zttp:module"` declares `Name` when the module
//! lists it in `type_exports`. A name that the module does not export is a
//! refusal at that name in the import. `FetchOptions` is the one such type: a
//! builtin alias that `module_types.populateModuleTypes` registers for the
//! `fetch` signature (spec section 7.1).
//!
//! A `structural` or `nominal` declaration may not take an ambient type name
//! or a name that an `import type` binds: the declaration would shadow a type
//! that the runtime or the module owns, and the handler would pass the check
//! and fail at the first request (ZTS019, at the declared name).
//!
//! A type parameter of a function is in scope for the whole file in this pass,
//! because the store does not record where a function body ends. A type
//! parameter of a `structural` or `nominal` declaration is in scope inside that
//! declaration only.

const std = @import("std");
const parser = @import("parser/root.zig");
const object = @import("object.zig");
const atom_table = @import("atom_table.zig");
const known_types = @import("zts-base").known_types;
const builtin_modules = @import("builtin_modules.zig");

const type_syntax = parser.type_syntax;
const Store = type_syntax.Store;
const Span = type_syntax.Span;
const ir = parser.ir;

const Repair = struct { name: []const u8, text: []const u8 };

/// The repair text for each refused name that has a specific replacement. The
/// one place that holds this table.
const repairs = [_]Repair{
    .{ .name = "Record", .text = "write `Dict<K, V>`" },
    .{ .name = "Map", .text = "write `Dict<K, V>`" },
    .{ .name = "Partial", .text = "declare the record type with `structural`" },
    .{ .name = "Required", .text = "declare the record type with `structural`" },
    .{ .name = "Pick", .text = "declare the record type with `structural`" },
    .{ .name = "Omit", .text = "declare the record type with `structural`" },
    .{ .name = "Readonly", .text = "write the type itself, or `readonly T[]` for an array" },
    .{ .name = "bigint", .text = "write `number`" },
    .{ .name = "any", .text = "write `unknown` and narrow it, or write a precise type" },
    .{ .name = "Function", .text = "write a function type, such as `(x: number) => string`" },
};

const default_repair = "declare it with `type`, import it, or use a type name from `meta` ambient_names";

pub fn repairFor(name: []const u8) []const u8 {
    for (repairs) |row| {
        if (std.mem.eql(u8, row.name, name)) return row.text;
    }
    return default_repair;
}

pub const RefusalKind = enum {
    /// A type name that resolves to nothing (ZTS065).
    undeclared_name,
    /// A name in an `import type` that the module does not export (ZTS207).
    unexported_type,
    /// A declaration named like an ambient type (ZTS019).
    ambient_redeclared,
    /// A declaration named like an `import type` binding (ZTS019).
    imported_redeclared,
    /// A type-position query that does not resolve to a brand (ZTS001).
    unsupported_type_query,
};

pub const Refusal = struct {
    name: []const u8,
    offset: u32,
    kind: RefusalKind = .undeclared_name,
    /// The specifier of the module, for `unexported_type`.
    module: []const u8 = "",
};

const TypeImport = struct {
    module: []const u8,
    imported: []const u8,
    local: []const u8,
    offset: u32,
};

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn atomName(atoms: *atom_table.AtomTable, atom_value: u32) ?[]const u8 {
    const atom: object.Atom = @fromBackingInt(@intCast(atom_value));
    if (atom.isPredefined()) return atom.toPredefinedName();
    return atoms.getName(atom);
}

fn lessThan(_: void, a: Refusal, b: Refusal) bool {
    return a.offset < b.offset;
}

/// Every type name use in `store` that resolves to nothing, in source order.
/// The names borrow the source. The caller frees the slice.
pub fn undeclared(
    allocator: std.mem.Allocator,
    store: *const Store,
    view: ir.IrView,
    root: ir.NodeIndex,
    atoms: *atom_table.AtomTable,
) ![]Refusal {
    var imported: std.ArrayList([]const u8) = .empty;
    defer imported.deinit(allocator);
    if (view.getBlock(root)) |program| {
        for (0..program.stmts_count) |i| {
            const stmt = view.getListIndex(program.stmts_start, @intCast(i));
            if (view.getTag(stmt) != .import_decl) continue;
            const decl = view.getImportDecl(stmt) orelse continue;
            for (0..decl.specifiers_count) |j| {
                const spec_node = view.getListIndex(decl.specifiers_start, @intCast(j));
                const spec = view.getImportSpec(spec_node) orelse continue;
                const local = atomName(atoms, spec.local_binding.name_atom) orelse continue;
                try imported.append(allocator, local);
            }
        }
    }

    var type_imports: std.ArrayList(TypeImport) = .empty;
    defer type_imports.deinit(allocator);
    for (store.type_only_modules.items) |module| {
        if (module.kind != .import_type) continue;
        const specifier = store.typeOnlySpecifier(module) orelse continue;
        for (store.typeOnlyBindings(module)) |binding| try type_imports.append(allocator, .{
            .module = specifier,
            .imported = binding.imported_span.text(store.source),
            .local = binding.local_span.text(store.source),
            .offset = binding.imported_span.start,
        });
    }

    var type_bound: std.ArrayList([]const u8) = .empty;
    defer type_bound.deinit(allocator);
    var refusals: std.ArrayList(Refusal) = .empty;
    errdefer refusals.deinit(allocator);
    for (type_imports.items) |type_import| {
        const binding = builtin_modules.fromSpecifier(type_import.module) orelse {
            if (isFileSpecifier(type_import.module)) {
                try imported.append(allocator, type_import.local);
                try type_bound.append(allocator, type_import.local);
            }
            continue;
        };
        if (containsName(binding.type_exports, type_import.imported)) {
            try imported.append(allocator, type_import.local);
            try type_bound.append(allocator, type_import.local);
        } else {
            try refusals.append(allocator, .{
                .name = type_import.imported,
                .offset = type_import.offset,
                .kind = .unexported_type,
                .module = type_import.module,
            });
        }
    }
    for (store.declarations.items) |declaration| {
        const name = declaration.name_span.text(store.source);
        const kind: RefusalKind = if (containsName(&known_types.ambient, name))
            .ambient_redeclared
        else if (containsName(type_bound.items, name))
            .imported_redeclared
        else
            continue;
        try refusals.append(allocator, .{ .name = name, .offset = declaration.name_span.start, .kind = kind });
    }
    for (store.nodes.items, 0..) |node, node_index| {
        const span = switch (node.data) {
            .named_reference => |span| span,
            else => continue,
        };
        if (brandQueryTarget(node)) |target| {
            const name = target.text(store.source);
            if (isNominalBrandQuery(store, @intCast(node_index), type_imports.items)) {
                if (declaresBrand(store, name)) continue;
                if (importsProspectiveBrand(type_imports.items, name)) continue;
            }
            try refusals.append(allocator, .{
                .name = name,
                .offset = node.semantic_span.start,
                .kind = .unsupported_type_query,
            });
            continue;
        }
        const name = span.text(store.source);
        if (name.len == 0) continue;
        if (containsName(&known_types.ambient, name)) continue;
        if (containsName(imported.items, name)) continue;
        if (declaresName(store, name)) continue;
        if (isTypeParameterInScope(store, name, span)) continue;
        try refusals.append(allocator, .{ .name = name, .offset = span.start });
    }
    std.mem.sort(Refusal, refusals.items, {}, lessThan);
    return refusals.toOwnedSlice(allocator);
}

fn brandQueryTarget(node: type_syntax.Node) ?Span {
    const target = switch (node.data) {
        .named_reference => |span| span,
        else => return null,
    };
    if (target.start <= node.semantic_span.start) return null;
    if (target.end != node.semantic_span.end) return null;
    return target;
}

fn isNominalBrandQuery(store: *const Store, query_index: type_syntax.NodeIndex, imports: []const TypeImport) bool {
    for (store.nodes.items) |node| {
        const application = switch (node.data) {
            .generic_application => |value| value,
            else => continue,
        };
        const arguments = store.memberSlice(application.arguments) orelse continue;
        if (arguments.len != 2) continue;
        const query_argument = switch (arguments[1]) {
            .present => |index| index,
            .absent => continue,
        };
        if (query_argument != query_index) continue;
        const base_index = switch (application.base) {
            .present => |index| index,
            .absent => continue,
        };
        if (@as(usize, base_index) >= store.nodes.items.len) continue;
        const base_span = switch (store.nodes.items[base_index].data) {
            .named_reference => |span| span,
            else => continue,
        };
        const base_name = base_span.text(store.source);
        for (imports) |type_import| {
            if (!std.mem.eql(u8, type_import.module, "zttp:core")) continue;
            if (!std.mem.eql(u8, type_import.imported, "Nominal")) continue;
            if (std.mem.eql(u8, type_import.local, base_name)) return true;
        }
    }
    return false;
}

fn declaresBrand(store: *const Store, name: []const u8) bool {
    for (store.brand_declarations.items) |brand| {
        if (std.mem.eql(u8, brand.name_span.text(store.source), name)) return true;
    }
    return false;
}

fn importsProspectiveBrand(imports: []const TypeImport, local_name: []const u8) bool {
    for (imports) |type_import| {
        if (!isFileSpecifier(type_import.module)) continue;
        if (std.mem.eql(u8, type_import.local, local_name)) return true;
    }
    return false;
}

fn isFileSpecifier(specifier: []const u8) bool {
    return specifier.len > 0 and (specifier[0] == '.' or specifier[0] == '/');
}

fn declaresName(store: *const Store, name: []const u8) bool {
    for (store.declarations.items) |declaration| {
        if (std.mem.eql(u8, declaration.name_span.text(store.source), name)) return true;
    }
    return false;
}

fn isTypeParameterInScope(store: *const Store, name: []const u8, use: Span) bool {
    for (store.generic_owners.items) |owner| {
        const parameters = store.projectedGenericParameterSlice(owner.projected_parameters) orelse continue;
        for (parameters) |parameter| {
            if (!std.mem.eql(u8, parameter.name_span.text(store.source), name)) continue;
            switch (owner.identity) {
                .function => return true,
                .structural_declaration, .nominal_declaration => |index| {
                    if (index >= store.declarations.items.len) return true;
                    const extent = store.declarations.items[index].full_span;
                    if (use.start >= extent.start and use.end <= extent.end) return true;
                },
            }
        }
    }
    return false;
}

test "repairFor answers the specific names and falls back for the rest" {
    try std.testing.expectEqualStrings("write `Dict<K, V>`", repairFor("Record"));
    try std.testing.expectEqualStrings("write `number`", repairFor("bigint"));
    try std.testing.expectEqualStrings("write `unknown` and narrow it, or write a precise type", repairFor("any"));
    try std.testing.expectEqualStrings(default_repair, repairFor("Widget"));
}
