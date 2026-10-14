# Decisions

This ledger records structural decisions and product refusals that still govern the repository.

Read this ledger before you propose a structural change. Add a superseding entry when a decision changes.

## Repository tooling

### D-001 The agent spine uses native Zig tooling

- Status: standing
- Decided: 2026-10-14
- Binds: agents.json, build, tooling, scripts
- Gate: zig build check-spine

The accepted plan selected the native port. This choice keeps repository tooling on the existing Zig build graph.

## Product scope

### D-002 M5 agent handlers stay stopped

- Status: standing
- Decided: 2026-10-11
- Binds: docs/roadmap.md, packages/pi
- Gate: none

The owner accepted decision 3 from plan 005. That decision stopped M5 and removed the agent-handler runtime product.

### D-003 The stdin JSON agent surface stays and RPC mode stays removed

- Status: standing
- Decided: 2026-10-11
- Binds: advisor-plans/005-feature-removal-rebase.md, packages/pi, packages/tools
- Gate: none

The owner accepted decision 7 from plan 005. The external JSON surface retains the deterministic client path without RPC mode.

## Runtime architecture

### D-004 The interpreter is the only execution path

- Status: standing
- Decided: 2026-07-29
- Binds: packages/zts, packages/runtime, docs/internals/architecture.md
- Gate: none

Measurements showed that the tiered JIT did not compile on the request path. Commit `b768385e` removed the remaining tier on this date.

### D-005 The acceptance kernel stays independent and remains a leaf

- Status: standing
- Decided: 2026-08-31
- Binds: packages/proof-checker, packages/runtime, scripts/check-proof-checker.sh
- Gate: zig build test-proof-checker-purity

The consumer must derive its verdict without producer authority. Commit `f2ecf5f3` added the independent kernel on this date.

## Analyzer compatibility

### D-006 CHECK retains its separate imported-file traversals

- Status: standing
- Decided: 2026-10-13
- Binds: packages/tools/src/precompile.zig, packages/zts/src/path_generator.zig
- Gate: zig build test-precompile

The imported flow and fault traversals have different stopping rules. Their reader paths, calls, order, and revision selection remain compatibility inputs.

### D-007 Persistent reads carry unknown provenance

- Status: standing
- Decided: 2026-09-08
- Binds: packages/zttp-sdk/src/binding.zig, packages/modules, packages/zts/src/flow_checker.zig
- Gate: zig build test-zts

A persistent read returns data from a separate write. Commit `f87f97aa` added the `unknown` binding rule on this date.

## Withdrawn findings

### D-008 Automatic semicolon repair stays withdrawn

- Status: standing
- Decided: 2026-10-10
- Binds: packages/tools/src/canonicalize.zig, docs/solutions/tooling-decisions/withdrawn-semicolon-repair.md
- Gate: none

The former repair mapped stripped positions onto original source. Commit `da7b7ddf` removed the unsafe repair on this date.
