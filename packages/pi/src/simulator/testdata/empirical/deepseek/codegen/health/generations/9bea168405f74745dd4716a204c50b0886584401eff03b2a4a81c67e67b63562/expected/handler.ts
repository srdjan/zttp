structural Guard<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
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
  if (req.method === "GET" && req.path === "/health") {
    return Response.json({ ok: true });
  }
  return Response.json({ error: "not found" }, { status: 404 });
}
