import { run, step } from "zttp:durable";

structural OrderWorkflowProof<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "retry_safe"
  | "idempotent"
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
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key header" }, { status: 400 });
  }
  return run(key, () => {
    const reserved = step("reserve", () => ({ reservationId: "reservation-1" }));
    const charged = step("charge", () => ({ chargeId: "charge-1" }));
    return Response.json({ reserved: true, charged: true }, { status: 201 });
  });
}
