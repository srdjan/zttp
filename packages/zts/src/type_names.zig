//! The closed type namespace (ZTS065).
//!
//! A type name in source type syntax must be a primitive, an ambient type from
//! `ambient_names.types`, a `structural` or `nominal` declaration of the module
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

const Tokenizer = parser.Tokenizer;
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

const default_repair = "declare it with `structural`, import it, or use a type name from `meta` ambient_names";

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

/// Append the names of one `import type { A, B as C } from "m";` statement. A
/// statement of another shape adds nothing: the parser refuses it by itself.
fn appendTypeImports(
    allocator: std.mem.Allocator,
    text: []const u8,
    base: u32,
    out: *std.ArrayList(TypeImport),
) !void {
    var tokens = Tokenizer.init(text);
    var token = tokens.next();
    while (token.type != .lbrace) : (token = tokens.next()) {
        if (token.type == .eof) return;
    }
    var names: std.ArrayList(TypeImport) = .empty;
    defer names.deinit(allocator);
    token = tokens.next();
    while (token.type != .rbrace) {
        if (!parser.isNameText(token.text(text))) return;
        const imported = token.text(text);
        const offset = base + token.start;
        var local = imported;
        token = tokens.next();
        if (token.type == .kw_as) {
            token = tokens.next();
            if (!parser.isNameText(token.text(text))) return;
            local = token.text(text);
            token = tokens.next();
        }
        try names.append(allocator, .{ .module = "", .imported = imported, .local = local, .offset = offset });
        if (token.type == .comma) {
            token = tokens.next();
        } else if (token.type != .rbrace) {
            return;
        }
    }
    token = tokens.next();
    if (token.type != .kw_from) return;
    token = tokens.next();
    if (token.type != .string_literal or token.len < 2) return;
    const specifier = token.text(text)[1 .. token.len - 1];
    for (names.items) |name| {
        try out.append(allocator, .{
            .module = specifier,
            .imported = name.imported,
            .local = name.local,
            .offset = name.offset,
        });
    }
}

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
        try appendTypeImports(allocator, module.raw_span.text(store.source), module.raw_span.start, &type_imports);
    }

    var refusals: std.ArrayList(Refusal) = .empty;
    errdefer refusals.deinit(allocator);
    for (type_imports.items) |type_import| {
        const binding = builtin_modules.fromSpecifier(type_import.module) orelse continue;
        if (containsName(binding.type_exports, type_import.imported)) {
            try imported.append(allocator, type_import.local);
        } else {
            try refusals.append(allocator, .{
                .name = type_import.imported,
                .offset = type_import.offset,
                .kind = .unexported_type,
                .module = type_import.module,
            });
        }
    }
    for (store.nodes.items) |node| {
        const span = switch (node.data) {
            .named_reference => |span| span,
            else => continue,
        };
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
