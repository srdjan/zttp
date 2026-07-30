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

## Workstream D: companion design docs (week one, parallel to Phase 0)

These unblock later phases; Phase 0 does not depend on them.

- **D1 type-system spec** — the assignability relation (record width/depth,
  function variance, readonly, optionals, distinct types, recursive-graph
  unfolding), the generic-inference algorithm and its ambiguity criterion,
  narrowing dataflow kill/persist rules (assignment invalidation, aliasing,
  loop back edges), join/union normalization across aliases, the canonical
  type serialization format. Interim rule until D1 lands: the existing
  `type_pool.zig:1058 isAssignableTo` structural relation is the assignability
  oracle, and every use is marked `// D1-interim`.
- **D2 effects-and-purity spec** — the closed effect-row atom set and its
  mapping to `ModuleCapability`, row syntax in `Effects<T, R>`, the inference
  rules and row join, the purity predicate (the spec uses "pure" normatively
  ~15 times without defining it), flow labels for the `assert`-on-user-input
  rule. Interim rule: purity = empty inferred effect row per
  `effect_inference.zig`, marked `// D2-interim`.
- **D3 canonical-form and wire spec** — lexical grammar (numeric literals,
  escapes, Unicode identifiers, templates, TSX), the byte-level formatter
  layout, digest algorithm and pre-image encodings (source digest,
  `module_graph_hash`, policy hash, type serialization), per-operation
  protocol payload schemas, the frozen version-negotiation response, the
  protocol error-code registry, the equivalence-validator method taxonomy
  with a concrete method per idiom-table rewrite class.

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

(no entries yet)
