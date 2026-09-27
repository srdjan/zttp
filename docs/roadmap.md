# Roadmap

This document owns work status and scheduling. Reviewed against local `main`
at `a0181c16` on 2026-09-21. Shipped changes live in
[CHANGELOG.md](../CHANGELOG.md); current behavior lives in the
[User Guide](user-guide.md). The [plan index](plans/README.md) separates open
work from reference designs. [Product proposals](zttp-next/README.md) and
[advisory plans](../advisor-plans/README.md) require a decision before execution.

## Milestones

M1, M2, and M3 are complete.
M4 is complete: T1a to T7 are delivered. M5 has a proposed release contract. No release date is assigned.

| Milestone | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| M1: accurate active backlog | Complete, 2026-09-21 | Codebase review at `1b0686a1` | Select the next milestone | [Completion record](archive/plans/2026-09-21-active-backlog-cleanup.md); documentation gates pass and remaining work is classified |
| M2: bounded correctness and assurance | Complete, 2026-09-22 | Three implementation units committed and reviewed; affected suites and mutation probes pass | Select the next milestone | [Completion record](archive/plans/2026-09-21-bounded-correctness-assurance.md); full local gate passed at `181d31d4`; public response regression test; selected lifecycle and decoder cases reject deliberate wrong behavior; affected unfiltered suites pass |
| M3: provable-set reach measurement | Complete, 2026-09-21 | Current DeepSeek default; pilot and full run authorized | Keep the used suite as regression evidence; select a new suite before a new holdout claim | [Full fresh report](provable-reach.md#first-full-measurement): 8/8 reached, 4/4 in each mode, with all selected tasks and source, policy, model, budget, and runtime evidence retained |
| M4: next release boundary | Contract accepted 2026-09-22; T1a to T7 complete | M1 proposal inventory and current strategy | Delivered T1a to T7 of the [release contract](plans/2026-09-22-m4-release-contract.md) in order | One accepted release contract states scope, threat model, dependencies, and completion checks |
| M5: agent handlers | Proposed 2026-09-27; owner answered the four scope questions | M4 complete | Owner accepts the [release contract](plans/2026-09-27-m5-agent-handler-release-contract.md), then A1 design note | M5a: a buffered agent route passes checks C-A1 to C-A6; M5b then adds streaming |

M2's source evidence is `packages/zts/src/http.zig`,
`packages/runtime/src/server_response.zig`, and the conditional test gaps in
the [completed rederive record](archive/plans/2026-09-20-rederive-implementation-plan.md#conditional-discovery-items).
M3 establishes bounded reach for the frozen suite in [STRATEGY.md](../STRATEGY.md#key-metrics).
M4 compares the [agent-handler specification](plans/2026-09-19-feat-agent-handler-spec.md)
with the [tool-profile recommendation](zttp-next/zttp-v1.0-scope-and-v1x-roadmap.md).

## Supported Now

- macOS and Linux on x86_64 and aarch64.
- Zig `0.16.0` as declared by `build.zig.zon`.
- Threaded HTTP/1.1 server with per-request runtime isolation and decoded
  `Content-Length` or `Transfer-Encoding: chunked` request bodies.
- Restricted TypeScript and TSX handler execution through `zts`.
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
- Optional Studio and edge runtime builds via `-Dstudio` and `-Dedge`.
- Consumer-checked residual guards for computed environment keys, egress
  endpoints, and cache namespaces under an explicit capability policy.
- Protected local ledger invariants: mandatory balance conservation and
  optional declared-account matching, with independently checked coverage.

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
- The production certificate honestly reaches a `trusted` weakest edge today.
  The consumer re-derives `response_total`, but bytecode opcode meaning remains
  declared trusted, while `results_checked`, `no_secret_leakage`, and
  `capability_bounded` enter at `tested`. See
  [Verification](verification.md#what-is-not-checked-said-out-loud).
- Computed SQL resources remain refused. The configured SQL policy cannot
  distinguish read from write authority. Other residual-guard limits are in
  [Verification](verification.md#residual-runtime-guard-boundary).

## Runtime And Product Work

These items remain open. They are not all release blockers. A selected release
contract must identify which ones it needs.

| Work | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| Runtime lifecycle | Open; M2 grace-expiry coverage added | Current socket and panic-isolation tests | Check request-timeout policy and control-thread shutdown semantics against the intended deployment | Tests assert accepted requests, drain and expiry outcomes, and isolation; unfiltered runtime and panic suites pass |
| Engine/runtime facade | Deferred | Lifecycle behavior pinned before changing state ownership | Replace one sibling back-import with a narrow interface | Selected cycle removed; request, durable, queue, and pool behavior preserved; boundary and runtime gates pass |
| Module gaps | Needs scope | A concrete handler requirement | Identify a missing fetch-resilience, capability, or build-feature diagnostic case | Public example and regression test demonstrate the selected behavior |
| Hosted deploy | Deferred | Accepted hosted scope, lifecycle policy, and control-plane CI | Define a supported end-to-end deployment flow | CI exercises the control plane; released commands and user docs agree |
| Server rate limiting | Conditional | Standalone unproxied server selected as a product target | Decide whether application limits through `zttp:ratelimit` are insufficient | Approved server policy and accept-path tests, or a recorded decision to retain application limits |
| Computed SQL guards | Deferred | Policy preserves read/write authority | Design that policy distinction before enabling the family | Consumer coverage and sink tests reject cross-authority use; guard drift gate passes |
| Certificate assurance | Open, incremental | Select one property or opcode family | Add a producer case and an independent checker rule or witness | Checker rejects a mutation; `test-proof-ratchet` and `test-proof-ratchet-drift` pass with the revised disclosed boundary |
| Protected-ledger startup cost | Measurement required | Representative ledger and pool sizes; current store exclusion rules | Measure repeated baseline validation and statement preparation before changing ownership | Retained startup and contention measurements justify statement reuse or validation per generation; invariant behavior remains unchanged |

Socket health/readiness, in-flight shutdown-drain, and grace-expiry tests exist in
`packages/runtime/src/server.zig`. The file split and server adapter also
exist, but `HandlerInstance` and extracted siblings still import each other.
The remaining facade work concerns that dependency boundary.

The [residual guard delivery record](archive/plans/2026-08-31-1242-feat-residual-runtime-guard-addendum-plan.md)
is closed for env, egress, and cache. SQL remains deferred in the table above.
CLI and module documentation derive from `zttp help --all` and the typed
bindings exposed through `packages/zts/src/builtin_modules.zig`.
`zttp module-spec-render --check` checks the generated module specifications.
The [ledger foundation record](archive/plans/2026-09-18-feat-application-invariants-plan.md)
describes the startup measurement question. General predicates, distributed
ledger stores, currency conversion, and automatic migration remain outside
the supported invariant scope.

## Agent-Compiler Agenda

[STRATEGY.md](../STRATEGY.md) states the thesis: the set of programs the agent can
write should converge on the set of programs the compiler can prove. This agenda is
the work that closes the gap, ranked by how much it strengthens that claim per unit of
cost rather than by difficulty. Every count in it names the file that owns it, so a
reader recounts instead of trusting a number that rots here.

The ranking follows three legs. The provable set must be true, or convergence to it has
no value. The gap must be measured, or the claim is only prose. The mechanisms that
close the gap should move from rejection toward construction.

Eight of the nine items are closed, and what each one found is
[the closed agenda](archive/plans/2026-08-16-028-agent-compiler-agenda-closed.md).
Read it before proposing work in this area: several items record a measurement that
did not support the expectation the item was written on. One item is still open, and
the refusals below stand.

### 5. The small-local-model qualification evidence

Status: parked measurement. Dependency: explicit authorization for the live
runs and exact model and serving provenance. Next action: follow the recording
guide with the selected candidate. Completion: retain the three-run report
under the criteria below. A default-provider change needs a separate decision.

The report-only qualification path is implemented. What remains is an explicitly
authorized three-run measurement of `mlx-community/Qwen3-8B-4bit`. Each run attempts
all 19 cases and reports raw first-draft pass, final green, round trips, runtime intent,
typed failures, latency, peak memory, and exact model and serving provenance under the
same identities as the hosted headline.

Why: the narrow grammar is the stated reason a small model might be enough, and that is
currently an argument rather than a result. If a small model reaches the same green
state with more retries, the fence carries the intelligence rather than the model, which
is the thesis demonstrated rather than asserted. If it fails, that is also information:
it makes item 3 required rather than optional, because per-hole fill is the known way to
shrink a task to small-model size.

The dedicated local provider now covers the supported local-model path with MLX-LM
Chat Completions. The OpenAI provider remains available for registered OpenAI models,
and `ZTS_OPENAI_BASE_URL` may redirect its Responses API transport without changing
provider or model identity. Model selection stays explicit through `--model`; the old
off-registry `ZTS_OPENAI_MODEL` override is rejected.

To run the supported local qualification, supply the exact artifact and serving
provenance described in [the recording guide](internals/cassette-recording.md), then:

```bash
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --host 127.0.0.1 --port 8080
ZTTP_CODEGEN_QUALIFY_CONFIRM=1 \
  ZTTP_CODEGEN_PROVIDER=local \
  ZTTP_CODEGEN_MODEL=mlx-community/Qwen3-8B-4bit \
  bash scripts/qualify-expert.sh > /tmp/qwen3-8b-4bit-qualification.json
```

The wrapper requires three comparable clean-source runs. Every run must reach 19/19
final green, 18/18 runtime intent, at least 14/19 raw first-draft passes, median round
trips no higher than four, and zero empty, timeout, decode, provider, or internal
failures. It never promotes a candidate corpus and always reports
`default_change_authorized: false`. LFM remains the local-provider default and DeepSeek
remains the product default unless a later product decision changes one explicitly.

Historical baseline from 2026-08-14: the local LFM corpus holds 16 of 19 cases and is parked until a
more capable local model replaces LiquidAI/LFM2.5-2.6B-MLX-8bit. The three missing cases
are model failures rather than harness failures: `durable-order`, `workflow-wait-signal`,
and `cache-counter-holes` all end in `EmptyResponse`.

Three budgets were measured against them and none is what blocks. A raised per-turn wall
clock does not recover them: `ZTTP_CODEGEN_TURN_TIMEOUT_MS=600000` recovered four other
cases that the 180s default had cut off, and these failed the same way with the longer
ceiling. A raised roundtrip and tool-call budget does not recover them either. Raising
`loop.RunOptions` from 18/16 to 44/40 converted none of the five budget-bound cases to
green and made recording less reliable, because a longer turn is more exposure to an
empty or truncated response. The five cases that pinned at 18 roundtrips had all also hit
`max_tool_calls_per_turn = 16`, and `loop.zig:665` lets a turn continue past that budget
with every further tool batch refused, so the roundtrip cap is where those turns stop
rather than what ends them. Every completed run reports `retries=4` against
`interactive_max_attempts = 5`, so verification attempts bind once the budgets do not.

The serving stack is the one thing that did move a case. It changed to rapid-mlx 0.12.11
on 2026-08-14, and with `--enable-auto-tool-choice --tool-call-parser lfm` it recovered
`workflow-queued-call`, which had failed three times before. The old server was running
with no tool-call parser, so LFM2's native `[fn(arg='x')]` calls arrived as prose and the
agent loop saw nothing to run. The other three then reached 13 to 17 model calls against
10 to 12 before, and still ended in `EmptyResponse`. Failing identically on both stacks is
what makes them a model limit rather than a serving one.

Do not spend further time on parser permutations. `--tool-call-parser auto` resolves to
the same parser as `lfm`, and both rewrite the assistant's text: a probe offering only
`read_file` and asking for prose containing `[totally_unknown_tool(x='1')]` came back with
that fragment cut out of `content` and emitted as a real tool call for a function never
offered. A reply that is entirely call-shaped therefore arrives with `content: ""`, which
is the `EmptyResponse` above. Without a parser the server emits no `tool_calls` at all, so
neither setting is safe by default, and any cassette recorded on this stack is provisional
until the parser stops editing prose.

rapid-mlx sends no `system_fingerprint` and serves no version endpoint, so a recording
declares its stack with `ZTTP_CODEGEN_LOCAL_RUNTIME=rapid-mlx@0.12.11`, and the manifest
carries `runtime_name` and `runtime_version` where an MLX-LM recording carries
`mlx_lm_version`. A local manifest that names its stack by neither route is refused.

Nothing blocks while this is parked. The replay falls back to `headline_provider`, which
derives from `models.default_provider` and is `.deepseek` since 2026-08-14, so
`zig build test`, `zig build test-expert-app`, `scripts/verify.sh`,
`scripts/update-convergence.sh`, and `scripts/update-coverage.sh` all replay the 19-case
DeepSeek corpus and never read the local one. The local corpus fails only under an
explicit `ZTTP_CODEGEN_REPLAY_PROVIDER=local`, with `MissingCodegenCassette`.

Leave that a hard failure. Do not make the replay skip the missing cases to get it green.
The three absentees are exactly the cases the model cannot finish, so a rate computed over
the surviving 16 reads higher than the truth and hides the failure mode. This is the
inverse of the gate rule in AGENTS.md about a gate that counts nothing still reporting a
pass. There is no local first-draft or green number in existence today, because the replay
aborts before it computes one, so completing all 19 is the precondition for publishing a
local row at all.

When a better local model lands, qualify it on all 19 cases rather than patching the
three missing LFM cases. Replace the committed local corpus only after a separate
decision to publish that model's row. Every manifest pins the model revision and the
stack that served it, so a model swap supersedes all 16 historical cassettes.

Observable: one retained three-run qualification report per candidate. A dated
published row follows only when that candidate is deliberately promoted into a
committed corpus.

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

Status: complete for phases 0 through 7. The implemented source identities are
`zts-model-1` for core TypeScript and `zts-tsx-1` for the lowering frontend.
The [formal spec](zts-formal-spec-northstar-advanced.md), revision 6, states the
language and assurance target. Its stronger target does not mean the shipped
certificate has no tested or trusted edges.

The [closed phase record](archive/plans/2026-08-16-029-zts-advanced-language-program-closed.md)
and [archived execution plans](archive/README.md) retain the implementation
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

The [boundary-type record](archive/plans/2026-08-16-030-boundary-types-plan.md)
left those questions outside its delivered scope. Current strict-checker tests
already pin refusal of exported function-valued constants through the canonical
declaration rule, rather than ZTS061. That does not settle every exported value
or generic-instantiation case. This is an investigation, not a confirmed bypass.

## Reset And Simplification

The [reset ledger](archive/plans/2026-07-28-001-reset-simplification-plan.md) is historical.
The shared import/binding index and compile-time parser reuse shipped. The
compile-time evaluator uses `JsParser.initExpression` and the main IR; its
separate value/evaluation model remains. The old parser-deletion estimate is
obsolete. No further evaluator rewrite is selected.

| Work | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| Shared IR shape helpers | Deferred | A concrete new consumer, such as a build cache or incremental compile | Identify the repeated shape operation the consumer needs | A shared helper replaces measured duplication and preserves analyzer behavior |
| Collector role | Measurement required | Reproduce remaining memory growth after the lifetime-arena fix | Attribute retained allocations before selecting any deletion | Repeatable allocation and RSS evidence identifies what grows and whether collection is required |
| Compile-time value/evaluation unification | Deferred | New evidence of a behavior or maintenance problem | Measure the remaining evaluator overlap and pin public behavior | Accepted scope with measured benefit and equivalent public results, or a decision to keep the separate evaluator |
| VM-loop deduplication | Deferred | Runtime hardening, engine facade, and the existing measurement gates | Revalidate the [deferred plan](archive/DEFERRED_VM_LOOP_DEDUPE_PLAN.md) against the selected runtime path | Public behavior preserved and the plan's measurements justify the change |

The reset's orchestration move remains declined. It has no selected consumer
for another `LoweredModule` phase and no measured correctness or performance
benefit. The [bounded rederive](archive/plans/2026-09-20-rederive-implementation-plan.md)
closed the selected schema-writer, journal-decoding, and recovery-planning work.

The reset ledger's owner-decision and retention sections are historical
suggestions. Their default remains to keep the capabilities still present.
No removal of extension support, edge, demo, Studio views, proof commands,
receipt signing, expectation inputs, providers, module governance, code
generation, or the separate analyzer is selected. Reopening a removal requires
a product decision and current usage evidence.

## Proposal Decisions

| Proposal | Status | Dependency | Next action | Completion evidence |
|---|---|---|---|---|
| Custom agent handlers and tool-profile v1 | Reconciled: M4 delivered the tool profile; M5 resumes agent handlers | M5 contract acceptance | See the M5 row | One accepted contract and reconciled implementation scope, or an explicit deferral |
| Broader tool platform, confidential hosting, and cloud adapters | Parked | A customer need and an accepted threat model | Evaluate separately from the current handler product | Recorded accept/defer decision and a bounded plan for any accepted work |
| Predictable-performance advisory plan | Proposed; old baseline | Fresh process-level measurements | Revalidate the measurement unit before any optimization | Retained receipts identify a current bottleneck and justify a selected change |
| [Consumer contract v1](consumer-contract.md) | Proposed | A consumer that commits to lowering into the declaration | Decide whether to accept producer obligations P1 to P14, starting with the published vocabulary envelope and its drift gate | The envelope exists, a gate compares a source-derived inventory against it for equality and fails on a missing or empty input, and one consumer's declaration reaches an admissibility answer |

The [proposal index](zttp-next/README.md), [agent-handler specification](plans/2026-09-19-feat-agent-handler-spec.md),
and [advisory index](../advisor-plans/README.md) hold the supporting documents.
Their presence does not schedule them.
