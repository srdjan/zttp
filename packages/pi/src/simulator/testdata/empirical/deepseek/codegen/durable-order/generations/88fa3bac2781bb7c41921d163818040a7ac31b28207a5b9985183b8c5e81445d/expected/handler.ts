import { run, step } from "zttp:durable";

structural OrderWorkflowProof<T> = Proof<T,
  | "retry_safe"
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
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    step("reserve", () => ({ reservationId: key }));
    step("charge", () => ({ chargeId: key }));
    return Response.json({ reserved: true, charged: true }, { status: 201 });
  });
}
