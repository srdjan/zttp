---
title: An export that declared no labels answered the empty set
date: 2026-08-09
category: security-issues
module: packages/zts/src/flow_checker.zig (label propagation through zttp:collections and zttp:json)
problem_type: security_issue
component: compiler
symptoms:
  - A secret returned directly is refused; the same secret put into a Dict and read back out is clean.
  - "`no_secret_leakage` reports PROVEN on a handler whose response body holds `env(\"API_SECRET\")`."
  - The analyzer emits zero label diagnostics on the laundered handler, so nothing warns and nothing blocks.
root_cause: security_issue
resolution_type: code_fix
severity: critical
related_components:
  - flow_checker
  - virtual_modules
tags:
  - zts
  - flow-analysis
  - taint-labels
  - fail-open
  - security
  - laundering
  - module-bindings
applies_when:
  - "Adding a virtual-module export that returns a value built out of its arguments"
  - "Reading a PROVEN security property as evidence that a handler discloses nothing"
  - "Deciding what an export's declared labels mean when the declaration is empty"
---

# An export that declared no labels answered the empty set

## Problem

`zttp:collections` and `zttp:json` shipped without declaring any return labels.
An export that declares nothing answers the empty set, and the empty set is a
positive claim that the value carries no provenance. So a secret put into a
dictionary and read back out arrived at the response unlabelled.

Measured against the shipped analyzer, with the control in the first row:

| Handler | `no_secret_leakage` |
|---|---|
| `return Response.json({ leaked: secret })` | refused |
| `dictSet(dictEmpty(), "k", secret)` then `dictGet(d, "k")`, returned | **PROVEN** |
| `stringifyJson(secret)`, returned | **PROVEN** |

The control matters. `??` preserves the label, literals preserve it, arrays and
objects preserve it. The dictionary was the launderer, not the surrounding code.

## Why This Is A New Shape Of The Documented Class

This is the same family as
[validate-json-strips-the-label-it-was-asked-to-check](./validate-json-strips-the-label-it-was-asked-to-check.md)
and [empty-label-set-claimed-a-value-was-clean](./empty-label-set-claimed-a-value-was-clean.md),
but it fails one step earlier, and that difference is the reason the earlier
fixes did not cover it.

The validator family relabelled: `validateJson` declared `validated` and
answered with that instead of what its input carried. The fix taught those
exports to union their arguments' labels and clear only `user_input`, because
validating is what clears `user_input`.

These two modules declared nothing at all. There was no wrong contract to
correct - they never reached the branch the earlier fix installed, because that
branch is selected by the presence of a `validated` declaration. An export with
no declaration falls to the arm that answers with whatever a callback returned,
which for `dictGet(d, k)` is nothing.

So the earlier repair was specific to exports that made a claim. The gap is
exports that make none, and "makes none" is the default every new binding
starts from.

## Solution

`FunctionBinding` gains `derives_from_args`: the return value can contain what
an argument carried, and the export validates nothing. The flow checker then
unions every argument's labels into the call's result.

The implementation is deliberately the validator path minus its one privilege:

```zig
fn parsedResultLabels(self: *FlowChecker, base: LabelSet, call_data: Node.CallExpr) LabelSet {
    var labels = self.argDerivedLabels(base, call_data);
    labels.user_input = false;   // the discharge validating is entitled to
    return labels;
}

fn argDerivedLabels(self: *FlowChecker, base: LabelSet, call_data: Node.CallExpr) LabelSet {
    var labels = base;
    for (0..call_data.args_count) |i| {
        const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
        labels = LabelSet.merge(labels, self.inferLabels(arg));
    }
    return labels;
}
```

Writing them as one function with one difference keeps the two claims
separable. "The data passes through" and "and `user_input` is cleared, because
validating is what clears it" are different statements, and collapsing them is
what produced the earlier bug in the other direction.

Two exports of `zttp:collections` are deliberately not marked. `dictEmpty` has
no argument to derive from. `dictHas` returns a presence boolean and cannot
carry the value - the rule is that the result can *contain* argument data, not
that it was computed from it.

## Why This Works

The label lattice's soundness rests on every operation being either a
propagator or a declassifier, with declassification named. Language operators
were all propagators and were handled. Module exports were treated as opaque:
the analysis asked what the export declared, and an export declaring nothing
was read as declaring cleanliness rather than as declaring nothing.

The repair does not add a new judgement. It says that an export of this shape
is a propagator, which is what it always was.

## Prevention

The probe is the one AGENTS.md already prescribes for this class, and it is
cheap enough to run on every new export that returns a value built from its
arguments:

1. Write the handler that returns a labelled value directly. Confirm it is
   refused - this is the control, and without it the test proves nothing.
2. Route the identical value through the export under test.
3. Read the security section. A property that was `---` and is now `PROVEN` is
   the defect.

Two things the gates do not catch, so do not read their green as coverage:

`scripts/check-proof-swallow.sh` sees discarded errors, not wrong answers. Every
export here returned a value that claimed more than it had checked, and no error
was discarded anywhere.

The frozen-signature gate and the module-spec renderer both saw these bindings
and had nothing to say - neither renders `return_labels`, so an export's
provenance contract is invisible to the artifacts that pin its surface.

## Measured Scope, And What Is Still Open

The neighbours were probed rather than assumed, and the class is wider than the
three modules that were fixed:

| Export | Module | Laundered? | Status |
|---|---|---|---|
| `dictSet` / `dictGet` | `zttp:collections` | yes | fixed |
| `stringifyJson` | `zttp:json` | yes | fixed |
| `sha256` | `zttp:crypto` | yes | **open** |
| `base64Encode` | `zttp:crypto` | yes | **open** |

`base64Encode` is the sharp one: the output *is* the secret, in another
alphabet. `sha256` is arguable as a one-way function and is exactly the argument
that makes it dangerous to leave undecided.

Those live behind the SDK's own `FunctionBinding`, which has no counterpart to
this field yet; the adapter carries the default and says so at the site. Closing
them is a decision about the SDK surface, not a further instance to fix
silently.

The general rule, which is the third time this writeup family has had to state
it: an export whose result can hold what it was handed carries the labels it was
handed. Fixing one instance is not closing the class, and the default a new
binding starts from is the instance most likely to be wrong.
