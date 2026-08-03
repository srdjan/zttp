# Repository Guidelines

## Project Structure & Module Organization
- `build.zig` is the root orchestrator that wires package dependencies into executables and test steps.
- `packages/runtime/` contains the HTTP server and runtime (`main.zig`, `server.zig`, `handler_instance.zig`); `zruntime_tests.zig` is the end-to-end test root behind `zig build test-zruntime`.
- `packages/zts/` is the pure-Zig JavaScript engine (parser, VM, GC, value system, modules).
- `packages/modules/` is the peer package implementing most virtual modules (`zttp:env`, `zttp:crypto`, `zttp:router`, `zttp:auth`, `zttp:validate`, `zttp:cache`, and more), organized under `data/`, `http/`, `net/`, `platform/`, `security/`, `workflow/`, with generated module specs under `module-specs/` (produced by `zttp module-spec-render` from the Zig bindings; do not hand-edit).
- `packages/zts/src/modules/` holds the engine-coupled workflow modules (`io`, `scope`, `durable`, `workflow`, `queue`) plus adapter shims and module-graph internals.
- `packages/pi/` contains the interactive expert agent; `packages/proof-review/` contains the proof-review tooling.
- `packages/zts/src/parser/` contains the Pratt parser, tokenizer, IR, bytecode codegen, and scope tracking.
- `packages/tools/` contains build-time tooling (`precompile.zig` for handler bytecode embedding, `zts_cli.zig` for the compiler CLI).
- `packages/zttp-sdk/` contains the extension SDK.
- `examples/` holds runnable handlers and demos, organized by topic (`handler/`, `jsx/`, `modules/`, `routing/`, `parallel/`, `sql/`, `durable/`, `workflow/`, `websocket/`, `fetch/`, `hypermedia/`, `patterns/`, `system/`, `autoloop/`).
- `scripts/` contains shell scripts for build and setup.
- `docs/` contains user-facing documentation (see Documentation section below).
- `zig-out/` and `.zig-cache/` are generated outputs; don't edit or commit them.

## Documentation

| File | Purpose |
|------|---------|
| `docs/user-guide.md` | The single guide: handler API, routing, virtual modules, CLI options, JS/TS subset, JSX/TSX, local deploy and proof receipts, troubleshooting |
| `docs/internals/architecture.md` | System design, runtime model, project structure |
| `docs/performance.md` | Benchmarks, cold starts, optimizations, deployment patterns |
| `docs/internals/api-reference.md` | Zig embedding API, extending with native functions |
| `docs/typescript.md` | Type stripping, compile-time evaluation (`comptime()`) |
| `docs/feature-detection.md` | Unsupported feature detection matrix |
| `docs/verification.md` | `-Dverify` compile-time proof of handler correctness |
| `docs/sound-mode.md` | Type-directed analysis across operators (arithmetic, comparison, boolean) |
| `docs/roadmap.md` | What is deferred from the current beta and what comes next |
| `docs/convergence.md` | Measured first-draft veto-pass rate over the frozen prompt corpus; regenerate with `scripts/update-convergence.sh` |
| `docs/solutions/` | Categorized solutions to past bugs and engineering problems, searchable by YAML frontmatter (`module`, `tags`, `problem_type`); relevant when implementing or debugging in documented areas |
| `CONCEPTS.md` | Shared domain vocabulary - entities, named processes, and status concepts with project-specific meaning; relevant when orienting to the codebase or discussing domain concepts |

## Build, Test, and Development Commands
- `zig build` - debug build.
- `zig build -Doptimize=ReleaseFast` - optimized release build.
- `zig build -Doptimize=ReleaseFast -Dhandler=handler.jsx` - production build with embedded bytecode.
- `zig build run -- -e "function handler(r) { return Response.json({ok:true}) }"` - run with inline handler.
- `zig build run -- examples/handler/handler.ts -p 3000` - run a file-based handler.
- `zig build test` - all tests.
- `zig build test-zts` - JS engine tests only.
- `zig build test-zruntime` - runtime tests only.
- `zig build bench` - Zig-native benchmark suite.

## Coding Style & Naming Conventions
- Format Zig code with `zig fmt` and follow existing patterns.
- Zig identifiers: types in `UpperCamelCase`, functions and variables in `lowerCamelCase`.
- Files are short, descriptive, and lowercase (e.g., `server.zig`, `handler_instance.zig`).
- Keep APIs explicit: the engine/runtime use native Zig error unions (`!T`); `Result<T>` is a user-facing JS/verification construct in handlers, not a Zig engine pattern.
- Shell scripts that enumerate files should use `git ls-files -z | xargs -0` for safe path handling (handles spaces and special characters).

## Testing Guidelines
- Tests live alongside code using Zig `test "..."` blocks (no separate test directory).
- `docs/internals/testing.md` maps the build steps: what `zig build test` runs, what it leaves to `scripts/verify.sh`, and why `test-zruntime` is standalone.
- Name tests with concise behavioral descriptions (e.g., `test "runtime init and deinit"`).
- Add tests near the feature you touched in `packages/runtime/` or `packages/zts/` and run the relevant `zig build test*` step.
- Reaching a new `zts` internal module (anything in the internal tier of `packages/zts/src/root.zig`) from `runtime`, `tools`, `pi`, or `proof-review` needs a row in `scripts/module-boundary.allow`, and a row that nothing uses fails the same gate. Prefer the curated surface at the bottom of `root.zig`; widen the allowlist only deliberately, and say why in the commit. Run `zig build test-module-boundary`.
- Discarding an error in the analysis files that decide whether a program is proven (the eleven listed in `scripts/check-proof-swallow.sh`) needs a row in `scripts/proof-swallow.allow` with the reason it cannot weaken a verdict, and a row nothing matches fails the same gate. A swallow there does not surface as a failure, it surfaces as a pass. Run `zig build test-proof-swallow`. The gate sees discarded errors, not wrong answers: a function that returns a value claiming more than it checked passes it, and five such fail-opens shipped past it in the flow checker - see [docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md](docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md) for the class and the probe method that finds it. The class is open: `validateJson`, `coerceJson`, and `decodeJson` each relabel their output from their own contract rather than from their input, so a secret routed through any of them reaches the response with `no_secret_leakage` PROVEN - see [docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md](docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md). Probe any export that returns a value derived from its argument before trusting a security property on a handler that calls it. The class is not bounded by those eleven files: the same conflation later shipped in `packages/pi`, where no such gate exists, and destroyed a file - see [docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md](docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md).
- A gate asserts a floor on its own input before any count it reports means anything. A gate whose corpus is empty, whose filter matches no test, or whose build product nothing depends on reports success while checking nothing, and is then cited as evidence. `scripts/check-runtime-purity.sh` and `scripts/check-docs-drift.sh` already do this; see [docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md](docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md) for the four shapes and the delete-its-input check.

## Commit & Pull Request Guidelines
- Commit history is informal; keep subjects short and descriptive (lowercase is common). Use `WIP-#:` only for intentional multi-step series.
- PRs should include: a clear summary, rationale, test commands run, and doc/example updates when behavior changes.

## Security & Configuration Notes
- Preserve path traversal checks in `packages/runtime/src/server.zig`.
- Runtime isolation depends on `HandlerPool`/`LockFreePool`; avoid introducing shared mutable state between requests.
