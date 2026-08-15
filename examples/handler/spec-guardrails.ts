// Proof<T, P> example: author-declared proof obligations.
//
// `Guardrails` is a normal TS type alias whose body is the built-in
// ambient `Proof<T, P>` marker. When the handler return type instantiates this
// alias (`Guardrails<Response>`), the
// verifier runs after the analyzer pipeline and emits ZTS500 if any
// declared spec is not discharged by the inferred HandlerProperties.
//
// This handler is fully discharged: it makes no I/O, has no
// non-determinism, and never touches an env-labelled secret, so every
// member of the active spec set holds.


structural Guardrails<T> = Proof<T,
    | "idempotent"
    | "deterministic"
    | "no_secret_leakage"
    | "injection_safe"
>;

function handler(req: Request): Guardrails<Response> {
  return Response.json({ ok: true });
}
