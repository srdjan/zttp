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

Baseline capture, the declaration study, and intrinsic metadata are complete.
The metadata commit is `eeb3716d`. U3 (admit aliases and explicit nominal construction) is committed as `33c69fc8`.
Its owning behavior checks pass. The aggregate remains held on empirical replay until the approved owner recording.

U4 (lower imported invariant assertions) is committed as `079e845e` after its owning checks pass.
The main agent owns the specification, verification, this log, and local commits.
U5 (lower complete fluent match chains) passes its owning suites after main review and integration repairs.
The aggregate remains held on empirical replay and policy drift. The main agent now owns its local commit.
U6 (complete normalization and source cutover) has a prepared validator design and an ignored fixture inventory.
Its implementation waits for the match commit because both units own parser and lowering files.

Remaining implementation follows U5, U6, and U7 (align authoring surfaces and website claims), in that order.
U8 (close evidence for the migrated profile) then requires the owner recording before the main agent publishes fresh evidence.
The baseline inventory covers packages, examples, corpus files, shell fixtures, documentation, and embedded skills.

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

A four-turn refinement selects four implemented M4 declared-law validators: declaration, implicit nominal initializer, match, and assertion migration.
Each validator rederives a deterministic replacement from retained records and checks accepted repaired source facts.
No migration uses unsupported kernel comparison as equality. The validator taxonomy gains no new method.
After declaration migration, exact ZTS200 evidence authorizes a raw nominal initializer wrap. An already-branded initializer receives no wrap.
Unresolved or legacy dependencies keep the importer unchanged. Dependencies must be normalized and persisted first through the existing single-file calls.
A caller may supply already-normalized dependency snapshots through its existing reader. The CLI cannot silently authorize writes against synthetic dependencies.

The main agent measures a record-binding snapshot through the public legacy CLI and runtime.
The valid handler mutates the matched record between two reads of the bound field. Its exact response is status 200 and body `old||old`.
Migration must create callback-local constants for old pattern bindings. Repeated member reads cannot stand in for those snapshots.
The ignored study is `demos/typescript-syntax-u6/snapshot-study/`. The legacy runtime log is `/tmp/zttp-syntax-u6-snapshot-runtime.log`.
The fresh U5 development build exits zero. Its naive member-read target returns `old||new` and fails the legacy response test.
The target with callback-local constants returns status 200 and exact body `old||old`, with exit zero.
The two logs are `/tmp/zttp-syntax-u6-snapshot-naive.log` and `/tmp/zttp-syntax-u6-snapshot-preserved.log`.
This confirms the snapshot migration law. It does not identify a defect in the new match engine.

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

The declaration study uses ignored files under `demos/typescript-syntax-study/`.
The workers used twelve-turn budgets. The declaration worker received bounded extensions of twelve, eight, and eight turns for reproduced omissions.
The independent review is complete. The main agent reproduced its recursive-union failure and checked the correction.
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

## Imported assertion unit

U3 (admit aliases and explicit nominal construction) is committed as `33c69fc8`.
The assertion worker now executes U4 (lower imported invariant assertions) with a sixteen-turn budget.
Its ownership covers parser statement handling, shared intrinsic lowering, type diagnostics, and public check and server tests.
The main agent owns the specification, integration review, unfiltered gates, and local commit.
The fluent-match and normalization workers remain read-only until their execution signals.

The imported assertion passes public narrowing, exact arity and type-argument diagnostics, label, effect, and runtime checks.
The initial narrowing regression fails before lowering. The empty-call case now reports exact ZTS202 instead of reaching an operand accessor.
A two-number foreign call returns a used number without gaining assertion semantics.
A returned secret still reports ZTS400 and leaves `no_secret_leakage` false.
Legacy and imported failed assertions both return status 500 with the same exact public body.
The reserved-name policy still refuses `import { add as assert }`; this migration does not broaden that policy.

The main agent reviews every changed source line and runs the owning suites without filters.
`env -u DEEPSEEK_API_KEY -u ZTTP_CODEGEN_RECORD zig build test-zts test-precompile test-server test-proof-swallow check-spine test` exits one.
It reports 9069 passing tests, three skipped tests, and one failed test across 9073 tests.
The only failed test is the held empirical replay. No owning behavior suite fails.
The log is `/tmp/zttp-syntax-u4-final.log`. Separate documentation drift and spine checks exit zero after the final documentation changes.
Formatting and diff checks pass. The aggregate remains held until the owner recording, and is not reported as green.

The main agent reviews the proposed fluent-match representation before execution.
Passing the discriminant node as an ordinary callback argument would repeat subject traversal.
The initial duplicate-I/O example uses a call subject, which the approved profile refuses.
No duplicate I/O has been reproduced for an admitted subject. Subjects remain identifiers and member paths.
The lowering must preserve one subject evaluation in the interpreter, flow analysis, and fault paths.
Public regressions must establish that behavior before the representation is accepted.

A four-turn refinement replaces the rejected callback-call marker with explicit `MatchArmKind` metadata.
The main agent accepts `value` and `callback` arms, with `value` as the default.
A callback arm keeps the original arrow node as its body. Only the match discriminant contains the subject expression.
The IR store uses extra storage for the new field. It does not pack metadata into a node index.
Runtime and static consumers must invoke or analyze the selected callback with the retained subject value.

After U4, the match worker will own lowering, IR, code generation, typing, narrowing, and public CHECK cases.
A separate worker will own flow, paths, boolean inference, and contract facts.
Kernel handling must preserve callback bindings and captures. Unsupported proof normalization must fail closed.
The consumer worker starts a four-turn read-only preparation unit before the U4 commit.
That worker cannot edit until the main agent sends an execution signal.
Its source trace shows that IR comparison and kernel comparison parse source strings, without intrinsic lowering.
Neither public comparison path receives callback arms. U5 therefore adds no unreachable identity branch or private IR test.
U6 must validate migration through its named repair rules. It cannot treat an unsupported kernel result as equality.
The consumer worker will increment path analysis from version 6 to 7 and flow analysis from version 10 to 11.
These callback semantics change policy identity. Empirical pins remain unchanged until U8 and the owner recording.
U4 is committed as `079e845e`. Both U5 workers now have execution signals.
The first consumer regressions select four executions and fail at production parser admission before intrinsic lowering.
Those cases cover boolean results, varying effects, and routed request and schema facts.
The focused consumer checks pass callback returns, fallthrough, nested continuations, request aliases, Result aliases, and failed callback assertions.
The main agent also runs one real CLI handler covering all six type descriptors, presence semantics, exact arrays, and selected-arm execution.
Its exact response passes. A committed server regression now carries the same literal output.

A public proof comparison confirms one remaining regression. The legacy control discharges `Proof<Response, "cost_bounded">` with exit zero.
The equivalent fluent control exits one with ZTS500. It classifies an arm callback as an escaped anonymous function with an unbounded call cost.
Generic arrow-body traversal did not establish the executed-callback classification.
The consumer worker receives a six-turn repair extension and ownership of `effect_inference.zig`.
Its new regression must preserve `cost_bounded` and retain the existing refusal for truly escaped functions.
That repair passes its public CHECK regression and escaping-function controls.
The main agent rebuilds and confirms the complete runtime case with `cost_bounded=true` and no diagnostics.

Three review probes expose missing target refinement: unknown to a descriptor type, boolean literals, and finite fields inside one record.
The legacy checker also lacks the boolean and record precision. The accepted callback contract still requires it.
An eight-turn core extension adds shared matched-type and remainder refinement, including a two-field complement test.
Its public CHECK regression passes. Inference also records temporary allocation failures instead of returning an unknown successful type.

Two further CLI regressions reproduce undeclared lowercase descriptors. Before repair, `P.dict` and `P.bytes` exit zero instead of one.
The lowerer now accepts only the declared case-sensitive names. Invalid intrinsic trees stop later type, boolean, and strict checks.
This prevents an unrelated return diagnostic from preceding the actual refusal. Both cases now report one ZTS001 at line 3, column 29.
The CLI regression runner passes all 40 cases after a separate nested-pattern repair.
That positive case fails before the repair: the legacy profile accepts 33 nested records, while the new lowerer imposes a limit of 32.
Pattern walks now use the original accepted node count as their bound. They do not add a smaller syntax limit.

The public allocation-failure sweep passes its selected execution across the pipeline test roots.
Its compiler-root selection reports three passing tests and its umbrella selection reports one passing test.
The selection log is `/tmp/zttp-syntax-u5-allocation-selection.log`. These filtered checks remain development evidence only.

Receipt component isolation restores only the previous policy hash and reproduces all prior contract and certificate bytes.
The current policy identity is `57cd1d6828d199b62d7c698e56c9427149ffc989636a7ba9834548f91dfd6f1e`.
The field proof is `/tmp/zttp-syntax-u5-policy-field-proof.log`. Current receipt goldens change; empirical recordings and pins do not.
Main review rejects the proposed second live policy pin in `check-meta-drift.sh` and restores that script exactly.
`policy-hash.txt` remains the single committed policy pin. Its drift gate stays held until the approved owner recording.
The worker's passing metadata gate used the rejected script change and is not final evidence.

The final shape review adds record refinement for unknown inputs and tuple refinement for unknown or typed arrays.
Nested patterns retain literal fields. General-array and open-record remainders remain conservative.
The review also reproduces lost nominal identity in literal callback arms.
Scalar brands now retain their original type because the pool has no branded-literal representation.
The public nominal regression fails before that repair and passes afterward.
Float literal patterns now refine an unknown callback input to `number`.
The float regression also fails before the repair and passes afterward.
The selected float run reports three passing tests, including the public CHECK case.
A readonly callback probe still reports ZTS215 for an element assignment.

A nested optional-field probe exposes an incorrect `never` remainder for a tuple.
The public CHECK regression expects ZTS203 for that callback annotation and fails before the repair.
Full record coverage now requires each tested field to be required.
The selected regression passes afterward, with three passing tests in its build selection.
The obsolete matching-type collector is removed because the refinement code replaces its only caller.

The unfiltered integration run exposes five current CLI snapshots with the previous policy hash.
Their policy fields now carry the measured identity. No empirical pin changes.
Four bytecode goldens change because type predicates duplicate the retained subject instead of evaluating the source path again.
The existing generator writes 62 identity rows, with 58 successfully digested inputs.
The main agent reviews all four changed rows.
Five new allocation-error allowlist rows name the poison flag and mandatory `ensureHealthy` check.
The proof-swallow, expert-golden, script-reachability, and spine checks pass after those integration repairs.

The ignored normalization inventory lists 107 active TypeScript files and 62 embedded Zig migration candidates.
It separates 26 immutable empirical files: nine source snapshots and seventeen transcripts.
The manifests live under `demos/typescript-syntax-u6/inventory/`.
The inventory does not authorize edits to the empirical files.

The independent match review confirms a callback validation gap for generic subjects.
The main agent separately reproduces the same gap for intersections.
An unavailable narrowed type skips callback compatibility, so a record can reach a callback annotated as `string`.
Public regressions fail before repair. The repair preserves intersection fields and intersects generic inputs with the tested shape.
Explicit callback annotations remain authoritative inside callback bodies.
The selected intersection and generic record checks each report three passing tests after repair.
The reviewer reports no other confirmed defect and does not claim an unfiltered suite result.
A follow-up public probe reproduces the generic gap for `P.number`; the final repair must cover every pattern kind.

The second unfiltered run reports 9858 passing tests, six skipped tests, and two failed tests across 9866 tests.
It completes 225 of 229 build steps. All owning behavior suites pass for that pre-repair source snapshot.
The failed tests are the frozen rule-search digest and empirical replay. The metadata drift script also fails.
The rule-search payload remains 1017 bytes. Changing only its policy field reproduces its exact prior SHA-256 digest.
The current digest is `38eb111d4ec1acab188a0e3bbf4b2974458cc5398ad1006772b867a85d540d98`.
The previous digest is `d580e82357e714f5be78713b0e3d4d5c4e911aea6c012e1d5e290fb1530be70d`.
The frozen current-output assertion now uses the measured digest; its selected public tool test passes.
The source files for that comparison are `/tmp/zttp-syntax-u5-search-current.json` and `/tmp/zttp-syntax-u5-search-old-policy.json`.
The main agent will rerun unfiltered checks after the final callback repair and source review.

The final generic repair applies every pattern through unknown-source refinement and retains the original source constraint.
When refinement is unavailable, callback checking retains the remaining source type instead of skipping compatibility.
The numeric descriptor control now accepts `number` and refuses `string` with one ZTS203.
An inferred generic identity callback passes and preserves the outer `T` return type through the public CLI.
The added CHECK case includes that control.
Explicit outer-generic callback annotations expose a shared limitation: the existing array `map` control also reports `expected T, got T`.
The match control reports `expected T, got T & number`. This unit does not change global generic assignability.
The comparison is `/tmp/zttp-syntax-u5-generic-annotation-control-final.json`; the inferred control exits zero with no diagnostics.
The main agent reviews the completed repair and freezes source for the final unfiltered run.
The unfiltered proof-swallow and spine checks exit zero after that repair.
The combined focused callback command passes six CHECK tests, but its filtered proof-swallow wrapper refuses the filter.
That mixed command is not evidence for the unfiltered proof gate.

The normalization brand-name rule is exact: lowercase the first ASCII character, preserve the remaining characters, then append `Brand`.
For example, `UserId` becomes `userIdBrand`. A generated-name collision leaves the whole input unchanged with a diagnostic.
Normalization must also update existing repair builders that emit legacy syntax.
The implementation order remains: verify normalization, migrate executable sources, then remove legacy admission.

The final frozen command is `env -u DEEPSEEK_API_KEY -u ZTTP_CODEGEN_RECORD zig build test-zts test-flow-census test-precompile test-proof-swallow test-contract-golden test-server test-zruntime check-spine test`.
It exits one and reports 9867 passing tests, six skipped tests, and one failed test across 9874 tests.
It completes 225 of 229 build steps. The only failed test is empirical replay; the policy drift script also fails.
Every owning behavior suite passes. The log is `/tmp/zttp-syntax-u5-final-frozen.log`.
The unfiltered CLI abuse gate passes all 40 cases. All 61 example suites pass.
The flow census passes 640 probes, with no fail-open, over-refusal, weak, or absent verdict.
The restriction census passes all 793 probes across 220 rows.
The bytecode gate matches 62 inputs, including 58 successfully digested inputs.
Formatting, diff, proof-swallow, layering, module-boundary, documentation, and spine checks pass.
These results do not establish a passing aggregate or a completed migration.
Normalization, source cutover, authoring updates, performance measurement, boundary mutations, and the owner recording remain.
