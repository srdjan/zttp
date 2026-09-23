import { run, waitSignal, signal } from "zttp:durable";

// Both paths are POST. POST /wait parks a durable run under the caller's
// Idempotency-Key inside `waitSignal("approval")`, so the runtime answers
// 202 while the run is parked and replays the closure once POST /signal
// writes the payload to that same key, answering 200 with the approval
// decision. `waitSignal` returns a value some separate `signal` call
// wrote, so its provenance is unknowable to the checker and the binding
// is `unknown`; carrying it into the response clears `no_secret_leakage`,
// `no_credential_leakage`, and `deterministic` (and `idempotent`, which
// follows determinism), so the declared proof names the properties this
// handler does carry.
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
