// zts semantics spec - GENERATED from packages/zts/src/semantics.zig.
// Do not edit by hand; run `zts spec-render` to regenerate.
//
// semanticsHash:   83b822bd0dee8e5f9a9231501f0f95b34fa48a0f08c671ade7a8bee822b877b8
// irTableHash:     78e7a99405de0a7f01baec7a599af5221c540b0b8045340e596fe48d226383f3
// opcodeTableHash: d3354fa6676c42bd2855e423c339001d2bf8f1d008e6270c5a0ab1170b96478c
//
// Coverage: 69/69 reachable IR nodes and 127/127 reachable bytecode opcodes classified.
// IR assurance: 12 specified, 0 translation-validated, 57 trusted, 0 unreachable.
// Opcode assurance: 7 specified, 1 translation-validated, 119 trusted, 0 unreachable.
// `denote` is what the node computes; `lower` is the bytecode it compiles to.
// A value node's lower, symbolically executed, equals its denote (spec-check
// mechanism 3), and the real compiler agrees on a corpus (mechanism 4).

// operator -> opcode
export const binOpcode = { add: "add", sub: "sub", mul: "mul", lt: "lt", eq: "eq" };
export const unOpcode = { not: "not", neg: "neg" };

export const nodeAssurance = {
  lit_int: { disposition: "specified", reason: "executable denotation and lowering rule" },
  lit_float: { disposition: "trusted", reason: "literal representation and constant-pool lowering remain in the compiler and VM TCB" },
  lit_string: { disposition: "trusted", reason: "literal representation and constant-pool lowering remain in the compiler and VM TCB" },
  lit_bool: { disposition: "specified", reason: "executable denotation and lowering rule" },
  lit_null: { disposition: "specified", reason: "executable denotation and lowering rule" },
  lit_undefined: { disposition: "trusted", reason: "literal representation and constant-pool lowering remain in the compiler and VM TCB" },
  identifier: { disposition: "specified", reason: "executable denotation and lowering rule" },
  binary_op: { disposition: "specified", reason: "executable denotation and lowering rule" },
  unary_op: { disposition: "specified", reason: "executable denotation and lowering rule" },
  ternary: { disposition: "specified", reason: "executable denotation and lowering rule" },
  call: { disposition: "specified", reason: "executable denotation and lowering rule" },
  method_call: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  member_access: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  computed_access: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  optional_chain: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  assignment: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  array_literal: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  object_literal: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  object_property: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  object_method: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  object_getter: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  object_setter: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  object_spread: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  function_expr: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  arrow_function: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  spread: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  await_expr: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  yield_expr: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  sequence_expr: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  comma_expr: { disposition: "trusted", reason: "typed expression lowering remains in the compiler and VM TCB; bytecode verification checks its stack contract" },
  match_expr: { disposition: "trusted", reason: "match-pattern elaboration remains in the checker TCB and lowers to ordinary core tests and bindings" },
  match_arm: { disposition: "trusted", reason: "match-pattern elaboration remains in the checker TCB and lowers to ordinary core tests and bindings" },
  match_pattern: { disposition: "trusted", reason: "match-pattern elaboration remains in the checker TCB and lowers to ordinary core tests and bindings" },
  match_type_test: { disposition: "specified", reason: "executable denotation and lowering rule" },
  expr_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  var_decl: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  if_stmt: { disposition: "specified", reason: "executable denotation and lowering rule" },
  for_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  for_of_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  for_in_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  while_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  do_while_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  switch_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  case_clause: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  return_stmt: { disposition: "specified", reason: "executable denotation and lowering rule" },
  assert_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  throw_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  break_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  continue_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  try_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  block: { disposition: "specified", reason: "executable denotation and lowering rule" },
  labeled_stmt: { disposition: "trusted", reason: "control-flow lowering remains in the compiler and VM TCB; bytecode verification checks targets and stack joins" },
  function_decl: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  array_pattern: { disposition: "trusted", reason: "match-pattern elaboration remains in the checker TCB and lowers to ordinary core tests and bindings" },
  pattern_element: { disposition: "trusted", reason: "match-pattern elaboration remains in the checker TCB and lowers to ordinary core tests and bindings" },
  pattern_rest: { disposition: "trusted", reason: "match-pattern elaboration remains in the checker TCB and lowers to ordinary core tests and bindings" },
  pattern_default: { disposition: "trusted", reason: "match-pattern elaboration remains in the checker TCB and lowers to ordinary core tests and bindings" },
  import_decl: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  import_specifier: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  import_default: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  import_namespace: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  export_decl: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  export_specifier: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  export_default: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  export_all: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  program: { disposition: "trusted", reason: "parser-only structural container with no independent runtime denotation" },
  param_list: { disposition: "trusted", reason: "parser-only structural container with no independent runtime denotation" },
  arg_list: { disposition: "trusted", reason: "parser-only structural container with no independent runtime denotation" },
  stmt_list: { disposition: "trusted", reason: "parser-only structural container with no independent runtime denotation" },
} as const;

export const opcodeAssurance = {
  nop: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_const: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_0: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_1: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_2: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_3: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_i8: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_i16: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_null: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_undefined: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_true: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  push_false: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  dup: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  drop: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  swap: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  rot3: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  halt: { disposition: "trusted", reason: "VM control transition remains in the execution TCB and has verifier-checked targets and stack effects" },
  loop: { disposition: "trusted", reason: "VM control transition remains in the execution TCB and has verifier-checked targets and stack effects" },
  get_length: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  dup2: { disposition: "trusted", reason: "VM stack transition remains in the execution TCB and has verifier-owned arity metadata" },
  get_loc: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  put_loc: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  get_loc_0: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  get_loc_1: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  get_loc_2: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  get_loc_3: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  put_loc_0: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  put_loc_1: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  put_loc_2: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  put_loc_3: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  add: { disposition: "specified", reason: "executable denotation and lowering rule" },
  sub: { disposition: "specified", reason: "executable denotation and lowering rule" },
  mul: { disposition: "specified", reason: "executable denotation and lowering rule" },
  div: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  mod: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  pow: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  neg: { disposition: "specified", reason: "executable denotation and lowering rule" },
  inc: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  dec: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  math_floor: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  math_ceil: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  math_round: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  math_abs: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  math_min2: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  math_max2: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  bit_and: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  bit_or: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  bit_xor: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  bit_not: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  shl: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  shr: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  ushr: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  lt: { disposition: "specified", reason: "executable denotation and lowering rule" },
  lte: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  gt: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  gte: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  eq: { disposition: "specified", reason: "executable denotation and lowering rule" },
  neq: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  strict_eq: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  strict_neq: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  not: { disposition: "specified", reason: "executable denotation and lowering rule" },
  goto: { disposition: "trusted", reason: "VM control transition remains in the execution TCB and has verifier-checked targets and stack effects" },
  if_true: { disposition: "trusted", reason: "VM control transition remains in the execution TCB and has verifier-checked targets and stack effects" },
  if_false: { disposition: "trusted", reason: "VM control transition remains in the execution TCB and has verifier-checked targets and stack effects" },
  ret: { disposition: "trusted", reason: "VM control transition remains in the execution TCB and has verifier-checked targets and stack effects" },
  ret_undefined: { disposition: "trusted", reason: "VM control transition remains in the execution TCB and has verifier-checked targets and stack effects" },
  call: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  call_method: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  tail_call: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  get_field: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  put_field: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  get_elem: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  put_elem: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  put_elem_keep: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  put_field_keep: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  new_object: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  new_array: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  new_object_literal: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  get_global: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  put_global: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  define_global: { disposition: "trusted", reason: "binding and module lowering remain in the compiler TCB; static resolution and bytecode verification guard the boundary" },
  make_function: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  array_spread: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  call_spread: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  object_spread: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  typeof: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  import_module: { disposition: "trusted", reason: "static module transition remains in the VM TCB behind the resolved module graph" },
  import_name: { disposition: "trusted", reason: "static module transition remains in the VM TCB behind the resolved module graph" },
  import_default: { disposition: "trusted", reason: "static module transition remains in the VM TCB behind the resolved module graph" },
  export_name: { disposition: "trusted", reason: "static module transition remains in the VM TCB behind the resolved module graph" },
  export_default: { disposition: "trusted", reason: "static module transition remains in the VM TCB behind the resolved module graph" },
  get_loc_add: { disposition: "translation_validated", reason: "translation validation proves the fused opcode equivalent to its declared base sequence" },
  get_loc_get_loc_add: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  push_const_call: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  get_field_call: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  if_false_goto: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  add_mod: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  sub_mod: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  mul_mod: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  for_of_next: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  for_of_next_put_loc: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  shr_1: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  mul_2: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  mod_const: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  mod_const_i8: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  add_const_i8: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  sub_const_i8: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  get_field_ic: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  put_field_ic: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  call_ic: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  mul_const_i8: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  lt_const_i8: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  le_const_i8: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
  get_upvalue: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  put_upvalue: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  close_upvalue: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  make_closure: { disposition: "trusted", reason: "call and closure transition remains in the VM TCB behind typed call-site and capability checks" },
  set_slot: { disposition: "trusted", reason: "object and property transition remains in the VM TCB behind shape and stack verification" },
  add_num: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  sub_num: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  mul_num: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  div_num: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  lt_num: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  gt_num: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  lte_num: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  gte_num: { disposition: "trusted", reason: "typed numeric transition remains in the VM TCB and has verifier-owned arity metadata" },
  drop_goto: { disposition: "trusted", reason: "optimized transition remains in the VM TCB and is guarded by bytecode verification and optimizer tests" },
} as const;

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
