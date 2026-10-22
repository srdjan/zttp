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
