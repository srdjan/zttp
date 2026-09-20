import { run } from "zttp:durable";
import { call } from "zttp:workflow";

export function handler(req: Request): Proof<Response,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
> {
  const key = req.headers.get("idempotency-key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    const greeting = call("greet", {});
    return Response.text(greeting.body);
  });
}
