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

U1 through U11 are committed locally.
The current commit is `f48b8295`, which completes annotation ownership.
U12's type-consumer implementation and required checks are complete; its local commit remains pending.
Astra accepts the complete U12 source and evidence with no remaining requirement blocker.
The task continues through U20 and the required quality checks.

U12 adds explicit source modes and final-owner inputs for type environments, type checking, strict checking, and function specifications.
The implementation preserves construction order, generic reuse, compact signatures, repeated-name winners, calls, predicates, and operational health.
The corrected small gate passes all 21 steps with 2,939 tests and one skip.
The final frontend gate passes all 45 steps with 3,757 tests and one skip.
All 182 diagnostic corpus cases pass within the existing cost budget.

The full local script exits zero as `u12-verify.log`.
Its aggregate tests, standalone runtime, release binaries, verified handler compilation, workflows, offline checks, and formatting pass.
The final documentation gate exits zero across all eight steps.
Whole-repository formatting and `git diff --check` also pass.
The receipt table retains every failed and corrected run separately.

The simplification review applies reuse one, quality one, and comments one; efficiency and test changes remain zero.
The review preserves every proof test, helper, observation seam, source order, and public behavior.
Broader lowering consolidation lacks exact equivalence, while shared whitespace helpers would expand the parser API; both proposals remain excluded.
The independent documentation review corrects current coverage, ownership, high-level entry, and bounded comparison-preflight descriptions.
Production frontend callers still use legacy source preparation.

I will record the final receipts and commit the completed U12 files on local main.
The earlier current-work narration remains in `worklog-through-u12-acceptance.md` outside the repository.
The authority owns detailed findings; this worklog owns current state and receipts.

U13 implementation remains unstarted.
Astra accepts the bounded printer packet with fourteen measured legacy outputs and exact refusal and OOM behavior.
The consumer packet still needs its measured ABI amendment and a positive callback ceiling fixture before implementation release.
The nine-case legacy harness compiles and passes both its one-case pilot and complete run.
Those receipts retain callback facts, transient contract fields, and six complete contract byte strings.
The omitted native `isDict` hole expects `boolean`; the ordinary helper control expects `unknown`.
The admission census for U14 remains preparation, with its final API refresh and production measurements pending.

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
