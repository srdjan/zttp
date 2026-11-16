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

U0 measures each "not measured" count before U6 starts.

Owner decision, 2026-11-15: adopt N1 to N5, N7, N8, and N10 to N16. Defer N6,
N9, and N17.

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
