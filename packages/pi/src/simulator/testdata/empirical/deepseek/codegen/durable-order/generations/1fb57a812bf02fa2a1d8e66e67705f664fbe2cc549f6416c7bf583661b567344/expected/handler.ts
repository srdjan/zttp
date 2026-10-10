import { run, step } from "zttp:durable";

structural OrderProof<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "retry_safe"
  | "idempotent"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): OrderProof<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing idempotency-key" }, { status: 400 });
  }
  return run(key, () => {
    const reservation = step("reserve", () => ({ reservationId: "res-1" }));
    const charge = step("charge", () => ({ chargeId: "chg-1" }));
    return Response.json(
      {
        reserved: reservation.reservationId !== "",
        charged: charge.chargeId !== "",
      },
      { status: 201 }
    );
  });
}
