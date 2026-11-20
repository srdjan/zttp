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
Baseline capture, the declaration study, and intrinsic metadata are complete.
The metadata commit is `eeb3716d`. Type aliases, nominal construction, and graph integration pass their owning behavior checks.
The aggregate remains held on empirical replay until the approved owner recording.

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
Both workers started implementation after the metadata commit.
The consumer worker completed its twelve-turn unit and six-turn refinement; the main agent reviewed those diffs.
The internal transparent unary operation retains the original argument as its child.
It adds no bytecode operation or runtime function. This preserves nested call type arguments without cloning typed owners.
One shared `IrView.unwrapTransparent` method bounds traversal by the actual node count.
Focused consumer checks pass where the concurrent type changes compile. These checks do not establish the unfiltered suite.

The caller worker owns remaining path fields outside the type, graph, and runtime integration files.
Its two bounded cohorts use eight turns each. Production inputs use their resolved paths; test inputs use explicit synthetic paths.

The public runtime baseline reports ZTS065 for an imported `Message` type.
Its source and expected response live under ignored `demos/typescript-u3-runtime/`.
The main agent added two public runtime tests with real files and exact responses.
Those tests require type-only modules and their transitive runtime dependencies to remain unexecuted.

Runtime graph routing now precedes single-module type checks. Runtime execution uses the mapped runtime order.
The shared compiler callback validates intrinsics before code generation and publishes imported types through the existing signature table.
The transport worker completed publication of aliases, recursive generics, brands, and callable signatures.
Seven focused graph frontend tests pass, including accepted and refused imported constructor operands.
An independent review found no new transport or reachability defect. Its real-files probe excludes analysis-only environment imports from runtime claims.
Normal typed runtime files must retain full type checking. Prepared evaluation must retain its existing omission of unrelated authored type checks.
The shared direct-analysis boundary now lowers intrinsics before facts and proof consumers run.
Graph validation retains live diagnostics before session teardown. Public missing-export and constructor-base cases retain ZTS207 and ZTS203 with their locations.
No U3 completion or passing aggregate verdict is claimed.

The admission worker completed its twenty-turn unit. Brand queries and ordinary-query refusals pass focused checks.
Both generation boundaries refuse unvalidated intrinsic sources. The unused ZTS050 type-alias refusal is retired.
The profile worker completed its twelve-turn unit. Grammar drift passes with seventy-one productions.
The restriction gate observes 220 rows and 793 probes, with no failures after its clean file-import probe supplies a real dependency.

The boundary worker has a twenty-turn budget for direct semantic ordering and typed diagnostic projection.
The runtime-import worker has a twelve-turn budget for code generation, effects, and flow initialization of compiler-only imports.
The main agent reproduced and corrected two missing-export regressions caused by an obsolete argument order.
The main agent also reproduced compiler-only imports in runtime contract collections, then excluded them while preserving import identity.
Those focused regressions pass. The effect-tool test now reports the exact expected pure row after shared lowering.
The consumer repair removes the false flow gap and retains source-level unused-import checks.
The public clean nominal handler now has no diagnostics or runtime module claim.
The runtime-import worker completed its twelve-turn unit and eight-turn extension.

An interrupted unfiltered ZTS run reported seven failures before these integration repairs.
Two failures concern the corrected export lookup. One allocation expectation now passes after unnecessary path interning was removed.
The noted grammar rows now pass their four-row census. The recursive-generic transport failure also passes its focused check.
Five receipt snapshots changed with the grammar identity. Restoring that one field reproduces every original expected hash.
The reviewed snapshots now carry the measured grammar identity. No empirical recording changed.
The first unfiltered owning run passed 3668 tests, skipped one, and failed two repository gates.
The failed gates identified the missing dependency fixture and an allocation allowlist row. Both have corrections.
The next integration run passes the restriction census and exposes the expected stale empirical replay.
Its expert diagnostic census also needs the retired ZTS050 expectation removed; the alias fixture now belongs among positive cases.

The public review confirms preserved nominal labels and source-exact declassification behavior.
The review also confirms one grammar admission gap and expected failures reported as internal errors.
A brand query outside `Nominal` is accepted. Valid query trivia and scalar aliases fail nominal declaration resolution.
Invalid constructor targets and escaped intrinsic references report ZTS000 instead of author diagnostics.
The brand-closure worker owns an eighteen-turn correction unit across type names, type resolution, syntax parsing, and public regressions.
The public-review worker owns a twelve-turn correction unit for diagnostic projection and public label regressions.
The main agent owns the remaining source review, corpus expectation changes, unfiltered gates, and the U3 commit.
The server restart interrupted the integration run before its final status was captured. That run establishes no final suite verdict.
The restored workers retain the same file ownership and budgets. The owner supplied replacement repository instructions without changing the approved migration scope.
The main agent independently reproduced the brand-query admission gap and both internal-error projections through the current CLI.
The next surface run reports all 202 corpus cases accepted by the gate and the metadata pins matched. Its remaining steps are pending.
An additional public check accepts mutually recursive aliases through a type-only import.
The normalization-admission study has a ten-turn read-only budget. It must determine whether retained admission refusals support the approved repair path.
The study concludes that retained refusal spans and normalization-only records can support U6 without another parser entry.
Executable capabilities must remain unavailable for refused sources. Declaration repairs must precede ordinary graph analysis for implicit construction repairs.

The brand worker reproduced and corrected five focused cases: query scope, query trivia, local scalar aliases, imported scalar aliases, and nested nominal bases.
The diagnostic worker corrected invalid constructor targets to ZTS209 and escaped intrinsic references to ZTS001.
Public regressions retain secret refusal and bounded masking after nominal construction.
The main agent reproduced the ZTS209 correction through the rebuilt CLI and removed a new test that asserted private flow state.

The unfiltered surface run failed: 1458 of 1546 tests passed, with 24 failures and 64 crashes across two test roots.
The crash comes from reading a member callee with the non-validating identifier accessor.
A new public graph test reproduces the panic before an identifier-tag guard. The focused test passes with the guard.
Ordinary graph type failures also changed native error categories because the new callback ran an earlier duplicate refusal.
Compilation now leaves ordinary refusals to its existing graph check. Its focused graph suite passes and retains the earlier error priority.
The type-only admission table now supplies real dependency files instead of relying on erased imports.
The remaining malformed-declaration projection has a twelve-turn worker budget. The main agent owns the final unfiltered rerun.
The malformed-declaration unit is complete. A typed failure retains its source span through storage cleanup and graph validation.
The public projection uses ZTS048, ZTS210, and ZTS001. Bare `Nominal` and inline misuse fail closed.

The artifact review traces nominal type keys outside certificate and runtime cache authority. Artifact relocation does not compare those keys.
Type keys retain the approved normalized module-path scope. They do not claim identity across different checkout paths.
The review found an encoding change still advertised as version 1. The main agent reproduced that metadata failure before changing the version to 2.
The specification now states the scope of those type digests. No portable-module identity feature is added.
The final owning run is active. Its proof-swallow gate requires three rows for typed refusal projection; each row preserves refusal or propagates the error.
That run finishes with 6948 passing tests, two skipped tests, and five failures across 6955 tests.
The five failures are repeated census assertions: the checker count and the deliberate ZTS001 sharing record.
The proof-swallow gate passes after the reviewed rows and exhaustive refusal reasons are added.
The checker census passes its focused run after the count changes to 67.
The JSON census filters select no tests in `test-precompile` or `test-agent-protocol`; neither run establishes a verdict.
The unfiltered aggregate reaches that imported census and must establish its result.
The aggregate and standalone runtime steps are now running against the census corrections.
The first aggregate scan sees removed corpus paths in the unstaged index and refuses the documentation census.
The main agent stages the completed fixture move. The unfiltered documentation drift step then passes.
That aggregate reports 9094 passing tests, six skipped tests, and one failed test across 9101 tests.
The failed test is the held empirical replay. The documentation scan also fails before its index correction.
No checker or JSON census failure remains in that unfiltered run.

A later allocation probe confirms three retained allocations from an unexecuted type-only function.
The public runtime test returns the correct response but fails allocator cleanup before the fix.
The runtime now frees constant payloads only for analysis-only modules. The focused allocation regression then passes.
The final aggregate rerun includes the runtime cleanup, corrected index, and standalone runtime suite.

U4 (lower imported invariant assertions) has a four-turn read-only preparation unit while these gates finish.
The assertion worker must not edit until the main agent commits U3 (admit aliases and explicit nominal construction).

The direct-source contract and two certificate goldens change only because the approved grammar hash changes.
Restoring only the old grammar field reproduces all three original hashes. The production tests retain the new exact hashes.
The field-isolation result is `/tmp/zttp-syntax-u3-certificate-field-proof.log`.

A public type-only import test reproduces lost boolean validation: `if (1)` loads before the fix.
Runtime graph validation now runs the existing boolean checker before compilation. The regression then refuses with `SoundModeViolation`.
The runtime suppresses expected compilation logs only in tests, consistent with its existing logging rules.

Two public CLI cases reproduce missing text details for direct and imported malformed nominal declarations.
JSON already carries the diagnostic. Both text paths now print ZTS048, the exact location, and the existing message.
Unfiltered `zig build test-cli-abuse` passes all 37 cases after both cases fail before the fix.

The latest aggregate reports 8354 passing tests, six skipped tests, and one failed test across 8361 tests.
Its only failed test is the held empirical replay. It includes the standalone runtime and expert golden suites.
The final frozen-tree rerun includes the text diagnostic repair and the spine check.
It reports 6080 passing tests, four skipped tests, and one failed test across 6085 tests.
Its only failure is the held empirical replay. The command exits one, so the aggregate gate is not green.
The exact command is `env -u DEEPSEEK_API_KEY -u ZTTP_CODEGEN_RECORD zig build test test-zruntime test-expert-golden check-spine`.
The final log is `/tmp/zttp-syntax-u3-final-frozen.log`. Formatting and staged diff checks pass.

U5 (lower complete fluent match chains) has a six-turn read-only preparation unit. No source changes are authorized before U4 finishes.
Its preparation identifies `parser/codegen.zig` as an additional owner for singular subject evaluation.
The proposed immediate callback representation must also preserve fault paths and analysis traversal before it is accepted.
U6 (complete normalization and source cutover) has a separate six-turn preparation unit for repair APIs and validators.
That unit uses the completed admission study instead of repeating it.

## Normalization admission study

`parseProgram` currently refuses admission before final binding and root creation. `acceptedCapabilities` exposes no refused source.
`AdmissionDiagnostic.span` retains the repair range, but `fromAdmissionError` currently discards that range during JSON projection.
The implementation must retain parser-owned legacy repair records without exposing execution or code generation for refused sources.
Each migration intent needs its own implemented validator. Existing intents describe other laws and cannot stand in for migration evidence.

Declaration repairs must precede accepted graph analysis. The type checker can then identify unbranded initializers of explicit nominal annotations.
A correctly branded initializer must produce no constructor repair. Dependencies must normalize before their importers.
The normalizer must reuse resolved core import aliases. If a required name conflicts, the normalizer must retain the source and report the conflict.
These steps need no new parser entry under D-016. An unadmitted parser entry or executable legacy capability would require a superseding owner decision.

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

The assertion worker will execute U4 (lower imported invariant assertions) after the U3 local commit.
The main agent owns review, unfiltered verification, and the next local commit.
