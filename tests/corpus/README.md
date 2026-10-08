# Golden diagnostic corpus

Each case pins what the default check reports for one source file. The gate is
`packages/tools/src/diagnostic_corpus_gate.zig`. It runs in `zig build test`
through `zig build test-diagnostic-corpus`.

## Layout

A case is `FAMILY/KIND/NAME.ts` (or `.tsx`) with a sibling `NAME.diag`.

| Directory | Holds |
|---|---|
| `parse/bad/` | a source the front end refuses: the run stops at or before the import check |
| `parse/good/` | a source that exercises a parser rule and passes every stage |
| `check/bad/` | a source that parses and then reports a diagnostic from a later stage |
| `check/good/` | a source with a narrow `Proof<Response, ...>` capsule that passes every stage |

The gate refuses a case filed in the wrong family. It refuses a `good` case
with any diagnostic, a `good` case that skipped a stage, and a `bad` case with
no diagnostic. Every case starts with a `//` comment that says what it proves.
A `good` case needs a narrow capsule, or the check reports ZTS500.

## The `.diag` format

```
stages: strip,parse,imports,boolean,types,strict
{"code":"ZTS205","severity":"warning","message":"...","file":"check/bad/x.ts","line":5,"column":12,"suggestion":"...","repair_intent":null}
```

The first line lists the stages that ran, in pipeline order, joined by commas.
Each later line is one diagnostic, exactly as `zts check --json` writes it
(`json_diagnostics.writeDiagnosticJson`), in the order the check reports them.
The `file` field is the path relative to `tests/corpus/`, so a golden holds no
absolute path. A case with no diagnostic has the stage line only.

A stage is listed when the check performed it, including when it then reported
errors. The stages are `strip`, `parse`, `imports`, `boolean`, `types`,
`strict`, `verifier`, `flow`, `contract`, `policy`, `paths`, `trace`, `spec`,
and `canonical`. `policy` runs only when the caller supplies a policy, and the
gate supplies none. A `good` case must list every stage except `policy`. The
`types` stage runs only when the type environment exists, and `strict` only
when the strict checker exists, which is why the list is pinned.

## Commands

```
zig build test-diagnostic-corpus            # check every case
zig build test-diagnostic-corpus -- NAME    # check cases whose path contains NAME
zig build diagnostic-corpus-write           # rewrite every golden
zig build diagnostic-corpus-write -- NAME   # rewrite matching goldens
```

A filter that matches no case fails. A filtered run is not a verdict on the
corpus. Read each rewritten golden against the case's `//` comment before you
commit it: a golden that pins the wrong diagnostic is worse than none.

## The floor

`minimum_cases` in the gate is the number of committed cases. The gate fails
below it, so deleting a case fails. When you add cases, raise `minimum_cases` to
the count that the gate prints (`N case(s) found`) in the same commit. Never
lower it to make a deletion pass.

## What the gate does not do

The check runs with no policy, no declaration, no SQL schema, and no system
file, so the POL rules and the declaration rules are outside this corpus. It
reads neither `zttp.json` nor `.zttp/witnesses`, and it writes no witness.

## The cost budget

The gate reads `instruction_counter` (`packages/tools/src/instruction_counter.zig`)
before and after each case's in-process check call, and nothing else sits
between the two readings. A case above its budget fails as `over_budget`. The
budget is one number for every case, `case_budget` in the gate.

The summary line names the source, the largest case, and the budget:

```
cost budget: source instructions_darwin, 161 case(s) measured, max 423000870 instructions (check/bad/tool_catalog_missing_byte_bound.ts), budget 1300000000 per case, 0 over budget
```

| Source | Host | Effect |
|---|---|---|
| `instructions_darwin` | macOS, `proc_pid_rusage` | a case above budget fails |
| `instructions_linux_perf` | Linux, `perf_event_open` | a case above budget fails |
| `cpu_time_ns` | any host that gives neither counter | the gate prints the numbers and fails nothing |

The `cpu_time_ns` source counts nanoseconds, so it cannot meet a budget in
instructions. The GitHub runners (`macos-latest`, `ubuntu-latest`) have not been
read yet, so the owner must read the `cost budget: source ...` line in a CI log
(decision T3). Until then CI may report only. `--cpu-time` forces the fallback
on any host, to see what that run prints. `--report-costs` prints one line per
case, most expensive first.

The budget holds for the build mode that compiled the gate. That is Debug unless
the build passes `-Doptimize`. A release build retires fewer instructions and
only loosens the check, so do not read a release run as a measurement.

### What the count includes

On macOS the counter is the whole process, not one thread. The gate runs every
case on its main thread and the check starts no thread, so no other thread adds
to a case's count. If the check ever starts a thread on macOS, its work is
inside the count. On Linux the counter opens with pid 0 and cpu -1, which counts
only the calling thread, so a thread that the check starts is outside it. The
count includes the check's own writes to stderr, because the check prints its
errors in process. The count does not include reading the source or the golden.

### The measurement

Seven runs on macOS arm64 (Darwin 25.6.0), Debug build, 161 cases, every case
read in every run. The 10 most expensive cases, in retired instructions:

| Case | Min over 7 runs | Max over 7 runs |
|---|---:|---:|
| `check/bad/tool_catalog_missing_byte_bound.ts` | 422,959,615 | 423,121,401 |
| `check/good/match_nested_discriminants.ts` | 371,480,016 | 371,590,617 |
| `check/bad/dict_entry_round_trip.ts` | 324,728,025 | 324,778,308 |
| `check/bad/dict_entries_reduce.ts` | 323,289,692 | 323,344,413 |
| `check/bad/optional_object_access.ts` | 319,750,325 | 319,936,577 |
| `check/good/checked_result.ts` | 318,928,456 | 319,302,481 |
| `check/good/match_tuple_element_wildcard.ts` | 312,010,464 | 312,051,081 |
| `check/good/validated_json_with_result_check.ts` | 308,441,627 | 308,547,306 |
| `check/bad/match_missing_nested_case.ts` | 305,432,016 | 305,500,237 |
| `check/bad/secret_in_log.ts` | 302,388,949 | 302,528,542 |

The median case costs 188,883,403 at most, and the cheapest (a parse refusal)
1,715,157. The largest case is 2.2 times the median, so no case is an outlier
and `case_budget_overrides` is empty. The run-to-run spread is under 0.1 percent
for the top 10 and under 9 percent for the cheapest cases.

The budget is `1_300_000_000`, which is 3.07 times the largest maximum, rounded
up. The headroom covers a different host: the counts above are for one CPU
architecture, and a Linux runner on another architecture will retire a
different number. If the CI log shows a source that counts instructions and a
case near the budget, measure again on that host before changing the number.

### What the budget catches

The cheapest `check` case costs 168 million instructions, and a 7-line source
adds little to that, so most of a `check` case is a fixed cost of the check. The
budget is therefore a guard on that fixed cost and a coarse guard on one case. A case fails when it costs more than the budget, which is a
growth of 4.1 times for `check/good/checked_result.ts` (319 million), 7.7 times
for the cheapest check case (168 million), and far more for a parse case. A probe
that copied `checked_result.ts`'s handler 230 times made the case cost
3,216,224,935 instructions, which is 10.07 times its normal cost, and the gate
failed it as `over_budget`. A regression of 3 times in the fixed cost of the
check, which moves every case, fails the heaviest case first.

To raise the budget, run the gate at least five times with `--report-costs`,
record the new table here, and change `case_budget` and its comment in the same
commit. To give one case more, add a row to `case_budget_overrides` with the
reason; a row for a path that is not a case, or without a reason, fails as
`bad_budget_row`. A counter that reads 0 around a check fails as
`counter_failed`, because a gate that measures nothing would pass.

## The code ratchet

The gate also iterates every distinct code in the diagnostic catalog
(`zts.DiagnosticCatalog.entries()` in `packages/zts/src/diagnostic_catalog.zig`).
The catalog is the universe, not `rule_registry`. Each code needs one of two
things:

- a `bad` case whose diagnostics carry that code in their `code` field. The
  gate compares the field. It never searches a message, because ZTS codes
  appear inside other messages.
- a row in `scripts/corpus-uncovered.allow`, with a reason that states the
  mechanism that stops the default check from producing the code.

The gate prints one line with the three counts, and they sum to the universe:

```
code ratchet over the diagnostic catalog: N code(s) = C covered by a bad case + A allowlisted (D DEFECT) + U uncovered (floor F)
```

The gate fails on each of these. A filtered run skips the ratchet.

| Failure | Meaning |
|---|---|
| `uncovered_code` | a catalog code with neither a case nor a row |
| `stale_allow_row` | a row for a code that a `bad` case now reports; delete the row |
| `unknown_code_row` | a row for a code that is not in the catalog |
| `duplicate_row` | two rows for one code |
| `empty_reason` | a row with no reason |
| `weak_reason` | a reason under 12 characters, or a placeholder such as "not written yet" |
| `universe_below_floor` | the catalog holds fewer codes than `minimum_universe` |

The list only ratchets down. "Not written yet" is not a mechanism: write the
case. The gate supplies no policy, no SQL schema, no system file, no
declaration, and its source is a string, so a code that needs one of those
carries a row. A reason that starts with `DEFECT:` records a catalog code that
does not fire when it should. The row keeps the gap visible and leaves when the
checker is fixed and a case proves the code.

When a row's reason is no longer true, for example because a producer now exists
for the code, write the case and delete the row in the same commit.
