import { match, P } from "zttp:core";
// Proves: top-level type-test patterns over a closed union parse and pass every stage with no default arm.
type Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
  const value: string | number = 1;
  const label = match (
    value
  ).with(P.string, () => "text").with(P.number, () => "count").exhaustive();
  return Response.text(label);
}
