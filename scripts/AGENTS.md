<!-- agent-spine: area -->

# scripts

This area owns repository shell gates, allowlists, regeneration commands, and the canonical verification script.

No import boundary applies. `zig build test-script-reachability` checks that each script has an execution route or manual declaration.

## Invariants

- **Every tracked script is invoked by repository automation or declared manual.**
  An orphaned gate can keep its name while checking nothing. Proved by `zig build test-script-reachability`.

## Decisions that bind here

D-001

## Rule detail

These paragraphs hold the reasons behind the gate rules in the root `AGENTS.md`.

Proof swallow. The gated files are the analysis files that decide whether a program is proven: the thirty-four listed in `scripts/check-proof-swallow.sh`, which cover the producer, six more analysis files that decide `equivalent`, ZTS205, boolean gating, and `canonical` (`contract_diff.zig`, `match_analysis.zig`, `bool_checker.zig`, `behavior_canonical.zig`, `ir_identity.zig`, `strict_checker.zig`), three files of the consumer-side acceptance kernel - `checker.zig`, `capability_policy.zig`, and `wire.zig` - `proof_activation.zig`, and the CHECK files `precompile_check_run.zig`, `precompile_contract.zig`, and `precompile_imports.zig`. A swallow there does not surface as a failure, it surfaces as a pass. A walk over node tags that ends in `else => {}` reports a verdict for children it never read.

Gate floors. A gate whose corpus is empty, whose filter matches no test, or whose build product nothing depends on reports success while checking nothing, and is then cited as evidence. `scripts/check-runtime-purity.sh` and `scripts/check-docs-drift.sh` already do this; see [a-gate-that-counts-nothing-still-reports-a-pass](../docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) for the four shapes and the delete-its-input check.

Weak assertions. A gate holding a full input can still assert something weaker than its own name, so that runs in which the named behavior never happened satisfy it too. A probe is code: one that does not compile runs no check. A failed build and a passing gate both emit no failure message ([difference-is-not-the-claim-and-a-probe-must-compile](../docs/solutions/conventions/difference-is-not-the-claim-and-a-probe-must-compile.md)).

Porous gates. A gate that satisfies both rules can still be porous: its probes show that the cases their author named are caught and say nothing about the cases nobody named. Find those by applying one edit to a copy of the gate's declared inputs and running the built gate binary against the copy. A gate whose subject is an open vocabulary must say which threat it bounds instead of leaving a reader to assume it bounds every one ([a-gate-can-be-non-vacuous-and-still-porous](../docs/solutions/conventions/a-gate-can-be-non-vacuous-and-still-porous.md)).

Filtered runs. The aggregate `zig build test` refuses `-Dtest-filter`. A named suite whose filter selects no test fails, and a fixed filter such as the stand-in suite's gets the same check (`build/Context.zig` `addTest`, `tooling/nonempty_test_runner.zig`).
