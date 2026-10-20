---
title: A defense that also claimed what request data selects never stopped growing rules
date: 2026-10-20
last_updated: 2026-10-20
category: architecture-patterns
module: ZigTS flow interpreter defense facts (P6, production analyzer v7)
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - "Designing a sanitizer fact (a defense) that a sink accepts in place of a clean value"
  - "A review keeps finding one more operation that the defense rules miss"
  - "Request data can decide a position, a count, or an order that picks author text"
  - "A source table row passes a fact through from its input"
related_components:
  - documentation
  - testing_framework
tags:
  - zts
  - flow-checker
  - defense-facts
  - html-escaped
  - soundness
  - stated-limit
  - implicit-flow
  - mutation-testing
binds:
  - packages/zts/src/flow_interp.zig
proves: zig build test-zts
---

# A defense that also claimed what request data selects never stopped growing rules

## Context

P6 of the flow-checker redesign added defense facts beside the provenance
labels in `packages/zts/src/flow_interp.zig#Defense`. `html_escaped` is
the fact that `escapeHtml` establishes and that the HTML response sink
accepts (`packages/zts/src/flow_interp.zig#requirement`).

**2026-10-20, analyzer v7.** The interpreter now supplies the production flow
verdict through the `FlowChecker` facade. `html_escaped` and `schema_checked`
are separate defenses; provenance labels survive validation. Object validation
attaches a checked view whose evidence expires when an alias writes into its
reachable cells. The P6 design history below explains the narrower HTML claim
that production retains.

The first drafts gave `html_escaped` a wide meaning: request data controls no
markup in the value. Request data controls markup in two ways. It injects
characters, which escaping prevents. Or it decides which author characters
appear, where, and in what order, which escaping cannot touch. The drafts
tried to cover the second way with "choice rules": a cut, a positional read,
a pick, or a sort removed `html_escaped` when request data chose it.

Codex astra reviewed six drafts of the specification
(`docs/plans/2026-10-20-flow-interp-p6-spec.md`). Rounds 1 to 5 found a
family of selection paths, and each draft added rules that the next round
beat. Among them, per the review record of this work:

- a slice bound computed from escaped text, such as
  `"<img src=x onerror=alert(1)>".slice(escapeHtml(u).length)`;
- a cut that moves with the length of `u` with no exposed argument at all:
  `(escapeHtml(u) + "<").charAt(1)`;
- `toSorted()` without a comparator, which orders author markup by request
  content;
- a callback index that P5 passed as `clean`;
- a write to `length`, `Array.from` over an array-like `length`, and the
  receiver that `splice`, `pop`, and `shift` leave behind.

Each fix added a table row, a mark, or a parameter variant, and the next
round found the next channel. A late round also found that the count of loop
passes picks an author value (`xs.reduce((acc, x) => x, "<img>")`). That is
control flow, which the analysis already leaves out (D9). So the choice rules
could never be complete without implicit-flow tracking.

## Guidance

Define a defense by what its establishing operation enforces, and state
everything else as a named limit. Do not extend the fact to cover a channel
that the sanitizer itself does not touch.

The owner chose this as D25 Option B. `html_escaped` now claims only this:
every character of the value that came from request data passed `escapeHtml`,
and no later operation turned an escaped character back into markup. It says
nothing about which author characters appear, where, how often, or in what
order. The doc comment on `Defense` states the claim, and the
doc comment on `requirement` states the limit beside the HTML-context limit
(D24).

Two rules keep the narrowed claim sound:

1. Positions still carry provenance (R1). A slice bound, a computed key, and
   a callback index carry the labels of the data that computed them, and
   they combine as data. A raw request bound therefore removes the defense,
   because the bound is an exposed contributor with no defense. The callback
   index uses the `structure` parameter in `FlowInterp.paramValue`, which reads
   the labels of everything the receiver reaches.
2. An operation that makes or reinterprets characters removes `html_escaped`
   at its row edge: `replace`, `replaceAll`, `String.fromCharCode`,
   `JSON.stringify`, `JSON.parse`, `Object.keys`, `Object.entries`,
   `renderToString`, and the request readers. `JSON.stringify`,
   `Object.keys`, `Object.entries`, and `renderToString` keep
   `schema_checked`; the others remove it too. Every export that is not a
   source clears all defenses.

A cut, a pick, or an order of escaped text keeps the defense, because a
partial character reference such as `&lt` decodes to a data character and
never to a tag.

## Why This Matters

A defense whose meaning is wider than its sanitizer turns every review into a
search for one more channel. The rule set grows without converging, and each
new rule is another place for an implementer to be wrong. The channel it
tries to close (request data choosing among author values) is a selection
channel, the same shape as implicit flow, so a complete answer needs
implicit-flow tracking that the analysis deliberately does not do.

A narrow claim with a stated limit is checkable. A reader of the proof
receipt can see what the fact covers, and a test can pin the limit. Test 10
(`request data that selects author characters keeps html_escaped, as D25
states`) records the limit, so a later phase that narrows it must
change that test on purpose.

A second finding from the same work: a source table row that passes a fact
through from its input needs an evaluator test, not only a census row.
`escapeHtml` keeps `schema_checked` from a validated argument. The census
table checked that the row said so, but no evaluator test exercised it, so a
mutation that made `escapeHtml` keep nothing survived. Test 6 now checks
`escapeHtml(v)` with a seed that holds `schema_checked`. This is
the same shape as [a gate can be non-vacuous and still
porous](../conventions/a-gate-can-be-non-vacuous-and-still-porous.md): a
census checks that a declaration exists, not that the evaluator honours it.

## When to Apply

- When a new defense fact is proposed (a URL-escaped fact, a SQL-parameter
  fact), write its claim as what the establishing export enforces, and list
  the channels it does not cover beside D9, D24, and D25.
- When a review finds a third path of the same shape that a rule set misses,
  stop adding rules. Ask whether the claim is wider than the sanitizer, and
  bring the narrowing to the owner as a numbered decision.
- When a table row states a pass-through, an establishment, or a removal,
  add one evaluator test per effect, and mutate the effect to confirm that
  the test fails.

## Examples

The claim before and after D25, for the same program:

```ts
// u is request data
const n = escapeHtml(u).length;
return Response.html("<img src=x onerror=alert(1)>".slice(n));
```

- Before (choice rules): `slice` with an exposed bound is a choice, so the
  result loses `html_escaped`. The next review then finds
  `(escapeHtml(u) + "<").charAt(1)`, where no argument is exposed, and a new
  rule follows.
- After (D25 Option B): the result holds `html_escaped`. The value holds no
  unescaped request character. The author tag that the length of `u` selects
  is outside the claim, and the stated limit says so.
- Still refused: with `n = u.length`, the bound is raw request data with no
  defense, so the result holds no `html_escaped` (R1).

## Related

- [An empty label set claimed a value was clean](../security-issues/empty-label-set-claimed-a-value-was-clean.md)
  names the class this guards against: a value that claims more than was
  checked.
- [A proxy signal carried a proof it never claimed](../logic-errors/a-proxy-signal-carried-a-proof-it-never-claimed.md)
  is the same lesson for determinism: the fix narrowed the claim to what the
  check measures.
- [validateJson strips the label it was asked to check](../security-issues/validate-json-strips-the-label-it-was-asked-to-check.md)
  describes the former `validated` provenance bit. Production uses the separate
  `schema_checked` defense in `flow_interp.zig`; its `defense_sources` table
  supplies the parsed-value validation rules.
