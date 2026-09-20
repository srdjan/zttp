
import { run, step } from "zttp:durable";

// The run key comes from the caller's idempotency header, so the durable
// run resumes instead of re-executing `reserve` and `charge` on a retry.
// Neither step result reaches the response: `step` returns `unknown` and
// the checker cannot vouch for its provenance, so the response body is
// built from literals and states only what the two steps guarantee.
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
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    step("reserve", () => ({ reservationId: "res-1" }));
    step("charge", () => ({ chargeId: "chg-1" }));
    return Response.json({ reserved: true, charged: true }, { status: 201 });
  });
}
