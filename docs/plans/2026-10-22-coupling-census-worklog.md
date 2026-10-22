# Coupling census worklog

This file records the counts, classifications, probes, and gate exit statuses for each unit of the [coupling census plan](2026-10-22-coupling-census-plan.md).

All builds used a private cache under `/private/tmp/claude-501/zcache-u1/` with `DEEPSEEK_API_KEY` unset. Logs are in `/private/tmp/claude-501/u1logs/`. Each exit status was read directly from the build command.

## U1 (properties that were never proven read as false)

Status: implemented, awaiting review. Nothing is committed.

### Change

The seven properties `injection_safe`, `state_isolated`, `deterministic`, `no_secret_leakage`, `no_credential_leakage`, `input_validated`, and `pii_contained` now default to `false` in `ProvenFacts` and in `review.Properties`. The null branch of `extractProvenFacts` also gives `false`. `HandlerProperties` in `contract_types.zig` is unchanged. The comment above `review.Properties` now says that a missing block, a missing key, or a non-bool value proves nothing.

### New tests

| Test | File | What it checks |
|---|---|---|
| `extractProvenFacts reads every security property as false when properties is null` | `packages/tools/src/deploy_manifest.zig` | step 1(a) |
| `extractProvenFacts keeps a proven property when properties is set` | `packages/tools/src/deploy_manifest.zig` | a proven property still reads true |
| `multi-module compile proves no security property in the extracted facts` | `packages/tools/src/precompile.zig` | step 1(b), the production path |
| `ReviewFacts.parseJson reads every property as false when the properties key is missing` | `packages/proof-review/src/review.zig` | step 1(c) |
| `ReviewFacts.parseJson reads every property as false when properties is empty` | `packages/proof-review/src/review.zig` | step 1(c) |
| `ReviewFacts.parseJson reads a non-bool property value as false` | `packages/proof-review/src/review.zig` | step 1(c) |
| `ReviewFacts.parseJson keeps a property that the JSON states as true` | `packages/proof-review/src/review.zig` | a stated `true` survives, and an unstated key stays false |

Test (b) lives in `precompile.zig`. That file is in the `tools` package, so a relative `@import("deploy_manifest.zig")` inside the test works. The test reuses the fixture of "compileHandler keeps merged properties null after loaded graph effects" and asserts `merged.properties == null` before it extracts the facts.

### Failing-test evidence (before the production change)

| Step | Exit | Failing tests | Log |
|---|---|---|---|
| `test-deploy-manifest` | 1 | the null-properties test (8 of 9 passed) | `red-test-deploy-manifest.log` |
| `test-precompile` | 1 | the multi-module test and the null-properties test (285 of 287 passed) | `red-test-precompile.log` |
| `test-proof-review` | 1 | the four `parseJson` tests (28 of 32 passed) | `red-test-proof-review.log` |

The fourth `parseJson` test failed because an unstated key still read as held (`state_isolated` was true).

### Step 2: tests that depended on a true default

| Test | File | Class | Action |
|---|---|---|---|
| `appendEvent preserves existing hosted state bytes` | `packages/runtime/src/proof_ledger.zig` | Depended on the default. It compares a ledger line byte for byte, and the line holds the seven properties as `true`. It read them from the defaults in the shared fixture `buildFactsForTest`. `test-cli` failed. | The fixture now sets the seven properties to `true` explicitly. The expected bytes did not change. Other `proofs_cli.zig` tests share the fixture and kept their expectations. |
| `ReviewFacts.parseJson tolerates missing optional fields` | `packages/proof-review/src/review.zig` | Asserted `injection_safe` is true for a missing block. `test-proof-review` failed. | The assertion now reads `!injection_safe`, because a missing block proves nothing. This is the intended behavior change. The new `parseJson` tests cover all seven properties. |
| `fromProvenFacts: projects every field from ProvenFacts` | `packages/proof-review/src/review.zig` | Claimed to project every field but never set or asserted `deterministic`. It passed only because the old default was `true`. | The literal sets `.deterministic = true` and the test asserts it. |
| `writeProofCardFrame: resisted block surfaces a held flow proof and keeps width` | `packages/runtime/src/proof_card_tui.zig` | The plan named this test as dependent on the default. It is not. The `+injection-safe` text comes from the `proof_trace_json` argument in `writeResistedBlock`, not from `properties`. | No change. I added `injection_safe = true`, removed that line, and `test-cli` still exited 0 (`probe-card-test-cli.log`). I then reverted the file. |

`test-proof-review`, `test-cli`, `test-zruntime`, `test-expert-golden`, `test-precompile`, and `zig build test` found no other test that depends on a `true` default. No golden file changed.

### Step 5: comptime census and probes

A `comptime` block at the end of `deploy_manifest.zig` rejects any `bool` field of `ProvenFacts` whose default is `true`. A matching block at the end of `review.zig` does the same for `review.Properties`, and it also requires a `property_metas` row for every field.

A field with no default is allowed. `env_proven`, `egress_proven`, and `cache_proven` have none, and the producer must state them. My first version required a default of `false` for every bool and failed on those three fields, which is why the rule is "no default of true".

Probes, each reverted afterwards (`grep -c probe_flag` gives 0 in both files):

| Probe | Exit | Message | Log |
|---|---|---|---|
| Add `probe_flag: bool = true` to `ProvenFacts` | 1 | `ProvenFacts.probe_flag must default to false` | `probe-provenfacts-true.log` |
| Add `probe_flag: bool = true` to `review.Properties` | 1 | `review.Properties.probe_flag must default to false` | `probe-properties-true.log` |
| Add `probe_flag: bool = false` to `review.Properties` with no meta row | 1 | `review.Properties.probe_flag has no property_metas row` | `probe-properties-nometa.log` |

### Gates

| Gate | Exit | Log |
|---|---|---|
| `zig fmt --check` on the four edited files | 0 | not logged |
| `zig build test-deploy-manifest` | 0 | `final-test-deploy-manifest.log` |
| `zig build test-proof-review` | 0 | `final-test-proof-review.log` |
| `zig build test-precompile` | 0 | `final-test-precompile.log` |
| `zig build test-cli` (also compiles `proof_card_tui.zig`, through `cli_main.zig`) | 0 | `final-test-cli.log` |
| `zig build test-zruntime` | 0 | `final-test-zruntime.log` |
| `zig build test-expert-golden` | 0 | `final-test-expert-golden.log` |
| `zig build test` | 1 | `final-test.log`: 194 of 200 steps passed, 9160 of 9166 tests passed, 6 skipped. Two steps failed: `check-spine` and `test-spine`. See the note below. |
| `zig build check-spine` | 1 | `final-check-spine.log` |

### The spine failure is outside U1

`check-spine` prints 35 `spine[line_anchor]` messages. Every message names `docs/plans/2026-10-22-coupling-census-plan.md`, which anchors source files by line number (for example `review.zig`). The spine rejects line anchors and asks for a file or `#symbol` reference. The plan document came in with commit 74ce28cc, after the baseline at 0d4866c8 where `check-spine` passed. `test-spine` fails for the same reason, because its probe runs the check on the repository. U1 does not edit the plan except for one Progress row, and the worklog uses no line anchors. I did not rewrite the anchors. The lead owns that decision. All other steps of `zig build test` passed, including `test-proof-swallow` and `test-module-boundary`.

### U1 lead verification

The lead reviewed the diff line by line. The lead then re-ran the gates with a fresh private cache in `/private/tmp/claude-501/verify-u1/`. `zig fmt --check` on the four edited files, `test-deploy-manifest`, `test-proof-review`, `test-precompile`, `test-cli`, `test-zruntime`, `test-expert-golden`, and `zig build test` each exited 0. The aggregate reported 200/200 steps and 9160/9166 tests passed, with 6 skipped.

The first aggregate failure in `check-spine` and `test-spine` came from line anchors in the plan document. The lead removed the anchors, and `check-spine` exited 0.

Effect on existing ledgers: a multi-module handler now records the seven properties as false. A ledger that holds an earlier entry for that handler can show one demotion on the next deploy. That earlier entry claimed properties that nothing proved.

## U2: the binding adapter copies fields by reflection

Status: implemented, awaiting review. Only `packages/zts/src/module_binding_adapter.zig` changed in source. No pin, golden, or wire byte moved.

### What changed

`adaptFunctionBinding`, `adaptModuleBinding`, and a new `adaptLabels` now copy fields with an `inline for` over `std.meta.fields` of the SDK type. The hand-written struct literals are gone. The new `coverageProblem` function takes a source type, a target type, a source exclusion list, and a target exclusion list. Each exclusion is an `Exclusion` record with a name and a reason. `requireCoverage` turns its result into a `@compileError`.

`coverageProblem` fails in these cases. A source field has no target field of the same name. A source and target field of one name have different types. A target field has no source field. An exclusion names a field that its own side does not have. An exclusion has an empty reason. The message names both types and the field.

The existing `requireCoverage` in `packages/zttp-sdk/src/descriptors.zig` is unchanged. It checks names only and allows exclusions on the source side only. The new function lives in the adapter file.

The test "adapted bindings preserve capability inheritance and reject reserved label bits" is unchanged. I added one test, "adapter coverage refuses unclassified fields, type changes, and bad exclusions". It checks each failure case of `coverageProblem` on small local types.

### Exclusions

| Pair | Side | Field | Reason |
|---|---|---|---|
| `FunctionBinding` | source | `module_func` | `wrapToNativeFn` turns it into the internal `func` field. |
| `FunctionBinding` | source and target | `return_labels` | The two `LabelSet` types differ. `adaptLabels` converts it. |
| `FunctionBinding` | source and target | `declassifies` | The two `LabelSet` types differ. `adaptLabels` converts it. |
| `FunctionBinding` | target | `func` | The adapter sets it from the wrapped SDK `module_func`. |
| `FunctionBinding` | target | `module_func` | It stays null. The adapter wraps the SDK function into `func`. |
| `ModuleBinding` | source and target | `exports` | The element type differs. `adaptFunctionBindings` converts it. |
| `LabelSet` | source and target | `_reserved` | Reserved bits never become analyzer labels. |

The adapter assigns `func`, `module_func`, `return_labels`, `declassifies`, and `exports` explicitly. The `inline for` assigns every other field by name.

### Probes

Each probe changed one SDK file and ran `zig build test-zts` with a private cache. I restored the file after each probe. `git status` then showed only the adapter file as modified.

| Probe | Exit | Error text | Log |
|---|---|---|---|
| Add `probe_flag: bool = false` to `FunctionBinding` in `packages/zttp-sdk/src/binding.zig` only | 1 | `binding.FunctionBinding -> module_binding.types.FunctionBinding: unclassified source field: probe_flag` | `/private/tmp/claude-501/u2logs/probe-a.log` |
| Add `probe_label: bool` to the SDK `LabelSet` in `packages/zttp-sdk/src/descriptors.zig` only, and shrink `_reserved` to `u6` | 1 | `descriptors.LabelSet -> module_binding.types.LabelSet: unclassified source field: probe_label` | `/private/tmp/claude-501/u2logs/probe-b.log` |
| Change `arg_count` in the SDK `FunctionBinding` from `u8` to `u16` | 1 | `binding.FunctionBinding -> module_binding.types.FunctionBinding: field type differs: arg_count` | `/private/tmp/claude-501/u2logs/probe-c.log` |

### Gates

Logs are under `/private/tmp/claude-501/u2logs/`.

| Gate | Exit | Log |
|---|---|---|
| `zig fmt --check` on the adapter file | 0 | not logged |
| `zig build test-sdk` | 0 | `final-test-sdk.log` |
| `zig build test-modules` | 0 | `final-test-modules.log` |
| `zig build test-zts` | 0 | `final-test-zts.log` |
| `zig build test-module-governance` | 0 | `final-test-module-governance.log` |
| `zig build test-capability-audit` | 0 | `final-test-capability-audit.log` |
| `zig build test-flow-census` | 0 | `final-test-flow-census.log` |
| `zig build test-meta-drift` | 0 | `final-test-meta-drift.log` |
| `zig build test` | 0 | `final-test.log` |

`EXPECTED_BUILTIN_HASH` did not move. `test-meta-drift` exits 0, so the reflective copy yields the same bindings as the old literals for all 17 adapted modules.

### U2 lead verification

The lead reviewed the diff line by line. With a fresh private cache in `/private/tmp/claude-501/verify-u2/`, `zig fmt --check`, `test-sdk`, `test-modules`, `test-zts`, `test-module-governance`, `test-capability-audit`, `test-flow-census`, `test-meta-drift`, `check-spine`, and `zig build test` each exited 0. The aggregate reported 200/200 steps and 9161/9167 tests passed, with 6 skipped. `EXPECTED_BUILTIN_HASH` did not move.

## U3: a census of contract fields and property projections

Status: implemented, awaiting review. Nothing is committed. No pin, golden, or wire byte moved. `diffContracts` and every production code path are unchanged.

Builds used a private cache under `/private/tmp/claude-501/zcache-u3/` with `DEEPSEEK_API_KEY` unset. Logs are in `/private/tmp/claude-501/u3logs/`. Each exit status was read directly from the build command.

### What changed

| File | Change |
|---|---|
| `packages/zts/src/contract_schema.zig` (new, tier `zts-contracts`) | One entry for each of the 36 `HandlerContract` fields, with a wire class and a diff class. One entry for each of the 36 `ContractWire` fields. Comptime checks and 5 tests. |
| `packages/zts/src/contract_census.zig` (new, tier `zts-contracts`) | The fully populated fixture, the golden-byte tests, the round-trip tests, the population check, the root-key check, and the retired-field refusal tests. 10 tests. |
| `packages/zts/src/fixtures/contract/full_v1.json`, `full_v2.json` (new) | The byte goldens. I generated them once from the writers as they stood before U3. |
| `packages/zts/src/contract_json_parser.zig` | One import and one `comptime` block that calls `contract_schema.requireWireMirror(ContractWire)`. |
| `packages/zts/src/contracts_root.zig` | Exports `contract_schema`. The root test block imports `contract_census.zig`. |
| `scripts/zts-tiers.allow` | Two rows, one for each new `.zig` file. |
| `packages/runtime/src/contract_runtime.zig`, `packages/tools/src/deploy_manifest.zig`, `packages/proof-review/src/review.zig` | Each file holds a two-list projection check beside its projection, a value test, and a test of the check itself. |

I added no row to `scripts/module-boundary.allow`. Each of the three projection packages sees `zts.HandlerProperties` through the curated surface. Each package holds its own private copy of the small `projectionProblem` helper, because the packages cannot share one without a new import. That makes three copies, plus the U2 `coverageProblem` copy in the adapter.

### Census summary

The wire column of `contract_schema.entries`: 28 fields are serialized and 8 are not. The `ContractWire` table: 24 fields fill `HandlerContract` fields, and 12 are `retired_refused`. The field `sandbox` fills 5 `HandlerContract` fields (`capabilities`, `capability_budget`, `policy_hash`, `wasm_policy_hash`, `artifact_sha256`). Every other carrying field fills one.

The diff column, over all 36 fields:

| Class | Count | Fields |
|---|---|---|
| `diffed` | 4 | `env`, `cache`, `sql`, `behaviors` |
| `partly_diffed` | 5 | `routes`, `egress`, `api`, `properties`, `cost_envelope` |
| `not_diffed` with a design reason | 15 | listed below |
| `not_diffed` with a gap | 12 | listed below |

The plan names two diff classes. I added `partly_diffed`, because five fields have a compared part and an uncompared part. Each `partly_diffed` field has a reason that names the uncompared part. This is a deviation from the plan.

### Fields that are not serialized (8)

All eight are transient. The contract JSON does not emit them.

| Field | Reason |
|---|---|
| `owned_rate_limit_namespace` | An allocation that backs `rate_limiting.namespace` after a decode. |
| `owned_fault_cause_snippet` | An allocation that backs a `property_provenance` snippet at check time. |
| `effect_analysis_complete` | Transient analysis state. |
| `property_provenance` | In-memory provenance for the live-reload HUD. |
| `declared_specs_implicit` | Transient. The build recomputes it. |
| `function_capsules` | Transient output for the `--json` analysis envelope. |
| `function_effect_capsules` | Transient output for the `--json` analysis envelope. |
| `holes` | Exist only for an unfinished program. |

### Fields that `diffContracts` does not compare, with a design reason (15)

The eight transient fields above, and these seven: `version` (wire format marker), `handler` (source location), `fault_coverage` (the bit `properties.fault_covered` carries the outcome), `intent` (assertions are examples outside the proof boundary), `artifact_sha256`, `policy_hash`, and `wasm_policy_hash` (build stamps). The design judgments are mine. I read them from the type comments and the field meaning, and the owner can overturn them.

### Gaps for the owner (17 fields)

A gap means that `diffContracts` does not compare the field, or compares only part of it, and no reason is recorded. I did not fix any of them.

Not compared at all (12):
- `modules` and `functions`: an added or removed import is not reported.
- `verification`: `results_safe` is covered only through `properties.result_safe`, and only when `properties` is set.
- `aot`: the AOT pattern count and default flag.
- `rate_limiting`: the dynamic flag. The namespace is usually also in `cache.namespaces`, which is compared.
- `declared_specs`: a narrower or wider declared Proof set.
- `extensions`: the category literals and dynamic flags. The extension egress hosts are copied into `egress.endpoints`, which is compared.
- `spec_diagnostics`: a new or cleared diagnostic.
- `behaviors_exhaustive`: a change from exhaustive to truncated enumeration.
- `capabilities`: a widened capability matrix.
- `capability_budget`: a changed declared `Effects` budget.
- `source_identity`: a changed core profile or grammar hash.

Compared in part (5):
- `routes`: `field` (path or url) and `aot` are not compared.
- `egress`: the full fetch `urls` are not compared.
- `api`: `api.auth`, `api.requests`, and schemas that no route references are not compared.
- `properties`: nothing is compared when either contract has `properties` null. Inverse facts such as `has_egress` are left out on purpose.
- `cost_envelope`: only the class of the total bound is compared. A larger constant or coefficient inside one class, the per-module entries, and the exhaustive flag are not.

The diff column is declared from a reading of `diffContracts`. Nothing executes the differ against the table, so the table can go stale if someone adds a comparison. An existing test in `contract_diff.zig` fails if someone removes one that it covers.

### Wire census: evidence

- The fixture sets every serialized field. The writers produce `full_v1.json` and `full_v2.json` byte for byte, and `write, parse, write` returns the same bytes for both versions. Parsing each golden and writing it back also returns the same bytes.
- The population check parses each golden and walks every value, 316 in all. It refuses `[]`, `{}`, `null`, `false`, `0`, `""`, and all-zero hex strings. The floor is 220 leaves for each version, measured from the committed goldens. The count is the same for v1 and v2.
- The root-key check requires every carried wire field to appear as a root key and no retired wire field to appear. It allows two other keys, `payments` (the partner section) and `provenSpecs` (a summary that the writer derives from `properties`), and requires both to appear.
- All 12 retired fields have a refusal case. The parser refuses each one in v1 and in v2 with `UnsupportedRuntimeAuthority`. A control document without the key parses. A second test refuses `sourceIdentity.frontend`. A retired field with no case fails the test.

Population allowlist (6 rows, v1 spelling; the v2 check converts them to snake case). A row is valid only when the path holds an empty value somewhere and a populated value somewhere. A row that nothing matches fails.

| Path | Reason |
|---|---|
| `api.routes[].requestBodies[].schemaRef` | A schema spec holds one of ref, inline JSON, or dynamic. Another body in the array populates this one. |
| `api.routes[].requestBodies[].schema` | Same. |
| `api.routes[].requestBodies[].dynamic` | Same. |
| `api.routes[].responses[].schemaRef` | Same. |
| `api.routes[].responses[].schema` | Same. |
| `api.routes[].responses[].dynamic` | Same. |

One line of each golden ends in a space (`}, ` in `costEnvelope.perModule`). The writer emits it, so the golden keeps it. `git diff --check` reports it.

Limits of the wire census. The key `sandbox` fills five fields, and the census cannot tell which sub-key is missing if the writer drops one. The golden bytes and the population check catch that case, because a dropped sub-key changes the bytes.

### Projection census (step 5)

Each check uses two exclusion lists and requires the same type on both sides. A value test runs once with every flag true and once with every flag false, and compares each carried field by name. A forgotten assignment then shows as a default in one of the two runs. None of the three projections renames a field, so I wrote no rename support.

`RuntimeContract.Properties` (17 fields). Excluded source fields:

| Field | Reason |
|---|---|
| `post_only` | No runtime code reads it. The route pre-filter works from the contract route table. |
| `canonical` | A claim about the source form, fixed at compile time. No runtime code reads it. |
| `cost_bounded` | No runtime code reads the bit. The cost limits come from the separate `cost_envelope` field. |

`ProvenFacts` (12 fields copied by name). Excluded source fields:

| Field | Reason |
|---|---|
| `pure`, `stateless`, `optional_safe`, `post_only`, `canonical`, `cost_bounded` | `ProvenFacts` has no field, so neither the review card nor the proof ledger shows the property. |
| `has_egress` | An inverse fact that the monotonic ratchets leave out on purpose. `egress_endpoints` and `egress_proven` carry the egress surface. |
| `result_safe` | `ProvenFacts.results_safe` reads `contract.verification.results_safe` instead. |

`ProvenFacts` target fields that do not come from `HandlerProperties`, each with its source: `handler_name` and `handler_path` (the handler path), `env_vars` and `env_proven` (`env`), `egress_endpoints` and `egress_proven` (`egress`), `cache_namespaces` and `cache_proven` (`cache`), `routes`, `proof_level` (`deriveProofLevel`), `checks_passed` (the passed flags of `verification`), and `results_safe` (`contract.verification.results_safe`, not `HandlerProperties.result_safe`). A separate test sets `result_safe` to the opposite of `verification.results_safe` and checks that `results_safe` follows `verification`.

`review.Properties` (11 fields by name from `HandlerProperties` through `ProvenFacts`). The check runs against `HandlerProperties` and the test goes from a `HandlerContract` through `extractProvenFacts` and `fromProvenFacts`. The excluded source fields are the same eight as for `ProvenFacts`, plus `max_io_depth`. `ProvenFacts` carries `max_io_depth`, but `Properties` holds boolean flags only. The one target field, `results_safe`, names its source: `ProvenFacts.results_safe`, from `contract.verification.results_safe`.

Finding for the owner: six proven properties (`pure`, `stateless`, `optional_safe`, `post_only`, `canonical`, `cost_bounded`) never reach `ProvenFacts`, the review card, or the proof ledger. A loss of one of them is not visible there. I recorded the fact and changed nothing.

Other copies of `HandlerProperties` already had guards. The probes below showed `propertyLossSeverity` in `contract_diff.zig`, the property table in `proof_trace.zig`, `PropertiesWire` in the parser, and `PropertiesSnapshot` in `packages/pi`. `runtime`'s `acceptedProperties` is a second `Properties` filter (6 fields) that I did not cover.

### Probes

Each probe changed source temporarily, ran the build, and then restored the source. I restored the parser from a saved copy after a first mistake (see Surprises).

| Probe | Exit | Error text | Log |
|---|---|---|---|
| A: add `probe_flag: bool = false` to `HandlerContract` | 1 | `contract_schema.zig:411:91: error: contract_types.HandlerContract: field has no entry: probe_flag` | `probe-a-handlercontract.log` |
| B1: add `probe_flag: bool = false` to `HandlerProperties` only | 1 | The existing guards stop `zts` first: `PropertiesWire and HandlerProperties differ in field count`, `propertyLossSeverity has no entry for HandlerProperties.probe_flag`, and `proof_trace: HandlerProperties field has no property_info row: probe_flag`. The new censuses are not reached. | `probe-b1-handlerproperties.log` |
| B2: B1 plus a matching `PropertiesWire` field, `test-deploy-manifest` | 1 | `deploy_manifest.zig:432:9: error: contract_types.HandlerProperties -> deploy_manifest.ProvenFacts: unclassified source field: probe_flag` | `probe-b2-test-deploy-manifest.log` |
| B2, `test-proof-review` | 1 | `review.zig:1932:9: error: contract_types.HandlerProperties -> review.Properties: unclassified source field: probe_flag` | `probe-b2-test-proof-review.log` |
| B2, `test-cli` | 1 | `contract_runtime.zig:490:106: error: contract_types.HandlerProperties -> contract_runtime.Properties: unclassified source field: probe_flag` | `probe-b2-test-cli.log` |
| M1: the parser skips `contract.egress.urls = ...` | 1 | Round-trip tests: `First difference occurs on line 49`. | `probe-m1-parser-drops-urls.log` |
| M2: `rejectRetiredFields` skips `wire.sagas` | 1 | `a retired wire field was accepted: sagas` | `probe-m2-retired-forgets-sagas.log` |
| M3: add `probeWire: bool` to `ContractWire` | 1 | `contract_schema.zig:407:60: error: contract_json_parser.ContractWire: field has no wire entry: probeWire` | `probe-m3-new-wire-field.log` |
| M4: set `handler.line` to 0 in `full_v1.json` | 1 | `unpopulated value in the golden: handler.line (1 of 1 occurrences)` | `probe-m4-zero-in-golden.log` |

The B2 logs also hold the existing `propertyLossSeverity` error, because I did not add a severity row. M1 to M4 ran the contracts test binary directly, with the command that the build printed. After each probe the files matched the saved copies (`cmp`), and the final gates ran after the last restore.

### Test counts

| Step | Before | After |
|---|---|---|
| `test-zts`, `zts-contracts` binary | 52 | 67 (5 schema, 10 census) |
| `test-zts`, total | 2973 passed of 2974 | 2988 passed of 2989 (1 skipped both times) |
| `test-deploy-manifest` | 9 | 12 |
| `test-proof-review` | 32 | 34 |
| `test`, aggregate | 9161 passed of 9167 (end of U2) | 9206 passed of 9212 (6 skipped) |

The new runtime tests (2) compile and run inside `test-cli`. I have no baseline count for `test-cli`. The contracts test count rose from 52 to 67, which confirms that the new files run.

### Gates

Logs are under `/private/tmp/claude-501/u3logs/`. The final run used the files `final2-<step>.log`, after the last restore.

| Gate | Exit | Result |
|---|---|---|
| `zig fmt --check` on the 7 edited `.zig` files | 0 | not logged |
| `zig build test-zts` | 0 | 13/13 steps, 2988/2989 tests |
| `zig build test-contract-golden` | 0 | 8/8 steps |
| `zig build test-deploy-manifest` | 0 | 12/12 tests |
| `zig build test-proof-review` | 0 | 34/34 tests |
| `zig build test-cli` | 0 | 5/5 steps |
| `zig build test-zruntime` | 0 | 240/240 tests |
| `zig build test-module-boundary` | 0 | no row added |
| `zig build test-zts-layering` | 0 | two tier rows added |
| `zig build check-spine` | 0 | also exit 0 after this worklog entry, with `test-doc-links` and `test-docs-drift` (`final3-*.log`) |
| `zig build test` | 0 | 200/200 steps, 9206/9212 tests |

The first `test-module-boundary` run failed with `proof-review handler_contract`, because my test called `zts.handler_contract.emptyContract`. I replaced it with a literal `zts.HandlerContract`, and the gate then passed with no new row.

### Surprises

- During probe B2, `git checkout` on the parser file reverted my own edit to it. The probe M3 result caught this (it exited 0). I re-applied the edit, saved a copy, and used the saved copy for every later restore. The gates in the table ran after that.
- The writer already emits a derived root key `provenSpecs` that no `ContractWire` field reads. The root-key check lists it with a reason.
- A schema spec holds one of ref, inline JSON, or dynamic. A fully populated golden therefore needs three bodies and three responses, and the allowlist has 6 rows for that reason.

### U3 lead verification

The lead reviewed the schema, the census tests, the population check, and the three projection checks. With a fresh private cache in `/private/tmp/claude-501/verify-u3/`, `zig fmt --check`, `test-zts`, `test-contract-golden`, `test-deploy-manifest`, `test-proof-review`, `test-cli`, `test-zruntime`, `test-module-boundary`, `test-zts-layering`, `test-docs-drift`, `test-doc-links`, `check-spine`, and `zig build test` each exited 0. The aggregate reported 200/200 steps and 9206/9212 tests passed, with 6 skipped. The existing goldens did not move.

## U4: the imported-file analysis gets its own file under the swallow gate

Status: implemented, awaiting review. Nothing is committed. `packages/tools/src/precompile_imports.zig` is staged with `git add` (needed by the gate probe) and nothing else is staged. No pin, golden, or wire byte moved. No moved body changed.

Builds used a private cache under `/private/tmp/claude-501/zcache-u4/` with `DEEPSEEK_API_KEY` unset. Logs are in `/private/tmp/claude-501/u4logs/`. Each exit status was read directly from the build command.

### What moved

The moved text is 590 lines of `precompile.zig`, from the doc comment of `max_import_depth` to the end of `analyzeImportedFunction`. A plain `diff` of the old text against the new file body shows only the `pub` changes listed below plus one added comment line. The new file adds a 4-line module doc and imports of `std`, `builtin`, `zts`, and `zts.parser` (alias `ir`). It adds its own `readFilePosix` alias.

Moved symbols: `max_import_depth`, `ImportStack`, `ImportReader`, `ImportedFile`, `FlowModuleGraph`, `loadFlowModulesForCheck`, `ImportedFunctionAnalysis`, `ImportedFunctionAnalyses`, `collectImportedAnalyses`, `importBindingKey`, `importedFunctionNode`, `ImportedFaultScan`, `resolveCheckImportPath`, `isRelativeSpecifier`, `collectImportedFailableCalls`, `importedFileDisplay`, `scanImportedFileTree`, `analyzeImportedFunction`.

`precompile.zig` keeps its own `readFilePosix` alias, because five other call sites in that file use it. This is a small deviation from the plan, which said to move `readFilePosix`. The parent re-exports `ImportReader`, `FlowModuleGraph`, and `loadFlowModulesForCheck` as `pub`. It imports `max_import_depth`, `ImportedFile`, `collectImportedFailableCalls`, and `resolveCheckImportPath` as private aliases for its own code and tests. `precompile.ImportReader` stays a public path.

### Visibility changes

| Symbol | Before | After | Reason |
|---|---|---|---|
| `max_import_depth` | private | `pub` | Parent tests use it. |
| `ImportedFile` | private | `pub` | Parent tests build one. |
| `ImportedFile.load` | private | `pub` | Parent tests call it. |
| `ImportedFile.deinit` | private | `pub` | Parent tests call it. |
| `ImportedFaultScan` | private | `pub` | It is the return type of the `pub` function below. |
| `ImportedFaultScan.deinit` | private | `pub` | Parent production code calls it. |
| `collectImportedFailableCalls` | private | `pub` | Parent production code calls it at two sites. |
| `resolveCheckImportPath` | private | `pub` | Parent tests call it. |

`ImportReader`, `FlowModuleGraph`, `FlowModuleGraph.deinit`, and `loadFlowModulesForCheck` were already `pub`. I made no other symbol `pub`. The compiler accepted these and nothing more.

The one added line is an `// exhaustive:` comment above the `else => unreachable` arm in `resolveCheckImportPath`. The gate requires it.

### Test counts

| Step | Before | After |
|---|---|---|
| `zig build test-precompile` | 290 passed of 290 | 290 passed of 290 |

The moved range holds no `test` block, so no test moved. The count did not change. Log files: `before-test-precompile.log`, `g-test-precompile.log`. The sibling files `precompile_check.zig` and `precompile_args.zig` do not need a collection line for the new file, because it has no tests.

### Swallow gate

I staged the new file, then added it to `proof_files` (22 files). The first run (`b1-swallow.log`) exited 1 and listed 9 unreviewed catch sites. The silent-arm scan had one more site, which only shows after the catch scan passes. After the rows below and the `// exhaustive:` comment, the gate exits 0 with `22 files, 121 reviewed swallows, 104 reviewed silent arms, 0 unreviewed`. The baseline was `21 files, 112 reviewed swallows, 103 reviewed silent arms`.

New allowlist rows (all in `scripts/proof-swallow.allow`, file `precompile_imports.zig`):

| Function | Pattern | Why it cannot make an unproven program proven |
|---|---|---|
| `resolveCheckImportPath` | `catch-switch` | OutOfMemory propagates. The other arm traps on an error that needs a file extension, and the path has none here. A trap reports no verdict. |
| `analyzeImportedFunction` | `catch-switch` | `graph.load` failure other than OutOfMemory sets `complete = false` and returns a `.blocked` effect with no target. |
| `analyzeImportedFunction` | `catch-block`, `@2`, `@3` | The three type-check catches. See the analysis below. |
| `analyzeImportedFunction` | `catch-return`, `@2` | `effects.analyze` and `exportEffects` failure returns the default `.blocked` effect. |
| `at` | `catch-return` | Attributed to the nested helper `at` by the scanner. The site is in `scanImportedFileTree`. A file that fails to load returns a blocked fault entry. |
| `at` | `catch-switch` | Same attribution. OutOfMemory propagates and invalid IR returns a blocked fault entry. |

### Analysis of the three type-check catches

Observation. The three catches are the `initWithSource` catch, the `check` catch, and the `ensureHealthy` catch. Each sets `type_check_clean = false`.

What happens next, by code reading:
- `graph.complete = false`. The flow evaluator then records `module_graph_gap`. A non-zero unresolved count clears every flow property (`FlowChecker.unresolvedCount` doc comment).
- `finishModule` does not run and no flow target is set.
- Every relative import of the file gets a `.blocked` effect before the effect analysis runs.
- `EffectAnalyzer` runs with `type_source = .omitted`.

`type_source` reaches `self.type_env`. In `effect_inference.zig`, `type_env` is read at exactly one place: `contributeDeclaredCallbackRow`. It starts with `self.type_env orelse return false`. Without a type environment the function returns false, and the caller sets `row.lower_bound = true`. With a type environment, the function adds the declared callback row and leaves `lower_bound` clear. A grep over the file found no other read of `type_env` or `type_source` apart from `analyze`, which only calls `validate()`.

Conclusion. The untyped result differs from the typed result in one way. It is a lower-bound row, and it misses the declared callback capabilities. The importer then merges that row through `mergeImportedEffect`. That function merges the full `incomplete` row (every capability, impure, non-deterministic, writes, egress, lower bound) whenever the supplied row has `lower_bound`. The untyped result is therefore not weaker than the typed result. The rows are justified. I found no defect here.

Limit of this evidence. It comes from reading the code. I did not run a probe that forces each of the three catches. The existing tests that cover the type-failure path are in `precompile.zig` (the `!graph.complete` assertions and the nested-read-order tests). They pass.

One observation that is not a defect. The two `catch return result` sites also swallow OutOfMemory as a `.blocked` effect. Other sites in the same function propagate OutOfMemory. The swallow is conservative, so it needs no fix for the gate.

### Step 5: catches in the rest of `precompile.zig`

I ran the gate's catch scan against `precompile.zig` without adding the file to `proof_files`. The scan reports 63 sites outside the moved range. The plan expected 72 minus 9, which is 63. The scan skips `test` blocks. I added no rows. The classification:

| Function | Sites | Class | Can it weaken a verdict? |
|---|---|---|---|
| `runCompileWithArgs` | 16 | 13 propagate an error or map it to a named error. 2 are `MissingArgument` returns after argument parsing. 1 prints a failure to write the violations file. | No. The `MissingArgument` return emits no artifact. The violations-file write happens after `verify_failed`, and the function still returns `VerificationFailed`. |
| `runCheckOnlyWithOptions` | 3 | All return the original error or a structured error diagnostic with `parse_errors = 1`. | No. |
| `appendCheckAdmissionDiagnostic` | 1 | Drops one JSON diagnostic when append fails. | No. Both callers set `parse_errors` from the diagnostic count after the call. |
| `runCheckOnParsedSource` | 15 | 1 import-validation catch that returns `parse_errors = 1`. 1 catch-switch (OutOfMemory sets `parse_errors = 1`, others return the error). 3 parse-error catches and JSON appends that set `parse_errors` after. 5 JSON appends that drop a record on OutOfMemory. 4 formatter writes to stderr. 1 unsupported-extension append. | No. Each count (`bool_errors`, `type_errors`, `strict_errors`, `verify_errors`, `flow_errors`, `flow_unresolved`) is set from the checker before the append. `totalErrors` reads the counts. The one consumer of the list length, in `packages/pi/src/aggregate_proof.zig`, returns the original error when the list is empty. |
| `runGenTests` | 4 | 1 read failure (returns the error). 2 parse failures (return `ParseError`). 1 `catch null`. | See the next paragraph. |
| `compileHandler` | 14 | 3 propagate or refuse (parse, recorder check, serialization). 6 formatter writes to stderr. 1 `gen.generate(hf) catch {}` on the verification-failure path. 2 violation-text catches on the failure path and 2 on the success path. | No. The `gen.generate` catch only enriches counterexamples before `verify_failed = true` is returned. The violation text on the success path is printed and does not set `verify_failed`. `recorder.check` failure refuses the certificate. |
| `compileMultiModule` | 4 | All return the error. | No. |
| `projectCompletedFlow` | 1 | One formatter write to stderr. | No. The counts are printed separately and the properties come from `completed.getProperties()`. |
| `validateSqlContractNative` | 2 | Both return an error. | No. |
| `enforcePolicyForContract` | 1 | One formatter write to stderr. | No. The function returns `PolicyViolation` right after. |
| `appendPolicyDiagnostics` | 1 | A policy parse failure appends an error diagnostic and adds to `policy_errors`. | No. |
| `read` (test helper `TracingImportReader`) | 1 | Frees the copy and returns the error. | No. It is test code. |

`runGenTests` `catch null`. A failure to build effect facts falls back to `.unavailable`. In `path_generator.zig`, `.unavailable` sets `reaches_recursion = true` for the handler. That blocks the fault-covered result. The test `"unavailable effect facts conservatively report recursion"` pins this. The command only writes a starter test fixture, so no verdict depends on it. The fallback moves toward unproven.

Limit. This is a classification from reading each block. No probe forced any of the 63 catches.

### Documents

| File | Change |
|---|---|
| `docs/decisions.md` | D-006 `Binds` line now names `packages/tools/src/precompile_imports.zig`. |
| `docs/solutions/security-issues/a-missing-import-entry-was-conservative-for-one-proof-and-clean-for-another.md` | Three lines named `precompile.zig` for moved functions. They now name `precompile_imports.zig`. One line says `collectImportedFnSummaries` is now `collectImportedAnalyses`. |
| `AGENTS.md` | Not edited. The Testing Guidelines paragraph still says "the twenty-one listed" files. The list now holds 22. This is outside the U4 scope, so I left it for the lead. |

### Gates

Logs are under `/private/tmp/claude-501/u4logs/`. The final run used the files `g-<step>.log`, taken after the last source edit. I ran the doc edits and `check-spine` again inside that run.

| Gate | Exit | Result |
|---|---|---|
| `zig fmt --check` on `precompile.zig` and `precompile_imports.zig` | 0 | not logged |
| `zig build test-precompile` | 0 | 4/4 steps, 290/290 tests |
| `zig build test-proof-swallow` | 0 | 22 files, 121 reviewed swallows, 104 reviewed silent arms, 0 unreviewed |
| `zig build test-diagnostic-corpus` | 0 | 6/6 steps, 308/308 tests |
| `zig build test-flow-census` | 0 | 6/6 steps, 290/290 tests |
| `zig build test-contract-golden` | 0 | 8/8 steps |
| `zig build test-script-reachability` | 0 | 4/4 steps |
| `zig build test-module-boundary` | 0 | 2/2 steps, no row added |
| `zig build test-runtime-purity` | 0 | 8/8 steps |
| `zig build test-docs-drift` | 0 | 3/3 steps |
| `zig build test-zts-layering` | 0 | 3/3 steps |
| `zig build check-spine` | 0 | 4/4 steps |
| `zig build test-doc-links` | 0 | 2/2 steps |
| `zig build test-cli` | 0 | 5/5 steps. It builds the runtime consumer `proofs_cli.zig` and `pr_gate.zig`, which use `precompile.ImportReader`. |
| `zig build test` | 0 | 200/200 steps, 9206/9212 tests (6 skipped), the same totals as the end of U3 |

The first `test-proof-swallow` run exited 1 as intended (`b1-swallow.log`). It proves the gate sees the new file. I did not run `bash scripts/verify.sh`. The plan assigns that run to the lead.

### U4 lead verification

The lead reviewed the move, the re-exports, and each allowlist reason. The lead confirmed that `effect_inference.zig` reads the type environment only in `contributeDeclaredCallbackRow`, and that its caller sets `row.lower_bound = true` when the function returns false. The lead also updated the file count in `AGENTS.md` from twenty-one to twenty-two.

With a fresh private cache in `/private/tmp/claude-501/verify-u4/`, `zig fmt --check`, `test-precompile`, `test-proof-swallow`, `test-diagnostic-corpus`, `test-flow-census`, `test-contract-golden`, `test-script-reachability`, `test-module-boundary`, `test-runtime-purity`, `test-docs-drift`, `test-doc-links`, `test-cli`, `check-spine`, and `zig build test` each exited 0. The aggregate reported 200/200 steps and 9206/9212 tests passed, with 6 skipped.

## Final gate

`bash scripts/verify.sh` exited 0 and ended with \"verify.sh: all per-commit gates passed\". The log is `/private/tmp/claude-501/verify-u4/verify.log`. This run covers U1 to U4.
