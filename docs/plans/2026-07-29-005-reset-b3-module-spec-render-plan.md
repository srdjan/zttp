# Reset B3 Implementation Plan: generate the module specs from the bindings

**Status:** planned, not started.

**Source:** section 5 of `docs/plans/2026-07-29-002-reset-b-design.md`. B1
(`2026-07-29-003`) and B2 (`2026-07-29-004`) are done, B2 at commit `2075264b`.

**Goal:** Make the typed Zig module bindings authoritative for the 24 JSON module specs, and
generate the JSON from them with a `--check` drift gate. Stop hand-editing generated data.

**Ground truth:** measured at commit `2075264b` on 2026-07-29.

## 1. Two corrections to the design doc

### 1.1 The schema is richer than section 5.1 says

Section 5.1 describes each spec as carrying `schemaVersion`, `specifier`, `source`,
`requiredCapabilities`, and `exports[{name, effect, returns}]`. Measured across all 24 files
and their 90 exports, the export objects also carry:

| Export field | Count | Zig source |
| --- | --- | --- |
| `name` | 90 | `FunctionBinding.name` |
| `effect` | 90 | `FunctionBinding.effect` |
| `returns` | 90 | `FunctionBinding.returns` |
| `failureSeverity` | 23 | `FunctionBinding.failure_severity` |
| `contractExtractions` | 28 | `FunctionBinding.contract_extractions` |
| `laws` | 27 | `FunctionBinding.laws` |
| `params` | 6 | `FunctionBinding.param_types` |

This matters because byte-identity is the acceptance test. A renderer that emits only the
three fields section 5.1 names would fail on 24 of 24 files.

### 1.2 `source` already has a binding-side home

Section 5.2 says `source` "is the one field with no binding-side home" and proposes
resolving it from the module-to-path registry. It is already a literal field.
`builtin_modules.zig:93-118` declares `builtin_governance_entries`, 24 entries of
`BuiltinGovernanceEntry{ specifier, module_path, spec_path }`. `module_path` is exactly the
`source` value, and `spec_path` is the output path. A `comptime` block at `:121-131`
already gates that table against `builtins` for count and specifier drift.

So B3 adds no new mapping and no new hand-maintained field. It iterates
`builtin_governance_entries` alongside `builtins` and writes each rendered document to that
entry's `spec_path`.

## 2. The exact output contract

Byte-identity is the gate, so the renderer's formatting rules are requirements, not taste.
All of the following were read off the committed files.

Document shape: two-space indent, `": "` after every key, one array element per line even
when the array holds one element, and a trailing newline. Top-level key order is
`schemaVersion`, `specifier`, `source`, `requiredCapabilities`, `exports`. All five appear in
all 24 files. `schemaVersion` is always `1`.

Export key order is `name`, `effect`, `returns`, then the optional fields.

Omission rules, each derived from the committed data rather than from the Zig defaults:

| Field | Rule |
| --- | --- |
| `requiredCapabilities` | always emitted, `[]` when empty |
| `effect` | always emitted, including at the Zig default `.read` |
| `returns` | always emitted, including at the Zig default `.unknown` |
| `failureSeverity` | omitted when `.none` |
| `contractExtractions` | omitted when empty |
| `laws` | omitted when empty |
| `params` | omitted when empty |
| `argPosition` inside an extraction | omitted when `0` |
| `transform` inside an extraction | omitted when null |
| `flag_only` inside an extraction | never emitted |

That last row is the important one. The JSON is a deliberately lossy projection of
`ContractExtraction`: `flag_only` exists in Zig and appears in no spec file. The renderer
emits today's subset exactly. Widening the projection is a separate decision with its own
byte-identity cost, not something to slip in here.

Laws serialize in two shapes, matching `Law`'s void and payload variants:

```json
"laws": [ "pure" ]
"laws": [ "idempotent_call" ]
"laws": [ { "inverseOf": "base64Decode" } ]
"laws": [ { "absorbing": { "argPosition": 0, "argumentShape": "empty_string_literal", "residue": "result_err" } } ]
```

Note the casing split: JSON keys are camelCase (`argPosition`, `argumentShape`, `inverseOf`)
while enum VALUES stay snake_case (`empty_string_literal`, `result_err`, `idempotent_call`,
`optional_string`). Getting this backwards on either side breaks every affected file.

**One ambiguity the data cannot settle.** `params` appears only in `net/websocket.json`, on
six exports, none of which also carry `failureSeverity`, `contractExtractions`, or `laws`.
The relative order of `params` against those three is therefore undetermined by the
committed files. The renderer emits `params` immediately after `returns`, which matches
`websocket.json` and is consistent with the `FunctionBinding` field order. The first binding
that carries both will be the first real test of that choice.

## 3. Risks

### 3.1 The committed files may already have drifted

The design doc's acceptance is "output byte-identical to the 24 committed files on first
run". That assumes the hand-edited JSON currently agrees with the Zig bindings. Nothing has
been enforcing that: `scripts/check-docs-drift.sh` cross-checks the registry against the
docs and the spec COUNT, not the spec CONTENT. Twenty-four hand-edited files with a
count-only tripwire is exactly the shape that accumulates silent drift.

So Task 1 measures the drift before any renderer exists, read-only. If a file disagrees with
its binding, each divergence gets classified:

- JSON stale, Zig right: the regenerated file is correct and the golden moves. Legitimate,
  but it must be listed and reviewed field by field, never bulk-accepted.
- Zig wrong, JSON right: a real binding defect that the hand-edited file was compensating
  for. Fix the Zig, and say so.

Either way the design doc's "byte-identical on first run" gets amended to what was actually
true. Forcing byte-identity by teaching the renderer to reproduce a stale file would make
the generator lie, which defeats the point of making the bindings authoritative.

**Measured: 22 of the 24 files had drifted.** See section 6. The acceptance test therefore
changes shape, and this is the amendment section 5.3 of the design doc needs:

- The renderer must be correct field by field against the BINDINGS, proven per field so a
  divergence names the field rather than the file. That is Task 2's unit tests.
- `data/cache.json` and `data/sql.json`, the only two files whose sole drift is `params`,
  must match the rendered output exactly once `params` is stripped. See finding 6: they are
  not byte-identical outright, and no file is. Stripped, they are still the only evidence
  that comes from a file no generator wrote, and they cover formatting, key order,
  capabilities, `contractExtractions` with an omitted `argPosition`, `failureSeverity`, and a
  bare-string law.
- Every other file's diff must be reviewed field by field and match the four findings in
  section 6 exactly. A diff line that no finding predicts means the renderer is wrong, not
  that the file was stale.

The last rule is what keeps this honest. Regenerating 22 files is only safe because the
expected change was enumerated BEFORE the renderer existed.

### 3.2 Existing consumers must not change behavior

`packages/tools/src/module_audit.zig` and `packages/zts/src/manifest_registry.zig` read
these files. Neither may change what it accepts. `scripts/check-docs-drift.sh` keeps its
module section; per section 8 of the design doc, deleting it is out of scope. Its role
changes from catching hand-edit drift to proving the generator ran.

## 4. Tasks

### Task 1: measure the drift, write nothing

**Goal:** know whether the 24 committed files agree with the bindings today.

Build a throwaway comparison, in the scratch directory rather than the repository: for each
of the 24 entries, project the binding into the schema of section 2 and diff it against the
committed file, field by field, ignoring formatting.

**Verify:** a divergence table, one row per disagreeing field, each classified as "JSON
stale" or "Zig wrong" with the reason.

**Commit:** the findings, into section 6 of this plan. No source change.

### Task 2: add the renderer

**Goal:** `packages/zts/src/module_spec_render.zig`, mirroring `semantics_render.zig`. A
pure function from a binding plus its governance entry to a rendered document. No filesystem
access in the renderer: the CLI owns I/O, which is what keeps the analyzer wasm-safe.

Suggested surface, kept to what the CLI needs:

```zig
/// Render one module's spec JSON. Caller owns the result.
pub fn renderModuleSpec(
    allocator: std.mem.Allocator,
    binding: module_binding.ModuleBinding,
    source_path: []const u8,
) ![]u8
```

**Verify:** unit tests asserting the rendered output equals the committed bytes for a
representative spread, chosen to cover every optional field and both law shapes:
`workflow/io.json` (minimal, capabilities non-empty), `security/validate.json`
(`failureSeverity`, `contractExtractions`, `laws`), `net/websocket.json` (`params`),
`security/crypto.json` (`inverseOf` both directions), `security/auth.json` (`absorbing`),
and one with `requiredCapabilities: []`. These tests read the committed files, so they are
the byte-identity gate at unit granularity, which reports WHICH field diverges rather than
just that a file differs.

**Commit:** `feat(modules): render the module spec JSON from the bindings`.

### Task 3: wire the CLI verb and the check mode

**Goal:** a `module-spec-render` verb reachable as both `zts` and `zttp`, with `--check`,
following `semantics_cli.zig:40-85`.

Unlike `spec-render`, this handles 24 files, so:

- default: write every entry's document to its `spec_path`.
- `--check`: read each committed file, compare, and report EVERY stale path before exiting
  non-zero. A gate that names one file when four are stale wastes a full cycle per file.
- absent or unreadable file is a failure, not a skip. B1's lesson: a gate that silently
  passes when its input is missing is worse than no gate.

Register it under "Machine tools" in `help --all`, matching how the other generated-spec
verbs are listed.

**Verify:** `module-spec-render --check` exits 0 against the committed tree. Run it, then
mutate one byte of one spec file, confirm it exits non-zero and names that file, then restore.
A `--check` that has never been observed failing is not known to work.

**Commit:** `feat(cli): add module-spec-render with a drift gate`.

### Task 4: put the gate in the verify script

**Goal:** `scripts/verify.sh` runs `module-spec-render --check`.

Only after Task 3 shows byte-identity across all 24. This is the design doc's explicit
sequencing in section 5.3, and it is the right order: a gate added before the generator is
proven pins whatever the generator happens to emit.

**Verify:** `bash scripts/verify.sh > /tmp/v.txt 2>&1; echo "EXIT=$?"` reports `EXIT=0`.
Read the recorded code, not a tail of the log.

**Commit:** `ci(verify): gate the module specs against the bindings`.

### Task 5: record what B3 cost

**Commit:** `docs(plans): record what the B3 generator cost`.

## 5. What must not change

- What `module_audit.zig` and `manifest_registry.zig` accept.
- The module section of `scripts/check-docs-drift.sh`.
- Any `ModuleBinding` or `FunctionBinding` field, unless Task 1 finds a genuine Zig defect,
  which lands as its own commit.
- The lossy projection: no spec file gains a field in B3.

## 6. Findings

To be filled in during execution.

Measured by dumping every binding as canonical JSON from a throwaway test and diffing
against the committed files field by field, ignoring formatting. The dump had no formatting
contract, so it could not be tuned to reproduce a stale file.

**The headline: 22 of 24 files have drifted, so byte-identity on first run is not
achievable.** Section 5.3 of the design doc and section 3.1 of this plan both assumed it
might be. It is not, and the reason is that the drift is the JSON having LOST data the
bindings carry.

Good news first, because it bounds the risk: `effect`, `returns`, `failureSeverity`,
`requiredCapabilities`, and the export set and its order agree in 24 of 24 files, on all 90
exports. Every semantically load-bearing field is already in sync. The drift is confined to
four things.

| # | Finding | Direction | Resolution |
| --- | --- | --- | --- |
| 1 | `param_types` is declared on 84 of 90 exports, and only `net/websocket.json` records it. 22 files lost the data entirely | JSON stale, Zig right. No functional effect: nothing loads these files at runtime, the bindings are already authoritative for behavior | Emit `params` whenever `param_types` is non-empty. The alternative, dropping websocket's six, discards real data and would leave the builtin specs strictly less informative than the partner manifests that describe the same shape: `module_manifest.zig:262` accepts and validates `params` on the partner path. 22 files gain the field |
| 2 | `security/decode.json` omits `laws: ["pure"]` on all four exports, which the bindings declare | JSON stale, Zig right | Regenerate. One file |
| 3 | `workflow/workflow.json` omits the `contractExtractions` entry `{category: workflow_call}` that `workflow.call` declares | JSON stale, Zig right. This one is worth naming: `contractExtractions` is the field that drives contract extraction, so the spec was describing a module as extracting nothing while the binding extracted a workflow call | Regenerate. One file |
| 4 | The committed files are internally inconsistent about `argPosition`. 23 extractions omit it, 5 write `argPosition: 0` explicitly, and 2 write `argPosition: 1`. Since 0 is the Zig default, the 5 explicit zeros are redundant | neither side wrong, the convention was never settled | Emit when non-zero, omit when 0, which is what 23 of 30 already do. Three files lose a redundant key. Confirms the omission rule stated in section 2 and refutes nothing else there |
| 5 | `net/fetch.json` orders extraction keys `argPosition, category, transform` while `workflow/durable.json` uses `category, argPosition`. A second unsettled convention, found while reading the exact layout for the renderer | neither side wrong | One canonical order in the renderer: `category`, `argPosition`, `transform` |
| 7 | `net/websocket.json` wrote `params` inline on one line (`"params": ["object", "string"]`) while every other array in every one of the 24 files is expanded one element per line. Found only after regeneration, as a diff line no earlier finding predicted | neither side wrong, a third unsettled convention | Expanded, consistent with every other array. This is the one diff line the pre-generator enumeration missed, which is exactly why the plan required reviewing unpredicted lines instead of bulk-accepting the diff: it was a real inconsistency rather than a renderer bug, but the rule is what surfaced it |
| 6 | Correction to my own first measurement. It reported `data/cache.json` and `data/sql.json` as "already identical"; they are not, because they gain `params` like the other 22. What is true, and what the renderer's tests now assert, is that those two are the only files whose ONLY drift is `params` | - | They are still the byte-identity evidence, compared with `params` stripped. Every other formatting decision - indentation, key order, non-empty capabilities, an extraction with an omitted `argPosition`, `failureSeverity`, a bare-string law - is checked against a file no generator wrote. Zero files come out byte-identical, so the section 3.1 amendment stands with this correction |

## 7. Measurements

To be filled in during execution.

| Measurement | Value |
| --- | --- |
| Spec files byte-identical on first generator run | |
| Files needing regeneration, and why | |
| `bash scripts/verify.sh` | |

## 8. Done when

- The 24 spec files are generated from the bindings, and the generator is the only thing
  that writes them.
- `module-spec-render --check` is in `scripts/verify.sh` and has been observed to fail on a
  deliberate mutation.
- Any file whose bytes changed is listed in section 6 with the reason.
- `bash scripts/verify.sh` exits 0 and `zig fmt --check` is clean.
- Sections 6 and 7 are filled in.

That closes wave 4 item 0b and Reset B.
