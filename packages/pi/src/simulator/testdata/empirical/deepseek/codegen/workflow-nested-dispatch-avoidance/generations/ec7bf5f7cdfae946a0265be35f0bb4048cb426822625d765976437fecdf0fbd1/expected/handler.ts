import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing idempotency-key" }, { status: 400 });
  }
  return run(key, () => {
    const reserved = step("reserve", () => {
      return { reserved: true };
    });
    const notified = call("notify", { method: "POST" });
    return Response.json({ reserved: reserved, notified: notified.status }, { status: 201 });
  });
}
