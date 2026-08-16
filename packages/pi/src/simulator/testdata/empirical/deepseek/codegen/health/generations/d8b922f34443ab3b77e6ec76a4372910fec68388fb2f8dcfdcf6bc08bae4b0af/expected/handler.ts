structural Guard<T> = Proof<T,
  | "deterministic"
  | "read_only"
  | "retry_safe"
  | "idempotent"
  | "state_isolated"
  | "pure"
  | "stateless"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): Guard<Response> {
  return Response.json({ ok: true });
}
