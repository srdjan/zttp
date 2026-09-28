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

// One durable run keyed by Idempotency-Key. `reserve` then `charge` are
// recorded as separate steps at step depth 0, so a retry replays the
// journal instead of re-reserving or double-charging the order.
export function handler(req: Request): OrderProof<Response> {
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    const reservation = step("reserve", () => ({ reservationId: "rsv-1" }));
    const charge = step("charge", () => ({ chargeId: "chg-1" }));
    return Response.json({
      reserved: reservation !== undefined,
      charged: charge !== undefined
    }, { status: 201 });
  });
}
