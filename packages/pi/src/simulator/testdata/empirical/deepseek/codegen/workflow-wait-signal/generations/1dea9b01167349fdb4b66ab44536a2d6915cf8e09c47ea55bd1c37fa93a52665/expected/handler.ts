import { run, waitSignal, signal } from "zttp:durable";

// POST /wait parks a durable run under the Idempotency-Key header and waits
// on the `approval` signal; POST /signal delivers { approved: true } to that
// same key. `waitSignal` returns a payload some separate `signal` call wrote,
// so its provenance is unknowable to the checker and the binding is `unknown`.
// Only a literal boolean derived from that value reaches the response, so the
// properties below are the ones this file actually proves.
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
    return Response.json({ error: "method not allowed" }, { status: 405 });
  }
  if (req.path === "/signal") {
    const delivered = signal(key, "approval", { approved: true });
    return Response.json({ delivered: delivered });
  }
  if (req.path === "/wait") {
    return run(key, () => {
      const approval = waitSignal("approval");
      if (approval === undefined) {
        return Response.json({ approved: false }, { status: 202 });
      }
      return Response.json({ approved: true });
    });
  }
  return Response.json({ error: "not found" }, { status: 404 });
}
