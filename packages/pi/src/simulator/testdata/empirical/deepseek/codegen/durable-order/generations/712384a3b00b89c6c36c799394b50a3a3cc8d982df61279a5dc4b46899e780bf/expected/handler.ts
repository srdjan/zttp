import { run, step } from "zttp:durable";

structural OrderWorkflowProof<T> = Proof<T,
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

export function handler(req: Request): OrderWorkflowProof<Response> {
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    const reserve = step("reserve", () => {
      return { reservationId: "res-1" };
    });
    const charge = step("charge", () => {
      return { chargeId: "chg-1" };
    });
    return Response.json(
      {
        reserved: true,
        charged: true,
        reservationId: reserve.reservationId,
        chargeId: charge.chargeId
      },
      { status: 201 }
    );
  });
}
