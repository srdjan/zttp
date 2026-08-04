# Phase 2: type-system rock - Implementation Plan

**Goal:** Land D1 in the engine. Sound generic inference and instantiation,
constraints and explicit type arguments before inference, the closed narrowing
list with its kill rules, and canonical type serialization as the identity
function.

**Exit (from the roadmap):** Generic functions instantiate soundly and never
fall back to `unknown` over a frozen signature corpus covering every
virtual-module export; narrowing conformance tests; stable type digests.

**Source of truth:** `docs/zts-formal-spec-northstar-advanced.md` revision 4,
sections 5.4, 5.6, 5.7, and `docs/plans/2026-07-30-014-d1-type-system-design.md`
sections 1 through 6.

## Ground truth re-measured on 2026-08-04

D1's section-0 table still holds, with three corrections that change the work:

| D1 said | Measured today | Consequence |
|---|---|---|
| `joinTypes` must be built | It exists, `type_checker.zig:1199`, in D1's five-step shape, carrying the `D1-interim` marker | Task 3 replaces its identity relation, not its shape |
| Narrowing store must be split from `binding_types` | Already split: `narrowed`, `type_checker.zig:130` | Task 4 adds the kill rules to an existing store |
| New diagnostics go in the ZTS5xx band | ZTS5xx is author-declared spec discharge (500-512 taken). Type-checker diagnostics are ZTS2xx, mapped in `json_diagnostics.typeCheckerCode` and described in `describe_rule.type_checker_rules` | New codes are ZTS206-ZTS211 |

One further fact D1 did not record: a nominal type carries **no name**.
`addNominalAlias` (`type_pool.zig:294`) copies the base node and sets
`nominal = true`, so `distinct type UserId = string` and
`distinct type OrderId = string` differ only by pool index. Assignability
distinguishes them today by index identity (`type_pool.zig:1079`). A canonical
key that ignores the name would make them share a key, and `normalizeUnion`
would then collapse `UserId | OrderId` to one member. Task 1 therefore gives a
nominal node its name, as D1 section 1 rule 4 already assumed.

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
- Model interaction stays offline. Any corpus or agent-loop work in this phase
  runs against the deterministic stand-in in `packages/pi/src/standin/`, and a
  blocker in the stand-in is fixed in the stand-in rather than worked around
  with a live model.

---

### Task 1: canonical type key, structural equality, type digest

**Files:** create `packages/zts/src/type_key.zig`; edit `type_pool.zig`
(memo storage, nominal name), `type_env.zig` (pass the distinct-type name).

**Produces:**
`typeKey(pool, allocator, idx) ![]const u8`,
`structurallyEqual(pool, allocator, a, b) bool`,
`typeDigest(pool, allocator, idx) ![32]u8`,
`writeCanonical(pool, idx, writer) !void`.

The grammar is D1 section 1 verbatim. Recursion terminates through de Bruijn
back-references over a stack of in-progress indices. An unresolved `t_ref` is a
hard error and is never encoded.

**Tests:** two independently built identical records share a key; two unions
with the same members in different order share a key; two distinct types over
`string` do **not** share a key; a self-referential type terminates; a key is
computed once per index.

### Task 2: assignability amendments A1 through A5

**Files:** `type_pool.zig`, `type_checker.zig`, `json_diagnostics.zig`,
`describe_rule.zig`.

- **A1** deletes the `t_ref`/`t_generic_param` blanket-true at
  `type_pool.zig:1201-1202`. An unresolved name at an assignability site raises
  `unresolved_type_reference` (ZTS206).

  **Measured and re-sequenced.** A1 was applied, the corpus was run, and it
  fails: `jsx/jsx-ssr.tsx`, three workflow orchestrators, and
  `patterns/infer-and-generics.ts`. Three separate things are missing, and none
  of them is A1's own logic.

  `Request` and `Response` are `t_ref` with no definition anywhere in
  `TypeEnv`, so every handler's declared return type is an unresolved name.
  `zttp:durable.run` is declared to return the coarse `unknown`, which under
  sound rules is assignable to nothing, so `return run(...)` from a handler
  fails the moment the target resolves to anything at all. And the generics
  example fails for the third reason, which is that inference does not exist
  yet.

  A1 therefore lands with the ABI types and with inference, not before. The
  deferral is recorded at the site in `type_pool.zig` naming what has to exist.
  What did land here is the reporting half, `firstUnresolvedName`, so the site
  that closes A1 can tell an unresolved name apart from a real mismatch.

- **A1 side finding, fixed.** Running A1 exposed a live checker defect it had
  been masking: a nested function with no signature of its own kept the
  enclosing function's `current_return_type`, so an inner `return` was measured
  against an outer contract. The convergence corpus had this pinned as a
  first-draft failure - `workflow-nested-dispatch-avoidance`, where the model's
  own next turn reads "ZTS204 on line 88, the `Response.json(...)` call inside
  `run()`". Fixing it moves the offline replay from 95% (19/20) to 100% (20/20)
  first-draft pass, and covers two more advertised rules.
- **A2** adds an assumption set of `(source, target)` pairs with the coinductive
  re-entry rule, so recursive aliases terminate.
- **A3** puts a readonly flag in `t_array`'s unused `TypeData.b`. `T[]` is
  assignable to `readonly T[]`; the reverse is not.
- **A4** records that readonly fields stay write-site-enforced. No code change,
  a test and a comment.
- **A5** formalizes the asymmetric nominal direction against the source node.

**Tests:** an unresolved ref now diagnoses instead of accepting; a recursive
alias terminates; readonly-array variance holds in both directions; a nominal
is assignable to its base and the base is not assignable back.

### Task 3: `joinTypes` on structural identity, and `normalizeUnion`

**Files:** `type_pool.zig`, `type_checker.zig`.

Step 2 of the join switches from index equality to `structurallyEqual`.
`addUnion`'s dedup becomes D1 section 3's seven steps. The `D1-interim` comment
on `joinTypes` is deleted.

**Tests:** one per join step; `never` elimination; member coalescing; strict
subsumption; first-appearance display order.

**Two corrections to D1, both measured.**

D1 asked for overflow past sixteen members to fail closed with a
`union_too_wide` diagnostic, on the grounds that the raw fallback stores a type
whose key is not canonical. The premise is right and the cap is wrong: sixteen
was the width of a stack scratch buffer, never a language limit, and the corpus
already pins wider unions as supported - `parseTypeExpr keeps unions wider than
thirty two members` and `TypeChecker tracks schema enum members beyond 32
values` are existing tests, because a schema enum is routinely wider than
sixteen. Normalizing on the heap removes the buffer and with it the reason for
the cap, so there is no `union_too_wide` and no ZTS207. The only remaining bound
is what the node's u16 member count can address.

Step 5, dropping a member assignable to another member, cannot be applied to
every member. `Effects<string, "env">` resolves to
`string & { __zttp_effect__: ... }`, which is assignable to plain `string`, so
in `Effects<string, "env"> | string` the marker branch is dropped and the result
reads as though the author declared no capability ceiling - the same fail-open
an existing test (`a marker on one union branch reports non_literal, not an
empty set`) was written to catch. Subsumption therefore never drops an
intersection member, a nominal member, or a member reaching an unresolved name.
Each exclusion is a case where assignability is not the question being asked.

### Task 4: narrowing - kill rules, `typeof`, negation, bare discriminant

**Files:** `type_checker.zig`, `bool_checker.zig`.

Kill rules 1 through 6 from D1 section 5, the `NarrowingGuard.key` sentinel fix,
`typeof` migrated up from `bool_checker.zig`, `Array.isArray`, negation of any
admitted test, bare boolean discriminant reads, and narrowing in the `else`
branch. `isDict` and `isBytes` wait for phases 4 and 5 with their types.

**Tests:** one per kill rule, each with its positive control; `if (!r.ok)`
extracts the ok branch.

**Two facts D1's table did not record, both load-bearing.**

The narrowing store was never split. D1's ground truth said it was, because
`narrowed` exists - but only the `match` path wrote to it. Every `if` and
`assert` guard overwrote `binding_types` and restored it afterwards, which is
exactly the arrangement D1 said made a narrowing impossible to kill without
losing the declaration. The split is done here rather than assumed.

Narrowing over a **function parameter** never worked at all, for any test in
the closed list. A parameter is registered in `param_types` and in the
environment; the guard extractors read `binding_types`, which holds `const` and
`let` declarations only, so every guard over a parameter silently installed
nothing. `if (v === undefined) return;` over a parameter - the most common
guard shape there is - narrowed nothing. The extractors now use `inferType`'s
own fallback chain.

That second fact is why the first three tests written for this task were
vacuous: with no narrowing at all, a program that should report one error
reports one error. Each kill-rule test now pins its positive control first.

**A defect this found in itself.** The bare-discriminant guard asked for the
member whose discriminant is `false` when the condition is `if (r.ok)`, which
selects the wrong arm. Neither the aliased-union test nor a `validateJson`
handler shows it - a union of named refs does not resolve to records, so no
guard installs and the test passes whichever way the flag is set. The offline
corpus caught it: `workflow-nested-dispatch-avoidance` reported four
`property does not exist` diagnostics that were not there before, and
`docs/coverage.json` failed on the drift. The pinned test now uses inline
record members, the shape that actually selects a member.

### Task 5: generic constraints, inference, checked instantiation

**Files:** `type_env.zig`, `type_pool.zig`, `type_checker.zig`.

`GenericScope` gains a constraint slot parsed from `extends`. `FunctionSig`
gains `type_params`. `instantiate` gains its missing `t_function` and `t_tuple`
cases. Inference is D1 section 4's one-pass argument-driven algorithm.
Ambiguity, constraint violation, and arity mismatch each get a diagnostic
(ZTS208, ZTS209, ZTS210). Explicit type arguments skip inference and are checked
against constraints. Every instantiation re-checks its value arguments.

**Tests:** `first(["a"])` returns `string`, not `"a"`; an unbound parameter
diagnoses rather than silently widening; a constraint violation diagnoses; an
explicit type argument overrides inference; `type F<T> = (x: T) => T`
substitutes.

**Three facts measured while landing this.**

**No generic alias had ever instantiated.** The stripper records a function's
type-parameter list without its angle brackets and an alias's list with them, so
splitting the alias list on commas produced the single parameter name `<V>`. No
`t_ref` in the body ever matched that, `instantiate` substituted nothing, and
`Box<string>` resolved to the uninstantiated body - where the unresolved `V`
makes assignability blanket-true, so `const b: Box<string> = { v: 1 }` was
accepted. The existing tests passed because they build the TypeMap by hand and
wrote the list the way the reader wanted to read it; the pinned test now runs
through the stripper's own recording. Splitting is depth-aware for the same
reason a bound needs it: `U extends Record<string, number>` carries its own
comma.

**Explicit type arguments needed a kind of their own.** After stripping,
`first<string>(xs)` and `<U>(x: U) => x` are the same thing: an unnamed balanced
`<...>` blanked out and followed by `(`. Only the stripper can tell them apart,
by whether the `<` follows an operand, and it already computes that answer to
decide whether the span is a comparison. It records which one it saw. Binding
the argument list to its call is then exact rather than positional: the stripper
blanks rather than deletes, so byte offsets survive into the source the parser
reads, and the call node's `(` sits one past the recorded `>`.

**A signature's type parameters have to be in scope while its own annotations
resolve.** `xs: T[]` is resolved by the type-expression parser, which knows
nothing of the scope stack, so `T` arrives as a `t_ref` either way - but a bare
`T` must reach the parameter node, and a same-named alias must not win. Both
tags are therefore matched by name during unification, which is also how
`TypePool.instantiate` substitutes.

One limit recorded rather than fixed: a type argument written at a call *inside*
a generic function (`return first<U>(xs)`) resolves without the enclosing
function's parameters in scope, so `U` stays an unresolved name and the call
neither instantiates nor diagnoses. That is the A1 fail-open, not a new one, and
it closes with A1.

### Task 6: type-predicate validation

**Files:** `type_checker.zig`, plus the parser if `value is T` is not admitted.

A function returning `value is T` installs a guard only when its body is a
single `return` of admitted narrowing tests over the named parameter, combined
with `&&`, `||`, `!`. Any other body raises `invalid_type_predicate` (ZTS211).

**Tests:** an admitted predicate narrows at the call site; a predicate whose
body calls a function is rejected; no annotation installs an unverified guard.

**Admission is on the form of the test, not on its effect.** The first version
asked the narrowing extractors whether a leaf produced a guard, and that
rejected `function isObject(x: unknown): x is object { return typeof x ===
"object"; }` - the shape the corpus writes. `typeof x === "object"` narrows
nothing when the declared type is `unknown`, because `unknown` is not a union,
and it is still exactly the test a predicate is allowed to be made of. The leaf
check is syntactic against the closed list over the named parameter.

**The corpus trips this rule, and it costs a row.** One draft in
`workflow-nested-dispatch-avoidance` writes `typeof val === "object" && val !==
undefined && "status" in val`, and `in` is not in the closed narrowing list, so
ZTS211 is right to refuse it. `zts check --json` reports the earliest failing
phase, so that draft no longer reaches the strict checker and `docs/coverage.md`
drops from seven tripped rules to six: ZTS601 was only ever felt on that draft.
The count is regenerated in the same commit. ZTS601 is not in the coverage
ratchet's baseline, so the loss is recorded rather than gated - and it is a
description of one corpus draft, not of the rule.

### Task 7: the exit gate

**Files:** a new test root or an added test in `packages/zts/src/type_key.zig`
and `packages/tools/src/precompile_check.zig`.

The frozen signature corpus is the `.d.ts` surface `zts check --types` already
generates from `builtin_modules.all`, so it covers every virtual-module export
by construction and cannot drift from the bindings. The gate parses each emitted
signature into the pool and asserts: no member resolves to `unknown` by
fallback, every signature has a stable digest across two runs, and the digest
set is pinned so a signature change is visible in the diff.

The gate asserts a floor on its own input first: the corpus is empty if
`builtin_modules.all` is empty or the emitter writes nothing, and an empty
corpus fails rather than reporting a pass over nothing.

**Tests:** the floor; per-export digest stability; the no-`unknown` assertion.

---

## Risks

The generics retrofit has the long tail the master plan named. The frozen
corpus is what bounds it: a signature that does not instantiate is a failing
row, not a silent `unknown`.

A1 is the amendment most likely to break the existing corpus, because every
site that asks about an unresolved name gets an answer it did not get before.
Task 2 runs `bash scripts/test-examples.sh` before it commits for that reason.
