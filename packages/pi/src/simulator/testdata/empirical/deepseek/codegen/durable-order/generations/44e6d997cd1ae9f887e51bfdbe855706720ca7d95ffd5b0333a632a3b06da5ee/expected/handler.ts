import { run, step } from "zttp:durable";
import { uuid } from "zttp:id";

structural OrderProof<T> = Proof<T,
  | "deterministic"
  | "retry_safe"
  | "idempotent"
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

export function handler(req: Request): OrderProof<Response> {
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    step("reserve", () => ({ reservationId: uuid() }));
    step("charge", () => ({ chargeId: uuid() }));
    return Response.json({ reserved: true, charged: true }, { status: 201 });
  });
}
