import { run } from "zttp:durable";
import { call } from "zttp:workflow";

export function handler(req: Request): Proof<Response, "state_isolated" | "injection_safe"> {
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing_idempotency_key" }, { status: 400 });
  }
  return run(key, () => {
    const child = call("greet", { path: "/greet" });
    return Response.text(child.body);
  });
}
