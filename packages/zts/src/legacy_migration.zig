//! Independent M4 validation for the four legacy source migrations.

const std = @import("std");
const engine = @import("zts-engine");
const repair_intent = @import("repair_intent.zig");
const type_checker = @import("type_checker.zig");
const type_env = @import("type_env.zig");
const type_pool = @import("type_pool.zig");
const module_facts = @import("module_facts.zig");

const Store = engine.parser.type_syntax.Store;
const Declaration = engine.parser.type_syntax.Declaration;
const LegacyAssertRepair = engine.parser.type_syntax.LegacyAssertRepair;
const LegacyMatchRepair = engine.parser.type_syntax.LegacyMatchRepair;
const LegacyMatchArmRepair = engine.parser.type_syntax.LegacyMatchArmRepair;
const RepairIntent = repair_intent.RepairIntent;

pub const TypedDiagnosticEvidence = struct {
    code: []const u8,
    intent: RepairIntent,
    line: u32,
    start_offset: u32,
    end_offset: u32,
    source_digest: [32]u8,
    declaration_span: engine.parser.type_syntax.Span,
    binding_span: engine.parser.type_syntax.Span,
    annotation_span: engine.parser.type_syntax.Span,
    initializer_span: engine.parser.type_syntax.Span,
    nominal_name: []const u8,
    brand_name: ?[]const u8,
    module_path: []const u8,
    nominal_declaration_start: u32,
    base: type_checker.NominalBase,
};

pub const SourceInput = struct {
    original: OriginalRecords,
    typed_source: []const u8,
    typed_diagnostics: []const TypedDiagnosticEvidence,
    candidate: CandidateAuthority,
};

pub const OriginalRecords = struct {
    source: []const u8,
    ir_view: engine.parser.IrView,
    atoms: *engine.atom_table.AtomTable,
    scopes: *const engine.parser.ScopeAnalyzer,
    type_store: *const Store,
    declarations: []const Declaration,
    asserts: []const LegacyAssertRepair,
    matches: []const LegacyMatchRepair,
    match_arms: []const LegacyMatchArmRepair,

    fn arms(self: OriginalRecords, record: LegacyMatchRepair) []const LegacyMatchArmRepair {
        const start: usize = record.arms.start;
        const end = start + record.arms.count;
        if (end > self.match_arms.len) return &.{};
        return self.match_arms[start..end];
    }
};

pub const CandidateAuthority = struct {
    module_path: []const u8,
    source: []const u8,
    ir_view: engine.parser.IrView,
    atoms: *engine.atom_table.AtomTable,
    scopes: *const engine.parser.ScopeAnalyzer,
    type_store: *const Store,
    module_facts: *const module_facts.ModuleFacts,
    type_env: *const type_env.TypeEnv,
};

pub const Verdict = union(enum) {
    equivalent,
    refused: []const u8,
};

pub fn sourceDigest(source: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(source, &digest, .{});
    return digest;
}

const Edit = struct { start: usize, end: usize, replacement: []u8 };

const ParsedAuthority = struct {
    source: []const u8,
    ir_view: engine.parser.IrView,
    atoms: *engine.atom_table.AtomTable,
    scopes: *const engine.parser.ScopeAnalyzer,
    type_store: *const Store,
};

fn originalAuthority(input: SourceInput) ParsedAuthority {
    return .{
        .source = input.original.source,
        .ir_view = input.original.ir_view,
        .atoms = input.original.atoms,
        .scopes = input.original.scopes,
        .type_store = input.original.type_store,
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdent(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn simpleIdentifier(text: []const u8) bool {
    if (text.len == 0 or !isIdentStart(text[0])) return false;
    for (text[1..]) |c| if (!isIdent(c)) return false;
    return true;
}

fn bindingEqual(a: engine.parser.ir.BindingRef, b: engine.parser.ir.BindingRef) bool {
    return a.scope_id == b.scope_id and a.slot == b.slot and a.name_atom == b.name_atom and a.kind == b.kind;
}

fn runtimeCoreAlias(authority: ParsedAuthority, export_name: []const u8) ?[]const u8 {
    for (0..authority.ir_view.nodeCount()) |raw| {
        const node: engine.parser.NodeIndex = @intCast(raw);
        if (authority.ir_view.getTag(node) != .import_decl) continue;
        const declaration = authority.ir_view.getImportDecl(node) orelse continue;
        const module = authority.ir_view.getString(declaration.module_idx) orelse continue;
        if (!std.mem.eql(u8, module, "zttp:core")) continue;
        for (0..declaration.specifiers_count) |offset| {
            const specifier_node = authority.ir_view.getListIndex(declaration.specifiers_start, @intCast(offset));
            const specifier = authority.ir_view.getImportSpec(specifier_node) orelse continue;
            const imported = authority.atoms.getName(@fromBackingInt(@intCast(specifier.imported_atom))) orelse continue;
            if (!std.mem.eql(u8, imported, export_name)) continue;
            return authority.atoms.getName(@fromBackingInt(@intCast(specifier.local_binding.name_atom)));
        }
    }
    return null;
}

fn typeCoreAlias(authority: ParsedAuthority, export_name: []const u8) ?[]const u8 {
    for (authority.type_store.type_only_modules.items) |module| {
        if (module.kind != .import_type) continue;
        const specifier = authority.type_store.typeOnlySpecifier(module) orelse continue;
        if (!std.mem.eql(u8, specifier, "zttp:core")) continue;
        for (authority.type_store.typeOnlyBindings(module)) |binding| {
            if (std.mem.eql(u8, binding.imported_span.text(authority.source), export_name)) {
                return binding.local_span.text(authority.source);
            }
        }
    }
    return null;
}

fn hasBinding(authority: ParsedAuthority, name: []const u8) bool {
    for (authority.scopes.scopes.items) |scope| {
        for (scope.bindings.items) |binding| if (std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

fn hasModuleBinding(authority: ParsedAuthority, name: []const u8) bool {
    if (authority.scopes.scopes.items.len == 0) return false;
    for (authority.scopes.scopes.items[0].bindings.items) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

fn nodeSource(authority: ParsedAuthority, node: engine.parser.NodeIndex) ?[]const u8 {
    const location = authority.ir_view.getLoc(node) orelse return null;
    const span = location.span();
    if (span.start > span.end or span.end > authority.source.len) return null;
    return authority.source[span.start..span.end];
}

const PatternBinding = struct { name: []u8, path: []u8 };

fn patternPath(allocator: std.mem.Allocator, base: []const u8, key: []const u8) ![]u8 {
    if (simpleIdentifier(key)) return allocator.print("{s}.{s}", .{ base, key });
    return allocator.print("{s}[{s}]", .{ base, key });
}

fn appendPatternBinding(
    allocator: std.mem.Allocator,
    bindings: *std.ArrayListUnmanaged(PatternBinding),
    name: []const u8,
    path: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try bindings.append(allocator, .{ .name = owned_name, .path = owned_path });
}

const PatternDescriptor = struct {
    alias: []const u8,
    used: bool = false,
};

fn appendStructuredPattern(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    bindings: *std.ArrayListUnmanaged(PatternBinding),
    authority: ParsedAuthority,
    node: engine.parser.NodeIndex,
    path: []const u8,
    descriptor: *PatternDescriptor,
) !void {
    const view = authority.ir_view;
    switch (view.getTag(node) orelse return error.InvalidMigration) {
        .match_pattern => {
            const object = view.getMatchPattern(node) orelse return error.InvalidMigration;
            try output.appendSlice(allocator, "{ ");
            var emitted = false;
            for (0..object.props_count) |offset| {
                const property_node = view.getListIndex(object.props_start, @intCast(offset));
                const property = view.getProperty(property_node) orelse return error.InvalidMigration;
                const key = nodeSource(authority, property.key) orelse return error.InvalidMigration;
                const field_path = try patternPath(allocator, path, key);
                defer allocator.free(field_path);
                if (view.getTag(property.value) == .identifier) {
                    const binding = view.getBinding(property.value) orelse return error.InvalidMigration;
                    const name = authority.atoms.getName(@fromBackingInt(@intCast(binding.name_atom))) orelse return error.InvalidMigration;
                    try appendPatternBinding(allocator, bindings, name, field_path);
                    continue;
                }
                if (emitted) try output.appendSlice(allocator, ", ");
                emitted = true;
                try output.print(allocator, "{s}: ", .{key});
                if (property.value == engine.parser.null_node) {
                    descriptor.used = true;
                    try output.print(allocator, "{s}.present", .{descriptor.alias});
                } else {
                    try appendStructuredPattern(allocator, output, bindings, authority, property.value, field_path, descriptor);
                }
            }
            try output.appendSlice(allocator, " }");
        },
        .array_pattern => {
            const array = view.getArray(node) orelse return error.InvalidMigration;
            try output.append(allocator, '[');
            for (0..array.elements_count) |offset| {
                if (offset > 0) try output.appendSlice(allocator, ", ");
                const element = view.getListIndex(array.elements_start, @intCast(offset));
                if (element == engine.parser.null_node) {
                    descriptor.used = true;
                    try output.print(allocator, "{s}.any", .{descriptor.alias});
                } else {
                    const item_path = try allocator.print("{s}[{d}]", .{ path, offset });
                    defer allocator.free(item_path);
                    try appendStructuredPattern(allocator, output, bindings, authority, element, item_path, descriptor);
                }
            }
            try output.append(allocator, ']');
        },
        .match_type_test => {
            const kind = (view.getMatchTypeTest(node) orelse return error.InvalidMigration).kind;
            const name: []const u8 = switch (kind) {
                .boolean => "boolean",
                .number => "number",
                .string => "string",
                .array => "array",
                .dict => "Dict",
                .bytes => "Bytes",
            };
            descriptor.used = true;
            try output.print(allocator, "{s}.{s}", .{ descriptor.alias, name });
        },
        .lit_int, .lit_float, .lit_string, .lit_bool, .lit_null, .lit_undefined => try output.appendSlice(allocator, nodeSource(authority, node) orelse return error.InvalidMigration),
        else => return error.InvalidMigration,
    }
}

fn freshCallbackName(allocator: std.mem.Allocator, authority: ParsedAuthority, next: *usize) ![]u8 {
    while (true) {
        const suffix = next.*;
        next.* += 1;
        const name = if (suffix == 1) try allocator.dupe(u8, "matchValue") else try allocator.print("matchValue{d}", .{suffix});
        if (!hasBinding(authority, name)) return name;
        allocator.free(name);
    }
}

fn matchReplacement(
    allocator: std.mem.Allocator,
    records: OriginalRecords,
    record: LegacyMatchRepair,
    match_alias: []const u8,
    descriptor: *PatternDescriptor,
    authority: ParsedAuthority,
    next_callback: *usize,
) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(allocator, "{s}({s})", .{ match_alias, record.subject_span.text(records.source) });
    var default_body: ?[]u8 = null;
    defer if (default_body) |body| allocator.free(body);
    for (records.arms(record)) |arm| {
        const body = try renderNestedMatches(allocator, records, arm.body_span, match_alias, descriptor, authority, next_callback);
        if (arm.pattern_span == null) {
            if (default_body != null) allocator.free(default_body.?);
            default_body = body;
            continue;
        }
        defer allocator.free(body);
        var pattern: std.ArrayListUnmanaged(u8) = .empty;
        defer pattern.deinit(allocator);
        var bindings: std.ArrayListUnmanaged(PatternBinding) = .empty;
        defer {
            for (bindings.items) |binding| {
                allocator.free(binding.name);
                allocator.free(binding.path);
            }
            bindings.deinit(allocator);
        }
        const callback = try freshCallbackName(allocator, authority, next_callback);
        defer allocator.free(callback);
        try appendStructuredPattern(allocator, &pattern, &bindings, authority, arm.pattern_node, callback, descriptor);
        try output.print(allocator, ".with({s}, ", .{pattern.items});
        if (bindings.items.len == 0) {
            try output.print(allocator, "() => {s})", .{body});
        } else {
            try output.print(allocator, "({s}) => {{ ", .{callback});
            for (bindings.items) |binding| try output.print(allocator, "const {s} = {s}; ", .{ binding.name, binding.path });
            try output.print(allocator, "return {s}; }})", .{body});
        }
    }
    if (default_body) |body| try output.print(allocator, ".otherwise(() => {s})", .{body}) else try output.appendSlice(allocator, ".exhaustive()");
    return output.toOwnedSlice(allocator);
}

fn renderNestedMatches(
    allocator: std.mem.Allocator,
    records: OriginalRecords,
    span: engine.parser.type_syntax.Span,
    match_alias: []const u8,
    descriptor: *PatternDescriptor,
    authority: ParsedAuthority,
    next_callback: *usize,
) anyerror![]u8 {
    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    defer {
        for (edits.items) |edit| allocator.free(edit.replacement);
        edits.deinit(allocator);
    }
    for (records.matches, 0..) |record, index| {
        if (record.full_span.start < span.start or record.full_span.end > span.end) continue;
        var nested = false;
        for (records.matches, 0..) |other, other_index| {
            if (index == other_index) continue;
            if (other.full_span.start >= span.start and other.full_span.end <= span.end and
                other.full_span.start <= record.full_span.start and record.full_span.end <= other.full_span.end)
            {
                nested = true;
                break;
            }
        }
        if (nested) continue;
        try edits.append(allocator, .{
            .start = record.full_span.start - span.start,
            .end = record.full_span.end - span.start,
            .replacement = try matchReplacement(allocator, records, record, match_alias, descriptor, authority, next_callback),
        });
    }
    const raw = span.text(records.source);
    if (edits.items.len == 0) return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r"));
    const rendered = try applyEdits(allocator, raw, edits.items, "");
    defer allocator.free(rendered);
    return allocator.dupe(u8, std.mem.trim(u8, rendered, " \t\r"));
}

fn applyEdits(allocator: std.mem.Allocator, source: []const u8, edits: []Edit, prefix: []const u8) ![]u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn lessThan(_: void, a: Edit, b: Edit) bool {
            return a.start < b.start;
        }
    }.lessThan);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, prefix);
    var cursor: usize = 0;
    for (edits) |edit| {
        if (edit.start < cursor or edit.end > source.len) return error.InvalidMigration;
        try out.appendSlice(allocator, source[cursor..edit.start]);
        try out.appendSlice(allocator, edit.replacement);
        cursor = edit.end;
    }
    try out.appendSlice(allocator, source[cursor..]);
    return out.toOwnedSlice(allocator);
}

fn phaseOneExpected(allocator: std.mem.Allocator, input: SourceInput) ![]u8 {
    const source = input.original.source;
    const authority = originalAuthority(input);
    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    defer {
        for (edits.items) |edit| allocator.free(edit.replacement);
        edits.deinit(allocator);
    }
    var need_nominal = false;
    const match_alias = runtimeCoreAlias(authority, "match") orelse "match";
    const assert_alias = runtimeCoreAlias(authority, "assert") orelse "assert";
    var descriptor: PatternDescriptor = .{ .alias = runtimeCoreAlias(authority, "P") orelse "P" };
    const nominal_alias = typeCoreAlias(authority, "Nominal") orelse "Nominal";
    var next_callback: usize = 1;

    for (input.original.declarations) |declaration| switch (declaration.kind) {
        .structural => if (std.mem.eql(u8, declaration.keyword_span.text(source), "structural")) {
            try edits.append(allocator, .{ .start = declaration.keyword_span.start, .end = declaration.keyword_span.end, .replacement = try allocator.dupe(u8, "type") });
        },
        .nominal => if (std.mem.eql(u8, declaration.keyword_span.text(source), "nominal")) {
            const body = switch (declaration.body) {
                .present => |present| present.raw_span.text(source),
                .absent => return error.InvalidMigration,
            };
            const name = declaration.name_span.text(source);
            if (name.len == 0 or !isIdentStart(name[0])) return error.InvalidMigration;
            const brand = try allocator.print("{c}{s}Brand", .{ std.ascii.toLower(name[0]), name[1..] });
            defer allocator.free(brand);
            if (hasModuleBinding(authority, brand)) return error.InvalidMigration;
            const export_prefix: []const u8 = if (declaration.export_span != null) "export " else "";
            const replacement = try allocator.print("declare const {s}: unique symbol;\n{s}type {s} = {s}<{s}, typeof {s}>;", .{ brand, export_prefix, name, nominal_alias, body, brand });
            try edits.append(allocator, .{ .start = declaration.full_span.start, .end = declaration.full_span.end, .replacement = replacement });
            need_nominal = true;
        },
    };
    for (input.original.asserts) |record| {
        try edits.append(allocator, .{ .start = record.full_span.start, .end = record.full_span.end, .replacement = try allocator.print("{s}({s});", .{ assert_alias, record.predicate_span.text(source) }) });
    }
    for (input.original.matches, 0..) |record, index| {
        var nested = false;
        for (input.original.matches, 0..) |other, other_index| {
            if (index == other_index) continue;
            if (other.full_span.start <= record.full_span.start and record.full_span.end <= other.full_span.end) {
                nested = true;
                break;
            }
        }
        if (nested) continue;
        try edits.append(allocator, .{
            .start = record.full_span.start,
            .end = record.full_span.end,
            .replacement = try matchReplacement(allocator, input.original, record, match_alias, &descriptor, authority, &next_callback),
        });
    }

    var prefix: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix.deinit(allocator);
    if (need_nominal and typeCoreAlias(authority, "Nominal") == null) {
        if (hasModuleBinding(authority, "Nominal")) return error.InvalidMigration;
        try prefix.appendSlice(allocator, "import type { Nominal } from \"zttp:core\";\n");
    }
    var runtime: std.ArrayListUnmanaged(u8) = .empty;
    defer runtime.deinit(allocator);
    if (input.original.matches.len > 0 and runtimeCoreAlias(authority, "match") == null) {
        if (hasModuleBinding(authority, "match")) return error.InvalidMigration;
        try runtime.appendSlice(allocator, "match");
    }
    if (input.original.asserts.len > 0 and runtimeCoreAlias(authority, "assert") == null) {
        if (hasModuleBinding(authority, "assert")) return error.InvalidMigration;
        if (runtime.items.len > 0) try runtime.appendSlice(allocator, ", ");
        try runtime.appendSlice(allocator, "assert");
    }
    if (descriptor.used and runtimeCoreAlias(authority, "P") == null) {
        if (hasModuleBinding(authority, "P")) return error.InvalidMigration;
        if (runtime.items.len > 0) try runtime.appendSlice(allocator, ", ");
        try runtime.appendSlice(allocator, "P");
    }
    if (runtime.items.len > 0) try prefix.print(allocator, "import {{ {s} }} from \"zttp:core\";\n", .{runtime.items});
    return applyEdits(allocator, source, edits.items, prefix.items);
}

fn phaseTwoExpected(allocator: std.mem.Allocator, input: SourceInput) ![]u8 {
    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    defer {
        for (edits.items) |edit| allocator.free(edit.replacement);
        edits.deinit(allocator);
    }
    const authority = originalAuthority(input);
    const nominal_alias = runtimeCoreAlias(authority, "nominal") orelse "nominal";
    const digest = sourceDigest(input.typed_source);
    for (input.typed_diagnostics) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.code, "ZTS200") or diagnostic.intent != .wrap_implicit_nominal_initializer) continue;
        if (!std.mem.eql(u8, &digest, &diagnostic.source_digest)) return error.InvalidMigration;
        if (diagnostic.declaration_span.end > input.typed_source.len or
            diagnostic.binding_span.start < diagnostic.declaration_span.start or
            diagnostic.annotation_span.start < diagnostic.binding_span.end or
            diagnostic.initializer_span.start < diagnostic.annotation_span.end or
            diagnostic.initializer_span.end > diagnostic.declaration_span.end or
            diagnostic.start_offset != diagnostic.initializer_span.start or
            diagnostic.end_offset != diagnostic.initializer_span.end)
            return error.InvalidMigration;
        const type_name = diagnostic.annotation_span.text(input.typed_source);
        const value = diagnostic.initializer_span.text(input.typed_source);
        if (!simpleIdentifier(type_name) or value.len == 0) return error.InvalidMigration;
        try edits.append(allocator, .{
            .start = diagnostic.initializer_span.start,
            .end = diagnostic.initializer_span.end,
            .replacement = try allocator.print("{s}<{s}>({s})", .{ nominal_alias, type_name, value }),
        });
    }
    const prefix: []const u8 = if (edits.items.len > 0 and runtimeCoreAlias(authority, "nominal") == null)
        "import { nominal } from \"zttp:core\";\n"
    else
        "";
    return applyEdits(allocator, input.typed_source, edits.items, prefix);
}

fn parsedCoreReferenceCount(authority: ParsedAuthority, export_name: []const u8) usize {
    var count: usize = 0;
    for (0..authority.ir_view.nodeCount()) |raw| {
        const node: engine.parser.NodeIndex = @intCast(raw);
        if (authority.ir_view.getTag(node) != .identifier) continue;
        const reference = authority.ir_view.getBinding(node) orelse continue;
        var matched = false;
        for (0..authority.ir_view.nodeCount()) |import_raw| {
            const import_node: engine.parser.NodeIndex = @intCast(import_raw);
            if (authority.ir_view.getTag(import_node) != .import_decl) continue;
            const declaration = authority.ir_view.getImportDecl(import_node) orelse continue;
            const module = authority.ir_view.getString(declaration.module_idx) orelse continue;
            if (!std.mem.eql(u8, module, "zttp:core")) continue;
            for (0..declaration.specifiers_count) |offset| {
                const specifier_node = authority.ir_view.getListIndex(declaration.specifiers_start, @intCast(offset));
                const specifier = authority.ir_view.getImportSpec(specifier_node) orelse continue;
                const imported = authority.atoms.getName(@fromBackingInt(@intCast(specifier.imported_atom))) orelse continue;
                if (std.mem.eql(u8, imported, export_name) and bindingEqual(reference, specifier.local_binding)) {
                    matched = true;
                    break;
                }
            }
            if (matched) break;
        }
        if (matched) count += 1;
    }
    return count;
}

fn resolvedCoreReferenceCount(candidate: CandidateAuthority, export_name: []const u8) usize {
    var count: usize = 0;
    for (0..candidate.ir_view.nodeCount()) |raw| {
        const node: engine.parser.NodeIndex = @intCast(raw);
        if (candidate.ir_view.getTag(node) != .identifier) continue;
        const reference = candidate.ir_view.getBinding(node) orelse continue;
        const imported = candidate.module_facts.importForReference(reference, .module_reference, .builtin) orelse continue;
        if (std.mem.eql(u8, imported.module_specifier, "zttp:core") and
            std.mem.eql(u8, imported.imported_name, export_name)) count += 1;
    }
    return count;
}

fn phaseTwoGrowthBefore(input: SourceInput, offset: u32) ?u32 {
    const authority = originalAuthority(input);
    const nominal_alias = runtimeCoreAlias(authority, "nominal") orelse "nominal";
    var growth: u32 = 0;
    for (input.typed_diagnostics) |diagnostic| {
        if (diagnostic.intent != .wrap_implicit_nominal_initializer or
            !std.mem.eql(u8, diagnostic.code, "ZTS200") or
            diagnostic.initializer_span.start >= offset) continue;
        const target = diagnostic.annotation_span.text(input.typed_source);
        const added = std.math.add(usize, nominal_alias.len, target.len) catch return null;
        growth = std.math.add(u32, growth, @intCast(added + 4)) catch return null;
    }
    return growth;
}

fn finalBrandOriginMatches(input: SourceInput, prefix_len: usize) bool {
    for (input.typed_diagnostics) |diagnostic| {
        if (diagnostic.intent != .wrap_implicit_nominal_initializer or
            !std.mem.eql(u8, diagnostic.code, "ZTS200")) continue;
        if (!std.mem.eql(u8, diagnostic.module_path, input.candidate.module_path)) continue;
        const brand_name = diagnostic.brand_name orelse return false;
        var found = false;
        for (input.candidate.type_store.brand_declarations.items) |brand| {
            if (!std.mem.eql(u8, brand.name_span.text(input.candidate.source), brand_name)) continue;
            const prefix_shift = std.math.add(u32, @intCast(prefix_len), phaseTwoGrowthBefore(input, diagnostic.nominal_declaration_start) orelse return false) catch return false;
            const shifted = std.math.add(u32, diagnostic.nominal_declaration_start, prefix_shift) catch return false;
            if (brand.declaration_start != shifted) return false;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn finalNominalFactsMatch(input: SourceInput, prefix_len: usize) bool {
    const authority = originalAuthority(input);
    const nominal_alias = runtimeCoreAlias(authority, "nominal") orelse "nominal";
    for (input.typed_diagnostics) |diagnostic| {
        if (diagnostic.intent != .wrap_implicit_nominal_initializer or
            !std.mem.eql(u8, diagnostic.code, "ZTS200")) continue;
        const target_name = diagnostic.annotation_span.text(input.typed_source);
        const call_offset = nominal_alias.len + target_name.len + 2;
        const prior_growth = phaseTwoGrowthBefore(input, diagnostic.initializer_span.start) orelse return false;
        const prefix_shift = std.math.add(u32, @intCast(prefix_len), prior_growth) catch return false;
        const initializer_start = std.math.add(u32, diagnostic.initializer_span.start, prefix_shift) catch return false;
        const expected_start = std.math.add(u32, initializer_start, @intCast(call_offset)) catch return false;
        var target_type: ?type_pool.TypeIndex = null;
        for (input.candidate.type_store.nominal_constructors.items) |constructor| {
            const location = input.candidate.ir_view.getLoc(constructor.owner) orelse continue;
            if (location.offset != expected_start) continue;
            target_type = input.candidate.type_env.nominalConstructorType(constructor.owner);
            break;
        }
        const target = target_type orelse return false;
        const origin = input.candidate.type_env.pool.nominalOrigin(target) orelse return false;
        const origin_shift: u32 = if (std.mem.eql(u8, diagnostic.module_path, input.candidate.module_path))
            std.math.add(u32, @intCast(prefix_len), phaseTwoGrowthBefore(input, diagnostic.nominal_declaration_start) orelse return false) catch return false
        else
            0;
        const expected_origin = std.math.add(u32, diagnostic.nominal_declaration_start, origin_shift) catch return false;
        if (!std.mem.eql(u8, origin.module_path, diagnostic.module_path) or
            origin.declaration_start != expected_origin or
            !std.mem.eql(u8, input.candidate.type_env.pool.nominalName(target), diagnostic.nominal_name)) return false;
        if (diagnostic.brand_name) |brand_name| {
            const final_brand = input.candidate.type_env.nominalBrandName(target) orelse return false;
            if (!std.mem.eql(u8, final_brand, brand_name)) return false;
        }
        const base = input.candidate.type_env.pool.unwrapNominal(target);
        const base_matches = switch (diagnostic.base) {
            .string => input.candidate.type_env.pool.getTag(base) == .t_string,
            .number => input.candidate.type_env.pool.getTag(base) == .t_number,
            .boolean => input.candidate.type_env.pool.getTag(base) == .t_boolean,
        };
        if (!base_matches) return false;
    }
    return true;
}

fn validEnvelope(allocator: std.mem.Allocator, original: []const u8, candidate: []const u8, input: SourceInput) !bool {
    if (!std.mem.eql(u8, input.original.source, original) or
        !std.mem.eql(u8, input.original.type_store.source, original) or
        !std.mem.eql(u8, input.candidate.source, candidate) or
        !std.mem.eql(u8, input.candidate.type_store.source, candidate)) return false;

    const phase_one = phaseOneExpected(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(phase_one);
    if (!std.mem.eql(u8, phase_one, input.typed_source)) {
        return false;
    }
    const phase_two = phaseTwoExpected(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(phase_two);
    if (!std.mem.eql(u8, phase_two, candidate)) {
        return false;
    }

    const authority = originalAuthority(input);
    const nominal_prefix_len: usize = if (hasIntent(input, .wrap_implicit_nominal_initializer) and
        runtimeCoreAlias(authority, "nominal") == null)
        "import { nominal } from \"zttp:core\";\n".len
    else
        0;
    if (!finalBrandOriginMatches(input, nominal_prefix_len)) {
        return false;
    }
    if (!finalNominalFactsMatch(input, nominal_prefix_len)) {
        return false;
    }

    const expected_asserts = parsedCoreReferenceCount(authority, "assert") + input.original.asserts.len;
    const expected_matches = parsedCoreReferenceCount(authority, "match") + input.original.matches.len;
    var nominal_additions: usize = 0;
    for (input.typed_diagnostics) |diagnostic| {
        if (diagnostic.intent == .wrap_implicit_nominal_initializer and std.mem.eql(u8, diagnostic.code, "ZTS200")) nominal_additions += 1;
    }
    const expected_nominals = parsedCoreReferenceCount(authority, "nominal") + nominal_additions;
    const needs_runtime_intrinsic = expected_asserts > 0 or expected_matches > 0 or expected_nominals > 0;
    if (needs_runtime_intrinsic and (!input.candidate.type_store.requires_intrinsic_validation or
        !input.candidate.type_store.intrinsics_validated)) return false;
    if (resolvedCoreReferenceCount(input.candidate, "assert") != expected_asserts or
        resolvedCoreReferenceCount(input.candidate, "match") != expected_matches or
        resolvedCoreReferenceCount(input.candidate, "nominal") != expected_nominals)
    {
        return false;
    }
    if (input.candidate.type_store.nominal_constructors.items.len != expected_nominals) {
        return false;
    }
    return true;
}

fn hasIntent(input: SourceInput, intent: RepairIntent) bool {
    return switch (intent) {
        .replace_legacy_declaration => for (input.original.declarations) |declaration| {
            if (std.mem.eql(u8, declaration.keyword_span.text(input.original.source), "structural") or
                std.mem.eql(u8, declaration.keyword_span.text(input.original.source), "nominal")) break true;
        } else false,
        .replace_legacy_assert => input.original.asserts.len > 0,
        .replace_legacy_match => input.original.matches.len > 0,
        .wrap_implicit_nominal_initializer => for (input.typed_diagnostics) |diagnostic| {
            if (diagnostic.intent == .wrap_implicit_nominal_initializer and std.mem.eql(u8, diagnostic.code, "ZTS200")) break true;
        } else false,
        else => false,
    };
}

pub fn validateLegacyDeclarationMigration(allocator: std.mem.Allocator, original: []const u8, candidate: []const u8, input: SourceInput) !Verdict {
    if (!hasIntent(input, .replace_legacy_declaration)) return .{ .refused = "the batch has no legacy declaration migration" };
    return if (try validEnvelope(allocator, original, candidate, input)) .equivalent else .{ .refused = "the declaration migration envelope does not match the source records" };
}

pub fn validateImplicitNominalMigration(allocator: std.mem.Allocator, original: []const u8, candidate: []const u8, input: SourceInput) !Verdict {
    if (!hasIntent(input, .wrap_implicit_nominal_initializer)) return .{ .refused = "the batch has no typed nominal initializer migration" };
    return if (try validEnvelope(allocator, original, candidate, input)) .equivalent else .{ .refused = "the nominal migration envelope does not match ZTS200 evidence" };
}

pub fn validateLegacyMatchMigration(allocator: std.mem.Allocator, original: []const u8, candidate: []const u8, input: SourceInput) !Verdict {
    if (!hasIntent(input, .replace_legacy_match)) return .{ .refused = "the batch has no legacy match migration" };
    return if (try validEnvelope(allocator, original, candidate, input)) .equivalent else .{ .refused = "the match migration envelope does not preserve its arms and snapshots" };
}

pub fn validateLegacyAssertMigration(allocator: std.mem.Allocator, original: []const u8, candidate: []const u8, input: SourceInput) !Verdict {
    if (!hasIntent(input, .replace_legacy_assert)) return .{ .refused = "the batch has no legacy assert migration" };
    return if (try validEnvelope(allocator, original, candidate, input)) .equivalent else .{ .refused = "the assert migration envelope does not preserve its predicate" };
}

pub fn validateAll(
    allocator: std.mem.Allocator,
    requested: RepairIntent,
    original: []const u8,
    candidate: []const u8,
    input: SourceInput,
) !Verdict {
    if (!hasIntent(input, requested)) return .{ .refused = "the requested migration intent is absent from this batch" };
    for ([_]RepairIntent{
        RepairIntent.replace_legacy_declaration,
        RepairIntent.wrap_implicit_nominal_initializer,
        RepairIntent.replace_legacy_match,
        RepairIntent.replace_legacy_assert,
    }) |intent| {
        if (!hasIntent(input, intent)) continue;
        const verdict = switch (intent) {
            .replace_legacy_declaration => try validateLegacyDeclarationMigration(allocator, original, candidate, input),
            .wrap_implicit_nominal_initializer => try validateImplicitNominalMigration(allocator, original, candidate, input),
            .replace_legacy_match => try validateLegacyMatchMigration(allocator, original, candidate, input),
            .replace_legacy_assert => try validateLegacyAssertMigration(allocator, original, candidate, input),
            else => unreachable,
        };
        switch (verdict) {
            .equivalent => {},
            .refused => return verdict,
        }
    }
    return .equivalent;
}
