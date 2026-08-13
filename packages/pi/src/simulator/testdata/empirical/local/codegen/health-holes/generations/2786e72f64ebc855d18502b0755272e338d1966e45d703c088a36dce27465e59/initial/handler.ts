function handler(req: Request): Response & Spec<"deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
  return hole();
}
