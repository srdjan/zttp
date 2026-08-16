# Roadmap

The one forward-looking document in the maintained docs. It records the current
support boundary, what the implementation does not cover, and the work that is
planned but not built. Shipped changes live in `../CHANGELOG.md`; current user
behavior lives in [User Guide](user-guide.md).

## Supported Now

- macOS and Linux on x86_64 and aarch64.
- Zig `0.16.0` as declared by `build.zig.zon`.
- Threaded HTTP/1.1 server with per-request runtime isolation and decoded
  `Content-Length` or `Transfer-Encoding: chunked` request bodies.
- Restricted TypeScript and TSX handler execution through `zts`.
- The five core `zttp` commands: `init`, `dev`, `test`, `expert`, `deploy`.
- Local self-contained deploy artifacts with default-on attestation.
- Compile-time checks for response paths, Result and optional handling,
  state isolation, active specs, flow properties, contracts, and module policy.
- Built-in `zttp:*` virtual modules listed in
  [Virtual Modules](virtual-modules/README.md).
- Optional Studio and edge runtime builds via `-Dstudio` and `-Dedge`.

## Current Limitations

- Hosted cloud deploy is not part of the current CLI surface. `deploy` builds a
  local binary, `deploy --cloud` parses and rejects with a "not available in
  this beta" message, and the account verbs (`login`, `logout`, `review`,
  `grants`, `revoke-grant`) are not dispatched at all.
- The runtime uses the threaded HTTP server path. The evented `std.Io`
  networking path is not a supported request backend.
- Handlers receive raw `multipart/form-data` bodies from the HTTP server. Use
  `decodeFormMultipart` from `zttp:decode` or handler-owned parsing when a
  handler accepts multipart input.
- There is no scrape-able `/metrics` endpoint. `/_health` and `/_readiness`
  return bare status codes.
- Windows is not supported.

## Runtime And Product Work

- Close the remaining runtime lifecycle verification gaps before hosted deploy
  claims: broader accept-path coverage for deadlines, graceful shutdown, probes,
  and panic isolation; hosted request-timeout policy; and shutdown
  thread-safety semantics.
- Finish the engine-to-runtime boundary refactor by routing runtime calls
  through a strict facade and exposing stable runtime-facing engine types. The
  file split landed (`handler_instance.zig` owns `HandlerInstance`;
  `zruntime_tests.zig` is the test root), but six import cycles remain between
  the instance and the sibling files its methods moved into.
- Keep near-term module work limited to table-stakes gaps: fetch resilience,
  capability surfacing, and build-feature diagnostics. Cloud-adapter modules
  stay in a separate evaluated track.
- Keep `zttp help --all` and `packages/zts/src/builtin_modules.zig` as the
  sources of truth for CLI and module docs. `packages/modules/module-specs/` is
  not one of them: it is generated from the typed Zig module bindings by
  `zttp module-spec-render`, and `--check` gates it in `scripts/verify.sh`. Edit
  the binding, then regenerate.
- Add server-level rate limiting only if the standalone server becomes a
  first-class unproxied deployment target. Application limits are handled with
  `zttp:ratelimit`.
- Promote hosted deploy only after the control-plane path has CI smoke coverage
  and user-facing commands appear in default docs.

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

Implement the advanced language incrementally on the existing engine, keeping
`scripts/verify.sh` green at every phase boundary. The implemented source
identities are `zts-model-1` for core `.ts` and `zts-tsx-1` for the lowering
frontend. The source
spec is [zts-formal-spec-northstar-advanced.md](zts-formal-spec-northstar-advanced.md)
revision 5. The certificate and verifier stack (spec 13.3-13.4) and the
two-client conformance lab (14.2) are outside this program.

Three ground rules survive from phase to phase: the engine stays
interpreter-only with no kernel growth except where the spec names it; each
admitted form adds its semantics-registry rules in the same phase, so
`spec-check` stays green by construction; and no `meta` payload is ever
hand-written, because a hand-written payload is another drift gate.

Phases 0 through 7 are done. What each phase found is
[the closed phase record](archive/plans/2026-08-16-029-zts-advanced-language-program-closed.md),
and the executed plans and the program's decision log are in
[docs/archive/plans/](archive/README.md). Phase 2's plan is still
[docs/plans/2026-08-04-018-zts-advanced-rev4-phase2-plan.md](plans/2026-08-04-018-zts-advanced-rev4-phase2-plan.md),
phase 3's is
[docs/plans/2026-08-09-022-zts-advanced-rev4-phase3-plan.md](plans/2026-08-09-022-zts-advanced-rev4-phase3-plan.md),
and phase 4's is
[docs/plans/2026-08-09-023-zts-advanced-rev4-phase4-plan.md](plans/2026-08-09-023-zts-advanced-rev4-phase4-plan.md).

Three design documents own the decisions the phases consume. Two of them also
retire an interim marker left in the code by phase 0:

- [D1 type system](plans/2026-07-30-014-d1-type-system-design.md) - assignability,
  generic inference, narrowing dataflow, join and union normalization, canonical
  type serialization. Unblocks phases 2, 3, and 4; retired `// D1-interim`, and
  no marker of that name is left in the tree.
- [D2 effects and purity](plans/2026-07-30-015-d2-effects-purity-design.md) -
  the effect-row atom set and its capability mapping, row inference and join, the
  purity predicate, and `Proof<T, P>`'s property domain. Unblocks phases 4 and 5;
  retires `// D2-interim`.
- [D3 canonical form and wire](plans/2026-07-30-016-d3-canonical-form-wire-design.md) -
  the lexical grammar, the canonical formatter, digest pre-images, protocol
  payload schemas, and the equivalence-validator taxonomy. Unblocks phase 6.

The no-ASI flip landed in phase 6 and did not wait on a validator: the corpus
needed no migration, so a statement with no terminator is refused with ZTS047
and a location, and the repair that shipped beside it was withdrawn when a
review found it unsound. The migration policy is now decided: phase 7 performs
a direct cutover to the model-minimal profile. `|>`, `pipe()`, `guard()`, and
`interface` are removed; no compatibility profile is planned.

## Reset And Simplification

The reset ledger is
[2026-07-28-001-reset-simplification-plan.md](plans/2026-07-28-001-reset-simplification-plan.md).
Waves 0 through 3 and wave 6 are executed, and waves 4 and 5 are done except
for three items:

- Shared IR shape helpers (wave 4, item 4). The shared import and binding index
  shipped as `packages/zts/src/module_facts.zig` and all six analyzers adopted
  it. The shape-helper library is deferred, and the orchestration move is closed
  as declined: it had an architectural justification and no performance or
  correctness one, and it needed an IO boundary inside `pipeline.zig` that does
  not exist. Revisit only with a concrete consumer for a fourth `LoweredModule`
  phase, such as a build cache or incremental compile.
- The collector's role (wave 5, item 3). Inverted by the wave 0 RSS
  measurement. The memory defect it started from was found, fixed, and closed by
  a two-hour soak (per-runtime lifetime arena), but what the collector still
  earns has not been measured. No GC code is deleted until the remaining growth
  is attributed.
- `comptime.zig` unification (wave 5, item 4). Replacing its separate tokenizer,
  parser, and value model with evaluation over the main IR after parse would
  delete roughly 1,800 lines and structurally resolve the `==` inconsistency. It
  needs more comptime tests first.

VM-loop dedupe stays deferred behind the FaaS hardening, engine facade, and
measurement gates. The standalone plan is
[Deferred VM Loop Dedupe Plan](archive/DEFERRED_VM_LOOP_DEDUPE_PLAN.md).
