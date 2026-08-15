// Proof<T, P> example: a handler that declares `idempotent` as an
// obligation but uses Date.now(), which the verifier classifies as
// non-deterministic. The build emits ZTS500 ("spec_not_discharged")
// with the per-property suggestion attached to the failure.


structural Guardrails<T> = Proof<T, "idempotent" | "deterministic">;

function handler(req: Request): Guardrails<Response> {
  return Response.json({ now: Date.now() });
}
