// The admitted operations on `Result`, imported as free functions.
//
// `Result` itself is predeclared and never imported. `zttp:result` supplies
// what you do with one: the two constructors, the four combinators, and the
// two consumers. There is no member form - `unwrapOr(r, d)` is the spelling,
// not `r.unwrapOr(d)` - because the profile gives new abstractions free
// functions rather than methods.
//
// `collectAll` is first-error: it returns the first `err` in order and reads
// nothing after it, which is what makes it interchangeable with the `andThen`
// chain a handler would otherwise spell by hand.
//
// The combinator callbacks are effect-row polymorphic. Every callback here is
// pure, so this handler's row is empty and it proves `deterministic`; a
// callback that read a clock would join its row into this one and cost exactly
// that property.

import {
  andThen,
  collectAll,
  err,
  mapError,
  mapResult,
  ok,
  orElse,
  unwrapOr,
} from "zttp:result";

structural Guardrails<T> = Proof<T,
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "stateless"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
    | "cost_bounded"
>;

function handler(req: Request): Guardrails<Response> {
  // A chain: transform the value, then the failure, then recover from it.
  const doubled = mapResult(ok(21), (n) => n * 2);
  const chained = andThen(doubled, (n) => ok(n + 1));
  const relabelled = mapError(err("boom"), (e) => `${e}-relabelled`);
  const recovered = orElse(relabelled, (e) => ok(`recovered from ${e}`));

  // Consumption rule 1: the site's type is the value type and the error arm
  // supplies a constant of it.
  const value = unwrapOr(chained, 0);
  const fallback = unwrapOr(err("gone"), -1);

  // First error wins, and the errors after it are never looked at.
  const collected = collectAll([ok(1), ok(2), ok(3)]);
  const failed = collectAll([ok(1), err("first"), err("second")]);
  const empty = collectAll([]);

  return Response.json({
    value: value,
    fallback: fallback,
    recovered: unwrapOr(recovered, "never"),
    collected: unwrapOr(collected, []),
    firstError: unwrapOr(orElse(failed, (e) => ok(e)), "none"),
    emptyOk: empty.ok,
  });
}
