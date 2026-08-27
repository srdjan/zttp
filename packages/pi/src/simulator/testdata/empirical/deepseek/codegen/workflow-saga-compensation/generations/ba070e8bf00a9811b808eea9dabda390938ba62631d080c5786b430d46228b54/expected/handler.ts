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
    return Response.json({ error: "missing idempotency-key header" }, { status: 400 });
  }
  const outcome = run(key, () => {
    return saga([
      {
        name: "reserve",
        run: () => call("inventory", { method: "POST", path: "/reserve" }),
        compensate: () => call("inventory", { method: "POST", path: "/release" }),
      },
      {
        name: "charge",
        run: () => call("billing", { method: "POST", path: "/charge" }),
        compensate: () => call("billing", { method: "POST", path: "/refund" }),
      },
      {
        name: "ship",
        run: () => call("shipping", { method: "POST", path: "/ship" }),
      },
    ]);
  });
  return Response.json(outcome);
}
