---
title: A gate that counts nothing still reports a pass
date: 2026-08-03
last_updated: 2026-09-20
category: conventions
module: repo-wide (build gates, verification scripts, test roots)
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "Writing a gate that loops over a corpus, a registry, a marker list, or any collection it does not own"
  - "Driving a hand-written case list against a table the case list is supposed to cover"
  - "Filtering a test binary by name, path, or tag"
  - "Adding a build product that no other step depends on"
  - "Reading a green gate as evidence that the thing it names is covered"
tags:
  - testing
  - build
  - gates
  - vacuous-check
  - fail-open
  - verification
---

# A gate that counts nothing still reports a pass

## Context

A gate that finds nothing and a gate that checks nothing produce the same output: success. `0/0 false fires`, `26/26 passed`, `all rows checked`, exit code 0. None of those is a claim until something compares the number to a value derived independently of the thing being measured.

This repo has now learned that at least four times, and never in a place anyone would find it again.

On 2026-07-30 two instances landed in the same session and were recorded only in a plan that is now archived. `zig build test-zts -- --test-filter "a\|b"` passes a literal `a\|b` to Zig rather than a grep alternation, so it matched zero tests and exited 0 - noted at the time as "the second time this session a verification step silently did nothing" (`docs/archive/plans/2026-07-30-004-item4-c1-plan.md`, finding 3). That sentence is the 2026-07-30 record and nobody can reproduce it against the tree today, which describes the same command form two other ways: the `-Dtest-filter` comment in `build/Context.zig` says Zig takes the filter at compile time, so the `-- --test-filter ...` form panics the runner, and `docs/internals/testing.md:283-288` says the run does not filter at all and executes every test in the root while reporting success. Keep the finding as written. Only the mechanism has moved, and all three versions end the same way, with a command that did not do what its author believed. In the same table, a corpus differential was found structurally unable to catch the bug it was cited for, because every corpus case supplied a real atom table: "the differential read as stronger evidence than it was ... This is the same lesson as wave 3 item 1: a check that reads as covering more than it does" (finding 2). Wave 3 item 1 is a third instance, earlier still.

On 2026-08-03 four more shipped at once in the deterministic stand-in and were caught by an adversarial review rather than by any gate. They are the worked examples below.

Two scripts in this repo already carry the remedy locally. Neither states it as a rule, so it has not spread.

## Guidance

**A gate asserts a floor on its own input before it trusts a count taken over that input.**

`scripts/check-runtime-purity.sh` is the model, and it carries two floors rather than one. Before it reads the binary at all it checks its own marker list against the client directories under `packages/pi/src/providers/`, so a provider family that has a client and no marker fails instead of going unexamined (`:46-61`, whose comment says why: "a family added later is checked by nothing and this gate reports a pass over a binary it never examined for it"). Then, per family, it requires at least one marker to have matched before it reports anything (`:89-92`):

```bash
if [ "$present" -eq 0 ]; then
  echo "error: no '$family' markers found in dev binary '$(basename "$dev_bin")' - this gate cannot assert that provider is absent from the shipped binary; update its markers" >&2
```

`scripts/check-docs-drift.sh:238-241` does the same for a parsed registry - "A registry that stops parsing (renamed table, changed literal) would silently pass the loop above with zero iterations" - and enforces `command_count >= 40`.

The four shapes below are that rule applied to four different kinds of gate.

**A frozen corpus must be covered by the hash that guards it.** `range.negative_corpus` holds the prompts that must fall outside the stand-in's declared range, and it is the only thing asserting the range does not silently grow. It sat outside `contentHash()`, so emptying it changed no published number, while both gates looping over it fell to zero iterations and printed `0/4` as `0/0`. Fix: hash the corpus alongside the entries it guards (`packages/pi/src/standin/range.zig:247-248`, inside `contentHash()` at `:229`, over the corpus declared at `:117`), and assert a floor before trusting any count over it (`try testing.expect(range.negative_corpus.len >= 4);`).

**A hand-written case list must be tied to the table it covers.** The stand-in's sequence gate is the only check on tool ordering and the at-most-one-edit rule, and it drove a literal array of six rows. A seventh range entry would have had no row, escaped the check, and left the gate reporting success. Fix is one line:

```zig
try testing.expectEqual(range.entries.len, cases.len);
```

**A name filter must enforce the naming rule it depends on.** The stand-in test root compiles with the `stand-in` filter, so a test whose name omits that token never runs and never reports. Nothing enforced the convention the filter relied on. Fix: a gate that `@embedFile`s the roots, fails on any column-zero `test "` declaration whose name lacks the token, and - applying this document's own rule to itself - asserts a floor on how many declarations it scanned.

The pin is no longer a bare literal, so do not go looking for one. The `test-standin` row of the `host_test_roots` table carries `.standin_only = true` (`build/host_tests.zig`), and the loop over that table reads the attribute when it builds each test artifact: `.filters = if (root.standin_only) &.{"stand-in"} else ctx.test_filters,` (`build/host_tests.zig`, the loop in `add`). The token is the same and so is the failure it permits.

The same shape then reached every test artifact in the repository. `-Dtest-filter` landed on 2026-08-01 in commit `0124cd1f`, two days before this document, and it is wired to `.filters` on all of them (`test_filters` in `build/Context.zig`), so an artifact the filter matches nothing in runs zero tests and exits 0. Measured: a filtered run reported "2 passed" while the named test's assertion was sabotaged to expect an impossible error, because that run executed none of them. There is no floor to add here, because the filter belongs to the caller and not to the gate. The rule is a rule of use instead, and `AGENTS.md` now states it: never cite a `-Dtest-filter` run as evidence, and take every verdict from an unfiltered run of the named step.

**A build product with no consumer must be given one.** `zttp-standin` is deliberately not installed, so no step forced it to compile and a break would surface only when somebody ran it by hand. Fix: `test_step.dependOn(&standin_exe.step);` - compiled by the suite, still not installed.

## Why This Matters

The failure is not that these gates were wrong. Each was working correctly and answering the question it was asked. The question had been quietly replaced by an easier one, and the output is identical either way.

That makes it the same fail-open one level up from [an empty baseline made a file-destroying edit prove clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md), over the polarity rule stated in [normalize-unions-without-dropping-members](../logic-errors/normalize-unions-without-dropping-members.md).

The cost compounds differently from an ordinary bug. A broken gate does not just miss its own defect; it is cited afterwards as evidence. The 2026-07-30 record is explicit about this - the differential "read as stronger evidence than it was" - and the 2026-08-03 data-loss defect shipped past a full `scripts/verify.sh` run and a dedicated 27-test target, both of which were green and neither of which was broken.

## When to Apply

Whenever a gate's verdict depends on a collection, a filter, or a build edge it does not itself define. Concretely: a loop over a corpus, registry, marker list, or fixture directory; a hand-maintained list paired with a generated one; any test filter; any artifact nothing depends on.

Not needed when the gate's input is a fixed literal in the same file as the assertion, where an empty input is visible in the diff that caused it.

## Examples

The general shape, in the order the rule applies:

```zig
// Before: a count nobody compares.
var false_fires: usize = 0;
for (range.negative_corpus) |negative| { ... }
std.debug.print("false-fire {d}/{d}\n", .{ false_fires, range.negative_corpus.len });

// After: the floor makes the count mean something.
try testing.expect(range.negative_corpus.len >= 4);
var false_fires: usize = 0;
for (range.negative_corpus) |negative| { ... }
try testing.expectEqual(@as(usize, 0), false_fires);
```

The test to apply to any gate before trusting it: **delete its input and see whether it still passes.** Empty the corpus, rename every marker, filter on a token no test carries, remove the only consumer of the build product. A gate that stays green through that is not measuring what its name says.

Two amendments to that method, and the shapes this rule does not reach, are in [difference is not the claim, and a probe that does not compile is not a probe](difference-is-not-the-claim-and-a-probe-must-compile.md): the probe must compile, and its verdict comes from the build's exit code rather than from a grep over its output.

## Related Issues

- `CONCEPTS.md`, the Gate and Probe entries - the whole class in one place, kept current as these documents change; read it before restating any of them here
- [difference-is-not-the-claim-and-a-probe-must-compile](difference-is-not-the-claim-and-a-probe-must-compile.md) - the same class over a degenerate assertion and a degenerate probe rather than a degenerate input, and the two amendments to this document's probe method
- [a-gate-can-be-non-vacuous-and-still-porous](a-gate-can-be-non-vacuous-and-still-porous.md) - the failure that remains once a gate passes both of the rules above
- [empty-baseline-made-a-file-destroying-edit-prove-clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md) - the same fail-open one level down, and the defect these four gates did not catch
- [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) - the compiler instance, whose Prevention section states the sibling rule: do not let a green gate stand in for a class it cannot see
- [normalize-unions-without-dropping-members](../logic-errors/normalize-unions-without-dropping-members.md) - the polarity rule underneath all of these
- `scripts/check-runtime-purity.sh:42-51` and `scripts/check-docs-drift.sh:239` - the two places this rule was already implemented before it was written down
- `docs/archive/plans/2026-07-30-004-item4-c1-plan.md` - findings 2 and 3, the prior recurrences that stayed in an archived plan
- `docs/internals/testing.md` - maps which build step runs what, and states this rule in "Adding A Test Root". Its own host-root table was an instance: it said "Nine host test roots" against twenty-one in `build.zig` and omitted `test-standin` entirely, a count nothing tied to its source. `scripts/check-docs-drift.sh` now binds the two, with a floor on the parsed side
