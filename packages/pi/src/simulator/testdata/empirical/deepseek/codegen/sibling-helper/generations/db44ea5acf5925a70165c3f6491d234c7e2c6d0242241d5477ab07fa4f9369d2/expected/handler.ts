import { apiToken, displayName } from "./lib/settings.ts";

export function handler(request: Request): Proof<Response, "read_only" | "deterministic" | "retry_safe" | "idempotent" | "state_isolated" | "no_secret_leakage" | "injection_safe"> {
  const token = apiToken();
  if (token === undefined) {
    return Response.json({ error: "Service Unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
