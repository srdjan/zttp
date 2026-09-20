import { run, waitSignal, signal } from "zttp:durable";

// POST /wait parks a durable run under the caller's Idempotency-Key header
// and answers 202 until the run resumes; once the "approval" signal lands
// the parked run continues and answers 200. POST /signal delivers that
// payload to the same key. `waitSignal` returns a payload some separate
// `signal` call wrote, so its provenance is unknowable to the checker and
// the binding declares `unknown`: reaching the response sink with it clears
// `no_secret_leakage`, `no_credential_leakage`, and `deterministic`, and
// `idempotent` follows determinism. The presence test does not narrow that,
// the checker unions labels through a comparison, so none of those four are
// on this list. `retry_safe` is the property the durable handoff carries.
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
  if (req.method !== "POST") {
    return Response.json({ error: "method not allowed" }, { status: 405 });
  }
  const key = req.headers.get("Idempotency-Key");
  if (key === undefined) {
    return Response.json({ error: "missing Idempotency-Key" }, { status: 400 });
  }
  if (req.path === "/signal") {
    const delivered = signal(key, "approval", { approved: true });
    return Response.json({ delivered: delivered });
  }
  if (req.path !== "/wait") {
    return Response.json({ error: "not found" }, { status: 404 });
  }
  return run(key, () => {
    const approval = waitSignal("approval");
    return Response.json({ approved: approval !== undefined });
  });
}
