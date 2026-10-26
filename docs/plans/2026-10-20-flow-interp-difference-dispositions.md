# Flow interpreter differential dispositions

Status: review ledger for expanded report 03, 2026-10-20. This records semantic
directions and remaining implementation work; it does not approve production
cutover, rewrite goldens, or exempt any row from the differential gate.

## Evidence and authority

The native `flow-shadow-diff --census --diagnostic-corpus --codegen` executable
exited 1. Its report is `/tmp/zttp-flow-shadow-expanded-03.jsonl`, SHA256
`3ff26b153b2f05763b4c53a4b22333bf1951b6571cdc04f445e5bb315ca22884`.
It ran on the working tree based on `1c24eaf2`, after the context/scalar fixes
and the owner's weather correction, before the constructive-evidence batch.
Later reports must be reconciled with this snapshot rather than silently
replacing its counts.

The report contains 1,024 cases, 4,952 property rows, 222 changed verdicts,
1,054 unmatched flow-diagnostic occurrences, 345 unresolved observations,
zero source errors, and 112 explicit pre-flow/non-handler cases. The frozen
floor is 48 handlers / 214 required bits, plus 38 P0 fixtures and four clean
contrasts. All 734 census inputs, 182 diagnostic sources, and 29 active
codegen descriptors were counted: 18 codegen handler roots and 11 explicit
workspaces without a handler.

The [redesign](2026-10-18-flow-checker-sound-redesign-plan.md), especially
P0/P1/P8/P9 and revised R1–R16, supplies the operational claim and fixed P0
expectations. The [P6 specification](2026-10-20-flow-interp-p6-spec.md) supplies
the accepted D24 sink matrix. The [P7 specification](2026-10-20-flow-interp-p7-spec.md)
requires source, witness and defended-path compatibility. The
hardening plan's owner resolution (`pre-reset-archive-2026-10-25:docs/plans/2026-10-20-hardening-pruning-plan.md`, section "Owner resolution of the weather precision conflict")
supersedes only the two weather expectations, reducing 216 historical bits
to 214. It preserves `input_validated` and keeps recorded generations immutable.

Verdict notation below: **S** = `no_secret_leakage`, **C** =
`no_credential_leakage`, **V** = `input_validated`, **P** = `pii_contained`,
**I** = `injection_safe`; **T** = `PROVEN`, **U** = `UNPROVEN`, **R** =
`REFUSED`. Only changed properties are listed. A design-supported direction
still requires the named behavior/evidence checks before P9 can pass.

| Report group | Changed rows | Cases with changes | Ledger section |
|---|---:|---:|---|
| P0 | 24 | 24 | A |
| Census: old depth/parameter caps | 170 | 42 | B |
| Census: resolved record callable | 5 | 1 | C |
| Census: strict PII policy | 2 | 2 | D |
| Frozen precision | 7 | 3 | E |
| Actual codegen | 3 | 1 | F |
| Diagnostic corpus | 11 | 3 | G |
| **Total** | **222** | **76** | Each row belongs to exactly one section |

A read-only tuple census expanded the literal tables/rules below and compared
`(group, case, property, production, shadow)` with every changed property row
in report 03: 222 unique expected tuples, 222 unique observed tuples, zero
missing and zero uncovered. Sections A and B contribute 24 exact fixture names
and 21 exact prefix pairs; C–G enumerate the remaining named cases.

## A. Permanent false-proof corrections: 24 rows

Source: [flow_false_proofs.zig](../../packages/tools/src/flow_false_proofs.zig).
Each named fixture has exactly the listed changed property, **T → R**.
P0/R8 already require it to be refused or unproven. These are required security
corrections, not regressions to preserve and not new policy choices. Restoring
constructive witnesses remains a separate P7 obligation; this table does not
establish that each new diagnostic already has one.

| Exact fixture | Property | Mechanism |
|---|---|---|
| `branch_assign_raw_then` | I | Join both branch states |
| `branch_assign_raw_initial` | I | Preserve the raw alternative |
| `loop_carried_scalar` | I | Ascending loop state |
| `push_in_initializer` | I | Observe initializer heap writes |
| `push_in_if_condition` | I | Observe condition heap writes |
| `alias_variable_push` | I | Shared array origin |
| `alias_object_field_push` | I | Nested shared origin |
| `alias_callback_array_param` | I | Callback receiver alias |
| `iterated_array_write_foreach_html` | I | Callback heap fixpoint |
| `iterated_array_write_some_html` | I | Callback heap fixpoint |
| `unescape_after_escape_html` | I | P6 removes the HTML defense |
| `ternary_selected_request_credential` | C | Request contents survive selection |
| `request_popped_from_array_credential` | C | Request contents survive container extraction |
| `headers_object_to_json_credential` | C | Serialization reads authorization cells |
| `iterated_array_write_foreach_log` | S | Callback heap fixpoint |
| `iterated_array_write_literal_receiver` | S | Receiver writes survive iteration |
| `reduce_logs_secret_accumulator` | S | Accumulator carries earlier values |
| `dict_map_values_logs_secret` | S | Module callback argument/result edges |
| `dict_fold_logs_secret` | S | Module callback accumulator edges |
| `helper_in_if_condition_logs_secret` | S | Evaluate condition callees |
| `callback_selected_by_ternary` | S | Evaluate every possible callable |
| `assert_message_secret_in_handler` | S | Assertion message is a root response |
| `assert_message_secret_in_helper` | S | Assertion completion reaches caller |
| `array_from_callback_logs_secret` | S | String-source callback provenance |

## B. Resolve the legacy caps: 170 rows

Source: [flow_census_probes.zig](../../packages/tools/src/flow_census_probes.zig),
templates `t_chain9` and `t_param9`. For **each** exact prefix in this table,
the cases are `PREFIX__chain9` and `PREFIX__param9`. Both have exactly the
listed changed properties, all starting at **U**. This is a closed list of
42 case names, not a wildcard exception for future cases.

The legacy walk stops after eight helper levels or parameters. The bounded
interpreter reaches the ninth level/parameter, preserving argument provenance,
callee effects and clean returns. R3/R6 and the P4/P8 call model support the
new precision: a forbidden sink becomes R; a property with no corresponding
forbidden source/event becomes T. The existing census explicitly permits an
improved proof past the old cap (`hold_or_unprove`). A call that still cannot
be resolved must stay U; none of these report rows is unresolved.

| Exact prefix | U → T properties | U → R properties | Rows, both suffixes |
|---|---|---|---:|
| `secret__log` | C, V, P, I | S | 10 |
| `secret__egress_url` | C, V, P, I | S | 10 |
| `secret__egress_body` | C, V, P, I | S | 10 |
| `secret__egress_headers` | C, V, P, I | S | 10 |
| `secret__egress_opaque` | C, V, P, I | S | 10 |
| `secret__response` | C, V, P, I | — | 8 |
| `secret__response_html` | C, V, P, I | — | 8 |
| `credential__log` | S, V, P, I | C | 10 |
| `credential__egress_url` | S | C, I | 6 |
| `credential__egress_body` | S | C, I | 6 |
| `credential__egress_headers` | S | C, I | 6 |
| `credential__egress_opaque` | S | C, I | 6 |
| `credential__response` | S, V, P, I | — | 8 |
| `credential__response_html` | S, V, P | I | 8 |
| `user_input__log` | S, C, V, P, I | — | 10 |
| `user_input__egress_url` | S, C | I | 6 |
| `user_input__egress_body` | S, C | I | 6 |
| `user_input__egress_headers` | S, C | I | 6 |
| `user_input__egress_opaque` | S, C | I | 6 |
| `user_input__response` | S, C, V, P, I | — | 10 |
| `user_input__response_html` | S, C, V, P | I | 10 |
| **Total** | | | **170** |

These are design-supported precision improvements, subject to bounded-context,
operation-edge and constructive-refusal tests. No counterexample or diagnostic
may be invented merely because the old result was U.

## C. Returned record callable: 5 rows

In the same census source, exact case `x22_returned_record_method_discarded`:
**S: U → R; C,V,P,I: U → T**. `makeOps()` returns a record containing a
closure; calling its `run` field logs the secret even though its scalar result
is discarded. P4/P8 full callable values and heap effects remove the legacy
resolution gap. The census expects S to be refused or unproven, so the new
refusal is required semantic direction; the four clean neighboring properties
are supported precision improvements. Retain method/capture and witness tests.

## D. Validated egress is still PII egress: 2 rows

In the same census source, exact cases `x04_validate_in_helper_egress` and
`x05_validate_in_handler_egress`: **P: T → U**, one row each.
`validateJson` plus `JSON.stringify` establishes/preserves schema evidence for
the body, so the claimed I property remains T. D24 expressly permits no
defense for exposed data at any PII egress sink. These two unproven PII results
are approved strict-policy consequences, not schema regressions. Do not make
validation erase provenance to recover the old P proof.

## E. Frozen precision: 7 rows

| Exact source | Changed properties | Disposition |
|---|---|---|
| [examples/fetch/webhook.ts](../../examples/fetch/webhook.ts) | S,C: U → T (2) | Supported precision: static non-authorization header access retains only its own field; `fetch`/response readers use the declared `.external` result, rather than laundering or inheriting unrelated request heap cells. Outbound input checks remain. The binding at `packages/modules/src/net/fetch.zig` declares the response's source; these new proofs still need the corresponding source/alias contrasts. |
| [examples/handler/sugar.ts](../../examples/handler/sugar.ts) | S,C: U → T (2) | Supported precision: literal numbers/strings, local arithmetic and array callbacks introduce neither secret nor credential input. Fully resolved calls replace the old blanket unknown state. |
| [frozen weather-egress](../../packages/tools/tests/fixtures/flow_precision/corpus/weather-egress/handler.ts) | P: T → U; I: T → R (2) | **Owner-approved strict-policy correction.** The two claims/expectations were removed; schema validation is neither PII containment nor a URL/query injection defense. |
| Same frozen weather source | V: T → U (1) | **Pending implementation regression.** V remains a frozen requirement. Recover only genuine heap-bound validator evidence with mutation/alias invalidation; do not weaken the requirement or turn schema checking into a URL injection defense. |

The R16 rules permit new proofs on previously unrequired bits, with a written
reason. They do not authorize eliminating the remaining weather requirement.

## F. Actual recorded weather generation: 3 rows

Descriptor: `packages/pi/src/simulator/testdata/empirical/deepseek/codegen/weather-egress/case.json`.
Source: `packages/pi/src/simulator/testdata/empirical/deepseek/codegen/weather-egress/generations/36a5ae0cb70ac19536009d7128f19156c14131f154c20a460551928961477139/expected/handler.ts`.

| Changed property | Disposition |
|---|---|
| P: T → U | Same approved strict policy as E; the recorded promise is obsolete. |
| I: T → R | Same approved strict policy as E; the recorded promise is obsolete. |
| V: T → U | Same pending validator-evidence regression as E. |

The active recording stays immutable. Its stale P/I promise requires a
deliberate recording after the cutover; editing the content-addressed expected
workspace to make replay green is not a disposition.

## G. Diagnostic sources: 11 rows

| Exact source | Changed properties | Disposition |
|---|---|---|
| [dict_entry_round_trip.ts](../../tests/corpus/check/bad/dict_entry_round_trip.ts) | V,P,I: T → U (3) | Fail-closed direction is allowed for unsupported calls (R3/R15), but **P9 remains blocked** by missing transfer precision and repeated unresolved observations. The `bad` directory is not an exemption: this source reaches the flow stage. |
| Same dictionary source | C: U → R (1) | **Pending over-refusal/evidence defect.** The source builds literal dictionaries and returns boolean/literal fields; it does not read request credentials. Unknown provenance can justify U, not an established credential counterexample. Trace and fix the invented/merged credential path rather than accepting a new warning on this basis. |
| [dict_entries_reduce.ts](../../tests/corpus/check/bad/dict_entries_reduce.ts) | S,C: U → T (2) | Supported precision: literal dictionary entries and a numeric reduction have no secret/credential source. Preserve callback and `Result` payload edges; the existing deterministic/advisory diagnostics are independent. |
| [effect_row_lower_bound.ts](../../tests/corpus/check/bad/effect_row_lower_bound.ts) | S,C,V,P,I: U → T (5) | Supported flow precision: a returned record's known closure hashes a constant and returns its scalar string. This does **not** authorize removing the existing ZTS512 effect-row diagnostic or granting a capability/effect budget; those are separate analyses. |

All 345 unresolved observations belong to `dict_entry_round_trip.ts`:
342 `unknown_callee/call`, three `no_operation_rule/call`. These are repeated
evaluation observations, not 345 unique source sites. Their owner/tag/node
records remain visible; no budget, source or diagnostic exclusion is approved.

## Diagnostic compatibility work

The comparator retains code, severity, full message/help, file, line/column,
byte span and repair intent, preserving duplicate occurrences. The counts below
classify unmatched occurrences by `(group, case, code)` after exact matches are
removed. A text or location pair contributes two occurrences. This table is a
work classification, not a replacement comparator or an allowlist.

| Group/category | Case-code groups | Unmatched occurrences | Required disposition/work |
|---|---:|---:|---|
| Census, text changed | 284 | 568 | Restore supported call-origin help. Example `credential__egress_body__apply_cb` retains ZTS407/ZTS408 text/location but drops `(reached through the call at line 11, column 18)`. Do not delete that context merely to equalize counts. |
| Census, location changed | 34 | 68 | Preserve truthful sink and callsite locations. Example `credential__response_html__apply_cb`, ZTS407: old 11:69, new 11:15. Explain any intentional corrected origin; never substitute an unrelated node. |
| Census, count changed | 76 | 228 | Review event multiplicity and field separation. Egress-header cases can lose an old spurious body warning while keeping the real header warning. Distinguish that from suppressing a real second event or counting fixpoint visits as distinct runtime sinks. |
| Census, old-only leftovers | 114 | 114 | Includes ZTS400/401 route leftovers and ZTS406/407/408 body leftovers. Some are stale helper/duplicate/body-at-header observations. Check retained real events per case before approval; a removed leftover does not mean that the corresponding code is entirely absent from the new report. |
| Census, new-only leftovers | 41 | 41 | New real refusals from B/C, including formerly capped callees. Semantic direction is supported; source and constructive witness obligations remain. |
| P0, new-only leftovers | 24 | 24 | The required corrections in A; construct valid witnesses without inventing a path from a joined state. |
| P0, old-only leftovers | 2 | 2 | `fetch_with_retry_secret_in_url` loses extra ZTS406 body evidence; `status_from_secret_length_in_route` loses an old ZTS400 location. Confirm real URL/root-status refusal remains and describe corrected location/multiplicity. |
| Frozen precision, new-only | 1 | 1 | Weather ZTS407 URL/query warning under owner-approved strict policy. |
| Frozen precision, old-only | 1 | 1 | `examples/fetch/weather-app.ts:120:25` loses an extra body ZTS407. Its identical URL/query ZTS407 and raw-input sink event remain on both sides: supported field-precision cleanup, not a missing query sink. |
| Codegen, new-only | 1 | 1 | Same strict weather warning; do not rewrite the recorded generation. |
| Diagnostic corpus, new-only | 1 | 3 | Three ZTS401 warnings on `dict_entry_round_trip.ts` at 7:42, 9:43 and 11:25. Pending defect from G; they are not proven credential counterexamples. |
| Diagnostic corpus, old-only | 3 | 3 | Extra body ZTS407/ZTS408 in `credential_in_egress_headers.ts`, and ZTS406 in `secret_in_egress_headers.ts`. Preserve real header events and review exact golden deltas deliberately. |
| **Total** | **582** | **1,054** | Exact comparison remains failing |

Witnesses, defended paths and contained-secret evidence are not covered by
these 1,054 diagnostic-field comparisons. Report 03 precedes the evidence
batch; copying its green property bits is not evidence of an executable
counterexample. P7/P9 still require constructive candidates to satisfy every
path constraint, truthful source/I/O provenance, supported defended paths,
and preserved public contract/golden behavior.

## Remaining decisions and completion

No additional policy choice is needed to resolve these 222 verdict differences:
the strict matrix and the owner's weather correction decide the semantic
changes; the remaining weather V miss and dictionary over-refusal need fixes.
The diagnostic location/help/multiplicity changes still need exact compatibility
implementation or an explicit reviewed reason for a truthful correction.
They are not silently approved by this ledger.

Re-run the exact default and expanded native modes after fixes, reconcile every
new or vanished row, and retain the original corpus floors except the recorded
owner-approved 214-bit correction. Then run the operation/tag, persistence,
example, production diagnostic/contract, and full repository gates. Only P9
acceptance authorizes production dispatch/version/policy-pin changes. Recording
and publication remain separate deliberate operations.

## Follow-up reconciliation: report 04

The schema-evidence checkpoint was evaluated separately using the same expanded
command and floors. `/tmp/zttp-flow-shadow-expanded-04.jsonl`, SHA256
`2fd5e2e3138e027b5fd1fba4576d26cb985cfdcc61ae4eecde0124cb62c83ba1`,
still exits 1, with 1,024 cases / 4,952 rows, zero expectation misses, zero
source errors, 112 not-applicable cases, 345 unresolved observations, 220
verdict differences, and 1,052 unmatched diagnostic occurrences.

The entire verdict delta from report 03 is confined to the two weather sources
in E/F. Both recover V to T, removing their two V differences. Both change I
from R to U: the input has genuine schema evidence, so the raw/unvalidated URL
warning disappears, while strict policy still provides no injection defense.
P stays U. Those two I rows remain differences from the old T result; their
updated disposition is approved strict-policy non-proof rather than a witnessed
refusal. The original recorded source remains unchanged.

All other 218 changed tuples from report 03 are identical. The validator miss
is resolved in this report; the dictionary unresolved/credential problem,
diagnostic compatibility, constructive evidence and production cutover gates
remain open. Neither zero frozen misses nor this reconciliation is a P9 pass.

## Follow-up reconciliation: report 05

The P7c checkpoint's expanded report is
`/tmp/zttp-flow-shadow-expanded-05.jsonl`, SHA256
`691f35be126eb01c291cd24fa063897adc590758c6388449b5f24a7afd110a80`.
It exits 1 with the same 1,024 cases / 4,952 rows and all 214 required precision
bits, 38 P0 cases and four contrasts satisfied. It has zero expectation misses,
zero unresolved observations, zero source errors, 112 not-applicable cases,
218 verdict differences and 1,049 unmatched diagnostic occurrences.

The entire verdict delta from report 04 is
`check/bad/dict_entry_round_trip.ts`. V/P/I recover to T, removing three
differences. C changes from old U / shadow R to old U / shadow T. S changes
from old U / shadow U to old U / shadow T. The two remaining changed properties
are supported literal-dictionary precision, like `dict_entries_reduce.ts`:
the source has no secret or credential source. All other 216 changed tuples
from report 04 are identical. Together with the weather reconciliation above,
this accounts for every report-05 tuple without an exemption.

| Group | Changed rows | Cases with changes |
|---|---:|---:|
| Census | 177 | 45 |
| P0 | 24 | 24 |
| Frozen precision | 6 | 3 |
| Actual codegen | 2 | 1 |
| Diagnostic corpus | 9 | 3 |
| **Total** | **218** | **76** |

Three unsupported Dict ZTS401 occurrences at 7:42, 9:43 and 11:25 disappear.
Thirty-six existing shadow occurrences in 28 imported census cases gain
`(in MODULE:LINE:COLUMN)` help, preserving their other fields. Those cases
are the closed product of `secret`/`credential`, the five sinks `log`,
`egress_url`, `egress_body`, `egress_headers`, `egress_opaque`, and suffixes
`import2`/`import_fn`, plus `user_input` with the four egress sinks and those
two suffixes. The remaining 1,013 unmatched occurrence tuples are identical
between runs after replacing only the generated scratch-directory prefix for
this cross-run reconciliation. The actual diagnostic comparator still uses
exact fields and duplicate counts within each run. Imported-source help is
now inspectable; its public compatibility still needs deliberate review.

The implementation owner reported that the unfiltered `zig build test-zts`
P7c core-04 checkpoint exited 0. That establishes the component regressions,
including initializer/sibling I/O order, branch constraints, uncertain
selection, and replay-pure handling. Report 05 predates the runner's explicit
witness/card serialization. It therefore establishes neither actual replay
success nor witness/card compatibility. The remaining diagnostic differences,
evidence comparison, public golden checks and repository gates still apply;
this checkpoint is not P9 acceptance.

## Local v7 checkpoint: report 06

After local production activation, the pinned Zig 0.16 command
`zig build flow-shadow-diff -j2 -- --census --diagnostic-corpus --codegen`
exited 0. Its separate artifact is `/tmp/zttp-flow-shadow-expanded-06.jsonl`,
SHA256 `9391b171290347aa8554b312f724e1dec322bc85e7bd13993a956adc3b6a742b`.
Report 05 remains unchanged at its recorded SHA256 above.

The v7 production path and the directly invoked interpreter agree on every
verdict and exact flow diagnostic. This is a same-engine integration check,
not independent evidence of semantic correctness. The fixed expectations were
checked separately: 48 frozen handlers / 214 required proven bits, all 38 P0
cases (33 refused, five unproven), four proven clean contrasts, 1,024 cases /
4,952 rows, zero expectation misses, zero source errors and zero unresolved
observations. The inventory retains all 734 census inputs, 182 diagnostic
sources and 29 codegen descriptors (18 handlers / 11 no-handler records), with
112 explicit flow-not-applicable inputs.

For the independent historical comparison, every report-06 shadow tuple
`(group, case name, property, shadow verdict)` was compared with report 05's
**shadow** column. Each report has 4,952 unique case/property keys. There are
zero added, removed or changed tuples. Thus the 218 semantic differences from
the old production engine retain their report-05 dispositions; activation has
not hidden a new shadow verdict change behind same-engine agreement.

The new raw evidence records expose the following inventory:

| Evidence surface | Count |
|---|---:|
| Analyzed cases / public proof traces | 912 |
| Public property-evidence projections | 4,560 |
| Shadow diagnostics / witness-presence records | 646 |
| Diagnostics carrying raw witness and solver candidate | 101 |
| Diagnostics with no raw witness | 545 |
| Candidate properties: injection / secret / credential | 98 / 2 / 1 |
| Raw candidate I/O calls / branch constraints | 88 / 1 |
| Shadow defended paths | 707 |
| Defended paths: never reached / validated | 697 / 10 |
| Named guards: escapeHtml / validateJson / validateObject | 2 / 4 / 4 |
| Public counterexample / resisted cards | 645 / 705 |

All 101 canonical candidate replay JSONL strings parse. Each preserves its
solver request and the raw ordered call count, module/function identities,
sequence numbers and JSON stub results. Every candidate explicitly records
`runtime_replay: "not_run"`. These checks establish serialization consistency,
not execution of the sink or success of a replay-pure transform.

The public counterexample count must not be confused with raw witness support.
`proof_trace.flowCounterexample` currently substitutes empty constraints and
I/O when `Diagnostic.witness` is absent, then synthesizes the public request
card. Joining public cards to raw witnesses by case/property finds 101 with
raw support and 544 without it. Accordingly, 645 public counterexample cards
do not establish 645 constructive witnesses. Raw absence is visible rather
than treated as valid evidence. The card multiplicities also differ from raw defended-path records
because the public trace selects per-property evidence. Runtime replay,
evidence compatibility, public golden checks, recording/publication and the
remaining full repository gates retain their own acceptance obligations.

## Public evidence correction: report 07

The same expanded command exited 0 after the public proof-trace correction.
`/tmp/zttp-flow-shadow-expanded-07.jsonl` has SHA256
`e84658834133e5cdfe6f111f8bcb39fd4aa6a3f7efa88b5c6b23b4c466b57b71`.
The immutable report-05 shadow comparison still contains exactly the same
4,952 unique case/property verdicts: zero additions, removals or changes.
The independently checked floors remain 48 handlers / 214 required proven
bits, 38 P0 cases (33 refused / five unproven), four proven contrasts and
1,024 cases / 4,952 rows. Expectation misses, source errors and unresolved
observations are all zero. Current production/interpreter verdict and exact
diagnostic agreement remains a same-engine integration check.

The raw inventory is unchanged: 646 shadow diagnostics, 101 witness capsules
and solver candidates, and 545 diagnostics with no capsule. Public
counterexample cards now number **101**, all matched to a raw witness by
case/property. Unsupported public cards fall from report 06's **544 to zero**.
The producer omits a counterexample when its executable-path capsule is
absent, rechecks every retained constraint against the solver candidate, and
prefers a supported capsule when another sink for the property lacks one.
It no longer invents a default request card from an absent witness.

The public containment narrative is also scoped to the particular property:
secret/credential containment names response, log and egress sinks;
input-validation/PII containment names external egress; injection containment
names HTML and governed external egress. A validated card without a named
guard is omitted. Counts remain 707 raw defended paths (697 never reached /
10 validated) and 705 public resisted cards; unchanged counts do not imply
unchanged narrative text.

All 101 candidate JSONL encodings again preserve their request and ordered
I/O schema, and all explicitly say `runtime_replay: "not_run"`. Capsule/card
presence and constraint satisfaction do not establish that runtime replay
executes the sink, or that replay-pure transforms accept synthetic stub data.
This report captures the core/public-projection correction before the pending
CHECK extensionless-selector checkpoint; later evidence must use a distinct
artifact and keep the historical reports intact.

## Selector and refreshed-input checkpoint: report 08

After the owner-approved CHECK `.ts` selector change and the fresh 13-case
DeepSeek recording, the expanded command exited 0.
`/tmp/zttp-flow-shadow-expanded-08.jsonl` has SHA256
`ba9451d14aaf4b9b1c6164948fc05f466fd8ed8acda9bc51a671893e0c9934e8`.
The independent floors still pass: 48 handlers / 214 required proven bits,
38 P0 cases (33 refused / five unproven), four proven contrasts and 1,024
cases / 4,952 unique property rows. Expectation misses, source errors and
unresolved observations are zero. Production/direct-interpreter agreement
also has zero verdict or exact diagnostic differences; it remains a
same-engine integration check.

All 13 DeepSeek descriptors now select new generations. Source snapshots are
therefore compared separately from outcome changes. Seven analyzed source
graphs differ from report 05, all in these DeepSeek codegen cases:
`egress-options`, `health`, `jwt-auth`, `sibling-helper`, `sql-users`,
`validate-body`, and `weather-egress`. The other six new DeepSeek generations
contain identical analyzed source bytes despite different recording identities.
The old generation files and report artifacts remain unchanged.

Across the 905 unchanged analyzed cases, all retained module/source SHA256
identities agree with report 05, ignoring only generated directory names.
The 112 pre-flow diagnostic cases also retain their source files unchanged
from report 05's base `1c24eaf2`; their no-verdict observations are checked
separately because that report has no flow-module SHA record for them.
The resulting unchanged-source comparison covers 4,917 property rows, with
zero added, removed or changed shadow outcomes. The 35 rows from the seven
revised codegen sources are classified as changed inputs. Their verdicts
happen to be identical too; this is not evidence that the revised source
has identical semantics. The full source-revision census is retained at
`/tmp/zttp-shadow-input-revisions-05-08.json`.

Evidence counts remain 646 shadow diagnostics, 101 raw witness capsules /
solver candidates, 101 matching public counterexample cards and zero public
cards without raw support. There are 707 raw defended paths and 705 public
resisted cards. Every candidate still says `runtime_replay: "not_run"`.
Neither same-engine agreement nor unchanged counts establish runtime witness
validity. The refreshed empirical replay, coverage measurement/publication
and full repository gates remain separately accountable.
