//! Validation of `zttp:` virtual module imports against the module registry.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const diagnostic_catalog = zts.DiagnosticCatalog;
const ir = zts.parser;
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;
const json_diag = @import("json_diagnostics.zig");

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

        for (0..import_decl.specifiers_count) |j| {
            const spec_idx = view.getListIndex(import_decl.specifiers_start, @intCast(j));
            const spec = view.getImportSpec(spec_idx) orelse continue;
            const imported_name = resolveImportedAtomName(spec.imported_atom, atoms) orelse continue;
            if (zts.modules.validateImports(binding, &.{imported_name})) |missing| {
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
}

/// The JSON diagnostic for a refused virtual import. The message is a heap copy
/// that the diagnostic owns. `file` stays borrowed.
pub fn virtualImportJsonDiagnostic(
    allocator: std.mem.Allocator,
    diagnostic: VirtualImportDiagnostic,
    file: []const u8,
) !json_diag.JsonDiagnostic {
    // The retired types module is refused with the code and text of its
    // `import type` form, so that both spellings report ZTS053.
    const retired = diagnostic.kind == .unknown_module and
        std.mem.eql(u8, diagnostic.module, zts.retired_types_module);
    const message = switch (diagnostic.kind) {
        .unknown_module => if (retired)
            try allocator.dupe(u8, zts.StripDiagnosticKind.retired_types_import.message())
        else
            try allocator.print("unknown virtual module '{s}'", .{diagnostic.module}),
        .missing_export => try allocator.print("module '{s}' does not export '{s}'", .{ diagnostic.module, diagnostic.missing_export.? }),
    };
    errdefer allocator.free(message);
    const suggestion = switch (diagnostic.kind) {
        .unknown_module => if (retired)
            "Remove the import and write Proof<T, P> or Effects<T, R> directly."
        else
            "Use a specifier published by meta.module_catalog.",
        .missing_export => "Use an export published for this module by meta.module_catalog.",
    };
    return .{
        .code = if (retired)
            diagnostic_catalog.stripCode(.retired_types_import)
        else
            diagnostic_catalog.virtualImportCode(diagnostic.kind),
        .severity = "error",
        .message = message,
        .file = file,
        .line = diagnostic.line,
        .column = diagnostic.column,
        .suggestion = suggestion,
        .message_owned = true,
    };
}

test "validateVirtualModuleImports checks specifiers past the 32nd" {
    const allocator = std.testing.allocator;
    const source =
        \\import {
        \\  match as m0, match as m1, match as m2, match as m3,
        \\  match as m4, match as m5, match as m6, match as m7,
        \\  match as m8, match as m9, match as m10, match as m11,
        \\  match as m12, match as m13, match as m14, match as m15,
        \\  match as m16, match as m17, match as m18, match as m19,
        \\  match as m20, match as m21, match as m22, match as m23,
        \\  match as m24, match as m25, match as m26, match as m27,
        \\  match as m28, match as m29, match as m30, match as m31,
        \\  nonexistentExport
        \\} from "zttp:core";
        \\function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
    ;
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var p = try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer p.deinit();
    p.setAtomTable(&atoms);
    _ = try p.parse();
    const view = zts.IrView.fromIRStore(&p.nodes, &p.constants);

    var diag: ?VirtualImportDiagnostic = null;
    try std.testing.expectError(
        error.InvalidImportSpecifier,
        validateVirtualModuleImports(view, &atoms, "handler.ts", &diag),
    );
    try std.testing.expect(diag != null);
    try std.testing.expectEqual(diagnostic_catalog.VirtualImportKind.missing_export, diag.?.kind);
    try std.testing.expectEqualStrings("nonexistentExport", diag.?.missing_export.?);
}
