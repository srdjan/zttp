# TypeScript syntax migration worklog

The plan authority is [the syntax design](2026-11-15-typescript-syntax-design.md).
This file records execution evidence and open work. It does not change the design.

## Objective and authority

The owner selected Decision 2, option A, on 2026-11-19.
The selection authorizes the four syntax migrations, specification changes, and one new batched model recording window.
The owner runs the model recording. The main agent publishes the resulting evidence afterward.
Work stays on local `main`. No push or deployment is authorized.
Compiler metadata owns intrinsic authority. The migration preserves the interpreter and proof semantics.

## Baseline

Starting commit: `0435bfde`, with compiler source at `8b154522` (`v0.27.1`).
The working tree was clean before execution.
The refreshed plan passed six static reviews, `zig build check-spine`, and unfiltered `zig build test`.
Those checks establish the starting repository, not support for the proposed syntax.
Native execution uses Sol workers at high effort. No external implementation engine or Compound Pack is configured.

## Current work

The declaration study uses ignored files under `demos/typescript-syntax-study/`.
The baseline inventory is complete. Its census includes packages, examples, corpus files, shell fixtures, documentation, and embedded skills.
The main agent owns verification, this log, and local commits.
The workers used twelve-turn budgets. The declaration worker received bounded extensions of twelve, eight, and eight turns for reproduced omissions.
The independent review is complete. The main agent reproduced its recursive-union failure and checked the correction.
Baseline capture and the declaration feasibility gate are complete. Intrinsic metadata and external declarations are ready for a local commit.

## Intrinsic metadata work

The worker reached its eighteen-turn budget after SDK tests passed. The main agent took repair and verification ownership.
The attempted red command used runtime filter arguments and produced no assertion verdict before it stopped.
The documented build option reproduced the public generator failure. That filtered run is development evidence only.

The main agent corrected the single registry, governance row, tier manifest, and generated core module artifact.
The main agent also reproduced an ambient TypeScript privacy failure before fixing it with an explicit export list.
The generated declarations now keep helper types private and reuse the existing opaque `Bytes` and `Dict` identities.
Four positive files and seventeen negative files pass against actual generated declarations with `--lib es2022`.
A public integration case passes values from bytes and collections functions through the pattern descriptors.
The generated checks live under `/tmp/zttp-syntax-u2-generated/`.

The catalog, metadata, module specification, and generated table now distinguish types, intrinsics, and runtime functions.
The original twenty-one runtime entries retain identical specifiers, exports, and signatures.
The reviewed public goldens and registry pin reflect this deliberate contract change. No empirical recording or cassette pin changed.

The main agent reproduced missing intrinsic fields in registry and artifact identities before correcting the hash inputs.
An independent review found that type-only exports and helper-only declarations also escaped the hash guards.
Exact literal hash regressions reproduce both omissions and pass after the repairs. Independent reference preimages supplied the expected hashes.
The review found no other confirmed defect. The main agent reviewed every changed source line.

The unfiltered owning run passed 7524 tests, skipped two, and failed only the stale empirical replay.
The subsequent aggregate passed 9783 tests, skipped six, and failed one test: the same stale replay.
Two shell failures also reported the missing capability inventory entry for `zttp:core`.
The main agent added that entry. Unfiltered documentation, capability, rejection-probe, and spine checks pass after the correction.
The final unfiltered aggregate rerun exits one, with only the stale empirical replay failed.
It reports 218 of 221 steps succeeded, 1186 tests passed, one skipped, and one failed; successful earlier results are cached.
These results do not establish a passing aggregate gate.
Empirical replay remains held for the approved owner recording after the final syntax and authoring updates.

Three SDK compilation probes accept core-only metadata and reject foreign or mixed runtime/intrinsic declarations.
Removing each guard from a copied SDK makes its corresponding negative probe compile. The production SDK remains unchanged by those mutations.
The exact outcomes are recorded under `/tmp/zttp-syntax-u2-sdk-results.json` and `/tmp/zttp-syntax-u2-sdk-mutants/`.

The type-path trace found that type-only file imports are erased before module-graph discovery.
The next type unit must extend the existing graph with checking edges, without running those modules or their runtime imports.
It must retain normal admission, cycle refusal, and graph identity for those dependencies.
The source trace is `/tmp/zttp-syntax-u3-type-paths.md`.

## Type unit integration

The type worker owns parser syntax, nominal representation, type checking, signature transport, and the shared lowering boundary.
Its implementation budget is twenty-four turns after the read-only integration phase.
The graph worker owns dependency discovery, analysis order, runtime order, compile mappings, and source hashes.
Its implementation budget is twenty turns after the read-only integration phase.
The main agent owns runtime and remaining caller integration, review, unfiltered checks, and local commits.

`DirectSyntaxInput.module_path` will require the normalized source path without a default.
`ModuleSourceTypeInput.direct` will carry that path into declaration population.
Nominal origins will contain the module path and declaration offset. Each destination pool will own its copied origin.
The graph will retain runtime edges and add type-only edges. Analysis order will cover both; execution order will cover runtime reachability.
`CompileResult.positionOfModule` will map a graph index to its compiled position.
The parser will retain accepted type-only specifiers and named bindings, with one shared decoding path.
These changes extend existing checking paths. They do not add a second module graph or execution path.
Both workers remain read-only until the metadata unit is committed.
An independent consumer worker will handle the internal transparent unary operation, within a twelve-turn implementation budget.
The operation will retain the original argument as its child. It adds no bytecode operation or runtime function.
This preserves nested call type arguments and avoids cloning typed owners.

## Baseline evidence

The authorization commit is `d78d2775`. The compiler source remains `8b154522`; the earlier plan refresh is `0435bfde`.
These revisions name different layers of the baseline, not different compiler behavior.
`zig build` exited zero, and the rebuilt CLI reports `zts 0.27.1`.

One public `zts check` probe combines all four legacy forms. It exits zero with no diagnostic and seven true properties.
The public `zttp serve --test` flow returns status 200 and the exact body `u1`: one test passes, with none unchecked.
The probe files and JSON output are under `/tmp/zttp-syntax-u1-baseline/`.

The frozen corpus has thirteen active cases. Eleven contain final handler snapshots; all eleven pass source checking with required inputs.
The SQL case passes with its recorded schema. Two cases contain no final handler and are not source-profile refusals.
The census does not replace convergence evidence or claim that every recorded task succeeded.
The raw results are under `/tmp/zttp-syntax-u1-corpus/`.

The cross-module probe confirms a current identity collision through exported function signatures.
Separate nominal declarations named `Id` interchange without a diagnostic. Different nominal names report ZTS203 at the argument.
The control using one declaration passes. Direct file imports of nominal type aliases currently report ZTS065.
The approved identity work must preserve declaration identity through both alias imports and exported signatures.
These literal fixtures are under ignored `demos/typescript-current-baseline/`.

A captured secret in a match arm reports ZTS400 and an undischarged `no_secret_leakage` claim.
A selected arm that reads the clock leaves `deterministic` false and reports ZTS500.
The pure contrast passes with `deterministic` true. Existing runtime, effect, fault, and flow suites remain baseline evidence.

## Declaration evidence

The first study missed finite record splits, optional-field partitions, and general arrays. The main agent reproduced each TypeScript failure.
Further public probes confirmed unknown subjects and bindings for missing fields. Their initial target forms also failed TypeScript.
The corrected projection covers those cases without a runtime helper or interface change.
An independent review also found TS2589 for an admitted recursive union. Pattern-driven checking removes that eager type expansion.
The main agent ran four positive files and seventeen negative files with TypeScript 7.0.2.
All positive files exit zero without diagnostics. Each negative file exits one with its expected diagnostic code.
Three additional fixtures for nested records, renamed bindings, and nested tuples also pass against the corrected declarations.
The exact commands and diagnostics are in ignored `demos/typescript-syntax-study/STUDY.md`.
The authoritative result matrix is `/tmp/zttp-syntax-u1-typescript-final.json`.
The declaration SHA-256 is `e7cdde40b9f81d7c82fd444d00fca0f2e889fd19bb63a01708d0d1329e1f5f0d`.

The projection keeps broad string and general array complements open.
ZTS retains duplicate-arm and unreachable-arm checks, including cases that the external declarations cannot decide.
No compiler, prompt, cassette, policy pin, or published evidence changed during the baseline study.

## Completion boundary

The declaration contract must pass before frontend implementation starts.
Every behavior change needs public evidence and the required unfiltered gates.
A required raw parser entry needs a superseding owner decision under D-016 before cutover.
Owner recording remains an external prerequisite. The migration cannot finish without the recording and evidence publication.

## Next action

The main agent will commit the metadata unit, then start type aliases, nominal construction, and graph integration.
