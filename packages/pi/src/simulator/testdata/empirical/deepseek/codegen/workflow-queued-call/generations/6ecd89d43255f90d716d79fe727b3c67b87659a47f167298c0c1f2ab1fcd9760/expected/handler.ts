import { run } from "zttp:durable";
import { call } from "zttp:workflow";

structural DurableWorkflowProof<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
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

export function handler(req: Request): DurableWorkflowProof<Response> {
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    const child = call("greet", {});
    if (!child.ok) {
      return Response.json({ error: child.statusText }, { status: child.status });
    }
    return Response.text(child.body);
  });
}
