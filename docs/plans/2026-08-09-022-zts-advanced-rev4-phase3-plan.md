# Phase 3: source `null`, recursive aliases, match upgrades - Implementation Plan

**Goal:** Admit the three source forms phase 4's data abstractions are written
in. `null` as explicit data with the absence-operator rule that keeps it from
being swallowed, contractive recursive aliases over the finite named type graph,
and the `match` upgrades - field bindings, type-test patterns, effectful arms -
that let a recursive union be taken apart.

**Exit (from the roadmap):** `JsonValue` minus the Dict arm compiles;
exhaustiveness over null, literals, and type tests.

**Source of truth:** `docs/zts-formal-spec-northstar-advanced.md` revision 4,
sections 5.3, 5.5 (`match`), 5.7, and 16.3.

## Ground truth measured on 2026-08-09

Seven assumptions the scope sentence invites, each measured against the tree:

| Assumed | Measured | Consequence |
|---|---|---|
| `null` needs runtime work | `JSValue.null_val` (`value.zig:763`), `push_null` opcode `0x08` (`bytecode.zig:54`), and its interpreter case (`interpreter.zig:227`) all ship today | Phase 3 is a front-end phase. No kernel growth, and the ground rule about kernel growth is satisfied by construction |
| `null` is refused in one place | Two parser sites refuse it: `parsePrefixExpr` (`parse.zig:1719`) and `parseMatchPattern` (`parse.zig:1245`). Both already admit it when `expression_profile` is set, which is the `comptime()` evaluator | Admission is two deletions, and the comptime path shows the node already flows to codegen |
| A `null` type annotation is refused | `parseTypeExpr` maps the identifier `null` to `idx_unknown` (`type_pool.zig:2344`), and a test pins that mapping (`type_pool.zig:2805`) | The fail-open is pinned. The pin is rewritten with the fix, not deleted alongside it |
| `t_nullable` is `T \| null \| undefined` | `t_nullable` is `T \| undefined` (`type_pool.zig:76`), and it accepts a `t_null` source in two places (`type_pool.zig:1491`, `type_env.zig:1089`) | Spec 5.3 says `null` is not assignable to an optional `T \| undefined`. Those two acceptances are the rule to delete, and they are live today only because no source program can produce a `t_null` |
| Recursive aliases need a type graph built | The graph exists: `type_aliases` maps a name to a `TypeIndex`, a self-reference stays a `t_ref`, and `resolveAliasChain` (`type_env.zig:1063`) follows it. D1 amendment A2's assumption set landed in phase 2 (`type_pool.zig:1274-1296`) with its termination test | What is missing is contractivity and memoized unfolding away from assignability, not representation |
| `match` record patterns bind fields | A record pattern admits `key: pattern` only (`parse.zig:1257`). An identifier that is not `_` is a parse error, so neither the shorthand binding `text` nor the rename `value: v` parses, and neither does a type-test pattern | Bindings and type tests are new pattern forms in the parser, the IR, codegen, and `match_analysis.zig` |
| Exactly-one-arm evaluation has to be built | `emitMatchExpr` (`codegen.zig:2299`) emits a test chain, then one labelled body per arm, each jumping to the end label | The property holds. It is pinned with a test that observes an effect, not built |

Two further facts that decide where new code goes:

`semantics.zig` pins the IR alphabet at comptime (`expected_nodes = 81`). Every
new `NodeTag` this phase adds trips that gate and must either take a rule or be
declared structural in the same commit. `lit_null` is already a named member and
has no rule; `lit_bool` has one, so the shape to copy is there.

Free diagnostic codes: ZTS206, ZTS207, and ZTS212 upward in the type-checker
band (`describe_rule.zig:221-230` has 200-205 and 208-211; 207 was released when
`union_too_wide` was dropped in phase 2). ZTS624 upward in the canonical-profile
band, which is `strict_checker.zig`'s, and which is where a rule that needs an
exact repair belongs because `RepairIntent` lives there.

## Scope decisions

`null` lands front-end only. The `zttp:json` error taxonomy and the ABI
re-typing stay in phases 4 and 5, as the roadmap has them. Type-test patterns
land for `boolean`, `number`, `string`, and `array`, whose narrowing tests exist
today; `Dict` and `Bytes` wait for phases 4 and 5 with their types, which is the
same deferral phase 2 task 4 recorded for `isDict` and `isBytes`.

## Global constraints

- The engine stays interpreter-only. No kernel growth outside what the spec
  names.
- Each admitted form adds its semantics-registry rules in the same task, so
  `spec-check` stays green by construction.
- No `meta` payload content is hand-written.
- Every task: `zig fmt` on touched files, tests in `test "..."` blocks next to
  the code, the named test step run before and after, one commit per task,
  never push.
- Phase boundary gate: `bash scripts/verify.sh` green, `zig build test` green,
  `bash scripts/test-examples.sh` green.
- A gate asserts a floor on its own input before its count means anything, and a
  probe's verdict is read from the build's exit status.

---

### Task 1: `null` as a type

**Files:** `type_pool.zig`, `type_env.zig`.

`parseTypeExpr` resolves the identifier `null` to `pool.idx_null` instead of
`idx_unknown`. Assignability gains the spec 5.3 direction: `t_null` is assignable
only to a target that names `null` (itself, a union with a `null` member, or
`unknown`), and the two sites that accept a `t_null` source into `t_nullable`
are deleted. `t_undefined` keeps its acceptance, since `t_nullable` is exactly
`T | undefined`.

**Tests:** `null` in an annotation resolves to `t_null`, replacing the pin that
asserted `unknown`; `null` is not assignable to `string | undefined`; `null` is
assignable to `string | null`; `undefined` stays assignable to `t_nullable`;
`t_null` prints as `null` and keys as `d` (already true, pinned here so the two
new directions cannot silently swap).

### Task 2: `null` in source

**Files:** `parse.zig`, `type_checker.zig`, `bool_checker.zig`, `semantics.zig`,
`restriction_registry.zig`, `json_diagnostics.zig`, `docs/restrictions-to-proofs.md`,
`docs/feature-detection.md`, `docs/user-guide.md`, `CLAUDE.md`.

The two parser refusals are deleted, so `null` parses in expression and pattern
position under the ordinary profile. `.lit_null` infers `pool.idx_null` in the
type checker (`type_checker.zig:1494`) and maps to a null domain rather than
`.undefined` in the bool checker (`bool_checker.zig:628`); both carry a comment
saying the parser refuses `null`, and both comments go with the refusal.
`semantics.zig` gains the `lit_null` node rule beside `lit_bool`.

The `restriction.null` row leaves the restriction registry. That row carries a
`v1_feature_name`, so removing it changes the frozen v1 `features` output and
`v1_count`. The doc is emitted from the registry by `writeRestrictionsMarkdown`
and asserted against the on-disk file, so the doc is regenerated rather than
edited. Whether the v1 surface may lose a row is measured before the row is
touched: if a golden or a compatibility test pins the v1 list by content, the
row stays with its nature changed rather than being deleted, and the reason is
recorded at the site.

**Tests:** `const x: string | null = null;` compiles; `const x: string = null;`
reports a type mismatch; a `null` literal reaches the interpreter and compares
`=== null` true and `=== undefined` false; the restriction registry no longer
advertises `null`, and the emitted doc matches the file.

### Task 3: the absence operators refuse `null`

**Files:** `strict_checker.zig`, `rule_registry.zig`, `describe_rule.zig`,
`idiom_registry.zig`.

Spec 5.3: `??` and `?.` are refused with an exact repair when the operand's
static type includes `null`, or when it is a generic parameter or `unknown`,
because a later instantiation could admit `null` under source already accepted.
The rule is ZTS624 in the canonical band, severity `.err`, with the repair being
the explicit `=== null` or `=== undefined` comparison, or `match`. On a concrete
type without `null` both operators keep their single meaning and stay the
idiomatic spelling, so `idiom.absence-default` and `idiom.absent-member-read`
gain the restriction in their rows rather than being retired.

Thirteen example files use one of the two operators. The rule is applied, every
example is swept directly rather than through the `set -e` harness, and each
failure is traced to a cause before any of them is fixed. A failure over a
generic parameter or `unknown` is the rule working; a failure over a concrete
non-null type is a defect in the rule.

**Tests:** `??` over `string | null` reports ZTS624 with its repair; `??` over
`string | undefined` does not; `?.` over a generic parameter reports; `?.` over a
concrete record does not; the repair text names the comparison the operand needs.

### Task 4: contractive recursive aliases

**Files:** `type_env.zig`, `type_pool.zig`, `describe_rule.zig`,
`diagnostic_projection.zig`.

At alias registration, every cycle in the alias graph must pass through a record,
tuple, or array constructor (`Dict` joins the list in phase 4). A cycle that
passes only through unions, intersections, or a bare name is non-contractive and
reports `non_contractive_alias` (ZTS212). Negative recursion through a function
parameter is the same error. The check runs over the alias map after the first
pass that defines the type namespace, so a forward reference is not mistaken for
a cycle.

Unfolding is memoized wherever a walk can now re-enter a name: assignability has
A2's assumption set already, and `collectVariants` in `match_analysis.zig`,
`joinTypes`, and `normalizeUnion` are each checked against a self-referential
alias and given a visited set where they need one. `typeKey` already terminates
through de Bruijn back-references.

**Tests:** `type Loop = Loop;` reports ZTS212; `type A = B; type B = A;` reports;
`type JsonValue = null | boolean | number | string | readonly JsonValue[];`
is accepted; assignability between two structurally equal recursive aliases
terminates and answers true; a union containing a recursive alias normalizes
without expanding the cycle.

### Task 5: match field bindings

**Files:** `parse.zig`, `ir.zig`, `codegen.zig`, `scope.zig`, `type_checker.zig`,
`semantics.zig`, `strict_checker.zig`, `idiom_registry.zig`, `rule_registry.zig`.

A record pattern field becomes one of three forms: the discriminant test it is
today (`kind: "echo"`), a shorthand binding under the field's own name (`text`),
or a rename (`value: v`). A binding introduces an arm-scoped `const` of the
narrowed field type and does not test the field, so it matches whenever the field
is present. Codegen emits the field read into an arm-scoped local at the top of
the arm body rather than re-reading the scrutinee.

Two idiom rows follow from spec 4.2.1 and land with the form: an arm that reads
the field off the scrutinee instead of binding it is rewritten to a binding, and
a rename whose new name equals the field name is rewritten to the shorthand. Both
are advisory, which is the idiom channel's severity.

**Tests:** a shorthand binding is in scope in its arm and not in the next arm; a
rename binds under the new name and the field name is not in scope; the bound
value has the narrowed field type, not the union's; a binding does not make an
arm match a variant lacking the field; the two idiom rows fire on their
non-idiomatic spelling and stay silent on the idiomatic one.

### Task 6: type-test patterns

**Files:** `parse.zig`, `ir.zig`, `codegen.zig`, `match_analysis.zig`,
`type_checker.zig`, `semantics.zig`.

`when boolean:`, `when number:`, `when string:`, and `when array:` are admitted
in pattern position, lowering to the narrowing test each names from the section
5.4 closed list - `typeof` for the three scalars, `Array.isArray` for the array.
The pattern narrows the scrutinee for its arm through `narrowTypeForPattern`, and
`patternFullyCoversType` reports which union variants each test covers so
exhaustiveness sees them. `Dict` and `Bytes` are refused with a diagnostic that
names the phase they arrive in, rather than being silently unrecognized
identifiers.

**Tests:** `when string:` narrows a `string | number` scrutinee to `string` in
its arm; the four tests over a four-member union exhaust it without `default`;
one missing test leaves the match non-exhaustive (ZTS205), which is the positive
control that the coverage logic is not answering true for everything; `when
Dict:` reports the deferral rather than parsing as a wildcard.

### Task 7: effectful arms, and exactly-one-arm evaluation

**Files:** `strict_checker.zig`, `effect_inference.zig`, plus tests beside
`codegen.zig`.

Spec 5.5 admits effectful arm expressions and names `match` the idiomatic
effectful selection form. The canonical profile is checked for a rule that
refuses an effectful arm, and any such refusal is deleted. Effect inference joins
the rows of the arms rather than taking the first, so a `match` whose second arm
calls an effectful export carries that effect.

Exactly-one-arm evaluation is pinned rather than built: a program whose arms each
call a counter-incrementing function runs exactly one of them.

**Tests:** the counter test; an effectful second arm contributes its effect atom
to the inferred row; a `const` initialized from a two-way effectful `match`
passes the canonical profile.

### Task 8: the exit gate

**Files:** a new example under `examples/patterns/`, plus the tests that pin it.

The gate is spec 16.3 minus its Dict arm, which is the roadmap's exit sentence
made executable:

```ts
type JsonValue =
  | null
  | boolean
  | number
  | string
  | readonly JsonValue[];
```

with a `depth`-style function whose `match` covers the five kinds through the
`null` literal pattern and the four type tests, exhaustive without `default`, and
whose array arm recurses. The gate asserts the program compiles, that the match
is exhaustive without `default`, and that removing one arm makes it
non-exhaustive - the last is the floor that keeps the gate from passing over a
check that never ran.

`docs/coverage.md` and `docs/convergence.md` are regenerated in the same commit
as whatever changes them, since the replay fails on drift.

---

## Risks

The absence-operator rule (task 3) is the change most likely to break the example
corpus, because `??` over a generic parameter or `unknown` is accepted today and
is refused after. Task 3 sweeps every example directly before it commits, for the
same reason task 2 of phase 2 did.

Contractivity (task 4) has a false-positive direction and a false-negative one.
A forward reference read before the namespace is complete looks like a cycle
through a bare name; a cycle whose guard is a generic application whose body is
not yet instantiated looks contractive when it is not. Both directions get a
test.

The v1 restriction surface (task 2) may not be free to lose a row. That is
measured before the row is touched, and the fallback - change the row's nature
rather than delete it - keeps the phase moving either way.
