# Remove the features that do not carry the agent-compiler

## Status

DECISIONS ACCEPTED 2026-10-11. The owner answered "your recommendations", which selects the recommended option of all nine decisions.
Decision 3 therefore stops M5: agent handlers are not the next product.
Decision 7 keeps `zts agent --stdin-json` with its determinism gate and module graph operation, and cuts RPC mode.
The DeepSeek re-record in Phase 3 still needs a separate authorization.
The tag `pre-rebase` marks `b33cac5c`, the full feature set before any removal.
Phase 1 executes from `docs/plans/2026-10-11-feature-removal-phase-1.md`. That plan corrects several file lists below and moves every model-visible tool removal to Phase 3, because the tool catalog is part of the frozen replay identity.
Phase 1 is complete. The owner selected Phase 2 execution through Decision 10 on 2026-10-12.
The implementation plan is `docs/plans/2026-10-12-1109-refactor-feature-removal-phase-two-plan.md`.
It corrects the Phase 2 sequence: runtime authority and artifact sections leave first; model-visible ledger and tool exports wait for Phase 3.
Certificate schema 4 becomes 5 alongside payload format 6 becoming 7. The eight handler properties and residual guards remain.
Decision 11 confirms retained compiler exports until Phase 3. Combined phases and DeepSeek recording remain outside this execution.
Phase 2 is complete on 2026-10-12. The worklog records removals, format boundaries, offline checks, and review limits.
The full verification script passes. Compiler identities remain unchanged, and all nineteen authoring cases replay offline.

Plan 003 kept every documented feature and changed only internal compiler boundaries.
This proposal is different: the owner asked which features can go.
It removes product surface first, so that plan 003's internal work runs on a smaller tree.

## Recommendation

Remove the surfaces outside the agent-compiler spine in three phases.
Phase 1 changes no language rule, no certificate byte, and no corpus identity.
Phase 2 removes three kernel-checked payload sections in one format bump.
Phase 3 removes orchestration, system linking, TSX, comptime, and hypermedia, then re-records the corpus once.
Before Phase 1, tag the current state so that every removed feature stays recoverable from one ref.

Whole files measured in the removal groups below total about 156,000 physical lines.
That count has 42,600 lines of Phase 1 code and scripts, 48,300 lines of documents, and 22,500 lines of frozen fixtures.
It also has 22,900 lines in Phase 2 and 20,100 lines in Phase 3.
For comparison, `packages/` holds 442,720 Zig lines.
The count excludes regions inside shared files, such as `server.zig`, `contract_builder.zig`, `precompile.zig`, `checker.zig`, and `live_reload.zig`.
Those regions need measurement during execution.
A whole-file count is a measured scope. It is not a guaranteed deletion total, because some files need small replacements.

## Evidence and method

Two reviewers read the repository at `b33cac5c`. Both were read-only.
A Fable subagent argued which subsystems earn a place.
Codex `gpt-6-astra` measured reachability, dead code, duplicates, and the gate apparatus with file citations.
The root session checked the load-bearing claims in source and measured each removal group with `wc -l` over the exact file lists.
The full reports are session scratch files. This document restates every finding that it uses.

The root session confirmed these claims:

- Interactive `zttp demo` passes `--studio` (`packages/runtime/src/demo_command.zig:139`). The default build rejects that flag (`runtime_cli.zig:351`). The demo is therefore broken in a default build.
- `demo.zig:3` imports `pi_app`. The demo is why the runtime module graph reaches the agent.
- No caller runs `initSymbol` or `initWeakCollections` (`packages/zts/src/builtins/root.zig:57-58`).
- No tracked file links to `docs/investor-precise.html`, `docs/investor-warm.html`, or the 14,722-line architecture HTML.
- `packages/runtime/src/invariant_cli.zig:21-22` sends an advisory request to `https://api.typesafe.ai/v1/systemone` when `TYPESAFE_API_KEY` is set. CLAUDE.md permits DeepSeek and a local MLX server only.
- The acceptance kernel (`packages/proof-checker/src`) has zero mentions of durable, workflow, or queue. The runtime acts on durable-workflow properties that come from the producer contract (`contract_runtime.zig:1142`), not from a kernel re-derivation.
- `extension_bindings.all` is an empty array (`packages/zts/src/extension_bindings.zig:3`).
- The optional native AOT path exists. `handler_instance.zig:1581` runs a native handler before the interpreter when `-Daot` built one. CLAUDE.md says "The interpreter is the single execution path". That sentence is wrong while AOT exists.

The root session corrected three reviewer claims:

- AOT risk. Fable rated the AOT cut as low risk. That rating is wrong. Contract building calls `analyzeAot` for route extraction even when AOT is off (`packages/tools/src/precompile.zig:3429`). `analyzeAot` is the `HandlerAnalyzer` dispatch pass, not the transpiler. The cut removes `transpiler.zig` and the runtime hook and keeps the analysis under a neutral name.
- Corpus counts. Fable said 7 of 19 DeepSeek cases import `zttp:durable`. The measured counts are 5 for `zttp:durable`, 3 for `zttp:workflow`, and 1 for `zttp:io`. The conclusion stands: 6 cases depend on orchestration (`durable-order`, the four `workflow-*` cases, and `parallel-secret`).
- Shared runtime files. Fable listed `fetch_deadline.zig` and `outbound_io.zig` with tool routes. `runtime_http.zig` and `handler_instance.zig` also import them, so they stay.

Codex also found that several apparent duplicates are real sharing.
`stripper.zig` and `transpiler.zig` do different jobs.
`canonicalize` and `normalize` already share `canonicalize.zig`.
`prove`, `prove-behavior`, and `proofs gate` share `contract_diff.zig`.
`verify <url>` and `proofs verify` make different trust claims.
Removing a command adapter over a shared engine saves little code. The engines stay.

## The spine that stays

The spine is one path.
A developer gives `zttp expert` a goal.
The model drafts inside the compiler fence, and the veto simulates every draft.
The compiler repairs or refuses.
The applied handler compiles to an artifact with a certificate.
The independent kernel accepts the artifact, and the runtime serves only accepted artifacts.

These parts stay: the `zts-model-1` language over `.ts`, the analyzer and its flow, fault, and contract passes, the interpreter and engine, twenty virtual modules, the DeepSeek and local providers, the stand-in and defect seeds, the 13 surviving corpus cases, the eight handler properties in the kernel with residual guards, attestation, certificates, `proofs bundle`, `proofs verify`, `proofs gate`, `verify <url>`, and the three binaries.
Sound mode stays because it is part of the fence.
The diagnostic corpus, the flow census, the proof-swallow gate, the module-boundary gate, and step coverage stay.

## Phase 1: cuts that move no identity

Each group is one commit. Run `bash scripts/verify.sh` after each group, with a private `ZIG_LOCAL_CACHE_DIR`.
Each commit deletes the group's dedicated tests, build steps, gate rows, allowlist rows, help text, and docs-drift sections.

| Group | What goes | Whole-file lines | What a user loses |
|---|---|---:|---|
| 1a | Studio, demo, proof quest, tour, keystroke input, demo passport, edge runtime, `-Dstudio`, `-Dedge` | 5,878 | Browser workbench, guided demo, multi-handler edge listener. Two of these are compiled out by default. |
| 1b | AOT transpiler, `-Daot`, the runtime AOT hook; unused Symbol and WeakMap builtins; three trivial scripts | 3,301 | A second execution path that nothing measures. Keep `analyzeAot` as route analysis. |
| 1c | `prove`, `prove-behavior`, `prove-upgrade` merged into one `diff` command; `review-patch` merged into `edit-simulate`; `proof` alias, capsules, audit ring; `gate-report` and gate records; `witnesses` CLI and on-disk corpus; `ratchet show`; `zts-training-export`; module manifests and `extension-status`; `mock` | 9,003 | Several command spellings, a capsule format, a witness file manager, and features with no consumer. Counterexample generation and replay stay. |
| 1d | Build options for external generators: `-Dmanifest`, `-Dexpect-properties`, `-Dgenerator-pack`, `-Dfault-severity`, `-Dreport`, `-Dopenapi`, `-Dsdk`, `-Dreplay`, `-Dtest-file`, `-Dprove`, `-Dgenerate-tests` | 3,495 | OpenAPI output, a generated TypeScript client, and build-time test runs. No example, script, or workflow passes these options. |
| 1e | Perf receipts, equivalence receipts, instruction counter | 1,762 | Signed laptop latency and equivalence receipts on each edit. |
| 1f | Expert qualification, provable-reach tooling, the three Python scripts, the evidence-marker gate | 4,845 | Two parked or completed measurement programs. Keep `docs/provable-reach.md` as the record of the 8/8 result. |
| 1g | Agent memory store, remember and recall tools, `zig_build_step` and `zig_test_step` tools | 1,122 | Cross-session facts and an `execute_process` escape that the strategy refuses. |
| 1h | SMT solver, semantics audit, render, and corpus, the `spec-*` commands, z3 in CI | 1,737 | SMT refinement of the registry. `semantics.zig` stays as the identity source. |
| 1i | WASM analyzer and publisher, browser language and expert overviews, Node browser test | 5,926 | The in-browser playground. Move it to the website repository if wanted. |
| 1j | Module graph record, agent determinism script, RPC mode | 2,224 | An unclaimed integration surface. See decision 7. |
| 1k | Investor HTML, architecture HTML export, explainer HTML, essay, advisory plans 001 and 002 | 17,821 | Marketing and visual exports with no inbound link. |
| 1l | `docs/archive/` and `docs/zttp-next/` | 30,464 | In-checkout history. Git history and the tag keep it. |
| 1m | Claude and OpenAI provider code, credentials, and selection | 3,289 | `--provider claude` and `--provider openai`, which CLAUDE.md already forbids. |
| 1n | Frozen Claude corpus and provider fixtures | 22,494 | The pre-cutover baseline, which nothing may re-record. |

Order constraints inside Phase 1:

- 1a removes demo consumers before Studio, because each imports the other.
- 1m moves `anthropic/propose_change_set.zig` and `anthropic/tools_schema.zig` to a neutral directory first. DeepSeek and local import them.
- 1m ports the stand-in from the OpenAI wire (`packages/pi/src/standin/server.zig:1`) to the chat-completions wire before the OpenAI parsers go.
- 1n re-records the recorder transport fixture on a surviving wire before it deletes the Anthropic fixture (`docs/coverage.md:22`).
- 1b and 1d edit `precompile.zig`. They wait until the active plan 004 unit lands. See decision 9.
- After the last group, reduce `docs/plans/` to open plans, and fold `sound-mode.md` into `typescript.md`.

## Phase 2: one payload format bump

Three kernel-checked sections leave together, and `self_extract.zig` moves from format 6 to format 7.
An old artifact then refuses to start, which is the documented behavior for a format mismatch (`self_extract.zig:17-22`).

| Group | What goes | Whole-file lines | Proof effect |
|---|---|---:|---|
| 2a | Tool routes, tool catalog (section 9), credential injection, agent turns and recorder, SSE, `examples/tools/` | 8,674 | Removes a kernel section. Ends the active M5 milestone. See decision 3. |
| 2b | Application invariants (section 8), `zttp:ledger`, the 3,573-line invariant drift gate, `zttp invariant`, the TypeSafe classifier | 9,407 | Removes one verdict family. The eight handler properties do not change. |
| 2c | Consumer declaration (section 10), vocabulary envelope, `docs/consumer-contract.md` | 4,841 | Removes a consumer obligation for a consumer that has not committed. |

Phase 2 updates `executable_graph.zig`, `verdict.zig`, `checker.zig`, `proof_ratchet.zig`, `check-proof-ratchet.sh`, and `check-residual-guards.sh`.
Required checks: `test-proof-checker`, `test-proof-checker-mutants`, `test-proof-ratchet`, `test-proof-ratchet-drift`, `test-residual-guards-drift`, `test-cli`, `test-zruntime`, and `bash scripts/verify.sh`.

## Phase 3: one language change and one re-record

| Group | What goes | Whole-file lines |
|---|---|---:|
| 3a | `zttp:durable`, `zttp:workflow`, `zttp:queue`, `zttp:scope`, `zttp:io`, the durable runtime, dead-letter and dead-run CLIs, saga and fan-out extraction | 11,212 |
| 3b | System linking, rollout, `zttp:service`, in-process dispatch | 6,079 |
| 3c | TSX frontend and `comptime()` | 2,844 |
| 3d | Hypermedia `resource()` affordances and the `htmx` template | Regions only; needs measurement |

Registry hashes change once. `policy-hash.txt`, `restrictions-to-proofs.md`, the contract goldens, and the diagnostic corpus update once.
The six orchestration cases leave the corpus. The 13 remaining cases are re-recorded against DeepSeek at `ZTTP_CODEGEN_TURN_TIMEOUT_MS=600000` and must replay 13/13 offline.
Convergence and then coverage are published in that order.
This phase spends DeepSeek time and needs the owner's authorization.
3b removes the `type_checker.zig:1299` import of the linker before it deletes the linker.

## Phase 4: resume plan 003 on the smaller tree

Recount the repository. Then continue plan 003's shared analysis and typed frontend work.
That work gets smaller, because `contract_builder.zig` loses its workflow span and `precompile.zig` loses its generator branches.
Correct the CLAUDE.md sentence about the single execution path once 1b lands.

## What stays that a reviewer proposed to cut

- Local MLX provider. Codex marked it KEEP until the owner decides whether local inference is part of the thesis. The local corpus does not drive the headline.
- `zts agent --stdin-json`. STRATEGY.md claims that an outside client completes a propose, simulate, verify cycle with no in-process access. Cutting it retracts that claim. See decision 7.
- `docs/zts-formal-spec-northstar-advanced.md`. Two gates maintain it, and the roadmap calls it the language target. It stays unless the owner archives it.

## Decisions for the owner

1. Phase 1 scope. Option A: accept groups 1a to 1n as listed. Option B: accept a subset. Recommendation: A.
2. Orchestration and system linking (3a, 3b). Option A: cut all and re-record 13 cases. Option B: keep `zttp:durable` alone and cut the rest. Option C: keep all. Recommendation: A. The durable guarantees have no kernel check, and the six cases are where the model fails most.
3. Tool routes and agent handlers (2a). Option A: cut and stop M5. Option B: keep and continue M5 A5. Recommendation: A, only if agent handlers are not the next product. The roadmap calls M5 the active milestone, so this is a strategy change.
4. Application invariants (2b). Option A: cut all. Option B: keep the kernel check and cut the classifier and the drift gate. Recommendation: A. Under B, the TypeSafe classifier must still go.
5. Consumer declaration and envelope (2c). Option A: cut until a consumer commits. Option B: keep. Recommendation: A.
6. Language features (3c, 3d). Option A: cut TSX, comptime, and hypermedia. Option B: keep TSX only. Recommendation: A. The canonical formatter already refuses TSX, so the compiler cannot co-author a TSX draft.
7. External integration surfaces (1j). Option A: keep `zts agent --stdin-json` and cut RPC mode unless the owner names a client. Option B: cut both and retract the strategy sentence. Option C: keep both. Recommendation: A. `rpc_mode.zig` changed on 2026-10-10, so the owner must say whether that work has a client.
8. History. Option A: tag the current state as `pre-rebase`, then delete `docs/archive/` and completed plans. Option B: keep them in the tree. Recommendation: A.
9. Coordination with plan 004, which another session is implementing now. Option A: finish the current 004 unit, pause 004, run Phases 1 to 3, then resume. Option B: run Phase 1 groups that do not touch `precompile.zig` in parallel with 004. Recommendation: A. The plan index forbids two overlapping plans at once.

Next action: the root session executes the selected Phase 2 implementation plan and records evidence in its companion worklog.
