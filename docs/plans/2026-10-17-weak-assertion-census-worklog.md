# Weak test assertion census: worklog

Date: 2026-10-17. Plan: [weak-assertion census plan](2026-10-17-weak-assertion-census-plan.md).
Ledger: [2026-10-17-weak-assertion-census-ledger.tsv](2026-10-17-weak-assertion-census-ledger.tsv),
one row for each of the 576 census lines. Its line numbers refer to commit `60db0cd5`.

## Result

The census classified all 576 assertions. 130 were weak and 3 were tautologies.
Of the weak rows, 127 now have an exact assertion, and a sabotage shows that each
new assertion refuses a broken implementation that the old one accepted. 2 weak
rows are deferred, and 1 stays open. No product defect was found.

| Final verdict | Rows | Outcome |
|---|---|---|
| FLOOR | 284 | kept |
| GUARD | 88 | kept |
| UNSTABLE | 40 | kept |
| PINNED | 31 | kept (24), or strengthened but redundant with a validator (7) |
| WEAK | 130 | fixed and probed (127), deferred (2), open (1) |
| TAUTOLOGY | 3 | replaced and probed (1), replaced without a probe (1), deleted (1) |

The fixes are in eight commits, `61a0bbf6` to `c0a33b88`. They change test code
only. One product-file line changed: a tautology in the tests of
`packages/pi/src/providers/local/client.zig` was deleted.

## Classification

Nine read-only Sonnet agents classified the set. Two pilots came first. The
first pilot used revision 1 of the rubric. A Fable review then changed the
rubric: it now asks for the broken implementation first, a `PINNED` row must
determine the exact value, and an `UNSTABLE` row must show that no stronger
stable assertion exists. With the new rubric, 7 precompile rows moved from
`PINNED` to `WEAK`. On the 13 pilot rows that Opus read, Opus agreed with every
verdict.

Opus read every `WEAK` and `TAUTOLOGY` row. Opus changed 8 of the 11
tautologies: 2 became `FLOOR` (an emptied corpus fails them) and 6 became
`PINNED` (a neighbouring assertion determines the value). Two `FLOOR` rows cite
a weak line; they became sound when that line was fixed.

## Audit of the keep verdicts

A Fable agent re-classified a stratified sample without seeing the verdicts.
The table counts keep rows that the audit found weak.

| Kind | Sampled | Found weak | False-keep rate |
|---|---|---|---|
| FLOOR | 42 of 284 | 2 | 4.8 percent |
| UNSTABLE | 41 of 41 | 1 | 2.4 percent |
| GUARD | 10 of 88 | 0 | 0 |
| PINNED | 5 of 18 | 0 | 0 |

No kind passed the 5 percent threshold, so no kind was re-run. The accepted
residual is about 13 weak rows still labelled `FLOOR`, estimated from the
sample rate. The 3 rows that the audit found were fixed in round E. Opus
rejected 2 audit tautologies (`typed_frontend_tests.zig:661` and `:1811`):
they check that the counting allocator is wired in, and they fail if it is not.

## Fixes and sabotage evidence

Four Sonnet implementers (parts A to D) and one follow-up (part E) did the
fixes. For each fix, the implementer applied the broken implementation that
the row names. The new assertion then failed with a test assertion error, not a
compile error, and the old assertion passed. The probe tables are in the
session scratch directory and are summarised here. 128 rows have a probe. 7
rows have none, because a validator that the test already runs refuses the
break first: `typed_frontend_tests.zig` 1200, 1289, 1292, 1293, 1294 and
`recorder_test.zig` 750, 751. The ledger records these 7 rows as `PINNED`.

Derivations that the run corrected, not defects:

- `precompile.zig:4300`: the default profile also raises ZTS611, so
  `canonical_errors` is the sum of the ZTS610 and ZTS611 counts.
- `arena.zig:500`: the arena rounds a request up to 8 bytes.
- `proof_ir.zig:1031`: both `env` and `Response.text` lower to a capability call.
- `standin_range_tests.zig:345`: the `fix` arm ends with a different fixed sentence.
- `runtime_pool.zig:2003`: the old line already refused the named break. The
  exact count catches over-counting instead.

## Open and deferred rows

- `precompile.zig:4796` stays weak. The classifier derived that the handler
  hole lists `deterministic`, and the run did not. Opus probed the cause. The
  handler reports `deterministic: true` only when the `uuid()` result is
  discarded. When the value reaches the response, directly or through a
  helper, `deterministic` is false. So this is not a fail-open. No independent
  oracle for the handler hole set exists.
- `mlx_e2e_test.zig:163` and `:222` are deferred. They run only against a local
  MLX server, which runs only when the operator asks.
- `parse.zig:10880` and `:10900` pin the location but not the kind. The kind
  `expected_expression` (ZTS004) has no producer, as
  `scripts/corpus-uncovered.allow` already records.

## Process deviations

- The Codex astra fact check did not run, because the account was at its usage
  limit until 2026-10-23. Opus checked the counts and build steps directly.
- The harness created the four implementer worktrees from `origin/main`
  (`1bee7b1b`), not from local main. Each fix was cherry-picked onto main. Every
  named step was then re-run on main: `test-proof-checker`, `test-server`,
  `test-zruntime`, `test-cli`, `test-expert-app`, `test-simulator`,
  `test-standin`, `test-zts`, `test-zts-layering`, and `test-module-boundary`.
  All exited 0. Part E used a worktree created from local main.
- Part A used a filtered `zig test` run only for the old-assertion side of its
  probes. Its log lists the named tests as run. The new-assertion side used the
  unfiltered `test-zts` step.

## Re-grep at the final commit

The census pattern matches 504 lines at the final commit, against 575 at
`60db0cd5`. The fixes removed 74 lines and added 3. The 3 new lines are floors,
and each is followed by an exact equality: `agent_protocol.zig`
(`parameters.items.len > 0`), `edit_simulate.zig` (`introduced > 0`), and
`precompile.zig` (`spec_err_count > 0`). The other remaining lines are kept
rows, or weak lines that a fix kept as a floor beside its new exact assertion.
The ledger is a record, not a gate. A weak assertion added later carries no
verdict.
