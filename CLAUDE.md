# CLAUDE.md

@AGENTS.md

## What This Repo Is

Serverless JavaScript runtime for FaaS, powered by zts (pure Zig JS engine). Targets AWS Lambda, Azure Functions, Cloudflare Workers, edge. Design goals: instant cold starts, small binary, request isolation, zero dependencies.

## Build & Run

Validated on Zig 0.16.0 stable. The build produces three binaries: `zttp` (developer CLI and local runtime entry point), `zttp-runtime` (internal runtime template wrapped by self-contained outputs), and `zts` (pi-free analyzer CLI for IDE and CI integrations).

```bash
zig build                                      # Debug build (all three binaries)
zig build -Doptimize=ReleaseFast              # Release build
zig build -Dstudio                             # Compile in the browser proof workbench (zttp studio); off by default
zig build -Dedge                               # Compile in the edge runtime (zttp edge); off by default
zig build -Dhandler=handler.jsx               # Precompile handler into zttp
zig build -Dhandler=handler.jsx -Dverify      # Verify at compile time
zig build -Dhandler=handler.jsx -Dcontract    # Emit contract.json
zig build -Dhandler=handler.jsx -Dreplay=traces.jsonl   # Replay-verify
zig build -Dhandler=handler.jsx -Dtest-file=tests.jsonl  # Handler tests at build time

zig build run -- examples/handler/handler.ts -p 3000       # Run zttp
zig build run -- examples/handler/handler.ts --watch --prove  # Proven live reload
zig build run -- -e "function handler(req) { return Response.json({ok:true}); }"
zig build cli -- --help                        # Run zttp

zig build wasm                     # Build zts analyzer as a wasm module (web playground)
bash scripts/build-wasm-playground.sh  # Build wasm + publish to zttp-website/static

zig build test                     # Bulk unit suite (excludes zruntime root, smoke, panic-isolation, examples)
bash scripts/verify.sh             # Full local gate mirroring CI, including zig fmt --check
zig build test-zts                 # Engine tests only
zig build test-zruntime            # Runtime tests only
zig build test-cli                 # Developer CLI tests only
zig build test -Dtest-filter="name"    # Single test (compile-time filter)
bash scripts/test-examples.sh      # All example handler tests

zig build bench                    # Zig-native benchmarks (packages/runtime/bench/benchmark.zig)
```

## CLI Surface

`zttp --help` advertises five core commands: `init`, `dev`, `test`, `expert`, `deploy`. Everything else is advanced and listed by `zttp help --all`, in six categories: Analyze, Run and inspect, Package, Proof ledger, Credentials, and Machine tools. Every analyzer command is reachable both as `zts <command>` and as `zttp <command>` with identical output; `expert` and `ledger` live only in `zttp`.

`zttp verify <url>` is the proof-receipt verifier and is distinct from `zttp proofs verify <bundle-dir>`, which checks bundle integrity. `studio` and `edge` are compiled out by default. Hosted cloud deploy and the account verbs are deferred from this beta; hosted control-plane, provider, registry, and OCI image orchestration are intentionally out of core.

Full reference: [docs/cli.md](docs/cli.md). Semantics registry checking (`spec-check`, `spec-hash`, `spec-render`, `module-spec-render`, the SMT layer and exclusion audit): [docs/internals/semantics-verification.md](docs/internals/semantics-verification.md). Generated artifacts under `packages/modules/module-specs/` and the Module Catalog table in `docs/virtual-modules/README.md` are rendered from the Zig bindings; edit the binding and regenerate, never the output.

## Architecture

Monorepo with packages under `packages/`. Runtime (`packages/runtime/`): HTTP, CLI, request routing, static files, live reload. Two entry points:

- `main.zig` -> `runtime_cli.zig` - the `zttp-runtime` binary (serve, attest, self-extract startup, version, help).
- `cli_main.zig` -> `dev_cli.zig` - the `zttp` developer binary (init, dev, test, expert, deploy, and the advanced commands).
- `cli_shared.zig` - arg parsing, watch sets, size parsing shared by both.

HTTP in `server.zig`, runtime management in `handler_instance.zig` (`zruntime_tests.zig` is its end-to-end test root), live reload in `live_reload.zig`. Engine (`packages/zts/`): two-pass compilation (parse to IR, then bytecode), parser in `packages/zts/src/parser/`, VM dispatch loop in `interpreter.zig`. The interpreter is the single execution path; the tiered JIT was removed after measurement. Values use NaN-boxing (`value.zig`, `object.zig`), memory management in `gc.zig`/`heap.zig`/`arena.zig`/`pool.zig`, TypeScript stripping in `stripper.zig`. Tools (`packages/tools/`): build-time precompilation, CLI, analysis.

Request flow: accept connection, check proven route table, check proof cache for deterministic and read-only handlers (`proof_adapter.zig`), acquire an isolated runtime from HandlerPool, convert to a JS Request, invoke the handler, extract the Response, release the runtime. Self-extracting binaries parse the embedded contract at startup for env var validation, route pre-filtering, proof cache activation, and property logging (`contract_runtime.zig`).

Key patterns: native Zig error unions (`!T`) throughout the implementation (the `Result<T>` seen in handlers is a user-facing JS and verification construct, not a Zig engine pattern), hidden classes for inline caching, request-scoped arena allocation, guard composition via the pipe operator (`packages/modules/src/workflow/compose.zig`).

Detail: [docs/internals/architecture.md](docs/internals/architecture.md) and [docs/performance.md](docs/performance.md).

## Virtual Modules

Import via `import { fn } from "zttp:module"`. Most implementations live in `packages/modules/src/` under `data/`, `http/`, `net/`, `platform/`, `security/`, and `workflow/`; the workflow modules `zttp:io`, `zttp:scope`, `zttp:durable`, `zttp:workflow`, and `zttp:queue` live under `packages/zts/src/modules/workflow/`. The authoritative module-to-path registry is `packages/zts/src/builtin_modules.zig`. Each module owns its `pub const binding = sdk.ModuleBinding{...}` next to its implementation file; the type and the shared capability-enforcement helpers live in `packages/zts/src/module_binding.zig`. Bindings declare `required_capabilities` (clock, crypto, random, stderr, and so on) enforced at call time.

| Module | Key Exports |
|--------|-------------|
| `zttp:env` | `env` |
| `zttp:crypto` | `sha256`, `hmacSha256`, `base64Encode`, `base64Decode` |
| `zttp:router` | `routerMatch` |
| `zttp:auth` | `parseBearer`, `jwtVerify`, `jwtSign`, `verifyWebhookSignature`, `timingSafeEqual` |
| `zttp:validate` | `schemaCompile`, `validateJson`, `validateObject`, `coerceJson`, `schemaDrop` |
| `zttp:decode` | `decodeJson`, `decodeForm`, `decodeQuery`, `decodeFormMultipart` |
| `zttp:collections` | `dictEmpty`, `dictFromEntries`, `dictGet`, `dictSet`, `dictRemove`, `dictHas`, `dictEntries`, `dictMapValues`, `dictFilter`, `dictFold` |
| `zttp:bytes` | `bytesFromOctets`, `bytesLength`, `byteAt`, `sliceBytes`, `concatBytes`, `encodeUtf8`, `decodeUtf8`, `decodeBase64`, `encodeBase64` |
| `zttp:json` | `parseJson`, `parseJsonBytes`, `stringifyJson` |
| `zttp:result` | `ok`, `err`, `mapResult`, `mapError`, `andThen`, `orElse`, `unwrapOr`, `collectAll` |
| `zttp:cache` | `cacheGet`, `cacheSet`, `cacheDelete`, `cacheIncr`, `cacheStats` |
| `zttp:sql` | `sql`, `sqlOne`, `sqlMany`, `sqlExec` |
| `zttp:service` | `serviceCall` |
| `zttp:fetch` | `fetch(url, options?: FetchOptions)`, `fetchWithRetry` |
| `zttp:websocket` | `send`, `close`, `serializeAttachment`, `deserializeAttachment`, `getWebSockets`, `setAutoResponse` |
| `zttp:io` | `parallel`, `race` |
| `zttp:durable` | `run`, `step`, `stepWithTimeout`, `sleep`, `sleepUntil`, `waitSignal`, `signal`, `signalAt` |
| `zttp:workflow` | `call`, `saga`, `fanout`, `follow` |
| `zttp:queue` | `send`, `request`, `receive`, `ack`, `nack`, `reply` |
| `zttp:compose` | `guard`, `pipe` |
| `zttp:scope` | `scope`, `using`, `ensure` |
| `zttp:url` | `urlParse`, `urlSearchParams`, `urlEncode`, `urlDecode` |
| `zttp:id` | `uuid`, `ulid`, `nanoid` |
| `zttp:http` | `parseCookies`, `setCookie`, `negotiate`, `parseContentType`, `cors` |
| `zttp:log` | `logDebug`, `logInfo`, `logWarn`, `logError` |
| `zttp:text` | `escapeHtml`, `unescapeHtml`, `slugify`, `truncate`, `mask` |
| `zttp:time` | `formatIso`, `formatHttp`, `parseIso`, `addSeconds` |
| `zttp:ratelimit` | `rateCheck`, `rateReset` |

## JavaScript Subset

ES5 + arrow functions, template literals, destructuring, spread, `for...of` (arrays), optional chaining, nullish coalescing, `match` expression, `assert` statement, pipe operator, typed arrays, compound assignments, array HOFs, `Object.keys/values/entries`, `range()`.

`match` patterns are literals, record patterns, array patterns, and the six type tests `boolean`, `number`, `string`, `array`, `Dict`, and `Bytes`. A record pattern field is a discriminant test (`kind: "echo"`), a binding under the field's own name (`text`), or a binding under a new name (`value: v`); a binding is an arm-scoped `const` carrying the narrowed field type. A closed union covered member by member needs no `default`, and `??`/`?.` are refused on an operand whose type admits `null` (ZTS624). A recursive type alias must be contractive: every cycle passes through a record, tuple, or array (ZTS212).

Not supported (detected at parse time with suggestions): classes, async/await, Promises, `var`, `while`, `switch`, `this`, `new`, `try/catch`, regex, `==`, `++`. `null` is admitted as explicit data and is permitted only where the type names it; `undefined` stays the absence sentinel. See [docs/feature-detection.md](docs/feature-detection.md).

Response helpers: `Response.json()`, `Response.text()`, `Response.html()`, `Response.redirect()`, `Response.rawJson()`. `Response.json` refuses a payload whose type JSON cannot carry (ZTS213); `Response.text` is the total constructor.

Request body readers (globals): `requestBody(req)` returns `Bytes` and is total, `requestText(req)` and `requestJson(req)` return a `Result` whose error names `absent`, `invalid-encoding`, or spec 6.4's JSON taxonomy.

TS and TSX files work directly through the native type stripper. JSX is parsed by the zts parser and rendered via `h()` and `renderToString()` in `packages/zts/src/http.zig`. `comptime()` evaluates expressions at load time. See [docs/typescript.md](docs/typescript.md).

## Compile-Time Systems

- **Verification** (`-Dverify`): Response returns, Result checking, state isolation. [docs/verification.md](docs/verification.md).
- **Contracts** (`-Dcontract`): imports, env vars, routes, egress hosts, handler properties, author-declared intent assertions. `packages/zts/src/handler_contract.zig`, `packages/zts/src/intent_extractor.zig`.
- **Sound mode**: type-directed analysis across operators. [docs/sound-mode.md](docs/sound-mode.md).
- **Type checking**: `packages/zts/src/type_checker.zig`, `packages/zts/src/type_map.zig`.
- **Flow analysis**: data label tracking (secret, credential, user_input). `packages/zts/src/flow_checker.zig`.
- **Fault coverage**: path enumeration, failure severity. `packages/zts/src/fault_coverage.zig`.
- **Replay and durable**: `packages/zts/src/trace.zig`, `packages/runtime/src/durable_recovery.zig`.
- **Deploy manifests**: `packages/tools/src/deploy_manifest.zig`.
- **System linking**: `packages/zts/src/system_linker.zig`.

## Conventions

- All Zig. New code in Zig unless editing existing JS/TS handler examples.
- Tests live alongside code in `test "..."` blocks. Run relevant `zig build test*` after changes. [docs/internals/testing.md](docs/internals/testing.md) maps which step runs what.
- `errdefer` on all allocations. `orelse` instead of `?` unwrap.
- Use `zig build bench` for repository benchmarks. Do not add ad-hoc benchmark scripts.
