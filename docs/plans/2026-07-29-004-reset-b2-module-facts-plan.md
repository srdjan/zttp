# Reset B2 Implementation Plan: the ModuleFacts index

**Status:** planned, not started.

**Source:** section 4 of `docs/plans/2026-07-29-002-reset-b-design.md`. B1
(`docs/plans/2026-07-29-003-reset-b1-runtime-codec-plan.md`) is done at commit `9a795f90`.

**Goal:** Move the one genuinely re-derivable part of `ContractBuilder` into an immutable
index built once, and make `ContractBuilder` read it instead of deriving it. Nothing else
about the builder changes.

**Ground truth:** every line number below was measured at commit `9a795f90` on 2026-07-29.
B1 did not touch `packages/zts/src/contract_builder.zig`, so the numbers the design doc
recorded at `51a8f6d8` still hold.

## 1. What moves and what does not

`scanImports` (`contract_builder.zig:1136-1235`) is the only traversal in the builder that
is a pure function of the import declarations and the module binding registry. It populates
four fields:

| Field | Declared | Type declared | Written only in |
| --- | --- | --- | --- |
| `generic_bindings` | `:94` | `:181` | `scanImports` (`:1183`) |
| `extension_bindings` | `:140` | `:192` | `scanImports` (`:1194`) |
| `modules_list` | `:97` | `[]const u8` items | `scanImports` (`:1155`) |
| `functions_map` | `:98` | `HandlerContract.FunctionEntry` | `scanImports` (`:1225`) |

No production code outside `scanImports` appends to any of the four. That was verified by
listing every reference: the remaining sites are reads at `:1110`, `:1280`, `:1319`,
`:1375`, `:1650`, `:1812`, `:3264`, `:3850`, `:4047`, `:4068`, `:4158`, `:4161`, plus the
move into the contract at `:441-442` and the clear at `:551-552`. The two appends at
`:4272` and the assertions from `:4912` onward are tests.

The other four traversals are untouched. `scanCallSites` (`:1240`), `walkScopeDepth`
(`:1682`), `walkWorkflowBlock` (`:1923`), and `scanFunctionNodeForApiFacts` (`:3136`) keep
their own order and their own accumulators. Section 5.5 of the reset plan is right about
them and section 2 of the B2 design records why.

## 2. Two decisions that must be made before the first edit

### 2.1 Ownership: the index keeps its lists, the contract gets copies

Today `build()` moves `modules_list` and `functions_map` into the `HandlerContract`
(`:441-442`) and then sets both to `.empty` (`:551-552`) so `deinit` does not double-free.

A move is a mutation of the index. It would also leave the facts unusable after `build()`,
which defeats the whole point of an index the other six consumers can share. So
`ModuleFacts` keeps ownership and `build()` copies the two lists into the contract.

The cost is one new allocation per compile: a dupe of the module list and of each module's
name list, both bounded by the number of imported virtual modules. That is a handful of
short strings. It is recorded here rather than discovered later, and it is the only
behavior-visible cost B2 adds.

`generic_bindings` and `extension_bindings` are already never moved, so they need nothing.

### 2.2 Borrowed extraction rules stay borrowed

`GenericBinding.extractions` points into the comptime tables reached through
`builtin_modules.findExport`. `ExtensionBinding.extractions` points into the live
`ManifestRegistry`. Neither is copied today and neither is copied in B2, so the registry
must outlive the facts exactly as it must outlive the builder now
(`contract_builder.zig:89-91`, `:189-191`). The "all strings in the contract are owned"
invariant at `:80-81` is unchanged, because the strings that enter the contract are still
duped at the point they enter it.

## 3. Tasks

### Task 1: pin the four fields against the goldens

**Goal:** know that the four contract goldens actually cover the index before changing how
the index is built, and settle one ordering question.

`zig build test-contract-golden` exits 0 at `9a795f90`. That is the baseline. The step is
part of `zig build test` (`build.zig:759`) and checks seven fixtures, four of which are the
contract goldens named in section 4.4 of the design doc.

The ordering question is already settled, during planning rather than during execution,
because the answer changes what Task 3 is allowed to do. Both late readers of the two moved
lists run before the move at `:551`:

- `detectRateLimiting` (`:4157`, reads `:4158` and `:4161`) is called at `:377`.
- `computeGlobalEffectSummary` (`:3847`, reads `functions_map` at `:3850`) is reached
  through `computeProperties` (`:4093`) and `computeEffectSummary` (`:3835`), and
  `computeProperties` is called at `:374`.

So no site reads an emptied list today. Had one existed, B2 would have silently fixed it and
the goldens would have moved bytes for a reason unrelated to the refactor, which would have
destroyed the acceptance test. That fix would have had to land as its own commit with its own
golden update before Task 2.

One check remains: confirm the four goldens actually observe the index. Findings 2 and 3
below record the answer, and it is not the one section 4.4 of the design doc assumes.

`modules_list` reaches the goldens as `virtual_modules` (`json_diagnostics.zig:379` and
`:463`), in list order, so a reordering there does move bytes. But only two of the four
goldens carry any modules: `modules_all` has five, order-pinned as
`zttp:auth, zttp:env, zttp:validate, zttp:cache, zttp:crypto`, and `durable_approval` has
one. `plain_ts` and `jsx` both emit `[]` and are blind to the index entirely.

`functions_map` never reaches the goldens. `json_diagnostics.zig` has no `functions` field.

The two binding lists are observed only indirectly, through the facts `scanCallSites`
derives while consuming them: `env_vars`, `outbound_hosts`, seven of the seventeen
`properties` fields, `proofTrace`, `declared_specs`, `proofCapsules`, `effectCapsules`, and
`witnesses`.

**Consequence for the rest of this plan.** The goldens remain the integration gate and the
`modules_list` ordering gate. They are not a sufficient gate. Breaking the merge or the
dedup in `functions_map` moves no golden byte, so the unit tests named in Task 2 are the
only thing standing there and must be written before Task 3 deletes anything. This is the
same discipline B1 used: build the evidence, then delete.

**Verify:** `zig build test-contract-golden` exits 0 at `9a795f90`. Confirmed.

**Commit:** none. This task produces no diff.

### Task 2: add `ModuleFacts` beside the builder, not inside it

**Goal:** a new `packages/zts/src/module_facts.zig` holding the index, with `scanImports`
transcribed into it. `ContractBuilder` still derives its own copy. Nothing consumes the new
file yet except its own tests.

A new file, not a new type inside `contract_builder.zig`, because the six later consumers
(`path_generator`, `handler_verifier`, `strict_checker`, `flow_checker`,
`effect_inference`, `bool_checker`) must be able to import the index without importing a
5,000-line builder they do not use.

`GenericBinding` (`:181`) and `ExtensionBinding` (`:192`) are currently file-private `const`
declarations nested in `ContractBuilder`. They move to `module_facts.zig` as `pub const`.

Construction signature:

```zig
pub fn build(
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*context.AtomTable,
    registry: ?*const manifest_registry_mod.Registry,
) !ModuleFacts
```

Those four are exactly what `scanImports` reads. It does not read `type_env` or
`type_checker`, which is the evidence that the index is pure in the imports and the reason
this part is separable while the other four traversals are not.

**The body is a transcription, not a rewrite.** Golden byte-identity depends on three
orderings that `scanImports` produces incidentally:

- `modules_list` is in first-appearance node order, deduplicated by `containsString`
  (`:1152`).
- `functions_map` is in first-appearance module order, merged by module string (`:1208`).
- each entry's `names` is in specifier order, deduplicated, with the duplicate freed
  (`:1211-1214`).

Any reordering moves bytes in the goldens. Copy the loop; do not improve it.

`resolveAtomName` (`:2442-2452`) is needed and reads only `self.atoms`, so it moves to
`module_facts.zig` as a private helper taking the optional table. `containsString` is a
free function in `contract_builder.zig` and is needed too; the plan duplicates it in
`module_facts.zig` rather than exporting it, because it is four lines and exporting it
creates an import edge from the new file back to the builder, which is the edge Task 2
exists to avoid.

**On the API for the other six.** The design doc says the API is shaped so they can adopt
it. Shaped, not populated: B2 adds only the accessors `ContractBuilder` uses. Adding
accessors with no caller is the speculative generality the project rules forbid. What B2
does commit to is the data shape those six need, which is the flat per-import record
(module specifier, imported name, local slot) plus slot-keyed lookup, because all six run
the same skeleton today:

| File | Import scan |
| --- | --- |
| `path_generator.zig` | `:487-495`, `:1716-1720` |
| `handler_verifier.zig` | `:558-581` |
| `strict_checker.zig` | `:906-910` |
| `flow_checker.zig` | `:664-672` |
| `effect_inference.zig` | `:200-204` |
| `bool_checker.zig` | `:1637-1646` |

If the shape is right, their migration in wave 4 item 4 adds accessors and does not reshape
the index.

`deinit` frees the module strings, the function entry modules and names, and the two
binding lists, mirroring `contract_builder.zig:250-251` and `:285-292`.

**Verify:** `zig build test-zts` green. New unit tests in `module_facts.zig` covering a
builtin import, a partner import through a registry, an unknown module that is skipped, two
imports of the same module merging into one entry, and a duplicate name being freed rather
than appended. `zig build test-contract-golden` still exits 0, trivially, because nothing
consumes the file.

**Commit:** `feat(contract): add the ModuleFacts import index`.

### Task 3: make `ContractBuilder` read the index

**Goal:** delete `scanImports` from the builder and read `ModuleFacts` instead. This is the
task the goldens gate.

Edits:

- `ContractBuilder` gains `facts: ModuleFacts` and loses the four fields.
- `build()` replaces `try self.scanImports()` (`:334`) with the facts construction, using
  the `ir_view`, `atoms`, and `manifest_registry` it already holds.
- The twelve read sites listed in section 1 change to read through `self.facts`.
- `:441-442` copies instead of moving. `:551-552` loses the two `.empty` assignments,
  because there is no longer a move to undo.
- `deinit` loses the four blocks at `:250-251` and `:285-292` and gains
  `self.facts.deinit()`.
- `GenericBinding` and `ExtensionBinding` become aliases to the `module_facts` types, or
  the references change to the qualified names. Prefer the aliases: fewer touched lines,
  and the deletion stays legible in the diff.
- The seven tests that call `builder.scanImports()` (`:4912`, `:4972`, `:5012`, `:5063`,
  `:5105`, `:5136`, `:5322`) build a `ModuleFacts` and assert on it. The test at `:4272`
  that appends to `functions_map` constructs the facts it needs instead.

**Verify:**

- `zig build test-contract-golden` exits 0 with all four contract goldens byte-identical.
  This is the acceptance gate from section 4.4 of the design. A single moved byte means the
  change is wrong.
- `bash scripts/verify.sh > /tmp/v.txt 2>&1; echo "EXIT=$?"` reports `EXIT=0`. Read the
  recorded code, not a tail of the log.
- `zig fmt --check build.zig packages/`.
- `zig build bench-check`, run separately, because `test` compiles the bench binaries
  without running them. Note that `intArithmetic` trips the per-benchmark 8 percent gate
  intermittently on this machine on an unmodified tree; B1 measured four passing runs at
  1.14 to 2.88 percent geomean against one failure. Judge on geomean and on whether the
  diff touches any interpreter, value, GC, or bytecode file. B2 touches none.
- `grep -c "fn scanImports" packages/zts/src/contract_builder.zig` returns 0.

**Commit:** `refactor(contract): read imports through one immutable index`.

### Task 4: correct section 5.6 of the reset plan

**Goal:** stop the reset plan from asking for something its own section 5.5 rejects.

The sentence to replace is the last one of section 5.6
(`docs/plans/2026-07-28-001-reset-simplification-plan.md:260-280`):

> The same principle applies to contract construction on the producing side, where
> `ContractBuilder` accumulates facts through repeated mutable scans; one immutable
> `ModuleFacts` index built once from parsed and checked source, with pure projections for
> routes, effects, capabilities, workflows, and proof data, replaces both the seven scans
> and the accumulation.

Section 5.5, twenty lines earlier, says "The right fix is not one grand unified visitor.
The passes have genuinely different traversal orders and state." The replacement records
the index-only reading and the measurement behind it: one of the five scans is a pure
function of the imports and is the one duplicated across six other files; the other four
carry their own order and state, and merging them is the unified visitor 5.5 rejects.

**Verify:** prose only. `bash scripts/check-docs-drift.sh` if it covers the plans directory.

**Commit:** `docs(plans): correct 5.6 to the index-only reading`.

### Task 5: record what B2 cost

**Goal:** fill in sections 5 and 6 below with what actually happened, as B1 did.

**Commit:** `docs(plans): record what the B2 index cost`.

## 4. What must not change

- The four other traversals, in order or in state.
- Any of the six other import scanners. Their migration is wave 4 item 4 and is out of
  scope per section 8 of the design doc.
- The bytes of any of the seven fixtures in `contract_golden_step` (`build.zig:600-618`).
- The "all strings in the contract are owned" invariant.
- `scripts/update-contract-goldens.sh` must not be run. If a golden moves, the refactor is
  wrong; regenerating hides the evidence.

## 5. Findings

To be filled in during execution. One row per divergence between the transcribed index and
`scanImports`, with the direction and the resolution, as B1 recorded its six.

| # | Finding | Direction | Resolution |
| --- | --- | --- | --- |
| 1 | Both late readers of the moved lists (`detectRateLimiting` at `:377`, `computeProperties` at `:374`) run before the move at `:551`, so no site reads an emptied list | none, no defect | Settled during planning. Task 1 no longer needs the check, and Task 3 must keep both call sites where they are |
| 2 | The four contract goldens cover the index only partly. `modules_list` is emitted as `virtual_modules` (`json_diagnostics.zig:379`, `:463`) in order, but only `modules_all` (five modules, order-pinned) and `durable_approval` (one) carry any: `plain_ts` and `jsx` both emit `[]`. `functions_map` is never emitted at all. The two binding lists are covered only indirectly, through what `scanCallSites` derives using them | the gate is weaker than "all four goldens, one byte" reads | Goldens stay the integration gate but are not sufficient. Direct unit assertions on `functions_map` order, merge, and dedup are load-bearing in Task 2, not belt-and-braces. Section 4.4 of the design doc overstates the gate; this row is the correction |
| 3 | `contract_json_writer.zig:105` writes a `functions` object into contract.json, but `contract_json_parser.zig` never parses the key. Same lossy-codec family as B1 finding 5, which was the identical gap for `modules` | write-only wire field, not a live defect: no production code reads `HandlerContract.functions` back from the wire | Reported, not fixed. Out of B2 scope. The consequence for B2 is concrete: a writer round-trip cannot serve as the `functions_map` gate, which is why finding 2 falls to unit tests |

## 6. Measurements

To be filled in during execution.

| Measurement | Before | After |
| --- | --- | --- |
| `contract_builder.zig` lines | | |
| Four contract goldens | byte-identical baseline at `9a795f90` | |
| `zig build bench-check` geomean | | |

## 7. Done when

- `ModuleFacts` exists in its own file, is built once per compile, and is not mutated after
  construction.
- `scanImports` no longer exists in `contract_builder.zig`.
- All four contract goldens are byte-identical.
- `bash scripts/verify.sh` exits 0 and `zig fmt --check` is clean.
- No file outside `packages/zts/src/contract_builder.zig`,
  `packages/zts/src/module_facts.zig`, and the two plan documents is edited, unless Task 1
  finds the `computeGlobalEffectSummary` ordering defect, which lands separately.
- Sections 5 and 6 are filled in.

Then write the B3 plan for descriptor generation, per section 5 of the design doc.
