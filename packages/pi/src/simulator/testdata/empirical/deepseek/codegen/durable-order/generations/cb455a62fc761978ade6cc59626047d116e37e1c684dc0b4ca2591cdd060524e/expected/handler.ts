import { hmacSha256 } from "zttp:crypto";
import { run, step } from "zttp:durable";

structural OrderRun<T> = Proof<T,
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

export function handler(req: Request): OrderRun<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    step("reserve", () => ({ reservationId: hmacSha256(key, "reserve") }));
    step("charge", () => ({ chargeId: hmacSha256(key, "charge") }));
    return Response.json({ reserved: true, charged: true }, { status: 201 });
  });
}
