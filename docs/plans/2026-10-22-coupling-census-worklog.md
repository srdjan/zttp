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
