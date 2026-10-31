# Legacy removal worklog, 2026-10-30

This worklog records the execution of the [legacy removal plan](2026-10-30-legacy-removal-plan.md).
The plan is the authority. This file holds evidence, rulings, and deviations.

## Owner decisions

The owner answered "all a" on 2026-10-30. That answer covers Decisions 1 to 13 in the plan, and Decision 14 from the same message.

| Decision | Selection | Effect on this run |
|---|---|---|
| 1. Generic arrow after a comment | (a) | L4a runs |
| 2. Erased type prefix | (a) | L4b runs |
| 3. Predicate second parse | (a) | L4c runs, with an explicit refusal of an empty narrowing |
| 4. Raw parser, `inline_code`, Zig aliases | (a) | L5 runs. `.inline_code` stays and passes admission |
| 5. Duplicate journal `body` | (a) | L7a runs |
| 6. Ledger rows and `--no-sign` | (a) | L8a keeps both kinds as opaque rows, and removes the payload types and the flag |
| 7. Undocumented runtime paths | (a) | L3e runs |
| 8. Retired provider keys | (a) | L8b keeps `zttp auth revoke claude` and `zttp auth revoke openai`, and removes the rest |
| 9. `canonicalize --json` kind names | (a) | L7b runs, with a release note |
| 10. Scalar response fields | (a) | L7c runs |
| 11. Installer fallback | (a) | L7d runs |
| 12. Tag removal and the moved `semanticsHash` | (a) | L6 runs |
| 13. Order against the reset | (a) | L0 to L9 run before reset Phases 10 and 11 |
| 14. `zttp compile` hash gap | (a) | I measure the tamper effect as separate work after this plan |

The run commits on local `main`, as the owner's standing instructions require. No push or pull request is part of this run.

## Baseline

Base commit: `71173d15`. It differs from `0635cd09`, which the review read, only by the plan document.
`bin-base` in the scratch directory holds the three binaries built at `0635cd09`.

## L0

Status: complete. All checks ran in the scratch directory, and only this worklog, the plan status line, and the plan index changed.

| Check | Result |
|---|---|
| Inputs | 648: the 645 inputs of the review plus the three `block` probes |
| Comparison script, two runs of the base binaries | 0 rows differ at 648 rows |
| Comparison script, base against a build at the base commit | 0 rows moved |
| Stored-data set | Built with the base binaries. Two runs of `stored.sh` match. `zttp proofs verify` exits 0, `GET /` returns 200 with `message` "Hello, World", and `zttp proofs list`, `show`, `diff`, and `export` exit 0 |
| `surface.sh` | Exit 0: identical to the table saved after reset unit 9a |
| `eprobe.sh` | 11 rows saved as `legacy-base` |
| `zig build test`, cold | Exit 0. 8478 of 8484 tests pass, with 6 skipped, on 214 of 214 steps |

The ledger in the stored-data set holds, in order: one `deploy` row, the `perf` and `equivalence` fixtures from `proof_ledger.zig`, and one `deploy` row.
