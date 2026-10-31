<!-- agent-spine: area -->

# packages/zts

This area owns parsing, analysis, bytecode, proof facts, and the interpreter for the restricted TypeScript profile.

Each tier imports only lower tiers. `zig build test-zts-layering` enforces the tier boundary.

## Invariants

- **Flow analysis enters routed functions and module-level data declarations.**
  An unvisited root can make a leak appear clean. Proved by `zig build test-zts`.

- **A persistent read carries unknown provenance unless a stronger binding rule applies.**
  Current call arguments do not identify data from a separate write. Proved by `zig build test-zts`.

- **A literal `env` name is secret unless the policy lists it in `env.public`.**
  The name's spelling vouches for nothing, a computed name keeps the declared
  label, and a command that reads no policy keeps every name secret. Proved by
  `zig build test-zts`.

- **A declassifier discharges a label only for an integer literal bound within its ceiling on an unmodified source value.**
  A join keeps the `source_exact` mark only when both sides hold it, and every
  operation that builds a new value drops it. Proved by `zig build test-zts`
  and `zig build test-flow-census`.

## Decisions that bind here

D-004, D-006, D-007, D-014, D-015

## Rule detail

These paragraphs hold the history and the definitions behind the flow rules in the root `AGENTS.md`.

Wrong answers. A function that returns a value claiming more than it checked shipped five fail-opens in the flow checker ([empty-label-set-claimed-a-value-was-clean](../../docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md), which also gives the probe method), then in `validateJson`, `coerceJson`, and `decodeJson` ([validate-json-strips-the-label-it-was-asked-to-check](../../docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md)), then in routes dispatched through `routerMatch` ([a-dispatched-route-was-never-walked-so-its-leak-proved-clean](../../docs/solutions/security-issues/a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md)). The weaker assertion on `deterministic` let the class survive in `cacheGet`, `queue.receive`, `sqlOne`, `sqlMany` and `durable.waitSignal`. The class is not bounded by the thirty-four files in `scripts/check-proof-swallow.sh`: it also shipped in `packages/pi`, where no such gate exists ([empty-baseline-made-a-file-destroying-edit-prove-clean](../../docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md)).

Declassifiers. `mask` uses `mask_visible_max`, which is 4. An unmodified source value is a value that `FlowInterp` marks `source_exact`: the result of `env` from `zttp:env`, the `authorization` header cell, or a plain copy of one (a local, a parameter, a return, a stored and reloaded field, a branch that picks between such values and clean ones). A slice, a concatenation, `trim`, `truncate`, `slugify`, or any other operation builds a new value without the mark, because `mask(text, visible)` reveals the trailing `visible` bytes and bounded calls over slices of one secret would reveal all of it. A runtime `visible` puts the magnitude of the declassification in whatever computes it.
