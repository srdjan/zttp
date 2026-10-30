# Roadmap

This document owns work status and scheduling. Phase R13 of the 2026-10-25 reset
reviewed it on 2026-10-25. Shipped changes live in
[CHANGELOG.md](../CHANGELOG.md); current behavior lives in the
[User Guide](user-guide.md). The [plan index](plans/README.md) separates open
work from reference designs. Product proposals (`pre-rebase:docs/zttp-next/README.md`) and
[advisory plans](../advisor-plans/README.md) require a decision before execution.

## Milestones

The [2026-10-30 reset plan](plans/2026-10-30-reset-implementation-plan.md) is the active reset authority.
The [2026-10-30 reset worklog](plans/2026-10-30-reset-worklog.md) records its execution, commands, and exit statuses.
The 2026-10-25 reset is complete through R13 (2026-10-25). Its [plan](plans/2026-10-25-reset-implementation-plan.md) and [worklog](plans/2026-10-25-reset-worklog.md) are records, not an authority.
The [2026-10-14 reset plan](plans/2026-10-14-reset-implementation-plan.md) is also complete (U1 to U20) and is not an authority.
Release v0.26.0 was published on 2026-10-30. The release fixes plan shipped as 0.25.0.

Standing rule D-012 in [decisions.md](decisions.md): a model-visible change waits for one batched re-record window. The v0.26.0 window ran on 2026-10-29. The owner runs any later window.

Next work: the 2026-10-30 reset.

M1, M2, and M3 are complete.
M4 is complete: T1a to T7 were delivered. Decision 3 of [plan 005](../advisor-plans/005-feature-removal-rebase.md) stopped M5 on 2026-10-11. Phase 2 later removed both runtime products. No release date is assigned.

| Milestone | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| M1: accurate active backlog | Complete, 2026-09-21 | Codebase review at `1b0686a1` | Select the next milestone | Completion record (`pre-rebase:docs/archive/plans/2026-09-21-active-backlog-cleanup.md`); documentation gates pass and remaining work is classified |
| M2: bounded correctness and assurance | Complete, 2026-09-22 | Three implementation units committed and reviewed; affected suites and mutation probes pass | Select the next milestone | Completion record (`pre-rebase:docs/archive/plans/2026-09-21-bounded-correctness-assurance.md`); full local gate passed at `181d31d4`; public response regression test; selected lifecycle and decoder cases reject deliberate wrong behavior; affected unfiltered suites pass |
| M3: provable-set reach measurement | Complete, 2026-09-21 | Current DeepSeek default; pilot and full run authorized | Keep the used suite as regression evidence; select a new suite before a new holdout claim | [Full fresh report](provable-reach.md#first-full-measurement): 8/8 reached, 4/4 in each mode, with all selected tasks and source, policy, model, budget, and runtime evidence retained |
| M4: next release boundary | Contract accepted 2026-09-22; T1a to T7 completed; runtime product removed in Phase 2 | M1 proposal inventory and current strategy | None | Historical release contract at `pre-rebase:docs/plans/2026-09-22-m4-release-contract.md` |
| M5: agent handlers | Stopped 2026-10-11; A1 to A4 completed; A5 not implemented; runtime product removed in Phase 2 | Owner decision | None | Reopening M5 needs a new owner decision; historical A5 design at `pre-rebase:docs/plans/2026-09-28-m5-a5-reference-agent-design.md` |

M2's source evidence is `packages/zts/src/http.zig`,
`packages/runtime/src/server_response.zig`, and the conditional test gaps in
the completed rederive record (`pre-rebase:docs/archive/plans/2026-09-20-rederive-implementation-plan.md`).
M3 establishes bounded reach for the frozen suite in [STRATEGY.md](../STRATEGY.md#key-metrics).
M4 compared the agent-handler specification
(`pre-rebase:docs/plans/2026-09-19-feat-agent-handler-spec.md`) with the tool-profile recommendation.
The recommendation remains at `pre-rebase:docs/zttp-next/zttp-v1.0-scope-and-v1x-roadmap.md`.

## Supported Now

- Source builds on macOS and Linux, on x86_64 and aarch64.
- Published binaries for Linux on x86_64 and aarch64, and for macOS on aarch64.
  There is no Intel macOS binary.
- Zig `0.17.0` as declared by `build.zig.zon`.
- Threaded HTTP/1.1 server with per-request runtime isolation and decoded
  `Content-Length` or `Transfer-Encoding: chunked` request bodies.
- Restricted TypeScript handler execution through `zts`.
- The five core `zttp` commands: `init`, `dev`, `test`, `expert`, `deploy`.
- Local self-contained deploy artifacts with default-on attestation.
- Mandatory artifact-level proof certificates for deploy builds. Production
  startup reconstructs the executable graph and required obligations with the
  independent checker before pool initialization. `--no-attest` removes
  provenance, not semantic acceptance.
- Compile-time checks for response paths, Result and optional handling,
  state isolation, active specs, flow properties, contracts, and module policy.
- Built-in `zttp:*` virtual modules listed in
  [Virtual Modules](virtual-modules/README.md).
- Consumer-checked residual guards for computed environment keys, egress
  endpoints, and cache namespaces under an explicit capability policy.

## Current Limitations

- Hosted cloud deploy is not part of the current CLI surface. `deploy` builds a
  local binary, `deploy --cloud` parses and rejects with a "not available in
  this beta" message, and the account verbs (`login`, `logout`, `review`,
  `grants`, `revoke-grant`) are not dispatched, each naming itself as deferred
  rather than as an unknown command.
- The runtime uses the threaded HTTP server path. The evented `std.Io`
  networking path is not a supported request backend.
- Handlers receive raw `multipart/form-data` bodies from the HTTP server. Use
  `decodeFormMultipart` from `zttp:decode` or handler-owned parsing when a
  handler accepts multipart input.
- There is no scrape-able `/metrics` endpoint. `/_health` and `/_readiness`
  return bare status codes.
- Windows is not supported.
- Proof receipts have no identity binding. `zttp verify <url>` checks a
  signature against the key the endpoint supplies, so only `--trust-key`
  authenticates the signer. A claim has no host binding and no checked time.
  Deferred to receipt slice 2: a well-known key endpoint, a transparency log,
  and origin and freshness binding.
- The production certificate honestly reaches a `trusted` weakest edge today.
  The consumer re-derives `response_total`, but bytecode opcode meaning remains
  declared trusted, while `results_checked` and `no_secret_leakage` enter at `tested`. The
  production floor no longer requires `capability_bounded`: a handler gets it,
  at `tested`, only when it declares `Effects<...>`. See
  [Verification](verification.md#what-is-not-checked-said-out-loud).
- `zttp proofs gate` compares a handler that imports a changed helper, but it
  grades only what the contract records. The gate finds each handler that
  reaches a changed file through relative imports, and it compares that handler
  as if its own file changed: behavior paths, status, effects, and lost proofs.
  A change that only alters a value the helper computes is invisible, as it is
  for an edit inside a handler. A helper is never analyzed as a root, so a
  helper that fails its own analysis, such as `examples/handler/utils.ts` with
  ZTS061, no longer stops the gate. A changed helper that no handler imports
  is skipped as `unreferenced_helper`. The gate exits 2 when a handler that
  reaches a changed file has an import that CHECK cannot follow: a deleted or
  renamed helper, an extensionless specifier, a chain deeper than eight files,
  or a helper that fails its type check. It also exits 2 when a file that does
  not parse names a changed file and so may import it.
- Computed SQL resources remain refused. The configured SQL policy cannot
  distinguish read from write authority. Other residual-guard limits are in
  [Verification](verification.md#residual-runtime-guard-boundary).

## Runtime And Product Work

These items remain open. They are not all release blockers. A selected release
contract must identify which ones it needs.

| Work | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| Runtime lifecycle | Open; M2 grace-expiry coverage added | Current socket and panic-isolation tests | Check request-timeout policy and control-thread shutdown semantics against the intended deployment | Tests assert accepted requests, drain and expiry outcomes, and isolation; unfiltered runtime and panic suites pass |
| Modular analysis and runtime ownership | Complete, 2026-10-22; all five phases reviewed and finally verified | Owner approved phased implementation; [delivery plan](plans/2026-10-22-modular-boundaries-plan.md) | None within the approved plan | Analysis inputs, HTTP state, import identity, static descriptors, and server generation transitions have explicit owners; focused gates, registry pins, goldens, independent aggregate and full sequential verification pass |
| Module gaps | Needs scope | A concrete handler requirement | Identify a missing fetch-resilience, capability, or build-feature diagnostic case | Public example and regression test demonstrate the selected behavior |
| Hosted deploy | Deferred | Accepted hosted scope, lifecycle policy, and control-plane CI | Define a supported end-to-end deployment flow | CI exercises the control plane; released commands and user docs agree |
| Server rate limiting | Conditional | Standalone unproxied server selected as a product target | Decide whether application limits through `zttp:ratelimit` are insufficient | Approved server policy and accept-path tests, or a recorded decision to retain application limits |
| Computed SQL guards | Deferred | Policy preserves read/write authority | Design that policy distinction before enabling the family | Consumer coverage and sink tests reject cross-authority use; guard drift gate passes |
| Certificate assurance | Open, incremental | Select one property or opcode family | Add a producer case and an independent checker rule or witness | Checker rejects a mutation; `test-proof-ratchet` and `test-proof-ratchet-drift` pass with the revised disclosed boundary |
| Runtime cost fuse | Open product question | The server, the CLI, and the build do not set `cost_ceilings` in `RuntimeConfig`; only tests set it | Decide whether to wire the fuse into the server or to delete it (unit 9g of the [reset plan](plans/2026-10-30-reset-implementation-plan.md)). The code stays until the owner decides | A shipped binary records the incident, or the field and `CostMeter` are deleted; [Verification](verification.md) matches |

Socket health/readiness, in-flight shutdown-drain, and grace-expiry tests exist in
`packages/runtime/src/server.zig`. The HTTP implementation and native helpers
now receive explicit dependencies and no longer import `HandlerInstance`.
Constructor registration and host callback adapters remain in the instance's
composition layer. The delivery plan records the selected boundary and tests.

The residual guard delivery record (`pre-rebase:docs/archive/plans/2026-08-31-1242-feat-residual-runtime-guard-addendum-plan.md`)
is closed for env, egress, and cache. SQL remains deferred in the table above.
CLI and module documentation derive from `zttp help --all` and the typed
bindings exposed through `packages/zts/src/builtin_modules.zig`.
`zttp module-spec-render --check` checks the generated module specifications.

## Agent-Compiler Agenda

[STRATEGY.md](../STRATEGY.md) states the thesis: the set of programs the agent can
write should converge on the set of programs the compiler can prove. This agenda is
the work that closes the gap, ranked by how much it strengthens that claim per unit of
cost rather than by difficulty. Every count in it names the file that owns it, so a
reader recounts instead of trusting a number that rots here.

The ranking follows three legs. The provable set must be true, or convergence to it has
no value. The gap must be measured, or the claim is only prose. The mechanisms that
close the gap should move from rejection toward construction.

The closed agenda records the nine items and their results at
`pre-rebase:docs/archive/plans/2026-08-16-028-agent-compiler-agenda-closed.md`.
Read it before proposing work in this area. Several measurements did not
support the expectations that motivated them. The refusals below still stand.

### Considered and refused

Recorded so they are not proposed again:

- **An SMT-grade counterexample solver.** The solver's triviality is a deliberate design
  choice and no current property needs path-sensitive constraints. Revisit only when a
  property demands it.
- **Replay as a training reward signal.** No training loop exists, and a reward computed
  over a fixed witness set leaks the same way a recorded cassette does. Replay is an
  acceptance check (item 2), not a reward.
- **Auto-applying validator M5.** Contract diff is blind to changes in pure computation,
  and D3 already forbids auto-apply on that basis.
- **Widening the autoloop past solver-backed boolean properties.** The six verdicts
  assume a decidable check; stretching them to fuzzy goals would break rollback
  semantics.

## The Advanced ZTS Language Program

Status: complete for phases 0 through 7. The implemented source identity is
`zts-model-1` for TypeScript.
The [formal spec](zts-formal-spec-northstar-advanced.md), revision 6, states the
language and assurance target. Its stronger target does not mean the shipped
certificate has no tested or trusted edges.

The closed phase record (`pre-rebase:docs/archive/plans/2026-08-16-029-zts-advanced-language-program-closed.md`)
and archived execution plans (`pre-rebase:docs/archive/README.md`) retain the implementation
history. D1, D2, and D3 remain [design references](plans/README.md).
The model-minimal cutover shipped. `|>`, `pipe()`, `guard()`, and
`interface` are removed; no compatibility profile is planned.

The independent checker ships. Further assurance work is in the runtime table
above. The two-client conformance lab remains deferred: it needs an approved
external-client scope. The next action is to define shared accepted and refused
fixtures. Completion requires two independent clients to produce the same
specified protocol outcomes under the same identities.

| Work | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| Exported boundary-type scope | Investigation required | Revalidate the questions in the archived boundary-type plan against current diagnostics | Probe exported constants and generic signatures instantiated with raw scalar types through the public checker | Record accepted or refused behavior for each case; any scope change gets a separate decision and public regression tests |

The boundary-type record (`pre-rebase:docs/archive/plans/2026-08-16-030-boundary-types-plan.md`)
left those questions outside its delivered scope. Current strict-checker tests
already pin refusal of exported function-valued constants through the canonical
declaration rule, rather than ZTS061. That does not settle every exported value
or generic-instantiation case. This is an investigation, not a confirmed bypass.

## Reset And Simplification

The [2026-10-30 reset plan](plans/2026-10-30-reset-implementation-plan.md) is the active reset authority.
The [2026-10-30 reset worklog](plans/2026-10-30-reset-worklog.md) records its execution.
Earlier reset work is complete. Each plan below is a record of its own work, not a second authority.

- Plan 005 Phase 1 ([plan](plans/2026-10-11-feature-removal-phase-1.md)), 2026-10-12. It removed Studio, the demo and proof quest, the edge runtime, the AOT native-handler path, the WASM playground, the Claude and OpenAI providers, the SMT layer, RPC mode, the receipt writers for performance and equivalence, and the provable-reach tooling. Groups G1 to G15 changed no model-visible input. The policy, module registry, and spec hashes equal their baselines. Studio and edge are not part of "Supported Now".
- Plan 005 Phase 2 ([plan](plans/2026-10-12-1109-refactor-feature-removal-phase-two-plan.md)), 2026-10-12. It removed runtime tool routes, agent turns, application invariants, and consumer declarations. New artifacts use payload format 7 and certificate schema 5, and the reader refuses the previous formats.
- Plan 005 Phase 3 ([plan](plans/2026-10-12-1444-refactor-feature-removal-phase-three-plan.md)). It removed orchestration, TSX, source `comptime()`, hypermedia, and the deferred PI tools.
- Shared analysis, 2026-10-11. Single-module coordinators own their analysis. The multi-module phase moved both default graph producers onto completed per-module contract analysis from one owner. Fixed public JSON and generated compiler output match the baseline exactly. Custom callbacks keep their compatibility branch.
- CHECK facts reuse ([plan](plans/2026-10-13-1113-refactor-check-facts-reuse-plan.md)), Phase 4. CHECK keeps its own import traversal, because strict graph reuse would change its verdicts and revision reads. Full convergence between CHECK and compilation is follow-up work.
- Reset of 2026-10-14 ([plan](plans/2026-10-14-reset-implementation-plan.md), [worklog](plans/2026-10-15-reset-worklog.md)). U1 to U20 are complete. The unresolved advisory benchmark result is in the worklog.
- Reset of 2026-10-25 ([plan](plans/2026-10-25-reset-implementation-plan.md), [worklog](plans/2026-10-25-reset-worklog.md)). Complete through R13.

The shared import and binding index shipped. The old parser-deletion estimate is obsolete.
The orchestration move stays declined: no selected consumer needs another `LoweredModule` phase.
The bounded rederive (`pre-rebase:docs/archive/plans/2026-09-20-rederive-implementation-plan.md`) closed the schema-writer, journal-decoding, and recovery-planning work.
The owner accepted the nine decisions of plan 005 on 2026-10-11 with "your recommendations". Reopening a removal needs a product decision and current usage evidence.
Plans that earlier resets archived stay readable at the local tags `pre-rebase`, `pre-round-2-archive`, `pre-round-3-archive`, and `pre-reset-archive-2026-10-25`.

| Work | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| Shared IR shape helpers | Deferred | A concrete new consumer, such as a build cache or incremental compile | Identify the repeated shape operation the consumer needs | A shared helper replaces measured duplication and preserves analyzer behavior |
| Collector role | Measurement required | Reproduce remaining memory growth after the lifetime-arena fix | Attribute retained allocations before selecting any deletion | Repeatable allocation and RSS evidence identifies what grows and whether collection is required |
| VM-loop deduplication | Deferred | Runtime hardening, engine facade, and the existing measurement gates | Revalidate the deferred plan (`pre-rebase:docs/archive/DEFERRED_VM_LOOP_DEDUPE_PLAN.md`) against the selected runtime path | Public behavior preserved and the plan's measurements justify the change |

## Proposal Decisions

| Proposal | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| Custom agent handlers and tool-profile v1 | Retired in Phase 2 after M4 delivery and the M5 stop | New owner decision | None | The M4 and M5 milestone rows preserve the release facts |
| Broader tool platform, confidential hosting, and cloud adapters | Parked | A customer need and an accepted threat model | Evaluate separately from the current handler product | Recorded accept/defer decision and a bounded plan for any accepted work |
| Predictable-performance advisory plan (`pre-rebase:advisor-plans/001-tigerbeetle-inspired-predictable-performance-plan.md`) | Proposed; old baseline | Fresh process-level measurements | Revalidate the measurement unit before any optimization | Retained receipts identify a current bottleneck and justify a selected change |

The proposal index (`pre-rebase:docs/zttp-next/README.md`) and
[advisory index](../advisor-plans/README.md) hold the supporting documents.
Their presence does not schedule them.
