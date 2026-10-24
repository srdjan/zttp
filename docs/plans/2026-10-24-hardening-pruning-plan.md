# Hardening and pruning implementation plan, round 4

The owner authorized execution with `go ahead` after the [ranked list](2026-10-24-hardening-pruning-list.md).
The source baseline is `4ed80e8b`. The initial tree is clean on local `main`.
The [worklog](2026-10-24-hardening-pruning-worklog.md) records progress, evidence, and any unresolved decision.

## Goal and constraints

The changes reduce complexity while preserving supported handler behavior, request isolation, and independent certificate acceptance.
Each behavioral repair starts with a regression or a characterization of the current behavior.
Workers own disjoint files and make no commits. The main agent reviews each diff, runs authoritative checks, and commits isolated units.
No worker runs shared build or install steps. The main agent owns verification and generated artifacts.
No branch, worktree, push, new dependency, Python tooling, or Git history rewrite is authorized.
Native execution uses Sol workers with high reasoning effort. Standing project decisions remain binding.

## Implementation units

| Unit | Findings | Owned changes | Completion evidence |
|---|---|---|---|
| U1: reliable check output | 4, 5 | `scripts/audit-docs.sh`, existing gate probes, metric and evidence stdout, `build/tooling.zig` | Empty input and failed scanners reject; redirected prefixes survive; named gate tests pass |
| U2: atomic object layouts | 1 | `packages/zts/src/object.zig` | Allocation failures preserve usable pool state; retry tests pass |
| U3: strict replay decoding | 3 | `packages/zts/src/trace.zig` | Partial or failed decoding causes explicit divergence; allocation-failure cases pass |
| U4: bounded layout retention | 2 | Runtime pool release policy and tests, pooling documentation | Stable-name permutations grow classes; measured class threshold recycles the slot |
| U5: complete type parsing | 6 | `type_pool.zig`, signature validation tests | Trailing text rejects; valid binding signatures keep their meanings |
| U6: one predicate authority | 7 | `type_env.zig`, frontend predicate tests | Valid whitespace preserves narrowing; malformed predicates remain refused |
| U7: representable string lengths | 9 | String constructors and concatenation boundaries | Boundary tests reject unsupported lengths without huge allocations |
| U8: remove printer scaffolding | 10 | `packages/proof-review/src/printer.zig` | Whole-tree census finds no removed production caller; `FdWriter` behavior remains |
| U9: shared provider validation | 11 | Both provider clients and one existing-directory helper | Identical validation and offline replay outputs remain unchanged |
| U10: one aggregate route per test family | 12 | Test root registration, aggregate wiring, test documentation and task classification | Collected inventories show retained coverage; named suites remain callable |
| U11: typed document and native gate ownership | 13, 14 | Build graph, scripts, verification routes, task declarations | Typed renderer replaces redundant checks; emitted tools replace nested compilation; rejection probes remain |
| U12: proof defaults | 8 | Contract defaults, dependent fixtures, real-provider recording when authorized | False means unproven; goldens and genuine offline cassettes agree |
| U13: dead representations | 15 | Current producer census, one removable family, all consumers and identity pins | Census proves non-production; compatibility effect is explicit; complete affected suites pass |
| U14: reconcile records | 16 | Plan index and execution worklog | Status follows actual commits and checks; links and spine pass |

The first parallel wave contains U1, U2, and U3. Their files and public contracts do not overlap.
U4 follows U2. U10 and U11 follow U1 because their build edits share files.
U12 requires a concrete recording decision before a paid provider request or empirical artifact replacement.
U13 starts with a producer census and preserves every representation that remains live.
If a candidate cannot preserve functionality, the worklog records the evidence instead of deleting it.

## Verification

The main agent runs each unit's named gates from the ranked list after reviewing its changes.
The final integrated tree must pass unfiltered `zig build test`, `zig build test-zruntime`, and `zig build check-spine`.
The main agent runs `bash scripts/verify.sh` before claiming the full local gate.
Runtime retention and native compilation changes require small measurements before scaling the same workload.
Every complete isolated change receives a local commit with an explicit file list.

## Definition of done

Each selected finding has a committed repair, a verified deletion, or an explicit evidence-based disposition in the worklog.
The repository has no unexplained changed files. Required integrated gates pass, or a genuine external blocker is named precisely.
