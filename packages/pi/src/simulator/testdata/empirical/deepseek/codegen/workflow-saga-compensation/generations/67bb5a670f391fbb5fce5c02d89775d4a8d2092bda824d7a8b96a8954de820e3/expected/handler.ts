import { run } from "zttp:durable";
import { call, saga } from "zttp:workflow";

structural SagaProof<T> = Proof<T,
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
  return run(key, () => {
    const outcome = saga([
      {
        name: "reserve",
        run: () => call("inventory", { path: "/reserve" }),
        compensate: () => call("inventory", { path: "/release" }),
      },
      {
        name: "charge",
        run: () => call("billing", { path: "/charge" }),
        compensate: () => call("billing", { path: "/refund" }),
      },
      {
        name: "ship",
        run: () => call("shipping", { path: "/ship" }),
      },
    ]);
    return Response.json({ outcome: outcome });
  });
}
