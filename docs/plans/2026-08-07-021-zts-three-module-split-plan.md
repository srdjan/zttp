# Splitting `zts` into `zts` / `zts-compiler` / `zts-contracts`

Status: plan, not started.
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
`trace.zig` to `root.zig` is first and free.

**Step 2 - assign every file to a tier and prove the assignment is acyclic.**
Extend the step 0 script to read a tier manifest and fail on any edge from a
lower tier to a higher one. This is the gate that says the split will compile,
before any build wiring is touched. Resolve the unplaced files here.

**Step 3 - rewire cross-tier relative imports to named imports.** Mechanical,
and the compiler catches every miss. Under the assignment above this touches on
the order of 57 files; the exact number falls out of step 2.

**Step 4 - split `packages/zts/build.zig` into three `addModule` calls,**
lowest tier first, and wire `zts-compiler` and `zts-contracts` into the root
`build.zig` next to the existing `zts` module. Three test roots replace one, so
`zig build test-zts` becomes three steps, or one step depending on three.

**Step 5 - retire the allowlist to the extent the compiler now enforces it.**
Rows in `scripts/module-boundary.allow` that name a module now in
`zts-compiler` or `zts-contracts` become ordinary named imports and their rows
are deleted. Rows still naming a `zts` internal keep the gate. The gate itself
stays: the split enforces the tier direction, not the size of any one tier's
public surface.

## Success criteria

1. `bash scripts/verify.sh` passes at every step, not only at the end.
2. The step 2 acyclicity check passes and is wired into `zig build test`.
3. `zig build -Doptimize=ReleaseFast` and `zig build wasm` both succeed.
4. No type identity regression: a value produced by `zts` and consumed through
   `zts-compiler` compiles without a cast. The concrete probe is
   `packages/tools`, which today names both `parser` and `handler_contract`.
5. `zig build bench` runs and its numbers are unchanged within noise. The split
   is a build-graph change and must not move the interpreter's performance.
6. `scripts/check-module-boundary.sh` reports a smaller allowed-reach count than
   it does today, and no row it still lists is stale.

## What the split buys

Three things, stated so they can be checked afterward rather than assumed:

- **A compiler-enforced direction.** Today `scripts/module-boundary.allow` is
  the only thing stopping the engine from importing the flow checker, and it
  gates consumer packages, not `zts` itself. Inside the package there is no
  boundary at all - that is what the 101-file cycle is.
- **A smaller analyzer build.** `-Danalyzer_only` already exists to strip the
  VM, SQLite, and libc for the wasm target, and it does so with `comptime`
  gates scattered across `module_binding.zig`, `bridge.zig`, `capabilities.zig`,
  and `root.zig:74`. With `zts-compiler` not importing `zts`, most of those
  gates become unnecessary: the analyzer links the compiler module and never
  names the engine.
- **Test suites that match the code.** One `addTest` root over 154 files means
  a change to the flow checker recompiles the interpreter's tests. Three roots
  do not.

## Risks

- **`refAllDecls` coverage.** `root.zig:660` collects tests by
  `std.testing.refAllDecls(@This())`, and three of the anchors below it exist
  because that recursion misses files nothing analyzes. Three roots means three
  such anchor audits, and a file that lands in no root runs no tests while the
  suite still reports a pass. This is the gate-with-no-input shape that
  `docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md`
  documents. Assert a per-root file floor.
- **`build_options`.** Each module needs its own `addOptions`, and
  `analyzer_only` currently means one thing for the whole package. Splitting it
  three ways without deciding what it means per tier will silently change which
  code is compiled out.
- **The seven cuts change behavior if done carelessly.** Six of them are alias
  or single-call reaches, but `parser/codegen.zig:2907` constructs a
  `HandlerAnalyzer` during code generation. Moving that out of codegen changes
  when analysis runs. Reproduce the current behavior with a test before cutting.

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
