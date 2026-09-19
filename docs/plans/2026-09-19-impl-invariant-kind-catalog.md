# Invariant Kind Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow the accepted invariant catalog from one closed template to a closed, gated set of kinds over the protected ledger, adding `declared_accounts_v1` end to end.

**Architecture:** The kernel gains per-kind metadata and a versioned tagged payload set beside the existing v1 bytes. The native adapter publishes a manifest of what it actually enforces, and the runtime compares that manifest with the consumer's expectation before opening the store, which closes a hole where both sides derive from the same constant. Authoring moves from Python to a Zig developer command that requires explicit kind selection.

**Tech Stack:** Zig 0.16.0 stable, SQLite via the module SDK, the existing proof-checker acceptance kernel.

**Spec:** [docs/plans/2026-09-18-feat-invariant-kind-catalog-plan.md](2026-09-18-feat-invariant-kind-catalog-plan.md). That document is the design and carries the reasoning; this one is its execution order. Executors read both.

**Plan location note:** this repository keeps plans in `docs/plans/`, so that convention is used instead of the skill default.

## Global Constraints

- No Python. Do not add a `.py` file or a `python3` invocation. Per `AGENTS.md`.
- All Zig. Native Zig error unions (`!T`) in engine and runtime code; `Result<T>` is a handler-facing construct only.
- `errdefer` on all allocations. `orelse` instead of `?` unwrap.
- Tests live beside code in `test "..."` blocks. Name them behaviourally.
- Work on local main. Commit complete isolated units. Do not push.
- Leave the pre-existing working-tree changes alone: the deletion of `docs/zts-advanced-v2.1.md`, `docs/zttp-next/`, and `proof-gate.md`.
- Do not record cassettes or drive the expert loop as part of this work.
- Scripts that run longer than two minutes need explicit approval before running. `scripts/verify.sh` and `zig build release` are both in that class.
- Measure, never estimate. Where this plan says measure, take the measurement rather than reasoning about the likely cost.
- Run `zig fmt` on every file touched; `scripts/verify.sh` checks `zig fmt --check`.

## Verified facts

Confirmed by reading the source on 2026-09-19 at `e8e503a8`. Executors do not need to re-derive these.

| Fact | Location |
|---|---|
| `Kind = enum(u16) { balance_conservation_v1 = 1 }` | `packages/proof-checker/src/invariant.zig:35` |
| `adapter_identity` is a fixed string constant | `invariant.zig:137` |
| `adapterDigest()` is `sha256(adapter_identity)` and nothing else | `invariant.zig:139` |
| Graph adds spec digest from inputs, adapter member from `adapterDigest()`, so both sides derive from the checker's own constant | `packages/runtime/src/artifact_graph.zig:250` |
| `spec_members != 1` refused | `packages/proof-checker/src/checker.zig:464` |
| `invariant_operation_required` refuses only when certificate AND observed lists are both empty | `checker.zig:470` |
| `kind_bits` set by `1 << (kind - 1)` | `checker.zig:479` |
| `kind_bits: u8`, capping the catalog at eight | `packages/proof-checker/src/verdict.zig:323` |
| Conservation enforced unconditionally, no kind selector | `packages/modules/src/data/ledger.zig:437` |
| Group hook: `validateGroup`, before the transaction | `ledger.zig:433` |
| State hook: per-account `next`, inside the transaction | `ledger.zig:303` |
| `BEGIN IMMEDIATE` in `executePost` | `ledger.zig:267` |
| `BEGIN EXCLUSIVE` in `bootstrapOrValidate` | `ledger.zig:181` |
| `ledger_meta.invariant_digest` binds a store to its spec | `ledger.zig:16`, field at `:33` and `:89` |
| Native config installed here | `packages/runtime/src/handler_instance.zig:950` |
| Drift gate reads exactly fourteen named inputs | `scripts/check-invariants.sh:27` |
| Gate body is a `python3` heredoc | `scripts/check-invariants.sh:15` |
| Build depends on the Python self-test | `build.zig:267`, wired at `:271` |
| `test-invariant-drift` already depends on proof-checker, modules, zts and host suites | `build.zig:269-274`, `:471`, `:1167` |
| `zig build test` depends on `test-invariant-drift` | `build.zig:1194` |
| Author tool treats `not_requested` as permission to emit conservation | `scripts/invariant-author.py:69`, `:120` |

**Consequence to hold onto:** because `zig build test` depends on `test-invariant-drift`, which depends on the Python self-test, the bulk suite currently requires `python3`. Task 2 is what removes that dependency, and until it lands the suite still shells out to Python.

## Task order

The design fixes this order and the reason for it: the gate is replaced before adapter changes invalidate its fixed-string checks. Do not reorder.

U2, U1, U7, U3, U4, U5, U6, U8, which is Task 1 through Task 8 below.

Each task ends with a commit and a review checkpoint. Do not start the next task until the checkpoint passes.

---

### Task 1 (U2): Define kind metadata

**Files:**
- Modify: `packages/proof-checker/src/invariant.zig` (beside `Kind` at `:35`)

**Interfaces:**
- Produces: a `KindInfo` row type and a comptime-derived table keyed by `Kind`, carrying at minimum the wire ordinal, a canonical description string, a predicate semantic version, a required flag, and a write-applicability flag. Tasks 2, 3, 5, 6 and 8 all read this table. Name the accessor so later tasks can call it without guessing; the table and its accessor are this task's only public additions.
- Consumes: nothing.

The kernel is import-free and must stay a leaf. Do not import the SDK or the native module here. `test-proof-checker-purity` enforces this.

- [ ] **Step 1: Write the failing tests**

Three tests beside the table: every `Kind` has a non-empty description; wire ordinals are unique; the table covers the enum exhaustively, written so that adding an enum member without a row fails to compile or fails the test rather than passing silently.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-proof-checker`
Expected: FAIL, table not defined.

- [ ] **Step 3: Add the table with the single `balance_conservation_v1` row**

Required is true and write-applicable is true for conservation. The description is the sentence a developer confirms, so write the canonical one from the design: the sum of signed balances is zero within each ledger and currency after every committed posting group.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-proof-checker && zig build test-proof-checker-purity`
Expected: PASS both.

- [ ] **Step 5: Commit**

```bash
git add packages/proof-checker/src/invariant.zig
git commit -m "feat(proof-checker): per-kind metadata beside Kind"
```

**Checkpoint:** the kernel still builds as a leaf, and the exhaustiveness test genuinely fails when a member is added without a row. Verify that by adding a throwaway enum member locally, confirming the failure, then reverting it. A test that passes on an incomplete table is the defect this task exists to prevent.

---

### Task 2 (U1): Replace Python authoring with a Zig command

**Files:**
- Create: a host authoring module under `packages/tools/src/`
- Modify: `packages/runtime/src/dev_cli.zig` (command dispatch), `cli_help.zig` (help text), `cli_main.zig` (test root wiring)
- Modify: `build.zig:267` and `:271` (remove the Python self-test dependency)
- Delete: `scripts/invariant-author.py`

**Interfaces:**
- Consumes: Task 1's metadata table, for `zttp invariant list` output and for validating a selection.
- Produces: `zttp invariant list` and `zttp invariant author`. The author command requires an explicit kind selection and emits a reviewable candidate; it never writes an accepted specification.

The advisory transport is injected at the host tooling boundary, following the pure/host split in `packages/tools/src/smt_solver.zig`. No HTTP client may enter the pure checker, the `zts` analyzer, or the wasm build. Only the developer's sentence and the public catalog criteria go in a request body. No source, ledger data, or credential value enters model state or logs.

- [ ] **Step 1: Write the failing tests**

The load-bearing one first, because it is the shipped defect: a sentence such as "accounts cannot be overdrawn" with no explicit selection must not produce a conservation candidate. Then: list output names every supported kind with its required status; a missing selection is an error; an unknown kind is an error with the supported list; candidate output is stable across runs; a candidate is clearly distinct from an accepted specification. Use an injected fake transport to cover advisory unavailable, malformed, and conflicting cases with no network call.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-cli`
Expected: FAIL, command not defined.

- [ ] **Step 3: Implement the command and the host authoring module**

Emit the original sentence, the canonical descriptions shown for review, `requiresReview`, the advisory status, and the structured candidate. Put `reviewed_against` in the review output, outside the accepted candidate: it identifies which descriptions and versions were displayed, and it does not assert that a person read them. Keep a legacy v1 `statement` field readable as an annotation only; every executable constraint lives in canonical structured fields.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-cli`
Expected: PASS.

- [ ] **Step 5: Remove the Python from the build, then delete the script**

Drop the `invariant_author_test` system command at `build.zig:267` and its `dependOn` at `:271`. Then `rm scripts/invariant-author.py`.

- [ ] **Step 6: Verify the build no longer shells out to Python for authoring**

Run: `grep -n "invariant-author" build.zig` and expect no output.
Run: `zig build test-invariant-drift`
Expected: PASS. The gate still runs its own Python body at this point; Task 3 removes that.

- [ ] **Step 7: Commit**

```bash
git add packages/tools/src packages/runtime/src/dev_cli.zig packages/runtime/src/cli_help.zig packages/runtime/src/cli_main.zig build.zig
git rm scripts/invariant-author.py
git commit -m "feat(cli): zttp invariant list/author in Zig, drop the Python tool"
```

**Checkpoint:** run the author command by hand with a sentence that does not describe conservation and no selection, and confirm it refuses rather than emitting a conservation candidate. This is the shipped defect; confirm the fix by observation, not by the test alone.

---

### Task 3 (U7): Replace and extend the drift gate

**Files:**
- Create: a host Zig gate command under `packages/tools/src/`
- Modify: `build.zig` (wire `test-invariant-drift` to the Zig command)
- Modify: `scripts/check-invariants.sh` (reduce to a wrapper that only invokes the build step, or delete it if nothing else references it)

**Interfaces:**
- Consumes: Task 1's metadata table, and the fourteen named inputs the current gate reads.
- Produces: `zig build test-invariant-drift` backed by Zig.

Preserve every existing check: compiler, operation catalog, native export and effect, observer, proof IR tag, adapter graph, documentation, and compiled-test checks. Add checks for the kind metadata and the authoring output. **Do not narrow the gate to only the new surfaces.** Comparing four surfaces and dropping the rest would silently lose the current operation-coverage protection, which is the failure this ordering exists to prevent.

- [ ] **Step 1: Write the failing tests**

One deletion probe and one mutation probe per independent input, including the new authoring and build-wiring inputs. Missing, empty, or unparsed input must fail explicitly.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-invariant-drift`
Expected: FAIL, Zig gate not defined.

- [ ] **Step 3: Port the fourteen checks to Zig and add the two new ones**

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift`
Expected: PASS.

- [ ] **Step 5: Prove the gate is not vacuous**

For each input in turn, delete or corrupt it and confirm the gate fails, then restore. Read the verdict from the command's exit status, not from a grep over its output: a gate whose own build fails and a gate that passes both print no failure message. This step is not optional and its results go in the commit message.

- [ ] **Step 6: Confirm no Python remains in this feature's build path**

Run: `grep -rn "python3" build.zig scripts/check-invariants.sh` and expect no output.

- [ ] **Step 7: Commit**

```bash
git add build.zig packages/tools/src scripts/check-invariants.sh
git commit -m "test(invariant): Zig drift gate replacing the Python body"
```

**Checkpoint:** the gate count did not shrink. Confirm the new gate asserts at least as many independent inputs as the fourteen it replaced, and that each one has a passing deletion probe.

---

### Task 4 (U3): Add the versioned payload set

**Files:**
- Modify: `packages/proof-checker/src/invariant.zig` (codec)
- Modify: `packages/tools/src/invariant_config.zig` (JSON side)
- Modify: `packages/proof-checker/src/verdict.zig:323` (`kind_bits`)
- Modify: `packages/proof-checker/src/checker.zig:479` (ordinal check before shift)

**Interfaces:**
- Consumes: Task 1's metadata table.
- Produces: schema 2 decoding beside the preserved v1 path, normalized to one internal view that Tasks 5, 6, 7 and 8 consume.

Keep the v1 decoder and its exact canonical bytes and digest. Existing v1 JSON must still build a conservation-only artifact that opens its existing store. Schema 2 carries common ledger and currency fields plus a sorted, length-delimited list of kind payloads. Conservation has no extra payload. Keep one specification graph member, so `checker.zig:464` is untouched. Use a distinct v2 digest domain.

Widen `kind_bits` from `u8` to `u32`, and check the ordinal is supported before shifting. The current shift at `checker.zig:479` has no such check and would be undefined for an ordinal above eight.

- [ ] **Step 1: Write the failing tests**

v1 bytes still decode to the identical digest. A v2 round-trip through encode, decode and acceptance. Then the refusals: duplicate kinds, unknown kinds, missing conservation, malformed lengths, trailing data, non-canonical record order, oversize specification, and an ordinal above the supported range reaching the shift. Test through the public parsing and acceptance APIs, not private helpers.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-proof-checker`
Expected: FAIL.

- [ ] **Step 3: Implement schema 2 and widen the mask**

Retain the bounded specification size and the zero-copy decoding. Keep unsupported kinds rejected; Task 5 is what makes kind 2 supported.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift`
Expected: PASS. This step covers the proof-checker, modules, zts and host suites in one command.

- [ ] **Step 5: Commit**

```bash
git add packages/proof-checker/src packages/tools/src/invariant_config.zig
git commit -m "feat(invariant): schema 2 tagged payload set beside v1 bytes"
```

**Checkpoint:** a v1 fixture built before this task still produces a byte-identical specification digest. If it does not, stop: every existing artifact and store has been invalidated, which this task exists to avoid.

---

### Task 5 (U4): Bind the linked adapter

**Files:**
- Modify: `packages/modules/src/data/ledger.zig` (native manifest and dispatch metadata)
- Modify: `packages/zts/src/modules/data/ledger.zig` (expose it)
- Modify: `packages/runtime/src/handler_instance.zig:950` (pass selected payloads into owned native config)
- Modify: `packages/runtime/src/artifact_graph.zig:250` (explicit adapter digest input)

**Interfaces:**
- Consumes: Task 4's normalized specification view.
- Produces: a native supported-kind manifest obtained from the linked adapter, and an adapter digest computed independently by the build and activation paths.

This is the task that closes the verified hole. Today the graph adds the adapter member from `pcc.invariant.adapterDigest()`, which is `sha256` of a string constant in the checker. Both sides of the comparison therefore come from the same place, so an adapter that does not implement a configured kind is undetectable. After this task the digest binds the native supported-kind manifest, predicate semantic versions, mandatory kinds, ledger schema and operation identities, and the runtime obtains that manifest from the linked adapter and compares it with the consumer's expectation before opening the store.

The native dispatch table must drive the checks that posting and baseline validation actually run. A name in a table nothing calls is not evidence of enforcement.

Preserve the checker's import-free build throughout.

- [ ] **Step 1: Write the failing tests**

A mismatched native manifest, a configured kind the adapter does not support, a changed predicate version, a certificate bound to the old adapter, and an incomplete configuration. Every one must fail before store creation or mutation, not after. Then: a rebuilt v1 fixture whose unchanged store digest is still accepted.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-modules`
Expected: FAIL.

- [ ] **Step 3: Implement the manifest, the dispatch metadata, and the digest inputs**

Retain allocator cleanup on every failure path in `installLedgerModuleState`, with `errdefer` on each allocation.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift && zig build test-proof-checker-purity`
Then: `zig build test-zruntime`
Expected: PASS all three. `test-zruntime` is standalone and is not covered by the others.

- [ ] **Step 5: Commit**

```bash
git add packages/modules/src/data/ledger.zig packages/zts/src/modules/data/ledger.zig packages/runtime/src
git commit -m "feat(invariant): bind the linked adapter manifest, not the checker's constant"
```

**Checkpoint:** build an artifact whose specification names a kind, then link an adapter that does not enforce it, and confirm activation refuses before the store opens. If this passes, the task did not do its job. This is the single most important check in the plan.

---

### Task 6 (U5): Add declared accounts end to end

**Files:**
- Modify: `packages/proof-checker/src/invariant.zig` (second metadata row and payload)
- Modify: `packages/tools/src/invariant_config.zig` (JSON parameters)
- Modify: `packages/modules/src/data/ledger.zig` (`validateGroup` at `:433`, baseline at `:214`, dispatch entry)
- Modify: the authoring command (CLI parameters)
- Modify: `packages/modules/module-specs/data/ledger.json` and the Module Catalog table, if the public module contract changes

The account pattern is a closed union of exact and prefix matchers. An exact matcher accepts only the same account bytes. A prefix matcher accepts an account starting with its non-empty prefix, including the prefix itself. Matching is case-sensitive over valid UTF-8 bytes, with no normalization, regex, wildcards, or locale rules. Prefix `asset:` accepts `asset:cash` and refuses `assets:cash`. An empty prefix is invalid. The payload requires a non-empty matcher list, canonicalized by matcher tag then byte value, rejecting duplicates.

Every entry must match at least one rule, including zero-amount entries and entries that cancel on the same account. Refuse the whole posting before any write if one entry fails, and return a stable domain error through the existing Result API. Conservation stays mandatory.

Baseline validation checks historical entry accounts **and** materialized balance accounts, under the existing exclusive transaction. Checking only non-zero balances would miss a forbidden account whose net balance is zero. Retain the existing posting hash, conservation, schema, currency and materialized-balance checks.

`balance` stays a read API and does not become an account authorization check.

- [ ] **Step 1: Write the failing tests**

Exact and prefix matching, case differences, UTF-8 boundaries, invalid matcher text, duplicate matchers, a forbidden zero-amount entry, and entries that cancel on one forbidden account. Then the state test that matters: a refused group leaves entries, balances and the idempotency record unchanged. Then reopen a valid v2 store; refuse a same-spec store holding a forbidden historical account; refuse one holding a forbidden balance account; refuse a changed spec without rewriting ledger metadata.

Use fixtures that actually reach the account check. A fixture that fails earlier on a hash or metadata mismatch proves nothing about this predicate.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-modules`
Expected: FAIL.

- [ ] **Step 3: Implement the row, payload, CLI parameters, group predicate and baseline check as one unit**

Do not advertise kind 2 in the offered list until its codec, native enforcement and consumer checks are all wired, which is the end of this task.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift`
Then: `zig build test-zruntime`
Expected: PASS both.

- [ ] **Step 5: Commit**

```bash
git add packages
git commit -m "feat(ledger): declared_accounts_v1 as the second invariant kind"
```

**Checkpoint:** startup never rewrites `ledger_meta` to make a mismatch pass. Confirm by pointing a changed specification at an existing store and checking both that it refuses and that the stored digest is unchanged afterwards.

---

### Task 7 (U6): Report write applicability

**Files:**
- Modify: `packages/proof-checker/src/checker.zig:470` (`checkInvariantCoverage`)
- Modify: `packages/proof-checker/src/verdict.zig` (`InvariantVerdicts`)
- Modify: the runtime `InvariantStatus`

**Interfaces:**
- Consumes: Task 1's write-applicability flag, Task 4's widened mask.
- Produces: per-kind write applicability carried through runtime and proof reports.

Coverage counts call sites, not calls that executed. The current checker refuses an empty operation set but accepts a balance-only artifact. That is a missing write-applicability report, not a demonstrated conservation failure, so the fix is to report it, not to reject it. Report each configured kind as `vacuous` when it has no observed write site, and report write-site coverage otherwise. Neither state may claim a posting occurred. Keep store readiness in a separate field. Continue refusing a configured artifact with no ledger operation at all.

- [ ] **Step 1: Write the failing tests**

Read-only coverage reports `vacuous` write status. A write-capable artifact reports write-site coverage. An empty operation set still rejects. A forged or omitted witness rejects. The subtle one: a declared write absent from independent observation must **reject**, not quietly downgrade to `vacuous`.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-proof-checker`
Expected: FAIL.

- [ ] **Step 3: Implement per-kind write applicability**

Keep the exact operation, witness and observation comparison unchanged.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift && zig build test-zruntime`
Expected: PASS both.

- [ ] **Step 5: Commit**

```bash
git add packages/proof-checker/src packages/runtime/src
git commit -m "feat(invariant): per-kind write applicability in coverage reports"
```

**Checkpoint:** read-only serving still works after successful baseline validation. This task must not turn a legitimate read-only deployment into a refusal.

---

### Task 8 (U8): Complete reports and documentation

**Files:**
- Modify: `packages/runtime/src/proofs/invariant_report.zig`
- Modify: `docs/verification.md`, `docs/user-guide.md`, `CONCEPTS.md`

The summary states configured kind names, write applicability, trusted native enforcement, independent call-site coverage, and baseline status. It always states that external writer exclusion is a deployment assumption the checker does not verify, and that line is not suppressible. Offline proof reports keep baseline status as `not checked`; only a live validated instance reports readiness. No output may label arbitrary prose as verified.

- [ ] **Step 1: Write the failing tests**

Exact status values for each case: unconfigured, rejected, offline, read-only, and ready write-capable. Assert the expected value, not a difference from the excluded ones.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-zruntime`
Expected: FAIL.

- [ ] **Step 3: Implement the report and update the three documents**

Cover v1 compatibility, the v2 fresh-store requirement, and the advisory boundary.

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test-invariant-drift && zig build test-docs-drift && zig build test-zruntime`
Expected: PASS all three.

- [ ] **Step 5: Commit**

```bash
git add packages/runtime/src/proofs/invariant_report.zig docs CONCEPTS.md
git commit -m "docs(invariant): truthful catalog status reporting"
```

**Checkpoint:** read the summary as someone who has not read `docs/verification.md`. If any line reads as "the invariant is verified", rewrite it.

---

## Final validation

Run the small end-to-end case first, before any scaling: author an explicit candidate, build it, start a fresh store, accept a balanced declared posting, and refuse an undeclared one with no state change. Only then cover restart, read-only status, changed adapter identity, and invalid baseline.

Preserve the existing retry, conflicting-key, overflow, currency-separation, concurrent-write, interrupted-commit, storage-bypass, output-path and secret-label regressions.

Run: `zig build test-invariant-drift`, then `zig build test-zruntime`, then `zig build test-server`, then `zig build test-cli`. Retain the proof-checker purity, capability, module governance, module boundary, proof-swallow, proof ratchet, stand-in and invariant drift gates. Build the browser analyzer to check the pure boundary.

`bash scripts/verify.sh` and `zig build release` both exceed the two-minute limit and need explicit approval before running. Ask.

## Carried-forward debt

The predecessor plan records that full-repository validation is incomplete: the model replay corpus needs a fresh provider capture after the module tool bytes changed, and the release build hit the execution limit. Neither is granted permission here. Historical model responses must not be rewritten as if newly captured.

## Measurements owed

Baseline validation runs per handler instance under an exclusive lock, and this plan adds a second baseline check. Measure startup, pool expansion and posting cost on a small workload before scaling, changing only the scale parameter between comparable runs. Measure the added account-check cost before any third kind is proposed. Do not assume the generated catalog resolves lock contention or permits validating once per generation.

## Self-review notes

Spec coverage: every design section maps to a task. Purpose and baseline to Tasks 1 and 4; admission criterion to Tasks 5 and 6; supported versus configured kinds to Tasks 1, 4 and 5; specification and storage compatibility to Task 4; declared accounts to Task 6; authoring and evidence claims to Tasks 2 and 8; coverage and vacuity to Task 7; the gate to Task 3.

Deliberate deviation from the skill template: steps specify behaviour and exact file locations rather than literal Zig bodies. The signatures these tasks need do not exist yet, and inventing them here would put unverified API surface into the plan, which this repository's conventions refuse. Every step names the file, the line where known, the test to write, and the command that decides the verdict.
