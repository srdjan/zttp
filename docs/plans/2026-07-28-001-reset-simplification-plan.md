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

## 9. The plan

Waves are ordered so that every later wave is cheaper and safer because of the earlier
ones. Each wave ends at a gate. Do not start the next wave with a red gate.

Standard gate unless stated otherwise: `bash scripts/verify.sh` green, plus
`bash scripts/test-examples.sh`.

### Wave 0: measure and freeze the baseline

Run all five measurements in section 8 and record the results here. Regenerate
`zig build bench` and `bench-check` baselines so every later deletion has a before and
after receipt. No code changes. This wave exists because three of the largest proposals
below are gated on numbers that do not exist yet.

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

Gate: standard, plus `zig build --list-steps` diff empty.

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

### Wave 4: concept unification

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

Gate: standard, plus golden outputs for `prove`, `prove-behavior`, `gate`, and the deploy
card unchanged, plus contract golden files unchanged.

### Wave 5: measurement-gated structural cuts

Only with wave 0 numbers in hand.

1. If optimized-tier entry is near zero on the handler corpus, delete the optimized tier
   and its deopt plumbing.
2. If handler-shaped throughput barely moves without the JIT, delete the baseline tier,
   `type_feedback.zig`, both machine-code emitters, the `Context` JIT fields, and the
   `jit_inhibited` durable special case. This is roughly 14,900 lines and it is the single
   largest simplification available.
3. If long-run RSS is flat, reduce `gc.zig` to a plain stop-the-world mark-sweep for the
   load path and non-hybrid embedders, keeping the budget-checked allocator front end.
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

## 12. What this buys

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
