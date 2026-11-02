# `zttp check` parity and the 2026-11-01 re-record window

Status: approved by the owner on 2026-11-01, as the D-012 re-record window. The window covers unit G8 of the [module graph certificates plan](2026-11-01-module-graph-certificates-plan.md), unit 9d of the [reset plan](2026-10-30-reset-implementation-plan.md), one seed edit, and one DeepSeek re-record of the corpus. It covers no push, no deploy, and no release.

## Problem

`zttp build` runs every check on every module of a handler with file imports. `zttp check` checks the entry alone, with each file import untyped. Measured on 2026-11-01 at `7d9349f0` with `zts check --json`:

| Handler | Today |
|---|---|
| A dependency with a type error, or a generic export | Exit 1, with ZTS500 only: a default profile failure that does not name the cause |
| A named import that the target does not export | ZTS401 and ZTS500: the wrong cause |
| An import of a file that does not exist | ZTS401 and ZTS500: the wrong cause |
| `examples/handler/handler-with-imports.ts` | Exit 0, with one ZTS305 warning |

A handler with an authored capsule gets no ZTS500 of that kind, so a defect in a dependency can pass `zttp check` and fail `zttp build`. D-018 records this gap.

## Goal

For a handler with a file import, `zttp check` reports each refusal that `zttp build` makes, with a coded diagnostic that names the file at fault. A handler that passes `zttp check` passes `zttp build`. A single-module handler keeps its exact output.

## Decisions

The owner approved the window. I made these design decisions, and D-018 will record them.

1. **One implementation.** `zttp check` calls the graph checks and the contract merge of `zttp build`. It does not get a second copy, because two copies drift.
2. **The entry keeps the check path.** The entry runs the existing stages of `runCheckOnParsedSource`, on the parser of the graph and with typed imports. Each dependency runs `checkGraphModule`. The check result, the proof trace, and the policy report stay in one place.
3. **The merged contract replaces the entry contract** for a handler with file imports. The policy and spec reports then read the same facts as the build.
4. **Two new codes.** ZTS063 `module_link_refused`: the modules cannot run as one program. ZTS064 `file_import_untyped`: a file import has no type that can cross modules. Each refusal keeps its own message. A diagnostic in a dependency keeps its existing code, with the dependency in `file`.
5. **`markReachableChanges` returns on a link refusal.** The `zttp check` result already carries the coded refusal. Revised during W5: `discoverModulePaths` does not call `checkBindings`. Its only caller returns first, so the call would be dead code, and the paths of a graph with a binding refusal stay correct.
6. **`sibling-helper-holes` drops `cost_bounded` from its capsule.** Its seed dependency calls `env`, so the graph cannot establish that property, and the model cannot repair the seed. The re-record covers this seed edit.
7. **The proof fold runs in `zttp check`,** so that the Result limit refuses in check too. `error.GraphResultsNotProved` stays build-only: no real source reached it in 11 probes.

## Non-goals

No change to `packages/proof-checker`. No change to a single-module result. No new generic signatures across modules: the refusal stays. Freestanding builds keep today's behavior, because they have no file reader.

## Design

The driver is `runCheckOnParsedSource` in `packages/tools/src/precompile_check_run.zig`. After stage 3, and when the entry has a handler and a file import by the predicate that `compileHandler` uses, it builds a `GraphCheck`:

1. `ModuleGraph.build` through a reader that honors `CheckOptions.import_reader`. An error yields ZTS063 under the entry path.
2. `checkBindings`. A refusal yields ZTS063 with `bindingRefusalMessage`, under the path of the module at fault.
3. A parse of each dependency through `zts.DirectCheckSource`. A refusal yields the existing parser or admission codes under the dependency path. The dependency then stops the check.
4. `ModuleCompiler.compileAll` with fresh `AtomTable` and `StringTable` values that `GraphCheck` owns, and with `record_witnesses` true unless `skip_contract` is set.
5. `checkGraphModule` for each dependency, with a JSON sink. It stops at the first dependency that fails, as the build does.

The driver then swaps `parsed`, `atoms`, `ir_view`, `root`, and `handler_fn` to the entry parser of the graph and passes `file_import_signatures` to `initFull`. After `complete`, `firstUntypedFileImport` yields ZTS064.

Each later stage stays, with four changes for a graph:

- The flow pass takes `flowModulesForGraph`, as the build does.
- `state_isolated` folds the dependency facts.
- The entry evidence and the fold run after a clean verifier, and a fold error yields ZTS063.
- After stage 9, `mergeDependencies` unions the dependency contracts and folds the properties. The policy report and the spec report then read the merged contract, so stage 8b moves after the merge for a graph.

`already_mapped` moves past the dependency diagnostics, because `remapDiagnosticsToSource` applies the entry source to each later diagnostic. `checkGraphModule` maps a dependency diagnostic through the source of that dependency.

## Units

| Unit | Model | Files | Acceptance | Turns |
|---|---|---|---|---|
| W1. Reader in the graph | Sonnet | `module_graph.zig`, `precompile.zig`, `precompile_imports.zig` | `test-zts`, `test-precompile`. No output moves | 15 |
| W2. Sink and contract split | Sonnet | `precompile.zig`, `precompile_contract.zig`, `precompile_check_run.zig` | `test-precompile`, `test-cli`, `test-contract-golden`. `zts compile` output is byte-identical | 25 |
| W3. New codes | Sonnet | `diagnostic_catalog.zig`, `rule_registry`, `json_diagnostics.zig`, `defect_seeds.zig`, docs | `test-standin`, `test-diagnostic-producers`, `test-grammar-drift` | 25 |
| W4. Check driver | Sonnet | `precompile_check_run.zig`, `precompile_check_tests.zig`, `precompile.zig` | Failing tests first, then `test-precompile` and the parity table | 40 |
| W4b. Remove the replaced walker | Sonnet | `precompile_imports.zig`, `precompile_check_run.zig`, `proof-swallow.allow` | Digest equal to W4, `test-precompile`, `test-proof-swallow`. Added during W4 | 15 |
| W5. Reachability | Opus | `aggregate_proof.zig` | A refused root stays coded. A ZTS063 message reads the same on both scratch roots. `test-expert-app` names only the expected stale cassettes | 10 |
| W6. Unit 9d | Opus | `net/fetch.zig`, generated module spec, meta pin | `test-modules`, `test-docs-drift`, `test-meta-drift`, `test-expert-golden` | 10 |
| W7. Seed edit | Opus | `expert_codegen_record.zig` | The `sibling-helper-holes` seed passes `zts check`. The plan first asked this of the filled handler, which was wrong: `env` data is secret without a policy, so that handler gets ZTS400 before and after this plan | 5 |
| W8. Documentation | Opus | `decisions.md`, `verification.md`, `cli.md`, `user-guide.md`, `roadmap.md`, `README.md`, website | `test-doc-links`, `test-docs-drift`, `check-spine`, `deno task verify` | 15 |
| W9. Re-record | Owner or Opus | Corpus, pins, `docs/convergence.*`, `docs/coverage.*` | One case, then whole corpus, then replay offline | 25 |
| W10. Final gate | Opus | Worklog | Empty caches, no provider key, every step exit 0 | 15 |

## Parity table

W4 adds one table of literal cases. Each case is a set of files. Each row states the expected `zts check` code, the expected file, and that the compile also refuses. The table covers a dependency type error, a generic export, a mutated module binding, a missing export, a missing file, a cycle, an ambiguous binding, a reserved binding, a dependency that binds `handler`, a dependency top-level assert, a dependency parse error, an uncalled effect that fails the default profile, and an API schema conflict. It also holds three passing rows: `handler-with-imports`, `sibling-helper`, and a pure dependency. Each passing row must pass both.

## Risks

- **A deterministic replay needs stable paths.** A dependency path reaches the model. Each expert tool passes a workspace path, so its text is stable. The aggregate proof passes a scratch path. W5 found that a ZTS063 message carried that path, so `appendCheckDiagnostics` removes the scratch root from `file` and from the message.
- **Cost.** A graph check compiles each module. I will measure `zts check` on `handler-with-imports` before and after W4.
- **Evidence consumers.** `pr_gate` and `agent_protocol_check` read `file`. W4 tests a base side reader and a dependency diagnostic.

## Order of commits

W1 to W8 are separate commits. `test-expert-app` stays red from the first moved output until the corpus commit, and the worklog names that range. W9 then makes three commits in order: the corpus, the convergence report, the coverage report.
