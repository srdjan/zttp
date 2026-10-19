# Repository Guidelines

## Project Structure & Module Organization
- `packages/runtime/src/zruntime_tests.zig` is the end-to-end test root behind `zig build test-zruntime`, not a peer of the unit tests beside the code.
- `zig-out/` and `.zig-cache/` are generated output directories; do not edit or commit them.

## Documentation

| File | Purpose |
|------|---------|
| `docs/user-guide.md` | The single guide: handler API, routing, virtual modules, CLI options, JS/TS subset, JSX/TSX, local deploy and proof receipts, troubleshooting |
| `docs/internals/architecture.md` | System design, runtime model, project structure |
| `docs/performance.md` | Benchmarks, cold starts, optimizations, deployment patterns |
| `docs/internals/api-reference.md` | Zig embedding API, extending with native functions |
| `docs/typescript.md` | Type stripping, type checking, sound mode (type-directed analysis across operators), compile-time evaluation (`comptime()`) |
| `docs/feature-detection.md` | Unsupported feature detection matrix |
| `docs/verification.md` | `-Dverify` compile-time proof of handler correctness |
| `docs/roadmap.md` | What is deferred from the current beta and what comes next |
| `docs/convergence.md` | Measured first-draft veto-pass rate over the frozen prompt corpus; regenerate with `scripts/update-convergence.sh` |
| `docs/coverage.md` | Which advertised rules the corpus trips, and what the offline suite does and does not prove; regenerate with `scripts/update-coverage.sh`. The replay fails when it drifts |
| `docs/solutions/` | Categorized solutions to past bugs and engineering problems, searchable by YAML frontmatter (`module`, `tags`, `problem_type`); relevant when implementing or debugging in documented areas |
| `CONCEPTS.md` | Shared domain vocabulary - entities, named processes, and status concepts with project-specific meaning; relevant when orienting to the codebase or discussing domain concepts |

## Coding Style & Naming Conventions
- No Python. This is a Zig project. Do not add a `.py` file and do not add a `python3` heredoc or `-c` invocation to a shell script. New tooling is a Zig command or a Zig build step. Existing Python (three tracked `.py` scripts under `scripts/`, plus eleven shell scripts that invoke `python3`) is legacy to be removed as each area is touched, never a precedent to extend.
- Keep APIs explicit: the engine/runtime use native Zig error unions (`!T`); `Result<T>` is a user-facing JS/verification construct in handlers, not a Zig engine pattern.
- Shell scripts that enumerate files should use `git ls-files -z | xargs -0` for safe path handling (handles spaces and special characters).

## Testing Guidelines
- Tests live alongside code using Zig `test "..."` blocks (no separate test directory).
- `docs/internals/testing.md` maps the build steps: what `zig build test` runs, what it leaves to `scripts/verify.sh`, and why `test-zruntime` is standalone.
- Name tests with concise behavioral descriptions (e.g., `test "runtime init and deinit"`).
- Runtime and ZTS tests live beside the affected code in `packages/runtime/` or `packages/zts/`; run the relevant `zig build test*` step.
- Reaching a new `zts` internal module (anything in the internal tier of `packages/zts/src/root.zig`) from `runtime`, `tools`, `pi`, or `proof-review` needs a row in `scripts/module-boundary.allow`, and a row that nothing uses fails the same gate. Prefer the curated surface at the bottom of `root.zig`; widen the allowlist only deliberately, and say why in the commit. Run `zig build test-module-boundary`.
- Discarding an error in the analysis files that decide whether a program is proven (the seventeen listed in `scripts/check-proof-swallow.sh`, which cover the producer, three files of the consumer-side acceptance kernel - `checker.zig`, `capability_policy.zig`, and `wire.zig` - and `proof_activation.zig`) needs a row in `scripts/proof-swallow.allow` with the reason it cannot weaken a verdict, and a row nothing matches fails the same gate. A swallow there does not surface as a failure, it surfaces as a pass. Run `zig build test-proof-swallow`. The gate sees discarded errors, not wrong answers: a function that returns a value claiming more than it checked passes it, and five such fail-opens shipped past it in the flow checker - see [docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md](docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md) for the class and the probe method that finds it. The class recurred once more in `validateJson`, `coerceJson`, and `decodeJson`, which relabelled their output from their own contract rather than from their input, so a secret routed through any of them reached the response with `no_secret_leakage` PROVEN. Fixed: an export that derives its return value from its arguments discharges `user_input` and nothing else - see [docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md](docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md). The class also recurred one level up, as a function the walk never entered: route functions dispatched through `routerMatch` were not flow roots, so a routed leak proved all six flow properties - see [docs/solutions/security-issues/a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md](docs/solutions/security-issues/a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md). When adding such an export, probe it: return a labelled value directly, confirm it is refused, then route the same value through the new export and check the diagnostic is still there. Assert the property the export could launder - `no_secret_leakage` - and not a neighbour like `deterministic`: substituting the easier assertion is why the class survived in `cacheGet`, `queue.receive`, `sqlOne`, `sqlMany` and `durable.waitSignal`, whose only round-trip test asserted `runDeterministic`. The class is not bounded by those eleven files: the same conflation later shipped in `packages/pi`, where no such gate exists, and destroyed a file - see [docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md](docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md).
- Adding an advertised rule needs either a defect seed in `packages/pi/src/standin/defect_seeds.zig` that is observed tripping it, or a row in `scripts/unseeded-rules.allow` giving the reason a seed cannot reach it; a row for a code a seed now verifies fails the same gate. Both directions run inside `zig build test-standin`. The list is not a backlog and it only ratchets down: it once carried nineteen rows and now carries 1 row (`ZTS508 non-default`), and all eighteen that went were closed by giving a rule a producer or by deleting a rule no execution order could surface, never by writing a seed. The reason belongs beside the row rather than in a reader's assumption about what `docs/coverage.md` leaves out. A row naming a code the registry advertises and nothing constructs is a false advertisement in a hashed policy surface; `scripts/check-diagnostic-producers.sh` is what catches that shape now, because a gate keyed on the code cannot - three dead variants shared ZTS500/501/502 with a live producer and were permanently satisfied by it.
- An export that reads persistent cross-call state - a cache, a queue, a SQL table, a durable signal - declares `.unknown` in its `return_labels`, alongside whatever kind of store it is. It hands back a value some separate write put there, and the read call holds no reference to that value, so no dataflow rule can reach it and only the binding knows. `derives_from_args` is a **no-op** for this shape and closing the finding with it leaves the fail-open open: `argDerivedLabels` unions only the current call's own arguments, which for `cacheGet("ns", "k")` are two string literals. `derives_from_args` is the right answer for a pass-through, where the return *is* an argument; the retired `returns_from_param` binding field is no longer part of the API. Expect `.unknown` to move a verdict from PROVEN to unproven rather than to refused; an export deriving its result from the limiter's or the generator's own state, like `rateCheck` or `uuid`, is not this shape.
- A declassifier - an export whose declared labels replace its input's rather than joining them - names the argument that bounds it in `declassify_bound_arg`, and the declassification holds only while that argument is a compile-time literal. `mask(text, visible)` reveals the trailing `visible` bytes, so a runtime `visible` puts the magnitude of the declassification in whatever computes it.
- A gate asserts a floor on its own input before any count it reports means anything. A gate whose corpus is empty, whose filter matches no test, or whose build product nothing depends on reports success while checking nothing, and is then cited as evidence. `scripts/check-runtime-purity.sh` and `scripts/check-docs-drift.sh` already do this; see [docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md](docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) for the four shapes and the delete-its-input check. The floor is necessary and not sufficient: a gate holding a full input can still assert something weaker than its own name, so that runs in which the named behavior never happened satisfy it too - assert the value expected, not a difference from the values excluded. And a probe is code: one that does not compile runs no check, and since a failed build and a passing gate both emit no failure message, read a probe's verdict from the build's exit status rather than from a grep over its output. See [docs/solutions/conventions/difference-is-not-the-claim-and-a-probe-must-compile.md](docs/solutions/conventions/difference-is-not-the-claim-and-a-probe-must-compile.md). A gate that satisfies both of those can still be porous: its probes show that the cases their author named are caught and say nothing about the cases nobody named, and reading the source does not expose the gap, because the hole is in what the gate never looks at. Find those by applying one edit to a copy of the gate's declared inputs and running the built gate binary against the copy, and close a round with a census rather than with one more probe - iterate the verdict enum and require every member to be probed or to carry an allowlist row that states a mechanism, because a check nobody probed produces no message and no count. Count per verdict, never per input or per file: two coverage tests here counted 21 inputs and 19 name-matched checks while 23 checks had never been observed rejecting anything. A gate whose subject is an open vocabulary must also say which threat it bounds instead of leaving a reader to assume it bounds every one. See [docs/solutions/conventions/a-gate-can-be-non-vacuous-and-still-porous.md](docs/solutions/conventions/a-gate-can-be-non-vacuous-and-still-porous.md). Two concrete forms of this bite in this repository. `-Dtest-filter` is wired to `.filters` on every test artifact (`build/Context.zig`), so an artifact the filter matches nothing in runs zero tests and exits 0: a filtered run was measured reporting "2 passed" while the named test's assertion was sabotaged to expect an impossible error, because that run executed none of them. Never cite a `-Dtest-filter` run as evidence; take every verdict from an unfiltered run of the named step. And `zig build <step> | tail -n` followed by `$?` reports the status of `tail`, not of the build, so redirect to a file and read the exit status directly.

## Commit Guidelines
- Commit history is informal; keep subjects short and descriptive (lowercase is common). Use `WIP-#:` only for intentional multi-step series.

## Security & Configuration Notes
- Preserve path traversal checks in `packages/runtime/src/server.zig`.
- Runtime isolation depends on `HandlerPool`/`LockFreePool`; avoid introducing shared mutable state between requests.

## Agent spine

`agents.json` classifies every task from the live Zig build graph.
`docs/decisions.md` records standing decisions and superseded decisions.
Marked area contracts state ownership, boundaries, invariants, and the gates that check those invariants.

`zig build brief -- <path>` reports the rules that govern a repository file.
`zig build check-spine` checks the manifest, contracts, ledger, solution bindings, source anchors, and generated blocks.
`zig build check-spine -- --write` regenerates the blocks after every other spine check passes.
`zig build test-spine` runs the native behavior tests and rejection probes.
The aggregate `zig build test` runs the spine check and its tests.

The spine checks structural links. The named behavior suites establish the corresponding behavior.
`bash scripts/verify.sh` remains the full local gate and runs the standalone runtime root separately.
The spine checks task declarations against the graph. Task effects require source review because Zig has no Deno permission flags.
The native port and its limits are described in `docs/internals/agent-spine.md`.

### Areas

<!-- generated: areas -->

| Area | Owns |
| --- | --- |
| [`build/`](build/AGENTS.md) | This area owns the root Zig build graph, package wiring, named tasks, and aggregate task reach. |
| [`packages/modules/`](packages/modules/AGENTS.md) | This area owns native implementations and binding metadata for each `zttp:` virtual module. |
| [`packages/pi/`](packages/pi/AGENTS.md) | This area owns the expert loop, provider adapters, deterministic stand-in, veto, transcripts, and change receipts. |
| [`packages/proof-checker/`](packages/proof-checker/AGENTS.md) | This area owns the consumer acceptance kernel. |
| [`packages/runtime/`](packages/runtime/AGENTS.md) | This area owns the CLI, server, request isolation, artifact activation, and the bridge to the analyzer. |
| [`packages/zts/`](packages/zts/AGENTS.md) | This area owns parsing, analysis, bytecode, proof facts, and the interpreter for the restricted TypeScript profile. |
| [`scripts/`](scripts/AGENTS.md) | This area owns repository shell gates, allowlists, regeneration commands, and the canonical verification script. |
| [`tooling/`](tooling/AGENTS.md) | This area owns native repository gates, measurements, evidence generation, and agent-spine navigation. |
<!-- end generated: areas -->

### Gates

<!-- generated: gates -->

| Gate | Proves | Required when | Measured |
| --- | --- | --- | --- |
| `zig build test-zts` | runs all zts tier unit-test roots | after analyzer, compiler, interpreter, or binding changes | not measured |
| `zig build test-sdk` | runs zttp-sdk tests | after SDK contract changes | not measured |
| `zig build test-modules` | runs virtual-module implementation tests | after virtual-module behavior or binding changes | not measured |
| `zig build test-proof-checker` | runs consumer acceptance-kernel tests | after proof-checker or certificate changes | not measured |
| `zig build test-proof-checker-mutants` | runs committed acceptance-kernel mutants | after acceptance logic or mutation coverage changes | not measured |
| `zig build test-proof-checker-purity` | checks the kernel leaf boundary and suite floor | after proof-checker source or dependency changes | not measured |
| `zig build test-script-reachability` | checks that each repository script has a declared route | after script or build-graph changes | not measured |
| `zig build test-diagnostic-producers` | checks that each advertised diagnostic has a producer | after diagnostic-registry changes | not measured |
| `zig build test-proof-ratchet-drift` | checks the published trusted boundary against the kernel | after proof boundary or kernel changes | not measured |
| `zig build test-residual-guards-drift` | checks residual guard catalogs, evidence, and documentation | after residual-guard changes | not measured |
| `zig build test-proof-ratchet` | checks disclosed trust against kernel reconstruction | after proof-ratchet changes | not measured |
| `zig build test-proof-review` | runs proof-review package tests | after proof-review changes | not measured |
| `zig build test-precompile` | runs precompile and CHECK behavior tests | after precompile or CHECK changes | not measured |
| `zig build test-canonicalize` | runs canonicalize and normalize tests | after source-repair or normalization changes | not measured |
| `zig build test-expert` | runs expert command contract tests | after expert command changes | not measured |
| `zig build test-zts-cli` | runs analyzer dispatch and machine-command tests | after zts CLI changes | not measured |
| `zig build test-deploy-manifest` | runs deploy-manifest renderer tests | after deploy-manifest changes | not measured |
| `zig build test-agent-identity` | runs agent identity primitive tests | after agent identity changes | not measured |
| `zig build test-module-graph-record` | runs module graph and digest tests | after module graph record changes | not measured |
| `zig build test-agent-protocol` | runs agent protocol envelope tests | after agent protocol changes | not measured |
| `zig build test-module-audit` | runs module-contract audit tests | after module-contract audit changes | not measured |
| `zig build test-verify-paths-core` | runs behavior-path verification core tests | after verification path changes | not measured |
| `zig build test-project-config` | runs project configuration discovery tests | after configuration discovery changes | not measured |
| `zig build test-instruction-counter` | runs retired instruction-counter tests | after instruction counter changes | not measured |
| `zig build test-expert-app` | runs expert loop and provider integration tests | after expert loop or provider changes | not measured |
| `zig build test-cassette` | runs the offline provider cassette harness | after cassette or provider wire changes | not measured |
| `zig build test-recorder-smoke` | runs provider-free recorder capture and replay | after recorder changes | not measured |
| `zig build test-simulator` | runs the offline full-flow simulator | after simulator or fail-closed flow changes | not measured |
| `zig build test-standin` | runs the deterministic stand-in through the expert loop | after stand-in, veto, or rule changes | not measured |
| `zig build test-expert-mlx-e2e` | uses the operator's configured MLX server for a real model flow | only when the operator requests local model use | not measured |
| `zig build test-diagnostic-corpus` | checks diagnostic corpus cases against committed goldens | after diagnostics or corpus changes | not measured |
| `zig build test-flow-census` | checks leak verdicts over the generated flow census | after flow-checker or binding-label changes | not measured |
| `zig build test-capability-audit` | checks capability helper declarations | after capability helper changes | not measured |
| `zig build test-native-gates` | runs native repository gate tests | after native gate changes | not measured |
| `zig build test-evidence-publish` | runs native evidence publisher tests | after evidence publisher changes | not measured |
| `zig build release-provenance` | validates release evidence provenance | before release readiness is claimed | not measured |
| `zig build test-release-provenance` | runs release provenance tests | after provenance validation changes | not measured |
| `zig build test-coverage-union` | runs coverage-union tests | after coverage-union changes | not measured |
| `zig build release-check` | prints the repository release-readiness passport | before release readiness is claimed | not measured |
| `zig build test-release-check` | runs release-passport tests | after release passport changes | not measured |
| `zig build test-production-branch-metric` | tests and runs the production branch metric | after branch metric changes | not measured |
| `zig build test-kernel-safety` | checks acceptance-kernel runtime safety under release optimization | after kernel guards or build modes change | not measured |
| `zig build test-module-boundary` | checks consumer access to zts internals | after imports across the zts boundary change | not measured |
| `zig build test-release-workflow` | checks release script invariants | after release script changes | not measured |
| `zig build test-proof-swallow` | checks proof analysis for unreviewed discarded errors | after proof pipeline error handling changes | not measured |
| `zig build test-zts-layering` | checks that zts tiers import only lower tiers | after zts imports or tier assignments change | not measured |
| `zig build test-convergence-emitter` | checks the convergence marker producer and consumer | after convergence evidence changes | not measured |
| `zig build test-evidence-marker` | checks evidence marker and publisher boundaries | after evidence marker or publisher changes | not measured |
| `zig build test-docs-drift` | checks documentation against registries and build paths | after documented registries or paths change | not measured |
| `zig build test-idiom-table` | checks the specification idiom table against the registry | after idiom or rule changes | not measured |
| `zig build test-canonical-style` | checks canonical-style examples against the rule registry | after canonical rules or examples change | not measured |
| `zig build test-grammar-drift` | checks specification grammar against the registry | after grammar or registry changes | not measured |
| `zig build test-decision-registry` | checks that each published decision kind has a producer | after decision-kind changes | not measured |
| `zig build test-meta-drift` | checks published registry hashes against their pins | after registry identity changes | not measured |
| `zig build test-doc-links` | checks documentation links | after documentation path or link changes | not measured |
| `zig build test-runtime-purity` | checks shipped binaries for agent and provider surfaces | after runtime, analyzer, or provider changes | not measured |
| `zig build test-module-governance` | runs the module governance audit | after module governance changes | not measured |
| `zig build test-contract-golden` | checks analyzer contract output against goldens | after contract output changes | not measured |
| `zig build test-generic-intersection-cli-matrix` | runs generic-intersection rejection and contrast fixtures | after generic intersection behavior changes | not measured |
| `zig build test-expert-golden` | checks the zts direct-tool contract against goldens | after expert tool output changes | not measured |
| `zig build test-cli` | runs developer CLI unit tests | after CLI behavior changes | not measured |
| `zig build test` | runs the aggregate unit and repository test graph | before any repository change is complete | not measured |
| `zig build test-zruntime` | runs the standalone ZRuntime test root | after runtime engine or artifact activation changes | not measured |
| `zig build test-server` | runs server and runtime facade integration tests | after server or runtime facade changes | not measured |
| `zig build test-examples` | runs example handler suites | after examples or public handler behavior changes | not measured |
| `zig build test-cli-abuse` | runs the built analyzer against hostile CLI input | after analyzer process or machine output changes | not measured |
| `zig build bench-check` | compares benchmark results with the committed baseline | after performance-sensitive runtime changes | not measured |
| `zig build test-bench-diff` | runs benchmark sampling and comparison tests | after benchmark tooling changes | not measured |
| `zig build smoke-v1` | runs the v1 user flow in a temporary directory | after core CLI workflow changes | not measured |
| `zig build test-module-scope-panic` | checks module authorization isolation after a recovered panic | after module authorization or panic recovery changes | not measured |
| `zig build test-panic-isolation` | runs handler panic isolation end to end | after handler isolation or panic recovery changes | not measured |
| `zig build smoke-getting-started` | runs the Getting Started guide in a temporary directory | after the guide or first-run workflow changes | not measured |
| `zig build test-compile-bench` | runs compile benchmark harness tests | after compile benchmark changes | not measured |
| `zig build test-step-coverage` | checks that every build step has an execution route | after build task or aggregate changes | not measured |
| `zig build check-spine` | checks the installed agent spine against the live repository graph | before any repository change is complete | not measured |
| `zig build test-spine` | runs agent-spine behavior tests and rejection probes | after agent-spine policy or tooling changes | not measured |
<!-- end generated: gates -->
