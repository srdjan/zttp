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
- Binds: packages/tools/src/precompile.zig, packages/tools/src/precompile_check_run.zig, packages/tools/src/precompile_imports.zig, packages/zts/src/path_generator.zig
- Gate: zig build test-precompile

The imported flow and fault traversals have different stopping rules. Their reader paths, calls, order, and revision selection remain compatibility inputs.

Owner amendment, 2026-10-20: relative imports without a file extension resolve
to `.ts` using the compiler's pure path-selection rule. This narrowly extends
previously unresolved extensionless imports; already explicit paths remain
unchanged. Resolution uses no filesystem existence probes. The selected path
is read through the caller's revision reader, and flow and fault retain their
separate traversals, read order, repeated reads, and revision selection.

### D-007 Persistent reads carry unknown provenance

- Status: standing
- Decided: 2026-09-08
- Binds: packages/zttp-sdk/src/binding.zig, packages/modules, packages/zts/src/flow_checker.zig, packages/zts/src/flow_interp.zig
- Gate: zig build test-zts

A persistent read returns data from a separate write. Commit `f87f97aa` added the `unknown` binding rule on this date.

## Withdrawn findings

### D-008 Automatic semicolon repair stays withdrawn

- Status: standing
- Decided: 2026-10-10
- Binds: packages/tools/src/canonicalize.zig, docs/solutions/tooling-decisions/withdrawn-semicolon-repair.md
- Gate: none

The former repair mapped stripped positions onto original source. Commit `da7b7ddf` removed the unsafe repair on this date.

## Release process

### D-009 Releases are verified and built locally

- Status: standing
- Decided: 2026-10-18
- Binds: scripts/release.sh, tooling/repo_gate.zig, tooling/release_check.zig, build/step_coverage.zig
- Gate: zig build test-release-workflow

GitHub's macOS runner hit the 30-minute job limit in the v0.22.3 release run. The verifier step ran 29m45s before cancellation.

The owner now verifies, builds, smoke-tests, and publishes each release with `scripts/release.sh` on an Apple Silicon Mac. Linux runs inside Apple's `container` CLI.

Three choices follow from this. First (D9), releases publish no Intel macOS binary (`x86_64-macos-none`). Second (D12), `.github/workflows/ci.yml` and `.github/workflows/release.yml` are deleted, so no workflow builds or tests the repository. Third (D13), `proof-gate.yml` moves to `docs/examples/proof-gate.yml`, because `docs/proofs-and-receipts.md` documents it as a template that users copy. No workflow runs in this repository.

Fourth (D14), the Linux gate runs `scripts/verify.sh --release` in a native arm64 container. The first local run of the gate under Rosetta failed 28 compile steps. Rosetta refuses the `translate-c` helper that Zig 0.16 builds with its x86_64 backend ("bss_size overflow"). Only the Rosetta smoke test of the shipped tarball checks x86_64 Linux. That smoke test cannot catch a crash that occurs only in x86_64 Debug builds, such as the 0.22.2 crash.
