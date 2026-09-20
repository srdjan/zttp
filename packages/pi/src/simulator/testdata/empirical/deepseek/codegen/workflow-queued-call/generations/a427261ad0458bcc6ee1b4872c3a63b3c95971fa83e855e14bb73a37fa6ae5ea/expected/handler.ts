import { run } from "zttp:durable";
import { call } from "zttp:workflow";

structural WorkflowProof<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): WorkflowProof<Response> {
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    const greeted = call("greet", {});
    return Response.text(greeted.body);
  });
}
