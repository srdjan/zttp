---
title: A dispatched route was never walked, so its leak proved clean
date: 2026-09-28
last_updated: 2026-09-28
category: security-issues
module: packages/zts/src/flow_checker.zig (analysis roots and calls through zttp:router routerMatch)
problem_type: security_issue
component: compiler
symptoms:
  - "A routed handler whose route returned `env(\"SECRET_KEY\")` reported `no_secret_leakage` PROVEN and exited 0."
  - "All six flow properties had the gap: `no_secret_leakage`, `no_credential_leakage`, `input_validated`, `injection_safe`, `pii_contained`, and `deterministic`."
  - "The same leak written directly in the handler was refused, so every direct-return probe and test stayed green."
  - "Two shipped examples claimed properties they did not hold, and nothing reported it."
root_cause: logic_error
resolution_type: code_fix
severity: critical
related_components:
  - tooling
  - documentation
tags:
  - zts
  - flow-checker
  - data-labels
  - fail-open
  - dynamic-dispatch
  - router
  - analysis-roots
  - soundness
---

# A dispatched route was never walked, so its leak proved clean

## Problem

The flow checker started its walk at the handler function and at no other function. A route function that the handler reached through `zttp:router` (`const found = routerMatch(routes, req); return found.handler(req);`) was never walked as a place where request data enters and leaves. The checker did not judge the sinks inside it, and the value of the `found.handler(req)` call carried only the labels of its receiver and its arguments. A routed handler that returned a secret from a route therefore proved all six flow properties.

## Symptoms

This handler type-checks, and before the fix it reported `no_secret_leakage ... PROVEN`:

```js
import { routerMatch } from "zttp:router";
import { env } from "zttp:env";
function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
const routes = { "GET /leak": leak };
function handler(req) {
  const found = routerMatch(routes, req);
  return found.handler(req);
}
```

- The same `env("SECRET_KEY")` returned directly from the handler was refused. Every probe and test that returned a value directly passed, so the gap was invisible to them.
- The gap covered each flow property, not only secrets: a credential, unvalidated input, an injection sink, PII, and a clock read inside a route were all unseen.
- `examples/system/orders.ts` and `examples/system/users.ts` claimed `no_secret_leakage` and, for `users.ts`, `injection_safe`. Neither held. Both return cache reads, which carry `unknown` provenance, and `users.ts` sends its route parameter `id` unvalidated into a `serviceCall` query (`examples/system/users.ts:24-26`). The claims passed because the routes were never walked.

## What Didn't Work

**Security review of the export labels.** Two security reviews of the `zttp:tool` change that added `agentPrompt` and `callTool` checked each export's declared labels and reported no findings (session history). They reasoned about what a value carries. They did not ask whether the function that holds the value is walked at all. The gap was found later, during the M5 A4 design review. The `callTool` label design assumed that tool routes were checked as response sinks. The reviewer tested that assumption against the source and then ran a scratch probe: the `convert` tool route in `examples/tools/tools.ts` changed to return `env("ORDERS_API_KEY")` gave exit 0 and PROVEN. A minimal routed handler, the one above, reproduced it.

**A general `unknown` fallback for every unrecognized call.** The first fix gave `.unknown` to every call whose callee the checker could not resolve to a function body. That also caught builtin method calls on values that the stripped IR cannot type, such as `body.slice(0, 8).toUpperCase()` where `body` is `req.body ?? ""`. The M3 reach reference handler (`packages/pi/src/expert_reach_corpus.zig:171`) is unrouted and correct, and the change flipped it to `deterministic` false. The flow checker's own tests did not catch this. Only the reach reference test (`packages/pi/src/expert_reach.zig:177`), which `zig build test-expert-app` runs, caught it. A fail-closed fallback that is too wide does not make a false PROVEN. It makes a false refusal, and a false refusal is quiet in the analysis tests.

**Validating the route parameter in `users.ts` with `validateObject`.** This attempt to make `users.ts` hold `injection_safe` failed at the system linker. `validateObject` declares a `.request_schema` contract extraction (`packages/modules/src/security/validate.zig:40`), so a call to it made the users service require a request body. The gateway's `serviceCall` to users sends no body, so the linker refused the system. The change was reverted, and `users.ts` now does not claim `injection_safe`.

## Solution

The fix has three parts and one wiring change.

**Route functions are analysis roots.** `scanRouteFunctionRoots` (`packages/zts/src/flow_checker.zig:1004`) finds every call to the imported `routerMatch` and resolves the functions in its literal route table. The table is an object literal, or a module binding that an object literal initializes. `check` (`packages/zts/src/flow_checker.zig:444-472`) walks the handler, and then walks each route function as its own root. The route's request parameter carries `user_input`, and each root starts with clean witness state.

**A dispatched call carries the union of its routes' return labels.** `routerDispatchLabels` (`packages/zts/src/flow_checker.zig:2360`) recognizes `found.handler(...)` when `found` is bound to a `routerMatch` result. The value is the merge of the return labels of every resolved route. When the table or an entry does not resolve, or the `found` binding is mutated, aliased, or escapes, the call carries `.unknown`, and `unknownRouteCallLabels` (`packages/zts/src/flow_checker.zig:2431`) clears all six flow properties.

**A call to a function value that cannot be resolved carries `.unknown`.** `isUnresolvedFunctionValueCallee` (`packages/zts/src/flow_checker.zig:2349`) applies to a parameter, an unresolved member, a computed element, a call result, or a selector such as a ternary. It does not apply to a known builtin member call (`isKnownBuiltinMemberCall`, `packages/zts/src/flow_checker.zig:2511`).

**The type checker reaches the flow checker.** Some builtin receivers cannot be identified from the stripped IR, for example a parameter declared `string`. `checkedBuiltinReceiverKind` (`packages/zts/src/flow_checker.zig:2626`) asks the type checker, and only a string or array type proves a builtin receiver. Records and functions stay unresolved, so an arbitrary object method still carries `.unknown`. `pipeline.check` (`packages/zts/src/pipeline.zig:335`) and both flow-checker call sites in `packages/tools/src/precompile.zig` (`:545` and `:3166`) pass the type checker in.

The tests pin each direction:

- `test "FlowChecker checks each flow property inside routerMatch route functions"` (`packages/zts/src/flow_checker.zig:5383`) breaks each of the six properties once directly and once routed.
- `test "FlowChecker unions routerMatch route return labels at dispatch"` (`:5543`) and `test "FlowChecker proves every flow property for clean routerMatch routes"` (`:5563`) check the union and the clean case.
- `test "FlowChecker gives an unresolved dynamic call unknown response labels"` (`:5622`) covers the fallback, and `test "FlowChecker refuses mutated and local routerMatch tables"` (`:5757`) covers unstable tables.
- `test "typed imported builtin receivers keep their pre-fallback labels"` (`:5223`) and `test "check keeps typed imported builtin methods deterministic"` (`packages/tools/src/precompile.zig:7269`) pin the scope of the fallback. `test "a typed arbitrary object method remains an unresolved function value"` (`packages/zts/src/flow_checker.zig:5260`) pins its other side.

Per this session's mutation checks, removal of the route-root walk failed a test, removal of the `.unknown` fallback failed a test, and a wider fallback failed the builtin-method regression test. The full local gate `scripts/verify.sh` passed after the fix.

The two examples now claim only what they hold, and a comment beside each proof capsule gives the reason (`examples/system/orders.ts:5-8`, `examples/system/users.ts:6-10`).

## Why This Works

A property analysis proves a property for the program only when it walks every place where user code runs with request data. The handler was one such place. Each route function that the router can dispatch to is another. The old checker treated `found.handler(req)` as an ordinary expression and merged the labels it could see: the receiver and the argument. The route body, where the secret was, was not in that set. This is the conflation from [empty-label-set-claimed-a-value-was-clean](empty-label-set-claimed-a-value-was-clean.md), one level up. There an empty label set stood for "did not look at this value". Here a missing walk stood for "no sink in this function".

The fix closes both halves. Every function the checker can resolve is walked as a root, so its sinks are judged. Every call it cannot resolve is marked as not known, so its value cannot prove anything. The `unknown` fallback is scoped to function values that have no resolved body. A builtin method has a known label behavior, so it keeps its ordinary label union, and a clean program stays proven.

## Prevention

**Enumerate every entry into user code, not only the handler.** For each property analysis, list the ways user code runs: the handler, dispatched routes, callbacks that a module invokes, and any other indirect call. Walk each resolvable one as a root. An entry that the analysis does not walk is a fail-open, because a sink it never visits cannot cost a property.

**Probe the dispatched position as well as the direct one.** The probe method in [empty-label-set-claimed-a-value-was-clean](empty-label-set-claimed-a-value-was-clean.md) puts a labelled value in one syntactic position inside the handler. That method did not find this gap, because every position it named was inside the handler. For each property, write the leak once directly and once through each dispatch shape, and require both to fail. The routed-and-direct table in the `flow_checker.zig:5383` test is the pattern.

```bash
cat > /tmp/probe.ts <<'EOF'
import { routerMatch } from "zttp:router";
import { env } from "zttp:env";
structural Claim<T> = Proof<T, | "no_secret_leakage">;
function leak(req: Request): Response {
  return Response.json({ key: env("SECRET_KEY") ?? "none" });
}
const routes = { "GET /leak": leak };
function handler(req: Request): Claim<Response> {
  const found = routerMatch(routes, req);
  if (found === undefined) return Response.json({ error: "not found" }, { status: 404 });
  return found.handler(req);
}
EOF
./zig-out/bin/zts check /tmp/probe.ts; echo "exit=$?"
# After the fix: exit=1, "no_secret_leakage ... ---", and ZTS500
# "declared Proof capsule was not discharged ... (failing spec: no_secret_leakage)".
# exit=0 here is a fail-open.
```

The probe claims only the property under test, so that a failure for another property cannot hide the result. The capsule and the `found === undefined` check are necessary. Without them the probe fails for other reasons (the default proof profile and an optional access on `found`), and that exit 1 says nothing about the route. Read the verdict from the exit status and from the named failing spec together. A probe that fails for the wrong reason checks nothing, as [difference-is-not-the-claim-and-a-probe-must-compile](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md) records.

**Fail closed on calls the analysis cannot resolve, and scope the fallback to them.** A call whose callee has no resolved body carries `.unknown`. A call whose callee is known, such as a builtin method on a typed string or array, keeps its known labels. Test both sides: one test that an unresolved function value costs the property, and one test that a clean program that calls builtins still proves it. The wide first fix passed every flow-checker test and failed only a reference handler in a different package. Run an unrouted corpus of known-correct handlers, such as the reach references, before you accept a new fallback.

**When a claim in an example stops holding, remove the claim.** Do not add a guard only to keep the claim. A guard can bring its own contract, as `validateObject` did with its request-schema extraction.

**The same gap was open in six more analyses, and a second commit closed it.** `response_total`, `results_safe`, `optional_safe`, `read_only`, `state_isolated`, and `fault_covered` each walked only the handler. The flow checker's route resolution now lives in `packages/zts/src/route_resolution.zig` and feeds every property analysis, so a new analysis gets routed roots by using it rather than by repeating the flow fix. A census over every proof property and flow tag requires a routed and a direct probe for each, which is what stops the next analysis from opening the gap again.

**Rebuild routed artifacts.** Per the `CHANGELOG.md` entry, artifacts built by 0.21.1 and earlier from a routed handler can carry the six flow properties falsely.

## Related Issues

- [empty-label-set-claimed-a-value-was-clean](empty-label-set-claimed-a-value-was-clean.md) - the parent class: absence of evidence encoded as evidence of absence. That doc is about a value the walk did not read. This doc is about a function the walk did not enter.
- [a-check-that-never-ran-passed-every-handler](a-check-that-never-ran-passed-every-handler.md) - a different pass with the same result. A check that does not run on some code reports a pass for that code.
- [a-gate-can-be-non-vacuous-and-still-porous](../conventions/a-gate-can-be-non-vacuous-and-still-porous.md) - the direct-return probes were non-vacuous and still porous. They caught every case they named and did not name the dispatched case.
- [a-label-union-that-never-narrows-refuses-a-clean-program](../logic-errors/a-label-union-that-never-narrows-refuses-a-clean-program.md) - the opposite failure, a false refusal. The first, too-wide `unknown` fallback here was an instance of it.
- [an-export-that-declared-no-labels-answered-clean](an-export-that-declared-no-labels-answered-clean.md) - lists `routerMatch` among the exports that once laundered a secret through their declared labels. That fix labelled the router's return value. It did not walk the route bodies.
