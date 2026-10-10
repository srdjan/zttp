import { apiToken, displayName } from "./lib/settings.ts";

structural Guard<T> = Proof<T, "state_isolated" | "no_secret_leakage">;

export function handler(req: Request): Guard<Response> {
  if (apiToken() === undefined) {
    return Response.json({ error: "service unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
