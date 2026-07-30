# D1: type-system design doc

**Owns:** the assignability relation, generic inference, narrowing dataflow, the
join and union normalization, and the canonical type serialization.
**Unblocks:** master-plan Phase 2 (type-system rock), Phase 3 (recursive
aliases), Phase 4 (Dict/JSON typing, `Schema<T>`), and D3's type digests.
**Retires:** the `D1-interim` markers introduced in Phase 0.
**Spec basis:** `docs/zts-formal-spec-northstar-advanced.md` rev 4, sections
5.4 (join, narrowing), 5.6 (generics), 5.7 (types).

---

## 0. Ground truth (measured, not assumed)

| Fact | Location | Consequence for this doc |
|---|---|---|
| Types are **not interned**; `addNode` always appends | `type_pool.zig:209-221` | `TypeIndex` equality is not structural identity. Every spec rule phrased as "identical" or "duplicate identities" needs a structural key. **This is the doc's central problem.** |
| 22 `TypeTag` members; no readonly-array tag exists | `type_pool.zig:42-76` | `readonly T[]` is currently unrepresentable; spec 5.7 admits it. |
| `isAssignableTo` returns **true** for unresolved `t_ref`/`t_generic_param` on either side | `type_pool.zig:1201-1202` | Direct violation of gate 14.1 "never falls back to `unknown`". |
| No recursion guard or memo in assignability | `type_pool.zig:1207-1232` | Contractive recursive aliases (spec 5.7) would not terminate. |
| Union dedup is by `TypeIndex` equality into a 16-slot buffer; >16 members stores raw and lossy | `type_pool.zig:374-410` | `"a" \| string` keeps both members; no `never` elimination; no ordering. |
| `t_literal_number` stores `@bitCast(i16)`; out-of-range literals silently widen to `number` | `type_pool.zig`, `type_checker.zig:1177-1181` | Literal types are unsound above 32767. Named below as a known limit. |
| Two narrowing systems: `TypeIndex`-based in `type_checker.zig`, `ExprType`-based in `bool_checker.zig` | `type_checker.zig:109,130`; `bool_checker.zig:30-58,162` | `typeof` narrowing exists **only** in the coarse system. The spec's closed list needs both or one. |
| Narrowing is **never invalidated** on assignment, aliasing, or loop back edge | `type_checker.zig:530-545` | A guard installed by early return survives a later reassignment. Unsound. |
| `NarrowingGuard.key` defaults to 0 and callers test `!= 0` | `type_checker.zig:318,381` | Binding at scope 0 slot 0 can never narrow. |
| `instantiate` omits `t_function` and `t_tuple` from its switch | `type_pool.zig:564-668` | `type F<T> = (x: T) => T` never substitutes. |
| No type-argument inference anywhere; no constraint storage | `type_env.zig:54-78,892-908` | Spec 5.6 inference must be built, not fixed. |
| `formatType` truncates into a caller buffer and returns `"?"` on overflow | `type_pool.zig:1351-1356` | Unusable as an identity function. |
| Eight ad-hoc join sites already exist (ternary, `&&`, `??`, match arms, ...) | `type_checker.zig:1198,1393,1408,1711,1472,1597` | One `joinTypes` subsumes all of them. |

---

## 1. Decision: canonical type serialization is the identity function

Because types are not interned, this doc introduces **one** canonical string per
type and derives everything else from it. This single decision resolves join
step 2, union dedup, recursive-alias comparison, and D3's type digests.

**`canonicalTypeString(pool, idx, writer) !void`** emits a deterministic
pre-order encoding. Grammar (ASCII, no whitespace, no ambiguity):

```
type    := prim | lit | rec | arr | tup | fn | uni | isect | nom | ref | tmpl | rec_ref
prim    := "b" | "n" | "s" | "u" | "d" | "v" | "!" | "?"      # bool number string
                                                              # undefined null void
                                                              # never unknown
lit     := "L" ("s" len ":" bytes | "n" digits | "b" ("0"|"1"))
rec     := "R" count ( flags name_len ":" name type )*         # fields sorted by name
flags   := "." | "o" | "r" | "or"                              # optional / readonly
arr     := "A" ("m"|"r") type                                  # mutable / readonly
tup     := "T" ("m"|"r") count type*
fn      := "F" param_count type* "->" type
uni     := "U" count type*                                     # members in canonical order
isect   := "I" count type*                                     # members in canonical order
nom     := "N" name_len ":" name type                          # distinct type over base
ref     := "@" name_len ":" name                               # unresolved: an error, never emitted
tmpl    := "M" part_count ( "l" len ":" bytes | "t" type )*
rec_ref := "^" depth                                           # back-reference, see below
```

Rules that make it canonical:

1. **Record fields sort by name** (byte order), so field declaration order never
   affects identity. Declaration order is preserved separately for JSON encoding
   (spec 6.4 requires wire order) — it lives on the record node, not in the key.
2. **Union and intersection members sort by their own canonical strings.** This
   is the spec's "identity over the member set" (rev 4, 5.4): `string | number`
   and `number | string` produce one key. Source order is retained on the node
   for display and for the join's first-appearance rule; it is absent from the
   key.
3. **Recursion terminates via de Bruijn back-references.** Walking maintains a
   stack of in-progress node indices; re-entering a node already on the stack
   emits `^k` where `k` is the distance from the top. This makes the encoding of
   a cyclic type finite and structure-preserving, and it is what
   `structurallyEqual` and the digest both consume.
4. **Nominal types encode their name.** Two distinct types over `string` have
   different keys, which is what makes `UserId` and `OrderId` non-interchangeable
   in a union.
5. **An unresolved `t_ref` is a hard error**, never an emitted key. Callers
   resolve through `TypeEnv` first. This is where the current
   `isAssignableTo` escape hatch dies.

Derived, both memoized in a side table keyed by `TypeIndex`:

- `typeKey(idx) []const u8` — the string above, arena-allocated, computed once.
- `typeDigest(idx) [32]u8` — `SHA-256(typeKey)`, hex-encoded at wire boundaries.
  D3 consumes this; the algorithm and encoding match every other hash in the
  repo (SHA-256, lowercase hex).
- `structurallyEqual(a, b) bool` — `a == b or mem.eql(typeKey(a), typeKey(b))`.

**Cost:** one arena string per distinct type per compilation. The pool caps at
65535 nodes and the names arena at 64 KB today; the key arena is new and
separate, sized by measurement before the cap is set. **Do not** retrofit
hash-consing into `addNode`: 22 tags with packed side-array payloads make that a
much larger change than the memoized key, and the key is needed for digests
regardless.

**Known limit carried forward:** `t_literal_number` holds an `i16`. Literal
types outside `[-32768, 32767]` widen to `number` before reaching the key, so
they are indistinguishable in identity. Documented, not fixed in this doc;
fixing it is a `TypeData` layout change worth its own ticket.

---

## 2. Decision: the assignability relation

The existing relation (`type_pool.zig:1061-1205`) is **kept as the base** and
amended by six changes. It is already a reasonable structural subtyping
relation; the amendments close soundness holes the spec's gates test for.

**A1 — unresolved names are an error, not `true`.** Delete the
`t_ref`/`t_generic_param` blanket-true at `:1201-1202`. Callers must resolve
refs through `TypeEnv.resolveType` before asking. An unresolved name at an
assignability site raises a diagnostic (new code in the ZTS5xx band,
`unresolved_type_reference`) rather than silently accepting. This is the
concrete meaning of gate 14.1's "never falls back to `unknown`".

**A2 — memoized pair comparison with a cycle guard.** Assignability takes an
`AssumptionSet` of `(source, target)` pairs currently being compared. On
re-entry with a pair already in the set, return `true` (coinductive
assumption — the standard equirecursive rule, and exactly what spec 5.7's
"memoized pair comparison" names). This is what makes `JsonValue` assignability
terminate. Set is a small sorted array; depth is bounded by the type-graph size.

**A3 — readonly arrays become representable.** `t_array` gains a readonly flag
in the unused `TypeData.b` field (`b = 1` means readonly). Variance:
`T[]` is assignable to `readonly T[]`; `readonly T[]` is **not** assignable to
`T[]`. Element position stays covariant, which is unsound under mutation for the
mutable case and is the same trade TypeScript makes; the spec does not require
element invariance and the corpus does not exercise it.

**A4 — readonly fields stay write-site-enforced.** Record assignability ignores
the `readonly` flag (current behavior at `:1207-1232`); assigning **through** a
readonly field is rejected at the assignment site
(`type_checker.zig:546-568`). Deliberate: field-variance would reject the
`Pick`/`Omit`/`Partial` flows the spec admits, for no proof the profile claims.

**A5 — nominal direction is asymmetric and stays that way.** `UserId` is
assignable to `string` (spec 5.7: "a distinct value supports the operations of
its base type"); `string` is **not** assignable to `UserId`, and neither is
`OrderId` (spec 5.7, enforced today by the nominal check at `:1079-1084`).
Formalize by consulting `node.nominal` on the **source** as well: if the target
is nominal and the source is not the same nominal node, reject unless both are
records reaching `isRecordAssignable` — which is current behavior, now
documented as intentional rather than incidental.

**A6 — `t_null` becomes live.** The type parser maps `"null"` to `unknown`
(`type_pool.zig:1861`) and inference maps `lit_null` to `undefined`
(`type_checker.zig:1189`). Both are removed in Phase 3 when source `null` is
admitted; `t_null` then behaves as an ordinary primitive, assignable only to
itself, to `unknown`, and to unions containing it. `t_nullable` keeps meaning
`T | undefined` — note its display bug (`writeType` prints `T | null` at
`:1416-1418`) is fixed at the same time, since the canonical key would otherwise
disagree with what a human reads.

Everything else in the existing relation — width subtyping, optional-field
rejection, union both-directions, intersection merging, literal widening,
tuple-to-array, template-literal matching, function contravariance — is
**adopted as specified**, and this section is the normative statement of it for
the profile.

---

## 3. Decision: the join rule

One `joinTypes(when_true, when_false) TypeIndex` implements spec 5.4 steps 1-5
and replaces all eight ad-hoc sites listed in section 0.

```
1. never:      both never -> never; one never -> the other
2. identical:  structurallyEqual(a, b) -> a          # section 1, NOT index equality
3. mutual:     assignable both ways -> a             # the whenTrue branch, spec rev 4
4. one-way:    a -> b assignable -> b; b -> a -> a   # the receiving type
5. otherwise:  normalizeUnion([a, b])
```

Step 2 is the reason section 1 exists: with index equality, two separately
constructed `{ id: string }` records would fall through to step 3, and only
mutual assignability would rescue them — producing the right type by accident
and the wrong one whenever a field is optional on one side.

**Union normalization** (`normalizeUnion`), replacing `addUnion`'s dedup:

```
1. flatten nested unions (already present)
2. drop `never` members                              (new)
3. dedup by typeKey                                  (was: TypeIndex equality)
4. coalesce mutually assignable members to the first written   (new)
5. drop a member strictly assignable to another member         (new)
6. keep survivors in first-appearance order                    (new: was arbitrary)
7. one survivor -> that type; zero -> never
```

First-appearance order is display order only; the canonical key sorts (section
1, rule 2), so identity is order-free while the printed type reads the way the
author wrote it.

**Overflow fails closed.** Today >16 members abandons dedup and stores the raw
sequence (`type_pool.zig:396-399`), which silently produces a type whose key is
not canonical. Replace with a diagnostic (`union_too_wide`, ZTS5xx) at the
existing `MAX_UNION_MEMBERS = 16`. Raising the cap is a separate measured
decision; failing closed at the current cap is the correct default for a profile
whose whole claim is closed semantics.

---

## 4. Decision: generic inference

Spec 5.6 constrains the outcome; this is the algorithm.

**Representation.** `GenericScope` gains a per-parameter constraint slot
(`constraint: TypeIndex = null_type_idx`), parsed from `extends` in
`TypeParam`. `FunctionSig` gains `type_params: []GenericParam`. `instantiate`
gains the two missing cases: `t_function` (substitute parameters and return) and
`t_tuple` (substitute each element) — without these, the profile's own
`Component<P>` and `parallel` tuple signatures cannot be instantiated.

**Inference is one-pass, argument-driven, no return-type propagation.**

```
infer(sig, arg_types):
  bindings := {}                                  # param name -> TypeIndex
  for (param_type, arg_type) in zip(sig.params, arg_types):
      unify(param_type, arg_type, bindings)
  for each type param P of sig:
      if P unbound:
          if P has a default: unreachable (defaults excluded, spec 5.6)
          else: AMBIGUOUS(P)
      if P.constraint != none and not assignable(bindings[P], P.constraint):
          CONSTRAINT_VIOLATION(P)
  return bindings
```

`unify(pattern, actual, bindings)` walks both structurally:
- `pattern` is `t_generic_param P`: if `P` unbound, bind to `actual` (widening
  a literal to its base **only** when `actual` is a literal and `P`'s constraint
  does not itself accept literals — this keeps `first(["a"])` returning `string`,
  not `"a"`, matching the corpus expectation); if bound, join the existing
  binding with `actual` via `joinTypes`.
- both records: unify field-wise on names present in the pattern.
- both arrays/tuples/functions/unions: unify positionally; a union pattern with
  exactly one generic member binds it to the whole actual.
- otherwise: no binding contributed (assignability checks it afterward).

**Ambiguity is exactly "a type parameter appears in no value-parameter
position, or unification produced no binding for it."** That is the decidable
criterion spec 5.6 leaves open. The diagnostic names the parameter and states
that an explicit type argument is required — which the spec already permits.

**Explicit type arguments** skip inference entirely and are checked against
constraints. Arity mismatch is an error (today it silently leaves the
application uninstantiated, `type_env.zig:539`).

**Checked instantiation.** After binding, substitute and re-check every value
argument against its substituted parameter type. This is the "every
instantiation is checked" gate; the frozen signature corpus from the master plan
is what proves it holds across every virtual-module export.

**Out of scope, as the spec excludes them:** variance annotations, higher-kinded
types, conditional/mapped/`infer` types, generic defaults, overload sets,
rank-2 polymorphism (spec rev 4 made function types monomorphic, so the
`FunctionType` production carries no `TypeParams` and `instantiate` never meets
a nested binder).

---

## 5. Decision: narrowing dataflow

Spec 5.4's list is a set of tests and positions; a checker needs the kill rules
too. This section supplies them.

**One authoritative system.** The `TypeIndex` narrowing in `type_checker.zig` is
authoritative for the profile. `bool_checker.zig`'s `ExprType` narrowing stays
as an independent boolean-soundness pass and **must not contradict** it; its
`typeof` support migrates up (below), and a divergence between the two is a bug
in the checker, not a language ambiguity.

**Narrowing store.** Separate `narrowed` from `binding_types`. Today
`binding_types` doubles as declared-type store and flow store
(`type_checker.zig:109`), which is why nothing can be invalidated without losing
the declaration. After the split: `binding_types` is the declared/inferred type,
`narrowed` is the flow-sensitive overlay, and killing a narrowing means dropping
the overlay entry.

**Tests recognized** (spec 5.4 closed list, mapped to implementation):

| Test | Status |
|---|---|
| `=== / !==` vs `undefined`, `null`, literal | exists (`:1244-1299`), extend to `null` in Phase 3 |
| `typeof x === "..."` | **migrate** from `bool_checker.zig:1395-1415` into the TypeIndex system |
| `Array.isArray(x)` | new |
| `isDict(x)`, `isBytes(x)` | new, Phase 4/5 with the types |
| literal discriminant field test | exists (`:1317-1371`) |
| bare boolean discriminant read (`if (r.ok)`) | new — required by the spec's `ok`-guard idiom |
| `!` of any admitted test | new — required by `if (!r.ok) return` |
| validated type predicate `x is T` | new; predicate-body validation below |

**Positions:** `if`/`else` **both** branches (today the else branch narrows
nothing, `:348-350`), `?:` both branches, `match` arms, after `assert`, after an
early-exit guard, and the right operand of `&&`/`||`. This is the spec list
verbatim.

**Kill rules — the half the spec omits:**

1. **Assignment kills.** Any assignment to binding `k` drops every narrowing
   entry for `k`. Today `walkExpr .assignment` (`:530-545`) does not touch the
   store; this is a real unsoundness fix, not a refactor.
2. **Aliasing does not propagate and does not need to.** Narrowing keys are
   `(scope, slot)` bindings, never member paths, and the language has no
   references, so a narrowed binding cannot be mutated through another name.
   `const y = x` snapshots the type at declaration (`:269-307`) and is unaffected
   by later narrowing of `x` — correct, and now documented.
3. **Member-path scrutinees are not narrowed.** Spec 5.5 allows a member path as
   a `match` scrutinee; narrowing binds to the **arm-scoped binding pattern**,
   not to the path. A record field is writable, so narrowing `x.f` across a call
   would be unsound without an alias analysis the profile does not have. Binding
   patterns (Phase 3) are what make this a non-restriction.
4. **Loop back edges kill.** Narrowings established inside a `for...of` body are
   dropped at the back edge; narrowings established **before** the loop survive
   only if the binding is not assigned anywhere in the body. Implementation: scan
   the body for assignments once, kill those keys at loop entry.
5. **Scope exit kills.** Truncate `narrowed` on scope pop, as
   `active_declared_types` already does (`:255-256`).
6. **Calls do not kill.** No capability call can reach a local binding, since the
   language has no references and module state is immutable (spec 5.1). This is
   what makes the `ok`-guard idiom sound across an intervening call.

**Fix the sentinel.** `NarrowingGuard.key` uses 0 as "absent"
(`:318,381`), which makes scope-0 slot-0 unnarrowable. Replace with an optional
(`?u32`).

**Type-predicate validation** (spec 5.7: "the checker validates the predicate
body before using it"). A function returning `value is T` is accepted as a guard
only when its body is a single `return` of a chain of admitted narrowing tests
(section above) over the named parameter, combined with `&&` / `||` / `!`. Any
other body is rejected with a diagnostic; no annotation can install a guard the
checker did not verify. This is deliberately narrow — it covers the JSON and
schema predicates the corpus needs, and it can widen later with evidence.

---

## 6. Implementation order (feeds master-plan Phase 2)

1. `canonicalTypeString` + `typeKey` memo + `structurallyEqual` + `typeDigest`
   (section 1). Tests: two independently built identical records share a key;
   member-order-different unions share a key; a cyclic alias terminates.
2. Assignability amendments A1-A5 (A6 waits for Phase 3). Tests: unresolved ref
   now diagnoses; recursive alias assignability terminates; readonly-array
   variance holds both directions.
3. `joinTypes` + `normalizeUnion`; migrate all eight ad-hoc sites. Tests: the
   spec's five join steps, each with a case; union overflow diagnoses.
4. Narrowing store split, kill rules, `typeof` migration, negation and bare
   discriminant tests, sentinel fix. Tests: one per kill rule, plus the
   `if (!r.ok) return;` extraction the `Result` idiom depends on.
5. Generic constraints, `instantiate` function/tuple cases, inference,
   ambiguity diagnostic, checked instantiation. Tests: the frozen signature
   corpus over every virtual-module export.
6. Type-predicate validation.

Each numbered item is one commit with its tests; each keeps
`bash scripts/verify.sh` green.

---

## 7. Deliberately deferred

- Hash-consing the pool. The memoized key delivers identity without a layout
  change; interning is a performance decision to be made against a measurement,
  not a correctness one.
- `t_literal_number`'s i16 limit (section 1).
- Element invariance for mutable arrays (A3).
- Widening the 16-member union cap (section 3).
- Unifying `bool_checker`'s `ExprType` lattice into the `TypeIndex` system. Two
  passes with a no-contradiction obligation is cheaper than one merged pass, and
  the boolean checker's role in the strictness gates is orthogonal.
