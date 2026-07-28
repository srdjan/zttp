# Reset and Simplification Plan

Date: 2026-07-28. Baseline commit: 113022e3. Status: findings and proposed plan, not
yet approved.

## 1. Purpose and method

The goal is a solid, simple base to continue development from. This document records a
fresh-eyes review of the whole repository, a list of what to prune, merge, re-architect,
and a wave-ordered plan to do it without losing functionality.

Five independent read-only reviews ran in parallel, one per slice: engine core, proof and
analyzer surface, runtime and CLI, agent and tools and modules, and the meta layer of
build, tests, and docs. Every number below comes from a command or a file. Nothing is
estimated. Claims that could not be verified in the repository are marked "needs
measurement" and are not used to justify a deletion.

A second, independently produced reset plan was then merged into this one. Its technical
findings were re-verified against the source before adoption; four of them were real and
missed by the first pass, and one was misattributed. Section 12 records what was absorbed
and the three conflicts that remain open. This file is the reset ledger: findings,
decisions, evidence, and execution status live here until the reset closes.

Findings that were spot-checked a second time by hand are marked as verified. Section 11
lists the reviewer claims that the second check corrected.

## 2. Measured baseline

| Metric | Value | Source |
| --- | --- | --- |
| Tracked files | 807 | `git ls-files \| wc -l` |
| Zig lines | 281,741 across 458 files | `git ls-files '*.zig' \| xargs wc -l` |
| Lines inside `test` blocks | 70,236, which is 24.9 percent | awk over top-level `test` blocks |
| Test blocks | 3,530 | `grep -c '^test '` summed |
| Prose lines | about 20,800 markdown and HTML | `find \| xargs cat \| wc -l` |
| Build steps | 38 active, plus 1 behind `-Dsystem`, plus 3 unused package-local | `zig build --list-steps` |
| Commits in 6 months | 1,195 of 1,369 total | `git log --since='6 months ago'` |
| Debt markers (TODO, FIXME, HACK) | 28 | `git grep -In` over `*.zig` |

Package sizes: zts 140,756, runtime 62,297, pi 39,999, tools 27,848, modules 5,644,
proof-review 2,671, zttp-sdk 1,502.

The debt marker count is low and the commit rate is high. This is not a neglected
codebase. It is an accreted one: features were added faster than older ones were retired,
so the problem is surface area and duplicate concepts, not rot.

## 3. Headline verdicts

Four structural questions were asked. The answers are not the expected ones, so they are
stated first.

**Keep the three-binary split.** About 500 lines of stubs and feature plumbing keep the
agent out of `zttp-runtime` and `zts`, and `scripts/check-runtime-purity.sh` enforces the
invariant by grepping the built binaries for provider host strings
(`build.zig:538-543`, run inside `zig build test` at `build.zig:729`). Local deploy works
by copying the installed template and appending a payload
(`packages/runtime/src/build_command.zig:529-530`), so merging the binaries would append
payloads to a dev binary that contains the agent. The split earns its cost.

**Keep `packages/pi` in the repository.** The isolation benefit of a separate repository
is already delivered and machine-enforced. Extraction would also break a real guarantee:
`packages/pi/src/expert_persona.zig:1-12` builds the agent system prompt from the
comptime-known rule registry so the persona cannot drift from the binary's semantics. A
subprocess boundary replaces that compile-time guarantee with version skew. The pi problem
is size, not placement. Prune inside it.

**The JIT question is unanswered and must be measured, not argued.** The JIT is 14,874
lines, about 23 percent of the engine core slice, and no benchmark in this repository
isolates its contribution. `packages/runtime/src/benchmark.zig` has zero occurrences of
"jit" and measures with the JIT on. `docs/performance.md` flags its own public numbers as
pending receipt-backed measurement. Do not delete and do not defend it until section 8
runs.

**The proof surface, not the engine, is where the concept duplication lives.** One
algorithm, `contract_diff.diffContracts`, has seven frontends and four separate verdict
vocabularies. Three signed receipts have no reader anywhere in the repository.

**Ownership, not size, is the real defect.** Added after the second review. Compilation has
no single fallible entry point and no single owned result, and three production
constructors turn allocation failure into `unreachable` (section 4.5). The runtime carries a
second hand-written reader for the contract format the product signs (section 5.6). Native
callbacks resolve their target through threadlocal state (section 6.1). These are not
surface-area problems and they do not shrink by deleting anything. They are the work that
makes the base solid, and they belong at the front of the plan, not the end.

## 4. Engine core (packages/zts)

Slice measured at 65,491 lines. Subsystem sizes: JIT 14,874, parser front-end 14,287,
interpreter 8,736, orchestration 6,854, TypeScript front-end 6,199, values and objects
6,055, bytecode family 5,918, memory 4,308, type backend 2,959.

### 4.1 Dead generality, verified

The parser bans features that the layers below still implement end to end.

- Generators. The parser accepts `function*` (`parser/parse.zig:690-692`) while rejecting
  `yield` (`parse.zig:1701`). The interpreter materializes generator objects
  (`interpreter/call.zig:113-140`), `object.zig:889-898` and `1821-1895` carry
  `GeneratorState` and the constructors, and `context.zig:267` owns a prototype. Verified:
  the only references to `createGenerator` outside `object.zig` are the two creation sites
  in `call.zig`, and no code advances a generator. A generator that cannot yield and
  cannot be advanced is fully dead.
- Async. Opcodes `await_val` and `make_async` are marked "kept for future implementation"
  (`bytecode.zig:163-165`) and are fully implemented in the interpreter
  (`interpreter.zig:1363-1381`, `1476-1480`) and handled by the verifier
  (`bytecode_verifier.zig:101`). No producer exists because async is a parse error.
- Loose equality. `==` and `!=` are parse errors (`parse.zig:1748-1755`) yet remain mapped
  to IR ops (`parse.zig:3241-3242`), defined as IR tags (`ir.zig:83-84`), folded
  (`parser/ir_opt.zig:303`), lowered (`parser/codegen.zig:994-995`), and executed
  (`interpreter.zig:827`). Worse, `comptime.zig` supports `==` (`comptime.zig:9`,
  `looseEquals` at `comptime.zig:134`), so the compile-time language contradicts the
  runtime language.
- Catch handlers. `try/catch` is banned, but `Context` carries a 32-deep catch stack
  (`context.zig:199`, `274`, `1923-1944`) with no non-test caller.
- Parallel compilation. `compiler.zig`'s `Compiler`, `compileParallel`, and `CompileUnit`
  plus all of `intern_pool.zig` (786 lines) have one importer, `semantics_corpus.zig:34`,
  which uses only the plain `compile()` helper. Verified by import grep.
- `packages/zts/src/parser/parse.zig.tmp`, 5,260 lines, dated 14 June, is a stale editor
  artifact in the source tree. Verified: it is gitignored by the `*.tmp` rule, so it does
  not inflate the tracked count, but it is a live trap for readers and greps.

### 4.2 Duplication

Five independently written scanners exist for one small language: the Pratt parser, the
`comptime.zig` tokenizer and evaluator (2,236 lines with its own value model), the
`type_pool.zig` type-expression parser (`type_pool.zig:1484`), the `stripper.zig`
character scanner (`stripper.zig:2375`), and `tokenizer.zig`. Three of them independently
know how to skip a template literal. Constant folding is implemented twice, in
`parser/ir_opt.zig` and again in `comptime.zig`, and the two already disagree about `==`.

Opcode semantics exist in three executable encodings: the interpreter switch, the baseline
JIT `compileOpcode`, and the optimized tier. Drift risk is contained because JIT slow
paths call shared interpreter helpers (`interpreter/arith.zig:13`), and a fourth
non-executable encoding, the semantics registry, is drift-gated by `spec-check`. This is
managed duplication, but it means every language change is implemented three times.

### 4.3 Layering

`context.zig` is a 49-field god object (`context.zig:239-340`) that mixes VM stacks, GC,
the dead catch stack, JIT policy and metrics, HTTP shape caches, the JSX vnode shape,
module state slots, and the capability policy. HTTP and JSX state inside the core VM
context is the clearest boundary break. `parser/codegen.zig:16` imports `context.zig` only
for `AtomTable`, which puts a compiler backend behind a runtime module. `http.zig:23-33`
calls user JS through a threadlocal function pointer that the runtime sets per handler,
which is hidden coupling across the engine boundary.

### 4.4 The dormant collector

In every shipped configuration `use_hybrid_allocation` defaults to true
(`packages/runtime/src/runtime_config.zig:37`, `pool.zig:24`), and hybrid mode turns
`minorGC` and `majorGC` into no-ops (`gc.zig:794`, `1123`, `1131`, `1139`, `1217`).
Collection is reachable only during handler load, where `runtime_pool.zig:936-941`
temporarily disables hybrid mode, and in the non-default non-hybrid pool branch
(`pool.zig:190-194`). The generational, incremental, and SIMD machinery therefore serves a
load-time-only collector. This needs the RSS measurement in section 8 before any cut,
because nothing collects persistent objects during serving today.

### 4.5 Compilation ownership, verified

This was missed by the first pass and comes from the external review. It is the most
serious correctness finding in this document, because it is about failure paths rather
than surface area.

`Parser.init` at `parser/parse.zig:131-133` is an infallible wrapper that calls
`initFallible` and converts allocation failure into `unreachable`. The same pattern
appears at `parser/root.zig:170` and `parser/scope.zig:151`. There are 26 occurrences of
`catch unreachable` in `packages/zts`. Some are honest and documented as such
(`parser/ir.zig:918` notes that parser construction performs no allocation), but the three
constructor wrappers convert an out-of-memory condition in production code into undefined
behavior. `packages/zts/src/parser/root.zig:133-136` also documents a legacy Parser
wrapper kept for `zruntime.zig` compatibility, so there are two live parser entry points.

The consequence is that compilation has no single fallible entry point and no single owned
result. Ownership of bytecode, constants, nested function payloads, diagnostics, and
optional contract output is spread across the caller, and the compile benchmark currently
hides nested-function ownership behind an arena.

The target is one fallible `CompileRequest` to `CompiledModule` API, where `CompiledModule`
owns everything the compile produced and exposes one idempotent `deinit`, with the internal
stages made explicit as Parsed, Resolved, Checked, Contracted, Lowered. This subsumes the
weaker proposal elsewhere in this document to merely move `precompile.zig`'s orchestration
into `pipeline.zig`: the orchestration move is the same work done properly.

Acceptance is objective and stronger than a passing test suite: every compile path,
including every failure stage, must report no leaks under `std.testing.allocator`.

## 5. Proof and verification surface

Slice measured at about 72,000 lines across zts, runtime, tools, and proof-review.

### 5.1 One algorithm, seven frontends, four verdict vocabularies

`contract_diff.diffContracts` is the single behavioral-change algorithm. On top of it sit
`zttp prove`, `zttp prove-behavior`, `zttp proofs gate`, the `dev --watch --prove` swap
gate, equivalence receipts, `upgrade_verifier`, and the deploy review card. The first
three are thin shells over one function with different input forms. The concerning part is
the vocabulary sprawl: `contract_diff.Classification`, `upgrade_verifier.UpgradeVerdict`,
the behavioral verdict, and `proof-review/review.zig`'s `ReviewDelta`, where
`review.zig:27-30` documents mirroring an enum by hand instead of importing it.

### 5.2 Artifacts nobody reads, verified

- `.zttp/semantics-receipt.jws`, `kind=semantics`, written by
  `semantics_probe_lib.zig:27`. Verified: the only references in the repository are inside
  the producer, which self-verifies at write time. The CI gate reads the `--json` summary
  (`scripts/verify.sh:83-84`), not the receipt.
- `workflow-receipt.jws`, written by `hypermedia_probe_lib.zig:70`. Verified: the producer
  is the only reference. The kind is not even in `proof_ledger.EventKind`.
- Perf receipt signatures. The numbers are displayed from the ledger; `perf_receipt.verify`
  is called only from a test (`perf_probe_lib.zig:193`).
- `kind=check` ledger rows. Verified: the only `.kind = .check` producer is a test
  (`proof_ledger.zig:622`), while the module doc claims production use
  (`proof_ledger.zig:1-2`).
- `proofs badge` and `proofs export` output, consumed only by their own tests.

Signing ceremonies that produce bytes no code path checks are the clearest example of
accretion in the product's flagship story.

### 5.3 Three mechanisms for one spec gate

"Does the proven property set cover the declared expectations" is answered three times: by
`spec_discharge.zig` as compile-time ZTS500-502 diagnostics on the contract, by
`ratchet check`, which recompiles and diffs declared against proven
(`ratchet_command.zig:8-15`), and by `property_expectations.zig` (688 lines), a JSON
expectations file checked at build time. The second and third are projections of data the
first already computes. Note also that `ratchet_command.zig:21-24` announces a waiver
system that does not exist.

### 5.4 Deliberate redundancy that should stay

The five semantics mechanisms are documented as layered defense in
`semantics_check.zig:1-32`, the whole SMT surface is small (about 900 lines across
`semantics_smt`, `semantics_audit`, and `smt_solver`), and the differential corpus is the
only mechanism that binds the registry to the real compiler. Keep all of it. Capsule
record and replay is the strongest practical regression gate in the product. `proofs gate`
is the only proof surface that crosses a trust boundary.

### 5.5 One analysis pipeline behind many passes

`pipeline.zig:1-24` defines a typed phase pipeline, but `precompile.zig` orchestrates
extra passes outside it: `PathGenerator` runs up to twice per compile
(`precompile.zig:1765` and `1979`), `FlowChecker` is constructed a second time when not
precomputed (`precompile.zig:2429`), and `ContractBuilder`, which describes itself as a
single walk (`contract_builder.zig:1`), contains seven separate linear scans. The scan
"find every `import_decl` and resolve builtin module bindings" is implemented
independently in at least five places, including `flow_checker.zig:659-698` and
`bool_checker.zig:1595-1610`.

The right fix is not one grand unified visitor. The passes have genuinely different
traversal orders and state. The collapsible layer is a shared import and binding index
computed once, a shared read-only IR shape helper library, and moving `precompile.zig`'s
ad-hoc orchestration into `pipeline.zig` so each pass runs exactly once.

### 5.6 Two contract wire readers, verified

Also missed by the first pass. The canonical contract codec is
`packages/zts/src/contract_json_parser.zig`, 2,924 lines. The runtime carries a second,
hand-written reader in `packages/runtime/src/contract_runtime.zig`, 1,818 lines, whose
`parseContractJson` produces a `RawRuntimeContract` (`contract_runtime.zig:166-185`). Two
independent readers of the same on-disk format is a drift hazard on the exact artifact the
product signs and attests.

The fix is to replace the hand-written reader with the canonical codec followed by a
runtime-specific projection. The `RawRuntimeContract` to `ValidatedRuntimeContract`
promotion is not the problem and must be preserved: it is a real trust boundary, and the
capability, policy, and artifact-hash checks that hang off it stay exactly as they are.
The same principle applies to contract construction on the producing side, where
`ContractBuilder` accumulates facts through repeated mutable scans; one immutable
`ModuleFacts` index built once from parsed and checked source, with pure projections for
routes, effects, capabilities, workflows, and proof data, replaces both the seven scans
and the accumulation.

Acceptance for this whole area is byte-identical contract and artifact fixtures. If a
single byte moves, the change is wrong.

## 6. Runtime and CLI

The census: 5 core commands, about 20 named advanced commands, 24 registry analyzer
commands, and about 40 subcommands. No dead commands and no dead files were found. The
surface is wide but live, and the parts of it that are generated from the command registry
(`cli_help.zig:106-114`, drift-tested at `cli_help.zig:215-225`) do not drift. The
hand-written descriptions do.

The server core is better than its file sizes suggest. There is one HTTP parse path, one
inbound request pipeline in `server.zig:538` onward, and `server.zig` reaches the engine
only through `engine_adapter.zig`, a boundary the purity script enforces.

Three residual problems:

- `zruntime.zig` is 7,242 lines: about 2,100 lines of `Runtime` implementation doing engine
  setup, every `install*ModuleState`, the whole actor-queue callback suite, bytecode
  caching, deadlines, dispatch, and incident recording, followed by about 4,900 lines of
  tests in the same file.
- `runtime_http.zig` is 2,305 lines with zero test blocks, the highest-risk untested file
  in the slice. `witnesses_cli.zig`, 382 lines, has no tests and is not linked into any
  test root.
- `zttp dev` and `zttp studio` re-invoke their own binary as a `serve` child process
  (`dev_command.zig:61-108`), which needs binary path re-resolution machinery and couples
  Ctrl+C behavior to process-group signaling.

Two items ship inside the user-facing CLI that are repository tooling, not product:
`cli_release_check.zig` (581 lines, behind `doctor --release`, consumed by
`release.yml`), and the two benchmark files (1,434 lines), which contradict the
project's own rule that benchmarks live outside this repository.

### 6.1 Ambient dispatch state, verified

The first pass found the threadlocal SSR callback at `http.zig:23-33` but stopped there.
The runtime carries more of the same: `zruntime.zig:137` `current_runtime`,
`zruntime.zig:143` `last_fault_location`, `zruntime.zig:155` `aot_override`, and
`zruntime.zig:2289` `active_ws_connection`. WebSocket native callbacks therefore resolve
their target through ambient thread state rather than through a passed context.

Combined with the back-imports already noted (`runtime_http.zig:9` documents that it exists
because of the threadlocal and back-imports `Runtime`), this is one problem with one fix:
an explicit per-invocation context carrying request, WebSocket handle, tracing, and allowed
egress hosts, passed to native callbacks, plus a `HandlerInstance` that owns the engine
runtime, installed builtins, loaded handler, and reset lifecycle, owned directly by the
pool. That removes the runtime-to-pool cycle and the alias bridges at the same time.

This changes the earlier recommendation about `server.zig`. The first pass judged it a
single coherent pipeline and advised against splitting it. That judgement was about the
request path, and it holds: there is one parse path and one ordered pipeline. But
`ServerConfig` reaching below the server edge into durable scheduling and recovery is a
separate problem, and the answer is a data-only `ExecutionSpec` mapped from `ServerConfig`
at the composition edge, with `server.zig` kept as a small composition facade over
transport, request execution, control surface, WebSocket, and recovery. Decompose by
ownership, not by line count.

## 7. Agent, tools, modules

### 7.1 pi

36 tools registered (`app.zig:94-129`) with an already table-driven registry, so there is
no dispatch boilerplate to collapse. 20 of the tool files are thin wrappers, 2,315 lines
total, repeating the same allocating-writer pattern; a comptime wrapper would remove
roughly 600 to 900 lines. The real concentration is elsewhere: `ui_payload.zig` is 3,013
lines defining 24 payload structs with 44 hand-written `init`, `clone`, and `deinit`
functions, which is exactly what an arena-owned payload envelope deletes.

The best pattern in the whole repository lives here and must be preserved: each
`zts_expert_*` tool calls the same writer function the CLI command uses, so agent output
and CLI output are byte-identical by construction
(`packages/pi/src/tools/zts_expert_features.zig:1-3`).

### 7.2 The SDK boundary

`packages/modules` binds against `zttp-sdk`, which reaches the engine through 59 `export
fn zttpSdk*` symbols (`module_binding.zig:591-1176`, about 585 lines), plus a 216-line
adapter and a mirrored type vocabulary guarded by ordinal drift asserts
(`module_binding_adapter.zig:10-29`). The boundary exists to support third-party
extensions. Verified: `packages/zts/src/extension_bindings.zig:3` is an empty array and
there is no dynamic loading anywhere in `packages/`. This is an ABI priced for a
marketplace that has not shipped, between two packages that are always statically linked
into the same binary.

Nine modules stayed engine-side for stated reasons (`builtin_modules.zig:37-39`, `46`):
bootstrap-time state installation cannot go through the SDK's handle gate, and `io` and
`scope` touch the threadlocal and GC roots directly.

`module_binding.zig` (2,388 lines) splits roughly into capability enforcement 575, ABI
bridge 585, declarative types 540, tests 605. Across `packages/modules`, 52 impl functions
repeat the same guard prologue, with 47 occurrences of `orelse return
sdk.JSValue.undefined_val` and 39 of the `catch` equivalent; a comptime wrapper generated
from the already-declared `param_types` would remove them and make arity errors uniform
instead of a silent `undefined`.

### 7.3 tools

`packages/tools` is three packages in one: build-time precompile 13,454 lines, analyzer CLI
and analysis cores 10,281, and system, deploy, and mock 3,616, plus two strays. Clusters 1
and 2 intentionally share a module graph because `zts compile` is precompile. The
genuinely misplaced code is `canonicalize.zig` and `edit_simulate.zig`, which are compiler
analyses living outside the compiler package; `build.zig:206-208` and `264-268` document
that their tests are unreachable except through bespoke test roots, which is the symptom.
`src/skills/zts-expert/` is pi content with no tools dependency.

## 8. Measurements that gate the structural cuts

None of these numbers exist today. Each one gates a deletion worth thousands of lines. Run
them before deciding, and record the results in this document.

1. **JIT contribution.** ReleaseFast, same machine, interleaved runs, `zig build bench`
   with and without the JIT. Correction: the knob is `ZTS_JIT_POLICY=disabled`
   (`packages/zts/src/interpreter/jit_policy.zig:26-56`), not `ZTS_DISABLE_JIT`, which is
   only a test guard inside `zruntime.zig`. Weight the handler-shaped benchmarks
   (`httpHandler`, `httpHandlerHeavy`, `runHandlerCorpus` at `benchmark.zig:26-50`) over
   `intArithmetic` and `forOfLoop`, which model the JIT's best case rather than the
   product's workload.
2. **End-to-end latency.** `wrk` against `zttp serve` on a representative handler, with and
   without the JIT, at both low request rate and sustained rate, p50 and p99. Low rate
   matters because functions may never reach the 100-call threshold
   (`bytecode.zig:447`) between deploys.
3. **Optimized-tier entry rate.** Count how often the optimized tier is entered on the
   handler corpus, through `jit_metrics` (`context.zig:305`). The subset has no `while`,
   so hot loops are only `for...of` and array HOFs. If entry count is near zero, the
   optimized tier plus its deopt plumbing, about 2,900 lines, goes without a throughput
   debate.
4. **Warm-runtime RSS over hours.** In hybrid mode nothing collects tenured objects during
   serving. Sustained load for hours with RSS recorded either validates reducing the
   collector or reveals a latent leak the dormant GC was assumed to cover.
5. **Deploy artifact size** with the JIT excluded, since small binary size is a stated
   design goal.

Recommended decision rule for item 1: if handler-shaped throughput moves less than about
10 percent, delete the optimized tier at once and schedule the baseline tier. Two
hand-written machine-code backends and a deopt protocol are the largest maintenance
liability in the engine, and the durable-mode correctness special case (`jit_inhibited`,
`context.zig:300-306`) disappears with them.

## 8.1 Wave 0 results, recorded 2026-07-28

Host: darwin 25.5.0, arm64. Toolchain: Zig 0.16.0. Working tree clean at 329e88de, which
differs from the review baseline 113022e3 only in `docs/`.

ReleaseFast artifact sizes: `zttp` 10 MB, `zttp-runtime` 5.7 MB, `zts` 6.2 MB.

### Measurement 3, optimized-tier entry rate: answered, zero

The benchmark JSON already reports `tier_promotions` per benchmark, so this needed no new
instrumentation. Across all 13 benchmarks, in every run:

- `optimized` promotions: **0**. The optimized tier is never entered.
- `optimized_candidate`: 1 on `functionCalls`, 1 on `recursion`, 0 everywhere else. Two
  functions in the whole corpus become candidates, and neither is promoted.
- `baseline` promotions: 2 on `functionCalls`, 1 on `recursion`, **0 on all eleven others**,
  including `httpHandler` and `httpHandlerHeavy`.

Caveat on instrumentation: `enable_jit_metrics` is `builtin.mode != .ReleaseFast`
(`packages/zts/src/context.zig:23`), so the richer JIT metrics are compiled out of the
configuration under test. The tier-promotion counters quoted above come from the bytecode
profile, not from `jit_metrics`, and are present in ReleaseFast.

### Measurement 1, microbenchmark A/B: the JIT pays only where it promotes

Protocol: `zig build bench -Doptimize=ReleaseFast`, 5 interleaved rounds alternating JIT on
and `ZTS_JIT_POLICY=disabled`, best-of-N per benchmark on `ops_per_sec`.

| Benchmark | JIT on | JIT off | Delta | Noise floor |
| --- | ---: | ---: | ---: | ---: |
| functionCalls | 18,155,410 | 11,890,606 | +52.7 percent | 3.0 |
| recursion | 3,399 | 2,443 | +39.1 percent | 2.7 |
| gcPressure | 9,023,641 | 8,785,802 | +2.7 percent | 5.3 |
| jsonOps | 4,025,764 | 4,003,202 | +0.6 percent | 28.9 |
| arrayOps | 17,507,002 | 17,476,406 | +0.2 percent | 3.4 |
| intArithmetic | 22,311,468 | 22,281,639 | +0.1 percent | 37.1 |
| httpHandler | 7,173,601 | 7,183,908 | -0.1 percent | 4.7 |
| httpHandlerHeavy | 1,264,222 | 1,271,455 | -0.6 percent | 2.5 |
| forOfLoop | 65,445,026 | 66,755,674 | -2.0 percent | 12.7 |
| stringConcat | 27,886,224 | 28,490,028 | -2.1 percent | 3.2 |
| stringOps | 21,468,441 | 21,949,078 | -2.2 percent | 13.2 |
| objectCreate | 14,615,609 | 15,096,618 | -3.2 percent | 2.6 |
| propertyAccess | 19,747,235 | 20,686,801 | -4.5 percent | 3.2 |

Geometric mean speedup with the JIT enabled: **+5.04 percent**, and that figure is carried
entirely by the two benchmarks that promote. The noise-floor column is the spread across
the five JIT-on runs; `intArithmetic` and `jsonOps` are too noisy on this host to read at
all, and every entry between +2.7 and -4.5 percent is at or inside its own noise.

The two results agree with each other, which is the useful part: the benchmarks that gain
are exactly the two that reach a promotion threshold, and the benchmarks that model the
product's workload promote nothing and gain nothing.

### Measurement 5, artifact size without the JIT: blocked

Not measurable as the build stands. `analyzer_only` strips the interpreter, JIT, GC,
SQLite, and libc together (`build.zig:550-558`) and is hardcoded false for the main build
(`build.zig:112`). There is no option that removes only the JIT. This needs a temporary
build flag before the number exists.

### Measurement 2, end-to-end server load: no measurable JIT effect

Protocol: `zttp serve` on `examples/handler/handler-full.tsx`, request logging disabled
with `-q`, `hey` driving fixed request counts (40,000 warmup then 60,000 timed) at
concurrency 32, three interleaved rounds per configuration.

This host cannot produce a trustworthy median. Individual runs of the same configuration
ranged from 2,165 to 98,607 requests per second, a 97 percent spread, with load average
3.0 on 14 cores and occasional multi-second connect stalls in the accept path. Medians are
therefore not reported as a result. Best-of-N is the appropriate estimator for a noisy
host, and it is clean:

| Configuration | Best run | p50 | p99 |
| --- | ---: | ---: | ---: |
| JIT on | 98,607 rps | 0.200 ms | 3.5 ms |
| JIT off | 97,843 rps | 0.200 ms | 3.9 ms |

Best-case throughput differs by 0.8 percent, and p50 is identical. An earlier attempt that
left request logging enabled is discarded: it measured logging I/O, produced 40 to 56
percent spreads, and its numbers do not appear here.

A structural observation matters more than the delta. At p50 of 0.2 ms with a handler whose
execution the microbench clocks at roughly 0.14 microseconds, JS execution is about one
part in a thousand of end-to-end request time. The connection and accept path dominates.
Even a JIT that doubled interpreter speed could not move this number, which is the honest
reason the end-to-end test cannot separate the configurations.

### Measurement 4, warm-runtime RSS: memory grows without bound, and does not flatten

This is the most consequential result of wave 0, and it points the opposite way from what
the plan assumed.

Protocol: `zttp serve` on `examples/handler/handler-full.tsx`, request logging off,
`hey` at concurrency 8 for 12 minutes, resident set size sampled every 15 seconds.

| Elapsed | RSS |
| --- | ---: |
| 0 s | 14.8 MB |
| 2 min | 50.9 MB |
| 5 min | 75.9 MB |
| 8 min | 118.9 MB |
| 12 min | 135.5 MB |

Growth over the run is 120.7 MB.

Correction to the first reading of this run. A least-squares fit over the final 6 minutes
gave 8.4 MB per minute, and that number was reported as a sustained growth rate. It is not
reliable. The series oscillates with dips of 10 to 20 MB, and fitting a straight line
through a sawtooth reports the slope of whichever part of the cycle the window happens to
cover. The 6-minute attribution run below plateaus in its second half by the same estimator,
which is the same measurement disagreeing with itself. The honest statement is that memory
rises steeply for the first several minutes and then oscillates in a band, and that neither
6 nor 12 minutes distinguishes a plateau from a slow upward drift. This is why the wave 0
requirement is an hours-long run, and it stands.

### Measurement 4a, attribution: the growth requires handler execution

Discriminating experiment, 6 minutes per arm, identical load (`hey`, concurrency 8) against
the same server binary and handler, differing only in the request path. `/_health` returns
at `server.zig:613`, before any handler invocation, proof cache, or JS execution.

| Arm | Start | End | Second-half slope |
| --- | ---: | ---: | ---: |
| `/_health`, no JS executed | 14.5 MB | 4.5 MB | +0.02 MB/min |
| `/`, handler executed | 14.5 MB | 76.5 MB | +0.39 MB/min |

The `/_health` arm is flat at 4 to 5 MB for the whole run, and it ends lower than it
started because startup memory is released once serving begins. The connection, accept, and
HTTP layers therefore do not accumulate. Whatever grows, grows only when the JS handler
runs, which narrows the search to the engine, the pool, and per-request state, and clears
the server layer entirely.

The handler arm rises to about 91 MB by 4 minutes and then oscillates between 72 and 93 MB
for the rest of that short run. That apparent flattening was a window artifact, and the
45-minute run below settles it.

### Measurement 4b, 45 minutes with an idle tail: unbounded retention

Same server, same handler, same load, 45 minutes of `hey` at concurrency 8, sampled every
30 seconds, followed by 4 minutes with the load stopped and the server left running.

| Elapsed | RSS |
| --- | ---: |
| 0 min | 15 MB |
| 6 min | 94 MB |
| 12 min | 145 MB |
| 20 min | 185 MB |
| 30 min | 234 MB |
| 40 min | 318 MB |
| 45 min | 348 MB |
| 45 min, load stopped | 348 MB |
| 49 min, still idle | 329 MB |

Slope over the first half is +8.28 MB per minute, over the second half +5.50, and over the
final 15 minutes +8.90. There is no plateau at any point in 45 minutes: the process ends at
23 times its startup footprint and is still climbing at the same rate it started with. The
oscillations seen in the shorter runs are noise on a rising line, not a bound.

The idle tail is the decisive part. With the load stopped, the process released 19 MB of
348, about 5 percent, and then held flat at 329 MB for the remaining 4 minutes. Memory
acquired during serving is not returned when serving stops. That rules out the benign
explanations: a cache high-water mark, arena reuse, or a pool warming to steady state would
all give back far more than 5 percent once the work stops.

This corrects the caution in the previous subsection. The oscillation was real and the
short-window fits were unreliable, but the underlying reading of the 12-minute run was
right: the growth rate of roughly 8 MB per minute is genuine and sustained. Sustained
growth with retention after idle is the definition of a leak, and the term is now used
deliberately rather than hedged.

### Measurement 4c, narrowing matrix: the leak is in the core request path

Four arms, 4 minutes each, identical load at concurrency 8, fresh server per arm. The
second-half slope is the comparable figure because early growth includes pool warmup.

| Arm | Start | End | Second-half slope |
| --- | ---: | ---: | ---: |
| Inline trivial, `Response.json({ok:true})`, no imports | 14 MB | 93 MB | +10.66 MB/min |
| `handler.ts`, plain JSON with a helper call | 14 MB | 77 MB | +9.43 MB/min |
| `handler-full.tsx`, JSX render path | 15 MB | 83 MB | +12.75 MB/min |
| `handler.ts` with pool size 1 | 14 MB | 37 MB | +9.12 MB/min |

Every arm leaks, at broadly the same rate, and the simplest possible handler leaks fastest
of all. Handler complexity is therefore not the driver: JSX, imports, and helper calls make
no material difference. Pool size 1 reaches a much lower absolute figure over the window,
which is consistent with N runtimes each warming, but its ongoing slope matches the others,
so this is per-request accumulation and not a fixed per-runtime cost.

Combined with the `/_health` arm being flat, the defect sits on the path between accepting
a parsed request and resetting after handler invocation.

### What the static reading rules out

Four plausible explanations were checked in the source and do not hold:

- The server, accept, and HTTP layers, excluded by the `/_health` arm.
- Arena overflow blocks. `Arena.reset` calls `freeOverflow`, which walks the overflow list,
  frees each node through the backing allocator, and zeroes the counters
  (`packages/zts/src/arena.zig:165-178`, `:311-325`).
- Hidden class explosion. `HiddenClassPool.addProperty` dedupes through a `transition_map`
  keyed on the from-class and property atom, and returns the existing class on a hit
  (`packages/zts/src/object.zig:1107-1114`), so repeated identical object shapes do not
  allocate new classes.
- Unbounded atom interning as the primary cause. The request path does intern arbitrary
  header names and query-parameter keys (`packages/runtime/src/runtime_natives.zig:61`,
  `:273`), and the `AtomTable` is never reset per request, with `reset` called only at
  `packages/zts/src/context.zig:824` and in a test. That is a genuine unbounded-growth risk
  for traffic with varying header or parameter names, and it should be fixed on its own
  merits, but interning deduplicates, and the load used here sends a fixed header set with
  no query string, so it cannot explain this leak.

What remains, and where the next look should go: allocations made during handler invocation
that are neither arena-backed nor freed. Note the shape of the design. `HybridAllocator`
routes by lifetime, and the persistent side is documented as "lives forever" with
`persistent_used` a monotonically increasing counter and no free path
(`packages/zts/src/arena.zig:373-400`). Anything that reaches the persistent side per
request, rather than once per runtime, grows without bound by construction.

### Measurement 4d, configuration sensitivity: nothing bounds it

Two further arms, 8 minutes each at concurrency 4, on the trivial inline handler, to test
whether pool size or the memory limit contains the growth.

| Arm | Start | End | Second-half slope |
| --- | ---: | ---: | ---: |
| Pool size 1, no limit | 14 MB | 64 MB | +5.16 MB/min |
| Default pool (28), `-m 64m` | 14 MB | 135 MB | +4.15 MB/min |

Neither bounds it. A single runtime still leaks at about 5 MB per minute, so this is not an
artifact of many pooled runtimes each warming. A memory limit does not contain it either,
and the source says why: in hybrid mode, budget exhaustion is explicitly not a trigger for
collection, because the major GC call is guarded behind `!hybrid_mode`
(`packages/zts/src/gc.zig:707-711`). The limit can only fail an allocation, never reclaim
one.

Two configuration facts compound this, and both are worth fixing independently of the leak:

- `memory_limit` defaults to 0, meaning unlimited
  (`packages/runtime/src/runtime_config.zig:35`), so the default configuration has no bound
  at all.
- The limit is applied per runtime, not per process
  (`packages/runtime/src/runtime_config.zig:181-184`), while the pool defaults to a size
  derived from CPU count (`packages/runtime/src/server.zig:1674-1675`, `:2355`). On the
  14-core host used here the pool is 28 runtimes, so `-m 128m` authorizes roughly 3.5 GB
  process-wide. A user setting a memory limit to fit a container will not get the bound they
  expect.

An earlier arm combining pool size 1 with a 64 MB limit did appear bounded, oscillating in a
30 to 48 MB band. That reading is not repeatable against the two arms above and is treated
as noise, not as evidence that either knob helps.

### Measurement 4e, instrumented run: the driver is runtime recycling

Temporary instrumentation was added to the pool release path, used, and then reverted. It
exposed the engine counters plus the recycle count, and added an environment override for
the recycle threshold so recycling could be switched off without changing the handler.

The first attempt instrumented `Runtime.resetForNextRequest` and printed nothing at all.
That was itself the first clue: `reset_after` is `self.owns_resources`
(`packages/runtime/src/zruntime.zig:1603`), and pooled runtimes are created by
`initFromPool` with `owns_resources = false` (`:429`). The pooled serving path never calls
that reset. The real per-request path is `HandlerPool.releaseForRequest`
(`packages/runtime/src/runtime_pool.zig:690`), which consults a lifecycle policy and either
returns the runtime to the pool or destroys it.

The policy is the finding. `PoolingThresholds.max_requests` defaults to **64**
(`packages/runtime/src/contract_runtime.zig:62`), and `derivePoolingPolicy` falls back to
`.reuse_bounded_by_count` for any handler that is not proven pure, deterministic, and
state-isolated (`:76-83`). So by default every pooled runtime is destroyed and rebuilt every
64 requests.

A/B on that threshold alone, single runtime, identical inline handler and load:

| Arm | RSS over 6 min | Recycles | Releases |
| --- | --- | ---: | ---: |
| `max_requests=64`, the default | 13.9 MB climbing to 50 MB | 12,812 | 820,000 |
| recycling effectively disabled | 13.9 MB falling to 6.3 MB, flat | 0 | 800,000 |

Same request volume, same handler, one runtime. With recycling off the process is stable and
settles below its startup footprint. With recycling on it climbs steadily. The counters
printed alongside confirm what is not happening: interned atoms held at 131 and hidden
classes at 265 in both arms, so neither grows.

### Measurement 4f: nothing is leaked in the Zig sense

The obvious next hypothesis was that teardown misses a free. It does not. A Debug build uses
`std.heap.DebugAllocator` (`packages/runtime/src/runtime_cli.zig:23-28`), which reports
leaks on exit. Run with an aggressive recycle threshold, about 375 recycles over 3,000
requests, then shut down through SIGINT so the allocator's report runs, it found exactly one
leak, and not in the recycle path:

```
error(DebugAllocator): memory address 0x103e401c0 leaked:
  cli_shared.zig:108:26 in stripInlineSource
  runtime_cli.zig:625:76 in parseServeArgs
```

That is a one-time startup dupe of the `-e` inline source, a genuine but trivial leak worth
fixing on its own. Nothing from the recycle path appears. Every runtime teardown frees what
it allocated.

The mechanism is therefore allocator retention, not a missing free. ReleaseFast uses
`std.heap.smp_allocator` (`runtime_cli.zig:28`), whose design keeps a per-thread freelist
per size class and returns memory to those freelists rather than to the operating system;
only large allocations are mapped and unmapped directly. Building a complete JS runtime
allocates thousands of small objects: context, builtins, module state, atom table, hidden
classes, bytecode structures. Destroying it returns all of them to thread freelists that
never shrink. At roughly 39 recycles per second on this host, that churn is what the RSS
curve measures. Debug does not show it because `DebugAllocator` releases pages back.

This also explains why the memory limit cannot help. The bytes are not owned by any runtime
when they accumulate; they sit in the allocator between a destroy and the next create, where
no per-runtime budget can see them.

### The fix, and what it is worth

The defect is a design interaction, not a bug in one function: an aggressive default recycle
policy (every 64 requests) combined with a general-purpose allocator that does not return
freed small objects to the operating system, in a server that runs for days.

Three candidate directions, in the order they should be evaluated:

1. Stop destroying and rebuilding. Recycling exists to bound per-runtime state such as the
   interned atom table, but the measured state does not grow on ordinary traffic (atoms held
   at 131). Resetting the state that actually accumulates is cheaper and does not churn the
   allocator. This looks like the right fix.
2. Raise the default threshold. 64 requests is very aggressive and no evidence in the repo
   justifies that number. This is a mitigation, not a fix: it slows the curve proportionally.
3. Give pooled runtimes their own arena or slab so a rebuild reuses one large mapping
   instead of thousands of small allocations, which keeps recycling available where it is
   genuinely needed without the churn.

Whichever is chosen, the acceptance test now exists and is cheap: sustained load for 30
minutes with the default policy, RSS flat within a band, plus the recycling-disabled arm as
the control.

Note the irony worth recording for the reset: recycling is a correctness mechanism
protecting request isolation, and it is the thing consuming the memory. That is exactly the
kind of interaction the simplification waves must not break, which is why this is fixed
first and with a regression test attached.

### The fix, applied and measured

Landed as a per-runtime lifetime arena in `packages/zts/src/pool.zig`: every
runtime-lifetime allocation draws from one `std.heap.ArenaAllocator`, so destroying a
runtime unmaps once instead of returning about 1,400 small blocks to per-thread freelists.
The per-step errdefers stay, because they release JIT code pages and file descriptors that
an arena does not track, and `destroy` no longer frees individual members through the
caller's allocator, which would now be a mismatched free.

The allocation profile that justified the instrument was measured, not assumed: creating one
runtime performs 1,419 allocations, 1,411 of them under 4 KiB, and a counting allocator
showed live bytes returning to approximately zero on destroy, which is the same "no leak"
answer the Debug build gave.

Like-for-like against the pre-fix 45-minute run, same handler, default 28-runtime pool,
concurrency 8:

| | At 30 minutes | Released when load stopped | Slope |
| --- | ---: | ---: | ---: |
| Before | 234 MB, still climbing | 19 MB of 348, about 5 percent | +8.3 to +8.9 MB/min |
| After | 76 MB, oscillating 51 to 137 | 76 MB to 38 MB, about 50 percent | +1.0 MB/min |

Verification: `zig build test-zts` green, `scripts/verify.sh` green (exit 0, matching the
baseline recorded before the change), 1,000,000 responses in the soak all 200.

**Not yet closed.** The dominant term is gone and memory is returned on idle again, but the
residual is about 1 MB per minute and the band swings widely enough that a 30-minute linear
fit is not trustworthy, which is the same estimator trap documented earlier in this section.
Before declaring this defect closed, run the acceptance soak for two hours and confirm the
band is stationary rather than drifting. If a residual survives, the likely candidates are
the same churn mechanism applied to allocations that still bypass the runtime arena, and the
next step is to profile those the same way rather than to guess.

One test was updated rather than weakened: it allocated module state from the testing
allocator but freed it through `ctx.allocator`, which is now arena-backed. Production
installers allocate from `ctx.allocator`, so the test now matches how the code it covers
owns memory, and the ordering it asserts is unchanged.

Still outstanding from this investigation, and not addressed by this fix:

- The one genuine leak the Debug build found, a startup dupe of the `-e` inline source
  (`packages/runtime/src/cli_shared.zig:108`).
- Unbounded atom interning of arbitrary header names and query-parameter keys
  (`packages/runtime/src/runtime_natives.zig:61`, `:273`) into a table never reset per
  request. Not the cause of this leak, but an unbounded-growth risk under varying traffic.
- `memory_limit` defaulting to unlimited, and applying per runtime while the pool sizes from
  CPU count.
- Whether recycling every 64 requests is the right default at all, now that its memory cost
  is understood. That is a design question for the reset, not a bug.

### Where this investigation stands

Resolved by measurements 4e and 4f above. The growth is driven by the default runtime
recycling policy, and the mechanism is allocator retention under that churn rather than a
missing free. The counter dump was the decisive step, and it answered in the second way the
plan anticipated: none of the engine counters tracked the curve, which pointed below them to
the allocator.

A related gap this exposes: none of these counters is reachable from a running server. There
is no metrics endpoint; `/_health` and `/_readiness` return bare status codes
(`packages/runtime/src/server.zig:613-630`). A runtime that cannot report its own memory
accounting is a runtime whose leaks are found by external RSS sampling, which is how this
one was found. Exposing them behind a debug flag belongs in the reset.

### Consequence: this outranks the refactor

A serverless runtime whose selling point is long-lived pooled runtimes leaks about 8 MB per
minute under continuous load on the default configuration, with no observed bound. At this
rate a container with a 512 MB limit is at risk within an hour of sustained traffic. The
`/_health` arm proves the server layer is clean, so the defect is in the engine, the pool,
or per-request state, on the path that executes JS.

This is a defect, not a design smell, and it takes priority over every simplification in
this plan. Fix it before wave 1. Concretely, the next steps are to narrow which execution
path retains: compare a trivial inline handler, a plain JSON handler, and a JSX handler; and
compare pool sizes, since a per-runtime leak and a per-request leak scale differently. That
matrix is running now.

Note also what this does to section 4.4 and to wave 5 item 3. The dormant generational
collector was described there as machinery serving a load-time-only collector, and the
proposal was to reduce it. With a confirmed leak on the serving path, in a default
configuration where `minorGC` and `majorGC` are no-ops, the collector's dormancy is now a
prime suspect rather than a saving. No GC code is deleted until the leak is understood.

What this does not say: it does not prove a leak. Bytecode caches, inline caches, the
string intern table, and pool warmup all legitimately grow, and 12 minutes on a noisy host
is a proxy, not the hours-long observation wave 0 asks for. Extrapolating the late slope to
an hour or a day would be arithmetic, not evidence, so no such number is claimed here.

What this does say, and it is enough to act on: a warm pooled runtime under continuous load
reaches roughly 10 times its startup footprint within minutes, and short observations cannot
yet tell a bounded band from a slow climb, in a product whose deployment model is exactly a
long-lived pooled runtime under continuous load. Section 4.4 established that in hybrid mode,
which is the default in every shipped configuration, `minorGC` and `majorGC` are no-ops and
collection happens only during handler load. That fact and this measurement belong in the
same investigation.

Consequence for the plan: wave 5 item 3 is inverted. It proposed reducing `gc.zig` on the
theory that a dormant collector serves nothing. The correct next step is the opposite
order: first find out what is accumulating, then decide what the collector should be. Add
this as the first task of wave 0 continuation, ahead of any GC simplification:

- Re-run for several hours on a quiet host and confirm the trend.
- Attribute the growth. Sample allocator statistics, arena high-water marks, bytecode cache
  size, intern pool size, and per-runtime state across the run, and identify which of them
  accounts for the slope.
- If the growth is caches with no eviction, the fix is bounded caches, not a collector.
  If it is reachable-but-uncollected handler garbage, the dormant collector is not dead
  weight, it is a missing call site, and section 4.4 needs rewriting.

Either way, no GC code is deleted until this is answered.

### Reading of measurements 1 to 3 and 5

Three independent lines of evidence agree, and none of them was available before today:

1. The optimized tier is never entered on any benchmark, and the baseline tier is entered
   by two microbenchmarks and by neither HTTP handler benchmark.
2. In the microbenchmark A/B, every benchmark that gains is a benchmark that promotes.
   Handler-shaped work moves -0.1 and -0.6 percent, inside its own noise.
3. End-to-end, best-case throughput and p50 are the same with the JIT on and off, and JS
   execution is about one part in a thousand of request time.

This is sufficient to act on wave 5 item 1: the optimized tier, roughly 2,900 lines, is not
earning its place, because nothing in the corpus reaches it. It is not yet sufficient to
act on wave 5 item 2. The baseline tier demonstrably pays on call-heavy and recursive code
(+52.7 and +39.1 percent), and although no HTTP benchmark reaches it here, a long-lived
pooled runtime accumulates call counts across requests in a way this corpus does not model.
Before deciding the baseline tier, measure one more thing: run a pooled server for a long
period against a call-heavy handler and record whether handler functions cross the 100-call
promotion threshold in practice. That is the missing experiment, and it is cheap.

Measurement 5 stays blocked until a build flag exists that removes only the JIT.

## 9. The plan

Waves are ordered so that every later wave is cheaper and safer because of the earlier
ones. Each wave ends at a gate. Do not start the next wave with a red gate.

Standard gate unless stated otherwise: `bash scripts/verify.sh` green, plus
`bash scripts/test-examples.sh`.

### Wave 0: freeze, inventory, and measure

No code changes. This wave exists because three of the largest proposals below are gated on
numbers that do not exist yet, and because a refactor of this size needs its safety net
built before the first cut, not after.

1. Declare a feature freeze for the duration of the reset. Lift it only when the
   documentation gates, release gates, performance gates, and public-compatibility
   fixtures all pass.
2. Record the baseline in this document: commit, toolchain version, binary sizes,
   `scripts/verify.sh` output, compile-benchmark results, and `doctor --release --json`
   output. Note that the release verdict is currently `ready_with_known_issues` because
   performance claims lack durable measurement receipts; that is unfinished work, not an
   accepted state.
3. Build the public-contract inventory. This is the single most valuable addition to the
   plan and it did not exist in the first draft. Enumerate every surface that must not
   change: CLI stdout, stderr, and exit codes per command; contract JSON; embedded artifact
   contents; every receipt format; module behavior; installer compatibility; and the Zig
   embedding API. Capture a golden fixture for each one before any wave touches it. The
   rule for the whole reset is then mechanical: if a golden moves, the change is wrong,
   and the unit stops until it is explained.
4. Open a deletion ledger. Nothing is removed without recorded live-reference evidence,
   which is the grep or import scan proving no consumer exists. Every deletion proposed in
   sections 4 and 5 already has that evidence and is transferred into the ledger with its
   citation. Nothing is deleted because a file is large or a date is old.
5. Run all five measurements in section 8 and record the results. Regenerate
   `zig build bench` and `bench-check` baselines so every later deletion has a before and
   after receipt.
6. Write the target dependency graph down before moving any code.

Exit when every reset item has an owner, an invariant, a test surface, and a position in
the dependency order.

### Wave 0.5: make verification authoritative

`scripts/verify.sh`, `ci.yml`, `release.yml`, and `doctor --release` describe overlapping
but non-identical gate sets. The first pass measured the drift (section 3 of the meta
findings: `verify.sh` mirrors `ci.yml` faithfully but not `release.yml`) and proposed
patching the differences. The better fix is one declarative verification manifest with
fast, CI, and release profiles, from which the build steps, the script, both workflows, and
doctor reporting all derive. Add to it the dependency-boundary and generated-artifact drift
checks, and an example manifest classifying every example as supported, illustrative,
expected-failure, or live-service dependent.

Performance receipts become reproducible artifacts recording commit, Zig version, host,
run configuration, sample count, and thresholds. Do this wave before any refactor wave, so
that every later claim of "no regression" is made against one authority instead of four.

Exit when the release profile covers every supported surface and `doctor --release --json`
returns ready.

### Wave 1: provably dead code, low risk

1. Delete `packages/zts/src/parser/parse.zig.tmp`.
2. Delete the generator machinery and make `function*` a parse error with the same
   diagnostic style as `yield`. About 250 lines.
3. Delete the async opcodes and their interpreter, verifier, and JIT-exclusion handling.
   About 100 lines. The bytecode verifier will now reject old cached bytecode containing
   them, which is correct fail-closed behavior, and the cache key changes anyway.
4. Delete the catch-handler machinery from `Context` and the frame save and restore of
   `catch_depth`. About 200 lines.
5. Delete the loose-equality remnants from the IR, folder, codegen, and interpreter. Decide
   `comptime.zig`'s `==` deliberately; the recommendation is to remove it for language
   consistency, after grepping `examples/` to size the change.
6. Delete `compiler.zig`'s parallel driver and all of `intern_pool.zig`, keeping only the
   `compile` helpers next to their single consumer. About 950 lines.
7. Delete the `kind=check` ledger variant and fix the stale doc at `proof_ledger.zig:1-2`.
8. Delete the semantics receipt and workflow receipt signing paths. About 470 lines
   including `hypermedia_receipt.zig`. The `spec-check` exit code and the CI JSON gate are
   untouched.

Gate: standard, plus `zttp spec-check` passing with an intentionally changed spec hash.

### Wave 2: relocation and boundaries, no behavior change

1. Move `cli_release_check.zig` out of the product CLI into repository tooling. Update
   `release.yml`.
2. Move `benchmark.zig` and `compile_benchmark.zig` out of `packages/runtime/src`.
3. Move `packages/tools/src/skills/zts-expert/` into `packages/pi`.
4. Split `zruntime.zig`: move its roughly 4,900 test lines to `zruntime_tests.zig`, extract
   the actor-queue callbacks into their own file mirroring `ws_runtime_callbacks.zig`, and
   delete the alias shims at `zruntime.zig:36-68` by updating call sites.
5. Extract `AtomTable` from `context.zig` into its own module so `parser/codegen.zig` stops
   importing the runtime context. Group the JIT fields of `Context` into one struct and
   move the HTTP and JSX caches into an http-owned side structure.
6. Split `module_binding.zig` into capabilities, ABI bridge, and types.
7. Rename `server_io.zig` to reflect that it is generic fd helpers, and document the
   `zruntime` to `server_io` import.
8. Create curated `zts`, `zts-compiler`, and `zts-contracts` build modules with
   package-local internals, and enforce the boundary with a forbidden-import check. Do this
   before considering any physical package move. `packages/zts/src/root.zig` documents a
   stable-versus-internal split today but re-exports both, and runtime, tools, and pi all
   import internals directly. Curating the module surface is cheap, reversible, and it makes
   the later moves mechanical. It also replaces the first draft's proposal to relocate
   `canonicalize.zig` and `edit_simulate.zig` into `packages/zts`: fix the surface first,
   then decide whether the files need to move at all.

Gate: standard, plus `zig build --list-steps` diff empty, plus the forbidden-import check
passing.

### Wave 3: test and build hygiene

1. Stop double-executing the zruntime and server suites. `main.zig:10-18` imports both
   `zruntime.zig` and `server.zig` into the aggregate test root while standalone roots run
   the same tests again. Keep the separate processes that the macOS teardown note requires
   (`build.zig:744-747`); change only the membership.
2. Remove the redundant `test-docs-drift` invocation in CI and in `verify.sh` step 2, and
   add `test-doc-links` to the `test` step.
3. Table-drive the nine host-tool and pi test roots and the five `embedded_handler` stub
   attachments in `build.zig`. About 150 to 180 lines of 972.
4. Delete the three unused package-local `test` steps.
5. Add tests for `runtime_http.zig` and link `witnesses_cli.zig` into a test root.
6. Turn `scripts/check-docs-drift.sh`'s accumulated one-off regexes into a data table and
   retire the bans whose docs no longer exist.

Gate: standard, plus identical collected-test counts before and after item 1.

### Wave 4: ownership and concept unification

This is the substance of the reset. The first four items are ownership resets added from
the external review; they are larger and more valuable than the concept cleanups that
follow them, and they should be sequenced first.

0a. Introduce the fallible `CompileRequest` to `CompiledModule` API from section 4.5, with
   explicit Parsed, Resolved, Checked, Contracted, Lowered stages and one idempotent
   `deinit`. Retire the infallible parser constructors (`parse.zig:131-133`,
   `parser/root.zig:170`, `parser/scope.zig:151`) and the legacy Parser wrapper
   (`parser/root.zig:133-136`) once every caller has migrated. Stop recreating type,
   environment, and checker state during contract extraction; carry one session through all
   stages. Move compile benchmarking off the arena that currently masks nested-function
   ownership, and measure the real production pipeline.

0b. Build the immutable `ModuleFacts` index from section 5.6 and convert contract
   construction to pure projections. Replace the runtime's hand-written wire reader with
   the canonical codec plus a runtime projection, keeping the raw-to-validated promotion and
   every capability, policy, and hash check intact. Make typed module descriptors
   authoritative for binding, capability, effect, documentation, and governance metadata,
   and generate the module spec JSON and documentation mirrors from them rather than
   editing either by hand. This resolves the module-specs governance question in section 10
   without deleting the tripwire.

0c. Introduce `HandlerInstance` as the owner of the engine runtime, installed builtins,
   loaded handler, invocation state, and reset lifecycle, owned directly by the pool. This
   removes the runtime-to-pool back-imports and the alias bridges.

0d. Replace the ambient state in section 6.1 with an explicit `InvocationContext` passed to
   native callbacks, and introduce the data-only `ExecutionSpec` mapped from `ServerConfig`
   at the composition edge so durable scheduling and recovery stop depending on the full
   server configuration.

1. Collapse the four verdict vocabularies onto one type, and delete the hand-mirrored enum
   at `proof-review/review.zig:27-30`.
2. Merge `zttp proof replay` into the `proofs` namespace, keeping the old spelling as a
   hidden alias for one release. This removes the naming collision that CLAUDE.md
   currently has to disclaim.
3. Fold `ratchet check` into `check` behind a fail-on-undischarged flag over the spec
   diagnostics that already exist, and either build the announced waiver system or delete
   its comment.
4. Add the shared import and binding index computed once after parse, and the shared IR
   shape helper library. Move `precompile.zig`'s orchestration into `pipeline.zig` so
   `PathGenerator` and `FlowChecker` run exactly once per compile.
5. Replace `ui_payload.zig`'s 44 hand-written clone and deinit functions with arena-owned
   payloads. About 1,500 to 2,000 lines of 3,013.
6. Add the comptime argument-decode wrapper for module impl functions, generated from the
   `param_types` already declared in each binding.
7. Add the comptime JSON-tool generator for the 20 thin pi wrappers.
8. Define typed `CommandDescriptor` records carrying name, help, options, capability
   requirements, handler, and output contract, and derive dispatch and help for all three
   binaries from them. Each binary keeps its own command set and its exact current output.
   The command registry already proves the principle: the generated parts of the help
   surface never drift while the hand-written parts do.
9. Extract artifact construction into an explicit `BuildRequest` plus `BuildCapabilities`
   to `BuildReceipt` service with declared dependencies, so building an artifact stops
   being a set of ambient effects.
10. Convert pi's flat tool catalog into typed capability bundles. Classify every tool
   first; remove a wrapper or a provider only after prompt, cassette, schema, and
   live-reference analysis proves it redundant.

Gate: standard, plus every compile path and every failure stage leak-free under
`std.testing.allocator`, plus byte-identical contract, artifact, and receipt fixtures, plus
unchanged CLI goldens, plus the runtime dependency graph proven acyclic and free of ambient
dispatch state.

### Wave 5: measurement-gated structural cuts

Only with wave 0 numbers in hand.

1. Cleared to proceed by wave 0. Optimized-tier entry is zero on every benchmark, so delete
   the optimized tier and its deopt plumbing.
2. Not cleared. The baseline tier pays where it promotes (+52.7 percent on `functionCalls`,
   +39.1 percent on `recursion`), and no HTTP benchmark reaches it in this corpus. Run the
   pooled-server promotion experiment named in section 8.1 before deciding. If it stays
   unreached under sustained real traffic, delete the baseline tier,
   `type_feedback.zig`, both machine-code emitters, the `Context` JIT fields, and the
   `jit_inhibited` durable special case. This is roughly 14,900 lines and it is the single
   largest simplification available.
3. Blocked and inverted by the wave 0 RSS result in section 8.1. Warm-runtime memory grew
   120 MB in 12 minutes without flattening, so no GC code is deleted until the growth is
   attributed. If the cause is unbounded caches, the fix is eviction and this item returns
   as written. If the cause is uncollected handler garbage, the collector is a missing call
   site rather than dead weight, and this item is struck.
4. Consider replacing `comptime.zig`'s separate tokenizer, parser, and value model with
   evaluation over the main IR after parse. This deletes about 1,800 lines and structurally
   resolves the `==` inconsistency, but it needs more comptime tests first.

Gate: standard, plus the before-and-after bench receipts from wave 0, plus the deploy
artifact size recorded.

### Wave 6: documentation reset

Run this last, so the docs describe the simplified system rather than the current one.

1. Rewrite `CLAUDE.md`. Today its CLI paragraph is a single roughly 5,900-character
   sentence chain. Its content survived accuracy spot-checks, but about 70 percent of it is
   engine internals that belong in a document, not in the instruction file loaded into
   every agent turn. Target about 120 lines: build commands, module table, subset summary,
   conventions, and a 10-line surface summary that links to `docs/cli.md` and a new
   `docs/internals/semantics-verification.md` receiving the spec-check and SMT content
   verbatim. Fix two stale claims while there: line 129 says `verify.sh` does not run
   `zig fmt --check` but `verify.sh:96-97` does, and line 283 points benchmarks at
   `../zttp-bench`, which does not exist on this machine while the repository itself ships
   `zig build bench`.
2. Fix the six-command hole in `docs/cli.md`: `doctor`, `build`, `compile`, `ratchet`,
   `witnesses`, and `ledger` are advertised by `help --all` (`cli_help.zig:62-98`) and
   documented nowhere. Then make it a gate: extend `check-docs-drift.sh` to assert that
   every `help --all` command name appears in `docs/cli.md`. This converts a one-time fix
   into a standing invariant, which is why the generated surfaces in this repository never
   drift and the hand-written ones do.
3. Merge overlapping documents: `typescript-patterns.md` into `typescript.md`, and
   `counterexamples.md` plus `witnesses.md` plus `proof-card.md` plus `proof-gate.md` into
   one proofs and receipts reference, and `canonical-profile.md` into the `canonicalize`
   section of `docs/cli.md`.
4. Archive the dated planning residue: `docs/plans/`, `docs/ideation/`, `docs/vision/`, the
   root `plans/` directory, `IMPROVEMENT_PLAN.md`, `DEFERRED_VM_LOOP_DEDUPE_PLAN.md`, and
   `packages/zts/src/docs/v0.1-v0.2-gap-analysis.md`. That is 8,187 lines, about 39 percent
   of all prose, referenced by no gate. Keep `docs/solutions/`, which agents are pointed at.
   Move the three top-level HTML explainers into the archive or the website repository.
   This document joins the archive once the plan is executed.
5. Write the missing contributor document: which steps `zig build test` includes and
   excludes, and why the zruntime suite is standalone.

Gate: `zig build test-docs-drift test-doc-links` green, and the new CLI-coverage assertion
passing.

## 10. Decisions needed from the owner

Everything below is a working feature. Cutting any of it is a product decision, not
cleanup, so none of it is scheduled above. The plan assumes "keep" until told otherwise.

| # | Capability | What is lost | Recommendation |
| --- | --- | --- | --- |
| 1 | Third-party module extension SDK | The designed ABI for out-of-tree modules; `extension-status` and `verify-module-manifest` become vestigial. Removing the bridge, adapter, sdk package, and shims is about 2,600 lines. | Keep only if extensions ship within about two releases. Otherwise collapse. |
| 2 | Edge runtime (`zttp edge`) | Multi-handler routing on one listener. Already opt-in, and TLS termination is unimplemented (`runtime_cli.zig:188-190`). 1,154 lines. | Cut or freeze. |
| 3 | `zttp demo` and the first-run proof quest | The Proof Theater first-run experience, smoked by `smoke-demo.sh`. Up to 1,737 lines out of the default build. | Gate behind a build flag like studio. |
| 4 | TUI lenses `trade`, `handover`, `caller_view`, and the proof certificate | HUD depth beyond the properties card. Part of 1,673 lines. | Cut or move behind `-Dstudio`. |
| 5 | `proofs badge`, `proofs export` html and svg, `proofs watch` | The README-badge share story and the live ledger tail. All write-only or duplicated by the dev HUD. | Cut. |
| 6 | Perf receipt signatures | The Ed25519 envelope. The p50 and p99 numbers stay in the ledger. | Cut the signing, keep the numbers. |
| 7 | `--expect-properties` build input | The JSON expectations authoring surface. `Spec<...>` declarations remain. 688 lines. | Cut after migrating any example expectations. |
| 8 | OpenAI backend for `zttp expert` | A documented capability including `zttp auth openai`. 1,345 lines. | Owner call. Anthropic-only would simplify the beta. |
| 9 | module-specs JSON governance | An intentional drift tripwire. Note the correction in section 11: the specs are referenced by `builtin_modules.zig` as well as the audit, so this is not a clean delete. | Keep unless the audit proves redundant against `validateBindings`. |
| 10 | Analyzer tail commands: `gen-tests`, `canonicalize`, `normalize`, `rollout`, `mock` | Advertised machine surface for IDE and CI integrations. | Keep. They are cheap at the registry level. |
| 11 | `sdk_codegen` and `openapi_manifest` | `precompile --sdk ts` and `--openapi`. About 1,900 lines. | Keep unless the beta surface excludes them. |
| 12 | Separate `zts` install | The analyzer-only-binary story for CI. Only 52 lines of unique code. | Keep. Nearly free. |

## 11. Corrections to the reviews

Second-pass verification changed three claims. They are recorded because the plan depends
on them.

1. The JIT A/B knob is `ZTS_JIT_POLICY=disabled`
   (`packages/zts/src/interpreter/jit_policy.zig:26-56`). `ZTS_DISABLE_JIT` appears only as
   a test guard in `zruntime.zig` and does not disable the engine's JIT. A review implied
   the measurement was directly runnable with the latter.
2. The module-specs JSON files have two consumers, not one: `module_audit.zig` and
   `builtin_modules.zig:94` onward, where each entry carries a `spec_path`. Deleting the
   audit does not orphan the specs.
3. `parse.zig.tmp` is covered by the `*.tmp` gitignore rule, so it never inflated the
   tracked line count. It is still a live trap for readers and greps and should go.
4. The external review's finding that artifact building performs process-wide
   working-directory mutation is misattributed. Verified: every `chdir` call in the
   repository is in pi test harnesses and the codegen recorder
   (`packages/pi/src/agent.zig:1357-1462`, `expert_codegen_record.zig:337`), each paired
   with a restoring `defer`. No production build path mutates the working directory. The
   `BuildRequest` to `BuildReceipt` proposal still stands on its own merits, but not on
   that justification.
5. The external review's baseline claims, that the verifier, edge and WebAssembly builds,
   the Studio smoke test, and the benchmark gates all pass at 113022e3, were not
   independently re-run for this document. Wave 0 records them properly.

## 12. Reconciliation with the external reset plan

A second, independently produced reset plan was merged into this document. Most of it is
complementary and has been absorbed into the sections above: the compile ownership finding
(4.5), the duplicate wire reader (5.6), the ambient dispatch state (6.1), the verification
manifest (wave 0.5), the public-contract inventory and deletion ledger (wave 0), and the
ownership resets (wave 4, items 0a to 0d). Its process discipline is stronger than the
first draft's and is adopted wholesale: freeze features, capture goldens before cutting,
require live-reference evidence for every deletion, and stop the current unit on any
unexplained public behavior difference.

Three genuine conflicts remain. They are recorded rather than silently resolved, because
each is a decision, not a detail.

**Conflict 1, the JIT.** The external plan locks the interpreter, baseline JIT, and
optimized JIT as three separate execution loops and rejects removing any of them. This
document says the question is unanswered and gates it on five measurements that have never
been recorded. These positions are not compatible, and the difference is roughly 14,900
lines. The recommendation is to run wave 0 first and let the numbers decide. A lock adopted
before the measurement is a preference; a lock adopted after it is engineering. If the
numbers show the JIT earns its place, this document's wave 5 items 1 and 2 are struck and
the lock stands. Note that both plans already agree on the smaller point: no universal
opcode visitor and no virtual dispatch in the execution loops. Sharing pure opcode metadata
and semantic primitives is allowed; sharing the dispatch loop is not.

**Conflict 2, retention.** The external plan locks retention of pi, proof review, Studio,
edge, WebAssembly, WebSockets, durable execution, workflows, queues, modules, and installer
compatibility. This document agrees on all of them except that it lists edge, the demo and
quest, several HUD lenses, badge and export, and three unread receipts as owner decisions
in section 10. The conflict is narrower than it looks: the external plan's own rule is that
nothing is removed without live-reference evidence, and every item in section 10 carries
that evidence. So the rule is satisfied and the disagreement is purely about product
appetite. Section 10 stays as written, with the default set to keep.

**Conflict 3, deletion policy versus dead code.** The external plan says not to remove
source, examples, tools, or documentation based on file size or apparent age alone. This
document agrees and never proposes a deletion on those grounds. Wave 1 removes only code
that is unreachable by construction, each item verified by a parse-time ban plus an absent
consumer, and each one is now entered in the deletion ledger with its citation. The 8,187
lines of dated planning documents in wave 6 are archived, not deleted, and git holds the
detail either way.

Two smaller positions from the external plan are adopted without reservation. First,
publish only performance numbers that a release receipt supports, and otherwise remove the
claim; `docs/performance.md` currently carries numbers it flags as unverified, which is why
the release verdict is `ready_with_known_issues`. Second, do not hand-edit generated
documentation, vendored artifacts, or `CHANGELOG.md`.

### 12.1 Acceptance thresholds

The first draft had gates but no reject criteria. These are adopted. Reject a unit of work
if the compiler suite geomean regresses more than 5 percent, an individual compiler fixture
regresses more than 10 percent, binary size grows more than 5 percent, or an existing
benchmark threshold fails without an evidence-backed explanation. Run the final release
profile twice, once from a clean cache and once warm, to expose hidden dependencies and
flakiness.

### 12.2 Required final commands

```
zig fmt --check build.zig packages/
zig build test
zig build test-zts
zig build test-zruntime
zig build test-cli -Dstudio
zig build smoke-v1
zig build smoke-studio -Dstudio
zig build wasm
zig build -Dedge test
zig build bench-check
zig build compile-bench -Doptimize=ReleaseFast -- --json --iterations 50
bash scripts/test-examples.sh
bash scripts/verify.sh
./zig-out/bin/zttp doctor --release --json
git diff --check
git status --short --branch
```

Reset-specific scenarios to add and pass: nested-function compilation and every failure
stage under `std.testing.allocator`; goldens for diagnostics, contracts, bytecode,
artifacts, receipts, CLI streams, and exit codes; end-to-end tests for pool reset,
concurrent isolation, timeout, panic recovery, WebSocket lifecycle, durable replay, and
restart recovery; browser verification of Studio before and after any control-surface
change; completeness checks over examples, commands, pi tools, package tests, module
descriptors, and generated outputs; and forbidden-import and dependency-cycle checks.

## 13. Deletion ledger

Wave 0 item 4. Nothing is removed without recorded live-reference evidence. Every row below
was verified by grep or import scan on 2026-07-28 at 329e88de. A row is cleared to execute
only when its evidence still holds at the moment of the cut, so re-run the check in the
commit that performs it.

| # | Target | Live-reference evidence | Re-check command | Status |
| --- | --- | --- | --- | --- |
| D1 | `packages/zts/src/parser/parse.zig.tmp` | Untracked editor artifact, gitignored by the `*.tmp` rule; no importer possible | `git check-ignore -v <path>` | cleared |
| D2 | Generator machinery: `object.zig:889-898`, `object.zig:1821-1895`, `interpreter/call.zig:113-140`, `context.zig:267`, `is_generator` plumbing | `yield` is a parse error (`parse.zig:1701`); only references to `createGenerator*` outside `object.zig` are the two creation sites; nothing advances a generator | `git grep -n 'createGenerator\|GeneratorState\|generator_prototype'` | cleared |
| D3 | Async opcodes `await_val`, `make_async` and their interpreter, verifier, and JIT-exclusion handling | async is a parse error, so no producer exists; opcodes documented as "kept for future implementation" (`bytecode.zig:163-165`) | `git grep -n 'await_val\|make_async'` | cleared |
| D4 | Catch stack: `context.zig:199`, `:274`, `:1923-1944`, frame save/restore | `try/catch` is a parse error; no non-test caller of the push/get functions | `git grep -n 'catch_stack\|CatchHandler\|catch_depth'` | cleared |
| D5 | Loose-equality remnants: `parse.zig:3241-3242`, `ir.zig:83-84`, `ir_opt.zig:303`, `codegen.zig:994-995`, interpreter eq/neq, opcodes 0x44/0x45 | `==` and `!=` are parse errors (`parse.zig:1748-1755`), so no producer exists | `git grep -n 'eq\b.*neq\|0x44\|0x45'` plus a parse-error test | cleared, but see note |
| D6 | `compiler.zig` `Compiler`, `compileParallel`, `CompileUnit`; all of `intern_pool.zig` | Only importer is `semantics_corpus.zig:34`, which uses the plain `compile()` helper; `intern_pool` is imported only by `compiler.zig` and re-exported by `root.zig` | `git grep -ln 'intern_pool.zig\|compileParallel'` | cleared |
| D7 | `kind=check` ledger variant | Only `.kind = .check` producer is a test (`proof_ledger.zig:622`); module doc at `:1-2` claims production use that does not exist | `git grep -n '\.kind = \.check'` | cleared |
| D8 | Semantics receipt signing (`semantics_probe_lib.zig`), workflow receipt signing (`hypermedia_probe_lib.zig`, `hypermedia_receipt.zig`) | Only references to `semantics-receipt` and `workflow-receipt` are inside their producers; the CI gate reads the `--json` summary (`scripts/verify.sh:83-84`), not the receipt | `git grep -n 'semantics-receipt\|workflow-receipt'` | cleared |
| D9 | Optimized JIT tier and deopt plumbing | Wave 0 measurement: `tier_promotions.optimized` is 0 on all 13 benchmarks | re-run `zig build bench -Doptimize=ReleaseFast -- --json` and confirm | cleared by measurement |
| D10 | Baseline JIT tier | Not cleared. Pays +52.7 percent on `functionCalls` and +39.1 percent on `recursion`; pooled-server promotion experiment outstanding | see section 8.1 | blocked |
| D11 | Any `gc.zig` reduction | Not cleared. Warm-runtime RSS grows without flattening; growth unattributed | see section 8.1 | blocked |

Note on D5: the deletion is cleared for the runtime language, but `comptime.zig` genuinely
supports `==` today (`comptime.zig:9`, `looseEquals` at `:134`). Removing it there is a
behavior change to `comptime()` expressions, not dead-code removal. Grep `examples/` and any
user corpus first, and treat it as a small breaking change with its own decision, not as
part of D5.

Rows D1 to D8 are wave 1. Together they are the roughly 2,000 lines the plan calls
removable at low risk, and each one is unreachable by construction rather than merely
unused.

## 14. What this buys

Wave 1 removes roughly 2,000 lines that are provably unreachable today, at low risk, in
about a week. Waves 2 through 4 remove or relocate several thousand more without any
user-visible behavior change, and they retire the duplicate concepts that make the codebase
feel larger than it is: four verdict types for one algorithm, five scanners for one
language, three answers to one spec question, and two module systems.

Wave 5 is where the large numbers are, and it is deliberately last and deliberately gated
on measurement. Between the JIT and the dormant collector, roughly 17,000 lines are
waiting on five benchmark runs that have never been recorded. That is the highest
leverage available in this repository, and it is an afternoon of measurement, not an
argument.
