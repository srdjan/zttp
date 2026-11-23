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
const Node = engine.parser.Node;
const NodeIndex = engine.parser.NodeIndex;
const null_node = engine.parser.null_node;
const TypeEnv = type_env_mod.TypeEnv;
const ModuleFacts = module_facts_mod.ModuleFacts;

const PatternContext = enum { top, record, array };

const Descriptor = enum {
    any,
    present,
    boolean,
    number,
    string,
    array,
    dict,
    bytes,
};

const PendingMatchArm = struct {
    call: NodeIndex,
    pattern: NodeIndex,
    callback: NodeIndex,
    receiver: NodeIndex,
};

fn atomName(atoms: *engine.atom_table.AtomTable, atom: u16) ?[]const u8 {
    const value: engine.object.Atom = @fromBackingInt(@intCast(atom));
    return value.toPredefinedName() orelse atoms.getName(value);
}

fn importedIntrinsicKind(
    view: IrView,
    facts: *const ModuleFacts,
    node: NodeIndex,
) ?engine.module_binding.IntrinsicKind {
    if (view.getTag(node) != .identifier) return null;
    const binding = view.getBinding(node) orelse return null;
    const imported = facts.importForReference(binding, .module_reference, .builtin) orelse return null;
    const intrinsic = builtin_modules.findIntrinsic(
        imported.module_specifier,
        imported.imported_name,
    ) orelse return null;
    return intrinsic.kind;
}

fn isNamePath(view: IrView, node: NodeIndex) bool {
    var current = node;
    while (true) switch (view.getTag(current) orelse return false) {
        .identifier => return true,
        .member_access => current = (view.getMember(current) orelse return false).object,
        else => return false,
    };
}

fn callbackIsSupported(view: IrView, node: NodeIndex) bool {
    if (view.getTag(node) != .arrow_function) return false;
    const callback = view.getFunction(node) orelse return false;
    if (callback.params_count > 1) return false;
    if (callback.params_count == 0) return true;
    const param = view.getListIndex(callback.params_start, 0);
    if (view.getTag(param) != .pattern_element) return false;
    const element = view.getPatternElem(param) orelse return false;
    return element.kind == .simple and
        element.key == null_node and
        element.default_value == null_node;
}

fn markIntrinsicReferences(
    view: IrView,
    facts: *const ModuleFacts,
    handled: []bool,
    node: NodeIndex,
    depth: usize,
) void {
    if (depth > handled.len or node >= handled.len) return;
    if (view.getTag(node) == .identifier and importedIntrinsicKind(view, facts, node) != null) {
        handled[node] = true;
    }
    var children = view.expressionChildren(node);
    while (children.next()) |child| {
        markIntrinsicReferences(view, facts, handled, child, depth + 1);
    }
}

fn retireMatchChainForDiagnostics(
    parser: *JsParser,
    view: IrView,
    owner: NodeIndex,
    base: NodeIndex,
    base_call: Node.CallExpr,
    arms: []const PendingMatchArm,
) !void {
    if (base_call.args_count != 1) return;
    const subject = view.getListIndex(base_call.args_start, 0);
    try parser.nodes.lowerCallToTransparent(base, subject);
    for (arms) |pending| {
        if (view.getTag(pending.call) == .call) {
            try parser.nodes.lowerCallToTransparent(pending.call, pending.receiver);
        }
    }
    if (view.getTag(owner) == .call) try parser.nodes.lowerCallToTransparent(owner, subject);
}

fn descriptorAt(
    view: IrView,
    atoms: *engine.atom_table.AtomTable,
    facts: *const ModuleFacts,
    handled: []bool,
    node: NodeIndex,
) ?Descriptor {
    if (view.getTag(node) != .member_access) return null;
    const member = view.getMember(node) orelse return null;
    if (view.getTag(member.object) != .identifier) return null;
    if (importedIntrinsicKind(view, facts, member.object) != .pattern_namespace) return null;
    if (member.object < handled.len) handled[member.object] = true;
    const name = atomName(atoms, member.property) orelse return null;
    inline for (std.enums.values(Descriptor)) |descriptor| {
        const source_name = switch (descriptor) {
            .dict => "Dict",
            .bytes => "Bytes",
            else => @tagName(descriptor),
        };
        if (std.mem.eql(u8, name, source_name)) return descriptor;
    }
    return null;
}

fn addGlobalReference(
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    loc: engine.parser.SourceLocation,
    name: []const u8,
) !NodeIndex {
    const atom = try atoms.intern(name);
    const atom_index: u16 = @truncate(@backingInt(atom));
    return parser.nodes.addIdentifier(loc, .{
        .scope_id = 0,
        .slot = atom_index,
        .name_atom = atom_index,
        .kind = .undeclared_global,
    });
}

fn addTypeTestPredicate(
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    loc: engine.parser.SourceLocation,
    subject: NodeIndex,
    kind: Node.TypeTestKind,
) !NodeIndex {
    switch (kind) {
        .boolean, .number, .string => {
            const typeof_node = try parser.nodes.addUnary(loc, .{ .op = .typeof_op, .operand = subject });
            const string_index = try parser.constants.addString(@tagName(kind));
            const literal = try parser.nodes.addString(loc, string_index);
            return parser.nodes.addBinary(loc, .{ .op = .strict_eq, .left = typeof_node, .right = literal });
        },
        .array => {
            const array_ref = try addGlobalReference(parser, atoms, loc, "Array");
            const method = try atoms.intern("isArray");
            const callee = try parser.nodes.addMember(.member_access, loc, .{
                .object = array_ref,
                .property = @truncate(@backingInt(method)),
                .computed = null_node,
                .is_optional = false,
            });
            const args = try parser.nodes.addIndexList(&.{subject});
            return parser.nodes.addCall(.call, loc, .{ .callee = callee, .args_start = args, .args_count = 1 });
        },
        .dict, .bytes => {
            const callee = try addGlobalReference(
                parser,
                atoms,
                loc,
                if (kind == .dict) "isDict" else "isBytes",
            );
            const args = try parser.nodes.addIndexList(&.{subject});
            return parser.nodes.addCall(.call, loc, .{ .callee = callee, .args_start = args, .args_count = 1 });
        },
    }
}

fn lowerPattern(
    parser: *JsParser,
    atoms: *engine.atom_table.AtomTable,
    facts: *const ModuleFacts,
    handled: []bool,
    subject: NodeIndex,
    node: NodeIndex,
    context: PatternContext,
    depth: usize,
) !NodeIndex {
    if (depth > handled.len) return error.InvalidMatchPattern;
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    if (descriptorAt(view, atoms, facts, handled, node)) |descriptor| {
        return switch (descriptor) {
            .any => if (context == .array) null_node else error.InvalidMatchPattern,
            .present => if (context == .record) null_node else error.InvalidMatchPattern,
            .boolean, .number, .string, .array, .dict, .bytes => if (context != .top)
                error.InvalidMatchPattern
            else blk: {
                const kind: Node.TypeTestKind = switch (descriptor) {
                    .boolean => .boolean,
                    .number => .number,
                    .string => .string,
                    .array => .array,
                    .dict => .dict,
                    .bytes => .bytes,
                    .any, .present => unreachable,
                };
                const loc = view.getLoc(node) orelse return error.InvalidMatchPattern;
                const predicate = try addTypeTestPredicate(parser, atoms, loc, subject, kind);
                break :blk try parser.nodes.addMatchTypeTest(loc, .{ .kind = kind, .predicate = predicate });
            },
        };
    }
    const tag = view.getTag(node) orelse return error.InvalidMatchPattern;
    switch (tag) {
        .lit_int, .lit_float, .lit_string, .lit_bool, .lit_null, .lit_undefined => return node,
        .object_literal => {
            const object = view.getObject(node) orelse return error.InvalidMatchPattern;
            if (object.properties_count > std.math.maxInt(u8)) return error.InvalidMatchPattern;
            var properties: [std.math.maxInt(u8)]NodeIndex = undefined;
            for (0..object.properties_count) |index| {
                const property_node = view.getListIndex(object.properties_start, @intCast(index));
                if (view.getTag(property_node) != .object_property) return error.InvalidMatchPattern;
                const property = view.getProperty(property_node) orelse return error.InvalidMatchPattern;
                const value = try lowerPattern(
                    parser,
                    atoms,
                    facts,
                    handled,
                    subject,
                    property.value,
                    .record,
                    depth + 1,
                );
                const loc = view.getLoc(property_node) orelse return error.InvalidMatchPattern;
                properties[index] = try parser.nodes.addProperty(loc, .{
                    .key = property.key,
                    .value = value,
                    .is_shorthand = false,
                });
            }
            const start = if (object.properties_count == 0)
                null_node
            else
                try parser.nodes.addIndexList(properties[0..object.properties_count]);
            const loc = view.getLoc(node) orelse return error.InvalidMatchPattern;
            return parser.nodes.addMatchPattern(loc, .{
                .props_start = start,
                .props_count = @intCast(object.properties_count),
            });
        },
        .array_literal => {
            const array = view.getArray(node) orelse return error.InvalidMatchPattern;
            if (array.has_spread or array.elements_count > std.math.maxInt(u8)) return error.InvalidMatchPattern;
            const elements = try parser.nodes.allocator.alloc(NodeIndex, array.elements_count);
            defer parser.nodes.allocator.free(elements);
            for (0..array.elements_count) |index| {
                elements[index] = try lowerPattern(
                    parser,
                    atoms,
                    facts,
                    handled,
                    subject,
                    view.getListIndex(array.elements_start, @intCast(index)),
                    .array,
                    depth + 1,
                );
            }
            const start = try parser.nodes.addIndexList(elements);
            const loc = view.getLoc(node) orelse return error.InvalidMatchPattern;
            return parser.nodes.addArray(.array_pattern, loc, .{
                .elements_start = start,
                .elements_count = array.elements_count,
                .has_spread = false,
            });
        },
        else => return error.InvalidMatchPattern,
    }
}

pub const ValidationIssue = union(enum) {
    value_argument_count: struct { node: engine.parser.NodeIndex, got: usize },
    type_argument_count: struct {
        node: engine.parser.NodeIndex,
        expected: usize,
        got: usize,
    },
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
    const original_node_count = parser.nodes.tags.items.len;
    const initial_issue_count = if (issues) |out| out.items.len else 0;
    const checkpoint = parser.type_store.checkpoint();
    errdefer parser.type_store.rollback(checkpoint);
    const handled = try allocator.alloc(bool, original_node_count);
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

    for (0..original_node_count) |raw_statement| {
        const statement: engine.parser.NodeIndex = @intCast(raw_statement);
        const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        if (view.getTag(statement) != .expr_stmt) continue;
        const owner = view.getOptValue(statement) orelse continue;
        if (view.getTag(owner) != .call) continue;
        const call = view.getCall(owner) orelse continue;
        if (view.getTag(call.callee) != .identifier) continue;
        const binding = view.getBinding(call.callee) orelse continue;
        const imported = facts.importForReference(binding, .module_reference, .builtin) orelse continue;
        const intrinsic = builtin_modules.findIntrinsic(
            imported.module_specifier,
            imported.imported_name,
        ) orelse continue;
        if (intrinsic.kind != .assert) continue;
        handled[call.callee] = true;
        if (call.args_count != 1) {
            if (issues) |out| {
                try out.append(allocator, .{ .value_argument_count = .{
                    .node = owner,
                    .got = call.args_count,
                } });
                continue;
            }
            return error.InvalidAssertionCall;
        }
        if (env.getCallTypeArgsForCall(view, owner)) |type_arguments| {
            if (type_arguments.count != 0) {
                if (issues) |out| {
                    try out.append(allocator, .{ .type_argument_count = .{
                        .node = owner,
                        .expected = 0,
                        .got = type_arguments.count,
                    } });
                    continue;
                }
                return error.InvalidAssertionCall;
            }
        }
        const condition = view.getListIndex(call.args_start, 0);
        try parser.nodes.lowerCallStatementToAssert(statement, owner, condition);
    }

    for (0..original_node_count) |raw_owner| {
        const owner: NodeIndex = @intCast(raw_owner);
        const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        if (view.getTag(owner) != .call) continue;
        const terminal_call = view.getCall(owner) orelse continue;
        if (view.getTag(terminal_call.callee) != .member_access) continue;
        const terminal_member = view.getMember(terminal_call.callee) orelse continue;
        const terminal_name = atomName(atoms, terminal_member.property) orelse continue;
        const is_exhaustive = std.mem.eql(u8, terminal_name, "exhaustive");
        const is_otherwise = std.mem.eql(u8, terminal_name, "otherwise");
        if (!is_exhaustive and !is_otherwise) continue;

        var reversed: [std.math.maxInt(u8)]PendingMatchArm = undefined;
        var arm_count: usize = 0;
        var cursor = terminal_member.object;
        var chain_shape_valid = true;
        while (view.getTag(cursor) == .call) {
            const with_call = view.getCall(cursor) orelse {
                chain_shape_valid = false;
                break;
            };
            if (view.getTag(with_call.callee) != .member_access) break;
            const with_member = view.getMember(with_call.callee) orelse {
                chain_shape_valid = false;
                break;
            };
            const with_name = atomName(atoms, with_member.property) orelse break;
            if (!std.mem.eql(u8, with_name, "with")) break;
            if (arm_count == reversed.len) {
                chain_shape_valid = false;
                break;
            }
            reversed[arm_count] = .{
                .call = cursor,
                .pattern = if (with_call.args_count > 0)
                    view.getListIndex(with_call.args_start, 0)
                else
                    null_node,
                .callback = if (with_call.args_count > 1)
                    view.getListIndex(with_call.args_start, 1)
                else
                    null_node,
                .receiver = with_member.object,
            };
            arm_count += 1;
            cursor = with_member.object;
        }

        if (view.getTag(cursor) != .call) continue;
        const base_call = view.getCall(cursor) orelse continue;
        if (view.getTag(base_call.callee) != .identifier) continue;
        if (importedIntrinsicKind(view, facts, base_call.callee) != .match) continue;
        handled[base_call.callee] = true;

        var valid = chain_shape_valid;
        valid = valid and base_call.args_count == 1;
        valid = valid and (if (env.getCallTypeArgsForCall(view, cursor)) |args| args.count == 0 else true);
        valid = valid and isNamePath(
            view,
            if (base_call.args_count == 1) view.getListIndex(base_call.args_start, 0) else null_node,
        );
        valid = valid and (if (env.getCallTypeArgsForCall(view, owner)) |args| args.count == 0 else true);
        valid = valid and if (is_exhaustive)
            terminal_call.args_count == 0 and arm_count != 0
        else
            terminal_call.args_count == 1 and callbackIsSupported(
                view,
                if (terminal_call.args_count == 1)
                    view.getListIndex(terminal_call.args_start, 0)
                else
                    null_node,
            );
        if (is_otherwise and arm_count == reversed.len) valid = false;
        for (reversed[0..arm_count]) |pending| {
            const pending_call = view.getCall(pending.call) orelse {
                valid = false;
                continue;
            };
            valid = valid and pending_call.args_count == 2;
            valid = valid and callbackIsSupported(view, pending.callback);
            valid = valid and (if (env.getCallTypeArgsForCall(view, pending.call)) |args| args.count == 0 else true);
        }
        if (!valid) {
            if (issues) |out| {
                for (reversed[0..arm_count]) |pending| {
                    markIntrinsicReferences(view, facts, handled, pending.pattern, 0);
                }
                try out.append(allocator, .{ .unsupported_reference = .{ .node = owner } });
                try retireMatchChainForDiagnostics(parser, view, owner, cursor, base_call, reversed[0..arm_count]);
                continue;
            }
            return error.InvalidMatchIntrinsic;
        }

        const subject = view.getListIndex(base_call.args_start, 0);
        const lowered_count = arm_count + @intFromBool(is_otherwise);
        var lowered_arms: [std.math.maxInt(u8)]NodeIndex = undefined;
        for (0..arm_count) |forward_index| {
            const pending = reversed[arm_count - forward_index - 1];
            const pattern = lowerPattern(
                parser,
                atoms,
                facts,
                handled,
                subject,
                pending.pattern,
                .top,
                0,
            ) catch |err| switch (err) {
                error.InvalidMatchPattern => {
                    if (issues) |out| {
                        try out.append(allocator, .{ .unsupported_reference = .{ .node = pending.pattern } });
                        valid = false;
                        break;
                    }
                    return error.InvalidMatchPattern;
                },
                else => return err,
            };
            const loc = view.getLoc(pending.call) orelse return error.InvalidMatchIntrinsic;
            lowered_arms[forward_index] = try parser.nodes.addMatchArm(loc, .{
                .pattern = pattern,
                .body = pending.callback,
                .kind = .callback,
            });
        }
        if (!valid) {
            try retireMatchChainForDiagnostics(parser, view, owner, cursor, base_call, reversed[0..arm_count]);
            continue;
        }
        if (is_otherwise) {
            const callback = view.getListIndex(terminal_call.args_start, 0);
            const loc = view.getLoc(owner) orelse return error.InvalidMatchIntrinsic;
            lowered_arms[arm_count] = try parser.nodes.addMatchArm(loc, .{
                .pattern = null_node,
                .body = callback,
                .kind = .callback,
            });
        }
        const arms_start = try parser.nodes.addIndexList(lowered_arms[0..lowered_count]);
        try parser.nodes.lowerCallToTransparent(cursor, subject);
        for (reversed[0..arm_count]) |pending| {
            try parser.nodes.lowerCallToTransparent(pending.call, pending.receiver);
        }
        try parser.nodes.lowerCallToMatch(owner, .{
            .discriminant = subject,
            .arms_start = arms_start,
            .arms_count = @intCast(lowered_count),
        });
    }

    for (0..original_node_count) |raw_owner| {
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
                    .expected = 1,
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
                    .expected = 1,
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
    for (0..original_node_count) |raw| {
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

test "a foreign match-like chain is not a compiler intrinsic" {
    const allocator = std.testing.allocator;
    const source =
        "import { select } from \"./foreign.ts\";\n" ++
        "const value = select().otherwise();\n";
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    var pool = type_pool_mod.TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants),
        .atoms = &atoms,
        .module_path = "/app/main.ts",
    } });
    try validateSource(allocator, &parser, &atoms, &env);
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

fn prepareMatchTestBytecode(
    parser: *engine.parser.Parser,
    allocator: std.mem.Allocator,
    atoms: *engine.atom_table.AtomTable,
) ![]const u8 {
    try std.testing.expect((try parser.parseTypedIr()) == .accepted);
    try validateMatchTestSource(parser, allocator, atoms);
    return parser.generateParsed(allocator);
}

fn validateMatchTestSource(
    parser: *engine.parser.Parser,
    allocator: std.mem.Allocator,
    atoms: *engine.atom_table.AtomTable,
) !void {
    var pool = type_pool_mod.TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.js_parser.type_store,
        .ir_view = IrView.fromIRStore(&parser.js_parser.nodes, &parser.js_parser.constants),
        .atoms = atoms,
        .module_path = "fluent-match-test.ts",
    } });
    try validateSource(allocator, &parser.js_parser, atoms, &env);
}

test "End-to-end: a match evaluates exactly one arm" {
    // Spec 5.5 admits effectful arm expressions and says exactly one arm's
    // expression is evaluated. The property is a consequence of how the arms
    // are laid out - one labelled body per arm, each jumping to the end - so
    // this pins it by observing an effect rather than by reading the emitter.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var gc_state = try engine.gc.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();

    var ctx = try engine.context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    var strings = engine.string.StringTable.init(allocator);
    defer strings.deinit();

    const source =
        \\import { match } from "zttp:core";
        \\let firstCalls = 0;
        \\let secondCalls = 0;
        \\function first() { firstCalls = firstCalls + 1; return 1; }
        \\function second() { secondCalls = secondCalls + 1; return 2; }
        \\let tag = "b";
        \\let picked = match(tag).with("a", () => first()).with("b", () => second()).exhaustive();
        \\let result = firstCalls * 100 + secondCalls * 10 + picked;
    ;

    var p = try engine.parser.Parser.initTyped(allocator, allocator, source, &strings, &ctx.atoms);
    defer p.deinit();

    const code = try prepareMatchTestBytecode(&p, allocator, &ctx.atoms);
    try std.testing.expect(code.len > 0);

    const shapes = p.getShapes();
    if (shapes.len > 0) {
        try ctx.materializeShapes(shapes);
    }

    var func = engine.bytecode.FunctionBytecode{
        .header = .{},
        .name_atom = 0,
        .arg_count = 0,
        .local_count = p.max_local_count,
        .stack_size = 256,
        .flags = .{},
        .code = code,
        .constants = p.constants.items,
        .source_map = null,
        .line_table = null,
    };

    var interp = engine.interpreter.Interpreter.init(ctx);
    _ = try interp.run(&func);

    const result_atom = try ctx.atoms.intern("result");
    const result_val = ctx.getGlobal(result_atom) orelse return error.MissingResult;
    try std.testing.expect(result_val.isInt());
    // The selected arm ran once and the other never ran: 0*100 + 1*10 + 2.
    // Evaluating both arms would give 112.
    try std.testing.expectEqual(@as(i32, 12), result_val.getInt());
}

/// Compile `source`, run it with the builtins installed, and hand the context
/// to `check`, which reads the globals the program left behind. Match tests
/// need the builtins because a record or array pattern lowers to a call.
fn runMatchProgram(source: []const u8, comptime check: fn (*engine.context.Context) anyerror!void) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var gc_state = try engine.gc.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();

    var ctx = try engine.context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();
    try engine.builtins.initBuiltins(ctx);

    var strings = engine.string.StringTable.init(allocator);
    defer strings.deinit();

    var p = try engine.parser.Parser.initTyped(allocator, allocator, source, &strings, &ctx.atoms);
    defer p.deinit();

    const code = try prepareMatchTestBytecode(&p, allocator, &ctx.atoms);
    try std.testing.expect(code.len > 0);

    const shapes = p.getShapes();
    if (shapes.len > 0) {
        try ctx.materializeShapes(shapes);
    }

    var func = engine.bytecode.FunctionBytecode{
        .header = .{},
        .name_atom = 0,
        .arg_count = 0,
        .local_count = p.max_local_count,
        .stack_size = 256,
        .flags = .{},
        .code = code,
        .constants = p.constants.items,
        .source_map = null,
        .line_table = null,
    };

    var interp = engine.interpreter.Interpreter.init(ctx);
    _ = try interp.run(&func);
    try check(ctx);
}

fn expectGlobalString(ctx: *engine.context.Context, name: []const u8, expected: []const u8) !void {
    const atom = try ctx.atoms.intern(name);
    const val = ctx.getGlobal(atom) orelse return error.MissingResult;
    try std.testing.expect(val.isString());
    try std.testing.expectEqualStrings(expected, val.toPtr(engine.string.JSString).data());
}

test "End-to-end: a fluent match callback reads fields at each depth of the selected pattern" {
    const source =
        \\import { match } from "zttp:core";
        \\let nested = { a: { b: "deep" } };
        \\let r1 = match(nested).with({ a: {} }, (selected) => selected.a.b).otherwise(() => "none");
        \\let boxed = { kind: "box", inner: { v: "seven" } };
        \\let r2 = match(boxed).with({ kind: "box", inner: {} }, (selected) => selected.inner.v).otherwise(() => "none");
        \\let arr = [{ n: "first" }];
        \\let r3 = match(arr).with([{}], (selected) => selected[0].n).otherwise(() => "none");
        \\let three = { a: { b: { c: "c3" } } };
        \\let r4 = match(three).with({ a: { b: {} } }, (selected) => selected.a.b.c).otherwise(() => "none");
        \\let mixed = { items: [{ id: "i1" }] };
        \\let r5 = match(mixed).with({ items: [{}] }, (selected) => selected.items[0].id).otherwise(() => "none");
    ;
    try runMatchProgram(source, struct {
        fn check(ctx: *engine.context.Context) anyerror!void {
            try expectGlobalString(ctx, "r1", "deep");
            try expectGlobalString(ctx, "r2", "seven");
            try expectGlobalString(ctx, "r3", "first");
            try expectGlobalString(ctx, "r4", "c3");
            try expectGlobalString(ctx, "r5", "i1");
        }
    }.check);
}

test "End-to-end: a nested empty array or record pattern is still a test" {
    // Spec 5.5: a nested `[]` matches an array of length 0 and a nested `{}`
    // matches a record. Codegen must not drop either test, or the arm would
    // match whatever the field held, present or not.
    const source =
        \\import { match } from "zttp:core";
        \\let full = { v: [1, 2] };
        \\let empty = { v: [] };
        \\let absent = {};
        \\let e1 = match(full).with({ v: [] }, () => "empty").otherwise(() => "other");
        \\let e2 = match(empty).with({ v: [] }, () => "empty").otherwise(() => "other");
        \\let e3 = match(absent).with({ v: [] }, () => "empty").otherwise(() => "other");
        \\let inner = [[1]];
        \\let e4 = match(inner).with([[]], () => "empty").otherwise(() => "other");
        \\let rec = { w: { k: 1 } };
        \\let r1 = match(rec).with({ w: {} }, () => "record").otherwise(() => "other");
        \\let r2 = match(absent).with({ w: {} }, () => "record").otherwise(() => "other");
    ;
    try runMatchProgram(source, struct {
        fn check(ctx: *engine.context.Context) anyerror!void {
            try expectGlobalString(ctx, "e1", "other");
            try expectGlobalString(ctx, "e2", "empty");
            try expectGlobalString(ctx, "e3", "other");
            try expectGlobalString(ctx, "e4", "other");
            try expectGlobalString(ctx, "r1", "record");
            try expectGlobalString(ctx, "r2", "other");
        }
    }.check);
}

test "End-to-end: a record pattern matches only a record, at every depth" {
    const source =
        \\import { match, P } from "zttp:core";
        \\let str = "s";
        \\let num = 5;
        \\let arr = [1];
        \\let nothing = null;
        \\let rec = { w: 1 };
        \\let empty = {};
        \\let lengthy = { length: 3 };
        \\function one() { return 1; }
        \\let fun = one;
        \\let t1 = match(str).with({}, () => "record").otherwise(() => "other");
        \\let t2 = match(rec).with({}, () => "record").otherwise(() => "other");
        \\let t3 = match(arr).with({}, () => "record").otherwise(() => "other");
        \\let t4 = match(num).with({}, () => "record").otherwise(() => "other");
        \\let t5 = match(empty).with({}, () => "record").otherwise(() => "other");
        \\let t6 = match(nothing).with({}, () => "record").otherwise(() => "other");
        \\let t7 = match(lengthy).with({}, () => "record").otherwise(() => "other");
        \\let t8 = match(fun).with({}, () => "record").otherwise(() => "other");
        \\let t9 = match(arr).with({}, () => "record").otherwise(() => "other");
        \\let outer_str = { a: "str" };
        \\let outer_rec = { a: { b: 1 } };
        \\let outer_arr = { a: [1] };
        \\let n1 = match(outer_str).with({ a: {} }, () => "record").otherwise(() => "other");
        \\let n2 = match(outer_rec).with({ a: {} }, () => "record").otherwise(() => "other");
        \\let n3 = match(outer_str).with({ a: {} }, () => "record").otherwise(() => "other");
        \\let n4 = match(outer_arr).with({ a: {} }, () => "record").otherwise(() => "other");
        \\let n5 = match(outer_rec).with({ a: {} }, () => "record").otherwise(() => "other");
        \\let strs = ["s"];
        \\let n6 = match(strs).with([{}], () => "record").otherwise(() => "other");
        \\let recs = [{ n: 1 }];
        \\let n7 = match(recs).with([{}], () => "record").otherwise(() => "other");
        \\let empty_str = { v: "" };
        \\let empty_lengthy = { v: { length: 0 } };
        \\let a1 = match(empty_str).with({ v: [] }, () => "empty").otherwise(() => "other");
        \\let a2 = match(empty_lengthy).with({ v: [] }, () => "empty").otherwise(() => "other");
        \\let empty_text = "";
        \\let a3 = match(empty_text).with([], () => "empty").otherwise(() => "other");
        \\let empty_arr = [];
        \\let a4 = match(empty_arr).with([], () => "empty").otherwise(() => "other");
        \\let empty_field = { v: [] };
        \\let a5 = match(empty_field).with({ v: [] }, () => "empty").otherwise(() => "other");
        \\let a6 = match(lengthy).with([P.any, P.any, P.any], () => "array").otherwise(() => "other");
        \\let abc = "abc";
        \\let a7 = match(abc).with([P.any, P.any, P.any], () => "array").otherwise(() => "other");
        \\let three = [1, 2, 3];
        \\let a8 = match(three).with([P.any, P.any, P.any], () => "array").otherwise(() => "other");
    ;
    try runMatchProgram(source, struct {
        fn check(ctx: *engine.context.Context) anyerror!void {
            try expectGlobalString(ctx, "t1", "other");
            try expectGlobalString(ctx, "t2", "record");
            try expectGlobalString(ctx, "t3", "other");
            try expectGlobalString(ctx, "t4", "other");
            try expectGlobalString(ctx, "t5", "record");
            try expectGlobalString(ctx, "t6", "other");
            try expectGlobalString(ctx, "t7", "record");
            try expectGlobalString(ctx, "t8", "other");
            try expectGlobalString(ctx, "t9", "other");
            try expectGlobalString(ctx, "n1", "other");
            try expectGlobalString(ctx, "n2", "record");
            try expectGlobalString(ctx, "n3", "other");
            try expectGlobalString(ctx, "n4", "other");
            try expectGlobalString(ctx, "n5", "record");
            try expectGlobalString(ctx, "n6", "other");
            try expectGlobalString(ctx, "n7", "record");
            try expectGlobalString(ctx, "a1", "other");
            try expectGlobalString(ctx, "a2", "other");
            try expectGlobalString(ctx, "a3", "other");
            try expectGlobalString(ctx, "a4", "empty");
            try expectGlobalString(ctx, "a5", "empty");
            try expectGlobalString(ctx, "a6", "other");
            try expectGlobalString(ctx, "a7", "other");
            try expectGlobalString(ctx, "a8", "array");
        }
    }.check);
}

test "End-to-end: a fluent presence descriptor checks for a defined field value" {
    // Spec 5.5, and the model `match_analysis.zig` uses: a field `_` fails on
    // `undefined` and matches every other value, `null` included; a field
    const source =
        \\import { match, P } from "zttp:core";
        \\let present = { a: 1 };
        \\let nulled = { a: null };
        \\let absent = { b: 1 };
        \\let undef = { a: undefined };
        \\let u1 = match(present).with({ a: P.present }, () => "present").otherwise(() => "other");
        \\let u2 = match(nulled).with({ a: P.present }, () => "present").otherwise(() => "other");
        \\let u3 = match(absent).with({ a: P.present }, () => "present").otherwise(() => "other");
        \\let u4 = match(undef).with({ a: P.present }, () => "present").otherwise(() => "other");
        \\let b1 = match(absent).with({}, () => "bound").otherwise(() => "other");
        \\let b2 = match(undef).with({}, () => "bound").otherwise(() => "other");
        \\let wild_a = [undefined, 2];
        \\let wild_b = [1, 3];
        \\let w1 = match(wild_a).with([P.any, 2], () => "wild").otherwise(() => "other");
        \\let w2 = match(wild_b).with([P.any, 2], () => "wild").otherwise(() => "other");
    ;
    try runMatchProgram(source, struct {
        fn check(ctx: *engine.context.Context) anyerror!void {
            try expectGlobalString(ctx, "u1", "present");
            try expectGlobalString(ctx, "u2", "present");
            try expectGlobalString(ctx, "u3", "other");
            try expectGlobalString(ctx, "u4", "other");
            try expectGlobalString(ctx, "b1", "bound");
            try expectGlobalString(ctx, "b2", "bound");
            try expectGlobalString(ctx, "w1", "wild");
            try expectGlobalString(ctx, "w2", "other");
        }
    }.check);
}

// The tests below are the soundness check for `match_analysis.zig`. Each one
// writes the arms of a match the analysis accepts without a `default` (the
// corpus cases under `tests/corpus/check/good` carry the same arms), runs every
// value of the matched type through it, and reads each result as a string. A
// result of `undefined` would mean the model called a match exhaustive that the
// runtime lets fall through.

test "End-to-end: split coverage over record fields reaches an arm for every value" {
    const source =
        \\import { match } from "zttp:core";
        \\let f1 = { x: true, y: true };
        \\let f2 = { x: true, y: false };
        \\let f3 = { x: false, y: true };
        \\let f4 = { x: false, y: false };
        \\let s1 = match(f1).with({ x: true, y: true }, () => "both").with({ x: true, y: false }, () => "x only").with({ x: false }, () => "no x").exhaustive();
        \\let s2 = match(f2).with({ x: true, y: true }, () => "both").with({ x: true, y: false }, () => "x only").with({ x: false }, () => "no x").exhaustive();
        \\let s3 = match(f3).with({ x: true, y: true }, () => "both").with({ x: true, y: false }, () => "x only").with({ x: false }, () => "no x").exhaustive();
        \\let s4 = match(f4).with({ x: true, y: true }, () => "both").with({ x: true, y: false }, () => "x only").with({ x: false }, () => "no x").exhaustive();
        \\let n1 = { k: "x", inner: { t: "p" } };
        \\let n2 = { k: "x", inner: { t: "q" } };
        \\let n3 = { k: "y" };
        \\let d1 = match(n1).with({ k: "x", inner: { t: "p" } }, () => "x-p").with({ k: "x", inner: { t: "q" } }, () => "x-q").with({ k: "y" }, () => "y").exhaustive();
        \\let d2 = match(n2).with({ k: "x", inner: { t: "p" } }, () => "x-p").with({ k: "x", inner: { t: "q" } }, () => "x-q").with({ k: "y" }, () => "y").exhaustive();
        \\let d3 = match(n3).with({ k: "x", inner: { t: "p" } }, () => "x-p").with({ k: "x", inner: { t: "q" } }, () => "x-q").with({ k: "y" }, () => "y").exhaustive();
        \\let c1 = { kind: "a", n: 1 };
        \\let c2 = { kind: "b" };
        \\let c3 = { kind: "c", t: "s" };
        \\let k1 = match(c1).with({ kind: "a" }, () => "a").with({ kind: "b" }, () => "b").with({ kind: "c" }, () => "c").exhaustive();
        \\let k2 = match(c2).with({ kind: "a" }, () => "a").with({ kind: "b" }, () => "b").with({ kind: "c" }, () => "c").exhaustive();
        \\let k3 = match(c3).with({ kind: "a" }, () => "a").with({ kind: "b" }, () => "b").with({ kind: "c" }, () => "c").exhaustive();
    ;
    try runMatchProgram(source, struct {
        fn check(ctx: *engine.context.Context) anyerror!void {
            try expectGlobalString(ctx, "s1", "both");
            try expectGlobalString(ctx, "s2", "x only");
            try expectGlobalString(ctx, "s3", "no x");
            try expectGlobalString(ctx, "s4", "no x");
            try expectGlobalString(ctx, "d1", "x-p");
            try expectGlobalString(ctx, "d2", "x-q");
            try expectGlobalString(ctx, "d3", "y");
            try expectGlobalString(ctx, "k1", "a");
            try expectGlobalString(ctx, "k2", "b");
            try expectGlobalString(ctx, "k3", "c");
        }
    }.check);
}

test "End-to-end: optional fields, tuples, and arrays reach an arm for every value" {
    // `{ a?: string }` has three runtime shapes: the field holds a string, holds
    const source =
        \\import { match, P } from "zttp:core";
        \\let o1 = { a: "x" };
        \\let o2 = { a: "z" };
        \\let o3 = {};
        \\let o4 = { a: undefined };
        \\let b1 = match(o1).with({ a: "x" }, () => "x").with({}, () => "other").exhaustive();
        \\let b2 = match(o2).with({ a: "x" }, () => "x").with({}, () => "other").exhaustive();
        \\let b3 = match(o3).with({ a: "x" }, () => "x").with({}, () => "other").exhaustive();
        \\let b4 = match(o4).with({ a: "x" }, () => "x").with({}, () => "other").exhaustive();
        \\let u1 = match(o1).with({ a: undefined }, () => "absent").with({ a: P.present }, () => "present").exhaustive();
        \\let u2 = match(o3).with({ a: undefined }, () => "absent").with({ a: P.present }, () => "present").exhaustive();
        \\let u3 = match(o4).with({ a: undefined }, () => "absent").with({ a: P.present }, () => "present").exhaustive();
        \\let t1 = [true, "p"];
        \\let t2 = [true, "q"];
        \\let t3 = [false, "p"];
        \\let t4 = [false, "q"];
        \\let p1 = match(t1).with([true, "p"], () => "true-p").with([true, "q"], () => "true-q").with([false, P.any], () => "false").exhaustive();
        \\let p2 = match(t2).with([true, "p"], () => "true-p").with([true, "q"], () => "true-q").with([false, P.any], () => "false").exhaustive();
        \\let p3 = match(t3).with([true, "p"], () => "true-p").with([true, "q"], () => "true-q").with([false, P.any], () => "false").exhaustive();
        \\let p4 = match(t4).with([true, "p"], () => "true-p").with([true, "q"], () => "true-q").with([false, P.any], () => "false").exhaustive();
        \\let e1 = [];
        \\let e2 = [1, 2, 3];
        \\let a1 = match(e1).with([], () => "empty").with(P.array, () => "some").exhaustive();
        \\let a2 = match(e2).with([], () => "empty").with(P.array, () => "some").exhaustive();
    ;
    try runMatchProgram(source, struct {
        fn check(ctx: *engine.context.Context) anyerror!void {
            try expectGlobalString(ctx, "b1", "x");
            try expectGlobalString(ctx, "b2", "other");
            try expectGlobalString(ctx, "b3", "other");
            try expectGlobalString(ctx, "b4", "other");
            try expectGlobalString(ctx, "u1", "present");
            try expectGlobalString(ctx, "u2", "absent");
            try expectGlobalString(ctx, "u3", "absent");
            try expectGlobalString(ctx, "p1", "true-p");
            try expectGlobalString(ctx, "p2", "true-q");
            try expectGlobalString(ctx, "p3", "false");
            try expectGlobalString(ctx, "p4", "false");
            try expectGlobalString(ctx, "a1", "empty");
            try expectGlobalString(ctx, "a2", "some");
        }
    }.check);
}

test "End-to-end: literal and type-test partitions reach an arm for every value" {
    // `string | { w: number }` needs a record arm and a string arm: the record
    // arm does not take the string. The six value kinds of a JSON-like union
    // each reach their own type test, and `boolean` and a literal pair reach
    // theirs.
    const source =
        \\import { match, P } from "zttp:core";
        \\let m1 = "s";
        \\let m2 = { w: 1 };
        \\let r1 = match(m1).with({}, () => "record").with(P.string, () => "text").exhaustive();
        \\let r2 = match(m2).with({}, () => "record").with(P.string, () => "text").exhaustive();
        \\let v1 = null;
        \\let v2 = true;
        \\let v3 = 1;
        \\let v4 = "s";
        \\let v5 = [1];
        \\let k1 = match(v1).with(null, () => "null").with(P.boolean, () => "boolean").with(P.number, () => "number").with(P.string, () => "string").with(P.array, () => "array").exhaustive();
        \\let k2 = match(v2).with(null, () => "null").with(P.boolean, () => "boolean").with(P.number, () => "number").with(P.string, () => "string").with(P.array, () => "array").exhaustive();
        \\let k3 = match(v3).with(null, () => "null").with(P.boolean, () => "boolean").with(P.number, () => "number").with(P.string, () => "string").with(P.array, () => "array").exhaustive();
        \\let k4 = match(v4).with(null, () => "null").with(P.boolean, () => "boolean").with(P.number, () => "number").with(P.string, () => "string").with(P.array, () => "array").exhaustive();
        \\let k5 = match(v5).with(null, () => "null").with(P.boolean, () => "boolean").with(P.number, () => "number").with(P.string, () => "string").with(P.array, () => "array").exhaustive();
        \\let t = true;
        \\let f = false;
        \\let l1 = match(t).with(true, () => "t").with(false, () => "f").exhaustive();
        \\let l2 = match(f).with(true, () => "t").with(false, () => "f").exhaustive();
        \\let one = 1;
        \\let two = 2;
        \\let n1 = match(one).with(1, () => "one").with(2, () => "two").exhaustive();
        \\let n2 = match(two).with(1, () => "one").with(2, () => "two").exhaustive();
        \\let present = "a";
        \\let absent = undefined;
        \\let q1 = match(present).with("a", () => "a").with(undefined, () => "none").exhaustive();
        \\let q2 = match(absent).with("a", () => "a").with(undefined, () => "none").exhaustive();
    ;
    try runMatchProgram(source, struct {
        fn check(ctx: *engine.context.Context) anyerror!void {
            try expectGlobalString(ctx, "r1", "text");
            try expectGlobalString(ctx, "r2", "record");
            try expectGlobalString(ctx, "k1", "null");
            try expectGlobalString(ctx, "k2", "boolean");
            try expectGlobalString(ctx, "k3", "number");
            try expectGlobalString(ctx, "k4", "string");
            try expectGlobalString(ctx, "k5", "array");
            try expectGlobalString(ctx, "l1", "t");
            try expectGlobalString(ctx, "l2", "f");
            try expectGlobalString(ctx, "n1", "one");
            try expectGlobalString(ctx, "n2", "two");
            try expectGlobalString(ctx, "q1", "a");
            try expectGlobalString(ctx, "q2", "none");
        }
    }.check);
}

test "End-to-end: a match with no covering arm evaluates to undefined" {
    // The other half of the soundness check: where the analysis reports a
    // missing case, the runtime really does fall through, which is why the type
    // of such a match includes `undefined`.
    const source =
        \\import { match, P } from "zttp:core";
        \\let v = { kind: "c" };
        \\let r = match(v).with({ kind: "a" }, () => "a").with({ kind: "b" }, () => "b").exhaustive();
        \\let s = "text";
        \\let r2 = match(s).with({}, () => "record").exhaustive();
        \\let tup = [true, "q"];
        \\let r3 = match(tup).with([true, "p"], () => "true-p").with([false, P.any], () => "false").exhaustive();
    ;
    try runMatchProgram(source, struct {
        fn check(ctx: *engine.context.Context) anyerror!void {
            for ([_][]const u8{ "r", "r2", "r3" }) |name| {
                const atom = try ctx.atoms.intern(name);
                const val = ctx.getGlobal(atom) orelse return error.MissingResult;
                try std.testing.expect(val.isUndefined());
            }
        }
    }.check);
}

test "a fluent match refuses code generation when its record key cannot be interned" {
    const allocator = std.testing.allocator;
    const source =
        \\import { match } from "zttp:core";
        \\function h(subject: unknown): number {
        \\  return match(subject).with({ zzkind: "x" }, () => 200).otherwise(() => 404);
        \\}
    ;
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var strings = engine.string.StringTable.init(allocator);
    defer strings.deinit();
    var parser = try engine.parser.Parser.initTyped(allocator, allocator, source, &strings, &atoms);
    defer parser.deinit();
    try std.testing.expect((try parser.parseTypedIr()) == .accepted);
    try validateMatchTestSource(&parser, allocator, &atoms);

    atoms.next_id = 0xFFFE;
    try std.testing.expectError(error.OutOfMemory, parser.generateParsed(allocator));
}
