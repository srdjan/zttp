---
title: A gate can be non-vacuous and still porous, and only a mutation shows it
date: 2026-09-19
last_updated: 2026-09-20
category: conventions
module: packages/tools (invariant drift gate), packages/runtime (adapter bridge), packages/proof-checker (acceptance kernel), repo-wide (attacking any gate)
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "Guarding a property that has no runtime symptom, so only a source-level gate can hold it"
  - "Writing or reviewing a gate that scans source text rather than comparing typed values"
  - "Adding a carve-out, an allowlist, or a positional region to a gate"
  - "Reviewing a gate that was fixed in the last round, whose new machinery has no probe yet"
  - "Counting probes per input, per name family, or per file, instead of per verdict"
  - "Reading a gate's source and concluding that its net catches what its name says"
tags:
  - testing
  - build
  - gates
  - vacuous-check
  - fail-open
  - verification
  - probes
  - mutation-testing
  - threat-model
---

# A gate can be non-vacuous and still porous, and only a mutation shows it

## Context

The acceptance kernel in `packages/proof-checker/` decides whether a deployed
artifact is accepted. One of its decisions is whether the adapter that this
binary linked is the adapter the artifact's specification needs. That decision
was once unable to fail. The bridge file states the history in its own header at
`packages/runtime/src/invariant_adapter.zig:4-8`: before the file existed, "the
producer bound that member from `pcc.invariant`'s own constant and the consumer
compared it against the same function, so an artifact whose specification named
a kind the linked adapter did not enforce was undetectable: the comparison had
one source."

The repair gave the comparison two sources. `linked_manifest` is filled field by
field from the native module at `packages/runtime/src/invariant_adapter.zig:44-49`,
`linkedDigest()` hashes that manifest at `:64-66`, and `require()` reads the
consumer's expectation `pcc.invariant.adapterDigest()` at `:75-79` and compares
the two. The bridge file was added by the commit "feat(invariant): bind the
linked adapter manifest, not the checker's constant". Every commit cited in this
document is named by its subject and not by its hash, because this history was
local when the document was written and a rebase before it is pushed would
invalidate every hash written down here; find one with `git log --grep`.

The repair has one awkward quality: it is a property of how the code is written,
not of what the code computes. A bridge that copies the kernel's constant into
`linked_manifest` produces exactly the digest an honest bridge produces. Every
unit test passes. Every refusal test passes. The digests compare equal, because
they are the same value arriving twice. There is no runtime symptom at all. Only
a source-level gate can hold this property, and that gate is
`packages/tools/src/invariant_drift_gate.zig`, run by the build as
`zig build test-invariant-drift` (`build.zig:311`).

The friction is what happened next. The gate went through four review rounds. In
each round the gate was read, and in each round the reading said the gate was
working. The reading was correct. Every check fired. Every probe rejected its
mutation. The gate has floors that refuse an empty input, an empty row set and a
scan that recognises nothing, so it is not vacuous by any shape named in
[docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md](a-gate-that-counts-nothing-still-reports-a-pass.md).

And in rounds 1, 2 and 3, single-line edits to the bridge still passed the gate
at exit 0. The round 2 commit, "fix(invariant): deny by default over the kernel
namespace, and scan linkedDigest", records how they were found: "shown
empirically by the re-reviewer running the head gate against single-line
mutations: three next-nearest regressions passed the whole gate at exit 0".
Round 3, "fix(invariant): scan the whole bridge, resolve aliases, and floor the
scan", found five more and says where they were: "Five single-edit regressions
sat in the two places round 2 introduced and did not probe".

Reading the gate did not find any of them. A mutation harness found all of them.

## Guidance

### The harness

The harness has five steps. None of them needs new code in the gate.

**1. Build the gate as its own binary.** Its exit status must be its own verdict
and nothing else. This repo already installs it separately for that reason, at
`build.zig:329-336`, with the comment: "The gate binary on its own, so a single
mutation probe can be run directly and read from its exit status. Routing a
probe through the aggregate step above would mix the gate's verdict with seven
test suites."

```
zig build invariant-gate          # writes zig-out/tooling/invariant-drift-gate
```

**2. Copy the gate's inputs into an isolated directory.** This gate declares its
inputs as a table: an `Input` enum at `packages/tools/src/invariant_drift_gate.zig:52`
and a `paths` array at `:76` that gives one path per member. It finds its root by
walking up from the working directory looking for `packages/proof-checker/src/invariant.zig`
and `build.zig.zon`, in `findRepoRoot`. So a directory that holds those declared
files plus `build.zig.zon` is a complete, isolated input set, and the binary runs
against it with no other change.

**3. Confirm the copy is clean before you attack it.** Run the binary in the copy
and require exit 0. A harness that was already failing tells you nothing about
your edit. Measured at this tree, in an isolated copy holding only the declared
inputs:

```
application invariants: 21 sources, 2 catalog rows, 2 kinds over 2 wire schemas,
2 native exports, 2 linked adapter predicates and 16 compiled evidence markers
agree; 83 mutation probes reject
exit=0
```

**4. Apply one edit, run the real binary, read the exit status.** One edit. Not
two. A mutation that changes two things cannot tell you which one the gate saw.
The gate documents its own codes in its usage text at
`packages/tools/src/invariant_drift_gate.zig:2912`: 0 accepted, 1 rejected, 2 the
mutation slipped through under `--mutate`, 3 the probe could not find its anchor
or the repository was not found.

**5. Revert from a pristine copy, not by an inverse edit.** Keep an untouched
copy of each file you mutate and restore from it. An inverse edit can fail
silently and leave the next mutation running on top of the last one.

### What makes a mutation faithful

A mutation is a claim that a developer could write this line and the gate would
not notice. Two shapes look like passes and are not regressions:

- **A binding with no use copies nothing.** Binding a kernel value to a name and
  never reading it changes no value that reaches the comparison. If the gate
  exits 0, you have learned that the scanner is blind to that spelling. You have
  not learned that a regression slips, because there is no regression.
- **A use with no binding does not compile.** Reading a member the kernel does
  not declare, or through a name nothing binds, is not code a developer could
  commit. The gate scans text and does not compile it, so this can exit 0 while
  never being a possible edit.

The faithful form is the one a developer would actually write when taking the
shortcut: it compiles, and the copied value reaches the comparison. Write that
form. If it exits 0, you have found a hole.

There is one deliberate exception, and it is worth knowing because the gate uses
it itself. For a text-scanning gate, a mutation that does not compile is still
useful as a **blindness measurement**, as long as you label it that way. The gate
ships exactly such a probe: `probeBridgeScanBlind` rewrites every `pcc.invariant.`
to `kern.invariant.` throughout the bridge, which binds nothing and would not
compile, and its purpose is to make the scan recognise zero reads so the
`adapter_scan_blind` floor fires. That floor lives at
`packages/tools/src/invariant_drift_gate.zig:1492-1505` and exists because, as
the comment there says, "a spelling it cannot follow reads as a clean file".

### What to attack first

Attack in this order. It is ordered by yield, and the ordering was learned the
expensive way.

**1. Whatever the last round introduced and did not probe.** Each fix adds
machinery, and machinery is unprobed on the day it lands. Round 2 introduced the
bridge region split and the alias resolver. Round 3's five holes were both in
those two places, which is what its commit message says. The gate's own comment
now records this at `:1443-1449`: "An earlier version stopped at the first test,
which was a second carve-out, unargued and unprobed."

**2. Every carve-out.** A carve-out is a hole by construction. You built a region
where the forbidden thing is allowed, so the only question is how wide it is.
This gate has two: `require`'s body may read `adapterDigest` (the
`comparison_kernel_surface` allowlist at `:678`), and the file's tests take the
same surface. Both carve-outs now carry a probe of their own, and the probe
comment states the reason: "A carve-out is a hole by construction, so it gets its
own probe: without this, a carve-out widened to the whole file would show no
symptom here."

**3. Both ends of every half-open range.** A positional region has two boundaries
and an off-by-one at either end silently stops scanning. The gate probes the far
end specifically, with the comment: "The carve-out is a half-open range, and an
off-by-one at its end would leave everything below it unscanned."

**4. Any name-shaped heuristic.** If the forbidden set is derived by matching a
substring inside a name, feed it a name that does not carry the substring. Round
1 derived its forbidden set as "contains adapter, plus `kind_table` and
`kindInfo`". Round 2's commit lists what that admitted: "`Kind`, `Operation`,
`SinkId`, `schema_version`, `catalog`, `digest_domain` and whatever the kernel
grows next".

**5. Relocation, not only substitution.** If a region is positional, do not change
what a declaration says, change where it sits. Delete a function and re-declare
it below the boundary.

**6. Alias, not only spelling.** Rebind the import. Try the inline form, the
`pub const` form, and a transitive binding that names another binding. All three
slipped round 2 and all three are closed now.

### Account for checks, not for inputs

This gate had a second and separate gap, found by review rather than by mutation,
and it is the one that generalises furthest.

The gate had two coverage tests. `test "every independent input carries a
mutation probe"` at `:3090` loops over the `Input` enum, which has 21 members.
`test "every adapter and manifest check is exercised by a probe"` at `:3103`
loops over `Check` but only over the members whose names contain "adapter",
"manifest", "dispatch" or "bridge", which is 19 of them at this tree.

Neither test counts all of `Check`. So a check could be added with no probe and
be invisible to both. The replacement test records the measured result at
`:3134-3138`: "Neither counts checks, so a check added with no probe was
invisible to both: 23 of them had never been observed rejecting anything, and one
such check shipped on this branch with review as the only thing that caught it."

The fix is a census. `test "every check is either probed or allowlisted with a
stated reason"` at `:3134` iterates `@typeInfo(Check).@"enum".fields` at `:3141`
and requires each member to be either probed or to hold a row in
`deliberately_unprobed` (`:2805`) whose reason is at least 80 bytes, so a row
cannot be a placeholder. It refuses a row that is stale, meaning a check that is
both probed and allowlisted. It then asserts the values expected rather than a
remainder (`:3175-3176`) and adds two ratchets (`:3190-3191`):

```zig
try testing.expectEqual(@typeInfo(Check).@"enum".fields.len, probed + allowlisted);
try testing.expectEqual(deliberately_unprobed.len, allowlisted);
try testing.expect(probed >= 67);
try testing.expect(deliberately_unprobed.len <= 9);
```

The two ratchets point opposite ways on purpose: a probe may be added and never
removed, and an allowlist row may be removed and never added. The comment beside
them explains why the ceiling replaced an earlier floor on the table's size:
"Nothing should guarantee that some number of checks stays unprobed, and that
assertion duly failed the day two of its rows became probes."

Measured at this tree: `Check` has 76 members, 67 are probed, 9 are allowlisted,
and the probe table holds 83 rows, which the binary confirms with
`--list-probes`. Some checks carry more than one probe, which is why 83 exceeds
67.

### Why the census, and not a better exit code

The gate does report a probe that slips. Under `--mutate <name>` that is exit 2,
documented in the usage text at `:2912`. In the full run the same condition exits
1 with the message "probe 'X' passed validation; Y checks nothing".

Neither of those can help with an unprobed check, because both are reports about
a probe that ran. A check with no probe produces no message at all: nothing looks
for it, nothing times out, nothing counts it. The reporting channel was never the
problem. The census was missing. A gate can only tell you about the probes it
has, so the thing that has to be complete is the list of what needs a probe, and
that list is the verdict enum.

## Why This Matters

**Vacuity and porosity are different failures, and only one is visible by
reading.**

A vacuous gate checks nothing, and the shapes it takes and the delete-its-input
check that finds them are in
[docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md](a-gate-that-counts-nothing-still-reports-a-pass.md).

A porous gate checks something real, over a real input, and what it checks is
narrower than what it is named for. Reading its source tells you what it does.
The question a porous gate raises is what it does not do, and a source file has
no section that lists that. You cannot read your way to it. You have to feed the
gate something it should reject and see whether it does.

**Passing probes prove that the probes fire. They prove nothing about what is
unprobed.** A probe is an example the gate's author wrote, so the set of
mutations the probes cover is exactly the set the author thought of. The floor
`covered >= 19` at `:3131` is a floor on how many examples the author wrote. It
is not a floor on the property. This is the same caution as in
[docs/solutions/conventions/difference-is-not-the-claim-and-a-probe-must-compile.md](difference-is-not-the-claim-and-a-probe-must-compile.md).
Here the weaker assertion is "these 83 edits are rejected", and the
name claims "the bridge does not read the kernel's value".

**A text scan over source has no terminating condition.** There is always another
spelling. Every round closed the spellings it was shown and every round was shown
new ones. That is not a sequence that converges, because the input is a
programming language and a language has unbounded ways to name the same value.

So the terminating condition has to come from somewhere other than the scan. Two
places it came from here.

*Structure.* `packages/modules/build.zig` gives the `zttp-modules` module exactly
one import, `zttp-sdk`, and `packages/zttp-sdk/build.zig` declares no imports at
all. The native module therefore cannot import the acceptance kernel: an attempt
does not compile. That side needs no scan and no probe, and the guarantee cannot
be weakened by a spelling.

*A bounded threat model, written down.* The bridge has no such guarantee, because
it lives in the runtime package, which imports both sides by design. Round 4
stopped widening the scan and instead bounded what the scan claims. The gate now
states the bound in its own source at `:711-720`:

> Threat model: an accidental regression by a developer. Deliberate evasion -
> `@field(pcc.invariant, "kindInfo")`, a re-export of the package through a third
> module - is not closed here and is not meant to be.

That statement is verifiable and it is verified below: the `@field` form still
escapes the namespace scan at this tree. The value of writing the bound down is
that it stops the next reviewer reading a green gate as a guarantee it never
made. The docs commit that made this correction, "docs(invariant): correct the
limit statement; the package graph guards one side", opens with the reason: "A
limit statement that under-claims is worse than none."

**A positive requirement narrows the evasion surface, but it does not close
it.** A rule that says "must not name X" is defeated by any new way to name X,
and enumerating those ways is the unbounded problem above. A rule that says
"this body must contain this derivation" does not need that enumeration, which
is what makes it the cheaper half of the pair. The gate has one of each over
`linkedDigest`, at `:1513-1523`: it requires exactly one definition, requires
the body to contain `adapterManifestDigest(linked_manifest)`, and separately
forbids `adapterDigest`.

Be precise about what that buys, because the obvious stronger claim is false.
The positive clause tests for the presence of one spelling, not for derivation.
A body holding a dead `_ = adapterManifestDigest(linked_manifest);` and
returning a helper declared below the first test satisfies it, and satisfies
every other named check too: that shape was measured, and the run was stopped
only because the edit disturbed the line a probe anchors on, which is the
accidental tripwire this document says at "Do not rely on a probe anchor as a
check" not to rely on. The positive rule is a text-shape rule whose terminating
condition is the same bounded threat model as the negative one.

Nor does the `@field` measurement below isolate positive from negative. The
pin's negative clause is a raw substring test for `adapterDigest`, and
`@field(pcc.invariant, "adapterDigest")` contains that substring, so it would
have been caught either way. What that spelling escapes is the alias-qualified
region scan, which looks for `<alias>.` and finds no alias there. The
measurement separates an alias-qualified scan from a raw substring test, not a
negative rule from a positive one.

The honest form of the lesson: state what the code must do wherever you can,
because it spares you enumerating a vocabulary you cannot close, and keep it
beside the negative clause and the region scan rather than in place of them.
The price is that a positive rule trips on honest refactoring, a line break
inside the call or a rename of `linked_manifest`, and it trips closed.

## When to Apply

Attacking a gate with a mutation harness costs an hour or so once the harness
exists, and minutes per mutation afterwards. It is worth that when several of
these hold:

1. **The property has no runtime symptom.** If a violation produces a wrong
   answer somewhere, a test can catch it and the gate is a convenience. If a
   violation produces exactly the right answer from the wrong source, as here,
   the gate is the only thing that can catch it, and its holes are the whole
   exposure.
2. **The gate scans text.** A gate that compares typed imported values cannot be
   evaded by a spelling, because a value has no spelling. The gate's own header
   says this at `:11-14`: "A surface that is data is imported and compared as a
   value: a typed import cannot be misparsed." Attack the text-scanning half.
3. **The gate has a carve-out, an allowlist, or a positional region.** Each one
   is a hole you built on purpose, and the question is only its width.
4. **The gate was fixed recently.** Every fix adds machinery, and the new
   machinery is unprobed on the day it lands. Attack the newest code first. Two
   of the four rounds here found their holes in exactly the previous round's
   addition.
5. **Undoing the feature is one line.** If there is a single edit that restores
   the original hole whole, that edit deserves its own named check and its own
   probe. The gate says so at `:1508-1511`: "This is the one line that, changed,
   restores the original hole whole."
6. **The gate is cheap to run in isolation.** A standalone binary, file inputs,
   seconds per run. If a mutation costs a full CI pass, attack a narrower unit.

It is not worth it when the gate compares typed values end to end, or when the
property it names already fails a test on violation. In those cases spend the
time on the test instead.

Whatever a mutation round finds, close it with a census rather than with one more
probe. One more probe closes one more spelling. A census over the verdict enum
closes the class of "added a check, forgot the probe" permanently, and it is the
part of this work that keeps paying.

## Examples

Every result below was measured at this tree by copying the gate's 21 declared
inputs plus `build.zig.zon` into an isolated directory, applying one edit to
`packages/runtime/src/invariant_adapter.zig` in that copy, and running
`zig-out/tooling/invariant-drift-gate` from it.

### 1. One forbidden token is one spelling

Round 1's three "must not read the kernel" checks each forbade exactly one token.

```zig
// passed the round 1 gate at exit 0
.identity = pcc.invariant.adapter_identity,
```

Its commit explains why every other check stayed quiet: "passed the floor test
because the digests are then equal, and passed the field-for-field test because
the strings compare equal by value. Identity and store schema would have been one
constant meeting itself again, silently."

At this tree the same edit is rejected:

```
exit=1
application invariants: adapter_value_copied: packages/runtime/src/invariant_adapter.zig:
the bridge ahead of require reads the kernel's 'adapter_identity' instead of
deriving it from the linked adapter
```

The same round also admitted, in the executable graph,
`pcc.invariant.adapterManifestDigest(pcc.invariant.expected_adapter_manifest)`,
which contains no `adapterDigest` substring. That shape is now the gate's own
`graph-kernel-value` probe, which expects `adapter_value_copied`.

### 2. The whole feature, undone in one line

Round 2's scanned bridge region covered the two manifest bodies only, so
`linkedDigest` sat outside the scan.

```zig
pub fn linkedDigest() [32]u8 {
    return pcc.invariant.adapterDigest();   // passed the round 2 gate at exit 0
}
```

The round 2 commit states what that restores: "producer and activation both call
`linkedDigest()`, the checker compares against `adapterDigest()`, one constant
meets itself, and the floor test passes trivially because both sides become the
same value."

At this tree:

```
exit=1
application invariants: adapter_value_copied: packages/runtime/src/invariant_adapter.zig:
the bridge ahead of require reads the kernel's 'adapterDigest' instead of
deriving it from the linked adapter
```

Two independent checks now cover this edit. The deny-by-default region scan
answers first, because `linkedDigest` sits ahead of `require`. If the read were
spelled in a form the region scan admitted, the name-pinned check at `:1513-1523`
answers instead, as example 6 shows.

### 3. A name-substring heuristic admits every uppercase enum

Round 1 derived its forbidden set by matching "contains adapter" in the member
name. `Kind` does not contain it.

```zig
const ProbeKind = pcc.invariant.Kind;   // passed the round 1 and 2 name heuristic
```

At this tree:

```
exit=1
application invariants: adapter_value_copied: packages/runtime/src/invariant_adapter.zig:
the bridge ahead of require reads the kernel's 'Kind' instead of deriving it from
the linked adapter
```

The gate ships the load-bearing version of this as `probeBridgeKernelKind`, whose
comment names the class: "The row ordinal comes from the kernel's enum instead of
the native table. The name carries no 'adapter', so a rule keyed on name shape
admits it."

```zig
.kind_ordinal = @intFromEnum(pcc.invariant.Kind.balance_conservation_v1),
```

The inversion that closed the class is in `disallowedKernelRead` at `:821`, with
the argument at `:658-667`: "The rule is therefore 'nothing, except these, and
here is why each one is not a value', rather than 'anything, except these', which
only ever catches the spelling it was written against."

### 4. Relocation past a positional boundary

Round 3's two holes were both below the bridge's first `test "`, where round 2's
scan stopped. Neither changes what a declaration says. Both change where it sits.

A `pub const` declared after the tests and read by the runtime region above them,
now the gate's `bridge-tail-declaration` probe:

```zig
    try requireLinked();
}
pub const kernel_pv = pcc.invariant.kindInfo(.balance_conservation_v1).predicate_version;
test "probe tail" {
```

`linkedDigest` deleted and re-declared below the tests, returning the kernel's
expectation, now `bridge-digest-relocated`:

```zig
    try requireLinked();
}
pub fn linkedDigest() [32]u8 {
    return pcc.invariant.adapterDigest();
}
test "probe relocated" {
```

Both are rejected at this tree, by different checks, which is the point of
naming the expected check per probe:

```
probe 'bridge-tail-declaration' rejected by adapter_value_copied (expected adapter_value_copied):
  the bridge tests reads the kernel's 'kindInfo' instead of deriving it from the linked adapter
probe 'bridge-digest-relocated' rejected by bridge_digest_derivation (expected bridge_digest_derivation):
  linkedDigest does not hash the linked manifest
```

The fix was two-sided. The scan now covers the whole comment-stripped file in
four regions (`:1467-1475`), and `linkedDigest` is additionally pinned by name,
because, as `:1508-1510` says, "the region split above is positional and a
declaration can move".

### 5. Aliases, resolved to a fixed point

Three alias forms slipped round 2, per the round 3 commit: a `pub const`
binding where only a bare `const ` was accepted, the inline `@import` form that
nothing seeded, and a transitive binding because resolution ran once rather than
to a fixed point.

```zig
const k2 = pcc;                                        // transitive
return k2.invariant.adapterDigest();

return @import("zttp_proof_checker").invariant.adapterDigest();   // inline
```

Both are rejected at this tree, each with
`adapter_value_copied: ... the bridge ahead of require reads the kernel's
'adapterDigest'`. `kernelAliases` at `:754` seeds the inline spellings at
`:760-763`, accepts both `const ` and `pub const ` in `boundDeclaration` at
`:737-739`, and runs its resolution loop until nothing new appears.

### 6. The gap that remains, measured rather than assumed

The gate's threat model excludes `@field`. That exclusion is real, and it is
worth knowing exactly how much it costs.

A binding through `@field` that reads an unrelated kernel member passes:

```zig
const ns = @field(pcc, "invariant");
const sneaky = ns.some_kernel_member;   // exit=0, the scan recognises nothing here
```

The alias resolver accepts three right-hand sides: one ending in `.invariant`,
one already naming a known namespace, and one naming a known package spelling,
which binds a package alias and registers its `.invariant` as a namespace. That
third branch is what closes the transitive form above. `@field(pcc, "invariant")`
matches none of the three, so it binds a namespace the scan cannot follow. That
result is a blindness measurement and not a regression, because nothing uses the
value.

The faithful version, which compiles and does reach the comparison, is rejected,
but not by a named check:

```zig
const ns = @field(pcc, "invariant");
...
.identity = ns.adapter_identity,
```

```
exit=1
application invariants: probe 'adapter_bridge' could not mutate its input: ProbeAnchorMissing
```

This is worth stating plainly. The edit removed the exact string that the gate's
own `adapter_bridge` probe anchors on, which is
`.identity = native.adapter_manifest.identity,`. The gate fails closed, so the
edit does not ship, but the message names a probe rather than the copy. The probe
table's anchors act here as a second and partly accidental tripwire. Do not rely
on that. It holds only for edits that happen to collide with an anchor.

A different `@field` form is caught by a positive rule rather than a negative
one, which is the useful half of this example:

```zig
return @field(pcc.invariant, "adapterDigest")();
```

```
exit=1
application invariants: bridge_digest_derivation: linkedDigest does not hash the linked manifest
```

The deny scan does not see that read. The requirement at `:1518-1520`, that
`linkedDigest`'s body must contain `adapterManifestDigest(linked_manifest)`,
catches it anyway, because the body no longer contains the derivation it is
required to contain.

Two further reads are caught by plain substring rather than by the namespace
scan, and they survive an alias because they do not depend on one: any occurrence
of `expected_adapter_manifest` anywhere in the bridge is refused by
`bridge_reads_native` at `:1420-1422`. Measured, both of these exit 1 with
"fills the linked manifest from the kernel's expected table":

```zig
.identity = pcc.invariant.expected_adapter_manifest.identity,
.exports  = @field(pcc, "invariant").expected_adapter_manifest.exports,
```

### 7. The census that replaced two partial counts

Before, two tests, neither of which counted verdicts:

```zig
test "every independent input carries a mutation probe" {
    for (std.enums.values(Input)) |input| { ... }      // 21 members
}

test "every adapter and manifest check is exercised by a probe" {
    inline for (@typeInfo(Check).@"enum".fields) |field| {
        const names_family =
            std.mem.indexOf(u8, field.name, "adapter") != null or
            ...                                        // 19 of 76 members
    }
}
```

After, one test that accounts for every member of the verdict enum exactly once,
at `:3134-3192`. Its shape is the transferable part:

```zig
inline for (@typeInfo(Check).@"enum".fields) |field| {
    // probed, or allowlisted with a reason of at least 80 bytes, or a named error
    ...
}
try testing.expectEqual(@typeInfo(Check).@"enum".fields.len, probed + allowlisted);
try testing.expectEqual(deliberately_unprobed.len, allowlisted);
try testing.expect(probed >= 67);
try testing.expect(deliberately_unprobed.len <= 9);
```

The nine allowlist rows at `:2805` are not a backlog. Each one argues a
mechanism, not a conclusion, and the table's own header says why that distinction
was added: "Each reason must state the mechanism it claims, not only the
conclusion: three of these once named a mechanism that did not hold while
reaching a conclusion that did." Eight of the nine are structural floors under a
comparison, which fire when the comparison's input is gone, duplicated or empty,
and each row names what is probed over the same surface instead. For example, the
row for `compiler_resolver_missing`:

> a two-armed floor: the gate requires exactly one 'fn resolveLedger(', so a
> second definition trips it as surely as none. probeCompiler locates its rows
> through that signature and yields ProbeAnchorMissing without it [...] Both
> paths are reported as a probe failure, never as agreement.

Finally, the gate's own tests hang off the same build step as the gate, at
`build.zig:317-326`, for the reason recorded there: "A probe is code. One that
does not compile runs no check, and a failed build and a passing gate both emit
no failure message." That is the rule from
[docs/solutions/conventions/difference-is-not-the-claim-and-a-probe-must-compile.md](difference-is-not-the-claim-and-a-probe-must-compile.md),
and the census above is only worth its floors because the build refuses to run
the gate if the census does not compile.

## Related Issues

- `CONCEPTS.md`, the Gate and Probe entries - the whole class in one place, kept current as these documents change; read it before restating any of them here
- [a-gate-that-counts-nothing-still-reports-a-pass](a-gate-that-counts-nothing-still-reports-a-pass.md) - vacuity, the failure this one is not
- [difference-is-not-the-claim-and-a-probe-must-compile](difference-is-not-the-claim-and-a-probe-must-compile.md) - a degenerate assertion and a degenerate probe, the two failures between vacuity and porosity
