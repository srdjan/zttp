import { run } from "zttp:durable";
import { call } from "zttp:workflow";

structural WorkflowProof<T> = Proof<T,
  | "state_isolated"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "pii_contained"
  | "input_validated"
>;

export function handler(req: Request): WorkflowProof<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    const child = call("greet", { method: "GET" });
    return Response.text(child.body);
  });
}
