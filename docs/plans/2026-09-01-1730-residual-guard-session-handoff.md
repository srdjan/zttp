# Residual Runtime Guard Addendum - Session Handoff

Written 2026-09-01, paused at `5fc7bd5b` with a clean tree and
`bash scripts/verify.sh` green on that commit.

Companion to
[2026-08-31-1242-feat-residual-runtime-guard-addendum-plan.md](2026-08-31-1242-feat-residual-runtime-guard-addendum-plan.md).
That file is the spec and stays authoritative. This one says where the work
stopped and what the next session needs that the spec does not carry.

## Where the units stand

| Unit | State |
|---|---|
| U1 closed residual guard contract | done before this session |
| U2 producer plan and exact binding | done before this session |
| U3 fail-closed policy generations | done before this session |
| U4a endpoint policy, contract facts, egress check | done before this session |
| U4 authoritative sink enforcement | **done this session** |
| U5 selective ZTS602 reclassification | **done this session** |
| U6 honest assurance surfaces | **partially done - this is where to resume** |
| U7 atomic format cutover and release gates | not started |

## What landed this session

Fifteen commits, `a6e05680` through `8410fc51`.

**U4.** The egress sink gained the check it never had: `resolvedScopeDecision`
in `packages/runtime/src/runtime_http.zig` resolves the name in the runtime,
classifies every answer with `zts.endpoint.scopeOf`, and opens the connection to
an address the policy admits - passed as a literal, with the real host name in
`proxied_host` so TLS still verifies the certificate. Handing
`std.http.Client` the name again would resolve a second time and reach an
address nothing checked. All three outbound call sites go through it, including
the parallel worker, which now carries the collecting runtime's policy across
the thread boundary.

An unnamed address scope denies, everywhere, including the struct default. That
was a decision taken in this session and recorded in the plan's Key Decisions;
R11 and AE11 were amended, because a literal-only handler needs the scope grant
like any other and no contract can supply it.

The env, cache, and SQL guards moved onto one normalization rule
(`packages/zts/src/identifier.zig`, mirrored from the kernel's
`identifier_exact_v1` and pinned against it in
`packages/runtime/src/proof_activation.zig`). Probes replaced assertions on the
helpers' return values: a denied env key aborts the request, five denied cache
operations each leave the module state slot empty, and a denied SQL write leaves
the row count in a real database file unchanged.

**U5.** `literalRequiredArg` no longer restates the guard catalog by hand - it
derives from `packages/zts/src/guard_catalog.zig`, a base-tier mirror pinned
against the kernel's table by content and order. That closed a live gap:
`fetchWithRetry` had a catalog row and no entry in the hand-written list, so a
computed URL through it passed strict checking while the same URL through
`fetch` was ZTS602.

The classifier is exhaustive and returns one of four answers - guarded, missing
policy section, family not enabled, unguarded surface - each with its own
diagnostic naming the guard kind, the policy section, the assurance consequence,
and the command to rerun.

Egress and cache were seeded, on the user's decision, so all three families have
the measured rejection R19 requires. SQL stays rejected: `sql.allow_queries`
names a query without saying whether it reads or writes, so a configured SQL
policy would admit one name for both and lose the split the sink enforces.

**U6, the part that is done.** Denial telemetry names the guard and not the
value it refused, with its own reason code for a resolved-address refusal, and
`zttp proofs verify` reports guard coverage on its own line through
`packages/runtime/src/proofs/guard_report.zig`.

## U6: what is left

The remaining work is the signed and machine-readable surfaces. The renderer and
the vocabulary already exist; what is missing is carrying the same facts through
the claim, the verifier, and the agent protocol.

1. **`packages/runtime/src/attest/envelope.zig`** - `Claims` needs a field for
   what this deployment decides at run time. The receipt is signed at build time
   from the contract alone (`build_receipt.zig:18` takes a `HandlerContract` and
   no assessment), so the honest producer-side claim is which capability
   categories the contract marks `dynamic`, not a residual obligation count the
   producer does not have. Suggested field `guarded_categories: []const u8 = ""`,
   wire key `guardedCategories`, comma-joined section names. Decode defaults to
   empty, and that default is honest for every envelope signed before the field
   existed, because nothing could be guarded before U7 turns classification on.
   The dynamic flags are on the contract's section structs
   (`packages/zts/src/contract_types.zig`, `dynamic: bool` per section).
2. **`packages/runtime/src/attest/build_receipt.zig:136`** - fill that field
   beside `property_summary`, in the same place the proof chips are formatted.
3. **`packages/runtime/src/verify_cli.zig`** - print it in the text block near
   "claimed chips" and emit it in `renderClaimsJson`. The `"assurance":
   "provenance_only"` marker already there is the right shape; the new field sits
   beside it, never inside the chip list.
4. **`packages/runtime/src/server.zig`** - three sites build `Claims` with
   `.property_summary = ""` (around lines 4036, 4091, 4133). They need the new
   field set deliberately rather than defaulted, for the same reason the comment
   at `build_receipt.zig:100` gives about absent cases that read as real values.
5. **`packages/tools/src/agent_protocol.zig`** - the machine surface. Add guard
   coverage as its own field. Not yet audited; that file is 5350 lines and the
   audit is the first task, not the edit.
6. **Golden outputs** - the plan wants static-only and guarded artifacts to keep
   distinct golden CLI, JSON, bundle, attestation, and agent-protocol outputs.
   None of that exists yet for the guarded side.

Verification for the unit: `zig build test-cli`, `zig build test-agent-protocol`,
and the golden-output gates.

## Decisions already taken, so they are not re-litigated

- **An unnamed address scope denies.** Chosen over an unconfigured-means-
  unconstrained flag and over a fixed default set. An empty scope set means one
  thing wherever it is read.
- **SQL stays rejected.** Not for lack of a seed - the policy file cannot
  express the read/write split. Enabling it needs a format change first.
- **Classification runs; only fatality waits.**
  `guard_catalog.classification_enabled` is `false`. A guarded operation is
  still a build error, because the producer emits the predecessor certificate
  and a guarded handler would fail at `GuardedOperationsNotRepresentable` with
  nothing for the author to read. **U7 flips that constant in the same commit
  that makes the successor certificate the strict default. Turning it on alone
  is the one thing that must not happen.**
- **The shape-table bug is documented, not fixed**, by explicit instruction. See
  [docs/solutions/logic-errors/a-second-program-load-kept-the-first-ones-object-shapes.md](../solutions/logic-errors/a-second-program-load-kept-the-first-ones-object-shapes.md).
  It is test-only today: production reload builds a fresh `HandlerInstance`.

## Gotchas this session paid for

- **A new file's tests are not collected unless something anchors them.** A
  deliberate break in `proofs/guard_report.zig` left `zig build test` green until
  `cli_main.zig`'s test block imported it. Break a new test on purpose and watch
  the build fail before believing it runs. The two new `zts` files were checked
  the same way and were fine, because `base_root.zig` re-exports them.
- **`scripts/update-coverage.sh` refuses to run on a dirty tree.** Commit first,
  regenerate, commit the regenerated pair.
- **Stand-in defect seeds have three constraints that are not written down
  anywhere else.** A seed source must pass the veto on its own, so it needs a
  `Proof` capsule its handler actually discharges. A good draft must differ from
  the seed source, or the repair is an empty change set and nothing is applied.
  And selection matches the seed id, longest first, since one id can sit inside
  another.
- **`zig build test-zruntime` takes several minutes** and a killed run can leave
  a build lock that makes the next one hang with no output. Check for stray `zig
  build` processes before concluding a suite is broken.

## Verification status

Green at `5fc7bd5b`, the commit this session paused on: `bash scripts/verify.sh`
(full gate, exit 0). That run covers every commit listed above, the two U6 ones
included.

Also run individually and green: `zig build test`, `test-zts`, `test-zts-cli`,
`test-zruntime`, `test-modules`, `test-standin`, `test-module-boundary`,
`check-zts-layering.sh`, `zig fmt --check`.
