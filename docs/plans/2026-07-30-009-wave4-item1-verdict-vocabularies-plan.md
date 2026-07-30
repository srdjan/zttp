# Wave 4 item 1: collapse the verdict vocabularies

Item 1 of `docs/plans/2026-07-28-001-reset-simplification-plan.md` reads: "Collapse the four
verdict vocabularies onto one type, and delete the hand-mirrored enum at
`proof-review/review.zig:27-30`."

## Census

Section 5.1 named four. Measured, the change-verdict family has five members, plus a
hand-mirrored `ProofLevel` in the same file the item calls out:

| Type | Variants | Rendering | Status |
|---|---|---|---|
| `contract_diff.Classification` | equivalent, equivalent_modulo_laws, additive, breaking | lowercase | keep: the algorithm's own output |
| `upgrade_verifier.UpgradeVerdict` | safe, safe_with_additions, needs_review, breaking | UPPERCASE | keep: the one decision type |
| `system_rollout.RolloutVerdict` | same four | same UPPERCASE | delete: exact duplicate, same `exitCode`, same `toString` |
| `review.Verdict` | safe, safe_with_additions, breaking | lowercase | delete: its own doc comment says it mirrors `UpgradeVerdict` |
| `review.ProofLevel` | complete, partial, none | lowercase | delete: its own doc comment says it mirrors `contract_diff.ProofLevel` |

`review.zig`'s stated reason for both mirrors is that the file "stays independent of zts
contract types". That premise is false: `packages/proof-review/build.zig` already imports both
the `zts` and `zts_cli` modules, and `review.zig` already imports `zts_cli` for
`deploy_manifest.ProvenFacts`. There is no dependency edge to add.

## Why the result is two types, not one

`Classification` and `UpgradeVerdict` are not the same vocabulary in different words.
`synthesizeVerdict` (`upgrade_verifier.zig:242`) is the derivation: it takes a
`Classification` and folds in property regressions and coverage gaps, which is where
`needs_review` comes from. `diffContracts` can never produce `needs_review`, and the deploy
decision deliberately flattens `equivalent` and `equivalent_modulo_laws` into `safe`. Forcing
one enum would make every diff switch handle a variant the algorithm cannot emit, and every
decision switch handle a proof-strength distinction it does not act on. So: one decision type
(`UpgradeVerdict`), one classification type (`Classification`), and one documented derivation
between them.

## Not touched, and why

- `system_rollout.StageStatus` (private; safe/needs_review/breaking): the state of a rollout
  stage, not a verdict on a change. Merging it would make `safe_with_additions` representable
  in a position that cannot mean it.
- `cli_release_check.ReleaseVerdict` (ready/ready_with_known_issues/blocked): repository
  release readiness, a different domain.
- `system_linker.ProofLevel`: per-handler proof completeness inside system linking, distinct
  from the contract-level `contract_diff.ProofLevel`.
- `semantics_smt.Verdict`: an SMT solver answer.

## Plan

1. Add `fromString` to `contract_diff.ProofLevel` (the inverse of the existing `toString`,
   which `review.zig` needs to read persisted facts) and `slug` to
   `upgrade_verifier.UpgradeVerdict` returning the lowercase form. `toString` stays
   UPPERCASE for the surfaces that already print it that way; `slug` serves the lowercase
   JSON, markdown, HTML class, and card surfaces. Nothing renders differently.
   -> verify: unit tests for both, `zig build test-zts test-cli`.
2. Delete `review.Verdict` and `review.ProofLevel`; use `UpgradeVerdict` and
   `contract_diff.ProofLevel`. `review.classify` keeps returning only the three variants it
   can derive; document that it never returns `needs_review`.
   -> verify: `zig build test-proof-review`.
3. Update the consumers that print the lowercase form to call `slug`: `review.zig`,
   `proofs_cli.zig` (markdown, HTML, SVG), `studio.zig`, `proof_card_tui.zig`. Add the
   `needs_review` arm to the one exhaustive switch (`proofs_cli.renderSvg`).
   -> verify: CLI goldens unchanged, `zig build test-cli -Dstudio`.
4. Delete `system_rollout.RolloutVerdict`, use `UpgradeVerdict`.
   -> verify: `zig build test-rollout`.

Gate: `bash scripts/verify.sh`, plus byte-identical CLI and contract goldens. Every verdict
string this change touches is user-visible, so a moved byte is a regression, not an update.

## Outcome, recorded 2026-07-30

Done. Three enums deleted (`review.Verdict`, `review.ProofLevel`,
`system_rollout.RolloutVerdict`), two helpers added (`ProofLevel.fromString`,
`UpgradeVerdict.slug`). The verdict-family type count went from five to two.

The lowercase/UPPERCASE split is where the work was. `review.Verdict.toString` rendered
lowercase and `UpgradeVerdict.toString` renders UPPERCASE, so every consumer of the deleted
enum had to move to `slug()`: the deploy card, `proofs list`/`printRows`, `proofs export`
markdown, HTML (including the CSS class name), SVG, the Studio JSON and its recent-entry
timeline, and the TUI card. The `printRows` site was the one the tests caught rather than the
grep - `review.classify(&delta).toString()` reads like the others but sits inside a table row
- so the gate that mattered was `test-cli`, not inspection.

No golden moved. `test-contract-golden`, `test-cli` (767), `test-cli -Dstudio` (786),
`test-zruntime`, and `zig build test -j1` all pass.
