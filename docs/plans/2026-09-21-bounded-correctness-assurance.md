# M2: bounded correctness and assurance

Status: selected by the user on 2026-09-21. Baseline: `e28355b6` on local
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
`AGENTS.md`. Save temporary logs and mutation backups outside the tracked tree.
Restore each mutation before the next probe. Run the relevant checks again on
the restored tree. Review the integrated diff, update the roadmap, and archive
this record when complete. Commit each complete unit on local `main`; do not
push.

Baseline check: `zig build test-proof-checker --summary all` passed all 160 tests.
The cached build completed in 0.1 seconds; the test process took 28 milliseconds.
