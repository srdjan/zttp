# Reset implementation plan, 2026-10-25

## Authority and status

This document is the plan authority for the 2026-10-25 reset.
It owns the findings review, the design, the phase order, the verification, and the owner decisions.
The worklog for this plan records execution and evidence. Phase R0 (baseline) creates that worklog.
Preparation findings go into the worklog, not into this document.

Status: draft for owner review. No implementation is authorized.
The owner authorizes implementation by answering the decisions in "Owner decisions".

When the owner approves this plan, it replaces the [2026-10-14 reset plan](2026-10-14-reset-implementation-plan.md) as the active reset authority.
The 2026-10-14 plan remains the record of its completed units U1 to U20.
The roadmap and the plan index point to this document after phase R1 (authority documents).

Validation: one Fable review of the draft. The section "Validation record" lists each finding and its disposition.

## Goal

The reset gives future work a simple and stable base. It does not add a feature.
A base is stable when each fact has one producer and each test exercises the production path.
It is simple when each file has one responsibility and a reader can find each authority in one place.

## Preservation contract

The reset preserves current functionality. These outputs are the compatibility boundary:

- The CLI commands, flags, exit codes, and output text of `zttp`, `zttp-runtime`, and `zts`.
- Every diagnostic code, message, and location.
- The contract JSON, the certificate wire format, the agent protocol schema, and the meta payload.
- The policy hash, the registry hashes, and the pins that `check-meta-drift.sh` checks.
- The corpus identity and the recorded cassettes. A prompt, seed, tool output, or wire byte change forces a paid DeepSeek re-record.
- Handler behavior at runtime, request isolation in `HandlerPool`, and the path traversal checks in `server.zig`.
- The leaf boundary of `packages/proof-checker` (decision D-005) and the CHECK traversals (decision D-006).

Each phase has one of two classes:

- Class A (behavior-neutral). The phase must not change any golden, cassette, pin, or published evidence file. The verification proves this with `git diff --exit-code` against the phase base.
- Class B (owner-gated). The phase can move model-visible output, a hash, or a verdict. It runs only after an owner decision names it.

Every phase in this plan is class A, except where a phase states a stop rule.
A stop rule halts the phase when a class A phase would move a protected output.
The implementer then records the evidence in the worklog, and the owner decides.
No phase regenerates a golden with an `update-*` script to make a gate pass.

## Baseline and evidence limits

The review read local `main` at `90510194` on 2026-10-25. The validation read `75594cc8`, three commits later.
The working tree was not clean during the review.
Another session had uncommitted edits in 14 to 22 files, including `flow_interp.zig`, `type_syntax.zig`, `type_checker.zig`, `type_pool.zig`, `server.zig`, and `agent_protocol.zig`.
This plan does not touch those edits. Phase R0 does not start until the owner commits or discards them.
R0 records its own base commit. Each count below can move by a few lines before R0; the counts set scope, not acceptance.

Measured sizes at `90510194`:

| Item | Count |
|---|---|
| Tracked Zig lines | 397,312 |
| `packages/zts` Zig lines | 204,398 |
| `packages/pi`, `packages/runtime`, `packages/tools` Zig lines | 71,877, 47,785, 40,912 |
| Top-level build steps | about 89 (47 `b.step`, 17 host roots, 25 `addGate`) |
| Gate rows in `AGENTS.md`, tasks in `agents.json` | 78, 93 |
| Files under `scripts/`, of which allowlists | 54, 7 (458 non-comment rows) |
| Files under `docs/plans/` | 50 |
| Lines in the 2026-10-14 reset plan | 7,039 |

Evidence limits: the review used `git grep`, `wc`, `git log`, and reading.
It ran no build and no test. Each count is from HEAD, not from the dirty tree.
No timing is claimed. A finding marked "probable" names the check that confirms it.

## First-principles design

A future change lands safely when four conditions hold.
First, the change has one place to edit for each fact.
Second, the tests that cover that place run the production path.
Third, a reviewer can read the file that holds the change without unrelated code.
Fourth, the gates tell the author what broke, and one registry names the gates.

The current code breaks these conditions in four ways.
Some facts have two producers or two grammars (findings F2, F3, F4, F8).
Analyzer tests use a parse mode that production never runs (finding F1).
Several files mix four to eight responsibilities (findings F7, F11, F12).
The status documents and the gate registries repeat each other (findings F15, F16, F17).

The reset therefore applies five rules, in this order:

1. Prove preservation before any change. Freeze the protected outputs and add one bytecode identity check.
2. Make tests run the production path. Then remove the path that only tests use.
3. Give each fact one producer. Keep the output bytes the same.
4. Split files by responsibility with code motion only. Logic changes and motion never share a commit.
5. Make one document own status and one registry own gates. Archive what is complete.

Model-visible changes wait. The reset freezes them and lists them for one later re-record window (Decision 2).
This keeps each reset phase cheap to verify, because the offline replay proves it.

## Detailed findings review

Each finding gives the evidence, the effect on future work, the reset action, and the preservation risk.
Line counts are from HEAD. The phase column in "Phases" maps each finding to its phase.

### F1. Analyzer tests use a typed parse mode that production never runs

Evidence: `parser/parse.zig` has five entry modes built from booleans in `initWithProfile`.
Production uses two of them.
Typed TypeScript sources use `initAdmission(.compile)`: `source_frontend`, the `zts.Parser.initTyped` wrapper in `parser/root.zig`, `module_graph`, and `pipeline`.
Virtual JavaScript sources use the untyped `JsParser.init`: three sites in `precompile.zig`, `module_graph_record.zig`, `pipeline.extractVirtualContract`, and the fallback branch of four pi tools.
`JsParser.initTyped` carries the comment "Private migration initializer". It builds the typed profile without admission.
Only test code calls it, at about 190 sites: 146 in `typed_frontend_tests.zig`, 20 in the tests of `parse.zig`, and others in `pipeline.zig`, `type_checker.zig`, `type_env.zig`, `handler_verifier.zig`, `strict_checker.zig`, `flow_checker.zig`, `match_analysis.zig`, and the test-only `analysis_fuzz.zig`.

Effect: the typed analyzer tests prove behavior for a configuration that no user runs.

Action: move every test to `initAdmission(.compile)` or to the `DirectCheckSource` entry. Then delete `JsParser.initTyped`.
A test whose expectation changes reveals a real difference between the two modes. The worklog records each one.

Risk: production does not change, because production never calls the deleted function.
After R4, the parser still has two production modes, and its 246 `self.admission` branches stay live.
The admission replay and a move of virtual JavaScript onto admission are class B items (Decision 2).
The comment label `legacy_parser` on the live virtual JavaScript path in `precompile.zig` is stale; R3 corrects it.

### F2. Contract properties come from a two-step producer

Evidence: `contract_builder.zig` (`computeProperties`) sets `deterministic` from `handler_fn != null`.
`HandlerProperties` and `FlowProperties` default the flow fields to `true`.
The values are correct only after a caller runs `pipeline.projectFlowProperties`.
Three callers do this in different ways: `precompile.projectCompletedFlow` skips a null flow result, `pipeline.extractContract` calls `projectParsedFlow` with a second `FlowChecker` that has no module views, and `extractVirtualContract` and `extractPreparedEvalContract` have their own calls.

Effect: a new contract caller can forget the second step and publish proven defaults.

Action: `ModuleAnalysisSession.extractContract` returns a contract with the flow results applied. Delete `projectParsedFlow`.
The default values do not change. The flip of the defaults is round 4 unit U12, which the owner deferred.

Risk: the contract goldens, the contract digest that `build_command.zig` pins, and the `holes` list that the model sees.
Stop rule: if one producer gives a different contract than the current second `FlowChecker`, stop and record the case.

### F3. `pipeline.ModuleAnalysisSession` holds duplicate analysis state

Evidence: the session holds 3 profiles, 2 `TypeEnvStorage`, up to 3 `TypeChecker` values, 2 `ModuleFacts`, 2 `FlowChecker` values, and 5 `PassState` fields.
The free function `pipeline.check` has no production caller; three test call sites use it.
Three pi tools build a bare `FlowChecker` or `HandlerVerifier`.
`zts_expert_narrow` writes the bare `FlowChecker` diagnostics into its tool envelope, which the model sees.
`pi_repair_plan` runs only the bare checkers. Only `pi_goal_check` also runs the production check.

Effect: a change to analysis state must be made in up to three copies. Pi can see analysis that production does not run.

Action: one type environment and one checker for each module. A profile selects passes, not storage.
For pi, R7c measures how far the bare and production diagnostics differ. The move of the three tools onto the production session is class B (Decision 2), because their output is model-visible.

Risk: the profile differences (strict on or off, the `type_check` callback) are compatibility inputs. The pinned contract digest and the analyzer output digests from R0 must not move.

### F4. Two grammars parse type expressions

Evidence: `type_pool.zig` (`TypeExprParser`) parses type text for `TypeEnv.resolveType`.
Binding signatures in `module_types`, `ambient_names`, `path_generator.returnsOkRecord`, and the signature census in `precompile_check` use it.
Authored source uses `parser/type_syntax.zig` instead.
Round 4 unit U5 fixed one disagreement between the two (`(first: Left, Right)`).

Effect: each new type form needs two parsers, and the two can disagree in silence.

Action: parse binding signatures through the standalone annotation entry of `type_syntax.zig`. Then delete `TypeExprParser` and `resolveType(text)`.

Risk: the signature census hash and the types of module exports. Stop rule: any census or golden change.

### F5. Shared helpers live inside peer analyzers

Evidence: `packBindingKey` in `bool_checker.zig` is imported by six analyzers, including `strict_checker`, `handler_verifier`, `path_generator`, `effect_inference`, `flow_interp`, and `route_resolution`, for that function only.
`findHandlerFunction` lives in `handler_verifier.zig`, and `pipeline`, `proof_trace`, `severity_census`, `path_generator`, and pi use it.
`flow_interp` imports `path_generator` only for `isOkRecordExport`.
`root.sourceLine` forwards to `bool_checker.getSourceLine`. `canonicalize`, `repair_validator`, and `parser/error` have their own copies.

Effect: peer analyzers depend on each other for unrelated reasons. The layering gate cannot show the real structure.

Action: move each helper to a leaf module. Keep the re-exports in `root.zig`.

Risk: none to semantics.

### F6. Analysis walks over IR node tags are written by hand

Evidence: switch statements on node tags per file: `type_checker` 20, `strict_checker` 13, `effect_inference` 12, `flow_interp` 9, `contract_builder` 9, `type_env` 8, `handler_verifier` 8, `path_generator` 7.
The shared child iterator `IrView.expressionChildren` appears in 8 files only.
`scripts/proof-swallow.allow` has 410 lines.
`AGENTS.md` records five shipped fail-opens of the "`else => {}` skipped a child" class.

Effect: each new node kind needs edits in many walks. A missed edit gives a verdict for code that no pass read.

Action: one child visitor for expressions and statements. Every analysis walk uses it as the default arm. Migrate one file per commit.

Risk: a child that was skipped and is now visited can move a verdict, normally toward unproven. This is a soundness repair, not neutral motion. Stop rule in phase R10.

### F7. The IR has two construction representations

Evidence: `parser/ir.zig` defines the struct `Node` and an adapter `IRStore.add(Node)` with the comment "for seamless migration".
`IRStore.get` ("compatibility during migration") has callers only in `parse.zig`.
`parse.zig` builds nodes through `add(Node)` 68 times.

Effect: two encodings of the same node exist. A payload change must be made in both.

Action: build nodes with `addNode` only, then delete the adapter and the unused struct form.

Risk: the node payload encoding and the emitted bytecode must not change. Phase R0 adds the bytecode identity check that proves this.

### F8. Six diagnostic types and two unifiers

Evidence: the bool, strict, type, verifier, fault, and flow checkers each define a `Diagnostic` type. Five have their own `formatDiagnostics`.
`diagnostic_projection` and `property_diagnostics` both unify them.
`precompile.zig` still prints flow diagnostics through the flow-specific formatter.

Effect: a new diagnostic field must be added in up to eight places.

Action: consumers read only the projection. One formatter produces byte-identical output.
Nobody has measured whether the five formatters agree. R9b therefore starts with a format census.

Risk: the text is visible to the model. The diagnostic corpus, the expert goldens, the R0 analyzer digests, and the cassette replay catch a change.
Stop rule: if the census shows that the formatters differ, the formatter merge becomes class B.

### F9. Proof property names are declared in at least five places

Evidence: `HandlerProperties`, `FlowProperties`, `counterexample.PropertyTag`, `spec_discharge.PropertyField`, and the census enums in `packages/tools`.
No compile-time check links them. The comment on `PropertyTag` says the solver "runs before flow_checker is wired in", which is out of date.

Effect: a new property can be added to one list and missed in another without a compile error.

Action: add compile-time checks that each enum covers each field of `HandlerProperties`. Do not reorder any enum, because a registry hash depends on the order.

Risk: none if the order stays. `test-meta-drift` catches an order change.

### F10. The serve flag list exists twice

Evidence: `cli_shared.zig` (`findPositionalPath`) hard-codes the serve flags that take a value.
`runtime_cli.zig` (`parseCommonServeFlag`, `parseServeArgs`) parses the same flags again.
`parseServeArgs` accepts `--_debug-panic-path` with a value, and `findPositionalPath` does not list it.

Probable effect: `zttp-runtime serve --_debug-panic-path /x handler.ts` passes `/x` to project discovery as the handler path.
Check: a unit test of `parseServeArgs` with that argument order in a Debug build.

Action: one table of value-taking flags, read by both functions. If the check confirms the defect, the fix ships with the regression test.

Risk: the flag is internal and Debug-only. Public flags keep their behavior; `test-cli` and `test-zruntime` check them.

### F11. `precompile.zig` is the analysis hub and the largest churn point

Evidence: 12,598 lines, of which production code is about the first quarter and the rest is 244 tests. It had 80 commits since 2026-09-25.
Callers: 13 runtime sites, 9 pi sites, and `agent_protocol.runVerify`.
Responsibilities: the `-Dhandler` code generation CLI, the CHECK facade, contract and policy building, SQL schema validation, text reports, and test generation.

Effect: unrelated changes collide in one file, and a reviewer must page through 12,000 lines.

Action: move each responsibility to its own file. `precompile.zig` re-exports, so no caller changes.

Risk: D-006 freezes the CHECK traversal order; code motion keeps it.
`scripts/check-proof-swallow.sh` lists `precompile_imports.zig`, not `precompile.zig`. A moved block that holds CHECK analysis adds its new path to that list.
`tooling/production_branch_metric.zig` names `precompile.zig` by path and needs the new paths.

### F12. Other files mix responsibilities

Evidence:
- `parser/type_syntax.zig` (12,729 lines) holds the syntax `Store`, the type parser, and about 3,500 lines of admission byte scanners.
- `agent_protocol.zig` (6,327 lines) holds schema negotiation, dispatch, the meta and catalog payloads, and five operations.
- `server.zig` (4,063 lines) holds `ConnectionPool`, about 845 lines. `check-runtime-purity.sh` names `server.zig` by path.
- `typed_frontend_tests.zig` (14,179 lines) holds parity fixtures from the 2026-10-14 reset. It mentions "legacy" or "parity" 219 times.
- `flow_checker.zig` (5,572 lines) has 148 production lines. The rest is 165 tests that run the same engine as the tests in `flow_interp.zig`.

Effect: as in F11.

Action: code motion into sibling files with one responsibility each. Parity fixtures shrink only where phase R4 removes their comparison path.

Risk: none to behavior if the motion is exact. The reviewer checks with `git show --color-moved`.

### F13. Two provider clients copy the same decode code

Evidence: `providers/local/client.zig` (1,797 lines) and `providers/deepseek/client.zig` (1,236 lines) have the same function structure.
In the sanitize and decode code, 54 of about 250 lines differ. The main difference is the reasoning-retention rule.
Round 4 unit U9 shared only the response-field validation (`providers/response_fields.zig`).

Effect: a decode fix must be made twice.

Action: move the shared decode and sanitize code into one module. Pass the reasoning rule as a parameter.

Risk: the request body feeds `wire_request_sha256`. The cassette replay rejects a byte change.

### F14. Pi production code reads process-wide state

Evidence: tests call `CwdOverride.set` or `chdir` 208 times and `EnvOverride` 48 times.
Seven pi production files read the environment: `expert_codegen_record` 24 reads, `agent` 15, `tools/common` 12, `change_transaction` 12.
`tooling/verify.zig` adds `-j1` to `zig build test` on macOS.

Effect: tests that set process state cannot run in parallel, and a missed reset leaks into the next test.
Inference, not confirmed: process-wide state is a probable second cause of the macOS `-j1` need. `docs/internals/testing.md` names teardown traps as the first.

Action: R0 first runs the aggregate five times without `-j1` as a measurement.
If all five pass, the process state is not a measured cause, and R11c is dropped.
Otherwise, pass the environment and the root directory as values into `AgentSession`, `tools/common`, and `change_transaction`, one file per commit.
The `-j1` flag stays in both cases. A change to `tooling/verify.zig` needs its own owner decision.

Risk: tool output must not change. The cassette replay and `test-standin` check it.

### F15. The policy hash is pinned in many files

Evidence: the current policy hash prefix `ebb4b2b0` occurs in 12 tracked files.
They include `policy-hash.txt`, `scripts/check-meta-drift.sh`, five expert goldens, `docs/convergence.json`, `docs/coverage.json`, and two plan documents.
`check-meta-drift.sh` changed 17 times in a month.

Effect: each policy change edits many files by hand.

Action: `check-meta-drift.sh` reads the policy pin from `policy-hash.txt` instead of a second literal.
The script also pins the grammar, idiom, restriction, and builtin hashes; those pins stay.
The five expert goldens embed the hash literally. A placeholder in them would move protected files, so that change is class B (Decision 2).
The published evidence JSON stays as it is.

Risk: wire bytes do not change. `test-meta-drift`, `test-expert-golden`, and `release-provenance` check it.

### F16. `packages/proof-review` is a runtime library in a separate package

Evidence: 2,145 lines. Only six runtime files import it. No pi or tools file imports it.
`build/Context.zig` records a past failure where Zig built it twice and split type identity.
It needs its own step, `test-proof-review`.

Effect: one more package, step, and dependency edge for code that has one consumer.

Action: move it into `packages/runtime/src/proofs/`. Its tests join the runtime test route.

Risk: CLI output does not change. `agents.json`, `AGENTS.md`, and `docs/internals/architecture.md` need updates.

### F17. Gate tooling repeats checks and keeps routes that the build never uses

Evidence:
- Three tools check the import graph: `check-module-boundary.sh` (176 lines, with a 97-line wrapper test), `check-proof-checker.sh` (262 lines), and `tooling/zts_graph_gate.zig` (1,009 lines).
- Seven shell gates have a no-argument branch that rebuilds the tool with `zig build-exe` or `zig run`: `check-agent-determinism.sh`, `check-meta-drift.sh`, `check-zts-layering.sh`, `test-release-workflow.sh`, `check-kernel-safety.sh`, `check-residual-guards.sh`, and `run-production-branch-metric.sh`. `build/repo_gates.zig` always passes the built artifact, so the build never runs that branch directly. Round 4 unit U11 kept these branches as direct entry points.
- One probe uses a fallback: `scripts/test-gate-floors.sh` runs copies of `check-kernel-safety.sh` with no argument for its "kernel safety, empty list" floor probes.
- Task data lives in `agents.json`, `step_coverage.zig` with `manual-steps.allow`, `script_routes` and `verification_routes` with `manual-scripts.allow`, and the tables in `docs/internals/testing.md` that `check-docs-drift.sh` compares.

Effect: a new gate needs edits in four registries, and untested branches can rot.

Action: the native graph gate takes the boundary check and the proof-checker leaf check as subcommands, under the same step names.
Delete the unused fallback branches (Decision 5). `agents.json` becomes the one task registry, with a route field, and `check-spine --write` generates the testing tables.

Risk: the D-005 gate semantics must not weaken. The rejection probes move first and must fail on the same inputs.
D-005 binds `scripts/check-proof-checker.sh` by name. The commit that replaces the script also amends D-005 in `docs/decisions.md`.

### F18. Status documents repeat each other and are stale

Evidence: `docs/roadmap.md` says "Reviewed against local `main` at `a0181c16` on 2026-09-21". It still names the 2026-10-14 reset as "the active reset design".
`docs/plans/README.md` has 50 rows. `advisor-plans/README.md` still lists plan 005 Phase 4 as open.
The 2026-10-14 reset plan grew to 7,039 lines, because preparation findings were appended to it.
`.agents/skills/zttp-build/SKILL.md` is already a symbolic link to the `.claude/skills` copy.
`.agents/skills/zttp-models/SKILL.md` and `.claude/skills/zttp-models/SKILL.md` are two identical regular files.

Effect: an agent cannot find the current authority in one read. The two `zttp-models` copies can drift.

Action: the roadmap owns status. The plan index lists only active plans and retained references. Archive completed plans under a local tag.
Replace `.agents/skills/zttp-models/SKILL.md` with a symbolic link to the `.claude/skills` copy, in the same direction as `zttp-build`.

Risk: none to code. `test-doc-links`, `test-docs-drift`, and `check-spine` check links and anchors.

### Findings considered and excluded

- Two flow producers: refuted. `flow_checker.zig` is a 148-line facade over `flow_interp.zig` since commit `e0d30630`. Commit `a2ceca87` removed the shadow harness. A rename would move `flow_analyzer_version` inputs and many references for no gain.
- Contract JSON v1 and v2: one parametrized writer serves both wire formats.
- CHECK traversals: decision D-006 keeps them.
- Build graph deduplication in `build/Context.zig` (13 `b.dependency` calls): no current defect, high risk to D-005, and the past collisions are fixed.
- One executable for the release and evidence tools: no measured compile saving.
- The two JSON parsers: round 4 found different public semantics.
- The `semantics_corpus` compile path through `compiler.zig`: `zts` cannot import the runtime, and both paths use `zts.Parser.initTyped`.
- Route reachability in `flow_interp` without `route_resolution.zig`: unconfirmed. Phase R10 runs the probe and records the result. A difference becomes a class B finding.
- Each class B item under Decision 2: excluded from class A phases by design.

## Phases

Each phase is one reviewable unit. A phase with sub-phases commits each sub-phase on its own.
The worklog records each commit, each command, and each exit status.

| Phase | Findings | Class | Depends on |
|---|---|---|---|
| R0. Baseline and preservation evidence | none | A | clean tree |
| R1. Authority documents | F18 (status part) | A | R0 |
| R2. Leaf helpers | F5 | A | R0 |
| R3. Dead scaffolding and stale comments | F3 (`pipeline.check`), F9 (comment) | A | R0 |
| R4. Tests on the production parse mode | F1 | A | R0 |
| R5. One IR construction path | F7 | A | R4 |
| R6. File splits by responsibility | F11, F12 | A | R4 (R6a only) |
| R7. One analysis session and one contract producer; pi census | F2, F3 | A, stop rule | R2, R3 |
| R8. One type-expression grammar | F4 | A, stop rule | R6a |
| R9. One diagnostic surface and one property vocabulary | F8, F9 | A | R7 |
| R10. One child visitor | F6 | B where a verdict moves | R9 |
| R11. Runtime and expert consolidations | F10, F13, F14, F15 | A | R0 |
| R12. Package and gate consolidation | F16, F17 | A | R6, R11 |
| R13. Final documentation and archive | F18 | A | all |

Parallel work: R2, R3, and R4a share `pipeline.zig`, `handler_verifier.zig`, and `strict_checker.zig`. One worker runs them in order.
R11 touches other files and can run as a second worker in parallel.
R6 sub-phases are pure motion, so each runs alone to keep the motion review exact.
R7 to R10 run in order, because they share `pipeline.zig` and the analyzers.

### R0. Baseline and preservation evidence

Precondition: `git status --porcelain` prints nothing on local `main`.
Steps:
1. Record the base commit and its tree hash in a new worklog, `docs/plans/2026-10-25-reset-worklog.md`.
2. Run the full gate once and record the test count of each named step from its Build Summary.
3. Add one characterization test. It compiles each tracked handler under `examples/` and each `tests/corpus/check/good` case to bytecode with the existing serializer in `bytecode_cache.zig`. It compares the SHA-256 of each result with a committed golden list.
4. Put the test in an existing runtime test file that the aggregate already runs. Add no build step.
5. Run the test twice from a clean cache. If the digests differ between runs, record that serialization is not deterministic. Then drop the test and rely on `test-examples` and `test-zruntime`.
6. Record the analyzer output digests. The goldens cover 7 contract and 11 expert fixtures only, so this list is the wider oracle for R7 to R10. Run from the repository root:

```bash
zig build
git ls-files 'tests/corpus/**.ts' 'examples/**.ts' | while read -r f; do
  out="$(./zig-out/bin/zts check "$f" --json --contract 2>&1)"; code=$?
  printf '%s %s %s\n' "$f" "$code" "$(printf '%s' "$out" | shasum -a 256 | cut -d' ' -f1)"
done > /private/tmp/claude-501/zttp-reset-20261025/analyzer-digests.txt
```

7. Run step 6 twice and compare the two files. Record the SHA-256 of the file in the worklog. If the two runs differ, record the unstable cases and exclude them by name.
8. Run `zig build test` five times without `-j1` on macOS, as the F14 measurement. Record each exit status. Do not change `tooling/verify.zig`.

If the digest file is lost, rebuild it from a detached worktree at the R0 base commit.

Exit: the worklog holds the base commit, the counts, the full-gate result, the digest file hash, and the five measurement results. The bytecode golden is committed, or the worklog explains why not.

### R1. Authority documents

Steps:
1. In `docs/roadmap.md`, replace the stale review header and the reset paragraphs. Name this plan as the reset authority and the 2026-10-14 reset as complete.
2. In `docs/plans/README.md`, add this plan and its worklog. Mark the 2026-10-14 plan as complete and no longer the authority.
3. In `advisor-plans/README.md`, mark plan 005 Phase 4 as closed by the 2026-10-14 reset, with its commit range.

Exit: one read of the roadmap names this plan. No other document claims reset authority.

### R2. Leaf helpers

Steps: move `packBindingKey`, `findHandlerFunction`, `isOkRecordExport`, and one `getSourceLine` into leaf modules in `packages/zts/src/`.
Replace the copies in `canonicalize`, `repair_validator`, and `parser/error` only where the bodies are identical. Keep each `root.zig` export name.
Update `scripts/zts-tiers.allow` and `scripts/module-boundary.allow` only if the gates require it.

Exit: `flow_interp.zig` no longer imports `path_generator.zig`, and no analyzer imports `bool_checker.zig` for `packBindingKey`.

### R3. Dead scaffolding and stale comments

Steps:
1. Move the three `pipeline.check` test call sites to the production entry, with the same allocation-failure assertions. Then delete `pipeline.check`.
2. Correct the "Legacy Parser API" comments in `parser/root.zig`, the `PropertyTag` comment in `counterexample.zig`, and the `legacy_parser` name on the live virtual JavaScript path in `precompile.zig`.
3. Before each deletion, run `git grep -n '<symbol>'` across `packages/`, `tooling/`, and `build/`. Record the empty production result in the worklog.

Exit: the census shows no production caller of each deleted symbol. The test count drops by zero.

### R4. Tests on the production parse mode

Steps:
1. R4 census (a dry run, not committed): substitute `initAdmission(.compile)` for every `JsParser.initTyped` test site, including the 20 sites in the tests of `parse.zig`. Run `zig build test-zts`. Record each test whose expectation changes, with its source, old value, and new value.
2. Owner checkpoint: admission refuses some sources that the typed parser accepts. The owner decides once, for the whole census, whether each difference is a test that used an unrealistic source or a production defect.
3. R4a: commit the test sites outside `typed_frontend_tests.zig`, by file group.
4. R4b-1: commit the mechanical substitution in `typed_frontend_tests.zig`. A grep count before and after proves that the commit changes only the entry call.
5. R4b-2: commit the hand edits. About three test blocks use both parse paths, and nine names say "legacy" or "parity". A test that compares two paths that are now the same function keeps its expected-value assertion. Delete it only when no expected-value assertion remains, and record the count.
6. R4c: delete `JsParser.initTyped`. Remove the boolean combination in `initWithProfile` that only it used.

Stop rule: no expectation is edited before the owner checkpoint. After the checkpoint, each change follows the owner's ruling for its census row.

Exit: `git grep -n 'JsParser.initTyped' -- packages` and `git grep -n 'initTyped' -- packages/zts/src/parser/parse.zig` print nothing. Each remaining typed test runs `initAdmission(.compile)`.

### R5. One IR construction path

Steps: move the 68 `add(Node)` call sites in `parse.zig` to `addNode`. Move the `IRStore.get` callers to the array accessors. Delete the adapter and the struct form that nothing else reads.

Exit: the R0 bytecode golden, the contract goldens, and the diagnostic corpus are unchanged. `bench-check` stays within its limits on a host with load under 4.

### R6. File splits by responsibility

Each sub-phase is code motion only, in one commit. Logic edits are not permitted in the same commit.
1. R6a: split `parser/type_syntax.zig` into the syntax store, the type parser, and the admission scanners. Add the new files to `scripts/zts-tiers.allow` at the tier of the source file.
2. R6b: split `precompile.zig` into the code generation CLI, the CHECK facade, contract and policy building, SQL schema validation, and reports. `precompile.zig` re-exports each public name. Add a new file that holds CHECK analysis to `scripts/check-proof-swallow.sh`, and update the file count in `AGENTS.md`. Update the paths in `tooling/production_branch_metric.zig`.
3. R6c: split `agent_protocol.zig` by operation. Keep `schemaHash` and the meta payload bytes unchanged.
4. R6d: move `ConnectionPool` from `server.zig` into its own file. Add the new path to `scripts/check-runtime-purity.sh`, so the zts-import check still covers it.
5. R6e: move inline tests out of a file only where tests are more than half of the file. Candidates include `flow_checker.zig` and `pipeline.zig`. Use sibling `*_tests.zig` files that the same test root imports.

Exit: `git show --color-moved=dimmed-zebra --stat` shows motion for each sub-phase. The per-step test counts equal the R0 counts.

### R7. One analysis session and one contract producer

Steps:
1. R7a: `ModuleAnalysisSession` keeps one `TypeEnvStorage`, one `TypeChecker`, one `ModuleFacts`, and one `FlowChecker` for each module. A profile selects passes.
2. R7b: `extractContract` applies the flow results itself. Delete `projectParsedFlow` and the two-step callers. Keep every default value.
3. R7c: census only. For each `tests/corpus` case and each cassette input, record where the bare checkers in `pi_repair_plan`, `pi_goal_check`, and `zts_expert_narrow` differ from the production session. The worklog holds the result. The move of the tools is class B (Decision 2).

Stop rule: a change to any contract golden, the `build_command.zig` digest pin, the R0 analyzer digests, a tool output, or a cassette replay stops the phase.

Exit: `pipeline.zig` declares one checker and one environment per module. `git grep -n 'projectParsedFlow'` prints nothing.

### R8. One type-expression grammar

Steps: route `TypeEnv.resolveType` callers for binding signatures, `ambient_names`, `returnsOkRecord`, and the signature census through the standalone annotation entry of the type parser. Delete `TypeExprParser` and `resolveType(text)`.

Stop rule: any change to the signature census or to a module export type stops the phase.

Exit: `git grep -n 'TypeExprParser'` prints nothing.

### R9. One diagnostic surface and one property vocabulary

Steps:
1. R9a: add compile-time coverage checks between `HandlerProperties` and each property enum. Do not reorder any enum.
2. R9b: first, census the five `formatDiagnostics` functions and record where their formats differ. If they agree, route every diagnostic consumer through `diagnostic_projection` and replace them with one formatter that keeps each output byte. If they differ, route consumers through the projection, keep the formatters, and list the merge under Decision 2.

Exit: removing one field from `HandlerProperties` in a scratch copy fails compilation. Record that probe in the worklog. The diagnostic corpus and the expert goldens are unchanged.

### R10. One child visitor

Steps:
1. R10a: census. List each switch on node tags in the analysis files, with its default arm, in the worklog. Run the route reachability probe for `flow_interp` against `route_resolution.zig`.
2. R10b: add one child visitor for expressions and statements beside `IrView.expressionChildren`.
3. R10c and later: migrate one analysis file per commit. Order: `flow_interp`, `effect_inference`, `path_generator`, `handler_verifier`, `strict_checker`, `contract_builder`, `type_env`, `type_checker`.

Stop rule: a migration that moves a verdict, a diagnostic, or a golden stops. The worklog records the source and the before and after values. The owner decides whether that file's migration proceeds as a class B soundness repair.

Exit: each migrated walk uses the visitor in its default arm. `test-flow-census` reports fail-open 0 and the R0 over-refusal count.

### R11. Runtime and expert consolidations

Steps:
1. R11a (F10): first add the regression test for `--_debug-panic-path` before the handler path. Then make one table of value-taking serve flags, read by `findPositionalPath` and `parseServeArgs`.
2. R11b (F13): move the shared provider decode and sanitize code into one module. Pass the reasoning rule as a parameter. Check that both request bodies stay byte-identical.
3. R11c (F14): run only if a measurement in R0 step 8 failed. Pass the environment and the root directory into `AgentSession`, `tools/common`, and `change_transaction`, one file per commit. Move their tests off `EnvOverride` and `CwdOverride`. Keep `-j1`.
4. R11d (F15): `check-meta-drift.sh` reads the policy pin from `policy-hash.txt`. The other four pins and the expert goldens stay.

Exit: each sub-phase passes its gates. No cassette, golden, or published evidence file changes.

### R12. Package and gate consolidation

Steps:
1. R12a (F16): move `packages/proof-review` into `packages/runtime/src/proofs/`. Delete the package, its build wiring, and the `test-proof-review` step. Its tests join the runtime route.
2. R12b (F17): port the rejection probes of `check-module-boundary.sh` and `check-proof-checker.sh` to `tooling/zts_graph_gate.zig` first. Then add the two checks as subcommands under the same step names. Delete the two scripts and the wrapper test. Amend D-005 in `docs/decisions.md` in the same commit.
3. R12c (F17, Decision 5): first rework the kernel safety probes in `scripts/test-gate-floors.sh` to pass the built tool path. Then delete the no-argument fallback branches of the seven shell gates.
4. R12d-1 (F17): add a route field (aggregate, verify, release, or manual) with a reason to each task in `agents.json`. Make `check-spine` check it. Keep the allowlists.
5. R12d-2 (F17): run a parity probe. Delete one row from each allowlist in a scratch copy, and confirm that `check-spine` fails on the same task. Then generate the testing tables with `check-spine --write`, and delete `manual-steps.allow`, `manual-scripts.allow`, and the table comparison in `check-docs-drift.sh`.

Stop rule for R12b: each ported probe must fail on the same input as before. The D-005 zon check (`.dependencies = .{}`) stays.

Exit: the gate count, the allowlist row count, and the script count are lower than at R0. Each deleted check has a named successor that fails on its old rejection inputs.

### R13. Final documentation and archive

Steps:
1. Update `docs/internals/architecture.md`, `docs/internals/testing.md`, `CONCEPTS.md`, `AGENTS.md`, the area `AGENTS.md` files, and `CLAUDE.md` where they name moved files, removed steps, or removed packages.
2. Add decision entries to `docs/decisions.md`: tests use the production parse mode, each fact has one producer, and model-visible changes wait for a batched re-record window. Confirm that the R12b amendment of D-005 is present.
3. Replace `.agents/skills/zttp-models/SKILL.md` with a symbolic link to `../../../.claude/skills/zttp-models/SKILL.md`, the same form as `zttp-build`.
4. Create a local tag at the commit before the archive. Delete the completed plans and worklogs that no tracked file outside `docs/plans/` cites. Keep this plan and its worklog. List each deleted file in the worklog.
5. Update the roadmap and the plan index to the final state.

Exit: the documents describe the final design. Links, the spine, and the drift gates pass.

## Verification

### Common rules

Every phase uses a private cache and an offline provider configuration:

```bash
export ZIG_LOCAL_CACHE_DIR=/private/tmp/claude-501/zttp-reset-20261025/local
export ZIG_GLOBAL_CACHE_DIR=/private/tmp/claude-501/zttp-reset-20261025/global
unset DEEPSEEK_API_KEY
```

Each command writes its output to a log file. The verdict is the direct exit status, not a grep:

```bash
zig build test-zts > /tmp/zttp-reset/test-zts.log 2>&1; echo "exit=$?"
```

A filtered run (`-Dtest-filter`) is never evidence. A Build Summary that shows "failed command" for a passing step is not a failure; read the leaf failures.
The implementer runs `git add` before `zig build check-spine`, because the spine reads tracked files only.
Documents cite `file` or `file#symbol`, never a file and line number.

Every class A phase ends with this protection check against the phase base commit:

```bash
git diff --exit-code <phase-base> -- packages/tools/tests/fixtures tests/corpus \
  packages/pi/src/simulator/testdata packages/pi/src/prompts \
  packages/zts/src/fixtures packages/modules/module-specs tooling/fixtures \
  policy-hash.txt docs/convergence.json docs/convergence.md \
  docs/coverage.json docs/coverage.md benchmarks/perf-baseline.json
```

R0 adds the bytecode golden to this list after it is committed.
Every phase from R4 on also reruns R0 step 6 and compares the result with the R0 digest file:

```bash
command cmp /private/tmp/claude-501/zttp-reset-20261025/analyzer-digests.txt <phase output file>
```

R11d is the one phase that edits `scripts/check-meta-drift.sh`. Its policy pin moves to a read of `policy-hash.txt` with an unchanged value.

Every phase ends with `zig build test` and `zig build check-spine`, both exit 0.
The test count of each named step equals the R0 count, or the worklog explains each change.

### Phase gates

| Phase | Exact additional commands, each exit 0 |
|---|---|
| R0 | `bash scripts/verify.sh`; the bytecode digest test twice from an empty cache |
| R1 | `zig build test-doc-links`; `zig build test-docs-drift` |
| R2 | `zig build test-zts`; `zig build test-zts-layering`; `zig build test-module-boundary`; `zig build test-proof-swallow` |
| R3 | `zig build test-zts`; `zig build test-precompile` |
| R4 | census: `zig build test-zts` on the dry run; commits: `zig build test-zts`; `zig build test-zts-cli`; `zig build test-diagnostic-corpus`; `zig build test-standin`; `zig build test-precompile` |
| R5 | `zig build test-zts`; `zig build test-zruntime`; `zig build test-examples`; `zig build test-contract-golden`; `zig build test-meta-drift`; `zig build test-proof-checker`; `zig build bench-check -Doptimize=fast` |
| R6a | `zig build test-zts`; `zig build test-zts-layering`; `zig build test-diagnostic-corpus` |
| R6b | `zig build test-precompile`; `zig build test-agent-protocol`; `zig build test-contract-golden`; `zig build test-proof-swallow`; `zig build test-module-boundary`; `zig build test-cli`; `zig build test-production-branch-metric` |
| R6c | `zig build test-agent-protocol`; `zig build test-expert-golden`; `zig build test-agent-determinism`; `zig build test-meta-drift` |
| R6d | `zig build test-server`; `zig build test-zruntime`; `zig build test-panic-isolation`; `zig build test-runtime-purity` |
| R6e | `zig build test-step-coverage`; the per-step counts equal R0 |
| R7 | `zig build test-zts`; `zig build test-precompile`; `zig build test-contract-golden`; `zig build test-cli`; `zig build test-zruntime`; `zig build test-expert-app`; `zig build test-standin`; `zig build test-diagnostic-corpus`; `zig build test-flow-census`; `zig build test-expert-golden` |
| R8 | `zig build test-modules`; `zig build test-zts`; `zig build test-precompile`; `zig build test-flow-census` |
| R9 | `zig build test-diagnostic-corpus`; `zig build test-expert-golden`; `zig build test-cassette`; `zig build test-meta-drift`; the scratch compile probe fails |
| R10 | per file: `zig build test-flow-census`; `zig build test-standin`; `zig build test-diagnostic-corpus`; `zig build test-proof-swallow`; `zig build test-contract-golden` |
| R11a | `zig build test-cli`; `zig build test-zruntime` |
| R11b | `zig build test-cassette`; `zig build test-expert-app`; `zig build test-recorder-smoke` |
| R11c | `zig build test-expert-app`; `zig build test-standin` |
| R11d | `zig build test-meta-drift`; `zig build test-expert-golden`; `zig build release-provenance` |
| R12a | `zig build test-cli`; `zig build test-step-coverage`; `zig build test-docs-drift`; `zig build test-module-boundary`; `zig build test-production-branch-metric` |
| R12b | `zig build test-module-boundary`; `zig build test-proof-checker-purity`; `zig build test-zts-layering`; `zig build test-native-gates`; each ported probe fails on its old input |
| R12c | `zig build test-script-reachability`; `bash scripts/test-gate-floors.sh`; the reworked kernel safety probes fail on the empty and short lists |
| R12d-1, R12d-2 | `zig build test-spine`; `zig build test-step-coverage`; `zig build test-script-reachability`; `zig build test-docs-drift`; R12d-2: the scratch allowlist probe fails |
| R13 | `zig build test-doc-links`; `zig build test-docs-drift`; `bash scripts/verify.sh` |

`bench-check` fails under host load. Run it only when the load average is under 4, and record the load.

## Execution rules

Opus dispatches each phase to a Sonnet implementer with the phase text, the common rules, and the private cache paths.
Opus reviews each diff line by line, runs the phase gates itself, and commits each phase or sub-phase on local `main`.
No push, branch, provider call, golden regeneration, or corpus re-record is authorized by this plan.
A phase that fails its gates twice goes to a Fable advisor with the evidence before a third attempt.

## Owner decisions

Decision 1: scope of execution.
- (a) Approve phases R0 to R13 as written. Recommended.
- (b) Approve R0 to R6 and R11 to R13 only. Defer R7 to R10, the analyzer consolidations.
- (c) Do not approve.

Decision 2: model-visible changes.
- (a) Keep them out of this reset. Record them as one later re-record window. Recommended, because every reset phase then stays provable by offline replay.
- (b) Add one batched re-record phase after R13.
The window would hold:
- the expert recording cutover from cassettes to the simulator;
- one analyzer route for pi tools, informed by the R7c census;
- the proof defaults (round 4 unit U12);
- the unreachable IR tags and opcodes (round 4 unit U13);
- removal of the admission replay, and a move of virtual JavaScript onto admission;
- a policy-hash placeholder in the five expert goldens (F15);
- a formatter merge if the R9b census shows different formats;
- the "Lambda auto-retry" report text in `precompile.zig`;
- any class B result from R4, R7, R8, or R10.

Decision 3: the `-Dhandler` build path.
- (a) Keep it unchanged. Recommended, because removal changes public build behavior.
- (b) Make it a wrapper that builds the self-extracting artifact.
- (c) Remove it.

Decision 4: archive of completed plans in R13.
- (a) Archive under a local tag the completed plans that no tracked file outside `docs/plans/` cites, as in rounds 2 and 3. Recommended.
- (b) Keep all plans.

Decision 5: unused fallback branches of the seven shell gates.
- (a) Delete them in R12c, after the kernel safety floor probes in `scripts/test-gate-floors.sh` pass the built tool path. Recommended, because the build never runs the fallbacks, and that probe is their one user.
- (b) Keep them as direct entry points, as round 4 unit U11 did.

Answer Decisions 1 to 5. A one-word answer such as "as recommended" covers all five and selects option (a) for each.
Acceptance of this plan as a report is not approval to edit. Decision 1 (a) or (b) authorizes the selected phases.

## Validation record

Fable reviewed the first draft read-only at `75594cc8` and reported 12 findings, five of them major.
The author checked each load-bearing claim against the repository before acting on it.
All 12 are accepted; none is rejected.

| Finding | Severity | Disposition |
|---|---|---|
| V1. F1 claimed that all production parsing uses admission; virtual JavaScript uses the untyped `JsParser.init` | Major | F1 rewritten to name both production modes. R4 adds the 20 `parse.zig` test sites and a second exit grep. Virtual JavaScript on admission moves to Decision 2 |
| V2. R7c would move model-visible pi output, which Decision 2 reserves | Major | R7c is now a census only. F3 corrected: only `pi_goal_check` also runs the production check |
| V3. R11d cannot remove the hash from the expert goldens without moving protected files | Major | R11d narrowed to the policy pin in `check-meta-drift.sh`. The golden placeholder moves to Decision 2 |
| V4. `.agents/skills/zttp-build` is already a symbolic link; the proposed direction loops | Major | F18 and R13 corrected. Only `zttp-models` is linked, in the existing direction |
| V5. Goldens are too few to prove R7 to R10 preservation; R9b assumed the formatters agree | Major | R0 adds analyzer output digests over 215 corpus and example sources. R9b starts with a format census and has a stop rule |
| V6. The protection list missed fixture, spec, prompt, and rendered evidence paths | Minor | Six path groups added |
| V7. R12b replaces a script that D-005 binds by name | Minor | R12b amends D-005 in the same commit |
| V8. Decision 5 said no test covers the fallbacks; `test-gate-floors.sh` uses one | Minor | Decision 5 and R12c corrected; the probe is reworked first |
| V9. R2, R3, and R4a share files | Minor | One worker runs them in order; R11 is the parallel worker |
| V10. Phase gate lists missed the layering, purity, metric, and corpus gates | Minor | Gates added to R6a, R6b, R6d, R7, and R12a. R6b and R6d update the path lists |
| V11. R4b, R11c, and R12d were too large or weakly linked | Minor | R4 gets a dry-run census and one owner checkpoint, and R4b splits in two. R11c runs only if the R0 measurement fails. R12d splits in two with a parity probe |
| V12. Stale numbers and two omissions | Minor | Baseline note added. Call-site counts corrected. `flow_checker.zig` named for R6e. U13 and the `legacy_parser` comment added |

## Definition of done

Each selected phase has a commit, or the worklog records a stop-rule result and the owner decision.
Every class A phase passed its protection check, its phase gates, `zig build test`, and `zig build check-spine`.
The final tree passed `bash scripts/verify.sh`.
The documents name one reset authority, and each moved or deleted surface is reflected in them.
The worklog lists every class B item that waits for Decision 2.
