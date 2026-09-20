import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";

structural OrderProof<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
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
    const reserved = step("reserve", () => ({ reserved: true }));
    const notified = call("notify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(reserved)
    });
    return Response.json({ notified: notified.status }, { status: 201 });
  });
}
