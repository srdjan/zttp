# Splitting `zts` into layered build modules

Planned as three modules; shipped as five. The filename keeps the original name.

Status: done. Steps 0 through 5 are complete; step 5 closed one allowlist row
and the rest is recorded below as deliberately not done.
Scope: `packages/zts/`, `packages/zts/build.zig`, the root `build.zig`,
`scripts/check-module-boundary.sh`, `scripts/module-boundary.allow`.

## Why this document exists

`scripts/check-module-boundary.sh:25-30` records the split as the remaining half
of a two-part item, and prices it as "rewiring 36 of the 84 files in
packages/zts/src off relative imports". That price is measured from a tree that
has since changed, and it names the wrong obstacle. This document replaces the
estimate with measurements taken from the current tree, and states what the work
actually is.

## What was measured

The measurement is the `@import("....zig")` graph over every tracked Zig file in
`packages/zts/src`. Relative imports only; named-module imports (`std`,
`zttp-sdk`, `zttp-modules`, `build_options`) are excluded because they already
cross a module boundary correctly.

| Quantity | Value |
|---|---|
| Tracked `.zig` files under `packages/zts/src` | 154 |
| Of those, at the top level of `src/` | 94 |
| Relative import edges between them | 760 |
| Non-trivial strongly connected components | 3 |
| Largest strongly connected component | 101 files |
| Files reachable from the engine entry points | 154 of 154 |

The comment's "84 files" counted the top level of `src/` at the time it was
written; that count is 94 today, and the package is 154 files once the
subdirectories are included. The "36 files" figure is not reproducible from the
current tree. Under the tier assignment proposed below, 57 files hold at least
one relative import that crosses a proposed module line.

## The obstacle is not relative imports

Rewiring a relative import to a named one is mechanical. The blocking fact is
different, and the file count hides it:

**The engine's transitive import closure is the entire package.** Starting from
`context.zig`, `interpreter.zig`, `pool.zig`, `builtins/root.zig`,
`parser/root.zig`, `http.zig`, `stripper.zig`, `modules/root.zig`,
`comptime.zig`, and `bytecode_cache.zig`, every one of the 154 files is
reachable. 101 of them sit in a single strongly connected component that
contains the interpreter, the parser, the builtins, the flow checker, the type
checker, the contract types, and the semantics registry together.

A Zig module graph is a DAG. `zts-compiler` may import `zts`; `zts` may not
import `zts-compiler`. So no assignment of these 154 files to three modules is
legal until the cycles between the tiers are broken. Rewiring the imports
without breaking the cycles produces exactly the failure the comment predicts -
the engine gets analyzed twice and `JSValue` from one copy is not `JSValue` from
the other - because the second copy is what a cyclic edge across a module line
compiles to.

Therefore: **cut the back edges first, rewire second, split the build last.**

## The back edges that carry the cycle

A greedy search removed, at each step, the single edge whose removal freed the
most files from the engine closure. The result is concentrated, not diffuse:

| Edge | Files freed | Closure after |
|---|---|---|
| `trace.zig` to `root.zig` | 26 | 128 |
| `handler_contract.zig` to `contract_builder.zig` | 23 | 105 |
| `parser/root.zig` to `parser/codegen.zig` | 7 | 98 |
| `modules/root.zig` to `modules/internal/types.zig` | 4 | 94 |
| `modules/net/service.zig` to `system_linker.zig` | 2 | 92 |
| `handler_policy.zig` to `handler_contract.zig` | 5 | 87 |
| `modules/internal/resolver.zig` to `builtin_modules.zig` | 2 | 85 |

Seven cuts take the engine closure from 154 to 85. Everything after that frees
one file per cut and is ordinary tier assignment, not cycle breaking.

The search names the edge it can cut, which is not always the edge to cut. Rows
three and four are the clearest case: nothing is wrong with `parser/root.zig`
importing `parser/codegen.zig`, or with `modules/root.zig` importing
`modules/internal/types.zig`. Those are the edges the search reaches because
the offending imports sit one file further down - `parser/codegen.zig` reaches
three analyzer files, and `modules/internal/types.zig` is compiler code filed
under `modules/`. Reproduce the numbers with `bash scripts/zts-import-graph.sh`
and read the row as "the subtree behind this edge", not as an instruction.

Each of the seven is thin at the call site. Inspected:

- `trace.zig` to `root.zig` - four imports, all inside `test` blocks
  (`trace.zig:2115`, `:2124`, `:2158`, `:2170`), each reaching
  `zts.createContext` / `zts.destroyContext`. No non-test code depends on it.
  This one edge is why `builtins/helpers.zig` transitively imports the entire
  semantics registry.
- `handler_contract.zig` to `contract_builder.zig` - a re-export facade.
  `handler_contract.zig:82-83` is commented "Re-exports from
  contract_builder.zig" and aliases one symbol, `ContractBuilder`.
- `handler_policy.zig` to `handler_contract.zig` - one type alias
  (`handler_policy.zig:7,13`), taken so the policy file does not "reach into
  handler_contract directly". It reaches in anyway, through the alias.
- `parser/codegen.zig` to `handler_analyzer.zig` - one construction site,
  `codegen.zig:2907`.
- `parser/codegen.zig` to `bool_checker.zig` - two references to one type,
  `bool_checker.NodeTypeMap` (`codegen.zig:106,194`).
- `parser/codegen.zig` to `module_manifest.zig` - two references,
  `validSpecifier` and `namespaced_export_separator` (`codegen.zig:581,587`).
- `modules/net/service.zig` to `system_linker.zig` - one call,
  `parseSystemConfig` (`service.zig:93`).
- `modules/internal/resolver.zig` to `module_manifest.zig` - one reference to
  `namespaced_export_separator` (`resolver.zig:142`).
- `modules/internal/types.zig` to `type_pool.zig` and `type_env.zig` - not a
  cut. The file populates a `TypeEnv` from the module bindings; it is compiler
  code filed under `modules/`. It moves rather than being severed.

## Proposed tier assignment

Four modules, strictly layered bottom to top (see Decisions below).

- **`zts-base`** - utilities every other tier names, depending on nothing in
  the package: `file_io.zig`, `json_utils.zig`, `compat.zig`.

- **`zts-contracts`** - contract and receipt data types with their
  serialization, and nothing that analyzes or executes. Candidates:
  `contract_types.zig`, `contract_json_parser.zig`, `contract_json_writer.zig`,
  `handler_contract.zig` (after the `ContractBuilder` re-export is dropped),
  `module_manifest.zig`, `module_facts.zig`, `api_schema.zig`, `json_wire.zig`,
  `perf_receipt.zig`, `equivalence_receipt.zig`, `service_types.zig`,
  `contract_diff.zig`.

- **`zts`** - the engine: value representation, GC and heap, objects and
  strings, context, bytecode, interpreter, builtins, parser, pool, stripper,
  comptime, HTTP, the virtual-module implementations, SQLite. Roughly the
  85-file closure that remains after the seven cuts, minus the files that the
  cuts move up.

- **`zts-compiler`** - everything that decides whether a program is proven:
  the checkers (`bool_checker`, `flow_checker`, `type_checker`,
  `strict_checker`), the type system (`type_pool`, `type_key`, `type_env`,
  `type_map`), `handler_analyzer`, `handler_verifier`, `contract_builder` and
  the extractors, `effect_inference`, `path_generator`, `counterexample`,
  `fault_coverage`, the `semantics_*` family, the three registries
  (`rule_registry`, `idiom_registry`, `restriction_registry`), the `repair_*`
  family, `spec_discharge`, `system_linker`, `pipeline`, `sql_analysis`,
  `match_analysis`, `diagnostic_projection`, and `modules/internal/types.zig`
  relocated out of `modules/`.

Files not yet placed and needing a decision during step 2: `policy.zig`,
`handler_policy.zig`, `security_events.zig`, `module_authorization.zig` (runtime
enforcement, so probably `zts`), `trace.zig` (engine-side recorder, so `zts`),
`witness_corpus.zig`, `proof_trace.zig` (compiler).

## Plan

**Step 0 - freeze the measurement.** Land `scripts/zts-import-graph.sh` so
every number in this document is reproducible from the tree, and correct the
stale price in the `check-module-boundary.sh` header. Done.

**Step 1 - cut the seven back edges, one commit each.** No module boundary
exists yet, so each cut is independently verifiable with `zig build test-zts`
and each is revertible on its own. Order matters only in that
`trace.zig` to `root.zig` is first and free. Done; see the results below.

**Step 2 - assign every file to a tier and prove the assignment is acyclic.**
`scripts/zts-tiers.allow` holds the assignment and
`scripts/check-zts-layering.sh` enforces it, wired into `zig build test` as
`test-zts-layering`. Done; see the results below.

**Steps 3 and 4 - rewire the imports and split the build.** These are one
change, not two: a named import needs the module to exist. Done, bottom-up, one
tier per commit; see the results below.

**Step 5 - shrink the consumer allowlist where a curated name earns it.**
Done, and it closed one row rather than many; see the results below. The
premise this step was written on did not survive the umbrella decision.

## Step 1 results, 2026-08-07

Six commits. `bash scripts/verify.sh` passes.

| | Before | After |
|---|---|---|
| Files under `packages/zts/src` | 154 | 157 |
| Relative import edges | 760 | 765 |
| Engine import closure | 154 (100%) | 94 (60%) |
| Largest strongly connected component | 101 | 48 |
| Non-trivial components | 3 | 6 |

What changed, in order:

1. `trace.zig` stopped importing `root.zig`. Local
   `testCreateContext`/`testDestroyContext` replace the four test-only reaches.
   Closure 154 to 128.
2. `handler_contract.zig` stopped re-exporting `ContractBuilder`. Its two
   callers, `pipeline.zig` and `root.zig`, name `contract_builder.zig`.
   Closure 128 to 105.
3. Two new leaf files gave `parser/codegen.zig` lower homes for the vocabulary
   it borrowed: `node_types.zig` holds `ExprType` and `NodeTypeMap` (was in
   `bool_checker.zig`), and `module_specifier.zig` holds `validSpecifier` and
   `namespaced_export_separator` (was in `module_manifest.zig`). Both original
   files re-export what they used to define. Closure 105 to 102 with two files
   added.
4. `modules/internal/types.zig` moved to `module_types.zig`. It fills a
   `TypeEnv` from the module bindings and only the type checker, the handler
   verifier and the pipeline call it. Closure 102 to 98.
5. `SystemConfig` and `parseSystemConfig` moved from `system_linker.zig` to
   `system_config.zig`, so `zttp:service` can read `system.json` at runtime
   without importing 1700 lines of cross-handler proof. Closure to 97 of 157.
6. `handler_policy.zig` imports `contract_types.zig` instead of
   `handler_contract.zig`. One line; every name it resolves is unchanged.
   Closure 97 to 94.

Two rows in the original table turned out not to be cuts:

- **`parser/codegen.zig` to `handler_analyzer.zig` was left in place.**
  `handler_analyzer.zig` imports `bytecode.zig`, `parser/ir.zig`, `object.zig`
  and `context.zig` and nothing else, and what it produces is a
  `PatternDispatchTable` the interpreter reads at run time. It is an engine
  optimization pass, not analysis, so codegen naming it is a same-tier edge.
  This is the row the plan flagged as behavior-bearing; the behavior does not
  need to move, so no test was needed to pin it.
- **`modules/internal/resolver.zig` to `builtin_modules.zig` resolved itself.**
  Cuts 3 and 4 removed the paths that made it load-bearing.

The two rows the ranking still reports are the same kind: what sits behind
`parser/root.zig` to `parser/codegen.zig` is `handler_analyzer.zig`, and behind
`modules/net/service.zig` to `system_config.zig` is `system_config.zig` and
`json_wire.zig`. All are engine or base tier. **There is no engine-to-compiler
back edge left.**

The remaining components are each inside a single proposed tier, with one
exception to resolve in step 2: the 48-file component is the engine, and it
contains `contract_types.zig`, `handler_policy.zig`, `policy.zig` and
`file_io.zig`. Those four are the unplaced files listed above, and three of them
are now measured rather than guessed:

- `contract_types.zig` imports `module_binding.zig` and `builtin_modules.zig`,
  so contracts-at-the-bottom needs one more cut before it is legal.
- `policy.zig` imports `handler_policy.zig` and `security_events.zig`, which is
  consistent with all three being engine-tier runtime enforcement.
- `file_io.zig` imports `modules/internal/module_graph.zig`, which is why it
  cannot go into `zts-base` as it stands.

## Step 2 results, 2026-08-07

Two commits. `bash scripts/verify.sh` passes, and `zig build test` now depends
on `test-zts-layering`.

The assignment, from `scripts/zts-tiers.allow`:

| Tier | Files |
|---|---|
| `zts-base` | 9 |
| `zts-contracts` | 8 |
| `zts` | 90 |
| `zts-compiler` | 50 |

767 edges, 231 of them crossing a tier line, none pointing upward.

The first run of the gate reported 26 upward imports. Every one came from the
contracts tier or below; **the engine reported none**, which is what step 1 was
for. They resolved in two ways.

Four files were simply in the wrong tier. `module_facts.zig`, `proof_trace.zig`,
`api_schema.zig` and `contract_diff.zig` all read like contract data by name,
but they import the parser, the flow checker, the type environment and the
behavior canonicalizer: they are compiler-tier and are now filed there.
`module_manifest.zig` moved the other way, into `zts` - it parses extension
manifests describing module bindings, which is about modules rather than about a
handler's contract, and it belongs beside `builtin_modules.zig`.
`route_match.zig` moved down to `zts-base`, `node_types.zig` up to `zts`.

Six were real, and all six were the contracts tier reaching for vocabulary
rather than machinery. Three moves fixed them:

- `unescapeJson` moved from `trace.zig` to `json_utils.zig`. A contract parser
  decoding a recorded body had to import the trace recorder, and the engine
  behind it, for one string unescaper.
- `capability_count` and `capabilityHash` moved from
  `module_binding/capabilities.zig` to `module_authorization.zig`, beside the
  `ModuleCapability` enum they derive from. That file imports nothing, so a
  contract can name the whole capability vocabulary without the module bridge.
- `computeCapabilityMatrix` moved from `contract_types.zig` to
  `builtin_modules.zig`. It resolves each specifier through the linked module
  registry, so it belongs with the registry; the `CapabilityMatrix` type needs
  only the enum and stayed. `handler_contract.zig` stopped re-exporting it, and
  the curated surface gained `zts.computeCapabilityMatrix` so the two runtime
  callers did not need a wider internal allowlist.

Each original file re-exports what it used to define, so no consumer package
changed except those two runtime call sites.

### Three unplaced files, now decided

- **`file_io.zig` is `zts`, not `zts-base`.** It imports
  `modules/internal/module_graph.zig`, so it cannot sit at the bottom as it
  stands. Decision 2 said generic utilities go into `zts-base` to keep
  `zts-compiler` from linking the engine to read a file; that still holds for
  `compat.zig` and `json_utils.zig`, and `file_io.zig` needs its own cut before
  it can join them. Not attempted here: it does not block the split, only the
  size of what `zts-compiler` links.
- **`policy.zig`, `handler_policy.zig` and `security_events.zig` are `zts`.**
  They are runtime enforcement, they import each other, and nothing above them
  needs them lower.
- **`trace.zig` is `zts`**, as expected: it is the engine-side recorder.

## Steps 3 and 4 results, 2026-08-07

Three commits, one per extraction. `bash scripts/verify.sh` passes.

| | Start of the work | Now |
|---|---|---|
| Files under `packages/zts/src` | 154 | 161 |
| Relative import edges | 760 | 595 |
| Edges crossing a tier line | 231 (measured at step 2) | **0** |
| Largest strongly connected component | 101 | within one tier |
| Build modules | 1 | 5 |

The final shape, which differs from what this document originally planned:

    zts-base <- zts-contracts <- zts-engine <- zts-compiler
                                                      ^
                              zts (umbrella, holds no code)

**Why the umbrella.** `zts-compiler` sits above the engine, so `src/root.zig`
could not re-export it the way it re-exports the tiers below - that direction is
the cycle. The plan as written had consumers import `zts` and `zts-compiler`
separately, which measured at 136 call sites across 33 files in three packages,
four consumer `build.zig` files, and about forty curated names moving to a new
module. Making `root.zig` a re-export-only umbrella instead leaves every
consumer's `@import("zts")` resolving exactly the names it always did.
`zq.Context` comes from `zts-engine` and `zq.FlowChecker` from `zts-compiler`;
both are the same module instance everywhere, so the types are interchangeable.
`scripts/module-boundary.allow` is unchanged - 77 internal modules, 55 allowed
package reaches, the same numbers as before the split.

**What each extraction needed.**

- `zts-base` (10 files) was already clean: no edges among its members, none
  outbound, 60 inbound from 43 files.
- `zts-contracts` (9 files) had seven internal edges and, after step 2, nothing
  outbound above `zts-base`. 27 inbound from 20 files.
- `zts-engine` (92) and `zts-compiler` (49) went together, 125 relative imports
  across 33 files. `parser/root.zig` gained `pub const ir` so a compiler-tier
  file can walk the IR without compiling a second copy of `ir.zig`; `parse.zig`
  needed no such re-export, because `JsParser` was the only thing anyone wanted
  from it.

**The duplicate-file failure is real, and it fires twice.** Pointing
`trace.zig` back at `"json_utils.zig"` makes the gate report
`zts -> zts-base (1 edges): trace.zig -> json_utils.zig`, and makes zig fail
with `error: file exists in modules 'zts-base' and 'root'`. That is the
two-incompatible-types outcome this plan was written to prevent, reachable in
one edit and caught at both ends.

**Test collection was the real hazard**, exactly as the Risks section said. `zig
test` collects only from the files its root module analyzes, so one root over
`src/root.zig` would compile and pass while running none of the tier tests.
There are five roots now, one per module, and each imports only the tiers below
it. Importing its own tier makes zig report the duplicate-file error; importing
one above drags in a second `sqlite3.c` and turns every `sqlite3_*` symbol into
a duplicate definition. Both happened during this change. Coverage was then
verified rather than assumed: a deliberately failing test appended to
`compat.zig`, `contract_types.zig`, `interpreter.zig` and `flow_checker.zig`
each made `zig build test-zts` exit nonzero, one per tier, against a control
that passes.

**`scripts/check-module-boundary.sh` needed its parser updated.** `root.zig`
spells the internal tier `= engine.value` now, not `= @import("value.zig")`.
Its own input floor caught this, reporting `only 0 internal modules parsed`
rather than silently checking nothing - the gate-with-no-input shape, working as
designed.

## Success criteria, and how they came out

1. **`bash scripts/verify.sh` passes at every step, not only at the end.** Met.
   It was run and passed after each of the eleven commits.
2. **The acyclicity check passes and is wired into `zig build test`.** Met.
   `scripts/check-zts-layering.sh`, as the `test-zts-layering` step. It now
   reports zero cross-tier relative imports rather than only zero upward ones.
3. **`zig build -Doptimize=ReleaseFast` and `zig build wasm` both succeed.**
   Half met, and honestly so. ReleaseFast passes. `zig build wasm` fails on
   `std/posix.zig:108:21: error: struct 'posix.system__struct_*' has no member
   named 'O'`, and that failure reproduces unchanged at the commit before this
   work started. It is a pre-existing break in the freestanding analyzer target,
   not a consequence of the split, and it is not addressed here.
4. **No type identity regression.** Met. `packages/tools` names both `parser`
   (engine) and `handler_contract` (contracts) and compiles without a cast, as
   do `runtime` and `pi`. The umbrella is what makes this hold for free: every
   consumer reaches one module instance per tier.
5. **`zig build bench` runs and its numbers are unchanged within noise.** Met.
   Total 62.2ms across thirteen benchmarks, with inline-cache hit rates
   unchanged (propertyAccess 100.0%, jsonOps 75.0%, httpHandler 100.0%). The
   split moved the build graph, not the interpreter.
6. **`check-module-boundary.sh` reports a smaller allowed-reach count.** Not
   met, and it should not have been the criterion. The count is unchanged at 77
   internal modules and 55 allowed reaches, because the umbrella deliberately
   preserves the consumer surface. Shrinking that surface is a separate piece of
   work with its own trade-offs; conflating it with the split would have meant
   rewriting 136 consumer call sites for reasons unrelated to the cycle. Step 5
   below is what remains of it.

## Step 5 results, 2026-08-07

One commit. `bash scripts/verify.sh` passes. `scripts/module-boundary.allow`
goes from 55 allowed package reaches to 54.

**The step was written on a premise the umbrella invalidated.** It assumed rows
would delete because consumers would import `zts-compiler` and `zts-contracts`
directly, making those reaches ordinary named imports. With `zts` as a
re-export-only umbrella, consumers still reach one module, so the allowlist
still gates every internal name that leaves the package. The compiler enforces
direction *inside* `packages/zts`; this file gates what comes *out*. The two
checks are complementary, not redundant, and the allowlist header now says so.

**What did close.** `HandlerProperties` - what a build proved about a handler -
is a field of `HandlerContract`, which was already curated, and sixteen call
sites across the runtime, the tools and the expert agent reached
`zts.handler_contract` for it because it had no curated name. It has one now.
The same pass switched every `zts.handler_contract.writeJsonString` to the
curated `zts.writeJsonString`, which existed all along. `pi` reached
`handler_contract` for exactly those two names, so its row is gone.

**What did not, and why not.** A row closes when every symbol behind it has a
curated name. Measured after the split, most rows reach seven to eighteen
symbols. Of the rows reaching three or fewer, most reach things that should stay
internal: `interpreter.PerfStats` (a benchmark-only counter layout),
`string.RopeNode`, `bytecode_cache.SliceWriter`, `sqlite.Db`, `arena.Arena`.
Curating those to delete a row would trade a gated internal surface for an
ungated public one, which is a worse position than the one being fixed. The
policy is now written into the allowlist header: close a row when the name
belongs in the curated surface on its own merits, not to make the list shorter.

**A measurement trap worth recording.** A first pass that matched only
`zq.<module>.<symbol>` reported `runtime module_binding` at 3 symbols and
`tools contract_diff` at 1, which made both look like easy closures. Counting
local `const X = zq.<module>;` aliases as well puts them at 8 and 10. Acting on
the first numbers would have curated the wrong things. Any future pass over this
list must be alias-aware.

## What the split bought

Three things were claimed. Two are delivered, one is set up but not taken.

- **A compiler-enforced direction. Delivered.** Before this,
  `scripts/module-boundary.allow` was the only thing stopping the engine from
  importing the flow checker, and it gated consumer packages, not `zts` itself.
  Inside the package there was no boundary at all - that is what the 101-file
  strongly connected component was. Now the direction is a property of the build
  graph: an engine file that names a compiler file does not fail review, it
  fails to compile.
- **Test suites that match the code. Delivered.** One `addTest` root over 154
  files meant a change to the flow checker recompiled the interpreter's tests.
  Five roots do not.
- **A smaller analyzer build. Set up, not taken.** `-Danalyzer_only` still
  strips the VM, SQLite and libc with `comptime` gates in
  `module_binding.zig`, `bridge.zig` and `capabilities.zig`. Those gates can now
  go, because the analyzer can link `zts-compiler` and never name the engine -
  but the wasm target does not build today for an unrelated `std.posix` reason
  (criterion 3), so nothing was changed there and no size claim is made.

## Risks, as they turned out

- **`refAllDecls` coverage. Materialized, and was the main hazard.** `zig test`
  collects only from the files its root module analyzes, so one root over
  `src/root.zig` would have compiled and passed while running none of the tier
  tests. Five roots now exist, one per module, each importing only the tiers
  below it. Coverage was verified per tier with deliberately failing tests
  rather than assumed.
- **`build_options`. Materialized, benignly.** Options are per-module, so all
  five modules get their own `addOptions` copy. `analyzer_only` still means one
  thing for the whole package; nothing about its meaning changed, and deciding
  what it should mean per tier is deferred with the analyzer-size work above.
- **The seven cuts change behavior if done carelessly. Did not materialize.**
  The one behavior-bearing cut, `parser/codegen.zig:2907` constructing a
  `HandlerAnalyzer` during code generation, turned out not to be a cut at all:
  `handler_analyzer.zig` imports only the bytecode, the IR, objects and the
  context, and produces a dispatch table the interpreter reads at run time. It
  is engine-tier, so codegen naming it is a same-tier edge and nothing moved.
- **Two risks the plan did not name, both found by building.** Compiling
  `sqlite3.c` into more than one module in a binary makes the linker report
  every `sqlite3_*` symbol as a duplicate definition. And a test root that
  imports its own tier makes zig report `file exists in modules 'root' and
  'zts-engine'`. Both are the duplicate-file failure this plan is about, seen
  from angles the plan did not anticipate.

## Decisions taken 2026-08-07

1. **`zts-contracts` sits at the bottom.** Both `zts` and `zts-compiler` may
   import it; it imports neither. The contract types are plain data and
   `handler_policy.zig` already names them, so this needs no duplication. The
   cost accepted is that the engine module still knows contract shapes.
2. **Generic utilities go into a fourth `zts-base` module,** not into `zts`.
   `file_io.zig`, `json_utils.zig`, and `compat.zig` are named by all tiers.
   Filing them under `zts` would make `zts-compiler` link the interpreter, the
   GC, and SQLite in order to read a file, which cancels most of the
   `-Danalyzer_only` payoff listed above. The cost accepted is four modules,
   four `build_options` blocks, and four test roots rather than three.
3. **Module names use a hyphen:** `zts-base`, `zts-contracts`, `zts`,
   `zts-compiler`. This matches `zttp-sdk` and `zttp-modules`, the other
   `addModule` names in the tree. The underscore form is live too (`zts_cli`,
   `zts_expert_skill`) but those are `packages/tools` modules, not `zts` peers.
4. **Execution stops after step 1.** Steps 0 and 1 land now; the tree is
   re-measured and the remaining steps re-decided before any build wiring is
   touched. The seven cuts are worth having on their own merits even if the
   split never lands.

The layering is therefore, bottom to top:

    zts-base  <-  zts-contracts  <-  zts  <-  zts-compiler

with `zts-compiler` free to name `zts-contracts` and `zts-base` directly.
