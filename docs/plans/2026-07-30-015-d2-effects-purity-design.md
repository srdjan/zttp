# D2: effects and purity design doc

**Owns:** the effect-row atom set and its capability mapping, row syntax and
inference, the row join, the purity predicate, `Proof<T, P>`'s property domain,
and the flow labels behind the `assert` rule.
**Unblocks:** master-plan Phase 4 (effect-row polymorphic `Result` combinators),
Phase 5 (the decidable `Effects` ceiling rule), and every spec MUST that says
"pure".
**Retires:** the `D2-interim` purity marker from Phase 0.
**Spec basis:** rev 4, sections 4.4, 5.5 (`assert`), 5.7 (capsules), 6.1
(combinators), 6.5 (callbacks), 7 (capabilities).

---

## 0. Ground truth (measured)

| Fact | Location | Consequence |
|---|---|---|
| `EffectRow` = `EnumSet(ModuleCapability)` + `{deterministic, pure, recursive, has_egress, writes}` | `effect_inference.zig:46-85` | A real row exists; it needs atoms named in the spec, not new machinery. |
| `ModuleCapability` has exactly 11 members | `module_binding.zig:1247-1259` | The atom set is already closed. Adopt verbatim. |
| Capabilities are declared **per module**, unioned for a call to **any** export | `module_binding.zig:1581`; `effect_inference.zig:477-479` | `escapeHtml` from `zttp:text` carries the whole module's capabilities. Over-approximation that makes every ceiling wrong. |
| `collectFunctionsIn` walks only top-level forms and does not recurse into bodies | `effect_inference.zig:236-262` | A function declared inside a function contributes **nothing** — effects are dropped, not attributed. |
| `handleCall` returns unless the callee is an `.identifier` | `effect_inference.zig:474` | Calls through a parameter or a member contribute an empty row. Silent under-approximation. |
| Inline arrows are inlined into the enclosing row; a closure bound to a local `const` is dropped | `effect_inference.zig:449-453` | Inline callbacks are handled; named local ones are not. |
| `EffectRow.pure` is cleared by **any** module call, including `.effect = .none` helpers | `effect_inference.zig:481` | Function-level only, and stricter than the spec's notion in one direction, weaker in another. |
| Nine distinct "pure" mechanisms exist; none is expression-level | §7 of the ground-truth sweep | The spec's ~15 normative uses of "pure" have no single referent. |
| `Effects<T, R>` is a built-in alias expanding to `T & { __zttp_effect__: R }`; erased by `stripProofMarkers` | `type_env.zig:170-176, 218-247, 769-791` | The capsule mechanism works. Keep it. |
| A non-literal `R` extracts zero names and is indistinguishable from "no annotation"; no diagnostic | `spec_discharge.zig:627`; `contract_builder.zig:911` | Fail-open. The one hole that lets an unchecked program claim conformance. |
| `Proof<T, P>`'s `P` **is** defined in code: `CapsuleProperty = { total, pure, read_only, deterministic }` | `spec_discharge.zig:475-484` | The spec's "P is undefined" gap is a *spec* gap, not a code gap. |
| `CapsuleFacts.holds` returns false for every property when `recursive` | `spec_discharge.zig:504-506` | Matches spec 5.6: recursion yields no totality claim without a decreasing argument. |
| Flow labels exist: 7 `DataLabel` members, `LabelSet` with `mergeConditional` AND-ing `validated` | `module_binding.zig:1283-1352`; `flow_checker.zig` | The `assert`-on-`user_input` rule has its analysis already. |

---

## 1. Decision: the atom set is `ModuleCapability`, verbatim

The effect-row alphabet is exactly the existing enum — no new vocabulary, no
respelling, no aliasing:

```
env  clock  random  crypto  stderr  runtime_callback
sqlite  filesystem  network  policy_check  websocket
```

`spec_discharge.effect_capability_names` already derives the `Effects<...>`
vocabulary from this enum by `@typeInfo` (`spec_discharge.zig:593-598`), so
source spelling and enum cannot drift. The spec's example row
`"env" | "network"` is already valid under it.

**Consequences to fix as part of adopting it:**
- `rule_registry.zig:518` (the ZTS504 help string) lists 10 names and omits
  `websocket`. Generate the help text from the enum instead of hand-listing.
- `module_binding.zig:1244-1246` documents these as "not affecting handler-level
  effect classification", which stopped being true at
  `effect_inference.zig:478-479`. Delete the stale comment.

**Row atoms are capabilities only.** The five booleans on `EffectRow`
(`deterministic`, `pure`, `recursive`, `has_egress`, `writes`) are **derived
facts**, not row members: they feed `Proof` properties and contract flags, they
are never written in an `Effects<...>` annotation, and they never appear in a
digest of a row. Keeping them off the atom set is what lets the row be a plain
set with a set join.

**Row join** is `EffectRow.merge` (`effect_inference.zig:59-68`) unchanged:
capabilities union, `deterministic`/`pure` AND, the rest OR. It is already the
lattice join the spec's "join of the callback's row and its operands' rows"
(rev 4, 6.1) requires.

**Row subset** — used by every ceiling check — gets a first-class
`EffectRow.capabilitiesSubsetOf(other) bool`. Today the subset test is written
ad hoc at the two discharge sites; naming it is what lets D3 hash it and the
protocol report it.

---

## 2. Decision: capabilities move from module-scoped to export-scoped

Per-module capabilities make every ceiling an over-approximation:
`import { escapeHtml } from "zttp:text"` today demands whatever `zttp:text`
demands as a whole. Under a mandatory-ceiling rule (spec 5.7) that turns into
annotations that are wrong on their face, which is worse than no annotation.

**Change:** `FunctionBinding` gains
`required_capabilities: []const ModuleCapability = &.{}` alongside its existing
`effect: EffectClass`. `effect_inference.handleCall` resolves the **export**
(it already calls `builtin_modules.findExport` for `EffectClass` at
`:531-536`) and unions that export's set.

**Migration is incremental and fail-closed.** A binding whose exports declare no
capabilities keeps the module-level set as the per-export default, so nothing
regresses on day one; the 24 module bindings are then tightened export by
export, each tightening being a separate reviewable commit with the module's
tests. `validateBindings` gains a comptime check that an export's set is a
subset of its module's declared set, so a tightening can never widen authority
by accident.

**`zttp-ext:` partner modules contribute the empty set today** because the union
is guarded by `builtin_modules.fromSpecifier` (`effect_inference.zig:477`) while
`EffectClass` comes from the partner registry. That is a fail-open hole in the
authority story: an extension module's calls carry no capabilities at all. Fix
with the same change — resolve capabilities from whichever registry resolved the
export, and treat an unresolvable export as **all capabilities** (fail closed)
rather than none. This is the spec's "unknown module makes the certified build
fail closed" (rev 4, 4.5) applied at the row level.

---

## 3. Decision: one purity predicate, three scopes

The spec says "pure" of expressions, of callbacks, and of functions. One
definition, evaluated at three granularities.

**Core definition.** An expression is **pure** when its evaluation:
1. contributes no capability to the effect row,
2. performs no assignment (to a binding, a record field, or an array element),
3. and cannot halt other than by a bounds or arithmetic fault the kernel raises
   for any expression.

**Expression scope** — the new predicate, replacing Phase 0's `D2-interim`
syntactic approximation:

```
purityOf(expr) = pure   if expr is a literal, identifier, member read,
                           index read, template over pure parts, array/record
                           literal over pure parts, unary/binary op over pure
                           operands, or `?:` over pure parts
               = pure   if expr is a call whose callee resolves to a function
                           whose EffectRow has an empty capability set and
                           `writes == false`
               = impure otherwise (assignment, unresolvable callee, any call
                           carrying a capability or a write)
```

The call case is the substantive change over Phase 0: a call to a genuinely pure
helper (`formatRatio`, `escapeHtml` once §2 lands) is pure, so it may appear in a
`?:` arm. Phase 0's approximation rejected every call; this one asks the row.

**Callback scope** (spec 6.5: HOF callbacks MUST be pure; 6.1: `Result`
combinator callbacks MAY be effectful). A callback is pure when the function it
denotes has an empty capability set, `writes == false`, and every function
reachable from it does too — which is exactly `EffectRow.pure` after
propagation, once `pure` stops being cleared by capability-free module calls
(below).

**Function scope.** `EffectRow.pure` is redefined as
`capabilities.count() == 0 and !writes and deterministic`. Today it is cleared
unconditionally by any imported call (`effect_inference.zig:481`), which makes
`escapeHtml` impure and is why the flag cannot be used as the callback test. The
`Date.now`/`Math.random` clearing (`:470`) is subsumed by `deterministic`.

**Consequence to accept:** `Proof<T, "pure">` becomes provable for more
functions than today. That is the point — the current flag is not the property
its name claims, and four other mechanisms (`HandlerProperties.pure`,
`V1Spec` "pure", `Law.pure`, `replay_pure`) already mean four other things. This
doc renames nothing; it fixes the one that the language surface consumes and
leaves the binding-level `Law.pure` and `replay_pure` alone, since those are
audited claims about native modules, not inferences about source.

---

## 4. Decision: inference gaps close, function types carry a ceiling

Three holes in `effect_inference.zig` make the row unsound. All three close;
the third needs a type-system change.

**I1 — collect nested functions.** `collectFunctionsIn` recurses into function
bodies, so a function declared inside another becomes its own unit with its own
row, and the enclosing function gets a call edge to it. Today its effects vanish
(`:236-262`, `:356-358`). Local named functions are admitted by the profile
(spec 5.5 statement set), so this is not a hypothetical.

**I2 — closures bound to a local `const` are units.** Same fix, same reason:
`const isDone = (t) => ...` inside a body is collected rather than skipped at
`:352`.

**I3 — calls through function-typed values.** The callee-must-be-an-identifier
guard (`:474`) silently under-approximates. The fix follows the spec rather than
inventing row variables:

- **Function types carry an effect ceiling.** A `FunctionType` whose return type
  is `Effects<T, R>` declares that any value of that type may perform at most
  `R`. A function type **without** a capsule declares the empty row — a pure
  callback. This is exactly spec 6.5 ("Its callback MUST be pure") made
  representable, and it is why no row variables are needed for user code.
- Calling through a parameter or any function-typed value contributes that
  type's declared row. An unresolvable callee contributes **all capabilities**
  (fail closed), with a diagnostic naming the site.
- Assigning a function to a function-typed position checks row subset in the
  same direction as every other ceiling: the value's inferred row must be a
  subset of the target type's declared row.

**Result combinators need no row variables** because they are checker
intrinsics: `row(andThen(r, f)) = row(r) ∪ row(f)` is a special case in the
checker, not a signature the source type system has to express. Same for
`mapResult`, `mapError`, `orElse`. This is the concrete reading of spec 6.1's
"effect-row polymorphic".

---

## 5. Decision: `Effects<T, R>` and `Proof<T, P>` keep their mechanism, lose their fail-open

**Keep.** The built-in-alias expansion to `T & { __zttp_effect__: R }`
(`type_env.zig:218-247`) with erasure via `stripProofMarkers` (`:769-791`) is a
working transparent capsule that costs no runtime representation. It stays, and
this doc is the statement that it is intentional rather than incidental.

**`R` is a closed literal union of atom names**, resolved through alias refs
(`collectLiteralUnionStrings`, `type_env.zig:858-886`). Three fail-open holes
close:

1. **A non-literal `R` is an error**, not zero names. Today
   `Effects<T, SomeComputedThing>` extracts nothing and is indistinguishable
   from no annotation (`spec_discharge.zig:627`). New diagnostic:
   `effect_ceiling_not_literal`.
2. **An all-invalid budget no longer suppresses the budget check**
   (`contract_builder.zig:938`). ZTS504 fires per bad name **and** the budget
   check proceeds against the empty ceiling, so an over-budget capability still
   reports.
3. **An exported function with a nonempty inferred row and no ceiling is an
   error** under the spec's decidable rule (rev 4, 5.7): exported + nonempty
   MUST declare; module-internal MUST NOT. Today this is ZTS610 in the canonical
   band and ZTS507 in an opt-in docs mode; the rule collapses them into one
   always-on check whose repair is computed from the inferred row.

**`P`'s domain is `CapsuleProperty`, and the spec adopts it.** The four members
`{ total, pure, read_only, deterministic }` (`spec_discharge.zig:475-484`) are
already checked against `CapsuleFacts` derived from the row plus
`functionAlwaysReturns`. The spec's open question ("what does `P` range over")
is answered by the code; the spec text should be amended to name this enum.
`CapsuleFacts.holds` returning false for every property under `recursive`
(`:504-506`) is exactly spec 5.6's "no runtime stack cap may be presented as a
termination proof" and needs no change.

**Direction asymmetry stays and gets documented in the spec:** `Effects` checks
`inferred ⊆ declared`; `Proof`/`Spec` check `declared ⇒ proven`
(`spec_discharge.zig:582-588`).

---

## 6. Decision: flow labels back the `assert` rule

Spec 5.5 rejects `assert` on a value whose flow label is `user_input` or
ingress-derived. The analysis exists and needs no design: `DataLabel` has 7
members, `LabelSet.mergeConditional` AND-s `validated` so an unvalidated branch
cannot launder it, request parameters are seeded `user_input`, and unknown
callee shapes fail closed with the union of receiver and argument labels
(`flow_checker.zig:1277-1287`).

**The rule:** `assert e;` is an error when `labelsOf(e)` contains `user_input`
and does not contain `validated`. Exact repair: `if (!e) { return err(...); }`.
Diagnostic code in the ZTS6xx canonical band.

**Not extended:** the label set, the propagation rules, or the sink list. This
doc consumes the analysis; it does not redesign it.

---

## 7. Implementation order (feeds master-plan Phases 4-5)

1. §1 atom-set adoption: generate ZTS504 help from the enum, delete the stale
   comment, add `capabilitiesSubsetOf`. Tests: help text lists 11 names.
2. §3 purity: redefine `EffectRow.pure`, implement `purityOf(expr)`, replace the
   Phase 0 `D2-interim` predicate at the `?:` site. Tests: a call to a
   capability-free helper is pure in a `?:` arm; a capability call is not.
3. §4 I1/I2: collect nested and const-bound functions. Tests: a nested function's
   capability reaches the enclosing function's row.
4. §5 fail-open closures: non-literal `R` diagnoses; invalid budget no longer
   suppresses; the exported-ceiling rule becomes always-on with its computed
   repair. Tests: one per hole.
5. §2 export-scoped capabilities: `FunctionBinding.required_capabilities` with
   module-set default, comptime subset validation, `handleCall` resolution
   change, unresolvable export fails closed. Then tighten the 24 bindings, one
   commit per module. Tests: `escapeHtml` carries no capability.
6. §4 I3: function-type ceilings, subset check on assignment, calls through
   values, fail-closed unresolvable callee. Depends on D1's function-type
   handling. Tests: a pure-typed callback rejects an effectful function.
7. §6 the `assert` flow rule. Tests: assert on a request field errors with the
   repair; assert on a validated value passes.

---

## 8. Deliberately deferred

- Row variables and true effect polymorphism in source. Intrinsics plus declared
  ceilings cover the profile's surface; row variables are a large type-system
  change for cases the corpus does not contain.
- Unifying the nine purity mechanisms. This doc fixes the one the language
  consumes and leaves the audited native-module claims (`Law.pure`,
  `replay_pure`) and the contract-level flags alone.
- Per-argument capability refinement (a call's capabilities depending on which
  literal argument it receives).
- `has_egress`'s dead seed: the row's egress bit keys on a `fetchSync` export
  that does not exist (`effect_inference.zig:485-489`); handler-level egress is
  computed elsewhere. Harmless, worth a cleanup ticket.
