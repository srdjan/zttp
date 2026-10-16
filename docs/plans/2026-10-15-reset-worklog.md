# Reset implementation worklog

## Objective and authority

The [reset plan](2026-10-14-reset-implementation-plan.md) owns findings, design, phase order, and acceptance.
This worklog records execution state and receipts.
The user approved implementation with "reviewd, go ahead, use subagents when possible, verify with astra" on 2026-10-15.
That approval supersedes the plan's earlier planning-only paragraph.
The task continues through U20.

## Constraints

Work stays on local main, with a local commit after each completed phase.
No push, branch, worktree, project provider call, corpus replacement, or public format change is authorized.
Public behavior remains compatible except for U2's sibling-effect correction and U6's approved binding of graph identity to override bytes.
CHECK retains its separate imported traversals and reader observations.
Main owns review, verification, documentation, integration, and Git writes.
Each phase uses a refreshed Sol high implementation packet; Astra xhigh supplies independent review.
Workers run no builds or tests and make no Git writes.
The pinned toolchain is Zig 0.16.0.
No Python, filtered acceptance tests, or concurrent pool-heavy roots are permitted.

The starting commit was `f917dc0b7320ecd0165e49a274311f77b3290796`.
Its tracked tree was `d3b97c46e4ee5fbd0da9174d4343887fbbbc7e16`.
The Claude draft `2026-10-14-sibling-module-effects-plan.md` remains untracked, untouched, and excluded.
No browser session was opened.

## Current work

U1 through U12 are committed locally; U12 is `0b7dc23b`.
U13 source and all required checks are complete.
Astra accepts U13 for its exact-path local commit.
The task continues through U20 and the required quality checks.

The final focused gate passes all 57 steps, with 4,018 native tests and one skip.
CLI separately reports 600 passes and one skip; all 182 diagnostic corpus cases pass.
The full local script, documentation checks, formatting, and whitespace checks pass.
The allocation sweeps pass without leaks after bounded capsule ownership corrections.
All current proof tests remain intact after simplification.

Main owns the local U13 commit, then the U14 reader characterization.
The U14 test candidate remains outside the repository and has Astra source acceptance.
Its unfiltered execution must precede the production CHECK cutover.

Astra accepts the corrected U14 implementation design.
The authority contains its binding rules and six review slices.
The temporary packet SHA-256 is `49d7643bd0596092f3fcb07ff56c055d888c868f10e5bc86ab74d8f807e8d019`.
U15 preparation is frozen outside the repository and remains unreviewed.

## Earlier U13 small-gate receipts

| U13 receipt | Actual result and scope |
|---|---|
| `u13-printer-small.log` | Exit 1; the engine root fails compilation on an error-set conversion. Other roots remain separately reported. |
| `u13-printer-error-set.log` | Exit 0; thirteen steps, 2,703 pass, one skip. All four direct printer tests pass. |
| `u13-consumer-api-small.log` | Exit 1; twenty-five of twenty-seven steps succeed. Native tests report 2,746 pass, one skip; CLI reports 600 pass, one skip. Only proof-swallow fails. |
| Further U13 receipt | Actual result and scope |
|---|---|
| `u13-proof-swallow-reason.log` | Exit 0; both steps pass with zero unreviewed cases. No allowance changes. |
| `u13-consumer-tests-v1.log` | Exit 1; a cross-tier relative import blocks compiler test artifacts. |
| `u13-consumer-tests-v1-tier.log` | Exit 1; sixteen of eighteen steps succeed, 2,946 pass, one skip, one failure. The generic-first callback differs in exact pool order. |
| `u13-callback-pool-probe/result.log` | Exit 0; both pools contain 95 nodes. Nodes 84, 85, and 86 have different name offsets. |
| Further U13 receipt | Actual result and scope |
|---|---|
| `u13-graph-contract-matrix.log` | Exit 1; sixteen of eighteen steps succeed, 2,948 pass, one skip, one known callback failure. The graph tests and fourteen contract comparisons pass. |
| `u13-callback-pool-probe/census-all.log` | Measurement exit 0 for eight cases after a one-case pilot. Seven cases show an ordering or speculative-write difference; absent return matches. |
| `u13-hole-owner-baseline/all.jsonl` | Measurement script exit 0 for two CLI cases after its pilot. Each CLI exits 1 with only ZTS500 and retains the measured hole fields. |

| U12 receipt | Actual result and scope |
|---|---|
| `u12-pilot-small.log` | Exit 1; nine of 21 steps, 1,148 pass, one skip. Import shadowing, duplicate error handling, and tracking block consumer compilation. |
| `u12-pilot-corrected.log` | Exit 1; sixteen of 21 steps, 1,401 pass, one skip. An error-handler arm and its explanation block acceptance. |
| `u12-pilot-error-handler.log` | Exit 0; all 21 steps, 2,903 pass, one skip. The seven consumer tests and unchanged repository gates pass. |
| `u12-declarations-small.log` | Exit 0; all 21 steps, 2,907 pass, one skip. Four declaration tests and the unchanged repository gates pass. |
| `u12-generic-set-small.log` | Exit 0; all 21 steps, 2,911 pass, one skip. Four captured-set tests and the unchanged repository gates pass. |
| `u12-generic-declarations-small.log` | Exit 1; eighteen of 21 steps, 1,401 pass, one skip. Captured error-defer typing prevents the compiler root from compiling. |
| `u12-generic-declarations-corrected-growth-small.log` | Exit 1; nineteen of 21 steps, 2,916 pass, one skip, one failure. All 237 precompile tests pass; one direct-only alias fact has a stale expected tag. |
| `u12-generic-declarations-facts-small.log` | Exit 0; all 21 steps, 2,917 pass, one skip. Five generic-declaration tests and the seventeen-case public CHECK growth test pass. |
| `u12-phase-two-small.log` | Exit 1; thirteen of 21 steps, 1,148 pass, one skip. One unused declaration blocks compiler and precompile test artifacts. |
| `u12-phase-two-globals-corrected-small.log` | Exit 1; seventeen of 21 steps, 2,919 pass, one skip, three failures. Bounded prefix parsing blocks two compiler tests; one public contract-presence expectation is wrong. |
| `u12-phase-two-prefix-admission-small.log` | Exit 0; all 21 steps, 2,923 pass, one skip. Callable generics, complete bounded prefixes, repeated globals, and unchanged repository gates pass. |
| `u12-phase-three-small.log` | Exit 1; nineteen of 21 steps, 2,925 pass, one skip, one failure. Positive calls and the allocation sweep pass; a refusal assertion ignores the built-in generic aliases. |
| `u12-phase-three-alias-baseline-small.log` | Exit 0; all 21 steps, 2,926 pass, one skip. All four call cases, three validation mutations, and the seeded allocation sweep pass. |
| `u12-predicates-native-matrix-small.log` | Exit 1; thirteen of 21 steps, 1,148 pass, one skip. An unqualified helper call blocks compiler and precompile test artifacts. |
| `u12-predicates-native-matrix-qualified.log` | Exit 1; seventeen of 21 steps, 2,934 pass, one skip, five failures. Four compiler assertions and one public stage assertion fail. |
| `u12-predicates-native-matrix-fixtures.log` | Exit 0; all 21 steps, 2,939 pass, one skip. All 1,534 compiler and 240 precompile tests pass after the five test corrections. |
| `u12-focused.log` | Exit 0; all 45 steps, 3,757 pass, one skip. The complete frontend command passes before the accepted mechanical simplifications. |
| `u12-focused-final.log` | Exit 0; all 45 steps, 3,757 pass, one skip. The complete frontend command passes after all final source edits. |
| `u12-verify.log` | Exit 0; the full local script passes aggregate tests, standalone runtime, release and handler compilation, workflows, offline gates, and formatting. |
| `u12-docs-final.log` | Exit 0; all eight documentation drift, link, and spine steps pass. |
| Final Astra acceptance | U12 is complete for local commit, with no remaining source or requirement blocker. |

| U11 receipt | Actual result and scope |
|---|---|
| `u11-public-baseline.log` | Exit 0; four steps and all 230 precompile tests pass. |
| `u11-first-slice-red.log` | Exit 1; 2,561 pass, one skip, two expected failures. Cursor publication and exchanged return-only owners fail. |
| `u11-first-slice-corrected.log` | Exit 0; sixteen steps, 2,794 pass, one skip. Both failures and two parameter-owner contrasts pass. |
| First-slice Astra review | Static source acceptance only. All seventeen arrays participate in rollback. |
| `u11-final-owner-first.log` | Exit 1; two shadowing errors prevent four artifacts from compiling. Only 94 base and contract tests run. |
| `u11-final-owner-shadow-fixed.log` | Exit 1; fourteen of sixteen steps, 2,798 pass, one skip, one recorded-window failure. All 232 precompile tests pass. |
| `u11-final-owner-corrected.log` | Exit 0; sixteen steps, 2,802 pass, one skip. All 232 precompile tests pass. |
| `u11-final-owner-endpoint.log` | Exit 0; sixteen steps, 2,803 pass, one skip. All 232 precompile tests pass after endpoint correction. |
| `u11-header-first.log` | Exit 0; sixteen steps, 2,809 pass, one skip. All 233 precompile tests pass, including expanded public cases. |
| `u11-header-repeated-red.log` | Exit 1; eleven of thirteen steps, 2,576 pass, one skip, one failure. Repeated-name parsing returns `InvalidPredicateTarget`. |
| `u11-header-first-corrected.log` | Exit 0; sixteen steps, 2,810 pass, one skip. All 233 precompile tests pass after first-match correction. |
| `u11-header-matrix-first.log` | Exit 1; fourteen of sixteen steps, 2,822 pass, one skip, two probe failures. All 233 precompile tests pass. |
| `u11-header-matrix-corrected.log` | Exit 0; sixteen steps, 2,824 pass, one skip. All 233 precompile tests pass after probe corrections. |
| `u11-module-first.log` | Exit 1; fourteen of sixteen steps, 2,826 pass, one skip, one stale typed diagnostic-error expectation. All 233 precompile tests pass. |
| `u11-module-first-corrected.log` | Exit 0; sixteen steps, 2,827 pass, one skip. All 233 precompile tests pass with corrected pilot parity. |
| `u11-module-lexical-public.log` | Exit 0; four steps and all 234 precompile tests pass, including eight lexical sources. |
| `u11-module-scanner-correction.log` | Exit 0; sixteen steps, 2,838 pass, one skip. All 235 precompile tests pass. |
| `u11-nominal-module-corrected.log` | Exit 0; sixteen steps, 2,846 pass, one skip. All 235 precompile tests pass before the combined nominal diagnostic probe. |
| `u11-module-matrix-nominal-diagnostics.log` | Exit 0; sixteen steps, 2,859 pass, one skip. All 236 precompile tests pass. |
| `u11-module-probes-corrected.log` | Exit 0; sixteen steps, 2,859 pass, one skip. The strengthened wrapper and rich signature probes pass. |
| `u11-arrow-corrected.log` | Exit 0; sixteen steps, 2,865 pass, one skip. All 236 precompile tests pass before the stronger recovery control. |
| `u11-object-pilot-arrow-recovery.log` | Exit 1; four shadowing errors stop dependent artifacts. No object behavior verdict exists. |
| `u11-object-pilot-arrow-recovery-corrected.log` | Exit 0; sixteen steps, 2,870 pass, one skip. All 236 precompile tests pass. |
| `u11-owner-census.log` | Exit 0; sixteen steps, 2,872 pass, one skip. Census and shadowing probes pass before the exact closure-capture assertion. |
| `u11-named-comments-closure.log` | Exit 1; an unqualified nested enum stops compilation after 94 base and contract tests. |
| `u11-named-comments-closure-qualified.log` | Exit 1; fourteen of sixteen steps, 2,879 pass, one skip, one stale direct-refusal assertion fails. Closure capture passes. |
| `u11-named-comments-provenance.log` | Exit 0; sixteen steps, 2,882 pass, one skip. Exact legacy capture, rejected grammar, and closure binding assertions pass. |
| `u11-prefix-complete-first.log` | Exit 1; fourteen of sixteen steps, 2,888 pass, one skip, five failures. Three assertions, successful-prefix bookkeeping, and a diagnostic expectation need correction. |
| `u11-prefix-complete-corrected.log` | Exit 1; fourteen of sixteen steps, 2,890 pass, one skip, two failures. Prefix presence and diagnostic parity need correction. |
| `u11-prefix-complete-diagnostic-parity.log` | Exit 0; sixteen steps, 2,892 pass, one skip. All prefix and earlier owner probes pass. |
| `u11-focused.log` | Exit 0; 45 steps, 3,698 pass, one skip. This receipt precedes the variable declaration-owner amendment. |
| `u11-variable-owners-small.log` | Exit 0; sixteen steps, 2,896 pass, one skip. Final declaration owners and strengthened rollback probes pass. |
| `u11-focused-variable-owners.log` | Exit 0; 45 steps, 3,702 pass, one skip. Complete amended frontend checks pass. |
| `u11-verify.log` | Exit 1; aggregate reports 188 of 191 steps, 8,459 pass, six skips. Only documentation drift fails; later script steps do not run. |
| `u11-retired-module-small.log` | Exit 0; 27 steps, 2,896 pass, one skip. Documentation, metadata, tier, and behavior checks pass after the shared-identity correction. |
| `u11-focused-final.log` | Exit 0; all 45 steps, 3,702 pass, one skip. The complete frontend command passes. |
| `u11-verify-final.log` | Exit 0; every CI test-job step in the full script passes. |
| `u11-docs-final.log` | Exit 0; all eight documentation and spine steps pass. |

Every temporary artifact path in this worklog is relative to `/tmp/zttp-reset-20261015/`.
The authority retains detailed findings, source corrections, and accepted design requirements.
Astra source acceptance does not replace execution or authorize production cutover.
U11's public baseline includes twenty-six header cases and the measured prefix and module contrasts.

U12's final API refresh found the repeated-global identity gap.
Astra accepts the amended source selections, declaration queries, and authored annotation census.
Direct variable lookup uses the declaration node and validates the complete binding.
Eligibility refusal leaves selection unchanged; successful validation reserves selection before lowering.
Lowering failure consumes selection and leaves incomplete metadata unhealthy.
The authority retains the complete API conditions.
Isolated drafting can overlap U11's frozen gates, as Astra accepted.
Integration waits for the U11 commit and a refresh against committed APIs.
The external `u12-growth-tools.zig` fragment now has an integrated, source-reviewed seventeen-case test.
The sixteen layout cases and sixteen prefix shifts remain in `u12-growth-baseline/`.

The task continues through U20.

## U9 intermediate receipts

| Run | Direct result |
|---|---|
| `u9-first-slice.log` | Exit 0; 13 steps, 2,483 pass, 1 skip |
| `u9-public-baseline.log` | Exit 0; 213 precompile tests, including the initial 26 declaration sources |
| `u9-full-first.log` | Exit 1; 14 of 16 steps, 2,699 pass, 1 skip, 1 census failure |
| `u9-corrected-first.log` | Exit 0; 16 steps, 2,710 pass, 1 skip |
| `u9-corrected-second.log` | Exit 0; 16 steps, 2,713 pass, 1 skip |

## Completed phase receipts

Every log name below is relative to `/tmp/zttp-reset-20261015/`.
Every accepted phase passed whole-tree formatting, diff checks, and Astra source review.
The full gate passed aggregate tests, standalone runtime, optimized builds, verified precompilation, smoke tests, shell gates, and offline replay.
Source review does not replace execution or establish a performance improvement.

| Phase | Local commit | Final additional-suite result | Full gate | Final documentation and spine |
|---|---|---|---|---|
| U1 (compatibility baseline) | `ad1aa961` | `u1-focused-corrected.log`: exit 0, 34 steps, 3,474 pass, 1 skip | `u1-verify.log`: exit 0 | `u1-docs-final.log`: exit 0 |
| U2 (sibling export effects) | `2f1ca7c5` | `u2-focused-final.log`: exit 0, 53 steps, 4,026 pass, 2 skip | `u2-verify.log`: exit 0 | `u2-docs-final.log`: exit 0 |
| U3 (analysis lifetime) | `f4967788` | `u3-focused-third.log`: exit 0, 36 steps, 2,865 pass, 1 skip | `u3-verify.log`: exit 0 | `u3-docs-final.log`: exit 0 |
| U4 (path effect facts) | `a13b1849` | `u4-focused-final.log`: exit 0, 30 steps, 2,854 pass, 1 skip | `u4-verify.log`: exit 0 | `u4-docs-final.log`: exit 0 |
| U5 (contract effect facts) | `d79afafb` | `u5-focused-final.log`: exit 0, 39 steps, 3,090 pass, 1 skip | `u5-verify.log`: exit 0 | `u5-docs-final.log`: exit 0 |
| U6 (root source capture) | `f8d4fce4` | `u6-focused.log`: exit 0, 25 steps, 1,765 pass, 1 skip; `u6-determinism.log`: exit 0 | `u6-verify.log`: exit 0 | `u6-docs-final.log`: exit 0 |
| U7 (primitive typed parser) | `a56107e3` | `u7-focused-accepted.log`: exit 0, 45 steps, 3,383 pass, 1 skip | `u7-verify.log`: exit 0 | `u7-docs-final.log`: exit 0 |
| U8 (compound type syntax) | `df11fb48` | `u8-focused.log`: exit 0, 45 steps, 3,424 pass, 1 skip | `u8-verify.log`: exit 0 | `u8-docs-final.log`: exit 0, 8 steps |
| U9 (named and recursive declarations) | `23ef9e84` | `u9-focused.log`: exit 0, 45 steps, 3,470 pass, 1 skip | `u9-verify.log`: exit 0 | `u9-docs-final.log`: exit 0, 8 steps |
| U10 (generic syntax) | `aa5489c2` | `u10-focused.log`: exit 0, 45 steps, 3,551 pass, 1 skip; corrected source: `u10-propagation-small.log`, exit 0, 16 steps, 2,778 pass, 1 skip | `u10-verify-propagation.log`: exit 0 | `u10-docs-final.log`: exit 0, 8 steps |

U2 also passed `u2-zruntime.log` separately.
U2, U4, U5, and U7 matched all 734 flow probes.
The final focused and full gates passed the 182-case diagnostic corpus where required.
Detailed accepted findings remain in the authority.
Earlier execution narratives remain in prior commits and `worklog-through-u8-slice.md` outside the repository.

## Failed checks and corrections

These receipts retain failures without treating a later pass as evidence that the earlier run passed.

| Run | Result | Correction or limit |
|---|---|---|
| `u1-focused.log` | Exit 1; one failure | Fixture lost a function name and trailing spaces. |
| `u2-integration-first.log` | Exit 1; three failures and one crash | Corrected stale expectations and invalid fixtures. |
| `u2-focused-corrected.log` | Exit 1; 51 of 53 steps | Added the missing conservative-default explanation. |
| `u2-null-atoms-red-corrected.log` | Exit 1; intended failure | Exposed holder registration without resolved names. |
| `u3-focused-first.log`, `u3-focused-corrected.log` | Compilation failures | Renamed conflicting state types and local captures. |
| `u4-zts-first.log` | Compilation failure | Corrected a shadowed capture and missing facts argument. |
| `u5-baseline-first.log`, `u5-baseline-corrected.log` | Exit 1; one failure each | Prepared typed source, corrected ownership cleanup, and used an actual declaration-bearing block. |
| `u5-focused.log` | Exit 1; 37 of 39 steps | Restored two proof-scope explanations without widening the allowlist. |
| `u6-changing-root-red.log` | Exit 1; intended failure | CHECK reread replacement bytes after capturing the root. |
| `u6-agent-first.log` | Compilation failure | Unwrapped an optional JSON value in the new assertion. |
| `u7-zts-first.log` | Compilation failure | Corrected atom narrowing and runtime iteration over a comptime enum. |
| `u7-focused.log` | Exit 1; tier gate only | Added the two new tracked source files; the gate remained unchanged. |
| `u7-focused-final.log` | Exit 1; one failure | Corrected the expected private exclusion reason while retaining exclusion. |
| `u8-slice-first.log` | Exit 1; compilation failures | Renamed the shadowed checkpoint and added missing ASCII identifier helpers. |
| `u8-slice-corrected.log` | Exit 1; compiler artifact failed | Added an explicit `TypeSyntax.Span` result type. Engine and precompile tests passed. |
| `u8-final-bounded.log` | Exit 1; engine compilation failed | Main moved the computed second-annotation offset inside the allocation-sweep function. |
| `u9-full-first.log` | Exit 1; declaration census failed | Same-line declaration fixtures declined before their intended semantic checks. Source review also found unasserted census rows. |

The first U2 CLI candidate used prohibited `void` and supplied no writer evidence.
The corrected writer baseline and final responses remain in `u2-baseline-writer.json` and `u2-final-writer.json`.
A native `Math.random()` probe clears purity and determinism without adding the `random` capability.
The authority retains the resulting imported-row, namespace, holder, summary, and identity decisions.

## U8 baseline receipts

Main measured 45 original CLI fixtures in `u8-cli-baseline/`.
The full responses and direct statuses remain in that directory's index.
Tools tests freeze diagnostic order, stages, text, locations, suggestions, and the propagated empty-template error.
Compiler tests separately freeze exact type structure and admission.
The exhaustive census contains eight compound families and 31 semantic quirks.

| Run | Direct result |
|---|---|
| `u8-baseline-first.log` | Exit 0; 16 steps, 2,676 pass, 1 skip |
| `u8-baseline-census.log` | Exit 0; 16 steps, 2,673 pass, 1 skip |
| `u8-baseline-boundaries.log` | Exit 0; 16 steps, 2,675 pass, 1 skip |
| `u8-baseline-whitespace.log` | Exit 0; 16 steps, 2,675 pass, 1 skip |
| `u8-slice-third.log` | Exit 0; 16 steps, 2,676 pass, 1 skip |
| `u8-full-corrected.log` | Exit 0; 16 steps, 2,685 pass, 1 skip |
| `u8-final-slice.log` | Exit 0; 16 steps, 2,690 pass, 1 skip |
| `u8-final-bounded-corrected.log` | Exit 0; 16 steps, 2,690 pass, 1 skip |

The census consolidated duplicate tests, which reduced the intermediate passing count.
Astra required the record tag before accepting a zero-field result.
Fifteen function parameters retain exact metadata; sixteen produce `TypePoolCapacityExceeded` after admission.
Arrays with 63 and 64 suffixes retain every layer in healthy pools.
Canonical encoding succeeds at 63 layers and refuses 64 layers.
Whitespace before adjacent `[]` remains allowed; whitespace inside the brackets stops suffix recognition.
Astra accepted the baseline and revised private specification before main released Stage 2B.

The full earlier U8 narration remains in `worklog-through-u11-module-pilot.md` outside the repository.
The authority retains accepted design findings, and the tables above retain execution receipts.

## Later phase preparation

Read-only reviews ran no builds, tests, edits, or Git writes.
Each fresh implementation worker must refresh findings against the completed preceding phase.

| Phase | Preparation and receipts |
|---|---|
| U9 (declarations) | Authority records admission, aliases, nominal identity, and recursion. Sixteen CLI fixtures in `u9-declaration-baseline/` all exit 1 at measured distinct stages. |
| U10 (generics) | Authority records admission, ignored defaults, compact limits, collisions, constraints, and substitution. |
| U11 (annotation owners) | Authority maps all legacy kinds to exact owners. `u11-partial-parameter-baseline/partial.json` observes ZTS203 before ZTS601. |
| U12 (type consumers) | Authority records compact parameter policy, repeated-name selection, strict raw spans, health, and profiles. Seven CLI fixtures remain in `u12-lookup-baseline/`. |
| U13 (proof and printer) | Authority records opaque spans, callback projection, contracts, and certificate inputs. Both fixtures in `u13-signature-baseline/` exit 0 and report nested `pure` declarations. |
| U14-U16 (cutovers) | Authority maps CHECK, compilation, normalization, virtual sources, Pi tools, graph observations, and benchmark boundaries. |
| U17 (removal) | Authority records live helper relocation, diagnostic identity, exports, gates, and fixture retention. `u17-diagnostic-baseline/meta.json` exposes no catalog hash. |
| U18 (recovered workspace) | Authority records five owner sites, lock/root binding, recovery progress, fault outcomes, and persistence-before-acknowledgement. |
| U19 (retired state) | Authority records three deletion candidates, live ledger/rendering owners, exact directory timing, and hosted-state preservation. |
| U20 (documentation and evidence) | Authority records preliminary guide references and the required final census. |

The authority retains the accepted distinction between loaded multi-module contracts and single-module full analysis.
Later phase workers must refresh preparation against completed source before implementation.

## Verification commands

All acceptance steps remain unfiltered, and direct process exit status supplies each verdict.
The common full gate runs aggregate `zig build test -j1` on Darwin and standalone runtime in a separate process.
Existing user approval covers the required long gates.

```sh
env -u DEEPSEEK_API_KEY -u ZTTP_CODEGEN_RECORD -u ZTTP_EVIDENCE_PUBLISH bash scripts/verify.sh
```

The frontend phases also require:

```sh
env -u DEEPSEEK_API_KEY -u ZTTP_CODEGEN_RECORD -u ZTTP_EVIDENCE_PUBLISH zig build test-zts test-precompile test-zts-cli test-canonicalize test-diagnostic-corpus test-contract-golden test-generic-intersection-cli-matrix test-cli-abuse test-module-boundary test-zts-layering -j1 --summary all
zig build test-docs-drift test-doc-links check-spine -j1 --summary all
zig fmt --check build.zig build/ packages/ tooling/
git diff --check
```

The authority names each phase's additional suites.

## Frontend measurement baseline

The host reports Darwin 25.6.0 arm64 and Apple M4 Pro; Zig reports 0.16.0.
The one-iteration pilot and 50-iteration measurement exited 0 across all eight fixtures.
Only the iteration parameter changed.
Receipts are `frontend-baseline-pilot.json` and `frontend-baseline.json`.
The harness measures source preparation, parsing, and code generation, not CHECK or imported analysis.
No performance improvement is claimed.

| Fixture | Nanoseconds per iteration | Allocated bytes | IR nodes |
|---|---:|---:|---:|
| `tiny_hello` | 7640 | 7218 | 16 |
| `small_arith` | 19160 | 10882 | 48 |
| `medium_object_ops` | 41080 | 23594 | 101 |
| `large_module` | 87340 | 47035 | 214 |
| `explicit_text_joins` | 35300 | 19872 | 86 |
| `member_chains` | 26360 | 14409 | 75 |
| `module_imports` | 21440 | 15188 | 46 |
| `html_component` | 38100 | 25132 | 110 |

Main integrates seven operational tests and expands the contract matrix from seven to nine cases.
The two added cases use measured ZTS511 and ZTS504 output at line 1, column 17.
Astra reviews both frozen candidates independently.
The lowering patch remains outside the repository because source review finds overlapping cleanup and one stale assertion.
Sol prepares both corrections and a planning allocation-failure test.
A separate Sol refreshes U14's packet without implementing that phase.

| Further U13 receipt | Actual result and scope |
|---|---|
| `u13-operational-prelowering.log` | Exit 1; eighteen of twenty-one steps succeed, 1,409 pass and one skips. A private constructor call blocks compiler tests; precompile passes all 240 tests. |

Main corrects the operational tests to use the public contract constructor without widening visibility.
Astra identifies that an inline callback return cannot produce the asserted marker under the retained semantics.
Main replaces that source with the independently measured `CryptoValue` alias fixture.
The corrected small gate runs before the lowering patch enters the repository.

| Further U13 receipt | Actual result and scope |
|---|---|
| `u13-operational-public-constructor.log` | Exit 1; nineteen of twenty-one steps succeed, 2,952 pass, one skips, and four fail. The existing callback pool assertion fails. Three allocation-test controls stop at SoundModeViolation before injection. |

The corrected operational tests compile and their callback effect projection sweep passes.
Their shared generic source returns a concrete alias where sound mode requires the generic return type.
Sol prepares a valid fixture before further execution.
Astra also requires allocation injection through the environment, actual export capture, precise failure counts, and partial serialization coverage.
Those changes strengthen the accepted operational checks without changing production behavior.
The corrected lowering candidate is frozen for Main and Astra review; it is not integrated yet.

Astra accepts the corrected lowering source, and Main integrates the exact frozen patch after full line review.
The strengthened native probe passes its one-case pilot, then all eight cases with the same binary.
Every pool array and all ten primitive indices match; the backtracking case now contains 84 nodes on both paths.
The unfiltered lowering gate runs against the integrated source.
Operational fixture and coverage corrections remain outside the repository.

| Further U13 receipt | Actual result and scope |
|---|---|
| `u13-callback-pool-probe/compile-parity.log` | Exit 0; the strengthened executable compiles against integrated lowering. |
| `u13-callback-pool-probe/parity-pilot.log` | Exit 0; the callback pools match exactly. |
| `u13-callback-pool-probe/parity-all.log` | Exit 0; all eight cases match every pool array and primitive index. Only the case limit changes. |

| Further U13 receipt | Actual result and scope |
|---|---|
| `u13-lowering-v3.log` | Exit 1; nineteen of twenty-one steps succeed, 2,959 pass, one skips, and three fail. The callback regression and all six new lowering and parser tests pass. Only the three known SoundModeViolation controls fail. |
| `u13-operational-healthy-probe/compile.log` | Exit 0; the revised healthy control compiles against integrated source. |
| `u13-operational-healthy-probe/pilot.log` | Exit 0; sound completion, extraction, the crypto callback row, and export capture all succeed. |

Main integrates the fixture-only correction after line review.
The nongeneric callback uses string for its parameter and declared return.
Sol continues the allocation coverage corrections against that source.

U14 source review rejects several proposed shared policies because legacy producers differ.
Main measures five general cases, two module-priority cases, and eleven producer-policy cases after separate one-case pilots.
The immutable legacy analyzer confirms the distinct export, parameter-key, optional-parameter, assertion-position, declaration-order, and module-priority rules.
Astra prepares a bounded correction note before any U14 implementation starts.
The authority owns those detailed findings.

| Further U13 receipt | Actual result and scope |
|---|---|
| `u13-operational-complete.log` | Exit 1; nineteen of twenty-one steps succeed, 2,961 pass and one skips. Serialization has one failed error expectation. Extraction also reports two leaks and double frees in capsule cleanup. |

The complete sweep exposes a pre-existing ownership defect in `dischargeFunctionCapsules`.
A transferred proof summary retains local error cleanup, and nested string allocations can leak before append takes ownership.
The same code exists in committed U12; the new failure sweep supplies the missing evidence.
Sol prepares a bounded cleanup patch, and Main retains the existing public extraction sweep as its regression.
Main corrects serialization expectations to retain the writer's measured `WriteFailed` error and owned-slice `OutOfMemory` error.
Both require an induced allocation failure and an unchanged completed extraction.

Main merges Astra's U14 corrections into the refreshed temporary packet.
Seven lexical and recovery controls pass their measurement script after a one-case pilot.
The raw resume position remains explicit because recording a string diagnostic alone can lose a later import.
Astra reviews the corrected packet before implementation release.

| Further U13 receipt | Actual result and scope |
|---|---|
| `u13-ownership-corrected.log` | Exit 1; eighteen of twenty-one steps succeed, 1,413 pass and one skips. An unreachable test switch arm prevents the compiler root from running. |
| `u13-ownership-test-accounting.log` | Exit 0; all twenty-one steps succeed, 2,962 pass and one skips. Compiler reports 1,549 pass without leaks. All operational, public lowering, and cleanup probes pass. |

Astra accepts the bounded capsule cleanup and both test corrections as source changes.
Main preserves exact writer error tags and uses one allocator throughout the public pool failure probe.
The new public lowerer test replaces a private test whose unchanged-pool assertions were tautological.
Its successful control compares exact legacy pool structure with nonempty fields, parameters, and template parts.
Its allocation sweep observes both early healthy-pool refusal and later pool allocation failure.

The printer now uses its existing trim helper before appending a legacy region.
The full profile retains only settings used after source selection.
Parameter validation shares one range classifier, and name-plan capacities use named options.
The inaccurate checker-reuse paragraph and private helper narration are removed.
The focused gate checks these changes with every current proof test unchanged.

| Final U13 focused receipt | Actual result and scope |
|---|---|
| `u13-focused-final.log` | Exit 0; all 57 steps succeed, 4,018 native tests pass and one skips. CLI separately reports 600 pass and one skip. All 182 diagnostic corpus cases pass. |
| `u13-fmt-final.log` | Exit 0; build, packages, and tooling formatting checks pass. |
| `u13-diff-final.log` | Exit 0; whitespace checks pass. |

Astra accepts final U13 source without a remaining blocker after the bounded simplification.
The complete local script now runs as `u13-verify-final.log`.
Its result, final documentation checks, and the final execution audit remain pending.

| Final U13 full receipt | Actual result and scope |
|---|---|
| `u13-verify-final.log` | Exit 0; all CI test-job steps pass. The aggregate, standalone runtime, release compilation, verified handler compilation, workflows, offline gates, and formatting pass. |

The full local script passes after all final source changes.
Final documentation checks and Astra's execution audit remain before the local commit.
The U14 reader characterization patch remains outside the repository and has independent Astra source acceptance.
Its execution starts only after U13 commits.

| Final U13 acceptance | Actual result and scope |
|---|---|
| `u13-docs-final.log` | Exit 0; all eight documentation drift, link, and spine steps pass. |
| Final Astra execution audit | ACCEPT; U13 satisfies source and execution requirements without a remaining blocker. |

Main owns the exact-path local commit.
The unchanged untracked Claude sibling plan remains excluded.
