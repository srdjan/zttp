import { apiToken, displayName } from "./lib/settings.ts";

structural Ready<T> = Proof<T, "deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "stateless" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded">;

export function handler(req: Request): Ready<Response> {
  if (apiToken() === undefined) {
    return Response.json({ error: "service unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
