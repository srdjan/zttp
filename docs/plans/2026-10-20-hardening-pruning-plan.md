# Hardening and pruning before further features

Source checkpoint, 2026-10-20: all eight units implemented locally.
The acceptance notes below describe this checkpoint. Final ordinary verification
is recorded in the generated-evidence commits for this session, alongside
[convergence](../convergence.md) and [coverage](../coverage.md). The provenance
gate permits only generated evidence changes after the measured source commit.
The owner selected all eight findings from the source audit at `1c24eaf2`.
This plan preserves supported handler behavior, public commands, diagnostic
identities, wire formats, independent acceptance, and request isolation.
No release or remote publication is requested. The owner later approved publishing the new corpus measurement, including zero registry-rule hits; source and evidence provenance must be completed through the canonical publisher.

## Delivery order and status

| Unit | Result | Dependencies | Status |
|---|---|---|---|
| H1 | JSON HTTP headers borrow their existing JSON owner | none | Implemented; unfiltered standalone runtime suite passes in the main session |
| H2 | Failed runtime initialization releases wrapper resources and clears the host pointer | H1 | Implemented; bounded failure probes and standalone runtime suite pass |
| H3 | Verification route checks require executable work; unmatched test selection fails | none | Implemented; native rejection and positive-selection probes pass; combined gate follows |
| H4 | Each gate executes once and native helpers use the existing build artifact | H3 | Implemented; meta and determinism gates pass; combined gate follows |
| H5 | Both HTTP adapters use one native outbound exchange | H1, H2 | Implemented; standalone runtime, server and isolation suites pass |
| H6 | Complete the existing flow interpreter migration and retire the old walk | existing P6, then P7, P8 and P9 | Implemented locally with analyzer version 7; all 214 expectations and semantic censuses pass; final aggregate and evidence publication pending |
| H7 | Remove duplicate extraction orchestration and impossible contract selection | none | Implemented; unfiltered zts and precompile suites pass; broader graph merge rejected below |
| H8 | SDK and engine share runtime-independent binding vocabulary and validation | none; reconcile with H6 before integration | Implemented; SDK/module/zts and contract, diagnostic and expert golden gates pass |

Work on runtime, repository gates, and binding vocabulary may proceed
independently. Integrate and verify all changes together before claiming
completion. The flow redesign plan and its revised R1 to R16 contracts remain
the semantic authority for H6. This plan does not replace their fixtures or
weaken the cutover criteria. D-006 preserves CHECK's separate imported flow
and fault traversals, including their reader calls and revision selection.

## Baseline and drift

Planned at `1c24eaf2d4907a76d85675d7816aa2b3e7668e07`, clean working tree.
Read each affected area contract before editing. Compare current source with
the audit's cited mechanisms if HEAD changes. Use Zig 0.16.0 as pinned in
`build.zig.zon`; the installed Zig 0.17.0 cannot compile this build graph.
Record actual commands, toolchain, exit statuses, and any baseline failures.
Never use filtered runs as acceptance evidence or a pipeline's final command
as the build status.

## H1: remove duplicate header ownership

In `packages/runtime/src/runtime_http.zig`, `httpRequestResultJsonAlloc`
keeps `parsed` alive through synchronous request teardown. Validate and append
borrowed JSON header names and values. Delete `owned_header_slices` and both
string copies. Preserve errors, header ordering, newline checks, and request
lifetime. Exercise malformed headers and header-list allocation failures with
the testing allocator so leaks and duplicate frees fail the tests.

## H2: make construction and failure cleanup agree

In `packages/runtime/src/handler_instance.zig`, account for every resource
acquired before `init` or `initFromPool` returns. Clear a published `ctx.host`
on failure. Release tracing, outbound, and wrapper-owned state without
destroying pooled core resources. Prefer an explicit ownership handoff and
existing cleanup routines over another lifecycle framework. Test failures
after trace opening and after pooled host publication, with surviving pooled
contexts inspected after failure.

## H3: verify execution rather than mentions

Replace textual command/filename reachability assumptions in
`build/step_coverage.zig` and `scripts/check-script-reachability.sh` with
explicit executable route data consumed by the sequential verification driver
and coverage checker. The live build graph remains the authority for tasks.
Keep `test` and `test-zruntime` in separate processes, preserve manual and
release-only classifications, and do not build a general shell parser.
Ensure a requested test selection that executes no matching tests fails;
aggregate verification must not silently accept an empty filtered selection.
Add rejection probes that remove execution but retain labels/comments and
that select a nonexistent test. Count actual checked verdicts.

## H4: remove repeated gate work

In `scripts/verify.sh`, remove repeated proof-checker purity, diagnostic
producer, proof-ratchet drift, and residual-guard checks already reached by
aggregate `test`. Preserve their standalone steps. Route native helper users
through the existing `repo-gate` artifact, preserving command arguments and
the analyzer identity under test. Keep direct script invocation usable where
it is an established interface. Verify no helper needs a disposable cold
compiler cache during the canonical verifier.

## H5: one native outbound exchange

In `packages/runtime/src/runtime_http.zig`, preserve public fetch and JSON
HTTP adapters but share normalized transport orchestration. The native result
owns the response head/body and has explicit cleanup; errors retain stage and
details for the current adapters. Preserve DNS pinning, address-scope checks,
TLS identity, watchdog ordering, decompression and response-size limits,
timeouts, headers, reason phrases, trace behavior, and error strings. Compare
both adapters against the same local server cases, including send/read
failure, oversized decompressed bodies, empty POST/PUT, and timeout.

## H6: finish the existing flow cutover

Continue `docs/plans/2026-10-18-flow-checker-sound-redesign-plan.md` and its
P2 to P6 specifications. Implement request/header carriers and sink checks,
then persistence and imported summaries, before enabling the new evaluator.
Preserve diagnostic/witness/counterexample contracts. Evaluate every frozen
precision fixture, P0 semantic fixture, operation/tag census, diagnostic
corpus, flow census, example suite, and committed codegen handler. Classify
every verdict difference. Update analyzer version and all policy pins only
when changing production verdicts. Retain behavioral tests when deleting the
old implementation. Never turn an unsupported case into a proof. A corpus
re-record or evidence publication remains a deliberate recorded operation;
do not use live-model output as a substitute for semantic acceptance.

The [differential disposition ledger](2026-10-20-flow-interp-difference-dispositions.md)
covers every changed verdict in expanded report 03 and the later reconciliations.
Report 08 preserves all 4,917 report-05 shadow outcomes on unchanged inputs.
The other 35 rows come from seven revised recorded source graphs and are
classified separately as changed inputs. There are zero unresolved operations.
Its 101 public counterexample cards match 101 supported raw witnesses;
unsupported cases retain their verdict without an invented card. The runner
does not establish runtime validity for every candidate.

## H7: share remaining analysis orchestration

In `packages/tools/src/precompile.zig` and `packages/zts/src/pipeline.zig`,
make check, compile, and contract consumers receive completed analysis rather
than independently selecting missing passes. Reuse the existing direct typed
parser and `ModuleAnalysisSession`. Preserve D-006 reader behavior. Pin
single-module and imported-module diagnostics, contracts, bytecode, and pass
completion failures before deleting duplicate orchestration. Avoid a new IR,
generic pass framework, or speculative optimizer.

Detailed inspection narrowed this unit. The loaded-graph sound extraction
profile preserves direct authored types, while multi-module compilation uses
contract-only extraction with omitted types and per-module SQL and policy
checks. Combining those profiles would change accepted behavior. D-006 also
requires the independent flow and fault reader traversals. That broader merge
is rejected for this preservation pass rather than hidden behind a new graph
abstraction.

The implemented reduction keeps those profiles and shares their final
contract-extraction assembly in `ModuleAnalysisSession.extractCheckedResult`.
It removes `compileHandler`'s constant `needs_contract = true`, the forwarded
private parameter, and both impossible no-contract branches. The public
optional contract stays because verification-failure results legitimately
carry no artifact contract. Existing unfiltered `test-zts` and
`test-precompile` pass without changing their assertions.

## Release-version baseline correction

The committed baseline's `VERSION` was 0.22.4 while its three release package
manifests, public version string, README heading and installer current-version
comment still said 0.22.3. The existing aggregate release-version test rejected
that drift. The owner explicitly chose to align the copies to `VERSION`
0.22.4 during this work. Historical release notes and the separate analyzer
surface identity remain unchanged. The unfiltered `test-release-check` step
passes after this correction; the expert application also runs in aggregate
verification to check the identity boundary.

## H8: share binding vocabulary

In `packages/zttp-sdk/src/binding.zig`,
`packages/zts/src/module_binding/types.zig`, and
`packages/zts/src/module_binding_adapter.zig`, share types and pure validation
that carry identical semantics. Prefer SDK-owned dependency-free metadata
re-exported internally. Retain implementation pointer differences, opaque SDK
handles, capability enforcement, and engine-specific methods. Preserve enum
ordinals, label bits, declared signatures, discovery output, hashes, and
null-versus-empty capability meaning. Remove only conversion/alignment logic
made unnecessary by actual type identity. Assert public schema identities.

## Verification and completion

Run relevant unfiltered steps after each unit: runtime changes require
`zig build test-zruntime`, `zig build test-server`, panic/isolation gates;
tooling changes require native-gate/spine tests, step coverage and script
reachability; binding changes require `test-sdk`, `test-modules`, `test-zts`,
module boundary/layering, governance, and contract/diagnostic goldens.
Compiler and flow changes require `test-precompile`, `test-zts-cli`,
`test-flow-census`, `test-diagnostic-corpus`, `test-contract-golden`,
`test-expert-golden`, `test-standin`, `test-examples`, proof checker and
proof-ratchet gates. These command names are from the live task manifest.

Before completion run `zig build test`, `zig build check-spine`, and
`bash scripts/verify.sh` using the pinned toolchain. Check formatting and
`git diff --check`. Record commands and remaining limits in this plan. No
unit is complete merely because source edits exist. Preserve current tests
unless replacing an implementation-specific test with an equally strong
behavior assertion. Report a compatibility conflict before weakening any
frozen expectation. Do not change public behavior merely to make a
consolidation easier.

## Integration evidence

Pinned Zig 0.16.0 is used with explicit local and global cache overrides.
The main session's unfiltered standalone runtime suite and CLI suite pass;
the latter reports 609 passed and one skipped. Runtime replay exercises direct
authorization and actual branded Bytes/Dict values before an independent env
leak, including exact stub identity and complete stub consumption.

The unfiltered integration-10 batch passes `test-zts`, `test-precompile`,
`test-agent-protocol`, `test-diagnostic-corpus`, `test-contract-golden`, and
`test-diagnostic-producers`. The diagnostic corpus retains all 182 inputs;
only four goldens change: header-only flows lose duplicate body diagnostics,
and two precise dictionary transfers lose false determinism failures.
All 164 legacy flow test declarations remain, with three facade tests added.
Implementation-specific assertions are replaced by public behavior, and
unsupported legacy fabricated capsules have explicit absence assertions.

SDK, modules, governance, module boundaries, layering, proof-swallow, spine,
documentation, executable-route coverage and native-gate checks pass their
unfiltered checkpoints. Policy and receipt audits reproduce every old pinned
contract/certificate/search digest by changing only the policy hash back;
proof IR and runtime-policy bytes remain identical. Current policy identity is
`7e4e80f8f16700f9978aa97228a46aa66b02887e8a514b647c83495a5be48279`.

CHECK retains parser/capture owners and independent per-read dependency
revisions. Existing explicit-path and type-failure stopping probes remain.
The owner approved one D-006 extension: extensionless relative imports select
`.ts` with the compiler's pure resolver before either traversal reads. There
are no existence probes or shared flow/fault bytes. Clean and leaking custom
reader revisions are checked separately. Merged multi-module contracts still
omit proof properties; an unused compiled-graph adapter and its sole test
were removed rather than adding an analysis pass with no published result.

The new evaluator replaces about 5,100 implementation lines of the old walk.
It retains the finite heap/capture/persistence model, schema views tied to heap
writes, strict sink defenses, supported path constraints and exact-candidate
validation. Public proof traces omit missing/contradictory capsules and scope
containment statements to the property checked. Four precise constraint
variants are active (`req_path`, `req_path_not`, `stub_present`, `stub_absent`);
runtime witness JSONL record shapes are unchanged. Routed selections and
imprecise data reads may refuse a property without an executable capsule.

The approved complete DeepSeek re-record activates 13 new generations. All
13 reached green and passed runtime intent; 11 passed on the first attempt.
Every original generation is restored byte-identically beside the new active
descriptors. Two observed outcome pins change: `jwt-auth` true to false and
`sibling-helper` false to true. No recording metadata is edited by hand.

The draw trips `ZTS056` and `ZTS203`, both outside the advertised registry,
and zero registry rules. The owner approved publishing this measured zero.
The implemented correction calibrates the actual collector through all three
diagnostic paths against all 59 registry rules and a negative transcript;
no-op and false-positive collector probes reject. The replay requires all 13
declared cases, executions, artifacts and model observations, with an explicit
zero baseline and both off-registry codes. Native marker, publisher and union
checks accept a complete zero measurement while rejecting missing input,
incomplete partitions and conflicting source-tree observations. Their
unfiltered targeted suites pass. Generated prose distinguishes this draw's
zero observed registry-rule rejections from the faithful-harness claim.

The main-session unfiltered `ZTTP_EVIDENCE_PUBLISH=1 zig build test -j1`
passes with direct exit status 0 (`/tmp/zttp-pruning-source-aggregate.log`).
Its complete replay reproduces 13/13 intent passes and 11/13 first-attempt
greens, including collector calibration and the measured-zero marker.
The final HTML diagnostic guidance also passes the unfiltered ZTS and all
182 diagnostic corpus cases. Child-session socket restrictions are superseded
by this successful main-session aggregate. The ordinary full sequential
verifier and canonical publication follow this source checkpoint; their
results belong to the generated-evidence commits. Normal replay checks the
published coverage page after regeneration.

## Owner resolution of the weather precision conflict

On 2026-10-20 the owner chose to keep the strict sink policy and correct the
weather example's two proof claims and frozen expectations. The example sends
a schema-checked city to an external URL. Schema validation does not establish
`pii_contained` or the URL/header `injection_safe` guarantee. Those two claims
are removed from the frozen example and its expectation set, taking the
required property count from 216 to 214 over the same 48 handlers. This is an
explicit correction of false promises, not a miss-table exemption.
`input_validated` remains required and needs genuine heap-bound validator
evidence. No other frozen expectation changes. Original recorded generations
remain immutable; the corpus is re-recorded deliberately after the cutover.

Report 08 satisfies all 214 retained required bits, all 38 unsafe fixtures
(33 refused, five unproven), four clean contrasts, and the 734-case flow
census. The expanded runner checks 1,024 cases and 4,952 property rows with
zero source errors, unresolved operations or expectation misses. Its direct
exit status is zero. Current production/interpreter agreement is a sanity
check; the immutable pre-cutover reports and disposition ledger provide the
old/new comparison. The final inventory reconciles 4,917 unchanged-source
property rows with no shadow outcome changes and 35 revised-source rows
separately. Those 35 outcomes also remain identical; this does not establish
semantic equivalence of the revised sources.
