import { run, waitSignal, signal } from "zttp:durable";

// `waitSignal` returns whatever payload a separate `signal` call wrote, so its
// provenance is unknowable to the checker: the binding is `unknown`. The
// presence test below only selects which response the run returns. The payload
// value itself never reaches a response body, a log, or an egress sink, so the
// durable run stays keyed on the Idempotency-Key and retry-safe.
structural ApprovalProof<T> = Proof<T,
  | "retry_safe"
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): ApprovalProof<Response> {
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  if (req.method !== "POST") {
    return Response.json({ error: "not found" }, { status: 404 });
  }
  if (req.path === "/signal") {
    const delivered = signal(key, "approval", { approved: true });
    return Response.json({ delivered: delivered }, { status: 200 });
  }
  if (req.path !== "/wait") {
    return Response.json({ error: "not found" }, { status: 404 });
  }
  return run(key, () => {
    const approval = waitSignal("approval");
    if (approval === undefined) {
      return Response.json({ status: "pending" }, { status: 202 });
    }
    return Response.json({ approved: true }, { status: 200 });
  });
}
