import { run } from "zttp:durable";
import { call } from "zttp:workflow";

// Durable workflow entry point. The Idempotency-Key header doubles as the
// durable run key, and the registered `greet` child handler is dispatched
// with workflow.call at step depth 0 inside run(), so the dispatch stays
// durably recorded and the child's response body answers the caller.
structural WorkflowProof<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): WorkflowProof<Response> {
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  return run(key, () => {
    const child = call("greet", {});
    return Response.text(child.body);
  });
}
