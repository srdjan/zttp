# Tier 1 plan: test and diagnostic discipline (beni items R1 to R5)

Status: draft for owner approval, 2026-10-07, revision 2. Source: the
[beni retrofit study](2026-10-07-beni-retrofit-study.md), decision D1 (a).
Code references are to local `main` at `84444568`. This plan does not
authorize implementation until the owner approves it.

Revision 2 folds in a Fable review of the reasoning and a Codex astra fact
check of every citation. Section 7 lists what changed and why.

## 1. Goal and order

Tier 1 adds five capabilities:

- R1: a pattern-matrix `match` coverage check with missing-case examples.
- R2: a golden diagnostic corpus.
- R3: fuzz, stress, and mutation tests.
- R4: a safe subset of diagnostic-pipeline changes.
- R5: instruction budgets and CLI abuse tests.

The review found that the `match` runtime does not do what the spec says in
four cases. A coverage check is only as sound as the runtime it models, so
those defects come first. The order is:

1. U0 fixes the `match` runtime defects.
2. R2 makes the diagnostic output a pinned golden surface.
3. R1, then R4.
4. R3 and R5. Their decoder and CLI units do not depend on R1 or R4.
5. One batched DeepSeek re-record, if the owner approves it (decision T5).

## 2. Binding constraints

- **C1 (hashes that pin replay).** Every one of the 19 DeepSeek traces pins
  an apply-receipt digest (`simulator/runner.zig:368-380`). The receipt holds
  `policy_hash`, `grammarHash()`, `semanticsHash()`, and
  `diagnosticCatalogHash()` (`change_set_receipt.zig:75-81`). A change to any
  of these four hashes breaks replay of all 19 traces. A new diagnostic kind
  in any checker moves `diagnosticCatalogHash`. A new `rule_registry` row
  moves `policy_hash`, which `meta` also shows to the model
  (`agent_protocol.zig:789,913`). No offline tool re-stamps receipts. The
  precedent is a DeepSeek re-record after each new code (`0ce1d45d`,
  `d037e696`). Rules:
  - Each unit records the four hashes before and after. A unit that is not
    listed in section 5 as a hash mover must leave all four unchanged.
  - Hash-moving units are batched. The re-record happens once, after the last
    of them, and only with owner approval (T5). Until then, a failing
    `test-expert-app` is an expected state that the unit's commit message
    states, not a defect to fix by other means.
- **C2 (corpus identity).** Do not edit codegen prompts or the `seed_files`
  of codegen cases. Defect-seed edits do not move the codegen identity, but
  they move the stand-in pin `content_hash` (`standin/range.zig:14`, hashed at
  `:255-275`). A seed edit updates that pin and its generated document in the
  same commit. This is offline work.
- **C3 (replay of model-visible text).** The model sees each diagnostic's
  code, severity, message, line, column, suggestion, and repair intent, and the
  number of diagnostics (`edit_simulate.zig:249-299`). `violationKey` hashes
  code plus message (`edit_simulate.zig:525`). A unit that changes any of these
  for existing diagnostics runs `zig build test-expert-app` and records the
  result.
- **C4 (public JSON shape).** Do not add, remove, or rename fields in the
  `zts check --json` output (`json_diagnostics.zig:215-244` for diagnostics,
  `:261` onward for the envelope) in Tier 1.
- **C5 (evidence).** Take every verdict from an unfiltered run of the named
  step. Redirect build output to a file and read the exit status directly.
  A new gate asserts a floor on its own input, and states and tests what it
  could miss. An allowlist row that matches nothing fails.
- **C6 (proof-swallow).** A discarded error in a file that
  `scripts/check-proof-swallow.sh` lists needs a row in
  `scripts/proof-swallow.allow`. `type_checker.zig` is in that list.

## 3. Units

Each unit gets one commit. "Check" names the verification that closes it.
For each defect fix, the failing test is written and run first, and the
commit includes it.

### U0: make the `match` runtime match the spec

All four defects were observed on 2026-10-07 with `zig-out/bin/zttp serve`
(built after the last parser or checker change). Each handler passes
`zttp check` with only ZTS500 (proof profile) and ZTS305 (unused variable).

| Id | Pattern | Input | Result today | Spec result |
|---|---|---|---|---|
| U0.1 | `when { a: { b: x } }: x` | `{a:{b:"deep"}}` | `undefined` (binding never stored) | `"deep"` |
| U0.2 | `when { v: [] }` then `default` | `{v:[1,2]}` | first arm | `default` |
| U0.3 | `when { w }` then `when string` over `string \| { w: number }` | `"s"` | first arm | `when string` |
| U0.4 | `when 1`, `default`, `when 2` | `2` | `when 2` | refused |

Causes, from the reviews:

- **U0.1.** `emitPatternBindings` (`codegen.zig:2022-2045`) stores only the
  direct identifier fields of the top-level pattern. The parser declares
  nested bindings (`parse.zig:1211-1215`). Fix: store bindings at every depth.
- **U0.2.** `emitPatternValueTest` drops a nested empty array without a test
  (`codegen.zig:2135-2141`). A nested `{}` has the same shape. Fix: a nested
  `[]` tests "array of length 0", and a nested `{}` tests "is a record".
- **U0.3.** `emitObjectPatternTest` reads fields with `get_field` and never
  tests that the value is a record (`codegen.zig:2095-2098`). Fix: every
  record pattern, at every depth, first tests that the value is a record (not
  an array, `Bytes`, string, number, boolean, `null`, or `undefined`). This
  also makes a top-level `{}` match records only. The spec calls these
  "fixed record patterns" (`docs/zts-formal-spec-northstar-advanced.md:1064`).
- **U0.4.** Codegen tests every non-default arm in order and jumps to
  `default` last (`codegen.zig:1983-2008`). The parser accepts `default` at
  any position (`parse.zig:949`). The spec grammar is `MatchArm+ [DefaultArm]`.
  Fix: the parser refuses a `default` that is not last, and a second `default`.
  This needs a parser diagnostic: either a new kind (a hash mover) or an
  existing ZTS0xx code with new text. The implementer uses an existing code
  if one fits the meaning, and records the choice.
- **U0.5 (name trap).** `when { v: string }` is a binding named `string`, as
  the spec defines (`parse.zig:1209-1216`), so the arm matches every value. A
  programmer who writes it almost always meant a type test. See decision T4.

**Check.** Runtime tests for each row in `zig build test-zruntime`, or the
step that runs handler execution tests. `zig build test`. R2 corpus cases for
U0.4 and U0.5 once R2 exists.

### R2: golden diagnostic corpus

**U2.1: corpus gate.** Add a host executable gate, for example
`packages/tools/src/diagnostic_corpus_gate.zig`. Follow the vocab-envelope
pattern (`build/proof_gates.zig:113-145`): a Run step with
`has_side_effects = true`, its own tests on the same step, and a separate
write step.

- Layout: `tests/corpus/{parse,check}/{good,bad}/NAME.ts` or `.tsx`, each with
  a sibling `NAME.diag`.
- Run each case in-process with
  `precompile.runCheckOnlyFromSourceWithOptions(..., .{ .json_mode = true })`
  (`precompile.zig:1370`). Pass the path relative to `tests/corpus/` as
  `handler_path`, so goldens hold no absolute paths. This call does not read
  `zttp.json` (confirm in the unit).
- The golden records two things: the list of stages that ran, and the
  diagnostics array exactly as `json_diag.writeDiagnosticJson` emits it.
  Recording the stages stops a `good` case from passing because a stage was
  skipped (the type checker runs only when the type environment exists,
  `precompile.zig:1652`).
- A `good` case must produce zero diagnostics and must show every expected
  stage. Good cases use a narrow `Proof<>` capsule, or they get ZTS500.
- A `bad` case without a `.diag` fails with the instruction to run the write
  step. A `.diag` without a source fails.
- An optional filter argument limits the run to matching paths. A filter that
  matches no case fails. The `test` aggregate and `verify.sh` never pass a
  filter.
- The gate fails below a stated case-count floor.
- Steps: `test-diagnostic-corpus` joins the aggregate `test` step.
  `diagnostic-corpus-write` rewrites goldens and is listed in
  `scripts/manual-steps.allow`. Update `docs/internals/testing.md`.

**U2.2: seed the corpus.** Move the 14 cases from `tests/verify/` into the
corpus, with goldens. Add cases for each ZTS code that the default `check`
path can reach, in batches by code family. Delete `tests/verify/run_tests.sh`,
which no gate runs, and update its references (`docs/verification.md:915`,
`CONTRIBUTING.md:66`). Review each written golden against the case's intent
before commit.

**U2.3: code ratchet.** The gate iterates `diagnostic_catalog.entries()` (the
catalog universe, about 158 codes). Each code needs at least one `bad` case
with a diagnostic whose `code` field equals it (a field match, not a
substring), or a row in `scripts/corpus-uncovered.allow` with a reason. A row
for a covered code fails. A row for an unknown code fails. The file states
that its universe is the catalog, not `rule_registry`. This gate pins exact
output. It does not replace `test-standin`, which checks veto outcomes.

**Not done in Tier 1.** A refusal of a `-Dtest-filter` that matches no test
across `zig build test`. Only the corpus gate's own filter refuses a zero
match.

**Check.** `zig build test-diagnostic-corpus`. Probes in a scratch copy:
delete one `.diag` (fails), change one golden byte (fails), pass a filter that
matches nothing (fails), remove a stage from a good case's golden (fails).
Then `zig build test` and `test-step-coverage`.

### R1: pattern-matrix `match` coverage

**U1.1: matrix algorithm.** Rewrite `packages/zts/src/match_analysis.zig`
(377 lines) around Maranget's usefulness algorithm. Keep `hasDefaultArm`,
`narrowTypeForPattern`, and `isMatchExhaustive` for their callers, and update
the private `StrictChecker.matchIsCovered` (`strict_checker.zig:1955`).

The model must match the runtime after U0:

- A record pattern requires a record. A record discriminant field with a
  literal type (`kind: "echo"`) is a constructor of the closed union.
- A field `_` is a presence check and fails on `undefined`
  (`codegen.zig:2088,2185`). A binding field matches any value, including
  `undefined`. An optional field admits `undefined`.
- `_` as an array element is a plain wildcard with no presence check
  (`parse.zig:1013-1016`, `codegen.zig:2286`).
- An array pattern requires the exact length at every depth. A `T[]`
  scrutinee needs a `default` to be exhaustive.
- A top-level type test (`boolean`, `number`, `string`, `array`, `Dict`,
  `Bytes`) is one alternative of a finite set of value kinds.
- `boolean` has two constructors. `t_nullable` is the inner type plus
  `undefined`. `t_never` is covered by any pattern set.
- String and number literals over an open type need a `default`. `lit_float`
  patterns are values. Number literal types are `i16` (`type_pool.zig:727`).
- Resolve `t_ref` through `TypeEnv` with a depth bound. Treat
  `t_unknown_type`, `t_generic_app`, `t_generic_param`, `t_intersection`,
  `t_template_literal`, and unresolved refs as open. `t_function` is covered
  only by a binding or `default`.
- After U0.4, `default` is the last arm and appears at most once.

The algorithm has a step budget. Running out of budget gives "not exhaustive"
and no redundancy verdict in either direction.

A `match` that is not proven exhaustive, including by budget exhaustion, has
type `T | undefined`, where `T` is the union of the arm types. Today
`inferMatchType` unions the arm types only. This makes the four call paths
that run without the strict checker sound by construction
(`handler_instance.zig:1186`, `in_process_dispatch.zig:70`,
`build_command.zig:2138`, `contract_runtime.zig:2998`).

**U1.2: diagnostics.**

- ZTS603 (strict, error) and ZTS205 (type checker, warning) keep their codes,
  severities, and `message` text. The first missing case goes in the
  `suggestion` field as a source-syntax example, for example
  `missing case: when { kind: "c" }`. The `message` stays stable, because
  `violationKey` hashes code plus message. A changing message would turn a
  pre-existing ZTS603 into a "new" violation after each partial fix.
- Budget exhaustion gives the same codes. The suggestion says that the
  analysis budget ran out.
- ZTS205 is emitted only when the strict checker does not run. Today both
  fire for one match, which gives two violations for one mistake. Update
  `type_checker.zig` test 4943.
- A redundant arm is reported with a new type-checker kind and a new ZTS2xx
  code. This is a hash mover (C1). Its severity follows decision T1.
- Witness text is deterministic.

**U1.3: seeds, tests, and docs.**

- Rewrite defect-seed baselines that would gain a redundant-arm diagnostic:
  the `clean_match_default` baseline (`defect_seeds.zig:415`, which matches
  on a `const` with a literal type) and the `match-not-exhaustive` good draft
  (`:1697`). Use a `number` parameter. Update the stand-in pin (C2). Run
  `zig build test-standin`.
- Update `type_checker.zig` test 4952 per decision T1.
- Add corpus cases: split coverage across arms, nested discriminants, a
  missing case with its example, a redundant arm, a redundant `default`,
  optional fields, a field `_` against `undefined`, array element `_`, tuples
  and exact lengths, `T[]`, literals over open types, a binding-only record
  against a union with a string member, and budget exhaustion.
- Add runtime tests: each newly accepted split-coverage case runs every value
  of its type to an arm and never returns `undefined`.
- Delete the dead `isMatchExhaustive` call path in `handler_verifier.zig:1313`.
- Fix `docs/typescript.md:728-745` (it says every `match` needs `default`) and
  the ZTS603 text in `docs/verification.md:123-128`.

**Check.** `zig build test`, `test-standin`, `test-diagnostic-corpus`, and
`test-expert-app` (C3; expected to fail on the receipt digest until T5).

### R4: diagnostic pipeline (safe subset)

**U4.1: human renderer.** Add one renderer for human output: the ZTS code,
`file:line:col`, the source line, and an underline from `offset` to
`end_offset` (`token.zig:165`). Use it in each checker's `formatDiagnostics`
and in the three parse-error paths that print no code and no caret
(`precompile.zig:1529-1535`, `1981-1988`, `handler_instance.zig:1156-1165`).
Add text tests for those three paths. The JSON output does not change (C4).

**U4.2: parser progress assertion.** In safe builds, assert that each loop
iteration in `parse.zig` consumes at least one token. The loops are at about
lines 251, 603, 933, 1174, 1265, 1304, 1374, 1602, 1997, 2326, 2376, 2590,
and 2953. The depth guard (ZTS044) already exists.

**U4.3: ZTS046 names the character.** Decode the code point with
`std.unicode.Utf8View` when an `.invalid` token holds a byte >= 0x80. Narrow
the span to that code point. Add a lookalike table, at minimum: U+2212 minus,
U+2013 and U+2014 dashes, U+201C, U+201D, U+2018, U+2019 quotes, U+00A0
no-break space, U+FEFF byte-order mark, U+00D7 multiplication sign. The
message names the code point and its ASCII replacement. A byte outside an
identifier gets text that does not say "identifiers". Keep code ZTS046.
Update `docs/feature-detection.md:42`. Check C3.

**U4.4: one message for one type mistake.** Add an error type to the type
pool. Do not name it "poisoned", which already means a pool failure
(`type_pool.zig:27,240-259`). A failed operator or call produces it, and
assignability and operator checks accept it silently. Containment rules:

- The error type never leaves the type checker. `inferTypeWithoutDiagnostics`
  (`type_checker.zig:244`), the match-narrowing APIs, and every other public
  getter map it to `null_type_idx`, which the strict checker, verifier, flow
  checker, contract builder, and Boolean checker already treat as unknown.
- A test asserts that "error type produced" implies `typeErrorCount() > 0`.
- One probe per consumer shows that an error-typed receiver is still refused.
- Stage gating is not the containment: `pipeline.resolve` still runs the
  Boolean and strict checkers after type errors (`pipeline.zig:197`).

Probe: `const m: number = n + "y";` gives ZTS105 and then ZTS200 today, and
only ZTS105 after. Check C3. Add the probe as a corpus case.

**U4.5: parser dampers.** Never report two parse errors at the same offset.
Keep recovery silent until the parser reaches a synchronization point. Check C3.

**Not in Tier 1.** Skipping a failed declaration in later passes (a skip in
the flow, proof, or verifier stages is the fail-open class in AGENTS.md).
Wider construct spans. The "what, where, why, hint" shape in JSON text.

### R3: fuzz, stress, and mutation tests

House style is the deterministic harness in `http_parser.zig:1063-1290`: a
stated contract, a fixed seed, a bounded iteration count, and
`std.testing.allocator`.

**U3.1: certificate decoder sweep.** In `packages/proof-checker`, sweep
`certificate.decode` (`certificate.zig:652`) over `buildMinimal` (:1252):
flip each bit of each byte, truncate at every length, and extend by one byte.
Each mutation gets a fresh budget (`certificate.zig:671`). Contract: a typed
error or a structurally valid value; no panic. The kernel gate forbids
`std.Random`, `@embedFile`, allocator references, and column-0 `var`
(`scripts/check-proof-checker.sh:81-104,113,180`), so the sweep uses
deterministic loops only. Update the test floor (`:198,208`) if the count
rises past it.

**U3.2: bytecode cache decoders.**
- `bytecode_cache.deserialize` (:746) allocates an uncapped size (:762) and
  reads fields before a minimum-size check (:776,785). Only a test calls it
  (:1072). Delete it and its CRC format if no non-test code uses it.
  Otherwise add a cap and a minimum-size check.
- `deserializeBytecodeWithAtomsAndShapes` (:2119) is live, with two callers:
  `handler_instance.zig:1334` and `invariant_observer.zig:79`. It has no CRC
  (:1876). Add a depth bound to the `.nested_function` recursion (:338), caps
  on the lengths that size allocations (:360,378,468,1716,1849), and a
  checked conversion in place of `@intCast` at the atom remap (:1776).
  `remapBytecodeAtoms` returns `void` (:1745), so it gains an error return
  and its callers (:1790,2134) change.
- First write a byte-mutation sweep over a valid encoding and record which
  inputs fail today. Then add the limits. The sweep shows each limit firing.

**U3.3: frontend fuzz tests.**
- Tokenizer: `std.testing.fuzz` with a seed corpus and a PRNG stress loop.
  Contract: terminates within `len + 1` tokens, ends at EOF, spans in bounds,
  offsets do not decrease. Include 256 or more nested `{` inside a template:
  the brace depth is a `u8` (`tokenizer.zig:84`), a probable overflow panic in
  safe builds.
- Stripper, TSX lowerer, and parser: the same pattern. Contract: a result or
  a typed error; spans in bounds; no leak; no stack overflow near the 512 and
  64 depth limits; out-of-memory may give an error without a diagnostic.
  Add deep-nesting generators.
- Each fuzz test asserts a seed-count floor and counts its iterations.
- Zig 0.16 facts (probed 2026-10-07): the callback takes `*std.testing.Smith`;
  `smith.slice()` reads a 4-byte length prefix, so seeds need a helper that
  prepends it; plain `zig build test` runs each seed and the empty input once.
  Fuzz tests must not be reachable from the `cli_main_tests` root
  (`build/runtime_tests.zig:38`), whose runner has no `fuzz` function.
- Gate iteration counts stay small. `ZTTP_FUZZ_ITERATIONS` raises them for
  manual runs. Record the time added to `zig build test`.

**U3.4: pipeline mutation.** In a host root (`test-precompile`), mutate the
R2 corpus and the `.ts` and `.tsx` files in `examples/` (filter other
extensions). Run the in-process check on each mutant. The contract lists the
allowed errors from `runCheckOnlyFromSourceWithOptions` by name; any other
error fails. A returned result has every diagnostic line and column inside
the file, and the same input gives the same diagnostics JSON twice. Fix each
defect in a separate commit, with the crashing input as a regression case.

**Not in Tier 1.** `zig build test --fuzz`: the stock 0.16.0 runner fails to
compile it, and a patched runner exits 0 after a crash (research probe,
2026-10-07, not committed).

### R5: budgets and abuse tests

**U5.1: instruction counter.** A small module returns retired user-space
instructions for the current process: `proc_pid_rusage` with
`RUSAGE_INFO_V4` (`ri_instructions`) on macOS, declared by hand as
`extern "c"`, and `perf_event_open` on Linux. The fallback is CPU time from
`getrusage`, and the result names its source. A test asserts that the count
for 2n loop iterations exceeds the count for n by a stated margin. A wrong
struct layout reads 0, which a research probe observed.

**U5.2: corpus budgets.** The R2 gate measures instructions for each case and
fails a case above a budget. Set the budget from a measurement of the
current maximum, with stated headroom. On the CPU-time fallback the gate
reports and does not fail. Today that means: macOS gates locally; the CI
runners report only, until decision T3 is resolved.

**U5.3: CLI abuse tests.** Spawn the built `zts` in a new temporary directory
with hostile inputs: an empty file, a missing path, a directory, a file over
the 10 MiB cap, invalid UTF-8, NUL bytes, deep nesting past the limit, and
unknown flags. Assert: exited, not signalled; the exact exit code; completion
within a deadline; with `--json`, any stdout is one complete JSON document.
Unknown flags print stderr text without JSON today (`zts_main.zig:44`), so
that case asserts empty stdout. Project discovery walks every ancestor of the
input path (`project_config.zig:159-165`), so the test asserts that no
`zttp.json` exists in the temporary directory's ancestors. Model the spawn on
`reference_tools_check.zig:304-358`.

**Deferred.** Ratio scaling tests (cost(2n)/cost(n)) move to Tier 3 with the
R10 measurement work. They need a program generator and give a manual step,
not a gate.

## 4. Final verification

After the last unit: `bash scripts/verify.sh` with output redirected to a
file and the exit status read directly. `verify.sh` runs the aggregate
`test` step, which includes `test-expert-app` and `test-standin`. Report the
time that the new gates added to `zig build test`, and the four C1 hashes.

## 5. Hash movers

These units move `diagnosticCatalogHash` or `grammarHash` and break replay
of the 19 DeepSeek traces until a re-record (C1):

- U0.4, if no existing parser code fits.
- U0.5, if T4 is (a).
- U1.2 (the redundant-arm kind).

All other units must leave the four hashes unchanged.

## 6. Decisions for the owner

**T1 (redundant arms).** This covers a `default:` after full coverage and an
arm that can never match. Spec 5.5 says a closed union must not include
`default`, and treats unreachable arms as errors.
Options: (a) a warning; (b) an error; (c) not reported, as today.
Recommendation: (a). The expert loop counts warnings as veto violations, so
models move toward the spec form, and a warning does not stop a build.

**T2 (record patterns test record shape, U0.3).** This changes runtime
results for programs that pass today: a binding-only or `{}` pattern stops
matching strings, numbers, and arrays.
Options: (a) fix it as the spec says; (b) keep today's behavior and teach the
coverage model to treat a binding-only pattern as matching any value.
Recommendation: (a). Today's behavior gives wrong bindings typed as record
fields.

**T3 (CI instruction counters).** The counters are not measured on the
GitHub `macos-latest` and `ubuntu-latest` runners.
Options: (a) CI reports only, until the owner pushes once and reads the
counter source in the CI log; (b) gate on CPU time everywhere.
Recommendation: (a).

**T4 (a binding named like a type test, U0.5).** `when { v: string }` binds a
variable named `string` and matches every value.
Options: (a) refuse a binding named `boolean`, `number`, `string`, `array`,
`Dict`, or `Bytes`, with a suggestion to use a top-level type test; (b) leave
it as a legal binding.
Recommendation: (a). The spec does not allow nested type tests, so this name
is almost always a mistake.

**T5 (one batched DeepSeek re-record).** The section 5 units break replay of
all 19 traces.
Options: (a) approve one re-record after the last hash mover, run as
`ZTTP_CODEGEN_PROVIDER=deepseek` with the 600000 ms turn timeout, then the
convergence and coverage republish; (b) drop the hash movers, so U0.4 and T4
use existing codes only and redundant arms are not reported.
Recommendation: (a). It follows the precedent of `0ce1d45d` and `d037e696`.

## 7. Changes in revision 2

- U0 rewritten. The first draft named a defect in nested type tests. Codex
  showed that `{ v: string }` is a renamed binding by spec, so that claim was
  wrong. Fable found four real defects, and I reproduced each one.
- C1 widened. Fable and Codex found that `diagnosticCatalogHash` is pinned in
  all 19 trace receipts. The first draft said a type-checker code was not
  model-visible.
- C2 corrected. Defect-seed edits move the stand-in pin.
- R1: the witness moved from `message` to `suggestion`; ZTS205 no longer
  duplicates ZTS603; a non-exhaustive `match` includes `undefined` in its
  type; array element `_` and five more type tags are modelled; "arms after
  `default` are unreachable" was wrong, and U0.4 replaces it.
- R4 U4.4: containment is now explicit, because stage gating does not stop
  the strict and Boolean checkers.
- R2: goldens record the stages that ran; the ratchet matches the `code`
  field.
- R3: the live decoder has no CRC; a second caller, the `void` remap
  signature, the fresh budget per mutation, and the template-brace overflow
  were added.
- R5: the scaling tests moved to Tier 3; the counter test now checks growth;
  the abuse test assertions match the current CLI.
- Line references were corrected per the Codex check.
