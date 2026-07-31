# zts-advanced-1 revision 4: master implementation plan

**Source spec:** `docs/zts-formal-spec-northstar-advanced.md` (revision 4, 2026-07-30)
**Readiness basis:** three-lens fresh-eyes review (implementer, standards editor,
tech lead), 2026-07-30. Verdict: start now on the specified half; write three
companion design docs in week one; do not build the certificate layer.
**Plan style:** this document is the program map. Each phase gets its own
detailed executable plan (bite-sized tasks, real code) when it starts. Phase 0
is already detailed: `2026-07-30-013-zts-advanced-rev4-phase0-plan.md`.

## Goal

Implement the `zts-advanced-1` language profile incrementally on the existing
engine, keeping `scripts/verify.sh` green at every phase boundary, without
building the certificate/verifier stack or the two-client conformance lab in
this program.

## Ground rules

1. Follow the repo's simplification direction: interpreter-only, no kernel
   growth except where the spec names it (array append), minimum code.
2. Every phase ends with `bash scripts/verify.sh` green and a `spec-check`
   pass; each admitted form adds its semantics-registry rules in the same
   phase (standing rule, not a phase of its own).
3. No meta payload is ever hand-written: meta content generates from the
   registry or it does not ship (stall risk 3 from the review).
4. The five named decisions (below) are made in design docs, never silently
   in code.
5. Commit per task; never push.

## Workstream D: companion design docs (written 2026-07-30)

These unblock later phases; Phase 0 does not depend on them.

- **D1 type system** — `2026-07-30-014-d1-type-system-design.md`. Canonical
  type serialization as the identity function (types are not interned, so
  `TypeIndex` equality is not structural identity), six amendments to the
  existing assignability relation, the join and union normalization, the
  generic-inference algorithm with a decidable ambiguity criterion, and the
  narrowing kill rules the spec omits.
- **D2 effects and purity** — `2026-07-30-015-d2-effects-purity-design.md`.
  Atom set = the 11 existing `ModuleCapability` members verbatim; capabilities
  move from module-scoped to export-scoped; one purity predicate at three
  scopes; three inference holes closed with function-type ceilings instead of
  row variables; `Proof<T, P>`'s domain is the existing `CapsuleProperty`
  enum, which the spec should adopt.
- **D3 canonical form and wire** —
  `2026-07-30-016-d3-canonical-form-wire-design.md`. The lexical grammar with
  six divergences promoted to errors, the formatter that must be built from
  scratch (none exists), digest pre-images, the five-method
  equivalence-validator taxonomy, one repair vocabulary replacing three, and
  the per-operation protocol payload schemas.

Interim markers until D1/D2 land, both introduced in Phase 0:
`// D1-interim` on `type_pool.zig` assignability as the join oracle;
`// D2-interim` on the syntactic purity predicate in `strict_checker.zig`.

Spec-editorial debt to fix alongside D1-D3 (from the review): the `Bytes`
signature block is missing the promised hex and equality functions;
`Proof<T, P>` never defines `P`'s domain; `warning` severity is used by two
gates but assigned to zero rules; a migration policy for removing shipped
surface (`|>` pipe, `interface`) is absent; a phasing section replacing the
all-endpoint framing.

## Workstream L: language phases

Dependency chain (A -> B means A blocks B):

```
P0 advisory channel ──────────► P6 full idiom table
P0 pure ?: + join ────────────► P4 Result-default idiom row
P1 registry seed ─────────────► P1 protocol skeleton ─► P6 gate-complete meta
P2 generics ──────────────────► P4 Dict/JSON typing, Schema<T>
P2 narrowing list ────────────► P3 match type-tests, P4 Result ok-guard
P3 null + recursive aliases ──► P4 JsonValue ─► P4 zttp:json ─► P5 HTTP ABI
P4 Dict ──────────────────────► P4 JSON ─► P5 ABI       P5 Bytes ─► P5 ABI
P6 equivalence validators ◄─── D3
```

### Phase 0 — truth, ternary, and the advisory channel (detailed plan exists)

Admit pure `?:` with the join rule (interim assignability), add the
`advisory` severity and the idiom-ID registry seed, re-badge the existing
`canonicalize.zig` rewrites under idiom IDs, and pay the honesty debt
(recursive functions no longer labeled total; summarized loop skeletons no
longer labeled exhaustive). ~8-12 files, zero kernel changes.
Exit: `scripts/verify.sh` green; ternary admission/rejection tests;
`describe-rule --json` shows `advisory` and idiom IDs; double-normalize
byte-idempotence over `examples/` holds.

### Phase 1 — registry seed + protocol v2 skeleton

Consolidate `rule_registry.zig` as the single generated source for the
section-12 matrix; implement `zts agent --stdin-json` with the v2 envelope,
frozen version negotiation, top-level `error` object, and the uniform
`expected`-hash staleness rule, wrapping existing v1 code for
`meta/features/restrictions/describe_rule/check/canonicalize/normalize`; add
`modules` returning `module_graph_hash` (construction per D3).
Exit: golden envelope tests; determinism test (stdout is response JSON only);
staleness-guard test; v1 surfaces byte-identical.

### Phase 2 — type-system rock

Sound generic inference and instantiation per D1 (constraints and explicit
type arguments first, inference second); the closed narrowing list including
negation, bare discriminant reads, and the value-kind guards `isDict`/
`isBytes`; the canonical type serialization per D3.
Exit: the 14.1 bullet "generic functions instantiate soundly and never fall
back to unknown" holds over a frozen signature corpus covering every virtual
module export; narrowing conformance tests; stable type digests.
Stall risk 1 lives here; the signature corpus is the ratchet.

### Phase 3 — source null, recursive aliases, match upgrades

`null` as explicit data with the `??`/`?.`-rejected-on-null diagnostic and
exact repair; contractive recursive aliases (finite type graph, memoized
unfolding per D1); match binding fields, rename and shorthand bindings,
type-test patterns, identifier/member-path scrutinee rule, effectful arms
with exactly-one-arm evaluation.
Exit: `JsonValue` minus the Dict arm compiles; exhaustiveness over
null/literals/type-tests; worked example 16.1 compiles and runs.

### Phase 4 — Dict, JSON, Result completion

`Dict` + `zttp:collections` (persistent semantics, SameValueZero keys,
insertion order, bulk ops, `comptime(dictFromEntries)` discharge); `zttp:json`
(closed error taxonomy, limits from policy, encodability rule); `zttp:result`
completion (`unwrapOr`, `orElse`, `collectAll`, effect-row-polymorphic
combinators per D2) and the ordered consumption procedure. First kernel
growth beyond `push` is here only if Dict needs an intrinsic representation.
Exit: worked examples 16.2 and 16.3 compile and run; Dict determinism and
SameValueZero tests; JSON round-trip and limit tests; `collectAll`
first-error test.

### Phase 5 — Bytes, ABI re-typing, defaults, Effects ceiling

`Bytes` + `zttp:bytes` (fix the spec's missing hex/equality signatures via
D-workstream first); re-type the HTTP/WebSocket/queue/durable ABIs to the
7.2 shapes including total `responseText`; trailing scalar default
parameters; the decidable `Effects`-ceiling rule with repairs computed from
the inferred row (D2).
Exit: worked example 16.4 compiles; fetch/websocket/queue examples re-typed;
ceiling-rule repair tests.

### Phase 6 — full idiom table, validators, gate-complete protocol

The remaining idiom rows (match-binding rows, Dict rows, Result rows);
equivalence validators per D3's method taxonomy — any row without a
registered validator ships advisory-only, which the spec permits; fixed-point
normalization with the published pass bound; batch `apply_repair` and
multi-property `verify`; the full meta payload set, every part
registry-generated.
Exit: double-normalize byte-identity over the whole corpus; atomic
`apply_repair` rejection tests (overlap, stale digest, cross-digest);
meta drift gates wired into `scripts/verify.sh`.
Stall risk 2 lives here; the double-normalize property test runs from day
one of the phase.

## Explicitly out of scope for this program

- Section 13.3-13.4 certificate bundle, obligation language, independent
  verifier, trust/key model. Prerequisite per the spec's own gap 9: a real
  consumer and a verifier-first design. Keep only 13.1's labeling discipline
  (already partly delivered by Phase 0's honesty fixes).
- Section 14.2 two-client conformance lab and token-ratio measurement.
  Replace with a 10-20 task smoke corpus driven by the in-repo `expert`
  agent; grow later.
- `race`'s per-call-site synthesized union (type `parallel` in Phase 5;
  `race` typing deferred).
- The no-ASI flip stays late (Phase 6, with the unique-parse-insertion
  validator), since the live parser has `return`-ASI today.
- Pipe (`|>`) and `interface` removal: blocked on the migration policy in
  the D workstream. Until then both stay shipped; no phase removes them.

## Risk register

1. Generics retrofit long tail (Phase 2) — mitigation: frozen signature
   corpus, constraints-before-inference ordering.
2. Non-confluent or non-idempotent normalize (Phase 6) — mitigation:
   double-normalize property test from day one; advisory-only fallback for
   unvalidated rows.
3. Hand-written meta payloads multiplying drift gates (Phases 1, 6) —
   mitigation: ground rule 3.
4. Silent decisions leaking into wire formats — mitigation: D1-D3 land
   before Phase 2 (D1), Phase 4 (D2), Phase 1 hash freeze (D3 digest
   section, which may land ahead of the rest of D3).

## Decision log

Every D-doc decision and every `D*-interim` marker gets a dated entry
appended to this file's Decision log section when made or retired.

**2026-07-30 — D1-D3 written.** Decisions with the widest blast radius, and
the spec edits they imply:

1. Type identity is a canonical serialization string, memoized per
   `TypeIndex`, not index equality. Forced by the measurement that the pool
   never interns. Everything downstream (join step 2, union dedup, recursive
   assignability, type digests) consumes it.
2. Capabilities become export-scoped, not module-scoped. The current union of
   a whole module's capabilities for a call to any of its exports makes every
   mandatory ceiling wrong on its face.
3. Function types carry an effect ceiling; absence means the empty row. This
   is how calls through parameters and closures get sound rows without
   introducing row variables, and it matches spec 6.5's pure-callback rule.
4. `Proof<T, P>`'s domain is the existing `CapsuleProperty` enum
   `{ total, pure, read_only, deterministic }`. **Spec edit owed:** rev 4
   lists `P` as undefined; the code has defined it since before this program.
5. The canonical formatter must be written from scratch; no printer exists
   anywhere in the repo. It fails closed per-construct until total. This is
   the largest unplanned cost in the program and it lands in Phase 6.
6. Equivalence validators are five methods (layout identity, parse identity,
   kernel-IR identity, declared law, contract behavioral). Only the first four
   may auto-apply; contract-level equivalence is advisory-only because it is
   blind to pure-computation changes.
7. Six lexical divergences from JS become errors (line continuations, unknown
   escapes, malformed radix prefixes, legacy octal, unterminated strings,
   non-ASCII identifiers).

**Spec edits owed from this workstream**, to be applied in the next
editorial pass: adopt `CapsuleProperty` as `P`'s domain (item 4); add the
missing `Bytes` hex and equality signatures; assign the `warning` severity to
at least one rule or drop it from the gates; state that spec 5.8's TSX
comparison requirement is already satisfied by prefix-position
disambiguation; add the migration policy for `|>` and `interface`.

**2026-07-31 — Phase 0 complete.** `scripts/verify.sh`, `zig build test`,
`bash scripts/test-examples.sh` (43/43), and `zts spec-check --json` all green.
Detail and per-task deviations:
`2026-07-30-013-zts-advanced-rev4-phase0-plan.md`.

Interim markers adopted, both to be retired when their design doc lands:

- **D1-interim** at `type_checker.zig joinTypes`. Spec 5.4's join steps 1-5,
  with step 2's "syntactically identical" as `TypeIndex` equality and steps 3-4
  as `type_pool.isAssignableTo` in both directions. The pool does not intern, so
  index equality is strictly narrower than the canonical type identity D1
  specifies; step 3 covers the gap, since two structurally identical types are
  mutually assignable and resolve to the `whenTrue` branch either way. Retire
  when D1's canonical serialization lands. The join's shape does not change.
- **D2-interim** at `strict_checker.zig isPureExpr`. A syntactic purity class:
  call, method call, and assignment are impure, and so is any composite
  containing one. Retire when D2's inferred effect row replaces it.

Four decisions made in code during Phase 0 that the phase plan did not
anticipate:

1. **The idiom table is published on its own flag, not inside the rule list.**
   `describe-rule --json` is a bare JSON array of rules, duplicated by the pi
   expert tool and published in the expert contract; an `idioms` sibling key
   would have meant turning that array into an object. An idiom also carries no
   code, category, or severity. `describe-rule --idioms [--json]` is additive.
   Spec 5 puts `idioms` in the `meta` payload, which is Phase 1's job.
2. **The idiom back-reference runs registry-to-intent.** Mapping the rewrite
   catalog against the table found exactly one pair: every other rewrite repairs
   a *restriction*, while the idiom table picks among admitted spellings. So
   `rewrite_rule` holds the `RepairIntent` tag name that `normalize --json`
   already prints, rather than adding an `idiom_id` field to two rewrite
   descriptors and two JSON surfaces for one wired row.
3. **`cost_bounded` is no longer conjoined with path exhaustiveness.** Task 6
   would otherwise have stripped it from every loop-bearing handler. The
   conjunct was already redundant - truncation forces the total to unbounded -
   and a summarized loop still carries a symbolic linear bound.
4. **Path coverage reports its cause, not a bool.** `PathGenerator.Coverage` has
   four cases, each carrying its own note. Three separate reworks of one
   parenthetical proved a bool cannot say why coverage is incomplete.

Two findings recorded for later phases, neither fixed here:

- **The path generator does not walk into user functions at all**, so every
  helper's module calls are missing from the cost envelope, recursive or not.
  Measured: one `sqlOne` moved from a handler body into a non-recursive
  one-line helper drops `Max I/O depth` from 1 to 0. Whole-program cost
  analysis, not Phase 0.
- **`advisory` is assigned to zero rules**, so it is not yet observable in any
  CLI output - the same shape as the `warning` debt already listed above. The
  severity exists, is isolated from success and exit codes, and is tested; the
  idiom channel that will carry it is Phase 6.

**Spec edits owed, added by Phase 0:** the `idiom.element-iteration` row's
non-idiomatic column should also list the `items.entries()`-with-unread-index
spelling. Spec 4.2.1 gives only the `range(items.length)` form, but ZTS619 has
rewritten the other since before this program, targeting the same idiomatic
spelling for the same operation.
