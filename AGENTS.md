# Repository Guidelines

## What This Repo Is

This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.

Agent-compiler and local serverless runtime powered by zts, a pure Zig engine
for the restricted `zts-model-1` TypeScript profile. The supported deployment
surface is a self-contained macOS or Linux binary. Hosted cloud deployment is
deferred from this beta.

## Build & Run

Validated on Zig 0.17.1 stable. The build produces three binaries: `zttp` (developer CLI and local runtime entry point), `zttp-runtime` (internal runtime template wrapped by self-contained outputs), and `zts` (pi-free analyzer CLI for IDE and CI integrations).

```bash
zig build                                            # Debug build (all three binaries)
zig build test                                       # Bulk unit suite (excludes zruntime root, smoke, panic-isolation)
bash scripts/verify.sh                               # Full local gate, including zig fmt --check
zig build run -- examples/handler/handler.ts -p 3000 # Run zttp
```

Release builds, handler precompilation (`-Dhandler` with `-Dverify` and `-Dcontract`), the per-package test steps, and benchmarks are in the `zttp-build` skill.

## CLI Surface

`zttp --help` advertises five core commands: `init`, `dev`, `test`, `expert`, `deploy`. Everything else is listed by `zttp help --all`, in seven categories: Analyze, Run and inspect, Package, Proof ledger, Credentials, Machine tools, and Advanced. Every analyzer command is reachable both as `zts <command>` and as `zttp <command>` with identical output; `expert` and `ledger` live only in `zttp`.

`zttp verify <url>` verifies provenance for a signed live-endpoint claim. It is
distinct from `zttp proofs verify <bundle-dir>`, which checks bundle integrity
and, when the artifact carries a certificate, runs semantic acceptance against
the artifact itself. `edge` is removed. Hosted
cloud deploy and the account verbs are deferred from this beta; hosted
control-plane, registry, and OCI image orchestration are out of core.

Full reference: [docs/cli.md](docs/cli.md). Semantics registry checking (`spec-check`, `spec-hash`, `spec-render`, `module-spec-render`, and the soundness boundary): [docs/internals/semantics-verification.md](docs/internals/semantics-verification.md). Generated artifacts under `packages/modules/module-specs/` and the Module Catalog table in `docs/virtual-modules/README.md` are rendered from the Zig bindings; edit the binding and regenerate, never the output.

## Architecture

The interpreter is the single execution path; the tiered JIT was removed after measurement.

Request flow: accept connection, check the integrity-validated route table,
check the proof cache only when an accepted certificate promoted the required
properties, acquire an isolated runtime from `HandlerPool`, convert to a JS
Request, invoke the handler, extract the Response, and release the runtime.
Self-extracting binaries validate the contract and serialized policy, rebuild
the executable graph, and run `packages/proof-checker` before pool creation.
Contract parsing alone enables env validation and route pre-filtering, not
proof-authoritative caching or reuse.

Detail: [docs/internals/architecture.md](docs/internals/architecture.md) and [docs/performance.md](docs/performance.md).

## Virtual Modules

Import via `import { fn } from "zttp:module"`. The authoritative module-to-path registry is `packages/zts/src/builtin_modules.zig`. Each module owns its `pub const binding = sdk.ModuleBinding{...}` next to its implementation file; the type and the shared capability-enforcement helpers live in `packages/zts/src/module_binding.zig`. Bindings declare `required_capabilities` (clock, crypto, random, stderr, and so on) enforced at call time.

For the module list and every export, read `packages/zts/src/builtin_modules.zig`.

## JavaScript Subset

ES5 + arrow functions, template literals without interpolation, leading object and array spread, `for...of` (arrays), optional chaining, nullish coalescing, `match` expression, `assert` statement, array HOFs, `Object.keys/values/entries`, `range()`.

The model-minimal profile refuses several forms an ES2015 author reaches for. Declaration destructuring is refused at the parser boundary: bind the source to one name, then read each member with explicit `const` bindings. Template interpolation is refused; build a string array with explicit `String(...)` conversions and call `.join("")`. The pipe operator, `pipe()`, and `guard()` report ZTS001, and object literal shorthand does too. Compound assignment is ZTS613: write `x = x + 1`. Non-leading object spread is ZTS614 and call-site spread is ZTS616.

`match` patterns are literals, record patterns, array patterns, and the six type tests `boolean`, `number`, `string`, `array`, `Dict`, and `Bytes`. A record pattern field is a discriminant test (`kind: "echo"`), a binding under the field's own name (`text`), or a binding under a new name (`value: v`); a binding is an arm-scoped `const` carrying the narrowed field type. A closed union covered member by member needs no `default`, and `??`/`?.` are refused on an operand whose type admits `null` (ZTS624). A recursive type alias must be contractive: every cycle passes through a record, tuple, or array (ZTS212).

Not supported (detected at parse time with suggestions): classes, async/await, Promises, `var`, `while`, `switch`, `this`, `new`, `try/catch`, regex, `==`, `++`. `null` is admitted as explicit data and is permitted only where the type names it; `undefined` stays the absence sentinel. See [docs/feature-detection.md](docs/feature-detection.md).

Statement termination is explicit: there is no automatic semicolon insertion (ZTS047). The escape set, the numeric forms, and the identifier character set are closed - an unknown escape (ZTS013), a backslash before a real newline (ZTS045), a radix prefix or exponent with no digits and a legacy octal literal (ZTS012), and a byte above ASCII in an identifier (ZTS046) are all refused with a location.

Response helpers: `Response.json()`, `Response.text()`, `Response.html()`, `Response.redirect()`, `Response.rawJson()`. `Response.json` refuses a payload whose type JSON cannot carry (ZTS213); `Response.text` is the total constructor. A Response init accepts only a number `status`, and `Response.redirect` takes a status number, not an init; any other form is ZTS203.

Request body readers (globals): `requestBody(req)` returns `Bytes` and is total, `requestText(req)` and `requestJson(req)` return a `Result` whose error names `absent`, `invalid-encoding`, or spec 6.4's JSON taxonomy. The `.value` of `requestJson(req)` is raw JSON, and a member or index read on it is refused (ZTS201). Decode it with `decodeJson` and a schema, or check `isDict(v)` and read with `dictGet(v, key)` from `zttp:collections`.

`.ts` enters the `zts-model-1` core. `.js`, `.jsx`, `.tsx`, and unknown extensions are refused with ZTS052. The parser has no JSX mode. `h()` and `renderToString()` provide manual HTML construction. See [docs/typescript.md](docs/typescript.md).

## Compile-Time Systems

- **Verification** (`-Dverify`): Response returns, Result checking, state isolation. [docs/verification.md](docs/verification.md).
- **Contracts** (`-Dcontract`): imports, env vars, routes, egress hosts, handler properties, author-declared intent assertions. `packages/zts/src/handler_contract.zig`, `packages/zts/src/intent_extractor.zig`.
- **Sound mode**: type-directed analysis across operators. [docs/typescript.md](docs/typescript.md#sound-mode).
- **Type checking**: `packages/zts/src/type_checker.zig`, `packages/zts/src/type_env.zig`.
- **Flow analysis**: data label tracking (secret, credential, user_input). `packages/zts/src/flow_checker.zig`.
- **Fault coverage**: path enumeration, failure severity. `packages/zts/src/fault_coverage.zig`.
- **Replay**: `packages/zts/src/trace.zig`.
- **Proven deployment facts**: `packages/tools/src/deploy_manifest.zig`.
- **Artifact acceptance**: `packages/proof-checker/` owns bounded certificate
  decoding, obligation reconstruction, evidence checks, consumer policy, and
  exhaustive verdicts. `packages/runtime/src/proof_activation.zig` supplies the
  independently reconstructed artifact graph.

## Models

Two providers exist here: DeepSeek and a developer-managed local MLX-LM server.
Handler source leaves the machine on a DeepSeek turn. A failing local case is
the measurement, not a reason to reach for a hosted model. Provider selection,
recording, keys, and the turn timeout are in the `zttp-models` skill.

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
- All Zig. New code in Zig unless editing existing JS/TS handler examples.
- `errdefer` on all allocations. `orelse` instead of `?` unwrap.
- Use `zig build bench` for repository benchmarks. Do not add ad-hoc benchmark scripts.
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
- `docs/internals/testing.md` gives the reasons behind the test step split: what `zig build test` leaves to `scripts/verify.sh`, and why `test-zruntime` is standalone. `zig build -l` lists the steps.
- Name tests with concise behavioral descriptions (e.g., `test "runtime init and deinit"`).
- Runtime and ZTS tests live beside the affected code in `packages/runtime/` or `packages/zts/`; run the relevant `zig build test*` step.
- Analyzer tests parse typed TypeScript through `JsParser.initAdmission(allocator, type_allocator, source, .compile)`, the mode that production uses. Do not add a test-only parse mode.
- Reaching a new `zts` internal module (anything in the internal tier of `packages/zts/src/root.zig`) from `runtime`, `tools`, or `pi` needs a row in `scripts/module-boundary.allow`, and a row that nothing uses fails the same gate. Prefer the curated surface at the bottom of `root.zig`; widen the allowlist only deliberately, and say why in the commit. Run `zig build test-module-boundary`.
- Discarding an error in a file listed in `scripts/check-proof-swallow.sh` needs a row in `scripts/proof-swallow.allow` with the reason it cannot weaken a verdict, and a row nothing matches fails the same gate. A walk over node tags that ends in `else => {}` is the same class. A new walk descends through `IrView.expressionChildren` in its default arm, and a spread operand is read with `getOptValue`, not `getUnary`. Run `zig build test-proof-swallow`. Detail: [scripts/AGENTS.md](scripts/AGENTS.md).
- The gate sees discarded errors, not wrong answers: a function that returns a value claiming more than it checked passes it. An export that derives its return value from its arguments discharges `user_input` and nothing else. When adding such an export, probe it: return a labelled value directly, confirm it is refused, then route the same value through the new export and check the diagnostic is still there. Assert the property the export could launder - `no_secret_leakage` - and not a neighbour like `deterministic`. History: [packages/zts/AGENTS.md](packages/zts/AGENTS.md).
- Adding an advertised rule needs either a defect seed in `packages/pi/src/standin/defect_seeds.zig` that is observed tripping it, or a row in `scripts/unseeded-rules.allow` giving the reason a seed cannot reach it; a row for a code a seed now verifies fails the same gate. Both directions run inside `zig build test-standin`. The list only ratchets down and now carries 1 row (`ZTS508 non-default`). Write the reason beside the row. Detail: [packages/pi/AGENTS.md](packages/pi/AGENTS.md).
- An export that reads persistent cross-call state - a cache, a queue, a SQL table, a durable signal - declares `.unknown` in its `return_labels`, alongside whatever kind of store it is. `derives_from_args` is a **no-op** for this shape and closing the finding with it leaves the fail-open open. Detail: [packages/modules/AGENTS.md](packages/modules/AGENTS.md).
- A declassifier - an export whose declared labels replace its input's rather than joining them - names the argument that bounds it in `declassify_bound_arg` and the ceiling in `declassify_bound_max`, and the declassification holds only while that argument is an integer literal in `0..declassify_bound_max` and every other argument is an unmodified source value. An omitted, float, negative, non-literal, or larger bound keeps the labels. Mark a new export as a source only after the census over `builtin_modules.all` in `flow_interp.zig` lists it (D-015). Detail: [packages/zts/AGENTS.md](packages/zts/AGENTS.md).
- A gate asserts a floor on its own input before any count it reports means anything. The floor is necessary and not sufficient. Assert the value expected, not a difference from the values excluded. Read a probe's verdict from the build's exit status rather than from a grep over its output. Close a round with a census rather than with one more probe: iterate the verdict enum and require every member to be probed or to carry an allowlist row that states a mechanism. Count per verdict, never per input or per file. A gate whose subject is an open vocabulary must also say which threat it bounds. Detail: [scripts/AGENTS.md](scripts/AGENTS.md).
- Never cite a filtered run as evidence. `-Dtest-filter` runs only part of the suite, so it cannot establish what the whole suite establishes. Take every verdict from an unfiltered run of the named step. `zig build <step> | tail -n` followed by `$?` reports the status of `tail`, not of the build, so redirect to a file and read the exit status directly.

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
| `zig build test` | runs the aggregate unit and repository test graph | before any repository change is complete |
| `zig build check-spine` | checks the installed agent spine against the live repository graph | before any repository change is complete |

Run `zig build brief -- <path>` before a change. It lists the gates for that path.
<!-- end generated: gates -->
