//! Validation of `zttp:` virtual module imports against the module registry.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const diagnostic_catalog = zts.DiagnosticCatalog;
const ir = zts.parser;
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;

fn resolveImportedAtomName(
    atom_value: u32,
    atoms: ?*zts.AtomTable,
) ?[]const u8 {
    const atom: zts.Atom = @fromBackingInt(@intCast(atom_value));
    if (atom.isPredefined()) return atom.toPredefinedName();
    if (atoms) |table| return table.getName(atom);
    return null;
}

pub const VirtualImportDiagnostic = struct {
    kind: diagnostic_catalog.VirtualImportKind,
    module: []const u8,
    missing_export: ?[]const u8 = null,
    line: u32,
    column: u32,
};

pub fn validateVirtualModuleImports(
    view: zts.IrView,
    atoms: ?*zts.AtomTable,
    filename: []const u8,
    diagnostic_out: ?*?VirtualImportDiagnostic,
) !void {
    const node_count = view.nodeCount();
    for (0..node_count) |idx| {
        const node_idx: ir.NodeIndex = @intCast(idx);
        const tag = view.getTag(node_idx) orelse continue;
        if (tag != .import_decl) continue;

        const import_decl = view.getImportDecl(node_idx) orelse continue;
        const module_str = view.getString(import_decl.module_idx) orelse continue;
        const location = view.getLoc(node_idx);
        const line: u32 = if (location) |loc| loc.line else 1;
        const column: u32 = if (location) |loc| loc.column else 1;
        const binding = zts.builtin_modules.fromSpecifier(module_str) orelse {
            // A specifier in the built-in namespace that resolves to nothing
            // is an import of a module that does not exist, and it used to
            // pass with no diagnostic at all: `fromSpecifier` returning null
            // skipped the declaration entirely, so this function only ever
            // checked the exports of modules that were there. Removing
            // `zttp:websocket` is what made the hole visible - every handler
            // still importing it reported clean. Spec rev 4 4.5 has the rule:
            // an unknown module makes the certified build fail closed.
            //
            // `zttp-ext:` is a different namespace, resolved against the
            // session's manifest registry rather than the comptime table, and
            // is deliberately not judged here.
            if (std.mem.startsWith(u8, module_str, "zttp:")) {
                if (diagnostic_out) |out| out.* = .{
                    .kind = .unknown_module,
                    .module = module_str,
                    .line = line,
                    .column = column,
                };
                if (!builtin.is_test) debugPrint(
                    "import error: unknown module '{s}'\n  --> {s}\n  run `zttp modules` for the modules that exist\n",
                    .{ module_str, filename },
                );
                return error.UnknownVirtualModule;
            }
            continue;
        };

        var name_buf: [32][]const u8 = undefined;
        var name_count: usize = 0;
        var j: u8 = 0;
        while (j < import_decl.specifiers_count) : (j += 1) {
            const spec_idx = view.getListIndex(import_decl.specifiers_start, j);
            const spec = view.getImportSpec(spec_idx) orelse continue;
            const imported_name = resolveImportedAtomName(spec.imported_atom, atoms) orelse continue;
            if (name_count < name_buf.len) {
                name_buf[name_count] = imported_name;
                name_count += 1;
            }
        }

        if (zts.modules.validateImports(binding, name_buf[0..name_count])) |missing| {
            if (diagnostic_out) |out| out.* = .{
                .kind = .missing_export,
                .module = module_str,
                .missing_export = missing,
                .line = line,
                .column = column,
            };
            if (!builtin.is_test) debugPrint(
                "import error: module '{s}' does not export '{s}'\n  --> {s}\n",
                .{ module_str, missing, filename },
            );
            return error.InvalidImportSpecifier;
        }
    }
}
