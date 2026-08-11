// Discriminated unions plus match narrowing (tips 5 and 6).
//
// A tagged union makes impossible states unrepresentable: every value
// carries a `kind` discriminant, so `match` narrows each arm to exactly
// one variant. `match` exhaustiveness is checked natively: a closed union
// covered member by member needs no `default`, and the spec forbids one
// there. No `assertNever(x: never)` helper is needed to get that guarantee.
//
// An arm reads a field by binding it in the pattern (`text` below), not by
// reading it back off the scrutinee.

import type { Spec } from "zttp:types";

type Command = { kind: "echo", text: string } | { kind: "ping", text: string };

type Guardrails = Spec<
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
  return match (cmd) {
    when { kind: "echo", text }: text
    when { kind: "ping" }: "pong"
  };
}

function handler(req: Request): Response & Guardrails {
  const cmd: Command = { kind: "echo", text: "hi" };
  return Response.json({ result: run(cmd) });
}
