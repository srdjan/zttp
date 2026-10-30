# Reset worklog, 2026-10-30

This worklog records the execution of the [reset plan](2026-10-30-reset-implementation-plan.md).
The plan is the authority. This file holds evidence, rulings, and deviations.

## Owner decisions

The owner selected the recommended option for each decision on 2026-10-30.

| Decision | Selection | Effect on this run |
|---|---|---|
| 1. Scope | (a) | Phases 0 to 8, 10, and 11 run. Phase 9 units run as Decisions 2, 4, and 5 select |
| 2. Cost fuse | (a) | The code stays. Unit 1b corrects the document. Unit 9g does not run |
| 3. Second checker | (a) | Unit 6b runs |
| 4. One language path | (a) | Unit 9b runs |
| 5. Other class B units | (a) | Each unit that keeps the offline replay green runs. Any other unit waits for a re-record window |
| 6. Archive tags | (a) | The owner pushes the four tags. This run does not push |

The run commits on local `main`, as the owner's standing instructions require. No push or pull request is part of this run.

## Baseline

Base commit: `617243e376beefc439fca4b229a86fe8d2a0b2ba`. Base tree: `aef49967c2b42c03e23451198c2a13e9502acccd`.

## Phase 0

Status: complete at base `617243e3`. The base differs from `1d009062` only by the plan document, so Appendix A and Appendix B stand unchanged. A repeat of the Appendix B command gave 214 sites.

| Step | Result |
|---|---|
| Clean tree | `git status --porcelain` printed nothing on local `main` |
| `bash scripts/verify.sh` | Exit 0 in 1,097 seconds, load average 2.90 at the start |
| `zig build test` | Exit 0 from the warm verify cache; 211 of 211 steps |
| `digest.sh` | Two runs exit 0 and compared equal. `zts check` gave 73 at exit 0 and 142 at exit 1. `zts compile` gave 98 at exit 0 and 117 at exit 1 |
| Surface digests | 38 rows, all exit 0, two runs equal |
| Admission probe table | 80 rows, two runs equal |
| Serve flag cases | 4 rows in the probe table, two runs equal |
| `proof-swallow.allow` | 0 rows for `flow_interp.zig` |

The scratch directory `/private/tmp/claude-501/zttp-reset-20261030` holds `digest.sh`, `surface.sh`, `probe.sh`, and their Phase 0 tables.
The test count of the aggregate is 8492 of 8498 with 6 skipped, from the cold run at `1d009062`. A warm run reports only the steps that ran, so a count comparison needs a cold run.

Probe deviations. The plan asked for one source per form of `AdmissionFailure`. The table holds 19 sources: the 17 `AdmissionKind` forms, a leading comment, and a trailing comment. The forms drop the `import type` prefix of the module graph test, because that prefix makes every raw message the same. Without the prefix `legacy_types_import` starts and answers HTTP 200, so that probe is not a refusal case. The trailing comment form uses an untyped helper, because the raw parser cannot read a typed one. Stderr hashes drop stack trace lines, which carry addresses.

Observed defect rows, with `zts check` at exit 1 for each:

| Source | `serve` result |
|---|---|
| Imported file with a trailing `/* open` | Starts, HTTP 200, body `ok` |
| Imported file with a leading `/* open` | Starts, HTTP 500 |
| Entry file with a trailing `/* open` | Refused |

`nesting_too_deep` now has a source that triggers it: the source from the module graph test.

Appendix B classification: 163 sites are in `test` blocks and 51 are in other functions. Phase 3 classifies the 51 by reading. The production feeders are `run` in `zts_expert_effects.zig`, the load path in `handler_instance.zig`, `renderParseRefusal`, `collectImports`, `runCheckOnParsedSource`, `runGenTests`, `compileHandler`, `compile` and `compileWithOptions`, `extractVirtualContract`, and the parse in `module_graph.zig`.

The advisory `bench-check` did not run. It cannot fail this phase.
