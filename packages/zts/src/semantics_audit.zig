//! semantics_audit.zig - the faithful-value-model REFUTATION encoder.
//!
//! semantics_smt.zig encodes obligations over an integer abstraction (ℤ) to
//! PROVE algebraic laws. This module is its dual: it encodes obligations over a
//! FAITHFUL model of the engine's JS-ish value type to REFUTE the laws the
//! registry claims are NOT slice-wide laws (`semantics.excluded_laws`). It exists
//! so the soundness boundary - "these tempting equivalences are false on the real
//! engine, do not assert them" - is machine-checked, not just a hand-written
//! comment.
//!
//! Value model: a tagged `Val` of number (IEEE-754 Float64) | bool | string,
//! with the engine's coercion (`toNum`/`toStr`/`toBool`) and polymorphic
//! operators - `+` is numeric add OR string concat, `!` coerces via truthiness,
//! `===` (`seq`) is type-strict (so `5 !== "5"`, `true !== 1`). Leaves are
//! UNCONSTRAINED `Val`s: a child can be any type, which is exactly what makes the
//! excluded laws refutable (commutativity of `+` fails on strings; associativity
//! fails on f64 rounding; `!!x` is a bool, not `x`).
//!
//! The query asserts `not (seq lhs rhs)`: a solver answering `sat` exhibits a
//! counterexample (the claimed non-law is indeed not a law - the exclusion is
//! confirmed); `unsat` would mean the two sides ARE always equal (the law holds,
//! so excluding it was wrong - the driver fails loud). Pure and wasm-safe: no I/O,
//! the solver is injected from the native CLI like the ℤ check. A per-query
//! `:timeout`, taken from the row's own measured budget, is emitted so a hard
//! refutation degrades to `unknown` (inconclusive) rather than hanging.
//!
//! Scope (the bounded "exclusion-audit" tier): this refutes the declared
//! excluded laws. It does NOT add a reachability/type-precondition layer to let
//! numeric laws be asserted under guards. That layer is deliberately not built:
//! the U2 reachability analysis showed the slice's `child`/`local`/`call_result`
//! leaves are genuinely opaque (a local or call_result can carry a string), so
//! a precondition would narrow nothing - the unconstrained `Val` domain above IS
//! the reachable domain. Asserting a numeric law would instead need a *typed
//! leaf* (a registry/`Term`-model change), and the only law it would unlock -
//! numeric `+` commutativity - the U1 spike measured at ~130s over Float64,
//! landing `unproven` under the timeout anyway. So the faithful *scalar* value
//! model is complete here; the next real strengthening is the heap/object model,
//! not more scalar preconditions. The `excluded-law leaves stay unconstrained`
//! test below pins the opacity this soundness rests on.

const std = @import("std");
const semantics = @import("semantics.zig");

const Term = semantics.Term;

/// SMT-LIB preamble: the faithful Val datatype, coercions, and operators. RNE is
/// round-nearest-ties-to-even, JS's number rounding mode. `s2n`/`n2s` are the
/// uninterpreted string<->number coercions (their exact values do not matter for
/// the refutations, only that the type tags mix).
// The `:timeout` is a ceiling, not a fixed cost, and it is emitted per query
// from the row's own budget rather than baked into this preamble. Refutation
// cost is not uniform across the table: the string/type-mix refutations return
// in well under a second, while the f64 associativity counterexample search
// measured 28.8-29.8 seconds on z3 5.1.0 (see the numbers beside each
// `excluded_laws` row). One shared ceiling has to be sized for that slowest row
// and then applies to every row, so a later law that is genuinely undecidable
// burns the whole budget before reporting.
//
// Sizing matters because `spec-check --audit` fails on an inconclusive audit at
// both the gate and the command level: a timeout is a hard error, not a silent
// skip. A ceiling within a second of the measured solve time is a gate that
// fails on a loaded machine and passes on an idle one, which is worse than no
// gate.
const preamble =
    \\(set-logic ALL)
    \\(declare-datatypes ((Val 0)) (((num (n Float64)) (bl (b Bool)) (st (s String)))))
    \\(declare-fun s2n (String) Float64)
    \\(declare-fun n2s (Float64) String)
    \\(define-fun toNum ((v Val)) Float64
    \\  (ite ((_ is num) v) (n v)
    \\    (ite ((_ is bl) v) (ite (b v) ((_ to_fp 11 53) roundNearestTiesToEven 1.0) ((_ to_fp 11 53) roundNearestTiesToEven 0.0))
    \\      (s2n (s v)))))
    \\(define-fun toStr ((v Val)) String
    \\  (ite ((_ is st) v) (s v)
    \\    (ite ((_ is bl) v) (ite (b v) "true" "false") (n2s (n v)))))
    \\(define-fun toBool ((v Val)) Bool
    \\  (ite ((_ is bl) v) (b v)
    \\    (ite ((_ is num) v)
    \\      (and (not (fp.isNaN (toNum v)))
    \\           (not (fp.eq (toNum v) ((_ to_fp 11 53) roundNearestTiesToEven 0.0))))
    \\      (not (= (s v) "")))))
    \\(define-fun vadd ((a Val) (b Val)) Val
    \\  (ite (or ((_ is st) a) ((_ is st) b)) (st (str.++ (toStr a) (toStr b)))
    \\    (num (fp.add roundNearestTiesToEven (toNum a) (toNum b)))))
    \\(define-fun vsub ((a Val) (b Val)) Val (num (fp.sub roundNearestTiesToEven (toNum a) (toNum b))))
    \\(define-fun vmul ((a Val) (b Val)) Val (num (fp.mul roundNearestTiesToEven (toNum a) (toNum b))))
    \\(define-fun vneg ((a Val)) Val (num (fp.neg (toNum a))))
    \\(define-fun vnot ((a Val)) Val (bl (not (toBool a))))
    \\(define-fun vlt ((a Val) (b Val)) Val (bl (fp.lt (toNum a) (toNum b))))
    \\(define-fun seq ((x Val) (y Val)) Bool
    \\  (or (and ((_ is num) x) ((_ is num) y) (fp.eq (n x) (n y)))
    \\      (and ((_ is bl) x) ((_ is bl) y) (= (b x) (b y)))
    \\      (and ((_ is st) x) ((_ is st) y) (= (s x) (s y)))))
    \\
;

pub const EncodeError = error{
    /// A parametric placeholder reached the encoder un-instantiated.
    Uninstantiated,
    /// The RPN does not reduce to exactly one value.
    Malformed,
    OutOfMemory,
};

const Builder = struct {
    arena: std.mem.Allocator,
    leaves: std.ArrayList([]const u8) = .empty,

    fn addLeaf(self: *Builder, name: []const u8) !void {
        for (self.leaves.items) |l| {
            if (std.mem.eql(u8, l, name)) return;
        }
        try self.leaves.append(self.arena, name);
    }

    fn pop(stack: *std.ArrayList([]const u8)) ![]const u8 {
        if (stack.items.len == 0) return error.Malformed;
        return stack.pop().?;
    }

    /// Reduce an RPN denotation to a single faithful `Val` expression string.
    fn build(self: *Builder, terms: []const Term) ![]const u8 {
        var stack: std.ArrayList([]const u8) = .empty;
        for (terms) |t| {
            switch (t) {
                .imm => {
                    try self.addLeaf("imm");
                    try stack.append(self.arena, "imm");
                },
                .child => |i| try self.pushLeaf(&stack, try std.fmt.allocPrint(self.arena, "c{d}", .{i})),
                .local => |i| try self.pushLeaf(&stack, try std.fmt.allocPrint(self.arena, "L{d}", .{i})),
                .call_result => |i| try self.pushLeaf(&stack, try std.fmt.allocPrint(self.arena, "k{d}", .{i})),
                .binop => |k| {
                    const b = try pop(&stack);
                    const a = try pop(&stack);
                    const expr = switch (k) {
                        .add => try std.fmt.allocPrint(self.arena, "(vadd {s} {s})", .{ a, b }),
                        .sub => try std.fmt.allocPrint(self.arena, "(vsub {s} {s})", .{ a, b }),
                        .mul => try std.fmt.allocPrint(self.arena, "(vmul {s} {s})", .{ a, b }),
                        .lt => try std.fmt.allocPrint(self.arena, "(vlt {s} {s})", .{ a, b }),
                        .eq => try std.fmt.allocPrint(self.arena, "(bl (seq {s} {s}))", .{ a, b }),
                    };
                    try stack.append(self.arena, expr);
                },
                .unop => |k| {
                    const a = try pop(&stack);
                    const expr = switch (k) {
                        .not => try std.fmt.allocPrint(self.arena, "(vnot {s})", .{a}),
                        .neg => try std.fmt.allocPrint(self.arena, "(vneg {s})", .{a}),
                    };
                    try stack.append(self.arena, expr);
                },
                .select => {
                    const e = try pop(&stack);
                    const th = try pop(&stack);
                    const c = try pop(&stack);
                    try stack.append(self.arena, try std.fmt.allocPrint(self.arena, "(ite (toBool {s}) {s} {s})", .{ c, th, e }));
                },
                .binop_self, .unop_self => return error.Uninstantiated,
            }
        }
        if (stack.items.len != 1) return error.Malformed;
        return stack.items[0];
    }

    fn pushLeaf(self: *Builder, stack: *std.ArrayList([]const u8), name: []const u8) !void {
        try self.addLeaf(name);
        try stack.append(self.arena, name);
    }
};

/// The budget for a row that declares none. Sized for the type-mix refutations,
/// which measured under a third of a second: a row that needs more says so, and
/// a row that needs more without saying so should report inconclusive quickly
/// rather than hold the gate for minutes.
pub const default_audit_timeout_ms: u32 = 15_000;

/// Encode `lhs == rhs` (JS `===`) over the faithful Val model, asserting the
/// negation. `sat` => a counterexample exists (the equivalence is NOT a law);
/// `unsat` => the two sides are always equal (it IS a law).
///
/// `timeout_ms` is the row's solver budget. It is a parameter rather than a
/// constant because the table's refutation costs differ by two orders of
/// magnitude; see `preamble` above.
pub fn encodeRefutation(
    caller: std.mem.Allocator,
    lhs: []const Term,
    rhs: []const Term,
    timeout_ms: u32,
) EncodeError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(caller);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder{ .arena = arena };
    const l = try b.build(lhs);
    const r = try b.build(rhs);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "(set-option :timeout {d})\n", .{timeout_ms}));
    try out.appendSlice(arena, preamble);
    for (b.leaves.items) |leaf| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "(declare-const {s} Val)\n", .{leaf}));
    }
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "(assert (not (seq {s} {s})))\n(check-sat)\n", .{ l, r }));

    return caller.dupe(u8, out.items);
}

// ---------------------------------------------------------------------------
// Tests (pure; no solver needed - they check the emitted SMT-LIB text).
// ---------------------------------------------------------------------------

test "refutation query shares leaves and uses polymorphic vadd" {
    const a = std.testing.allocator;
    // add commutativity: c0 c1 add  vs  c1 c0 add
    const lhs = [_]Term{ .{ .child = 0 }, .{ .child = 1 }, .{ .binop = .add } };
    const rhs = [_]Term{ .{ .child = 1 }, .{ .child = 0 }, .{ .binop = .add } };
    const q = try encodeRefutation(a, &lhs, &rhs, default_audit_timeout_ms);
    defer a.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "(vadd c0 c1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "(vadd c1 c0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "(assert (not (seq") != null);
    // exactly one declaration of c0.
    const first = std.mem.indexOf(u8, q, "(declare-const c0 Val)").?;
    try std.testing.expect(std.mem.indexOf(u8, q[first + 1 ..], "(declare-const c0 Val)") == null);
    // carries the timeout backstop.
    try std.testing.expect(std.mem.indexOf(u8, q, ":timeout") != null);
}

test "not involution emits vnot and a strict-equality root" {
    const a = std.testing.allocator;
    const lhs = [_]Term{ .{ .child = 0 }, .{ .unop = .not }, .{ .unop = .not } };
    const rhs = [_]Term{.{ .child = 0 }};
    const q = try encodeRefutation(a, &lhs, &rhs, default_audit_timeout_ms);
    defer a.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "(vnot (vnot c0))") != null);
}

test "each excluded law's query carries that row's own budget, not a shared one" {
    // The gate fails on an inconclusive audit, so a ceiling near a row's solve
    // time is a gate that flips with machine load. Pin two things: the budget
    // the row declares is the budget the query carries, and the slow row's
    // budget clears its measured cost with room. `add_associative` measured
    // 28.8-29.8s on z3 5.1.0 (semantics.zig carries the runs).
    const a = std.testing.allocator;
    const measured_assoc_ms: u32 = 29_820;
    var saw_slow_row = false;
    for (semantics.excluded_laws) |law| {
        const budget = law.audit_timeout_ms orelse default_audit_timeout_ms;
        const q = try encodeRefutation(a, law.lhs, law.rhs, budget);
        defer a.free(q);
        const want = try std.fmt.allocPrint(a, "(set-option :timeout {d})", .{budget});
        defer a.free(want);
        // Assert the value expected, not merely that some timeout is present:
        // a shared ceiling would still satisfy "a :timeout exists".
        try std.testing.expect(std.mem.indexOf(u8, q, want) != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, q, ":timeout"));
        if (std.mem.eql(u8, law.name, "add_associative")) {
            saw_slow_row = true;
            try std.testing.expect(budget >= 3 * measured_assoc_ms);
        }
    }
    // Floor: the loop above checks nothing if the row it is about is gone.
    try std.testing.expect(saw_slow_row);
}

test "an un-instantiated parametric placeholder is rejected" {
    const a = std.testing.allocator;
    const terms = [_]Term{ .{ .child = 0 }, .{ .child = 1 }, .binop_self };
    try std.testing.expectError(error.Uninstantiated, encodeRefutation(a, &terms, &terms, default_audit_timeout_ms));
}

test "a malformed RPN is rejected" {
    const a = std.testing.allocator;
    const terms = [_]Term{ .{ .child = 0 }, .{ .child = 1 } };
    try std.testing.expectError(error.Malformed, encodeRefutation(a, &terms, &terms, default_audit_timeout_ms));
}

test "excluded-law leaves stay unconstrained (refutation covers the full reachable Val domain)" {
    // Reachability verdict for the scalar slice: child/local/call_result are
    // opaque engine values. A local or call_result can carry a string (string
    // and template literals exist in the language; values are NaN-boxed and
    // untyped at the slot), so each leaf is declared as an UNCONSTRAINED `Val`.
    // That is exactly what keeps the excluded laws refutable over the engine's
    // real domain - if a leaf were narrowed (e.g. asserted numeric), an excluded
    // law could go vacuously "held" and the boundary would look checked when it
    // is not. Lock it without a solver: the ONLY assertion in each refutation
    // query is the root `(not (seq ...))` - no per-leaf constraint is emitted.
    const a = std.testing.allocator;
    for (semantics.excluded_laws) |law| {
        const q = try encodeRefutation(a, law.lhs, law.rhs, law.audit_timeout_ms orelse default_audit_timeout_ms);
        defer a.free(q);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, q, "(assert "));
    }
}
