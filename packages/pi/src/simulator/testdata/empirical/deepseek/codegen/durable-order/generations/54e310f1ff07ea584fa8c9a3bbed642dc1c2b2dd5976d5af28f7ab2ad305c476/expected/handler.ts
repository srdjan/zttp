import { run, step } from "zttp:durable";

structural OrderProof<T> = Proof<T,
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

export function handler(req: Request): OrderProof<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    const reservation = step("reserve", () => ({ reservationId: "res-001" }));
    const charge = step("charge", () => ({ chargeId: "chg-001" }));
    return Response.json({ reserved: true, charged: true }, { status: 201 });
  });
}
