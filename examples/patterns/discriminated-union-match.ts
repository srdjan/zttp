// Discriminated unions plus match narrowing (tips 5 and 6).
//
// A tagged union makes impossible states unrepresentable: every value
// carries a `kind` discriminant, so `match` narrows each arm to exactly
// one variant. `match` exhaustiveness is checked natively: a closed union
// covered member by member needs no `default`, and the spec forbids one
// there. No `assertNever(x: never)` helper is needed to get that guarantee.
//
// An arm callback receives the selected value. The callback binds
// `text` before it evaluates the arm result.

import { match } from "zttp:core";

type Command = { kind: "echo"; text: string } | { kind: "ping"; text: string };

type Guardrails<T> = Proof<T,
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "injection_safe"
    | "no_secret_leakage"
    | "input_validated"
>;

function run(cmd: Command): string {
  return match(cmd)
    .with({ kind: "echo" }, (selected) => {
      const text = selected.text;
      return text;
    })
    .with({ kind: "ping" }, () => "pong")
    .exhaustive();
}

function handler(req: Request): Guardrails<Response> {
  const cmd: Command = { kind: "echo", text: "hi" };
  return Response.json({ result: run(cmd) });
}
