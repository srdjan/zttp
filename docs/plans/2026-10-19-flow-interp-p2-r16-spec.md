# Flow redesign: R16 precision freeze and P2 evaluator core

Status: specification for implementation, 2026-10-19, revised after one Codex
astra validation round (a fact check and an argument review). The owner
approved the R16 precision expectations and the P2 implementation. Parent plan:
[the flow checker redesign](2026-10-18-flow-checker-sound-redesign-plan.md).
Its round 2 and round 3 revisions override its earlier sections, and this
document follows them. R9 holds: P2 runs in shadow only and changes no verdict,
so `flow_analyzer_version` and the policy hash do not move.

The two parts are independent. They touch different files and can be built in
parallel.

## Prerequisite: two runtime defects

The argument review found two places where the runtime returns a value the
analysis cannot see. Both were confirmed under `zttp serve` on 2026-10-19:
`zts check` proved `no_secret_leakage`, and the response body was the secret.

1. A failed `assert cond;` without a message emits `halt`
   (`parser/codegen.zig` `emitAssert`), and `halt` returns the stack top
   (`interpreter.zig` 201). A local that holds a secret becomes the body.
2. `let b;` without an initializer emits nothing (`emitVarDecl`). Sibling
   blocks reuse local slots (`parser/scope.zig` 159), so `b` reads the value an
   earlier block left in its slot.

A separate commit fixes both in code generation: `let` without an initializer
stores `undefined`, and a failed `assert` without a message pushes `undefined`
before `halt`, so the handler returns no Response and the request fails. P2's
rules for both forms assume these fixes.

## Part A: R16 precision expectations

### Purpose

R16 freezes, before P2 starts, the properties that representative handlers must
prove. P9 may not switch to the new interpreter until it meets them. Every
difference from the old checker needs a written disposition before the switch.
Today the old checker must meet them too, so the freeze is a running test from
the first commit.

### Corpus

Three groups, with the baseline measured with `zts check --json`
(`proofTrace` entries of kind `flow-trace`) and reproduced by the fact check:

1. The example handlers under `examples/`, read in place at test time. The test
   reads repository-relative paths, as `packages/zts/src/tests/asi_census.zig`
   does. That works when the test runs from the repository root, which is how
   `zig build` invokes it; the build graph does not set the directory itself.
2. The 13 committed DeepSeek codegen handlers. A re-record changes their paths
   and contents, so the freeze holds a copy. Copy each case's whole
   `generations/<hash>/expected/` directory, with its helper files (`lib/`) and
   `schema.sql`, to
   `packages/tools/tests/fixtures/flow_precision/corpus/<case>/`. Relative
   imports resolve from the handler's directory
   (`precompile.zig` 838 and 297), so the tree must keep its shape. A `SOURCE`
   file in each copy names the generation hash it came from.
3. Four handwritten authenticated handlers in
   `packages/tools/tests/fixtures/flow_precision/auth/`. All four prove the five
   flow properties today. `auth_branch_selected_message.ts` chooses its
   response by comparing a secret, so it pins the explicit-flow policy (D9
   Option A).

### Expectations

The flow properties are `no_secret_leakage`, `no_credential_leakage`,
`input_validated`, `pii_contained`, and `injection_safe`. For each handler,
the expectation is the set of these properties that the old checker proves on
the baseline. A property that the old checker leaves unproven gets no
expectation: the new checker may prove more.

Baseline (1 = proven):

| Handler | secret | credential | validated | pii | injection |
|---|---|---|---|---|---|
| examples/autoloop/handler.ts | 0 | 1 | 1 | 1 | 1 |
| examples/fetch/weather-app.ts | 1 | 1 | 0 | 0 | 0 |
| examples/fetch/weather-forecasts.ts | 1 | 1 | 1 | 1 | 1 |
| examples/fetch/webhook.ts | 0 | 0 | 0 | 0 | 0 |
| examples/handler/effects-capsule.ts | 1 | 1 | 1 | 1 | 1 |
| examples/handler/handler-with-imports.ts | 1 | 1 | 1 | 1 | 1 |
| examples/handler/handler.ts | 1 | 1 | 1 | 1 | 1 |
| examples/handler/secret-leak.ts | 0 | 1 | 1 | 1 | 1 |
| examples/handler/spec-fails-idempotent.ts | 1 | 1 | 1 | 1 | 1 |
| examples/handler/spec-guardrails.ts | 1 | 1 | 1 | 1 | 1 |
| examples/handler/sugar.ts | 0 | 0 | 1 | 1 | 1 |
| examples/modules/modules.ts | 1 | 1 | 1 | 1 | 1 |
| examples/modules/modules_all.ts | 0 | 0 | 1 | 1 | 1 |
| examples/patterns/*.ts (13 files) | 1 | 1 | 1 | 1 | 1 |
| examples/routing/api-surface.ts | 1 | 1 | 1 | 1 | 1 |
| examples/routing/guard-flow.ts | 0 | 0 | 1 | 1 | 1 |
| examples/routing/match-handler.ts | 1 | 1 | 1 | 1 | 1 |
| examples/routing/router.ts | 1 | 1 | 1 | 1 | 1 |
| examples/sql/sql-crud.ts with `examples/sql/schema.sql` | 0 | 0 | 1 | 1 | 1 |
| corpus sql-users with its `schema.sql` | 0 | 0 | 1 | 1 | 1 |
| corpus cache-counter, cache-counter-holes | 0 | 0 | 1 | 1 | 1 |
| corpus (the other 10) | 1 | 1 | 1 | 1 | 1 |
| auth (4 files) | 1 | 1 | 1 | 1 | 1 |

`examples/fetch/webhook.ts` is a legitimate row with no expectation: it stays
in the manifest so that a later proof is visible in review.

No flow verdict: `examples/handler/feature-probes.ts` and
`examples/handler/utils.ts` (a helper module, not a handler). The file header
lists both with the reason. Any baseline row that the test harness does not
reproduce is reported to the reviewer, not dropped.

### Test

A new file `packages/tools/src/flow_precision_expectations.zig`, imported from
the `test` block in `packages/tools/src/precompile.zig` that imports
`flow_false_proofs.zig`, so it runs under `zig build test-precompile`.

- `Entry`: `path` (repository-relative), `expect` (a fixed set of the five
  properties), `sql_schema_path` (optional).
- The verdict reader reads `CheckResult.stages_run` (the flow stage must have
  run) and `CheckResult.properties` (must be non-null), then the boolean for the
  property. Either missing is a test failure that names the path. It does not
  use `flow_census_gate.classify`, because `classify` treats a false property
  without a matching claim failure, and any non-flow error, as no verdict;
  the examples carry no `Proof<...>` claims and some have non-flow errors.
- Test 1 (manifest): the paths are unique; the entry count equals a frozen
  constant; the total number of expected property bits equals a second frozen
  constant; every listed file is read. Either constant changes only with a
  commit message that gives the reason.
- Test 2 (expectations): every expected property holds, except entries in
  `old_checker_misses`, which is empty today. Each row of that table carries a
  written reason. A test holds the table equal to the observed misses. The
  table exempts the old checker only: the P9 gate checks every expectation
  with no exemption.
- File header: the R16 rule and the excluded handlers with reasons.

`docs/internals/testing.md` gets one paragraph beside the P0 paragraph.

## Part B: P2 evaluator core

### Scope

P2 builds the abstract domain, the location scheme, field-sensitive heap cells,
and the evaluator for expressions without calls, with `exec` for blocks,
declarations, assignment, `if`, `return`, and `assert`. It runs in shadow: no
pipeline, CLI, or verdict reads it. Later phases own loops (P3), calls and
captures (P4), operation edges and callbacks (P5), defenses (P6), request
contents and sinks (P7), and persistence and imported summaries (P8). Every
construct owned by a later phase gets the conservative rule now: it clears every
flow property.

### Placement

- New file `packages/zts/src/flow_interp.zig`.
- `packages/zts/src/compiler_root.zig`: `pub const flow_interp =
  @import("flow_interp.zig");`, so `refAllDecls` runs its tests under
  `zig build test-zts`.
- `scripts/zts-tiers.allow`: row `zts-compiler flow_interp.zig`. Run
  `zig build test-zts-layering`.
- Not added to `packages/zts/src/root.zig`: no consumer exists before P9.
- `scripts/check-proof-swallow.sh`: add the file to `proof_files` now, so no
  discarded error enters it unreviewed. Change "the sixteen listed" in
  `AGENTS.md` to "the seventeen listed". Run `zig build test-proof-swallow`.

### Memory

`FlowInterp` owns an `std.heap.ArenaAllocator`. Values, sets, cells, and state
copies are arena allocations and are immutable once built. A join builds new
storage. `deinit` frees the arena. The analysis is bounded per program, so
arena growth is bounded.

### Domain

- `SiteKey`: `{ kind: enum { literal, function, request, headers }, node:
  NodeIndex, context: u16 }`. P2 creates `literal` sites (array and object
  literals) and `function` sites (function objects, which are mutable at
  runtime, `object.zig` 1753), with `context = 0`. The `request` and `headers`
  kinds exist so that P7 can model R4 as synthetic containers. There is no
  separate carrier field: a request is a value whose origins include the
  request site.
- `Value`:
  - `labels: LabelSet` (the type in `packages/zts/src/module_binding/types.zig`);
  - `origins`: a sorted, deduplicated slice of `SiteKey`, plus
    `origins_top: bool`;
  - `callables`: a sorted, deduplicated slice of function-expression
    `NodeIndex`, plus `callables_top: bool`.
  - Constructors: `clean`, `labelled(LabelSet)`, `top` (labels `unknown`,
    `origins_top`, `callables_top`).
- Bottom is the absence of a value (`?Value` is `null`), never an empty value.
  `join(?Value, ?Value) ?Value` returns the other operand when one is `null`.
  Otherwise labels use `LabelSet.mergeConditional`, and the other parts take the
  set union with the `top` flags ORed.
- Combination inside one expression (an operator over operands) uses
  `LabelSet.mergeValues` on the labels and yields no origins and no callables:
  the result of an arithmetic operator, a comparison, or a unary operator is a
  fresh primitive.
- `Cells`: a map from property-name atom (`u16`) to `Value`, plus a `summary:
  ?Value` for unknown names and for every array element.
- `State`: `env` (map from `packBindingKey(scope_id, slot)` to `Value`),
  `heap` (map from `SiteKey` to `Cells`), and `top_cell: Cells` (writes whose
  target origin is `top`). A state is reachable or bottom; bottom is a separate
  flag, and `join(bottom, s) = s`.
- State join: union of keys; matching keys join; a key present on one side keeps
  its value (a binding declared in one branch is out of scope after it). A heap
  field missing on one side stands for a reachable `undefined`, not for bottom;
  P6 must keep that distinction when it joins defense facts.

### Reads and writes (R14)

Let `o` be the receiver value and `k` the key value of a computed access.

- Cells a static read of name `n` can see: for each origin, `cells[n]` and
  `summary`; always `top_cell[n]` and `top_cell.summary`; and, if
  `origins_top`, every cell of every heap site.
- Cells a dynamic read can see (a computed key that is not a string literal):
  every cell and the summary of each origin; every cell of `top_cell`; and, if
  `origins_top`, every cell of every heap site.
- A computed key that is a string literal is a static read of that name.
- The read result is the join of the visible cells (full values: labels,
  origins, callables). Its labels are then combined by `mergeValues` with
  `o.labels`, and for a computed access with `k.labels`. A property of a
  labelled value (`secret.length`) and a selection by a labelled key
  (`table[secret]`) carry the label (R1).
- A write of `v` to `o.n` or `o[k]` stores `v'`: `v` with its labels combined by
  `mergeValues` with `o.labels` and, for a computed key, `k.labels`, and with
  `v`'s origins and callables kept. A target chosen by a labelled receiver or
  key carries the label into the cell. The assignment expression's own value is
  `v`, not `v'`.
- Write targets: for each origin, `cells[n] = join(cells[n], v')` for a static
  name, and `summary = join(summary, v')` for a dynamic key. This is a weak
  update: one site stands for every object it creates. If `origins_top`, the
  write goes to `top_cell` the same way.
- A write never removes labels from a cell. A read never reads less than every
  cell that the key can name.

### Evaluation order

The analysis evaluates in the order that code generation does
(`parser/codegen.zig` 1231 and nearby), and evaluates each operand once:

- binary operators: left, then right;
- member and computed assignment: receiver, then key, then the right side;
  the receiver and key values are kept and used for the write (and, with a
  compound operator, for the read before it), so a right side that reassigns
  the receiver's binding does not move the write;
- computed read: receiver, then key;
- array elements and object properties: in source order, including spreads;
- call: callee, then arguments in order.

### Expressions (`eval(node, *State) Value`)

| Tag | Rule |
|---|---|
| `lit_*` | `clean` |
| `identifier` | `local` and `argument` kinds: `env` lookup by packed key; a missing key is `top` with an unresolved record. `upvalue`, `global`, `undeclared_global`: `top` and unresolved (P4 owns captures, P8 module state) |
| `binary_op`, op not `.and_op`, `.or_op`, `.nullish` | both operands in order; `mergeValues` |
| `binary_op` `.and_op`, `.or_op`, `.nullish` | left evaluated; right evaluated in a copy of the state; resulting state = join(after left, after right); value = join(left, right) |
| `unary_op` | operand evaluated; its labels kept, no origins or callables |
| `ternary` | condition evaluated (effects only); each arm in a copy of the state; value and state are the joins |
| `member_access` | static read |
| `optional_chain` | a `MemberExpr` with `is_optional` (the parser refuses optional computed access and optional calls): the static read, joined with `clean` for the short circuit; the state is the join of the states before and after the read |
| `computed_access` | static or dynamic read as above |
| `assignment` | target `identifier` of kind `local` or `argument`: strong update of `env`. Target of kind `upvalue` or `global`: unresolved (P4, P8). Member or computed target: a heap write. With `AssignExpr.op` non-null (a compound operator), read the target through the kept reference, combine with `mergeValues`, then write. The expression value is the assigned value |
| `array_literal` | site = this node; elements in source order into `summary`; a `spread` element joins every cell its source can show to a dynamic read (including `top_cell`, and every heap site if the source has `origins_top`) into `summary`, each copied value combined with the source's labels by `mergeValues`; value = origins `{site}` |
| `object_literal` | site = this node; `object_property` with a static key writes `cells[key]`; `object_spread` copies each visible source cell to the same name and the visible summaries to `summary`, each combined with the source's labels, with `origins_top` expanded as for an array spread; value = origins `{site}` |
| `function_expr`, `arrow_function` | callables `{node}` and origins `{function site of node}`; the body is not executed |
| `call` | callee and arguments evaluated in order for their effects, then unresolved (P4, P5); value `top` |
| `match_expr` | discriminant evaluated; each arm in a copy of the state; a record-pattern field binding gets the static read of that field from the discriminant; an arm value is an expression; arm values and states join; a `match_type_test` binds nothing new. A nested record or array pattern is unresolved in P2 |
| Tags the parser does not produce: `method_call`, `sequence_expr`, `comma_expr`, `object_method`, `object_getter`, `object_setter`, a computed object-literal key | unresolved, `top` |
| `spread` outside a literal, `await_expr`, `yield_expr`, `object_property` and the other non-expression tags | unresolved, `top` |

### Statements (`exec(node, *State)`)

| Tag | Rule |
|---|---|
| `block` | each statement of `getBlock` in order; a statement executed in a bottom state does nothing |
| `var_decl` | strong `env` update with the initializer value, or `clean` without one (code generation stores `undefined`, per the prerequisite fix) |
| `function_decl` | in statement order, like the runtime (no hoisting): a strong `env` update of the declaration's binding with the value of its initializer function expression (`getFunctionOfDecl`, `ir.zig` 2053) |
| `expr_stmt` | evaluate for effects |
| `if_stmt` | condition evaluated; then and else executed in copies; state = join |
| `return_stmt` | value evaluated (or `clean`); a return completion records the value and the state; the state becomes bottom |
| `assert_stmt` | condition evaluated. With a message: the message is evaluated in a copy of the state, and that copy and the message value form a return completion; a string message becomes the response body and another primitive gives a 500 (`handler_instance.zig` 1668). Without a message: a halt completion whose value is `clean` (`undefined`, per the prerequisite fix). The original state continues in both cases (the assert held) |
| `for_of_stmt` | unresolved (P3) |
| `for_stmt`, `for_in_stmt`, `while_stmt`, `do_while_stmt`, `switch_stmt`, `case_clause`, `try_stmt`, `throw_stmt`, `labeled_stmt`, `break_stmt`, `continue_stmt` | unresolved; the parser refuses all of them except `break` and `continue`, which appear only in loops |
| `stmt_list`, `program`, `param_list`, `arg_list`, module tags, pattern tags | unresolved when reached as a statement: they are read through their parents' accessors |

Both `eval` and `exec` switch exhaustively on `NodeTag` with no `else` arm, so
a new tag fails to compile until it has a row.

### Result and API

```zig
pub const FlowInterp = struct {
    pub fn init(allocator: std.mem.Allocator, ir_view: IrView, atoms: ?*atom_table.AtomTable) FlowInterp;
    pub fn deinit(self: *FlowInterp) void;
    /// Analyze one function body with its parameters bound to `params`
    /// (missing entries are `clean`). The result lives in the arena.
    pub fn analyzeFunction(self: *FlowInterp, func: NodeIndex, params: []const Value) !FunctionResult;
};

pub const Completion = struct { kind: enum { returned, assert_message, halt }, value: ?Value, state: State };

pub const FunctionResult = struct {
    /// Join of every returned value, every assert message, every halt value,
    /// and `clean` when the end of the body is reachable (an implicit
    /// `return undefined`).
    returned: ?Value,
    /// Join of the states of every completion and of the fallthrough.
    exit: State,
    completions: []const Completion,
    /// True when any construct was unresolved: every flow property is then
    /// cleared, and `returned` and `exit` carry no guarantee.
    cleared: bool,
    unresolved: []const Unresolved, // { node, tag, owner: Owner }
};
```

`Owner` names the phase that will resolve the construct (P3 to P8), or
`refused_by_parser`, or `not_produced`.

Test helpers in the same file: parse a source with `JsParser.init` and
`IrView.fromIRStore` (as `runNoSecretLeakage` in `flow_checker.zig` does), find
a named function, and read all cells of a value (`readAll`).

### Tag census

`pub fn tagPlan(tag: NodeTag) TagPlan`, exhaustive with no `else`, where
`TagPlan` is `handled`, `later(Phase)`, `refused_by_parser`, or
`not_produced`. A test iterates every `NodeTag` value, prints the counts per
plan, and checks that `tagPlan` agrees with `eval` and `exec`: a tag marked
`handled` has a rule that does not record an unresolved entry, and every other
tag records one. P9 requires that no tag is `later`.

The census shows that every tag has a disposition. It does not show that a
handled rule is correct: the per-rule tests and the reviewer's mutations do
that.

### Tests

Each rule gets a test that shows the over-approximation on a concrete case, and
a contrast that keeps a clean result. Parameters are seeded through
`analyzeFunction`'s `params`. Probes use operations that the runtime executes:
string `+` is refused by the typed frontend and by runtime addition
(`interpreter/arith.zig` 11), so arithmetic probes use numbers. The minimum set:

1. A literal returns `clean`; a parameter seeded `secret` returns `secret`.
2. `secret + 1` and `1 + secret` both carry `secret`, so each operand position
   is checked; `secret > 3` and `3 > secret` too; `-secret` and `!secret`.
3. `&&`, `||`, `??`: the value joins both operands, with the secret in the left
   and then in the right operand; a write in the right operand is visible in
   the exit state.
4. Ternary: a secret in either arm reaches the value; a write in either arm
   reaches the state.
5. The P0 shape `let x = clean; if (c) { x = raw; } else { x = clean2; }
   return x;` returns `raw`'s labels; the shape with the raw value in the
   initializer and a clean value in one branch returns them too. Contrast: both
   branches clean returns `clean`.
6. Array literal: `[secret][0]` carries `secret`; `["a", "b"][secretIndex]`
   carries `secret` through the key.
7. Alias through a variable: `const a = ["x"]; const b = a; b[0] = secret;
   return a[0];` carries `secret`. Alias through a field:
   `const a = ["x"]; const h = { items: a }; h.items[0] = secret; return a[0];`
   carries `secret`.
8. Field sensitivity: `{ a: secret, b: "x" }.b` is `clean`; a dynamic read of
   the same object carries `secret`.
9. Receiver and key labels: `table[secret][0]` carries `secret` (dynamic read
   of a labelled receiver); `table[secret].x = "X"; return a.x;` carries
   `secret` (write through a labelled receiver).
10. Spread: `[...[secret]][0]`, `{ ...{ a: secret } }.a`, and a spread of a
    labelled source (`{ ...table[secret] }.x`) carry `secret`.
11. Function objects: `const g = () => 0; g.x = secret; return g.x;` carries
    `secret`.
12. `origins_top`: a write through a parameter seeded `origins_top` reaches a
    static read through a parameter seeded with a known origin, and the
    reverse.
13. Evaluation order: `o.x = ((o = b) === b ? secret : 0); return a.x;` with
    `o` first bound to `a` carries `secret` in `a.x`.
14. `assert c, secret; return "ok";` returns `secret`'s labels; an `assert`
    without a message adds a halt completion with a `clean` value.
15. A return in one branch: the exit state joins its heap writes with the
    fallthrough.
16. `function_decl` binds its name in statement order; a read before the
    declaration is unresolved.
17. A call, a `for...of`, an upvalue read, and a nested match pattern each set
    `cleared` with their owner.
18. `match` arms join, and a record-pattern field binding reads that field's
    cell.

### Verification

`zig build test-zts`, `zig build test-zts-layering`,
`zig build test-proof-swallow`, `zig fmt --check build.zig build/ packages/`,
then `bash scripts/verify.sh` with a private `ZIG_LOCAL_CACHE_DIR` and
`DEEPSEEK_API_KEY` unset. The reviewer reverts one transfer obligation at a
time (the branch join, each operand position, the weak heap write, the summary
and `top_cell` joins in a read, the receiver and key labels in a read and a
write, the spread label, the function site, the assert completion) and
confirms that a test fails for each.
