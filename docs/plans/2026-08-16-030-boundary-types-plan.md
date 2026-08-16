# Boundary types: declared types at the exported boundary - Implementation Plan

**Goal:** Make an exported function's parameter and return types declared rather
than raw. A `nominal` or `structural` alias is required in both positions; the
brand is erased at comptime and costs nothing at runtime.

**Exit:** `zts check` reports `ZTS061` on a raw built-in in an exported
signature and nothing else changes about the program; a `nominal` value can be
constructed and round-tripped through a served handler; `scripts/verify.sh` is
green; the two invalidated corpus cases are re-recorded and replay.

**Source of truth:**
[docs/zts-advanced-v2.1.md](../zts-advanced-v2.1.md) section 1, which owns the
rule, its scope, and the composite and ABI carve-outs.

Date: 2026-08-16. Snapshot: `main` at `767e7bba`.

## Scope decisions, stated before the tasks

**The draft left the construction fix open between two options. Measurement
closes it, and not the way the draft implied.** The draft offered lowering the
constructor `UserId(x)` to identity, or admitting the annotation form
`const id: UserId = "u-1"`. The first is ruled out.

`packages/zts/src/parser/codegen.zig` holds `node_types: ?*const NodeTypeMap`,
and the only caller of `setNodeTypes` in the tree is
`packages/tools/src/precompile.zig:2026`. Type information therefore reaches the
generator on the precompile path and nowhere else. A constructor erasure keyed
on node types would work under `-Dhandler=`, `zttp build`, and `zttp deploy`, and
fault under `zttp dev` and `zttp serve`. That is the proven-in-one-path class
this repository treats as a soundness defect, not a gap to fill later.

So task 1 admits the annotation form and refuses the constructor. Refusing costs
nothing: zero tracked `.ts` and `.tsx` sources declare a `nominal`, so no program
can be using the form, and the refusal converts a runtime `NotCallable` into a
compile error.

**Advisory severity does not protect the corpus, so there is no cheap first
landing.** The obvious sequencing was to ship `ZTS061` advisory-only, migrate
authored source, then flip it to error alongside a re-record.
`packages/tools/src/edit_simulate.zig:157` appends every JSON diagnostic to the
violation list with no severity filter, and `new_count` counts all of them. The
veto passes on `new_count == 0`. An advisory `ZTS061` firing inside a recorded
workspace fails the veto exactly as an error would and stales the cassette the
same way. Task 7 therefore carries the re-record rather than deferring it.

**The rule binds exported functions only.** Parameters and return type, both
positions, internal functions untouched. This is the split ZTS610 and ZTS623
already draw for capability ceilings, and `strict_checker.zig` already
distinguishes the two cases, so the rule reuses a decision rather than inventing
one.

## Ground truth measured on 2026-08-16

Every number below was produced against this snapshot, not estimated.

| Fact | Value | How |
|---|---:|---|
| Tracked `.ts` / `.tsx` files | 128 | `git ls-files` |
| Annotated function declarations | 189 | signature scan |
| Of which exported | 34 | signature scan |
| Exported signatures tripping the rule | 10 | signature scan |
| Of those, authored source | 2 | both in `examples/handler/utils.ts` |
| Of those, recorded cassette workspaces | 8 | 2 cases x 2 providers |
| Tracked sources declaring a `nominal` | 0 | `grep '^nominal '` |
| Free code in the 0xx band | `ZTS061` | `ZTS000`-`ZTS060` all in use |
| Restriction registry rows | 19 | `zts restrictions --json` |
| Rule registry rows | 71 | `zts describe-rule --json` |

Construction, probed rather than read:

| Spelling | Type checker | Runtime |
|---|---|---|
| `const id = UserId("u-1");` | accepted, infers `UserId` | faults, `error.NotCallable` |
| `const id: UserId = "u-1";` | refused, not assignable | never reached |

The two authored signatures are `greet(name: string): string` and
`formatJson(data: object): string`. The eight recorded ones are all
`displayName(name: string): string` in a `lib/settings.ts` carried by the
`sibling-helper` and `sibling-helper-holes` cases, recorded against both the
DeepSeek and the local provider.

## Global constraints

- `scripts/verify.sh` green at every task boundary, as the language program's
  ground rules require.
- No hand-written `meta` payload. Both hash pins move in this plan and both are
  re-pinned from the binary, never typed.
- Each task lands as its own commit. Task 7 is the only one that needs a live
  model, so nothing before it may depend on it.
- A new rule is a new fence. Add its semantics-registry rules in the same task
  that admits the form, so `spec-check` stays green by construction.

## Task 1: give `nominal` a construction path

**Done.** `const id: UserId = "u-1"` brands and runs; `UserId("u-1")` reports
ZTS214 and `serve` refuses it before the handler executes, so it cannot reach a
runtime fault. `examples/patterns/nominal-brand.ts` asserts the erasure through
a served response rather than only in the checker.

Four things the work found that the task as written did not anticipate:

- `type_pool.unwrapNominal` was broken and had been since it was written. It
  delegated to `widenLiteral`, which fires only on the `.t_literal_*` tags,
  while a brand over `string` carries `.t_string` copied from its base. It
  returned its own argument for every nominal that can exist. Its one caller
  keys on the tag, which is identical either way, so nothing observed it.
- The literal-of-base narrowing at the annotated declaration had to be guarded.
  A nominal node carries its base's tag, so `const id: UserId = "u-1"` read as
  a plain string and the declaration collapsed to the literal type, dropping the
  brand at the exact site that creates it.
- The refusal cannot be reported from inference, which is `*const TypeChecker`.
  It is reported from `walkExpr`, the mutable pass, and inference still answers
  the alias type so the declaration does not raise a second mismatch on the same
  line.
- Three existing tests pinned the broken behaviour, asserting that
  `UserId("usr_123")` was accepted and that the annotation form was refused.
  They encoded a form that type-checked and then answered 500. The `distinct
  type` and `nominal` test sets were also verbatim duplicates and are collapsed.

The blocking prerequisite. Nothing else in this plan is testable until a nominal
value can exist.

**Admit the annotation form.** Assignability accepts a value of the base type
into a nominal target **only at an explicitly annotated declaration**:
`const id: UserId = "u-1";` checks, and the brand still refuses everything else.
Widening it to any position where the expected type is known would admit
`widen("u-1")` at a call site and make the brand worthless, which is the whole
point of the type.

**Refuse the constructor form.** `UserId("u-1")` currently resolves its static
type at `type_checker.zig:2717` and reaches codegen as a call to a name no
function defines. Report it with a location and direct the author to the
annotated declaration. One operation, one spelling, per design law 4.2.

Cross-nominal assignment stays refused, and so does a raw value into a nominal
parameter. Both already have tests in `type_checker.zig`; this task must not
loosen either.

**Probe, not just test.** A unit test asserting the checker accepts the
annotation proves half of it. Serve a handler that declares a nominal, builds
one, passes it to a function taking that nominal, and returns it in the
response body, and assert the response bytes. That is the assertion the current
state fails, and it is the one that catches an erasure that only works on one
compile path.

## Task 2: widen the nominal base to `boolean`

`isScalarBaseText` in `stripper.zig:2312` admits `string` and `number`. Add
`boolean`. Update the `nominal_base_not_scalar` message, which names the two
admitted bases in prose, and the ZTS048 row wherever it is rendered.

Do not widen further. A nominal over a record, tuple, union, or function is
still refused, and the reason ZTS048 exists is unchanged.

The stripper test `"a nominal base that is not scalar is refused"` needs a case
proving `boolean` now passes and a non-scalar still fails, so the widening is
pinned in both directions.

## Task 3: `ZTS061` in the strict checker

`strict_checker.zig` already walks function declarations and already knows
exported from internal, which is how ZTS609, ZTS610, and ZTS623 are decided
there. Add the kind, the `rule_registry` row with `.code = "ZTS061"`, and the
`diagnostic_projection` mapping.

Fires on, in an exported function's parameter or return position:

- `string`, `number`, `boolean`, `object`, `unknown`
- an array or readonly array whose element is one of those

Does not fire on: any `nominal` or `structural` declaration or an array of one;
the spec 7.2 ABI (`Request`, `Response`, `Bytes`, `Dict<K, V>`, `JsonValue`,
`Result<T, E>`); a literal union.

The ABI carve-out is a list, and a list rots. Derive it from `abi_types.zig`
rather than writing the names into the checker, so a type added to the ABI does
not silently start tripping the rule.

**Assert the floor.** The gate for this task is not "the rule fires". It is that
the rule fires on each refused shape and stays silent on each admitted one, one
case per row above. A rule that fires on everything satisfies a test that only
checks a raw `string`.

## Task 4: the restriction registry row

`docs/restrictions-to-proofs.md` renders `restriction_registry.zig` and
`scripts/check-docs-drift.sh` gates the two against each other. Add the row,
regenerate with `scripts/update-restrictions-doc.sh`, and do not hand-edit the
Markdown.

The row belongs in both registries and the reason is that they answer different
questions. `policy_hash` says which rule set judged a file; a client that pinned
it needs to see a new rule. `restriction_matrix_hash` says which refusals the
language makes; a reader asking what the profile removed needs to see it there.
Task 8 re-pins both.

## Task 5: the repair intent

`ZTS061` is repairable only in part. The compiler can name the position and the
base type; it cannot choose the alias name, and a wrong name is worse than none.

Add the intent to `repair_intent.zig` and a `repair_validator.zig` row in the
`.none` method class with `.not_applicable` status, which is what D3 blesses for
a rewrite that claims no equivalence. It ships advisory-only and
`repair_available` answers false for it, from the registry rather than a
constant, exactly as the four existing `.none` rows do.

Do not attempt a declared law here. There is no rewrite to re-derive.

## Task 6: migrate the authored source

`examples/handler/utils.ts`, two functions. Declare the aliases the signatures
need and update both. The file is imported by handler examples, so their call
sites move with it.

Run `bash scripts/test-examples.sh` after. This is the task that proves the rule
is livable before it is imposed on recorded turns.

## Task 7: re-record the corpus

**Owed now, and wider than this plan predicted.** Task 1 already staled the
whole corpus, and `zig build test` is red on
`codegen baseline replays at the committed first-draft pass rate` and
`flow-backed corpus replay executes recorded compaction` until this task runs.

The cause is attributed rather than guessed: reverting only the one-line fix to
`packages/tools/src/example_registry.zig` makes the codegen replay pass again,
with every other Task 1 change still in place. That file publishes
`meta.payload.examples`, which the expert sends, so its bytes are inside the
request digest each cassette pins. The new diagnostic is not the cause; the
`policy_hash` did not move, because a type-checker code is not a rule-registry
row.

The conflict is between two gates and neither can yield. The published-example
gate requires the `nominal` example to stop using `OrderId("o-1")`, because that
form is now refused. Changing it stales every cassette. So the re-record is the
only way both go green, and it was taken as a known debt rather than reverting a
correct fix.

Four persona-bundle corrections ride in the same run, each of which would have
owed a re-record on its own:

- `SKILL.md` imported six exports from `zttp:websocket`, a module phase 5
  removed. Replaced with `zttp:fetch`, `zttp:sql`, and `zttp:durable`, verified
  against the live registry.
- `SKILL.md` claimed every `match` needs a `default` arm. A closed union covered
  member by member takes none, and that is the spelling spec 5.5 requires.
- `references/jsx-patterns.md` and `references/virtual-modules.md` published
  `Array<T>`, which ZTS058 refuses at the parser.
- The jsx-patterns list example also hit a live type-checker defect, recorded
  below.

This is therefore a full re-record, not the two cases the original scope named.
`sibling-helper` and `sibling-helper-holes` remain the two whose *workspaces*
trip `ZTS061` once task 3 lands, so running this task after task 3 rather than
before it pays the cost once. Per
[Cassette Recording](../internals/cassette-recording.md).

The local corpus is parked at 16 of 19 cases and neither of these two is among
the three that fail, so both should record. If either does not, that is the
measurement and it blocks the flip, not a reason to skip the case.

Record from a clean tree. `update-convergence.sh` marks a row `-dirty` otherwise,
and a number published from uncommitted work cannot be reproduced from its
commit.

This is the only task in the plan that needs a live model. Everything before it
must be complete and green first, because a re-record against a half-landed rule
buys nothing.

## Task 8: re-pin the hashes and republish

Both pins in `scripts/check-meta-drift.sh` move: `EXPECTED_POLICY_HASH` for the
new rule row, `EXPECTED_RESTRICTION_HASH` for the new restriction row. Read both
from the built binary and write them; never type a hash.

`policy-hash.txt` moves with the policy hash, per CONTRIBUTING.

Then regenerate, in this order, because each reads the one before:

```bash
zts module-spec-render --check      # expect no change; proves the rule touched nothing here
bash scripts/update-restrictions-doc.sh
bash scripts/update-convergence.sh
bash scripts/update-coverage.sh
```

The coverage page will move: `ZTS061` becomes an advertised rule, so the
denominator goes from 71 to 72, and the corpus will not trip it, so the
untripped list grows by one. That is the honest result and the ratchet is
one-directional, so it does not fail.

## Task 9: the exit gate

A single example is the gate, and its floor is probed rather than assumed:
`examples/patterns/boundary-types.ts`, an exported function taking and returning
branded scalars, one branded `boolean`, one branded array, one ABI type, and one
literal union, fully discharging a `Proof<T, P>`.

Three probes, each of which must fail exactly one thing:

- change one parameter to raw `string`: `ZTS061` fires, and only there.
- change one alias from `nominal` to `structural` over the same scalar: it still
  passes, which is the open question in section 1.9 of the draft answered
  empirically rather than by argument.
- delete the branded `boolean` alias and inline `boolean`: `ZTS061` fires, which
  is what proves task 2 is load-bearing rather than decorative.

Then `bash scripts/verify.sh`.

## Risks

**The corpus re-record is the schedule risk, not the code.** Tasks 1 through 6
are mechanical and locally testable. Task 7 needs a live model, a clean tree, and
two providers, and a recording run that produces a non-green case cannot be
patched by hand. Sequence it with other corpus-invalidating work rather than
spending a run on this alone.

**Task 1 can loosen the brand by accident.** The annotation form is admitted at
exactly one kind of site. A patch that implements it by relaxing assignability
generally will pass every test in this plan and silently make `widen("u-1")`
legal, which removes the only thing a nominal type does. The cross-nominal and
raw-argument refusal tests must be run before and after, and a new test must
assert that a raw literal is still refused at a call site.

**The ABI carve-out is a list that rots.** Deriving it from `abi_types.zig` is
task 3's mitigation. A hand-written list would pass on the day it is written and
start refusing a legitimate ABI type the first time one is added.

**An inline record-array type resolves to its element.** Found while correcting
the persona's JSX example on 2026-08-16, and unrelated to this plan's rule:

```ts
structural User = { name: string };
function names(users: { name: string }[]): string { ... }  // property does not exist on type
function names(users: User[]): string { ... }              // checks clean
```

`{ name: string }[]` is read as `{ name: string }`, so a member access on an
element fails and an array argument is refused against a record parameter. The
named-alias form is the workaround and the persona now teaches it. This wants
its own reproduction and fix; it is noted here because the probe that found it
belongs to this work, not because this plan closes it.

**Section 1.9 of the draft is not closed by this plan.** Whether a `structural`
alias over a bare scalar should satisfy the rule is decided empirically by the
task 9 probe rather than argued. Whether the rule extends to exported `const`
declarations, and what it does with a generic parameter a caller instantiates
with `string`, are open and out of scope here. A generic escape hatch in
particular would let a caller route around the rule, and that needs its own
measurement before it is either closed or accepted.
