import { run, waitSignal, signal } from "zttp:durable";

// `waitSignal` returns a payload some separate `signal` call wrote, so its
// provenance is unknowable to the checker and the binding it is read into
// declares `unknown`. The approval verdict below is therefore the constant
// `true`, written once the parked run has resumed, and never a read of the
// parked payload.
structural ApprovalProof<T> = Proof<T,
  | "deterministic"
  | "retry_safe"
  | "idempotent"
  | "state_isolated"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
>;

export function handler(req: Request): ApprovalProof<Response> {
  if (req.method !== "POST") {
    return Response.json({ error: "method not allowed" }, { status: 405 });
  }
  const key = req.headers.get("idempotency-key");
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
    if (approval === undefined) {
      return Response.json({ status: "pending" }, { status: 202 });
    }
    return Response.json({ approved: true });
  });
}
