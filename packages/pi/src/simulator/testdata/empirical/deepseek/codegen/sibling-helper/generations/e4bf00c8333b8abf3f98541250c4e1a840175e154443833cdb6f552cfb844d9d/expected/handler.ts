import { apiToken, displayName } from "./lib/settings.ts";

structural Guard<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
>;

export function handler(req: Request): Guard<Response> {
  const token = apiToken();
  if (token === undefined) {
    return Response.json({ error: "Service Unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
