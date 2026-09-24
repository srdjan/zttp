import { apiToken, displayName } from "./lib/settings.ts";

structural Guard<T> = Proof<T, "no_secret_leakage" | "deterministic" | "state_isolated">;

export function handler(req: Request): Guard<Response> {
  if (apiToken() === undefined) {
    return Response.json({ error: "service unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
