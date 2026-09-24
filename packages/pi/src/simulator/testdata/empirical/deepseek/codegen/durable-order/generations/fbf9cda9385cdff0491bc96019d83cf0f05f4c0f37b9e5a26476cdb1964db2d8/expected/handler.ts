import { run, step } from "zttp:durable";

// Two-step order workflow: `reserve` provisions the stock, `charge` takes the
// payment. Both steps run inside one durable run keyed by the caller's
// Idempotency-Key, so a retried request replays the recorded step results
// instead of reserving or charging a second time.
structural OrderProof<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "retry_safe"
  | "idempotent"
  | "deterministic"
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
    const reservation = step("reserve", () => ({ reservationId: "res-1" }));
    const charge = step("charge", () => ({ chargeId: "chg-1" }));
    return Response.json({
      reserved: true,
      charged: true,
      reservationId: reservation.reservationId,
      chargeId: charge.chargeId
    }, { status: 201 });
  });
}
