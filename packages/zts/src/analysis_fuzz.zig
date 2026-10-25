//! Stress tests for the analysis stages on deep source shapes. This module is
//! test-only.
//!
//! `tests/frontend_fuzz.zig` stops after admission. This file takes the
//! sources that the typed parser accepts and runs them through the type
//! checker and the flow checker, which is where the call-chain, long-chain,
//! and long-name crashes lived. Each generator draws its size from a seeded
//! PRNG, so a failure reproduces, and keeps the source inside the same 4096
//! byte cap as the frontend fuzz. The oracle: each stage returns a result or
//! an error from `analysis_errors`, and every diagnostic span lies inside the
//! source. The test counts what reached each stage and fails below a floor.
//!
//! The file lives in the compiler tier because the type checker and the flow
//! checker sit above the tier of `tests/frontend_fuzz.zig`.

const std = @import("std");
const engine = @import("zts-engine");
const type_checker_mod = @import("type_checker.zig");
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");
const flow_checker_mod = @import("flow_checker.zig");
const handler_verifier_mod = @import("handler_verifier.zig");
const module_types = @import("module_types.zig");
const abi_types = @import("abi_types.zig");

const IrView = engine.parser.ir.IrView;
const TypeChecker = type_checker_mod.TypeChecker;
const TypeEnv = type_env_mod.TypeEnv;
const TypePool = type_pool_mod.TypePool;
const FlowChecker = flow_checker_mod.FlowChecker;

/// Largest generated source, the same cap as `tests/frontend_fuzz.zig`.
const max_source = 4096;

/// Every error the typed parser may return on this input family.
const parser_errors = [_][]const u8{
    "OutOfMemory",
    "ParseError",
    "UnexpectedToken",
    "MissingSemicolon",
    "InvalidNumber",
    "InvalidEscapeSequence",
    "StringLineContinuation",
    "TooManyLocals",
    "TooManyConstants",
    "TooManyShapes",
    "JumpTooFar",
    "TypeOnlyModuleLexicallyExcluded",
};

/// Every error the type checker and the flow checker may return. The set is
/// closed on purpose: an error that is not here is new behavior to classify.
/// `BudgetExhausted` is absent because the flow interpreter turns it into an
/// unresolved entry before it reaches `FlowChecker.check`.
const analysis_errors = [_][]const u8{
    "OutOfMemory",
    "TypePoolCapacityExceeded",
    "UnresolvedTypeBinding",
};

fn expectKnown(comptime list: []const []const u8, stage: []const u8, err: anyerror) !void {
    for (list) |name| {
        if (std.mem.eql(u8, name, @errorName(err))) return;
    }
    std.debug.print("unclassified {s} error: {s}\n", .{ stage, @errorName(err) });
    return error.UnclassifiedAnalysisError;
}

const Shape = enum { call_chain, binary_chain, long_if, alias_chain, nested_calls };
const shape_count = std.enums.values(Shape).len;

const ShapeStats = struct {
    inputs: usize = 0,
    parsed: usize = 0,
    type_checked: usize = 0,
    flowed: usize = 0,
    failed_closed: usize = 0,
    /// Flow analyses that recorded an unresolved construct (a budget limit).
    unresolved: usize = 0,
    spans: usize = 0,
};

/// A size in 1...max. Half of the draws take the largest size that fits, so the
/// deepest shape the cap allows runs often.
fn size(rng: std.Random, max: usize) usize {
    if (max <= 1) return 1;
    return if (rng.boolean()) max else 1 + rng.uintLessThan(usize, max);
}

const handler_head = "function handler(req: Request): Response {";
const handler_fmt = "function handler(req: Request): Response {{";

fn generateCallChain(rng: std.Random, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const typed = rng.boolean();
    const want = size(rng, 140);
    const reserve = 160;
    try out.appendSlice(allocator, if (typed) "function g0(x: string): string { return x; }\n" else "function g0(x){return x;}\n");
    var last: usize = 0;
    while (last + 1 < want and out.items.len < max_source - reserve) {
        last += 1;
        if (typed) {
            try out.print(allocator, "function g{d}(x: string): string {{ return g{d}(x); }}\n", .{ last, last - 1 });
        } else {
            try out.print(allocator, "function g{d}(x){{return g{d}(x);}}\n", .{ last, last - 1 });
        }
    }
    try out.print(allocator, handler_fmt ++ " return Response.text(g{d}(req.url)); }}\n", .{last});
}

fn generateBinaryChain(rng: std.Random, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const strings = rng.boolean();
    const operand: []const u8 = if (strings) "\"a\"" else "1";
    // The parser refuses value nesting past 512, so most draws stay under it.
    const want = switch (rng.uintLessThan(u8, 4)) {
        0 => 511,
        1 => 1800,
        else => 1 + rng.uintLessThan(usize, 511),
    };
    try out.appendSlice(allocator, handler_head ++ " const x = ");
    try out.appendSlice(allocator, operand);
    var terms: usize = 1;
    while (terms < want and out.items.len < max_source - 80) : (terms += 1) {
        try out.append(allocator, '+');
        try out.appendSlice(allocator, operand);
    }
    try out.appendSlice(allocator, "; return Response.text(String(x)); }\n");
}

fn generateLongIf(rng: std.Random, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const want = size(rng, 350);
    const with_else = rng.boolean();
    try out.appendSlice(allocator, handler_head);
    // A type mismatch gives the span oracle a diagnostic to check.
    if (rng.boolean()) try out.appendSlice(allocator, " const bad: number = \"x\";");
    try out.appendSlice(allocator, " if (req.method === \"GET\") {");
    var count: usize = 0;
    while (count < want and out.items.len < max_source / (if (with_else) @as(usize, 2) else 1) - 100) : (count += 1) {
        try out.appendSlice(allocator, " String(1);");
    }
    try out.appendSlice(allocator, " }");
    if (with_else) {
        try out.appendSlice(allocator, " else {");
        var again: usize = 0;
        while (again < count and out.items.len < max_source - 100) : (again += 1) {
            try out.appendSlice(allocator, " String(2);");
        }
        try out.appendSlice(allocator, " }");
    }
    try out.appendSlice(allocator, " return Response.text(\"ok\"); }\n");
}

fn generateAliasChain(rng: std.Random, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    // A name past 255 bytes fails closed in the type pool.
    const pad: usize = switch (rng.uintLessThan(u8, 4)) {
        0 => 245 + rng.uintLessThan(usize, 20),
        else => 0,
    };
    const field_pad: usize = if (rng.uintLessThan(u8, 4) == 0) 250 + rng.uintLessThan(usize, 50) else 0;
    const want = size(rng, 140);
    var padding: [320]u8 = @splat('a');
    const name_pad = padding[0..pad];
    const fp = padding[0..field_pad];
    try out.print(allocator, "structural T{s}0 = {{ f{s}: number }};\n", .{ name_pad, fp });
    var last: usize = 0;
    // One more line holds two names; the handler holds one more.
    while (last + 1 < want and out.items.len + 3 * pad + 3 * field_pad + 250 < max_source) {
        last += 1;
        try out.print(allocator, "structural T{s}{d} = T{s}{d};\n", .{ name_pad, last, name_pad, last - 1 });
    }
    try out.print(allocator, handler_fmt ++ " const v: T{s}{d} = {{ f{s}: 1 }}; return Response.text(String(v.f{s})); }}\n", .{ name_pad, last, fp, fp });
}

fn generateNestedCalls(rng: std.Random, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const functions = 1 + rng.uintLessThan(usize, 40);
    const depth = size(rng, @max(1, (max_source - 250) / functions / 5 - 8));
    try out.appendSlice(allocator, "function g0(x){return x;}\n");
    for (1..functions) |i| {
        try out.print(allocator, "function g{d}(x){{return ", .{i});
        for (0..depth) |_| try out.append(allocator, '[');
        try out.print(allocator, "g{d}(x)", .{i - 1});
        for (0..depth) |_| try out.appendSlice(allocator, "][0]");
        try out.appendSlice(allocator, ";}\n");
    }
    try out.print(allocator, handler_fmt ++ " return Response.text(g{d}(req.url)); }}\n", .{functions - 1});
}

fn expectSpanInside(src: []const u8, view: IrView, node: u32) !bool {
    const loc = view.getLoc(node) orelse return false;
    const span = loc.span();
    try std.testing.expect(span.start <= span.end);
    try std.testing.expect(span.end <= src.len);
    return true;
}

/// Run one source through parse, type check, and flow analysis.
fn analyze(src: []const u8, stats: *ShapeStats) !void {
    const allocator = std.testing.allocator;
    stats.inputs += 1;

    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = engine.parser.JsParser.initTyped(allocator, allocator, src) catch |err| {
        try expectKnown(&parser_errors, "parser", err);
        return;
    };
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = parser.parse() catch |err| {
        try expectKnown(&parser_errors, "parser", err);
        return;
    };
    if (parser.hasErrors()) return;
    stats.parsed += 1;

    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    module_types.populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } }) catch |err| {
        try expectKnown(&analysis_errors, "type environment", err);
        stats.failed_closed += 1;
        return;
    };

    var checker = TypeChecker.init(allocator, view, &atoms, &env);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    if (checker.check(root)) |_| {
        checker.ensureHealthy() catch |err| {
            try expectKnown(&analysis_errors, "type checker", err);
            stats.failed_closed += 1;
            return;
        };
    } else |err| {
        try expectKnown(&analysis_errors, "type checker", err);
        stats.failed_closed += 1;
        return;
    }
    stats.type_checked += 1;
    for (checker.getDiagnostics()) |diagnostic| {
        if (try expectSpanInside(src, view, diagnostic.node)) stats.spans += 1;
    }

    const handler = handler_verifier_mod.findHandlerFunction(view, root) orelse return;
    var flow = FlowChecker.init(allocator, view, &atoms);
    defer flow.deinit();
    flow.scopes = &parser.scopes;
    flow.setTypeChecker(&checker);
    if (flow.check(handler)) |_| {} else |err| {
        try expectKnown(&analysis_errors, "flow checker", err);
        stats.failed_closed += 1;
        return;
    }
    stats.flowed += 1;
    if (flow.unresolvedCount() > 0) stats.unresolved += 1;
    for (flow.getDiagnostics()) |diagnostic| {
        if (try expectSpanInside(src, view, diagnostic.node)) stats.spans += 1;
    }
}

fn generateInto(shape: Shape, rng: std.Random, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (shape) {
        .call_chain => try generateCallChain(rng, out, allocator),
        .binary_chain => try generateBinaryChain(rng, out, allocator),
        .long_if => try generateLongIf(rng, out, allocator),
        .alias_chain => try generateAliasChain(rng, out, allocator),
        .nested_calls => try generateNestedCalls(rng, out, allocator),
    }
}

const iterations_per_shape = 8;
/// Inputs per shape that must reach type checking, and that must reach flow
/// analysis. A generator whose output the parser always refuses fails here.
const type_check_floor = 4;
const flow_floor = 4;
/// Inputs of a deep call shape whose flow analysis must hit a depth limit.
const unresolved_floor = 2;

test "analysis stages hold their contract on deep generated shapes" {
    const allocator = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x70C3_0A11);
    const rng = prng.random();
    var stats: [shape_count]ShapeStats = @splat(.{});

    for (0..iterations_per_shape) |_| {
        inline for (std.enums.values(Shape)) |shape| {
            const index = @backingInt(shape);
            var source: std.ArrayList(u8) = .empty;
            defer source.deinit(allocator);
            try generateInto(shape, rng, &source, allocator);
            if (source.items.len > max_source) {
                std.debug.print("{s} generated {d} bytes\n", .{ @tagName(shape), source.items.len });
                return error.SourceOverCap;
            }
            analyze(source.items, &stats[index]) catch |err| {
                // A failing input is the whole reproduction, so print it.
                std.debug.print("{s} failed on generated input \"{f}\"\n", .{ @tagName(shape), std.zig.fmtString(source.items) });
                return err;
            };
        }
    }

    inline for (std.enums.values(Shape)) |shape| {
        const index = @backingInt(shape);
        const s = stats[index];
        const shape_floor = switch (shape) {
            // Chains past the activation and native depth limits must reach them.
            .call_chain, .nested_calls => s.unresolved >= unresolved_floor,
            // A name past 255 bytes must fail closed in the type pool.
            .alias_chain => s.failed_closed >= 1,
            // The planted mismatch must reach the span oracle.
            .long_if => s.spans >= 1,
            .binary_chain => true,
        };
        if (s.inputs != iterations_per_shape or s.type_checked < type_check_floor or s.flowed < flow_floor or !shape_floor) {
            std.debug.print("{s} below floor: inputs={d} parsed={d} type_checked={d} flowed={d} failed_closed={d} unresolved={d} spans={d}\n", .{ @tagName(shape), s.inputs, s.parsed, s.type_checked, s.flowed, s.failed_closed, s.unresolved, s.spans });
            return error.BelowFloor;
        }
    }
}
