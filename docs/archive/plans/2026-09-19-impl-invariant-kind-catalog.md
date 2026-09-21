# Invariant Kind Catalog Implementation Plan

Archive status, reviewed 2026-09-21: Implemented. Delivery from `d571a6ed`
through `0df4e7f2` closed the selected units and added rejection probes. The
full gate subsequently passed at `9be65e0d`, as recorded in the bounded
rederive record. The original checklist below is historical, not pending work.
Current work status is in [Roadmap](../../roadmap.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow the accepted invariant catalog from one closed template to a closed, gated set of kinds over the protected ledger, adding `declared_accounts_v1` end to end.

**Architecture:** The kernel gains per-kind metadata and a versioned tagged payload set beside the existing v1 bytes. The native adapter publishes a dispatch-derived manifest of what it actually enforces; the runtime hashes that manifest with the kernel's encoder and feeds it to the artifact graph, so the checker compares a linked adapter against its own expectation instead of comparing a constant with itself. Authoring moves from Python to Zig commands that require explicit kind selection.

**Tech Stack:** Zig 0.16.0 stable, SQLite via the module SDK, the existing proof-checker acceptance kernel.

**Spec:** [docs/archive/plans/2026-09-18-feat-invariant-kind-catalog-plan.md](2026-09-18-feat-invariant-kind-catalog-plan.md). That document is the design and carries the reasoning; this one is its execution order. Executors read both.

**Plan location note:** this repository keeps plans in `docs/plans/`, so that convention is used instead of the skill default.

**Revision note:** this plan was validated against the tree and revised. Ten findings were applied, the most important being that the original Task 5 could have collapsed into comparing a constant with itself, and that three tasks named verification commands that never compile the file under test and would have reported a false PASS.

## Global Constraints

- No Python. Do not add a `.py` file or a `python3` invocation. Per `AGENTS.md`.
- All Zig. Native Zig error unions (`!T`) in engine and runtime code; `Result<T>` is a handler-facing construct only.
- `errdefer` on all allocations. `orelse` instead of `?` unwrap.
- Tests live beside code in `test "..."` blocks. Name them behaviourally.
- Work on local main. Commit complete isolated units. Do not push.
- Leave the pre-existing working-tree changes alone: the deletion of `docs/zts-advanced-v2.1.md`, `docs/zttp-next/`, and `proof-gate.md`.
- Do not record cassettes or drive the expert loop as part of this work.
- `scripts/verify.sh` and `zig build release` exceed the two-minute rule and need explicit approval. Every per-task command below is inside it.
- Measure, never estimate.
- Run `zig fmt` on every file touched.
- **Zig collects tests only from the root module.** A file reached through a named module is a different module and its tests do not run. Every task below names the build step that actually compiles the file under test. Do not substitute a step that merely sounds related.

## Verified facts

Confirmed by reading source and by measurement on 2026-09-19. Executors do not need to re-derive these.

| Fact | Location |
|---|---|
| `Kind = enum(u16) { balance_conservation_v1 = 1 }` | `packages/proof-checker/src/invariant.zig:35` |
| `adapter_identity` is a fixed string; `adapterDigest()` is bare `sha256` of it, with no domain prefix | `invariant.zig:137`, `:139` |
| `sha256("zttp:ledger/native-adapter-v1")` = `38190d83549a2f159b8c917b0a614856915358920ea73e831231a889db512c67` | measured |
| Graph adds adapter member from `pcc.invariant.adapterDigest()`; checker compares against the same function | `packages/runtime/src/artifact_graph.zig:252`, `checker.zig:437` |
| Both build and activation adapter paths live in the runtime package | `proof_certificate.zig:251`, `proof_activation.zig:98` |
| `digest()` prefixes `digest_domain = "zttp-invariant-spec-v1"` unconditionally | `invariant.zig:127` |
| Four callers of `digest()` | `checker.zig:425`, `handler_instance.zig:968`, `proof_activation.zig:116`, `proof_certificate.zig:246` |
| `spec_members != 1` refused | `checker.zig:464` |
| `invariant_operation_required` refuses only when certificate AND observed lists are both empty | `checker.zig:470` |
| `kind_bits: u8`, set by `1 << (kind - 1)` | `verdict.zig:323`, `checker.zig:479` |
| `InvariantVerdicts` is in-memory only; identity section is 193 fixed bytes with no kind field | `verdict.zig:314`, `certificate.zig:745` |
| Conservation enforced unconditionally, no kind selector | `packages/modules/src/data/ledger.zig:437` |
| Group hook `validateGroup`; state hook at per-account `next` | `ledger.zig:433`, `:303` |
| `BEGIN IMMEDIATE` in `executePost`; `BEGIN EXCLUSIVE` in `bootstrapOrValidate` | `ledger.zig:267`, `:181` |
| Baseline already scans every entry account and every balance account, and runs one content query per posting | `ledger.zig:614`, `:678`, `:626` |
| Baseline cross-check guarantees every historical entry account has a balances row | `ledger.zig:706` |
| `ledger_meta.invariant_digest` binds the store to the **spec** digest, not the adapter digest | `ledger.zig:16`, `:199` |
| Native config installed here | `handler_instance.zig:950` |
| `proofs/invariant_report.zig` is anchored from `cli_main.zig`, so it runs under `test-cli` | `cli_main.zig:39` |
| `invariant_drift_step` reaches tools tests only via the `test-project-config` root | `build.zig:470` |
| Gate step is forced to rerun by `has_side_effects = true` | `build.zig:266` |
| Existing gate probes mutate an **in-memory copy** and re-validate; they do not delete files | `scripts/check-invariants.sh:228` |
| Gate reads exactly fourteen named inputs | `check-invariants.sh:27` |
| Build depends on the Python self-test | `build.zig:267`, wired at `:271` |
| `zig build test` depends on `test-invariant-drift` | `build.zig:1194` |
| `docs/cli.md` is gated so a command cannot ship unlisted | `check-docs-drift.sh:202` |
| A new `host_test_roots` row requires a matching `docs/internals/testing.md` row | `check-docs-drift.sh:318` |
| The deleted Python script is described in three docs | `docs/user-guide.md:260`, `docs/internals/testing.md:267`, `docs/verification.md:351` |
| Measured at HEAD: `check-invariants.sh` passes in 0.06s; `zig build test-invariant-drift` passes, exit 0, about 11s warm | measured |

## Task order

U2, U1, U7, U3, U4, U5, U6, U8, which is Task 1 through Task 8. The gate is replaced before adapter changes invalidate its fixed-string checks. Do not reorder.

Each task ends with a commit and a checkpoint. Do not start the next task until the checkpoint passes.

## Interfaces pinned up front

Fixed here so tasks written by different people fit together.

**JSON document shapes.** Task 2 emits v1 unchanged from today's Python:

```json
{"version":1,"kind":"balance_conservation_v1","ledger":"main","currencies":[{"code":"USD","scale":2}]}
```

Task 4 defines v2, and Task 6 makes it reachable:

```json
{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],
 "kinds":[{"kind":"balance_conservation_v1"},
          {"kind":"declared_accounts_v1","accounts":[{"exact":"clearing:main"},{"prefix":"asset:"}]}]}
```

**CLI flags.** Task 2 adds `--kind` (repeatable, required). Task 6 adds `--account-exact` and `--account-prefix` (both repeatable). Version 2 is emitted when anything beyond conservation is selected.

---

### Task 1 (U2): Define kind metadata and pin the digests

**Files:**
- Modify: `packages/proof-checker/src/invariant.zig`

**Interfaces:**
- Produces: a `KindInfo` row type and a comptime table keyed by `Kind`, carrying wire ordinal, canonical description, predicate semantic version, required flag, and write-applicability flag, plus an accessor. Tasks 2, 4, 5, 6, 7 and 8 read this.

The kernel is import-free and stays a leaf. `test-proof-checker-purity` enforces it.

Pinning the digests happens here, before any codec change, because after Task 4 a "byte-identical v1 digest" check compares the new code against itself and proves nothing.

- [ ] **Step 1: Write the failing tests**

Every `Kind` has a non-empty description. Wire ordinals are unique. The table covers the enum exhaustively, written so a member added without a row fails to compile. A comptime assertion that every ordinal is below 32, which is what makes the Task 4 shift safe. Then the two pins: the v1 specification digest of the existing fixture (build the fixture bytes the way `invariant.zig:200` does and assert the hex literal), and `adapterDigest()` equals `38190d83549a2f159b8c917b0a614856915358920ea73e831231a889db512c67`.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-proof-checker`
Expected: FAIL, table not defined.

- [ ] **Step 3: Add the table with the single `balance_conservation_v1` row**

Required true, write-applicable true. The description is the sentence a developer confirms: the sum of signed balances is zero within each ledger and currency after every committed posting group.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-proof-checker && zig build test-proof-checker-purity`
Expected: PASS both.

- [ ] **Step 5: Commit**

```bash
git add packages/proof-checker/src/invariant.zig
git commit -m "feat(proof-checker): per-kind metadata and pinned v1 digests"
```

**Checkpoint:** add a throwaway enum member locally, confirm the exhaustiveness test fails to compile, then revert. A table test that passes on an incomplete table is the defect this task exists to prevent.

---

### Task 2 (U1): Replace Python authoring with Zig commands

**Files:**
- Create: `packages/tools/src/invariant_author.zig` (pure authoring logic)
- Modify: `packages/tools/src/project_config.zig` (re-export it, so its tests are collected)
- Modify: `packages/runtime/src/dev_cli.zig` (dispatch, commands table at `:498`), `cli_help.zig`, `cli_main.zig` (anchor the dispatch tests)
- Modify: `docs/cli.md`, `docs/user-guide.md:260`, `docs/internals/testing.md:267`, `docs/verification.md:351`
- Modify: `build.zig:267` and `:271`
- Delete: `scripts/invariant-author.py`

**Interfaces:**
- Consumes: Task 1's metadata table.
- Produces: `zttp invariant list` and `zttp invariant author`, under the Proof ledger category of `zttp help --all`.

**Test placement matters here and is easy to get wrong.** Pure authoring logic goes in `packages/tools/src/invariant_author.zig`, re-exported from `project_config.zig` so `test-project-config` collects it, which is also the root `invariant_drift_step` depends on (`build.zig:470`). Dispatch and help tests go in a runtime file anchored from `cli_main.zig` so `test-cli` collects them. Putting the tools tests where only `test-cli` runs means they never execute and the step reports PASS.

Four documents are not optional. `docs/cli.md` is gated at `check-docs-drift.sh:202` so a command cannot ship unlisted. A new `host_test_roots` row needs a matching `docs/internals/testing.md` row (`:318`). The other two still describe the script this task deletes.

The advisory transport is injected at the host tooling boundary, following the pure/host split in `packages/tools/src/smt_solver.zig`. The real `std.http` transport lives in the runtime dev CLI, where `runtime_http.zig` and `verify_cli.zig` already use it. The tools-side module stays pure with an injected transport. Confirm neither `zts_cli.zig` nor the wasm analyzer (`build.zig:935`) reaches it. Only the sentence and the public catalog criteria go in a request body; no source, ledger data or credential value enters model state or logs.

- [ ] **Step 1: Write the failing tests**

The load-bearing one first, because it is the shipped defect: a sentence such as "accounts cannot be overdrawn" with no `--kind` must not produce a conservation candidate. Then, in the tools-side file: list output names every supported kind with required status; missing selection errors; unknown kind errors with the supported list; candidate output is stable across runs; a candidate is distinct from an accepted specification; advisory unavailable, malformed and conflicting cases through a fake transport with no network call. In the runtime-side file: dispatch and help.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-project-config && zig build test-cli`
Expected: FAIL both.

- [ ] **Step 3: Implement the commands, the host module and the four doc updates**

Emit the sentence, the canonical descriptions shown for review, `requiresReview`, the advisory status, and the structured candidate. `reviewed_against` goes in the review output, outside the accepted candidate: it records which descriptions and versions were displayed, and asserts nothing about a person having read them. A legacy v1 `statement` stays readable as an annotation only.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-project-config && zig build test-cli && zig build test-docs-drift`
Expected: PASS all three.

- [ ] **Step 5: Remove the Python from the build, then delete the script**

Drop `invariant_author_test` at `build.zig:267` and its `dependOn` at `:271`, then `rm scripts/invariant-author.py`.

- [ ] **Step 6: Verify**

Run: `grep -n "invariant-author" build.zig` and expect no output.
Run: `zig build test-invariant-drift && zig build test-docs-drift`
Expected: PASS both. The gate still runs its own Python body here; Task 3 removes that.

- [ ] **Step 7: Commit**

```bash
git add packages/tools/src packages/runtime/src docs build.zig
git rm scripts/invariant-author.py
git commit -m "feat(cli): zttp invariant list/author in Zig, drop the Python tool"
```

**Checkpoint:** run the author command by hand with a sentence that does not describe conservation and no `--kind`, and confirm it refuses. Then confirm `zig build test` is green, since `build.zig:1194` makes it depend on the docs and invariant gates this task touches.

---

### Task 3 (U7): Replace and extend the drift gate

**Files:**
- Create: a host Zig gate command under `packages/tools/src/`
- Modify: `build.zig` (wire `test-invariant-drift`)
- Modify: `scripts/check-invariants.sh` (reduce to a wrapper, or delete if unreferenced)
- Modify: `docs/internals/testing.md` if a root is added

Preserve every existing check: compiler, operation catalog, native export and effect, observer, proof IR tag, adapter graph, documentation and compiled-test checks. Add checks for kind metadata and authoring output. **Do not narrow the gate to the new surfaces.** Dropping the existing checks to add four would lose operation-coverage protection.

**Pin intent, not literal strings.** The current gate pins the literal `pub const adapter_identity = "zttp:ledger/native-adapter-v1";` (`check-invariants.sh:196`) and the literal `pcc.invariant.adapterDigest()` in `artifact_graph.zig` (`:200`). Task 5 deliberately changes both. Port these as intent checks (the adapter member is bound from the native manifest; the kernel holds an expected manifest) so Task 5 does not break the gate it just rewrote.

**Probes mutate in memory.** The existing gate copies its sources into a dict, mutates one location, and re-validates (`check-invariants.sh:228`). Deleting a file on disk instead would break the compile of the proof-checker, modules, zts, project-config and runtime suites that `test-invariant-drift` depends on, so the nonzero exit would come from the compiler and prove nothing about the gate.

Parsing strategy: import the surface where the surface is data (the kernel catalog and kind table through `zttp_proof_checker`; the native binding through the curated `zts.builtinModules` at `root.zig:663`, which avoids a `tools modules` row in `scripts/module-boundary.allow`). Text-scan only the code surfaces. There is no regex in Zig, so in-memory probes mutate the text-scanned side or a test copy of an imported table.

- [ ] **Step 1: Write the failing tests**

One in-memory mutation probe per independent input, including the new authoring and build-wiring inputs, run on every invocation. Missing, empty or unparsed input fails explicitly.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-invariant-drift`
Expected: FAIL, Zig gate not defined.

- [ ] **Step 3: Port the fourteen checks and the probes, add the two new checks**

Wire with `addRunArtifact` and `has_side_effects = true`. A Run step is cached on executable and args, not on files read at runtime, so without that flag the gate reports a cached pass after `docs/verification.md` changes. The gate computes the repo root itself.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift`
Expected: PASS.

- [ ] **Step 5: Prove the gate is not vacuous**

Invoke the gate binary directly with its probe flag, one input at a time, and read the exit status. Never route a probe through the aggregate step. Record the results in the commit message.

- [ ] **Step 6: Confirm no Python remains in this feature's build path**

Run: `grep -rn "python3" build.zig scripts/check-invariants.sh` and expect no output.

- [ ] **Step 7: Commit**

```bash
git add build.zig packages/tools/src scripts/check-invariants.sh docs/internals/testing.md
git commit -m "test(invariant): Zig drift gate replacing the Python body"
```

**Checkpoint:** the gate asserts at least as many independent inputs as the fourteen it replaced, every one has a passing in-memory probe, and the step reruns rather than caching after a docs-only edit. Verify the last by editing `docs/verification.md` trivially and confirming the step runs again.

---

### Task 4 (U3): Add the versioned payload set

**Files:**
- Modify: `packages/proof-checker/src/invariant.zig` (codec, `digest()`)
- Modify: `packages/tools/src/invariant_config.zig` (JSON side)
- Modify: `packages/proof-checker/src/verdict.zig:323`, `checker.zig:479`
- Modify: the Task 3 gate source and `docs/verification.md`

**Interfaces:**
- Consumes: Task 1's metadata table and pinned digests.
- Produces: schema 2 decoding beside the preserved v1 path, normalized to one internal view for Tasks 5 through 8. The v2 JSON shape is pinned above.

Keep the v1 decoder, its exact canonical bytes and its digest. Schema 2 carries common ledger and currency fields plus a sorted, length-delimited list of kind payloads. Conservation has no extra payload and stays mandatory in both schemas. Keep one specification graph member, so `checker.zig:464` is untouched.

**The digest trap.** `digest()` prefixes the v1 domain unconditionally (`invariant.zig:127`) and has four callers (`checker.zig:425`, `handler_instance.zig:968`, `proof_activation.zig:116`, `proof_certificate.zig:246`). Adding a separate v2 function and missing one caller makes every v2 artifact fail `invariant_spec_digest_mismatch` between build and activation, or opens a store under the wrong digest. Instead: keep one entry point, have `digest(bytes)` read the schema from `bytes[8..10]` and select the domain. A test asserts the v2 domain differs from `"zttp-invariant-spec-v1"`.

Widen `kind_bits` from `u8` to `u32`. This touches no serialized surface: `InvariantVerdicts` is in-memory (`verdict.zig:314`), the identity section is 193 fixed bytes with no kind field (`certificate.zig:745`), and the artifact and certificate version 4 formats are untouched.

- [ ] **Step 1: Write the failing tests**

The pinned v1 digest from Task 1 still passes. A v2 round-trip through encode, decode and acceptance. The v2 domain differs from v1. Then the refusals: duplicate kinds, unknown kinds, missing conservation, malformed lengths, trailing data, non-canonical record order, oversize specification. Test through public parsing and acceptance APIs.

Do not write a test for "an ordinal above the supported range reaching the shift". It cannot be reached through a public API: `decode` refuses ordinals outside `Kind` (`invariant.zig:86`) and `spec.kind` is the enum. Task 1's comptime assertion that every ordinal is below 32 is the real guard. Keep the `UnknownInvariantKind` test.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-proof-checker`
Expected: FAIL.

- [ ] **Step 3: Implement schema 2, the domain-selecting digest, and the widened mask**

Retain the bounded specification size and zero-copy decoding. Keep unsupported kinds rejected; Task 6 makes kind 2 supported.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-project-config && zig build test-invariant-drift`
Expected: PASS both.

- [ ] **Step 5: Commit**

```bash
git add packages/proof-checker/src packages/tools/src docs/verification.md
git commit -m "feat(invariant): schema 2 tagged payload set beside v1 bytes"
```

**Checkpoint:** the pinned v1 specification digest test from Task 1 still passes unchanged. That pin is the only thing that makes this checkpoint meaningful; comparing the new code's v1 output against the new code's v1 output would be a tautology.

---

### Task 5 (U4): Bind the linked adapter

**Files:**
- Modify: `packages/modules/src/data/ledger.zig` (dispatch array and comptime manifest)
- Modify: `packages/zts/src/modules/data/ledger.zig` (expose it)
- Modify: `packages/proof-checker/src/invariant.zig` (`AdapterManifest` type, expected table, canonical encoder, `adapterDigest()`)
- Modify: `packages/runtime/src/artifact_graph.zig:252`, `proof_certificate.zig:251`, `proof_activation.zig:98`, `handler_instance.zig:950`
- Modify: the Task 3 gate source and `docs/verification.md`

This is the task that closes the verified hole, and it is the one that can silently fail to. Today `artifact_graph.zig:252` binds the adapter member from `pcc.invariant.adapterDigest()` and `checker.zig:437` compares it against the same function. Both build and activation paths are in the runtime package, so merely "moving the call to two call sites" changes nothing. Three parts are required and all three are mandatory:

**(a) Native side.** `ledger.zig` gains a dispatch array of `{kind ordinal, predicate version, group_fn, baseline_fn}` that `executePost` (`:258`) and `validateBaseline` (`:214`) actually iterate, plus a manifest derived at comptime from that array together with `SCHEMA_VERSION` (`:12`) and the export names (`:45`, `:62`). A row in a table nothing calls is not evidence of enforcement.

**(b) Expected side.** The kernel holds its own `AdapterManifest` type, an `expected_manifest` table, and a canonical encoder. `adapterDigest()` becomes the digest of the encoded expected manifest. Use a distinct domain for it; today it is a bare `sha256` with no domain prefix, and reusing the specification domain would conflate two different things. No import is added, so `test-proof-checker-purity` still holds.

**(c) Bridge.** The runtime converts the native manifest into the kernel's type, hashes it with the kernel's encoder, and passes that digest as the graph input in both `proof_certificate.zig` and `proof_activation.zig`. The checker keeps comparing the graph member against its own expectation. The graph input is computed from the linked ledger manifest, never from `pcc`.

Three parties must then agree: the building binary's adapter, the serving binary's adapter, and the kernel's table.

**What this detects:** a kind, predicate version, schema version or export the kernel expects and the linked dispatch table lacks; and a serving binary older than the artifact. **What it cannot detect:** a dispatch row whose predicate is wrong. The design admits this and the plan says it too, so nobody reads more into the check than it performs.

**State plainly in the commit message:** every certificate built before this task is refused afterwards, first with an adapter identity mismatch and then on artifact binding, because the executable root changes. That is intended. Stores survive, because `ledger_meta.invariant_digest` binds the specification digest, not the adapter digest (`ledger.zig:199`).

- [ ] **Step 1: Write the failing tests**

Feed the comparison a manifest missing a row, a manifest with a changed predicate version, and a manifest with a changed schema version. Each must be refused before `installStore`. Add a floor test that the linked manifest digest equals `pcc.invariant.adapterDigest()` on an honest build, so the comparison is exercised rather than trivially unequal. Add a probe that a test copy of the expected table with one row removed mismatches.

Note: "a configured kind the adapter does not support" is a manifest-level test until Task 6, because `Kind` has one member here and no specification can yet name an unsupported kind.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-modules`
Expected: FAIL.

- [ ] **Step 3: Implement (a), (b) and (c)**

Retain allocator cleanup on every failure path in `installLedgerModuleState`, with `errdefer` on each allocation.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift && zig build test-proof-checker-purity`
Then: `zig build test-zruntime`
Expected: PASS all three.

- [ ] **Step 5: Update the adapter digest pin**

Task 1 pinned `adapterDigest()` to the old value. This task changes it by design. Update the pin to the new computed value in the same commit, and say in the message that the change is intentional and invalidates prior certificates.

- [ ] **Step 6: Commit**

```bash
git add packages/modules/src/data/ledger.zig packages/zts/src/modules/data/ledger.zig packages/proof-checker/src packages/runtime/src packages/tools/src docs/verification.md
git commit -m "feat(invariant): bind the linked adapter manifest, not the checker's constant"
```

**Checkpoint:** run the three refusal tests and confirm each fails before `installStore`, and run the floor test and confirm it passes on an honest build. Do not attempt to swap the native adapter at build time; no build option does that, so a checkpoint phrased that way cannot be executed.

---

### Task 6 (U5): Add declared accounts end to end

**Files:**
- Modify: `packages/proof-checker/src/invariant.zig` (second row and payload)
- Modify: `packages/tools/src/invariant_config.zig` and `invariant_author.zig` (JSON and flags)
- Modify: `packages/modules/src/data/ledger.zig` (`validateGroup` at `:433`, baseline at `:214`, dispatch entry)
- Regenerate: `packages/modules/module-specs/data/ledger.json`
- Modify: the Task 3 gate source, `docs/verification.md`, `docs/virtual-modules/README.md`

The account pattern is a closed union of exact and prefix matchers. Exact accepts only the same bytes. Prefix accepts an account starting with a non-empty prefix, including the prefix itself. Matching is case-sensitive over valid UTF-8 bytes, with no normalization, regex, wildcards or locale rules. Prefix `asset:` accepts `asset:cash` and refuses `assets:cash`. An empty prefix is invalid. The payload requires a non-empty matcher list, canonicalized by matcher tag then byte value, rejecting duplicates.

Every entry must match at least one rule, including zero-amount entries and entries that cancel on the same account. Refuse the whole posting before any write if one entry fails, returning a stable domain error through the existing Result API. Conservation stays mandatory.

**Baseline: extend the existing pass, do not add a second.** The current pass already reads every entry account (`ledger.zig:614`) and every balance account (`:678`) and already runs one content query per posting (`:626`), which dominates. Fold the matcher check into that pass: no new statements, O(rows x matchers) CPU inside the existing exclusive window. The cross-check at `:706` guarantees every historical entry account has a balances row, so checking all balance rows including zeroes is complete on its own.

**Regenerate, do not hand-edit,** `ledger.json`. `zttp module-spec-render` produces it and `verify-modules --builtins --strict` (`build.zig:950`) fails a hand edit.

- [ ] **Step 1: Write the failing tests**

Exact and prefix matching, case differences, UTF-8 boundaries, invalid matcher text, duplicate matchers, a forbidden zero-amount entry, entries that cancel on one forbidden account. Then the state test that matters: a refused group leaves entries, balances and the idempotency record unchanged. Then reopen a valid v2 store; refuse a same-spec store holding a forbidden account; refuse a changed spec without rewriting ledger metadata.

Use fixtures that actually reach the account check. A fixture that breaks the entry-to-balance bijection fails earlier as a corrupt ledger and proves nothing about matchers.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-modules`
Expected: FAIL.

- [ ] **Step 3: Implement the row, payload, flags, group predicate and folded baseline check as one unit**

Do not advertise kind 2 in the offered list until its codec, native enforcement and consumer checks are all wired, which is the end of this task.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift && zig build test-project-config && zig build test-cli`
Then: `zig build test-zruntime`
Expected: PASS all four.

- [ ] **Step 5: Measure the added baseline cost**

Take the measurement here, at the boundary, not at plan end: baseline validation time before and after this task on one workload, changing only the scale parameter between comparable runs. Record the numbers in the commit message. The design owes this measurement before any third kind is proposed.

- [ ] **Step 6: Commit**

```bash
git add packages docs
git commit -m "feat(ledger): declared_accounts_v1 as the second invariant kind"
```

**Checkpoint:** point a changed specification at an existing store, confirm it refuses, and then read the stored digest back and confirm it is unchanged. Startup must never rewrite metadata to make a mismatch pass.

---

### Task 7 (U6): Report write applicability

**Files:**
- Modify: `packages/proof-checker/src/checker.zig:470`, `verdict.zig`
- Modify: the runtime `InvariantStatus` in `contract_runtime.zig`
- Modify: the Task 3 gate source and `docs/verification.md`

Coverage counts call sites, not calls that executed. A balance-only artifact is a missing write-applicability report, not a demonstrated conservation failure, so report it rather than reject it. The verdict's input floor is already real (`verdict.zig:325`, `checker.zig:470`), the balance call site is genuinely covered, and the store is validated on real input at startup (`ledger.zig:180`). Rejecting would break a legitimate read-only topology and push authors to add a fake post.

Condition on that decision: vacuity is a machine-readable `InvariantStatus` field, it leads the summary, and it never relabels `ready()` or `coverageReady()`. `server.zig:1841` stays as it is.

The rule that a declared write absent from independent observation must reject is **already expressed** and must not be reimplemented: witness and observed counts must agree both ways (`checker.zig:494`, `:546`), every ledger call IR node needs a witness (`:564`), and the producer refuses a certificate carrying a spec with no observation (`proof_certificate.zig:301`). Derive vacuity after the exact comparison, from `result.writes == 0` (`:544`) and nowhere else.

Per-kind vacuity is degenerate today, because both kinds gate `post`. Say so in the code comment, or someone will invent per-kind observation that nothing needs.

- [ ] **Step 1: Write the failing tests**

Assert expected values, not non-regression. A balance-only artifact reports `write_applicability == .vacuous`, activates, and serves a balance read. A post-bearing artifact reports covered. An artifact with no ledger operation rejects with `invariant_operation_required`. A forged or omitted witness rejects. A declared write absent from observation rejects rather than downgrading to vacuous.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-proof-checker && zig build test-cli`
Expected: FAIL.

- [ ] **Step 3: Implement per-kind write applicability**

Keep the exact operation, witness and observation comparison unchanged.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift && zig build test-cli && zig build test-zruntime`
Expected: PASS all three.

- [ ] **Step 5: Commit**

```bash
git add packages/proof-checker/src packages/runtime/src packages/tools/src docs/verification.md
git commit -m "feat(invariant): per-kind write applicability in coverage reports"
```

**Checkpoint:** the three expected-value assertions above pass by name, and read-only serving still works after successful baseline validation.

---

### Task 8 (U8): Complete reports and documentation

**Files:**
- Modify: `packages/runtime/src/proofs/invariant_report.zig`
- Modify: `docs/verification.md`, `docs/user-guide.md`, `CONCEPTS.md`
- Modify: the Task 3 gate source

`proofs/invariant_report.zig` is anchored from `cli_main.zig:39`, so it is compiled by `test-cli`. `test-zruntime` never reaches it. Using the wrong step here means Step 2 does not fail and Step 4 passes without running the new tests.

The summary states configured kind names, write applicability, trusted native enforcement, independent call-site coverage, and baseline status. It always states that external writer exclusion is a deployment assumption the checker does not verify, and that line is not suppressible. Offline proof reports keep baseline status as `not checked`; only a live validated instance reports readiness. No output may label arbitrary prose as verified.

- [ ] **Step 1: Write the failing tests**

Exact status values for unconfigured, rejected, offline, read-only, and ready write-capable artifacts. Assert the expected value, not a difference from the excluded ones.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-cli`
Expected: FAIL.

- [ ] **Step 3: Implement the report and update the three documents**

Cover v1 compatibility, the v2 fresh-store requirement, and the advisory boundary.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-cli && zig build test-invariant-drift && zig build test-docs-drift`
Expected: PASS all three.

- [ ] **Step 5: Commit**

```bash
git add packages/runtime/src/proofs/invariant_report.zig packages/tools/src docs CONCEPTS.md
git commit -m "docs(invariant): truthful catalog status reporting"
```

**Checkpoint:** read the summary as someone who has not read `docs/verification.md`. If any line reads as "the invariant is verified", rewrite it.

---

## Final validation

Run the small end-to-end case first: author an explicit candidate, build it, start a fresh store, accept a balanced declared posting, refuse an undeclared one with no state change. Then restart, read-only status, changed adapter identity, invalid baseline.

Preserve the existing retry, conflicting-key, overflow, currency-separation, concurrent-write, interrupted-commit, storage-bypass, output-path and secret-label regressions.

Run: `zig build test-invariant-drift`, `zig build test-project-config`, `zig build test-cli`, `zig build test-docs-drift`, `zig build test-zruntime`, `zig build test-server`. Retain the proof-checker purity, capability, module governance, module boundary, proof-swallow, proof ratchet, stand-in and invariant drift gates. Build the browser analyzer to check the pure boundary.

`bash scripts/verify.sh` and `zig build release` need explicit approval before running.

## Carried-forward debt

The predecessor records that full-repository validation is incomplete: the model replay corpus needs a fresh provider capture after the module tool bytes changed, and the release build hit the execution limit. Neither is granted permission here. Historical model responses must not be rewritten as if newly captured.

## Self-review notes

Spec coverage: purpose and baseline to Tasks 1 and 4; admission criterion to Tasks 5 and 6; supported versus configured kinds to Tasks 1, 5 and 6; specification and storage compatibility to Task 4; declared accounts to Task 6; authoring and evidence claims to Tasks 2 and 8; coverage and vacuity to Task 7; the gate to Task 3.

Deliberate deviation from the skill template: steps specify behaviour, file and line rather than literal Zig bodies. The signatures do not exist yet and inventing them would put unverified API surface into the plan, which this repository's conventions refuse. Every step names the file, the line where known, the test to write, and the command that decides the verdict.
