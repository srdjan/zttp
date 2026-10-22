# Coupling census plan

Status: revised 2026-10-22 after one Fable argument review and one Codex astra fact check. Planned at `0d4866c8`.

Authority: the owner answered decisions 1 to 4 of the coupling audit with "as recommended", which selects option (a) for each decision.
- Decision 1(a): confirm F0 first, then do the units that move no bytes (F5, F3, F4).
- Decision 2(a): keep the declined orchestration decision at `packages/zts/src/pipeline.zig`, and do only the interim F2 step.
- Decision 3(a): identity hashes and model-visible bytes stay identical. This applies to the later F1 and F7 work, which this plan does not include.
- Decision 4(a): keep both spec-diagnostic message texts as two named outputs from one row. This also applies to later F1 work.

The audit ledger is `~/.claude/plans/2026-10-22-zttp-coupling-audit.md`. This plan follows the completed [modular boundaries plan](2026-10-22-modular-boundaries-plan.md) and keeps its stop conditions. In particular, it adds no generic visitor, framework, event bus, or provider abstraction.

Worklog: `docs/plans/2026-10-22-coupling-census-worklog.md`. Every unit records its counts, classifications, probes, and gate exit statuses there.

## Goal

Several data shapes are copied by hand between files. A forgotten copy compiles and silently gives a default value. Each unit below replaces one such copy, or adds a census that fails the build when a new field or case is left unclassified. U1 also fixes a probable fail-open. No unit changes a wire format, a digest preimage, a golden, or model-visible text.

## Standing boundaries

- D-005: the proof-checker stays an independent leaf.
- D-006: the CHECK imported flow and fault traversals keep their reader paths, calls, order, and revision selection. D-006 binds behavior, not file placement.
- Contract-only extraction and loaded-graph sound extraction keep their different semantics (H7).
- These pins must not move: `EXPECTED_BUILTIN_HASH`, `EXPECTED_POLICY_HASH`, and the other identity pins in `scripts/check-meta-drift.sh`; the contract goldens; the expert goldens; and the v1 contract bytes that an artifact embeds.
- If a unit needs to move one of these, the implementer stops and reports. The implementer does not update a golden to match.

## Step 0 (baseline)

Done 2026-10-22 at `0d4866c8`, with a private Zig cache and `DEEPSEEK_API_KEY` unset. All 18 named gates that this plan uses exited 0: `test-deploy-manifest`, `test-proof-review`, `test-cli`, `test-zruntime`, `test-expert-golden`, `test-sdk`, `test-modules`, `test-zts`, `test-module-governance`, `test-capability-audit`, `test-flow-census`, `test-meta-drift`, `test-contract-golden`, `test-precompile`, `test-proof-swallow`, `test-diagnostic-corpus`, `check-spine`, and `test-script-reachability`. The logs are in `/private/tmp/claude-501/census-baseline/`.

## U1 (properties that were never proven read as false)

Problem, observed:
- `packages/tools/src/deploy_manifest.zig` and the `ProvenFacts` defaults at `:45-61` report `injection_safe`, `state_isolated`, `deterministic`, `no_secret_leakage`, `no_credential_leakage`, `input_validated`, and `pii_contained` as `true` when `contract.properties` is null.
- `packages/proof-review/src/review.zig` (`review.Properties`) has the same defaults.
- `ReviewFacts.parseJson` (`review.zig`) starts from these defaults. A JSON object that lacks a property key, or holds a non-bool value for it, reads that property as held.
- `packages/runtime/src/contract_runtime.zig` states that this fallback is wrong and keeps every property false.

Reachability, from code reading:
- A multi-module compile leaves `properties` null. `initMergedContract` (`packages/zts/src/handler_contract.zig`) does not set it, and the test "compileHandler keeps merged properties null after loaded graph effects" (`packages/tools/src/precompile.zig`) requires this result.
- With a ledger service name, `packages/runtime/src/build_command.zig` records that contract in the proof ledger through `extractProvenFacts`. The seven properties then appear in the ledger as proven.
- Every ledger line goes through `ReviewFacts.parseJson` (`packages/runtime/src/proof_ledger.zig`). `zttp proofs` reads the ledger at `proofs_cli.zig`, `:383`, `:405`, `:426`, `:494`, and `:564`.

Consumer effect, from code reading: `deriveDelta` (`review.zig`) reports old=true/new=false as `demoted_properties`, and `hasBreaking` and `classify` report that as breaking. With today's defaults, an old line that lacks a key reads as held, and the next line can report a false breaking regression. With `false`, the same case reads as `promoted`. No consumer was found where a missing key means "held".

Steps:
1. Add tests that fail today, and record each failure before you change the code:
   - (a) `extractProvenFacts` on a contract with `properties = null` gives `false` for each of the seven fields.
   - (b) A multi-module `compileHandler` result goes through `extractProvenFacts`, and each of the seven fields is `false`. This is the production path.
   - (c) `ReviewFacts.parseJson` gives `false` for each property in three cases: no `properties` key, an empty `properties` object, and a key whose value is not a bool.
2. Find every test that depends on a `true` default, and classify each one in the worklog. Known cases: the `review.zig` test "ReviewFacts.parseJson tolerates missing optional fields" (it asserts `injection_safe`), and the `review.zig` test "fromProvenFacts: projects every field from ProvenFacts", which never asserts `deterministic`. Correction from implementation: the plan also named a `proof_card_tui.zig` test, but that test does not depend on a default. Its `+injection-safe` text comes from the proof trace argument. Give that test the missing assertion. A test that asserts a property is `true` must set that property explicitly.
3. Change the defaults to `false` in `ProvenFacts`, `review.Properties`, and the null branch of `extractProvenFacts`. Do not change `HandlerProperties` in `contract_types.zig`. The builder computes its fields, and its defaults are outside this unit.
4. Update the comment at `review.zig`. It must say that a missing block, a missing key, or a non-bool value proves nothing.
5. Add a comptime check over `std.meta.fields` of `ProvenFacts` and of `review.Properties`. Every `bool` field must have the default `false`. A new property added with `= true` then fails the build. Also require each `review.Properties` field to have a `property_metas` row.

Gates: `zig build test-deploy-manifest`, `test-proof-review`, `test-precompile`, `test-cli`, `test-zruntime`, `test-expert-golden`, and then `zig build test`. `test-cli` compiles `proof_card_tui.zig`.

Done when the new tests pass, no golden moved, and the worklog has the step 2 classification.

## U2 (the binding adapter copies fields by reflection)

Problem, observed:
- `adaptFunctionBinding` (`packages/zts/src/module_binding_adapter.zig`) builds the internal `FunctionBinding` from a hand-written struct literal. `name` and `arg_count` are required, and every other field has a default. A forgotten line for a field with a default compiles, and it gives the default to all 17 adapted modules: 15 in `builtin_modules.zig`, plus `modules/data/sql.zig` and `modules/net/fetch.zig`.
- `adaptModuleBinding` (`:18-37`) has the same shape for the ten `ModuleBinding` fields. `exports` needs conversion because its element type differs.
- Commits `f8647cae`, `7f50ae3d`, and `f87f97aa` each needed a hand edit here.

Field mapping, observed:
- SDK `module_func` is wrapped into internal `func` through `wrapToNativeFn`. Internal `module_func` stays null.
- `return_labels` and `declassifies` convert between two distinct packed `u16` types. Each type has nine named bools and `_reserved: u7`. Reserved bits never become labels.
- Apart from these exceptions, field names and types match.

Steps:
1. Replace the `FunctionBinding` literal with an `inline for` over `std.meta.fields(sdk.FunctionBinding)`. Assign `func` explicitly, and skip SDK `module_func`. For a `LabelSet` field, copy each named label and skip `_reserved` on both sides. Assign every other field by name.
2. Write a coverage function with two exclusion lists, one for the source and one for the target. The existing `requireCoverage` (`packages/zttp-sdk/src/descriptors.zig`) checks names only, and it allows exclusions only on the source side, so it cannot express target-only `func`.
   - The new function also checks that each assigned pair has the same type.
   - Apply it to `FunctionBinding` (source excludes `module_func`; target excludes `func` and `module_func`).
   - Apply it to `LabelSet` in both directions (both sides exclude `_reserved`). A new SDK label then cannot be dropped silently.
   - Write the reason for each exclusion beside it.
3. Apply the same pattern to `adaptModuleBinding`, with `exports` assigned explicitly.
4. Keep the test "adapted bindings preserve capability inheritance and reject reserved label bits" (`module_binding_adapter.zig`) unchanged.
5. Probe: add a temporary field with a default to `sdk.FunctionBinding` and none to the internal type. Run `zig build test-zts`, and confirm from the exit status that the coverage error stops the build. Then add a temporary SDK label and confirm the same. Remove both. Record both probes in the worklog.

Gates: `zig build test-sdk`, `test-modules`, `test-zts`, `test-module-governance`, `test-capability-audit`, `test-flow-census`, `test-meta-drift`, and then `zig build test`. `EXPECTED_BUILTIN_HASH` must not move. A moved hash means the old copy and the new copy differ, so stop and report.

## U3 (a census of contract fields and property projections)

Problem, observed:
- `HandlerContract` (`packages/zts/src/contract_types.zig`, version 24, 36 fields) has these hand-kept field lists: the writer `contract_json_writer.zig`, the parser mirror `ContractWire` (`contract_json_parser.zig`, 36 fields) with `projectContract` (`:777`), and the diff `contract_diff.zig`.
- Eight `HandlerContract` fields are not serialized: `owned_rate_limit_namespace`, `owned_fault_cause_snippet`, `effect_analysis_complete`, `property_provenance`, `declared_specs_implicit`, `function_capsules`, `function_effect_capsules`, and `holes`.
- `ContractWire` keeps retired fields only so that `rejectRetiredFields` (`contract_json_parser.zig`) can refuse them. One example is `credentials`.
- v1 and v2 differ only in key names, and v2 always writes version 2 (`contract_json_writer.zig`).
- `HandlerProperties` (20 fields) is copied by hand into `RuntimeContract.Properties` (`packages/runtime/src/contract_runtime.zig`, 17 fields; it drops `post_only`, `canonical`, and `cost_bounded`), `ProvenFacts`, and `review.Properties`.
- `ProvenFacts.results_safe` comes from `contract.verification.results_safe` (`deploy_manifest.zig`), not from `HandlerProperties.result_safe`.
- `test-contract-golden` pins the JSON proof envelope for two handlers (`build/goldens.zig`). No golden pins a fully populated `writeContractJson` output.

Steps:
1. Add a fully populated contract fixture. Add two byte goldens, for `writeContractJson` (v1) and `writeContractJsonV2` (v2), generated from today's code. Add a round-trip test for each version: write, parse, write again, and expect identical bytes.
2. Add a population check over the golden bytes. Parse each golden as JSON, walk every value, and refuse `[]`, `{}`, `null`, `false`, `0`, `""`, and all-zero hex strings. An allowlist names each key path that legitimately holds such a value, with a reason. This check covers nested keys, so a nested field left at its default cannot hide a parser that drops it.
3. Add `packages/zts/src/contract_schema.zig` in the same tier as `contract_types.zig`. It holds one entry for each `HandlerContract` field, with two classifications:
   - `wire`: `serialized` or `not_serialized`, with a reason for each `not_serialized` field.
   - `diff`: `diffed` or `not_diffed`, with a reason for each `not_diffed` field. A field with no design reason gets the reason "gap", and the worklog lists it for the owner.

   A comptime block fails on a field with no entry, and on an entry that names no field.
4. Map each `ContractWire` field to one `HandlerContract` field, or classify it as `retired_refused`. A comptime block fails on an unmapped field. A `retired_refused` field must also appear in `rejectRetiredFields`. Check that with a test, or report why it cannot be checked.
5. Add projection coverage for `HandlerProperties`, with a two-list coverage check as in U2. For each projection (`RuntimeContract.Properties`, `ProvenFacts`, and `review.Properties`), every `HandlerProperties` field is projected, renamed, or excluded with a reason. Every projection field names its source. `ProvenFacts.results_safe` names `verification.results_safe`. Read each consumer, and write the reason that is true for each excluded field. U1 step 5 already covers the default values, so do not repeat it here.
6. The census records gaps and does not fix them. Do not change `diffContracts` in this unit.

Gates: `zig build test-zts`, `test-contract-golden`, `test-deploy-manifest`, `test-proof-review`, `test-cli`, `test-zruntime`, and then `zig build test`.

Done when the census compiles and the goldens match today's bytes. Two probes must also fail the build, confirmed by exit status and then removed: a temporary field added to `HandlerContract`, and a temporary field added to `HandlerProperties`.

## U4 (the imported-file analysis gets its own file under the swallow gate)

Problem, observed:
- `packages/tools/src/precompile.zig` lines 258-762 hold `FlowModuleGraph`, `loadFlowModulesForCheck`, `collectImportedAnalyses`, `ImportedFaultScan`, `collectImportedFailableCalls`, `scanImportedFileTree`, and `analyzeImportedFunction`. This code decides imported effects and flow targets.
- `precompile.zig` is not in `proof_files` in `scripts/check-proof-swallow.sh`. The range has 9 catch sites: `:492`, `:625`, `:631`, `:684`, `:703`, `:711`, `:717`, `:757`, and `:758`. It also has one silent switch arm without an `// exhaustive:` reason, at `:494`.
- The fallbacks differ:
  - `:492`: OOM propagates, and other resolver errors trap.
  - `:625`: returns a blocked fault scan.
  - `:631`: OOM propagates, or invalid IR is blocked.
  - `:684`: OOM propagates, or the graph is marked incomplete.
  - `:703`, `:711`, `:717`: type checking is marked unclean. Effect analysis then still runs without types and can return an effect that is not blocked.
  - `:757`, `:758`: return a blocked effect, possibly with a flow target already set.
- Behavior tests cover several of these cases, for example `precompile.zig`, `:7369`, `:7801`, `:7812`, `:8260`, and `:8397`. No structural gate covers them.
- The gate scanner reports 72 catch rows and three unmarked silent arms (`:494`, `:1223`, `:2973`) for all of `precompile.zig`.

Steps:
1. Move lines 258-762 into `packages/tools/src/precompile_imports.zig`, and follow the pattern of `precompile_check.zig` and `precompile_args.zig`.
   - The moved code depends on `readFilePosix` (`:168`), `max_import_depth` (`:176`), `ImportStack` (`:180`), `ImportReader` (`:198`), and `ImportedFile` (`:210`). Move these too, and re-export them from `precompile.zig`.
   - `precompile.ImportReader` must stay a public path, because `packages/runtime/src/proofs/pr_gate.zig` and `:897` use it.
   - Parent callers need `collectImportedFailableCalls` and `ImportedFaultScan.deinit`. Parent tests reference `max_import_depth`, `ImportedFile`, and `resolveCheckImportPath`. Make each of these `pub` in the new file, and record each visibility change in the worklog.
   - The logic does not change.
2. Make sure that `zig build test-precompile` runs the tests of the new file. Its test root is `precompile.zig` (`build/host_tests.zig`). Compare the test count before and after the move: the count must not go down.
3. Run `git add packages/tools/src/precompile_imports.zig` before the gate. The gate's mutation probe copies its inputs through `git ls-files` (`check-proof-swallow.sh`), so an untracked file is left out.
4. Add the new file to `proof_files`, so the list holds 22 files. Run `zig build test-proof-swallow`. The scanner attributes catches by the enclosing function, and it attributes `:625` and `:631` to the nested helper `at`.
   - Write one allowlist row for each reported site. Each reason must state why the site cannot turn an unproven program into a proven one.
   - For `:703`, `:711`, and `:717`, read what effect analysis without types can return, and show that it is not weaker than the typed result. If you cannot show that, stop and report it as a probable defect, and write no row.
   - Give the silent arm at `:494` an `// exhaustive:` reason.
5. For each catch outside the moved range that the scanner reports for `precompile.zig`, record in the worklog whether it can weaken a verdict. Name `:1940` (the `catch null` in `runGenTests`, which falls back to `.unavailable`) explicitly. This records the measured scope of the rest of the file. It adds no rows.
6. Add `packages/tools/src/precompile_imports.zig` to the `Binds` line of D-006 in `docs/decisions.md`. Update the function locations in `docs/solutions/security-issues/a-missing-import-entry-was-conservative-for-one-proof-and-clean-for-another.md`. Then run `zig build check-spine` and `zig build test-doc-links`.

Gates: `zig build test-precompile`, `test-proof-swallow`, `test-diagnostic-corpus`, `test-flow-census`, `test-contract-golden`, `check-spine`, `test-script-reachability`, `test-doc-links`, and then `zig build test`.

## U5 (census of node-kind default arms in proof files)

Problem, observed:
- 140 lines in `packages/zts/src` match `getTag(node)`. Many switches over the 69 `NodeTag` members (`parser/ir.zig`) have an `else` arm that treats an unnamed kind as a leaf.
- `scripts/check-proof-swallow.sh` already runs a silent-arm census over `proof_files`. Each arm that it matches needs an `// exhaustive:` reason (`:189-222`). Its regex sees `else => {}`, `return`, `continue`, literal arms, and name arms. It does not see `else => try ...` (for example `effect_inference.zig`), `else => blk:`, `else => |x|`, or a multi-line `else => {`.
- `proof_ir.forEachSubNode` starts at `proof_ir.zig` and has a default arm. Its comment relies on profile rejection (`:291`). No exhaustive node-kind classifier exists there.

This unit is read-only research. It edits no source file.

Steps:
1. Run the census over the 22 files in `proof_files` after U4. Start from the arms that the gate already reviews. Then add the arms that its regex cannot see, from an independent search, and report those as a separate count.
2. Compute once the set of `NodeTag` members that have child nodes, from `IrView` accessors in `parser/ir.zig`.
3. Classify each arm with exactly one label, using the first label that applies, in this order:
   - `leaf-correct`: no child-bearing tag reaches the arm. Decide this mechanically from step 2.
   - `local-refusal`: the arm itself sets the conservative value (for example `graph.complete = false`).
   - `refused-downstream`: name the check that refuses.
   - `diagnosed`: the missed kind produces a diagnostic.
   - `precision-only`: name why a missed kind cannot raise a property.
   - `unclear`.
4. Record the table and the count for each label in the worklog.
5. The owner decides later which `unclear` arms become exhaustive switches. This plan does not authorize that edit.

## Order, isolation, and commits

The units run in the order U1, U2, U3, U4, U5. U1 and U3 both edit `deploy_manifest.zig` and `review.zig`, so the units run one after another, not in parallel.

Work happens on local main in `/Users/srdjans/Code/_TEAMOK/ZTTP`. Each unit is one commit, made after Opus reviews the diff and re-runs the unit's gates.

Every build uses a private cache. Set `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` under `/private/tmp/claude-501/`, and unset `DEEPSEEK_API_KEY`. Redirect build output to a file, and read the exit status directly. Never use `-Dtest-filter` as evidence.

After U4, run `zig build test`, `zig build check-spine`, and `bash scripts/verify.sh`, and record each exit status in the worklog.

## Stop conditions

- A pin, golden, or wire byte moves.
- An allowlist row would describe a swallow that weakens a verdict.
- A gate fails and stays unexplained after two reasonable corrections.
- A unit needs a file outside its scope, apart from the documentation updates named in U4 step 6.

## Progress

| Unit | Status |
|---|---|
| Step 0 Baseline | Done 2026-10-22; 18 gates exit 0 |
| U1 Unproven properties read false | Done 2026-10-22; lead re-ran U1 gates and `zig build test` (200/200 steps) with a fresh cache |
| U2 Reflective binding adapter | Not started |
| U3 Contract census | Not started |
| U4 Imported analysis under the swallow gate | Not started |
| U5 Node-kind arm census | Not started |
