---
name: zttp-build
description: Use when running a zttp build beyond the everyday debug build and test suite - release builds, handler precompilation with -Dhandler/-Dverify/-Dcontract/-Dreplay/-Dtest-file, the optional -Dstudio and -Dedge features, the wasm playground, per-package test steps, filtered single tests, example handler tests, and benchmarks.
---

# zttp build reference

Validated on Zig 0.16.0 stable. The build produces three binaries: `zttp` (developer CLI and
local runtime entry point), `zttp-runtime` (internal runtime template wrapped by self-contained
outputs), and `zts` (pi-free analyzer CLI for IDE and CI integrations).

The four everyday commands live in the root `AGENTS.md`: `zig build`, `zig build test`,
`bash scripts/verify.sh`, and `zig build run -- <handler>`. Everything below is the rest.

## Build variants

```bash
zig build -Doptimize=ReleaseFast              # Release build
zig build -Dstudio                             # Compile in the browser proof workbench (zttp studio); off by default
zig build -Dedge                               # Compile in the edge runtime (zttp edge); off by default
```

## Handler precompilation

```bash
zig build -Dhandler=handler.jsx               # Precompile handler into zttp
zig build -Dhandler=handler.jsx -Dverify      # Verify at compile time
zig build -Dhandler=handler.jsx -Dcontract    # Emit contract.json
zig build -Dhandler=handler.jsx -Dreplay=traces.jsonl    # Replay-verify
zig build -Dhandler=handler.jsx -Dtest-file=tests.jsonl  # Handler tests at build time
```

## Run

```bash
zig build run -- examples/handler/handler.ts --watch --prove  # Proven live reload
zig build run -- -e "function handler(req) { return Response.json({ok:true}); }"
zig build cli -- --help                        # Run zttp
```

## Wasm playground

```bash
zig build wasm                         # Build zts analyzer as a wasm module (web playground)
bash scripts/build-wasm-playground.sh  # Build wasm + publish to zttp-website/static
```

## Test steps

```bash
zig build test-zts                     # Engine tests only
zig build test-zruntime                # Runtime tests only
zig build test-cli                     # Developer CLI tests only
zig build test -Dtest-filter="name"    # Single test (compile-time filter)
bash scripts/test-examples.sh          # All example handler tests
```

`docs/internals/testing.md` maps which step runs what.

## Benchmarks

```bash
zig build bench                        # Zig-native benchmarks (packages/runtime/bench/benchmark.zig)
```

Use this step for repository benchmarks. Do not add ad-hoc benchmark scripts.
