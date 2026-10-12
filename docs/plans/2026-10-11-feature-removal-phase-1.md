> Execution approved on 2026-10-11. The owner accepted every recommended decision of `advisor-plans/005-feature-removal-rebase.md` with "your recommendations".
> This file is the Phase 1 implementation plan. Progress belongs in the companion worklog, `2026-10-11-feature-removal-worklog.md`, which G1 creates.
> Revision 2: a Fable critique and a Codex astra fact-check of revision 1 found that three groups changed the model-visible tool catalog. This revision moves those removals to Phase 3 and writes every keep or delete verdict into the plan.

# Plan 005 Phase 1: remove surfaces that move no identity

## Preconditions

- Decision 9 is met: plan 004's shared analysis and multi-module units are complete (`docs/plans/README.md`). No other plan runs on `main` during Phase 1.
- Baseline: `bash scripts/verify.sh` passed at `464240f1` with exit 0 in 1,237 seconds, offline, with private Zig caches.
- The tag `pre-rebase` marks `b33cac5c`. A source comment or doc that cites a deleted path cites `pre-rebase:<path>`.

## Invariants

These hold after every group. A group that cannot keep them stops and reports.

1. `bash scripts/verify.sh` passes, run as `env -u DEEPSEEK_API_KEY ZIG_LOCAL_CACHE_DIR=<private> ZIG_GLOBAL_CACHE_DIR=<private> bash scripts/verify.sh`.
2. The frozen corpora replay offline. `zig build test-expert-app` runs inside `zig build test`. If it reports `model_context_mismatch`, `response_order_mismatch`, or `coverage.json is stale`, the group changed model-visible input. Stop.
3. Phase 1 changes no model-visible input. Every tool registered in `packages/pi/src/tool_registry.zig` keeps its name, description, and schema bytes. `expert_persona.zig`, `packages/pi/src/skills/`, and `packages/pi/src/prompts/` do not change.
4. These identities equal their baselines in the worklog: `policy_hash` and `module_registry_hash` from `zig-out/bin/zts meta --json`, the output of `zig-out/bin/zts spec-hash`, and `git diff --stat -- policy-hash.txt docs/coverage.json docs/convergence.json docs/spec/` is empty.
5. `self_extract.zig` stays at format 6. No certificate section changes.
6. No model provider is called. Nothing is re-recorded.
7. No gate is weakened. A step, gate, or allowlist row goes only when its whole subject goes in the same group.
8. After each group, these searches return nothing except `pre-rebase:` citations and historical plan text: `git grep -n -e "<each deleted command, flag, step, or script name>" -- docs README.md CLAUDE.md AGENTS.md STRATEGY.md CONCEPTS.md .agents .github scripts build build.zig packages`. The worklog records the exact patterns used.

Each group removes, in the same commit, everything whose only subject is the deleted code: build steps and options, test roots in `build/host_tests.zig`, rows in `scripts/*.allow`, calls in `scripts/verify.sh`, workflow steps in `.github/workflows/`, entries in `tooling/release_check.zig` and its fixture, help text in `cli_help.zig` and its tests, command registry rows, `docs/cli.md`, and sections of live docs.

## Deferred to Phase 3: model-visible surface

These removals change the model-visible tool catalog or prompt, so they wait for the one Phase 3 re-record:
the tools `zts_expert_review_patch`, `zig_build_step`, `zig_test_step`, `pi_witnesses`, `pi_remember_fact`, `pi_recall_facts`, `pi_extension_catalog`, and the `ratchet` operation of `zts_expert_query`;
the files `memory_store.zig`, `zts_expert_ratchet.zig`, and `witness_corpus.zig`;
the `/witnesses`, `/build`, and `/test` slash commands;
the persona lines that name those tools;
the `fix-violations` skill text about `review-patch`.

## Deferred to a later group or phase for other reasons

- `expert_qualification.zig`, `qualify-expert.sh`, and the two qualification Python scripts: the recorder folds `required_runs` into `thresholdHash`, which `docs/convergence.json` publishes. They go in Phase 3 with the convergence republish.
- `extract-evidence-marker.py` and `test-evidence-marker.sh`: `update-convergence.sh`, `update-coverage.sh`, and `check-convergence-emitter.sh` use them. A Zig replacement is separate work.
- `--fork`, `/tree`, and `proofs badge`, `watch`, `export`, and the HTML and Markdown renders: plan 005 did not list them. They stay.
- `module_manifest.zig`, `manifest_registry.zig`, `instruction_counter.zig`, `contract_gate.zig`, `gate_record.zig`: surviving code needs them.
- Plans that a tracked non-plan file cites: they stay until the cited code goes.

## Groups, in execution order

Line numbers are at `464240f1`. The edit sites come from an importer census and two reviews. The compiler and `git grep` stay the authority for anything the list misses.

### G1 Standalone documents and the archive

First create `docs/plans/2026-10-11-feature-removal-worklog.md` with the invariant 4 baselines.
Delete: `docs/internals/zttp-runtime-architecture.html`, `docs/internals/zttp-runtime-architecture.archify.json`, `docs/investor-precise.html`, `docs/investor-warm.html`, `docs/antfly-zig-patterns.html`, `docs/hypermedia-explainer.html`, `docs/essay.md`, `advisor-plans/001-tigerbeetle-inspired-predictable-performance-plan.md`, `advisor-plans/002-local-lfm-default-cutover-plan.md`, all of `docs/archive/`, all of `docs/zttp-next/`.
Edit sites: `STRATEGY.md`, `docs/README.md`, `docs/roadmap.md`, `docs/plans/README.md`, `docs/plans/2026-09-19-feat-agent-handler-spec.md`, `docs/plans/2026-09-22-m4-release-contract.md`, `docs/user-guide.md`, `docs/zts-formal-spec-northstar-advanced.md` (outside its grammar and idiom sections, which `check-grammar-drift.sh` and `check-idiom-table.sh` read), `advisor-plans/README.md`, and six solution docs: `architecture-patterns/separate-wire-compatibility-from-owned-domain-projection.md:50`, `conventions/a-gate-that-counts-nothing-still-reports-a-pass.md:33`, `logic-errors/admitting-a-value-made-latent-conflations-wrong.md:128`, `logic-errors/testing-effect-instead-of-form-refused-the-canonical-predicate.md:201`, `security-issues/empty-label-set-claimed-a-value-was-clean.md:140`, `tooling-decisions/zts-rich-surface-small-kernel.md:118`. Retarget source comments found by `git grep -n "docs/archive\|zttp-next"`.

### G2 WASM playground and browser overviews

Delete: `packages/tools/src/wasm_analyzer.zig`, `build/wasm.zig` (it also declares `wasm-playground-publish` and its test step), `tooling/wasm_playground_publish.zig`, `scripts/build-wasm-playground.sh`, `scripts/check-zts-language-overview.sh`, `scripts/test-zts-language-overview-browser.mjs`, `docs/zts-language-overview.html`, `docs/zts-expert-overview.html`, `packages/zts/src/wasm/`, and the `analyzer_only` option.
`build/wasm.zig:23` is the only place that sets `analyzer_only = true`. Remove the option from `packages/zts/build.zig` and `build/packages.zig:34`, and keep only the `analyzer_only == false` branch at each reader: `builtin_modules.zig:151`, `builtins/helpers.zig:196`, `engine_root.zig:39,64`, `root.zig:162`, `module_binding.zig:119`, `module_binding/bridge.zig:738`, `module_binding/capabilities.zig:380`.
Edit sites: `build.zig`, `build/artifacts.zig`, `scripts/verify.sh:91-92`, `tooling/release_check.zig:58` and its fixture near line 952, `scripts/manual-scripts.allow`, `scripts/manual-steps.allow`, `scripts/zts-tiers.allow:166`, `.agents/skills/zttp-build/SKILL.md`, `docs/README.md`, `docs/internals/testing.md`, `docs/plans/2026-10-09-fault-coverage-follow-ups.md:39`.

### G3 Studio, demo, proof quest, tour, keystroke input, demo passport

Before deletion, move `proof_quest_fixture.starter_source` into `packages/runtime/src/init_command.zig` byte for byte. The `basic` scaffold uses it (`init_command.zig:516`). Remove the quest mention in the generated instructions (`init_command.zig:622`).
Delete: `packages/runtime/src/studio.zig`, `studio_stub.zig`, `demo.zig`, `demo_command.zig`, `proof_quest.zig`, `cli_tour.zig`, `keystroke_input.zig`, `packages/tools/src/proof_quest_fixture.zig`, `packages/pi/src/demo_passport.zig`, `demo_passport_check.zig`, `scripts/smoke-demo.sh`, `scripts/smoke-studio.sh`.
Edit sites: `runtime_features.zig` (Studio selector only; the live-reload selector stays), `cli_main.zig`, `dev_cli.zig`, `dev_command.zig`, `live_reload.zig`, `server.zig` (Studio routes), `runtime_cli.zig` (`--studio`, `--demo`, `--quest`, `--quest-default`), `cli_args.zig:71`, `cli_help.zig:112`, `cli_shared.zig:127`, `proof_card_tui.zig` (Studio and quest hooks only), `packages/proof-review/src/review.zig`, `packages/pi/src/app.zig`, `packages/pi/src/tests.zig`, `packages/pi/src/commands.zig:127`, `packages/pi/src/repl.zig:405`, `packages/tools/src/zts_cli.zig`, `packages/runtime/build.zig:13,60,184`, `build/Context.zig` (`-Dstudio`), `build.zig:59`, `build/host_tests.zig`, `build/smoke.zig`, `build/tooling.zig`, `scripts/verify.sh:100-104`, `scripts/smoke-v1.sh`, `scripts/manual-steps.allow:70`, `tooling/release_check.zig:23,33,61`, `.github/workflows/release.yml:77-83`, `docs/proofs-and-receipts.md`, `docs/user-guide.md`, `docs/cli.md`, `docs/internals/testing.md:50`, `CLAUDE.md`.
Check that `repl.zig:405` and `commands.zig:127` are not model-visible text. If either feeds the prompt, stop and report.
Pass condition for `git grep -n pi_app packages/runtime/src`: only `cli_args.zig`, `cli_doctor.zig`, `dev_cli.zig`, `dev_command.zig`, `witness_replay_lib.zig`, and `handler_corpus.zig` remain.

### G4 Edge runtime

Delete: `packages/runtime/src/edge_server.zig`, `edge_server_stub.zig`, `docs/edge.md`.
Edit sites: `runtime_features.zig` (edge selector), `main.zig`, `runtime_cli.zig` (`edge` verb), `dev_cli.zig`, `cli_help.zig:114`, `packages/runtime/build.zig:14,56,61,185`, `build/Context.zig` (`-Dedge`), `.agents/skills/zttp-build/SKILL.md`, `docs/README.md`, `docs/user-guide.md`, `docs/cli.md`, `docs/roadmap.md` (Supported Now), `docs/plans/2026-09-22-m4-release-contract.md:158,167`, `CLAUDE.md`.
Keep `docs/solutions/security-issues/edge-chunked-encoded-body-amplification.md`. Its lesson applies to `server.zig:1053,1116`. Rewrite its edge-specific commands and file citations at lines 45 and 47 for `server.zig` or `pre-rebase:`.

### G5 AOT native-handler path and dead builtins

Delete: `packages/tools/src/transpiler.zig`, `packages/zts/src/builtins/symbol.zig`, `packages/zts/src/builtins/weak_collections.zig`, `scripts/build_minimal_dyld.sh`, `scripts/run-jsx.sh`.
Remove the production AOT path: the transpiler branch at `precompile.zig:3355`, `emit_aot` near `precompile.zig:2722`, the `has_aot` field that `precompile.zig:4509` emits and `embedded_handler_stub.zig:6,13` declares, the `embedded_handler.has_aot` check in `handler_instance.zig` near line 1600, `-Daot` in `build/Context.zig:143`, `--aot` in `build/artifacts.zig` and `precompile_args.zig:28,62`.
Keep `analyzeAot` and `AotAnalysis`: contract building uses them for routes (`precompile.zig:3429`).
Keep the test-only `aot_override` hook in `handler_instance.zig:110` and the `builtin.is_test` branch near line 1583. Tests in `engine_adapter.zig:70`, `runtime_http.zig:3163`, `server.zig:5966,6004,6044`, and `zruntime_tests.zig:87,4624` use it to inject handlers. It is a test seam, not the AOT feature.
Builtin exports: `builtins/root.zig:22-23,39-40,55-58`. Rows: `scripts/zts-tiers.allow`, `scripts/manual-scripts.allow`.

### G6 Precompile options for external generators, and `prove`

Delete: `packages/tools/src/manifest_alignment.zig`, `property_expectations.zig`, `openapi_manifest.zig`, `sdk_codegen.zig`, `precompile_buildtime.zig`, `prove.zig`, `precompile_prove.zig`, `prove_upgrade.zig`.
`prove_upgrade.zig` has no other production caller once `precompile_prove.zig` goes (`precompile_prove.zig:72`). `upgrade_verifier.zig` stays: `system_rollout.zig:9` and `zts_cli.zig:5` use it.
Delete the build options and their precompile flags: `-Dmanifest`, `-Dexpect-properties`, `-Dgenerator-pack`, `-Dfault-severity`, `-Dreport`, `-Dopenapi`, `-Dsdk`, `-Dreplay`, `-Dtest-file`, `-Dprove`, `-Dgenerate-tests`. No gate reads the `-Dreport` output.
Keep: `-Dhandler`, `-Dverify`, `-Dcontract`, `-Dpolicy`, `-Dsql-schema`, `-Dsystem`, `-Ddeclaration`, the `gen-tests` command, `prove-behavior`, and `report.zig` while a test uses it (`precompile.zig:9673`).
Edit sites: `precompile.zig` (including line 1314), `precompile_args.zig`, `report.zig`, `zts_cli.zig`, `cli_help.zig:292`, `build/Context.zig:140-162`, `build/artifacts.zig`, `build/host_tests.zig` (`test-manifest-alignment`, `test-openapi-manifest`, `test-property-expectations`), `.gitignore:53`, `CLAUDE.md:23`, `docs/user-guide.md:791,821`, `docs/verification.md:630`, `docs/contracts-and-sandboxing.md:167,402,479,603`, `docs/consumer-contract.md:718,780`, `examples/README.md:6`, `docs/internals/testing.md`, `docs/cli.md`, `.agents/skills/zttp-build/SKILL.md`, `docs/plans/2026-09-23-m4-t2-tool-catalog-design.md:29`.

### G7 Runtime proof extras: `proof` alias, capsules, audit ring

Delete: `packages/runtime/src/proof_cli.zig`, `capsule.zig`, `proof_audit_ring.zig`, the `proofs replay` subcommand, and `dev --record-proof`.
The audit ring is observability only: `server.zig:711,861` push and `proof_card_tui.zig:832-833` reads. No enforcement reads it. No verifier reads capsules.
Keep: `proofs list`, `show`, `diff`, `watch`, `export`, `badge`, `bundle`, `verify`, `gate`, the renders, `proof_ledger.zig`, `replay_runner.zig`, `witness_replay_lib.zig`, `zttp ledger replay` (`release.yml:85-89` uses it; no workflow change).
Edit sites: `cli_main.zig`, `dev_cli.zig` (including the capsule callback registration at line 112), `dev_command.zig` (capsule callback near line 173), `proofs_cli.zig:5,17,60-62,108`, `server.zig`, `proof_card_tui.zig`, `cli_help.zig:126,147,148,261`, `tooling/release_check.zig`, `docs/proofs-and-receipts.md`, `docs/cli.md`, `docs/plans/2026-09-19-feat-agent-handler-spec.md:96`.

### G8 Developer CLI extras: `witnesses` and `ratchet show`

Delete: `packages/runtime/src/witnesses_cli.zig`, `ratchet_command.zig`.
Keep: `packages/zts/src/witness_corpus.zig` (precompile, the corpus gate, pi tools, and `live_reload.zig:290,388` use it), `packages/pi/src/tools/zts_expert_ratchet.zig` (the query tool uses it), `proof_ratchet.zig`.
Edit sites: `cli_main.zig`, `dev_cli.zig`, `cli_help.zig`, `scripts/test-module-boundary.sh`, `scripts/module-boundary.allow`, `docs/proofs-and-receipts.md`, `docs/cli.md`, `docs/solutions/runtime-errors/builtin-graph-teardown-use-after-free.md:83`.

### G9 Analyzer command extras

Delete: `packages/tools/src/review_patch.zig` (the pi tool calls `edit_simulate` directly and does not import it), `packages/pi/src/gate_report.zig`, `packages/tools/src/training_export.zig`, `scripts/zts-training-export.sh`, `packages/tools/src/mock_server.zig`, `packages/zts/src/extension_bindings.zig`, and the `review-patch`, `gate-report`, `zts-training-export`, `mock`, `extension-status`, and `verify-module-manifest` commands.
`extension_bindings.all` is empty, so removing its concatenation at `builtin_modules.zig:157` leaves the ordered binding list and `module_registry_hash` unchanged. Invariant 4 confirms it.
Edit sites: `zts_cli.zig`, `expert.zig` (including `expert.zig:590-594`), `dev_cli.zig`, `cli_help.zig:128,295`, `packages/pi/src/app.zig`, `packages/pi/src/tests.zig`, `init_command.zig:386,824-834` (partner-module scaffold text), `build/host_tests.zig` (`test-training-export`), `build/artifacts.zig`, `scripts/manual-steps.allow:66`, `scripts/zts-tiers.allow`, `packages/pi/README.md:23,138`, `docs/cli.md`, `docs/internals/testing.md`.
Leave `expert_workflow.zig:162` and `expert_codegen_eval.zig:567` unchanged if their `review-patch` text is model-visible. Otherwise update them. Record which in the worklog.

### G10 Perf and equivalence receipts

Delete: `packages/zts/src/perf_receipt.zig`, `equivalence_receipt.zig`, `packages/pi/src/perf_probe.zig`, `equivalence_probe.zig`, `capsule_probe.zig`, `packages/runtime/src/perf_probe_lib.zig`, `equivalence_probe_lib.zig`, and the positive and negative receipt flags (`cli_args.zig:170-173,229-232`).
Keep `instruction_counter.zig`. Keep `proofs gate`'s verdict and exit code; signing is separate (`pr_gate.zig:993-1014`). Keep `--no-sign` (`scripts/proof-gate.sh:25` and `.github/workflows/proof-gate.yml` pass it).
Keep the `perf` and `equivalence` ledger kinds readable. `proof_ledger.zig:377` rejects an unknown kind, and existing `.zttp/proofs.jsonl` files hold such rows. Stop writing them, and add a test that a legacy `kind=perf` row still loads.
Edit sites: `packages/zts/src/contracts_root.zig`, `packages/zts/src/root.zig:147-148`, `scripts/zts-tiers.allow`, `scripts/module-boundary.allow:50,71`, `packages/pi/src/app.zig`, `packages/pi/src/tests.zig`, `cli_main.zig`, `dev_cli.zig`, `handler_corpus.zig`, `pr_gate.zig:1002-1005`, `cli_help.zig`, `docs/plans/2026-07-30-016-d3-canonical-form-wire-design.md:31`.

### G11 Provable-reach tooling and RPC mode

Delete: `packages/pi/src/expert_reach_main.zig`, `expert_reach_report.zig`, `expert_reach_corpus.zig`, `expert_reach.zig`, `expert_reach_tests.zig`, `docs/provable-reach.json`, `packages/pi/src/rpc_mode.zig`, `--mode rpc`.
Keep `docs/provable-reach.md` as the M3 record. Retarget its JSON links at lines 8 and 178 to `pre-rebase:docs/provable-reach.json`.
Edit sites: `build/tooling.zig` (`provable-reach`), `build/host_tests.zig` (`test-provable-reach`), `scripts/manual-steps.allow`, `packages/pi/src/tests.zig`, `packages/pi/src/app.zig`, `cli_help.zig`, `packages/pi/README.md`, `docs/internals/testing.md`, `docs/plans/2026-10-08-minimal-design-audit.md:261`, two solution docs that cite reach files (`a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md:60`).

### G12 SMT layer and z3

Delete: `packages/zts/src/semantics_smt.zig`, `semantics_audit.zig`, `packages/tools/src/smt_solver.zig`, `runSmt` and `runAudit` with their fake-solver tests, the `--audit` flag and SMT section of `spec-check`, the `test-smt-solver` row (`build/host_tests.zig:78`), `scripts/module-boundary.allow:111`, and z3 from the install steps at `ci.yml:55-62` and `release.yml:61-68`. Keep ripgrep in those steps.
Keep: `semantics.zig` with `excluded_laws` and `audit_timeout_ms` as data, `semantics_check.zig` structural `runCheck`, `semantics_corpus.zig` (`runCorpus` compares real bytecode with declared semantics without z3), `semantics_render.zig`, `semantics_cli.zig` with `spec-check`, `spec-hash`, and `spec-render`, and `docs/spec/`.
Keep the `SpecCode` variants ZTS757 and ZTS758 (`diagnostic_catalog.zig:111-112`) and their rows at `scripts/corpus-uncovered.allow:109-110`. Deleting them would move `diagnosticHash`. Record them as dead in the worklog for Phase 3.
Rewrite `scripts/check-semantics-spec.sh` to run `spec-check` and `spec-render --check` with no z3 branch.
Edit sites: `packages/zts/src/compiler_root.zig`, `packages/zts/src/root.zig:169-170,751,754`, `semantics.zig:527,554`, `semantics_check.zig:35,570`, `semantics_cli.zig:105,162-175`, `scripts/zts-tiers.allow`, `scripts/verify.sh:175-176`, `tooling/release_check.zig`, `invariant_author.zig:13` (comment), `docs/internals/semantics-verification.md`, `docs/internals/testing.md`, `docs/plans/2026-07-30-016-d3-canonical-form-wire-design.md:179`, `CLAUDE.md`.
`zts spec-hash` must equal its baseline.

### G13 Claude and OpenAI providers, in four commits

Record the `N passed` line of `zig build test-standin` before G13a. G13b and G13d must reproduce the same count.

- G13a: Move `providers/anthropic/propose_change_set.zig` to `providers/propose_change_set.zig` and update its relative imports and every importer. `tools_schema.zig` serializes Anthropic Messages schemas, so it stays in place until G13d decides it.
- G13b: Port the stand-in from the OpenAI Responses wire to the chat-completions wire in `providers/chat_completions.zig`. Port the server (`standin/server.zig`), the request decoder (`standin/request.zig`), the Responses encoder (`standin/playbook.zig:1235`), the clients, and the tests together. `standin_main.zig:63` stops naming `ZTS_OPENAI_BASE_URL`; `AgentSession.initDeepSeek` takes a `base_url` (`agent.zig:441-456`) and the DeepSeek client honors `DEEPSEEK_BASE_URL`. Every defect seed must trip the same rules. If a seed trips a different rule, stop.
- G13c: Rewrite the record-tee transport test (`expert_codegen_record.zig:683,723`) on the DeepSeek client, which already wires `capture_sink`. Delete the flat-cassette lane (`expert_codegen_record.zig:550,5240-5262,5383,5404-5411`), the Claude coverage baselines (`expert_codegen_record.zig:3778-3910`), `claude_empirical_flow_root` (line 276), and the corpus directories `providers/testdata/codegen/` and `simulator/testdata/empirical/codegen/`. Update `scripts/update-coverage.sh:337` and `docs/coverage.md:23` text so they describe the new loopback. If the coverage gate reports drift, republish offline with `scripts/update-convergence.sh` and then `scripts/update-coverage.sh`, each in its own commit.
- G13d: Delete `providers/anthropic/`, `providers/openai/`, `providers/testdata/anthropic/`, `providers/testdata/openai/`, the `.anthropic` and `.openai` enum members (`providers/models.zig:7-11`) and every switch arm on them, and the `claude` and `openai` rows in `cli_auth.zig` and `cli_help.zig`. Rewrite the fixture consumers `cassette_client.zig:299-300`, `cassette_tests.zig:10-13`, `simulator/model_client_test.zig:16`, and `simulator/runner_test.zig:11` onto chat-completions fixtures. Known importers: `agent.zig:20-22`, `expert_codegen_record.zig:16-19`, `gate_record.zig:15`, `loop.zig:12`, `providers/capture_sink.zig:9`, `simulator/model_client.zig:13-14`, `simulator/recorder.zig:15`, `simulator/recorder_test.zig:22`, `standin_main.zig:8-10`, `standin_range_tests.zig:7-8`, `standin_tests.zig:10-13`, `tests.zig:76-90`, `tool_catalog_consolidation_test.zig:13-14`, and the enum users `app.zig:54`, `context_budget.zig:162`, `context_budget_test.zig:282`, `expert_evidence_identity.zig:883`, `providers/cassette_record.zig:178`, `providers/model_request.zig:434`, `repl.zig:948`, `settings.zig:229`, and four simulator tests. Update CLAUDE.md's Models section.

The DeepSeek and local replays must stay green after each of G13a to G13d. If removing an enum member changes a DeepSeek request hash or evidence identity, keep the member as an unused tag, record why, and continue.

### G14 Plan index and sound-mode merge

Run G15 before G14. Delete each plan under `docs/plans/` that meets all three conditions: `docs/plans/README.md` marks it complete or implemented, `docs/roadmap.md` does not call it open, and `git grep -l "<its file name>" -- ':!docs/plans'` finds no tracked non-plan file. List the deleted and kept files in the worklog with the reason for each kept file.
Fold `docs/sound-mode.md` into `docs/typescript.md`. Retarget links at `AGENTS.md:18`, `CLAUDE.md:89`, `README.md:156`, `docs/README.md:54`, `docs/internals/api-reference.md:142`, `docs/proofs-and-receipts.md:307`, `docs/user-guide.md:582`, and `docs/typescript.md:487,793`.
Update `docs/roadmap.md`: Phase 1 complete, Studio and edge removed from Supported Now, M5 stopped by decision 3 of plan 005.
Recount with the plan 003 reproduction command. Record the counts in the worklog.

## Per-group procedure

1. The implementer applies one group, then runs the affected named steps unfiltered, then the invariant 1 command. Every exit status is read from the command, never from a pipe through `tail`. A `-Dtest-filter` run is never evidence.
2. The implementer checks invariants 2, 3, 4, and 8 and records the results and the search patterns in the worklog.
3. The implementer leaves the changes uncommitted and reports deleted files, edited files, each check with its exit status, and every judgment the plan did not settle.
4. The root session reads the diff line by line, runs `scripts/verify.sh` itself, and commits the group.

## Out of scope

Phase 2 and Phase 3. The deferred items above. Renames. Refactors inside surviving files beyond deleting dead branches.

## G15 Dead code that earlier groups left behind

Added during execution. Each item lost its last production caller in an earlier group. Delete it, its tests, and its docs, under the same invariants.

- From G3: the `trade`, `handover`, and `caller_view` lenses, `CallerView`, and any helper in `proof_card_tui.zig` that only those lenses reach, once `git grep` confirms no `zttp dev`, `deploy`, or `proofs` path renders them. Keep `buildProofCertificate` if any surviving path calls it.
- From G3: `Server.installDevAttestation`, `attest_build_receipt.buildDevJws`, and the `signer_fingerprint_hex` field, which only `--studio` reached.
- From G3: the in-place `.` branch of `init_command.scaffoldProject`, if no surviving command scaffolds in place.
- From G4: `cli_shared.featureCompiledOut`, which only `edge` and Studio called.
- From G5: the `embedded_handler` import on `runtime_instance` in `packages/runtime/build.zig`, if no file in that module imports it; stale AOT comments at `handler_analyzer.zig`, `runtime_config.zig`, `server.zig`, `runtime_cli.zig`, and `docs/consumer-contract.md` (keep `enableJsonBodyParsePatterns` and the `request_json_parse` body source, which feed routes); `WellKnownSymbol` support in `object.zig` and `value.zig`, if the engine no longer reaches it.
- From G6: `contract_diff.writeProofJson` and `writeProofReport`, `upgrade_verifier.writeUpgradeManifestJson` and `writeUpgradeReport`, and `report.zig` with the `test-report` step, each with its tests, once no production caller remains. `zts.routePatternsMatch` and `zts.pathsMatch` are curated public surface: keep them unless the root session decides otherwise.
- From G7: the proof card keeps a three-column frame whose third column is now blank after the audit ring went. Reflow it to two columns, together with the lens cleanup in the same file.
- From G8: `witness_corpus.synthesizeStructural` with `spec_discharge.isCauseOnly`, `witness_corpus.pin`, `witness_corpus.prune`, and `witness_corpus.selectFewShot`, each once `git grep` confirms that only tests call it. `isPinned` stays. `pi_witnesses` may call some of these: check before deletion, and leave any that a pi tool reaches for Phase 3.
- From G9: `module_audit.verifyManifestPath`, which has no caller and no test.
- From G10: `handler_corpus.zig` and its `zruntime_tests.zig` import; `cli_shared.nowUnixMs`; the `perf` and `equivalence` writer paths in `proof_ledger.appendEvent`, once the round-trip tests read raw rows (the reader and the two legacy-row tests stay).
- Further items that later groups report go in this list before G15 runs.
