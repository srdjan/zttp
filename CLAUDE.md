# CLAUDE.md

@AGENTS.md

## What This Repo Is

Agent-compiler and local serverless runtime powered by zts, a pure Zig engine
for the restricted `zts-model-1` TypeScript profile. The supported deployment
surface is a self-contained macOS or Linux binary. Hosted cloud deployment is
deferred from this beta.

## Build & Run

Validated on Zig 0.16.0 stable. The build produces three binaries: `zttp` (developer CLI and local runtime entry point), `zttp-runtime` (internal runtime template wrapped by self-contained outputs), and `zts` (pi-free analyzer CLI for IDE and CI integrations).

```bash
zig build                                            # Debug build (all three binaries)
zig build test                                       # Bulk unit suite (excludes zruntime root, smoke, panic-isolation)
bash scripts/verify.sh                               # Full local gate mirroring CI, including zig fmt --check
zig build run -- examples/handler/handler.ts -p 3000 # Run zttp
```

Release builds, handler precompilation (`-Dhandler` with `-Dverify` and `-Dcontract`), the per-package test steps, and benchmarks are in the `zttp-build` skill.

## CLI Surface

`zttp --help` advertises five core commands: `init`, `dev`, `test`, `expert`, `deploy`. Everything else is listed by `zttp help --all`, in seven categories: Analyze, Run and inspect, Package, Proof ledger, Credentials, Machine tools, and Advanced. Every analyzer command is reachable both as `zts <command>` and as `zttp <command>` with identical output; `expert` and `ledger` live only in `zttp`.

`zttp verify <url>` verifies provenance for a signed live-endpoint claim. It is
distinct from `zttp proofs verify <bundle-dir>`, which checks bundle integrity
and, when the artifact carries a certificate, runs semantic acceptance against
the artifact itself. `edge` is compiled out by default. Hosted
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

Response helpers: `Response.json()`, `Response.text()`, `Response.html()`, `Response.redirect()`, `Response.rawJson()`. `Response.json` refuses a payload whose type JSON cannot carry (ZTS213); `Response.text` is the total constructor.

Request body readers (globals): `requestBody(req)` returns `Bytes` and is total, `requestText(req)` and `requestJson(req)` return a `Result` whose error names `absent`, `invalid-encoding`, or spec 6.4's JSON taxonomy.

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

## Conventions

- All Zig. New code in Zig unless editing existing JS/TS handler examples.
- `errdefer` on all allocations. `orelse` instead of `?` unwrap.
- Use `zig build bench` for repository benchmarks. Do not add ad-hoc benchmark scripts.
