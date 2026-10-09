import { run, waitSignal, signal } from "zttp:durable";

// One durable run key, two POST paths. `waitSignal` returns a payload a
// separate `signal` call wrote, so its provenance is unknowable to the
// checker and the binding declares `unknown`. Reaching a response sink
// with that clears `no_secret_leakage`, `no_credential_leakage`, and
// `deterministic`, and `idempotent` follows determinism, so none of the
// four are on this list. The run body answers 202 while the run is still
// parked on `approval` and 200 with the approval once it has resumed.
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
  const key = req.headers.get("idempotency-key");
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
