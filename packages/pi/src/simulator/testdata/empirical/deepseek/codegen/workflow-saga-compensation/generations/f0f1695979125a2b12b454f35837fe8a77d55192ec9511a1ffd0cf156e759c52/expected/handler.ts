import { run } from "zttp:durable";
import { call, saga } from "zttp:workflow";

structural SagaResponse<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): SagaResponse<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing idempotency-key" }, { status: 400 });
  }
  return run(key, () => {
    const outcome = saga([
      {
        name: "reserve",
        run: () => call("inventory", { path: "/reserve" }),
        compensate: () => call("inventory", { path: "/release" })
      },
      {
        name: "charge",
        run: () => call("billing", { path: "/charge" }),
        compensate: () => call("billing", { path: "/refund" })
      },
      {
        name: "ship",
        run: () => call("shipping", { path: "/ship" })
      }
    ]);
    return Response.json({ outcome: outcome });
  });
}
