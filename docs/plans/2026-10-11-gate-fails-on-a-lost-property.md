# The PR gate fails on a lost proven property

Status: complete, 2026-10-11 (commits b3c5cac0, d9e97bec, 56f77fcf). Revision 2 (Fable review folded in; owner decision 3 on 2026-10-11: critical losses only). Decision by the owner on 2026-10-11 (decision 1,
option a, after the code review fixes in
`docs/plans/2026-10-10-code-review-fixes.md`).

## Problem

`zttp proofs gate` (`packages/runtime/src/proofs/pr_gate.zig`) sets each
handler's verdict from `diff.behavioralVerdict()` alone (`analyzeHandler`,
about line 975). `contract_diff.diffContracts` records every change of a
monotonic proven property in `diff.effect_changes`
(`packages/zts/src/contract_diff.zig:640-685`), but the gate never reads it. A
pull request that turns `fault_covered`, `no_secret_leakage`, or any other
proven property from true to false therefore passes the gate as `equivalent`.

## Decision

A lost proven property makes the handler `breaking`, so the gate fails. A
gained property does not change the verdict.

## Design

1. A lost property is a `PropertiesChange` in `diff.effect_changes` with
   `old_value == true`, `new_value == false`, and a field for which
   `handler_contract.HandlerProperties.isMonotonicProvenSpecName(field)` is
   true. This is every boolean property except `has_egress`. The two
   non-boolean rows that `diffContracts` also appends, `max_io_depth` and
   `cost_class`, are not counted here: their `old_value`/`new_value` are
   presence bits, not proofs, and `cost_bounded` already carries the cost
   proof as a boolean.
2. `HandlerResult` gains `lost_properties: []const []const u8 = &.{}`, the
   field names, arena-owned, in `effect_changes` order.
3. In `analyzeHandler`, the verdict is `.breaking` when `lost_properties` is
   not empty, else `diff.behavioralVerdict()` as now. The early returns for a
   handler that stopped being a handler, or became one, do not change.
4. `renderMarkdown`: for a handler with lost properties, print a
   **Lost proofs** block under its section, one line per property:
   `` - `fault_covered`: proven → not proven ``. It prints whether or not
   counterexamples exist. The summary table does not change.
5. `renderJson`: each handler object gains `"lostProperties": [ ... ]`
   (always present, possibly empty). `json_schema` stays
   `zttp.proof-gate.v1`: the change only adds a key.
6. The signed `kind=equivalence` receipt does not change. It is written from
   the contracts, and its own classification is outside this change.
7. `docs/cli.md` (the `zttp proofs gate` section near line 183) says that a
   lost proven property fails the gate, and names the JSON key.

## Tests (in `pr_gate.zig`, through public functions)

- Unit: a `HandlerResult` with `lost_properties` renders the Lost proofs block
  in Markdown and the `lostProperties` array in JSON.
- End to end through `checkSides` plus the same projection `analyzeHandler`
  uses (or through `analyzeHandler` itself): the helper fixture from the U6
  tests, where `lib.ts` gains an unchecked `fetch` and `handler.ts` changes,
  now gives verdict `.breaking` with `lost_properties` containing
  `fault_covered`. Confirm this test fails before the change.
- A handler that gains a property (false to true) and keeps its behavior is
  not `breaking`.
- A handler whose only effect change is `max_io_depth` or `cost_class` is not
  `breaking` on that account.

## Verification

Unfiltered `zig build test-cli` (which runs the gate tests), `zig build test`,
`zig fmt --check` on changed files, with a private Zig cache and
`env -u DEEPSEEK_API_KEY`. Then, by the lead, `scripts/verify.sh` and an
offline republish of convergence and coverage, because any commit makes the
published evidence stale.

## Revision 2: Fable review and owner decision 3

These override the sections above where they disagree.

R1 (policy, owner decision 3). Only a **critical** loss makes the handler
`breaking`. The critical set is the table in `upgrade_verifier.propertySeverity`
(`packages/tools/src/upgrade_verifier.zig:92`): `retry_safe`,
`injection_safe`, `state_isolated`, `no_secret_leakage`,
`no_credential_leakage`, `fault_covered`, `result_safe`, `optional_safe`.
Every other lost monotonic boolean (for example `pure`, `read_only`,
`stateless`, `post_only`) is listed under Lost proofs and does not change the
verdict. The reason: a first log call removes five properties, and a first
cache read removes `stateless`; failing the gate on those would turn ordinary
additive edits into failures.

The table must have one owner. Move the severity function to
`packages/zts/src/contract_diff.zig` as
`pub fn propertyLossSeverity(field: []const u8) Severity` (or an equivalent
name and enum that fits that file), and make `upgrade_verifier.propertySeverity`
call it for losses, so the gate and the upgrade verifier cannot drift. Keep
`upgrade_verifier`'s behavior and tests unchanged.

R2 (Problem wording and fixture, Fable 1). A capsule-less handler demands the
full v1 profile, gets a ZTS500 error on both sides, and the gate returns
`UnanalysableSource` (exit 2) before any verdict. A handler that declares the
lost property also exits 2 on the after side. The gap this plan closes is a
handler with a `Proof<...>` capsule that does not name the lost property: it
passes as `equivalent` today. Tests use `Proof<Response, "canonical">` on the
U6 helper fixture (`canonical` holds on both sides). Change the existing U6
fixture in `pr_gate.zig` only if the new tests need it, and keep the U6 tests
passing.

R3 (receipt, Fable 3). Compute the lost properties before the sign block in
`analyzeHandler`. When a critical loss makes the verdict `breaking`, do not
write the signed `kind=equivalence` receipt (it would record `equivalent`
from `behavioralVerdict()`), leave `sign_failure` unset, and let the report
say that no receipt was written because a proof was lost. `prove-behavior`
and `behavioralVerdict()` do not change in this plan.

R4 (docs, Fable 4). Update: `docs/cli.md` (gate section near line 183),
`docs/proofs-and-receipts.md` (the verdict table near lines 509-515 and the
JSON contents near 535-536), the module doc comment at the top of
`pr_gate.zig` (lines 12-14), the comment at the top of
`.github/workflows/proof-gate.yml` (lines 3-7), and an entry under
`[Unreleased]` in `CHANGELOG.md`.

R5 (table, Fable 5). The Δ behavior cell of the summary table shows
`N proof(s) lost` when the handler lost any property, so a row whose only cause
is a lost proof is not "— | —".

R6 (tests, Fable 6).
- Name the projection: `fn lostProperties(arena, diff: *const contract_diff.ContractDiff)`
  returning each lost field with its severity, or two lists. Test it on a
  synthetic `ContractDiff` with hand-built `PropertiesChange` rows: a critical
  loss, a non-critical loss, a gain, a `max_io_depth` row, and a `cost_class`
  row. Say in the test that the `cost_class` row asserts the projection only.
- One `run`-level test through a temporary git repo (helpers near
  `pr_gate.zig:1241-1254`) with the `canonical` capsule fixture: `lib.ts`
  gains an unchecked `fetch` and `handler.ts` changes. Assert exit 1, verdict
  `breaking`, `fault_covered` in the Lost proofs block, and that no
  equivalence receipt was written. Confirm the test fails before the change.
- A non-critical-only loss (for example adding a `logInfo` call) gives a
  non-breaking verdict and lists the lost properties.

## Result

The gate gives `breaking` for a handler that loses a critical proof, withholds
its signed receipt, and lists every lost proof in Markdown and in the JSON key
`lostProperties`. Two premises of this plan proved wrong. First, an edit that
loses a critical proof inside the handler already changed its I/O paths and was
already `breaking`, so the new rule matters mainly for a loss through an
imported helper. Second, a changed helper at a normal path is analyzed alone
and usually ends the run with exit 2, so the test helper sits under
`fixtures/`. Owner decision 4 (2026-10-11, option a): the gate gives no verdict
for a handler without a `Proof<...>` return type, and `docs/roadmap.md` records
that limit with no other change.
