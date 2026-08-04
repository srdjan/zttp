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
`addUnion`'s dedup becomes `normalizeUnion` with D1 section 3's seven steps.
Overflow past `MAX_UNION_MEMBERS` stops storing a lossy raw sequence and raises
`union_too_wide` (ZTS207). The `D1-interim` comment on `joinTypes` is deleted.

**Tests:** one per join step; `never` elimination; member coalescing; strict
subsumption; first-appearance display order; overflow diagnoses.

### Task 4: narrowing - kill rules, `typeof`, negation, bare discriminant

**Files:** `type_checker.zig`, `bool_checker.zig`.

Kill rules 1 through 6 from D1 section 5, the `NarrowingGuard.key` sentinel fix,
`typeof` migrated up from `bool_checker.zig`, `Array.isArray`, negation of any
admitted test, bare boolean discriminant reads, and narrowing in the `else`
branch. `isDict` and `isBytes` wait for phases 4 and 5 with their types.

**Tests:** one per kill rule; `if (!r.ok) return;` extracts the ok branch;
scope-0 slot-0 narrows; the two systems do not contradict each other on a
shared corpus.

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

### Task 6: type-predicate validation

**Files:** `type_checker.zig`, plus the parser if `value is T` is not admitted.

A function returning `value is T` installs a guard only when its body is a
single `return` of admitted narrowing tests over the named parameter, combined
with `&&`, `||`, `!`. Any other body raises `invalid_type_predicate` (ZTS211).

**Tests:** an admitted predicate narrows at the call site; a predicate whose
body calls a function is rejected; no annotation installs an unverified guard.

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
