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
Each phase uses a fresh Sol high implementation worker; Astra xhigh supplies independent review.
Workers run no builds or tests and make no Git writes.
The pinned toolchain is Zig 0.16.0.
No Python, filtered acceptance tests, or concurrent pool-heavy roots are permitted.

The starting commit was `f917dc0b7320ecd0165e49a274311f77b3290796`.
Its tracked tree was `d3b97c46e4ee5fbd0da9174d4343887fbbbc7e16`.
The Claude draft `2026-10-14-sibling-module-effects-plan.md` remains untracked, untouched, and excluded.
No browser session was opened.

## Current work

U1 through U8 are complete and committed locally.
U9 source review, focused execution, and the full local gate pass.
U10 through U20 implementations remain unstarted.
Production callers retain the legacy frontend.
Main owns all files for final documentation checks and the local U9 commit; every worker has paused edits.

Main reviewed every changed U9 line and every correction.
Astra accepts the final U9 source after all five earlier blockers and three boundary findings are resolved.
Whole-tree formatting and `git diff --check` pass.
`u9-focused.log` passes: 45 steps, 3,470 pass, and one skip.
All 218 precompile tests pass, including the 52 public declaration sources.
The authority retains the scanner, ownership, oracle, span, census, admission, and allocation findings.
`u9-verify.log` exits 0 and reports that all CI test-job steps pass.

Sol high worker `reset_u10_generic_design` completed read-only preparation and owns no files.
Main measured 74 generic CLI contrasts across six directories; every command exits 1 at its recorded stage.
Astra accepts the amended full design, subject to U9's commit and API refresh.
Sol's final U9 API refresh found no required design change.
The outside fragment `u10-tools-complete-74.zig` contains all 74 fixtures and passes formatting only.
Main reviewed the fragment; integration and execution wait for U9's commit.

U10 evidence separates eligible whole-source comparisons, direct fragment/API properties, and the public production baseline.
Typed parameters, returns, predicates, and complete typed-source comparisons wait for U11.

Fresh Sol high worker `reset_u11_annotation_owners` completed a read-only Stage 1 proposal.
Astra conditionally accepts that design with the refinements recorded in the authority.
Three measured predicate contrasts require unresolved targets and a separate facet for legacy return classification.
The accepted compatibility root retains the whole raw return span and uses engine grammar during admission.
U11 implementation waits for U10's commit, final API refresh, Astra acceptance, and explicit release.

No product decision blocks progress.

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

## U8 review and remaining work

Main reviewed the complete initial 1,230-line parser checkpoint and the typed hook.
Main later reviewed the revised parser, direct lowerer, ordered oracle, and preflight changes.
Astra independently reviewed the parser checkpoint and now reviews lowering and comparison.

Returned findings cover missing `null` and `undefined`, absent-member stopping, exact nullable selection, closer handling, and all-six-array rollback.
They also cover explicit admission ends, group and modifier nodes, full member spans, and private implementation budgets.
The authority owns the detailed requirements and examples.

Main requested a compile-ready vertical slice before the full corpus.
The worker paused edits; main corrected three compile issues and ran the unfiltered small roots.
The accepted slice includes ordered record fields and nested arrays.
Main then returned source ownership for full corpus completion.

The next handoff must remove unused nullable syntax and always-false array and tuple fields.
Every private exclusion must restore the caller cursor.
The quoted scanner must avoid a self-recursive helper call.
Key allocation failure must propagate instead of becoming parity.
Syntactically present groups with absent meaning must stop later constructors at the legacy position.

Main measured three such absence contrasts in `u8-absence-baseline/`.
Each exits 1 with empty JSON and propagated `UnresolvedTypeBinding`, including the unused 16-parameter function.
Main extended the tools baseline from one propagated-error case to four.
Those additional assertions await the next unfiltered handoff run.
Main also measured six admission contrasts in `u8-admission-extra-baseline/`.
They confirm suffix `any` detection, Array refusals, nested-template text handling, and depth refusal before a later `any`.
Main extended the tools baseline with those exact diagnostics and their order.
Those assertions also await the next handoff run.
Astra found no further successful-type blocker in lowering or ordered comparison.
Its review requires independent direct capacity checks, because an earlier legacy failure otherwise prevents direct lowering from running.
The worker received every finding and owns the corrections.

## U8 full-corpus checks

The worker handed back all three files and paused edits.
Main owns all source until another explicit handoff.
The full first run compiled, then exited 1: 13 of 16 steps succeeded, with 2,682 pass, one skip, two failures, and one crash.
Its log is `u8-full-first.log`.
All 212 precompile tests passed, including 54 compound fixtures.
Nested function arrows triggered unmatched-parenthesis handling before the intended rollback and absence assertions.
Main corrected that raw scanning boundary.

A test also assumed that CHECK retains an earlier `any` before fatal depth failure.
The actual CLI reports only ZTS044; the assertion accessed the wrong verdict field and crashed.
Main corrected collect precedence and added a compile-mode first-refusal contrast.
The seventh receipt in `u8-admission-extra-baseline/` records that measurement.
Main replaced a named-error comparison with an exhaustive switch.
The corrected unfiltered run is active in `u8-full-corrected.log`.
Astra now reviews the complete source handoff.
That run exited 0: all 16 steps succeeded, with 2,685 passing tests and one skipped test.
Astra then identified missing forced budget probes and second-annotation allocation rollback coverage.
It also found truncated empty-group spans and a private eligibility change that bypassed complete-source validation after depth refusal.
Main returned the three files for a bounded correction handoff.
The worker must restore complete-source eligibility and retain fatal-only diagnostic collection as a separate policy.
It must preserve bare empty groups, force both private budgets, and cover every syntax array during second-annotation failures.
Main retains tools and documentation ownership; no build currently runs.
Main confirmed the allocating writer's `WriteFailed` projection in the pinned Zig source.
The worker must add a successful-comparison allocation sweep and keep operational key failures distinct from semantic key limits.
The architecture guide now describes compound syntax ownership and separate admission and semantic boundaries.

The final correction preserves empty-group spans and complete-source eligibility after fatal depth refusal.
It excludes template-overflow origins until their distinct legacy treatment has a shared validation path.
It adds all-six-array rollback, direct lowerer allocation failures, and successful-comparison allocation failures.
Main replaced the manual failure loop with the standard measured allocation sweep.
The same allocator now owns both annotations throughout that sweep.
Main balanced the nested template source used to force the private capacity limit.
Both engine and comparator budget sources now contain balanced nested templates.
The corrected unfiltered small roots passed in `u8-final-bounded-corrected.log`.
Astra accepted the final source after reviewing the corrected probes.
Whole-tree formatting and diff checks passed.
The broad frontend command passed in `u8-focused.log`: 45 steps, 3,424 passing tests, and one skipped test.
All 182 diagnostic corpus cases passed.
The full gate passed with exit 0 in `u8-verify.log`.
Final documentation checks passed with exit 0 in `u8-docs-final.log`.

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

Main corrected an earlier profile claim after checking the production graph loop and its behavior fixture.
The fresh Sol worker `reset_u9_named_declarations` now owns read-only Stage 1 preparation; U9 implementation waits for U8's commit.
Two additional CLI contrasts show that an ignored alias suffix prevents eager root capture.
Loaded multi-module contracts omit types for both entry and dependencies.
Single-module full analysis remains different.
Four further CLI contrasts in `u9-primitive-alias-baseline/` confirm whole-body lookup for primitive-name aliases and the nested compound exception.
Astra found two additional named-type boundaries: implicit `Readonly<Named>` projection and the one-suffix limit for ungrouped named arrays.
The proposed U9 design now requires exact whole-body lookup before lowering every source root.
Contractivity finalization must retain legacy additive map behavior across repeated population calls.
Astra accepted the revised U9 design after exact-root, readonly, suffix, and declaration-only comparison corrections.
U8's completed gates and commit now permit the first U9 implementation slice.

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
