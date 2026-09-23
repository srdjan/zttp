# M4 T4 design note: declared-label carriage

Status: proposed on 2026-09-23. It is not accepted. Section 8 holds the
questions the owner must answer before code starts. Check C4 of the
[M4 release contract](2026-09-22-m4-release-contract.md) is written against
the approach this note names.

All citations are to local `main` at `143a5051`.

## 1. What T4 must deliver

T4 meets P8 and P9 (`docs/consumer-contract.md:764-783`). A consumer declares
that a field of data the producer did not produce carries a label, and the
flow checker enforces it. P9 holds only if the producer (a) refuses, or reports
`indeterminate` for, whole-object forwarding of a value carrying declared
fields, (b) matches a qualified path only on that path, never on its short name,
and (c) refuses a malformed entry rather than discarding it. P8 requires a
report that says, for each declared entry, whether the analysis saw the field,
and it must answer `indeterminate` whenever presence cannot be established.

Since T3, T4 also owns the authored declaration file and its loader (T3
decision Q1). C4 adds: assert `no_secret_leakage`, not a neighbor; AE4 through
validation, projection, serialization, and a helper; the AE18 negatives; AE19;
and "an empty label file must fail".

## 2. What exists today

**A dormant mechanism that breaks all three P9 conditions.** `parseExternalLabels`
(`flow_checker.zig:206`) reads `{"labels":[{field,label,reason}]}` and
`continue`s past a malformed entry or an unknown label (`:227-236`), which breaks
(c). `setExternalLabels` (`:814-826`) registers the short name after the last dot
as well, and the only lookup (`:1338`) keys on the bare property name, so
`User.email` never matches and any `.email` on any value does, which breaks (b).
Whole-object reads (`:1288-1292`) and computed access (`:1345-1362`) never
consult it, which breaks (a). It has no source: nothing ties an entry to a fetch
response, a service call, or anything else. Commit e9e5529b added it with tests
and no caller; `--data-labels` reaches only a build-report boolean
(`precompile_args.zig:118-119`, `precompile.zig:904`, `report.zig:102`).

**Labels are per value, never per path.** Every upstream source is labelled as
a whole: `fetch` and `serviceCall` return `{external}`
(`modules/src/net/fetch.zig:69`, `service.zig:81`), and `resp.json()` inherits
the receiver's labels through the fail-closed member-call rule
(`flow_checker.zig:1611-1628`). A member read carries the object's labels
(`:1312-1343`), so `resp.user.email` and `resp.user.name` are indistinguishable.

**Where labels would have to arrive.** The check path builds the flow checker
in `pipeline.check` from `CheckOptions` (`pipeline.zig:295-326`). The build path
builds its own in `buildContractWithPolicy` (`precompile.zig:2848`), reached
from `compileHandler(..., CompileOptions)` (`precompile.zig:1757`). Neither
options struct carries labels today.

**Verdicts and codes.** A labelled value at a sink sets `no_secret_leakage` or
`no_credential_leakage` false (`checkSinkLabels`, `:1986+`) and emits ZTS400 to
ZTS403 with a reason (`messageWithReason`, `:2483`). The laundering tests and
their harness (`runNoSecretLeakage`, `:4055`) already exist.

**The loader precedent.** `invariant_config.zig` parses a typed document with
default `std.json` options, which refuse unknown fields and duplicate keys, and
refuses a closed union that names neither or both members. zttp.json names the
file with an `invariants` key (`project_config.zig:24`, `:169`).

## 3. The declaration file

An authored JSON file that zttp.json names with a new `declaration` key, like
`invariants`. Version 1 has one section, `classifications`; T5 adds the
capability ceiling to the same file.

```json
{
  "version": 1,
  "classifications": [
    { "source": "fetch:api.example.com", "path": "customer.tax_id",
      "label": "secret", "required": true, "reason": "Tax identifier." },
    { "source": "service:billing", "path": "card.token",
      "label": "credential", "required": false, "reason": "Payment token." }
  ]
}
```

Every field of an entry is required; there are no defaults. The loader refuses,
with a named reason from one closed enum:

- an unknown field or a duplicate key, anywhere;
- a version other than 1, or an empty `classifications` array (C4);
- a `source` outside the grammar: `fetch:<host>` with a lowercase host name, or
  `service:<name>` with a service name as the system linker spells it;
- a `path` outside the grammar: 1 to 16 dot-separated segments, each
  `[A-Za-z_][A-Za-z0-9_]*`, with no wildcards and no array indexes in version 1;
- a `label` other than `secret` or `credential` (question Q1 of section 8 is
  about this subset);
- two entries with the same (source, path);
- a missing or empty `reason`.

The file is also given a canonical form, as P4 requires for the section. Its
binding as a graph member is question Q3.

## 4. Enforcement: origins in the flow checker

**Origin.** A value may carry an origin: a declared source and a path inside
it. A `fetch` call whose URL is a string literal gets the origin
`(fetch:<host>, response)`. Calling `.json()` on it gives
`(fetch:<host>, body, [])`. A `serviceCall` with a literal service name gives
`(service:<name>, response)`, and its `.json` gives the body root. A member read
`x.f` on a value with a body origin extends the path by `f`. A `const` binding
keeps its initializer's origin, so an alias is tracked. Any other expression
produces a value with no origin.

**Declared labels at an expression.** For a value with origin `(s, p)`, the
declared labels are the union of the labels of every entry on source `s` whose
path `q` relates to `p`:

- `q` equals `p`, or `p` extends `q` (the field or a part of it): the entry
  applies, and its P8 status becomes `matched`;
- `p` is a proper prefix of `q` (an aggregate that contains the field): the
  entry applies too, so forwarding the whole aggregate to a sink is refused
  (P9 condition a). Its P8 status becomes at least `indeterminate`;
- otherwise (a sibling): the entry does not apply.

**Precise member reads.** Today a member read unions the object's labels. For
a value with an origin, that union would give a sibling field its aggregate's
declared labels. So a member read on an origin-bearing value takes the object's
labels without the declared part and adds the declared labels of the new path.
Everything else stays as it is. This is the only change to an existing
propagation rule.

**Where precision ends, labels are kept.** A value that loses its origin keeps
the declared labels it held, because they are ordinary labels on it. Passing an
aggregate into a helper, spreading it, putting it in an array, or validating it
therefore carries its declared labels onward, and a read inside the helper
inherits them. This over-approximates, which is the safe direction. A computed
read `x[k]` on an origin-bearing value gets all declared labels of the paths
under `x`, and those entries become `indeterminate`.

**A fetch with a non-literal URL.** Its source is unknown, so its result gets
the origin "any fetch source". Every fetch entry then applies by path, and each
such entry reports `indeterminate`. A dynamic URL can never escape a
declaration.

**Short names cannot match.** Matching compares the whole path from the source
root. There is no name table keyed by property name, and `parseExternalLabels`
and `setExternalLabels` are deleted with their tests (question Q4).

**Reasons.** A leak diagnostic names the entry that fired, its source, and its
path, instead of the first reason in hash order (`findExternalReason`,
`:2469-2477`).

## 5. The P8 report

After the flow check, every entry has one status:

| Status | When |
|---|---|
| `matched` | an expression was evaluated with the entry's exact path, or a path under it |
| `indeterminate` | the entry applied only through an aggregate, a computed read, or a fetch with an unknown source |
| `absent` | the analysis never produced a value from the entry's source, or never reached the path or an aggregate above it |

A `required` entry that is `absent` refuses the build: a declaration naming a
field that never appears enforces nothing (`docs/consumer-contract.md:366-368`).
An optional one is reported. The report is written into the contract (a
`classifications` section, contract version 20), into `zts check --json`, and
into the build report, so it is never silent.

## 6. Diagnostics without a policy-hash change

A new ZTS rule moves the policy hash, and T2 showed that this makes every
recorded DeepSeek cassette stale. T4 therefore adds no rule. A leak through a
declared field reports through the existing ZTS400 to ZTS403 codes, with the
entry as the reason. A declaration the loader refuses, and a required entry that
is absent, are load and build errors with a named reason from closed enums, in
the style of the SQL schema errors, not ZTS diagnostics. If the owner prefers a
ZTS code for the absent case, the cost is one more re-record (question Q2).

## 7. Tests that C4 names

- AE4 and its control: a secret declared on `fetch:h` at `customer.tax_id`,
  returned directly, then through `validateJson`, a projection
  (`{ id: c.tax_id }`), `JSON.stringify`, `scope.using`, and a helper wrapper.
  Each is refused, asserting `no_secret_leakage`. A sibling field
  `customer.name` through the same paths is admitted.
- P9 (a): the whole `customer` aggregate returned is refused. (b): a local
  object with a `.tax_id` field, and `other.customer.tax_id` from another
  source, are admitted. (c): each loader refusal reason is driven by a case.
- P8: one case per status, including a computed read and a dynamic-URL fetch.
- AE18 negatives: a declared secret written to the cache and read back stays
  unproven, not proven (cross-call reads carry `.unknown`).
- AE19: `mask(declared, n)` with a runtime `n` keeps the label; with a literal
  `n` it declassifies, as today.
- An empty `classifications` array is refused.
- Mutation probes: drop the aggregate rule, drop the precise member read, and
  re-add a short-name lookup; each must fail a named test. A census covers the
  loader's refusal enum and the P8 status enum.

## 8. Questions for the owner

- **Q1. Label subset.** `secret` and `credential` only (recommended: they are
  the labels with sink rules and leakage properties; a consumer declaring
  `validated` or `internal` would be a laundering or a no-op), or the whole
  vocabulary.
- **Q2. A required entry the analysis never saw.** Refuse the build as a build
  error with a reason, with no new ZTS code and no re-record (recommended), or
  add a ZTS code for it, which moves the policy hash and needs one more
  DeepSeek re-record.
- **Q3. Graph binding of the declaration.** T4 defines the canonical form and
  enforces the classifications at build; the declaration binds as its own graph
  member once, in T5, when the capability-ceiling section joins it
  (recommended: one member, one payload format change). The option is to bind
  the classifications now as member 20 and rebind in T5.
- **Q4. The old `--data-labels` path.** Delete `parseExternalLabels`,
  `setExternalLabels`, the `{"labels":[...]}` format, and the build-report
  boolean, and take the declaration only from zttp.json's `declaration` key and a
  `--declaration` flag (recommended: the old path has no caller and breaks P9 as
  written). The option is to keep the `--data-labels` flag name for the new
  format.

These are recommended and are not questions unless the owner objects: the
source grammar (`fetch:<host>`, `service:<name>`), the path grammar with no
array segments in version 1, origin tracking with the aggregate rule and the
precise member read, a dynamic-URL fetch treated as any fetch source, and the
contract carrying the P8 report at version 20.
