//! Independent observation of protected-ledger calls in final bytecode.
//!
//! The compiler's proof IR says which source calls it believes exist. This
//! module starts from the serialized bytecode that the runtime loaded and
//! reconstructs calls whose callee originates at a namespaced
//! `zttp:ledger#post` or `zttp:ledger#balance` global. Import aliases and simple
//! module import aliases are accepted. Local storage, alias chaining, and
//! unknown provenance refuse activation.

const std = @import("std");
const zts = @import("zts");
const pcc = @import("zttp_proof_checker");

const Operation = pcc.invariant.Operation;

pub const Observed = struct {
    function_ordinal: u32,
    code_offset: u32,
    code_len: u8,
    operation: Operation,
};

pub const Error = error{
    OutOfMemory,
    MalformedBytecode,
    TooManyFunctions,
    UnsupportedLedgerEscape,
};

const max_functions: usize = 4096;

const Instruction = struct {
    offset: u32,
    op: zts.Opcode,
    size: u8,
};

const AliasMap = std.AutoHashMapUnmanaged(u32, Operation);

const Provenance = struct {
    operation: Operation,
    use_offset: u32,
    direct_import: bool,
};

pub fn observe(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    dep_bytecodes: []const []const u8,
) Error![]Observed {
    var out: std.ArrayList(Observed) = .empty;
    errdefer out.deinit(allocator);
    var next_ordinal: u32 = 0;

    try observeModule(allocator, bytecode, &next_ordinal, &out);
    for (dep_bytecodes) |dependency| {
        try observeModule(allocator, dependency, &next_ordinal, &out);
    }

    std.mem.sort(Observed, out.items, {}, struct {
        fn lessThan(_: void, a: Observed, b: Observed) bool {
            if (a.function_ordinal != b.function_ordinal) return a.function_ordinal < b.function_ordinal;
            if (a.code_offset != b.code_offset) return a.code_offset < b.code_offset;
            return @intFromEnum(a.operation) < @intFromEnum(b.operation);
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

fn observeModule(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    next_ordinal: *u32,
    out: *std.ArrayList(Observed),
) Error!void {
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var reader = zts.bytecode_cache.SliceReader{ .data = bytes };
    var decoded = zts.bytecode_cache.deserializeBytecodeWithAtomsAndShapes(
        &reader,
        &atoms,
        allocator,
        null,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedBytecode,
    };
    defer decoded.deinit();

    var aliases: AliasMap = .empty;
    defer aliases.deinit(allocator);
    try collectGlobalAliases(allocator, decoded.func, &atoms, &aliases);
    try observeFunctionTree(allocator, decoded.func, &atoms, &aliases, next_ordinal, out, true);
}

fn observeFunctionTree(
    allocator: std.mem.Allocator,
    func: *const zts.FunctionBytecode,
    atoms: *zts.AtomTable,
    aliases: *const AliasMap,
    next_ordinal: *u32,
    out: *std.ArrayList(Observed),
    is_module_root: bool,
) Error!void {
    if (next_ordinal.* >= max_functions) return error.TooManyFunctions;
    const ordinal = next_ordinal.*;
    next_ordinal.* += 1;
    try observeFunction(allocator, func, atoms, aliases, ordinal, out, is_module_root);

    for (func.constants) |constant| {
        if (!constant.isExternPtr()) continue;
        const magic = constant.toExternPtr(u32);
        if (magic.* != zts.bytecode.MAGIC) continue;
        try observeFunctionTree(
            allocator,
            constant.toExternPtr(zts.FunctionBytecode),
            atoms,
            aliases,
            next_ordinal,
            out,
            false,
        );
    }
}

fn instructionsFor(
    allocator: std.mem.Allocator,
    code: []const u8,
) Error![]Instruction {
    var instructions: std.ArrayList(Instruction) = .empty;
    errdefer instructions.deinit(allocator);
    var offset: usize = 0;
    while (offset < code.len) {
        const op = std.enums.fromInt(zts.Opcode, code[offset]) orelse return error.MalformedBytecode;
        const info = zts.bytecode.getOpcodeInfo(op);
        if (std.mem.eql(u8, info.name, "unknown") or offset + info.size > code.len) {
            return error.MalformedBytecode;
        }
        try instructions.append(allocator, .{
            .offset = @intCast(offset),
            .op = op,
            .size = info.size,
        });
        offset += info.size;
    }
    return instructions.toOwnedSlice(allocator);
}

fn collectGlobalAliases(
    allocator: std.mem.Allocator,
    func: *const zts.FunctionBytecode,
    atoms: *zts.AtomTable,
    aliases: *AliasMap,
) Error!void {
    const instructions = try instructionsFor(allocator, func.code);
    defer allocator.free(instructions);
    for (instructions, 0..) |instruction, index| {
        if (instruction.op != .put_global and instruction.op != .define_global) continue;
        const atom = readU16(func.code, instruction.offset + 1) orelse return error.MalformedBytecode;
        const provenance = resolveStackProducer(func, atoms, aliases, instructions, index, 0, 0);
        if (aliases.contains(atom)) return error.UnsupportedLedgerEscape;
        if (provenance) |value| {
            if (!value.direct_import) return error.UnsupportedLedgerEscape;
            try aliases.put(allocator, atom, value.operation);
        }
    }
}

fn observeFunction(
    allocator: std.mem.Allocator,
    func: *const zts.FunctionBytecode,
    atoms: *zts.AtomTable,
    aliases: *const AliasMap,
    ordinal: u32,
    out: *std.ArrayList(Observed),
    is_module_root: bool,
) Error!void {
    const instructions = try instructionsFor(allocator, func.code);
    defer allocator.free(instructions);
    var safe_uses: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer safe_uses.deinit(allocator);

    for (instructions, 0..) |instruction, index| {
        if (isPutLocal(instruction.op)) {
            if (resolveStackProducer(func, atoms, aliases, instructions, index, 0, 0)) |provenance| {
                _ = provenance;
                return error.UnsupportedLedgerEscape;
            }
        }
        if (instruction.op == .put_global or instruction.op == .define_global) {
            const atom = readU16(func.code, instruction.offset + 1) orelse return error.MalformedBytecode;
            if (resolveStackProducer(func, atoms, aliases, instructions, index, 0, 0)) |provenance| {
                const expected = aliases.get(atom) orelse return error.UnsupportedLedgerEscape;
                if (!is_module_root or !provenance.direct_import or expected != provenance.operation) {
                    return error.UnsupportedLedgerEscape;
                }
                try safe_uses.put(allocator, provenance.use_offset, {});
            } else if (aliases.contains(atom)) {
                return error.UnsupportedLedgerEscape;
            }
        }
        var embedded_arg_count: usize = 0;
        const argc: u8 = switch (instruction.op) {
            .call, .tail_call => func.code[instruction.offset + 1],
            .call_ic => func.code[instruction.offset + 1],
            .push_const_call => blk: {
                const fused_argc = func.code[instruction.offset + 3];
                if (fused_argc == 0) continue;
                embedded_arg_count = 1;
                break :blk fused_argc;
            },
            else => continue,
        };
        const provenance = resolveStackProducer(
            func,
            atoms,
            aliases,
            instructions,
            index,
            @as(usize, argc) - embedded_arg_count,
            0,
        ) orelse continue;
        try safe_uses.put(allocator, provenance.use_offset, {});
        try out.append(allocator, .{
            .function_ordinal = ordinal,
            .code_offset = instruction.offset,
            .code_len = instruction.size,
            .operation = provenance.operation,
        });
    }

    // Every load of a protected operation must flow either into a supported
    // direct alias assignment or into the callee slot of a recognized call.
    // Passing it as data, storing it in an object, or returning it is an
    // unsupported escape and refuses activation.
    for (instructions, 0..) |instruction, index| {
        if (instruction.op != .get_global) continue;
        const provenance = operationProducedBy(func, atoms, aliases, instructions, index, 0) orelse continue;
        if (!safe_uses.contains(provenance.use_offset)) return error.UnsupportedLedgerEscape;
    }
}

fn resolveStackProducer(
    func: *const zts.FunctionBytecode,
    atoms: *zts.AtomTable,
    aliases: *const AliasMap,
    instructions: []const Instruction,
    before_index: usize,
    initial_depth: usize,
    recursion_depth: u8,
) ?Provenance {
    if (recursion_depth >= 32) return null;
    var depth = initial_depth;
    var index = before_index;
    while (index > 0) {
        index -= 1;
        const instruction = instructions[index];
        if (isControlBoundary(instruction.op)) return null;
        const effect = stackEffect(func.code, instruction) orelse return null;
        if (depth < effect.pushes) {
            if (effect.pushes != 1 or depth != 0) return null;
            return operationProducedBy(
                func,
                atoms,
                aliases,
                instructions,
                index,
                recursion_depth + 1,
            );
        }
        depth = depth - effect.pushes + effect.pops;
    }
    return null;
}

fn operationProducedBy(
    func: *const zts.FunctionBytecode,
    atoms: *zts.AtomTable,
    aliases: *const AliasMap,
    instructions: []const Instruction,
    index: usize,
    recursion_depth: u8,
) ?Provenance {
    _ = recursion_depth;
    const instruction = instructions[index];
    return switch (instruction.op) {
        .get_global => blk: {
            const atom = readU16(func.code, instruction.offset + 1) orelse break :blk null;
            const direct = operationForDirectAtom(atoms, atom);
            const operation = direct orelse aliases.get(atom) orelse break :blk null;
            break :blk .{
                .operation = operation,
                .use_offset = instruction.offset,
                .direct_import = direct != null,
            };
        },
        else => null,
    };
}

fn isPutLocal(op: zts.Opcode) bool {
    return switch (op) {
        .put_loc, .put_loc_0, .put_loc_1, .put_loc_2, .put_loc_3 => true,
        else => false,
    };
}

fn operationForDirectAtom(atoms: *zts.AtomTable, raw_atom: u16) ?Operation {
    const atom: zts.Atom = @enumFromInt(@as(u32, raw_atom));
    const name = if (atom.isPredefined()) atom.toPredefinedName() else atoms.getName(atom);
    const value = name orelse return null;
    if (std.mem.eql(u8, value, "zttp:ledger#post")) return .post;
    if (std.mem.eql(u8, value, "zttp:ledger#balance")) return .balance;
    return null;
}

fn readU16(code: []const u8, offset: u32) ?u16 {
    const start: usize = @intCast(offset);
    if (start + 2 > code.len) return null;
    return std.mem.readInt(u16, code[start..][0..2], .little);
}

const StackEffect = struct { pops: usize, pushes: usize };

fn stackEffect(code: []const u8, instruction: Instruction) ?StackEffect {
    return switch (instruction.op) {
        .call, .tail_call => .{ .pops = @as(usize, code[instruction.offset + 1]) + 1, .pushes = if (instruction.op == .call) 1 else 0 },
        .call_ic => .{ .pops = @as(usize, code[instruction.offset + 1]) + 1, .pushes = 1 },
        .push_const_call => .{ .pops = code[instruction.offset + 3], .pushes = 1 },
        .call_method => .{ .pops = @as(usize, code[instruction.offset + 1]) + 2, .pushes = 1 },
        .dup => .{ .pops = 1, .pushes = 2 },
        .dup2 => .{ .pops = 2, .pushes = 4 },
        .swap => .{ .pops = 2, .pushes = 2 },
        .rot3 => .{ .pops = 3, .pushes = 3 },
        else => blk: {
            const info = zts.bytecode.getOpcodeInfo(instruction.op);
            break :blk .{ .pops = info.n_pop, .pushes = info.n_push };
        },
    };
}

fn isControlBoundary(op: zts.Opcode) bool {
    return switch (op) {
        .goto, .if_true, .if_false, .loop, .if_false_goto, .ret, .ret_undefined => true,
        else => false,
    };
}
