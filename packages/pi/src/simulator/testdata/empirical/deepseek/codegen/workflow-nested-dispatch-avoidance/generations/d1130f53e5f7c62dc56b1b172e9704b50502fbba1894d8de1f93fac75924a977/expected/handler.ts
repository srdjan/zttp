import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";

structural OrderWorkflowProof<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
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
    step("reserve", () => ({ reserved: true }));
    const notified = call("notify", { method: "POST", body: { order: "reserved" } });
    return Response.json({ notified: notified.status }, { status: 201 });
  });
}
