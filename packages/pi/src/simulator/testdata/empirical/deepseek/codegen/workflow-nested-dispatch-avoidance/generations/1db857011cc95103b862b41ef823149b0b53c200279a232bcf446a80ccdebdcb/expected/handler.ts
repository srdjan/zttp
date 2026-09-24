import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";

structural OrderProof<T> = Proof<T,
  | "result_safe"
  | "optional_safe"
  | "cost_bounded"
>;

export function handler(req: Request): OrderProof<Response> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing idempotency-key" }, { status: 400 });
  }
  return run(key, () => {
    const reserved = step("reserve", () => ({ reserved: true }));
    const notified = call("notify", { method: "POST", body: JSON.stringify({ reserved: reserved }) });
    return Response.json({ notified: notified.status }, { status: 201 });
  });
}
