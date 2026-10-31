# Repository Guidelines

## Project Structure & Module Organization
- `packages/runtime/src/zruntime_tests.zig` is the end-to-end test root behind `zig build test-zruntime`, not a peer of the unit tests beside the code.
- `zig-out/` and `.zig-cache/` are generated output directories; do not edit or commit them.

## Documentation

When a change adds an important feature or improvement, update `../ZTTP-WEBSITE` in the same work session.
Follow the website's `AGENTS.md` and `CLAUDE.md`. Keep claims tied to checked behavior and distinguish development changes from released features.
Run `deno task verify` before committing website changes. Commit locally and do not deploy or push without an explicit request.

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
- No Python. This is a Zig project. Do not add a `.py` file and do not add a `python3` heredoc or `-c` invocation to a shell script. New tooling is a Zig command or a Zig build step. Measured on 2026-10-21: `git ls-files '*.py'` lists no file, and no file under `scripts/`, `build/`, `tooling/`, or `packages/` invokes `python3`. Keep it that way.
- Keep APIs explicit: the engine/runtime use native Zig error unions (`!T`); `Result<T>` is a user-facing JS/verification construct in handlers, not a Zig engine pattern.
- Shell scripts that enumerate files should use `git ls-files -z | xargs -0` for safe path handling (handles spaces and special characters).

## Testing Guidelines
- Test behavior through a public surface: the `zttp` or `zts` command, the HTTP server, a `zig build` step, or a `pub` function of a package root. Do not assert private state, call order, or source layout.
- Assert what the user observes: stdout, stderr, exit status, response status and body, contract JSON, or the diagnostic code and location. Assert the exact expected value, not only a difference from a wrong value.
- Use real components. Use a simple in-memory double only at a slow, paid, or nondeterministic boundary: the model provider (use an offline cassette), the clock, or the network. Do not add a mocking framework or assertions on calls.
- When an integration test needs an external service, run the real service in Testcontainers. Do not write a fake of that service. SQLite runs in process and needs no container.
- Before you fix a bug, write a test that reproduces the bug. Run it and confirm that it fails for the reason of the bug. Then fix the bug, and record in the commit message that the test failed without the fix.
- Keep logic out of tests: no loops, branches, or computed expected values. Write literal expected values. A table of literal cases is permitted.
- Two kinds of test are exempt from the rule above: a census, which iterates every member of an enum or registry and fails when a member has no probe or allowlist row (such as `test-flow-census`), and a property test, which iterates generated inputs and asserts an invariant over each.
- Find missing tests with mutation tests and property-based tests. A committed mutant belongs beside its suite, as in `zig build test-proof-checker-mutants`. A property test uses a fixed `std.Random` seed and prints the seed on failure. Give each surviving mutant a test, or record why no test can kill it.
- Test a real user flow end to end. For the CLI, use the smoke steps (`zig build smoke-v1`, `zig build smoke-getting-started`). For a browser UI, such as `../ZTTP-WEBSITE`, use Playwright MCP against the running site, and close each browser session that you open.
- Tests live alongside code using Zig `test "..."` blocks (no separate test directory).
- `docs/internals/testing.md` maps the build steps: what `zig build test` runs, what it leaves to `scripts/verify.sh`, and why `test-zruntime` is standalone.
- Name tests with concise behavioral descriptions (e.g., `test "runtime init and deinit"`).
- Runtime and ZTS tests live beside the affected code in `packages/runtime/` or `packages/zts/`; run the relevant `zig build test*` step.
- Analyzer tests parse typed TypeScript through `JsParser.initAdmission(allocator, type_allocator, source, .compile)`, the mode that production uses. Do not add a test-only parse mode.
- Reaching a new `zts` internal module (anything in the internal tier of `packages/zts/src/root.zig`) from `runtime`, `tools`, or `pi` needs a row in `scripts/module-boundary.allow`, and a row that nothing uses fails the same gate. Prefer the curated surface at the bottom of `root.zig`; widen the allowlist only deliberately, and say why in the commit. Run `zig build test-module-boundary`.
- Discarding an error in the analysis files that decide whether a program is proven (the thirty-four listed in `scripts/check-proof-swallow.sh`, which cover the producer, six more analysis files that decide `equivalent`, ZTS205, boolean gating, and `canonical` (`contract_diff.zig`, `match_analysis.zig`, `bool_checker.zig`, `behavior_canonical.zig`, `ir_identity.zig`, `strict_checker.zig`), three files of the consumer-side acceptance kernel - `checker.zig`, `capability_policy.zig`, and `wire.zig` - `proof_activation.zig`, and the CHECK files `precompile_check_run.zig`, `precompile_contract.zig`, and `precompile_imports.zig`) needs a row in `scripts/proof-swallow.allow` with the reason it cannot weaken a verdict, and a row nothing matches fails the same gate. A swallow there does not surface as a failure, it surfaces as a pass. A walk over node tags that ends in `else => {}` is the same class: the pass reports a verdict for children it never read. A new walk descends through `IrView.expressionChildren` in its default arm, and a spread operand is read with `getOptValue`, not `getUnary`. Run `zig build test-proof-swallow`. The gate sees discarded errors, not wrong answers: a function that returns a value claiming more than it checked passes it. That class shipped five fail-opens in the flow checker ([empty-label-set-claimed-a-value-was-clean](docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md), which also gives the probe method), then in `validateJson`, `coerceJson`, and `decodeJson` ([validate-json-strips-the-label-it-was-asked-to-check](docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md)), then in routes dispatched through `routerMatch` ([a-dispatched-route-was-never-walked-so-its-leak-proved-clean](docs/solutions/security-issues/a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md)). An export that derives its return value from its arguments discharges `user_input` and nothing else. When adding such an export, probe it: return a labelled value directly, confirm it is refused, then route the same value through the new export and check the diagnostic is still there. Assert the property the export could launder - `no_secret_leakage` - and not a neighbour like `deterministic`; the weaker assertion let the class survive in `cacheGet`, `queue.receive`, `sqlOne`, `sqlMany` and `durable.waitSignal`. The class is not bounded by those thirty-four files: it also shipped in `packages/pi`, where no such gate exists ([empty-baseline-made-a-file-destroying-edit-prove-clean](docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md)).
- Adding an advertised rule needs either a defect seed in `packages/pi/src/standin/defect_seeds.zig` that is observed tripping it, or a row in `scripts/unseeded-rules.allow` giving the reason a seed cannot reach it; a row for a code a seed now verifies fails the same gate. Both directions run inside `zig build test-standin`. The list only ratchets down: it once carried nineteen rows and now carries 1 row (`ZTS508 non-default`). The rows that went were closed by giving a rule a producer or by deleting a rule no execution order could surface, never by writing a seed. Write the reason beside the row. A row naming a code that the registry advertises and nothing constructs is a false advertisement in a hashed policy surface. `scripts/check-diagnostic-producers.sh` catches that shape, because a gate keyed on the code cannot: see [a-guard-that-every-input-satisfied-refused-the-first-new-one](docs/solutions/conventions/a-guard-that-every-input-satisfied-refused-the-first-new-one.md) and [a-stale-cassette-is-loud-and-an-unsatisfiable-seed-is-silent](docs/solutions/logic-errors/a-stale-cassette-is-loud-and-an-unsatisfiable-seed-is-silent.md).
- An export that reads persistent cross-call state - a cache, a queue, a SQL table, a durable signal - declares `.unknown` in its `return_labels`, alongside whatever kind of store it is. It hands back a value some separate write put there, and the read call holds no reference to that value, so no dataflow rule can reach it and only the binding knows. `derives_from_args` is a **no-op** for this shape and closing the finding with it leaves the fail-open open: `argDerivedLabels` unions only the current call's own arguments, which for `cacheGet("ns", "k")` are two string literals. `derives_from_args` is the right answer for a pass-through, where the return *is* an argument; the retired `returns_from_param` binding field is no longer part of the API. Expect `.unknown` to move a verdict from PROVEN to unproven rather than to refused; an export deriving its result from the limiter's or the generator's own state, like `rateCheck` or `uuid`, is not this shape.
- A declassifier - an export whose declared labels replace its input's rather than joining them - names the argument that bounds it in `declassify_bound_arg` and the ceiling in `declassify_bound_max` (`mask` uses `mask_visible_max`, which is 4), and the declassification holds only while that argument is an integer literal in `0..declassify_bound_max` and every other argument is an unmodified source value. An omitted, float, negative, non-literal, or larger bound keeps the labels. An unmodified source value is a value that `FlowInterp` marks `source_exact`: the result of `env` from `zttp:env`, the `authorization` header cell, or a plain copy of one (a local, a parameter, a return, a stored and reloaded field, a branch that picks between such values and clean ones). A slice, a concatenation, `trim`, `truncate`, `slugify`, or any other operation builds a new value without the mark, because `mask(text, visible)` reveals the trailing `visible` bytes and bounded calls over slices of one secret would reveal all of it. A runtime `visible` puts the magnitude of the declassification in whatever computes it. Mark a new export as a source only after the census over `builtin_modules.all` in `flow_interp.zig` lists it (D-015).
- A gate asserts a floor on its own input before any count it reports means anything. A gate whose corpus is empty, whose filter matches no test, or whose build product nothing depends on reports success while checking nothing, and is then cited as evidence. `scripts/check-runtime-purity.sh` and `scripts/check-docs-drift.sh` already do this; see [a-gate-that-counts-nothing-still-reports-a-pass](docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) for the four shapes and the delete-its-input check. The floor is necessary and not sufficient: a gate holding a full input can still assert something weaker than its own name, so that runs in which the named behavior never happened satisfy it too. Assert the value expected, not a difference from the values excluded. A probe is code: one that does not compile runs no check. A failed build and a passing gate both emit no failure message, so read a probe's verdict from the build's exit status rather than from a grep over its output ([difference-is-not-the-claim-and-a-probe-must-compile](docs/solutions/conventions/difference-is-not-the-claim-and-a-probe-must-compile.md)). A gate that satisfies both rules can still be porous: its probes show that the cases their author named are caught and say nothing about the cases nobody named. Find those by applying one edit to a copy of the gate's declared inputs and running the built gate binary against the copy. Close a round with a census rather than with one more probe: iterate the verdict enum and require every member to be probed or to carry an allowlist row that states a mechanism. Count per verdict, never per input or per file. A gate whose subject is an open vocabulary must also say which threat it bounds instead of leaving a reader to assume it bounds every one ([a-gate-can-be-non-vacuous-and-still-porous](docs/solutions/conventions/a-gate-can-be-non-vacuous-and-still-porous.md)). Never cite a filtered run as evidence. `-Dtest-filter` runs only part of the suite, so it cannot establish what the whole suite establishes. The aggregate `zig build test` refuses it. A named suite whose filter selects no test fails, and a fixed filter such as the stand-in suite's gets the same check (`build/Context.zig` `addTest`, `tooling/nonempty_test_runner.zig`). Take every verdict from an unfiltered run of the named step. `zig build <step> | tail -n` followed by `$?` reports the status of `tail`, not of the build, so redirect to a file and read the exit status directly.

## Commit Guidelines
- Commit history is informal; keep subjects short and descriptive (lowercase is common). Use `WIP-#:` only for intentional multi-step series.

## Security & Configuration Notes
- Preserve path traversal checks in `packages/runtime/src/server_static.zig#resolveStaticFile`.
- Runtime isolation depends on `HandlerPool`/`LockFreePool`; avoid introducing shared mutable state between requests. The one exception is the per-pool `zttp:ratelimit` store (D-013): integer counters keyed by strings, never a JS value, every access under its mutex.

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

| Gate | Proves | Required when |
| --- | --- | --- |
| `zig build test-zts` | runs all zts tier unit-test roots | after analyzer, compiler, interpreter, or binding changes |
| `zig build test-sdk` | runs zttp-sdk tests | after SDK contract changes |
| `zig build test-modules` | runs virtual-module implementation tests | after virtual-module behavior or binding changes |
| `zig build test-proof-checker` | runs consumer acceptance-kernel tests | after proof-checker or certificate changes |
| `zig build test-proof-checker-mutants` | runs committed acceptance-kernel mutants | after acceptance logic or mutation coverage changes |
| `zig build test-proof-checker-purity` | checks the kernel leaf boundary and suite floor | after proof-checker source or dependency changes |
| `zig build test-script-reachability` | checks that each repository script has a declared route | after script or build-graph changes |
| `zig build test-diagnostic-producers` | checks that each advertised diagnostic has a producer | after diagnostic-registry changes |
| `zig build test-proof-ratchet-drift` | checks the published trusted boundary against the kernel | after proof boundary or kernel changes |
| `zig build test-residual-guards-drift` | checks residual guard catalogs, evidence, and documentation | after residual-guard changes |
| `zig build test-proof-ratchet` | checks disclosed trust against kernel reconstruction | after proof-ratchet changes |
| `zig build test-precompile` | runs focused precompile and CHECK behavior tests | after precompile or CHECK changes; aggregate coverage is in test-agent-protocol |
| `zig build test-canonicalize` | runs focused canonicalize and normalize tests | after source-repair or normalization changes; aggregate coverage is in test-agent-protocol |
| `zig build test-expert` | runs expert command contract tests | after expert command changes |
| `zig build test-zts-cli` | runs analyzer dispatch and machine-command tests | after zts CLI changes |
| `zig build test-deploy-manifest` | runs proven-facts extraction tests | after deploy-manifest changes |
| `zig build test-agent-identity` | runs agent identity primitive tests | after agent identity changes |
| `zig build test-module-graph-record` | runs module graph and digest tests | after module graph record changes |
| `zig build test-agent-protocol` | runs agent protocol envelope tests | after agent protocol changes |
| `zig build test-module-audit` | runs module-contract audit tests | after module-contract audit changes |
| `zig build test-verify-paths-core` | runs behavior-path verification core tests | after verification path changes |
| `zig build test-project-config` | runs project configuration discovery tests | after configuration discovery changes |
| `zig build test-instruction-counter` | runs retired-instruction counter tests | after instruction counter changes |
| `zig build test-expert-app` | runs expert loop and provider integration tests | after expert loop or provider changes |
| `zig build test-cassette` | runs the focused offline provider cassette harness | after cassette or provider wire changes; aggregate coverage is in test-expert-app |
| `zig build test-recorder-smoke` | runs provider-free recorder capture and replay | after recorder changes |
| `zig build test-simulator` | runs the focused offline full-flow simulator | after simulator or fail-closed flow changes; aggregate coverage is in test-expert-app |
| `zig build test-standin` | runs the deterministic stand-in through the expert loop | after stand-in, veto, or rule changes |
| `zig build test-expert-mlx-e2e` | uses the operator's configured MLX server for a real model flow | only when the operator requests local model use |
| `zig build test-diagnostic-corpus` | checks diagnostic corpus cases against committed goldens | after diagnostics or corpus changes |
| `zig build test-flow-census` | checks leak verdicts over the generated flow census | after flow-checker or binding-label changes |
| `zig build test-bytecode-identity` | checks emitted handler bytecode against the committed identity golden | after codegen, IR, or handler example changes |
| `zig build test-capability-audit` | checks capability helper declarations | after capability helper changes |
| `zig build test-native-gates` | runs native repository gate tests | after native gate changes |
| `zig build test-evidence-publish` | runs native evidence publisher tests | after evidence publisher changes |
| `zig build release-provenance` | validates release evidence provenance | before release readiness is claimed |
| `zig build test-release-provenance` | runs release provenance tests | after provenance validation changes |
| `zig build test-coverage-union` | runs coverage-union tests | after coverage-union changes |
| `zig build release-check` | prints the repository release-readiness passport | before release readiness is claimed |
| `zig build test-release-check` | runs release-passport tests | after release passport changes |
| `zig build test-production-branch-metric` | tests and runs the production branch metric | after branch metric changes |
| `zig build test-kernel-safety` | checks acceptance-kernel runtime safety under release optimization | after kernel guards or build modes change |
| `zig build test-module-boundary` | checks consumer access to zts internals | after imports across the zts boundary change |
| `zig build test-release-workflow` | checks release script invariants | after release script changes |
| `zig build test-proof-swallow` | checks proof analysis for unreviewed discarded errors | after proof pipeline error handling changes |
| `zig build test-zts-layering` | checks that zts tiers import only lower tiers | after zts imports or tier assignments change |
| `zig build test-convergence-emitter` | checks the convergence marker producer and consumer | after convergence evidence changes |
| `zig build test-evidence-marker` | checks evidence marker and publisher boundaries | after evidence marker or publisher changes |
| `zig build test-docs-drift` | checks documentation against registries and build paths | after documented registries or paths change |
| `zig build test-idiom-table` | checks the specification idiom table against the registry | after idiom or rule changes |
| `zig build test-canonical-style` | checks canonical-style examples against the rule registry | after canonical rules or examples change |
| `zig build test-grammar-drift` | checks specification grammar against the registry | after grammar or registry changes |
| `zig build test-decision-registry` | checks that each published decision kind has a producer | after decision-kind changes |
| `zig build test-meta-drift` | checks published registry hashes against their pins | after registry identity changes |
| `zig build test-doc-links` | checks documentation links | after documentation path or link changes |
| `zig build test-runtime-purity` | checks shipped binaries for agent and provider surfaces | after runtime, analyzer, or provider changes |
| `zig build test-module-governance` | runs the module governance audit | after module governance changes |
| `zig build test-contract-golden` | checks analyzer contract output against goldens | after contract output changes |
| `zig build test-generic-intersection-cli-matrix` | runs generic-intersection rejection and contrast fixtures | after generic intersection behavior changes |
| `zig build test-expert-golden` | checks the zts direct-tool contract against goldens | after expert tool output changes |
| `zig build test-cli` | runs developer CLI unit tests | after CLI behavior changes |
| `zig build test` | runs the aggregate unit and repository test graph | before any repository change is complete |
| `zig build test-zruntime` | runs the standalone ZRuntime test root | after runtime engine or artifact activation changes |
| `zig build test-server` | runs server and runtime facade integration tests | after server or runtime facade changes |
| `zig build test-examples` | runs example handler suites | after examples or public handler behavior changes |
| `zig build test-cli-abuse` | runs the built analyzer against hostile CLI input | after analyzer process or machine output changes |
| `zig build bench-check` | compares benchmark results with the committed baseline | after performance-sensitive runtime changes |
| `zig build test-bench-diff` | runs benchmark sampling and comparison tests | after benchmark tooling changes |
| `zig build smoke-v1` | runs the v1 user flow in a temporary directory | after core CLI workflow changes |
| `zig build test-module-scope-panic` | checks module authorization isolation after a recovered panic | after module authorization or panic recovery changes |
| `zig build test-panic-isolation` | runs handler panic isolation end to end | after handler isolation or panic recovery changes |
| `zig build smoke-getting-started` | runs the Getting Started guide in a temporary directory | after the guide or first-run workflow changes |
| `zig build test-compile-bench` | runs compile benchmark harness tests | after compile benchmark changes |
| `zig build test-step-coverage` | reports how the build graph reaches every build step | after build task or aggregate changes |
| `zig build check-spine` | checks the installed agent spine against the live repository graph | before any repository change is complete |
| `zig build test-spine` | runs agent-spine behavior tests and rejection probes | after agent-spine policy or tooling changes |
| `zig build verify` | runs the full local gate in separate sequential processes | before the full local verification gate is claimed |
| `zig build test-agent-determinism` | checks complete agent envelopes are deterministic | after agent wire or transport changes |
<!-- end generated: gates -->
