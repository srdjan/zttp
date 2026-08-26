import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";

structural OrderWorkflowProof<T> = Proof<T,
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

export function handler(req: Request): OrderWorkflowProof<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing idempotency-key" }, { status: 400 });
  }
  return run(key, () => {
    step("reserve-inventory", () => {
      return Response.json({ reserved: true });
    });
    const notified = call("notify", {});
    return Response.json({ notified: notified.status }, { status: 201 });
  });
}
