import { run, waitSignal, signal } from "zttp:durable";

// `waitSignal` resumes a parked run and hands back whatever a separate
// `signal` call delivered, so the checker cannot know the payload's
// provenance and the binding is `unknown`. Carrying that value into the
// response body would clear `no_secret_leakage`, `no_credential_leakage`,
// and `deterministic` (and `idempotent`, which follows determinism), and
// the presence test does not narrow it: the checker unions labels through
// the comparison. So the payload decides only which arm runs, and both
// bodies are built from literals. `retry_safe` is the property this
// workflow exists to earn - a repeat POST under the same Idempotency-Key
// replays the same run rather than parking a second one.
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
  if (req.path !== "/wait") {
    return Response.json({ error: "not found" }, { status: 404 });
  }
  return run(key, () => {
    const approval = waitSignal("approval");
    if (approval === undefined) {
      return Response.json({ status: "pending" }, { status: 202 });
    }
    return Response.json({ approved: true });
  });
}
