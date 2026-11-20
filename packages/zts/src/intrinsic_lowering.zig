//! Validation and transparent lowering for compiler-owned intrinsics.

const std = @import("std");
const engine = @import("zts-engine");
const builtin_modules = engine.builtin_modules;
const module_facts_mod = @import("module_facts.zig");
const import_signatures_mod = @import("import_signatures.zig");
const type_checker_mod = @import("type_checker.zig");
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");

const JsParser = engine.parser.JsParser;
const IrView = engine.parser.IrView;
const TypeEnv = type_env_mod.TypeEnv;
const ModuleFacts = module_facts_mod.ModuleFacts;

pub const ValidationIssue = union(enum) {
    value_argument_count: struct { node: engine.parser.NodeIndex, got: usize },
    type_argument_count: struct { node: engine.parser.NodeIndex, got: usize },
    target_constraint: struct {
        node: engine.parser.NodeIndex,
        target: type_pool_mod.TypeIndex,
    },
    base_mismatch: struct {
        node: engine.parser.NodeIndex,
        operand: engine.parser.NodeIndex,
        nominal: type_pool_mod.TypeIndex,
    },
    unsupported_reference: struct { node: engine.parser.NodeIndex },
};

pub const ValidationIssues = std.ArrayListUnmanaged(ValidationIssue);

pub fn validateSource(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
) !void {
    try validateSourceWithImports(allocator, parser, atoms, env, null);
}

pub fn validateSourceWithImports(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
) !void {
    try validateSourceInternal(allocator, parser, atoms, env, file_imports, null);
}

pub fn validateSourceForAnalysis(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
    issues: *ValidationIssues,
) !void {
    try validateSourceInternal(allocator, parser, atoms, env, file_imports, issues);
}

fn validateSourceInternal(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
    issues: ?*ValidationIssues,
) !void {
    var facts = try ModuleFacts.build(
        allocator,
        IrView.fromIRStore(&parser.nodes, &parser.constants),
        atoms,
        null,
    );
    defer facts.deinit();
    try validateAndLowerNominalConstructorsInternal(
        allocator,
        parser,
        atoms,
        env,
        &facts,
        file_imports,
        issues,
    );
}

pub fn validateAndLowerNominalConstructorsForAnalysis(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    facts: *const ModuleFacts,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
    issues: *ValidationIssues,
) !void {
    try validateAndLowerNominalConstructorsInternal(
        allocator,
        parser,
        atoms,
        env,
        facts,
        file_imports,
        issues,
    );
}

fn validateAndLowerNominalConstructorsInternal(
    allocator: std.mem.Allocator,
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    env: *TypeEnv,
    facts: *const ModuleFacts,
    file_imports: ?*const import_signatures_mod.FileImportSignatures,
    issues: ?*ValidationIssues,
) !void {
    if (parser.type_store.intrinsics_validated) return;
    const initial_issue_count = if (issues) |out| out.items.len else 0;
    const checkpoint = parser.type_store.checkpoint();
    errdefer parser.type_store.rollback(checkpoint);
    const handled = try allocator.alloc(bool, parser.nodes.tags.items.len);
    defer allocator.free(handled);
    @memset(handled, false);
    var checker = type_checker_mod.TypeChecker.init(
        allocator,
        IrView.fromIRStore(&parser.nodes, &parser.constants),
        atoms,
        env,
    );
    defer checker.deinit();
    if (file_imports) |imports| try checker.prepareFileImports(imports);

    for (0..parser.nodes.tags.items.len) |raw_owner| {
        const owner: engine.parser.NodeIndex = @intCast(raw_owner);
        const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        if (view.getTag(owner) != .call) continue;
        const call = view.getCall(owner) orelse continue;
        if (view.getTag(call.callee) != .identifier) continue;
        const binding = view.getBinding(call.callee) orelse continue;
        const imported = facts.importForReference(binding, .module_reference, .builtin) orelse continue;
        const intrinsic = builtin_modules.findIntrinsic(
            imported.module_specifier,
            imported.imported_name,
        ) orelse continue;
        if (intrinsic.kind != .nominal) continue;
        if (call.args_count != 1) {
            if (issues) |out| {
                try out.append(allocator, .{ .value_argument_count = .{
                    .node = owner,
                    .got = call.args_count,
                } });
                handled[call.callee] = true;
                continue;
            }
            return error.InvalidNominalConstructor;
        }
        const type_arguments = env.getCallTypeArgsForCall(view, owner) orelse {
            if (issues) |out| {
                try out.append(allocator, .{ .type_argument_count = .{
                    .node = owner,
                    .got = 0,
                } });
                handled[call.callee] = true;
                continue;
            }
            return error.InvalidNominalConstructor;
        };
        if (type_arguments.count != 1) {
            if (issues) |out| {
                try out.append(allocator, .{ .type_argument_count = .{
                    .node = owner,
                    .got = type_arguments.count,
                } });
                handled[call.callee] = true;
                continue;
            }
            return error.InvalidNominalConstructor;
        }
        const nominal = env.resolveRef(type_arguments.args[0]);
        if (!env.pool.isNominal(nominal) or
            env.pool.nominalConstruction(nominal) != .explicit_only)
        {
            if (issues) |out| {
                try out.append(allocator, .{ .target_constraint = .{
                    .node = owner,
                    .target = nominal,
                } });
                handled[call.callee] = true;
                continue;
            }
            return error.InvalidNominalConstructor;
        }
        const operand = view.getListIndex(call.args_start, 0);
        const inferred = checker.inferTypeWithoutDiagnostics(operand);
        const base = env.pool.unwrapNominal(nominal);
        if (base == nominal or env.pool.isNominal(inferred) or !env.isAssignableTo(inferred, base)) {
            if (issues) |out| {
                try out.append(allocator, .{ .base_mismatch = .{
                    .node = owner,
                    .operand = operand,
                    .nominal = nominal,
                } });
            } else {
                return error.InvalidNominalConstructorBase;
            }
        }
        try env.recordNominalConstructor(owner, nominal);
        try parser.type_store.nominal_constructors.append(
            parser.type_store.allocator,
            .{ .owner = owner, .operand = operand },
        );
        handled[call.callee] = true;
        try parser.nodes.lowerCallToTransparent(owner, operand);
    }
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    for (0..view.nodeCount()) |raw| {
        const node: engine.parser.NodeIndex = @intCast(raw);
        if (view.getTag(node) != .identifier) continue;
        const binding = view.getBinding(node) orelse continue;
        const imported = facts.importForReference(binding, .module_reference, .builtin) orelse continue;
        if (builtin_modules.findIntrinsic(imported.module_specifier, imported.imported_name) == null) continue;
        if (handled[node]) continue;
        if (issues) |out| {
            try out.append(allocator, .{ .unsupported_reference = .{ .node = node } });
            continue;
        }
        return error.UnsupportedIntrinsicReference;
    }
    parser.type_store.intrinsics_validated = if (issues) |out|
        out.items.len == initial_issue_count
    else
        true;
}

test "a retained nominal constructor keeps its type in a fresh analysis" {
    const allocator = std.testing.allocator;
    const source =
        "import type { Nominal as N } from \"zttp:core\";\n" ++
        "import { nominal as make } from \"zttp:core\";\n" ++
        "declare const idBrand: unique symbol;\n" ++
        "type Id = N<string, typeof idBrand>;\n" ++
        "function identity<T>(value: T): T { return value; }\n" ++
        "const id = make<Id>(identity<string>(\"x\"));\n";
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();

    var first_pool = type_pool_mod.TypePool.init(allocator);
    defer first_pool.deinit(allocator);
    var first_env = TypeEnv.init(allocator, &first_pool);
    defer first_env.deinit();
    try first_env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants),
        .atoms = &atoms,
        .module_path = "/app/id.ts",
    } });
    try validateSource(allocator, &parser, &atoms, &first_env);

    var second_pool = type_pool_mod.TypePool.init(allocator);
    defer second_pool.deinit(allocator);
    var second_env = TypeEnv.init(allocator, &second_pool);
    defer second_env.deinit();
    const lowered_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    try second_env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = lowered_view,
        .atoms = &atoms,
        .module_path = "/app/id.ts",
    } });
    var wrapper: ?engine.parser.NodeIndex = null;
    for (0..lowered_view.nodeCount()) |raw| {
        const node: engine.parser.NodeIndex = @intCast(raw);
        const unary = lowered_view.getUnary(node) orelse continue;
        if (unary.op == .transparent) wrapper = node;
    }
    var checker = type_checker_mod.TypeChecker.init(allocator, lowered_view, &atoms, &second_env);
    defer checker.deinit();
    const retained = checker.inferTypeWithoutDiagnostics(wrapper orelse return error.TestUnexpectedResult);
    try std.testing.expect(second_pool.isNominal(retained));
    try std.testing.expectEqualStrings("Id", second_pool.nominalName(retained));
    const origin = second_pool.nominalOrigin(retained) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/app/id.ts", origin.module_path);
}

test "a refused nominal constructor cannot generate bytecode after analysis" {
    const allocator = std.testing.allocator;
    const source =
        \\import type { Nominal } from "zttp:core";
        \\import { nominal } from "zttp:core";
        \\declare const idBrand: unique symbol;
        \\type Id = Nominal<string, typeof idBrand>;
        \\const id: Id = nominal<Id>(1);
    ;
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var strings = engine.string.StringTable.init(allocator);
    defer strings.deinit();
    var parser = try engine.parser.Parser.initTyped(allocator, allocator, source, &strings, &atoms);
    defer parser.deinit();
    try std.testing.expect((try parser.parseTypedIr()) == .accepted);
    var pool = type_pool_mod.TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.js_parser.type_store,
        .ir_view = IrView.fromIRStore(&parser.js_parser.nodes, &parser.js_parser.constants),
        .atoms = &atoms,
        .module_path = "/app/refused-id.ts",
    } });
    var issues: ValidationIssues = .empty;
    defer issues.deinit(allocator);
    try validateSourceForAnalysis(allocator, &parser.js_parser, &atoms, &env, null, &issues);
    try std.testing.expectError(error.UnvalidatedIntrinsicSource, parser.generateParsed(allocator));
}
