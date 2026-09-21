# M2: bounded correctness and assurance

Status: implementation and review complete; full local verification pending.
Selected by the user on 2026-09-21. Baseline: `e28355b6` on local
`main`, with a clean working tree and Zig `0.16.0`.

## Scope and completion checks

Make HTTP reason phrases consistent across response construction and wire
output. Test shutdown when its grace period expires. Close the four confirmed
certificate decoder error gaps. Keep the current lifecycle and certificate
contracts. Facade changes, new certificate rules, and M3/M4 are outside this
milestone.

### U1: HTTP status text

Inspect the response constructors, cached strings, prebuilt responses, runtime
native helpers, and server serializer. Add a public response regression and
observe its failure before changing production code. Replace the conflicting
lookups with one lookup at an existing dependency boundary. Preserve the union
of current named statuses, including durable status 202 and extension 599,
and the `Unknown` fallback. Keep
cached strings and prebuilt wire lines consistent with that lookup.

Owned files: HTTP helpers and their tests under `packages/zts/src/`; the tier
roots needed to expose the shared helper; `packages/runtime/src/runtime_natives.zig`,
`server_response.zig`, `durable_executor.zig`, and response tests in
`zruntime_tests.zig`. Add `status_text.zig` to `scripts/zts-tiers.allow`.
Do not change `server.zig`, which belongs to U2.

Completion: public regressions show the expected phrase for previously
inconsistent statuses and unknown statuses; affected unfiltered engine and
runtime suites pass; module-boundary and tier checks pass.

### U2: shutdown grace expiry

Owned file: `packages/runtime/src/server.zig`. Reuse the existing socket test
fixture for two scenarios: an accepted request completes within grace, and
shutdown returns at grace expiry while that request remains active. In the
expiry case, assert that the listener stops, pool occupancy remains one, and
the request still returns its exact response after release. Join workers before
deinitializing their state. Use bounded waits and measure the test duration.

Completion: unfiltered `test-server` passes. Removing the grace-expiry condition
must make the new test fail. Restore the production file before acceptance.
No shutdown behavior change is planned.

### U3: certificate decoder errors

Owned file: `packages/proof-checker/src/certificate.zig`. The four missing
public decode outcomes are `DuplicateSection`, `SectionTooLarge`,
`SectionLengthMismatch`, and `SectionNotCanonicallyOrdered`. Start with an
accepted certificate and mutate one wire property for each refusal. Count
observed errors by error variant, not by input count or reason-code mapping.

Completion: all decoder error variants have executable public decode probes;
unfiltered `test-proof-checker` and `test-proof-checker-purity` pass. Deliberately
bypass each of the four selected checks and confirm a test failure, then restore
the decoder exactly. No decoder contract change is planned.

## Execution and verification

U1, U2, and U3 have separate file ownership. Fresh Sol workers can author them
in parallel from this committed plan. Workers do not build, stage, or commit
in the shared checkout. The main agent reviews every changed line and owns all
builds, mutation probes, and commits. U1 stops after its regression is written
so the main agent can observe the failure before the fix.

Run unfiltered targets and read their exit status directly. Start with bounded
checks. Ask before running a script that exceeds two minutes, as required by
the AGENTS instructions supplied in this session. Save temporary logs and
mutation backups outside the tracked tree.
Restore each mutation before the next probe. Run the relevant checks again on
the restored tree. Review the integrated diff, update the roadmap, and archive
this record when complete. Commit each complete unit on local `main`; do not
push.

## Implementation and observed checks

Baseline check: `zig build test-proof-checker --summary all` passed all 160 tests.
The cached build completed in 0.1 seconds; the test process took 28 milliseconds.

U1 is committed as `a0181c16`. Before the fix, unfiltered regressions observed
`Unknown` for a handler-created 502, a prebuilt 413 response, and a threaded
202 response. One base-tier lookup now supplies all response paths. It retains
all 26 phrases from the old switches and the durable response's `202 Accepted`.
Cache checks enumerate the supported status range and require non-empty input.
Fetch replay checks that an upstream phrase survives unchanged.

U2 is committed as `96516a89`. Both full socket scenarios pass. The complete
within-grace scenario took 121.558 milliseconds; the expiry scenario took
44.740 milliseconds in an unfiltered instrumented run. The test measures the
shutdown call on its control thread and requires a duration from 25 to less
than 500 milliseconds. Disabling the grace limit made only the new expiry
test fail with `TestTimedOut`. Both the mutation and temporary timing code
were restored byte for byte before the final run.

U3 is committed as `d9cb0e23`. An exhaustive dispatch over `DecodeError`
executes public decoder probes for all 15 variants. Each starts from an
accepted certificate. Consolidation reduces the number of named kernel tests
from 160 to 153; it retains the predecessor case and truncation sweep. Separate
mutations bypassed the duplicate, section-size, section-order, and identity
length checks. Each made the executable census fail. An additional mutation
returned the wrong error for the length mismatch and also failed. Restoring
the decoder made the suite pass again. No production
decoder or shutdown behavior changed.

The main agent reviewed every changed line and ran these unfiltered checks:

| Check | Observed result |
|---|---|
| `zig build test-zts -j1 --summary all` | 2,218 passed; one skipped |
| `zig build test-zruntime -j1 --summary all` | 412 passed; one skipped |
| `zig build test-server test-proof-checker test-proof-checker-purity -j1 --summary all` | 566 passed; two skipped; purity check passed |
| `zig build test-zts-layering test-module-boundary -j1 --summary all` | Both gates passed |
| `zig build test-docs-drift test-doc-links -j1 --summary all` | All seven build steps passed |
| `zig fmt --check build.zig packages/` | Passed |

Three independent simplification readers checked reuse, code quality, and
efficiency. One comment now explains the decoder test's table-count offset.
A suggested extra helper for the direct cached-or-create expressions was not
needed. No other simplification finding remains.

Code review: skipped (ce-code-review unavailable). The skill requires Python
helpers, which conflict with the project's no-Python rule. An independent
manual correctness review and a separate concurrency review covered all 13
changed files against `0efdf160` and found no actionable defects. The reviewers
checked the root agent's test evidence but did not run builds themselves. The
500-millisecond expiry-test ceiling can fail under an extreme scheduler stall;
the measured run was within that bound.

The full `bash scripts/verify.sh` run can exceed two minutes. Approval was
requested under the supplied AGENTS time limit; it has not run for M2 yet.
