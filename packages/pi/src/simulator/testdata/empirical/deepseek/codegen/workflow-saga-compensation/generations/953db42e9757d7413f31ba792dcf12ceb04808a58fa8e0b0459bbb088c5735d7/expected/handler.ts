import { run } from "zttp:durable";
import { call, saga } from "zttp:workflow";

structural SagaGuard<T> = Proof<T,
  | "state_isolated"
  | "deterministic"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): SagaGuard<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing idempotency-key header" }, { status: 400 });
  }
  return run(key, () => {
    const outcome = saga([
      {
        name: "reserve",
        run: () => call("inventory", { method: "POST", path: "/reserve" }),
        compensate: () => call("inventory", { method: "POST", path: "/release" })
      },
      {
        name: "charge",
        run: () => call("billing", { method: "POST", path: "/charge" }),
        compensate: () => call("billing", { method: "POST", path: "/refund" })
      },
      {
        name: "ship",
        run: () => call("shipping", { method: "POST", path: "/ship" })
      }
    ]);
    return Response.json(outcome);
  });
}
