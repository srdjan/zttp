---
title: An empty label set claimed a value was clean
date: 2026-08-02
category: security-issues
module: ZigTS flow checker data-label inference
problem_type: security_issue
component: tooling
severity: critical
symptoms:
  - "`zts check` reported `no_secret_leakage ... PROVEN` for handlers that returned `env(\"SECRET_KEY\")` to the client."
  - "Every leaking program type-checked and passed strict mode, so no other gate objected."
  - "`scripts/check-proof-swallow.sh` stayed green throughout, because nothing was discarded - a wrong answer was returned."
root_cause: logic_error
resolution_type: code_fix
related_components:
  - documentation
  - testing_framework
tags:
  - zts
  - flow-checker
  - taint-analysis
  - data-labels
  - soundness
  - fail-open
  - proof-boundary
  - compiler-analysis
---

# An empty label set claimed a value was clean

## Problem

`LabelSet` (`packages/zts/src/module_binding/types.zig:107`) carries data provenance through the flow checker: `secret`, `credential`, `user_input`, and so on. The empty set means "this value carries nothing", and that is a load-bearing positive claim - it is what lets an ordinary handler discharge `no_secret_leakage` at all.

Five separate code paths returned the empty set for a different reason: the walk had not looked at the value. Absence of evidence was encoded identically to evidence of absence, so the compiler proved a security property for handlers that leak a secret into the HTTP response body.

## Symptoms

Each of these type-checks, passes strict mode, and reported `no_secret_leakage ... PROVEN` before its fix:

```js
// 1. behind a helper chain past the summary cap
function l10() { return env("SECRET_KEY"); }   // ... chained through l1
function handler(req) { return Response.json({ v: l1() }); }

// 2. hoisted egress options - not an object literal at the call site
const opts = { headers: { authorization: token } };
fetch("https://api.example.com/v1", opts);

// 3. computed key - invisible to by-name extractors even in a literal
fetch(url, { body: "ping", [field]: token });

// 4. a closure passed to a higher-order function
const keys = ["a", "b"].map(() => env("SECRET_KEY"));

// 5. a callback a module invokes
const results = parallel([() => env("SECRET_KEY")]);
```

## What Didn't Work

**Reading the arms that handle each node kind.** Two audits worked by inspecting `inferLabels`'s switch and reasoning about which tags reach the `else => LabelSet.empty` fallback. The second enumerated the unhandled tags that can appear in a value position, concluded only `sequence_expr`/`comma_expr` qualified - which no parser path emits - and reported the fallback as not a live hole. Arrow and function expressions land in that same arm and are passed as arguments constantly. The audit missed the most common laundering shape in the language while looking directly at the code that caused it.

**Trusting the standing soundness gate.** `scripts/check-proof-swallow.sh` scans the eleven analysis files between parsed IR and reported verdict and fails on any discarded error not carrying a reason. It was green through all five instances and is structurally blind to this class: nothing is swallowed, a function returns a value that is wrong. Its own header cites that "a taint fail-open in this repo once survived fourteen review passes" - the gate built from that lesson covers only the swallowed-error half of it.

**Fixing one instance and assuming the class was closed.** After the closure arm landed (`packages/zts/src/flow_checker.zig:1516`), the same laundering still worked through `parallel([...])`, because a module export answers with its *declared* return labels and those cannot describe what a caller's callback returns.

## Solution

Every fix separates "carries nothing" from "could not look".

**A label for not knowing.** `DataLabel` gained `unknown` (`packages/zts/src/module_binding/types.zig:102`), widening the enum to `u4` and `LabelSet` to `packed struct(u16)`. `userCallLabels` bails to it from every exit that cannot read a callee body (`packages/zts/src/flow_checker.zig:1653`):

```zig
const unresolved = LabelSet.merge(arg_union, .{ .unknown = true });
```

A sink that receives it clears every property that sink decides, rather than holding it (`packages/zts/src/flow_checker.zig:1987`, `2210`):

```zig
if (labels.has(.unknown)) self.clearSinkProperties(sink);
```

That widening exposed a sixth bug of the same family: `LabelSet.isEmpty` masked bit 7 off as padding (`packages/zts/src/module_binding/types.zig:165`), and `nondeterministic` had moved into that bit, so a set carrying only it read as empty.

**A sink for an object the walk cannot read field by field.** A non-literal options argument, or a literal with a computed key, routes the whole object to `egress_opaque` (`packages/zts/src/flow_checker.zig:1925`, `2159`), which carries the same checks the URL and header arms carry. Detecting the computed key needs the `is_computed` flag, not a failed name lookup (`packages/zts/src/flow_checker.zig:2432`): `getPropertyKeyName` resolves `{ [field]: v }` to `"field"`, the *variable* holding the key, so a by-name search both misses the real field and answers for one that is not present.

**Closures carry what they produce**, both as a value (`packages/zts/src/flow_checker.zig:1516`) and as a callback a module invokes (`packages/zts/src/flow_checker.zig:1540`, `1554`). Only closure-derived labels are unioned into a module call's result, never all arguments - `cacheSet("ns", key, userInput)` answers a boolean that is not the user's data, and tainting it would demote handlers for nothing. For durable exports `nondeterministic` is dropped and only that label: a clock read inside `step("ts", () => Date.now())` is recorded and replayed, so it is identical on every run, while a secret the same callback returns is still a secret.

Verified on the full gate after each change:

```
>> verify.sh: all CI test-job steps passed
Suites: 43 total, 43 passed, 0 failed
```

The published first-draft veto-pass rate held at 90% (10/11) across all five fixes ([docs/convergence.md](../../convergence.md)) - the replay is a ratchet that fails if a recorded first-draft outcome flips, so that is a checked result. It also says the eleven-case corpus is too small to see this fence move.

## Why This Works

The label set answers "what does this value carry". The empty set is a real answer to that question. The defect was reusing it for a question the walk never asked.

`unknown` splits the two, and the direction of every fix is the same: when the analysis cannot see, it widens. An opaque options object reaches *more* sinks, not fewer. An unsummarizable call clears *every* property its sink decides. That converts a false `PROVEN` into an honest "not proven", which costs a user precision instead of the guarantee.

The polarity rule this instantiates is already recorded one pass over, in [normalize-unions-without-dropping-members](../logic-errors/normalize-unions-without-dropping-members.md): a bounded path in a compiler analysis may degrade quality but must never drop an obligation, because dropping one turns a rejection into an acceptance. The same rule, in a different pass, with a different representation.

## Prevention

**Probe the position; do not read the arm.** Each of the five was found in minutes by laundering a secret through one syntactic position and running the real compiler:

```bash
cat > /tmp/probe.ts <<'EOF'
import { env } from "zttp:env";
export function handler(req: Request): Response {
  const v = <THE POSITION UNDER TEST>;   // launder env("SECRET_KEY") through it
  return Response.json({ v: v });
}
EOF
./zig-out/bin/zts check /tmp/probe.ts | grep no_secret_leakage
# PROVEN here is a fail-open, not a pass
```

Keep the probe type-correct or the type checker rejects it before the flow checker runs - `env()` returns an optional, so `?? "none"` is often needed. A probe that does not compile proves nothing.

**Record the sweep per position, with the reason each unreachable one is unreachable.** `inferLabels` (`packages/zts/src/flow_checker.zig:1516` and the doc comment above it) now carries that table: what is carried, and what cannot be reached because object methods are rejected at parse, spread-in-call fails arity checking before expansion, and comma expressions have a tag and an IR arm but no parser path that emits them. It closes with the operative rule - a new expression kind gets probed, not reasoned about.

**Do not let a green gate stand in for a class it cannot see.** Say what a gate covers, so its silence is not read as coverage it does not have.

**Write the reason an `else` arm skips things.** The proof-swallow gate stopped two changes in this series and demanded a justification for a new silent `else`. Writing one of those justifications is what exposed a further gap: the draft claimed `inferLabels` already covered closures passed by name, testing that claim showed it did not, and the fix landed in the same change. A gate that forces you to state why you owe nothing catches you owing something.

**Prefer `?T` over an empty value for "not found".** After the durable rule landed, `closuresWithin` returned an empty `LabelSet` for both "no closure here" and "a closure whose only label was just stripped". The caller tested emptiness to tell them apart, so `step("ts", () => Date.now())` fell into the eager-argument branch that put the label back. It returns `?LabelSet` now (`packages/zts/src/flow_checker.zig:498`). The conflation that caused the original class reappeared inside its own fix.

## Related Issues

- [validate-json-strips-the-label-it-was-asked-to-check](validate-json-strips-the-label-it-was-asked-to-check.md) - the next instance of this class, found 2026-08-03 and still open. `validateJson`, `coerceJson`, and `decodeJson` each label their output from their own contract rather than from what they were handed, so any label launders through them: `env("JWT_SECRET")` routed through one and returned in the body proves `no_secret_leakage`. Read it against the Prevention rule below about fixing one instance and assuming the class was closed - the JSON round-trip was closed, and these three sat beside it untouched.
- [empty-baseline-made-a-file-destroying-edit-prove-clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md) - the same conflation outside the compiler, one day later, in `packages/pi`: an empty edit baseline stood for an unreadable file, so the veto proved a destructive edit clean and the apply path overwrote it. Note what that means for the rule below - "Prefer `?T` over an empty value for not found" was already written here when that bug shipped. The rule did not travel across a package boundary, which is the argument for stating it as a repo-wide convention rather than a flow-checker lesson.
- [normalize-unions-without-dropping-members](../logic-errors/normalize-unions-without-dropping-members.md) - the same polarity rule in `type_pool.zig`; cite it for the general principle rather than restating it
- [sub-handler-contract-extraction-strict-profile](sub-handler-contract-extraction-strict-profile.md) - fail-closed discipline around the same compile pipeline
- `scripts/check-proof-swallow.sh` - the standing gate for the sibling class (swallowed errors); this learning is its missing counterpart
- `docs/archive/plans-advisory/018-fail-closed-on-analysis-allocation-errors.md` - the plan that produced that gate, scoped to allocation failure only, which is why the wrong-answer half stayed open
- [docs/proofs-and-receipts.md](../../proofs-and-receipts.md) - defines `no_secret_leakage` as "no secret-labelled value reaches a response, header, or egress call", the claim these bugs falsified
- `docs/roadmap.md` item 1 - the running record of this class

No GitHub issue covered this; the repo tracks work in `docs/plans/` and `docs/archive/plans-advisory/`. Nothing in `docs/solutions/` mentioned the flow checker, data labels, or taint analysis when this learning was written.
