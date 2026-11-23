import { match } from "zttp:core";
// Proves: a `default` arm in last position parses and passes every stage.
type Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
  const label = match (
    req.method
  ).with(
    "GET",
    () => "read",
  ).with("POST", () => "write").otherwise(() => "other");
  return Response.text(label);
}
