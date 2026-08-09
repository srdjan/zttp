// zts semantics spec - GENERATED from packages/zts/src/semantics.zig.
// Do not edit by hand; run `zts spec-render` to regenerate.
//
// semanticsHash:   8016a0a7dfdc21d4c988c734baa8b067996d70da5defc098e70b14f4593f77a0
// irTableHash:     851089d85fc76ed9e2d6bd245c23a558d6995591deb5c4e2b01382212e2434c1
// opcodeTableHash: 6821f0d79ecd2d45211219f8a003bac9d2fea9d2409449d06d5173f935e76b00
//
// Coverage: 12/82 IR nodes, 7/130 bytecode opcodes specified.
// `denote` is what the node computes; `lower` is the bytecode it compiles to.
// A value node's lower, symbolically executed, equals its denote (spec-check
// mechanism 3), and the real compiler agrees on a corpus (mechanism 4).

// operator -> opcode
export const binOpcode = { add: "add", sub: "sub", mul: "mul", lt: "lt", eq: "eq" };
export const unOpcode = { not: "not", neg: "neg" };

// lit_int: value node
export const lit_int = {
  proof: "value",
  denote: (imm) => imm,
  lower: "imm",
};

// lit_bool: value node
export const lit_bool = {
  proof: "value",
  denote: (imm) => imm,
  lower: "imm",
};

// lit_null: value node
export const lit_null = {
  proof: "value",
  denote: () => imm,
  lower: "imm",
};

// identifier: value node
export const identifier = {
  proof: "value",
  denote: (locals) => locals[0],
  lower: "get_loc[0]",
};

// binary_op: value node (generic over its binop; <op> ranges over the map above)
export const binary_op = {
  proof: "value",
  parametric: "binop",
  denote: (c0, c1) => (c0 <op> c1),
  lower: "eval(c0); eval(c1); <op>",
};

// unary_op: value node (generic over its unop; <op> ranges over the map above)
export const unary_op = {
  proof: "value",
  parametric: "unop",
  denote: (c0) => (<op>c0),
  lower: "eval(c0); <op>",
};

// ternary: value node
export const ternary = {
  proof: "value",
  denote: (c0, c1, c2) => (c0 ? c1 : c2),
  lower: { cond: "eval(c0)", then: "eval(c1)", else: "eval(c2)", wiring: ["if_false", "goto"] },
};

// call: value node
export const call = {
  proof: "value",
  denote: () => call0(),
  lower: "call0()",
};

// match_type_test: statement / non-value (structural-only in this slice)
export const match_type_test = { proof: "structural" };

// if_stmt: statement / non-value (structural-only in this slice)
export const if_stmt = { proof: "structural" };

// return_stmt: statement / non-value (structural-only in this slice)
export const return_stmt = { proof: "structural" };

// block: statement / non-value (structural-only in this slice)
export const block = { proof: "structural" };

// fused-opcode refinements (each must equal its base sequence)
// get_loc_add:  (get_loc[0]; add)  ==  (get_loc[0]; add)

// algebraic laws - SMT-certified value-model equivalences (mechanism 5)

// excluded laws - REFUTED under the faithful value model (false on the engine)
// add_associative:  ((c0 + c1) + c2)  !=  (c0 + (c1 + c2))
// add_commutative:  (c0 + c1)  !=  (c1 + c0)
// not_involution:  (!(!c0))  !=  c0
// neg_involution:  (-(-c0))  !=  c0
