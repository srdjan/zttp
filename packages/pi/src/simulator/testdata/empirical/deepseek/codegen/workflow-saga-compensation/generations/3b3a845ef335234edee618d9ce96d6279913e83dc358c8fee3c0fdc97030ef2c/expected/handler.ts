import { run } from "zttp:durable";
import { call, saga } from "zttp:workflow";

structural SagaProof<T> = Proof<T,
  | "deterministic"
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

export function handler(req: Request): SagaProof<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing idempotency-key" }, { status: 400 });
  }
  return run(key, () => {
    const outcome = saga([
      {
        name: "reserve",
        run: () => call("inventory", { method: "POST", path: "/reserve", headers: { "idempotency-key": key } }),
        compensate: () => call("inventory", { method: "POST", path: "/release", headers: { "idempotency-key": key } }),
      },
      {
        name: "charge",
        run: () => call("billing", { method: "POST", path: "/charge", headers: { "idempotency-key": key } }),
        compensate: () => call("billing", { method: "POST", path: "/refund", headers: { "idempotency-key": key } }),
      },
      {
        name: "ship",
        run: () => call("shipping", { method: "POST", path: "/ship", headers: { "idempotency-key": key } }),
      },
    ]);
    return Response.json(outcome);
  });
}
