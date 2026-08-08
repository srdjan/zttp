---
title: Difference is not the claim, and a probe that does not compile is not a probe
date: 2026-08-04
last_updated: 2026-08-08
category: conventions
module: packages/pi (deterministic stand-in gates), packages/runtime (graceful shutdown), packages/zts (generic instantiation), tooling (repository metrics), repo-wide (probing any gate)
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "Writing an assertion that says what the result is not, when the gate's name says what it is"
  - "Building a fixture whose two possible outcomes could write the same bytes"
  - "Building a regression fixture from the parameter a bug report names, without reading the branch that bug lives behind"
  - "Probing a gate by breaking its input and confirming it fails"
  - "Reading a probe's result from grepped output instead of the build's exit code"
  - "Citing a green gate or asynchronous E2E as evidence that the behavior it names happened"
tags:
  - testing
  - build
  - gates
  - vacuous-check
  - fail-open
  - verification
  - probes
  - async-ordering
---

# Difference is not the claim, and a probe that does not compile is not a probe

## Context

The deterministic stand-in in `packages/pi` is a scripted responder that takes the
place of a live model, so the expert loop can be driven offline. On 2026-08-04 it
got defect seeds: handler drafts written to fail the compiler veto on purpose, so
the rejection half of the loop became reachable without spending model turns.
`packages/pi/src/standin/defect_seeds.zig` declares each seed's outcome as a
`VetoClass`. One of the three classes is `salvaged`: the draft trips a
canonical-band diagnostic, `canonicalize.normalizeSource` clears it inside
`veto.runVeto`, the canonicalized bytes are applied, and the turn still counts as
a first-draft pass. The model never sees a rejection.

Two gates were written over that work. Both reported a pass while checking
nothing.

[A gate that counts nothing still reports a pass](a-gate-that-counts-nothing-still-reports-a-pass.md)
was written the day before, over four instances in this same subsystem. It covers
the gate whose input has gone empty: a corpus outside the hash that guards it, a
hand-written case list untied to its table, a name filter that matches no test, a
build product nothing depends on. Its remedy is a floor on the input, and its
probe is to delete that input and see whether the gate stays green.

Neither gate here had an empty input. Both already carried floors. The first
passed while checking nothing because its assertion over a full input was weaker
than the claim in its own name. The second passed while checking nothing because
the probe sent to test it never compiled, so no test ran, and the empty output was
read as a weak gate rather than an absent one.

The sibling document covers a degenerate input. These are a degenerate assertion
and a degenerate probe.

On 2026-08-05 the production branch metric exposed the same assertion defect in
a topology floor. The review found that the pre-fix classifier silently assigned
an unknown `packages/*` directory to the repository bucket while every known
package contributed input. The gate proved presence of known members while its
report claimed a complete package classification.

## Guidance

**Assert the value the gate names, not a difference from the values it must not
be.**

The salvage gate must show that the bytes on disk are the canonicalized bad
draft. As first written it asserted only that those bytes differed from the bad
draft and differed from the baseline:

```zig
// Never reached the tree. The shape, as the probe found it.
try testing.expect(run.result.first_draft_veto_pass);
try testing.expectEqual(@as(u32, 0), run.result.veto_retry_count);
try testing.expect(run.result.applied_edit);
try testing.expect(!std.mem.eql(u8, run.on_disk, seed.bad_draft));
try testing.expect(!std.mem.eql(u8, run.on_disk, seed.seed_source));
```

A clean first draft satisfies both of those trivially. It differs from the bad
draft, and it differs from the baseline, and no salvage happened at all. The gate
reported salvage over a run that contained none.

The fix is to compute the claim and compare against it. Run the real veto over
the bad draft inside the test, take `report.normalized_content`, and require the
bytes on disk to equal it (`packages/pi/src/standin_tests.zig`, test
"stand-in seeded arm: a canonical slip is salvaged without a retry"):

```zig
var normalized = try veto.runVeto(allocator, .{
    .file = "handler.ts",
    .content = seed.bad_draft,
    .before = seed.seed_source,
});
defer normalized.deinit(allocator);
const canonical = normalized.report.normalized_content orelse {
    std.debug.print("[standin-gate] seed {s}: nothing was normalized\n", .{seed.id});
    return error.SeedNotSalvaged;
};
try testing.expectEqualStrings(canonical, run.on_disk);
```

Note that this does not weaken the oracle. The expected value comes from the
production code path, not from a second model of it hand-written in the test.

**A topology floor must reject unknown members, not merely require known ones.**

`required_packages` defines the package set whose presence the production branch
metric checks. The review found that the pre-fix path classifier used `.repo` as
the fallback for both repository-level files and unknown directories below
`packages/`. A new package therefore satisfied every existing floor while
disappearing from the per-package report.

The fixed classifier keeps `.repo` only for paths outside `packages/` and returns
`error.UnknownPackage` for malformed or unknown paths inside that namespace
(`tooling/production_branch_metric.zig:92-102`). `collect` classifies each path
before file access, so parsing and I/O behavior cannot hide the topology error
(`tooling/production_branch_metric.zig:262-279`).

**A fixture must make the outcomes it separates observationally different.**

The same fix exposed a second problem one level down. Each bad draft had been
built as the baseline plus exactly one canonical slip. The `let-binding` seed's
baseline was `const total = 1;` and its bad draft was `let total = 1;`.
Canonicalizing that bad draft returns the baseline byte for byte. So "salvage
rewrote the draft on its way in" and "the draft was discarded and the baseline
was rewritten" produce identical bytes on disk. No assertion over those bytes can
separate them, however exact it is. The stronger assertion above would have been
exact and still blind.

The seeds now differ from the baseline in a second, non-canonical way, so the
applied bytes carry the draft's own content
(`packages/pi/src/standin/defect_seeds.zig`):

```zig
// Before: canonicalizes back to the baseline exactly.
\\  let total = 1;
// After: the value differs, so the applied bytes name their origin.
\\  let total = 5;
```

The `compound-assign` seed took the same correction: its `total += 2;`
canonicalizes to `total = total + 2;`, which is the baseline. It now uses
`total += 7;`.

**A fixture must be able to reach the branch the gate is named for.**

The bug report names a parameter. The branch is guarded by something else, and a
fixture built from the parameter alone never arrives.

On 2026-08-08 the code-quality rebase plan's P0 was reproduced end to end:
`instantiateCompositeMembers` (`packages/zts/src/type_env.zig`) once copied
intersection members into a fixed `[16]TypeIndex` buffer and rebuilt from that
prefix, dropping a seventeenth obligation. "Seventeenth" is the parameter, so the
obvious fixture is a seventeen-member intersection whose last member is the only
one violated:

```ts
type Wide =
  { f01: string } & { f02: string } & ... & { f17: string };
const v: Wide = { f01: "v", ... f16: "v" };   // f17 missing
```

Seventeen members, an exact assertion on the error count, a probe that compiles.
It rejects correctly. It also rejects with the truncation put back, because the
function returns `.unchanged` when no member changed, and an intersection of
plain record literals changes nothing. The truncated prefix is only ever used to
rebuild, so a fixture that never triggers a rebuild cannot observe the defect in
either direction.

The guard is "a member changed", not "there are more than sixteen members". One
generic application among the members satisfies it:

```ts
type Box<T> = { boxed: T };
type Wide = Box<string> & { f01: string } & ... & { f15: string } & { last: string };
```

Measured against the same locally reintroduced `@min(live.len, 16)`:

| Fixture | Fixed build | Truncated build |
|---|---|---|
| 17 members, one generic application | reject | **accept** |
| 17 members, all plain records | reject | reject |

The second row is the trap: correct count, exact assertion, working probe, and a
permanent false pass. Both cases live in `packages/tools/src/precompile.zig`,
with a floor test pinning `Box<` and the member count so a later edit cannot
quietly turn the first fixture into the second.

**Observe a production checkpoint before the test emits an equivalent event.**

The same ambiguity appears in concurrent tests even when the final state is
exact. The runtime's signal path wakes a blocked `listener.accept()` by opening
a loopback connection (`packages/runtime/src/server.zig:2393-2406`). Once the
accept returns, the loop observes the shutdown flag and exits
(`packages/runtime/src/server.zig:2422-2446`).

The first graceful-shutdown E2E ordering raised `SIGTERM`, then opened another
client before waiting for the accept loop to exit (session history). That client
could release the same blocked accept call. A broken production wake and a
working wake therefore reached the same observable end state.

The corrected test waits for `shutdown_started` immediately after the signal and
opens the rejection-probe client only after that checkpoint
(`packages/runtime/src/server.zig:3651-3659`). The accept thread publishes the
checkpoint only after `acceptLoop()` returns
(`packages/runtime/src/server.zig:3605-3610`). At that point, no test-owned
connection can create the event being attributed to the production signal path.

**A probe must compile, or it tests nothing. Read its result from the build's
exit code, not from a grep for a failure format.**

The method this repo uses to validate a gate is to break the gate's input and
confirm the gate goes red. Commit `f69b28f7` records a probe of the env
synthesizer gate that changed
`if (!has_env_import)` in `synthesizeEnvFeature`
(`packages/pi/src/standin/playbook.zig`) to `if (true)`, to force a duplicate
import. Zig then refuses the file, because `has_env_import` has no remaining use:

```
error: unused local constant
    const has_env_import = std.mem.indexOf(u8, source, env_import) != null;
          ^~~~~~~~~~~~~~
```

The test binary never ran. The check applied to the output was a grep for the
test-failure format, `error: '`. A Zig test failure opens with a quoted test name
and a compile error does not, so the grep found nothing. Nothing is exactly what
a clean run produces, and the result was briefly read as a gate too weak to see
the duplicate.

Re-done as `if (has_env_import or !has_env_import)`, the file compiles, the
condition is still unconditionally true, and the gate reports the duplicate.

## Why This Matters

The sibling document already records three earlier recurrences of this
class and four more that landed at once on 2026-08-03. These two landed on
2026-08-04, in the same subsystem, one day after the rule was written down, while
its author was working from it. That is the useful fact: the floor-on-input rule
was necessary and is not sufficient. A gate can hold a full input, count it, print
the count, and still answer a question easier than the one its name asks.

The cost is the same as the class's, and it is why the class is expensive rather
than merely annoying. A broken gate does not just miss its own defect. It is cited
afterwards as evidence that the behavior it names was observed. The salvage gate
would have been read as proof that normalize-on-reject applied canonicalized bytes
without a retry, over a run in which no draft was ever rejected. The env probe
would have been read as proof that the gate was weak, which is a conclusion about
the gate drawn from a run of the gate that never happened.

A positive floor and an exhaustive boundary check prove different things. The
first proves that every expected bucket received input. The second proves that no
unexpected input was normalized into a bucket with different meaning. A
closed-world report needs both claims before its totals are trustworthy.

Both failures also point the same way as the defect these gates exist to catch:
[an empty baseline made a file-destroying edit prove clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md).
A check handed nothing, or asked something easier than intended, reports success.

## When to Apply

Whenever you write or review a gate whose name makes a positive claim: this
happened, these bytes are that value, this path was taken. Read the assertions and
ask which other runs also satisfy them. If a run in which the named behavior never
occurred is among them, the assertion is not the claim.

Whenever you build a fixture with two outcomes to tell apart, check that the two
outcomes write different observable state before writing any assertion over it.

Whenever an asynchronous test waits for a production-owned milestone, list every
test action that can produce the same milestone. Put the assertion before those
actions. Later probes may inspect the earlier transition, but they must not be
able to create it.

Whenever you build a regression fixture from a bug report, read the branch the
defect lives behind before choosing the fixture's shape. A report names the
parameter that made the defect visible; the code guards that line with something
else. Satisfy the guard, then vary the parameter.

Whenever a gate reports a closed set of packages, modules, namespaces, or other
categories, probe an unknown member as well as every known member. A catch-all is
valid only outside the closed namespace. Inside it, an unknown member is a model
change and must fail until the classifier is updated.

Always when probing a gate. A probe is a code change that must make the gate fail.
Confirm the build ran before you read anything into its output, and take the
verdict from the exit code. `zig build test` exiting 0 after a probe is the
failure signal; a grep over its output is not, because a compile error and a
passing run both produce an empty match.

Not needed for an assertion whose expected value is a literal in the same file,
where a reader can see directly what it excludes.

## Examples

The salvage probe. In `renderSeededViolationFix`
(`packages/pi/src/standin/playbook.zig`), step 3 submits the seed's bad draft:

```zig
const args = try renderApplyArgs(allocator, file, seed.bad_draft, source);
```

Change `seed.bad_draft` to `seed.good_draft`. The arm now submits a clean first
draft, nothing is rejected, and no salvage occurs. The retry gate went red as it
should. The salvage gate stayed green, because a clean draft differs from the bad
draft and from the baseline. With `expectEqualStrings(canonical, run.on_disk)` in
place, both go red under the same probe.

The synthesizer probe, first attempt. `if (!has_env_import)` to `if (true)` in
`synthesizeEnvFeature`. Output:

```
error: unused local constant
```

That line does not match `error: '`, so a grep for the test-failure format
reported nothing, the same as a clean pass.

The synthesizer probe, second attempt. `if (!has_env_import)` to
`if (has_env_import or !has_env_import)`. The file compiles, the branch is still
always taken, and the test
"stand-in gate: every generated env source gets the answer its shape implies" in
`packages/pi/src/standin_range_tests.zig` fails on:

```zig
try testing.expectEqual(@as(usize, 1), countOccurrences(proposed, "import { env } from \"zttp:env\";"));
```

with `expected 1, found 2` on the variants that already carried the import.

The graceful-shutdown probe. In `wakeAcceptOnShutdown`, temporarily change the
connection target from the configured server port to port `0` while keeping the
helper and test compilable. Then run:

```text
zig build test -j1 -Dtest-filter=SIGTERM --summary all
```

The corrected E2E exits nonzero at
`Wait.forFlag(&shutdown_started, true, 2_000)` with `error.TestTimedOut`
(`packages/runtime/src/server.zig:3429-3435`,
`packages/runtime/src/server.zig:3651-3654`). Because no later test client exists
before that wait, the probe disables the only ordinary wake path and the exact
claim turns red. Restore the configured port after the probe.

The topology probe passes a nonexistent unknown-package path to `collect` and
expects `error.UnknownPackage` (`tooling/production_branch_metric.zig:428-451`).
Using a nonexistent path is deliberate: that exact error proves classification
ran before file access. A companion mapping test covers every known package and a
real repository-level path (`tooling/production_branch_metric.zig:412-426`).

Two questions to put to any gate, after the sibling document's "delete its input":

1. Which runs other than the one I mean also satisfy these assertions? If a run
   without the named behavior is among them, the gate is not measuring it.
2. Did my probe compile and run? If the answer comes from grepped text rather than
   an exit code, you do not know.
3. Can this fixture reach the branch at all? Put the defect back and watch the
   fixture go red. One that stays green under its own defect is measuring
   something else, however exact its assertions are.

## Related Issues

- [a-gate-that-counts-nothing-still-reports-a-pass](a-gate-that-counts-nothing-still-reports-a-pass.md) - the parent rule, over a degenerate input rather than a degenerate assertion or probe. Read it first
- [empty-baseline-made-a-file-destroying-edit-prove-clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md) - the defect in this same subsystem that these gates exist to catch, and the same fail-open one level down
- [normalize-unions-without-dropping-members](../logic-errors/normalize-unions-without-dropping-members.md) - the polarity rule underneath the family: when something cannot see, it must widen or fail, never narrow to a pass
- [two-hole-fills-in-one-turn-do-not-compose](../logic-errors/two-hole-fills-in-one-turn-do-not-compose.md) - another stand-in loop invariant carried by an assertion rather than by structure
- Commit `6e27440e` - the seeded arms, the salvage gate correction, and the seed values that made the two outcomes distinguishable
- Commit `dcbb694e` - the intersection reproduction, the floor test that pins its shape, and the plain-record fixture that reaches nothing
- Commit `f69b28f7` - the generated synthesizer corpus and the probe that had to be re-done because it did not compile
