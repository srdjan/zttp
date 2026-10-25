# Test Steps

`zig build test` is the aggregate unit suite. It is not the full gate.
`scripts/verify.sh` is the full local gate. No GitHub workflow runs the test
suite. This document says which steps each one runs, which steps `zig build
test` deliberately leaves out, and why.

`bash scripts/verify.sh --release` adds curated release-note checks and
`zig build release-provenance`, which checks that `docs/coverage.json` and
`docs/convergence.json` were published from a clean source commit the tree still
matches apart from generated evidence. Every ordinary source commit fails that
check until the corpus is replayed and both pages republished, so it belongs to
the release path (`scripts/release.sh`, `RELEASE_CHECKLIST.md`) rather than to
every commit.

The authority is `build.zig` and `build/`. When the two disagree, the build is right and
this document is stale.

## What `zig build test` Runs

Two runtime test roots:

| Step | Root | Covers |
|---|---|---|
| (no separate step) | `runtime_main_tests` (`main.zig`) | `runtime_cli`, `cli_shared`, `server`, `proof_adapter` |
| `test-cli` | `cli_main_tests` (`cli_main.zig`) | `dev_cli` and its dependencies: deploy, pi_app wiring, `zts_cli` delegation |

The host test roots, declared in the `host_test_roots` table in `build/host_tests.zig`.
`scripts/check-docs-drift.sh` binds this table to that one, so a root added
there without a row here fails `zig build test-docs-drift`:

| Step | Root |
|---|---|
| `test-precompile` | `packages/tools/src/precompile.zig` |
| `test-canonicalize` | `packages/tools/src/canonicalize.zig` |
| `test-expert` | `packages/tools/src/expert.zig` |
| `test-zts-cli` | `packages/tools/src/zts_cli.zig` |
| `test-deploy-manifest` | `packages/tools/src/deploy_manifest.zig` |
| `test-agent-identity` | `packages/tools/src/agent_identity.zig` |
| `test-module-graph-record` | `packages/tools/src/module_graph_record.zig` |
| `test-agent-protocol` | `packages/tools/src/agent_protocol.zig` |
| `test-module-audit` | `packages/tools/src/module_audit.zig` |
| `test-verify-paths-core` | `packages/tools/src/verify_paths_core.zig` |
| `test-project-config` | `packages/tools/src/project_config.zig` |
| `test-instruction-counter` | `packages/tools/src/instruction_counter.zig` |
| `test-expert-app` | `packages/pi/src/tests.zig` |
| `test-cassette` | `packages/pi/src/cassette_tests.zig` |
| `test-recorder-smoke` | `packages/pi/src/recorder_smoke_tests.zig` |
| `test-simulator` | `packages/pi/src/simulator_tests.zig` |
| `test-standin` | `packages/pi/src/standin_tests.zig` |

The aggregate runs `test-agent-protocol` in place of its complete
`test-precompile` and `test-canonicalize` subsets, and `test-expert-app` in place
of its complete `test-cassette` and `test-simulator` subsets. All four focused
steps remain callable. Collected inventories on 2026-10-24 contained 318, 390,
388, and 818 entries respectively, with no entry missing from the enclosing
root. This removes 1,914 repeated entries from aggregate execution; it does
not establish a wall-clock saving. The standalone runtime process remains
separate.

`test-standin` compiles with its filters pinned to the literal `stand-in`
(the `standin_only` row in `host_test_roots`, applied at `build/host_tests.zig`), so a
test in that root whose name omits the token never runs.
A gate in `packages/pi/src/standin_range_tests.zig` enforces the naming rule the
filter depends on. See "Adding A Test Root" for the rule behind it.

Two of those roots exist because of how modules are wired rather than because
of what they test. `canonicalize.zig` and `zts_cli.zig` are reached only
through the `zts_cli` named module, so a test root that imports them by
relative path collects none of their tests. The table entry is what runs them.

`test-recorder-smoke` captures a loopback response, stores its request digest, and replays the stored bytes through production APIs.
The dedicated unfiltered step needs no provider credential. Full-flow simulator tests separately enforce request checkpoint matching.

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

`test-expert-app` also owns the pure request-budget and compaction matrices:
soft and hard boundaries, whole- and split-turn cuts, closed tool pairs,
standalone summary validation, settings precedence and rejection, v4 checkpoint
resume/fork, and one-shot overflow recovery. `test-cassette` verifies the four
provider summary request shapes and cache controls. `test-simulator` verifies
provider-neutral request checkpoints and hard admission. New checkpoints
record the complete `estimated_logical_input_v2` component budget, normalized
provider-reported input, and the active compaction cut ID. Version 2 uses a
conservative whole-request estimate for fresh epochs. Within one compaction
epoch it projects the last stable normal-request density. A provider total that
falls outside the pre-response calibration envelope remains recorded as raw
usage, while the labeled budgeting observation uses the stable projection.
Replay compares the budget, raw usage, and cut, then derives the same stable
observation. Historical artifacts without those additive fields remain
readable, but changed prompt or wire bytes still make them stale. Refresh
empirical artifacts with their real provider. Do not rewrite request digests
around an old response, because that would attribute it to a request the model
never received. Compaction flow tests assert that retry does not duplicate user
input, tools, edits, or turn completion.

The same expert suite checks all 13 journal event kinds, exact reconstructed
entries and projections, invalid identity transitions, legacy payloads,
consumer-specific acceptance, and allocation cleanup. Transaction tests cover
all 32 marker combinations, existing and absent target states, conflict and
read-error precedence, effect faults, recovery retries, and receipt
acknowledgement. Pure planner tests check exact actions and reject incomplete
plan publication. These matrices test named behaviors; they are not source
coverage or a power-loss simulation.

`test-cli-abuse` is an executable check, not a test root. It runs the built
`zts` in a new temporary directory against eight hostile inputs: an empty file,
a missing path, a directory given as the file, a file one byte over the 10 MiB
read cap, invalid UTF-8, a NUL byte, 600 nested parentheses, and an unknown
flag. Each input runs in text mode and with `--json`, which gives 16 cases. For
each case the check asserts that the process exited and was not killed by a
signal, that it finished within 30 seconds, and the exact exit code. Today every
case exits 1. Under `--json` the standard output is empty or exactly one
parseable JSON document, and the unknown-flag cases assert an empty standard
output because they print stderr text only. The check refuses to run when a
`zttp.json` exists in any ancestor of its temporary directory, because project
discovery walks every ancestor, and it fails when it ran a different number of
cases than it defines. It does not assert stderr content. In text mode a
missing path and a directory leave `main` through an error return, so a Debug
build prints a Zig stack trace to stderr; the check pins the exit code only.

`test-instruction-counter` covers `packages/tools/src/instruction_counter.zig`,
which reports retired user-space instructions for the process and names its
source: `proc_pid_rusage` on macOS, `perf_event_open` on Linux, or CPU time from
`getrusage` when neither is available. The macOS test fails when the source is
not the instruction counter, so a silent fallback on a developer machine cannot
pass. The count for twice the work must be between 1.5 and 2.5 times the count
for the base work on the instruction sources. On the CPU-time fallback the test
asserts only growth.

The package suites: `test-zts`, `test-sdk`, `test-modules`,
`test-proof-checker`, `test-release-check`, `test-server`,
`test-compile-bench`, `test-bench-diff`.

`test-sdk` also runs a separate standard-library-only descriptor root. Its tests
check field-coverage classification and the absence of runtime callback fields;
the SDK root checks declaration projection. Engine tests compare every builtin
descriptor field and export position with the original runtime declaration.

`test-zts` checks the shared IR JSON writer's exact output, unsupported inputs,
malformed property nodes, caller atom resolution, and allocation cleanup.
The type checker tests inferred schema types. `test-precompile` checks emitted
schema bytes, raw JSON retention, dynamic inputs, and JSON binding behavior.
`test-zts` also runs the frontend fuzz contracts in
`packages/zts/src/tests/frontend_fuzz.zig`: each seed once through
`std.testing.fuzz`, plus small PRNG stress loops and nesting generators. Set
`ZTTP_FUZZ_ITERATIONS` to a positive integer to raise the stress iteration
count for a manual run; the gate uses the defaults in that file.
`packages/zts/src/analysis_fuzz.zig` runs seeded deep shapes (call chains, flat binary chains, long `if` bodies, alias chains, nested call sites) through type checking and flow analysis. It counts the inputs that reach each stage and fails below a floor.
`test-precompile` also mutates every `.ts` file under `tests/corpus`
and `examples` in `packages/tools/src/pipeline_mutation_tests.zig`. Each
mutant must give a result or a listed error, diagnostic positions inside the
mutant, and identical output on a second run. `ZTTP_FUZZ_ITERATIONS` sets the
mutants per input there, and the default is 4.
`test-precompile` also runs the false-proof fixtures in
`packages/tools/src/flow_false_proofs.zig`. Each fixture is a leaking handler
that claims a security property, and that property must stay unproven. A second
table lists the fixtures the flow checker still proves falsely. A test holds
that table equal to the observed set, so a fix edits the table in the same
change.
`test-precompile` also runs the precision expectations in
`packages/tools/src/flow_precision_expectations.zig` (plan R16). The file lists
48 representative handlers: the `examples/` handlers, a fixed copy of the 13
DeepSeek codegen handlers, and four handwritten authenticated handlers. Each
entry names the flow properties that the old checker proves on it. Each
property must still hold. A property that the old checker leaves unproven has
no expectation, so a more precise checker may prove more. The test reads each
handler by repository-relative path and runs it through the typed pipeline.
Two frozen constants pin the entry count and the total of expected properties.
The owner corrected two legacy weather-egress expectations under the strict
egress policy: `pii_contained` and `injection_safe` are omitted, while
`input_validated` remains required. The current floor is 214 expected bits.
A table of old-checker misses is empty today, and a test holds it equal to the
observed misses. The new flow interpreter must meet every expectation with no
exemption before it replaces the old checker.

The same file also holds a floor over the whole frozen corpus: the 48 precision handlers, the 38 false-proof fixtures, and the four clean contrasts. The test runs each case through the production check path. It requires 90 cases, no source error, and `CheckResult.flow_unresolved == 0`. An unresolved construct clears every flow property, so a non-zero count would hide a lost proof.

`test-zts` also runs the failure-severity census, in
`packages/zts/src/severity_census.zig`. It generates one probe handler per
builtin export and runs the real path generator and fault checker over it. An
export with a `failure_severity` must show a failure fork, a failing stub, and
one covered site. An export with a forkable return, or a response record that
declares an `ok: boolean` field, and no severity is a finding too. Each finding
needs one row in `allowed_rows` in that file, with a mechanism and a reason, and
a row for a finding that is gone fails, so the list only shrinks. The gate
asserts a floor on its rows, prints the counts per verdict on
every run, and probes every failure kind through a small synthetic census.

The audits and gates: `test-capability-audit`, `test-module-boundary`,
`test-proof-checker-purity`, `test-kernel-safety`, `test-proof-ratchet`, `test-proof-ratchet-drift`,
`test-residual-guards-drift`, `test-proof-swallow`,
`test-zts-layering`, `test-module-governance`,
`test-runtime-purity`, `test-contract-golden`, `test-expert-golden`,
`test-docs-drift`, `test-doc-links`, `test-diagnostic-corpus`, `test-flow-census`,
`test-convergence-emitter`, `test-native-gates`,
`test-production-branch-metric`,
`test-generic-intersection-cli-matrix`.

`test-diagnostic-corpus` pins the output of the default check over the cases
under `tests/corpus/`. Each case is a source file with a sibling `.diag` golden
that records the stages that ran and the diagnostics, so a diagnostic that
changes text, position, or severity fails here, and a `good` case cannot pass
because a stage was skipped. The gate fails below a committed case floor, on a
source with no golden, on a golden with no source, and on a filter that matches
no case. `zig build diagnostic-corpus-write` rewrites the goldens; read every
golden diff against the case's stated intent before committing it. An argument
after `--` filters both steps by path substring, and the aggregate `test` and
`scripts/verify.sh` pass none. The gate's own tests probe every failure kind
through a scratch corpus. The format is in `tests/corpus/README.md`.

The same gate runs a code ratchet over `zts.DiagnosticCatalog.entries()`. Each
distinct catalog code needs a `bad` case whose diagnostic carries it in the
`code` field, or a row in `scripts/corpus-uncovered.allow` that states the
mechanism that stops the default check from producing it. A row for a covered
code, for a code outside the catalog, a duplicate row, and a row with a missing
or placeholder reason all fail, and so does a catalog smaller than
`minimum_universe`. A `DEFECT:` row records a code that does not fire when it
should. The universe is the catalog, not `rule_registry`. The ratchet pins
exact output and does not replace `test-standin`, which checks veto outcomes.

The gate also measures the instructions that each case's check call retires, and
fails a case above `case_budget` as `over_budget`. This holds only on an
instruction source (`instructions_darwin`, `instructions_linux_perf`). On the
CPU-time fallback the gate prints the numbers and fails nothing, because the
GitHub runners' counter source has not been read yet. Every run prints one line
that names the source. The budget is for a Debug build of the gate. The
measurement table, the headroom, and the thread caveat are in
`tests/corpus/README.md`.

`test-flow-census` measures the flow checker's leak properties over a generated
census of probes, in `packages/tools/src/flow_census_probes.zig`. Each probe puts
one labelled value (secret, credential, user input, or clean) on a path to one
sink, through one kind of callee, and claims one property. The expected verdict
of each (label, sink) pair is an explicit table derived from the documented
promise, not from the checker, so a fail-open in the handler body cannot make a
whole column read as held. A probe that misses its expected verdict fails the gate; no allowlist
carries a mismatch. The gate also fails on a probe with no verdict, asserts a floor on the
probes in total, per group, and per (label, sink) column, prints the counts on
every run, and probes every failure kind through a small synthetic census.
`-- --list` prints every probe, and `-- --dump DIR` writes the probes to `DIR`.

The docs drift and link gates run here and only here. Neither Run step is
cached, so `zig build test` always executes both scripts, and `verify.sh`
deliberately does not invoke them a second time.

The native agent spine also runs in the aggregate test step.
`check-spine` validates the installed manifest, area contracts, decisions, solution bindings, source anchors, and generated root blocks.
`test-spine` exercises the public command with clean, rejected, and restored fixture states.
The rejection census requires observed evidence for every failure kind.
The build supplies task names from the completed graph, including install and uninstall.
The spine checks structural links. The existing behavior suites remain the authority for the linked behavior.
The [native spine guide](agent-spine.md) describes commands and evidence limits.

Both benchmark binaries are compiled but not run. They import engine
internals, so a change that removes an engine symbol breaks them even when no
test references them. That is not hypothetical: when the JIT was removed,
`verify.sh` passed while `zttp-bench` was broken, because the gate never built
it. Compiling catches that class of breakage. Running the benchmarks here would
import their measurement noise into the gate, so `bench-check` stays separate.
The benchmark sampler, threshold policy, and atomic baseline writer live in
`tooling/benchmark.zig`, a native Zig test root.

Root `VERSION` is the release-version authority. The package manifests,
`packages/zts/src/root.zig`, the `README.md` heading, and the `install.sh`
"current:" comment must each equal it. `test-release-check` reads those real
files, runs inside `zig build test`, and fails with the name of the first
source that differs. It also rejects a missing, malformed, or stale marker.

## What `zig build test` Excludes

Four build steps run only under `scripts/verify.sh`:

- **`test-zruntime`**, the `zruntime_tests.zig` root. See the next section.
- **`test-module-scope-panic`**, a focused executable that proves authorization
  isolation and teardown across the real non-local panic recovery mechanism.
- **`test-panic-isolation`**, an end-to-end script that needs the installed
  `zttp` binary, so it depends on the install step rather than on a test root.
  This step also depends on `test-module-scope-panic`.
- **`smoke-v1`**, a build step that runs the v1 user flow in a temporary
  directory.

The six single-script drift gates run inside `zig build test`: `test-idiom-table`, `test-canonical-style`, `test-grammar-drift`, `test-decision-registry`, `test-meta-drift`, and `test-agent-determinism`. `test-meta-drift` also compares `describe-rule --hash` with `policy-hash.txt`.

Four scripts and one command run only under `scripts/verify.sh`, with no
build step of their own: `scripts/check-normalize-idempotent.sh`,
`scripts/check-semantics-spec.sh`, `scripts/test-install-archive-safety.sh`,
and `scripts/test-release-notes.sh` (release routes only), plus
`zig fmt --check`. `test-docs-drift` runs `zts module-spec-render --check` and
rejects a stale catalog in an isolated copy. The release routes also run
`release-provenance`, `smoke-getting-started`, `release-check`, and
`bench-check`. `tooling/verification_routes.zig` is the list that
`scripts/verify.sh` follows.

`scripts/test-examples.sh` used to be on that list and is not any more. Being
driven by a shell script is a reason to wire the script into the build graph,
not a reason to leave the suites out of the aggregate step: the exclusion was
documented rather than enforced, so `zig build test` reported a pass while 56
example suites went unrun, and `examples/sql/sql-crud.ts` claiming a proof
property the compiler had stopped discharging (ZTS500) surfaced only under
`verify.sh`. The suites cost about 24 seconds. `test-examples` now takes the
built `zttp` as a file argument - a nested `zig build` inside a running build
would re-enter the build graph - and `zig build test` depends on it, so
`verify.sh` no longer runs it a second time. The script also asserts a floor on
its suite count, because a run that lost its calls printed "Suites: 0 total, 0
passed, 0 failed" and exited 0.

The general form now has an execution-route gate.
`scripts/check-script-reachability.sh` receives a census of scripts executed
by covered build Run steps and the canonical driver. It compares these with
the NUL-delimited tracked script inventory. Other scripts require a reason in
`scripts/manual-scripts.allow`; stale rows fail. Copied fixture scripts do not
authorize running their live publication commands. The gate bounds direct
execution routes; it does not infer arbitrary shell control flow.

`zig build test-step-coverage` walks the live dependency graph and asks whether
every named task's work is reached by aggregate `test`, an executable command
in `tooling/verification_routes.zig`, or a row in `scripts/manual-steps.allow`.
The same route data drives the native sequential verifier behind
`scripts/verify.sh`. Labels, comments, and filename mentions supply no coverage.
Release-only routes remain separate from per-commit routes, and the two runtime
test roots still run in separate processes. Both allowlists ratchet in both
directions. Input floors reject an empty inventory, route set, or declaration
set. Native rejection probes remove execution while retaining explanatory text.
The zts source census includes tracked and untracked nonignored source files,
so a new module is checked before staging; ignored generated files stay out.

`-Dtest-filter` remains a developer aid for named suites. Each selected test
runner records its collected test count, including custom runners. The named
suite rejects a zero total across its test artifacts; unrelated roots may
collect zero tests when another root matches. Aggregate
`test` rejects filtering because a subset cannot establish the aggregate's
invariants. Native probes check a matching selection, an unmatched selection,
and a filtered aggregate by process exit status and the expected diagnostic.
Acceptance evidence always comes from unfiltered suites.

The verifier runs proof-checker purity, diagnostic producers, proof-ratchet
drift and residual guards through aggregate `test` once. Meta drift and agent
determinism receive the current build's `repo-gate` and analyzer artifacts;
they do not rebuild helpers in temporary cold caches in the canonical path.

It also runs seven registry-drift and determinism gates, most of which need the
built binary. `scripts/verify.sh` runs the same seven:

| Gate | Asserts |
|---|---|
| `check-normalize-idempotent.sh` | a second `normalize` of the corpus produces identical bytes, and names every file the printer refused |
| `check-idiom-table.sh` | spec 4.2.1's table matches `idiom_registry.zig` row for row |
| `check-canonical-style.sh` | every ZTS code the `canonical-style` skill cites exists, and each labelled "before" snippet contains that rule's own `rule_registry` example (source-only; no binary needed) |
| `check-grammar-drift.sh` | spec section 8's productions match `grammar_registry.zig` in document order |
| `check-decision-registry.sh` | every decision kind `meta` publishes is emitted somewhere |
| `check-meta-drift.sh` | the core profile id and the five registry hashes `meta` publishes match their pins |
| `check-agent-determinism.sh` | the same request twice produces identical bytes |

Each carries a floor on its own input, because a gate whose corpus is empty or
whose extraction stopped matching reports success while checking nothing.

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

`scripts/verify.sh` runs `zig build test -j1` on macOS and plain
`zig build test` elsewhere. The serialization is for the same
teardown instability that keeps the zruntime root standalone.

## Source Coverage Is Unavailable

The repository uses Zig 0.17.0. Its normal `zig test` path does not
provide source line or branch coverage instrumentation. `zig test --help`
exposes PC instrumentation only through `-ffuzz`, which measures fuzzing
inputs rather than ordinary test execution. The local LLVM report tools cannot
produce coverage without instrumented binaries and raw profiles, and the
repository has no profile producer or coverage artifacts to feed them.

Do not infer source coverage from test counts or from
[`docs/coverage.md`](../coverage.md), which measures expert replay diagnostics.
Until Zig supplies a stable producer for normal test binaries, a high-risk
change to the contract decoder, server lifecycle, or
verifier must instead add an explicit behavior matrix and demonstrate that the
matrix fails under a deliberate mutation of each changed decision family.
Reassess this limitation when the pinned Zig toolchain changes.

## Running One Test

This is a shortening device for the edit loop, not a way to establish anything.
A filtered run is never evidence, because it checks only part of the suite.
`-Dtest-filter` reaches every test artifact through `addTest` in
`build/Context.zig`, which wraps the artifact in `tooling/nonempty_test_runner.zig`.
A named suite whose filter selects no test now fails, and the aggregate
`zig build test` refuses the option. An earlier build exited 0 over zero tests
and reported "2 passed" while the named test had been sabotaged. Take every
verdict you intend to cite from an unfiltered run of the named step, as
`AGENTS.md` requires.

```bash
zig build test-zts -Dtest-filter="runtime init and deinit"
```

The filter applies to the test name in the `test "..."` block. Tests live
alongside the code they cover; there is no separate test directory.

Zig takes the filter at compile time, so it has to be a build option. The
`-- --test-filter ...` form this document used to show does not filter at all:
the run executes every test in the root and reports success, which reads as a
single passing test to whoever wrote the command. `build/Context.zig` records what that
cost once - a live recording meant for one case cleared every committed
cassette.

## Adding A Test Root

A new root under `packages/tools/` or `packages/pi/` is a row in the
`host_test_roots` table in `build/host_tests.zig`, which creates its named step and adds
it to the aggregate in one place. Set `project_config` when the root resolves a
project SQL schema through the shared `project_config` module, and `pi_modules`
when it consumes the shared tool cores through the `zts_cli` named module.

Reaching a new `zts` internal module from `runtime`, `tools`, or `pi` also needs a row in `scripts/module-boundary.allow`, and a row
that nothing uses fails the same gate. Run `zig build test-module-boundary`.

`packages/proof-checker` is the consumer acceptance kernel and the only thing
in the repository whose word decides whether an artifact may serve production
traffic. `zig build test-proof-checker` runs its suite;
`zig build test-proof-checker-purity` runs `scripts/check-proof-checker.sh`,
which asserts the package still imports nothing but `std` and its own siblings,
reaches no filesystem, clock, process, network, signing, or allocator, and that
the suite the first step reports on is not empty. The second gate exists because
the first reports a pass over zero tests. It fails in both directions: a new
forbidden import fails it, and so does a source file that `src/test_root.zig`
does not reference or that carries no test. It also refuses mutable statics,
`extern`, `asm`, and `@embedFile` anywhere in the kernel and `std.debug.print`
outside tests. Its floors are 13 source files and 195 tests. Its reason-code
census requires every `ReasonCode` member to be named inside a kernel test
block, or to carry a row in the script that states why no input produces it.

`zig build test-kernel-safety` keeps runtime safety on in the kernel inside
ReleaseFast release binaries. A dependency module's optimize mode did not
isolate safety from the root module when measured on Zig 0.16.0, so every
non-test kernel function begins with `@setRuntimeSafety(true)`. The gate parses each kernel file.
It fails when a function omits that first statement. It also refuses
`std.debug.assert` or `@setRuntimeSafety(false)` outside a test.
Its floors are 13 files and 248 non-test functions.
A ReleaseFast probe must abort on an out-of-bounds index in an
annotated function of an imported module, which only happens when the setting
works.

`zig build test-proof-checker-mutants` measures whether that suite can see a
change. It applies each row of `packages/tools/src/proof_checker_mutants.zon`
to a private copy of the kernel, compiles the suite with a fresh cache, and
fails when a mutant survives, when a row no longer applies, or when a row
marked equivalent is killed. An equivalent row states the mechanism that makes
the change invisible. The step is manual (`scripts/manual-steps.allow`): it
takes about 100 seconds. Run it after any change to `packages/proof-checker`.
A reused cache gave stale verdicts during the review that introduced it, so the
fresh cache is not optional.

`zig build test-proof-ratchet` compiles a corpus of real handlers, builds real
certificates, runs the real acceptance kernel over them, and asserts the exact
edge each property was answered with. It is rooted at
`packages/runtime/src/proof_ratchet.zig` because nothing in the product imports
that file, and Zig collects tests only from files a root analyzes.
`zig build test-proof-ratchet-drift` runs `scripts/check-proof-ratchet.sh`,
which compares the published residual boundary in `docs/verification.md`
against `Property.consumerChecked` in the kernel and fails in both directions.
The doc carries a marked list rather than prose, because a promoted property
stays mentioned in prose: a gate that only greps for the name would report a
pass after exactly the promotion it exists to catch. Both directions were
confirmed by hand - an undocumented promotion, a doc that drops a disclosure, a
kernel that re-derives nothing, and an emptied corpus each fail.

`zig build test-residual-guards-drift` runs
`scripts/check-residual-guards.sh` and the compiled stand-in evidence. The
script parses every catalog row across whitespace, compares the ordered
consumer catalog and guard metadata to the compiler mirror and machine-marked
block in `docs/verification.md`, then compares enabled families to measured
stand-in conversions. Every registry has a non-empty floor. Internal
missing-row and extra-row probes make a vacuous comparison fail. The stand-in
dependency makes a compile failure fail the named gate and executes the
positive env, egress, and cache conversions. Each conversion must preserve the
exact proven Property set.

Discarding an error inside the analysis files that decide whether a program is
proven needs a row in `scripts/proof-swallow.allow` giving the reason it cannot
weaken a verdict, and a row nothing matches fails the same gate. A swallow
there does not surface as a failure, it surfaces as a pass. Run `zig build
test-proof-swallow`.

Adding an advertised rule needs either a seed in
`packages/pi/src/standin/defect_seeds.zig` that is observed tripping it, or a
row in `scripts/unseeded-rules.allow` giving the reason a seed cannot reach it,
and a row for a code a seed now verifies fails the same gate. Both directions
run inside `zig build test-standin`. This one is not about a build edge: it is
what stops `docs/coverage.md` publishing "53 of 72" while leaving a reader to
assume the other 19 are unwritten work when 17 of them name a diagnostic no
code path constructs.

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
