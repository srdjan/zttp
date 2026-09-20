import { run, waitSignal, signal } from "zttp:durable";

// `waitSignal` returns a payload some separate `signal` call wrote, so
// its provenance is unknowable to the checker and the binding declares
// `unknown`. Reaching the response with that clears the three
// properties the response sink decides - `no_secret_leakage`,
// `no_credential_leakage`, `deterministic` - and `idempotent` follows
// determinism, so none of the four are on this list. The presence test
// `approval !== undefined` does not narrow that: the checker unions
// labels through a comparison rather than treating it as a fact about
// the value. `retry_safe` still holds, which is the property this
// workflow is about: POST /wait parks a run under the Idempotency-Key
// (the durable runtime answers 202 while the run is parked) and answers
// 200 { approved: true } once the signal has resumed it, while
// POST /signal delivers the approval payload to the same key.
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
  if (req.method === "POST" && req.path === "/signal") {
    const delivered = signal(key, "approval", { approved: true });
    return Response.json({ delivered: delivered });
  }
  if (req.method !== "POST" || req.path !== "/wait") {
    return Response.json({ error: "not found" }, { status: 404 });
  }
  return run(key, () => {
    const approval = waitSignal("approval");
    return Response.json({ approved: approval !== undefined });
  });
}
