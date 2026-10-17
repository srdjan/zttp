//! Proof-capsule discharge for user-defined helper functions.
//!
//! Walks every named function the effect analyzer collected, reads its
//! `Proof<T, S>` capsule annotation, and discharges the declared properties
//! against the facts effect inference and path-return analysis proved.
//!
//! The reserved `handler` entry point is skipped: its `Proof<...>` return
//! capsule is discharged separately by the contract builder. Discharging it
//! here too would double-report and mis-flag handler-only flow specs.

const std = @import("std");
const ir = @import("zts-engine").parser.ir;
const effect_inference = @import("effect_inference.zig");
const handler_verifier = @import("handler_verifier.zig");
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");
const spec_discharge = @import("spec_discharge.zig");
const contract_types = @import("zts-contracts").contract_types;
const json_utils = @import("zts-base").json_utils;

const IrView = ir.IrView;
const EffectFacts = effect_inference.EffectFacts;
const TypeEnv = type_env_mod.TypeEnv;
const SpecDiagnostic = contract_types.SpecDiagnostic;
const CapsuleFacts = spec_discharge.CapsuleFacts;

pub const TypeSource = type_env_mod.ConsumerTypeSource;

/// The reserved handler entry point - discharged via `Proof<...>` elsewhere.
const handler_fn_name = "handler";

/// One helper's capsules: the declared `Proof<...>` properties and
/// `Effects<...>` capability ceiling, the facts the compiler proved, and the
/// per-function discharge diagnostics for each.
pub const Capsule = struct {
    /// Owned copy of the function name.
    name: []const u8,
    /// 1-based source line of the function declaration (0 when unknown).
    line: u32,
    /// Owned, de-duplicated capsule property names declared on the return
    /// type. Empty when the helper carries no `Proof<...>` annotation.
    declared: std.ArrayList([]const u8) = .empty,
    /// Facts proved about this function by effect inference + return analysis.
    proven: CapsuleFacts,
    /// ZTS500 / ZTS502 for this function's own declared `Proof<...>` capsule.
    diagnostics: std.ArrayList(SpecDiagnostic) = .empty,
    /// Owned, de-duplicated capability names declared via `Effects<...>`.
    /// Empty when the helper carries no `Effects<...>` annotation.
    effect_declared: std.ArrayList([]const u8) = .empty,
    /// The capability set effect inference computed for this function.
    inferred_caps: spec_discharge.CapabilitySet = spec_discharge.CapabilitySet.initEmpty(),
    /// ZTS503 / ZTS504 / ZTS505 for this function's `Effects<...>` ceiling.
    effect_diagnostics: std.ArrayList(SpecDiagnostic) = .empty,
    /// True when the helper is exported. The opt-in docs mode asks exported
    /// helpers to carry explicit `Proof<...>` / `Effects<...>` capsules.
    exported: bool = false,

    /// True when the function declared a `Proof<...>` capsule and every
    /// property held.
    pub fn discharged(self: *const Capsule) bool {
        return self.declared.items.len > 0 and self.diagnostics.items.len == 0;
    }

    /// True when the function declared an `Effects<...>` ceiling and no
    /// error-severity diagnostic fired against it. A `ZTS505` over-declaration
    /// warning does not break the ceiling.
    pub fn effectDischarged(self: *const Capsule) bool {
        if (self.effect_declared.items.len == 0) return false;
        for (self.effect_diagnostics.items) |d| {
            if (d.kind.severity() == .err) return false;
        }
        return true;
    }

    pub fn deinit(self: *Capsule, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.declared.items) |s| allocator.free(s);
        self.declared.deinit(allocator);
        for (self.diagnostics.items) |*d| @constCast(d).deinit(allocator);
        self.diagnostics.deinit(allocator);
        for (self.effect_declared.items) |s| allocator.free(s);
        self.effect_declared.deinit(allocator);
        for (self.effect_diagnostics.items) |*d| @constCast(d).deinit(allocator);
        self.effect_diagnostics.deinit(allocator);
    }
};

/// One capsule per user-defined named function (excluding `handler`).
pub const CapsuleTable = struct {
    capsules: std.ArrayList(Capsule) = .empty,

    pub fn deinit(self: *CapsuleTable, allocator: std.mem.Allocator) void {
        for (self.capsules.items) |*c| c.deinit(allocator);
        self.capsules.deinit(allocator);
    }

    /// Look up a capsule by function name. Helper names are expected unique
    /// within a module; the first match wins.
    pub fn byName(self: *const CapsuleTable, name: []const u8) ?*const Capsule {
        for (self.capsules.items) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

pub fn dischargeWithTypeSource(
    allocator: std.mem.Allocator,
    effects: *const EffectFacts,
    source: TypeSource,
    ir_view: IrView,
) !CapsuleTable {
    const env = try source.validate();
    var table: CapsuleTable = .{};
    errdefer table.deinit(allocator);

    for (effects.all()) |fe| {
        if (std.mem.eql(u8, fe.name, handler_fn_name)) continue;

        const line: u32 = if (ir_view.getLoc(fe.decl_node)) |loc| loc.line else 0;
        const signature = try functionSignature(source, ir_view, fe.decl_node);

        const facts: CapsuleFacts = .{
            .total = handler_verifier.functionAlwaysReturns(ir_view, fe.body_node),
            .pure = fe.row.pure,
            .read_only = fe.row.readOnly(),
            .deterministic = fe.row.deterministic,
            .recursive = fe.row.recursive,
            .lower_bound = fe.row.lower_bound,
            .function_value_escape = fe.row.function_value_escape,
            .escape_site = effects.functionValueEscape(),
        };

        var declared: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (declared.items) |s| allocator.free(s);
            declared.deinit(allocator);
        }
        _ = try collectDeclared(allocator, env, signature, &declared, false);

        var diagnostics = try spec_discharge.dischargeCapsule(allocator, declared.items, facts);
        errdefer {
            for (diagnostics.items) |*d| @constCast(d).deinit(allocator);
            diagnostics.deinit(allocator);
        }

        var effect_declared: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (effect_declared.items) |s| allocator.free(s);
            effect_declared.deinit(allocator);
        }
        const effect_extraction = try collectDeclared(allocator, env, signature, &effect_declared, true);

        var effect_diagnostics = try spec_discharge.dischargeEffects(
            allocator,
            effect_declared.items,
            fe.row.capabilities,
            effect_extraction.non_literal,
            fe.row.lower_bound,
        );
        errdefer {
            for (effect_diagnostics.items) |*d| @constCast(d).deinit(allocator);
            effect_diagnostics.deinit(allocator);
        }

        const owned_name = try allocator.dupe(u8, fe.name);
        errdefer allocator.free(owned_name);

        // `escape_site.name` is borrowed from `effects`, which the table can
        // outlive. The discharge above has already read it.
        var proven = facts;
        proven.escape_site = null;

        try table.capsules.append(allocator, .{
            .name = owned_name,
            .line = line,
            .declared = declared,
            .proven = proven,
            .diagnostics = diagnostics,
            .effect_declared = effect_declared,
            .inferred_caps = fe.row.capabilities,
            .effect_diagnostics = effect_diagnostics,
            .exported = fe.exported,
        });
    }

    return table;
}

fn functionSignature(
    source: TypeSource,
    ir_view: IrView,
    declaration: ir.NodeIndex,
) !?type_env_mod.FunctionSig {
    const env = switch (source) {
        .omitted => return null,
        .direct => |env| env,
    };
    const owner = switch (ir_view.getTag(declaration) orelse return error.InvalidFunctionOwner) {
        .function_expr, .arrow_function => declaration,
        .function_decl => (ir_view.getVarDecl(declaration) orelse
            return error.InvalidFunctionOwner).init,
        .var_decl => {
            const variable = ir_view.getVarDecl(declaration) orelse
                return error.InvalidFunctionOwner;
            const init_tag = ir_view.getTag(variable.init) orelse
                return error.InvalidFunctionOwner;
            if (init_tag != .function_expr and init_tag != .arrow_function) {
                return error.InvalidFunctionOwner;
            }
            return null;
        },
        else => return error.InvalidFunctionOwner,
    };
    const owner_tag = ir_view.getTag(owner) orelse return error.InvalidFunctionOwner;
    if (owner_tag != .function_expr and owner_tag != .arrow_function) {
        return error.InvalidFunctionOwner;
    }
    const reference = env.functionTypeRef(ir_view, owner) orelse return error.TypeSourceModeMismatch;
    return env.getFunctionSignature(reference);
}

/// Read the declared capsule property names (`Proof<...>`) or capability
/// names (`Effects<...>`, when `effects` is true) from a function's
/// return-type annotation. Owned, de-duplicated copies are appended to `out`.
/// The returned status says whether the annotation was fully readable; an
/// empty `out` alone cannot distinguish "no annotation" from "an annotation
/// this could not read".
fn collectDeclared(
    allocator: std.mem.Allocator,
    env: ?*const TypeEnv,
    signature: ?type_env_mod.FunctionSig,
    out: *std.ArrayList([]const u8),
    comptime effects: bool,
) !type_env_mod.MarkerExtraction {
    const e = env orelse return .{};
    const sig = signature orelse return .{};
    if (sig.return_type == type_pool_mod.null_type_idx) return .{};

    var raw: std.ArrayListUnmanaged([]const u8) = .empty;
    defer raw.deinit(allocator);
    const status = if (effects)
        try e.extractEffectMembers(sig.return_type, &raw)
    else
        try e.extractProofMembers(sig.return_type, &raw);

    for (raw.items) |name| {
        if (json_utils.containsString(out.items, name)) continue;
        const dup = try allocator.dupe(u8, name);
        errdefer allocator.free(dup);
        try out.append(allocator, dup);
    }
    return status;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const context = @import("zts-engine").context;
const JsParser = @import("zts-engine").parser.JsParser;

test "discharge records proven facts and skips the handler" {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    const source =
        \\function clean(s) { return s; }
        \\function nowMs() { return Date.now(); }
        \\function handler(req) { return clean(req); }
    ;
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var effects = try effect_inference.buildEffectFacts(allocator, view, &atoms, root, .{});
    defer effects.deinit(allocator);

    var table = try dischargeWithTypeSource(allocator, &effects, .omitted, view);
    defer table.deinit(allocator);

    // The handler is discharged via Proof<...> elsewhere; capsule discharge
    // skips it. Helpers each get a capsule entry.
    try std.testing.expect(table.byName("handler") == null);

    const clean = table.byName("clean") orelse return error.MissingCapsule;
    try std.testing.expect(clean.proven.pure);
    try std.testing.expect(clean.proven.total);
    try std.testing.expect(clean.proven.deterministic);
    try std.testing.expect(clean.proven.read_only);

    const now = table.byName("nowMs") orelse return error.MissingCapsule;
    try std.testing.expect(!now.proven.deterministic);
    try std.testing.expect(!now.proven.pure);
    try std.testing.expect(now.proven.total);

    // No declared capsules means no discharge diagnostics.
    try std.testing.expectEqual(@as(usize, 0), clean.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 0), now.diagnostics.items.len);
}

test "discharge records non-total facts for a helper that may not return" {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    // The `if` has no else, so one path falls through without returning.
    const source = "function maybe(n) { if (n) { return n; } }";
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var effects = try effect_inference.buildEffectFacts(allocator, view, &atoms, root, .{});
    defer effects.deinit(allocator);

    var table = try dischargeWithTypeSource(allocator, &effects, .omitted, view);
    defer table.deinit(allocator);

    const maybe = table.byName("maybe") orelse return error.MissingCapsule;
    try std.testing.expect(!maybe.proven.total);
}

fn totalHolds(source: []const u8, name: []const u8) !bool {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, source);
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var effects = try effect_inference.buildEffectFacts(allocator, view, &atoms, root, .{});
    defer effects.deinit(allocator);

    var table = try dischargeWithTypeSource(allocator, &effects, .omitted, view);
    defer table.deinit(allocator);
    const capsule = table.byName(name) orelse return error.MissingCapsule;
    return capsule.proven.holds(.total);
}

test "total is refused for a function that recurses through a function value" {
    // Each source recurses without end through a value, and each one proved
    // `total` before function values were tracked as a class. The first name
    // in a pair is the helper whose capsule is read.
    const cases = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "p2g", .source =
        \\function wrap(o) { return o; }
        \\function down(n) { const o = { a: down }; return wrap(o).a(n); }
        },
        .{ .name = "q1", .source = "function down(n) { return [down][0](n); }" },
        .{ .name = "r1", .source =
        \\function apply(f, n) { return f(n); }
        \\function down(n) { return apply(down, n); }
        },
        .{ .name = "r4", .source = "function down(n) { return [n].map(down)[0]; }" },
        .{ .name = "g1", .source =
        \\let slot = (n) => n;
        \\function down(items, n) { return items.map(slot)[0] ?? n; }
        \\function arm(n) { slot = (x) => down([x], x); return n; }
        },
        .{ .name = "fc1", .source =
        \\let slot = (n) => n;
        \\function down(n) { return slot(n); }
        \\function arm(n) { slot = down; return n; }
        },
        .{ .name = "h4", .source = "function down(n) { return [n].reduce((acc, x) => acc, down)(n); }" },
        .{ .name = "p2r", .source = "function down(n) { return down(n); }" },
        .{ .name = "n1", .source =
        \\function down(n) {
        \\  function g(x) { return [x].map(g)[0]; }
        \\  return [n].map(g)[0];
        \\}
        },
    };
    for (cases) |case| {
        const holds = try totalHolds(case.source, "down");
        if (holds) std.debug.print("total was proven for {s}\n", .{case.name});
        try std.testing.expect(!holds);
    }
}

test "total holds for helpers when no function value escapes" {
    const source =
        \\function fmt(x) { return String(x); }
        \\function norm(s) { return s.trim().toLowerCase(); }
        \\function all(items) { return items.map(fmt); }
        \\function pick(items) { return items.filter((x) => x > 1); }
    ;
    try std.testing.expect(try totalHolds(source, "fmt"));
    try std.testing.expect(try totalHolds(source, "norm"));
    try std.testing.expect(try totalHolds(source, "all"));
    try std.testing.expect(try totalHolds(source, "pick"));
}
