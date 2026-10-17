# Weak test assertion census

Date: 2026-10-17. Status: complete; results are in the
[worklog](2026-10-17-weak-assertion-census-worklog.md). Revision 2, after a Fable review. A Codex astra fact
check did not run, because that account was at its usage limit. Opus measured
the counts and checked the build-step names directly.

## Problem

Tests in this repository contain assertions of the form `expect(x > 0)`,
`expect(x != 0)`, and `expect(x >= 1)`. Each one states that a value is not
zero. It does not state what the value is. Such an assertion passes when the
behavior under test produces the wrong non-zero value: the wrong diagnostic,
the wrong count, or an output from a different path.
[Difference is not the claim](../solutions/conventions/difference-is-not-the-claim-and-a-probe-must-compile.md)
names this class. Nobody has checked which of these assertions can pass while
the behavior that the test names is broken.

## Census set

The set is every line in a tracked `.zig` file that matches this pattern, at
commit `60db0cd5`:

```
git ls-files -z '*.zig' | xargs -0 grep -nE 'expect\([^;]*(> 0|!= 0|>= 1)\)'
```

Measured: 575 lines in 111 files. By package: `packages/zts` 395,
`packages/tools` 81, `packages/pi` 52, `packages/runtime` 34,
`packages/proof-checker` 10, `packages/modules` 2, `tooling` 1. The pattern
misses an `expect(` call that spans lines. Thirteen lines end with `expect(`.
Opus read all 13, and one of them is in the class: the disjunction in
`expectDirectAccepted` (`packages/zts/src/typed_frontend_tests.zig#expectDirectAccepted`).
The set is therefore 576 rows.

## Verdicts

Each row first answers one question: which broken implementation passes this
assertion while the test's named claim is false? The row names that
implementation, or it states that no implementation passes. The verdict
follows from that answer, in this order of precedence:

1. `TAUTOLOGY`: the assertion cannot fail, for example `@sizeOf(T) > 0` or a
   non-optional pointer compared with zero. The fix deletes it, or replaces it
   with the check that the author intended.
2. `WEAK`: a broken implementation passes, and a stable assertion exists that
   refuses it. The row gives that assertion.
3. `PINNED`: another assertion in the same test determines the exact value of
   the censused expression. That assertion checks the same expression, or the
   censused value is a sum whose terms are all pinned. A flag that a loop sets
   on the first match does not pin a count. The row cites the pinning line.
4. `GUARD`: the assertion is a bounds check, and a later assertion reads the
   guarded element and pins its kind, code, message, or location. The row cites
   that line. If that line is itself in the census set, the GUARD row inherits
   that line's verdict. Diagnostic cascades after the first error are out of
   scope. One exception applies: when `expectError` already pins a single
   refusal, `expectEqual(1, errors.len)` is the natural form.
5. `FLOOR`: the assertion proves that the test's own input or sweep is not
   empty. The row cites the line that asserts a property over that input. The
   cited line can be in a helper or in a sweep callback, and the classifier
   must read it there. Inside a loop, the row also cites the loop's own floor.
   If no property is asserted, the verdict is `WEAK`.
6. `UNSTABLE`: the exact value is not part of the contract. The row states that
   no stable stronger assertion exists, after the classifier has tried a
   structural property, an execution result, and a golden. If the stronger
   property is already asserted in another test, the row cites that test. If a
   stronger assertion exists and nothing asserts it, the verdict is `WEAK`.

A `WEAK` row that cannot name a broken implementation is not `WEAK`. A named
implementation is not a confirmed defect until a sabotage shows it (Phase 3).

## Phases

**Phase 0: pilot.** A read-only Sonnet agent classifies
`packages/tools/src/precompile.zig` (24 rows) and 20 rows of
`packages/zts/src/typed_frontend_tests.zig`. The 20 rows include allocation
sweeps and `type_store` counts. Opus compares the records with its own reading.
If more than three verdicts disagree, Opus revises the rubric before Phase 1.

**Phase 1: classify.** Read-only Sonnet agents classify the set in parallel. A
file is never split between agents. Each agent writes one TSV row per census
line with these fields: `path`, `line`, `test_name`, `broken_impl` (or `none`),
`verdict`, `cited_line`, `reason`, and `proposed_assertion`. Agents make no
edits.

**Phase 2: audit.** Opus first checks the ledger floor: 576 rows, and each
census `(path, line)` appears exactly once. Opus then reads every `WEAK` and
`TAUTOLOGY` row. A separate Fable agent re-classifies a stratified sample of
the keep rows without seeing their verdicts: all `UNSTABLE` rows, 30 percent of
`PINNED`, 15 percent of `FLOOR`, and 10 percent of `GUARD`. Opus adjudicates
each disagreement. When the false-keep rate for one verdict kind is above 5
percent, Opus re-runs that verdict kind across the whole repository. The
worklog states the measured false-keep rate for each kind, and it states that
as the accepted residual.

**Phase 3: fix.** Sonnet agents strengthen each accepted `WEAK` row and resolve
each `TAUTOLOGY` row. The oracle rules are these:

- For diagnostics, pin the set of codes or kinds and their locations. Pin a
  count only where a registry, a specification, or a document states it,
  because parser recovery decides the count and the input does not.
- A value that comes from a production path names that path and explains why
  the path is independent of the code under test.
- When a run disagrees with the derived value, the agent records both values
  in its report and goes on. Opus triages each disagreement. The agent does not
  pin the observed value.

Each accepted fix gets a sabotage that applies the broken implementation that
its row names. Three runs give the evidence. First, the new assertion without
sabotage exits 0. Second, the new assertion with sabotage exits non-zero, and
the output names the test and an assertion failure (`TestExpected...` or
`TestUnexpectedResult`), not a compile error. Third, the old assertion with
sabotage exits 0. When build time does not allow one build per fix, one build
can serve one file and one class of broken implementation. A table maps each
fix to its probe. A fix without a probe carries a row that states the
mechanism. Every run uses the named build step without `-Dtest-filter`.

**Phase 4: verify.** Opus reviews the diff line by line. Opus runs each touched
test step, and then `bash scripts/verify.sh` with a private
`ZIG_LOCAL_CACHE_DIR` and without `DEEPSEEK_API_KEY`. Opus re-runs the census
pattern at the final commit, and every remaining match must carry a keep
verdict in the ledger.

## Outputs

The full ledger is `docs/plans/2026-10-17-weak-assertion-census-ledger.tsv`.
Its line numbers refer to commit `60db0cd5`. The worklog
`docs/plans/2026-10-17-weak-assertion-census-worklog.md` records the count per
verdict, the false-keep rate per kind, the sabotage table, and each possible
defect found. Fixes go into one commit per package. The ledger and the worklog
go into one more commit.

## Limits

The census covers the three textual forms above. It does not cover other weak
shapes, such as `expect(x != null)`, `expect(!eql(a, b))`, or a loop that sets a
flag on the first match. Those shapes appear here only as reasons why a row is
not `PINNED`. The classification is a reading, not a proof, and Phase 2
measures its error rate on a sample. After this work, the ledger is a record
and not a gate: a new weak assertion added later carries no verdict. Whether to
make it a gate is an open decision for the owner.
