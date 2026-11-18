# TS Restrictions Enforcement Plan

Status: revision 5, 2026-11-15. The owner approved Decision 1 (a), every
recommendation of Decision 2, and option (a) of Decisions 3 to 7. U0 and U1
are done. Execution continues with U1b.

## Goal

`docs/ts-restrictions.md` is the authority for the source profile (AGENTS.md,
section "JavaScript Subset"). This plan does three things:

1. It adds a gate that fails when the compiler and that file disagree.
2. It closes each gap in the file's section "Spec Rules That `zts check` Does
   Not Enforce".
3. It adds the new restrictions that the owner approves in Decision 2.

## Evidence

Two read-only research agents and my own probes ran on 2026-11-15 against
the build of commit `8be67e99`. The findings that the plan depends on:

- No test compares a restriction claim with compiler output. The
  `enforced_by` field of `packages/zts/src/restriction_registry.zig` was
  measured by hand on 2026-07-31.
- Most gap forms occur in no handler source. `JSON.stringify` is the
  exception: 4 example files, 2 fixture files, 61 lines in Zig test strings,
  and the recorded corpus case `validate-body`.
- The tagged-template row of the gap table is wrong. A tagged template gets
  ZTS047, not ZTS003.
- Numeric separators are refused with ZTS012, and the file has no row for
  them.
- The Fable review found more spec gaps, and my probes confirmed each of the
  following: `let a: number;` with no initializer, `if` without a block,
  `forEach`, `pop`, `shift`, `unshift`, `splice`, a callback that calls `push`
  or assigns to a captured binding, `a = b = 3`, `(a = 2);`, `match (xs[0])`,
  `match (typeof t)`, and `r["a"]` for an identifier key. All are accepted.
  The spec grammar (section 8), the closed array set (section 6.5), or the
  record-key rule (section 5.3) excludes each form.
- The gap list of the restrictions file came from ad hoc probes, so it is
  not complete. U0 derives the list from the spec.

## Hash Impact

D-012 in `docs/decisions.md` holds each model-visible change for one batched
re-record window. The research found these effects:

- A new ZTS001 message moves no hash. It changes the replay only when a
  recorded draft contains the form.
- A new strict-checker kind adds a row to `rule_registry.zig`. The row moves
  `policyHash` and `policy-hash.txt`, which the `meta` tool output shows to
  the model.
- A new stripper kind moves the diagnostic catalog hash, and `proof_id`
  includes that hash. Codex found that the model request excludes
  `proof_id` (`packages/pi/src/providers/model_request.zig`). The memory of
  2026-10-07 also says that a catalog change did not break the replay. So a
  new stripper kind is probably replay-safe. U2b measures it. When the
  replay holds, U3 lands before the window, except G11.
- A new limit in the `meta` payload is model-visible.
- A change to `enforced_by` moves the restriction `matrixHash`, which `meta`
  publishes.

## Decisions

### Decision 1: the re-record window

- (a) Recommended. Open one batched re-record window for this plan. Every
  parser-only unit lands first, while the replay is green. Before the first
  unit that moves a model-visible hash, U0 runs the new `zts check` over
  every recorded draft and records the refusals per rule. That record is the
  expressivity measure, because a red replay hides it. After that unit,
  `test-expert-app` is red by plan. At the end, the owner runs the DeepSeek
  recorder once. Then I republish convergence and coverage offline and run
  `scripts/verify.sh`.
- (b) Land only the replay-safe units now: U1, U2, and the docs of U7. Hold
  U3 to U6 for a later window.

G4 forces a re-record in any case, because the recorded `validate-body`
handler uses `JSON.stringify`.

Owner decision, 2026-11-15: option (a).

### Decision 2: new restrictions

Each candidate changes the spec, because the spec admits the form today. The
use count is from the census of 2026-11-15: tracked examples, then recorded
corpus outputs. Revision 2 of this table folds in the Fable review.

| ID | Candidate | Use today | Replacement | Recommendation |
|---|---|---|---|---|
| N1 | Bitwise operators `&`, `\|`, `^`, `~`, `<<`, `>>`, `>>>` | 0 and 0 | None. A module can add bit operations when an application needs them | Adopt |
| N2 | The `**` operator (two spellings with `Math.pow`) | 0 and 0 | `Math.pow(a, b)` | Adopt |
| N3 | `Boolean(x)`; `Number(x)` with an argument that is not a `string` | 0 and 0 | A comparison. `Number(text)` stays, because it is the only strict text-to-number parse. `Boolean(x)` passes the checker, but the runtime does not install it | Adopt |
| N4 | `substring` (a near-duplicate of `slice`; the two differ for negative or reversed bounds) | 0 and 0 | `slice` | Adopt |
| N5 | The `Headers` ambient value (it has no type, and Response headers are not supported) | 0 and 0 | None | Adopt |
| N6 | `continue` | 1 example and 0 | An `if` block | Defer: spec 6.5 uses `continue` to choose between `for...of` and a higher-order function |
| N7 | `0b` and `0o` literals, and a leading-dot number such as `.5` | 0 and 0 | Decimal or `0x`; `0.5` | Adopt |
| N8 | `Partial`, `Required`, `Pick`, `Omit`, and `Readonly<T>` | 4 lines in 1 example, and 0 | An explicit `structural` declaration; the `readonly` modifier | Adopt |
| N9 | Single-quoted strings | Count not reliable | Double quotes | Defer: measure the corpus first |
| N10 | Local function declarations | 0 and 0 | A module-level function. A local function also fails the default proof profile today | Adopt |
| N11 | Reassignment of a parameter, such as `a = a + 1` | not measured | A new `const` | Adopt |
| N12 | Shadowing of a name in a nested block or an arrow parameter | not measured | A different name | Adopt |
| N13 | Array `concat` (spec 6.5 calls it non-idiomatic) | not measured | Array spread `[...a, ...b]` | Adopt |
| N14 | Empty blocks, and a bare block statement | not measured | Remove the block, or put its statements in the enclosing block | Adopt |
| N15 | `Number.parseInt` and `Number.parseFloat` | 0 and 0 | `parseInt` and `parseFloat` | Adopt |
| N16 | Any call in an assignment target, such as `mk().n = 2` (the spec requires only purity) | not measured | Bind the receiver to a `const` first | Adopt |
| N17 | `else` after a branch that always returns | not measured | An early-return guard | Defer: low value |
| N18 | An assignment target whose root is not a name, such as `[1, 2][0] = 5` and `[mk(), b][0].n = 2` | not measured | Bind the value to a `const` first, then assign through the name | Adopt |

U0 measures each "not measured" count before U6 starts.

Owner decision, 2026-11-15: adopt N1 to N5, N7, N8, and N10 to N16. Defer N6,
N9, and N17.
Owner decision, 2026-11-16: adopt N18 (Decision 13).

### Decisions 3 to 7: conflicts found by the U0 sweep

The ledger `2026-11-15-ts-restrictions-sweep.md` lists each row X1 to X32.
The owner chose option (a) for each of these decisions on 2026-11-15:

- Decision 3 (X1, top-level statements): refuse every top-level statement
  except a bare registration call (`schemaCompile(...)`, `sql(...)`) with
  literal arguments. Spec 5.1 admits that one form.
- Decision 4 (X10, arrows outside a callback argument): follow spec 5.2. A
  module-level `function` is the one form of a named function. The ZTS001 row
  for object methods changes its replacement. Migrate the 20 tracked files.
- Decision 5 (X20, a `default` arm on a covered union, and a duplicate arm):
  ZTS216 becomes an error.
- Decision 6 (X29, `nominal` over `boolean`): the spec admits `boolean`. The
  compiler does not change.
- Decision 7 (X30, `Object` members): admit only `keys`, `values`, and
  `entries`. Refuse each other member with ZTS201.

The other 27 rows are forms that the spec excludes and the file does not
admit. They are gaps under the original request.

### Decision 8: the `match (!!(cond))` repair under G5

The ZTS612 and ZTS621 exact repairs write `match (!!(cond))`. G5 refuses each
`match` scrutinee that is not a name path. The owner chose option (a) on
2026-11-15: G5 stays strict, and `match` keeps one scrutinee form.

The repair binds the condition first, as `const c = !!(cond);`, and then
writes `match (c)`. The repair is exact only where the conditional is a
`const` initializer or a `return` operand. In each other position, a new
statement would change the evaluation order, so the diagnostic gives the
rewrite as a proposal. U1c counts the conditionals in the other positions
before U4e starts.

The rejected options were (b), which admits `match (!!(e))` as a second
scrutinee form, and (c), which drops the exact repair.

### Decision 9: the machinery behind a refused form

X11 refuses a generic arrow, and G2 refuses a generic default. After each
refusal, parser code for the form still runs on refused input, and no test
covers it. The owner chose option (a) on 2026-11-15. One U3 unit refuses
`<T>(x: T) => x` at the `<`. The same unit deletes the generic-arrow machinery
and the default handling of the generic list, with the tests whose subject is
that code. It rewrites each test that uses a generic arrow only incidentally.

The rejected options were (b), which admits generic arrows in
`docs/ts-restrictions.md`, and (c), which refuses the arrow but keeps the
machinery.

### Decision 11: the code that handles a duplicate declaration

U4b-3 refuses a second declaration of a name in one scope. After that
refusal, no parsed input reaches the code that handles a duplicate. That
code selects the first or last import record for one slot in
`module_facts.zig`, and it counts the declarations of a module name in
`flow_interp.zig`. Two sites first listed here serve legal input and stay.
One is the merge of an imported name, which one name imported under two
aliases reaches. The other is the declaration-owner keys of the typed
frontend, which every typed declaration uses. The owner chose option (a)
on 2026-11-16. U4b-3 deletes the test cases whose subject is a duplicate and
moves each outcome pin to the ZTS018 or ZTS019 refusal. A separate unit,
U4b-3b, deletes the code with its own gate.

The rejected options were (b), which deletes the code in the U4b-3 commit,
and (c), which keeps the code as defense in depth.

### Decision 12: the code that handles an untracked assignment root

After U4b-6, `route_resolution.zig` and `handler_verifier.zig` still treat
an assignment root that is not a tracked name as a write that can reach any
route table. The owner chose option (a) on 2026-11-16: search the scopes,
then delete that code in its own unit. The rejected options were (b), which
keeps the code as defense in depth, and (c), which deletes it at once.

Correction: the premise of Decision 12 was wrong. After U4b-6 an array
literal root still parses, and `[mk(), b][0].n = 2` writes through `b`. A
`zts check` probe showed this. Decision 13 closes that path first.

### Decision 13: the root of an assignment target is a name (N18)

The owner chose option (a) on 2026-11-16. ZTS016 refuses an assignment
target whose root is not a name, such as `[1, 2][0] = 5` and
`[mk(), b][0].n = 2`. The spec grammar becomes `LValue ::= Ident
AssignableSuffix*`, and the `AssignableExpr` production is deleted. Unit
U4b-6b makes the refusal. Unit U4b-6c first adds a test that a table
returned from a function and then written stays unresolved. Then U4b-6c
deletes the untracked-root code. The rejected options were (b), which
keeps the array-literal root and the code, and (c), which defers N18.

### Decision 14: a closure that writes a captured table parameter

`route_resolution.zig#Resolver.assignmentRootMatch` compares the binding key of an
assignment root with the key of the route table. An upvalue reference
carries the scope and slot of the closure, not of its source. So a closure
that writes a captured table parameter does not match, and the route table
stays resolved. A test outside the tree confirms the hole. The owner chose
option (a) on 2026-11-16: commit the reproducing test and fix the hole in
its own unit, R1. The rejected options were (b), which records the hole for
later, and (c), which fixes it inside U4b-6c.

### Decision 15: a reserved word as a name

The parser refused `get`, `set`, `of`, `as`, `from`, `match`, `assert`,
`static`, `async`, `await`, and `yield` as binding names with a generic
ZTS003. Neither `docs/ts-restrictions.md` nor the spec listed the refusal. The
owner chose option (a) on 2026-11-16: reserve every keyword of the lexer
as a value name, with a targeted code. The rejected option was (b), which
admits the words as names through contextual-keyword parsing.

### Decision 16: the scope of the shadowing refusal (N12)

The owner chose option (a) on 2026-11-17. ZTS069 refuses a declaration
whose name an enclosing or a nested scope already declares, and the module
scope counts. So a local, a parameter, or a pattern binding cannot reuse
the name of an import or a top-level declaration. The measured fallout was
about 29 broken tests and 0 uses in the 281 tracked `.ts` files. The
rejected option was (b), which covers only function and block scopes, with
about 24 broken tests.

### Decision 17: the tests whose subject is two bindings of one name

After N12, two sibling blocks can still declare one name. The owner chose
option (a) on 2026-11-17. Each broken test moves to a sibling form that
keeps its subject, and the analyzer code stays. A test case is deleted only
when its subject needs nesting, and its outcome pin moves to the ZTS069
refusal. The rejected option was (b), which follows Decision 11: delete the
tests, then delete the analyzer code in a later unit.

### Decision 18: the tests and code for a nested function declaration (N10)

N10 refuses a function declaration inside a function body or a block. In
a full `zig build test`, that breaks 76 distinct tests, and many have a
nested declaration as their subject. The owner chose option (a) on
2026-11-17, which follows Decisions 9 and 11. Each test whose subject is a
nested declaration becomes a ZTS071 refusal pin, or is deleted when its
file already has one. Each test that nests only incidentally moves the
function to module level. A later unit audits the analyzer code that only
a nested `function` reaches, with a probe for each site, and deletes it.
Some of that code probably also serves arrow callbacks. The rejected
option was (b), which follows Decision 17 and keeps the code.

### Decision 19: Decisions 3 and 4 at the measured cost

A measurement-only parser for each rule ran the aggregate on 2026-11-17.
Decision 3 breaks 124 distinct tests, smoke-v1, and the example script.
Decision 4 breaks 287 distinct tests (3 of them in test-zruntime),
smoke-v1, and the example script, and it moves 21 tracked `.ts` files.
N10 breaks 76 distinct tests. The plan had counted only the tracked
files. The owner chose option (a): proceed in the order N10,
Decision 4, callback purity, U5, Decision 3, X2, in units of at most 40
broken tests. Callback purity follows Decision 4 because every arrow is
then a callback argument, so the rule becomes a parser rule. Decision 3
follows U5 because five registrations pass `JSON.stringify(...)`, which is
not a literal argument. The rejected option was (b), which moves
Decisions 3 and 4 into a separate plan after U6.

### Decision 21: a validated value that `stringifyJson` encodes

A probe on 2026-11-17 measured this. A handler validates a body with
`validateJson`, encodes the value with `stringifyJson`, and sends the
text as a `fetch` body. The flow check refuses `injection_safe` with
ZTS407. With `JSON.stringify` the same handler held, because its flow row
kept every defense except `html_escaped`. An export result keeps no
defense unless `defense_sources` establishes one, and a row that only
keeps a defense has no effect (`packages/zts/src/flow_interp.zig#FlowInterp.applyExportCall`).
The result fails closed. Four census hand probes now send the validated
value, narrowed to a string, without an encode step.

- (a) Accept the refusal. A handler cannot prove `injection_safe` when it
  forwards encoded validated JSON.
- (b) Recommended. Give `stringifyJson` a row that keeps `schema_checked`
  and removes `html_escaped`, as `JSON.stringify` did. The flow check must
  apply a keep-only row, and the kept defense must be the intersection over
  every part that the argument reaches. Probes: a secret still refused, an
  unvalidated input still refused, and a record that mixes a validated
  part with a raw part still refused.

## Units

Every fix unit follows the bug rule of AGENTS.md. First it moves the gap row
from the gap table to a refusal table, with its probe. Then it runs the U1
gate and confirms that the gate fails for the reason of the gap. Then it fixes
the compiler. The commit message records that the probe failed before the
fix.

Every implementer gate list ends with these steps: the unit's named steps,
`zig build test-cli`, `zig build test-zruntime`, `zig build test-proof-swallow`,
`zig build smoke-v1`, `zig build test-expert-app` with `DEEPSEEK_API_KEY`
unset, and `zig build test` with an empty `ZIG_LOCAL_CACHE_DIR`.

### U0: spec conformance sweep (default model, 60 turns, read-only)

- Walk the grammar of spec section 8 and every MUST, MUST NOT, and "excludes"
  rule of sections 5 and 6. For each rule, write a probe and run
  `zts check --json`.
- Add each accepted form to the gap table of `docs/ts-restrictions.md`.
- Measure the "not measured" counts of Decision 2.
- Run `zts check` over every recorded draft of the DeepSeek corpus, under
  `packages/pi/src/simulator/testdata/empirical/deepseek/codegen/`. Record
  which gap fix and which candidate would refuse each draft.

Output: the ledger file `docs/plans/2026-11-15-ts-restrictions-sweep.md`. U0
runs in parallel with U1, so U0 does not edit `docs/ts-restrictions.md`. After
U1 lands, I move each new gap row of the ledger into the gap table, with its
U1 probe, and I commit the ledger.

### U1: the restriction gate (Sonnet, 100 turns)

Add the step `zig build test-ts-restrictions` and wire it into `zig build
test`. The gate lives in `packages/tools`, because the `zts` package root has
no check function that returns diagnostic codes. It calls
`runCheckOnlyFromSourceWithOptions` (`packages/tools/src/precompile_check_run.zig`)
through the `tools` package root. The build embeds `docs/ts-restrictions.md` through build options, as
`build/host_tests.zig` embeds `standin-range.md`. The form cell of a row is
its key.

Refusal rows (tables with the header `Refused form | Code | Write instead`):

- A Zig table supplies the probe inputs for each key: one refused source for
  each backticked span of the form cell, and one clean source for the
  "Write instead" form. The table holds inputs only. The expected codes come
  from the file.
- Each refused probe must report at least one error code. Every error code
  that it reports must be in the row's code set. A code marked `(warning)` in
  the file is compared at warning severity. A warning outside the row is
  ignored. An error outside the row fails the gate.
- The union of the codes over the row's probes must equal the row's code set.
- Each clean probe must report no error.

Gap rows (the gap table):

- Each gap row has a probe that `zts check` accepts with no error. When a
  fix makes the probe fail, the gate fails until the unit moves the row.

Census checks:

- A row with no probe, or a probe with no row, fails the gate.
- Every entry of the parser's unsupported-feature list, and every parser,
  stripper, type-checker, and strict-checker kind of `diagnostic_catalog.zig`
  that refuses source, must be observed in a refused probe. An entry that
  cannot be observed needs an allowlist row with its reason.
- Every array and string member of the type checker's member tables must
  occur in a new "Admitted members" section of the file, or in a refusal row.
- The ambient name list and the Limits table of the file must equal the
  `meta` payload.

Files: a new test file in `packages/tools/src/`, the `build/` wiring, the agent
spine manifest if `zig build check-spine` requires it, and
`docs/ts-restrictions.md` for the "Admitted members" section and the two
corrections of the Evidence section.

Acceptance: the gate passes on the current file. Each of these mutants makes
the gate fail: one code changed in one row, one probe deleted, one admitted
member removed from the file, one ambient name added to the file.

Result, 2026-11-15: committed as `825c69ca`. The gap table gained a Required
column. Eight refusal rows whose code the compiler does not report moved to
the gap table. 18 allowlisted kinds are profile rules that the file does not
list yet.

### U1b: complete the file (Sonnet, 80 turns, no compiler change)

- Add a gap row, with probes and a Required cell, for each of the 27 sweep
  rows, for Decisions 3, 4, 5, and 7, and for the known gaps that have no row:
  `let` without an initializer, `if` without a block, an impure higher-order
  callback, `r["a"]`, and `mk().n = 2`.
- Move `toReversed` from Admitted Members to a gap row (spec 6.5).
- Add a refusal row for each of the 18 allowlisted profile kinds that a probe
  reaches, and delete its allowlist row. A kind that no source form reaches
  keeps its row, with the probe result as its reason.
- Decision 4: change the replacement of the object-method row.

Acceptance: `test-ts-restrictions` passes. The allowlist loses one row for
each kind that gains a refusal row.

### U1c: generated-code census (Sonnet, two parts, no compiler change)

The compiler emits source that it must itself admit. U2a found two exceptions:
the repair templates write an `if` body that is not a block, and the ZTS621
exact repair writes `match (!!(cond))`. The census runs each emitted source
through the real check and requires no diagnostic at error or warning
severity. A census test lives beside each emitter, because pi depends on tools
and `ts_restrictions_gate.zig` cannot reach the pi sources. Each test asserts a
floor on its member count.

A read-only survey on 2026-11-15 found the existing coverage. `test-standin`
already proves each `seed_source` clean and each `good_draft` accepted after
normalization, so the census leaves the seeds to it. No test checks the other
kinds for zero errors.

- U1c-1, tools and pi: each canonical rewrite of `canonicalize.zig` (the seven
  line intents, the ZTS621 span rewrite, and the layout printer), and each
  code template of `repair_plan.zig` and `pi_repair_plan.zig`, applied to a
  fixture that triggers it.
- U1c-2, runtime and pi: each TypeScript scaffold of `zttp init`
  (`basicHandler`, `apiHandler`, `extension_handler_ts_template`), and each
  `// after` block of `packages/pi/src/skills/*.md`. A block that cannot be a
  module, such as an elided fragment, is named in the test with its reason.

A member that fails today is a finding. It goes in a known-failure list in its
test, with the observed codes, and the list ratchets: a listed member that
passes fails the test. The census does not change emitted text, because
repair templates and skills are model-visible. When a unit adds a refusal,
the census names each emitted source that uses the form in `zig build test`.

### Unit size

U2a overran two 70-call budgets on test fallout, not on the parser change.
Each later unit takes one to three rows. Before each dispatch, I run the U1c
census and a search for the form in tests, fixtures, and examples, and I put
the file list in the brief. A refusal and its fixture migration are separate
dispatches. Bulk rewrite scripts are not allowed.

### Row assignment

| Unit | Rows |
|---|---|
| U2a | G1, `let` without an initializer, X3, X4, X5, X7, X8, X17, X32 |
| U1c | The generated-code census (U1c-1 and U1c-2, above), before U2b |
| U2b | G8, G9, G10, X6, X9, N1, N2, N7, N14 |
| U3 | G2, G3, G7, G11, X11, X12, X16 (type keys), X26, X27, X28, N8 |
| U4a | The array set (`forEach`, `pop`, `shift`, `unshift`, `splice`), X23, X24, X25, X31, N4, N13, Decision 7 |
| U4b | X13, X14, X15, X16 (record keys), X18, `r["a"]`, G12 with N16, N11, N12 |
| U4c | Callback purity, Decision 3, Decision 4, X2, N10, X19 with the `if` without a block. X19 also changes the repair templates of `repair_plan.zig` and `pi_repair_plan.zig`, which write `if (!result.ok) return ...;` and are model-visible |
| U4e | G5 with Decision 8 (a). The ZTS612 and ZTS621 exact repair in `canonicalize.zig` binds `const c = !!(cond);` and writes `match (c)` |
| U4d | G6 with X21, X22, Decision 5, N3, N5, N15 |
| U5 | G4 |
| U6 | The spec text for Decisions 3, 4, 6, and 7, and for N1 to N16 |

U4a runs as five commits, one for each rule. U4a-1 refuses the array members
`forEach`, `pop`, `shift`, `unshift`, `splice`, `toReversed`, and `concat`,
and the string member `substring`. The checker already refused `reverse`
because the runtime does not install it, so U4a-1 deletes the eight methods
from the runtime, the result table, and the flow rules, and ZTS201 follows.
U4a-2 refuses each member of an ambient namespace that the runtime does not
install, such as `Math.nope` and `Object.create`. It deletes `Array.from`,
`Array.of`, and `Object.hasOwn`, refuses a `length` write on an array or a
string with ZTS200, and extends the member census of the gate to the
namespaces. U4a-3 takes X24 and X25. U4a-4 takes X31. U4a-5 refuses a number
literal type that is not an integer in -32768..32767 (Decision 10 a).

U4b runs as eight commits, one for each rule. U4b-1 takes X16 for record
literal keys and the read `r["a"]`. U4b-2 takes X13, U4b-3 X14, U4b-4 X15,
U4b-5 X18, U4b-6 G12 with N16, U4b-7a N11, and U4b-7b N12. U4b-3b deletes the
code that handles a duplicate declaration (Decision 11).
U4b-6b takes N18 (Decision 13). U4b-6c deletes the untracked-root code
(Decisions 12 and 13). R1 fixes the closure-capture hole (Decision 14).
U4b-8 reserves the keywords as value names (Decision 15).

### U2: parser refusals that move no hash (Sonnet, 3 sequential parts)

The parts touch `packages/zts/src/parser/parse.zig`, so they run in order.

- U2a (60 turns): G1 refuses assignment outside a statement with ZTS001,
  including `a = b = 3;` and `(a = 2);`. G5 refuses each scrutinee outside
  `Ident ("." Ident)*`, including `xs[0]`, `r.a?.b`, `typeof t`, `(n)`, and a
  call. U0 adds the other parser-only gaps here: `let` without an
  initializer and `if` without a block. Rewrite the tests that use these
  forms in `precompile_check_tests.zig`, `fault_coverage.zig`, and
  `path_generator.zig` so that they bind a `const` first.
- U2b (60 turns): G8 refuses `declare`, `abstract`, and the non-null `x!` with
  ZTS001. G9 refuses overloads, tagged templates, and comma expressions with
  ZTS001. G10 refuses `<T>x` with a message that names the type assertion.
  First, measure whether a second producer of ZTS042 moves a model-visible
  hash: make the change, then run `test-expert-app`. When the replay holds,
  use ZTS042. Otherwise, use ZTS001 and correct the restriction registry in
  U7. The approved parser-only candidates of Decision 2 (N1, N2, N7, N14)
  also land here.
- U2c (25 turns): G13 prints the code for a stripper error in the text output
  of `zts check`, through `diagnostic_catalog.stripCode`.

Acceptance: each moved row passes the U1 gate. `test-expert-app` replays
unchanged. A row whose refusal changes a recorded draft (U0 ledger) waits for
U3.

### U3: type syntax refusals (Sonnet, 80 turns, in the window)

G2 refuses generic defaults. G3 and G7 refuse any type text after the parsed
type, which covers index signatures, `keyof`, mapped types, conditional
types, type-position `typeof`, indexed access, and `infer`. Each form gets a
targeted message. G11 refuses a ninth type parameter and publishes the limit
in the `meta` limits. Approved N8 lands here.

Files: `packages/zts/src/parser/type_syntax_parser.zig`,
`packages/zts/src/source_diagnostics.zig`, `diagnostic_catalog.zig`,
`type_env.zig`, and `agent_protocol_meta.zig`.

### U4: checker refusals (Sonnet, four parts U4a to U4d of 80 turns each, in the window)

The parts follow the row assignment above.

- G6 refuses `for...of` over a value that is not an admitted iterable, in
  `type_checker.zig#TypeChecker.bindForOfElement`.
- The closed array set of spec 6.5 refuses `forEach`, `pop`, `shift`,
  `unshift`, and `splice` with ZTS201.
- Callback purity (spec 6.5) refuses a higher-order callback that calls an
  effectful member such as `push`, or that assigns to a captured binding.
- G12 depends on N16. With N16, the parser refuses any call in an assignment
  target, and the spec grammar drops the call from `AssignableSuffix` in the
  same commit. Without N16, a new strict rule refuses an impure call there.
  The seed of either rule uses a receiver call, because ZTS605 already
  refuses a call in an index.
- `r["a"]` for an identifier key refuses under spec 5.3.
- Approved N3, N4, N5, N10, N11, N12, N13, N15 land here, in units of at
  most three candidates.

A new strict rule needs a row in `rule_registry.zig`, an update of
`policy-hash.txt`, and a defect seed.

### U5: remove the `JSON` ambient (Sonnet, 80 turns, in the window)

G4 removes `JSON` from `known_globals.zig` and `builtin_results.zig`, so
`JSON.parse` and `JSON.stringify` get ZTS629. Migrate each use: a schema
argument becomes a string literal, and other uses move to `zttp:json`.
Update `example_registry.zig`, the 11 `.ts` files, and the Zig tests.

### U6: close-out (Opus)

- Fable and Codex astra review the combined diff with split briefs.
- Probe each finding, run named mutants on the U1 gate, and time the change
  with `hyperfine -N -i`.
- Delete the gap table of `docs/ts-restrictions.md`, and make the U1 gate
  refuse a gap table.
- Update `restriction_registry.zig` (`enforced_by` and `unenforced_note`),
  regenerate `docs/restrictions-to-proofs.md`, and update
  `docs/feature-detection.md`, `docs/typescript.md`, and the spec.
- Correct the spec: section 7 says that ambient `Date.now` is excluded, but
  section 15 and the compiler admit it.
- Add a CHANGELOG entry and update `../ZTTP-WEBSITE`.

### U7: re-record window (owner)

I give the owner the one-case validation command, the full recorder command,
and the pin diff, as `!` lines. Then I republish convergence and coverage, and
I run `bash scripts/verify.sh`.

## Review Ledger

Fable reviewed revision 1 on 2026-11-15 and reported 16 findings. I accepted
15 and changed the plan as follows:

1. The gap list was incomplete: U0 added; N3 and N7 of revision 1 became gaps.
2. The gate saw no admitted form: the admitted-member census added.
3. A per-code census missed new ZTS001 features: the census now runs over the
   unsupported-feature list and the type-checker kinds.
4. A union per row hid an accepted form: one probe per backticked span, and a
   per-probe check.
5. A catch-all code proved little: each row gets a clean probe for its
   replacement.
6. Incidental diagnostics: the gate compares error codes and ignores
   warnings outside the row.
7. Prose drifted: the ambient list and the Limits table are compared with
   `meta`; the gap table is gated.
8. Keep the form text as the key: kept.
9. G5 and G12 contradicted the grammar: G5 probes added; G12 now depends on
   N16.
10. G1 chained and parenthesized forms: added.
11. N1 and N2 change the spec: stated in Decision 2.
12. `Number(x)` is the only strict parse: N3 keeps `Number(text)`.
13. Local functions fail the default proof profile: N10 recommends adopt.
14. Missed candidates: N11 to N17 added; the quoted-key read became a gap.
15. `continue` drives a canonicalizer rule: N6 deferred.
16. Sequencing: parser-only units first, the recorded-draft sweep in U0, and
    `verify.sh` after the re-record.

Codex fact-checked revision 1 on 2026-11-15. I accepted its five corrections:
the `JSON.stringify` counts, the visibility of `proof_id`, the location of the
check function, `Boolean(x)` at runtime, and the semantics of `substring`.

Fable advised on the U2a overruns on 2026-11-15. I accepted its four points:
keep the U2a tree and move G5 to the window; add the generated-code census
(U1c); delete a test only when no admitted form reaches its behavior, so
seven deleted tests return in the called-closure form; and size later units
by measured fallout. I changed one point: the U2a refusals and the test
deletions land in one commit, because the refusals alone leave tests red.

I rejected one part of finding 11. Fable recommends deferring N1 until a
module offers bit operations. I keep "Adopt", because no example and no
recorded draft uses a bitwise operator, and a module can add the operations
later.

## Open Items

- The restriction registry and `docs/ts-restrictions.md` describe the same
  forms at different granularity. This plan does not merge them.
- The prose rules of the file, such as "A module specifier must be a string
  literal", have no probe.
- Codex marked the zero-use counts as text searches, not a semantic census.
  U0 measures them with the checker.
- `docs/plans/2026-11-15-typescript-syntax-design.md` (option A, accepted as
  direction, migration not authorized) needs `declare const b: unique symbol;`
  and `typeof b` inside `Nominal<...>`. G8 refuses `declare`, and G3 refuses
  type-position `typeof`. This plan follows the current
  `docs/ts-restrictions.md`. The option A migration must carve out those two
  narrow forms, with owner approval of the file change.
- The U2a review found two import defects that U2a does not fix. First,
  `zts check` on a module that imports a `structural` type with
  `import type { T } from "./t.ts";` reports ZTS200 for a matching record.
  The probable cause is that `zts check` does not resolve type imports. A run
  of the HEAD binary can confirm it. Second, a top-level `import type` with
  one leading space is refused, which the file admits. The type-only module
  matrix in `typed_frontend_tests.zig` asserts that refusal.
- The U1c census found six emitted sources that fail the check today. Each
  is a known-failure row in its census test. The model sees the skill files
  and the repair templates, so a change to them waits for the re-record
  window.
  - The `route-table` skill example fails ZTS500. The `sql-query` example
    needs a SQL schema, so the census cannot check it.
  - Skill block `canonical-style-8` is a complete module with no handler, and
    the check refuses it with ZTS500.
  - The `zttp init --extension` handler fails ZTS500, and its `greet` call
    gets ZTS401. `zts compile --module-manifest` reports the same ZTS401.
  - The `replace_export_arrow_with_function` rewrite of an exported arrow
    with a `string` parameter writes a function that ZTS061 refuses. The
    probable cause is that ZTS061 does not check an exported arrow. A probe
    of the arrow form can confirm it.
  - The `redact_sensitive_sink` template inserts a `return` before the sink,
    which leaves unreachable code (ZTS304). `candidateFromSource` refuses that
    candidate.
  - 12 of the 16 skill blocks are fragments. Each one that stops at ZTS002
    shows no checker code, so a later refusal does not reach it.
- X12 moved from U2b to U3. Its modifiers `in` and `const` sit in the generic
  parameter recognizer of `type_syntax_parser.zig`, which G2 also changes.
  Its `asserts` return type is also type syntax.
- The U2b work found three type syntax defects. X6 fixes the first. U3 owns
  the other two.
  - The parser erases a type-only import as raw text, so `import type { T }
    from m;` passed `zts check`. X6 now refuses that specifier.
  - A type-only import that puts `from` on its own line, such as
    `import type { T }` and then `from "./a.ts";`, is refused with ZTS002
    "expected expression". The probable cause is that the raw module scan
    ends the statement at the line break. A test of the scan can confirm it.
  - A top-level `structural L = ;` passes `zts check`. G3 and G7 refuse type
    text that the parser does not admit, and must cover this form.
- Before X9, a `structural` declaration at column 1 inside a function was
  admitted and reached the type checker. The census case
  `block_left_aligned` asserted that. X9 refuses both columns.
- X11 moved from U2b to U3. A refusal of `<T>(x: T) => x` at the `<`, before
  `tryReserveArrowGenericOwner` reserves an owner, passes the restriction
  gate. It breaks 40 tests in `zig build test-zts` and `test-precompile`.
  Most of them test the generic arrow machinery itself: owner reservation,
  projection windows, and allocation-failure restore. After the refusal no
  input reaches that machinery. U3 must delete those tests and the machinery
  together, and rewrite each test that uses a generic arrow only
  incidentally. Decision 9 (a) approves that deletion. A refusal that still
  parses the arrow keeps the machinery running on refused input with no
  tests, so U3 must not use it.
- G2 leaves default handling in the generic list code. The recorded
  `equals_span` and `default_span`, the empty-name projection, and the
  `compact_count` bound in `appendProjectedParametersWithBounds` now run only
  on a source that the parser refuses with ZTS001. The parser keeps parsing
  after the refusal, so that code still runs, and no test covers it.
  Decision 9 (a) deletes it in the X11 unit.
- U3b found that the type parser dropped admitted type text in three ways.
  Each one predates this plan, and U3b fixes each one. First, a comment
  inside a type cut the type: `number /* c */ | string` was checked as
  `number`, and a record with a comment line lost its fields. Second, an
  array suffix after a generic application was dropped:
  `Dict<string, number>[]` was checked as `Dict<string, number>`. Third,
  `number[ ]` was checked as `number`.
- U3b refuses a fraction or exponent literal type such as `1.5` with ZTS001.
  The type store holds 16-bit integer literals only, and reading `1.5` as
  `number` admits values that the type excludes. An integer literal type
  outside -32768..32767 is still read as `number`, so `x: "a" | 40000`
  admits `f(5)`. Decision 10 (a) refuses that case with ZTS001. Unit U4a-5
  makes the refusal, after U4a-4.
- A numeric literal type at the start of an annotation does not parse:
  `x: 400` gets ZTS003, and `const v: 400 = 5;` gets ZTS021. The probable
  cause is that a type start does not include a digit. This fails closed.
  U3c did not fix it. U3d fixes it.
- The leftover check of U3b sees text after the whole type only. Inside a
  record, a parameter list, or a type argument list, malformed text is still
  admitted: `{ x: }` reads as `{ x: unknown }`, `(x: number) =>` reads as a
  function that returns `void`, and a missing separator is accepted in
  `{ x: number y: string }`, `(x: number y: string) => number`, and
  `Box<string number>`. An unclosed `number [` gets the indexed access
  message. U3c owns these, together with the remaining X27 gap row
  (`readonly { a: number }` and comma separators).
- Two type sites still admit leftover type text after U3b: an explicit call
  type argument, such as `f<number number>(1)`, and a generic constraint,
  such as `<T extends number string>`. U3c owns them. U3c also checks that
  every type parse that can note a refusal is followed by a flush, so a
  noted refusal cannot be lost.
- U3c refuses malformed text inside a type: a missing field type, a
  missing return type, a missing separator, an unclosed bracket, comma
  separators in a record type, `readonly` on a record, and leftover text in
  an explicit call type argument and a generic constraint. A record type
  with newline-only separators is now refused too, because the profile has
  no automatic semicolon insertion. Three findings stay open for U3d:
  - `()` as a type is admitted where a `>` or `]` follows it, as in
    `Outer<()>` and `[()][]`. The checker then refuses the value (ZTS200),
    so this fails closed.
  - The explicit call type argument splitter splits at a comma inside a
    string literal or a comment, so `f<"a,b">(x)` gets ZTS001. Before U3c
    the same call got ZTS210 or ZTS200. Both refuse an admitted form. The
    probable cause is that the splitter does not skip quotes and comments.
    A test of `f<"a,b">` against a matching declaration can confirm it.
  - An unclosed `number [` still gets the indexed access message.

  U3d fixes these three findings and the numeric literal type start.
- U3d also refuses `()` as a type when no `=>` follows it. Before U3d,
  `structural Empty = ();` read as a type that accepts any value. This
  failed open. Three robustness tests used `structural Empty<T> = ();` to
  stop the analyzer with ZTS000. They now use the type `` `` `` (an empty
  template literal), which also stops the analyzer with ZTS000. A fourth
  test used that type before U3d. That is a fail-closed gap of the same
  class. When a unit refuses that type, these four tests need a different
  trigger: `canonicalize.zig#repair APIs refuse an
  analyzer failure`, `edit_simulate.zig#simulate reports type resolution
  failures as ZTS000`, the `unmapped.ts` input of `cli_abuse_check.zig`,
  and `precompile_check_tests.zig#CHECK reports absent compound analysis
  failures as ZTS000`.
- A call of a tuple element, such as `d[0]()` with `d: [() => number]`,
  gets ZTS106 "operand has no known type". HEAD before U3d gives the same
  result. This fails closed. The probable cause is that a tuple index read
  does not carry the element type to a call. A checker probe can confirm it.
- U3e-1 refuses a ninth type parameter with ZTS028 and publishes
  `type_parameters` in the `meta` limits. It refuses a Dict key type that
  is not assignable to `string | number` with ZTS209, at each variable,
  parameter, return type, and explicit call type argument, and inside
  records, arrays, tuples, unions, function types, and the bodies of
  aliases that these positions name. `Dict<unknown, V>` in source is
  refused, as spec 6.2 requires, and `Dict<never, V>` is admitted. U3e-1
  also refuses an empty type parameter between commas, such as `<A, ,B>`
  and `<A,>`, which was admitted before. These findings stay open:
  - An alias that nothing uses is not checked, so
    `structural A = Dict<boolean, string>;` alone passes. The check runs
    where a type names the alias, like the ZTS212 check.
  - A generic alias keeps no constraints. `structural Box<T extends string>
    = { value: T };` admits `Box<number>`, and the census case
    `ignored_constraint` pins it. For the same reason, `Bag<boolean,
    string>` passes when `Bag<K extends DictKey, V> = Dict<K, V>`. This
    fails open. A later unit must check a generic alias argument against
    its constraint.
  - An empty type parameter list `<>` is admitted, as in
    `structural Box<> = number;`. Six internal tests pin the empty-list
    distinction, so removing it needs its own unit, like X11.
  - A Dict key that is an intersection or an uninstantiated generic
    application is admitted by the key check.
- U3e-2 refuses a type name that is not declared, imported, ambient, or a
  type parameter in scope, with the new parser code ZTS065, at the name.
  `type_names.zig` walks the type store after the parse, and
  `known_types.zig` holds the admitted names. This closes X26, and it
  refuses the utility types `Partial`, `Required`, `Pick`, `Omit`, and
  `Readonly` (N8). It also refuses `object`, which compiled only because an
  unresolved name read as an opaque type, and `any` in a generic bound or
  type argument, which the stripper did not reach. ZTS629 was not reused,
  because one code must name one diagnostic. These findings stay open:
  - The utility transforms in `type_env.zig` are now dead from source. A
    later unit deletes them and their tests.
  - `FetchOptions` and `DictKey` resolve with no import and have no `meta`
    row. docs/ts-restrictions.md lists both as gaps. The spec names a
    module type through `import type`, and `zttp:fetch` exports no type.
  - A function type parameter is in scope for the whole file in the name
    walk, so a stray `T` outside its function passes the walk. The checker
    then reads it as an opaque type, which fails closed.
  - `any` in a generic bound gets ZTS065, not ZTS041.
- U4a-1 refuses the array members `forEach`, `pop`, `shift`, `unshift`,
  `splice`, `toReversed`, and `concat`, and the string member `substring`,
  with ZTS201. It deletes them from the runtime, the result table, and the
  flow rules, with the type and flow code that only they used. These
  findings stay open:
  - A `map` call whose result is discarded, over `range(Date.now() % 3)`,
    with a callback that writes a local record, leaves `no_secret_leakage`
    undischarged. The same loop with `some` discharges it. This fails
    closed. The cause is not known. A flow probe of the two forms can
    locate it.
  - Five fixtures in `flow_false_proofs.zig` keep their names, such as
    `request_popped_from_array_credential`, because
    `docs/plans/2026-10-20-flow-interp-difference-dispositions.md` cites
    them. Their sources now use `map` and an index read.
  - `docs/proofs-and-receipts.md` keeps `forEach` and `[req].pop()` in its
    table of shapes that v0.22.3 proved falsely. The table records that
    release, so it stays as written.
- U4a-2 refuses a read of a member that an ambient value does not install,
  such as `Math.nope`, `Object.create`, `Date.parse`, and `h.foo`, with
  ZTS201. Before U4a-2, the checker did not look at these reads, so a typo
  in a namespace member passed the check and failed at run time. U4a-2
  deletes `Array.from`, `Array.of`, and `Object.hasOwn` (Decision 7), and
  refuses a write to the `length` of a string, an array, or a tuple with
  ZTS200. The restriction gate now reads the own members of each ambient
  value, and docs/ts-restrictions.md lists the admitted members of each
  namespace. These findings stay open:
  - `range.length` is admitted, because the result table names the length
    of the iterator that `range` returns under the scope `range`. A read of
    `range.length` off the function itself is a different value. A probe of
    the run-time value can confirm what it reads.
  - The `JSON` line of the admitted members goes away with U5.
- U4a-3 refuses an array member call whose argument count spec 6.5 does
  not give, and a callback with more parameters than the method passes,
  with ZTS202. It refuses `join` on an array whose element type is known
  and is not `string`, with ZTS203. The callback now receives the element
  and the index only. These findings stay open:
  - The flow checker still models a callback parameter that names the
    array itself. Checked source can no longer reach that parameter, so a
    later unit can delete the model. U4a-3 deletes the two fixtures in
    `flow_false_proofs.zig` that used it, `alias_callback_array_param` and
    `iterated_array_write_literal_receiver`, and lowers the floor to 36.
    The frozen corpus count in `flow_precision_expectations.zig` goes from
    90 to 88. The 2026-10-20 dispositions plan still names both fixtures as
    history.
  - `join` on an array whose element type is not inferred, such as the
    result of an untyped function, is admitted. The runtime writes a number
    or a boolean element as text and skips `null` and `undefined`.
- U4a-4 refuses an index read and every member read on `Bytes`, such as
  `b[0]` and `b.length`, with ZTS201. Before U4a-4, both reads on a
  request body of two bytes gave `undefined` at run time. `byteAt` and
  `bytesLength` from `zttp:bytes` replace them. This finding stays open:
  - A member read on a union of `Bytes` and a record, such as `v.length`
    on `{ length: number } | Bytes`, is not refused. The checker types the
    read as `number | undefined`, which is the rule for any union with a
    record, so `v.length ?? 0` passes and `v.length` as a `number` gets
    ZTS204.
- U4a-5 refuses an integer literal type outside -32768..32767, such as
  `40000`, `-32769`, and `0x8000`, with ZTS001 at the first byte of the
  literal (Decision 10 a). Before U4a-5, the type parser read it as
  `number`, so `x: string | 40000` admitted `5`. docs/ts-restrictions.md
  now lists the fraction and exponent refusal of U3b in the same row.
  A number literal value outside the range keeps the type `number`, which
  is sound for a value.
- U4b-1 refuses a quoted record key that is a name, such as `{ "a": 1 }`,
  with ZTS001, and a string-literal read of a key that is a name, such as
  `r["a"]`, with ZTS605. A key that is not a name, such as
  `"Content-Type"` or `"GET /health"`, stays quoted, because headers and
  route tables need it. This finding stays open:
  - A read through a `const` bound to a name string, such as
    `const k = "a"; r[k]`, is admitted, because the strict checker treats
    that binding as a static key.
  U4b-1 moves the sources that used the refused forms: `req.headers.authorization`
  in two examples, the contract fixture, the census probes, and the security
  probe; `Accept:` in two fetch examples; and `req.query.city` in the
  weather-egress corpus and its module example. It deletes the A3 cases
  `p02_computed_record_key`, `p33_tracker_vs_phase_computed`, and
  `r05_computed_on_nullable`, whose form is now refused before the verifier,
  and it rewrites the bytecode identity lines of the four changed examples.
- The U4a-3 to U4a-5 gates showed a second failed step, `test-proof-swallow`,
  for the `catch` in `reportArrayCall`. Commit 29c1c9ce adds the allowlist
  row. Each later gate compares the failed step count with the baseline of
  218/221.
- U4b-2 refuses a write to a field that the type does not declare, such as
  `o.z = 1` on `{ a: number }`, with ZTS201. On a union, the write is
  refused when one member lacks the field. Before U4b-2, the write added the
  field at run time: `Object.keys(o)` gave `["a","z"]`, and the response
  carried a field that the type does not name. No existing test or example
  wrote such a field.
- U4b-3 refuses a second declaration of a name in one scope with ZTS019.
  This covers a second `const`, a `function` and a `const` of one name, and
  an import and a declaration of one name. It refuses a repeated parameter
  name and a repeated type parameter, such as `<T, T>`, with ZTS018. Both
  codes give the help "Write a different name." Two corpus cases prove the
  codes, so the two DEFECT rows in `scripts/corpus-uncovered.allow` are
  deleted. Under Decision 11, U4b-3 deletes 7 tests, 8 table cases, and 3
  flow assertions whose subject is a duplicate. It moves the generic
  admission pin to ZTS018. The `module_facts` dedup of an imported name
  stays, because one name imported under two aliases still reaches it. Its
  test and one shared import corpus case now use that legal form.
  These findings stay open:
  - A body `const` with the name of a parameter, such as
    `function f(a: number) { const a = 2; }`, is admitted. The parser gives
    the body its own scope, so this is shadowing. N12 in U4b-7 refuses it.
  - By reading `ModuleFacts.build`: when one declaration imports one name
    twice, such as `import { sha256 as a, sha256 as b } from "zttp:crypto";`,
    and no earlier entry exists for the module, the new entry keeps both
    names. This needs a test to confirm. The defect is older than U4b-3.
- U4b-3b deletes the code that handled a second declaration of one name
  (Decision 11). In `module_facts.zig` it removes `MatchOrder` with its
  `.last` scan, the any-record loop in `referenceHasCategory`, and the skip in
  `builtinDescriptorForNamedReference`. In `flow_interp.zig` it removes the
  declaration count from `buildModuleNames`. In `type_env.zig` it removes the
  census case `.duplicate_constraint_selection` and the `T, T` part of one
  test. The dedup of an imported name stays, because one name imported under
  two aliases still reaches it. The `ImportResolutionFilter` stays, because a
  single unresolved import still needs it.
- U4b-4 refuses an assignment to a `const` binding with the new parser code
  ZTS066, at the assigned name. This covers a local, a module `const`, a
  `for...of` `const`, an import, and a captured `const`. The help is
  "Declare the name with `let`, or bind the new value to a new name."
  `ScopeAnalyzer.isConstBinding` walks the scopes without creating an
  upvalue. Before U4b-4, `for (const k of xs) { k = 1; }` was admitted with
  no error, and the other forms got only ZTS200. An assignment to a module
  `const` that is declared later in the file gets ZTS629, because the parser
  has not declared the name yet. U4b-4 moves two fixtures to legal forms: the
  IR identity mutation of a binding keyword, and one flow collision case.
- U4b-5 refuses an object literal whose only member is a spread, such as
  `{ ...o }`, with ZTS614 in the strict checker. The message says that the
  spread only copies the record, and the help says to use the record itself
  or to add an explicit field after the spread. The rule registry text of
  ZTS614 stays as it was, because a change to it moves the policy hash, the
  expert goldens, and the frozen expert-query bytes. Two fixtures that
  spread a Result now add a field after the spread, and one contract-status
  row for the refused `{ ...b }` is deleted. This finding stays open:
  - `zttp describe-rule ZTS614` does not name the `{ ...o }` case. U6
    updates the registry text when it moves the hashes.
- U4b-6 refuses a call anywhere in the receiver chain of an assignment
  target, such as `mk().n = 2` and `mk().a.n = 2`, with ZTS016 at the
  callee. The help is to bind the call result to a `const` first. In the
  same commit, the spec grammar and `grammar_registry.zig` drop the call
  from `AssignableSuffix` (N16). The grammar hash moves, so the meta drift
  pin, seven contract `json_hash` pins, two receipt pins, and the contract
  and certificate pins in `build_command.zig` move with it. The policy hash
  does not move. U4b-6 deletes `compoundMemberProbe` from the feature-probes
  example and one `handler_verifier.zig` test of `getBox().n = 5`. These
  findings stay open:
  - `handler_verifier.zig` still treats an untracked assignment root as a
    write that can reach any route table. Correction: an array literal root
    such as `[mk(), b][0].n = 2` still reaches that code after U4b-6.
    U4b-6b refuses that root, and U4b-6c deletes the code.
  - `docs/coverage.json` and `docs/convergence.json` still carry the old
    grammar hash. They move with the U7 re-record.
- U4b-6b refuses an assignment target whose root is not a name, such as
  `[1, 2][0] = 5` and `[mk(), b][0].n = 2`, with ZTS016 at the root (N18,
  Decision 13). A call root keeps the U4b-6 message at the callee. The spec
  grammar and `grammar_registry.zig` replace `AssignableExpr` with `LValue
  ::= Ident AssignableSuffix*`. The grammar hash moves again, so the same
  pins as in U4b-6 move. One `handler_verifier.zig` test of
  `[routes][0]["GET /"] = bad` is deleted, and one precompile case loses its
  `[1, 2][0] = 5` line. The bible probes pin the refusal.
  The scope of U4b-6c is smaller than Decision 13 says.
  `route_resolution.zig#Resolver.assignmentRootMatch` also classifies call receivers,
  and a receiver root can still be a call or an array literal. So its
  array-literal arm and its `untracked` answer stay. U4b-6c measures what
  only an assignment reaches before it deletes code.
- U4b-6c deletes no code. It corrects the comments in
  `handler_verifier.zig#HandlerVerifier.writesSharedState`,
  `route_resolution.zig#Resolver.bindingIsMutated`, and
  `route_resolution.zig#Resolver.assignmentRootMatch`. It removes the unused
  `getBox` helper from the route-table test prelude, and it adds a test
  that a table returned from a function and written through the result
  stays unresolved.
- R1 closes the closure-capture hole (Decision 14). The IR keeps no
  capture record, so `route_resolution.zig#Resolver.mayNameBinding` treats
  an upvalue as a name for every binding with its name. The mutation,
  alias, and escape checks use it. `Resolver.findBindingDecl` stays exact,
  so a table read through an upvalue still does not resolve. Two tests
  reproduce the hole: a closure that writes a captured table parameter,
  and a closure that aliases that parameter and writes the alias. Both
  failed before the fix. A third test pins the direct parameter write. A
  probe showed that the state-isolation check already reports a closure
  write through an alias of module state (ZTS310).
  A precision test pins that a closure write to a different captured name
  leaves the table stable. Of four mutants of `mayNameBinding`, three are
  killed. The survivor drops the upvalue test on the subject binding. No
  test can kill it: a subject that is an upvalue never yields a stable
  table, because `Resolver.resolveStableRouteTable` accepts only a global
  and `Resolver.findBindingDecl` is exact.
- U4b-8 refuses a reserved word as a value name with ZTS067 (Decision 15):
  a variable, a function, a parameter, an import alias, and a pattern
  binding. Spec Section 5.2 lists the 54 reserved words, which are the
  keyword table of `parser/token.zig`. A reserved word stays valid as a
  record key, a type field, a pattern key, and a member name. Two defects
  are fixed in the same unit. `assert` could not be a record key or a
  member name, and after U4b-1 a quoted key could not spell it either. A
  match record pattern could not name a field whose name is a reserved
  word. A census test parses every keyword as a name and as a key. These
  findings stay open:
  - A type name may be a reserved word, such as `structural set = ...`,
    because
    `packages/zts/src/parser/type_syntax_scan.zig#tokenIsDeclarationName`
    checks only spelling. Decision 15 covered value names.
  - A later use of a refused name, such as `set > 0`, cascades a ZTS002.
  - `const enum = 1` reports the TypeScript `const enum` refusal, not
    ZTS067, so the census uses `let`.
- U4b-7 is split by measured fallout. In a full `zig build test`, N11
  breaks 6 tests. N12 breaks about 24 more when it covers function and
  block scopes, and about 29 more when it also covers module-level names.
  Neither form occurs in the 281 tracked `.ts` files.
- U4b-7a refuses an assignment to a parameter with ZTS068 (N11), for a
  function parameter and an arrow parameter, inside a closure too. Each
  test whose parameter assignment was incidental now assigns a `let` copy:
  two narrowing tests, a flow test, and the dense-expressions benchmark
  generator. The test of a captured-parameter assignment is deleted, and
  the parameter-assignment type test keeps only its `let` control, because
  their subject is now refused. `TypeChecker.typeOfDeclaration` keeps its
  parameter fallback, because reads use it.
- U4b-7b refuses a declaration whose name an enclosing or a nested scope
  already declares, with ZTS069 (N12, Decisions 16 and 17). The module
  scope counts. `ScopeAnalyzer` keeps the newest declaring scope of each
  name, so one check walks only the enclosing scopes. Under Decision 17,
  30 broken tests move: 21 to two sibling scopes that declare one name, 5
  by a rename where the shadowing was incidental, and 4 to a ZTS069 pin.
  A mutant that counts a closure call by name fails exactly the three
  sibling strict-checker tests. These findings stay open:
  - The 4 pinned cases had a local that reuses a module-level name: an
    import name in `flow_interp.zig` and `type_checker.zig`, a module
    `const` in the state-isolation cases, and a nested `handler` in the
    contract fixtures. The analyzer code that served them stays
    (Decision 17), and parsed input probably no longer reaches it. An
    audit with a probe for each site can confirm this.
  - A local may still reuse an ambient name such as `Date`, because an
    ambient name has no declaration in a scope.
  - After a refused local that reuses a module `const`, a later
    assignment to the name reads the module `const` and cascades a ZTS066.
  - With `hyperfine -N -i`, `zts check` on 2,000 small module functions
    took 380.8 ms before N12 and 379.3 ms after it (10 runs). On 20,000
    functions, the minimum of 3 runs was 27.0 s before and 26.9 s after.
    So N12 adds no measurable time, but the check itself grows faster
    than the file: 10 times the functions take about 71 times as long. The
    cause is older than N12 and is not measured.
- U4c starts with X19 in two commits. The first commit moves every
  non-block body of `if`, `else`, and `for...of` to a block. That covers
  three examples, two doc lines, tests in zts, tools, runtime, and pi,
  the repair templates, the stand-in seeds and playbook, two skill files,
  and one verifier help string. The second commit refuses the form with
  ZTS070, and `else if` stays legal. The model-visible text change moves
  the corpus identity, so U7 re-records it (Decision 1 a). These findings
  stay open:
  - 4 recorded DeepSeek responses in 3 cases (`jwt-auth`,
    `sibling-helper`, and `validate-body`) write `if (...) return ...;`.
    X19 refuses those drafts, so the U7 re-record measures what the
    refusal costs the model.
- U4c-N10 refuses a function declaration inside a function body or a block
  with ZTS071 (Decision 18 a). The parser still parses the refused
  declaration, so recovery resumes after it and reports no cascade. Two
  Sonnet units moved the 76 broken tests. A test that nested a function
  only incidentally now declares it at module level. A test whose subject
  is a nested declaration became a ZTS071 pin, one for each file and
  surface, or was deleted. The corpus case `nested_functions_with_one_name`
  is deleted, `bool_condition_in_nested_function` now uses an arrow
  callback, and the flow census loses its two nested-function templates
  and one hand probe (floors 504 to 448 and 30 to 29). The type_env growth
  tests now use module-level names. These findings stay open:
  - The audit unit of Decision 18 starts from this list of code that
    probably only a nested `function` reaches. The implementers named most
    sites from the deleted tests and did not confirm them:
    `packages/zts/src/effect_inference.zig#Analyzer.walkBaseStmt`,
    `packages/zts/src/effect_inference.zig#Analyzer.collectFunctionsIn`,
    `packages/zts/src/path_generator.zig#PathGenerator.walkPaths`,
    `packages/zts/src/handler_verifier.zig#HandlerVerifier.walkForResultsAndRefs`,
    `packages/zts/src/handler_verifier.zig#HandlerVerifier.walkResultNode`,
    `packages/zts/src/proof_ir.zig#deriveTotality`, the `.function_decl`
    arm of `packages/zts/src/flow_interp.zig#FlowInterp.exec` and the `.function_expr`
    arm of `packages/zts/src/flow_interp.zig#FlowInterp.eval` (the tagPlan census now
    runs both directly),
    `packages/zts/src/flow_interp.zig#FlowInterp.analyzeRoot` for `.capture_unseeded`, the
    nested-body walks of fault coverage, the flow checker, the boolean
    checker, and the strict checker, the nested-signature lookup by name and
    the surplus-argument and predicate checks of the type checker, the
    header publication of nested signatures in the typed parser, the hole
    owner attribution of `zts check`, the call-path expansion of
    prove-behavior, the slot lookup that a local function shared with an
    import atom, and the repeated-name merge of the type_env signature
    tables.
  - 10 tests express a capture or an arrow helper with a `const`-bound
    arrow: 7 that the N10 units moved there, and 3 strict-checker tests
    whose subject is the arrow helper. Decision 4 refuses that form, and its
    unit classifies them.
- U4c-Decision 4 refuses an arrow that is not a direct call argument with
  ZTS072, in two commits. The first commit moved each test, fixture,
  example, and corpus case whose arrow was incidental. The second commit
  adds the refusal and deletes ZTS608 and ZTS609, which refused a subset
  of the same forms later. The parser still parses the refused arrow, so
  recovery reports no cascade. Five Sonnet units resolved the 110 tests
  whose subject needed a refused form: each became a ZTS072 pin, one for
  each file and surface, a migration to a legal form, or a deletion. The
  normalizer keeps its arrow-to-`function` rewrite: the rewrite now fires
  on ZTS072, and a pass may also turn a source that fails to parse into
  one with no hard errors. The stand-in seeds `arrow-helper` and
  `exported-arrow-const` now target ZTS072 and stay salvaged. The skill
  text, the policy hash, and the stand-in seeds change, so U7 re-records
  the corpus. These findings stay open:
  - Decision 20 (decided, a): a local name can still hold a function
    value. Probes on 2026-11-17 at e49cf29b passed parse, types, sound
    mode, and strict mode for two forms: a capturing closure through an
    identity function, `const tag = id((x: string): string => ...);`,
    and an alias of a module-level function, `const tag = helper;`. The
    flow census uses the first form for 145 probes. The options are (a)
    refuse a local `const` or `let` whose type is a function type, with a
    new restriction row; (b) accept both forms and document them; and (c)
    defer to U6. The owner chose (a) on 2026-11-17. U4c-Decision 20 below
    records the rule.
  - The audit unit of Decision 4 starts from this list of code that
    probably only a refused arrow reaches. The implementers named the sites
    from the deleted tests and did not confirm them:
    `packages/zts/src/type_checker.zig#TypeChecker.boundCallableMetadata`,
    `packages/zts/src/type_checker.zig#TypeChecker.functionValueType` for
    an arrow literal in a return, annotation, record, array, or tuple
    position, `packages/zts/src/type_checker.zig#TypeChecker.admitTypePredicates`
    for a `const`-bound arrow predicate,
    `packages/zts/src/bool_checker.zig#BoolChecker.inferFunctionReturnType`
    for a `const`-bound arrow, `packages/zts/src/effect_inference.zig#Analyzer.reachesRecursion`
    for an inline arrow in a route table,
    `packages/zts/src/effect_inference.zig#buildEffectFacts` for the escape
    flag of an arrow in a record field, an immediately called arrow, and a
    body-local arrow, `packages/zts/src/function_specs.zig#dischargeWithTypeSource`
    for a capsule on an arrow helper, and
    `packages/zts/src/path_generator.zig#PathGenerator.onlyReturned` for a
    module call in a named closure.
  - Callback purity probably makes this code dead, because each site
    handles an arrow that writes a captured binding:
    `packages/zts/src/type_checker.zig#TypeChecker.killNarrowingsAssignedIn`,
    `packages/zts/src/type_checker.zig#TypeChecker.assignmentTargetType`,
    `packages/zts/src/type_checker.zig#TypeChecker.scanClosureWrites`,
    `packages/zts/src/type_checker.zig#TypeChecker.walkCallArgsThenKill`,
    `packages/zts/src/flow_interp.zig#FlowInterp.recurse`,
    `packages/zts/src/flow_interp.zig#FlowInterp.scheduleCall`,
    `packages/zts/src/flow_interp.zig#FlowInterp.evalAssignment`,
    `packages/zts/src/flow_interp.zig#FlowInterp.weakWriteCapture`,
    `packages/zts/src/handler_verifier.zig#HandlerVerifier.sweepHelperMutations`,
    `packages/zts/src/handler_verifier.zig#HandlerVerifier.killFlagsAssignedIn`,
    `packages/zts/src/handler_verifier.zig#HandlerVerifier.checkModuleScopeMutationCall`,
    `packages/zts/src/effect_inference.zig#Analyzer.holderWritesState`, and
    `packages/zts/src/function_specs.zig#dischargeWithStateWriters`. The
    tests of these paths were deleted with Decision 4, so the paths have
    no test until callback purity lands.
  - A named function held in a record and called as `ops.run()` gives
    only `lower_bound` in effect inference, where an arrow in the same
    field was charged.
  - `zttp compile` prints a dependency that fails to parse as
    `error at 1:22: ...`, with no ZTS code.
  - Several tests now hold a top-level bare call, such as `f((a) => a);`,
    or a top-level `const x = [0].map(...)`. Decision 3 and X2 measure them.
- U4c-callback purity refuses, with ZTS073, an arrow that assigns a
  binding of an enclosing function or calls `push` on one (spec 6.5). The
  parser decides it from the scope analyzer, because every arrow is a
  call argument and every function is at module level. The 19 tests that
  the rule broke were migrated, and none was deleted. Three flow tests
  had observed what a callback receives through a captured write. Control
  probes showed that a return or a write through a parameter joins the
  receiver's labels, so those cases could not fail. Their subjects moved
  to log-sink tests in `packages/zts/src/flow_checker_tests.zig`, each
  with a clean control. These findings stay open:
  - An arrow can still write a module-level `let`, and the flow
    interpreter then clears its result, which fails closed. Spec 6.5 says
    that a callback must be pure. Whether ZTS073 also covers a
    module-level binding is an owner decision.
  - A callback can still write a record through its own parameter: an
    element, an accumulator, or a payload. The analyzer gives the whole
    record the written label. Spec 6.5 purity also forbids this write.
  - Spec 6.5 also requires the checker to verify every helper that a
    callback reaches, and to refuse an effect in an array callback. The
    checker does not enforce either.
  - A pure callback cannot change the output through its run count, so
    the branch demotion at a higher-order call over an array of varying
    length is now an over-approximation. The precompile rows
    `d_some_range` and `c6b_tosorted_count` pin it.
  - Flow tests write through a third callback parameter, such as
    `(v, i, all) => { all[1] = x; }`, which the type checker refuses with
    ZTS202. The audit checks which analyzer code only such a write
    reaches.
  - The audit of the callback purity sites listed above must probe each
    site with a module-level `let` write and a parameter write before it
    deletes code, because both forms stay legal.
- U4c-Decision 20 refuses, with ZTS217, a `const` or `let` whose resolved
  type is a function type, at module level or in a function, such as
  `const tag = helper;` and `const tag = id((x: string): string => x);`.
  The type checker reports it at the declaration. A record field and an
  array element may still hold a function value. The restriction gate read
  each member as `const f = xs.filter;`, so its probe now reads the member
  inside an array literal. The corpus adds check/bad/function_value_binding.
  The ZTS512 case called through `const f = m.make;`. A direct call
  `m.make()` resolves and reports nothing, so the case now calls through an
  array element. That call leaves a `state_isolated` capsule undischarged
  (ZTS500), so the case and the `effect-row-lower-bound` stand-in seed
  declare `fault_covered`, which the call does not touch. These findings
  stay open:
  - Three forms still bind a function value: a method value with no
    resolved type, such as `const m = xs.map;`; a `for...of` binding over
    an array of functions, where strict mode refuses the call with ZTS600;
    and a union such as `Fn | undefined`.
  - The flow census templates that held a closure in a declaration now hold
    it in a record field through an identity function, such as
    `{ go: id1<string, T>((x: string): T => { ... }) }`, and call it through
    the field. All 683 probes match, and the floors do not move. A later
    rule that refuses a function value reached through an identity function
    moves these templates again.
  - The audit of Decision 20 starts from two analyzer functions that
    probably only a deleted alias test reached. This list is unconfirmed:
    packages/zts/src/type_checker.zig#TypeChecker.callableMetadataForExpression
    and packages/zts/src/type_checker.zig#TypeChecker.bindCallableMetadata.
    A probe for each site must confirm it before the audit deletes code.
  - The compound type row `() => number` is deleted, because a declaration
    cannot carry that type. The row `{ cb: (x?: number) => number }` still
    prints a function type, so the count of compound rows moves from 20
    to 19.
- U5 measurement, 2026-11-17: removing `JSON` from `known_globals.zig` and
  its three rows from `builtin_results.zig` breaks 22 distinct aggregate
  tests (the codegen replay already fails), one test-zruntime test, and
  smoke-v1, through `examples/handler/utils.ts`. The runtime still installs
  `JSON`, and three paths analyze source with `strict = false`, so they never
  report ZTS629: `packages/runtime/src/runtime_cli.zig#validateSourceAuthority`,
  `packages/runtime/src/handler_instance.zig`, and the contract flow
  extraction in `packages/tools/src/precompile_contract.zig`. For this reason
  U5 removes `JSON` only from the strict `names` and keeps it in
  `runtime_only_names`, so that a module cannot bind it. The `JSON` builtin
  result rows, the flow rows in `flow_interp.zig` and `flow_rules.zig`, the
  `Response.json(JSON.parse(...))` detection in `handler_analyzer.zig`, and
  the runtime object stay. The U5 audit decides each one with a probe. A
  probable finding goes to the same audit: `zttp serve` on a file may run a
  handler that the strict check refuses. A probe of `zttp serve` with
  `JSON.parse` can confirm it.
- U5 migrated each `JSON.*` call. A schema text argument became a compact
  string literal, and a value encoding became `stringifyJson` from
  `zttp:json`. The `.value` of a successful `stringifyJson` has the type
  `unknown`, so each caller narrows it with `typeof v === "string"` before
  it passes the text on. A direct read gave ZTS203 or ZTS204. The binding
  could return a `string` value; U6 records the decision.
- U4c-Decision 3 refuses, with ZTS074, a top-level statement other than a
  registration call with literal arguments, such as `f();` and
  `if (c) { f(); }` (spec 5.1). The parser admits a declaration, an
  import, an export, and a call of a name that the module imports as
  `schemaCompile` from `zttp:validate` or as `sql` from `zttp:sql`, with
  only literal arguments. An alias, such as
  `import { schemaCompile as register }`, stays a registration. A census
  in strict_checker.zig checks the parser table against the bindings that
  declare a `sql_registration` or `schema_compile` extraction. A
  measurement on 2026-11-17, after U5, broke 126 distinct tests,
  smoke-v1, and check-semantics-spec.sh. Five units fix the fallout:
  D3-1a and D3-1b split the 54 bool_checker tests at line 2264, D3-2
  takes the parser, type checker, and strict checker tests, D3-3 takes the
  pipeline, interpreter, flow, and precompile tests and smoke-v1, and D3-4
  takes the semantics corpus, whose cases compile a fragment that ends in
  an expression statement.
  The units migrated each incidental statement into a function or a
  `const` initializer, and no verdict moved. The semantics corpus now
  ends each case in `const r = <expr>;` and reads the value that the last
  `const` stores, with no dropped value. These findings stay open:
  - The audit of Decision 3 starts from code that probably only a
    refused top-level statement reached. This list is unconfirmed:
    packages/zts/src/bool_checker.zig#BoolChecker.check (a module-level
    `if` and `assert` walk),
    packages/zts/src/strict_checker.zig#StrictChecker.walkFunctionBody
    (the module-scope exemption for a computed registration),
    packages/zts/src/handler_verifier.zig#HandlerVerifier.verify (a
    module-initialization mutation),
    packages/zts/src/type_checker.zig#TypeChecker.collectSchemaCompileCall
    (a non-literal registration at top level),
    packages/tools/src/precompile.zig#hasTopLevelAssert and the ZTS063
    branch of packages/tools/src/precompile.zig#checkGraphModule, and the
    drop capture in packages/zts/src/semantics_corpus.zig#recover.
  - The skill text in canonical-style.md shows top-level statements, such
    as `count = count + 1;`. The skill census lists ZTS074 for those
    blocks. A prose fix can move the corpus identity, so it waits for U7.
