# Test Steps

`zig build test` is the aggregate unit suite. It is not the full gate.
`scripts/verify.sh` is the full local gate, and it mirrors the CI test job step
for step. This document says which steps each one runs, which steps `zig build
test` deliberately leaves out, and why.

The authority is `build.zig`. When the two disagree, `build.zig` is right and
this document is stale.

## What `zig build test` Runs

Two runtime test roots:

| Step | Root | Covers |
|---|---|---|
| (no separate step) | `runtime_main_tests` (`main.zig`) | `runtime_cli`, `cli_shared`, `server`, `edge_server`, `studio`, `proof_adapter` |
| `test-cli` | `cli_main_tests` (`cli_main.zig`) | `dev_cli` and its dependencies: deploy, pi_app wiring, `zts_cli` delegation |

The host test roots, declared in the `host_test_roots` table in `build.zig`.
`scripts/check-docs-drift.sh` binds this table to that one, so a root added
there without a row here fails `zig build test-docs-drift`:

| Step | Root |
|---|---|
| `test-precompile` | `packages/tools/src/precompile.zig` |
| `test-canonicalize` | `packages/tools/src/canonicalize.zig` |
| `test-property-expectations` | `packages/tools/src/property_expectations.zig` |
| `test-rollout` | `packages/tools/src/system_rollout.zig` |
| `test-expert` | `packages/tools/src/expert.zig` |
| `test-zts-cli` | `packages/tools/src/zts_cli.zig` |
| `test-deploy-manifest` | `packages/tools/src/deploy_manifest.zig` |
| `test-agent-identity` | `packages/tools/src/agent_identity.zig` |
| `test-module-graph-record` | `packages/tools/src/module_graph_record.zig` |
| `test-agent-protocol` | `packages/tools/src/agent_protocol.zig` |
| `test-module-audit` | `packages/tools/src/module_audit.zig` |
| `test-manifest-alignment` | `packages/tools/src/manifest_alignment.zig` |
| `test-smt-solver` | `packages/tools/src/smt_solver.zig` |
| `test-verify-paths-core` | `packages/tools/src/verify_paths_core.zig` |
| `test-report` | `packages/tools/src/report.zig` |
| `test-project-config` | `packages/tools/src/project_config.zig` |
| `test-proof-quest-fixture` | `packages/tools/src/proof_quest_fixture.zig` |
| `test-openapi-manifest` | `packages/tools/src/openapi_manifest.zig` |
| `test-expert-app` | `packages/pi/src/tests.zig` |
| `test-cassette` | `packages/pi/src/cassette_tests.zig` |
| `test-simulator` | `packages/pi/src/simulator_tests.zig` |
| `test-standin` | `packages/pi/src/standin_tests.zig` |

`test-standin` compiles with its filters pinned to the literal `stand-in`
(`build.zig:316`), so a test in that root whose name omits the token never runs.
A gate in `packages/pi/src/standin_range_tests.zig` enforces the naming rule the
filter depends on. See "Adding A Test Root" for the rule behind it.

Two of those roots exist because of how modules are wired rather than because
of what they test. `canonicalize.zig` and `zts_cli.zig` are reached only
through the `zts_cli` named module, so a test root that imports them by
relative path collects none of their tests. The table entry is what runs them.

`test-cassette` covers provider response parsing and assembly. `test-simulator`
covers the versioned full-flow contract: strict loading, request checkpoint
validation, approvals, multi-Turn transcript and workspace continuity, exact
final state, and crash-safe promotion. Both run without credentials. Simulator
fixtures marked `deterministic_harness` prove the full-flow machinery, not model
quality or convergence. Published convergence remains historical empirical model
evidence from response-only cassettes replayed by `expert_codegen_record.zig`.
It is not full-flow evidence and must not be described as such until fresh
`empirical_model` flows replace it through the direct cutover. Fresh capture
requires runtime credentials and successful provider responses; this checkout
does not contain synthetic replacements for that evidence.

The package suites: `test-zts`, `test-sdk`, `test-modules`,
`test-proof-review`, `test-release-check`, `test-server`, `test-compile-bench`.

The audits and gates: `test-capability-audit`, `test-module-boundary`,
`test-proof-swallow`, `test-module-governance`, `test-runtime-purity`,
`test-contract-golden`, `test-expert-golden`, `test-docs-drift`,
`test-doc-links`, `test-production-branch-metric`,
`test-comptime-cli-matrix`, `test-generic-intersection-cli-matrix`.

The docs drift and link gates run here and only here. Neither Run step is
cached, so `zig build test` always executes both scripts, and `verify.sh` and
CI deliberately do not invoke them a second time.

Both benchmark binaries are compiled but not run. They import engine
internals, so a change that removes an engine symbol breaks them even when no
test references them. That is not hypothetical: when the JIT was removed,
`verify.sh` passed while `zttp-bench` was broken, because the gate never built
it. Compiling catches that class of breakage. Running the benchmarks here would
import their measurement noise into the gate, so `bench-check` stays separate.

## What `zig build test` Excludes

Three build steps:

- **`test-zruntime`**, the `zruntime_tests.zig` root. See the next section.
- **`test-module-scope-panic`**, a focused executable that proves authorization
  isolation and teardown across the real non-local panic recovery mechanism.
- **`test-panic-isolation`**, an end-to-end script that needs the installed
  `zttp` binary, so it depends on the install step rather than on a test root.
  This step also depends on `test-module-scope-panic`.

Everything driven by a shell script rather than a build step is also outside
it: `smoke-v1`, `scripts/test-examples.sh`,
`scripts/test-install-archive-safety.sh`, `scripts/check-semantics-spec.sh`,
`zts module-spec-render --check`, the policy-hash and expert-subsystem
assertions, and `zig fmt --check`. `scripts/verify.sh` runs all of them.

## Why The ZRuntime Suite Is Standalone

`zruntime_tests.zig` is the end-to-end test root for `handler_instance.zig`. It
holds the pool-heavy tests, and running the same root twice in parallel has
produced intermittent libc and arena teardown traps on macOS. Keeping it out of
the aggregate means `zig build test test-zruntime` cannot schedule it twice at
once.

It is also invisible from the other side. `zruntime` is the root of its own
module, so a file import from `main.zig` collects none of its tests: measured
at 521 tests in `main.zig` with and without that import. There is no way to
fold it in by importing it; it needs its own step either way.

`zig build test-zruntime` is the only step that runs that root, and
`scripts/verify.sh` runs it as its own step immediately after the aggregate.

## Parallelism On macOS

Both `scripts/verify.sh` and the CI test job run `zig build test -j1` on macOS
and plain `zig build test` elsewhere. The serialization is for the same
teardown instability that keeps the zruntime root standalone.

## Source Coverage Is Unavailable

The repository and CI use Zig 0.16.0. Its normal `zig test` path does not
provide source line or branch coverage instrumentation. `zig test --help`
exposes PC instrumentation only through `-ffuzz`, which measures fuzzing
inputs rather than ordinary test execution. The local LLVM report tools cannot
produce coverage without instrumented binaries and raw profiles, and the
repository has no profile producer or coverage artifacts to feed them.

Do not infer source coverage from test counts or from
[`docs/coverage.md`](../coverage.md), which measures expert replay diagnostics.
Until Zig supplies a stable producer for normal test binaries, a high-risk
change to the contract decoder, compile-time evaluator, server lifecycle, or
verifier must instead add an explicit behavior matrix and demonstrate that the
matrix fails under a deliberate mutation of each changed decision family.
Reassess this limitation when the pinned Zig toolchain changes.

## Running One Test

```bash
zig build test -- --test-filter "runtime init and deinit"
```

The filter applies to the test name in the `test "..."` block. Tests live
alongside the code they cover; there is no separate test directory.

## Adding A Test Root

A new root under `packages/tools/` or `packages/pi/` is a row in the
`host_test_roots` table in `build.zig`, which creates its named step and adds
it to the aggregate in one place. Set `project_config` when the root resolves a
project SQL schema through the shared `project_config` module, and `pi_modules`
when it consumes the shared tool cores through the `zts_cli` and
`zts_expert_skill` named modules.

Reaching a new `zts` internal module from `runtime`, `tools`, `pi`, or
`proof-review` also needs a row in `scripts/module-boundary.allow`, and a row
that nothing uses fails the same gate. Run `zig build test-module-boundary`.

Discarding an error inside the analysis files that decide whether a program is
proven needs a row in `scripts/proof-swallow.allow` giving the reason it cannot
weaken a verdict, and a row nothing matches fails the same gate. A swallow
there does not surface as a failure, it surfaces as a pass. Run `zig build
test-proof-swallow`.

A root that pins its own test filter needs a gate that enforces the naming rule
the filter depends on. `test-standin` is the only one today: it filters on the
literal `stand-in`, and `packages/pi/src/standin_range_tests.zig` reads both
stand-in roots, rejects any column-zero `test "` declaration whose name omits
the token, and asserts a floor on how many declarations it scanned.

That floor is the general rule, and it applies to every gate here whose verdict
depends on a collection, a filter, or a build edge the gate does not itself
define: assert a floor on the input before any count taken over it means
anything. A gate that checks nothing and a gate that finds nothing both exit 0,
and the green one is then cited as evidence. See [a gate that counts nothing
still reports a
pass](../solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md)
for the four shapes and the delete-its-input check.
