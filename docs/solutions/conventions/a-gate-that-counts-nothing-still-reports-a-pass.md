---
title: A gate that counts nothing still reports a pass
date: 2026-08-03
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

On 2026-07-30 two instances landed in the same session and were recorded only in a plan that is now archived. `zig build test-zts -- --test-filter "a\|b"` passes a literal `a\|b` to Zig rather than a grep alternation, so it matched zero tests and exited 0 - noted at the time as "the second time this session a verification step silently did nothing" (`docs/archive/plans/2026-07-30-004-item4-c1-plan.md`, finding 3). In the same table, a corpus differential was found structurally unable to catch the bug it was cited for, because every corpus case supplied a real atom table: "the differential read as stronger evidence than it was ... This is the same lesson as wave 3 item 1: a check that reads as covering more than it does" (finding 2). Wave 3 item 1 is a third instance, earlier still.

On 2026-08-03 four more shipped at once in the deterministic stand-in and were caught by an adversarial review rather than by any gate. They are the worked examples below.

Two scripts in this repo already carry the remedy locally. Neither states it as a rule, so it has not spread.

## Guidance

**A gate asserts a floor on its own input before it trusts a count taken over that input.**

`scripts/check-runtime-purity.sh:42-51` is the model. It searches a binary for provider markers, and before reporting anything it requires at least one marker to have matched:

```bash
if [ "$present" -eq 0 ]; then
  echo "error: no agent/provider markers found in dev binary '$(basename "$dev_bin")' - purity check is vacuous; update markers" >&2
```

Its comment names the exact failure: the check goes vacuous when "every provider host was renamed and the markers went stale". `scripts/check-docs-drift.sh:239` does the same for a parsed registry - "A registry that stops parsing (renamed table, changed literal) would silently pass the loop above with zero iterations" - and enforces `command_count >= 40`.

The four shapes below are that rule applied to four different kinds of gate.

**A frozen corpus must be covered by the hash that guards it.** `range.negative_corpus` holds the prompts that must fall outside the stand-in's declared range, and it is the only thing asserting the range does not silently grow. It sat outside `contentHash()`, so emptying it changed no published number, while both gates looping over it fell to zero iterations and printed `0/4` as `0/0`. Fix: hash the corpus alongside the entries it guards (`packages/pi/src/standin/range.zig:171-179`), and assert a floor before trusting any count over it (`try testing.expect(range.negative_corpus.len >= 4);`).

**A hand-written case list must be tied to the table it covers.** The stand-in's sequence gate is the only check on tool ordering and the at-most-one-edit rule, and it drove a literal array of six rows. A seventh range entry would have had no row, escaped the check, and left the gate reporting success. Fix is one line:

```zig
try testing.expectEqual(range.entries.len, cases.len);
```

**A name filter must enforce the naming rule it depends on.** The stand-in test roots compile with `.filters = &.{"stand-in"}` (`build.zig:316`), so a test whose name omits that token never runs and never reports. Nothing enforced the convention the filter relied on. Fix: a gate that `@embedFile`s the roots, fails on any column-zero `test "` declaration whose name lacks the token, and - applying this document's own rule to itself - asserts a floor on how many declarations it scanned.

**A build product with no consumer must be given one.** `zttp-standin` is deliberately not installed, so no step forced it to compile and a break would surface only when somebody ran it by hand. Fix: `test_step.dependOn(&standin_exe.step);` - compiled by the suite, still not installed.

## Why This Matters

The failure is not that these gates were wrong. Each was working correctly and answering the question it was asked. The question had been quietly replaced by an easier one, and the output is identical either way.

That makes it a fail-open in the same family as [an empty baseline made a file-destroying edit prove clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md), one level up: there, an empty baseline made a real compiler prove a destructive edit clean; here, an empty collection makes a real gate prove an absent property. Both are a check handed a degenerate input and reporting success, and the polarity rule underneath both is stated in [normalize-unions-without-dropping-members](../logic-errors/normalize-unions-without-dropping-members.md) - when something cannot see, it must widen or fail, never narrow to a pass.

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

## Related Issues

- [empty-baseline-made-a-file-destroying-edit-prove-clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md) - the same fail-open one level down, and the defect these four gates did not catch
- [empty-label-set-claimed-a-value-was-clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md) - the compiler instance, whose Prevention section states the sibling rule: do not let a green gate stand in for a class it cannot see
- [normalize-unions-without-dropping-members](../logic-errors/normalize-unions-without-dropping-members.md) - the polarity rule underneath all of these
- `scripts/check-runtime-purity.sh:42-51` and `scripts/check-docs-drift.sh:239` - the two places this rule was already implemented before it was written down
- `docs/archive/plans/2026-07-30-004-item4-c1-plan.md` - findings 2 and 3, the prior recurrences that stayed in an archived plan
- `docs/internals/testing.md` - maps which build step runs what; it does not yet state this rule, and is the natural place to reference it from
