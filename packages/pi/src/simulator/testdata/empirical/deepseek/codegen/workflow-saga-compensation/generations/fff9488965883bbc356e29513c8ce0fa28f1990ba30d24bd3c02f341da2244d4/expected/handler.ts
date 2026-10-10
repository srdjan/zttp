import { run } from "zttp:durable";
import { call, saga } from "zttp:workflow";

structural SagaGuard<T> = Proof<T, "state_isolated" | "canonical">;

export function handler(req: Request): SagaGuard<Response> {
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
      { name: "ship", run: () => call("shipping", { path: "/ship" }) }
    ]);
    return Response.json({ outcome: outcome });
  });
}
