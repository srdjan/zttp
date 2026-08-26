//! semantics.zig - the fourth registry: what each IR `NodeTag` means and each
//! bytecode `Opcode` computes.
//!
//! zts already pins three declarative registries (features, modules, rules),
//! each reducible to a stable hash. The meaning of the language has no such home
//! today; it lives only implicitly in `parser/codegen.zig` (lowering) and
//! `interpreter.zig` (execution). This file is the L2 semantics registry. The
//! pure value core carries executable denotations and lowering rules. Every
//! other named IR node and opcode carries a per-member assurance disposition,
//! so the conformance denominator is the whole named alphabet rather than only
//! the symbolic slice. `semantics_check.zig` fails any unclassified member.
//!
//! The northstar (docs/zts-formal-spec-northstar.html) replaces the hand-rolled
//! symbolic executor with an SMT refinement check; this data model migrates there
//! unchanged.

const std = @import("std");
const bytecode = @import("zts-engine").bytecode;
const ir = @import("zts-engine").parser.ir;
const diagnostic_catalog = @import("diagnostic_catalog.zig");

pub const Opcode = bytecode.Opcode;
pub const NodeTag = ir.NodeTag;

/// Binary operators that appear in the slice's denotations.
pub const BinKind = enum { add, sub, mul, lt, eq };

/// Unary operators that appear in the slice's denotations.
pub const UnKind = enum { not, neg };

/// A symbolic term in reverse-polish (postfix) form. A denotation is a slice of
/// `Term`; symbolic execution of a lowering produces another slice; the two are
/// compared token-for-token. `child`, `local`, `call_result`, and `imm` are
/// opaque symbols standing for sub-results the checker does not look inside.
/// `binop_self`/`unop_self` are placeholders for "this node's operator", used by
/// parametric rules and substituted to a concrete `binop`/`unop` per instance
/// before any execution or comparison.
pub const Term = union(enum) {
    /// The node's own literal immediate (a lit_int's value, a lit_bool's value).
    imm,
    /// The denotation of the i-th subexpression (opaque).
    child: u8,
    /// locals[i].
    local: u8,
    /// The opaque result of the i-th call site (the FFI / oracle boundary).
    call_result: u8,
    /// Combine the top two terms with a binary operator.
    binop: BinKind,
    /// Combine the top term with a unary operator.
    unop: UnKind,
    /// Combine the top three terms (cond, then, else) into a selection.
    select,
    /// Parametric placeholder: this node's binary operator (substituted per instance).
    binop_self,
    /// Parametric placeholder: this node's unary operator (substituted per instance).
    unop_self,

    pub fn eql(a: Term, b: Term) bool {
        if (@as(std.meta.Tag(Term), a) != @as(std.meta.Tag(Term), b)) return false;
        return switch (a) {
            .imm, .select, .binop_self, .unop_self => true,
            .child => |i| i == b.child,
            .local => |i| i == b.local,
            .call_result => |i| i == b.call_result,
            .binop => |k| k == b.binop,
            .unop => |k| k == b.unop,
        };
    }
};

/// Compare two RPN denotations for structural equality.
pub fn termsEql(a: []const Term, b: []const Term) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

/// One step of a straight-line lowering template. The symbolic executor runs
/// these against a stack of Term sequences to reconstruct the node's denotation.
pub const Step = union(enum) {
    /// push_0..3 / push_i8 / push_i16 / push_const: leave the node's immediate.
    push_imm,
    /// the opcodes that evaluate child i and leave its value on the stack.
    eval_child: u8,
    /// get_loc i.
    push_local: u8,
    /// a call that yields call_result(i) on top of the stack.
    call_site: u8,
    /// a stack opcode whose transition is declared in `op_rules`.
    op: Opcode,
    /// Parametric placeholder: the opcode implementing this node's operator
    /// (substituted to a concrete `op` per instance before execution).
    op_self,
};

/// How a node lowers. `branch` models cond ? then : else, whose three regions are
/// wired with control opcodes; the wiring's stack discipline is checked via the
/// arity table (mechanism 2), the value via symbolic execution (mechanism 3).
pub const Lowering = union(enum) {
    straight: []const Step,
    branch: struct {
        cond: []const Step,
        then: []const Step,
        else_: []const Step,
        wiring: []const Opcode,
    },
};

/// How a node's meaning is established.
pub const ProofKind = enum {
    /// A value-producing node: `denote` and `lower` are present and proven equal.
    value,
    /// A statement / non-value node: coverage + (no value) for this slice.
    structural,
};

/// Operator-parameterization of a value rule. `binop`/`unop` rules carry
/// `binop_self`/`unop_self`/`op_self` placeholders the checker instantiates over
/// every BinKind/UnKind via `binOpcode`/`unOpcode`.
pub const Parametric = enum { none, binop, unop };

pub const NodeRule = struct {
    tag: NodeTag,
    proof: ProofKind,
    parametric: Parametric = .none,
    denote: []const Term = &.{},
    lower: ?Lowering = null,
};

/// The opcode that implements a binary operator (the op_map the parametric proof
/// is generic over; hashed into semanticsHash so the mapping is pinned too).
pub fn binOpcode(k: BinKind) Opcode {
    return switch (k) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .lt => .lt,
        .eq => .eq,
    };
}

pub fn unOpcode(k: UnKind) Opcode {
    return switch (k) {
        .not => .not,
        .neg => .neg,
    };
}

/// The symbolic transition of an opcode over the Term stack.
pub const Transition = union(enum) {
    /// pop 2 (a, b), push a ++ b ++ [binop k].
    binop: BinKind,
    /// pop 1 (a), push a ++ [unop k].
    unop: UnKind,
    /// control flow (if_false / goto / ret): no value pushed.
    control,
};

pub const OpRule = struct {
    op: Opcode,
    t: Transition,
};

// The symbolic transition registry: the arithmetic / comparison / logical opcodes
// that appear as `op` steps in lowerings. Stack (push_*), local (get_loc ->
// push_local Step), control-flow, object, module, and optimized opcodes are not
// in the symbolic registry for this slice and are modeled structurally.
pub const op_rules = [_]OpRule{
    .{ .op = .add, .t = .{ .binop = .add } },
    .{ .op = .sub, .t = .{ .binop = .sub } },
    .{ .op = .mul, .t = .{ .binop = .mul } },
    .{ .op = .lt, .t = .{ .binop = .lt } },
    .{ .op = .eq, .t = .{ .binop = .eq } },
    .{ .op = .not, .t = .{ .unop = .not } },
    .{ .op = .neg, .t = .{ .unop = .neg } },
};

/// Look up an opcode's symbolic transition, if specified.
pub fn opTransition(op: Opcode) ?Transition {
    for (op_rules) |r| {
        if (r.op == op) return r.t;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The slice registry. Every value rule carries denote + lower AS DATA, so
// semanticsHash covers all of it and the checker is a pure interpreter.
// ---------------------------------------------------------------------------

pub const node_rules = [_]NodeRule{
    // Literals: lower by pushing their own immediate, which is what they denote.
    .{ .tag = .lit_int, .proof = .value, .denote = &.{.imm}, .lower = .{ .straight = &.{.push_imm} } },
    .{ .tag = .lit_bool, .proof = .value, .denote = &.{.imm}, .lower = .{ .straight = &.{.push_imm} } },
    // `null` is a constant of its own, distinct from `undefined`. It denotes
    // its immediate and lowers to the constant push, the same shape the other
    // literals have (spec 5.3).
    .{ .tag = .lit_null, .proof = .value, .denote = &.{.imm}, .lower = .{ .straight = &.{.push_imm} } },
    // Identifier (local read): get_loc, denotes locals[0].
    .{ .tag = .identifier, .proof = .value, .denote = &.{.{ .local = 0 }}, .lower = .{ .straight = &.{.{ .push_local = 0 }} } },
    // binary_op: generic over its operator. denote = c0 c1 <op>; lower = <c0> <c1> <op>.
    .{ .tag = .binary_op, .proof = .value, .parametric = .binop, .denote = &.{ .{ .child = 0 }, .{ .child = 1 }, .binop_self }, .lower = .{ .straight = &.{ .{ .eval_child = 0 }, .{ .eval_child = 1 }, .op_self } } },
    // unary_op: generic over its operator.
    .{ .tag = .unary_op, .proof = .value, .parametric = .unop, .denote = &.{ .{ .child = 0 }, .unop_self }, .lower = .{ .straight = &.{ .{ .eval_child = 0 }, .op_self } } },
    // ternary: cond ? then : else, denoting select(c, t, e).
    .{ .tag = .ternary, .proof = .value, .denote = &.{ .{ .child = 0 }, .{ .child = 1 }, .{ .child = 2 }, .select }, .lower = .{ .branch = .{
        .cond = &.{.{ .eval_child = 0 }},
        .then = &.{.{ .eval_child = 1 }},
        .else_ = &.{.{ .eval_child = 2 }},
        .wiring = &.{ .if_false, .goto },
    } } },
    // call: the oracle boundary - denotes an opaque call_result, lowering pushes it.
    .{ .tag = .call, .proof = .value, .denote = &.{.{ .call_result = 0 }}, .lower = .{ .straight = &.{.{ .call_site = 0 }} } },
    // A type-test pattern denotes nothing on its own: it selects an arm, and
    // the value it tests with is the predicate expression the parser lowered
    // it to, whose own nodes carry the denotation (spec 5.5).
    .{ .tag = .match_type_test, .proof = .structural },
    // Statements: covered, no value denotation in this slice.
    .{ .tag = .if_stmt, .proof = .structural },
    .{ .tag = .return_stmt, .proof = .structural },
    .{ .tag = .block, .proof = .structural },
};

/// Assurance attached to every named IR node and opcode.
///
/// `specified` means the executable symbolic registry covers the member.
/// `translation_validated` means an explicit refinement proves an optimized
/// member equivalent to its base sequence. `trusted` keeps a narrow compiler or
/// VM transition in the TCB and names why. `not_reachable` is reserved for a
/// member that the profile front end proves cannot enter the core. An unknown
/// future named member is `unclassified` and makes spec-check fail.
pub const DispositionKind = enum {
    specified,
    translation_validated,
    trusted,
    not_reachable,
    unclassified,
};

pub const Disposition = struct {
    kind: DispositionKind,
    reason: []const u8,
};

const symbolic_reason = "executable denotation and lowering rule";
const literal_tcb_reason = "literal representation and constant-pool lowering remain in the compiler and VM TCB";
const expression_tcb_reason = "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract";
const control_tcb_reason = "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins";
const binding_tcb_reason = "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary";
const pattern_tcb_reason = "match-pattern elaboration remains in the checker TCB and lowers to ordinary core tests and bindings";
const parser_structure_reason = "parser-only structural container with no independent runtime denotation";
const vm_stack_reason = "VM stack transition remains in the execution TCB and has verifier-owned arity metadata";
const vm_numeric_reason = "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata";
const vm_control_reason = "VM control transition remains in the execution TCB and has verifier-checked targets and stack effects";
const vm_call_reason = "call and closure transition remains in the VM TCB behind typed call-site and capability checks";
const vm_object_reason = "object and property transition remains in the VM TCB behind shape and stack verification";
const vm_module_reason = "static module transition remains in the VM TCB behind the resolved module graph";
const vm_optimized_reason = "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests";
const already_specified = Disposition{ .kind = .specified, .reason = symbolic_reason };
const optimized_refinement_reason = "translation validation proves the fused opcode equivalent to its declared base sequence";
const unclassified_reason = "named member has no semantic assurance disposition";

fn hasNodeRule(tag: NodeTag) bool {
    for (node_rules) |rule| if (rule.tag == tag) return true;
    return false;
}

pub fn nodeDisposition(tag: NodeTag) Disposition {
    if (hasNodeRule(tag)) return already_specified;
    return switch (tag) {
        .lit_float, .lit_string, .lit_undefined => .{ .kind = .trusted, .reason = literal_tcb_reason },
        .method_call,
        .member_access,
        .computed_access,
        .optional_chain,
        .assignment,
        .array_literal,
        .object_literal,
        .object_property,
        .object_method,
        .object_getter,
        .object_setter,
        .object_spread,
        .function_expr,
        .arrow_function,
        .spread,
        .await_expr,
        .yield_expr,
        .sequence_expr,
        .comma_expr,
        => .{ .kind = .trusted, .reason = expression_tcb_reason },
        .match_expr, .match_arm, .match_pattern, .array_pattern, .pattern_element, .pattern_rest, .pattern_default => .{ .kind = .trusted, .reason = pattern_tcb_reason },
        .expr_stmt,
        .var_decl,
        .for_stmt,
        .for_of_stmt,
        .for_in_stmt,
        .while_stmt,
        .do_while_stmt,
        .switch_stmt,
        .case_clause,
        .assert_stmt,
        .throw_stmt,
        .break_stmt,
        .continue_stmt,
        .try_stmt,
        .labeled_stmt,
        => .{ .kind = .trusted, .reason = control_tcb_reason },
        .function_decl,
        .import_decl,
        .import_specifier,
        .import_default,
        .import_namespace,
        .export_decl,
        .export_specifier,
        .export_default,
        .export_all,
        => .{ .kind = .trusted, .reason = binding_tcb_reason },
        .program, .param_list, .arg_list, .stmt_list => .{ .kind = .trusted, .reason = parser_structure_reason },
        // Handled before this switch by `hasNodeRule`; spelling the members here
        // keeps the switch exhaustive, so adding a new NodeTag is a compile error.
        .lit_int, .lit_bool, .lit_null, .identifier, .binary_op, .unary_op, .ternary, .call, .match_type_test, .if_stmt, .return_stmt, .block => already_specified,
    };
}

/// A fused/superinstruction opcode and the base opcode sequence it must be
/// equivalent to. `fused_effect` and `base` are authored as two independent
/// fields; the checker proves they leave the same symbolic stack. For a faithful
/// concatenation superinstruction they coincide - the check exists to catch one
/// that does not (see the negative test in semantics_check.zig).
pub const Refinement = struct {
    fused: Opcode,
    fused_effect: []const Step,
    base: []const Step,
};

pub const refinements = [_]Refinement{
    .{
        .fused = .get_loc_add,
        .fused_effect = &.{ .{ .push_local = 0 }, .{ .op = .add } },
        .base = &.{ .{ .push_local = 0 }, .{ .op = .add } },
    },
};

fn hasOpRule(op: Opcode) bool {
    for (op_rules) |rule| if (rule.op == op) return true;
    return false;
}

fn hasRefinement(op: Opcode) bool {
    for (refinements) |refinement| if (refinement.fused == op) return true;
    return false;
}

/// Classify every named opcode. Opcode is non-exhaustive because bytecode
/// reserves numeric space, so the final else deliberately remains
/// `unclassified`. Coverage iterates the named enum fields, which means adding
/// a named opcode without adding it here makes spec-check fail.
pub fn opcodeDisposition(op: Opcode) Disposition {
    if (hasOpRule(op)) return already_specified;
    if (hasRefinement(op)) return .{ .kind = .translation_validated, .reason = optimized_refinement_reason };
    return switch (op) {
        .nop,
        .push_const,
        .push_0,
        .push_1,
        .push_2,
        .push_3,
        .push_i8,
        .push_i16,
        .push_null,
        .push_undefined,
        .push_true,
        .push_false,
        .dup,
        .drop,
        .swap,
        .rot3,
        .get_length,
        .dup2,
        => .{ .kind = .trusted, .reason = vm_stack_reason },
        .div,
        .mod,
        .pow,
        .inc,
        .dec,
        .math_floor,
        .math_ceil,
        .math_round,
        .math_abs,
        .math_min2,
        .math_max2,
        .bit_and,
        .bit_or,
        .bit_xor,
        .bit_not,
        .shl,
        .shr,
        .ushr,
        .lte,
        .gt,
        .gte,
        .neq,
        .strict_eq,
        .strict_neq,
        .typeof,
        .add_num,
        .sub_num,
        .mul_num,
        .div_num,
        .lt_num,
        .gt_num,
        .lte_num,
        .gte_num,
        => .{ .kind = .trusted, .reason = vm_numeric_reason },
        .halt,
        .loop,
        .goto,
        .if_true,
        .if_false,
        .ret,
        .ret_undefined,
        => .{ .kind = .trusted, .reason = vm_control_reason },
        .get_loc,
        .put_loc,
        .get_loc_0,
        .get_loc_1,
        .get_loc_2,
        .get_loc_3,
        .put_loc_0,
        .put_loc_1,
        .put_loc_2,
        .put_loc_3,
        .get_global,
        .put_global,
        .define_global,
        => .{ .kind = .trusted, .reason = binding_tcb_reason },
        .call,
        .call_method,
        .tail_call,
        .make_function,
        .call_spread,
        .get_upvalue,
        .put_upvalue,
        .close_upvalue,
        .make_closure,
        => .{ .kind = .trusted, .reason = vm_call_reason },
        .get_field,
        .put_field,
        .get_elem,
        .put_elem,
        .put_elem_keep,
        .put_field_keep,
        .new_object,
        .new_array,
        .new_object_literal,
        .array_spread,
        .object_spread,
        .set_slot,
        => .{ .kind = .trusted, .reason = vm_object_reason },
        .import_module,
        .import_name,
        .import_default,
        .export_name,
        .export_default,
        => .{ .kind = .trusted, .reason = vm_module_reason },
        .get_loc_get_loc_add,
        .push_const_call,
        .get_field_call,
        .if_false_goto,
        .add_mod,
        .sub_mod,
        .mul_mod,
        .for_of_next,
        .for_of_next_put_loc,
        .shr_1,
        .mul_2,
        .mod_const,
        .mod_const_i8,
        .add_const_i8,
        .sub_const_i8,
        .get_field_ic,
        .put_field_ic,
        .call_ic,
        .mul_const_i8,
        .lt_const_i8,
        .le_const_i8,
        .drop_goto,
        => .{ .kind = .trusted, .reason = vm_optimized_reason },
        // Symbolic and refined opcodes return before the switch. Listing them
        // still documents the complete named alphabet for human review.
        .add, .sub, .mul, .lt, .eq, .not, .neg => already_specified,
        .get_loc_add => .{ .kind = .translation_validated, .reason = optimized_refinement_reason },
        else => .{ .kind = .unclassified, .reason = unclassified_reason },
    };
}

/// Algebraic laws the language's value semantics must satisfy: equivalences
/// between *structurally different* denotations. Mechanism 3 (structural RPN
/// equality) cannot admit these - both sides have different `Term` sequences -
/// but the SMT check (mechanism 5, `semantics_smt.zig`) certifies them over the
/// value model. They are spec content (claims about the language), so they are
/// hashed into `semanticsHash` and rendered into the spec artifact. A law that
/// did NOT hold would surface as an SMT counterexample at `spec-check` time.
///
/// SOUNDNESS BOUNDARY - read before adding a law. The SMT encoder abstracts the
/// engine's number type (i32 that promotes to IEEE-754 f64 on overflow; see
/// interpreter.zig `addValues`) as the unbounded mathematical integers Z. That
/// abstraction is sound ONLY for a law whose truth does not depend on JS
/// coercion, string concatenation, truthiness, float rounding, integer overflow,
/// NaN, or signed zero. A law valid over Z but not over the engine's value
/// behavior would be falsely "proven" and folded into the signed receipt.
///
/// Associativity of addition is the canonical numeric boundary: it holds over Z
/// but FAILS on the engine, because a `child` can be a large float (e.g. a
/// mul-overflow result past 2^53) and f64 addition is not associative there.
/// Likewise, generic `+` can concatenate strings and `!` returns a boolean via
/// JS truthiness, so `a + b == b + a` and `!!x == x` are not slice-wide laws.
/// Faithful f64 and heap/string encoding is northstar work; until then, a law
/// must hold under the engine's value model, not merely under Z.
pub const Law = struct {
    name: []const u8,
    lhs: []const Term,
    rhs: []const Term,
    /// Solver budget for this row's audit query, in milliseconds. `null` takes
    /// `semantics_audit.default_audit_timeout_ms`. It is a per-row property
    /// because refutation cost is not uniform: three of the four excluded laws
    /// refute on a type mix and return in under a second, while the f64
    /// associativity counterexample search is two orders of magnitude slower
    /// (see the measurements beside each row). A single shared ceiling has to
    /// be set for the slowest row, which then hands every later row the same
    /// long rope and lets a genuinely undecidable one burn it in full.
    ///
    /// Deliberately outside `semanticsHash`: the hash covers what the registry
    /// CLAIMS (names and denotations), and a solver budget changes how long the
    /// machine may look for the answer, never what the answer is.
    audit_timeout_ms: ?u32 = null,
};

// No unconditioned algebraic law survives the engine's polymorphic, coercing
// value model: every tempting equivalence is in `excluded_laws` below (machine-
// refuted). Asserting laws that hold only for a restricted operand type needs the
// reachability / type-precondition layer (the deferred faithful-model work), so
// this table is intentionally empty for now. Mechanism 5 still proves every value
// node's denote == exec(lower) and the refinements; the algebraic-law slot is
// where guarded laws will land once preconditions exist.
pub const algebraic_laws = [_]Law{};

/// Excluded laws: equivalences that are tempting but FALSE under the engine's
/// faithful value model, declared here so the exclusion is machine-checked rather
/// than only asserted in the SOUNDNESS BOUNDARY comment above. The audit
/// (`semantics_audit.zig`, via spec-check) encodes each over a faithful
/// tagged-value model and REQUIRES the solver to find a counterexample - if one
/// of these ever came back as actually holding, the build fails (the exclusion
/// was wrong, or the value model drifted). They reuse the `Law` shape; the audit
/// interprets them as non-laws.
pub const excluded_laws = [_]Law{
    // associativity of +  - holds over ℤ, fails on f64 rounding past 2^53.
    // Two orders of magnitude slower to refute than every other row here: the
    // counterexample needs three unconstrained `Val`s to land on a rounding
    // witness past 2^53. Measured 2026-08-26 on z3 5.1.0, idle, seven runs:
    // 28.78 28.81 28.91 29.07 29.16 29.76 29.82 seconds, and the same figures
    // under a 600-second ceiling, so that is the solve cost and not a timeout
    // artifact. 180 seconds is ~6x the slowest of those.
    .{
        .name = "add_associative",
        .audit_timeout_ms = 180_000,
        .lhs = &.{ .{ .child = 0 }, .{ .child = 1 }, .{ .binop = .add }, .{ .child = 2 }, .{ .binop = .add } },
        .rhs = &.{ .{ .child = 0 }, .{ .child = 1 }, .{ .child = 2 }, .{ .binop = .add }, .{ .binop = .add } },
    },
    // The three rows below refute on a type mix rather than a numeric search and
    // take the default budget. Measured the same day and the same way:
    // add_commutative 0.32s, not_involution and neg_involution under 0.01s.
    // commutativity of +  - generic `+` concatenates strings: "a"+"b" != "b"+"a".
    .{
        .name = "add_commutative",
        .lhs = &.{ .{ .child = 0 }, .{ .child = 1 }, .{ .binop = .add } },
        .rhs = &.{ .{ .child = 1 }, .{ .child = 0 }, .{ .binop = .add } },
    },
    // involution of !  - `!` coerces via truthiness, so `!!x` is a bool, not x.
    .{
        .name = "not_involution",
        .lhs = &.{ .{ .child = 0 }, .{ .unop = .not }, .{ .unop = .not } },
        .rhs = &.{.{ .child = 0 }},
    },
    // involution of unary -  - `-` coerces to number, so `-(-"5") === "5"` is
    // false (number 5 !== string "5"). Was previously asserted over the ℤ tier;
    // now machine-refuted here, removing the receipt over-claim.
    .{
        .name = "neg_involution",
        .lhs = &.{ .{ .child = 0 }, .{ .unop = .neg }, .{ .unop = .neg } },
        .rhs = &.{.{ .child = 0 }},
    },
};

/// Conformance diagnostic codes (ZTS75x). They live in the closed diagnostic
/// catalog rather than the policy rule registry, because conformance failures
/// identify compiler implementation faults rather than source-policy rules.
pub const SpecCode = diagnostic_catalog.SemanticsKind;

// ---------------------------------------------------------------------------
// Drift gate.
// ---------------------------------------------------------------------------

// The pinned size of each alphabet. The comptime gate fails the build when these
// no longer match the enums - the moment a NAMED NodeTag or Opcode is added or
// removed - so the author must specify the new member or consciously re-pin.
//
// Caveat (honest): `Opcode` is a NON-EXHAUSTIVE enum (bytecode.zig `_,`), so
// `fields.len` counts only named members. An opcode wired through the reserved
// numeric range without a named member would NOT trip this gate. In practice
// opcodes are always added as named members, but the guarantee is "named
// alphabet", not "every byte value". Rename/reorder at equal size is caught by
// the receipt's irTableHash/opcodeTableHash at check time. A per-member
// rule-or-pending list plus SMT-checked coverage is the northstar's version.
pub const expected_nodes = 69;
pub const expected_opcodes = 127;

comptime {
    const n = @typeInfo(NodeTag).@"enum".fields.len;
    if (n != expected_nodes) {
        @compileError(std.fmt.comptimePrint(
            "semantics drift: NodeTag has {d} named members, registry pinned to {d}. " ++
                "An IR node was added or removed - give it a rule in semantics.zig (or decide it is structural), then set expected_nodes = {d}.",
            .{ n, expected_nodes, n },
        ));
    }
    const m = @typeInfo(Opcode).@"enum".fields.len;
    if (m != expected_opcodes) {
        @compileError(std.fmt.comptimePrint(
            "semantics drift: Opcode has {d} named members, registry pinned to {d}. " ++
                "A bytecode opcode was added or removed - give it a transition in semantics.zig op_rules (or acknowledge it), then set expected_opcodes = {d}.",
            .{ m, expected_opcodes, m },
        ));
    }
}

// ---------------------------------------------------------------------------
// Hashes. `semanticsHash` mirrors rule_registry.policyHash: a stable SHA-256 over
// the canonicalized registry, covering every rule's denotation AND lowering, the
// operator->opcode maps, and the refinements - so a change to any declared
// meaning moves the hash. The table hashes pin the alphabets the registry is
// written against.
// ---------------------------------------------------------------------------

fn hashTerms(hasher: *std.crypto.hash.sha2.Sha256, terms: []const Term) void {
    for (terms) |t| {
        const tag_byte: u8 = @intCast(@intFromEnum(@as(std.meta.Tag(Term), t)));
        hasher.update(&[_]u8{tag_byte});
        switch (t) {
            .imm, .select, .binop_self, .unop_self => {},
            .child => |i| hasher.update(&[_]u8{i}),
            .local => |i| hasher.update(&[_]u8{i}),
            .call_result => |i| hasher.update(&[_]u8{i}),
            .binop => |k| hasher.update(&[_]u8{@intCast(@intFromEnum(k))}),
            .unop => |k| hasher.update(&[_]u8{@intCast(@intFromEnum(k))}),
        }
    }
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashSteps(hasher: *std.crypto.hash.sha2.Sha256, steps: []const Step) void {
    for (steps) |s| {
        const tag_byte: u8 = @intCast(@intFromEnum(@as(std.meta.Tag(Step), s)));
        hasher.update(&[_]u8{tag_byte});
        switch (s) {
            .push_imm, .op_self => {},
            .eval_child => |i| hasher.update(&[_]u8{i}),
            .push_local => |i| hasher.update(&[_]u8{i}),
            .call_site => |i| hasher.update(&[_]u8{i}),
            .op => |o| hasher.update(@tagName(o)),
        }
    }
}

fn hashTransition(hasher: *std.crypto.hash.sha2.Sha256, t: Transition) void {
    const tag_byte: u8 = @intCast(@intFromEnum(@as(std.meta.Tag(Transition), t)));
    hasher.update(&[_]u8{tag_byte});
    switch (t) {
        .binop => |k| hashU64(hasher, @intCast(@intFromEnum(k))),
        .unop => |k| hashU64(hasher, @intCast(@intFromEnum(k))),
        .control => {},
    }
}

fn hashLowering(hasher: *std.crypto.hash.sha2.Sha256, lower: Lowering) void {
    switch (lower) {
        .straight => |steps| {
            hasher.update("s");
            hashSteps(hasher, steps);
        },
        .branch => |b| {
            hasher.update("b");
            hashSteps(hasher, b.cond);
            hashSteps(hasher, b.then);
            hashSteps(hasher, b.else_);
            for (b.wiring) |w| hasher.update(@tagName(w));
        },
    }
}

var cached_semantics_hash: ?[64]u8 = null;

pub fn semanticsHash() [64]u8 {
    if (cached_semantics_hash) |h| return h;
    const h = computeSemanticsHash();
    cached_semantics_hash = h;
    return h;
}

fn computeSemanticsHash() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (node_rules) |r| {
        hasher.update(@tagName(r.tag));
        hasher.update("\x00");
        hasher.update(@tagName(r.proof));
        hasher.update("\x00");
        hasher.update(@tagName(r.parametric));
        hasher.update("\x00");
        hashTerms(&hasher, r.denote);
        if (r.lower) |l| hashLowering(&hasher, l);
        hasher.update("\x01");
    }
    for (op_rules) |r| {
        hasher.update(@tagName(r.op));
        hasher.update("\x00");
        hashTransition(&hasher, r.t);
        hasher.update("\x01");
    }
    // operator -> opcode maps (so changing binOpcode/unOpcode moves the hash).
    inline for (std.meta.tags(BinKind)) |k| {
        hasher.update(@tagName(k));
        hasher.update(@tagName(binOpcode(k)));
    }
    inline for (std.meta.tags(UnKind)) |k| {
        hasher.update(@tagName(k));
        hasher.update(@tagName(unOpcode(k)));
    }
    for (refinements) |rf| {
        hasher.update(@tagName(rf.fused));
        hasher.update("\x00");
        hashSteps(&hasher, rf.fused_effect);
        hasher.update("\x00");
        hashSteps(&hasher, rf.base);
        hasher.update("\x01");
    }
    // The assurance boundary is semantic content too. Hash every named member,
    // its disposition, and the exact reason that keeps it in a trusted or
    // translation-validated boundary.
    hasher.update("node-dispositions\x00");
    inline for (@typeInfo(NodeTag).@"enum".fields) |field| {
        const disposition = nodeDisposition(@enumFromInt(field.value));
        hasher.update(field.name);
        hasher.update("\x00");
        hasher.update(@tagName(disposition.kind));
        hasher.update("\x00");
        hasher.update(disposition.reason);
        hasher.update("\x01");
    }
    hasher.update("opcode-dispositions\x00");
    inline for (@typeInfo(Opcode).@"enum".fields) |field| {
        const disposition = opcodeDisposition(@enumFromInt(field.value));
        hasher.update(field.name);
        hasher.update("\x00");
        hasher.update(@tagName(disposition.kind));
        hasher.update("\x00");
        hasher.update(disposition.reason);
        hasher.update("\x01");
    }
    // algebraic laws (the SMT-certified non-structural equivalences) are spec
    // content too, so a change to any law moves the hash.
    for (algebraic_laws) |law| {
        hasher.update(law.name);
        hasher.update("\x00");
        hashTerms(&hasher, law.lhs);
        hasher.update("\x00");
        hashTerms(&hasher, law.rhs);
        hasher.update("\x01");
    }
    // excluded laws (machine-refuted non-laws) are spec content too: the claim
    // "these are NOT laws" is part of the soundness boundary.
    hasher.update("excluded\x00");
    for (excluded_laws) |law| {
        hasher.update(law.name);
        hasher.update("\x00");
        hashTerms(&hasher, law.lhs);
        hasher.update("\x00");
        hashTerms(&hasher, law.rhs);
        hasher.update("\x01");
    }
    const digest = hasher.finalResult();
    return std.fmt.bytesToHex(digest, .lower);
}

/// SHA-256 over the IR alphabet (every named `NodeTag` member, in order).
pub fn irTableHash() [64]u8 {
    return enumTableHash(NodeTag);
}

/// SHA-256 over the bytecode alphabet (every named `Opcode` member and value).
pub fn opcodeTableHash() [64]u8 {
    return enumTableHash(Opcode);
}

fn enumTableHash(comptime E: type) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (@typeInfo(E).@"enum".fields) |f| {
        hasher.update(f.name);
        hasher.update("\x00");
        hashU64(&hasher, @intCast(f.value));
        hasher.update("\x00");
    }
    const digest = hasher.finalResult();
    return std.fmt.bytesToHex(digest, .lower);
}

fn transitionHashForTest(t: Transition) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTransition(&hasher, t);
    const digest = hasher.finalResult();
    return std.fmt.bytesToHex(digest, .lower);
}

/// Total classification coverage and its assurance breakdown. `reachable`
/// includes every named member except an explicitly unreachable one.
pub const Coverage = struct {
    nodes_total: usize,
    nodes_reachable: usize,
    nodes_classified: usize,
    nodes_specified: usize,
    nodes_translation_validated: usize,
    nodes_trusted: usize,
    nodes_unreachable: usize,
    opcodes_total: usize,
    opcodes_reachable: usize,
    opcodes_classified: usize,
    opcodes_specified: usize,
    opcodes_translation_validated: usize,
    opcodes_trusted: usize,
    opcodes_unreachable: usize,
};

pub fn coverage() Coverage {
    var result = Coverage{
        .nodes_total = @typeInfo(NodeTag).@"enum".fields.len,
        .opcodes_total = @typeInfo(Opcode).@"enum".fields.len,
        .nodes_reachable = 0,
        .nodes_classified = 0,
        .nodes_specified = 0,
        .nodes_translation_validated = 0,
        .nodes_trusted = 0,
        .nodes_unreachable = 0,
        .opcodes_reachable = 0,
        .opcodes_classified = 0,
        .opcodes_specified = 0,
        .opcodes_translation_validated = 0,
        .opcodes_trusted = 0,
        .opcodes_unreachable = 0,
    };
    inline for (@typeInfo(NodeTag).@"enum".fields) |field| {
        addNodeDisposition(&result, nodeDisposition(@enumFromInt(field.value)).kind);
    }
    inline for (@typeInfo(Opcode).@"enum".fields) |field| {
        addOpcodeDisposition(&result, opcodeDisposition(@enumFromInt(field.value)).kind);
    }
    return result;
}

fn addNodeDisposition(result: *Coverage, kind: DispositionKind) void {
    switch (kind) {
        .specified => {
            result.nodes_reachable += 1;
            result.nodes_classified += 1;
            result.nodes_specified += 1;
        },
        .translation_validated => {
            result.nodes_reachable += 1;
            result.nodes_classified += 1;
            result.nodes_translation_validated += 1;
        },
        .trusted => {
            result.nodes_reachable += 1;
            result.nodes_classified += 1;
            result.nodes_trusted += 1;
        },
        .not_reachable => result.nodes_unreachable += 1,
        .unclassified => result.nodes_reachable += 1,
    }
}

fn addOpcodeDisposition(result: *Coverage, kind: DispositionKind) void {
    switch (kind) {
        .specified => {
            result.opcodes_reachable += 1;
            result.opcodes_classified += 1;
            result.opcodes_specified += 1;
        },
        .translation_validated => {
            result.opcodes_reachable += 1;
            result.opcodes_classified += 1;
            result.opcodes_translation_validated += 1;
        },
        .trusted => {
            result.opcodes_reachable += 1;
            result.opcodes_classified += 1;
            result.opcodes_trusted += 1;
        },
        .not_reachable => result.opcodes_unreachable += 1,
        .unclassified => result.opcodes_reachable += 1,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "drift gate is pinned to the real enums" {
    try std.testing.expectEqual(expected_nodes, @typeInfo(NodeTag).@"enum".fields.len);
    try std.testing.expectEqual(expected_opcodes, @typeInfo(Opcode).@"enum".fields.len);

    const c = coverage();
    try std.testing.expectEqual(c.nodes_reachable, c.nodes_classified);
    try std.testing.expectEqual(c.opcodes_reachable, c.opcodes_classified);
    try std.testing.expectEqual(c.nodes_total, c.nodes_reachable + c.nodes_unreachable);
    try std.testing.expectEqual(c.opcodes_total, c.opcodes_reachable + c.opcodes_unreachable);
    try std.testing.expect(c.nodes_specified > 0);
    try std.testing.expect(c.opcodes_specified > 0);
    try std.testing.expect(c.nodes_trusted > 0);
    try std.testing.expect(c.opcodes_trusted > 0);
    try std.testing.expect(c.opcodes_translation_validated > 0);
    try std.testing.expectEqual(c.nodes_classified, c.nodes_specified + c.nodes_translation_validated + c.nodes_trusted);
    try std.testing.expectEqual(c.opcodes_classified, c.opcodes_specified + c.opcodes_translation_validated + c.opcodes_trusted);
}

test "reserved opcode values remain unclassified" {
    const reserved: Opcode = @enumFromInt(0xff);
    try std.testing.expectEqual(DispositionKind.unclassified, opcodeDisposition(reserved).kind);
}

test "hashes are deterministic and well-formed" {
    const a = semanticsHash();
    const b = semanticsHash();
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expectEqual(@as(usize, 64), a.len);
    try std.testing.expect(!std.mem.eql(u8, &irTableHash(), &opcodeTableHash()));
}

test "semantics hash input distinguishes transition payloads" {
    const add = transitionHashForTest(.{ .binop = .add });
    const sub = transitionHashForTest(.{ .binop = .sub });
    const not = transitionHashForTest(.{ .unop = .not });

    try std.testing.expect(!std.mem.eql(u8, &add, &sub));
    try std.testing.expect(!std.mem.eql(u8, &add, &not));
}

fn hasLawForTest(name: []const u8) bool {
    for (algebraic_laws) |law| {
        if (std.mem.eql(u8, law.name, name)) return true;
    }
    return false;
}

fn hasExcludedForTest(name: []const u8) bool {
    for (excluded_laws) |law| {
        if (std.mem.eql(u8, law.name, name)) return true;
    }
    return false;
}

test "JS coercive identities are excluded, not asserted" {
    // None of these hold under the engine's polymorphic, coercing value model, so
    // none may be an asserted algebraic law; each must instead be an excluded law
    // the faithful audit refutes. neg_involution moved here from the law table
    // once the audit existed (string coercion: -(-"5") !== "5").
    for ([_][]const u8{ "add_commutative", "not_involution", "neg_involution", "add_associative" }) |name| {
        try std.testing.expect(!hasLawForTest(name));
        try std.testing.expect(hasExcludedForTest(name));
    }
    // The law table is intentionally empty until the reachability layer lands.
    try std.testing.expectEqual(@as(usize, 0), algebraic_laws.len);
}

test "table hashes include enum discriminants" {
    const A = enum(u8) {
        first = 1,
        second = 2,
    };
    const B = enum(u8) {
        first = 2,
        second = 1,
    };

    const a = enumTableHash(A);
    const b = enumTableHash(B);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "every value rule carries denotation and lowering" {
    // The structural fix: meaning lives in the registry, not the checker - so the
    // hash covers it. Assert no value rule is a bare marker.
    for (node_rules) |r| {
        switch (r.proof) {
            .value => {
                try std.testing.expect(r.denote.len > 0);
                try std.testing.expect(r.lower != null);
            },
            .structural => {
                try std.testing.expect(r.denote.len == 0);
                try std.testing.expect(r.lower == null);
            },
        }
    }
}

test "term structural equality" {
    try std.testing.expect(Term.eql(.imm, .imm));
    try std.testing.expect(Term.eql(.{ .child = 1 }, .{ .child = 1 }));
    try std.testing.expect(!Term.eql(.{ .child = 1 }, .{ .child = 2 }));
    try std.testing.expect(!Term.eql(.imm, .select));
    try std.testing.expect(termsEql(&.{.{ .child = 0 }}, &.{.{ .child = 0 }}));
    try std.testing.expect(!termsEql(&.{.{ .child = 0 }}, &.{.{ .child = 1 }}));
}
